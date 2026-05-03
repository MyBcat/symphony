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
end
