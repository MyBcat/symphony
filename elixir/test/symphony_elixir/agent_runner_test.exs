defmodule SymphonyElixir.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue
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
end
