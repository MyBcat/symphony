defmodule SymphonyElixir.E2E.HarnessTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.E2E.Harness

  @prod_board_id 8_173_460_438

  defp base_deps(overrides \\ %{}) do
    test_pid = self()

    %{
      tracker: %{
        list_board_items: fn -> {:ok, []} end,
        create_item: fn name ->
          send(test_pid, {:create_item, name})
          {:ok, %{id: "1234567890", name: name}}
        end,
        upsert_workpad: fn item_id, body ->
          send(test_pid, {:upsert_workpad, item_id, body})
          :ok
        end,
        update_issue_state: fn item_id, state ->
          send(test_pid, {:update_issue_state, item_id, state})
          :ok
        end,
        fetch_issue_state: fn _item_id ->
          {:ok, %{state: "Symphony Ready", pr_url: nil}}
        end,
        delete_item: fn item_id ->
          send(test_pid, {:delete_item, item_id})
          :ok
        end
      },
      symphony_runner: fn _opts ->
        {:ok, %{log_tail: ""}}
      end,
      workspace_remover: fn path ->
        send(test_pid, {:workspace_remover, path})
        :ok
      end,
      pr_closer: fn url ->
        send(test_pid, {:pr_closer, url})
        :ok
      end,
      workspace_branch_exists?: fn _path, _branch -> true end,
      workspace_exists?: fn _path -> true end,
      logger: fn _msg -> :ok end,
      clock: fn -> ~U[2026-05-05 12:00:00Z] end,
      monotonic_now_ms: fn -> 0 end,
      sleeper: fn _ms -> :ok end
    }
    |> deep_merge(overrides)
  end

  defp deep_merge(target, overrides) do
    Enum.reduce(overrides, target, fn
      {k, %{} = v}, acc when not is_struct(v) ->
        Map.put(acc, k, deep_merge(Map.get(acc, k, %{}), v))

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  # Returns a stub `monotonic_now_ms` that advances by `step_ms` every call,
  # starting at 0. The harness uses the first call to compute the deadline,
  # so total available "wall time" inside the test = step_ms * (max_wait_seconds + 1).
  defp deadline_counter(step_ms) do
    counter = :counters.new(1, [])

    fn ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      n * step_ms
    end
  end

  defp base_opts(overrides \\ []) do
    Keyword.merge(
      [
        board_id: 1_234_567_890,
        dry_run: false,
        max_wait_seconds: 5,
        poll_interval_ms: 1,
        non_synthetic_max: 5,
        workspace_root: "/tmp/symphony-workspaces-test",
        synthetic_prefix: "[E2E]",
        identifier_prefix: "SYM",
        symphony_runner_opts: []
      ],
      overrides
    )
  end

  describe "guard_prod_board" do
    test "refuses when board id matches the production board id" do
      result = Harness.run(base_opts(board_id: @prod_board_id), base_deps())

      assert result.status == :failed
      assert result.reason == {:refused, :prod_board}
      assert result.item_id == nil
      refute_received {:create_item, _}
      refute_received {:delete_item, _}
    end

    test "refuses when board id is given as a string equal to the prod id" do
      result = Harness.run(base_opts(board_id: "8173460438"), base_deps())
      assert result.status == :failed
      assert result.reason == {:refused, :prod_board}
    end

    test "refuses an invalid board id format" do
      result = Harness.run(base_opts(board_id: "not-a-number"), base_deps())
      assert result.status == :failed
      assert result.reason == {:refused, :invalid_board_id}
    end
  end

  describe "non-synthetic count guard" do
    test "refuses when more than non_synthetic_max items lack the synthetic prefix" do
      deps =
        base_deps(%{
          tracker: %{
            list_board_items: fn ->
              {:ok,
               [
                 %{id: "1", name: "Real engineering task A"},
                 %{id: "2", name: "Real engineering task B"},
                 %{id: "3", name: "Real engineering task C"},
                 %{id: "4", name: "Real engineering task D"},
                 %{id: "5", name: "Real engineering task E"},
                 %{id: "6", name: "Real engineering task F"},
                 %{id: "7", name: "[E2E] keep this"}
               ]}
            end
          }
        })

      result = Harness.run(base_opts(non_synthetic_max: 5), deps)

      assert result.status == :failed
      assert {:refused, {:too_many_non_synthetic, 6, 5}} = result.reason
      refute_received {:create_item, _}
    end

    test "passes when non-synthetic count is exactly at the threshold" do
      deps =
        base_deps(%{
          tracker: %{
            list_board_items: fn ->
              {:ok,
               [
                 %{id: "1", name: "real A"},
                 %{id: "2", name: "real B"},
                 %{id: "3", name: "real C"},
                 %{id: "4", name: "real D"},
                 %{id: "5", name: "real E"},
                 %{id: "6", name: "[E2E] keep"}
               ]}
            end
          }
        })

      result = Harness.run(base_opts(non_synthetic_max: 5, dry_run: true), deps)

      assert result.status == :dry_run
    end

    test "propagates a list_board_items error as a failure" do
      deps =
        base_deps(%{
          tracker: %{
            list_board_items: fn -> {:error, :rate_limited} end
          }
        })

      result = Harness.run(base_opts(), deps)
      assert result.status == :failed
      assert {:list_board_items_failed, :rate_limited} = result.reason
    end
  end

  describe "dry-run path" do
    test "creates synthetic item, posts description update, sets ready, then cleans up without invoking Symphony" do
      runner_calls = :ets.new(:runner_calls_dryrun, [:public, :duplicate_bag])

      deps =
        base_deps(%{
          symphony_runner: fn opts ->
            :ets.insert(runner_calls, {:called, opts})
            {:ok, %{log_tail: ""}}
          end
        })

      result = Harness.run(base_opts(dry_run: true), deps)

      assert result.status == :dry_run
      assert result.item_id == "1234567890"
      assert result.identifier == "SYM-1234567890"
      assert result.dry_run == true
      assert :ets.tab2list(runner_calls) == []

      assert_received {:create_item, title}
      assert String.starts_with?(title, "[E2E] create hello.txt at ")
      assert_received {:upsert_workpad, "1234567890", body}
      assert body == Harness.description_body()
      assert_received {:update_issue_state, "1234567890", "Symphony Ready"}
      assert_received {:delete_item, "1234567890"}
      assert_received {:workspace_remover, _path}
      refute_received {:pr_closer, _}
    end

    test "still cleans up when delete_item fails on the way out" do
      deps =
        base_deps(%{
          tracker: %{
            delete_item: fn _id -> {:error, :rate_limited} end
          }
        })

      result = Harness.run(base_opts(dry_run: true), deps)

      assert result.status == :dry_run
      assert result.cleanup.delete_item == {:error, :rate_limited}
      assert result.cleanup.workspace == :ok
      assert result.cleanup.pr == :skipped
    end

    test "tolerates a workspace_remover :enoent (path absent)" do
      deps =
        base_deps(%{
          workspace_remover: fn _path -> {:error, :enoent} end
        })

      result = Harness.run(base_opts(dry_run: true), deps)

      assert result.status == :dry_run
      assert result.cleanup.workspace == :ok
    end

    test "logs the dry-run start message" do
      lines = :ets.new(:dryrun_log_lines, [:public, :duplicate_bag])

      deps =
        base_deps(%{
          logger: fn line ->
            :ets.insert(lines, {:line, line})
            :ok
          end
        })

      _ = Harness.run(base_opts(dry_run: true), deps)

      log_lines =
        lines
        |> :ets.tab2list()
        |> Enum.map(fn {_k, line} -> line end)

      assert Enum.any?(log_lines, &String.contains?(&1, "starting"))
      assert Enum.any?(log_lines, &String.contains?(&1, "dry_run=true"))
      assert Enum.any?(log_lines, &String.contains?(&1, "sandbox safety scan passed"))
    end
  end

  describe "full flow with mocked symphony_runner" do
    test "passes when item reaches Human Review with a PR URL and assertions hold" do
      deps =
        base_deps(%{
          symphony_runner: fn _opts ->
            # Block forever — harness's polling loop will shut us down once
            # it observes the desired state.
            Process.sleep(:infinity)
          end,
          tracker: %{
            fetch_issue_state: fn _item_id ->
              {:ok, %{state: "Human Review", pr_url: "https://github.com/MyBcat/symphony/pull/42"}}
            end
          }
        })

      result = Harness.run(base_opts(max_wait_seconds: 30, poll_interval_ms: 1), deps)

      assert result.status == :passed
      assert result.identifier == "SYM-1234567890"
      assert result.pr_url == "https://github.com/MyBcat/symphony/pull/42"
      assert result.final_state == "Human Review"
      assert result.reason == :ok

      # Cleanup happened.
      assert_received {:delete_item, "1234567890"}
      assert_received {:pr_closer, "https://github.com/MyBcat/symphony/pull/42"}
    end

    test "fails when Symphony exits with port_exit_nonzero before item reaches Human Review" do
      runner_done_ref = make_ref()
      parent = self()

      deps =
        base_deps(%{
          symphony_runner: fn _opts ->
            send(parent, {:runner_returning, runner_done_ref})

            {:error, {:port_exit_nonzero, 137}, "stderr: port_exit_nonzero status=137"}
          end,
          tracker: %{
            fetch_issue_state: fn _item_id -> {:ok, %{state: "In Progress", pr_url: nil}} end
          },
          monotonic_now_ms: deadline_counter(2_000)
        })

      result = Harness.run(base_opts(max_wait_seconds: 30, poll_interval_ms: 1), deps)

      # Sanity check: runner did execute.
      assert_received {:runner_returning, ^runner_done_ref}

      assert result.status == :failed

      assert {:assertions_failed, %{runner: runner_reason, assertions: assertions}} = result.reason

      # Either Task.yield caught the runner's error result, or the polling
      # loop hit deadline first. Both are valid failure paths; both surface
      # a failed `:no_port_exit_nonzero` / `:status_human_review` /
      # `:pr_url_written` assertion. `runner_reason` is one of:
      #   * `{:runner_error, {:port_exit_nonzero, 137}}` (yield caught it)
      #   * `:timeout` (polling deadline exceeded first)
      assert runner_reason in [
               {:runner_error, {:port_exit_nonzero, 137}},
               :timeout
             ]

      assert {:status_human_review, false} in assertions
      assert {:pr_url_written, false} in assertions
    end

    test "fails on timeout when item never reaches Human Review" do
      deps =
        base_deps(%{
          symphony_runner: fn _opts -> Process.sleep(:infinity) end,
          tracker: %{
            fetch_issue_state: fn _item_id -> {:ok, %{state: "In Progress", pr_url: nil}} end
          },
          monotonic_now_ms: deadline_counter(1_000)
        })

      result = Harness.run(base_opts(max_wait_seconds: 2, poll_interval_ms: 1), deps)

      assert result.status == :failed
      assert {:assertions_failed, %{runner: :timeout, assertions: assertions}} = result.reason
      assert {:status_human_review, false} in assertions
    end

    test "fails when workspace or branch assertion fails even if PR + status are good" do
      deps =
        base_deps(%{
          symphony_runner: fn _opts -> Process.sleep(:infinity) end,
          tracker: %{
            fetch_issue_state: fn _item_id ->
              {:ok, %{state: "Human Review", pr_url: "https://github.com/x/y/pull/1"}}
            end
          },
          workspace_branch_exists?: fn _path, _branch -> false end,
          workspace_exists?: fn _path -> false end
        })

      result = Harness.run(base_opts(max_wait_seconds: 30, poll_interval_ms: 1), deps)

      assert result.status == :failed
      assert {:assertions_failed, %{assertions: assertions}} = result.reason
      assert {:workspace_exists, false} in assertions
      assert {:agent_branch_created, false} in assertions
    end

    test "still posts description update and sets Symphony Ready before invoking the runner" do
      deps =
        base_deps(%{
          symphony_runner: fn _opts -> Process.sleep(:infinity) end,
          tracker: %{
            fetch_issue_state: fn _ ->
              {:ok, %{state: "Human Review", pr_url: "https://github.com/x/y/pull/1"}}
            end
          }
        })

      _ = Harness.run(base_opts(max_wait_seconds: 30, poll_interval_ms: 1), deps)

      assert_received {:create_item, _}
      assert_received {:upsert_workpad, "1234567890", body}
      assert body == Harness.description_body()
      assert_received {:update_issue_state, "1234567890", "Symphony Ready"}
    end
  end

  describe "create / status / description error paths" do
    test "create_item failure halts before posting description or setting status" do
      deps =
        base_deps(%{
          tracker: %{
            create_item: fn _ -> {:error, :rate_limited} end
          }
        })

      result = Harness.run(base_opts(dry_run: true), deps)

      assert result.status == :failed
      assert {:create_item_failed, :rate_limited} = result.reason
      refute_received {:upsert_workpad, _, _}
      refute_received {:update_issue_state, _, _}
      refute_received {:delete_item, _}
    end

    test "upsert_workpad failure halts before setting status" do
      deps =
        base_deps(%{
          tracker: %{
            upsert_workpad: fn _, _ -> {:error, :ambiguous_workpad} end
          }
        })

      result = Harness.run(base_opts(dry_run: true), deps)
      assert result.status == :failed
      assert {:post_description_failed, :ambiguous_workpad} = result.reason
      refute_received {:update_issue_state, _, _}
    end

    test "set_status failure halts before invoking Symphony" do
      deps =
        base_deps(%{
          tracker: %{
            update_issue_state: fn _, _ -> {:error, :auth_failed} end
          }
        })

      result = Harness.run(base_opts(dry_run: true), deps)
      assert result.status == :failed
      assert {:set_status_failed, :auth_failed} = result.reason
    end
  end

  describe "build_title / synthetic_prefix / prod_board_id helpers" do
    test "build_title embeds an ISO8601 timestamp after the synthetic prefix" do
      title = Harness.build_title(~U[2026-05-05 02:00:00Z], "[E2E]")
      assert String.starts_with?(title, "[E2E] create hello.txt at ")
      assert title =~ "2026-05-05T02:00:00Z"
    end

    test "synthetic_prefix returns the canonical prefix" do
      assert Harness.synthetic_prefix() == "[E2E]"
    end

    test "prod_board_id returns the spec-locked production board id" do
      assert Harness.prod_board_id() == 8_173_460_438
    end
  end
end
