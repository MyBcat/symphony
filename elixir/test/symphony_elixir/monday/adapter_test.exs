defmodule SymphonyElixir.Monday.AdapterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SymphonyElixir.Monday.Adapter

  defmodule FakeMondayClient do
    def graphql(query, vars, _opts) do
      send(self_pid(), {:graphql, query, vars})

      cond do
        query =~ "SymphonyItemsByIds" ->
          {:ok,
           %{
             "data" => %{
               "items" => [raw_item()]
             }
           }}

        query =~ "SymphonyStatusLabels" ->
          {:ok,
           %{
             "data" => %{
               "boards" => [
                 %{
                   "columns" => [
                     %{
                       "id" => "symphony_status_xyz",
                       "settings_str" => status_settings_str()
                     }
                   ]
                 }
               ]
             }
           }}

        true ->
          {:ok,
           %{
             "data" => %{
               "boards" => [
                 %{
                   "items_page" => %{
                     "cursor" => nil,
                     "items" => [raw_item()]
                   }
                 }
               ]
             }
           }}
      end
    end

    defp raw_item do
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
    end

    defp status_settings_str do
      Jason.encode!(%{
        "labels" => %{
          "0" => "Symphony Ready",
          "1" => "Done",
          "2" => "Rework",
          "4" => "Human Review",
          "7" => "In Progress",
          "10" => "Cancelled",
          "14" => "Merging"
        },
        "labels_colors" => %{
          "0" => %{"color" => "#00c875", "border" => "#00b461", "var_name" => "green-shadow"},
          "1" => %{"color" => "#00c875", "border" => "#00b461", "var_name" => "green-shadow"},
          "2" => %{"color" => "#fdab3d", "border" => "#e99729", "var_name" => "orange"},
          "4" => %{"color" => "#a25ddc", "border" => "#9238af", "var_name" => "purple"},
          "7" => %{"color" => "#579bfc", "border" => "#4387e8", "var_name" => "bright-blue"},
          "10" => %{"color" => "#c4c4c4", "border" => "#b0b0b0", "var_name" => "grey"},
          "14" => %{"color" => "#333333", "border" => "#222222", "var_name" => "blackish"}
        },
        "done_colors" => [1, 10],
        "deactivated_labels" => []
      })
    end

    defp self_pid, do: Process.get(:test_pid)
  end

  defmodule PHIClient do
    def graphql(query, _vars, _opts) do
      cond do
        query =~ "SymphonyStatusLabels" ->
          {:ok,
           %{
             "data" => %{
               "boards" => [
                 %{
                   "columns" => [
                     %{
                       "id" => "symphony_status_xyz",
                       "settings_str" =>
                         Jason.encode!(%{
                           "labels" => %{
                             "0" => "Symphony Ready",
                             "1" => "Done",
                             "2" => "Rework",
                             "4" => "Human Review",
                             "7" => "In Progress",
                             "10" => "Cancelled",
                             "14" => "Merging"
                           },
                           "labels_colors" => %{
                             "0" => %{"color" => "#00c875", "border" => "#00b461", "var_name" => "green-shadow"},
                             "1" => %{"color" => "#00c875", "border" => "#00b461", "var_name" => "green-shadow"},
                             "2" => %{"color" => "#fdab3d", "border" => "#e99729", "var_name" => "orange"},
                             "4" => %{"color" => "#a25ddc", "border" => "#9238af", "var_name" => "purple"},
                             "7" => %{"color" => "#579bfc", "border" => "#4387e8", "var_name" => "bright-blue"},
                             "10" => %{"color" => "#c4c4c4", "border" => "#b0b0b0", "var_name" => "grey"},
                             "14" => %{"color" => "#333333", "border" => "#222222", "var_name" => "blackish"}
                           },
                           "done_colors" => [1, 10],
                           "deactivated_labels" => []
                         })
                     }
                   ]
                 }
               ]
             }
           }}

        true ->
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
                         "name" => "Patient John Smith needs follow-up",
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
  end

  defmodule ConfigurableMondayClient do
    def graphql(query, vars, _opts) do
      send(self_pid(), {:graphql, query, vars})

      cond do
        query =~ "SymphonyStatusLabels" ->
          Process.get(:status_labels_result)

        true ->
          Process.get(:items_page_result)
      end
    end

    defp self_pid, do: Process.get(:test_pid)
  end

  defp clear_status_label_cache(%{tracker: cfg}) do
    Process.delete({Adapter, :status_label_id_map, cfg.board_id, cfg.symphony_status_column_id})
  end

  defp status_labels_result(settings_str) do
    {:ok,
     %{
       "data" => %{
         "boards" => [
           %{
             "columns" => [
               %{
                 "id" => "symphony_status_xyz",
                 "settings_str" => settings_str
               }
             ]
           }
         ]
       }
     }}
  end

  defp items_page_result(items) do
    {:ok,
     %{
       "data" => %{
         "boards" => [
           %{
             "items_page" => %{
               "cursor" => nil,
               "items" => items
             }
           }
         ]
       }
     }}
  end

  defp status_settings_str do
    Jason.encode!(%{
      "labels" => %{
        "0" => "Symphony Ready",
        "1" => "Done",
        "2" => "Rework",
        "4" => "Human Review",
        "7" => "In Progress",
        "10" => "Cancelled",
        "14" => "Merging"
      },
      "labels_colors" => %{
        "0" => %{"color" => "#00c875", "border" => "#00b461", "var_name" => "green-shadow"},
        "1" => %{"color" => "#00c875", "border" => "#00b461", "var_name" => "green-shadow"},
        "2" => %{"color" => "#fdab3d", "border" => "#e99729", "var_name" => "orange"},
        "4" => %{"color" => "#a25ddc", "border" => "#9238af", "var_name" => "purple"},
        "7" => %{"color" => "#579bfc", "border" => "#4387e8", "var_name" => "bright-blue"},
        "10" => %{"color" => "#c4c4c4", "border" => "#b0b0b0", "var_name" => "grey"},
        "14" => %{"color" => "#333333", "border" => "#222222", "var_name" => "blackish"}
      },
      "done_colors" => [1, 10],
      "deactivated_labels" => []
    })
  end

  setup do
    Process.put(:test_pid, self())
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
    assert %SymphonyElixir.Tracker.Issue{} = item
    assert item.identifier == "SYM-9482736152"
    assert item.state == "Symphony Ready"

    assert_received {:graphql, labels_query, %{"columnIds" => ["symphony_status_xyz"]}}
    assert labels_query =~ "SymphonyStatusLabels"

    assert_received {:graphql, items_query,
                     %{
                       "statusColumnId" => "symphony_status_xyz",
                       "states" => states
                     }}

    assert items_query =~ "query_params"
    assert Enum.all?(states, &is_integer/1)
    assert Enum.sort(states) == [0, 2, 4, 7, 14]
  end

  test "fetch_candidate_issues fails fast on bad status label translation paths" do
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
        active_states: ["Symphony Ready", "Bogus State"],
        handoff_states: [],
        terminal_states: ["Done", "Cancelled"],
        heartbeat_item_id: 999_000,
        heartbeat_ttl_ms: 60_000
      }
    }

    Application.put_env(:symphony_elixir, :test_config_override, config)

    log =
      capture_log(fn ->
        assert {:error, {:unknown_monday_status_labels, "symphony_status_xyz", ["Bogus State"]}} =
                 Adapter.fetch_candidate_issues()
      end)

    assert log =~ "refusing to run partial items_page filter"

    assert_received {:graphql, labels_query, _}
    assert labels_query =~ "SymphonyStatusLabels"
    refute_receive {:graphql, _items_query, _}, 10

    clear_status_label_cache(config)
    Application.put_env(:symphony_elixir, :monday_client_module, ConfigurableMondayClient)
    Process.put(:status_labels_result, status_labels_result(status_settings_str()))
    Process.put(:items_page_result, items_page_result([]))

    config = put_in(config, [:tracker, :active_states], ["Symphony Ready"])
    Application.put_env(:symphony_elixir, :test_config_override, config)

    assert {:ok, []} = Adapter.fetch_candidate_issues()

    assert_received {:graphql, labels_query, _}
    assert labels_query =~ "SymphonyStatusLabels"
    assert_received {:graphql, items_query, %{"states" => states}}
    assert items_query =~ "SymphonyItemsPage"
    assert states == [0]

    clear_status_label_cache(config)
    Process.put(:status_labels_result, {:error, :rate_limited})

    assert {:error, :rate_limited} = Adapter.fetch_candidate_issues()
    assert_received {:graphql, labels_query, _}
    assert labels_query =~ "SymphonyStatusLabels"
    refute_receive {:graphql, _items_query, _}, 10

    Enum.each([nil, "", Jason.encode!(%{}), Jason.encode!(%{"labels" => []})], fn settings_str ->
      clear_status_label_cache(config)
      Process.put(:status_labels_result, status_labels_result(settings_str))

      assert {:error, :invalid_settings_str} = Adapter.fetch_candidate_issues()
      assert_received {:graphql, labels_query, _}
      assert labels_query =~ "SymphonyStatusLabels"
      refute_receive {:graphql, _items_query, _}, 10
    end)
  end

  test "fetch_issue_states_by_ids returns normalized items for revalidation" do
    assert {:ok, [item]} = Adapter.fetch_issue_states_by_ids(["9482736152"])
    assert %SymphonyElixir.Tracker.Issue{} = item
    assert item.id == "9482736152"
    assert_received {:graphql, query, %{"itemIds" => ["9482736152"]}}
    assert query =~ "SymphonyItemsByIds"
  end

  test "fetch_candidate_issues rejects PHI items without returning PHI findings" do
    Application.put_env(:symphony_elixir, :monday_client_module, PHIClient)

    assert {:error, {:phi_detected, "9482736152"}} = Adapter.fetch_candidate_issues()
  end

  describe "write paths" do
    defmodule WriteCapturingClient do
      def graphql(query, vars, _opts) do
        send(self_pid(), {:graphql, query, vars})

        cond do
          query =~ "change_simple_column_value" ->
            {:ok, %{"data" => %{"change_simple_column_value" => %{"id" => "1"}}}}

          query =~ "create_update" ->
            {:ok, %{"data" => %{"create_update" => %{"id" => "u-1", "body" => Map.get(vars, "body")}}}}

          query =~ "edit_update" ->
            {:ok, %{"data" => %{"edit_update" => %{"id" => Map.get(vars, "id")}}}}

          query =~ "items" and query =~ "updates" ->
            {:ok, %{"data" => %{"items" => [%{"updates" => []}]}}}

          true ->
            {:ok, %{"data" => %{}}}
        end
      end

      defp self_pid, do: Process.get(:test_pid)
    end

    setup do
      Process.put(:test_pid, self())
      Application.put_env(:symphony_elixir, :monday_client_module, WriteCapturingClient)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :monday_client_module) end)
      :ok
    end

    test "update_issue_state issues change_simple_column_value mutation" do
      assert :ok = Adapter.update_issue_state("9482736152", "In Progress")
      assert_received {:graphql, query, %{"itemId" => "9482736152", "columnId" => "symphony_status_xyz", "value" => "In Progress"}}
      assert query =~ "change_simple_column_value"
    end

    test "set_pr_url writes to configured pr_column_id" do
      cfg = Application.get_env(:symphony_elixir, :test_config_override).tracker
      Application.put_env(:symphony_elixir, :test_config_override, %{tracker: Map.put(cfg, :pr_column_id, "link_pr_x")})

      assert :ok = Adapter.set_pr_url("9482736152", "https://github.com/x/y/pull/42")
      assert_received {:graphql, _query, %{"itemId" => "9482736152", "columnId" => "link_pr_x", "value" => v}}
      assert v =~ "github.com"
    end

    test "post_failure_update creates a Monday Update with a marker header" do
      assert :ok = Adapter.post_failure_update("9482736152", "Stranded after 5 attempts")
      assert_received {:graphql, query, %{"itemId" => 9_482_736_152, "body" => body}}
      assert query =~ "create_update"
      assert body =~ "## Symphony Failures"
      assert body =~ "Stranded after 5 attempts"
    end

    test "post_failure_update redacts PHI before posting per SYM-11923123790 AC5" do
      raw_body = """
      2026-05-05T10:00:00Z | profile=claude_sonnet | repo=symphony | reason=port_exit_nonzero
      agent crashed
      --- last 20 lines stderr ---
      patient John Doe failed lookup; DOB 12/01/1985 returned 500
      SSN 123-45-6789 not found in dataset
      """

      assert :ok = Adapter.post_failure_update("9482736152", raw_body)
      assert_received {:graphql, query, %{"itemId" => 9_482_736_152, "body" => body}}
      assert query =~ "create_update"

      refute body =~ "John Doe"
      refute body =~ "12/01/1985"
      refute body =~ "123-45-6789"

      assert body =~ "[REDACTED-PHI]"
      assert body =~ "## Symphony Failures"
      assert body =~ "agent crashed"
      assert body =~ "reason=port_exit_nonzero"
    end

    test "post_failure_update caps body at 8 KiB and appends [truncated]" do
      huge = String.duplicate("a", 20_000)

      assert :ok = Adapter.post_failure_update("9482736152", huge)
      assert_received {:graphql, _query, %{"body" => body}}

      assert byte_size(body) <= 8 * 1024
      assert String.ends_with?(body, "[truncated]")
      assert String.starts_with?(body, "## Symphony Failures")
    end

    test "post_failure_update leaves an exactly 8 KiB body uncapped" do
      marker_bytes = byte_size("## Symphony Failures\n")
      raw_body = String.duplicate("a", 8 * 1024 - marker_bytes)

      assert :ok = Adapter.post_failure_update("9482736152", raw_body)
      assert_received {:graphql, _query, %{"body" => body}}

      assert byte_size(body) == 8 * 1024
      refute String.ends_with?(body, "[truncated]")
    end

    test "post_failure_update truncates on valid UTF-8 boundaries" do
      marker_bytes = byte_size("## Symphony Failures\n")
      suffix_bytes = byte_size("[truncated]")
      prefix_bytes = 8 * 1024 - suffix_bytes
      ascii_before_multibyte = prefix_bytes - marker_bytes - 1
      raw_body = String.duplicate("a", ascii_before_multibyte) <> "🙂" <> String.duplicate("b", 128)

      assert :ok = Adapter.post_failure_update("9482736152", raw_body)
      assert_received {:graphql, _query, %{"body" => body}}

      assert byte_size(body) <= 8 * 1024
      assert String.valid?(body)
      assert String.ends_with?(body, "[truncated]")
      refute body =~ "🙂"
    end

    test "post_failure_update redacts common secrets and home paths before posting" do
      raw_body = """
      token escaped in stderr: MONDAY_API_TOKEN=secret-token-value
      bearer escaped in stderr: Bearer abcdefghijklmnop1234567890
      home path escaped in stderr: /home/ankit114/code/symphony-workspaces/SYM-1
      """

      assert :ok = Adapter.post_failure_update("9482736152", raw_body)
      assert_received {:graphql, _query, %{"body" => body}}

      refute body =~ "secret-token-value"
      refute body =~ "abcdefghijklmnop1234567890"
      refute body =~ "/home/ankit114"
      assert body =~ "[REDACTED-SECRET]"
      assert body =~ "[REDACTED-HOME-PATH]"
    end

    test "post_failure_update leaves bodies under the cap untouched and uses single-newline marker" do
      assert :ok = Adapter.post_failure_update("9482736152", "short body")
      assert_received {:graphql, _query, %{"body" => body}}

      refute body =~ "[truncated]"
      assert body == "## Symphony Failures\nshort body"
    end

    test "post_failure_update tolerates a nil body without crashing" do
      assert :ok = Adapter.post_failure_update("9482736152", nil)
      assert_received {:graphql, _query, %{"body" => body}}
      assert body =~ "## Symphony Failures"
    end

    test "post_pr_refusal posts an update under the Symphony PR Refusal marker" do
      assert :ok =
               Adapter.post_pr_refusal(
                 "9482736152",
                 "## Symphony PR Refusal\n\nReason: branch_convention_violation\n"
               )

      assert_received {:graphql, query, %{"itemId" => 9_482_736_152, "body" => body}}
      assert query =~ "create_update"
      assert String.starts_with?(body, "## Symphony PR Refusal")
      assert body =~ "branch_convention_violation"
    end

    test "post_pr_refusal prepends the marker when the body lacks it" do
      assert :ok = Adapter.post_pr_refusal("9482736152", "Reason: force_push_detected")
      assert_received {:graphql, _query, %{"body" => body}}
      assert String.starts_with?(body, "## Symphony PR Refusal")
      assert body =~ "force_push_detected"
    end

    test "post_pr_refusal redacts secrets and home paths before posting" do
      raw_body = """
      ## Symphony PR Refusal

      Reason: branch_convention_violation
      Token leak: GITHUB_TOKEN=ghp_abcdefghij1234567890
      Home path leak: /home/ankit114/code/symphony-workspaces/SYM-1/work
      """

      assert :ok = Adapter.post_pr_refusal("9482736152", raw_body)
      assert_received {:graphql, _query, %{"body" => body}}

      refute body =~ "ghp_abcdefghij1234567890"
      refute body =~ "/home/ankit114"
      assert body =~ "[REDACTED-SECRET]"
      assert body =~ "[REDACTED-HOME-PATH]"
      assert String.starts_with?(body, "## Symphony PR Refusal")
    end
  end

  describe "heartbeat" do
    defmodule HeartbeatClient do
      def graphql(query, vars, _opts) do
        send(self_pid(), {:graphql, query, vars})

        cond do
          # Find existing heartbeat — return none in this scenario
          query =~ "items" and query =~ "updates" ->
            {:ok, %{"data" => %{"items" => [%{"updates" => []}]}}}

          # Create heartbeat update
          query =~ "create_update" ->
            {:ok, %{"data" => %{"create_update" => %{"id" => "u-heartbeat-1", "body" => Map.get(vars, "body")}}}}

          # Edit existing
          query =~ "edit_update" ->
            {:ok, %{"data" => %{"edit_update" => %{"id" => Map.get(vars, "id")}}}}

          true ->
            {:ok, %{"data" => %{}}}
        end
      end

      defp self_pid, do: Process.get(:test_pid)
    end

    setup do
      Process.put(:test_pid, self())
      Application.put_env(:symphony_elixir, :monday_client_module, HeartbeatClient)
      previous_instance_id = Application.get_env(:symphony_elixir, :instance_id)
      Application.put_env(:symphony_elixir, :instance_id, "test-instance")

      on_exit(fn ->
        if is_nil(previous_instance_id) do
          Application.delete_env(:symphony_elixir, :instance_id)
        else
          Application.put_env(:symphony_elixir, :instance_id, previous_instance_id)
        end
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :monday_client_module) end)
      :ok
    end

    test "acquire_heartbeat creates fresh heartbeat update when sentinel has no recent one" do
      assert :ok = Adapter.acquire_heartbeat()
      # Expect a get_item_updates query, then a create_update
      assert_received {:graphql, q1, _}
      assert q1 =~ "items"
      assert_received {:graphql, q2, %{"itemId" => 999_000, "body" => body}}
      assert q2 =~ "create_update"
      assert body =~ "## Symphony Heartbeat"
      assert body =~ "instance_id:"
      assert body =~ "timestamp:"
    end

    test "release_heartbeat marks the existing heartbeat as released (or no-op if none)" do
      assert :ok = Adapter.release_heartbeat()
      # No existing heartbeat → no-op (no edit_update mutation)
      assert_received {:graphql, q1, _}
      assert q1 =~ "items"
    end
  end

  describe "heartbeat conflict detection" do
    defmodule ConflictingHeartbeatClient do
      def graphql(query, vars, _opts) do
        send(self_pid(), {:graphql, query, vars})

        cond do
          query =~ "items" and query =~ "updates" ->
            body = "## Symphony Heartbeat\n\ninstance_id: other-instance\ntimestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}\n"
            {:ok, %{"data" => %{"items" => [%{"updates" => [%{"id" => "u-other", "body" => body}]}]}}}

          query =~ "edit_update" ->
            {:ok, %{"data" => %{"edit_update" => %{"id" => Map.get(vars, "id")}}}}

          true ->
            {:ok, %{"data" => %{}}}
        end
      end

      defp self_pid, do: Process.get(:test_pid)
    end

    setup do
      Process.put(:test_pid, self())
      Application.put_env(:symphony_elixir, :monday_client_module, ConflictingHeartbeatClient)
      previous_instance_id = Application.get_env(:symphony_elixir, :instance_id)
      Application.put_env(:symphony_elixir, :instance_id, "test-instance")

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :monday_client_module)

        if is_nil(previous_instance_id) do
          Application.delete_env(:symphony_elixir, :instance_id)
        else
          Application.put_env(:symphony_elixir, :instance_id, previous_instance_id)
        end
      end)

      :ok
    end

    test "acquire_heartbeat fails cleanly when a fresh heartbeat belongs to another instance" do
      assert {:error, {:lock_held_by_other, "other-instance", timestamp}} = Adapter.acquire_heartbeat()
      assert is_binary(timestamp)
      assert_received {:graphql, q1, _}
      assert q1 =~ "updates"

      {:messages, messages} = Process.info(self(), :messages)

      refute Enum.any?(messages, fn
               {:graphql, query, _vars} -> query =~ "edit_update"
               _ -> false
             end)
    end
  end
end
