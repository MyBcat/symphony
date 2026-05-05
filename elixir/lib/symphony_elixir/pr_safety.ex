defmodule SymphonyElixir.PRSafety do
  @moduledoc """
  M-8 PR safety entry point. Coordinates branch validation, force-push
  detection, and idempotent state persistence so the AgentRunner only has
  to make a single call when it detects a PR URL in the agent stream.

  The orchestration:

    * `evaluate_pr/2` looks up any prior recorded state for the item.
    * If no record exists (first detection), validate the head branch via
      `gh pr view --json baseRefName,headRefName,url,headRefOid` against
      `BranchPolicy`. On valid: persist `{url, head_sha}` and return
      `{:ok, :transition}` so the caller sets PR URL + transitions to
      `Human Review`. On invalid: return `{:error, {:branch_convention_violation, head, expected}}`.
    * If a record exists for the item AND the URL matches, run the
      force-push check via `gh pr view --json commits`: refuse with
      `{:error, :force_push_detected}` when the recorded SHA is no longer
      among the PR's commits (history rewritten). Otherwise return
      `{:ok, :idempotent_no_force_push}` so the caller treats it as a
      no-op (no second write).
    * If a record exists with a different URL, treat as a fresh first
      detection (re-validate branch and re-record). This handles the
      retry-with-new-attempt case where a prior abandoned PR still sits in
      state.

  GitHub access goes through the `SymphonyElixir.PRSafety.GH` behaviour so
  tests can inject a stub. State persistence goes through
  `SymphonyElixir.PRSafety.PRState` so tests can configure a temp file via
  the `:pr_safety_state_path` application env.
  """

  alias SymphonyElixir.PRSafety.{BranchPolicy, GH, PRState}

  @typedoc """
  Outcomes from `evaluate_pr/2`. The caller decides which Monday writes to
  perform based on this tag.

    * `:transition` — first valid detection. Caller MUST call
      `Tracker.set_pr_url/2` and `Tracker.update_issue_state/2` to
      `"Human Review"`.

    * `:idempotent_no_force_push` — re-detection of the same PR with no
      detected history rewrite. Caller MUST treat as a no-op (no second
      Monday write).
  """
  @type ok_outcome :: :transition | :idempotent_no_force_push

  @typedoc """
  Refusal outcomes from `evaluate_pr/2`. On any of these, the caller MUST
  transition the item to `"Cancelled"` and post a refusal Workpad with
  `reason_label/1`.
  """
  @type refusal ::
          {:branch_convention_violation, String.t(), String.t()}
          | :force_push_detected
          | {:gh_unavailable, term()}
          | {:state_failure, term()}

  @doc """
  Evaluate a freshly detected PR URL against the M-8 PR safety policy for
  the given item id.
  """
  @spec evaluate_pr(String.t(), String.t()) ::
          {:ok, ok_outcome()} | {:error, refusal()}
  def evaluate_pr(url, item_id)
      when is_binary(url) and is_binary(item_id) and item_id != "" do
    case PRState.lookup(item_id) do
      :not_found ->
        first_detection(url, item_id)

      {:ok, %{url: ^url, sha: prior_sha}} ->
        check_force_push(url, prior_sha)

      {:ok, %{url: _other_url}} ->
        # Different URL recorded — treat as fresh first detection. The agent
        # opened a new PR (e.g., retry attempt-2) which gets validated and
        # re-recorded.
        first_detection(url, item_id)

      {:error, reason} ->
        {:error, {:state_failure, reason}}
    end
  end

  def evaluate_pr(_url, _item_id), do: {:error, {:branch_convention_violation, "", ""}}

  @doc """
  Render the human-readable reason label for a refusal outcome. Used by the
  AgentRunner to populate the `## Symphony PR Refusal` workpad.
  """
  @spec reason_label(refusal()) :: String.t()
  def reason_label({:branch_convention_violation, head, expected}) do
    "branch_convention_violation: got #{head}, expected #{expected}"
  end

  def reason_label(:force_push_detected), do: "force_push_detected"
  def reason_label({:gh_unavailable, _reason}), do: "gh_unavailable"
  def reason_label({:state_failure, _reason}), do: "state_failure"

  defp first_detection(url, item_id) do
    case GH.pr_view_basic(url) do
      {:ok, %{head_branch: head, head_sha: sha}} ->
        case BranchPolicy.validate(head, item_id) do
          :ok ->
            persist_first_detection(item_id, url, sha)

          {:error, _} = err ->
            err
        end

      {:error, reason} ->
        {:error, {:gh_unavailable, reason}}
    end
  end

  defp persist_first_detection(item_id, url, sha) do
    case PRState.record(item_id, %{url: url, sha: sha}) do
      :ok -> {:ok, :transition}
      {:error, reason} -> {:error, {:state_failure, reason}}
    end
  end

  defp check_force_push(url, prior_sha) do
    case GH.pr_view_commits(url) do
      {:ok, commits} ->
        if descendant?(commits, prior_sha) do
          {:ok, :idempotent_no_force_push}
        else
          {:error, :force_push_detected}
        end

      {:error, reason} ->
        {:error, {:gh_unavailable, reason}}
    end
  end

  defp descendant?(commits, prior_sha) when is_list(commits) and is_binary(prior_sha) do
    Enum.any?(commits, fn
      %{sha: sha} when is_binary(sha) -> sha == prior_sha
      _ -> false
    end)
  end

  defp descendant?(_commits, _prior_sha), do: false
end
