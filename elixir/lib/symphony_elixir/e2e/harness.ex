defmodule SymphonyElixir.E2E.Harness do
  @moduledoc """
  Live end-to-end smoke harness (SYM-11923096576 / Spec 4 §2.9 / DL-008).

  Creates a synthetic Monday item on a sandbox board, drives it to
  `Symphony Ready`, runs Symphony in headless mode for up to a configured
  budget, asserts the item progresses to `Human Review` with a PR URL written,
  and tears the synthetic item + workspace + PR back down.

  Constraints honored:

    * The harness HARD-FAILS if the configured board id matches the
      production board id (`8173460438`). Spec AC2.
    * The harness HARD-FAILS if the sandbox board contains more than
      `non_synthetic_max` items whose name does NOT begin with the synthetic
      prefix (default `"[E2E]"`). Spec AC5.
    * All Monday writes go through the configured `tracker` module
      (defaults to `SymphonyElixir.Monday.Adapter`). DL-005.
    * `dry_run: true` exercises setup + teardown without invoking Symphony.
      Spec AC6.

  The module is pure orchestration with dependency injection so unit tests can
  exercise every branch without hitting Monday or spawning Symphony. The Mix
  task wrapper (`Mix.Tasks.Symphony.E2eNightly`) wires up the real
  implementations.
  """

  @prod_board_id 8_173_460_438
  @synthetic_prefix "[E2E]"
  @non_synthetic_max 5
  @default_max_wait_seconds 600
  @default_poll_interval_ms 5_000
  @description_body "Create a file hello.txt with contents 'hello from symphony' and open a PR."

  @type result :: %{
          required(:status) => :passed | :dry_run | :failed,
          required(:item_id) => String.t() | nil,
          required(:identifier) => String.t() | nil,
          required(:reason) => term(),
          optional(:pr_url) => String.t() | nil,
          optional(:final_state) => String.t() | nil,
          optional(:log_tail) => String.t()
        }

  @type tracker_call_set :: %{
          required(:list_board_items) => (-> {:ok, [%{id: String.t(), name: String.t()}]} | {:error, term()}),
          required(:create_item) => (String.t() -> {:ok, %{id: String.t()}} | {:error, term()}),
          required(:upsert_workpad) => (String.t(), String.t() -> :ok | {:error, term()}),
          required(:update_issue_state) => (String.t(), String.t() -> :ok | {:error, term()}),
          required(:fetch_issue_state) => (String.t() -> {:ok, %{state: String.t(), pr_url: String.t() | nil}} | {:error, term()}),
          required(:delete_item) => (String.t() -> :ok | {:error, term()})
        }

  @type deps :: %{
          required(:tracker) => tracker_call_set(),
          required(:symphony_runner) => (keyword() -> {:ok, %{log_tail: String.t()}} | {:error, term(), String.t()}),
          required(:workspace_remover) => (String.t() -> :ok | {:error, term()}),
          required(:pr_closer) => (String.t() -> :ok | {:error, term()}),
          required(:workspace_branch_exists?) => (String.t(), String.t() -> boolean()),
          required(:workspace_exists?) => (String.t() -> boolean()),
          required(:logger) => (String.t() -> :ok),
          required(:clock) => (-> DateTime.t()),
          required(:monotonic_now_ms) => (-> integer()),
          required(:sleeper) => (non_neg_integer() -> :ok)
        }

  @type opts :: [
          board_id: integer() | String.t(),
          dry_run: boolean(),
          max_wait_seconds: pos_integer(),
          poll_interval_ms: pos_integer(),
          synthetic_prefix: String.t(),
          non_synthetic_max: non_neg_integer(),
          identifier_prefix: String.t(),
          workspace_root: String.t(),
          symphony_runner_opts: keyword()
        ]

  @spec run(opts(), deps()) :: result()
  def run(opts, deps) do
    board_id = Keyword.fetch!(opts, :board_id)
    identifier_prefix = Keyword.get(opts, :identifier_prefix, "SYM")
    synthetic_prefix = Keyword.get(opts, :synthetic_prefix, @synthetic_prefix)
    non_synthetic_max = Keyword.get(opts, :non_synthetic_max, @non_synthetic_max)
    dry_run? = Keyword.get(opts, :dry_run, false)
    max_wait_seconds = Keyword.get(opts, :max_wait_seconds, @default_max_wait_seconds)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    runner_opts = Keyword.get(opts, :symphony_runner_opts, [])

    log = deps.logger
    log.("e2e: starting board_id=#{inspect(board_id)} dry_run=#{dry_run?}")

    with :ok <- guard_prod_board(board_id),
         :ok <- guard_non_synthetic_count(deps, synthetic_prefix, non_synthetic_max, log),
         {:ok, item} <- create_synthetic(deps, synthetic_prefix, log) do
      identifier = "#{identifier_prefix}-#{item.id}"

      # M-9 cleanup correctness: once `item` is bound the synthetic item exists
      # on Monday. Any subsequent failure (post_description, set_ready,
      # run_symphony_and_assert) MUST still call finalize so the item is
      # deleted and its workspace is torn down. Without this, partial-setup
      # failures leak synthetic items on the sandbox board.
      try do
        with :ok <- post_description(deps, item, log),
             :ok <- set_ready(deps, item, log) do
          if dry_run? do
            finalize(deps, item, identifier,
              dry_run?: true,
              status: :dry_run,
              reason: :dry_run_complete,
              workspace_root: workspace_root,
              pr_url: nil
            )
          else
            run_symphony_and_assert(deps, item, identifier, %{
              max_wait_seconds: max_wait_seconds,
              poll_interval_ms: poll_interval_ms,
              workspace_root: workspace_root,
              runner_opts: runner_opts,
              log: log
            })
          end
        else
          {:error, reason} ->
            log.("e2e: setup failed after item create reason=#{inspect(reason)}; cleaning up")

            finalize(deps, item, identifier,
              dry_run?: dry_run?,
              status: :failed,
              reason: reason,
              workspace_root: workspace_root,
              pr_url: nil
            )

            %{status: :failed, item_id: item.id, identifier: identifier, reason: reason}
        end
      rescue
        exception ->
          log.("e2e: exception after item create #{inspect(exception)}; cleaning up")

          finalize(deps, item, identifier,
            dry_run?: dry_run?,
            status: :failed,
            reason: {:exception, Exception.message(exception)},
            workspace_root: workspace_root,
            pr_url: nil
          )

          reraise exception, __STACKTRACE__
      end
    else
      {:error, reason} ->
        log.("e2e: setup failed reason=#{inspect(reason)}")
        %{status: :failed, item_id: nil, identifier: nil, reason: reason}
    end
  end

  @doc """
  Returns the title used for the synthetic item given the current clock value.
  Pure helper; exposed for tests.
  """
  @spec build_title(DateTime.t(), String.t()) :: String.t()
  def build_title(%DateTime{} = now, prefix) do
    iso = DateTime.to_iso8601(now)
    "#{prefix} create hello.txt at #{iso}"
  end

  @doc """
  Returns the description body posted as a Monday Update on the synthetic item.
  Pure helper; exposed for tests.
  """
  @spec description_body() :: String.t()
  def description_body, do: @description_body

  @doc """
  Returns the synthetic prefix used to identify harness-owned items.
  """
  @spec synthetic_prefix() :: String.t()
  def synthetic_prefix, do: @synthetic_prefix

  @doc """
  Returns the production Monday board id the harness refuses to touch.
  """
  @spec prod_board_id() :: integer()
  def prod_board_id, do: @prod_board_id

  defp guard_prod_board(board_id) do
    case normalize_board_id(board_id) do
      {:ok, @prod_board_id} -> {:error, {:refused, :prod_board}}
      {:ok, _} -> :ok
      :error -> {:error, {:refused, :invalid_board_id}}
    end
  end

  defp normalize_board_id(id) when is_integer(id), do: {:ok, id}

  defp normalize_board_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp normalize_board_id(_), do: :error

  defp guard_non_synthetic_count(deps, synthetic_prefix, max_allowed, log) do
    case deps.tracker.list_board_items.() do
      {:ok, items} ->
        non_synthetic =
          Enum.reject(items, fn %{name: name} ->
            is_binary(name) and String.starts_with?(name, synthetic_prefix)
          end)

        count = length(non_synthetic)

        if count > max_allowed do
          log.(
            "e2e: refusing to run; sandbox board has #{count} non-synthetic items " <>
              "(max=#{max_allowed}, prefix=#{inspect(synthetic_prefix)})"
          )

          {:error, {:refused, {:too_many_non_synthetic, count, max_allowed}}}
        else
          log.("e2e: sandbox safety scan passed (#{count} non-synthetic, max=#{max_allowed})")
          :ok
        end

      {:error, reason} ->
        {:error, {:list_board_items_failed, reason}}
    end
  end

  defp create_synthetic(deps, synthetic_prefix, log) do
    title = build_title(deps.clock.(), synthetic_prefix)

    case deps.tracker.create_item.(title) do
      {:ok, %{id: id} = item} when is_binary(id) ->
        log.("e2e: created synthetic item id=#{id} title=#{inspect(title)}")
        {:ok, item}

      {:error, reason} ->
        {:error, {:create_item_failed, reason}}

      other ->
        {:error, {:create_item_failed, {:unexpected_response, other}}}
    end
  end

  defp post_description(deps, item, log) do
    case deps.tracker.upsert_workpad.(item.id, @description_body) do
      :ok ->
        log.("e2e: posted description body to item id=#{item.id}")
        :ok

      {:error, reason} ->
        {:error, {:post_description_failed, reason}}
    end
  end

  defp set_ready(deps, item, log) do
    case deps.tracker.update_issue_state.(item.id, "Symphony Ready") do
      :ok ->
        log.("e2e: set status='Symphony Ready' on id=#{item.id}")
        :ok

      {:error, reason} ->
        {:error, {:set_status_failed, reason}}
    end
  end

  defp run_symphony_and_assert(deps, item, identifier, ctx) do
    workspace_path = Path.join(ctx.workspace_root, identifier)

    deps.logger.("e2e: invoking symphony runner identifier=#{identifier} max_wait_s=#{ctx.max_wait_seconds}")

    runner_result =
      run_runner_with_polling(deps, item, ctx)

    final_state = runner_result.final_state
    pr_url = runner_result.pr_url
    log_tail = runner_result.log_tail
    runner_reason = runner_result.runner_reason

    assertions =
      collect_assertions(deps, identifier, workspace_path, final_state, pr_url, log_tail)

    overall_status =
      if runner_reason == :ok and Enum.all?(assertions, fn {_label, ok?} -> ok? end) do
        :passed
      else
        :failed
      end

    reason =
      if overall_status == :passed do
        :ok
      else
        {:assertions_failed, %{runner: runner_reason, assertions: assertions}}
      end

    finalize(deps, item, identifier,
      dry_run?: false,
      status: overall_status,
      reason: reason,
      workspace_root: ctx.workspace_root,
      pr_url: pr_url,
      final_state: final_state,
      log_tail: log_tail
    )
  end

  defp run_runner_with_polling(deps, item, ctx) do
    deadline_ms = deps.monotonic_now_ms.() + ctx.max_wait_seconds * 1_000

    runner_task =
      Task.async(fn ->
        deps.symphony_runner.(ctx.runner_opts)
      end)

    poll_until_done(deps, item, deadline_ms, ctx.poll_interval_ms, runner_task, %{
      final_state: nil,
      pr_url: nil
    })
  end

  defp poll_until_done(deps, item, deadline_ms, interval_ms, runner_task, last) do
    # Task.yield doubles as the inter-poll sleep; never spin without yielding.
    case Task.yield(runner_task, interval_ms) do
      {:ok, runner_result} ->
        finalize_runner_result(runner_result, last)

      _nil_or_exit ->
        case maybe_check_item(deps, item, last) do
          {:complete, observed} ->
            shutdown_runner_task(runner_task)
            %{final_state: observed.final_state, pr_url: observed.pr_url, runner_reason: :ok, log_tail: ""}

          {:continue, observed} ->
            now = deps.monotonic_now_ms.()

            if now >= deadline_ms do
              shutdown_runner_task(runner_task)

              %{
                final_state: observed.final_state,
                pr_url: observed.pr_url,
                runner_reason: :timeout,
                log_tail: ""
              }
            else
              poll_until_done(deps, item, deadline_ms, interval_ms, runner_task, observed)
            end
        end
    end
  end

  defp finalize_runner_result({:ok, %{log_tail: log_tail}}, last) do
    %{
      final_state: last.final_state,
      pr_url: last.pr_url,
      runner_reason: :ok,
      log_tail: log_tail || ""
    }
  end

  defp finalize_runner_result({:error, reason, log_tail}, last) do
    %{
      final_state: last.final_state,
      pr_url: last.pr_url,
      runner_reason: {:runner_error, reason},
      log_tail: log_tail || ""
    }
  end

  defp finalize_runner_result(other, last) do
    %{
      final_state: last.final_state,
      pr_url: last.pr_url,
      runner_reason: {:runner_error, {:unexpected_runner_result, other}},
      log_tail: ""
    }
  end

  # Give the runner a 5-second graceful window so its trap_exit handler can
  # SIGTERM/SIGKILL the Symphony OS subprocess before we force it down. After
  # the timeout the runner is brutally killed and the OS pid is on its own —
  # that's acceptable on ephemeral CI runners (the runner VM is torn down at
  # the end of the job) but operators running this locally should grep `ps`
  # if they kill the harness mid-flight.
  defp shutdown_runner_task(task) do
    case Task.shutdown(task, 5_000) do
      _ -> :ok
    end
  end

  defp maybe_check_item(deps, item, last) do
    case deps.tracker.fetch_issue_state.(item.id) do
      {:ok, %{state: state, pr_url: pr_url}} ->
        observed = %{final_state: state, pr_url: pr_url || last.pr_url}

        if state == "Human Review" and is_binary(observed.pr_url) and observed.pr_url != "" do
          {:complete, observed}
        else
          {:continue, observed}
        end

      {:error, _} ->
        {:continue, last}
    end
  end

  defp collect_assertions(deps, identifier, workspace_path, final_state, pr_url, log_tail) do
    branch = "symphony/#{identifier}/attempt-1"

    [
      {:workspace_exists, deps.workspace_exists?.(workspace_path)},
      {:agent_branch_created, deps.workspace_branch_exists?.(workspace_path, branch)},
      {:pr_url_written, is_binary(pr_url) and pr_url != ""},
      {:status_human_review, final_state == "Human Review"},
      {:no_port_exit_nonzero, not String.contains?(log_tail || "", "port_exit_nonzero")}
    ]
  end

  defp finalize(deps, item, identifier, fields) do
    dry_run? = Keyword.fetch!(fields, :dry_run?)
    status = Keyword.fetch!(fields, :status)
    reason = Keyword.fetch!(fields, :reason)
    workspace_root = Keyword.fetch!(fields, :workspace_root)
    pr_url = Keyword.get(fields, :pr_url)
    final_state = Keyword.get(fields, :final_state)
    log_tail = Keyword.get(fields, :log_tail, "")

    cleanup_outcome = cleanup(deps, item, identifier, workspace_root, pr_url, dry_run?)

    %{
      status: status,
      item_id: item.id,
      identifier: identifier,
      reason: reason,
      pr_url: pr_url,
      final_state: final_state,
      log_tail: log_tail,
      cleanup: cleanup_outcome,
      dry_run: dry_run?
    }
  end

  defp cleanup(deps, item, identifier, workspace_root, pr_url, dry_run?) do
    log = deps.logger
    workspace_path = Path.join(workspace_root, identifier)

    delete_outcome =
      case deps.tracker.delete_item.(item.id) do
        :ok ->
          log.("e2e: cleanup deleted item id=#{item.id}")
          :ok

        {:error, reason} ->
          log.("e2e: cleanup delete_item failed id=#{item.id} reason=#{inspect(reason)}")
          {:error, reason}
      end

    workspace_outcome =
      case deps.workspace_remover.(workspace_path) do
        :ok ->
          log.("e2e: cleanup removed workspace path=#{workspace_path}")
          :ok

        {:error, :enoent} ->
          log.("e2e: cleanup workspace already absent path=#{workspace_path}")
          :ok

        {:error, reason} ->
          log.("e2e: cleanup workspace_remove failed path=#{workspace_path} reason=#{inspect(reason)}")
          {:error, reason}
      end

    pr_outcome =
      cond do
        dry_run? ->
          :skipped

        is_binary(pr_url) and pr_url != "" ->
          case deps.pr_closer.(pr_url) do
            :ok ->
              log.("e2e: cleanup closed PR url=#{pr_url}")
              :ok

            {:error, reason} ->
              log.("e2e: cleanup pr_close failed url=#{pr_url} reason=#{inspect(reason)}")
              {:error, reason}
          end

        true ->
          :skipped
      end

    %{delete_item: delete_outcome, workspace: workspace_outcome, pr: pr_outcome}
  end
end
