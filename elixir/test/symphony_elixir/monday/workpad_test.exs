defmodule SymphonyElixir.Monday.WorkpadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.Workpad

  describe "render_session_start/1" do
    test "produces a structured session-start markdown body" do
      session = %{
        identifier: "SYM-9482736152",
        instance_id: "abc12345",
        host: "devbox-01",
        workspace_path: "/home/dev/code/symphony-workspaces/SYM-9482736152",
        short_sha: "7bdde33b",
        started_at: ~U[2026-05-03 10:00:00Z],
        profile_name: "codex_default"
      }

      body = Workpad.render_session_start(session)

      assert body =~ "## Symphony Workpad"
      assert body =~ "devbox-01:/home/dev/code/symphony-workspaces/SYM-9482736152@7bdde33b"
      assert body =~ "Started by Symphony"
      assert body =~ "codex_default"
    end
  end

  describe "render_completion/2" do
    test "folds in the agent's _symphony_summary.md content" do
      session = %{identifier: "SYM-1", profile_name: "codex_default"}
      summary = "## Summary\n\nFixed the bug.\n\n### Test plan\n- ran make all"
      body = Workpad.render_completion(session, summary)

      assert body =~ "## Symphony Workpad"
      assert body =~ "Fixed the bug."
      assert body =~ "ran make all"
    end

    test "marks the section as Completion when summary present" do
      body = Workpad.render_completion(%{identifier: "SYM-1", profile_name: "x"}, "summary")
      assert body =~ "Completion"
    end
  end

  describe "render_crash/2" do
    test "marks crash section with reason" do
      body = Workpad.render_crash(%{identifier: "SYM-1", profile_name: "x"}, "stdio_broken")

      assert body =~ "Crashed"
      assert body =~ "stdio_broken"
    end
  end

  describe "render_failure/1" do
    test "renders the SYM-11923123790 AC2 block format with header and message" do
      body =
        Workpad.render_failure(%{
          timestamp: "2026-05-05T10:00:00Z",
          profile_name: "claude_sonnet",
          repo: "symphony",
          reason: :port_exit_nonzero,
          message: "agent process exited with status 137"
        })

      lines = String.split(body, "\n")

      assert hd(lines) ==
               "2026-05-05T10:00:00Z | profile=claude_sonnet | repo=symphony | reason=port_exit_nonzero"

      assert Enum.at(lines, 1) == "agent process exited with status 137"
    end

    test "appends the stderr section only when stderr_tail is non-empty" do
      with_stderr =
        Workpad.render_failure(%{
          timestamp: "2026-05-05T10:00:00Z",
          profile_name: "codex_default",
          repo: "symphony",
          reason: :port_exit_nonzero,
          message: "exit 137",
          stderr_tail: "boom\nfatal: out of memory"
        })

      assert with_stderr =~ "--- last 20 lines stderr ---"
      assert with_stderr =~ "boom"
      assert with_stderr =~ "fatal: out of memory"

      without_stderr =
        Workpad.render_failure(%{
          timestamp: "2026-05-05T10:00:00Z",
          profile_name: "codex_default",
          repo: "symphony",
          reason: :max_turns_exceeded,
          message: "no stderr available"
        })

      refute without_stderr =~ "--- last 20 lines stderr ---"

      whitespace_only =
        Workpad.render_failure(%{
          timestamp: "2026-05-05T10:00:00Z",
          profile_name: "codex_default",
          repo: "symphony",
          reason: :timeout,
          message: "timed out",
          stderr_tail: "   \n  \n"
        })

      refute whitespace_only =~ "--- last 20 lines stderr ---"
    end

    test "stamps unknown for missing profile/repo and accepts string reasons" do
      body =
        Workpad.render_failure(%{
          timestamp: "2026-05-05T10:00:00Z",
          reason: "custom_reason",
          message: "thing happened"
        })

      assert body =~ "profile=unknown"
      assert body =~ "repo=unknown"
      assert body =~ "reason=custom_reason"
    end

    test "fills timestamp with current UTC when caller omits it" do
      body =
        Workpad.render_failure(%{
          profile_name: "p",
          repo: "r",
          reason: :workspace_create_failed,
          message: "m"
        })

      [first | _] = String.split(body, "\n")
      [iso, _profile, _repo, _reason] = String.split(first, " | ")
      assert {:ok, _, _} = DateTime.from_iso8601(iso)
    end
  end

  describe "tail_lines/2" do
    test "returns the last n lines, joined by newline" do
      text = "a\nb\nc\nd\ne"
      assert Workpad.tail_lines(text, 3) == "c\nd\ne"
      assert Workpad.tail_lines(text, 10) == text
      assert Workpad.tail_lines(nil, 3) == ""
      assert Workpad.tail_lines("", 3) == ""
    end
  end
end
