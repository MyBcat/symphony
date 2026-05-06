defmodule SymphonyElixir.Codex.Adapter do
  @moduledoc """
  Codex runtime adapter. Drives Codex CLI 0.128+ via `codex exec --json`,
  spawning one subprocess per turn and parsing the JSONL `ThreadEvent`
  stream (`thread.started`, `turn.started`, `turn.completed`, `turn.failed`,
  `error`, `item.{started,updated,completed}`).

  Each `send_turn/3` invocation is a one-shot `codex exec --json` run.
  Multi-turn continuity comes from workspace state (committed code, branch,
  workpad) — Codex `exec` itself is stateless and exits after emitting
  `turn.completed` (or `turn.failed`).

  Token accounting stays Codex-native (`%{input, output, total,
  cached_input, reasoning_output}`) per Spec 2 DL-007 — there is no
  cross-runtime normalization. AgentRunner's
  `extract_token_delta_from_usage/1` reads `input_tokens` / `output_tokens`
  off the `:usage` map carried on the `:turn_completed` envelope, which
  this adapter populates verbatim from the JSONL stream.
  """

  @behaviour SymphonyElixir.AgentRuntime

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          command: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_timeout_ms: pos_integer(),
          stream_buffer_key: reference()
        }

  ## ──────────────────────────────────────────────────────────────────────
  ## AgentRuntime callbacks
  ## ──────────────────────────────────────────────────────────────────────

  @impl SymphonyElixir.AgentRuntime
  @spec start_session(Path.t(), keyword() | map()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts_or_config \\ []) do
    worker_host = fetch_worker_host(opts_or_config)

    with :ok <- validate_profile_config(opts_or_config),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, command} <- command_for_session(opts_or_config),
         {:ok, policies} <- session_policies(expanded_workspace, worker_host, opts_or_config) do
      {:ok,
       %{
         command: command,
         workspace: expanded_workspace,
         worker_host: worker_host,
         approval_policy: policies.approval_policy,
         thread_sandbox: policies.thread_sandbox,
         turn_timeout_ms: Config.settings!().codex.turn_timeout_ms,
         stream_buffer_key: make_ref()
       }}
    end
  end

  @impl SymphonyElixir.AgentRuntime
  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  @doc """
  Submit a single prompt to a previously-started session.

  Spawns a fresh `codex exec --json` subprocess, writes the prompt to it
  via stdin (a temp file in the workspace, redirected via the bash
  wrapper), and consumes the JSONL event stream until `turn.completed`,
  `turn.failed`, or a top-level `error` event arrives. Events are observed
  inline via the optional `:on_message` callback AND mirrored into a
  per-session buffer that `stream_events/1` drains, so the polymorphic
  AgentRunner contract stays uniform across runtimes.

  Recognized opts:

    * `:issue` — issue map (with `:id`, `:identifier`, `:title`) used by
      `run_turn/4`. If absent, a placeholder is generated.
    * `:on_message` — observer fn invoked inline for each event during the
      turn. AgentRunner uses this to drive Tracker writes (status flips,
      workpad upserts, PR detection).
  """
  @impl SymphonyElixir.AgentRuntime
  @spec send_turn(session(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_turn(session, prompt, opts \\ []) do
    issue = Keyword.get(opts, :issue, default_issue_for_send_turn())
    extra_on_message = Keyword.get(opts, :on_message)

    reset_event_buffer(session)
    reset_session_tokens(session)

    on_message =
      compose_on_message(
        fn message -> capture_event_for_stream(session, message) end,
        compose_on_message(
          fn message -> accumulate_tokens_from_message(session, message) end,
          extra_on_message
        )
      )

    case run_turn(session, prompt, issue, on_message: on_message) do
      {:ok, _result} -> :ok
      {:error, _reason} = err -> err
    end
  end

  @impl SymphonyElixir.AgentRuntime
  @spec stream_events(session()) :: Enumerable.t()
  def stream_events(session) do
    Stream.unfold(session, fn s ->
      case drain_event_buffer(s) do
        nil -> nil
        [] -> nil
        events when is_list(events) -> {Enum.reverse(events), :done}
      end
    end)
    |> Stream.flat_map(& &1)
  end

  @impl SymphonyElixir.AgentRuntime
  @spec runtime_native_tokens(session()) :: %{required(atom()) => non_neg_integer()}
  def runtime_native_tokens(session) do
    case Process.get({:symphony_codex_adapter_tokens, session_buffer_key(session)}) do
      %{} = tokens -> tokens
      _ -> empty_tokens()
    end
  end

  @impl SymphonyElixir.AgentRuntime
  @spec passes_safety_floor?(map(), map()) :: boolean()
  def passes_safety_floor?(config, floor) do
    thread_sandbox = config[:thread_sandbox] || config["thread_sandbox"]
    approval_policy = config[:approval_policy] || config["approval_policy"]

    floor_thread_sandbox = Map.get(floor, "thread_sandbox", "workspace-write")

    sandbox_at_or_below_floor?(thread_sandbox, floor_thread_sandbox) and
      approval_policy == "never"
  end

  ## ──────────────────────────────────────────────────────────────────────
  ## Legacy entry points (preserved for Spec 1 callers + tests)
  ## ──────────────────────────────────────────────────────────────────────

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @doc """
  Run a single Codex `exec --json` turn against a started session.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    metadata = base_metadata(session)

    case start_codex_process(session, prompt) do
      {:ok, port, prompt_file} ->
        try do
          state = %{
            on_message: on_message,
            metadata: metadata,
            issue: issue,
            session_id: nil,
            thread_id: nil,
            session_emitted?: false,
            timeout_ms: session.turn_timeout_ms
          }

          drive_stream(port, "", state)
        after
          stop_port(port)
          if is_binary(prompt_file), do: File.rm(prompt_file)
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  ## ──────────────────────────────────────────────────────────────────────
  ## Subprocess + stream loop
  ## ──────────────────────────────────────────────────────────────────────

  defp start_codex_process(session, prompt) do
    case write_prompt_file(session, prompt) do
      {:ok, prompt_file} ->
        with {:ok, port} <- spawn_port(session, prompt, prompt_file) do
          {:ok, port, prompt_file}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_prompt_file(%{worker_host: nil, workspace: workspace}, prompt) do
    dir = Path.join(workspace, ".symphony")

    with :ok <- File.mkdir_p(dir) do
      path =
        Path.join(
          dir,
          "codex_prompt_#{System.unique_integer([:positive])}.txt"
        )

      case File.write(path, prompt) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, {:prompt_write_failed, path, reason}}
      end
    end
  end

  # Remote workers receive the prompt as a shell-escaped positional
  # argument inside the SSH command (no remote temp file created — that
  # would require a second SSH round trip). See `spawn_port/3` remote
  # branch.
  defp write_prompt_file(_session, _prompt), do: {:ok, nil}

  defp spawn_port(%{worker_host: nil} = session, _prompt, prompt_file) when is_binary(prompt_file) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      cmd = local_launch_command(session.command, prompt_file)
      wrapped = SymphonyElixir.Secrets.Resolver.wrap_command(cmd)
      env = scrub_inherited_env()

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(wrapped)],
            cd: String.to_charlist(session.workspace),
            line: @port_line_bytes,
            env: env
          ]
        )

      {:ok, port}
    end
  end

  defp spawn_port(%{worker_host: worker_host} = session, prompt, _prompt_file)
       when is_binary(worker_host) do
    # Remote workers receive the prompt as a shell-escaped positional
    # argument embedded directly in the SSH command. SSH's stdin pipe
    # cannot be half-closed from Erlang, so streaming the prompt over
    # stdin would require closing the port to signal EOF — which
    # terminates the SSH connection before codex finishes reading. The
    # positional-arg path avoids that timing trap and matches how
    # `codex exec` documents its `[PROMPT]` argument. ARG_MAX limits
    # apply (typically ≥ 128 KB on Linux), which is far above the
    # ~50 KB Symphony prompts produced by `PromptBuilder`.
    remote_command = remote_launch_command(session.workspace, session.command, prompt)

    case SSH.start_port(worker_host, remote_command, line: @port_line_bytes) do
      {:ok, port} -> {:ok, port}
      other -> other
    end
  end

  defp local_launch_command(command, prompt_file) do
    "exec " <> command <> " < " <> shell_escape(prompt_file)
  end

  defp remote_launch_command(workspace, command, prompt) do
    [
      "cd #{shell_escape(workspace)}",
      "exec #{command} #{shell_escape(prompt)}"
    ]
    |> Enum.join(" && ")
  end

  # Strip env vars that would corrupt a fresh `codex exec` child:
  #
  # * `CODEX_COMPANION_*` — when Symphony runs inside a parent Claude
  #   Code session that has booted the codex-companion broker (the
  #   `cxc-*` daemon under /tmp), the BEAM inherits these. Children
  #   would attempt to talk to that broker socket and either crash or
  #   leak state across orchestrations.
  # * `OPENAI_API_KEY` — codex 0.128 prefers ChatGPT auth via
  #   `~/.codex/auth.toml`; an inherited operator API key from the
  #   parent shell can flip auth modes mid-flight.
  defp scrub_inherited_env do
    [
      {~c"CODEX_COMPANION_SESSION_ID", false},
      {~c"CODEX_COMPANION_BROKER_SOCK", false},
      {~c"CODEX_COMPANION_BROKER_PID", false},
      {~c"OPENAI_API_KEY", false}
    ]
  end

  defp drive_stream(port, pending_line, state) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        process_line(line, port, state)

      {^port, {:data, {:noeol, chunk}}} ->
        drive_stream(port, pending_line <> to_string(chunk), state)

      {^port, {:exit_status, status}} ->
        handle_exit(status, state)
    after
      state.timeout_ms ->
        emit(state.on_message, :turn_failed, %{reason: :turn_timeout}, state.metadata)
        {:error, :turn_timeout}
    end
  end

  defp process_line(line, port, state) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = event} when is_binary(type) ->
        handle_event(type, event, line, port, state)

      {:ok, _other} ->
        log_non_json_stream_line(line, "turn stream")
        drive_stream(port, "", state)

      {:error, _reason} ->
        log_non_json_stream_line(line, "turn stream")

        if protocol_message_candidate?(line) do
          emit(
            state.on_message,
            :malformed,
            %{payload: line, raw: line},
            state.metadata
          )
        end

        drive_stream(port, "", state)
    end
  end

  defp handle_event("thread.started", event, _raw, port, state) do
    thread_id = Map.get(event, "thread_id")
    state = %{state | thread_id: thread_id, session_id: thread_id}

    state = ensure_session_started_emitted(state)
    drive_stream(port, "", state)
  end

  defp handle_event("turn.started", _event, _raw, port, state) do
    # Symphony's `:session_started` is already emitted on `thread.started`,
    # so `turn.started` only carries observability value. Forward as a
    # generic notification so workpad-write triggers can react if they want
    # without confusing AgentRunner's `:codex` event matcher (which only
    # cares about `:turn_completed` / `:turn_failed`).
    state = ensure_session_started_emitted(state)
    drive_stream(port, "", state)
  end

  defp handle_event("turn.completed", event, raw, port, state) do
    state = ensure_session_started_emitted(state)
    usage = Map.get(event, "usage") || %{}

    metadata = Map.put(state.metadata, :usage, usage)

    emit(
      state.on_message,
      :turn_completed,
      %{
        payload: event,
        raw: raw,
        details: event,
        usage: usage
      },
      metadata
    )

    # Drain remaining bytes so the port closes cleanly. Codex exits after
    # `turn.completed`; we don't loop further to receive more events.
    _ = drain_port_until_exit(port, "")
    {:ok, %{result: :turn_completed, session_id: state.session_id, thread_id: state.thread_id}}
  end

  defp handle_event("turn.failed", event, raw, port, state) do
    state = ensure_session_started_emitted(state)
    error = Map.get(event, "error", %{})

    emit(
      state.on_message,
      :turn_failed,
      %{payload: event, raw: raw, details: error},
      state.metadata
    )

    _ = drain_port_until_exit(port, "")
    {:error, {:turn_failed, error}}
  end

  defp handle_event("error", event, raw, port, state) do
    state = ensure_session_started_emitted(state)
    message = Map.get(event, "message", "codex stream error")

    emit(
      state.on_message,
      :turn_failed,
      %{payload: event, raw: raw, details: %{"message" => message}},
      state.metadata
    )

    _ = drain_port_until_exit(port, "")
    {:error, {:turn_failed, %{"message" => message}}}
  end

  defp handle_event("item.started", event, raw, port, state) do
    state = ensure_session_started_emitted(state)
    item = Map.get(event, "item", %{})
    item_type = Map.get(item, "type")

    case classify_item_event(:started, item_type, item) do
      nil ->
        emit_notification(state, event, raw)

      symphony_event ->
        emit(state.on_message, symphony_event, %{payload: event, raw: raw, item: item}, state.metadata)
    end

    drive_stream(port, "", state)
  end

  defp handle_event("item.updated", event, raw, port, state) do
    state = ensure_session_started_emitted(state)
    emit_notification(state, event, raw)
    drive_stream(port, "", state)
  end

  defp handle_event("item.completed", event, raw, port, state) do
    state = ensure_session_started_emitted(state)
    item = Map.get(event, "item", %{})
    item_type = Map.get(item, "type")

    symphony_event =
      classify_item_event(:completed, item_type, item) || :notification

    emit(
      state.on_message,
      symphony_event,
      %{payload: event, raw: raw, item: item},
      state.metadata
    )

    drive_stream(port, "", state)
  end

  defp handle_event(_type, event, raw, port, state) do
    state = ensure_session_started_emitted(state)
    emit_notification(state, event, raw)
    drive_stream(port, "", state)
  end

  defp emit_notification(state, event, raw) do
    emit(
      state.on_message,
      :notification,
      %{payload: event, raw: raw},
      state.metadata
    )
  end

  # Map Codex `item.{started,completed}` payloads onto Symphony's existing
  # tool-call vocabulary. `:tool_call_started`/`:tool_call_completed`/
  # `:tool_call_failed` mirror what AgentRunner already understood under
  # the JSON-RPC adapter — emitting these keeps any future workpad/UI
  # integration that relies on them firing.
  defp classify_item_event(:started, "command_execution", _item), do: :tool_call_started
  defp classify_item_event(:started, "mcp_tool_call", _item), do: :tool_call_started
  defp classify_item_event(:started, "file_change", _item), do: :tool_call_started
  defp classify_item_event(:started, "web_search", _item), do: :tool_call_started

  defp classify_item_event(:completed, "command_execution", item) do
    case Map.get(item, "status") do
      "completed" -> :tool_call_completed
      "failed" -> :tool_call_failed
      "declined" -> :tool_call_failed
      _ -> :tool_call_completed
    end
  end

  defp classify_item_event(:completed, "mcp_tool_call", item) do
    case Map.get(item, "status") do
      "completed" -> :tool_call_completed
      "failed" -> :tool_call_failed
      _ -> :tool_call_completed
    end
  end

  defp classify_item_event(:completed, "file_change", item) do
    case Map.get(item, "status") do
      "completed" -> :tool_call_completed
      "failed" -> :tool_call_failed
      _ -> :tool_call_completed
    end
  end

  defp classify_item_event(:completed, "agent_message", _item), do: nil
  defp classify_item_event(:completed, "reasoning", _item), do: nil
  defp classify_item_event(:completed, "todo_list", _item), do: nil
  defp classify_item_event(:completed, "web_search", _item), do: :tool_call_completed
  defp classify_item_event(:completed, "error", _item), do: nil
  defp classify_item_event(_phase, _type, _item), do: nil

  defp ensure_session_started_emitted(%{session_emitted?: true} = state), do: state

  defp ensure_session_started_emitted(%{session_emitted?: false, thread_id: thread_id} = state) do
    session_id = state.session_id || thread_id || generate_synthetic_session_id()

    Logger.info("Codex session started for #{issue_context(state.issue)} session_id=#{session_id}")

    emit(
      state.on_message,
      :session_started,
      %{
        session_id: session_id,
        thread_id: thread_id,
        turn_id: nil
      },
      state.metadata
    )

    %{state | session_emitted?: true, session_id: session_id}
  end

  defp generate_synthetic_session_id do
    "codex-exec-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp drain_port_until_exit(port, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        log_non_json_stream_line(line, "turn stream tail")
        drain_port_until_exit(port, "")

      {^port, {:data, {:noeol, chunk}}} ->
        drain_port_until_exit(port, pending_line <> to_string(chunk))

      {^port, {:exit_status, _status}} ->
        :ok
    after
      1_000 ->
        :ok
    end
  end

  defp handle_exit(status, state) when status == 0 do
    # Codex exited cleanly without emitting `turn.completed`. This is
    # unexpected — something terminated the stream early. Surface as a
    # turn_failed so AgentRunner can retry/escalate.
    reason = {:codex_exit_without_turn_completed, status}

    emit(
      state.on_message,
      :turn_failed,
      %{reason: reason},
      state.metadata
    )

    {:error, reason}
  end

  defp handle_exit(status, state) do
    emit(
      state.on_message,
      :turn_failed,
      %{reason: {:port_exit, status}},
      state.metadata
    )

    {:error, {:port_exit, status}}
  end

  ## ──────────────────────────────────────────────────────────────────────
  ## Configuration helpers
  ## ──────────────────────────────────────────────────────────────────────

  defp fetch_worker_host(opts) when is_list(opts), do: Keyword.get(opts, :worker_host)

  defp fetch_worker_host(config) when is_map(config) do
    Map.get(config, :worker_host) || Map.get(config, "worker_host")
  end

  defp fetch_worker_host(_), do: nil

  defp command_for_session(config) when is_map(config) do
    case config_value(config, :command) do
      command when is_binary(command) and command != "" -> {:ok, command}
      _ -> legacy_codex_command()
    end
  end

  defp command_for_session(_opts), do: legacy_codex_command()

  defp legacy_codex_command do
    case Config.settings!().codex.command do
      command when is_binary(command) and command != "" -> {:ok, command}
      _ -> {:error, :missing_command}
    end
  end

  defp validate_profile_config(config) when is_map(config) do
    floor = config[:_safety_floor] || config["_safety_floor"] || %{}

    if passes_safety_floor?(config, floor) do
      :ok
    else
      {:error, {:sandbox_floor_violation, :codex, :config}}
    end
  end

  defp validate_profile_config(_opts), do: :ok

  defp session_policies(workspace, worker_host, config) when is_map(config) do
    with {:ok, legacy_policies} <- legacy_session_policies(workspace, worker_host) do
      {:ok,
       %{
         approval_policy: config_value(config, :approval_policy) || legacy_policies.approval_policy,
         thread_sandbox: config_value(config, :thread_sandbox) || legacy_policies.thread_sandbox
       }}
    end
  end

  defp session_policies(workspace, worker_host, _opts) do
    legacy_session_policies(workspace, worker_host)
  end

  defp legacy_session_policies(workspace, nil) do
    case Config.codex_runtime_settings(workspace) do
      {:ok, settings} -> {:ok, Map.take(settings, [:approval_policy, :thread_sandbox])}
      other -> other
    end
  end

  defp legacy_session_policies(workspace, worker_host) when is_binary(worker_host) do
    case Config.codex_runtime_settings(workspace, remote: true) do
      {:ok, settings} -> {:ok, Map.take(settings, [:approval_policy, :thread_sandbox])}
      other -> other
    end
  end

  defp config_value(config, key) when is_map(config) and is_atom(key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp sandbox_at_or_below_floor?(thread_sandbox, floor_thread_sandbox) do
    sandbox_rank = %{"read-only" => 0, "workspace-write" => 1}

    with sandbox when is_integer(sandbox) <- Map.get(sandbox_rank, thread_sandbox),
         floor when is_integer(floor) <- Map.get(sandbox_rank, floor_thread_sandbox) do
      sandbox <= floor
    else
      _ -> false
    end
  end

  ## ──────────────────────────────────────────────────────────────────────
  ## Per-session token + event buffer state (process dictionary)
  ## ──────────────────────────────────────────────────────────────────────

  defp compose_on_message(primary, nil), do: primary

  defp compose_on_message(primary, secondary) when is_function(secondary, 1) do
    fn message ->
      _ = primary.(message)
      _ = secondary.(message)
      :ok
    end
  end

  defp capture_event_for_stream(session, message) do
    key = {:symphony_codex_adapter_events, session_buffer_key(session)}
    existing = Process.get(key, [])
    Process.put(key, [message | existing])
    :ok
  end

  defp reset_event_buffer(session) do
    Process.put({:symphony_codex_adapter_events, session_buffer_key(session)}, [])
    :ok
  end

  defp drain_event_buffer(session) do
    Process.delete({:symphony_codex_adapter_events, session_buffer_key(session)})
  end

  defp reset_session_tokens(session) do
    Process.put({:symphony_codex_adapter_tokens, session_buffer_key(session)}, empty_tokens())
    :ok
  end

  defp accumulate_tokens_from_message(session, %{usage: usage}) when is_map(usage) do
    update_session_tokens(session, usage)
  end

  defp accumulate_tokens_from_message(_session, _message), do: :ok

  defp update_session_tokens(session, usage) when is_map(usage) do
    key = {:symphony_codex_adapter_tokens, session_buffer_key(session)}
    current = Process.get(key, empty_tokens())

    input = pick_token_count(usage, ["input_tokens", "prompt_tokens", :input_tokens, :input])
    output = pick_token_count(usage, ["output_tokens", "completion_tokens", :output_tokens, :output])
    cached_input = pick_token_count(usage, ["cached_input_tokens", :cached_input_tokens, :cached_input])
    reasoning = pick_token_count(usage, ["reasoning_output_tokens", :reasoning_output_tokens, :reasoning_output])
    total = pick_token_count(usage, ["total_tokens", :total_tokens, :total])

    inferred_total = if total > 0, do: total, else: input + output

    Process.put(key, %{
      input: max(current.input, input),
      output: max(current.output, output),
      total: max(current.total, inferred_total),
      cached_input: max(current.cached_input, cached_input),
      reasoning_output: max(current.reasoning_output, reasoning)
    })

    :ok
  end

  defp pick_token_count(usage, keys) when is_map(usage) and is_list(keys) do
    Enum.reduce_while(keys, 0, fn key, acc ->
      case Map.get(usage, key) do
        value when is_integer(value) and value >= 0 -> {:halt, value}
        _ -> {:cont, acc}
      end
    end)
  end

  defp empty_tokens, do: %{input: 0, output: 0, total: 0, cached_input: 0, reasoning_output: 0}

  defp session_buffer_key(%{stream_buffer_key: ref}) when is_reference(ref), do: ref
  defp session_buffer_key(session), do: session

  ## ──────────────────────────────────────────────────────────────────────
  ## Logging + utility
  ## ──────────────────────────────────────────────────────────────────────

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)
      |> SymphonyElixir.Secrets.Scrubber.scrub()

    if text != "" do
      cond do
        String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) ->
          Logger.warning("Codex #{stream_label} output: #{text}")

        true ->
          Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}),
    do: "issue_id=#{issue_id} issue_identifier=#{identifier}"

  defp issue_context(%{"id" => issue_id, "identifier" => identifier}),
    do: "issue_id=#{issue_id} issue_identifier=#{identifier}"

  defp issue_context(_other), do: "issue_id=unknown issue_identifier=unknown"

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined -> :ok
      _ -> safe_close(port)
    end
  end

  defp safe_close(port) do
    try do
      Port.close(port)
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  defp emit(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp base_metadata(%{worker_host: nil}), do: %{}
  defp base_metadata(%{worker_host: host}) when is_binary(host), do: %{worker_host: host}
  defp base_metadata(_), do: %{}

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp default_issue_for_send_turn do
    %{
      id: "send-turn-#{System.unique_integer([:positive])}",
      identifier: "AGENT",
      title: "send_turn"
    }
  end
end
