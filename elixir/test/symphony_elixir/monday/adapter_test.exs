defmodule SymphonyElixir.Monday.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.Adapter

  defmodule FakeMondayClient do
    def graphql(_query, _vars, _opts) do
      {:ok,
       %{
         "data" => %{
           "boards" => [
             %{
               "items_page" => %{
                 "cursor" => nil,
                 "items" => [
                   %{
                     "id" => "9482736152",
                     "name" => "Fix bug",
                     "url" => "https://example.com",
                     "created_at" => "2026-05-01T00:00:00Z",
                     "updated_at" => "2026-05-03T00:00:00Z",
                     "column_values" => [
                       %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"}
                     ]
                   }
                 ]
               }
             }
           ]
         }
       }}
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :monday_client_module, FakeMondayClient)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :monday_client_module) end)

    config = %{
      tracker: %{
        kind: "monday",
        endpoint: "https://api.monday.com/v2",
        api_token: "test-token",
        board_id: 8_173_460_438,
        identifier_prefix: "SYM",
        symphony_status_column_id: "symphony_status_xyz",
        priority_column_id: "priority_abc",
        description_column_id: nil,
        branch_column_id: nil,
        labels_column_id: nil,
        active_states: ["Symphony Ready", "In Progress", "Rework"],
        handoff_states: ["Human Review", "Merging"],
        terminal_states: ["Done", "Cancelled"],
        heartbeat_item_id: 999_000,
        heartbeat_ttl_ms: 60_000
      }
    }

    Application.put_env(:symphony_elixir, :test_config_override, config)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :test_config_override) end)
    :ok
  end

  test "fetch_candidate_issues returns normalized items in active and handoff states" do
    assert {:ok, [item]} = Adapter.fetch_candidate_issues()
    assert item.identifier == "SYM-9482736152"
    assert item.state == "Symphony Ready"
  end
end
