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
            flunk("expected second orchestrator to fail to acquire heartbeat lock; got pid=#{inspect(second_pid)}")

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

    test "cost cap shutdown keeps Ready item claimed and schedules failure-style backoff without stranded TTL accounting" do
      orchestrator_name = Module.concat(__MODULE__, :CostCapBackoffOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      issue_id = "issue-cost-cap-backoff-1"

      issue = %Issue{
        id: issue_id,
        identifier: "SYM-COST-BACKOFF",
        title: "Cost cap backoff",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-COST-BACKOFF",
        assigned_to_worker: true
      }

      worker =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(worker)
      before_ms = System.monotonic_time(:millisecond)

      :sys.replace_state(pid, fn state ->
        running_entry = %{
          pid: worker,
          ref: ref,
          issue: issue,
          identifier: issue.identifier,
          profile_name: "claude_opus",
          worker_host: nil,
          workspace_path: "/tmp/work",
          started_at: DateTime.utc_now(),
          retry_attempt: 0
        }

        %{
          state
          | running: Map.put(state.running, issue_id, running_entry),
            claimed: MapSet.put(state.claimed, issue_id)
        }
      end)

      send(pid, {:DOWN, ref, :process, worker, {:shutdown, :cost_cap_exceeded}})
      Process.sleep(50)

      state = :sys.get_state(pid)

      assert %{attempt: 1, error: "cost cap exceeded", due_at_ms: due_at_ms} =
               Map.get(state.retry_attempts, issue_id)

      assert due_at_ms - before_ms >= 10_000
      assert MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.failure_counts, issue_id)

      refute Enum.any?(MemoryMonday.events(), fn
               {:status_write, ^issue_id, "Cancelled"} -> true
               _ -> false
             end)

      Process.demonitor(ref, [:flush])
      send(worker, :stop)
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

  describe "PHI gate at dispatch (M-6 / SYM-11923088103)" do
    test "strict mode (default): poll cycle posts ## Symphony PHI Refusal + flips to Cancelled" do
      offender = %{
        id: "issue-phi-1",
        identifier: "SYM-PHI-1",
        kinds: [:patient_name]
      }

      # Boot with no offenders so the init boot-scan succeeds; only seed
      # offenders afterwards so the poll-time refusal flow is what we test.
      orchestrator_name = Module.concat(__MODULE__, :PHIStrictDispatchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      MemoryMonday.set(
        :phi_findings_result,
        {:ok, %{items: [], phi_offenders: [offender]}}
      )

      # Drop any boot-tick events so we only assert on poll-time refusals.
      _ = :sys.get_state(pid)
      MemoryMonday.set(:events, [])

      capture_log(fn ->
        send(pid, :run_poll_cycle)
        Process.sleep(150)
      end)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:phi_refusal_write, "issue-phi-1", body} ->
                 String.starts_with?(body, "## Symphony PHI Refusal") and
                   body =~ "patient_name"

               _ ->
                 false
             end),
             "expected PHI refusal write; events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "issue-phi-1", "Cancelled"} -> true
               _ -> false
             end),
             "expected status flip to Cancelled; events=#{inspect(events)}"

      Enum.each(events, fn
        {:phi_refusal_write, _id, body} ->
          refute body =~ "matched_text"
          # Spec M-6 §Constraints: ZERO PHI in any posted text. Defensive
          # smoke check: the test offender carries kinds only, so the body
          # can never legally contain a patient-name string anyway, but we
          # also want to confirm we didn't somehow surface "Patient X" prose.
          refute body =~ ~r/Patient\s+[A-Z]/

        _ ->
          :ok
      end)
    end

    test "strict mode refuses PHI introduced between page fetch and dispatch refresh" do
      issue = %Issue{
        id: "issue-phi-race-1",
        identifier: "SYM-PHI-RACE-1",
        title: "Engineering task",
        description: "no PHI",
        state: "Symphony Ready",
        url: "https://example.org/issues/SYM-PHI-RACE-1",
        assigned_to_worker: true
      }

      offender = %{
        id: issue.id,
        identifier: issue.identifier,
        kinds: [:patient_name]
      }

      MemoryMonday.set(:phi_findings_result, {:ok, %{items: [issue], phi_offenders: []}})
      MemoryMonday.set(:item_states_result, {:error, {:phi_detected, offender}})

      orchestrator_name = Module.concat(__MODULE__, :PHIRefreshRaceOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      _ = :sys.get_state(pid)
      MemoryMonday.set(:events, [])

      capture_log(fn ->
        send(pid, :run_poll_cycle)
        Process.sleep(150)
      end)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:phi_refusal_write, "issue-phi-race-1", body} ->
                 String.starts_with?(body, "## Symphony PHI Refusal") and
                   body =~ "patient_name"

               _ ->
                 false
             end),
             "expected PHI refusal write for refresh race; events=#{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "issue-phi-race-1", "Cancelled"} -> true
               _ -> false
             end),
             "expected status flip to Cancelled for refresh race; events=#{inspect(events)}"

      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, issue.id)
    end

    test "strict mode does not crash the orchestrator when PHI offenders coexist with handoff-state items" do
      # Handoff-state items are claimed but not dispatched to new agents, so
      # this test asserts the PHI refusal flow does not poison the same poll
      # cycle's claim bookkeeping. We use a handoff item to keep the test
      # independent of `SymphonyElixir.TaskSupervisor` (only started when the
      # full app boots).
      offender = %{
        id: "issue-phi-2",
        identifier: "SYM-PHI-2",
        kinds: [:dob]
      }

      handoff_issue = %Issue{
        id: "issue-handoff-2",
        identifier: "SYM-HANDOFF-2",
        title: "Awaiting human review",
        description: "no PHI",
        state: "Human Review",
        url: "https://example.org/issues/SYM-HANDOFF-2",
        assigned_to_worker: true
      }

      orchestrator_name = Module.concat(__MODULE__, :PHIMixedDispatchOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      MemoryMonday.set(
        :phi_findings_result,
        {:ok, %{items: [handoff_issue], phi_offenders: [offender]}}
      )

      _ = :sys.get_state(pid)
      MemoryMonday.set(:events, [])

      capture_log(fn ->
        send(pid, :run_poll_cycle)
        Process.sleep(200)
      end)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:phi_refusal_write, "issue-phi-2", _body} -> true
               _ -> false
             end),
             "expected PHI refusal for offender; events=#{inspect(events)}"

      assert Process.alive?(pid),
             "orchestrator should remain alive after a same-tick PHI refusal"

      state = :sys.get_state(pid)

      assert MapSet.member?(state.claimed, handoff_issue.id),
             "expected handoff issue to still be claimed alongside PHI refusal; claimed=#{inspect(MapSet.to_list(state.claimed))}"
    end
  end

  describe "PHI gate boot scan (M-6 AC3)" do
    test "strict mode refuses to boot when active/handoff items have PHI findings" do
      offender_a = %{
        id: "boot-phi-1",
        identifier: "SYM-BOOT-PHI-1",
        kinds: [:patient_name]
      }

      offender_b = %{
        id: "boot-phi-2",
        identifier: "SYM-BOOT-PHI-2",
        kinds: [:ssn]
      }

      MemoryMonday.set(
        :phi_findings_result,
        {:ok, %{items: [], phi_offenders: [offender_a, offender_b]}}
      )

      orchestrator_name = Module.concat(__MODULE__, :BootRefusalStrictOrchestrator)

      {result, log} =
        with_log(fn ->
          Process.flag(:trap_exit, true)
          Orchestrator.start_link(name: orchestrator_name)
        end)

      case result do
        {:error, {:phi_detected_in_active_items, count}} ->
          assert count == 2

        other ->
          flunk("expected boot to refuse with phi_detected_in_active_items; got #{inspect(other)}")
      end

      assert log =~ "Symphony refusing to boot in strict mode"
      assert log =~ "SYM-BOOT-PHI-1"
      assert log =~ "SYM-BOOT-PHI-2"
      # Identifier-only refusal: no PHI types or matched text in the log.
      refute log =~ "matched_text"

      # Heartbeat should be released so a subsequent boot (after the operator
      # clears the PHI) is not blocked by a stale lock.
      assert Process.whereis(orchestrator_name) == nil
    end

    test "warn mode boots normally even when PHI offenders are present" do
      offender = %{
        id: "boot-phi-warn-1",
        identifier: "SYM-BOOT-PHI-WARN-1",
        kinds: [:dob]
      }

      MemoryMonday.set(
        :phi_findings_result,
        {:ok, %{items: [], phi_offenders: [offender]}}
      )

      workflow_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-orchestrator-warn-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")
      write_workflow!(workflow_file, phi_gate_mode: "warn")
      Workflow.set_workflow_file_path(workflow_file)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        try do
          SymphonyElixir.WorkflowStore.force_reload()
        catch
          :exit, _ -> :ok
        end
      end

      on_exit(fn -> File.rm_rf(workflow_root) end)

      orchestrator_name = Module.concat(__MODULE__, :BootRefusalWarnOrchestrator)

      log =
        capture_log(fn ->
          {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

          on_exit(fn ->
            if Process.alive?(pid) do
              Process.exit(pid, :normal)
            end
          end)

          assert Process.alive?(pid)
        end)

      assert log =~ "warn mode"
      assert log =~ "SYM-BOOT-PHI-WARN-1"
      refute log =~ "refusing to boot"
    end
  end

  describe "tracker outage tolerance (Spec M-7 AC3)" do
    alias SymphonyElixir.Orchestrator.State

    test "5xx http responses are classified as outage; 4xx and other errors are not" do
      assert :outage = SymphonyElixir.Orchestrator.classify_tracker_error_for_test(:timeout)
      assert :outage = SymphonyElixir.Orchestrator.classify_tracker_error_for_test({:http, 500})
      assert :outage = SymphonyElixir.Orchestrator.classify_tracker_error_for_test({:http, 503})
      assert :outage = SymphonyElixir.Orchestrator.classify_tracker_error_for_test({:http, 599})

      assert :outage =
               SymphonyElixir.Orchestrator.classify_tracker_error_for_test({:transport, :nxdomain})

      assert :other = SymphonyElixir.Orchestrator.classify_tracker_error_for_test(:auth_failed)
      assert :other = SymphonyElixir.Orchestrator.classify_tracker_error_for_test(:rate_limited)
      assert :other = SymphonyElixir.Orchestrator.classify_tracker_error_for_test({:http, 400})
      assert :other = SymphonyElixir.Orchestrator.classify_tracker_error_for_test({:http, 401})
      assert :other = SymphonyElixir.Orchestrator.classify_tracker_error_for_test({:http, 404})

      assert :other =
               SymphonyElixir.Orchestrator.classify_tracker_error_for_test({:graphql_errors, []})
    end

    test "Nth consecutive 5xx/timeout failure logs outage entry exactly once" do
      state = %State{outage_threshold: 3}

      log =
        capture_log(fn ->
          state =
            Enum.reduce(1..5, state, fn _i, acc ->
              SymphonyElixir.Orchestrator.record_tracker_outage_failure_for_test(
                acc,
                {:http, 503}
              )
            end)

          assert state.outage_active? == true
          assert state.outage_failure_count == 5
        end)

      # "outage entry" fires exactly once — subsequent failures stay in
      # outage and emit only debug-level "still in outage" messages.
      assert log =~ "outage entry"
      refute log =~ ~r/outage entry.*outage entry/s
    end

    test "successful tracker call after outage logs outage exit and resets counter" do
      state =
        %State{outage_threshold: 2}
        |> SymphonyElixir.Orchestrator.record_tracker_outage_failure_for_test({:http, 503})
        |> SymphonyElixir.Orchestrator.record_tracker_outage_failure_for_test(:timeout)

      assert state.outage_active? == true
      assert state.outage_failure_count == 2

      log =
        capture_log(fn ->
          state = SymphonyElixir.Orchestrator.record_tracker_success_for_test(state)
          assert state.outage_active? == false
          assert state.outage_failure_count == 0
        end)

      assert log =~ "outage exit"
    end

    test "tracker success while not in outage just resets the counter without logging" do
      state =
        %State{outage_threshold: 5}
        |> SymphonyElixir.Orchestrator.record_tracker_outage_failure_for_test(:timeout)
        |> SymphonyElixir.Orchestrator.record_tracker_outage_failure_for_test({:http, 503})

      assert state.outage_active? == false
      assert state.outage_failure_count == 2

      log =
        capture_log(fn ->
          state = SymphonyElixir.Orchestrator.record_tracker_success_for_test(state)
          assert state.outage_failure_count == 0
          assert state.outage_active? == false
        end)

      refute log =~ "outage exit"
    end
  end

  describe "tracker outage tolerance — orchestrator integration (Spec M-7 AC3)" do
    alias SymphonyElixir.Tracker.MemoryMonday

    setup do
      Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)
      MemoryMonday.reset()

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :tracker_adapter_override)
      end)

      :ok
    end

    defmodule FlakyTracker do
      @moduledoc false
      @behaviour SymphonyElixir.Tracker

      use Agent

      def start_link(_opts \\ []) do
        case Agent.start_link(
               fn -> initial_state() end,
               name: __MODULE__
             ) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Agent.update(pid, fn _ -> initial_state() end)
            {:ok, pid}
        end
      end

      defp initial_state do
        %{
          fail_remaining: 0,
          fail_reason: {:http, 503},
          acquire_count: 0
        }
      end

      def set_fail(count, reason) do
        Agent.update(__MODULE__, fn s ->
          %{s | fail_remaining: count, fail_reason: reason}
        end)
      end

      def acquire_count, do: Agent.get(__MODULE__, & &1.acquire_count)

      @impl true
      def fetch_candidate_issues_with_phi_findings do
        decide_fetch()
      end

      def fetch_candidate_issues_with_phi_findings(_opts), do: decide_fetch()

      defp decide_fetch do
        Agent.get_and_update(__MODULE__, fn s ->
          if s.fail_remaining > 0 do
            {{:error, s.fail_reason}, %{s | fail_remaining: s.fail_remaining - 1}}
          else
            {{:ok, %{items: [], phi_offenders: []}}, s}
          end
        end)
      end

      @impl true
      def fetch_candidate_issues, do: {:ok, []}

      @impl true
      def fetch_issues_by_states(_states), do: {:ok, []}

      @impl true
      def fetch_issue_states_by_ids(_ids), do: {:ok, []}

      @impl true
      def update_issue_state(_id, _state), do: :ok

      @impl true
      def upsert_workpad(_id, _body), do: :ok

      @impl true
      def set_pr_url(_id, _url), do: :ok

      @impl true
      def post_failure_update(_id, _body), do: :ok

      @impl true
      def post_pr_refusal(_id, _body), do: :ok

      @impl true
      def post_phi_refusal(_id, _body), do: :ok

      @impl true
      def acquire_heartbeat do
        Agent.update(__MODULE__, fn s -> %{s | acquire_count: s.acquire_count + 1} end)
        :ok
      end

      @impl true
      def release_heartbeat, do: :ok

      @impl true
      def validate_no_phi(_item), do: :ok
    end

    test "5 consecutive 5xx responses log outage entry but do NOT terminate the orchestrator" do
      {:ok, _flaky} = FlakyTracker.start_link()
      Application.put_env(:symphony_elixir, :tracker_adapter_override, FlakyTracker)

      # Push enough flakes to cross the default threshold (5) plus margin.
      FlakyTracker.set_fail(7, {:http, 503})

      orchestrator_name = Module.concat(__MODULE__, :OutageTolerantOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      log =
        capture_log(fn ->
          # Drive multiple poll cycles so the outage counter crosses threshold.
          Enum.each(1..7, fn _ ->
            send(pid, :run_poll_cycle)
            Process.sleep(20)
          end)
        end)

      assert Process.alive?(pid),
             "expected orchestrator to keep running through 5xx outage; pid=#{inspect(pid)}"

      assert log =~ "outage entry",
             "expected an outage-entry log line after consecutive 5xx; got=#{log}"
    end

    test "outage exit fires once tracker recovers" do
      {:ok, _flaky} = FlakyTracker.start_link()
      Application.put_env(:symphony_elixir, :tracker_adapter_override, FlakyTracker)

      # 6 failures then recovery.
      FlakyTracker.set_fail(6, :timeout)

      orchestrator_name = Module.concat(__MODULE__, :OutageRecoveryOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      log =
        capture_log(fn ->
          # First wave: drive enough cycles to enter outage.
          Enum.each(1..6, fn _ ->
            send(pid, :run_poll_cycle)
            Process.sleep(15)
          end)

          # Second wave: tracker now succeeds — the next cycle should log exit.
          send(pid, :run_poll_cycle)
          Process.sleep(50)
        end)

      assert log =~ "outage entry"
      assert log =~ "outage exit"
    end
  end

  defp write_workflow!(path, opts \\ []) do
    phi_block =
      case Keyword.get(opts, :phi_gate_mode) do
        nil -> ""
        mode -> "phi_gate:\n  mode: \"#{mode}\"\n"
      end

    yaml = """
    ---
    #{phi_block}tracker:
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
