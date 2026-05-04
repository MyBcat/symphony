defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker issue in its workspace via the AgentRuntime
  contract. Resolves the per-issue Profile via `ProfileResolver`, selects the
  matching adapter module via `adapter_for_kind/1`, and drives the session
  lifecycle (`start_session/send_turn/stream_events/stop_session`) through
  the AgentRuntime behaviour callbacks.
  """

  require Logger

  alias SymphonyElixir.{
    Config,
    Monday.PRDetector,
    Monday.Workpad,
    Profile,
    ProfileResolver,
    PromptBuilder,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Tracker.Issue

  @summary_filename "_symphony_summary.md"
  @summary_max_bytes 32_768
  @default_profile_name "codex_default"

  @adapter_for_kind %{
    codex: SymphonyElixir.Codex.Adapter,
    claude: SymphonyElixir.Claude.Adapter,
    gemini: SymphonyElixir.Gemini.Adapter
  }

  @type worker_host :: String.t() | nil

  @doc """
  Map an `AgentRuntime` profile kind atom (`:codex | :claude | :gemini`) to the
  concrete adapter module that implements `SymphonyElixir.AgentRuntime` for that
  runtime.

  Used by `AgentRunner.run/3` to dispatch a resolved Profile to the right
  adapter. The application env key `:agent_runtime_adapter_overrides` can
  supply a `%{kind => module}` map for tests that want to substitute a stub
  adapter without standing up a real Codex/Claude/Gemini subprocess.

  Raises `ArgumentError` for unknown kinds — Profiles validated through
  `SymphonyElixir.Config` are constrained to the supported set, so an unknown
  kind here indicates a programming error, not config drift.
  """
  @spec adapter_for_kind(atom()) :: module()
  def adapter_for_kind(kind) when is_atom(kind) do
    overrides = Application.get_env(:symphony_elixir, :agent_runtime_adapter_overrides, %{})

    cond do
      is_map(overrides) and Map.has_key?(overrides, kind) ->
        Map.fetch!(overrides, kind)

      Map.has_key?(@adapter_for_kind, kind) ->
        Map.fetch!(@adapter_for_kind, kind)

      true ->
        raise ArgumentError,
              "Unknown agent runtime kind: #{inspect(kind)}. Supported: :codex, :claude, :gemini"
    end
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host =
      selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info(
      "Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}"
    )

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info(
      "Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}"
    )

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns_with_tracker(
              workspace,
              issue,
              codex_update_recipient,
              opts,
              worker_host
            )
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Wraps the agent turn loop with tracker write triggers (session start,
  # PR URL detection, completion summary, crash handler). Resolves the
  # per-issue Profile and dispatches to the matching AgentRuntime adapter.
  defp run_codex_turns_with_tracker(workspace, issue, codex_update_recipient, opts, worker_host) do
    session = build_session(issue, workspace, worker_host)
    {:ok, writer_pid} = start_session_writer(session)

    try do
      case resolve_profile_for_issue(issue) do
        {:ok, %Profile{} = profile} ->
          run_agent_turns(
            profile,
            workspace,
            issue,
            codex_update_recipient,
            opts,
            worker_host,
            writer_pid
          )

        {:error, reason} ->
          Logger.error(
            "Profile resolution failed for #{issue_context(issue)}: #{inspect(reason)}"
          )

          {:error, {:profile_resolution_failed, reason}}
      end
    rescue
      error ->
        finalize_crash(writer_pid, issue, error)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        finalize_crash(writer_pid, issue, {kind, reason})
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      {:error, {:profile_resolution_failed, _reason}} = err ->
        err

      {:error, reason} = err ->
        finalize_crash(writer_pid, issue, reason)
        err

      other ->
        other
    after
      stop_session_writer(writer_pid)
    end
  end

  defp resolve_profile_for_issue(%Issue{} = issue) do
    settings = Config.settings!()
    profiles = settings.profiles || %{}
    default_profile = settings.agent.default_profile
    floor = settings.agent.sandbox_safety_floor || %{}

    case ProfileResolver.resolve(issue, profiles, default_profile, floor) do
      {:ok, %Profile{} = profile} ->
        assert_profile_allowed_on_repo(profile, issue, settings)

      {:error, :no_default} ->
        # Spec 1 backward compatibility: when no profiles or default_profile
        # is configured, synthesize a Codex profile from `codex.*` settings
        # so existing single-runtime workflows continue to work without
        # requiring operators to migrate to the multi-profile config shape.
        settings
        |> synthesize_legacy_codex_profile()
        |> assert_profile_allowed_on_repo(issue, settings)

      {:error, _reason} = err ->
        err
    end
  end

  defp assert_profile_allowed_on_repo(%Profile{} = profile, %Issue{} = issue, settings) do
    case ProfileResolver.assert_allowed_on_repo(profile, issue.repo, settings.repos || %{}) do
      :ok -> {:ok, profile}
      {:error, _reason} = err -> err
    end
  end

  defp synthesize_legacy_codex_profile(settings) do
    %Profile{
      name: @default_profile_name,
      kind: :codex,
      max_concurrent: nil,
      config: %{
        "command" => settings.codex.command,
        "thread_sandbox" => settings.codex.thread_sandbox,
        "approval_policy" => settings.codex.approval_policy
      }
    }
  end

  defp codex_message_handler(recipient, issue, writer_pid) do
    fn message ->
      observe_codex_message(writer_pid, issue, message)
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_agent_turns(
         %Profile{} = profile,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         writer_pid
       ) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    adapter = adapter_for_kind(profile.kind)
    session_config = build_session_config(profile, worker_host)

    Logger.info(
      "Dispatching agent run for #{issue_context(issue)} profile=#{profile.name} kind=#{profile.kind}"
    )

    with {:ok, session} <- adapter.start_session(workspace, session_config) do
      try do
        do_run_agent_turns(
          adapter,
          profile,
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns,
          writer_pid
        )
      after
        record_native_tokens(adapter, session, profile, codex_update_recipient, issue)
        adapter.stop_session(session)
      end
    end
  end

  defp do_run_agent_turns(
         adapter,
         profile,
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns,
         writer_pid
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    handler = codex_message_handler(codex_update_recipient, issue, writer_pid)

    case run_single_turn(adapter, profile, app_session, prompt, issue, handler) do
      :ok ->
        Logger.info(
          "Completed agent run for #{issue_context(issue)} workspace=#{workspace} turn=#{turn_number}/#{max_turns}"
        )

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info(
              "Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}"
            )

            do_run_agent_turns(
              adapter,
              profile,
              app_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns,
              writer_pid
            )

          {:continue, refreshed_issue} ->
            Logger.info(
              "Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator"
            )

            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} = err ->
        err
    end
  end

  # Drives a single turn through the AgentRuntime contract. For Codex,
  # `send_turn/3` runs the JSON-RPC App Server turn synchronously and
  # invokes `handler` inline for each event. For Claude/Gemini, `send_turn/3`
  # writes the prompt to the subprocess and returns immediately; events
  # arrive via `stream_events/1` and are translated into the Codex-shaped
  # event vocabulary expected by `observe_codex_message/3`.
  defp run_single_turn(adapter, profile, app_session, prompt, issue, handler) do
    case adapter.send_turn(app_session, prompt, issue: issue, on_message: handler) do
      :ok ->
        consume_events_for_turn(adapter, profile, app_session, issue, handler)

      {:error, _reason} = err ->
        err
    end
  end

  defp consume_events_for_turn(adapter, profile, app_session, issue, handler) do
    adapter.stream_events(app_session)
    |> Enum.reduce_while(:ok, fn event, _acc ->
      case handle_runtime_event(profile, event, handler, issue) do
        :continue -> {:cont, :ok}
        :done -> {:halt, :ok}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  # Codex events are already in `%{event: ...}` shape and were observed
  # inline during `send_turn/3`. The Stream may replay them, but we skip
  # observation so workpad writes are not duplicated and only watch for
  # the terminal turn boundary.
  defp handle_runtime_event(%Profile{kind: :codex}, event, _handler, _issue) do
    case Map.get(event, :event) do
      :turn_completed -> :done
      :turn_failed -> {:error, {:turn_failed, Map.get(event, :details)}}
      :turn_cancelled -> {:error, {:turn_cancelled, Map.get(event, :details)}}
      :turn_input_required -> {:error, {:turn_input_required, Map.get(event, :payload)}}
      :startup_failed -> {:error, {:startup_failed, Map.get(event, :reason)}}
      _ -> :continue
    end
  end

  # Claude/Gemini events use `kind:` vocabulary. Translate to the Codex
  # `event:` shape so the existing `observe_codex_message/3` triggers fire
  # without requiring a second observer implementation.
  defp handle_runtime_event(%Profile{}, event, handler, _issue) do
    translated = translate_runtime_event(event)
    if translated, do: handler.(translated)

    case Map.get(event, :kind) do
      :turn_completed -> :done
      :error -> {:error, {:turn_failed, Map.get(event, :payload)}}
      :exit -> {:error, {:port_exit, Map.get(event, :status)}}
      :stalled -> :continue
      _ -> :continue
    end
  end

  defp translate_runtime_event(%{kind: :session_started} = event) do
    %{
      event: :session_started,
      session_id: Map.get(event, :session_id),
      payload: Map.get(event, :payload),
      timestamp: DateTime.utc_now()
    }
  end

  defp translate_runtime_event(%{kind: :turn_delta} = event) do
    %{
      event: :notification,
      payload: Map.get(event, :payload),
      raw: Jason.encode!(Map.get(event, :payload, %{})),
      usage: token_usage_for_delta(event),
      timestamp: DateTime.utc_now()
    }
  end

  defp translate_runtime_event(%{kind: :turn_completed} = event) do
    %{
      event: :turn_completed,
      payload: Map.get(event, :payload),
      raw: Jason.encode!(Map.get(event, :payload, %{})),
      details: Map.get(event, :payload),
      usage: token_usage_for_delta(event),
      timestamp: DateTime.utc_now()
    }
  end

  defp translate_runtime_event(_event), do: nil

  defp token_usage_for_delta(%{tokens: tokens}) when is_map(tokens), do: tokens
  defp token_usage_for_delta(_), do: nil

  # Build the per-session config map handed to `adapter.start_session/2`.
  # Profile config is taken as-is; the per-runtime safety floor is merged
  # in under `_safety_floor` so adapters can re-check at runtime; and
  # `:worker_host` is threaded through for SSH-backed sessions.
  #
  # The synthesized legacy Codex profile (Spec 1 backward compat) bypasses
  # the new map-config path and hands `Codex.Adapter` the original keyword
  # opts so existing tests and operators that haven't migrated to the
  # multi-profile shape keep working unchanged.
  defp build_session_config(%Profile{name: @default_profile_name, kind: :codex}, worker_host) do
    [worker_host: worker_host]
  end

  defp build_session_config(%Profile{kind: kind, config: cfg}, worker_host) do
    floor = Config.settings!().agent.sandbox_safety_floor || %{}
    kind_floor = Map.get(floor, Atom.to_string(kind), %{})

    cfg
    |> Map.put(:_safety_floor, kind_floor)
    |> maybe_put_worker_host(worker_host)
  end

  defp maybe_put_worker_host(config, nil), do: config

  defp maybe_put_worker_host(config, worker_host) when is_binary(worker_host) do
    Map.put(config, :worker_host, worker_host)
  end

  # Best-effort: read runtime-native tokens off the session and report them
  # to the orchestrator so it can persist them under
  # `agent_native_tokens.<kind>`. Per Spec 2 DL-007 we never normalize
  # across runtimes — the orchestrator stores the per-kind shape verbatim.
  defp record_native_tokens(adapter, session, %Profile{kind: kind}, recipient, %Issue{
         id: issue_id
       })
       when is_pid(recipient) and is_binary(issue_id) do
    try do
      tokens = adapter.runtime_native_tokens(session)

      if is_map(tokens) and map_size(tokens) > 0 do
        send(
          recipient,
          {:agent_native_tokens, issue_id, %{Atom.to_string(kind) => tokens}}
        )
      end

      :ok
    rescue
      _ -> :ok
    end
  end

  defp record_native_tokens(_adapter, _session, _profile, _recipient, _issue), do: :ok

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  ## ---------------------------------------------------------------------------
  ## Tracker write triggers (Spec 1: Symphony owns Monday writes)
  ## ---------------------------------------------------------------------------

  @doc """
  Build a session map suitable for `SymphonyElixir.Monday.Workpad` rendering.
  """
  @spec build_session(map(), Path.t() | nil, worker_host()) :: map()
  def build_session(issue, workspace, worker_host) do
    %{
      identifier: issue_identifier(issue),
      profile_name: profile_name(),
      host: host_for_session(worker_host),
      workspace_path: workspace || "",
      short_sha: short_sha_for_workspace(workspace, worker_host),
      started_at: DateTime.utc_now()
    }
  end

  @doc """
  Start an Agent that tracks per-run state for the tracker writer (whether the
  PR URL was already written, the session map). Returns the agent pid.
  """
  @spec start_session_writer(map()) :: {:ok, pid()}
  def start_session_writer(session) do
    Agent.start_link(fn ->
      %{
        session: session,
        pr_url_written?: false,
        session_started_emitted?: false
      }
    end)
  end

  @doc """
  Stop a previously started session writer. Safe to call on a stopped pid.
  """
  @spec stop_session_writer(pid()) :: :ok
  def stop_session_writer(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        Agent.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  def stop_session_writer(_), do: :ok

  @doc """
  Public entry point for handling an arbitrary codex stream message and
  triggering the appropriate Tracker write. Tests drive this directly to
  validate behavior without needing a real Codex subprocess.
  """
  @spec observe_codex_message(pid(), map(), map()) :: :ok
  def observe_codex_message(writer_pid, issue, %{event: event} = message)
      when is_pid(writer_pid) do
    case event do
      :session_started ->
        on_session_started(writer_pid, issue)

      :turn_completed ->
        on_turn_completed(writer_pid, issue)

      _ ->
        :ok
    end

    maybe_detect_pr_url(writer_pid, issue, message)
    :ok
  end

  def observe_codex_message(_writer_pid, _issue, _message), do: :ok

  @doc """
  Render and write the crash workpad + status when the agent run errored or
  raised. Used both by the inline crash trap and tests.
  """
  @spec finalize_crash(pid(), map(), term()) :: :ok
  def finalize_crash(writer_pid, issue, reason) when is_pid(writer_pid) do
    if Process.alive?(writer_pid) do
      session = Agent.get(writer_pid, fn state -> state.session end)
      issue_id = issue_id(issue)

      if is_binary(issue_id) do
        body = Workpad.render_crash(session, inspect(reason))
        _ = Tracker.upsert_workpad(issue_id, body)
        _ = Tracker.update_issue_state(issue_id, "Cancelled")
      end
    end

    :ok
  end

  def finalize_crash(_writer_pid, _issue, _reason), do: :ok

  defp on_session_started(writer_pid, issue) do
    issue_id = issue_id(issue)

    {already_emitted?, session} =
      Agent.get_and_update(writer_pid, fn state ->
        {{state.session_started_emitted?, state.session},
         %{state | session_started_emitted?: true}}
      end)

    if !already_emitted? and is_binary(issue_id) do
      _ = Tracker.update_issue_state(issue_id, "In Progress")
      _ = Tracker.upsert_workpad(issue_id, Workpad.render_session_start(session))
    end

    :ok
  end

  defp on_turn_completed(writer_pid, issue) do
    issue_id = issue_id(issue)

    if is_binary(issue_id) do
      {session, pr_url_written?} =
        Agent.get(writer_pid, fn state -> {state.session, state.pr_url_written?} end)

      case read_summary(Map.get(session, :workspace_path)) do
        {:ok, summary_body} ->
          body = Workpad.render_completion(session, summary_body)
          _ = Tracker.upsert_workpad(issue_id, body)

          if pr_url_written? do
            _ = Tracker.update_issue_state(issue_id, "Human Review")
          end

          :ok

        :no_summary ->
          # Spec: if no summary present, leave workpad/status as-is so the
          # orchestrator's continuation logic can re-evaluate on next poll.
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to read #{@summary_filename} for issue_id=#{issue_id}: #{inspect(reason)}"
          )

          :ok
      end
    end

    :ok
  end

  defp maybe_detect_pr_url(writer_pid, issue, message) do
    issue_id = issue_id(issue)

    if is_binary(issue_id) do
      already_written? = Agent.get(writer_pid, fn state -> state.pr_url_written? end)

      if !already_written? do
        case scan_message_for_pr(message) do
          {:ok, url} ->
            updated? =
              Agent.get_and_update(writer_pid, fn state ->
                if state.pr_url_written? do
                  {false, state}
                else
                  {true, %{state | pr_url_written?: true}}
                end
              end)

            if updated? do
              _ = Tracker.set_pr_url(issue_id, url)
            end

            :ok

          :no_match ->
            :ok
        end
      end
    end

    :ok
  end

  defp scan_message_for_pr(message) when is_map(message) do
    [Map.get(message, :raw), Map.get(message, :payload)]
    |> Enum.reduce_while(:no_match, fn candidate, acc ->
      case scan_value_for_pr(candidate) do
        {:ok, _url} = hit -> {:halt, hit}
        :no_match -> {:cont, acc}
      end
    end)
  end

  defp scan_message_for_pr(_), do: :no_match

  defp scan_value_for_pr(value) when is_binary(value), do: PRDetector.scan(value)

  defp scan_value_for_pr(value) when is_map(value) or is_list(value) do
    PRDetector.scan(safe_inspect(value))
  end

  defp scan_value_for_pr(_), do: :no_match

  defp safe_inspect(value) do
    try do
      Jason.encode!(value)
    rescue
      _ -> inspect(value)
    end
  end

  defp read_summary(workspace_path) when is_binary(workspace_path) and workspace_path != "" do
    path = Path.join(workspace_path, @summary_filename)

    case File.read(path) do
      {:ok, body} when byte_size(body) > @summary_max_bytes ->
        {:ok, binary_part(body, 0, @summary_max_bytes) <> "\n\n... (truncated)\n"}

      {:ok, body} ->
        {:ok, body}

      {:error, :enoent} ->
        :no_summary

      {:error, _reason} = err ->
        err
    end
  end

  defp read_summary(_workspace_path), do: :no_summary

  defp issue_id(%Issue{id: issue_id}), do: issue_id
  defp issue_id(%{id: issue_id}), do: issue_id
  defp issue_id(_), do: nil

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_), do: "unknown"

  defp profile_name do
    Application.get_env(:symphony_elixir, :agent_profile_name, @default_profile_name)
  end

  defp host_for_session(nil) do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      _ -> "local"
    end
  end

  defp host_for_session(host) when is_binary(host), do: host

  defp short_sha_for_workspace(workspace, nil) when is_binary(workspace) and workspace != "" do
    case File.dir?(workspace) do
      true ->
        try do
          {output, status} =
            System.cmd("git", ["rev-parse", "--short", "HEAD"],
              cd: workspace,
              stderr_to_stdout: true
            )

          if status == 0 do
            output |> String.trim() |> trim_to_short_sha()
          else
            "no-sha"
          end
        rescue
          _ -> "no-sha"
        end

      false ->
        "no-sha"
    end
  end

  defp short_sha_for_workspace(_workspace, _worker_host), do: "no-sha"

  defp trim_to_short_sha(""), do: "no-sha"
  defp trim_to_short_sha(sha) when is_binary(sha), do: sha
end
