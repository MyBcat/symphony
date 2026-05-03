defmodule SymphonyElixir.Gemini.Adapter do
  @moduledoc """
  Gemini CLI adapter — invokes `gemini --output-format stream-json` per session.
  Token accounting passes through Gemini's native shape:
  `{prompt, candidates, cached, total}` per Spec 2 DL-007. Sandbox safety floor
  enforces --sandbox flag presence and --yolo absence.

  This is a v1 implementation focused on satisfying the AgentRuntime contract.
  Full integration with AgentRunner happens in Task 9; subprocess management
  details (port-based vs. Stream-based event consumption) may evolve based on
  what AgentRunner needs.
  """

  @behaviour SymphonyElixir.AgentRuntime

  @impl SymphonyElixir.AgentRuntime
  def start_session(workspace_path, config) do
    cmd = config[:command] || config["command"]

    if is_nil(cmd) do
      {:error, :missing_command}
    else
      port_opts = [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:cd, workspace_path},
        {:line, 16_384}
      ]

      port = Port.open({:spawn, cmd}, port_opts)

      {:ok,
       %{
         port: port,
         workspace_path: workspace_path,
         tokens: %{prompt: 0, candidates: 0, cached: 0, total: 0},
         session_id: nil,
         buffer: ""
       }}
    end
  end

  @impl SymphonyElixir.AgentRuntime
  def send_turn(%{port: port}, prompt, _opts) when is_port(port) do
    payload = Jason.encode!(%{"type" => "user_turn", "text" => prompt})
    Port.command(port, payload <> "\n")
    :ok
  end

  def send_turn(_session, _prompt, _opts), do: {:error, :session_dead}

  @impl SymphonyElixir.AgentRuntime
  def stream_events(%{port: port} = session) when is_port(port) do
    Stream.unfold(session, fn s ->
      receive do
        {^port, {:data, {:eol, line}}} ->
          {parse_event_line(line), s}

        {^port, {:exit_status, status}} ->
          {%{kind: :exit, status: status}, nil}
      after
        60_000 ->
          {%{kind: :stalled}, s}
      end
    end)
    |> Stream.take_while(&(&1 != nil))
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
  def runtime_native_tokens(_session), do: %{prompt: 0, candidates: 0, total: 0}

  @impl SymphonyElixir.AgentRuntime
  def passes_safety_floor?(config, floor) do
    cmd = config[:command] || config["command"] || ""

    require_sandbox = Map.get(floor, "require_sandbox", true)
    forbid_yolo = Map.get(floor, "forbid_yolo", true)

    sandbox_present? = String.contains?(cmd, "--sandbox")
    yolo_present? = String.contains?(cmd, "--yolo")

    (not require_sandbox or sandbox_present?) and (not forbid_yolo or not yolo_present?)
  end

  @doc """
  Parse a single line of Gemini streaming-json output into the AgentRuntime
  event vocabulary. Public for testability.
  """
  @spec parse_event_line(String.t()) :: map()
  def parse_event_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "start"} = msg} ->
        %{kind: :session_started, session_id: msg["session_id"], payload: msg}

      {:ok, %{"type" => "chunk"} = msg} ->
        usage = msg["usage"] || %{}
        %{kind: :turn_delta, payload: msg, tokens: extract_tokens(usage)}

      {:ok, %{"type" => "end"} = msg} ->
        usage = msg["usage"] || %{}
        %{kind: :turn_completed, tokens: extract_tokens(usage), payload: msg}

      {:ok, decoded} ->
        %{kind: :other, payload: decoded}

      {:error, _} ->
        %{kind: :parse_error, raw: line}
    end
  end

  defp extract_tokens(usage) when is_map(usage) do
    %{
      prompt: Map.get(usage, "prompt_tokens", 0),
      candidates: Map.get(usage, "candidates_tokens", 0),
      cached: Map.get(usage, "cached_tokens", 0),
      total: Map.get(usage, "total_tokens", 0)
    }
  end

  defp extract_tokens(_), do: %{prompt: 0, candidates: 0, cached: 0, total: 0}
end
