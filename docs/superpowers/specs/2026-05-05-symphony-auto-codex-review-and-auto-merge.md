# Symphony — Auto-Codex-review with conditional auto-merge (Spec 4 §2.8a)

**Status:** Implementation
**Date:** 2026-05-05
**Sequencing:** Spec 4 step 8a. **Depends on Spec 4 step 8 (PR safety) merged.**
**Tracker:** SYM-11923096520
**Branch:** `symphony/SYM-11923096520/attempt-1`
**Modifies:** `lib/symphony_elixir/{auto_merge,codex_review}/**` (new); `lib/symphony_elixir/{monday/{item,workpad,adapter},tracker,tracker/memory_monday,agent_runner,config/schema}.ex`; `WORKFLOW.md`.

---

## 1. System Overview

When an item transitions to `Human Review` (M-8 hook on PR detection), Symphony auto-runs a Codex review against the PR. The review output is posted to the Monday Workpad as a `## Symphony Codex Review` block. If — and only if — five fail-closed gates all pass, Symphony auto-merges the PR.

Gates (ALL must pass):

1. **Repo opt-in:** `repos.<key>.auto_merge_on_codex_pass: true` (default `false`).
2. **Codex pass pattern:** Codex output contains the configured pass pattern (default regex `NO BLOCKING ISSUES`, configurable via `repos.<key>.auto_merge_pass_pattern`).
3. **PR size:** `gh pr diff <url> | wc -l` is strictly less than `repos.<key>.auto_merge_max_lines` (default 500).
4. **Base branch:** PR base branch is `main` or `master`. Other targets always require human review.
5. **Item state:** Item is still in `Human Review` (operator hasn't flipped to `Rework` or `Cancelled`) at the time of merge.

If all gates pass: status → `Merging`, run `gh pr merge <url> --merge --auto`. On gh success → `Done`. On gh failure → `Rework` + `## Symphony Auto-Merge Failed` workpad with gh stderr.

If any gate fails (or Codex review itself errors): item stays in `Human Review`. Codex output (or failure reason) is always posted to the Workpad.

### Safe Defaults

- ALL repos in shipped WORKFLOW.md have `auto_merge_on_codex_pass: false` (or unset = false).
- `symphony` repo MUST stay opt-out — highest blast radius. Documented in WORKFLOW.md comment.

---

## 2. Behavioral Contract

### 2.1 Trigger
- **When** the agent_runner detects a PR URL via `PRDetector.scan/1` AND `PRSafety.evaluate_pr/2` returns `{:ok, :transition}`, **the system** transitions to `Human Review` (existing M-8 behavior) AND spawns an async Codex review task via `SymphonyElixir.AutoMerge.evaluate_human_review/1`.
- The Codex review runs in `Task.Supervisor.async_nolink` so a Codex error never crashes the agent_runner writer.
- **The system** persists `{item_id, pr_url}` to `AutoMerge.State` after a successful review run so retries / re-detections don't loop.

### 2.2 Codex review run
- **The system** invokes `codex exec --skip-git-repo-check ...` with the existing `codex_gpt55_xhigh` profile's model + reasoning effort, in the agent's workspace cwd if available, otherwise in the system temp dir.
- **The system** uses the canonical review prompt (see §6) which instructs Codex to scrutinize correctness, test coverage, regressions, and HIPAA/PHI implications, and to conclude with the literal phrase `NO BLOCKING ISSUES` or `BLOCKING ISSUES FOUND` followed by a numbered list.
- **The system** captures the full Codex stdout, scrubs for PHI / secrets via `Secrets.Scrubber`, and posts it to the Workpad as `## Symphony Codex Review`.
- **When** Codex's CLI fails (non-zero exit, network error), **the system** posts a single-line failure note to the workpad and leaves the item in `Human Review`. No auto-merge attempt.

### 2.3 Auto-merge gates (fail-closed, evaluated in order)

| # | Gate | Fails when | Telemetry on failure |
|---|---|---|---|
| 1 | repo opt-in | `auto_merge_on_codex_pass != true` | structured log only |
| 2 | pass pattern | `Regex.run(pass_pattern, codex_output) == nil` | structured log |
| 3 | PR size | line count >= `auto_merge_max_lines` | structured log |
| 4 | base branch | `base not in ["main", "master"]` | structured log |
| 5 | still in Human Review | re-fetch via Tracker; item state != "Human Review" | structured log |

If gate 1 fails (the most common case — opt-out by default), **the system** still posts the Codex review to the Workpad. No auto-merge attempt is made.

### 2.4 Merge action
- **When** all five gates pass, **the system** transitions to `Merging` via `Tracker.update_issue_state/2`, then runs `gh pr merge <url> --merge --auto`.
- On `gh` exit status 0: transition to `Done`.
- On `gh` exit status != 0: transition to `Rework`, post `## Symphony Auto-Merge Failed` with sanitized stderr.
- **The system** always uses `--merge` (not `--squash` or `--rebase`) per the spec.

### 2.5 Idempotency
- **When** the same `(item_id, pr_url)` pair has already been auto-merge-evaluated (recorded in `AutoMerge.State`), **the system** does NOT re-run Codex review for the same pair on subsequent triggers.
- An item with multiple PR URLs across attempts (e.g., attempt-1 opened PR#100, attempt-2 opened PR#200) records BOTH URLs in `AutoMerge.State`'s reviewed list. Re-detection of either URL is idempotent independently. The legacy single-record on-disk shape (one URL per item) is read transparently for backward compatibility — older state files don't need migration.
- If the operator flips the item back to `Human Review` after a previous Rework, but the PR URL unchanged, Symphony does NOT re-review (operator must close + reopen with a new PR or change the SHA via force-push, which the M-8 force-push detector would catch).

### 2.6 Defense-in-depth invariants
- **`symphony` repo is hardcoded opt-out.** `gate_repo_opt_in` pattern-matches on `repo_entry.key == "symphony"` and refuses regardless of the `auto_merge_on_codex_pass` config value. Spec 4 constraint #5: the symphony repo's blast radius is too high for unattended auto-merge.
- **Block-signal short-circuit.** `gate_pass_pattern` checks for the literal `BLOCKING ISSUES FOUND` phrase BEFORE evaluating the configured pass pattern. If Codex output contains the block signal, the gate holds even if the pass pattern also matches somewhere in the output (e.g., a quoted spec snippet). Operators can override `auto_merge_pass_pattern` but cannot disable the block-signal check.
- **TOCTOU defense on Merging.** Gate 5 (still in Human Review) is re-checked inside `do_merge/1` immediately before the `Tracker.update_issue_state(..., "Merging")` write. An operator flip in the window between gate evaluation and the merge write aborts the auto-merge.
- **Workpad fence defang.** Codex output that contains a literal triple-backtick (very common when Codex quotes diffs) is rewritten so the inner sequence cannot close the outer Markdown fence early. Without this, any token-shaped or PHI-shaped string in the orphaned tail would render as raw Markdown.
- **UTF-8 safe truncation.** `binary_part/3` may slice mid-codepoint when the output exceeds the byte cap. The truncate helper backtracks up to 3 bytes to land on a valid codepoint boundary so Monday + downstream `String.*` calls never see an invalid binary.
- **Codex CLI environment is allowlisted.** `CodexReview.Default` does NOT inherit the orchestrator's full env into `codex exec`. Only `PATH`, `HOME`, `USER`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR`, `PWD`, `XDG_*`, plus `CODEX_*` and `OPENAI_BASE_URL` prefixes propagate. Per-repo resolved secrets (Spec 4 §2.4) and Symphony's `MONDAY_API_TOKEN` are deliberately withheld.
- **Codex CLI cwd is workspace-rooted.** `cwd_for_exec/1` validates the supplied cwd canonicalizes to a descendant of `workspace.root`. If validation fails (e.g., cwd was deleted or workflow config is unloadable), falls back to `System.tmp_dir!()`.
- **Codex + gh CLI invocations have hard timeouts.** Both wrap `System.cmd` in a `Task.async` + `Task.yield(timeout)` + `Task.shutdown(:brutal_kill)` pattern so a hung child process can't starve the AutoMerge Task indefinitely. Default timeouts: codex exec 5min, gh CLI 60s.
- **Tracker-write guard before spawn.** `agent_runner.spawn_auto_merge` only fires when both `Tracker.set_pr_url/2` and `Tracker.update_issue_state(_, "Human Review")` succeed. If either fails (e.g., transient Monday outage), AutoMerge is not spawned — running Codex review for an item still showing as `In Progress` would post Workpad noise that operators can't reconcile.

---

## 3. Module Manifest

| Module | Path | Purpose |
|---|---|---|
| `SymphonyElixir.AutoMerge` | `lib/symphony_elixir/auto_merge.ex` | Orchestrate review + 5 gates + merge action |
| `SymphonyElixir.AutoMerge.GH` | `lib/symphony_elixir/auto_merge/gh.ex` | Behaviour for `gh pr diff/merge/view` calls |
| `SymphonyElixir.AutoMerge.GH.Default` | `lib/symphony_elixir/auto_merge/gh/default.ex` | Default `System.cmd/3` impl |
| `SymphonyElixir.AutoMerge.State` | `lib/symphony_elixir/auto_merge/state.ex` | Persist `{item_id, pr_url}` reviewed set |
| `SymphonyElixir.CodexReview` | `lib/symphony_elixir/codex_review.ex` | Behaviour + default runner for `codex exec` |
| `SymphonyElixir.CodexReview.Default` | `lib/symphony_elixir/codex_review/default.ex` | Default `System.cmd/3` codex exec invocation |

Modified existing modules:
- `Config.Schema` — `RepoEntry` gains `auto_merge_on_codex_pass`, `auto_merge_max_lines`, `auto_merge_pass_pattern`
- `Monday.Item` — adds two markers to `@symphony_marker_prefixes`
- `Monday.Workpad` — `render_codex_review/2`, `render_auto_merge_failure/2`
- `Monday.Adapter` + `Tracker` + `MemoryMonday` — `post_codex_review/2`, `post_auto_merge_failure/2`
- `AgentRunner` — invoke `AutoMerge.evaluate_human_review/1` after the Human Review transition
- `WORKFLOW.md` — schema documentation + per-repo opt-out comments

---

## 4. Decision Log

### DL-S4-2.8a-1: Run Codex review unconditionally on Human Review transition
**Choice:** Always run + post Codex review, even when `auto_merge_on_codex_pass` is false.
**Rationale:** Operator visibility is the primary value. Auto-merge is the cherry on top. If Codex review only ran when auto-merge was opted in, operators using opt-out repos would lose the review-as-feedback signal for free.
**Reversal cost:** Low.

### DL-S4-2.8a-2: Async via Task.Supervisor.async_nolink
**Choice:** Run AutoMerge.evaluate_human_review/1 in an unlinked Task so a Codex CLI hang or crash doesn't bubble up to the agent_runner writer.
**Rationale:** Codex CLI invocation can take ≥30s; blocking the writer would freeze stream observation for that duration. Unlinked Task lets the writer proceed and the AutoMerge logs / posts to Workpad on its own timeline.
**Reversal cost:** Low — switch to sync if a stronger ordering guarantee is needed.

### DL-S4-2.8a-3: Pass pattern as configurable regex (default `NO BLOCKING ISSUES`)
**Choice:** Treat `auto_merge_pass_pattern` as a regex string compiled at gate-check time.
**Rationale:** Spec calls out "configurable via `auto_merge_pass_pattern`, default this regex". Anchor is "this regex" → regex literal; default is the simple verbatim phrase. Operators who want to match e.g. case-insensitive variants override the regex.
**Reversal cost:** Low.

### DL-S4-2.8a-4: Auto-merge max-lines is strictly less than (`<`)
**Choice:** Reject when line count `>=` cap (strict less-than satisfies "PR diff line count … `< auto_merge_max_lines`").
**Rationale:** Matches spec verbatim. Simpler than "less than or equal" and avoids ambiguity at the boundary.
**Reversal cost:** Low.

### DL-S4-2.8a-5: `--merge` strategy only (no squash/rebase)
**Choice:** Always pass `--merge` to `gh pr merge`.
**Rationale:** Spec explicitly lists squash/rebase as out-of-scope. `--merge` is the lowest-blast-radius default and matches the human merge gate convention in `.claude/CLAUDE.md`.
**Reversal cost:** Low — add a `merge_strategy` config field if operator demand emerges.

### DL-S4-2.8a-6: AutoMerge.State is a JSON file, not ETS
**Choice:** Persist reviewed-pair set to disk via `priv/auto_merge_state.json` (overridable). Same persistence pattern as `PRSafety.PRState`.
**Rationale:** Survives orchestrator restarts. Avoids re-reviewing on each restart. ETS would lose state on crash. The dataset is small (one entry per Human-Review transition).
**Reversal cost:** Low.

---

## 5. Test Plan

| Test layer | Cases |
|---|---|
| `auto_merge_test.exs` | All 5 gates pass → merge happens → status → Done; each gate fails individually → no merge, item stays in Human Review; gh merge returns nonzero → Rework + Auto-Merge Failed workpad; Codex CLI fails → no merge, failure note posted; idempotent re-detection → no second Codex run. |
| `auto_merge/state_test.exs` | record + lookup; missing file = empty; concurrent record (last-write-wins). |
| `auto_merge/gh_default_test.exs` | line-count parsing; nonzero gh exit → error tuple. (Unit, no shell-out in CI.) |
| `codex_review_test.exs` | runner invocation arg shape; output captured; PHI scrubbed. |
| `monday/workpad_test.exs` | `render_codex_review/2` includes marker + scrubbed output; `render_auto_merge_failure/2` includes marker + sanitized stderr. |
| `monday/item_test.exs` | the new markers are filtered out of the description-from-updates path. |
| `agent_runner_test.exs` | After PR detection + Human Review transition, AutoMerge runner is invoked once with the right ctx. |

Targeted `mix test --no-start` runs per affected file. Full suite must remain green.

---

## 6. Codex Review Prompt (canonical)

```
Scrutinize PR <num> on <owner>/<repo>. Specifically check:
(a) correctness of new code,
(b) test coverage,
(c) regressions,
(d) security/PHI/HIPAA implications.

Conclude with the literal phrase "NO BLOCKING ISSUES" if you find none, or
"BLOCKING ISSUES FOUND" followed by a numbered list.
```

The prompt is rendered server-side by `AutoMerge.build_prompt/1` from the `pr_url` and the parsed `<owner>/<repo>/<num>` triplet.

---

## 7. Out of Scope

- Squash / rebase merge strategies. `--merge` only.
- Conflict resolution. If `gh pr merge` returns conflicts, item goes to `Rework` and a human resolves.
- Multi-reviewer escalation (e.g., escalate to a different reviewer profile).
- Per-repo Codex profile override (always uses `codex_gpt55_xhigh`).
- Operator-flip-only path detection (orchestrator scanning for un-reviewed Human Review items). This is a future M-8b — first cut wires the M-8 hook only. Manual operator flips that come AFTER an initial M-8 review will not re-trigger Codex review (idempotency guard via `AutoMerge.State`).

---

## 8. Acceptance Criteria → Implementation Map

| AC# | Spec text | Where implemented |
|---|---|---|
| 1 | On Human Review transition: spawn Codex review with prompt | `agent_runner.ex` calls `AutoMerge.evaluate_human_review/1` after the Human Review write; prompt rendered by `AutoMerge.build_prompt/1` |
| 2 | Capture Codex output, post to Workpad as `## Symphony Codex Review` | `Workpad.render_codex_review/2` + `Tracker.post_codex_review/2` |
| 3a | `auto_merge_on_codex_pass: true` (default false) | `Config.Schema.RepoEntry` field + gate 1 in `AutoMerge.evaluate_human_review/1` |
| 3b | Codex output contains pass pattern (configurable, default `NO BLOCKING ISSUES`) | `auto_merge_pass_pattern` field + gate 2 |
| 3c | PR diff line count < max_lines (default 500, configurable) | `auto_merge_max_lines` field + gate 3 via `AutoMerge.GH.pr_diff_line_count/1` |
| 3d | Base branch is main OR master | gate 4 via `AutoMerge.GH.pr_view_base/1` |
| 3e | Item still in Human Review | gate 5 via `Tracker.fetch_issue_states_by_ids/1` |
| 4 | All gates → status Merging, gh pr merge --merge --auto. Success → Done. Failure → Rework + Workpad | `AutoMerge.do_merge/1` |
| 5 | All shipped repos default to opt-out, symphony MUST stay opt-out | `WORKFLOW.md` comment + no `auto_merge_on_codex_pass: true` anywhere |
| 6 | Add new markers to `symphony_marker_prefixes` in `monday/item.ex` | `Monday.Item.@symphony_marker_prefixes` |
| 7 | Tests: each gate failure → no merge; all gates pass → merge; operator flip during review aborts | `auto_merge_test.exs` |
