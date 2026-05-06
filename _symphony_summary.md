# Symphony Summary — SYM-11942134820

**Task:** [Symphony M-4a] Consolidate failure updates — one final summary + enforce retry cap

**Branch:** `symphony/SYM-11942134820/attempt-1`

**PR:** https://github.com/MyBcat/symphony/pull/29

**Status:** Open — awaiting `/codex:rescue` review per `.claude/CLAUDE.md`.

---

## What changed

Replaced AgentRunner's per-attempt `## Symphony Failures` Monday Updates with a single consolidated Update the Orchestrator posts at retry-cap exhaustion. AgentRunner now sends a structured `{:agent_failure, issue_id, entry}` message to the orchestrator's recipient pid at every error site instead of writing to Monday on each retry. The orchestrator accumulates per-issue history (bounded by `tracker.failure_ttl_count`, default 5, FIFO-trimmed) and renders one consolidated body — header + per-attempt blocks (timestamp / profile / repo / reason / message / optional stderr tail) — at stranded TTL. Stalled-issue restarts (`reconcile_stalled_running_issues/1`) now flow through `record_dispatch_failure/3` so they count toward the cap; previously a repeatedly-hanging agent could be restarted forever.

## Plan vs reality

The shipped diff matches `_symphony_plan.md`:

- Files touched are exactly the four identified in the plan plus `WORKFLOW.md`.
- AgentRunner public surface (`emit_failure_update/4`, `emit_failure_update_via_writer/4`, `build_session/3` defaults) is preserved; `build_session/4` arity is added with a default-`nil` recipient so all existing call sites compile.
- The consolidated body's header is unchanged (`Stranded after N consecutive failures: <reason>`) so the existing M-4 stranded-TTL test passes without modification.
- One small extension over the plan: `restart_stalled_issue/5` appends a synthetic `:stalled` failure_history entry so the consolidated body still shows per-attempt detail when every attempt was a hang (the runner never reaches an `:agent_failure` send site, so without this the body would contain only the header).
- `WORKFLOW.md` got a comment annotating the new dual role of `failure_ttl_count` (retry cap + history cap).

## Test plan executed

- New plan committed first to `_symphony_plan.md` and pushed before any code change (the "plan vs reality" contract).
- Static review of all five files (agent_runner, orchestrator, both test files, WORKFLOW.md) for compilation issues, message ordering, and pattern-match coverage.
- Updated existing M-4 tests in `agent_runner_test.exs` to the new contract (structured message + zero Monday writes) and added a dead/missing-recipient case.
- Added four new orchestrator tests: single failure does NOT post a Monday Update, `:agent_failure` history is FIFO-capped at `failure_ttl_count`, stranded body lists every captured attempt, and stalled restarts contribute to the retry cap.

## Open concerns / follow-ups

- **`mix test --no-start` was NOT run locally.** The agent sandbox lacks a usable Erlang/Elixir toolchain — `mise install` tried to compile OTP from source and there is no `gcc`/`cc` in-sandbox, and the host wrappers under `/var/run/host/usr/share/elixir/.../bin` shebang to `/usr/bin/elixir` which doesn't exist inside the sandbox. The implementation was static-reviewed against the existing M-4 contract; per `.claude/CLAUDE.md` the merge gate is `/codex:rescue` so logic regressions get caught there + on CI.
- `:max_turns_exceeded` still does not increment the retry cap — current "continuation retry" semantics preserved (out of scope per the plan). Future work if operators want max_turns to also trip the cap.
- `terminate_running_issue/3` intentionally does NOT clear `failure_counts` / `failure_history` — both are cleared only on spawn-success, completion, and stranded TTL. Stalled restart relies on this so the counter persists across iterations. If a future change wants to clear them on terminate, that would silently break the stalled-cap test.
- The shipped consolidated body uses the "Attempt history:" prefix + `- attempt N: …` bullets. If operators want a more compact one-liner, that's a downstream rendering tweak, not a logic change.
- **Mid-flight merge of origin/main.** `main` advanced with the M-0a Codex-0.128 adapter rewrite (#28) while this PR was open, which left #29 in a `CONFLICTING` state. Resolved by merging `origin/main` into the branch (commit `321e79e`): the only content conflicts were in `_symphony_plan.md` / `_symphony_summary.md` (per-ticket workspace files — kept this branch's versions). `WORKFLOW.md` and `agent_runner_test.exs` auto-merged cleanly because the M-0a edits target the Codex profile / adapter test fixtures while M-4a's edits target failure-observability tests. Post-merge `gh pr view 29` reports `mergeable: MERGEABLE`.

## PR URL

https://github.com/MyBcat/symphony/pull/29
