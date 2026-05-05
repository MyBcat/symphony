defmodule SymphonyElixir.Monday.AdapterTest do
  use ExUnit.Case, async: false

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

  defmodule RaisingPHIDetector do
    def scan(_text), do: raise("detector unavailable")
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

  describe "fetch_candidate_issues_with_phi_findings (M-6)" do
    defmodule MixedClient do
      @moduledoc """
      Returns one clean item and one PHI-tainted item on the same page so we
      can assert the new split contract: clean items dispatch normally;
      PHI offenders surface as a separate list with finding *kinds* only.
      """
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
                             "labels_colors" => %{},
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
                           "id" => "1111111111",
                           "name" => "Engineering task",
                           "url" => "https://example.com/1",
                           "created_at" => "2026-05-01T00:00:00Z",
                           "updated_at" => "2026-05-03T00:00:00Z",
                           "column_values" => [
                             %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"}
                           ]
                         },
                         %{
                           "id" => "2222222222",
                           "name" => "Patient Jane Doe needs follow-up",
                           "url" => "https://example.com/2",
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

    test "splits a mixed page into clean items and PHI offenders, never including matched text" do
      Application.put_env(:symphony_elixir, :monday_client_module, MixedClient)

      assert {:ok, %{items: items, phi_offenders: offenders}} =
               Adapter.fetch_candidate_issues_with_phi_findings()

      # Clean item flows through; PHI item is split out.
      assert [%SymphonyElixir.Tracker.Issue{id: "1111111111"}] = items

      assert [%{id: "2222222222", identifier: "SYM-2222222222", kinds: kinds}] = offenders
      assert :patient_name in kinds

      # Sanity: no offender map should ever carry matched text.
      Enum.each(offenders, fn offender ->
        refute Map.has_key?(offender, :matched_text)
        refute Map.has_key?(offender, :findings)

        Enum.each(offender.kinds, fn kind ->
          assert is_atom(kind), "kinds must be atoms; got #{inspect(kind)}"
        end)
      end)
    end

    test "warn mode returns PHI-tainted items alongside redacted offenders so dispatch can proceed" do
      Application.put_env(:symphony_elixir, :monday_client_module, MixedClient)

      config = Application.get_env(:symphony_elixir, :test_config_override)
      Application.put_env(:symphony_elixir, :test_config_override, Map.put(config, :phi_gate, %{mode: "warn"}))

      assert {:ok, %{items: items, phi_offenders: offenders}} =
               Adapter.fetch_candidate_issues_with_phi_findings()

      assert Enum.map(items, & &1.id) == ["1111111111", "2222222222"]
      assert [%{id: "2222222222", kinds: kinds}] = offenders
      assert :patient_name in kinds

      refute inspect(offenders) =~ "Jane Doe"
    end

    test "strict mode fail-closes when the PHI detector itself fails" do
      Application.put_env(:symphony_elixir, :monday_client_module, FakeMondayClient)
      Application.put_env(:symphony_elixir, :phi_detector_module, RaisingPHIDetector)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :phi_detector_module) end)

      assert {:ok, %{items: [], phi_offenders: [offender]}} =
               Adapter.fetch_candidate_issues_with_phi_findings()

      assert offender.id == "9482736152"
      assert offender.identifier == "SYM-9482736152"
      assert offender.kinds == [:detector_failed_title]
    end

    test "warn mode fail-opens when the PHI detector itself fails" do
      Application.put_env(:symphony_elixir, :monday_client_module, FakeMondayClient)
      Application.put_env(:symphony_elixir, :phi_detector_module, RaisingPHIDetector)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :phi_detector_module) end)

      config = Application.get_env(:symphony_elixir, :test_config_override)
      Application.put_env(:symphony_elixir, :test_config_override, Map.put(config, :phi_gate, %{mode: "warn"}))

      assert {:ok, %{items: [item], phi_offenders: [offender]}} =
               Adapter.fetch_candidate_issues_with_phi_findings()

      assert item.id == "9482736152"
      assert offender.kinds == [:detector_failed_title]
    end

    test "returns empty offenders list on a clean page" do
      Application.put_env(:symphony_elixir, :monday_client_module, FakeMondayClient)

      assert {:ok, %{items: [%SymphonyElixir.Tracker.Issue{}], phi_offenders: []}} =
               Adapter.fetch_candidate_issues_with_phi_findings()
    end

    test "accepts a page limit override for the boot-time PHI scan" do
      Application.put_env(:symphony_elixir, :monday_client_module, FakeMondayClient)

      assert {:ok, %{items: [%SymphonyElixir.Tracker.Issue{}], phi_offenders: []}} =
               Adapter.fetch_candidate_issues_with_phi_findings(limit: 50)

      assert_received {:graphql, _labels_query, _}
      assert_received {:graphql, items_query, %{"limit" => 50}}
      assert items_query =~ "limit: $limit"
    end

    test "fetch_candidate_issues continues to surface a {:phi_detected, id} error for legacy callers" do
      Application.put_env(:symphony_elixir, :monday_client_module, MixedClient)

      assert {:error, {:phi_detected, "2222222222"}} = Adapter.fetch_candidate_issues()
    end
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

    test "post_phi_refusal posts an update under the Symphony PHI Refusal marker (M-6)" do
      assert :ok =
               Adapter.post_phi_refusal(
                 "9482736152",
                 "## Symphony PHI Refusal\n\nFinding types: `patient_name`\n"
               )

      assert_received {:graphql, query, %{"itemId" => 9_482_736_152, "body" => body}}
      assert query =~ "create_update"
      assert String.starts_with?(body, "## Symphony PHI Refusal")
      assert body =~ "patient_name"
    end

    test "post_phi_refusal prepends the marker when the body lacks it" do
      assert :ok = Adapter.post_phi_refusal("9482736152", "Finding types: `ssn`")
      assert_received {:graphql, _query, %{"body" => body}}
      assert String.starts_with?(body, "## Symphony PHI Refusal")
      assert body =~ "ssn"
    end

    test "post_phi_refusal scrubs any stray PHI in the body before posting" do
      # Defense in depth: even though Workpad.render_phi_refusal/2 never sees
      # raw matched text, the adapter MUST run sanitize_failure_body on the
      # incoming body. Spec M-6 §Constraints: ZERO PHI may appear, EVER.
      raw_body = """
      ## Symphony PHI Refusal

      Finding types: `patient_name`
      bug: caller accidentally included Patient John Smith in the body
      """

      assert :ok = Adapter.post_phi_refusal("9482736152", raw_body)
      assert_received {:graphql, _query, %{"body" => body}}

      refute body =~ "John Smith"
      assert body =~ "[REDACTED-PHI]"
      assert String.starts_with?(body, "## Symphony PHI Refusal")
    end

    test "post_codex_review posts an update under the Symphony Codex Review marker (Spec 4 §2.8a)" do
      assert :ok =
               Adapter.post_codex_review(
                 "9482736152",
                 "## Symphony Codex Review\n\nReviewed PR. NO BLOCKING ISSUES\n"
               )

      assert_received {:graphql, query, %{"itemId" => 9_482_736_152, "body" => body}}
      assert query =~ "create_update"
      assert String.starts_with?(body, "## Symphony Codex Review")
      assert body =~ "NO BLOCKING ISSUES"
    end

    test "post_codex_review prepends the marker when the body lacks it (Spec 4 §2.8a)" do
      assert :ok =
               Adapter.post_codex_review(
                 "9482736152",
                 "Reviewed PR. BLOCKING ISSUES FOUND"
               )

      assert_received {:graphql, _query, %{"body" => body}}
      assert String.starts_with?(body, "## Symphony Codex Review")
      assert body =~ "BLOCKING ISSUES FOUND"
    end

    test "post_codex_review scrubs secrets in Codex output (Spec 4 §2.8a)" do
      raw_body = """
      ## Symphony Codex Review

      Reviewed PR. NO BLOCKING ISSUES
      Token leak: GITHUB_TOKEN=ghp_abcdefghij1234567890
      """

      assert :ok = Adapter.post_codex_review("9482736152", raw_body)
      assert_received {:graphql, _query, %{"body" => body}}

      refute body =~ "ghp_abcdefghij1234567890"
      assert body =~ "[REDACTED-SECRET]"
      assert String.starts_with?(body, "## Symphony Codex Review")
    end

    test "post_auto_merge_failure posts an update under the Symphony Auto-Merge Failed marker (Spec 4 §2.8a)" do
      assert :ok =
               Adapter.post_auto_merge_failure(
                 "9482736152",
                 "## Symphony Auto-Merge Failed\n\ngh pr merge exited 1\n"
               )

      assert_received {:graphql, query, %{"itemId" => 9_482_736_152, "body" => body}}
      assert query =~ "create_update"
      assert String.starts_with?(body, "## Symphony Auto-Merge Failed")
      assert body =~ "gh pr merge exited 1"
    end

    test "post_auto_merge_failure prepends the marker when the body lacks it (Spec 4 §2.8a)" do
      assert :ok =
               Adapter.post_auto_merge_failure(
                 "9482736152",
                 "branch protection requires reviews"
               )

      assert_received {:graphql, _query, %{"body" => body}}
      assert String.starts_with?(body, "## Symphony Auto-Merge Failed")
      assert body =~ "branch protection"
    end
  end

  describe "e2e harness mutations (SYM-11923096576)" do
    defmodule E2EClient do
      def graphql(query, vars, _opts) do
        send(self_pid(), {:graphql, query, vars})

        cond do
          query =~ "SymphonyCreateItem" ->
            {:ok,
             %{
               "data" => %{
                 "create_item" => %{
                   "id" => "8888888888",
                   "name" => Map.get(vars, "itemName")
                 }
               }
             }}

          query =~ "SymphonyDeleteItem" ->
            {:ok, %{"data" => %{"delete_item" => %{"id" => to_string(Map.get(vars, "itemId"))}}}}

          query =~ "SymphonyBoardItemNames" ->
            {:ok,
             %{
               "data" => %{
                 "boards" => [
                   %{
                     "items_page" => %{
                       "cursor" => nil,
                       "items" => [
                         %{"id" => "111", "name" => "[E2E] create hello.txt at 2026-05-05T00:00:00Z"},
                         %{"id" => "222", "name" => "Untitled item"},
                         %{"id" => "333", "name" => nil}
                       ]
                     }
                   }
                 ]
               }
             }}

          true ->
            {:ok, %{"data" => %{}}}
        end
      end

      defp self_pid, do: Process.get(:test_pid)
    end

    defmodule E2EErrorClient do
      def graphql(_query, _vars, _opts), do: {:error, :rate_limited}
    end

    defmodule E2EBadShapeClient do
      def graphql(_query, _vars, _opts), do: {:ok, %{"data" => %{}}}
    end

    defmodule E2EBoardNotFoundClient do
      def graphql(_query, _vars, _opts), do: {:ok, %{"data" => %{"boards" => []}}}
    end

    setup do
      Process.put(:test_pid, self())
      Application.put_env(:symphony_elixir, :monday_client_module, E2EClient)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :monday_client_module) end)
      :ok
    end

    test "create_item issues a SymphonyCreateItem mutation and returns the new id + name" do
      assert {:ok, %{id: "8888888888", name: "[E2E] hello"}} =
               Adapter.create_item(123_456, "[E2E] hello")

      assert_received {:graphql, query, %{"boardId" => 123_456, "itemName" => "[E2E] hello"}}
      assert query =~ "create_item"
      assert query =~ "create_labels_if_missing: false"
    end

    test "create_item propagates client errors" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EErrorClient)
      assert {:error, :rate_limited} = Adapter.create_item(123_456, "[E2E] hello")
    end

    test "create_item rejects unexpected response shapes" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EBadShapeClient)
      assert {:error, {:unexpected_response, _}} = Adapter.create_item(123_456, "[E2E] hello")
    end

    test "delete_item issues a SymphonyDeleteItem mutation" do
      assert :ok = Adapter.delete_item("8888888888")
      assert_received {:graphql, query, %{"itemId" => 8_888_888_888}}
      assert query =~ "delete_item"
    end

    test "delete_item accepts integer ids without re-parsing them" do
      assert :ok = Adapter.delete_item(8_888_888_888)
      assert_received {:graphql, _query, %{"itemId" => 8_888_888_888}}
    end

    test "delete_item propagates client errors" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EErrorClient)
      assert {:error, :rate_limited} = Adapter.delete_item("8888888888")
    end

    test "list_board_items returns id+name maps and applies the configured limit" do
      assert {:ok, items} = Adapter.list_board_items(123_456, limit: 25)
      assert_received {:graphql, query, %{"boardId" => 123_456, "limit" => 25}}
      assert query =~ "items_page"

      assert items == [
               %{id: "111", name: "[E2E] create hello.txt at 2026-05-05T00:00:00Z"},
               %{id: "222", name: "Untitled item"},
               %{id: "333", name: ""}
             ]
    end

    test "list_board_items defaults to a page size of 50" do
      assert {:ok, _} = Adapter.list_board_items(123_456)
      assert_received {:graphql, _query, %{"limit" => 50}}
    end

    test "list_board_items returns :board_not_found when boards is empty" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EBoardNotFoundClient)
      assert {:error, :board_not_found} = Adapter.list_board_items(999_999)
    end

    test "list_board_items propagates client errors" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EErrorClient)
      assert {:error, :rate_limited} = Adapter.list_board_items(123_456)
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

    test "acquire_heartbeat encodes a Spec M-7 lock token (instance_id::random)" do
      assert :ok = Adapter.acquire_heartbeat()
      assert_received {:graphql, _q1, _}
      assert_received {:graphql, q2, %{"body" => body}}
      assert q2 =~ "create_update"
      # Token line is on its own row, prefix is the instance_id, "::" separator,
      # nonce is hex.
      assert body =~ ~r/\ntoken: test-instance::[0-9a-f]+\n/
    end

    test "successive acquire_heartbeat calls mint distinct tokens (per-renewal nonce)" do
      assert :ok = Adapter.acquire_heartbeat()
      assert_received {:graphql, _q1a, _}
      assert_received {:graphql, _q2a, %{"body" => body_a}}

      assert :ok = Adapter.acquire_heartbeat()
      assert_received {:graphql, _q1b, _}
      assert_received {:graphql, _q2b, %{"body" => body_b}}

      [_, token_a] = Regex.run(~r/\ntoken: (\S+)\n/, body_a)
      [_, token_b] = Regex.run(~r/\ntoken: (\S+)\n/, body_b)

      # Owner prefix matches; nonce differs.
      assert String.starts_with?(token_a, "test-instance::")
      assert String.starts_with?(token_b, "test-instance::")
      refute token_a == token_b
    end

    test "release_heartbeat marks the existing heartbeat as released (or no-op if none)" do
      assert :ok = Adapter.release_heartbeat()
      # No existing heartbeat → no-op (no edit_update mutation)
      assert_received {:graphql, q1, _}
      assert q1 =~ "items"
    end
  end

  describe "heartbeat takeover (Spec M-7 AC2)" do
    defmodule StaleHeartbeatClient do
      def graphql(query, vars, _opts) do
        send(self_pid(), {:graphql, query, vars})

        cond do
          query =~ "items" and query =~ "updates" ->
            stale_ts =
              DateTime.utc_now()
              |> DateTime.add(-10 * 60, :second)
              |> DateTime.to_iso8601()

            body = "## Symphony Heartbeat\ntoken: previous-leader::abc123\ntimestamp: #{stale_ts}\n"

            {:ok,
             %{"data" => %{"items" => [%{"updates" => [%{"id" => "u-stale", "body" => body}]}]}}}

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
      Application.put_env(:symphony_elixir, :monday_client_module, StaleHeartbeatClient)
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

    test "acquire_heartbeat takes over a stale token via edit_update (no conflict)" do
      assert :ok = Adapter.acquire_heartbeat()

      assert_received {:graphql, q_get, _}
      assert q_get =~ "updates"

      assert_received {:graphql, q_edit, %{"id" => "u-stale", "body" => new_body}}
      assert q_edit =~ "edit_update"
      # The takeover writes our token, replacing the stale one.
      assert new_body =~ ~r/\ntoken: test-instance::[0-9a-f]+\n/
      refute new_body =~ "previous-leader::abc123"
    end
  end

  describe "heartbeat token-aware quick restart (Spec M-7 AC2)" do
    defmodule SameOwnerFreshHeartbeatClient do
      def graphql(query, vars, _opts) do
        send(self_pid(), {:graphql, query, vars})

        cond do
          query =~ "items" and query =~ "updates" ->
            fresh_ts = DateTime.utc_now() |> DateTime.to_iso8601()

            body = "## Symphony Heartbeat\ntoken: test-instance::oldnonce\ntimestamp: #{fresh_ts}\n"

            {:ok,
             %{"data" => %{"items" => [%{"updates" => [%{"id" => "u-self", "body" => body}]}]}}}

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
      Application.put_env(:symphony_elixir, :monday_client_module, SameOwnerFreshHeartbeatClient)
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

    test "fresh token from the same instance is treated as ours and refreshed" do
      assert :ok = Adapter.acquire_heartbeat()

      assert_received {:graphql, _q_get, _}
      assert_received {:graphql, q_edit, %{"id" => "u-self", "body" => new_body}}
      assert q_edit =~ "edit_update"
      assert new_body =~ "token: test-instance::"
    end
  end

  describe "heartbeat backward-compat parsing (Spec M-7 AC2)" do
    defmodule LegacyOwnerHeartbeatClient do
      def graphql(query, vars, _opts) do
        send(self_pid(), {:graphql, query, vars})

        cond do
          query =~ "items" and query =~ "updates" ->
            fresh_ts = DateTime.utc_now() |> DateTime.to_iso8601()
            # Pre-M-7 body: only `instance_id:` line, no `token:` line.
            body =
              "## Symphony Heartbeat\n\ninstance_id: legacy-leader\ntimestamp: #{fresh_ts}\n"

            {:ok,
             %{"data" => %{"items" => [%{"updates" => [%{"id" => "u-legacy", "body" => body}]}]}}}

          true ->
            {:ok, %{"data" => %{}}}
        end
      end

      defp self_pid, do: Process.get(:test_pid)
    end

    setup do
      Process.put(:test_pid, self())
      Application.put_env(:symphony_elixir, :monday_client_module, LegacyOwnerHeartbeatClient)
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

    test "fresh pre-M-7 body owned by a different instance still surfaces a conflict" do
      # Owner from `instance_id:` line (no token: line) — must still block us.
      assert {:error, {:lock_held_by_other, "legacy-leader", _ts}} = Adapter.acquire_heartbeat()
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

  describe "e2e CRUD operations" do
    defmodule E2ECrudClient do
      def graphql(query, vars, _opts) do
        send(self_pid(), {:graphql, query, vars})

        cond do
          query =~ "SymphonyCreateItem" ->
            name = Map.get(vars, "itemName", "")
            {:ok, %{"data" => %{"create_item" => %{"id" => "42", "name" => name}}}}

          query =~ "SymphonyDeleteItem" ->
            {:ok, %{"data" => %{"delete_item" => %{"id" => Map.get(vars, "itemId", "0")}}}}

          query =~ "SymphonyBoardItemNames" ->
            {:ok,
             %{
               "data" => %{
                 "boards" => [
                   %{
                     "items_page" => %{
                       "cursor" => nil,
                       "items" => [
                         %{"id" => "100", "name" => "[E2E] synthetic item"},
                         %{"id" => "101", "name" => "Regular item"}
                       ]
                     }
                   }
                 ]
               }
             }}

          true ->
            {:ok, %{"data" => %{}}}
        end
      end

      defp self_pid, do: Process.get(:test_pid)
    end

    defmodule E2EErrorClient do
      def graphql(_query, _vars, _opts) do
        {:error, :auth_failed}
      end
    end

    defmodule E2EUnexpectedClient do
      def graphql(_query, _vars, _opts) do
        {:ok, %{"data" => %{}}}
      end
    end

    defmodule EmptyBoardClient do
      def graphql(_q, _v, _o), do: {:ok, %{"data" => %{"boards" => []}}}
    end

    setup do
      Process.put(:test_pid, self())
      Application.put_env(:symphony_elixir, :monday_client_module, E2ECrudClient)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :monday_client_module) end)
      :ok
    end

    test "create_item sends SymphonyCreateItem mutation with board_id and item_name" do
      assert {:ok, %{id: "42", name: "[E2E] test item"}} =
               Adapter.create_item(99_999, "[E2E] test item")

      assert_received {:graphql, query, vars}
      assert query =~ "SymphonyCreateItem"
      assert vars["boardId"] == 99_999
      assert vars["itemName"] == "[E2E] test item"
    end

    test "create_item returns error tuple on transport failure" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EErrorClient)
      assert {:error, :auth_failed} = Adapter.create_item(99_999, "[E2E] test")
    end

    test "create_item returns unexpected_response on malformed body" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EUnexpectedClient)
      assert {:error, {:unexpected_response, _}} = Adapter.create_item(99_999, "[E2E] test")
    end

    test "delete_item sends SymphonyDeleteItem mutation with item_id" do
      assert :ok = Adapter.delete_item("9999")

      assert_received {:graphql, query, vars}
      assert query =~ "SymphonyDeleteItem"
      assert vars["itemId"] == 9_999
    end

    test "delete_item accepts integer item_id" do
      assert :ok = Adapter.delete_item(9_999)

      assert_received {:graphql, _query, vars}
      assert vars["itemId"] == 9_999
    end

    test "delete_item returns error tuple on transport failure" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EErrorClient)
      assert {:error, :auth_failed} = Adapter.delete_item("9999")
    end

    test "list_board_items returns mapped id/name pairs" do
      assert {:ok, items} = Adapter.list_board_items(99_999)
      assert length(items) == 2

      assert Enum.any?(items, fn item ->
               item.id == "100" and item.name == "[E2E] synthetic item"
             end)

      assert Enum.any?(items, fn item ->
               item.id == "101" and item.name == "Regular item"
             end)
    end

    test "list_board_items sends SymphonyBoardItemNames query with board_id and limit" do
      Adapter.list_board_items(99_999, limit: 75)

      assert_received {:graphql, query, vars}
      assert query =~ "SymphonyBoardItemNames"
      assert vars["boardId"] == 99_999
      assert vars["limit"] == 75
    end

    test "list_board_items defaults limit to 50" do
      Adapter.list_board_items(99_999)

      assert_received {:graphql, _query, vars}
      assert vars["limit"] == 50
    end

    test "list_board_items returns :board_not_found when boards list is empty" do
      Application.put_env(:symphony_elixir, :monday_client_module, EmptyBoardClient)
      assert {:error, :board_not_found} = Adapter.list_board_items(99_999)
    end

    test "list_board_items returns error tuple on transport failure" do
      Application.put_env(:symphony_elixir, :monday_client_module, E2EErrorClient)
      assert {:error, :auth_failed} = Adapter.list_board_items(99_999)
    end
  end
end
