# Plan — SYM-11942134820: Symphony M-4a — Consolidate failure updates + enforce retry cap

## Goal

Replace AgentRunner's per-attempt `## Symphony Failures` Monday Updates with a single consolidated Monday Update posted by the Orchestrator at retry-cap exhaustion, and route every failure-shaped exit (including stalled restarts) through the retry-cap counter.

## Why

M-4 (PR #16) wired `emit_failure_update*` into every AgentRunner error site so failures land on Monday. Result today: a stranded issue with retry cap = 5 produces up to 5 Monday Updates (one per attempt) plus a final stranded summary — six writes per stuck item. M-4a consolidates those into one final Update and ensures the cap is enforced for all failure paths, including stalls (which currently bypass `record_dispatch_failure`).

## Acceptance criteria

- AgentRunner does NOT call `Tracker.post_failure_update/2` from any error site. Every per-attempt failure becomes an in-process message, not a Monday write.
- Failures from AgentRunner are sent to the orchestrator's recipient pid as `{:agent_failure, issue_id, entry}` where `entry` carries `attempt`, `reason_atom`, `message`, `occurred_at`, and `stderr_tail` (when available).
- Orchestrator accumulates a per-issue `failure_history :: %{issue_id => [entry]}` capped at `tracker.failure_ttl_count` entries.
- When the retry cap is reached, `apply_stranded_ttl/3` posts ONE consolidated Monday Update via `Tracker.post_failure_update/2` with:
  - The existing `Stranded after N consecutive failures: <reason>` header (preserved for tests + dashboard parsing).
  - One bulleted attempt block per accumulated entry (`{iso8601_utc} | profile=… | repo=… | reason=…` followed by message; reuses existing M-4 line format for operator familiarity).
- Stalled-issue restarts (`restart_stalled_issue/5`) flow through `record_dispatch_failure/3` so they count toward the cap; today they only call `schedule_issue_retry/4` and could loop forever.
- `failure_history` is cleared whenever `failure_counts` is cleared (terminate, complete, dispatch, stranded) so memory is bounded.
- Existing M-4 marker / PHI / 8 KiB rules at the Monday Adapter layer are unchanged.
- Existing stranded-TTL test passes with the new consolidated body shape; new tests cover (a) no Monday write on a single failure, (b) the final body lists each attempt, (c) stalled restarts contribute to the cap.

## Files to touch

- `elixir/lib/symphony_elixir/agent_runner.ex`
  - Add `:failure_recipient` to the session map built by `build_session/3` (sourced from `codex_update_recipient`).
  - Replace `Tracker.post_failure_update/2` inside `emit_failure_update/4` with a `send/2` of `{:agent_failure, issue_id, entry}` to `session.failure_recipient` when it's a live pid; otherwise log + drop.
  - Keep the `emit_failure_update/4` and `emit_failure_update_via_writer/4` signatures so call sites compile unchanged. (The functions become "send a structured failure event to the orchestrator" instead of "post to Monday".)
  - Pass an `attempt` opt through from AgentRunner.run/3 (already in `opts[:attempt]`) so the entry carries the same attempt number that the orchestrator schedules retries with.
- `elixir/lib/symphony_elixir/orchestrator.ex`
  - Add `failure_history: %{}` to `State`.
  - Add `handle_info({:agent_failure, issue_id, entry}, state)` that appends `entry` to `failure_history[issue_id]` (capped, FIFO drop oldest if a buggy runner spams).
  - Extend `record_dispatch_failure/3` to also store the latest entry under `failure_counts[issue_id].latest_entry` so the body has a fallback when no `:agent_failure` arrived (e.g. spawn failure before runner even starts).
  - Update `apply_stranded_ttl/3` to render the consolidated body from `failure_history[issue_id]` (latest entry if history empty) and post it once via `Tracker.post_failure_update/2`.
  - Clear `failure_history[issue_id]` everywhere `failure_counts[issue_id]` is cleared (`spawn_issue_on_worker_host/5`, `terminate_running_issue/3`, `complete_issue/2`, `apply_stranded_ttl/3`).
  - Route `restart_stalled_issue/5` through `record_dispatch_failure/3` so stalls increment the cap; if it returns `{:stranded, state}`, do NOT call `schedule_issue_retry/4`.
- `elixir/test/symphony_elixir/agent_runner_test.exs`
  - Replace the three `emit_failure_update*` tests under "failure observability" with new tests that:
    - Pass `self()` as the recipient via the session map.
    - Assert `assert_receive {:agent_failure, _issue_id, %{reason_atom: …, message: …}}` instead of inspecting `MemoryMonday.events()`.
    - Confirm no `:failure_write` event lands on `MemoryMonday`.
- `elixir/test/symphony_elixir/orchestrator_test.exs`
  - Extend `"5 consecutive dispatch failures …"` test to also assert each per-attempt block appears in the consolidated body.
  - Add `"single dispatch failure does not post a Monday Update"` test.
  - Add `"stalled restart counts toward retry cap"` test that pre-loads a stalled running entry and triggers `reconcile_stalled_running_issues/1` enough times to hit the cap; asserts `Cancelled` write + consolidated `failure_write`.
  - Add `":agent_failure messages append to failure_history"` test that sends the message and inspects `:sys.get_state/1`.

## Out of scope

- Changes to `Monday.Adapter.post_failure_update/2` (marker prefix, PHI scrub, 8 KiB cap, UTF-8 boundary truncation) — preserved.
- Cost-cap path (`{:shutdown, :cost_cap_exceeded}`) — already separate; not touched.
- Treating `:max_turns_exceeded` as a cap-incrementing failure — current "continuation retry" semantics preserved. Recorded as future work in the PR description.
- Workpad rendering of `Workpad.render_failure/1` — unchanged. The consolidated orchestrator body uses the same per-line shape but doesn't need a Workpad helper since it is bullets, not a workpad block.
- New config knobs — `tracker.failure_ttl_count` (default 5) is reused as the consolidation/cap threshold.
- Dashboard LiveView — `/failures` still derives from running entries + last events; no schema changes required.

## Risks / unknowns

- **Message ordering across `{:agent_failure, …}` and `{:DOWN, …}`.** Both originate from the same Task pid, so Erlang's per-sender FIFO ordering applies and the orchestrator processes the agent_failure first. The DOWN handler can rely on `failure_history[issue_id]` already containing the entry.
- **Tests that previously expected Monday writes from AgentRunner.** All affected tests are in `agent_runner_test.exs` (3 tests) — rewritten to use message-receive assertions.
- **Memory growth for stuck issues.** Bounded by the cap (default 5 entries). Capping the list explicitly in the handler covers the case where a buggy runner spams.
- **Older M-4 PRs / dashboards parsing the per-attempt Updates.** No external consumer parses these — the dashboard reads in-memory state, not Monday Updates. Operators reading Monday will still see one `## Symphony Failures` Update with the same line shape, just bundled.
- **Backwards compat for ad-hoc callers of `emit_failure_update*`.** Public surface for AgentRunner; only internal callers exist in this repo. No external module references them outside tests.
