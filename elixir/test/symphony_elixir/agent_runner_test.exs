defmodule SymphonyElixir.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.MemoryMonday

  describe "Tracker writes triggered by event stream" do
    setup do
      Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)

      case Process.whereis(MemoryMonday) do
        nil -> {:ok, _} = MemoryMonday.start_link([])
        _pid -> MemoryMonday.reset()
      end

      MemoryMonday.reset()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :tracker_adapter_override)

        if pid = Process.whereis(MemoryMonday) do
          Process.exit(pid, :normal)
        end
      end)

      issue = %Issue{
        id: "issue-runner-1",
        identifier: "SYM-1",
        title: "Tracker write trigger test",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-1",
        assigned_to_worker: true
      }

      workspace = Path.join(System.tmp_dir!(), "agent-runner-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace)

      on_exit(fn -> File.rm_rf(workspace) end)

      session = AgentRunner.build_session(issue, workspace, nil)
      {:ok, writer_pid} = AgentRunner.start_session_writer(session)

      on_exit(fn -> AgentRunner.stop_session_writer(writer_pid) end)

      %{issue: issue, workspace: workspace, writer_pid: writer_pid, session: session}
    end

    test "on session start, writes status `In Progress` and creates workpad",
         %{issue: issue, writer_pid: writer_pid} do
      message = %{
        event: :session_started,
        session_id: "thread-1-turn-1",
        thread_id: "thread-1",
        turn_id: "turn-1",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:status_write, "issue-runner-1", "In Progress"} -> true
               _ -> false
             end),
             "expected status write In Progress; got events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:workpad_write, "issue-runner-1", body} ->
                 String.contains?(body, "Symphony Workpad") and
                   String.contains?(body, "Started by Symphony")

               _ ->
                 false
             end),
             "expected workpad write with session-start render; got events=#{inspect(events)}"
    end

    test "on session start, only writes once even if event fires again",
         %{issue: issue, writer_pid: writer_pid} do
      message = %{
        event: :session_started,
        session_id: "thread-1-turn-1",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)
      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      status_writes =
        Enum.count(events, fn
          {:status_write, "issue-runner-1", "In Progress"} -> true
          _ -> false
        end)

      assert status_writes == 1,
             "expected exactly one In Progress status write; got #{status_writes} in events=#{inspect(events)}"
    end

    test "on PR URL appearing in stream, calls Tracker.set_pr_url",
         %{issue: issue, writer_pid: writer_pid} do
      message = %{
        event: :notification,
        payload: %{"text" => "Created https://github.com/openai/symphony/pull/42 for review"},
        raw: ~s({"method":"item/agent_message","params":{"text":"Opened PR https://github.com/openai/symphony/pull/42"}}),
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:pr_write, "issue-runner-1", "https://github.com/openai/symphony/pull/42"} -> true
               _ -> false
             end),
             "expected pr_write with PR URL; got events=#{inspect(events)}"
    end

    test "duplicate PR URL in stream does not trigger duplicate writes",
         %{issue: issue, writer_pid: writer_pid} do
      message = %{
        event: :notification,
        raw: "Opened https://github.com/openai/symphony/pull/42",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)
      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)
      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      pr_writes =
        Enum.count(events, fn
          {:pr_write, "issue-runner-1", _url} -> true
          _ -> false
        end)

      assert pr_writes == 1,
             "expected exactly one pr_write; got #{pr_writes} in events=#{inspect(events)}"
    end

    test "on completion event with _symphony_summary.md present, writes workpad with completion render and status :Human Review",
         %{issue: issue, workspace: workspace, writer_pid: writer_pid} do
      summary_path = Path.join(workspace, "_symphony_summary.md")
      summary_body = "## Summary\n\nFixed the bug.\n\n### Test plan\n- ran make all\n"
      File.write!(summary_path, summary_body)

      # First emit a PR URL so that completion bumps status to "Human Review".
      pr_message = %{
        event: :notification,
        raw: "Opened https://github.com/openai/symphony/pull/99",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, pr_message)

      completion_message = %{
        event: :turn_completed,
        payload: %{"method" => "turn/completed"},
        raw: ~s({"method":"turn/completed"}),
        details: %{},
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, completion_message)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:workpad_write, "issue-runner-1", body} ->
                 String.contains?(body, "Symphony Workpad") and
                   String.contains?(body, "Fixed the bug.") and
                   String.contains?(body, "ran make all")

               _ ->
                 false
             end),
             "expected workpad write with completion render embedding summary; got events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "issue-runner-1", "Human Review"} -> true
               _ -> false
             end),
             "expected status write Human Review; got events=#{inspect(events)}"
    end

    test "on completion without summary file, leaves status unchanged",
         %{issue: issue, writer_pid: writer_pid} do
      completion_message = %{
        event: :turn_completed,
        payload: %{"method" => "turn/completed"},
        raw: ~s({"method":"turn/completed"}),
        details: %{},
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, completion_message)

      events = MemoryMonday.events()

      refute Enum.any?(events, fn
               {:status_write, "issue-runner-1", "Human Review"} -> true
               _ -> false
             end),
             "expected NO status write to Human Review when summary missing; got events=#{inspect(events)}"
    end

    test "on completion with summary but no PR URL, writes workpad but leaves status unchanged",
         %{issue: issue, workspace: workspace, writer_pid: writer_pid} do
      summary_path = Path.join(workspace, "_symphony_summary.md")
      File.write!(summary_path, "## Summary\n\nWork in progress\n")

      completion_message = %{
        event: :turn_completed,
        payload: %{"method" => "turn/completed"},
        raw: ~s({"method":"turn/completed"}),
        details: %{},
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, completion_message)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:workpad_write, "issue-runner-1", body} ->
                 String.contains?(body, "Symphony Workpad")

               _ ->
                 false
             end),
             "expected workpad write on completion; got events=#{inspect(events)}"

      refute Enum.any?(events, fn
               {:status_write, "issue-runner-1", "Human Review"} -> true
               _ -> false
             end),
             "expected NO Human Review status write without PR URL"
    end

    test "completion summary larger than 32KB is truncated",
         %{issue: issue, workspace: workspace, writer_pid: writer_pid} do
      summary_path = Path.join(workspace, "_symphony_summary.md")
      huge = "## Summary\n" <> String.duplicate("a", 40_000)
      File.write!(summary_path, huge)

      completion_message = %{
        event: :turn_completed,
        payload: %{"method" => "turn/completed"},
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, completion_message)

      events = MemoryMonday.events()

      workpad_body =
        Enum.find_value(events, fn
          {:workpad_write, "issue-runner-1", body} -> body
          _ -> nil
        end)

      assert workpad_body != nil
      assert String.contains?(workpad_body, "(truncated)")
    end

    test "on abnormal exit, writes workpad crash render and update_issue_state :Cancelled",
         %{issue: issue, writer_pid: writer_pid} do
      reason = {:port_exit, 137}

      :ok = AgentRunner.finalize_crash(writer_pid, issue, reason)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:workpad_write, "issue-runner-1", body} ->
                 String.contains?(body, "Symphony Workpad") and
                   String.contains?(body, "Crashed") and
                   String.contains?(body, "port_exit")

               _ ->
                 false
             end),
             "expected workpad write with crash render; got events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "issue-runner-1", "Cancelled"} -> true
               _ -> false
             end),
             "expected status write Cancelled on crash; got events=#{inspect(events)}"
    end

    test "build_session populates workpad-required fields",
         %{issue: issue, workspace: workspace} do
      session = AgentRunner.build_session(issue, workspace, "remote-host-1")

      assert session.identifier == "SYM-1"
      assert is_binary(session.profile_name)
      assert session.host == "remote-host-1"
      assert session.workspace_path == workspace
      assert is_binary(session.short_sha)
      assert %DateTime{} = session.started_at
    end
  end

  describe "profile-based dispatch" do
    alias SymphonyElixir.{Profile, ProfileResolver, Tracker}

    setup do
      Application.put_env(:symphony_elixir, :tracker_adapter_override, SymphonyElixir.Tracker.MemoryMonday)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :tracker_adapter_override)
      end)

      :ok
    end

    test "resolves profile and selects matching adapter module" do
      issue = %Tracker.Issue{
        id: "1",
        identifier: "SYM-1",
        title: "test",
        state: "Symphony Ready",
        profile: "claude_test"
      }

      profiles = %{
        "claude_test" => %Profile{
          name: "claude_test",
          kind: :claude,
          max_concurrent: nil,
          config: %{"permission_mode" => "acceptEdits", "allowed_tools" => []}
        }
      }

      floor = %{"claude" => %{"permission_mode" => "acceptEdits"}}

      assert {:ok, profile} = ProfileResolver.resolve(issue, profiles, nil, floor)
      assert profile.kind == :claude
      assert SymphonyElixir.AgentRunner.adapter_for_kind(profile.kind) == SymphonyElixir.Claude.Adapter
    end

    test "adapter_for_kind returns the right module for each kind" do
      assert SymphonyElixir.AgentRunner.adapter_for_kind(:codex) == SymphonyElixir.Codex.Adapter
      assert SymphonyElixir.AgentRunner.adapter_for_kind(:claude) == SymphonyElixir.Claude.Adapter
      assert SymphonyElixir.AgentRunner.adapter_for_kind(:gemini) == SymphonyElixir.Gemini.Adapter
    end

    test "adapter_for_kind raises on unknown kind" do
      assert_raise ArgumentError, fn ->
        SymphonyElixir.AgentRunner.adapter_for_kind(:unknown)
      end
    end

    test "adapter_for_kind respects :agent_runtime_adapter_overrides app env" do
      stub = SymphonyElixir.AgentRunnerTest.StubAdapter
      Application.put_env(:symphony_elixir, :agent_runtime_adapter_overrides, %{claude: stub})

      try do
        assert SymphonyElixir.AgentRunner.adapter_for_kind(:claude) == stub
        # other kinds still resolve from the default map
        assert SymphonyElixir.AgentRunner.adapter_for_kind(:codex) == SymphonyElixir.Codex.Adapter
      after
        Application.delete_env(:symphony_elixir, :agent_runtime_adapter_overrides)
      end
    end
  end

  describe "polymorphic dispatch via AgentRuntime callbacks" do
    use SymphonyElixir.TestSupport

    alias SymphonyElixir.{AgentRunner, Tracker.Issue, Tracker.MemoryMonday, Workflow}

    defmodule RecordingAdapter do
      @moduledoc false
      @behaviour SymphonyElixir.AgentRuntime

      @impl true
      def start_session(workspace, config) do
        send_to_test({:start_session, self(), workspace, config})

        kind = Map.get(config, "_test_kind") || Map.get(config, :_test_kind)
        {:ok, %{workspace: workspace, config: config, kind: kind}}
      end

      @impl true
      def send_turn(session, prompt, opts) do
        send_to_test({:send_turn, session, prompt, opts})

        # Synthesize a session_started + turn_completed pair so the
        # AgentRunner's stream loop sees a clean turn boundary. Use the
        # `kind:` shape so the AgentRunner's translator path runs (matches
        # Claude/Gemini wire format).
        send(self(), {:recording_event, %{kind: :session_started, session_id: "stub-123"}})
        send(self(), {:recording_event, %{kind: :turn_completed, payload: %{}, tokens: %{input: 10, output: 5, total: 15}}})
        :ok
      end

      @impl true
      def stream_events(_session) do
        Stream.unfold(:running, fn
          :done ->
            nil

          :running ->
            receive do
              {:recording_event, %{kind: :turn_completed} = ev} -> {ev, :done}
              {:recording_event, ev} -> {ev, :running}
            after
              500 -> {%{kind: :stalled}, :done}
            end
        end)
      end

      @impl true
      def stop_session(session) do
        send_to_test({:stop_session, session})
        :ok
      end

      @impl true
      def runtime_native_tokens(_session), do: %{input: 10, output: 5, total: 15}

      @impl true
      def passes_safety_floor?(_config, _floor), do: true

      defp send_to_test(message) do
        case Application.get_env(:symphony_elixir, :recording_adapter_test_pid) do
          pid when is_pid(pid) -> send(pid, message)
          _ -> :ok
        end
      end
    end

    setup do
      Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)
      Application.put_env(:symphony_elixir, :recording_adapter_test_pid, self())

      case Process.whereis(MemoryMonday) do
        nil -> {:ok, _} = MemoryMonday.start_link([])
        _pid -> MemoryMonday.reset()
      end

      MemoryMonday.reset()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :tracker_adapter_override)
        Application.delete_env(:symphony_elixir, :recording_adapter_test_pid)
        Application.delete_env(:symphony_elixir, :agent_runtime_adapter_overrides)

        if pid = Process.whereis(MemoryMonday) do
          Process.exit(pid, :normal)
        end
      end)

      :ok
    end

    test "dispatching with profile=claude_test calls Claude.Adapter.start_session" do
      install_recording_adapter(:claude)
      configure_profiles_workflow(:claude, "claude_test")

      issue = %Issue{
        id: "issue-claude-1",
        identifier: "SYM-CL",
        title: "Claude routing",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-CL",
        profile: "claude_test",
        assigned_to_worker: true
      }

      AgentRunner.run(issue, self(), max_turns: 1)

      assert_received {:start_session, _pid, _workspace, config}
      assert Map.get(config, "_test_kind") == "claude"
      assert_received {:send_turn, _session, _prompt, _opts}
      assert_received {:stop_session, _session}
    end

    test "dispatching with profile=gemini_test calls Gemini.Adapter.start_session" do
      install_recording_adapter(:gemini)
      configure_profiles_workflow(:gemini, "gemini_test")

      issue = %Issue{
        id: "issue-gemini-1",
        identifier: "SYM-GM",
        title: "Gemini routing",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-GM",
        profile: "gemini_test",
        assigned_to_worker: true
      }

      AgentRunner.run(issue, self(), max_turns: 1)

      assert_received {:start_session, _pid, _workspace, config}
      assert Map.get(config, "_test_kind") == "gemini"
      assert_received {:send_turn, _session, _prompt, _opts}
      assert_received {:stop_session, _session}
    end

    test "items without a profile column value fall back to agent.default_profile" do
      install_recording_adapter(:claude)
      configure_profiles_workflow(:claude, "claude_test")

      # No `profile` set on the issue — resolver must use the default.
      issue = %Issue{
        id: "issue-default-1",
        identifier: "SYM-DEF",
        title: "Default profile fallback",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-DEF",
        profile: nil,
        assigned_to_worker: true
      }

      AgentRunner.run(issue, self(), max_turns: 1)

      assert_received {:start_session, _pid, _workspace, config}
      assert Map.get(config, "_test_kind") == "claude"
    end

    test "runtime-native tokens are reported under agent_native_tokens.<kind>" do
      install_recording_adapter(:claude)
      configure_profiles_workflow(:claude, "claude_test")

      issue = %Issue{
        id: "issue-tokens-1",
        identifier: "SYM-TOK",
        title: "Token reporting",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-TOK",
        profile: "claude_test",
        assigned_to_worker: true
      }

      AgentRunner.run(issue, self(), max_turns: 1)

      assert_received {:agent_native_tokens, "issue-tokens-1",
                       %{"claude" => %{input: 10, output: 5, total: 15}}}
    end

    defp install_recording_adapter(kind) do
      Application.put_env(:symphony_elixir, :agent_runtime_adapter_overrides, %{kind => RecordingAdapter})
    end

    defp configure_profiles_workflow(kind, profile_name) do
      workspace_root = Path.join(System.tmp_dir!(), "agent-dispatch-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(workspace_root) end)

      profile_kind_str = Atom.to_string(kind)

      profile_config = profile_config_for(kind)

      # Use string-keyed map so the YAML emitter doesn't trip on atom keys.
      # The profile_kind_str key holds the per-kind nested config; this is
      # where the adapter receives `_test_kind` for routing assertions.
      nested_config = Map.put(profile_config, :_test_kind, profile_kind_str)

      profile_entry = %{}
      profile_entry = Map.put(profile_entry, :kind, profile_kind_str)
      profile_entry = Map.put(profile_entry, profile_kind_str, nested_config)

      profiles = %{profile_name => profile_entry}

      sandbox_safety_floor = sandbox_safety_floor_for(kind)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_default_profile: profile_name,
        agent_sandbox_safety_floor: sandbox_safety_floor,
        profiles: profiles
      )

      :ok
    end

    defp profile_config_for(:claude), do: %{permission_mode: "acceptEdits", allowed_tools: ["Read"]}

    defp profile_config_for(:gemini),
      do: %{command: "gemini --output-format stream-json --sandbox"}

    defp profile_config_for(:codex), do: %{thread_sandbox: "workspace-write", approval_policy: "never"}

    defp sandbox_safety_floor_for(:claude),
      do: %{claude: %{permission_mode: "acceptEdits"}}

    defp sandbox_safety_floor_for(:gemini),
      do: %{gemini: %{require_sandbox: true, forbid_yolo: true}}

    defp sandbox_safety_floor_for(:codex),
      do: %{codex: %{thread_sandbox: "workspace-write"}}
  end

  defmodule StubAdapter do
    @moduledoc false
    @behaviour SymphonyElixir.AgentRuntime

    @impl true
    def start_session(_workspace, _config), do: {:ok, %{}}

    @impl true
    def send_turn(_session, _prompt, _opts), do: :ok

    @impl true
    def stream_events(_session), do: Stream.cycle([]) |> Stream.take(0)

    @impl true
    def stop_session(_session), do: :ok

    @impl true
    def runtime_native_tokens(_session), do: %{input: 0, output: 0, total: 0}

    @impl true
    def passes_safety_floor?(_config, _floor), do: true
  end
end
