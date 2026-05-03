defmodule SymphonyElixir.OrchestratorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.MemoryMonday
  alias SymphonyElixir.Workflow

  @workflow_prompt "You are an agent for this repository."

  setup do
    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestrator-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    write_workflow!(workflow_file)
    Workflow.set_workflow_file_path(workflow_file)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _ -> :ok
      end
    end

    Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)

    case Process.whereis(MemoryMonday) do
      nil -> {:ok, _} = MemoryMonday.start_link([])
      _pid -> MemoryMonday.reset()
    end

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :tracker_adapter_override)
      Application.delete_env(:symphony_elixir, :workflow_file_path)

      if pid = Process.whereis(MemoryMonday) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(workflow_root)
    end)

    :ok
  end

  describe "handoff_states" do
    test "items in handoff_states are claimed but not dispatched for new turns" do
      handoff_issue = %Issue{
        id: "issue-handoff-1",
        identifier: "MT-HANDOFF",
        title: "Awaiting human review",
        description: "no PHI",
        state: "Human Review",
        url: "https://example.org/issues/MT-HANDOFF",
        assigned_to_worker: true
      }

      MemoryMonday.set(:items_active, [handoff_issue])

      orchestrator_name = Module.concat(__MODULE__, :HandoffOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      send(pid, :run_poll_cycle)
      Process.sleep(100)

      state = :sys.get_state(pid)

      assert MapSet.member?(state.claimed, handoff_issue.id),
             "expected handoff issue to be claimed; claimed=#{inspect(MapSet.to_list(state.claimed))}"

      refute Map.has_key?(state.running, handoff_issue.id),
             "expected handoff issue to NOT have a worker running"

      events = MemoryMonday.events()

      refute Enum.any?(events, fn
               {:status_write, _id, _state} -> true
               _ -> false
             end),
             "expected no tracker writes for handoff item but saw events=#{inspect(events)}"
    end
  end

  describe "heartbeat" do
    test "boot acquires heartbeat lock; another orchestrator cannot start while held" do
      orchestrator_name = Module.concat(__MODULE__, :HeartbeatBootOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      assert Process.alive?(pid)

      # MemoryMonday's lock is global; a second Orchestrator must fail to acquire it.
      capture_log(fn ->
        Process.flag(:trap_exit, true)
        second_name = Module.concat(__MODULE__, :HeartbeatSecondOrchestrator)

        case Orchestrator.start_link(name: second_name) do
          {:ok, second_pid} ->
            flunk(
              "expected second orchestrator to fail to acquire heartbeat lock; got pid=#{inspect(second_pid)}"
            )

          {:error, _reason} ->
            :ok
        end
      end)
    end

    test "shutdown releases heartbeat lock so a new orchestrator can boot" do
      orchestrator_name = Module.concat(__MODULE__, :HeartbeatReleaseOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
      ref = Process.monitor(pid)

      :ok = GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      # Now the lock should be released; a new orchestrator can boot.
      second_name = Module.concat(__MODULE__, :HeartbeatReboot)
      {:ok, new_pid} = Orchestrator.start_link(name: second_name)

      on_exit(fn ->
        if Process.alive?(new_pid) do
          Process.exit(new_pid, :normal)
        end
      end)

      assert Process.alive?(new_pid)
    end
  end

  describe "stranded TTL" do
    test "5 consecutive dispatch failures trigger update_issue_state(:Cancelled) + post_failure_update" do
      orchestrator_name = Module.concat(__MODULE__, :StrandedOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-stranded-1"

      # Pre-claim the issue (mirrors what spawn_issue_on_worker_host would do
      # before observing a failure) so we can validate that the stranded path
      # also releases the claim.
      :sys.replace_state(pid, fn state ->
        %{state | claimed: MapSet.put(state.claimed, issue_id)}
      end)

      Enum.each(1..4, fn n ->
        state = :sys.get_state(pid)

        {:continue, state} =
          Orchestrator.record_dispatch_failure_for_test(
            state,
            issue_id,
            "spawn boom #{n}"
          )

        :sys.replace_state(pid, fn _ -> state end)
      end)

      state = :sys.get_state(pid)

      capture_log(fn ->
        {:stranded, state} =
          Orchestrator.record_dispatch_failure_for_test(
            state,
            issue_id,
            "spawn boom 5"
          )

        :sys.replace_state(pid, fn _ -> state end)
      end)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:status_write, ^issue_id, "Cancelled"} -> true
               _ -> false
             end),
             "expected status write to Cancelled in events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:failure_write, ^issue_id, body} ->
                 String.contains?(body, "Stranded after 5 consecutive failures") and
                   String.contains?(body, "spawn boom 5")

               _ ->
                 false
             end),
             "expected failure update with stranded reason in events=#{inspect(events)}"

      final_state = :sys.get_state(pid)

      refute Map.has_key?(final_state.failure_counts, issue_id),
             "expected failure_counts entry to be cleared after stranded TTL"

      refute MapSet.member?(final_state.claimed, issue_id),
             "expected claim to be released after stranded TTL"
    end
  end

  describe "per-profile concurrency caps" do
    alias SymphonyElixir.Tracker.MemoryMonday

    setup do
      Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)
      MemoryMonday.reset()
      on_exit(fn -> Application.delete_env(:symphony_elixir, :tracker_adapter_override) end)
      :ok
    end

    test "running_by_profile counter starts empty" do
      state = SymphonyElixir.Orchestrator.State.new()
      assert SymphonyElixir.Orchestrator.running_by_profile_count(state, "claude_opus") == 0
    end

    test "running_by_profile_count returns the count for a profile name" do
      state = SymphonyElixir.Orchestrator.State.new()
      state = SymphonyElixir.Orchestrator.increment_profile_count(state, "claude_opus")
      state = SymphonyElixir.Orchestrator.increment_profile_count(state, "claude_opus")
      state = SymphonyElixir.Orchestrator.increment_profile_count(state, "codex_default")

      assert SymphonyElixir.Orchestrator.running_by_profile_count(state, "claude_opus") == 2
      assert SymphonyElixir.Orchestrator.running_by_profile_count(state, "codex_default") == 1
      assert SymphonyElixir.Orchestrator.running_by_profile_count(state, "gemini_long_context") == 0
    end

    test "decrement_profile_count decrements a profile counter and floors at 0" do
      state = SymphonyElixir.Orchestrator.State.new()
      state = SymphonyElixir.Orchestrator.increment_profile_count(state, "claude_opus")
      state = SymphonyElixir.Orchestrator.decrement_profile_count(state, "claude_opus")
      state = SymphonyElixir.Orchestrator.decrement_profile_count(state, "claude_opus")
      state = SymphonyElixir.Orchestrator.decrement_profile_count(state, "claude_opus")

      assert SymphonyElixir.Orchestrator.running_by_profile_count(state, "claude_opus") == 0
    end

    test "profile_capacity_available?/3 returns false when cap reached" do
      state = SymphonyElixir.Orchestrator.State.new()
      state = SymphonyElixir.Orchestrator.increment_profile_count(state, "claude_opus")
      state = SymphonyElixir.Orchestrator.increment_profile_count(state, "claude_opus")

      refute SymphonyElixir.Orchestrator.profile_capacity_available?(state, "claude_opus", 2)
      assert SymphonyElixir.Orchestrator.profile_capacity_available?(state, "claude_opus", 3)
    end

    test "profile_capacity_available?/3 returns true when cap is nil (no cap)" do
      state = SymphonyElixir.Orchestrator.State.new()
      state = SymphonyElixir.Orchestrator.increment_profile_count(state, "claude_opus")
      state = SymphonyElixir.Orchestrator.increment_profile_count(state, "claude_opus")

      assert SymphonyElixir.Orchestrator.profile_capacity_available?(state, "claude_opus", nil)
    end
  end

  defp write_workflow!(path) do
    yaml = """
    ---
    tracker:
      kind: \"memory\"
      endpoint: \"https://example.org\"
      api_key: null
      project_slug: null
      assignee: null
      active_states: [\"Symphony Ready\", \"In Progress\"]
      handoff_states: [\"Human Review\", \"Merging\"]
      terminal_states: [\"Done\", \"Cancelled\"]
      heartbeat_ttl_ms: 60000
      failure_ttl_count: 5
    polling:
      interval_ms: 30000
    workspace:
      root: \"#{Path.join(System.tmp_dir!(), "symphony_orchestrator_workspaces")}\"
    agent:
      max_concurrent_agents: 10
      max_turns: 20
      max_retry_backoff_ms: 300000
      max_concurrent_agents_by_state: {}
    codex:
      command: \"codex app-server\"
      approval_policy: {\"reject\": {\"sandbox_approval\": true, \"rules\": true, \"mcp_elicitations\": true}}
      thread_sandbox: \"workspace-write\"
      turn_sandbox_policy: null
      turn_timeout_ms: 3600000
      read_timeout_ms: 5000
      stall_timeout_ms: 300000
    hooks:
      timeout_ms: 60000
    observability:
      dashboard_enabled: true
      refresh_ms: 1000
      render_interval_ms: 16
    ---
    #{@workflow_prompt}
    """

    File.write!(path, yaml)
    :ok
  end
end
