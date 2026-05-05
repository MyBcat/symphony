defmodule Mix.Tasks.Symphony.E2eNightly do
  @moduledoc """
  Drive the SYM-11923096576 e2e nightly harness against a sandbox Monday board.

  Reads configuration from CLI flags (preferred) or env vars (fallback). The
  task HARD-FAILS before any Monday call when:

    * the resolved sandbox board id matches the production board id
      (`8173460438`); or
    * the resolved sandbox board contains more than `--non-synthetic-max`
      items whose name does not begin with the synthetic prefix.

  ## Usage

      mix symphony.e2e_nightly --dry-run                        # setup/teardown only
      mix symphony.e2e_nightly --board-id 1234567890 --max-wait-seconds 600
      mix symphony.e2e_nightly  # uses SYMPHONY_E2E_* env vars (CI shape)

  Required env (or CLI equivalents):

    * `SYMPHONY_E2E_BOARD_ID`            — sandbox board id (integer)
    * `SYMPHONY_E2E_MONDAY_TOKEN`        — Monday API token for the sandbox
    * `SYMPHONY_E2E_HEARTBEAT_ITEM_ID`   — heartbeat sentinel item on the sandbox board (skipped in --dry-run)
    * `SYMPHONY_E2E_STATUS_COLUMN_ID`    — Symphony Status column id on the sandbox board
    * `SYMPHONY_E2E_WORKFLOW_PATH`       — pre-rendered WORKFLOW.md targeting the sandbox (skipped in --dry-run)

  Optional:

    * `SYMPHONY_E2E_WORKSPACE_ROOT`      — defaults to `~/code/symphony-workspaces`
    * `SYMPHONY_E2E_BINARY`              — defaults to `bin/symphony`
    * `SYMPHONY_E2E_LOG_PATH`            — defaults to a tmp file under `tmp/`
  """

  use Mix.Task

  alias SymphonyElixir.E2E.Harness
  alias SymphonyElixir.E2E.SymphonyRunner
  alias SymphonyElixir.Monday.Adapter

  @shortdoc "Live e2e nightly smoke against a sandbox Monday board"

  @switches [
    dry_run: :boolean,
    max_wait_seconds: :integer,
    poll_interval_ms: :integer,
    board_id: :integer,
    non_synthetic_max: :integer,
    workspace_root: :string,
    workflow_path: :string,
    symphony_binary: :string,
    log_path: :string
  ]

  @prod_board_id 8_173_460_438

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    {:ok, _} = Application.ensure_all_started(:req)

    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches)

    case execute(opts, runtime_deps()) do
      {:ok, %{status: :passed} = result} ->
        report(result)
        :ok

      {:ok, %{status: :dry_run} = result} ->
        report(result)
        :ok

      {:ok, %{status: :failed} = result} ->
        report(result)
        Mix.raise("e2e: harness reported failure: #{inspect(result.reason)}")

      {:error, {:refused, reason}} ->
        Mix.raise("e2e: refused before Monday calls — #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("e2e: aborted — #{inspect(reason)}")
    end
  end

  @doc false
  @spec execute(keyword(), map()) :: {:ok, map()} | {:error, term()}
  def execute(opts, deps) do
    with {:ok, env} <- gather_environment(opts, deps),
         :ok <- guard_prod_board(env.board_id),
         :ok <- maybe_configure_tracker(env, deps),
         :ok <- maybe_set_workflow_path(env, deps) do
      harness_opts = [
        board_id: env.board_id,
        dry_run: env.dry_run?,
        max_wait_seconds: env.max_wait_seconds,
        poll_interval_ms: env.poll_interval_ms,
        non_synthetic_max: env.non_synthetic_max,
        workspace_root: env.workspace_root,
        synthetic_prefix: Harness.synthetic_prefix(),
        identifier_prefix: env.identifier_prefix,
        symphony_runner_opts: [
          binary: env.symphony_binary,
          workflow_path: env.workflow_path,
          log_path: env.log_path
        ]
      ]

      harness_deps = build_harness_deps(env, deps)
      {:ok, deps.harness_run.(harness_opts, harness_deps)}
    end
  end

  defp gather_environment(opts, deps) do
    env_get = deps.env_get
    dry_run? = Keyword.get(opts, :dry_run, false)

    with {:ok, board_id} <- resolve_board_id(opts, env_get),
         {:ok, token} <- resolve_monday_token(opts, env_get, dry_run?) do
      env = %{
        board_id: board_id,
        monday_token: token,
        dry_run?: dry_run?,
        max_wait_seconds: Keyword.get(opts, :max_wait_seconds, 600),
        poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 5_000),
        non_synthetic_max: Keyword.get(opts, :non_synthetic_max, 5),
        workspace_root:
          opts
          |> Keyword.get(:workspace_root, env_get.("SYMPHONY_E2E_WORKSPACE_ROOT"))
          |> default_workspace_root(),
        workflow_path:
          opts
          |> Keyword.get(:workflow_path, env_get.("SYMPHONY_E2E_WORKFLOW_PATH")),
        symphony_binary:
          opts
          |> Keyword.get(:symphony_binary, env_get.("SYMPHONY_E2E_BINARY"))
          |> default_symphony_binary(),
        log_path:
          opts
          |> Keyword.get(:log_path, env_get.("SYMPHONY_E2E_LOG_PATH"))
          |> default_log_path(deps),
        identifier_prefix: env_get.("SYMPHONY_E2E_IDENTIFIER_PREFIX") || "SYM",
        status_column_id: env_get.("SYMPHONY_E2E_STATUS_COLUMN_ID") || "color_mm30c3vb",
        pr_column_id: env_get.("SYMPHONY_E2E_PR_COLUMN_ID") || "link_mm30ak49",
        heartbeat_item_id: env_get.("SYMPHONY_E2E_HEARTBEAT_ITEM_ID")
      }

      {:ok, env}
    end
  end

  defp resolve_board_id(opts, env_get) do
    case Keyword.get(opts, :board_id) || env_get.("SYMPHONY_E2E_BOARD_ID") do
      nil ->
        {:error, {:missing_required, "SYMPHONY_E2E_BOARD_ID"}}

      n when is_integer(n) ->
        {:ok, n}

      bin when is_binary(bin) ->
        case Integer.parse(bin) do
          {n, ""} -> {:ok, n}
          _ -> {:error, {:invalid_board_id, bin}}
        end
    end
  end

  defp resolve_monday_token(_opts, env_get, dry_run?) do
    case env_get.("SYMPHONY_E2E_MONDAY_TOKEN") || env_get.("MONDAY_API_TOKEN") do
      nil when dry_run? ->
        {:ok, "DRY_RUN_TOKEN_PLACEHOLDER"}

      nil ->
        {:error, {:missing_required, "SYMPHONY_E2E_MONDAY_TOKEN"}}

      "" when dry_run? ->
        {:ok, "DRY_RUN_TOKEN_PLACEHOLDER"}

      "" ->
        {:error, {:missing_required, "SYMPHONY_E2E_MONDAY_TOKEN"}}

      token ->
        {:ok, token}
    end
  end

  defp default_workspace_root(nil), do: Path.expand("~/code/symphony-workspaces")
  defp default_workspace_root(""), do: Path.expand("~/code/symphony-workspaces")
  defp default_workspace_root(path), do: Path.expand(path)

  defp default_symphony_binary(nil), do: "bin/symphony"
  defp default_symphony_binary(""), do: "bin/symphony"
  defp default_symphony_binary(path), do: path

  defp default_log_path(nil, deps), do: Path.join(deps.tmp_dir.(), "symphony.e2e.log")
  defp default_log_path("", deps), do: Path.join(deps.tmp_dir.(), "symphony.e2e.log")
  defp default_log_path(path, _deps), do: path

  defp guard_prod_board(@prod_board_id), do: {:error, {:refused, :prod_board}}
  defp guard_prod_board(_), do: :ok

  defp maybe_configure_tracker(env, deps) do
    config = %{
      tracker: %{
        kind: "monday",
        api_token: env.monday_token,
        endpoint: "https://api.monday.com/v2",
        board_id: env.board_id,
        identifier_prefix: env.identifier_prefix,
        symphony_status_column_id: env.status_column_id,
        priority_column_id: nil,
        description_column_id: nil,
        branch_column_id: nil,
        labels_column_id: nil,
        profile_column_id: nil,
        repo_column_id: nil,
        pr_column_id: env.pr_column_id,
        active_states: ["Symphony Ready", "In Progress", "Rework"],
        handoff_states: ["Human Review", "Merging"],
        terminal_states: ["Done", "Cancelled"],
        heartbeat_item_id: env.heartbeat_item_id,
        heartbeat_ttl_ms: 60_000
      }
    }

    deps.put_env.(:symphony_elixir, :test_config_override, config)
    :ok
  end

  defp maybe_set_workflow_path(%{dry_run?: true}, _deps), do: :ok

  defp maybe_set_workflow_path(%{workflow_path: nil}, _deps),
    do: {:error, {:missing_required, "SYMPHONY_E2E_WORKFLOW_PATH"}}

  defp maybe_set_workflow_path(%{workflow_path: path}, deps) do
    if deps.file_regular?.(path) do
      :ok
    else
      {:error, {:workflow_file_not_found, path}}
    end
  end

  defp build_harness_deps(env, deps) do
    tracker_module = deps.tracker_module
    log_path = env.log_path
    binary = env.symphony_binary

    %{
      tracker: %{
        list_board_items: fn -> tracker_module.list_board_items(env.board_id, limit: 200) end,
        create_item: fn name -> tracker_module.create_item(env.board_id, name) end,
        upsert_workpad: fn item_id, body -> tracker_module.upsert_workpad(item_id, body) end,
        update_issue_state: fn item_id, state ->
          tracker_module.update_issue_state(item_id, state)
        end,
        fetch_issue_state: fn item_id ->
          case tracker_module.fetch_issue_states_by_ids([item_id]) do
            {:ok, [issue]} ->
              {:ok,
               %{
                 state: Map.get(issue, :state) || Map.get(issue, "state"),
                 pr_url: Map.get(issue, :pr_url) || Map.get(issue, "pr_url")
               }}

            {:ok, []} ->
              {:error, :item_not_found}

            {:error, _} = err ->
              err
          end
        end,
        delete_item: fn item_id -> tracker_module.delete_item(item_id) end
      },
      symphony_runner: build_symphony_runner(deps, binary, log_path, env.workflow_path),
      workspace_remover: deps.workspace_remover,
      pr_closer: deps.pr_closer,
      workspace_branch_exists?: deps.workspace_branch_exists?,
      workspace_exists?: deps.workspace_exists?,
      logger: deps.logger,
      clock: deps.clock,
      monotonic_now_ms: deps.monotonic_now_ms,
      sleeper: deps.sleeper
    }
  end

  defp build_symphony_runner(_deps, _binary, _log_path, nil) do
    fn _opts ->
      {:error, :no_workflow_path, ""}
    end
  end

  defp build_symphony_runner(deps, binary, log_path, _workflow_path) do
    fn opts ->
      deps.symphony_subprocess.(binary: binary, log_path: log_path, opts: opts)
    end
  end

  defp report(result) do
    Mix.shell().info("e2e: status=#{result.status} item_id=#{inspect(result.item_id)} reason=#{inspect(result.reason)}")

    if Map.get(result, :pr_url),
      do: Mix.shell().info("e2e: pr_url=#{result.pr_url}")

    if Map.get(result, :final_state),
      do: Mix.shell().info("e2e: final_state=#{result.final_state}")

    if Map.get(result, :cleanup),
      do: Mix.shell().info("e2e: cleanup=#{inspect(result.cleanup)}")
  end

  @doc false
  @spec runtime_deps() :: map()
  def runtime_deps do
    %{
      env_get: &System.get_env/1,
      put_env: &Application.put_env/3,
      file_regular?: &File.regular?/1,
      tmp_dir: fn -> System.tmp_dir!() end,
      tracker_module: Adapter,
      workspace_remover: fn path ->
        case File.rm_rf(path) do
          {:ok, _} -> :ok
          {:error, reason, _} -> {:error, reason}
        end
      end,
      pr_closer: fn url ->
        case System.cmd("gh", ["pr", "close", url], stderr_to_stdout: true) do
          {_out, 0} -> :ok
          {out, code} -> {:error, {:gh_close_failed, code, out}}
        end
      end,
      workspace_branch_exists?: fn workspace_path, branch ->
        case System.cmd("git", ["-C", workspace_path, "branch", "--list", branch], stderr_to_stdout: true) do
          {output, 0} -> output |> String.trim() |> String.contains?(branch)
          _ -> false
        end
      end,
      workspace_exists?: &File.dir?/1,
      logger: &Mix.shell().info/1,
      clock: &DateTime.utc_now/0,
      monotonic_now_ms: fn -> System.monotonic_time(:millisecond) end,
      sleeper: &Process.sleep/1,
      symphony_subprocess: &SymphonyRunner.spawn/1,
      harness_run: &Harness.run/2
    }
  end
end
