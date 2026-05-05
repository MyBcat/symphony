defmodule SymphonyElixir.Monday.Workpad do
  @moduledoc """
  Renders Monday Update body from session state and (at completion) the agent's
  `_symphony_summary.md` workspace file. Symphony writes this; the agent does
  not.
  """

  @marker "## Symphony Workpad"
  @pr_refusal_marker "## Symphony PR Refusal"
  @phi_refusal_marker "## Symphony PHI Refusal"
  @codex_review_marker "## Symphony Codex Review"
  @auto_merge_failure_marker "## Symphony Auto-Merge Failed"
  @codex_review_max_output_bytes 6 * 1024

  @type session :: %{
          required(:identifier) => String.t(),
          required(:profile_name) => String.t(),
          optional(:instance_id) => String.t(),
          optional(:host) => String.t(),
          optional(:workspace_path) => String.t(),
          optional(:short_sha) => String.t(),
          optional(:started_at) => DateTime.t()
        }

  @spec render_session_start(session()) :: String.t()
  def render_session_start(session) do
    stamp = stamp_line(session)
    started = format_started(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Session

    - Started by Symphony #{started}
    - Profile: `#{session.profile_name}`
    - Identifier: `#{session.identifier}`
    """
  end

  @spec render_completion(session(), String.t()) :: String.t()
  def render_completion(session, summary) do
    stamp = stamp_line(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Completion

    Profile: `#{session.profile_name}`

    #{summary}
    """
  end

  @doc """
  Render the body of a `## Symphony PR Refusal` Monday Update for an agent PR
  that violated the M-8 PR safety rules. The marker is part of the body so
  Monday's update history clearly tags refusals separately from regular
  workpad / failure traffic.

  `reason_label` is the structured reason emitted by `PRSafety.evaluate_pr/2`
  (e.g. `"branch_convention_violation: got <head>, expected <pattern>"` or
  `"force_push_detected"`).
  """
  @spec render_pr_refusal(session(), String.t()) :: String.t()
  def render_pr_refusal(session, reason_label) do
    stamp = stamp_line(session)

    """
    #{@pr_refusal_marker}

    ```text
    #{stamp}
    ```

    ### Refusal

    Profile: `#{Map.get(session, :profile_name, "unknown")}`
    Reason: `#{reason_label}`
    """
  end

  @doc """
  Render the body of a `## Symphony PHI Refusal` Monday Update for a tracker
  item that the PHI gate refused to dispatch.

  `finding_kinds` is the list of detected finding *types* (e.g. `[:patient_name,
  :ssn]`). The matched text is intentionally NEVER passed in — Spec 4 §2.5
  forbids any raw PHI in logs, stdout, or Workpad bodies. Callers MUST extract
  only the kinds from `PHIDetector.scan/1` findings before invoking this
  helper. Anything that is not a known kind atom is rendered as the literal
  `[REDACTED]` placeholder so a stray binary in the list cannot leak text.
  """
  @spec render_phi_refusal(session(), [atom()]) :: String.t()
  def render_phi_refusal(session, finding_kinds) when is_list(finding_kinds) do
    stamp = stamp_line(session)
    kinds_line = render_finding_kinds(finding_kinds)

    """
    #{@phi_refusal_marker}

    ```text
    #{stamp}
    ```

    ### Refusal

    Profile: `#{Map.get(session, :profile_name, "unknown")}`
    Finding types: #{kinds_line}

    Symphony refused dispatch because the item title or non-Symphony update
    body matched a PHI pattern. The matched text is intentionally not shown
    here. Edit the item to remove the PHI, then re-enroll by setting the
    Symphony Status back to an active state.
    """
  end

  @doc """
  Render the body of a `## Symphony Codex Review` Monday Update for an
  agent PR that just transitioned to Human Review (Spec 4 §2.8a).

  `codex_output` is the full stdout/stderr capture from `codex exec`. It
  is truncated to `#{@codex_review_max_output_bytes}` bytes so a long
  Codex response never blows past Monday's update size cap; the
  `Monday.Adapter.post_codex_review/2` write also re-applies its own
  global cap.

  Operators read this block to confirm the auto-merge gate decision.
  """
  @spec render_codex_review(session(), String.t() | nil) :: String.t()
  def render_codex_review(session, codex_output) do
    stamp = stamp_line(session)
    body = truncate_for_codex_review(to_string(codex_output))

    """
    #{@codex_review_marker}

    ```text
    #{stamp}
    ```

    ### Codex Review

    Profile: `#{Map.get(session, :profile_name, "unknown")}`

    ```text
    #{body}
    ```
    """
  end

  @doc """
  Render the body of a `## Symphony Codex Review` block for a failure
  case (e.g. Codex CLI errored, network unavailable). The body explains
  why the auto-merge gate could not run and instructs the operator to
  resolve manually.
  """
  @spec render_codex_review_failure(session(), String.t()) :: String.t()
  def render_codex_review_failure(session, reason_label) do
    stamp = stamp_line(session)

    """
    #{@codex_review_marker}

    ```text
    #{stamp}
    ```

    ### Codex Review Unavailable

    Profile: `#{Map.get(session, :profile_name, "unknown")}`
    Reason: `#{reason_label}`

    Symphony was unable to run the Codex auto-review against this PR.
    No auto-merge attempted; operator review is required.
    """
  end

  @doc """
  Render the body of a `## Symphony Auto-Merge Failed` Monday Update for
  an item that passed all five gates but where `gh pr merge` itself
  errored (e.g. branch protection conflict, network issue).

  The item is moved to `Rework` separately by `AutoMerge.do_merge/1`; this
  block tells the operator what `gh` reported.
  """
  @spec render_auto_merge_failure(session(), String.t()) :: String.t()
  def render_auto_merge_failure(session, gh_output) do
    stamp = stamp_line(session)
    body = truncate_for_codex_review(to_string(gh_output))

    """
    #{@auto_merge_failure_marker}

    ```text
    #{stamp}
    ```

    ### Auto-Merge Failed

    Profile: `#{Map.get(session, :profile_name, "unknown")}`

    ```text
    #{body}
    ```

    Symphony moved this item to `Rework`. Resolve the merge conflict or
    branch-protection issue, then move the item back to `Human Review` to
    re-attempt auto-merge.
    """
  end

  defp truncate_for_codex_review(text) when is_binary(text) do
    text
    |> truncate_to_codex_review_cap()
    |> defang_code_fences()
  end

  defp truncate_for_codex_review(_), do: ""

  defp truncate_to_codex_review_cap(text) when is_binary(text) do
    if byte_size(text) <= @codex_review_max_output_bytes do
      String.trim_trailing(text)
    else
      head =
        text
        |> binary_part(0, @codex_review_max_output_bytes)
        |> backtrack_to_valid_utf8()

      String.trim_trailing(head) <> "\n\n... (truncated)"
    end
  end

  # `binary_part/3` slices at the byte cap and may land mid-codepoint,
  # producing an invalid UTF-8 binary that breaks Monday rendering and
  # any downstream String.* operation. Walk back at most 3 bytes (the
  # max length of a UTF-8 trailing-byte sequence) until we land on a
  # valid prefix.
  defp backtrack_to_valid_utf8(prefix) when is_binary(prefix) do
    Enum.reduce_while(0..3, prefix, fn drop, acc ->
      candidate =
        case drop do
          0 -> acc
          n -> binary_part(acc, 0, byte_size(acc) - n)
        end

      if String.valid?(candidate), do: {:halt, candidate}, else: {:cont, acc}
    end)
  end

  # Codex output is wrapped in a triple-backtick fenced block so Monday
  # renders it as preformatted text. If the output itself contains a
  # ```` ``` ```` sequence (very common — Codex quotes diffs), the fence
  # closes early and the rest of the body becomes raw Markdown. That's
  # both a UX bug and a defense-in-depth concern: any token-shaped or
  # PHI-shaped string in the orphaned tail would render with full
  # Markdown semantics. Replace `` ``` `` with `` `` `​`` (zero-width
  # joiner between the second and third backtick) so the visual is
  # preserved but Monday can't tokenize the sequence as a fence.
  defp defang_code_fences(text) when is_binary(text) do
    String.replace(text, "```", "``​`")
  end

  @spec render_crash(session(), String.t()) :: String.t()
  def render_crash(session, reason) do
    stamp = stamp_line(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Crashed

    Profile: `#{session.profile_name}`
    Reason: `#{reason}`
    """
  end

  @type failure_input :: %{
          optional(:timestamp) => String.t(),
          optional(:profile_name) => String.t() | nil,
          optional(:repo) => String.t() | nil,
          required(:reason) => atom() | String.t(),
          optional(:message) => String.t() | nil,
          optional(:stderr_tail) => String.t() | nil
        }

  @doc """
  Render the body of a `## Symphony Failures` Monday Update, without the marker
  itself. The marker is prepended by `Monday.Adapter.post_failure_update/2`.

  Format (per Spec 4 §2.4 / SYM-11923123790):

      {ISO8601 UTC timestamp} | profile={profile} | repo={repo} | reason={reason}
      {human-readable error message}
      --- last 20 lines stderr ---
      {stderr tail}

  The `--- last 20 lines stderr ---` section is rendered only when the caller
  supplies a non-empty `:stderr_tail`; many failure paths (profile denial,
  workspace creation, max_turns) have no stderr to attach.
  """
  @spec render_failure(failure_input()) :: String.t()
  def render_failure(input) when is_map(input) do
    timestamp =
      Map.get(input, :timestamp) || DateTime.to_iso8601(DateTime.utc_now())

    profile = stringify_field(Map.get(input, :profile_name))
    repo = stringify_field(Map.get(input, :repo))
    reason = format_reason(Map.fetch!(input, :reason))
    message = Map.get(input, :message) || ""
    stderr_tail = Map.get(input, :stderr_tail) || ""

    header = "#{timestamp} | profile=#{profile} | repo=#{repo} | reason=#{reason}"

    base = [header, message]

    lines =
      if String.trim(to_string(stderr_tail)) == "" do
        base
      else
        base ++ ["--- last 20 lines stderr ---", String.trim_trailing(stderr_tail)]
      end

    Enum.join(lines, "\n")
  end

  @doc """
  Take the last `n` lines of a binary, joined with `\\n`. Returns an empty
  string for nil/empty input. Used to render the stderr/stdout tail in
  `render_failure/1`.
  """
  @spec tail_lines(String.t() | nil, pos_integer()) :: String.t()
  def tail_lines(nil, _n), do: ""
  def tail_lines("", _n), do: ""

  def tail_lines(text, n) when is_binary(text) and is_integer(n) and n > 0 do
    text
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  # Render the finding-types line as a comma-separated list of backtick-quoted
  # kinds. Anything that isn't a plain atom collapses to `[REDACTED]` so a
  # caller that accidentally passes a raw PHI string cannot leak it into the
  # rendered body.
  defp render_finding_kinds([]), do: "`[REDACTED]`"

  defp render_finding_kinds(kinds) when is_list(kinds) do
    kinds
    |> Enum.map(&format_finding_kind/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp format_finding_kind(kind) when is_atom(kind), do: "`" <> Atom.to_string(kind) <> "`"
  defp format_finding_kind(_other), do: "`[REDACTED]`"

  defp stamp_line(session) do
    host = Map.get(session, :host, "unknown")
    path = Map.get(session, :workspace_path, "")
    sha = Map.get(session, :short_sha, "no-sha")
    "#{host}:#{path}@#{sha}"
  end

  defp format_started(%{started_at: dt}), do: "at " <> DateTime.to_iso8601(dt)
  defp format_started(_), do: "(time unknown)"

  defp stringify_field(nil), do: "unknown"
  defp stringify_field(""), do: "unknown"
  defp stringify_field(value) when is_binary(value), do: value
  defp stringify_field(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_field(value), do: inspect(value)

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
