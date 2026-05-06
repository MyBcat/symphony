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
        cmd =
          cmd
          |> build_full_command(config)
          |> SymphonyElixir.Secrets.Resolver.wrap_command()

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
      # Unset ANTHROPIC_API_KEY in the child env. The parent (Claude Code in
      # Ankit's session) has it set to an OAuth-flavored bearer token that the
      # parent process knows how to use, but a child `claude --print` will try
      # to use it as a literal API key and get HTTP 401. Unsetting it forces
      # the child to fall back to OAuth/keychain auth — same path as
      # interactive `claude` use.
      flagged =
        [base_cmd]
        |> append_flag("--model", get_field(config, :model))
        |> append_flag("--permission-mode", get_field(config, :permission_mode))
        |> append_allowed_tools(get_field(config, :allowed_tools))
        |> append_verbose_if_missing(base_cmd)
        |> Enum.join(" ")

      # Also unset CLAUDECODE / CLAUDE_CODE_* env vars. When Symphony is
      # restarted from inside a parent Claude Code session, the BEAM inherits
      # those vars; the child `claude --print` then thinks it's running INSIDE
      # a parent CC session and emits SessionStart hook JSON on every turn
      # instead of making model calls — manifests as turn-cycle loops with
      # input/output tokens stuck at 0.
      "env -u ANTHROPIC_API_KEY -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS -u CLAUDE_CODE_DISABLE_1M_CONTEXT -u CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING -u CLAUDE_CODE_EFFORT_LEVEL -u CLAUDE_PLUGIN_DATA -u AI_AGENT " <>
        flagged
    else
      base_cmd
    end
  end

  # Claude requires --verbose when using --print with --output-format=stream-json
  # ("When using --print, --output-format=stream-json requires --verbose").
  # Append it idempotently — only if neither --verbose nor -v already appears.
  defp append_verbose_if_missing(parts, base_cmd) do
    cmd_text = Enum.join(parts, " ") <> " " <> base_cmd

    if String.match?(cmd_text, ~r/(^|\s)(--verbose|-v)(\s|$)/) do
      parts
    else
      parts ++ ["--verbose"]
    end
  end

  defp claude_invocation?(cmd) when is_binary(cmd) do
    cmd
    |> shell_words()
    |> invocation_executable()
    |> claude_executable?()
  end

  defp shell_words(cmd) do
    ~r/(?:[^\s'"]+|'[^']*'|"[^"]*")+/u
    |> Regex.scan(cmd)
    |> Enum.map(fn [word] -> strip_wrapping_quotes(word) end)
  end

  defp strip_wrapping_quotes(<<quote, rest::binary>>) when quote in [?\", ?'] do
    if String.ends_with?(rest, <<quote>>) do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      <<quote, rest::binary>>
    end
  end

  defp strip_wrapping_quotes(word), do: word

  defp invocation_executable([]), do: nil

  defp invocation_executable([token | rest]) do
    cond do
      env_assignment?(token) ->
        invocation_executable(rest)

      env_executable?(token) ->
        rest
        |> drop_env_prefix()
        |> invocation_executable()

      true ->
        token
    end
  end

  defp env_assignment?(token) when is_binary(token) do
    String.match?(token, ~r/^[A-Za-z_][A-Za-z0-9_]*=.*/)
  end

  defp env_executable?(token) when is_binary(token) do
    token
    |> Path.basename()
    |> String.equivalent?("env")
  end

  defp drop_env_prefix([]), do: []
  defp drop_env_prefix(["--" | rest]), do: rest
  defp drop_env_prefix(["-u", _name | rest]), do: drop_env_prefix(rest)
  defp drop_env_prefix(["--unset", _name | rest]), do: drop_env_prefix(rest)
  defp drop_env_prefix([<<"--unset=", _::binary>> | rest]), do: drop_env_prefix(rest)
  defp drop_env_prefix(["-C", _dir | rest]), do: drop_env_prefix(rest)
  defp drop_env_prefix(["--chdir", _dir | rest]), do: drop_env_prefix(rest)
  defp drop_env_prefix([<<"--chdir=", _::binary>> | rest]), do: drop_env_prefix(rest)

  defp drop_env_prefix([option | rest]) when option in ["-i", "--ignore-environment"] do
    drop_env_prefix(rest)
  end

  defp drop_env_prefix([token | rest]) do
    if env_assignment?(token), do: drop_env_prefix(rest), else: [token | rest]
  end

  defp claude_executable?(nil), do: false

  defp claude_executable?(token) do
    # Symphony workers are Linux hosts; Windows-only names like claude.exe are
    # intentionally out of scope.
    token
    |> Path.basename()
    |> then(&(&1 in ["claude", "claude-code"]))
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
    # Claude accepts comma- or space-separated values; a single comma-separated
    # shell word avoids the variadic flag swallowing later flags if we add any.
    quoted = tools |> Enum.join(",") |> shell_quote()
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
    # stream-json input is newline-delimited over a live stdin stream; AgentRunner
    # consumes stdout until Claude emits a terminal turn event or exits.
    # Claude's stream-json input parser requires `message.role` to be present
    # (returns `Expected message role 'user', got 'undefined'` if omitted).
    payload =
      Jason.encode!(%{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => prompt}]
        }
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
