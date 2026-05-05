defmodule Mix.Tasks.Symphony.E2eNightlyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Symphony.E2eNightly

  defp stub_deps(overrides \\ %{}) do
    test_pid = self()

    base = %{
      env_get: fn _name -> nil end,
      put_env: fn app, key, value ->
        send(test_pid, {:put_env, app, key, value})
        :ok
      end,
      file_regular?: fn _path -> true end,
      tmp_dir: fn -> "/tmp" end,
      tracker_module: __MODULE__.FakeTracker,
      workspace_remover: fn _path -> :ok end,
      pr_closer: fn _url -> :ok end,
      workspace_branch_exists?: fn _path, _branch -> true end,
      workspace_exists?: fn _path -> true end,
      logger: fn _msg -> :ok end,
      clock: fn -> ~U[2026-05-05 12:00:00Z] end,
      monotonic_now_ms: fn -> 0 end,
      sleeper: fn _ms -> :ok end,
      symphony_subprocess: fn _opts ->
        send(test_pid, :symphony_subprocess_called)
        {:ok, %{log_tail: ""}}
      end,
      harness_run: fn opts, deps ->
        send(test_pid, {:harness_run, opts, deps})

        %{
          status: :dry_run,
          item_id: "1234567890",
          identifier: "SYM-1234567890",
          reason: :dry_run_complete,
          pr_url: nil,
          final_state: nil,
          log_tail: "",
          cleanup: %{delete_item: :ok, workspace: :ok, pr: :skipped},
          dry_run: true
        }
      end
    }

    Map.merge(base, overrides)
  end

  defmodule FakeTracker do
    def list_board_items(_board_id, _opts), do: {:ok, []}
    def create_item(_board_id, _name), do: {:ok, %{id: "1", name: "ok"}}
    def upsert_workpad(_id, _body), do: :ok
    def update_issue_state(_id, _state), do: :ok
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}
    def delete_item(_id), do: :ok
  end

  describe "execute/2" do
    test "halts before any Monday call when board id matches the prod board id" do
      deps = stub_deps()

      assert {:error, {:refused, :prod_board}} =
               E2eNightly.execute(
                 [board_id: 8_173_460_438, dry_run: true, workspace_root: "/tmp"],
                 deps
               )

      refute_received {:harness_run, _, _}
    end

    test "halts before any Monday call when board id env var equals prod" do
      deps =
        stub_deps(%{
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "8173460438"
            _ -> nil
          end
        })

      assert {:error, {:refused, :prod_board}} = E2eNightly.execute([dry_run: true], deps)

      refute_received {:harness_run, _, _}
    end

    test "errors with :missing_required when SYMPHONY_E2E_BOARD_ID is unset" do
      deps = stub_deps()
      assert {:error, {:missing_required, "SYMPHONY_E2E_BOARD_ID"}} =
               E2eNightly.execute([dry_run: true], deps)
    end

    test "errors with :invalid_board_id on a malformed board id string" do
      deps =
        stub_deps(%{
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "not-a-number"
            _ -> nil
          end
        })

      assert {:error, {:invalid_board_id, "not-a-number"}} =
               E2eNightly.execute([dry_run: true], deps)
    end

    test "errors when monday token is missing on a non-dry-run" do
      deps =
        stub_deps(%{
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "1234567890"
            "SYMPHONY_E2E_WORKFLOW_PATH" -> "/tmp/WORKFLOW.e2e.md"
            _ -> nil
          end
        })

      assert {:error, {:missing_required, "SYMPHONY_E2E_MONDAY_TOKEN"}} =
               E2eNightly.execute([], deps)
    end

    test "tolerates a missing monday token in dry-run mode (uses placeholder)" do
      deps = stub_deps(%{env_get: fn "SYMPHONY_E2E_BOARD_ID" -> "1234567890"; _ -> nil end})

      assert {:ok, %{status: :dry_run}} = E2eNightly.execute([dry_run: true], deps)
      assert_received {:put_env, :symphony_elixir, :test_config_override, _config}
      assert_received {:harness_run, _opts, _deps}
    end

    test "errors with :workflow_file_not_found when workflow path is missing on a real run" do
      deps =
        stub_deps(%{
          file_regular?: fn _ -> false end,
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "1234567890"
            "SYMPHONY_E2E_MONDAY_TOKEN" -> "tok"
            "SYMPHONY_E2E_WORKFLOW_PATH" -> "/nonexistent/WORKFLOW.e2e.md"
            _ -> nil
          end
        })

      assert {:error, {:workflow_file_not_found, "/nonexistent/WORKFLOW.e2e.md"}} =
               E2eNightly.execute([], deps)
    end

    test "errors when workflow path env var is missing on a non-dry-run" do
      deps =
        stub_deps(%{
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "1234567890"
            "SYMPHONY_E2E_MONDAY_TOKEN" -> "tok"
            _ -> nil
          end
        })

      assert {:error, {:missing_required, "SYMPHONY_E2E_WORKFLOW_PATH"}} =
               E2eNightly.execute([], deps)
    end

    test "writes test_config_override and forwards harness opts on a sandbox dry-run" do
      deps =
        stub_deps(%{
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "1234567890"
            "SYMPHONY_E2E_MONDAY_TOKEN" -> "tok-xyz"
            "SYMPHONY_E2E_HEARTBEAT_ITEM_ID" -> "999"
            _ -> nil
          end
        })

      assert {:ok, %{status: :dry_run}} = E2eNightly.execute([dry_run: true], deps)

      assert_received {:put_env, :symphony_elixir, :test_config_override, config}
      assert config.tracker.board_id == 1_234_567_890
      assert config.tracker.api_token == "tok-xyz"
      assert config.tracker.heartbeat_item_id == "999"
      assert config.tracker.identifier_prefix == "SYM"
      assert "Symphony Ready" in config.tracker.active_states

      assert_received {:harness_run, harness_opts, _harness_deps}
      assert harness_opts[:board_id] == 1_234_567_890
      assert harness_opts[:dry_run] == true
      assert harness_opts[:non_synthetic_max] == 5
      assert harness_opts[:synthetic_prefix] == "[E2E]"
    end

    test "passes through CLI overrides above env vars" do
      deps =
        stub_deps(%{
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "9999999999"
            _ -> nil
          end
        })

      assert {:ok, %{status: :dry_run}} =
               E2eNightly.execute(
                 [board_id: 1_234_567_890, dry_run: true, max_wait_seconds: 30],
                 deps
               )

      assert_received {:harness_run, harness_opts, _deps}
      assert harness_opts[:board_id] == 1_234_567_890
      assert harness_opts[:max_wait_seconds] == 30
    end

    test "build_harness_deps wires fetch_issue_state to the configured tracker module" do
      defmodule InspectableTracker do
        def list_board_items(_, _), do: {:ok, []}
        def create_item(_, name), do: {:ok, %{id: "999", name: name}}
        def upsert_workpad(_, _), do: :ok
        def update_issue_state(_, _), do: :ok

        def fetch_issue_states_by_ids(["999"]) do
          {:ok, [%{state: "Human Review", pr_url: "https://example.com/pr/1"}]}
        end

        def fetch_issue_states_by_ids(_), do: {:ok, []}

        def delete_item(_), do: :ok
      end

      parent = self()

      deps =
        stub_deps(%{
          tracker_module: InspectableTracker,
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "1234567890"
            "SYMPHONY_E2E_MONDAY_TOKEN" -> "tok"
            _ -> nil
          end,
          harness_run: fn _opts, harness_deps ->
            result = harness_deps.tracker.fetch_issue_state.("999")
            send(parent, {:fetch_issue_state_result, result})

            %{
              status: :dry_run,
              item_id: "999",
              identifier: "SYM-999",
              reason: :dry_run_complete,
              pr_url: nil,
              final_state: nil,
              log_tail: "",
              cleanup: %{delete_item: :ok, workspace: :ok, pr: :skipped},
              dry_run: true
            }
          end
        })

      assert {:ok, _} = E2eNightly.execute([dry_run: true], deps)

      assert_received {:fetch_issue_state_result,
                       {:ok, %{state: "Human Review", pr_url: "https://example.com/pr/1"}}}
    end

    test "fetch_issue_state surfaces :item_not_found when the tracker returns no rows" do
      defmodule MissingItemTracker do
        def list_board_items(_, _), do: {:ok, []}
        def create_item(_, name), do: {:ok, %{id: "1", name: name}}
        def upsert_workpad(_, _), do: :ok
        def update_issue_state(_, _), do: :ok
        def fetch_issue_states_by_ids(_), do: {:ok, []}
        def delete_item(_), do: :ok
      end

      parent = self()

      deps =
        stub_deps(%{
          tracker_module: MissingItemTracker,
          env_get: fn
            "SYMPHONY_E2E_BOARD_ID" -> "1234567890"
            "SYMPHONY_E2E_MONDAY_TOKEN" -> "tok"
            _ -> nil
          end,
          harness_run: fn _opts, harness_deps ->
            result = harness_deps.tracker.fetch_issue_state.("1")
            send(parent, {:fetch_issue_state_result, result})

            %{
              status: :dry_run,
              item_id: "1",
              identifier: "SYM-1",
              reason: :dry_run_complete,
              pr_url: nil,
              final_state: nil,
              log_tail: "",
              cleanup: %{delete_item: :ok, workspace: :ok, pr: :skipped},
              dry_run: true
            }
          end
        })

      assert {:ok, _} = E2eNightly.execute([dry_run: true], deps)
      assert_received {:fetch_issue_state_result, {:error, :item_not_found}}
    end
  end
end
