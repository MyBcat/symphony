defmodule SymphonyElixir.AutoMerge do
  @moduledoc """
  Spec 4 §2.8a — Auto-Codex-review with conditional auto-merge.

  When an item transitions to `Human Review` because the agent opened a PR,
  this module orchestrates a Codex review pass against the PR and — if all
  five fail-closed gates pass — auto-merges the PR via `gh pr merge --merge
  --auto`.

  ## Gate order (fail-closed, evaluated sequentially)

  1. **Repo opt-in** (`auto_merge_on_codex_pass: true`; default `false`).
  2. **Codex pass pattern** (`Regex.run(pass_pattern, codex_output) != nil`).
  3. **PR size** (`gh pr diff <url> | wc -l < auto_merge_max_lines`).
  4. **Base branch** (`base in ["main", "master"]`).
  5. **Item still in Human Review** at the moment of merge.

  ## Telemetry

  Every gate failure is logged at `:info` with the item id, gate, and
  reason. The Codex review output is ALWAYS posted to the Workpad as a
  `## Symphony Codex Review` block — even when gate 1 (repo opt-in) is
  false. Operator visibility is the primary value of this module; the
  auto-merge action is the cherry on top.

  ## Idempotency

  `(item_id, pr_url)` pairs are persisted in `AutoMerge.State`. Re-detection
  of the same PR (e.g. agent_runner replays a stream chunk) does NOT
  re-run Codex review.

  ## Concurrency

  `evaluate_human_review/1` is synchronous and CAN block for tens of
  seconds while Codex runs. Callers should invoke it inside a
  `Task.Supervisor.async_nolink/2` so a hung Codex CLI doesn't freeze the
  agent_runner stream observer.
  """

  require Logger

  alias SymphonyElixir.{
    AutoMerge.GH,
    AutoMerge.State,
    CodexReview,
    Config,
    Monday.Workpad,
    Tracker
  }

  alias SymphonyElixir.Tracker.Issue

  @default_review_profile_name "codex_gpt55_xhigh"

  @typedoc """
  Inputs for `evaluate_human_review/1`. Populated by the agent_runner
  immediately after the Human Review status transition.

  Required keys:
    * `:item_id` — Monday item id (string).
    * `:pr_url` — full GitHub PR URL.
    * `:repo_key` — resolved repo key from WORKFLOW.md `repos:` map. May be
      `nil` for legacy items routed via the default-hooks path; auto-merge
      is impossible in that case (no per-repo opt-in flag).
    * `:session` — workpad-render session struct (Workpad.session).

  Optional keys:
    * `:workspace_path` — agent workspace directory; used as cwd for the
      Codex CLI call when present.
    * `:base_branch` — already-fetched PR base ref (e.g. by PRSafety). When
      missing, AutoMerge fetches it via `GH.pr_view_base/1`.
  """
  @type ctx :: %{
          required(:item_id) => String.t(),
          required(:pr_url) => String.t(),
          required(:session) => Workpad.session(),
          optional(:repo_key) => String.t() | nil,
          optional(:repo_entry) =>
            SymphonyElixir.Config.Schema.RepoEntry.t() | nil,
          optional(:workspace_path) => Path.t() | nil,
          optional(:base_branch) => String.t() | nil
        }

  @doc """
  Evaluate auto-merge for an item that just entered Human Review.

  Returns:
    * `{:ok, :merged}` — all gates passed, gh pr merge succeeded
    * `{:ok, :merge_pending}` — all gates passed, gh pr merge --auto queued
      (this is the same outcome as `:merged` for current `--auto` semantics
      — kept for forward compatibility if auto-merge becomes async later)
    * `{:ok, {:held, gate}}` — review ran, a gate failed; item stays in
      Human Review
    * `{:ok, :idempotent}` — already reviewed; no work done
    * `{:error, {:codex_review_failed, reason}}` — Codex CLI errored; item
      stays in Human Review with a failure note posted
    * `{:error, reason}` — unexpected internal error

  Never raises; all failures are logged + returned.
  """
  @spec evaluate_human_review(ctx()) ::
          {:ok, :merged | :merge_pending | :idempotent | {:held, atom()}}
          | {:error, term()}
  def evaluate_human_review(%{item_id: item_id, pr_url: pr_url} = ctx)
      when is_binary(item_id) and item_id != "" and is_binary(pr_url) and pr_url != "" do
    cond do
      not gh_pr_url?(pr_url) ->
        {:error, {:invalid_pr_url, pr_url}}

      State.reviewed?(item_id, pr_url) ->
        Logger.debug(
          "AutoMerge: skipping idempotent re-review for item_id=#{item_id} url=#{pr_url}"
        )

        {:ok, :idempotent}

      true ->
        run_review_pipeline(ctx)
    end
  end

  def evaluate_human_review(_ctx), do: {:error, :invalid_ctx}

  @doc """
  Build the canonical Codex review prompt for `pr_url`. Public so tests
  can assert exact prompt shape and so the agent_runner could re-render it
  for diagnostic logging.
  """
  @spec build_prompt(String.t()) :: String.t()
  def build_prompt(pr_url) when is_binary(pr_url) do
    case parse_pr_url(pr_url) do
      {:ok, {owner, repo, number}} ->
        """
        Scrutinize PR #{number} on #{owner}/#{repo}. Specifically check:
        (a) correctness of new code,
        (b) test coverage,
        (c) regressions,
        (d) security/PHI/HIPAA implications.

        Conclude with the literal phrase "NO BLOCKING ISSUES" if you find none, or
        "BLOCKING ISSUES FOUND" followed by a numbered list.
        """

      :error ->
        """
        Scrutinize PR at #{pr_url}. Specifically check:
        (a) correctness of new code,
        (b) test coverage,
        (c) regressions,
        (d) security/PHI/HIPAA implications.

        Conclude with the literal phrase "NO BLOCKING ISSUES" if you find none, or
        "BLOCKING ISSUES FOUND" followed by a numbered list.
        """
    end
  end

  @doc """
  Test helper exposing the gate sequence as data so tests can assert each
  gate independently. The list order matches the order in which gates are
  evaluated by `evaluate_human_review/1`.
  """
  @spec gates() :: [atom()]
  def gates, do: [:repo_opt_in, :codex_pass_pattern, :pr_size, :base_branch, :still_in_human_review]

  defp run_review_pipeline(ctx) do
    case run_codex_review(ctx) do
      {:ok, codex_output} ->
        :ok = post_codex_review_workpad(ctx, codex_output)
        # Persist the (item_id, pr_url) review record so retries don't loop
        # the Codex CLI. Best-effort; a state-write failure is logged but
        # does not abort the run.
        log_state_write(State.mark_reviewed(ctx.item_id, ctx.pr_url), ctx)

        case evaluate_gates(ctx, codex_output) do
          {:ok, :all_passed} ->
            do_merge(ctx)

          {:hold, gate} ->
            Logger.info(
              "AutoMerge: holding for human review item_id=#{ctx.item_id} url=#{ctx.pr_url} gate=#{gate}"
            )

            {:ok, {:held, gate}}

          {:error, reason} ->
            Logger.warning(
              "AutoMerge: gate evaluation failed item_id=#{ctx.item_id} url=#{ctx.pr_url} reason=#{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        post_codex_review_failure_workpad(ctx, reason)
        {:error, {:codex_review_failed, reason}}
    end
  end

  defp run_codex_review(ctx) do
    profile_config = resolve_review_profile_config()

    input = %{
      prompt: build_prompt(ctx.pr_url),
      cwd: Map.get(ctx, :workspace_path),
      profile_config: profile_config
    }

    CodexReview.review(input)
  end

  defp resolve_review_profile_config do
    case lookup_profile(@default_review_profile_name) do
      {:ok, %SymphonyElixir.Profile{config: config}} when is_map(config) ->
        config

      _ ->
        %{}
    end
  end

  defp lookup_profile(name) do
    case Config.settings!() do
      %{profiles: profiles} when is_map(profiles) ->
        case Map.fetch(profiles, name) do
          {:ok, profile} -> {:ok, profile}
          :error -> :missing
        end

      _ ->
        :missing
    end
  rescue
    _ -> :missing
  end

  defp post_codex_review_workpad(ctx, codex_output) do
    body = Workpad.render_codex_review(ctx.session, codex_output)

    case Tracker.post_codex_review(ctx.item_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "AutoMerge: failed to post Codex Review workpad item_id=#{ctx.item_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp post_codex_review_failure_workpad(ctx, reason) do
    body = Workpad.render_codex_review_failure(ctx.session, format_reason(reason))

    case Tracker.post_codex_review(ctx.item_id, body) do
      :ok ->
        :ok

      {:error, post_reason} ->
        Logger.warning(
          "AutoMerge: failed to post Codex Review failure workpad item_id=#{ctx.item_id} reason=#{inspect(post_reason)}"
        )

        :ok
    end
  end

  defp evaluate_gates(ctx, codex_output) do
    repo_entry = ctx[:repo_entry] || resolve_repo_entry(ctx)

    with :ok <- gate_repo_opt_in(repo_entry),
         :ok <- gate_pass_pattern(codex_output, repo_entry),
         :ok <- gate_pr_size(ctx.pr_url, repo_entry),
         :ok <- gate_base_branch(ctx),
         :ok <- gate_still_in_human_review(ctx) do
      {:ok, :all_passed}
    else
      {:hold, _gate} = held -> held
      {:error, _} = err -> err
    end
  end

  defp resolve_repo_entry(%{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "" do
    case Map.get(Config.repos(), repo_key) do
      %SymphonyElixir.Config.Schema.RepoEntry{} = entry -> entry
      _ -> nil
    end
  rescue
    e ->
      Logger.warning(
        "AutoMerge: resolve_repo_entry failed repo_key=#{inspect(repo_key)} reason=#{Exception.message(e)}; falling back to nil"
      )

      nil
  end

  defp resolve_repo_entry(_ctx), do: nil

  # Spec 4 §2.8a constraint #5: the `symphony` repo MUST stay opt-out at
  # ALL times — its blast radius is too high (orchestrating real AI
  # sessions writing real code into real repos). WORKFLOW.md sets
  # `auto_merge_on_codex_pass: false` for symphony, but this hardcoded
  # gate refuses regardless of the config value. Defense in depth — a
  # future operator who accidentally flips the WORKFLOW.md value to true
  # for symphony will still be held here.
  @symphony_repo_key "symphony"

  defp gate_repo_opt_in(%SymphonyElixir.Config.Schema.RepoEntry{key: @symphony_repo_key}) do
    Logger.info(
      "AutoMerge: gate_repo_opt_in held for hardcoded symphony repo (Spec 4 constraint #5); auto-merge is permanently disabled for this repo regardless of config"
    )

    {:hold, :repo_opt_in}
  end

  defp gate_repo_opt_in(%SymphonyElixir.Config.Schema.RepoEntry{auto_merge_on_codex_pass: true}),
    do: :ok

  defp gate_repo_opt_in(_other), do: {:hold, :repo_opt_in}

  # Spec 4 §2.8a fail-closed gate 2: Codex output must (a) match the
  # configured pass pattern AND (b) NOT contain the spec-mandated block
  # signal "BLOCKING ISSUES FOUND". The block signal is hardcoded — the
  # spec prompt commits Codex to one of the two literal phrases, so an
  # output that says "BLOCKING ISSUES FOUND: 1. …" but ALSO mentions
  # "NO BLOCKING ISSUES" elsewhere (e.g., in a quoted spec snippet) must
  # still hold. If the operator overrides `auto_merge_pass_pattern` to
  # match a different review style ("LGTM", etc.), the block-signal
  # check still fires defensively as long as the canonical Codex prompt
  # is in use.
  @block_signal "BLOCKING ISSUES FOUND"

  defp gate_pass_pattern(codex_output, %SymphonyElixir.Config.Schema.RepoEntry{
         auto_merge_pass_pattern: pattern
       })
       when is_binary(pattern) and pattern != "" do
    output = codex_output || ""

    cond do
      String.contains?(output, @block_signal) ->
        Logger.info(
          "AutoMerge: codex output contains explicit block signal #{inspect(@block_signal)}; holding"
        )

        {:hold, :codex_pass_pattern}

      true ->
        case Regex.compile(pattern) do
          {:ok, regex} ->
            if Regex.match?(regex, output),
              do: :ok,
              else: {:hold, :codex_pass_pattern}

          {:error, reason} ->
            Logger.warning(
              "AutoMerge: invalid auto_merge_pass_pattern=#{inspect(pattern)} reason=#{inspect(reason)}; treating as held"
            )

            {:hold, :codex_pass_pattern}
        end
    end
  end

  defp gate_pass_pattern(_codex_output, _repo_entry), do: {:hold, :codex_pass_pattern}

  defp gate_pr_size(pr_url, %SymphonyElixir.Config.Schema.RepoEntry{auto_merge_max_lines: cap})
       when is_integer(cap) and cap > 0 do
    case GH.pr_diff_line_count(pr_url) do
      {:ok, count} when count < cap ->
        :ok

      {:ok, _count} ->
        {:hold, :pr_size}

      {:error, reason} ->
        Logger.warning(
          "AutoMerge: pr_diff_line_count failed url=#{pr_url} reason=#{inspect(reason)}; treating as held"
        )

        {:hold, :pr_size}
    end
  end

  defp gate_pr_size(_pr_url, _repo_entry), do: {:hold, :pr_size}

  defp gate_base_branch(%{base_branch: base}) when is_binary(base) do
    base_in_main_or_master(base)
  end

  defp gate_base_branch(%{pr_url: url}) do
    case GH.pr_view_base(url) do
      {:ok, base} -> base_in_main_or_master(base)
      {:error, _} -> {:hold, :base_branch}
    end
  end

  defp base_in_main_or_master(base) when base in ["main", "master"], do: :ok
  defp base_in_main_or_master(_), do: {:hold, :base_branch}

  defp gate_still_in_human_review(%{item_id: item_id}) do
    case Tracker.fetch_issue_states_by_ids([item_id]) do
      {:ok, [%Issue{state: "Human Review"}]} ->
        :ok

      {:ok, [%Issue{state: _other}]} ->
        {:hold, :still_in_human_review}

      {:ok, []} ->
        # Item not visible (deleted? privacy filter?). Fail closed.
        {:hold, :still_in_human_review}

      {:ok, _multi} ->
        # Tracker returned multiple matches; not expected for a single id.
        # Fail closed.
        {:hold, :still_in_human_review}

      {:error, reason} ->
        Logger.warning(
          "AutoMerge: fetch_issue_states_by_ids failed item_id=#{item_id} reason=#{inspect(reason)}; treating as held"
        )

        {:hold, :still_in_human_review}
    end
  end

  defp do_merge(ctx) do
    # Spec 4 §2.8a gate 5 (TOCTOU defense): re-check Human Review state
    # immediately before the Merging transition. The earlier
    # `gate_still_in_human_review/1` already ran at evaluate-gates time, but
    # there's a window between gates 1-4 (Codex review duration + GH calls)
    # and the actual merge. An operator flip to Rework/Cancelled in that
    # window MUST abort the merge.
    case gate_still_in_human_review(ctx) do
      :ok ->
        Logger.info(
          "AutoMerge: all gates passed; transitioning to Merging item_id=#{ctx.item_id} url=#{ctx.pr_url}"
        )

        case Tracker.update_issue_state(ctx.item_id, "Merging") do
          :ok ->
            run_gh_merge(ctx)

          {:error, reason} ->
            Logger.warning(
              "AutoMerge: failed to transition to Merging item_id=#{ctx.item_id} reason=#{inspect(reason)}"
            )

            {:error, {:transition_failed, reason}}
        end

      {:hold, gate} ->
        Logger.info(
          "AutoMerge: operator flipped item out of Human Review during review; aborting merge item_id=#{ctx.item_id} gate=#{gate}"
        )

        {:ok, {:held, gate}}
    end
  end

  defp run_gh_merge(ctx) do
    case GH.pr_merge(ctx.pr_url) do
      :ok ->
        Logger.info(
          "AutoMerge: gh pr merge succeeded; transitioning to Done item_id=#{ctx.item_id} url=#{ctx.pr_url}"
        )

        case Tracker.update_issue_state(ctx.item_id, "Done") do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "AutoMerge: post-merge transition to Done failed; item left in Merging item_id=#{ctx.item_id} reason=#{inspect(reason)}"
            )
        end

        {:ok, :merged}

      {:error, reason} ->
        Logger.error(
          "AutoMerge: gh pr merge failed item_id=#{ctx.item_id} url=#{ctx.pr_url} reason=#{inspect(reason)}"
        )

        body = Workpad.render_auto_merge_failure(ctx.session, format_gh_error(reason))
        _ = Tracker.post_auto_merge_failure(ctx.item_id, body)
        _ = Tracker.update_issue_state(ctx.item_id, "Rework")

        {:error, {:gh_merge_failed, reason}}
    end
  end

  defp gh_pr_url?(url) when is_binary(url),
    do: String.match?(url, ~r{^https://github\.com/[^/]+/[^/]+/pull/\d+(?:[/?#].*)?$})

  defp gh_pr_url?(_), do: false

  defp parse_pr_url(url) when is_binary(url) do
    case Regex.run(~r{^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)}, url) do
      [_, owner, repo, number] -> {:ok, {owner, repo, number}}
      _ -> :error
    end
  end

  defp parse_pr_url(_), do: :error

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  # Sanitize gh stderr/stdout that we'll embed in a Workpad post. The full
  # Workpad post will go through `Monday.Adapter.sanitize_failure_body/1`
  # which handles PHI / secret scrubbing; this just keeps shapes
  # human-readable.
  defp format_gh_error({:gh_failed, status, output}) do
    "gh pr merge exited #{status}\n\n#{output}"
  end

  defp format_gh_error({:gh_unavailable, message}) do
    "gh CLI unavailable: #{message}"
  end

  defp format_gh_error(other), do: inspect(other)

  defp log_state_write(:ok, _ctx), do: :ok

  defp log_state_write({:error, reason}, ctx) do
    Logger.warning(
      "AutoMerge: failed to persist auto_merge_state item_id=#{ctx.item_id} reason=#{inspect(reason)}"
    )

    :ok
  end
end
