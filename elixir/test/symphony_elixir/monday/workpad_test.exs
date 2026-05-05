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

  describe "render_codex_review/2 (Spec 4 §2.8a)" do
    test "renders Symphony Codex Review marker with full output" do
      session = %{
        identifier: "SYM-11923096520",
        host: "devbox-01",
        workspace_path: "/tmp/work",
        short_sha: "abc1234",
        profile_name: "codex_gpt55_xhigh"
      }

      body =
        Workpad.render_codex_review(session, """
        Reviewed PR 42. Notes:
        1. Tests look good.
        2. No regressions detected.

        NO BLOCKING ISSUES
        """)

      assert String.starts_with?(body, "## Symphony Codex Review")
      assert body =~ "Codex Review"
      assert body =~ "codex_gpt55_xhigh"
      assert body =~ "NO BLOCKING ISSUES"
      assert body =~ "Reviewed PR 42."
      assert body =~ "devbox-01:/tmp/work@abc1234"
    end

    test "truncates long Codex output with sentinel" do
      session = %{identifier: "SYM-1", profile_name: "codex_gpt55_xhigh"}
      long_output = String.duplicate("a", 8 * 1024)

      body = Workpad.render_codex_review(session, long_output)

      assert body =~ "## Symphony Codex Review"
      assert body =~ "... (truncated)"
    end

    test "handles nil output gracefully" do
      body = Workpad.render_codex_review(%{identifier: "SYM-1", profile_name: "x"}, nil)

      assert body =~ "## Symphony Codex Review"
      # No crash; output rendered as empty string.
    end
  end

  describe "render_codex_review_failure/2 (Spec 4 §2.8a)" do
    test "renders Symphony Codex Review marker with failure reason" do
      session = %{identifier: "SYM-1", profile_name: "codex_gpt55_xhigh"}
      body = Workpad.render_codex_review_failure(session, "codex_not_found")

      assert String.starts_with?(body, "## Symphony Codex Review")
      assert body =~ "Codex Review Unavailable"
      assert body =~ "codex_not_found"
      assert body =~ "operator review is required"
    end
  end

  describe "render_auto_merge_failure/2 (Spec 4 §2.8a)" do
    test "renders Symphony Auto-Merge Failed marker with gh stderr" do
      session = %{
        identifier: "SYM-11923096520",
        host: "devbox-01",
        workspace_path: "/tmp/work",
        short_sha: "abc1234",
        profile_name: "codex_gpt55_xhigh"
      }

      body =
        Workpad.render_auto_merge_failure(
          session,
          "gh pr merge exited 1\n\nbranch protection requires reviews"
        )

      assert String.starts_with?(body, "## Symphony Auto-Merge Failed")
      assert body =~ "Auto-Merge Failed"
      assert body =~ "gh pr merge exited 1"
      assert body =~ "branch protection requires reviews"
      assert body =~ "Rework"
      assert body =~ "devbox-01:/tmp/work@abc1234"
    end

    test "truncates long stderr with sentinel" do
      long_output = String.duplicate("err\n", 4_000)
      body = Workpad.render_auto_merge_failure(%{profile_name: "x"}, long_output)

      assert body =~ "## Symphony Auto-Merge Failed"
      assert body =~ "... (truncated)"
    end
  end

  describe "render_pr_refusal/2" do
    test "renders the Symphony PR Refusal marker as the body header" do
      session = %{
        identifier: "SYM-11923258050",
        host: "devbox-01",
        workspace_path: "/tmp/work",
        short_sha: "abc1234",
        profile_name: "codex_default"
      }

      body =
        Workpad.render_pr_refusal(
          session,
          "branch_convention_violation: got main, expected symphony/SYM-11923258050/attempt-N"
        )

      assert String.starts_with?(body, "## Symphony PR Refusal")
      assert body =~ "Refusal"
      assert body =~ "codex_default"
      assert body =~ "branch_convention_violation"
      assert body =~ "symphony/SYM-11923258050/attempt-N"
      assert body =~ "devbox-01:/tmp/work@abc1234"
    end

    test "renders force_push_detected reason verbatim" do
      session = %{identifier: "SYM-1", profile_name: "claude_test"}
      body = Workpad.render_pr_refusal(session, "force_push_detected")

      assert body =~ "## Symphony PR Refusal"
      assert body =~ "force_push_detected"
      assert body =~ "claude_test"
    end
  end

  describe "render_phi_refusal/2 (M-6)" do
    test "renders the Symphony PHI Refusal marker as the body header" do
      session = %{
        identifier: "SYM-11923088103",
        host: "devbox-01",
        workspace_path: "/tmp/work",
        short_sha: "abc1234",
        profile_name: "codex_default"
      }

      body = Workpad.render_phi_refusal(session, [:patient_name])

      assert String.starts_with?(body, "## Symphony PHI Refusal")
      assert body =~ "Refusal"
      assert body =~ "codex_default"
      assert body =~ "`patient_name`"
      assert body =~ "devbox-01:/tmp/work@abc1234"
    end

    test "lists multiple finding kinds, deduped" do
      body =
        Workpad.render_phi_refusal(%{profile_name: "claude_opus"}, [
          :ssn,
          :patient_name,
          :ssn
        ])

      assert body =~ "`ssn`"
      assert body =~ "`patient_name`"
      assert Regex.scan(~r/`ssn`/, body) |> length() == 1
    end

    test "redacts non-atom kinds (defense in depth — caller must never pass raw matched text)" do
      body =
        Workpad.render_phi_refusal(%{profile_name: "x"}, [
          "Jane Doe",
          {:patient_name, "John Doe"}
        ])

      refute body =~ "Jane Doe"
      refute body =~ "John Doe"
      assert body =~ "[REDACTED]"
    end

    test "empty kinds list still produces a refusal body without leaking text" do
      body = Workpad.render_phi_refusal(%{profile_name: "x"}, [])

      assert body =~ "## Symphony PHI Refusal"
      assert body =~ "[REDACTED]"
    end

    test "explanatory copy never references raw matched text or operator content" do
      body = Workpad.render_phi_refusal(%{profile_name: "p"}, [:dob])

      assert body =~ "matched text is intentionally not shown"
      refute body =~ "matched_text"
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
