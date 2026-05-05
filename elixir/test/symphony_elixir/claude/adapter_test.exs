defmodule SymphonyElixir.Claude.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.Adapter

  describe "build_full_command/2" do
    test "appends model permission mode and allowed tools to a Claude command" do
      command = "claude --print --output-format stream-json --input-format stream-json"

      config = %{
        model: "claude-opus-4-7",
        permission_mode: "acceptEdits",
        allowed_tools: ["Read", "Edit", "Bash(git:*)"]
      }

      assert Adapter.build_full_command(command, config) ==
               "env -u ANTHROPIC_API_KEY claude --print --output-format stream-json --input-format stream-json " <>
                 "--model claude-opus-4-7 --permission-mode acceptEdits " <>
                 "--allowed-tools 'Read,Edit,Bash(git:*)'"
    end

    test "does not modify non-Claude commands" do
      command = "printf '%s\\n' ok"

      assert Adapter.build_full_command(command, %{
               model: "claude-opus-4-7",
               permission_mode: "acceptEdits",
               allowed_tools: ["Read"]
             }) == command
    end

    test "shell-quotes allowed tool names containing shell metacharacters" do
      assert Adapter.build_full_command("claude --print", %{allowed_tools: ["Bash(git:*)"]}) ==
               "env -u ANTHROPIC_API_KEY claude --print --allowed-tools 'Bash(git:*)'"
    end

    test "detects an absolute path to claude as a Claude invocation" do
      assert Adapter.build_full_command("/usr/bin/claude --print", %{model: "claude-sonnet-4-6"}) ==
               "env -u ANTHROPIC_API_KEY /usr/bin/claude --print --model claude-sonnet-4-6"
    end

    test "detects claude-code as a Claude invocation" do
      assert Adapter.build_full_command("claude-code --print", %{model: "claude-sonnet-4-6"}) ==
               "env -u ANTHROPIC_API_KEY claude-code --print --model claude-sonnet-4-6"
    end

    test "detects env-wrapped claude commands" do
      assert Adapter.build_full_command("env -u FOO claude --print", %{
               permission_mode: "acceptEdits"
             }) ==
               "env -u ANTHROPIC_API_KEY env -u FOO claude --print --permission-mode acceptEdits"
    end

    test "shell-quotes model values containing shell metacharacters" do
      assert Adapter.build_full_command("claude --print", %{model: "opus;rm -rf /"}) ==
               "env -u ANTHROPIC_API_KEY claude --print --model 'opus;rm -rf /'"
    end

    test "prefixes claude commands with env -u ANTHROPIC_API_KEY to force OAuth/keychain auth" do
      # Parent process may have ANTHROPIC_API_KEY set to an OAuth bearer token
      # that the parent claude binary uses, but a child `claude --print` would
      # try to use it as a literal API key and get HTTP 401. Stripping it
      # forces the child to fall back to OAuth/keychain auth.
      assert Adapter.build_full_command("claude --print", %{model: "claude-opus-4-7"}) ==
               "env -u ANTHROPIC_API_KEY claude --print --model claude-opus-4-7"
    end
  end

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

  describe "start_session/2 and stream_events/1" do
    test "refuses unsafe config before opening a port" do
      config = %{
        command: "printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\"}'",
        permission_mode: "bypassPermissions",
        _safety_floor: %{"permission_mode" => "acceptEdits"}
      }

      assert {:error, {:sandbox_floor_violation, :claude, :config}} =
               Adapter.start_session(System.tmp_dir!(), config)
    end

    test "stream_events halts after emitting port exit" do
      config = %{
        command: "printf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess_stream\"}'",
        permission_mode: "acceptEdits",
        allowed_tools: ["Read"],
        _safety_floor: %{"permission_mode" => "acceptEdits"}
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
      assert %{input: 0, output: 0, total: 0} =
               Adapter.runtime_native_tokens(%{tokens: %{input: 0, output: 0, total: 0}})
    end
  end
end
