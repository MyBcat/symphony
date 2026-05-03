defmodule SymphonyElixir.ConfigSchemaTest do
  use ExUnit.Case, async: true

  test "tracker schema accepts Monday config" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "$MONDAY_API_TOKEN",
        "endpoint" => "https://api.monday.com/v2",
        "board_id" => 8_173_460_438,
        "identifier_prefix" => "SYM",
        "symphony_status_column_id" => "status_mkfoo",
        "pr_column_id" => "link_mkbar",
        "heartbeat_item_id" => 1_234_567_890,
        "heartbeat_ttl_ms" => 60_000,
        "complexity_budget_per_tick" => 500,
        "backoff_factor" => 2.0,
        "max_polling_interval_ms" => 60_000,
        "failure_ttl_count" => 5,
        "active_states" => ["Symphony Ready", "In Progress", "Rework"],
        "handoff_states" => ["Human Review", "Merging"],
        "terminal_states" => ["Done", "Cancelled"]
      }
    }

    assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
    assert settings.tracker.kind == "monday"
    assert settings.tracker.board_id == 8_173_460_438
    assert settings.tracker.identifier_prefix == "SYM"
    assert settings.tracker.handoff_states == ["Human Review", "Merging"]
  end

  test "Tracker struct inspect redacts api_token" do
    tracker = %SymphonyElixir.Config.Schema.Tracker{
      kind: "monday",
      api_token: "supersecrettoken1234567890",
      board_id: 1,
      symphony_status_column_id: "x"
    }

    rendered = inspect(tracker)
    refute rendered =~ "supersecrettoken1234567890"
    assert rendered =~ "<redacted:"
  end

  test "schema accepts profiles map and agent.default_profile" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "test-token",
        "board_id" => 1,
        "symphony_status_column_id" => "x",
        "heartbeat_item_id" => 999,
        "profile_column_id" => "dropdown_mm30zep"
      },
      "profiles" => %{
        "claude_opus" => %{
          "kind" => "claude",
          "max_concurrent" => 2,
          "claude" => %{
            "command" => "claude --print --output-format stream-json",
            "model" => "claude-opus-4-7",
            "permission_mode" => "acceptEdits"
          }
        },
        "codex_gpt55_xhigh" => %{
          "kind" => "codex",
          "max_concurrent" => 4,
          "codex" => %{
            "command" => "codex app-server",
            "approval_policy" => "never",
            "thread_sandbox" => "workspace-write"
          }
        }
      },
      "agent" => %{
        "default_profile" => "claude_opus",
        "sandbox_safety_floor" => %{
          "claude" => %{"permission_mode" => "acceptEdits"},
          "codex" => %{"thread_sandbox" => "workspace-write", "approval_policy" => "never"}
        }
      }
    }

    assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
    assert settings.tracker.profile_column_id == "dropdown_mm30zep"
    assert settings.agent.default_profile == "claude_opus"
    assert is_map(settings.profiles)
    assert Map.has_key?(settings.profiles, "claude_opus")
    assert settings.profiles["claude_opus"].kind == :claude
    assert settings.profiles["claude_opus"].max_concurrent == 2
    assert settings.profiles["claude_opus"].config["model"] == "claude-opus-4-7"
  end
end
