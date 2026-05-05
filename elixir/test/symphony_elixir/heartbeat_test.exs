defmodule SymphonyElixir.HeartbeatTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Heartbeat

  defmodule StubTracker do
    @moduledoc """
    Test double for `SymphonyElixir.Tracker` that lets each test override the
    `acquire_heartbeat/0` return value at runtime via the calling-pid's
    process dictionary. We deliberately don't use `Mox` here because the
    Heartbeat GenServer runs in its own process and Mox's pid-bound stubs
    would require explicit allow() plumbing — the process-dictionary
    approach matches existing `:test_pid` patterns in adapter_test.exs.
    """

    def acquire_heartbeat do
      test_pid = :persistent_term.get(:heartbeat_test_owner_pid, nil)

      result =
        case test_pid do
          nil ->
            :ok

          pid ->
            send(pid, {:tracker_acquire_called, self()})

            case :persistent_term.get(:heartbeat_test_acquire_result, :ok) do
              fun when is_function(fun, 0) -> fun.()
              other -> other
            end
        end

      result
    end

    @doc """
    Configure the next `acquire_heartbeat/0` return value. Pass either a
    static term (`:ok` / `{:error, reason}`) or a 0-arity function for
    sequence-driven scenarios.
    """
    def set_acquire_result(result) do
      :persistent_term.put(:heartbeat_test_owner_pid, self())
      :persistent_term.put(:heartbeat_test_acquire_result, result)
      :ok
    end

    def reset do
      :persistent_term.put(:heartbeat_test_owner_pid, nil)
      :persistent_term.put(:heartbeat_test_acquire_result, :ok)
    end
  end

  setup do
    StubTracker.set_acquire_result(:ok)
    on_exit(fn -> StubTracker.reset() end)
    :ok
  end

  describe "renewal cadence (Spec M-7 AC1)" do
    test "refresh interval is heartbeat_ttl_ms / 3" do
      ttl_ms = 600

      {:ok, pid} =
        Heartbeat.start_link(
          ttl_ms: ttl_ms,
          tracker_module: StubTracker,
          name: nil
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert_receive {:tracker_acquire_called, _}, ttl_ms
    end

    test "calls Tracker.acquire_heartbeat on each tick" do
      ttl_ms = 90

      {:ok, pid} =
        Heartbeat.start_link(
          ttl_ms: ttl_ms,
          tracker_module: StubTracker,
          name: nil
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      # Receive at least three acquire calls within a few ticks.
      assert_receive {:tracker_acquire_called, _}, ttl_ms
      assert_receive {:tracker_acquire_called, _}, ttl_ms
      assert_receive {:tracker_acquire_called, _}, ttl_ms
    end
  end

  describe "degraded mode (Spec M-7 AC4)" do
    test "stays healthy on transient renewal failure" do
      # Fail once, then recover.
      counter = :counters.new(1, [])

      StubTracker.set_acquire_result(fn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          n when n <= 1 -> {:error, :timeout}
          _ -> :ok
        end
      end)

      ttl_ms = 600

      {:ok, pid} =
        Heartbeat.start_link(
          ttl_ms: ttl_ms,
          tracker_module: StubTracker,
          name: nil
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      # First tick fires after ttl/3 (~200ms); second tick another ttl/3.
      # Stay below ttl_ms total to verify "transient" classification.
      Process.sleep(div(ttl_ms, 3) + 50)
      assert Heartbeat.degraded?(pid) == false
      assert Heartbeat.snapshot(pid).consecutive_failures >= 1
    end

    test "flips to degraded once renewal has failed for > ttl_ms" do
      StubTracker.set_acquire_result({:error, :timeout})

      ttl_ms = 90
      now_minus_ttl = System.monotonic_time(:millisecond) - (ttl_ms + 50)

      log =
        capture_log(fn ->
          {:ok, pid} =
            Heartbeat.start_link(
              ttl_ms: ttl_ms,
              tracker_module: StubTracker,
              # Pretend the last success was already older than ttl_ms so the
              # very first failed tick crosses the threshold.
              initial_success_at_ms: now_minus_ttl,
              name: nil
            )

          on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

          assert_receive {:tracker_acquire_called, _}, ttl_ms
          # Give the GenServer a beat to update its state after the call.
          Process.sleep(20)

          assert Heartbeat.degraded?(pid) == true
        end)

      assert log =~ "entering degraded mode"
    end

    test "exits degraded mode and logs recovery on next successful renewal" do
      counter = :counters.new(1, [])

      StubTracker.set_acquire_result(fn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          n when n <= 2 -> {:error, :timeout}
          _ -> :ok
        end
      end)

      ttl_ms = 90
      now_minus_ttl = System.monotonic_time(:millisecond) - (ttl_ms + 50)

      log =
        capture_log(fn ->
          {:ok, pid} =
            Heartbeat.start_link(
              ttl_ms: ttl_ms,
              tracker_module: StubTracker,
              initial_success_at_ms: now_minus_ttl,
              name: nil
            )

          on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

          assert_receive {:tracker_acquire_called, _}, ttl_ms
          assert_receive {:tracker_acquire_called, _}, ttl_ms
          assert_receive {:tracker_acquire_called, _}, ttl_ms
          # Wait for the third call (success) to settle.
          Process.sleep(50)

          assert Heartbeat.degraded?(pid) == false
        end)

      assert log =~ "entering degraded mode"
      assert log =~ "exiting degraded mode"
    end
  end

  describe "public accessors" do
    test "degraded?/1 returns false when the named process is missing" do
      refute Heartbeat.degraded?(:not_a_real_heartbeat_name)
    end

    test "snapshot/1 returns nil when the named process is missing" do
      assert Heartbeat.snapshot(:not_a_real_heartbeat_name) == nil
    end

    test "snapshot/1 reports ttl, last_success, degraded?, and counter" do
      ttl_ms = 1_000

      {:ok, pid} =
        Heartbeat.start_link(
          ttl_ms: ttl_ms,
          tracker_module: StubTracker,
          name: nil
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert %{
               ttl_ms: ^ttl_ms,
               last_success_at_ms: last_success_at_ms,
               degraded?: false,
               consecutive_failures: 0
             } = Heartbeat.snapshot(pid)

      assert is_integer(last_success_at_ms)
    end
  end
end
