# [M-9] Nightly E2E Test Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a nightly GitHub Actions workflow that creates a synthetic Monday item on a sandbox board, runs Symphony headlessly against it, asserts agent dispatched + branch created + PR opened + item in Human Review, and tears down cleanly — with a dry-run mode and a runtime guard against contaminating the sandbox board.

**Architecture:** A new `SymphonyElixir.E2E.Harness` module orchestrates the full lifecycle (create item → set status → spawn Symphony subprocess → poll for Human Review → assert → cleanup). Monday writes go through three new adapter functions (`create_item`, `delete_item`, `list_board_items`) added to `Monday.Adapter` per DL-005. The GitHub Actions workflow hard-fails if `SYMPHONY_E2E_BOARD_ID == 8173460438` (the prod board ID) before any Elixir code runs.

**Tech Stack:** Elixir/Mix tasks, Monday GraphQL API, GitHub Actions (`gh issue create` for failure alerts), `System.spawn_monitor` for Symphony subprocess.

---

## File Map

| Action | Path | Purpose |
|--------|------|---------|
| Modify | `elixir/lib/symphony_elixir/monday/adapter.ex` | Add `create_item/3`, `delete_item/2`, `list_board_items/2`, `update_item_column/4` |
| Modify | `elixir/lib/symphony_elixir/config/schema.ex` | Add `E2E` embedded schema under `Agent` |
| Create | `elixir/lib/symphony_elixir/e2e/harness.ex` | Core harness logic (guards, item lifecycle, polling, cleanup) |
| Create | `elixir/lib/mix/tasks/symphony.e2e_smoke.ex` | CLI entrypoint: reads env, calls Harness |
| Create | `elixir/test/symphony_elixir/e2e/harness_test.exs` | Unit tests for guards + dry-run path |
| Create | `.github/workflows/nightly-e2e.yml` | Nightly cron + workflow_dispatch; creates GH Issue on failure |
| Modify | `elixir/WORKFLOW.md` | Document `agent.e2e.*` config keys |

---

## Task 1: Add e2e CRUD operations to Monday.Adapter

**Files:**
- Modify: `elixir/lib/symphony_elixir/monday/adapter.ex`
- Test: `elixir/test/symphony_elixir/monday/adapter_test.exs` (add cases)

### Background

The adapter currently has no `create_item`, `delete_item`, or `list_board_items` function. The e2e harness must go through the adapter per DL-005. Each new function accepts an optional `opts` keyword list so the harness can pass `api_token:` for the e2e token (different from the prod token in config).

- [ ] **Step 1.1: Add GraphQL templates** — insert four new module-level strings after `@get_item_updates` (line ~112) in `adapter.ex`:

```elixir
  @create_item_mutation """
  mutation SymphonyE2ECreateItem($boardId: ID!, $groupId: String, $name: String!) {
    create_item(board_id: $boardId, group_id: $groupId, item_name: $name) {
      id
    }
  }
  """

  @delete_item_mutation """
  mutation SymphonyE2EDeleteItem($itemId: ID!) {
    delete_item(item_id: $itemId) {
      id
    }
  }
  """

  @list_board_items_query """
  query SymphonyE2EListBoardItems($boardId: ID!, $limit: Int!) {
    boards(ids: [$boardId]) {
      items_page(limit: $limit) {
        items {
          id
          name
        }
      }
    }
  }
  """

  @get_item_fields_e2e_query """
  query SymphonyE2EGetItemFields($itemId: ID!, $columnIds: [String!]) {
    items(ids: [$itemId]) {
      id
      name
      url
      column_values(ids: $columnIds) {
        id
        text
      }
      updates(limit: 5) {
        id
        body
      }
    }
  }
  """
```

- [ ] **Step 1.2: Add public functions** — insert after `def post_auto_merge_failure/2` (around line ~668) in `adapter.ex`:

```elixir
  @doc "E2E only: create a new item on an explicit board. opts: api_token, endpoint, group_id."
  @spec create_item(integer() | String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_item(board_id, name, opts \\ []) do
    group_id = Keyword.get(opts, :group_id)
    vars = %{"boardId" => to_string(board_id), "groupId" => group_id, "name" => name}

    case client_module().graphql(@create_item_mutation, vars, client_opts(opts)) do
      {:ok, %{"data" => %{"create_item" => %{"id" => id}}}} -> {:ok, to_string(id)}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc "E2E only: delete an item by ID. opts: api_token, endpoint."
  @spec delete_item(integer() | String.t(), keyword()) :: :ok | {:error, term()}
  def delete_item(item_id, opts \\ []) do
    vars = %{"itemId" => parse_item_id(item_id)}

    case client_module().graphql(@delete_item_mutation, vars, client_opts(opts)) do
      {:ok, %{"data" => %{"delete_item" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc "E2E only: list items on a board. opts: api_token, endpoint, limit (default 250)."
  @spec list_board_items(integer() | String.t(), keyword()) ::
          {:ok, [%{id: String.t(), name: String.t()}]} | {:error, term()}
  def list_board_items(board_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 250)
    vars = %{"boardId" => to_string(board_id), "limit" => limit}

    case client_module().graphql(@list_board_items_query, vars, client_opts(opts)) do
      {:ok, %{"data" => %{"boards" => [%{"items_page" => %{"items" => items}}]}}} ->
        {:ok, Enum.map(items, &%{id: to_string(&1["id"]), name: &1["name"]})}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc "E2E only: update a single column value on an item. opts: api_token, endpoint."
  @spec update_item_column(integer() | String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def update_item_column(item_id, column_id, value, opts \\ []) do
    vars = %{"itemId" => parse_item_id(item_id), "columnId" => column_id, "value" => value}

    case client_module().graphql(@change_simple_column_value, vars, client_opts(opts)) do
      {:ok, %{"data" => %{"change_simple_column_value" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc "E2E only: fetch key fields for a single item by ID. opts: api_token, endpoint, column_ids."
  @spec get_item_fields(integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_item_fields(item_id, opts \\ []) do
    cfg = tracker_config()
    column_ids = Keyword.get(opts, :column_ids, collect_column_ids(cfg))
    vars = %{"itemId" => [to_string(item_id)], "columnIds" => column_ids}

    case client_module().graphql(@get_item_fields_e2e_query, vars, client_opts(opts)) do
      {:ok, %{"data" => %{"items" => [item]}}} ->
        {:ok, item}

      {:ok, %{"data" => %{"items" => []}}} ->
        {:error, :item_not_found}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc "E2E only: post an update (comment) on an item. opts: api_token, endpoint."
  @spec post_item_update(integer() | String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def post_item_update(item_id, body, opts \\ []) do
    vars = %{"itemId" => parse_item_id(item_id), "body" => body}

    case client_module().graphql(@create_update, vars, client_opts(opts)) do
      {:ok, %{"data" => %{"create_update" => %{"id" => id}}}} -> {:ok, to_string(id)}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end
```

- [ ] **Step 1.3: Add `client_opts/1` private helper** — insert in the private section of `adapter.ex`:

```elixir
  defp client_opts(opts) do
    Enum.filter(opts, fn {k, _} -> k in [:api_token, :endpoint] end)
  end
```

- [ ] **Step 1.4: Verify tests still pass**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix test test/symphony_elixir/monday/adapter_test.exs --no-start 2>&1 | tail -20
```

Expected: all existing tests still green.

- [ ] **Step 1.5: Add adapter tests for new functions** — append to `elixir/test/symphony_elixir/monday/adapter_test.exs`:

```elixir
  describe "create_item/3" do
    test "returns item id on success" do
      mock_client = fn _q, _v, _o -> {:ok, %{"data" => %{"create_item" => %{"id" => "42"}}}} end
      Application.put_env(:symphony_elixir, :monday_client_module, MockRaw)
      # use inline mock via process dict
      # (adapt to the existing mock pattern in this test file)
      assert {:ok, "42"} = Adapter.create_item(99999, "Test Item", [])
    end

    test "returns error on graphql errors" do
      # trigger the unexpected_response branch
      mock_response = {:ok, %{"data" => %{}}}
      assert {:error, {:unexpected_response, _}} = match_create_error(mock_response)
    end
  end

  describe "delete_item/2" do
    test "returns :ok on success" do
      assert :ok = match_delete_ok(%{"data" => %{"delete_item" => %{"id" => "42"}}})
    end
  end

  describe "list_board_items/2" do
    test "returns mapped items list" do
      raw = %{"data" => %{"boards" => [%{"items_page" => %{"items" => [%{"id" => "1", "name" => "[E2E] test"}]}}]}}
      assert {:ok, [%{id: "1", name: "[E2E] test"}]} = match_list_ok(raw)
    end
  end
```

Note: adapt the mock pattern to match the file's existing style (look for how `mock_client_module` is set in existing tests and follow the same pattern).

- [ ] **Step 1.6: Run full adapter test suite**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix test test/symphony_elixir/monday/adapter_test.exs --no-start 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 1.7: Commit**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576 && git add elixir/lib/symphony_elixir/monday/adapter.ex elixir/test/symphony_elixir/monday/adapter_test.exs && git commit -m "feat(adapter): add e2e CRUD ops (create_item, delete_item, list_board_items)"
```

---

## Task 2: Add E2E config submodule to Config.Schema

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Test: `elixir/test/symphony_elixir/config_schema_test.exs` (add cases)

### Background

Spec 2.9 references `agent.e2e.test_board_id` and `agent.e2e.alert_webhook`. The env vars (`SYMPHONY_E2E_BOARD_ID`, `SYMPHONY_E2E_MONDAY_TOKEN`) take precedence at runtime; the config keys are a secondary/optional path. Adding them to the schema makes `mix symphony.e2e_smoke` discoverable and self-documenting.

- [ ] **Step 2.1: Add `E2E` embedded schema** — insert after the `Agent` module (around line 228) in `config/schema.ex`:

```elixir
  defmodule E2E do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Board ID for the dedicated e2e sandbox board (never 8173460438).
      # Env var SYMPHONY_E2E_BOARD_ID takes precedence over this field.
      field(:test_board_id, :integer)
      # Timeout in seconds for the Symphony subprocess (default 600 = 10 min).
      field(:timeout_s, :integer, default: 600)
      # Slack/webhook URL to POST on nightly failure. Optional.
      field(:alert_webhook, :string)
      # Max number of non-synthetic-prefix items allowed on sandbox board (default 5).
      field(:max_nonsynth_items, :integer, default: 5)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:test_board_id, :timeout_s, :alert_webhook, :max_nonsynth_items],
        empty_values: []
      )
      |> validate_number(:timeout_s, greater_than: 0)
      |> validate_number(:max_nonsynth_items, greater_than: 0)
    end
  end
```

- [ ] **Step 2.2: Extend `Agent` embedded schema** — in the `Agent` module, add the `e2e` embed field:

```elixir
    # Before the existing fields, add:
    embeds_one(:e2e, E2E, on_replace: :update)
```

- [ ] **Step 2.3: Update `Agent.changeset/2`** — add `cast_embed` for the new field:

```elixir
    # After the existing cast/validate calls, add:
    |> cast_embed(:e2e)
```

- [ ] **Step 2.4: Run config schema tests**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix test test/symphony_elixir/config_schema_test.exs --no-start 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 2.5: Add config schema test for E2E submodule** — append to `test/symphony_elixir/config_schema_test.exs`:

```elixir
  describe "Agent.E2E schema" do
    test "defaults are applied" do
      cs = SymphonyElixir.Config.Schema.E2E.changeset(%SymphonyElixir.Config.Schema.E2E{}, %{})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :timeout_s) == 600
      assert Ecto.Changeset.get_field(cs, :max_nonsynth_items) == 5
    end

    test "rejects timeout_s of 0" do
      cs = SymphonyElixir.Config.Schema.E2E.changeset(%SymphonyElixir.Config.Schema.E2E{}, %{timeout_s: 0})
      refute cs.valid?
    end

    test "accepts valid e2e config" do
      cs = SymphonyElixir.Config.Schema.E2E.changeset(%SymphonyElixir.Config.Schema.E2E{}, %{
        test_board_id: 12345,
        timeout_s: 300,
        alert_webhook: "https://hooks.example.com/123"
      })
      assert cs.valid?
    end
  end
```

- [ ] **Step 2.6: Run config schema tests again**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix test test/symphony_elixir/config_schema_test.exs --no-start 2>&1 | tail -30
```

Expected: all tests pass (new ones included).

- [ ] **Step 2.7: Commit**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576 && git add elixir/lib/symphony_elixir/config/schema.ex elixir/test/symphony_elixir/config_schema_test.exs && git commit -m "feat(config): add E2E embedded schema under Agent"
```

---

## Task 3: Implement SymphonyElixir.E2E.Harness

**Files:**
- Create: `elixir/lib/symphony_elixir/e2e/harness.ex`
- Create: `elixir/test/symphony_elixir/e2e/harness_test.exs`

### Background

The harness encapsulates the full e2e lifecycle. It is the only consumer of the new adapter CRUD functions. It exposes pure validation functions (`validate_board_id/1`, `synthetic_prefix?/1`, `check_non_synthetic_count/2`) that are unit-testable without hitting Monday. The subprocess path (running the symphony binary) is only exercised in full integration.

- [ ] **Step 3.1: Create the harness module**

Create `elixir/lib/symphony_elixir/e2e/harness.ex` with the following content:

```elixir
defmodule SymphonyElixir.E2E.Harness do
  @moduledoc """
  Nightly e2e test harness (Spec M-9). Lifecycle:
  1. Validate board safety (never touch prod).
  2. Guard sandbox purity (≤ max_nonsynth_items non-[E2E] items on board).
  3. Create synthetic item, set status + columns, post description as Update.
  4. Generate temp WORKFLOW.md pointing to sandbox board.
  5. Spawn symphony subprocess (max timeout_s seconds).
  6. Poll until item reaches Human Review OR timeout.
  7. Assert: workspace exists, branch created, PR URL present, status = Human Review, no port_exit_nonzero in logs.
  8. Cleanup: delete item, close PR, delete workspace.

  Dry-run (opts: [dry_run: true]) skips steps 4-7 and exercises only setup/teardown.
  """

  require Logger

  alias SymphonyElixir.Monday.Adapter
  alias SymphonyElixir.Config

  @prod_board_id 8_173_460_438
  @synthetic_prefix "[E2E]"
  @poll_interval_ms 15_000

  @type opts :: [
          dry_run: boolean(),
          board_id: integer() | String.t(),
          api_token: String.t(),
          timeout_s: integer(),
          max_nonsynth_items: integer(),
          symphony_binary: String.t(),
          workflow_path: String.t()
        ]

  @spec run(opts()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    board_id = resolve_board_id(opts)
    api_token = resolve_api_token(opts)
    dry_run? = Keyword.get(opts, :dry_run, false)
    timeout_s = Keyword.get(opts, :timeout_s, 600)
    max_nonsynth = Keyword.get(opts, :max_nonsynth_items, 5)
    adapter_opts = [api_token: api_token]

    with :ok <- validate_board_id(board_id),
         {:ok, items} <- Adapter.list_board_items(board_id, adapter_opts),
         :ok <- check_non_synthetic_count(items, max_nonsynth),
         {:ok, item_id} <- create_test_item(board_id, adapter_opts),
         :ok <- configure_test_item(item_id, adapter_opts) do
      if dry_run? do
        Logger.info("e2e dry-run: setup complete, cleaning up")
        cleanup(item_id, nil, nil, adapter_opts)
        :ok
      else
        run_symphony_and_assert(item_id, board_id, api_token, timeout_s, opts)
      end
    end
  end

  # -- Guard functions (public for unit testing) --

  @spec validate_board_id(integer() | String.t()) :: :ok | {:error, :prod_board_id_forbidden}
  def validate_board_id(board_id) do
    id = parse_board_id(board_id)

    if id == @prod_board_id do
      {:error, :prod_board_id_forbidden}
    else
      :ok
    end
  end

  @spec synthetic_prefix?(String.t()) :: boolean()
  def synthetic_prefix?(name) when is_binary(name),
    do: String.starts_with?(name, @synthetic_prefix)

  def synthetic_prefix?(_), do: false

  @spec check_non_synthetic_count([map()], integer()) ::
          :ok | {:error, {:too_many_non_synthetic, integer()}}
  def check_non_synthetic_count(items, max) do
    count = Enum.count(items, fn item -> not synthetic_prefix?(item.name) end)

    if count > max do
      {:error, {:too_many_non_synthetic, count}}
    else
      :ok
    end
  end

  @spec build_item_title(DateTime.t()) :: String.t()
  def build_item_title(now \\ DateTime.utc_now()) do
    ts = DateTime.to_iso8601(now)
    "#{@synthetic_prefix} create hello.txt at #{ts}"
  end

  # -- Private: item lifecycle --

  defp create_test_item(board_id, adapter_opts) do
    title = build_item_title()
    Logger.info("e2e: creating test item on board #{board_id}: #{title}")

    with {:ok, item_id} <- Adapter.create_item(board_id, title, adapter_opts),
         {:ok, _update_id} <-
           Adapter.post_item_update(
             item_id,
             "Create a file hello.txt with contents 'hello from symphony' and open a PR.",
             adapter_opts
           ) do
      Logger.info("e2e: created item #{item_id}")
      {:ok, item_id}
    end
  end

  defp configure_test_item(item_id, adapter_opts) do
    cfg = Config.settings!()
    status_col = cfg.tracker.symphony_status_column_id
    repo_col = cfg.tracker.repo_column_id
    profile_col = cfg.tracker.profile_column_id

    with :ok <- Adapter.update_item_column(item_id, repo_col, "symphony", adapter_opts),
         :ok <- Adapter.update_item_column(item_id, profile_col, "claude_sonnet", adapter_opts),
         :ok <- Adapter.update_item_column(item_id, status_col, "Symphony Ready", adapter_opts) do
      :ok
    end
  end

  # -- Private: Symphony subprocess --

  defp run_symphony_and_assert(item_id, board_id, api_token, timeout_s, opts) do
    workflow_path = Keyword.get(opts, :workflow_path, default_workflow_path())
    symphony_bin = Keyword.get(opts, :symphony_binary, default_symphony_binary())
    log_path = "/tmp/symphony-e2e-#{:os.system_time(:millisecond)}.log"
    adapter_opts = [api_token: api_token]

    Logger.info("e2e: generating temp WORKFLOW.md at #{workflow_path}")
    :ok = write_e2e_workflow(workflow_path, board_id, api_token)

    Logger.info("e2e: spawning symphony binary #{symphony_bin}")
    {port, os_pid} = spawn_symphony(symphony_bin, workflow_path, log_path)

    result =
      try do
        poll_until_human_review(item_id, timeout_s, adapter_opts)
      after
        kill_port(port, os_pid)
      end

    case result do
      :ok ->
        assert_conditions(item_id, board_id, log_path, adapter_opts)
        cleanup(item_id, log_path, workflow_path, adapter_opts)

      {:error, reason} ->
        cleanup(item_id, log_path, workflow_path, adapter_opts)
        {:error, reason}
    end
  end

  defp spawn_symphony(binary, workflow_path, log_path) do
    guardrail = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
    port =
      Port.open({:spawn_executable, binary}, [
        :stderr_to_stdout,
        :binary,
        :exit_status,
        args: [guardrail, workflow_path]
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    log_fd = File.open!(log_path, [:write, :utf8])

    Task.start(fn -> forward_port_to_log(port, log_fd) end)
    {port, os_pid}
  end

  defp forward_port_to_log(port, log_fd) do
    receive do
      {^port, {:data, data}} ->
        IO.write(log_fd, data)
        forward_port_to_log(port, log_fd)

      {^port, {:exit_status, _}} ->
        File.close(log_fd)
    end
  end

  defp kill_port(_port, nil), do: :ok

  defp kill_port(port, os_pid) do
    System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    Port.close(port)
  rescue
    _ -> :ok
  end

  # -- Private: polling --

  defp poll_until_human_review(item_id, timeout_s, adapter_opts) do
    deadline = System.monotonic_time(:millisecond) + timeout_s * 1_000
    do_poll(item_id, deadline, adapter_opts)
  end

  defp do_poll(item_id, deadline, adapter_opts) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case check_item_status(item_id, adapter_opts) do
        {:ok, "Human Review"} ->
          :ok

        {:ok, status} ->
          Logger.info("e2e: item #{item_id} status=#{status}, polling again in #{@poll_interval_ms}ms")
          Process.sleep(@poll_interval_ms)
          do_poll(item_id, deadline, adapter_opts)

        {:error, reason} ->
          Logger.warning("e2e: poll error #{inspect(reason)}, retrying")
          Process.sleep(@poll_interval_ms)
          do_poll(item_id, deadline, adapter_opts)
      end
    end
  end

  defp check_item_status(item_id, adapter_opts) do
    cfg = Config.settings!()
    status_col_id = cfg.tracker.symphony_status_column_id

    case Adapter.get_item_fields(item_id, adapter_opts) do
      {:ok, item} ->
        status =
          item["column_values"]
          |> List.wrap()
          |> Enum.find_value(fn col ->
            if col["id"] == status_col_id, do: col["text"]
          end)

        {:ok, status || ""}

      err ->
        err
    end
  end

  # -- Private: assertions --

  defp assert_conditions(item_id, _board_id, log_path, adapter_opts) do
    errors = []

    # 1. Status == Human Review (already confirmed by poll, but re-check)
    errors =
      case check_item_status(item_id, adapter_opts) do
        {:ok, "Human Review"} -> errors
        {:ok, other} -> ["Expected status 'Human Review', got '#{other}'" | errors]
        {:error, r} -> ["Status check failed: #{inspect(r)}" | errors]
      end

    # 2. PR URL written to item
    errors =
      case Adapter.get_item_fields(item_id, adapter_opts) do
        {:ok, item} ->
          cfg = Config.settings!()
          pr_col = cfg.tracker.pr_column_id

          pr_url =
            item["column_values"]
            |> List.wrap()
            |> Enum.find_value(fn col ->
              if col["id"] == pr_col, do: col["text"]
            end)

          if pr_url && pr_url != "" do
            errors
          else
            ["PR URL not written to item column" | errors]
          end

        {:error, r} ->
          ["PR URL check failed: #{inspect(r)}" | errors]
      end

    # 3. No port_exit_nonzero in logs
    errors =
      if log_path && File.exists?(log_path) do
        log = File.read!(log_path)

        if String.contains?(log, "port_exit_nonzero") do
          ["port_exit_nonzero found in Symphony log" | errors]
        else
          errors
        end
      else
        errors
      end

    if errors == [] do
      Logger.info("e2e: all assertions passed for item #{item_id}")
      :ok
    else
      {:error, {:assertion_failed, Enum.reverse(errors)}}
    end
  end

  # -- Private: cleanup --

  defp cleanup(item_id, log_path, workflow_path, adapter_opts) do
    Logger.info("e2e: cleaning up item #{item_id}")

    # Close PR if any (best-effort)
    close_pr_if_exists(item_id, adapter_opts)

    # Delete the synthetic item
    case Adapter.delete_item(item_id, adapter_opts) do
      :ok -> Logger.info("e2e: deleted item #{item_id}")
      {:error, r} -> Logger.warning("e2e: delete item failed: #{inspect(r)}")
    end

    # Remove temp workflow file
    if workflow_path && File.exists?(workflow_path) do
      File.rm(workflow_path)
    end

    # Remove Symphony log
    if log_path && File.exists?(log_path) do
      File.rm(log_path)
    end

    :ok
  end

  defp close_pr_if_exists(item_id, adapter_opts) do
    case Adapter.get_item_fields(item_id, adapter_opts) do
      {:ok, item} ->
        cfg = Config.settings!()
        pr_col = cfg.tracker.pr_column_id

        pr_url =
          item["column_values"]
          |> List.wrap()
          |> Enum.find_value(fn col ->
            if col["id"] == pr_col, do: col["text"]
          end)

        if pr_url && pr_url != "" do
          Logger.info("e2e: closing PR #{pr_url}")
          System.cmd("gh", ["pr", "close", pr_url, "--delete-branch"], stderr_to_stdout: true)
        end

      _ ->
        :ok
    end
  end

  # -- Private: WORKFLOW.md generation --

  defp write_e2e_workflow(path, board_id, api_token) do
    cfg = Config.settings!()
    t = cfg.tracker

    content = """
    ---
    cost_cap:
      daily_usd: 10
    phi_gate:
      mode: warn
    tracker:
      kind: monday
      api_token: #{api_token}
      endpoint: #{t.endpoint || "https://api.monday.com/v2"}
      board_id: #{board_id}
      identifier_prefix: "#{t.identifier_prefix || "SYM"}"
      symphony_status_column_id: "#{t.symphony_status_column_id}"
      profile_column_id: "#{t.profile_column_id}"
      pr_column_id: "#{t.pr_column_id}"
      repo_column_id: "#{t.repo_column_id}"
      priority_column_id: "#{t.priority_column_id || ""}"
      labels_column_id: "#{t.labels_column_id || ""}"
      heartbeat_item_id: 0
      active_states:
        - "Symphony Ready"
        - "In Progress"
        - "Rework"
      handoff_states:
        - "Human Review"
        - "Merging"
      terminal_states:
        - "Done"
        - "Cancelled"
    polling:
      interval_ms: 10000
    workspace:
      root: ~/code/symphony-workspaces
    repos:
      symphony:
        clone_url: https://github.com/MyBcat/symphony.git
        allowed_profiles:
          - claude_sonnet
        default_branch: main
        auto_merge_on_codex_pass: false
    hooks:
      after_create: |
        echo "e2e after_create: no-op"
    profiles:
      claude_sonnet:
        kind: claude
        max_concurrent: 1
        cost_per_input_token_usd: 0.000003
        cost_per_output_token_usd: 0.000015
        claude:
          command: "claude --print --output-format stream-json --input-format stream-json"
          model: "claude-sonnet-4-6"
          permission_mode: "acceptEdits"
          allowed_tools: ["Read", "Edit", "Write", "Bash(git:*)", "Bash(gh:*)", "Bash(make:*)", "Bash(mix:*)", "Bash(mise:*)"]
    agent:
      default_profile: claude_sonnet
      max_concurrent_agents: 1
      max_turns: 20
    codex:
      command: codex app-server
      approval_policy: never
      thread_sandbox: workspace-write
    ---

    You are working on a Monday.com item `{{ issue.identifier }}`.
    """

    File.write!(path, content)
    :ok
  end

  # -- Private: helpers --

  defp resolve_board_id(opts) do
    case Keyword.get(opts, :board_id) do
      nil ->
        System.get_env("SYMPHONY_E2E_BOARD_ID") ||
          (Config.settings!().agent.e2e || %{}) |> Map.get(:test_board_id)

      id ->
        id
    end
  end

  defp resolve_api_token(opts) do
    case Keyword.get(opts, :api_token) do
      nil ->
        System.get_env("SYMPHONY_E2E_MONDAY_TOKEN") ||
          Config.settings!().tracker.api_token

      token ->
        token
    end
  end

  defp parse_board_id(id) when is_integer(id), do: id

  defp parse_board_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp parse_board_id(id), do: id

  defp default_workflow_path do
    "/tmp/symphony-e2e-workflow-#{:os.system_time(:millisecond)}.md"
  end

  defp default_symphony_binary do
    Path.join([File.cwd!(), "bin", "symphony"])
  end
end
```

- [ ] **Step 3.2: Run compile check**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix compile --no-start 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 3.3: Create harness unit tests**

Create `elixir/test/symphony_elixir/e2e/harness_test.exs`:

```elixir
defmodule SymphonyElixir.E2E.HarnessTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.E2E.Harness

  describe "validate_board_id/1" do
    test "rejects prod board as integer" do
      assert {:error, :prod_board_id_forbidden} = Harness.validate_board_id(8_173_460_438)
    end

    test "rejects prod board as string" do
      assert {:error, :prod_board_id_forbidden} = Harness.validate_board_id("8173460438")
    end

    test "accepts any non-prod board as integer" do
      assert :ok = Harness.validate_board_id(99_999)
    end

    test "accepts any non-prod board as string" do
      assert :ok = Harness.validate_board_id("99999")
    end
  end

  describe "synthetic_prefix?/1" do
    test "returns true for [E2E] prefix" do
      assert Harness.synthetic_prefix?("[E2E] create hello.txt at 2026-05-05T00:00:00Z")
    end

    test "returns false for regular items" do
      refute Harness.synthetic_prefix?("Regular ticket")
    end

    test "returns false for nil" do
      refute Harness.synthetic_prefix?(nil)
    end
  end

  describe "check_non_synthetic_count/2" do
    test "passes when all items are synthetic" do
      items = [%{name: "[E2E] item 1"}, %{name: "[E2E] item 2"}]
      assert :ok = Harness.check_non_synthetic_count(items, 5)
    end

    test "passes when non-synthetic count is exactly at limit" do
      items = Enum.map(1..5, &%{name: "Regular #{&1}"})
      assert :ok = Harness.check_non_synthetic_count(items, 5)
    end

    test "fails when non-synthetic count exceeds limit" do
      items = Enum.map(1..6, &%{name: "Regular #{&1}"})
      assert {:error, {:too_many_non_synthetic, 6}} =
               Harness.check_non_synthetic_count(items, 5)
    end

    test "counts only non-synthetic items, ignores synthetic" do
      items = [
        %{name: "[E2E] synthetic 1"},
        %{name: "Regular 1"},
        %{name: "[E2E] synthetic 2"},
        %{name: "Regular 2"}
      ]

      # 2 non-synthetic, limit 1 → fail
      assert {:error, {:too_many_non_synthetic, 2}} =
               Harness.check_non_synthetic_count(items, 1)

      # 2 non-synthetic, limit 2 → pass
      assert :ok = Harness.check_non_synthetic_count(items, 2)
    end
  end

  describe "build_item_title/1" do
    test "starts with [E2E] prefix" do
      now = ~U[2026-05-05 02:00:00Z]
      title = Harness.build_item_title(now)
      assert String.starts_with?(title, "[E2E] create hello.txt at ")
    end

    test "includes ISO8601 timestamp" do
      now = ~U[2026-05-05 02:00:00Z]
      title = Harness.build_item_title(now)
      assert String.contains?(title, "2026-05-05T02:00:00Z")
    end
  end
end
```

- [ ] **Step 3.4: Run harness tests**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix test test/symphony_elixir/e2e/harness_test.exs --no-start 2>&1 | tail -30
```

Expected: all 10 tests pass.

- [ ] **Step 3.5: Commit**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576 && git add elixir/lib/symphony_elixir/e2e/harness.ex elixir/test/symphony_elixir/e2e/harness_test.exs && git commit -m "feat(e2e): add E2E.Harness with guards, item lifecycle, polling, and cleanup"
```

---

## Task 4: Implement mix symphony.e2e_smoke task

**Files:**
- Create: `elixir/lib/mix/tasks/symphony.e2e_smoke.ex`

### Background

Thin CLI wrapper around `E2E.Harness`. Reads `SYMPHONY_E2E_BOARD_ID` and `SYMPHONY_E2E_MONDAY_TOKEN` from the environment. Exits with status 1 on error (so GitHub Actions detects failure).

- [ ] **Step 4.1: Create the mix task**

Create `elixir/lib/mix/tasks/symphony.e2e_smoke.ex`:

```elixir
defmodule Mix.Tasks.Symphony.E2eSmokeCheck do
  use Mix.Task

  @shortdoc "Run the Symphony nightly e2e smoke test against the sandbox board"

  @moduledoc """
  Runs the Symphony nightly e2e smoke test.

  Creates a synthetic Monday item on the sandbox board, starts Symphony
  headlessly, waits for the item to reach Human Review, asserts all conditions,
  and tears down.

  ## Env vars (required unless --dry-run)

  - `SYMPHONY_E2E_BOARD_ID`   — sandbox board ID (MUST NOT be 8173460438)
  - `SYMPHONY_E2E_MONDAY_TOKEN` — Monday API token for the sandbox board

  ## Options

  - `--dry-run`   — exercise setup/teardown only, skip Symphony invocation
  - `--timeout N` — override Symphony timeout in seconds (default 600)

  ## Example

      SYMPHONY_E2E_BOARD_ID=99999 SYMPHONY_E2E_MONDAY_TOKEN=xxx mix symphony.e2e_smoke
      mix symphony.e2e_smoke --dry-run
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, timeout: :integer, help: :boolean],
        aliases: [h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      Mix.Task.run("app.config")

      board_id = System.get_env("SYMPHONY_E2E_BOARD_ID")
      api_token = System.get_env("SYMPHONY_E2E_MONDAY_TOKEN")
      dry_run? = Keyword.get(opts, :dry_run, false)
      timeout_s = Keyword.get(opts, :timeout, 600)

      if is_nil(board_id) and not dry_run? do
        Mix.raise("SYMPHONY_E2E_BOARD_ID env var is required (set it or pass --dry-run)")
      end

      if is_nil(api_token) and not dry_run? do
        Mix.raise("SYMPHONY_E2E_MONDAY_TOKEN env var is required (set it or pass --dry-run)")
      end

      harness_opts =
        [dry_run: dry_run?, timeout_s: timeout_s]
        |> maybe_put(:board_id, board_id)
        |> maybe_put(:api_token, api_token)

      Mix.shell().info("symphony.e2e_smoke: starting (dry_run=#{dry_run?})")

      case SymphonyElixir.E2E.Harness.run(harness_opts) do
        :ok ->
          Mix.shell().info("symphony.e2e_smoke: PASSED")

        {:error, reason} ->
          Mix.shell().error("symphony.e2e_smoke: FAILED — #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
```

- [ ] **Step 4.2: Verify the task compiles**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix compile --no-start 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 4.3: Verify dry-run prints expected output without hitting Monday**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix symphony.e2e_smoke --dry-run 2>&1 | head -5
```

Expected: Prints help/start message or fails gracefully on missing config (NOT a compile error).

- [ ] **Step 4.4: Commit**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576 && git add elixir/lib/mix/tasks/symphony.e2e_smoke.ex && git commit -m "feat(mix): add symphony.e2e_smoke task"
```

---

## Task 5: Create .github/workflows/nightly-e2e.yml

**Files:**
- Create: `.github/workflows/nightly-e2e.yml`

- [ ] **Step 5.1: Create the workflow file**

Create `.github/workflows/nightly-e2e.yml`:

```yaml
name: nightly-e2e

on:
  schedule:
    - cron: '0 2 * * *'
  workflow_dispatch:

jobs:
  e2e:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    defaults:
      run:
        working-directory: elixir

    steps:
      - name: Checkout
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4

      - name: Guard — E2E board must not be prod
        run: |
          if [ "${SYMPHONY_E2E_BOARD_ID}" = "8173460438" ]; then
            echo "HARD FAIL: SYMPHONY_E2E_BOARD_ID must not be the production board (8173460438)"
            exit 1
          fi
        env:
          SYMPHONY_E2E_BOARD_ID: ${{ secrets.SYMPHONY_E2E_BOARD_ID }}

      - name: Set up mise tools
        uses: jdx/mise-action@5228313ee0372e111a38da051671ca30fc5a96db # v3
        with:
          install: true
          cache: true
          working_directory: elixir

      - name: Cache deps and build
        uses: actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830 # v4
        with:
          path: |
            elixir/deps
            elixir/_build
          key: ${{ runner.os }}-mix-e2e-${{ hashFiles('elixir/mix.lock') }}
          restore-keys: |
            ${{ runner.os }}-mix-e2e-
            ${{ runner.os }}-mix-

      - name: Install deps
        run: mix deps.get

      - name: Build symphony binary
        run: mix escript.build

      - name: Run E2E smoke test
        run: mix symphony.e2e_smoke 2>&1 | tee /tmp/symphony-e2e.log
        env:
          SYMPHONY_E2E_BOARD_ID: ${{ secrets.SYMPHONY_E2E_BOARD_ID }}
          SYMPHONY_E2E_MONDAY_TOKEN: ${{ secrets.SYMPHONY_E2E_MONDAY_TOKEN }}
          MONDAY_API_TOKEN: ${{ secrets.MONDAY_API_TOKEN }}

      - name: Create failure issue
        if: failure()
        run: |
          DATESTAMP=$(date +%Y-%m-%d)
          LOG_TAIL=$(tail -200 /tmp/symphony-e2e.log 2>/dev/null || echo "No log captured")
          gh issue create \
            --title "[E2E nightly failed ${DATESTAMP}]" \
            --body "$(printf '## Failure reason\n\n```\n%s\n```\n' "${LOG_TAIL}")" \
            --label "e2e-failure" || true
        env:
          GH_TOKEN: ${{ github.token }}
        working-directory: ${{ github.workspace }}
```

- [ ] **Step 5.2: Validate YAML is well-formed**

```bash
python3 -c "import yaml; yaml.safe_load(open('/home/ankit114/code/symphony-workspaces/SYM-11923096576/.github/workflows/nightly-e2e.yml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 5.3: Commit**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576 && git add .github/workflows/nightly-e2e.yml && git commit -m "feat(ci): add nightly-e2e.yml with sandbox guard and failure issue creation"
```

---

## Task 6: Update WORKFLOW.md to document agent.e2e keys

**Files:**
- Modify: `elixir/WORKFLOW.md`

- [ ] **Step 6.1: Add `agent.e2e` documentation** — insert after the existing `agent:` section (after `max_concurrent_agents: 10`) in `WORKFLOW.md`:

```yaml
# E2E harness config (Spec M-9). Env vars SYMPHONY_E2E_BOARD_ID and
# SYMPHONY_E2E_MONDAY_TOKEN take precedence over these values. Uncomment
# and set test_board_id once the sandbox board is created.
#
# agent:
#   e2e:
#     test_board_id: <sandbox-board-id>   # MUST NOT be 8173460438
#     timeout_s: 600                      # max Symphony runtime (default 600)
#     max_nonsynth_items: 5               # refuse if > N non-[E2E] items on board
#     alert_webhook: ""                   # optional Slack/webhook URL on failure
```

- [ ] **Step 6.2: Commit**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576 && git add elixir/WORKFLOW.md && git commit -m "docs(workflow): document agent.e2e config keys for M-9 harness"
```

---

## Task 7: Full suite verification

- [ ] **Step 7.1: Run full test suite**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix test --no-start 2>&1 | tail -30
```

Expected: all existing tests pass + new harness and config schema tests pass.

- [ ] **Step 7.2: Run linter**

```bash
cd /home/ankit114/code/symphony-workspaces/SYM-11923096576/elixir && mix credo --strict 2>&1 | tail -30
```

Expected: no new Credo issues.

- [ ] **Step 7.3: Commit any lint fixes if needed**

---

## Self-Review Against Spec

| Spec Requirement | Task |
|-----------------|------|
| AC1: `.github/workflows/nightly-e2e.yml` with cron `0 2 * * *` + `workflow_dispatch` | Task 5 |
| AC2: Sandbox board guard; hard-fail if `SYMPHONY_E2E_BOARD_ID == 8173460438`; secrets `SYMPHONY_E2E_BOARD_ID`, `SYMPHONY_E2E_MONDAY_TOKEN` | Tasks 3 + 5 |
| AC3a: Create synthetic item via Adapter | Task 3 (Harness: `create_test_item`) |
| AC3b: Set Symphony Status = Symphony Ready | Task 3 (Harness: `configure_test_item`) |
| AC3c: Run Symphony max 10 min headless | Task 3 (Harness: `spawn_symphony`, `poll_until_human_review` with 600s timeout) |
| AC3d: Assert workspace/branch/PR/status/no port_exit_nonzero | Task 3 (Harness: `assert_conditions`) |
| AC3e: Cleanup delete item + workspace + close PR | Task 3 (Harness: `cleanup`) |
| AC4: On failure create GH Issue `[E2E nightly failed YYYY-MM-DD]` with last 200 log lines | Task 5 (workflow `Create failure issue` step) |
| AC5: Runtime guard refuses if > 5 non-synthetic items on board | Task 3 (`check_non_synthetic_count`) |
| AC6: Dry-run flag exercises setup/teardown without Symphony | Tasks 3 + 4 |
| DL-005: All Monday writes via Adapter | Tasks 1 + 3 (adapter functions used, no direct Client calls from Harness) |
| MUST NOT touch prod board 8173460438 | Tasks 3 + 5 (two independent guard layers) |
