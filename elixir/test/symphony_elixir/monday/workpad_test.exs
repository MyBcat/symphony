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
end
