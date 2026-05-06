defmodule SymphonyElixir.Codex.Adapter do
  @moduledoc """
  Codex runtime adapter. Implements `SymphonyElixir.AgentRuntime` on top of the
  long-running Codex app-server JSON-RPC 2.0 stream over stdio.

  This module preserves the legacy `run/4` and `run_turn/4` entry points used
  by extension tests and Spec 1 callers, while exposing the six
  `AgentRuntime` callbacks consumed by `AgentRunner`'s polymorphic dispatch
  path.

  Token accounting stays Codex-native (`%{input, output, total}`) per Spec 2
  DL-007 — there is no cross-runtime normalization.
  """

  @behaviour SymphonyElixir.AgentRuntime

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Codex.ProjectTrust, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

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
  Start a Codex app-server session for `workspace`.

  This function serves both the legacy `AgentRunner` integration (which passes
  a `Keyword.t()` of opts, currently only `:worker_host`) and the
  `SymphonyElixir.AgentRuntime.start_session/2` behaviour callback (which
  passes a `map()` config). Map keys may use either atoms or strings. Profile
  map config controls the Codex command plus `approval_policy`,
  `thread_sandbox`, and optional `turn_sandbox_policy`; legacy keyword opts keep
  using the top-level `codex.*` settings.
  """
  @impl SymphonyElixir.AgentRuntime
  @spec start_session(Path.t(), keyword() | map()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts_or_config \\ []) do
    worker_host = fetch_worker_host(opts_or_config)

    with :ok <- validate_profile_config(opts_or_config),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         :ok <- maybe_ensure_local_codex_trust(expanded_workspace, worker_host),
         {:ok, command} <- command_for_session(opts_or_config),
         {:ok, port} <- start_port(expanded_workspace, worker_host, command) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <-
             session_policies(expanded_workspace, worker_host, opts_or_config),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  # SSH-backed sessions execute Codex on the remote worker, where the
  # `~/.codex/config.toml` trust file is owned by that host. Local trust
  # automation only runs when worker_host is absent; remote workers are
  # responsible for their own trust setup.
  defp maybe_ensure_local_codex_trust(_workspace, worker_host) when is_binary(worker_host),
    do: :ok

  defp maybe_ensure_local_codex_trust(workspace, nil) do
    case ProjectTrust.ensure_trusted(workspace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Codex project trust update failed for workspace=#{workspace}: #{inspect(reason)}; " <>
            "if Codex emits 'remoteControl/status/changed status: disabled' the workspace " <>
            "must be added manually to ~/.codex/config.toml"
        )

        :ok
    end
  end

  defp fetch_worker_host(opts) when is_list(opts), do: Keyword.get(opts, :worker_host)

  defp fetch_worker_host(config) when is_map(config) do
    Map.get(config, :worker_host) || Map.get(config, "worker_host")
  end

  defp fetch_worker_host(_), do: nil

  defp command_for_session(config) when is_map(config) do
    config
    |> config_value(:command)
    |> case do
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

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, [])
      end)

    case start_turn(
           port,
           thread_id,
           prompt,
           issue,
           workspace,
           approval_policy,
           turn_sandbox_policy
         ) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @impl SymphonyElixir.AgentRuntime
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  @doc """
  Submit a single prompt to a previously-started session.

  `AgentRuntime` shape: events are observed inline via the optional
  `:on_message` callback AND mirrored into a per-session buffer that
  `stream_events/1` drains. The Codex JSON-RPC App Server protocol is
  synchronous in nature: a turn is driven to completion in one call, so
  `send_turn/3` blocks until `turn/completed`, `turn/failed`, or
  `turn/cancelled`. Real-time observation is preserved via the inline
  callback so AgentRunner's workpad-write triggers fire as events arrive.

  Recognized opts:
    * `:issue` — issue map (with `:id`, `:identifier`, `:title`) used by
      `run_turn/4`. If absent, a placeholder is generated.
    * `:on_message` — observer fn invoked inline for each event during the
      turn. AgentRunner uses this to drive Tracker writes (status flips,
      workpad upserts, PR detection). Events are also captured to a
      per-session buffer so `stream_events/1` can still emit them; this
      keeps the polymorphic adapter contract uniform across runtimes.
    * `:tool_executor` — passed through to `run_turn/4`.
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

    run_turn_opts =
      opts
      |> Keyword.drop([:issue, :on_message])
      |> Keyword.put(:on_message, on_message)

    case run_turn(session, prompt, issue, run_turn_opts) do
      {:ok, _result} -> :ok
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Return an `Enumerable` of events captured for `session` during the most
  recent `send_turn/3` call. The buffer is replenished per turn (cleared
  at the start of each `send_turn/3`) so the same Stream API works for the
  multi-turn loop in AgentRunner.

  Codex events have already been observed inline via the `:on_message`
  callback before `stream_events/1` is consumed; the Stream is provided so
  the polymorphic AgentRunner contract stays uniform across adapters.
  """
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

  @doc """
  Return Codex's native token shape `%{input: int, output: int, total: int}`.

  Tokens are accumulated by `send_turn/3` from `usage` blocks attached to
  JSON-RPC events. The shape stays Codex-native (no cross-runtime
  normalization) per Spec 2 DL-007.
  """
  @impl SymphonyElixir.AgentRuntime
  @spec runtime_native_tokens(session()) :: %{required(atom()) => non_neg_integer()}
  def runtime_native_tokens(session) do
    case Process.get({:symphony_codex_adapter_tokens, session_buffer_key(session)}) do
      %{} = tokens -> tokens
      _ -> %{input: 0, output: 0, total: 0}
    end
  end

  @doc """
  Check whether `config` satisfies the profile safety floor.

  Codex-native vocabulary:

    * `thread_sandbox` ∈ `["read-only", "workspace-write", "danger-full-access"]`
    * `approval_policy` ∈ `["never", ...]`

  Floor passes when `thread_sandbox` is no more permissive than the floor's
  `thread_sandbox` within the safe v1 set (`read-only` <= `workspace-write`),
  AND `approval_policy` is exactly `never`. Both atom and string keys are
  accepted on `config` so YAML-parsed and runtime-built configs share this
  check.
  """
  @impl SymphonyElixir.AgentRuntime
  @spec passes_safety_floor?(map(), map()) :: boolean()
  def passes_safety_floor?(config, floor) do
    thread_sandbox = config[:thread_sandbox] || config["thread_sandbox"]
    approval_policy = config[:approval_policy] || config["approval_policy"]

    floor_thread_sandbox = Map.get(floor, "thread_sandbox", "workspace-write")

    thread_sandbox_ok = sandbox_at_or_below_floor?(thread_sandbox, floor_thread_sandbox)
    approval_policy_ok = approval_policy == "never"

    thread_sandbox_ok and approval_policy_ok
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

  defp default_issue_for_send_turn do
    %{
      id: "send-turn-#{System.unique_integer([:positive])}",
      identifier: "AGENT",
      title: "send_turn"
    }
  end

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
    Process.put(
      {:symphony_codex_adapter_tokens, session_buffer_key(session)},
      %{input: 0, output: 0, total: 0}
    )

    :ok
  end

  defp accumulate_tokens_from_message(session, %{usage: usage}) when is_map(usage) do
    update_session_tokens(session, usage)
  end

  defp accumulate_tokens_from_message(_session, _message), do: :ok

  defp update_session_tokens(session, usage) when is_map(usage) do
    key = {:symphony_codex_adapter_tokens, session_buffer_key(session)}
    current = Process.get(key, %{input: 0, output: 0, total: 0})

    input = pick_token_count(usage, ["input_tokens", "prompt_tokens", :input])
    output = pick_token_count(usage, ["output_tokens", "completion_tokens", :output])
    total = pick_token_count(usage, ["total_tokens", :total])

    Process.put(key, %{
      input: max(current.input, input),
      output: max(current.output, output),
      total: max(current.total, total)
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

  # Use the session port (a process-local term) as the buffer key so that
  # multiple concurrent sessions in the same process don't share state.
  defp session_buffer_key(%{port: port}) when is_port(port), do: port
  defp session_buffer_key(session), do: session

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

  defp start_port(workspace, nil, command) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      wrapped_command = SymphonyElixir.Secrets.Resolver.wrap_command(command)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(wrapped_command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, command) when is_binary(worker_host) do
    # Remote workers don't currently receive .env.symphony — secrets resolved
    # locally are not transported via SSH (per SYM-11923119480 §Out of scope).
    remote_command = remote_launch_command(workspace, command)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp remote_launch_command(workspace, command) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "exec #{command}"
    ]
    |> Enum.join(" && ")
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, worker_host, config) when is_map(config) do
    with {:ok, legacy_policies} <- legacy_session_policies(workspace, worker_host) do
      {:ok,
       %{
         approval_policy: config_value(config, :approval_policy) || legacy_policies.approval_policy,
         thread_sandbox: config_value(config, :thread_sandbox) || legacy_policies.thread_sandbox,
         turn_sandbox_policy: config_value(config, :turn_sandbox_policy) || legacy_policies.turn_sandbox_policy
       }}
    end
  end

  defp session_policies(workspace, worker_host, _opts) do
    legacy_session_policies(workspace, worker_host)
  end

  defp legacy_session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp legacy_session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp config_value(config, key) when is_map(config) and is_atom(key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox
       }) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(
         port,
         on_message,
         timeout_ms,
         pending_line,
         tool_executor,
         auto_approve_requests
       ) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_incoming(
          port,
          on_message,
          complete_line,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text),
    do: text

  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions})
       when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions})
       when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or
      String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        log_pre_response_message(other)
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)
      |> SymphonyElixir.Secrets.Scrubber.scrub()

    if text != "" do
      cond do
        config_trust_warning?(text) ->
          Logger.warning(
            "Codex #{stream_label} flagged untrusted workspace " <>
              "(SymphonyElixir.Codex.ProjectTrust auto-trusts on session start; " <>
              "if you see this message check ~/.codex/config.toml is writable): #{text}"
          )

        String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) ->
          Logger.warning("Codex #{stream_label} output: #{text}")

        true ->
          Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp config_trust_warning?(text) when is_binary(text) do
    String.contains?(text, "until the project is trusted") or
      String.contains?(text, "Project-local config, hooks, and exec policies are disabled")
  end

  defp log_pre_response_message(%{
         "method" => "remoteControl/status/changed",
         "params" => %{"status" => "disabled"}
       }) do
    Logger.warning(
      "Codex remoteControl reported status=disabled while awaiting JSON-RPC response. " <>
        "This typically means the workspace is not listed as a trusted project in " <>
        "~/.codex/config.toml. SymphonyElixir.Codex.ProjectTrust auto-adds workspaces " <>
        "on session start; if this message persists the trust write may have failed."
    )
  end

  defp log_pre_response_message(payload) do
    Logger.debug("Ignoring message while waiting for response: #{inspect(payload)}")
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") ||
           Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
