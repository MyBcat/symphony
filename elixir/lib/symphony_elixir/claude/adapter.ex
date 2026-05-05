defmodule SymphonyElixir.Claude.Adapter do
  @moduledoc """
  Claude Code SDK adapter — invokes `claude --print --output-format stream-json
  --input-format stream-json` per session. Parses streaming JSON events into
  the AgentRuntime event vocabulary.

  Token accounting passes through Claude's native shape:
  `{input, output, cache_read, cache_creation, total}` per Spec 2 DL-007.
  Sandbox safety floor enforces permission_mode and a Bash denylist.

  This is a v1 implementation focused on satisfying the AgentRuntime contract.
  Full integration with AgentRunner happens in Task 9; subprocess management
  details (port-based vs. Stream-based event consumption) may evolve based on
  what AgentRunner needs.
  """

  @behaviour SymphonyElixir.AgentRuntime

  @bash_denylist_default [
    "*sudo*",
    "*rm -rf*",
    "*chmod 777*",
    "*curl * | sh*",
    "*wget * | sh*"
  ]

  @impl SymphonyElixir.AgentRuntime
  def start_session(workspace_path, config) do
    cmd = config[:command] || config["command"]

    cond do
      not is_binary(cmd) or String.trim(cmd) == "" ->
        {:error, :missing_command}

      not passes_safety_floor?(config, safety_floor(config)) ->
        {:error, {:sandbox_floor_violation, :claude, :config}}

      true ->
        cmd = build_full_command(cmd, config)

        with {:ok, port} <- open_bash_port(cmd, workspace_path) do
          {:ok,
           %{
             port: port,
             workspace_path: workspace_path,
             tokens: %{input: 0, output: 0, cache_read: 0, cache_creation: 0, total: 0},
             session_id: nil,
             buffer: ""
           }}
        end
    end
  end

  @doc false
  @spec build_full_command(String.t(), map()) :: String.t()
  def build_full_command(base_cmd, config) when is_binary(base_cmd) do
    if claude_invocation?(base_cmd) do
      [base_cmd]
      |> append_flag("--model", get_field(config, :model))
      |> append_flag("--permission-mode", get_field(config, :permission_mode))
      |> append_allowed_tools(get_field(config, :allowed_tools))
      |> Enum.join(" ")
    else
      base_cmd
    end
  end

  defp claude_invocation?(cmd) when is_binary(cmd) do
    cmd
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> List.first("")
    |> Path.basename()
    |> String.equivalent?("claude")
  end

  defp append_flag(parts, _flag, nil), do: parts
  defp append_flag(parts, _flag, ""), do: parts

  defp append_flag(parts, flag, value) when is_binary(value) do
    parts ++ [flag, shell_quote(value)]
  end

  defp append_flag(parts, flag, value) when is_atom(value) do
    append_flag(parts, flag, Atom.to_string(value))
  end

  defp append_allowed_tools(parts, nil), do: parts
  defp append_allowed_tools(parts, []), do: parts

  defp append_allowed_tools(parts, tools) when is_list(tools) do
    quoted = tools |> Enum.map(&shell_quote/1) |> Enum.join(" ")
    parts ++ ["--allowed-tools", quoted]
  end

  defp shell_quote(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9_\-\.,\/:=]+$/) do
      value
    else
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    end
  end

  defp get_field(config, key) when is_atom(key) do
    config[key] || config[Atom.to_string(key)]
  end

  @impl SymphonyElixir.AgentRuntime
  def send_turn(%{port: port}, prompt, _opts) when is_port(port) do
    payload =
      Jason.encode!(%{
        "type" => "user",
        "message" => %{"content" => [%{"type" => "text", "text" => prompt}]}
      })

    Port.command(port, payload <> "\n")
    :ok
  end

  def send_turn(_session, _prompt, _opts), do: {:error, :session_dead}

  @impl SymphonyElixir.AgentRuntime
  def stream_events(%{port: port} = session) when is_port(port) do
    Stream.unfold({:open, session}, fn
      {:done, _s} ->
        nil

      {:open, s} ->
        receive do
          {^port, {:data, {:eol, line}}} ->
            {parse_event_line(line), {:open, s}}

          {^port, {:exit_status, status}} ->
            {%{kind: :exit, status: status}, {:done, s}}
        after
          60_000 ->
            {%{kind: :stalled}, {:open, s}}
        end
    end)
  end

  def stream_events(_session), do: Stream.cycle([]) |> Stream.take(0)

  @impl SymphonyElixir.AgentRuntime
  def stop_session(%{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def stop_session(_session), do: :ok

  @impl SymphonyElixir.AgentRuntime
  def runtime_native_tokens(%{tokens: tokens}), do: tokens
  def runtime_native_tokens(_session), do: %{input: 0, output: 0, total: 0}

  @impl SymphonyElixir.AgentRuntime
  def passes_safety_floor?(config, floor) do
    perm_mode = config[:permission_mode] || config["permission_mode"]
    floor_perm_mode = Map.get(floor, "permission_mode", "acceptEdits")

    perm_ok = perm_mode == floor_perm_mode

    bash_denylist = Map.get(floor, "bash_denylist", @bash_denylist_default)
    allowed = config[:allowed_tools] || config["allowed_tools"] || []

    bash_ok =
      Enum.all?(allowed, fn tool ->
        not Enum.any?(bash_denylist, fn pattern -> match_glob?(tool, pattern) end)
      end)

    perm_ok and bash_ok
  end

  @doc """
  Parse a single line of Claude streaming-json output into the AgentRuntime
  event vocabulary. Public for testability.
  """
  @spec parse_event_line(String.t()) :: map()
  def parse_event_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> classify_event(decoded)
      {:error, _} -> %{kind: :parse_error, raw: line}
    end
  end

  defp classify_event(%{"type" => "system", "subtype" => "init"} = msg) do
    %{kind: :session_started, session_id: msg["session_id"], payload: msg}
  end

  defp classify_event(%{"type" => "assistant"} = msg) do
    usage = get_in(msg, ["message", "usage"]) || %{}
    %{kind: :turn_delta, payload: msg, tokens: extract_tokens(usage)}
  end

  defp classify_event(%{"type" => "result", "subtype" => "success"} = msg) do
    usage = msg["usage"] || %{}
    %{kind: :turn_completed, tokens: extract_tokens(usage), payload: msg}
  end

  defp classify_event(%{"type" => "result", "subtype" => "error"} = msg) do
    %{kind: :error, payload: msg}
  end

  defp classify_event(decoded) do
    %{kind: :other, payload: decoded}
  end

  defp extract_tokens(usage) when is_map(usage) do
    %{
      input: Map.get(usage, "input_tokens", 0),
      output: Map.get(usage, "output_tokens", 0),
      cache_read: Map.get(usage, "cache_read_input_tokens", 0),
      cache_creation: Map.get(usage, "cache_creation_input_tokens", 0),
      total: Map.get(usage, "total_tokens", 0)
    }
  end

  defp extract_tokens(_), do: %{input: 0, output: 0, cache_read: 0, cache_creation: 0, total: 0}

  defp match_glob?(text, pattern) do
    regex_str =
      pattern
      |> Regex.escape()
      |> String.replace(~r/\\\*/, ".*")

    case Regex.compile("^" <> regex_str <> "$") do
      {:ok, regex} -> Regex.match?(regex, text)
      _ -> false
    end
  end

  defp safety_floor(config) do
    config[:_safety_floor] || config["_safety_floor"] || %{}
  end

  defp open_bash_port(cmd, workspace_path) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      bash ->
        try do
          {:ok,
           Port.open(
             {:spawn_executable, String.to_charlist(bash)},
             [
               :binary,
               :exit_status,
               :hide,
               :stderr_to_stdout,
               args: [~c"-lc", String.to_charlist(cmd)],
               cd: String.to_charlist(workspace_path),
               line: 16_384
             ]
           )}
        rescue
          error in ArgumentError ->
            {:error, {:port_open_failed, Exception.message(error)}}
        end
    end
  end
end
