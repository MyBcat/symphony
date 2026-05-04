defmodule SymphonyElixir.ProfileResolverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Profile, ProfileResolver, Tracker}

  @claude_opus %Profile{
    name: "claude_opus",
    kind: :claude,
    max_concurrent: 2,
    config: %{"permission_mode" => "acceptEdits", "allowed_tools" => ["Read", "Edit"]}
  }

  @claude_sonnet %Profile{
    name: "claude_sonnet",
    kind: :claude,
    max_concurrent: 6,
    config: %{"permission_mode" => "acceptEdits", "allowed_tools" => ["Read", "Edit"]}
  }

  @profiles %{"claude_opus" => @claude_opus, "claude_sonnet" => @claude_sonnet}

  @floor %{"claude" => %{"permission_mode" => "acceptEdits"}}

  test "uses per-issue profile when set" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: "claude_sonnet"}

    assert {:ok, @claude_sonnet} =
             ProfileResolver.resolve(issue, @profiles, "claude_opus", @floor)
  end

  test "trims per-issue profile before lookup" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: " claude_sonnet "}

    assert {:ok, @claude_sonnet} =
             ProfileResolver.resolve(issue, @profiles, "claude_opus", @floor)
  end

  test "falls back to default when issue.profile is nil" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: nil}
    assert {:ok, @claude_opus} = ProfileResolver.resolve(issue, @profiles, "claude_opus", @floor)
  end

  test "falls back to default when issue.profile is blank" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: "  "}
    assert {:ok, @claude_opus} = ProfileResolver.resolve(issue, @profiles, "claude_opus", @floor)
  end

  test "errors on unknown profile name" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: "claude_opus_v9"}

    assert {:error, {:unknown_profile, "claude_opus_v9"}} =
             ProfileResolver.resolve(issue, @profiles, "claude_opus", @floor)
  end

  test "errors when no default and per-issue empty" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: nil}
    assert {:error, :no_default} = ProfileResolver.resolve(issue, @profiles, nil, @floor)
  end

  test "errors on safety-floor violation" do
    unsafe = %{@claude_opus | config: %{"permission_mode" => "bypassPermissions"}}
    profiles = %{"claude_opus" => unsafe}
    issue = %Tracker.Issue{identifier: "SYM-1", profile: "claude_opus"}

    assert {:error, {:safety_floor_violation, "claude_opus", :claude, _, _}} =
             ProfileResolver.resolve(issue, profiles, nil, @floor)
  end

  test "validate_drift/2 reports missing and orphan labels" do
    profiles = %{
      "claude_opus" => @claude_opus,
      "codex" => %Profile{name: "codex", kind: :codex, max_concurrent: nil, config: %{}}
    }

    dropdown_labels = ["claude_opus", "claude_sonnet"]

    {:ok, %{missing_in_dropdown: missing, orphan_dropdown_labels: orphans}} =
      ProfileResolver.validate_drift(profiles, dropdown_labels)

    assert "codex" in missing
    assert "claude_sonnet" in orphans
  end
end
