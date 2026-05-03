defmodule SymphonyElixir.Claude.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.Adapter

  describe "passes_safety_floor?/2" do
    test "passes when permission_mode is acceptEdits and allowed_tools have no danger Bash globs" do
      safe = %{permission_mode: "acceptEdits", allowed_tools: ["Read", "Edit", "Bash(git:*)"]}

      floor = %{
        "permission_mode" => "acceptEdits",
        "bash_denylist" => ["*sudo*", "*rm -rf*", "*chmod 777*"]
      }

      assert Adapter.passes_safety_floor?(safe, floor)
    end

    test "fails when permission_mode is bypassPermissions" do
      bypassed = %{permission_mode: "bypassPermissions", allowed_tools: []}

      floor = %{"permission_mode" => "acceptEdits"}

      refute Adapter.passes_safety_floor?(bypassed, floor)
    end

    test "fails when allowed_tools contains a Bash tool matching denylist" do
      sudo_allowed = %{permission_mode: "acceptEdits", allowed_tools: ["Bash(*sudo*)"]}

      floor = %{
        "permission_mode" => "acceptEdits",
        "bash_denylist" => ["*sudo*"]
      }

      refute Adapter.passes_safety_floor?(sudo_allowed, floor)
    end

    test "supports string keys on config (from YAML)" do
      safe = %{"permission_mode" => "acceptEdits", "allowed_tools" => ["Read"]}
      floor = %{"permission_mode" => "acceptEdits"}
      assert Adapter.passes_safety_floor?(safe, floor)
    end
  end

  describe "parse_event_line/1" do
    setup do
      lines =
        File.read!("test/fixtures/claude/turn_completed.jsonl")
        |> String.split("\n", trim: true)

      {:ok, lines: lines}
    end

    test "normalizes Claude streaming-json into a typed event vocabulary", %{lines: lines} do
      events = Enum.map(lines, &Adapter.parse_event_line/1)

      kinds = Enum.map(events, & &1.kind)
      assert :session_started in kinds
      assert :turn_completed in kinds
    end

    test "session_started event captures session_id", %{lines: lines} do
      [first | _] = Enum.map(lines, &Adapter.parse_event_line/1)
      assert first.kind == :session_started
      assert first.session_id == "sess_123"
    end

    test "turn_completed event captures runtime-native tokens", %{lines: lines} do
      events = Enum.map(lines, &Adapter.parse_event_line/1)
      complete = Enum.find(events, &(&1.kind == :turn_completed))

      assert complete.tokens.input == 260
      assert complete.tokens.output == 21
      assert complete.tokens.total == 281
      assert Map.has_key?(complete.tokens, :cache_read)
      assert Map.has_key?(complete.tokens, :cache_creation)
    end

    test "parse_error kind on malformed JSON" do
      ev = Adapter.parse_event_line("not valid json {{")
      assert ev.kind == :parse_error
      assert ev.raw == "not valid json {{"
    end
  end

  describe "runtime_native_tokens/1" do
    test "returns Claude native shape from session state" do
      session = %{
        tokens: %{input: 260, output: 21, cache_read: 0, cache_creation: 0, total: 281}
      }

      assert %{input: 260, output: 21, cache_read: 0, cache_creation: 0, total: 281} =
               Adapter.runtime_native_tokens(session)
    end

    test "returns zeros when session has no tokens accumulated" do
      assert %{input: 0, output: 0, total: 0} = Adapter.runtime_native_tokens(%{tokens: %{input: 0, output: 0, total: 0}})
    end
  end
end
