defmodule SymphonyElixir.Gemini.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Gemini.Adapter

  describe "passes_safety_floor?/2" do
    test "passes when command has --sandbox and no --yolo" do
      safe = %{command: "gemini --model gemini-2.5-pro --output-format stream-json --sandbox"}
      floor = %{"require_sandbox" => true, "forbid_yolo" => true}
      assert Adapter.passes_safety_floor?(safe, floor)
    end

    test "fails when command lacks --sandbox" do
      no_sandbox = %{command: "gemini --model gemini-2.5-pro --output-format stream-json"}
      floor = %{"require_sandbox" => true, "forbid_yolo" => true}
      refute Adapter.passes_safety_floor?(no_sandbox, floor)
    end

    test "fails when command has --yolo" do
      yolo = %{
        command: "gemini --model gemini-2.5-pro --output-format stream-json --sandbox --yolo"
      }

      floor = %{"require_sandbox" => true, "forbid_yolo" => true}
      refute Adapter.passes_safety_floor?(yolo, floor)
    end

    test "does not treat substring matches as sandbox flags" do
      sandboxed = %{
        command: "gemini --model gemini-2.5-pro --sandboxed --output-format stream-json"
      }

      floor = %{"require_sandbox" => true, "forbid_yolo" => true}
      refute Adapter.passes_safety_floor?(sandboxed, floor)
    end

    test "passes with relaxed floor (require_sandbox: false)" do
      no_sandbox = %{command: "gemini --output-format stream-json"}
      floor = %{"require_sandbox" => false, "forbid_yolo" => true}
      assert Adapter.passes_safety_floor?(no_sandbox, floor)
    end

    test "supports string keys on config" do
      safe = %{"command" => "gemini --sandbox --output-format stream-json"}
      floor = %{"require_sandbox" => true, "forbid_yolo" => true}
      assert Adapter.passes_safety_floor?(safe, floor)
    end
  end

  describe "start_session/2 and stream_events/1" do
    test "refuses unsafe config before opening a port" do
      config = %{
        command: "printf '%s\\n' '{\"type\":\"end\"}'",
        _safety_floor: %{"require_sandbox" => true, "forbid_yolo" => true}
      }

      assert {:error, {:sandbox_floor_violation, :gemini, :config}} =
               Adapter.start_session(System.tmp_dir!(), config)
    end

    test "stream_events halts after emitting port exit" do
      config = %{
        command:
          "printf '%s\\n' '{\"type\":\"start\",\"session_id\":\"gem_stream\"}'; : --sandbox",
        _safety_floor: %{"require_sandbox" => true, "forbid_yolo" => true}
      }

      task =
        Task.async(fn ->
          {:ok, session} = Adapter.start_session(System.tmp_dir!(), config)

          try do
            Enum.to_list(Adapter.stream_events(session))
          after
            Adapter.stop_session(session)
          end
        end)

      events = Task.await(task, 1_000)

      assert Enum.map(events, & &1.kind) == [:session_started, :exit]
      assert List.last(events).status == 0
    end
  end

  describe "parse_event_line/1" do
    setup do
      lines =
        File.read!("test/fixtures/gemini/turn_completed.jsonl")
        |> String.split("\n", trim: true)

      {:ok, lines: lines}
    end

    test "normalizes Gemini streaming-json into typed events", %{lines: lines} do
      events = Enum.map(lines, &Adapter.parse_event_line/1)
      kinds = Enum.map(events, & &1.kind)
      assert :session_started in kinds
      assert :turn_completed in kinds
    end

    test "session_started event captures session_id", %{lines: lines} do
      [first | _] = Enum.map(lines, &Adapter.parse_event_line/1)
      assert first.kind == :session_started
      assert first.session_id == "gem_456"
    end

    test "turn_completed event captures runtime-native tokens", %{lines: lines} do
      events = Enum.map(lines, &Adapter.parse_event_line/1)
      complete = Enum.find(events, &(&1.kind == :turn_completed))

      assert complete.tokens.prompt == 280
      assert complete.tokens.candidates == 21
      assert complete.tokens.cached == 0
      assert complete.tokens.total == 301
    end

    test "parse_error kind on malformed JSON" do
      ev = Adapter.parse_event_line("not valid json {{")
      assert ev.kind == :parse_error
      assert ev.raw == "not valid json {{"
    end
  end

  describe "runtime_native_tokens/1" do
    test "returns Gemini native shape from session state" do
      session = %{tokens: %{prompt: 280, candidates: 21, cached: 0, total: 301}}

      assert %{prompt: 280, candidates: 21, cached: 0, total: 301} =
               Adapter.runtime_native_tokens(session)
    end

    test "returns zeros when session has no tokens" do
      assert %{prompt: 0, candidates: 0, total: 0} =
               Adapter.runtime_native_tokens(%{tokens: %{prompt: 0, candidates: 0, total: 0}})
    end
  end
end
