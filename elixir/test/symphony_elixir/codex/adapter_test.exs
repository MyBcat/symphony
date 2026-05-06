defmodule SymphonyElixir.Codex.AdapterTest do
  use SymphonyElixir.TestSupport

  # Each fake codex emits the canonical `codex exec --json` JSONL stream
  # documented in `openai/codex` `codex-rs/exec/src/exec_events.rs`:
  #
  #   {"type":"thread.started","thread_id":"thread-..."}
  #   {"type":"turn.started"}
  #   {"type":"item.started","item":{"id":"item_0","type":"command_execution",...}}
  #   {"type":"item.completed","item":{...}}
  #   {"type":"turn.completed","usage":{"input_tokens":N,"output_tokens":N,...}}
  #
  # Test fakes are tiny shell scripts that print these literally — they do
  # NOT model the full codex CLI. They cover only the byte-level shape the
  # adapter parses.

  describe "workspace cwd validation" do
    test "rejects the workspace root and paths outside workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-codex-cwd-guard-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_workspace = Path.join(test_root, "outside")

        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_workspace)

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        issue = %Issue{
          id: "issue-workspace-guard",
          identifier: "MT-999",
          title: "Validate workspace guard",
          description: "Ensure the adapter refuses invalid cwd targets",
          state: "In Progress",
          url: "https://example.org/issues/MT-999",
          labels: ["backend"]
        }

        assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
                 Adapter.run(workspace_root, "guard", issue)

        assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
                 Adapter.run(outside_workspace, "guard", issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects symlink escape cwd paths under the workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-codex-symlink-guard-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_workspace = Path.join(test_root, "outside")
        symlink_workspace = Path.join(workspace_root, "MT-1000")

        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_workspace)
        File.ln_s!(outside_workspace, symlink_workspace)

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

        issue = %Issue{
          id: "issue-workspace-symlink-guard",
          identifier: "MT-1000",
          title: "Validate symlink workspace guard",
          description: "Ensure the adapter refuses symlink escape cwd targets",
          state: "In Progress",
          url: "https://example.org/issues/MT-1000",
          labels: ["backend"]
        }

        assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
                 Adapter.run(symlink_workspace, "guard", issue)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "happy path turn lifecycle" do
    test "emits :session_started + :turn_completed and captures token usage" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-1"}'
        printf '%s\\n' '{"type":"turn.started"}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hello"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":42,"cached_input_tokens":4,"output_tokens":17,"reasoning_output_tokens":3}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        issue = build_issue("happy", "MT-101", "Happy turn")
        on_message = capture_messages_to_test_pid()

        assert {:ok, result} = Adapter.run(ctx.workspace, "do the thing", issue, on_message: on_message)

        assert %{result: :turn_completed, thread_id: "thread-1", session_id: "thread-1"} = result

        assert_received {:codex_message,
                         %{
                           event: :session_started,
                           session_id: "thread-1",
                           thread_id: "thread-1"
                         }}

        assert_received {:codex_message,
                         %{
                           event: :turn_completed,
                           usage: %{
                             "input_tokens" => 42,
                             "output_tokens" => 17,
                             "cached_input_tokens" => 4,
                             "reasoning_output_tokens" => 3
                           }
                         }}
      end)
    end

    test "writes the prompt to a workspace temp file and pipes it into codex stdin" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        # The adapter pipes the prompt over stdin; capture it.
        prompt=$(cat)
        printf 'PROMPT:%s\\n' "$prompt" >> "$trace_file"
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-prompt"}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        issue = build_issue("prompt", "MT-PROMPT", "Capture prompt")

        assert {:ok, _result} = Adapter.run(ctx.workspace, "the prompt body", issue)

        trace = File.read!(ctx.trace_file)
        assert trace =~ "PROMPT:the prompt body"
      end)
    end
  end

  describe "token telemetry" do
    test "runtime_native_tokens/1 returns Codex-native shape after a turn" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-tok"}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":50,"cached_input_tokens":10,"reasoning_output_tokens":5}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        {:ok, session} = Adapter.start_session(ctx.workspace)
        assert :ok = Adapter.send_turn(session, "x", issue: build_issue("tok", "MT-TOK", "tokens"))

        tokens = Adapter.runtime_native_tokens(session)

        assert tokens.input == 100
        assert tokens.output == 50
        assert tokens.cached_input == 10
        assert tokens.reasoning_output == 5
        assert tokens.total >= 150

        Adapter.stop_session(session)
      end)
    end

    test "AgentRunner.extract_token_delta_from_usage/1 reads input_tokens / output_tokens off the :turn_completed envelope" do
      # End-to-end: the adapter MUST emit usage with the canonical Codex
      # JSONL keys (`input_tokens`, `output_tokens`) so M-3 cost cap math
      # in `AgentRunner.observe_token_usage_for_cost_meter/2` keeps reading
      # non-zero. Regression guard for the exact bug the spec called out.
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-agent-runner"}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":11}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:ok, _result} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("ar", "MT-AR", "AgentRunner usage"),
                   on_message: on_message
                 )

        assert_received {:codex_message,
                         %{event: :turn_completed, usage: %{"input_tokens" => 7, "output_tokens" => 11}}}
      end)
    end
  end

  describe "error paths" do
    test "turn.failed propagates the error message and emits :turn_failed" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-fail"}'
        printf '%s\\n' '{"type":"turn.failed","error":{"message":"context window exceeded"}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:error, {:turn_failed, %{"message" => "context window exceeded"}}} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("fail", "MT-FAIL", "fail"),
                   on_message: on_message
                 )

        assert_received {:codex_message, %{event: :session_started}}
        assert_received {:codex_message,
                         %{event: :turn_failed, details: %{"message" => "context window exceeded"}}}
      end)
    end

    test "top-level error event is treated as a fatal turn failure" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"error","message":"upstream auth failure"}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:error, {:turn_failed, %{"message" => "upstream auth failure"}}} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("err", "MT-ERR", "err"),
                   on_message: on_message
                 )

        assert_received {:codex_message,
                         %{event: :turn_failed, details: %{"message" => "upstream auth failure"}}}
      end)
    end

    test "exit-without-turn-completed is surfaced as :turn_failed" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-early-exit"}'
        # Exit cleanly WITHOUT emitting turn.completed.
        exit 0
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:error, {:codex_exit_without_turn_completed, 0}} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("early", "MT-EARLY", "early exit"),
                   on_message: on_message
                 )

        assert_received {:codex_message, %{event: :turn_failed, reason: {:codex_exit_without_turn_completed, 0}}}
      end)
    end
  end

  describe "stderr / non-JSON line handling" do
    test "captures non-JSON stderr noise via Logger and scrubs bearer tokens" do
      with_fake_codex(fn ctx ->
        bearer = String.duplicate("Z", 24)

        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' 'warning: codex initializing slowly' >&2
        printf '%s\\n' 'Authorization: Bearer #{bearer}' >&2
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-noise"}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        log =
          capture_log(fn ->
            assert {:ok, _result} =
                     Adapter.run(
                       ctx.workspace,
                       "x",
                       build_issue("noise", "MT-NOISE", "stderr noise"),
                       on_message: on_message
                     )
          end)

        assert_received {:codex_message, %{event: :turn_completed}}
        refute_received {:codex_message, %{event: :malformed}}

        assert log =~ "codex initializing slowly"
        assert log =~ "[REDACTED]"
        refute log =~ bearer
      end)
    end

    test "JSON-like protocol lines that fail to decode emit :malformed without aborting the turn" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-malformed"}'
        printf '%s\\n' '{"type":"turn.completed"'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:ok, _result} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("malformed", "MT-MAL", "malformed line"),
                   on_message: on_message
                 )

        assert_received {:codex_message, %{event: :malformed, payload: ~s({"type":"turn.completed")}}
        assert_received {:codex_message, %{event: :turn_completed}}
      end)
    end

    test "buffers partial JSON lines until newline terminator" do
      # Codex emits one JSON object per line. The Erlang port `line:` mode
      # delivers data in chunks bounded by `@port_line_bytes` — anything
      # bigger spans multiple `:noeol` chunks. The adapter MUST buffer
      # `:noeol` chunks until the terminating `:eol` arrives, otherwise
      # large `item.completed` payloads (with multi-KB command output)
      # would land as malformed events.
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        padding=$(printf '%*s' 1100000 '' | tr ' ' a)
        printf '{"type":"thread.started","thread_id":"thread-partial","padding":"%s"}\\n' "$padding"
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:ok, _result} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("partial", "MT-PART", "partial line"),
                   on_message: on_message
                 )

        refute_received {:codex_message, %{event: :malformed}}
        assert_received {:codex_message, %{event: :session_started, thread_id: "thread-partial"}}
      end)
    end
  end

  describe "item events" do
    test "command_execution items emit :tool_call_started + :tool_call_completed" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-cmd"}'
        printf '%s\\n' '{"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"ls","aggregated_output":"","exit_code":null,"status":"in_progress"}}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"ls","aggregated_output":"a\\nb\\n","exit_code":0,"status":"completed"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:ok, _result} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("cmd", "MT-CMD", "cmd"),
                   on_message: on_message
                 )

        assert_received {:codex_message, %{event: :tool_call_started, item: %{"type" => "command_execution"}}}
        assert_received {:codex_message, %{event: :tool_call_completed, item: %{"type" => "command_execution"}}}
      end)
    end

    test "command_execution failure emits :tool_call_failed" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-cmd-fail"}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"false","aggregated_output":"","exit_code":1,"status":"failed"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:ok, _result} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("cmd-fail", "MT-CMDF", "cmd fail"),
                   on_message: on_message
                 )

        assert_received {:codex_message, %{event: :tool_call_failed, item: %{"type" => "command_execution", "status" => "failed"}}}
      end)
    end

    test "agent_message item is forwarded as :notification" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-msg"}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"all done"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        on_message = capture_messages_to_test_pid()

        assert {:ok, _result} =
                 Adapter.run(
                   ctx.workspace,
                   "x",
                   build_issue("msg", "MT-MSG", "msg"),
                   on_message: on_message
                 )

        assert_received {:codex_message,
                         %{event: :notification, item: %{"type" => "agent_message", "text" => "all done"}}}
      end)
    end
  end

  describe "stream_events/1 + AgentRuntime contract" do
    test "captures emitted events into a per-session buffer drained by stream_events/1" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-stream"}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: ctx.codex_command,
          codex_approval_policy: "never"
        )

        {:ok, session} = Adapter.start_session(ctx.workspace)

        assert :ok = Adapter.send_turn(session, "x", issue: build_issue("stream", "MT-STR", "stream"))

        events = session |> Adapter.stream_events() |> Enum.to_list()

        # Order is preserved: session_started first, turn_completed last.
        events_by_kind = Enum.map(events, & &1.event)
        assert Enum.member?(events_by_kind, :session_started)
        assert Enum.member?(events_by_kind, :turn_completed)

        Adapter.stop_session(session)
      end)
    end
  end

  describe "command resolution" do
    test "profile-config command overrides legacy codex.command" do
      with_fake_codex(fn ctx ->
        File.write!(ctx.codex_binary, jsonl_fake_script(ctx, """
        prompt=$(cat)
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-profile"}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        """))

        File.chmod!(ctx.codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: ctx.workspace_root,
          codex_command: "definitely-not-this exec --json",
          codex_approval_policy: "never"
        )

        # Profile-config command: should be used instead of the legacy
        # workflow-level `codex.command`. If the legacy one ran, the test
        # would fail because `definitely-not-this` doesn't exist.
        config = %{
          "command" => ctx.codex_command,
          "approval_policy" => "never",
          "thread_sandbox" => "workspace-write"
        }

        {:ok, session} = Adapter.start_session(ctx.workspace, config)
        assert :ok = Adapter.send_turn(session, "x")

        Adapter.stop_session(session)
      end)
    end

    test "invalid sandbox profile config is refused at start_session/2" do
      config = %{
        "thread_sandbox" => "danger-full-access",
        "approval_policy" => "never",
        "_safety_floor" => %{"thread_sandbox" => "workspace-write"}
      }

      assert {:error, {:sandbox_floor_violation, :codex, :config}} =
               Adapter.start_session("/tmp/whatever", config)
    end
  end

  describe "passes_safety_floor?/2" do
    test "passes when thread_sandbox: workspace-write + approval_policy: never" do
      config = %{thread_sandbox: "workspace-write", approval_policy: "never"}
      floor = %{"thread_sandbox" => "workspace-write", "approval_policy" => "never"}
      assert Adapter.passes_safety_floor?(config, floor) == true
    end

    test "fails when thread_sandbox is danger-full-access" do
      config = %{thread_sandbox: "danger-full-access", approval_policy: "never"}
      floor = %{"thread_sandbox" => "workspace-write"}
      refute Adapter.passes_safety_floor?(config, floor)
    end

    test "passes when thread_sandbox: read-only" do
      config = %{thread_sandbox: "read-only", approval_policy: "never"}
      floor = %{"thread_sandbox" => "workspace-write"}
      assert Adapter.passes_safety_floor?(config, floor)
    end

    test "fails when workspace-write exceeds a read-only floor" do
      config = %{thread_sandbox: "workspace-write", approval_policy: "never"}
      floor = %{"thread_sandbox" => "read-only"}
      refute Adapter.passes_safety_floor?(config, floor)
    end

    test "fails when approval_policy is not never even if floor is relaxed" do
      config = %{thread_sandbox: "workspace-write", approval_policy: "on-request"}
      floor = %{"thread_sandbox" => "workspace-write", "approval_policy" => "on-request"}
      refute Adapter.passes_safety_floor?(config, floor)
    end

    test "supports string keys (from YAML parse)" do
      config = %{"thread_sandbox" => "workspace-write", "approval_policy" => "never"}
      floor = %{"thread_sandbox" => "workspace-write"}
      assert Adapter.passes_safety_floor?(config, floor)
    end
  end

  describe "remote (SSH) launch" do
    test "launches codex over ssh and embeds the prompt as a shell-escaped positional argument" do
      previous_path = System.get_env("PATH")
      previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      end)

      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-codex-remote-ssh-#{System.unique_integer([:positive])}"
        )

      try do
        trace_file = Path.join(test_root, "ssh.trace")
        fake_ssh = Path.join(test_root, "ssh")
        remote_workspace = "/remote/workspaces/MT-REMOTE"

        File.mkdir_p!(test_root)
        System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, """
        #!/bin/sh
        trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
        printf 'ARGV:%s\\n' "$*" >> "$trace_file"
        # Adapter embeds the prompt as a positional argument inside the
        # remote bash command — no stdin write, no port close timing
        # trap. The prompt is therefore visible in $@.
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-remote"}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
        """)

        File.chmod!(fake_ssh, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: "/remote/workspaces",
          codex_command: "fake-remote-codex exec --json"
        )

        issue = build_issue("remote", "MT-REMOTE", "Remote SSH launch")

        assert {:ok, _result} =
                 Adapter.run(
                   remote_workspace,
                   "remote prompt body",
                   issue,
                   worker_host: "worker-01:2200"
                 )

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
        assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
        assert argv_line =~ "cd "
        assert argv_line =~ remote_workspace
        assert argv_line =~ "exec fake-remote-codex exec --json"
        # The prompt rides as a single-quoted positional argument.
        assert argv_line =~ "'remote prompt body'"
      after
        File.rm_rf(test_root)
      end
    end
  end

  ## ──────────────────────────────────────────────────────────────────────
  ## Test helpers
  ## ──────────────────────────────────────────────────────────────────────

  defp with_fake_codex(fun) when is_function(fun, 1) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-codex-fake-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-WS")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")

    File.mkdir_p!(workspace)

    previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")
    System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)

    on_exit(fn ->
      restore_env("SYMP_TEST_CODEX_TRACE", previous_trace)
    end)

    try do
      fun.(%{
        test_root: test_root,
        workspace_root: workspace_root,
        workspace: workspace,
        codex_binary: codex_binary,
        codex_command: "#{codex_binary} exec --json",
        trace_file: trace_file
      })
    after
      File.rm_rf(test_root)
    end
  end

  defp jsonl_fake_script(_ctx, body) do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CODEX_TRACE:-/tmp/symphony-codex-fake.trace}"
    #{body}
    """
  end

  defp build_issue(slug, identifier, title) do
    %Issue{
      id: "issue-#{slug}",
      identifier: identifier,
      title: title,
      description: title,
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end

  defp capture_messages_to_test_pid do
    test_pid = self()
    fn message -> send(test_pid, {:codex_message, message}) end
  end
end
