defmodule SymphonyElixir.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.MemoryMonday

  defmodule PRSafetyStubGH do
    @moduledoc false
    @behaviour SymphonyElixir.PRSafety.GH

    @impl true
    def pr_view_basic(url) do
      case Process.get({__MODULE__, :basic, url}) do
        nil -> {:error, :stub_not_configured}
        response -> response
      end
    end

    @impl true
    def pr_head_contains_sha(url, sha) do
      case Process.get({__MODULE__, :head_contains, url, sha}) do
        nil -> {:error, :stub_not_configured}
        response -> response
      end
    end

    def stub_basic(url, response), do: Process.put({__MODULE__, :basic, url}, response)

    def stub_head_contains(url, sha, response),
      do: Process.put({__MODULE__, :head_contains, url, sha}, response)
  end

  defmodule FailingPrUrlTracker do
    @moduledoc """
    Stub Tracker for the CodeRabbit-flagged guard test: returns
    `{:error, :monday_outage}` on `set_pr_url/2` so we can verify that
    AutoMerge is NOT spawned when the Monday write fails.
    """
    @behaviour SymphonyElixir.Tracker

    @impl true
    def fetch_candidate_issues, do: {:ok, []}
    @impl true
    def fetch_candidate_issues_with_phi_findings,
      do: {:ok, %{items: [], phi_offenders: []}}

    @impl true
    def fetch_issues_by_states(_), do: {:ok, []}
    @impl true
    def fetch_issue_states_by_ids(_), do: {:ok, []}
    @impl true
    def update_issue_state(_, _), do: :ok
    @impl true
    def upsert_workpad(_, _), do: :ok
    @impl true
    def set_pr_url(_, _), do: {:error, :monday_outage}
    @impl true
    def post_failure_update(_, _), do: :ok
    @impl true
    def post_pr_refusal(_, _), do: :ok
    @impl true
    def post_phi_refusal(_, _), do: :ok
    @impl true
    def post_codex_review(_, _), do: :ok
    @impl true
    def post_auto_merge_failure(_, _), do: :ok
    @impl true
    def acquire_heartbeat, do: :ok
    @impl true
    def release_heartbeat, do: :ok
    @impl true
    def validate_no_phi(_), do: :ok
  end

  describe "Tracker writes triggered by event stream" do
    setup do
      Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)
      Application.put_env(:symphony_elixir, :pr_safety_gh_module, PRSafetyStubGH)

      # Spec 4 §2.8a: prevent the real AutoMerge pipeline from spawning during
      # existing PR-detection tests. Tests that want to assert AutoMerge was
      # invoked install their own capture fn via `:auto_merge_runner`.
      test_pid = self()

      auto_merge_runner = fn ctx ->
        send(test_pid, {:auto_merge_invoked, ctx})
        :ok
      end

      Application.put_env(:symphony_elixir, :auto_merge_runner, auto_merge_runner)

      pr_state_path =
        Path.join(
          System.tmp_dir!(),
          "agent-runner-pr-state-#{System.unique_integer([:positive])}.json"
        )

      Application.put_env(:symphony_elixir, :pr_safety_state_path, pr_state_path)

      case Process.whereis(MemoryMonday) do
        nil -> {:ok, _} = MemoryMonday.start_link([])
        _pid -> MemoryMonday.reset()
      end

      MemoryMonday.reset()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :tracker_adapter_override)
        Application.delete_env(:symphony_elixir, :pr_safety_gh_module)
        Application.delete_env(:symphony_elixir, :pr_safety_state_path)
        Application.delete_env(:symphony_elixir, :auto_merge_runner)
        File.rm(pr_state_path)

        if pid = Process.whereis(MemoryMonday) do
          Process.exit(pid, :normal)
        end
      end)

      issue = %Issue{
        id: "11923258050",
        identifier: "SYM-1",
        title: "Tracker write trigger test",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-1",
        assigned_to_worker: true
      }

      workspace =
        Path.join(System.tmp_dir!(), "agent-runner-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      on_exit(fn -> File.rm_rf(workspace) end)

      session = AgentRunner.build_session(issue, workspace, nil)
      {:ok, writer_pid} = AgentRunner.start_session_writer(session)

      on_exit(fn -> AgentRunner.stop_session_writer(writer_pid) end)

      %{
        issue: issue,
        workspace: workspace,
        writer_pid: writer_pid,
        session: session,
        pr_state_path: pr_state_path
      }
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
               {:status_write, "11923258050", "In Progress"} -> true
               _ -> false
             end),
             "expected status write In Progress; got events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:workpad_write, "11923258050", body} ->
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
          {:status_write, "11923258050", "In Progress"} -> true
          _ -> false
        end)

      assert status_writes == 1,
             "expected exactly one In Progress status write; got #{status_writes} in events=#{inspect(events)}"
    end

    test "on PR URL appearing in stream with valid branch, writes PR URL and transitions to Human Review",
         %{issue: issue, writer_pid: writer_pid} do
      url = "https://github.com/openai/symphony/pull/42"

      PRSafetyStubGH.stub_basic(
        url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "symphony/SYM-11923258050/attempt-1",
           url: url,
           head_sha: "abc1234"
         }}
      )

      message = %{
        event: :notification,
        payload: %{"text" => "Created #{url} for review"},
        raw: ~s({"method":"item/agent_message","params":{"text":"Opened PR #{url}"}}),
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:pr_write, "11923258050", ^url} -> true
               _ -> false
             end),
             "expected pr_write with PR URL; got events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "11923258050", "Human Review"} -> true
               _ -> false
             end),
             "expected status_write Human Review on PR detection; got events=#{inspect(events)}"
    end

    test "on PR URL with valid branch, AutoMerge.evaluate_human_review is invoked once with the right ctx (Spec 4 §2.8a)",
         %{issue: issue, writer_pid: writer_pid} do
      url = "https://github.com/openai/symphony/pull/142"

      PRSafetyStubGH.stub_basic(
        url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "symphony/SYM-11923258050/attempt-1",
           url: url,
           head_sha: "abc1234"
         }}
      )

      message = %{
        event: :notification,
        raw: "Opened #{url}",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      assert_receive {:auto_merge_invoked, ctx}, 500
      assert ctx.item_id == "11923258050"
      assert ctx.pr_url == url
      assert is_map(ctx.session)
      # Repo column unset for this test issue → repo_key is nil. AutoMerge
      # gate 1 (repo opt-in) handles a missing repo_key by holding.
      assert ctx[:repo_key] in [nil, ""]

      # Idempotency: second observation should not re-invoke AutoMerge.
      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)
      refute_receive {:auto_merge_invoked, _}, 100
    end

    test "AutoMerge does NOT spawn when Tracker.set_pr_url fails (CodeRabbit guard)",
         %{issue: issue, writer_pid: writer_pid} do
      # Override the Tracker adapter to return :error on set_pr_url. The
      # spawn_auto_merge call would otherwise fire-and-forget — but
      # auto-merging an item Monday hasn't recorded as Human Review is
      # exactly the noise the guard prevents.
      Application.put_env(:symphony_elixir, :tracker_adapter_override, FailingPrUrlTracker)

      try do
        url = "https://github.com/openai/symphony/pull/999"

        PRSafetyStubGH.stub_basic(
          url,
          {:ok,
           %{
             base_branch: "main",
             head_branch: "symphony/SYM-11923258050/attempt-1",
             url: url,
             head_sha: "abc1234"
           }}
        )

        message = %{
          event: :notification,
          raw: "Opened #{url}",
          timestamp: DateTime.utc_now()
        }

        :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

        # Tracker write returned an error → AutoMerge MUST NOT have been spawned.
        refute_receive {:auto_merge_invoked, _}, 100
      after
        Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)
      end
    end

    test "PR refusal path does NOT invoke AutoMerge.evaluate_human_review (Spec 4 §2.8a)",
         %{issue: issue, writer_pid: writer_pid} do
      url = "https://github.com/openai/symphony/pull/156"

      PRSafetyStubGH.stub_basic(
        url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "feature/wrong-branch",
           url: url,
           head_sha: "deadbeef"
         }}
      )

      message = %{
        event: :notification,
        raw: "Opened #{url}",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      refute_receive {:auto_merge_invoked, _}, 100
    end

    test "duplicate PR URL in stream does not trigger duplicate writes",
         %{issue: issue, writer_pid: writer_pid} do
      url = "https://github.com/openai/symphony/pull/42"

      PRSafetyStubGH.stub_basic(
        url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "symphony/SYM-11923258050/attempt-1",
           url: url,
           head_sha: "abc1234"
         }}
      )

      message = %{
        event: :notification,
        raw: "Opened #{url}",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)
      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)
      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      pr_writes =
        Enum.count(events, fn
          {:pr_write, "11923258050", _url} -> true
          _ -> false
        end)

      assert pr_writes == 1,
             "expected exactly one pr_write; got #{pr_writes} in events=#{inspect(events)}"

      status_writes =
        Enum.count(events, fn
          {:status_write, "11923258050", "Human Review"} -> true
          _ -> false
        end)

      assert status_writes == 1,
             "expected exactly one Human Review status write; got #{status_writes} in events=#{inspect(events)}"
    end

    test "PR URL split across stream messages is detected",
         %{issue: issue, writer_pid: writer_pid} do
      url = "https://github.com/openai/symphony/pull/4242"

      PRSafetyStubGH.stub_basic(
        url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "symphony/SYM-11923258050/attempt-1",
           url: url,
           head_sha: "abc1234"
         }}
      )

      first_chunk = %{
        event: :notification,
        raw: "Opened https://github.com/openai/symph",
        timestamp: DateTime.utc_now()
      }

      second_chunk = %{
        event: :notification,
        raw: "ony/pull/4242",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, first_chunk)
      :ok = AgentRunner.observe_codex_message(writer_pid, issue, second_chunk)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:pr_write, "11923258050", ^url} -> true
               _ -> false
             end),
             "expected pr_write for split PR URL; got events=#{inspect(events)}"
    end

    test "on PR URL with invalid branch, refuses with branch_convention_violation and transitions to Cancelled",
         %{issue: issue, writer_pid: writer_pid} do
      url = "https://github.com/openai/symphony/pull/55"

      PRSafetyStubGH.stub_basic(
        url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "feature/random-branch",
           url: url,
           head_sha: "deadbeef"
         }}
      )

      message = %{
        event: :notification,
        raw: "Opened #{url}",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      refute Enum.any?(events, fn
               {:pr_write, "11923258050", _url} -> true
               _ -> false
             end),
             "should NOT write PR URL on branch convention violation; got #{inspect(events)}"

      assert Enum.any?(events, fn
               {:pr_refusal_write, "11923258050", body} ->
                 String.contains?(body, "## Symphony PR Refusal") and
                   String.contains?(body, "branch_convention_violation") and
                   String.contains?(body, "feature/random-branch") and
                   String.contains?(body, "symphony/SYM-11923258050/attempt-N")

               _ ->
                 false
             end),
             "expected pr_refusal_write with branch_convention_violation reason; got #{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "11923258050", "Cancelled"} -> true
               _ -> false
             end),
             "expected status_write Cancelled on branch refusal; got events=#{inspect(events)}"
    end

    test "on PR URL with rebased history (force-push), refuses with force_push_detected",
         %{issue: issue, writer_pid: writer_pid} do
      url = "https://github.com/openai/symphony/pull/77"

      # Pre-populate state with a SHA that will no longer be in head history.
      :ok =
        SymphonyElixir.PRSafety.PRState.record("11923258050", %{
          url: url,
          sha: "originalsha"
        })

      PRSafetyStubGH.stub_head_contains(url, "originalsha", {:ok, false})

      message = %{
        event: :notification,
        raw: "Opened #{url}",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:pr_refusal_write, "11923258050", body} ->
                 String.contains?(body, "## Symphony PR Refusal") and
                   String.contains?(body, "force_push_detected")

               _ ->
                 false
             end),
             "expected pr_refusal_write with force_push_detected reason; got #{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "11923258050", "Cancelled"} -> true
               _ -> false
             end),
             "expected status_write Cancelled on force-push refusal; got events=#{inspect(events)}"
    end

    test "on PR URL re-detection where prior SHA is still in history (descendant), does NOT refuse",
         %{issue: issue, writer_pid: writer_pid} do
      url = "https://github.com/openai/symphony/pull/88"

      # Pre-populate state to simulate a prior agent run that already
      # recorded the PR.
      :ok =
        SymphonyElixir.PRSafety.PRState.record("11923258050", %{
          url: url,
          sha: "originalsha"
        })

      PRSafetyStubGH.stub_head_contains(url, "originalsha", {:ok, true})

      message = %{
        event: :notification,
        raw: "Opened #{url}",
        timestamp: DateTime.utc_now()
      }

      :ok = AgentRunner.observe_codex_message(writer_pid, issue, message)

      events = MemoryMonday.events()

      refute Enum.any?(events, fn
               {:pr_refusal_write, _, _} -> true
               _ -> false
             end),
             "should NOT refuse when prior SHA is still in commit chain; got #{inspect(events)}"

      refute Enum.any?(events, fn
               {:status_write, "11923258050", "Cancelled"} -> true
               _ -> false
             end),
             "should NOT cancel on descendant SHA append; got #{inspect(events)}"
    end

    test "on completion event with _symphony_summary.md present, writes workpad with completion render and status :Human Review",
         %{issue: issue, workspace: workspace, writer_pid: writer_pid} do
      summary_path = Path.join(workspace, "_symphony_summary.md")
      summary_body = "## Summary\n\nFixed the bug.\n\n### Test plan\n- ran make all\n"
      File.write!(summary_path, summary_body)

      # First emit a PR URL so that completion bumps status to "Human Review".
      url = "https://github.com/openai/symphony/pull/99"

      PRSafetyStubGH.stub_basic(
        url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "symphony/SYM-11923258050/attempt-1",
           url: url,
           head_sha: "abc1234"
         }}
      )

      pr_message = %{
        event: :notification,
        raw: "Opened #{url}",
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
               {:workpad_write, "11923258050", body} ->
                 String.contains?(body, "Symphony Workpad") and
                   String.contains?(body, "Fixed the bug.") and
                   String.contains?(body, "ran make all")

               _ ->
                 false
             end),
             "expected workpad write with completion render embedding summary; got events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "11923258050", "Human Review"} -> true
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
               {:status_write, "11923258050", "Human Review"} -> true
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
               {:workpad_write, "11923258050", body} ->
                 String.contains?(body, "Symphony Workpad")

               _ ->
                 false
             end),
             "expected workpad write on completion; got events=#{inspect(events)}"

      refute Enum.any?(events, fn
               {:status_write, "11923258050", "Human Review"} -> true
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
          {:workpad_write, "11923258050", body} -> body
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
               {:workpad_write, "11923258050", body} ->
                 String.contains?(body, "Symphony Workpad") and
                   String.contains?(body, "Crashed") and
                   String.contains?(body, "port_exit")

               _ ->
                 false
             end),
             "expected workpad write with crash render; got events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "11923258050", "Cancelled"} -> true
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

    test "build_session carries the issue's repo into the session map" do
      issue = %Issue{
        id: "issue-build-repo-1",
        identifier: "SYM-REPO",
        title: "Repo session field",
        description: "no PHI",
        state: "Symphony Ready",
        repo: "symphony"
      }

      session = AgentRunner.build_session(issue, "/tmp/x", nil)

      assert session.repo == "symphony"
    end

    test "emit_failure_update sends a structured :agent_failure to the recipient and does NOT write to Monday (SYM-11942134820)" do
      session = %{
        identifier: "SYM-FAIL",
        profile_name: "claude_sonnet",
        repo: "symphony",
        host: "devbox",
        workspace_path: "/tmp/ws",
        short_sha: "abc1234",
        started_at: DateTime.utc_now(),
        failure_recipient: self()
      }

      :ok =
        AgentRunner.emit_failure_update(session, "issue-fail-1", :port_exit_nonzero,
          message: "agent crashed with status 137",
          stderr_tail: "boom\nfatal: out of memory"
        )

      assert_receive {:agent_failure, "issue-fail-1", entry}, 200
      assert entry.reason_atom == :port_exit_nonzero
      assert entry.profile_name == "claude_sonnet"
      assert entry.repo == "symphony"
      assert entry.message == "agent crashed with status 137"
      assert entry.stderr_tail == "boom\nfatal: out of memory"
      assert %DateTime{} = entry.occurred_at

      refute Enum.any?(MemoryMonday.events(), fn
               {:failure_write, _, _} -> true
               _ -> false
             end),
             "M-4a: AgentRunner must not write `## Symphony Failures` Updates per attempt; orchestrator owns the consolidated final post"
    end

    test "emit_failure_update is a no-op when issue_id is empty" do
      :ok =
        AgentRunner.emit_failure_update(
          %{profile_name: "p", repo: "r", failure_recipient: self()},
          "",
          :workspace_create_failed,
          message: "x"
        )

      refute_receive {:agent_failure, _, _}, 50

      refute Enum.any?(MemoryMonday.events(), fn
               {:failure_write, _, _} -> true
               _ -> false
             end)
    end

    test "emit_failure_update is a no-op when the recipient pid is missing or dead" do
      {:ok, dead_pid} = Agent.start(fn -> :dead end)
      Agent.stop(dead_pid)

      :ok =
        AgentRunner.emit_failure_update(
          %{profile_name: "p", repo: "r", failure_recipient: dead_pid},
          "issue-1",
          :exception_in_adapter,
          message: "should not be sent"
        )

      :ok =
        AgentRunner.emit_failure_update(
          %{profile_name: "p", repo: "r", failure_recipient: nil},
          "issue-2",
          :exception_in_adapter,
          message: "no recipient"
        )

      refute Enum.any?(MemoryMonday.events(), fn
               {:failure_write, _, _} -> true
               _ -> false
             end)
    end

    test "emit_failure_update_via_writer forwards to the writer's recipient",
         %{issue: issue, workspace: workspace} do
      # The default writer in the test setup carries `failure_recipient: nil`;
      # this test wires a fresh writer with `self()` so we can observe the
      # forwarded message.
      session =
        AgentRunner.build_session(issue, workspace, nil, self())

      {:ok, writer_pid} = AgentRunner.start_session_writer(session)
      on_exit(fn -> AgentRunner.stop_session_writer(writer_pid) end)

      :ok =
        AgentRunner.emit_failure_update_via_writer(writer_pid, issue, :max_turns_exceeded,
          message: "max_turns reached"
        )

      assert_receive {:agent_failure, "11923258050", entry}, 200
      assert entry.reason_atom == :max_turns_exceeded
      assert entry.message == "max_turns reached"
    end

    test "emit_failure_update_via_writer is a no-op when the writer is already dead",
         %{issue: issue} do
      {:ok, dead_pid} = Agent.start(fn -> %{session: %{failure_recipient: self()}} end)
      Agent.stop(dead_pid)

      :ok =
        AgentRunner.emit_failure_update_via_writer(dead_pid, issue, :exception_in_adapter,
          message: "should not be posted"
        )

      refute_receive {:agent_failure, _, _}, 50
    end
  end

  describe "profile-based dispatch" do
    alias SymphonyElixir.{Profile, ProfileResolver, Tracker}

    setup do
      Application.put_env(
        :symphony_elixir,
        :tracker_adapter_override,
        SymphonyElixir.Tracker.MemoryMonday
      )

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

      assert SymphonyElixir.AgentRunner.adapter_for_kind(profile.kind) ==
               SymphonyElixir.Claude.Adapter
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

        if Map.get(session.config, "_emit_stalled_first") ||
             Map.get(session.config, :_emit_stalled_first) do
          send(self(), {:recording_event, %{kind: :stalled}})
        end

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

      assert_received {:agent_native_tokens, "issue-tokens-1", %{"claude" => %{input: 10, output: 5, total: 15}}}
    end

    test "cost-cap refusal posts workpad, skips adapter dispatch, and exits with backoff reason" do
      install_recording_adapter(:claude)
      configure_profiles_workflow(:claude, "claude_test", %{}, cost_cap_daily_usd: 0.0001)

      state_path =
        Path.join(
          System.tmp_dir!(),
          "agent-runner-cost-cap-#{System.unique_integer([:positive])}.json"
        )

      Application.put_env(:symphony_elixir, :cost_meter_state_path, state_path)
      start_supervised!(SymphonyElixir.CostMeter)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :cost_meter_state_path)
        File.rm(state_path)
      end)

      issue = %Issue{
        id: "issue-cost-cap-1",
        identifier: "SYM-COST",
        title: "Cost cap refusal",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-COST",
        profile: "claude_test",
        assigned_to_worker: true
      }

      assert catch_exit(AgentRunner.run(issue, self(), max_turns: 1)) ==
               {:shutdown, :cost_cap_exceeded}

      refute_received {:start_session, _pid, _workspace, _config}

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:workpad_write, "issue-cost-cap-1", body} ->
                 String.contains?(body, "## Symphony Cost Cap") and
                   String.contains?(body, "Symphony Ready")

               _ ->
                 false
             end),
             "expected Cost Cap workpad write; got events=#{inspect(events)}"

      refute Enum.any?(events, fn
               {:status_write, "issue-cost-cap-1", "Cancelled"} -> true
               _ -> false
             end),
             "cost cap refusal must not cancel the item; got events=#{inspect(events)}"
    end

    test "stalled stream heartbeat does not fail a long-silent turn" do
      install_recording_adapter(:claude)
      configure_profiles_workflow(:claude, "claude_test", %{_emit_stalled_first: true})

      issue = %Issue{
        id: "issue-stalled-1",
        identifier: "SYM-STALLED",
        title: "Long silent turn",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-STALLED",
        profile: "claude_test",
        assigned_to_worker: true
      }

      AgentRunner.run(issue, self(), max_turns: 1)

      assert_received {:stop_session, _session}
    end

    test "profile resolution errors return before adapter dispatch without cancelling issue" do
      install_recording_adapter(:claude)
      configure_profiles_workflow(:claude, "claude_test")

      issue = %Issue{
        id: "issue-profile-error-1",
        identifier: "SYM-PROFILE",
        title: "Unknown profile",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-PROFILE",
        profile: "missing_profile",
        assigned_to_worker: true
      }

      assert_raise RuntimeError, ~r/profile_resolution_failed/, fn ->
        AgentRunner.run(issue, self(), max_turns: 1)
      end

      refute_received {:start_session, _pid, _workspace, _config}

      refute Enum.any?(MemoryMonday.events(), fn
               {:status_write, "issue-profile-error-1", "Cancelled"} -> true
               _ -> false
             end)

      # SYM-11923123790 AC1: profile resolution failures must post a Monday
      # failure update so the operator sees the denial without grepping logs.
      assert Enum.any?(MemoryMonday.events(), fn
               {:failure_write, "issue-profile-error-1", body} ->
                 String.contains?(body, "reason=profile_resolution_failed")

               _ ->
                 false
             end),
             "expected failure_write for profile_resolution_failed; got events=#{inspect(MemoryMonday.events())}"
    end

    test "repo allowed_profiles blocks disallowed profile before adapter dispatch" do
      install_recording_adapter(:claude)

      workspace_root =
        Path.join(System.tmp_dir!(), "agent-dispatch-repo-allowlist-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(workspace_root) end)

      profile_config = %{permission_mode: "acceptEdits", allowed_tools: ["Read"], _test_kind: "claude"}

      profiles = %{
        "claude_opus" => %{kind: "claude", claude: profile_config},
        "claude_sonnet" => %{kind: "claude", claude: profile_config}
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_repo_column_id: "repo",
        agent_default_profile: "claude_opus",
        agent_sandbox_safety_floor: %{claude: %{permission_mode: "acceptEdits"}},
        profiles: profiles,
        repos: %{
          "symphony" => %{
            clone_url: "git@github.com:openai/symphony.git",
            allowed_profiles: ["claude_sonnet"]
          }
        }
      )

      issue = %Issue{
        id: "issue-repo-profile-denied",
        identifier: "SYM-REPO-DENIED",
        title: "Repo allowlist",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-REPO-DENIED",
        profile: "claude_opus",
        repo: "symphony",
        assigned_to_worker: true
      }

      assert_raise RuntimeError, ~r/profile_not_allowed_on_repo/, fn ->
        AgentRunner.run(issue, self(), max_turns: 1)
      end

      refute_received {:start_session, _pid, _workspace, _config}

      # SYM-11923123790 AC1: per-repo allowlist denial must post a Monday
      # failure update naming the profile and repo.
      assert Enum.any?(MemoryMonday.events(), fn
               {:failure_write, "issue-repo-profile-denied", body} ->
                 String.contains?(body, "reason=profile_not_allowed_on_repo") and
                   String.contains?(body, "claude_opus") and
                   String.contains?(body, "symphony")

               _ ->
                 false
             end),
             "expected failure_write for profile_not_allowed_on_repo; got events=#{inspect(MemoryMonday.events())}"
    end

    test "max_turns_exceeded posts a Monday failure update with reason=max_turns_exceeded" do
      install_recording_adapter(:claude)
      configure_profiles_workflow(:claude, "claude_test")

      issue = %Issue{
        id: "issue-max-turns-1",
        identifier: "SYM-MAXT",
        title: "Max turns",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-MAXT",
        profile: "claude_test",
        assigned_to_worker: true
      }

      # Force the issue to look active after each turn so the runner exhausts
      # max_turns rather than seeing the issue transition out of an active
      # state.
      fetcher = fn _ids -> {:ok, [%{issue | state: "In Progress"}]} end

      AgentRunner.run(issue, self(), max_turns: 1, issue_state_fetcher: fetcher)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:failure_write, "issue-max-turns-1", body} ->
                 String.contains?(body, "reason=max_turns_exceeded")

               _ ->
                 false
             end),
             "expected failure_write reason=max_turns_exceeded; got events=#{inspect(events)}"
    end

    test "Codex AgentRuntime map config controls launched command and session policies" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "agent-runner-codex-profile-config-#{System.unique_integer([:positive])}"
        )

      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "SYM-CODEX")
      global_binary = Path.join(test_root, "global-codex")
      profile_binary = Path.join(test_root, "profile-codex")
      trace_file = Path.join(test_root, "codex-profile.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_PROFILE_TRACE")

      try do
        File.mkdir_p!(workspace)
        System.put_env("SYMP_TEST_CODEX_PROFILE_TRACE", trace_file)

        File.write!(global_binary, """
        #!/bin/sh
        printf 'GLOBAL\\n' >> "${SYMP_TEST_CODEX_PROFILE_TRACE}"
        exit 42
        """)

        File.write!(profile_binary, """
        #!/bin/sh
        printf 'PROFILE\\n' >> "${SYMP_TEST_CODEX_PROFILE_TRACE}"
        count=0

        while IFS= read -r line; do
          count=$((count + 1))
          printf 'JSON:%s\\n' "$line" >> "${SYMP_TEST_CODEX_PROFILE_TRACE}"

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-profile"}}}'
              ;;
            3)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-profile"}}}'
              ;;
            4)
              printf '%s\\n' '{"method":"turn/completed","usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10}}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """)

        File.chmod!(global_binary, 0o755)
        File.chmod!(profile_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{global_binary} app-server"
        )

        config = %{
          "command" => "#{profile_binary} app-server",
          "approval_policy" => "never",
          "thread_sandbox" => "read-only",
          "_safety_floor" => %{"thread_sandbox" => "workspace-write"}
        }

        issue = %Issue{
          id: "issue-codex-profile",
          identifier: "SYM-CODEX",
          title: "Codex profile config",
          state: "Symphony Ready",
          assigned_to_worker: true
        }

        assert {:ok, session} = SymphonyElixir.Codex.Adapter.start_session(workspace, config)

        try do
          assert :ok =
                   SymphonyElixir.Codex.Adapter.send_turn(session, "Use profile config", issue: issue)

          assert %{input: 7, output: 3, total: 10} =
                   SymphonyElixir.Codex.Adapter.runtime_native_tokens(session)
        after
          SymphonyElixir.Codex.Adapter.stop_session(session)
        end

        trace = File.read!(trace_file)
        refute trace =~ "GLOBAL"
        assert trace =~ "PROFILE"

        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "thread/start" &&
                       get_in(payload, ["params", "approvalPolicy"]) == "never" &&
                       get_in(payload, ["params", "sandbox"]) == "read-only"
                   end)
                 else
                   false
                 end
               end)
      after
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEX_PROFILE_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEX_PROFILE_TRACE")
        end

        File.rm_rf(test_root)
      end
    end

    test "exception raised by an adapter posts a failure update with reason=exception_in_adapter" do
      Application.put_env(:symphony_elixir, :agent_runtime_adapter_overrides, %{
        claude: SymphonyElixir.AgentRunnerTest.RaisingAdapter
      })

      configure_profiles_workflow(:claude, "claude_test")

      issue = %Issue{
        id: "issue-raise-1",
        identifier: "SYM-RAISE",
        title: "Raising adapter",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-RAISE",
        profile: "claude_test",
        repo: "symphony",
        assigned_to_worker: true
      }

      assert_raise RuntimeError, ~r/boom in start_session/, fn ->
        AgentRunner.run(issue, self(), max_turns: 1)
      end

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:failure_write, "issue-raise-1", body} ->
                 String.contains?(body, "reason=exception_in_adapter") and
                   String.contains?(body, "boom in start_session")

               _ ->
                 false
             end),
             "expected failure_write reason=exception_in_adapter; got events=#{inspect(events)}"

      # Crash workpad still renders + status flips to Cancelled (existing
      # behaviour preserved alongside the new failure update).
      assert Enum.any?(events, fn
               {:status_write, "issue-raise-1", "Cancelled"} -> true
               _ -> false
             end)
    end

    test "{:error, reason} from an adapter posts a failure update tagged with the reason atom" do
      Application.put_env(:symphony_elixir, :agent_runtime_adapter_overrides, %{
        claude: SymphonyElixir.AgentRunnerTest.PortExitAdapter
      })

      configure_profiles_workflow(:claude, "claude_test")

      issue = %Issue{
        id: "issue-portexit-1",
        identifier: "SYM-PE",
        title: "Port exit adapter",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-PE",
        profile: "claude_test",
        repo: "symphony",
        assigned_to_worker: true
      }

      assert_raise RuntimeError, ~r/port_exit/, fn ->
        AgentRunner.run(issue, self(), max_turns: 1)
      end

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:failure_write, "issue-portexit-1", body} ->
                 String.contains?(body, "reason=port_exit_nonzero") and
                   String.contains?(body, "agent run failed")

               _ ->
                 false
             end),
             "expected failure_write reason=port_exit_nonzero; got events=#{inspect(events)}"
    end

    defp install_recording_adapter(kind) do
      Application.put_env(:symphony_elixir, :agent_runtime_adapter_overrides, %{
        kind => RecordingAdapter
      })
    end

    defp configure_profiles_workflow(
           kind,
           profile_name,
           config_overrides \\ %{},
           workflow_overrides \\ []
         ) do
      workspace_root =
        Path.join(System.tmp_dir!(), "agent-dispatch-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace_root)
      on_exit(fn -> File.rm_rf(workspace_root) end)

      profile_kind_str = Atom.to_string(kind)

      profile_config = profile_config_for(kind)

      # Use string-keyed map so the YAML emitter doesn't trip on atom keys.
      # The profile_kind_str key holds the per-kind nested config; this is
      # where the adapter receives `_test_kind` for routing assertions.
      nested_config =
        profile_config
        |> Map.merge(config_overrides)
        |> Map.put(:_test_kind, profile_kind_str)

      profile_entry = %{}
      profile_entry = Map.put(profile_entry, :kind, profile_kind_str)
      profile_entry = Map.put(profile_entry, :cost_per_input_token_usd, 0.000001)
      profile_entry = Map.put(profile_entry, :cost_per_output_token_usd, 0.000002)
      profile_entry = Map.put(profile_entry, profile_kind_str, nested_config)

      profiles = %{profile_name => profile_entry}

      sandbox_safety_floor = sandbox_safety_floor_for(kind)

      workflow_overrides =
        Keyword.merge(
          [
            workspace_root: workspace_root,
            agent_default_profile: profile_name,
            agent_sandbox_safety_floor: sandbox_safety_floor,
            profiles: profiles
          ],
          workflow_overrides
        )

      write_workflow_file!(Workflow.workflow_file_path(), workflow_overrides)

      :ok
    end

    defp profile_config_for(:claude),
      do: %{permission_mode: "acceptEdits", allowed_tools: ["Read"]}

    defp profile_config_for(:gemini),
      do: %{command: "gemini --output-format stream-json --sandbox"}

    defp profile_config_for(:codex),
      do: %{thread_sandbox: "workspace-write", approval_policy: "never"}

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

  defmodule RaisingAdapter do
    @moduledoc false
    @behaviour SymphonyElixir.AgentRuntime

    @impl true
    def start_session(_workspace, _config), do: raise("boom in start_session")

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

  defmodule PortExitAdapter do
    @moduledoc false
    @behaviour SymphonyElixir.AgentRuntime

    @impl true
    def start_session(_workspace, _config), do: {:error, {:port_exit, 137}}

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
