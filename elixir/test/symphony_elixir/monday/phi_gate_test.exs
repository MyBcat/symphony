defmodule SymphonyElixir.Monday.PHIGateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Monday.PHIGate
  alias SymphonyElixir.Tracker.MemoryMonday

  setup do
    Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)

    case Process.whereis(MemoryMonday) do
      nil -> {:ok, _} = MemoryMonday.start_link([])
      _pid -> MemoryMonday.reset()
    end

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :tracker_adapter_override, SymphonyElixir.Tracker.MemoryMonday)

      if pid = Process.whereis(MemoryMonday) do
        Process.exit(pid, :normal)
      end
    end)

    :ok
  end

  describe "mode_from_settings/1" do
    test "returns :strict when phi_gate is missing or default" do
      settings = %SymphonyElixir.Config.Schema{phi_gate: %SymphonyElixir.Config.Schema.PHIGate{}}
      assert PHIGate.mode_from_settings(settings) == :strict
    end

    test "returns :strict when mode is explicitly strict" do
      settings = %SymphonyElixir.Config.Schema{
        phi_gate: %SymphonyElixir.Config.Schema.PHIGate{mode: "strict"}
      }

      assert PHIGate.mode_from_settings(settings) == :strict
    end

    test "returns :warn when mode is warn" do
      settings = %SymphonyElixir.Config.Schema{
        phi_gate: %SymphonyElixir.Config.Schema.PHIGate{mode: "warn"}
      }

      assert PHIGate.mode_from_settings(settings) == :warn
    end

    test "falls back to :strict on unknown shapes (refuse-default)" do
      assert PHIGate.mode_from_settings(%{}) == :strict
      assert PHIGate.mode_from_settings(nil) == :strict
    end
  end

  describe "refuse/2 (strict mode flow)" do
    test "posts a Symphony PHI Refusal update and flips status to Cancelled" do
      offender = %{
        id: "11923088103",
        identifier: "SYM-11923088103",
        kinds: [:patient_name]
      }

      capture_log(fn ->
        assert :ok = PHIGate.refuse(offender, profile_name: "claude_opus")
      end)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:phi_refusal_write, "11923088103", body} ->
                 String.starts_with?(body, "## Symphony PHI Refusal") and
                   body =~ "patient_name" and
                   not String.contains?(body, "matched_text")

               _ ->
                 false
             end),
             "expected phi refusal write with kinds-only body; got #{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, "11923088103", "Cancelled"} -> true
               _ -> false
             end),
             "expected status flip to Cancelled; got #{inspect(events)}"
    end

    test "logs the offender identifier and kinds but never the matched text" do
      offender = %{
        id: "1",
        identifier: "SYM-1",
        kinds: [:ssn, :dob]
      }

      log =
        capture_log(fn ->
          PHIGate.refuse(offender)
        end)

      assert log =~ "identifier=SYM-1"
      assert log =~ "ssn"
      assert log =~ "dob"
      refute log =~ "123-45-6789"
      refute log =~ "matched_text"
    end
  end

  describe "warn/1 (warn mode flow)" do
    test "logs the offender but does not write to the tracker" do
      offender = %{
        id: "1",
        identifier: "SYM-1",
        kinds: [:patient_name]
      }

      log =
        capture_log(fn ->
          assert :ok = PHIGate.warn(offender)
        end)

      assert log =~ "warn mode"
      assert log =~ "SYM-1"

      assert MemoryMonday.events() == [],
             "warn mode must not produce any tracker writes; got #{inspect(MemoryMonday.events())}"
    end
  end

  describe "process_offenders/2" do
    test "is a no-op for an empty offender list (no log, no writes)" do
      log =
        capture_log(fn ->
          assert :ok = PHIGate.process_offenders([], [])
        end)

      refute log =~ "PHI gate"
      assert MemoryMonday.events() == []
    end
  end
end
