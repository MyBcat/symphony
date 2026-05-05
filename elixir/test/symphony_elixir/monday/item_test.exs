defmodule SymphonyElixir.Monday.ItemTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.Item

  @raw_item %{
    "id" => "9482736152",
    "name" => "Fix Codex tool injection",
    "url" => "https://mybcat-squad.monday.com/boards/8173460438/pulses/9482736152",
    "created_at" => "2026-05-01T10:00:00Z",
    "updated_at" => "2026-05-03T08:00:00Z",
    "column_values" => [
      %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"},
      %{"id" => "priority_abc", "text" => "High"},
      %{"id" => "description_def", "text" => "Engineering task description here."}
    ]
  }

  @config %{
    identifier_prefix: "SYM",
    symphony_status_column_id: "symphony_status_xyz",
    priority_column_id: "priority_abc",
    description_column_id: "description_def",
    branch_column_id: nil,
    labels_column_id: nil,
    profile_column_id: nil
  }

  describe "from_monday/2" do
    test "derives identifier as <prefix>-<item_id>" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.identifier == "SYM-9482736152"
      assert item.id == "9482736152"
    end

    test "extracts state from configured symphony_status column" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.state == "Symphony Ready"
    end

    test "extracts description from configured column when set" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.description == "Engineering task description here."
    end

    test "falls back to identifier when branch_column_id is nil" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.branch_name == "SYM-9482736152"
    end

    test "rejects items containing PHI in title" do
      raw = put_in(@raw_item["name"], "Patient John Smith reported issue")
      assert {:error, {:phi_detected, [{:patient_name, _}]}} = Item.from_monday(raw, @config)
    end

    test "rejects items containing PHI in description" do
      raw =
        update_in(@raw_item["column_values"], fn cols ->
          Enum.map(cols, fn
            %{"id" => "description_def"} = c -> %{c | "text" => "DOB: 01/02/1990 reported it"}
            other -> other
          end)
        end)

      assert {:error, {:phi_detected, _}} = Item.from_monday(raw, @config)
    end

    test "errors when symphony_status column is not present in column_values" do
      raw =
        update_in(@raw_item["column_values"], fn cols ->
          Enum.reject(cols, &(&1["id"] == "symphony_status_xyz"))
        end)

      assert {:error, {:missing_column, "symphony_status_xyz"}} = Item.from_monday(raw, @config)
    end
  end

  describe "profile extraction" do
    test "extracts profile from configured profile_column_id when present" do
      raw =
        put_in(@raw_item["column_values"], [
          %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"},
          %{"id" => "profile_dropdown_xyz", "text" => "claude_opus"}
        ])

      config = Map.put(@config, :profile_column_id, "profile_dropdown_xyz")

      assert {:ok, item} = Item.from_monday(raw, config)
      assert item.profile == "claude_opus"
    end

    test "profile is nil when column not configured" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.profile == nil
    end

    test "profile is nil when column is empty string" do
      raw =
        put_in(@raw_item["column_values"], [
          %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"},
          %{"id" => "profile_dropdown_xyz", "text" => ""}
        ])

      config = Map.put(@config, :profile_column_id, "profile_dropdown_xyz")

      assert {:ok, item} = Item.from_monday(raw, config)
      assert item.profile == nil
    end

    test "filters Symphony PR Refusal updates out of the synthesized description" do
      raw = %{
        "id" => "11923258050",
        "name" => "PR safety task",
        "url" => "https://example.org",
        "created_at" => "2026-05-01T10:00:00Z",
        "updated_at" => "2026-05-01T10:00:00Z",
        "column_values" => [
          %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"}
        ],
        "updates" => [
          %{
            "id" => "u1",
            "body" => "Operator note: please implement",
            "created_at" => "2026-05-01T10:00:00Z"
          },
          %{
            "id" => "u2",
            "body" =>
              "## Symphony PR Refusal\n\nReason: branch_convention_violation\n",
            "created_at" => "2026-05-01T11:00:00Z"
          }
        ]
      }

      config = %{
        identifier_prefix: "SYM",
        symphony_status_column_id: "symphony_status_xyz",
        priority_column_id: nil,
        description_column_id: nil,
        branch_column_id: nil,
        labels_column_id: nil,
        profile_column_id: nil
      }

      assert {:ok, item} = Item.from_monday(raw, config)
      assert item.description == "Operator note: please implement"
      refute item.description =~ "Symphony PR Refusal"
      refute item.description =~ "branch_convention_violation"
    end

    test "filters Symphony Cost Cap updates out of the synthesized description" do
      raw = %{
        "id" => "11923119477",
        "name" => "Cost cap task",
        "url" => "https://example.org",
        "created_at" => "2026-05-01T10:00:00Z",
        "updated_at" => "2026-05-01T10:00:00Z",
        "column_values" => [
          %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"}
        ],
        "updates" => [
          %{
            "id" => "u1",
            "body" => "Operator note: retry when cap resets",
            "created_at" => "2026-05-01T10:00:00Z"
          },
          %{
            "id" => "u2",
            "body" =>
              "## Symphony Cost Cap\n\nToday's spend: `$50.00`\nSymphony refused dispatch.\n",
            "created_at" => "2026-05-01T11:00:00Z"
          }
        ]
      }

      config = %{
        identifier_prefix: "SYM",
        symphony_status_column_id: "symphony_status_xyz",
        priority_column_id: nil,
        description_column_id: nil,
        branch_column_id: nil,
        labels_column_id: nil,
        profile_column_id: nil
      }

      assert {:ok, item} = Item.from_monday(raw, config)
      assert item.description == "Operator note: retry when cap resets"
      refute item.description =~ "Symphony Cost Cap"
      refute item.description =~ "Today's spend"
    end

    test "profile is trimmed and nil when whitespace-only" do
      raw =
        put_in(@raw_item["column_values"], [
          %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"},
          %{"id" => "profile_dropdown_xyz", "text" => "  claude_opus  "}
        ])

      config = Map.put(@config, :profile_column_id, "profile_dropdown_xyz")

      assert {:ok, item} = Item.from_monday(raw, config)
      assert item.profile == "claude_opus"

      raw =
        put_in(@raw_item["column_values"], [
          %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"},
          %{"id" => "profile_dropdown_xyz", "text" => "  "}
        ])

      assert {:ok, item} = Item.from_monday(raw, config)
      assert item.profile == nil
    end
  end
end
