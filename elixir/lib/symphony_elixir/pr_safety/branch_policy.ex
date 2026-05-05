defmodule SymphonyElixir.PRSafety.BranchPolicy do
  @moduledoc """
  Pure validator for the branch convention an agent must follow when opening
  a PR for a Symphony item: `symphony/SYM-<id>/attempt-<N>`.

  Spec 4 §2.8 / DL-006 anchored the convention on the agent prompt; this
  module enforces it after-the-fact when the AgentRunner detects a PR URL in
  the agent stream and fetches the head branch via `gh pr view`.

  The validation is strict: any deviation (different prefix, missing
  attempt-N suffix, wrong item id) produces a structured
  `{:branch_convention_violation, head, expected_pattern}` error so the
  caller can transition the item to `Cancelled` and post a refusal Workpad.
  """

  @attempt_suffix_pattern "attempt-N"

  @doc """
  Render the human-readable expected pattern for a given item id. Used in
  refusal messages so operators can see exactly what Symphony required.
  """
  @spec expected_pattern(String.t()) :: String.t()
  def expected_pattern(item_id) when is_binary(item_id) and item_id != "" do
    "symphony/SYM-#{item_id}/#{@attempt_suffix_pattern}"
  end

  def expected_pattern(_item_id), do: "symphony/SYM-<id>/#{@attempt_suffix_pattern}"

  @doc """
  Validate a head branch name against the Symphony convention for the given
  item id.

  Accepted: `symphony/SYM-<item_id>/attempt-<N>` where `<N>` is one or more
  digits. Anything else returns `{:error, {:branch_convention_violation,
  head, expected}}`.
  """
  @spec validate(String.t() | nil, String.t() | nil) ::
          :ok | {:error, {:branch_convention_violation, String.t(), String.t()}}
  def validate(head, item_id)
      when is_binary(head) and is_binary(item_id) and item_id != "" do
    expected = expected_pattern(item_id)
    regex = compile_pattern(item_id)

    if Regex.match?(regex, head) do
      :ok
    else
      {:error, {:branch_convention_violation, head, expected}}
    end
  end

  def validate(head, item_id) do
    expected = expected_pattern(item_id)
    head_str = if is_binary(head), do: head, else: ""
    {:error, {:branch_convention_violation, head_str, expected}}
  end

  defp compile_pattern(item_id) do
    escaped_id = Regex.escape(item_id)
    {:ok, regex} = Regex.compile("^symphony/SYM-#{escaped_id}/attempt-\\d+$")
    regex
  end
end
