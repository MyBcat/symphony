# Symphony — Monday.com Tracker Swap (Spec 1 of 2)

**Status:** Draft for review
**Date:** 2026-05-03
**Authors:** Ankit Patel + Claude (Opus 4.7)
**Sequencing:** Spec 1 of 2. **Spec 2** (`2026-05-03-symphony-multi-runtime-profiles.md`) depends on this and ships after.
**Modifies:** `SPEC.md` (tracker sections only), `elixir/WORKFLOW.md`, `elixir/lib/symphony_elixir/linear/**` → `monday/**`, `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`, `elixir/lib/symphony_elixir/tracker.ex`
**Does NOT modify:** Codex App Server adapter or any agent-runtime contract. Codex remains the sole supported coding-agent in this spec.
**Source design:** `2026-05-03-symphony-monday-multi-runtime-design.md` (superseded; design-intent reference only)
**Skills applied:** `agent_spec_writer` (format), `context-layer-generator` (per-part artifacts)
**Review-driven amendments + captured architecture context:**

| Amendment | Source | Applied where |
|---|---|---|
| **Tracker primitive (Symphony) owns Monday writes** — agent runs in workspace, Symphony observes events and writes outcomes to Monday | Captured decision OB_mybcat 2026-05-03 (MyBCAT agent factory two-tier architecture) — supersedes original "agent owns writes" preservation | §2.2, §3, DL-005 |
| Tech Board = DRIVER board (status changes trigger agents) | Captured 3-role board taxonomy (DRIVER / REFERENCE / MIRROR) | §1, DL-010 |
| Tech Board MUST NOT contain PHI (engineering items only) | Captured BAA gating dependency 2026-05-03 | §3, DL-011, §12 |
| 10-Layer Agent Operating Framework alignment (Layer 5: writes require approval; Layer 6: default to "propose") | Captured framework reference 2026-05-03 | DL-012 |
| `handoff_states` set distinct from `active_states` | Codex HIGH §1 | §1, §2, §5.3.1 cheat sheet |
| Dedicated Monday service user required | All 3 review agents on AW-4 | §3, DL-007 |
| Single Symphony instance per board enforced via heartbeat lock | All 3 review agents on AW-3 | §3, DL-008 |
| PHI logging policy authored inline (no defer to absent doc) | Codex HIGH §6 (`docs/logging.md` absent) | §12 |
| Stranded items get TTL → auto-Cancel after N consecutive failures | Claude MED #10 | §2.5 |
| All 4 open ambiguities (AW-1..AW-4) locked | Direct user instruction "stop asking questions" 2026-05-03 | §11 |

**Out of scope for Spec 1, deferred to future Spec 3:**

- Tier 2 DynamoDB telemetry layer (per captured two-tier architecture). File logs sufficient for v1; agent_runs table is Phase 2+ work.

---

## 1. System Overview

This spec retargets Symphony from Linear to Monday.com as the issue tracker. Coding-agent runtime is unchanged — Codex App Server only.

In MyBCAT's agent-factory architecture, Symphony plays two roles: **Orchestrator** (state machine, dispatch, retry, reconciliation) AND **Tracker primitive** (owns all Monday writes). Tech Board (`8173460438`) is classified as a **DRIVER** board: humans flip `Symphony Status` to `Symphony Ready` to enroll engineering work, Symphony picks it up, dispatches a Codex session in an isolated workspace, observes the agent's event stream, and writes outcomes back to Monday — status transitions, workpad summaries at milestones, PR URL on attachment, and terminal cleanup. The agent does not write to Monday directly; it does engineering work in the workspace and emits structured events.

The change introduces Monday-specific concepts: a dedicated `symphony_status` Status column on the target board (not the team's primary status), Monday Updates as the workpad surface (Symphony-written), and a derived `<prefix>-<item_id>` identifier scheme. Tech Board carries no PHI; engineering items reference clients only by anonymized identifier.

---

## 2. Behavioral Contract (system-level)

### 2.1 Polling and dispatch
- **When** Symphony reaches a poll tick, **the system** queries Monday for items on `tracker.board_id` whose `symphony_status_column_id` value matches one of `tracker.active_states`.
- **When** a candidate item is unclaimed and global concurrency permits, **the system** creates the per-item workspace and starts a Codex App Server session.
- **When** an item's `symphony_status` matches a value in `tracker.terminal_states`, **the system** stops any active session for that item, runs `before_remove` hooks, and removes the workspace.
- **When** an item's `symphony_status` matches a value in `tracker.handoff_states`, **the system** keeps the item claimed but stops dispatching new turns for it. Reconciliation polls continue until the state moves out of `handoff_states`. (Resolves Codex HIGH §1.)

### 2.2 Write ownership (Tracker primitive owns Monday writes)
- **The system** (Symphony, in its Tracker-primitive role) owns ALL Monday writes for boards classified as DRIVER. The agent does NOT write to Monday directly.
- **When** an agent session is dispatched, **the system** writes `symphony_status: In Progress` to the item.
- **When** the agent emits a turn-completion or final-summary event, **the system** writes `symphony_status: Human Review` if the agent reports a PR URL, otherwise leaves status unchanged for the orchestrator's continuation logic.
- **When** the agent's event stream contains a recognized PR URL pattern (`https://github.com/<org>/<repo>/pull/<n>`), **the system** writes that URL to the configured PR column.
- **When** the agent session ends (success, crash, timeout, or operator-initiated stop), **the system** writes a final workpad summary and, on abnormal exit, `symphony_status: Cancelled`.
- **When** an operator changes `symphony_status` to a value in `terminal_states`, **the system** does not write status — the operator already did. Symphony just stops the session and cleans up.

### 2.3 Workpad (Symphony-written milestone summaries)
- **When** an agent session starts, **the system** creates a `## Symphony Workpad` Monday Update with a session-start summary (timestamp, identifier, profile name, instance ID).
- **When** the agent crosses meaningful milestones (turn completion, PR open, completion event, error), **the system** appends or replaces the workpad with the latest summary. The workpad is a structured Symphony-managed artifact, not a free-form agent log.
- **When** more than one workpad Update is present (race or human duplication), **the system** detects it at session start and refuses to write until disambiguated. Operator alert; item left in `Symphony Ready`.
- The agent does NOT see or interact with the workpad. The agent's commentary is captured in workspace files (e.g., a markdown summary file the agent writes), and Symphony folds those into the workpad on milestone events.

### 2.4 Single-instance enforcement
- **When** Symphony starts, **the system** acquires a board-level lock by writing a heartbeat Update to a sentinel item (configured via `tracker.heartbeat_item_id`) with timestamp + Symphony instance ID.
- **When** a heartbeat is found within the last `tracker.heartbeat_ttl_ms` from a different instance ID, **the system** refuses to start and emits an operator-visible error.
- **When** Symphony stops cleanly, **the system** removes its heartbeat. On crash, the heartbeat expires after TTL.

### 2.5 Stranded item recovery
- **When** an item's dispatch attempt fails N consecutive times (configurable, default 5), **the system** writes `symphony_status: Cancelled` and posts a failure summary to the workpad before the workspace is removed. (Resolves Claude MED #10.)

---

## 3. Explicit Non-Behaviors

- The system MUST NOT support `tracker.kind: linear`. Linear support is removed in this spec.
- The system MUST NOT write to the team's existing primary Status column on the board. Symphony reads/writes only `symphony_status_column_id`.
- The system MUST NOT inject a `monday_graphql` tool into the agent's session. Agents do not write Monday directly (per Tracker-primitive ownership in §2.2).
- The system MUST NOT pick up items unless `symphony_status` ∈ `tracker.active_states`.
- The system MUST NOT dispatch new turns for items in `tracker.handoff_states` (`Human Review`, `Merging`).
- The system MUST NOT support multi-board polling. Each WORKFLOW.md targets exactly one Monday board.
- The system MUST NOT auto-create the `symphony_status` column or any other column on the board. Operator setup is a precondition.
- The system MUST NOT run more than one instance per board. Heartbeat lock enforces this.
- The system MUST NOT log full Monday item titles or update bodies in transport-level logs. Per §12 redaction policy.
- (Hardening goal, deferred to a future spec) The system SHOULD ultimately use a dedicated Monday service user. v1 ships against the existing shared `mybcat/integrations/api-keys/monday` AWS Secret per DL-007 amended.
- The system MUST NOT accept items whose title or description matches PHI patterns (SSN, DOB, plausible patient name format) at ingestion. Tech Board is a no-PHI surface per BAA gating (DL-011); items containing PHI MUST be rejected at dispatch with operator alert.
- The system MUST NOT write to any Monday surface beyond `symphony_status`, the configured PR column, and the workpad Update. No other column writes; no item creates; no item moves between groups.

---

## 4. Integration Boundaries

### Monday.com API
- **In:** GraphQL queries — items list, item details, board metadata, item updates, column values.
- **Out:** GraphQL mutations from Symphony — `change_simple_column_value` (for `Cancelled` cleanup writes only), `create_update` (heartbeat only).
- **Out:** GraphQL mutations from the agent (via injected `monday_graphql` tool) — `change_simple_column_value` (status transitions), `create_update` / `edit_update` (workpad), `change_multiple_column_values` (PR URL).
- **Endpoint:** `https://api.monday.com/v2`. Auth via `Authorization: <api_token>` header. Token MUST be tied to a dedicated Symphony service user.
- **Rate limits:** 5,000 complexity units per minute (Monday docs). Symphony's per-tick query budget capped at `tracker.complexity_budget_per_tick` (default 500). On 429, Symphony extends `polling.interval_ms` dynamically by `tracker.backoff_factor` (default 2.0) up to `tracker.max_polling_interval_ms` (default 60000).
- **On unavailable:** Symphony emits operator-visible error, retains last successful state, retries on next poll tick with exponential backoff up to `agent.max_retry_backoff_ms`.
- **Dev twin:** Existing `SymphonyElixir.Tracker.Memory` preserved. New `SymphonyElixir.Monday.Memory` for Monday-specific shape tests.

### Codex CLI (unchanged from existing)
- JSON-RPC over stdio via `codex app-server` per the existing Codex App Server protocol.
- Symphony does NOT inject a `monday_graphql` tool into the session. Per the Tracker-primitive ownership model (§2.2), Symphony observes the agent's event stream and writes Monday outcomes itself; the agent has no Monday access.
- The existing `linear_graphql` tool injection in `lib/symphony_elixir/codex/dynamic_tool.ex` is removed (not replaced with `monday_graphql`).

### Filesystem
- Reads/writes workspace directories under `workspace.root`; log files under configured `--logs-root`. Workspaces stay strictly under `workspace.root`. Symphony never executes agent commands in the source repo. (Unchanged.)

### Git / GitHub
- Out of scope for Symphony itself. Workspace `hooks.after_create` may clone repos; agents handle PR creation via their own tooling.

---

## 5. Behavioral Scenarios (eval-only)

### S1 — Happy path: full lifecycle (Symphony-driven Monday writes)
- **Setup:** New Tech Board item; user sets `symphony_status: Symphony Ready`.
- **Action:** Symphony's next poll tick.
- **Expected:**
  1. Symphony creates workspace, starts Codex App Server (no `monday_graphql` tool injected — agent has no Monday access).
  2. **Symphony writes `symphony_status: In Progress`** and creates the `## Symphony Workpad` Monday Update with a session-start summary.
  3. Agent does engineering work in the workspace per the WORKFLOW.md prompt (no Monday-related instructions).
  4. Agent opens a PR via the `gh` CLI; the PR URL appears in the agent's stdout/event stream.
  5. **Symphony observes the PR URL pattern in the stream and writes the URL to the configured PR column.**
  6. Agent emits a turn-completion event with a final summary written to a workspace file.
  7. **Symphony reads the workspace summary file, updates the workpad, and writes `symphony_status: Human Review`.**
  8. Symphony's next poll detects `Human Review` (handoff state); session is preserved but no new turns dispatch.
  9. Human approves; sets `symphony_status: Merging`.
  10. Symphony's poll picks up the new state; dispatches a follow-up Codex session whose prompt now includes the `land` task (PR merge). Agent runs `gh pr merge`. Output appears in the event stream.
  11. **Symphony observes successful merge and writes `symphony_status: Done`.**
  12. Symphony's next poll detects terminal state; runs `before_remove`; deletes workspace.

### S2 — Happy path: handoff state pause
- **Setup:** Symphony has written `symphony_status: Human Review` after observing PR URL + completion event.
- **Action:** Symphony's next reconciliation poll.
- **Expected:** Symphony observes `Human Review` (handoff state), stops dispatching new turns to this item, preserves the workspace and the Codex session for potential resumption. No new Monday writes for this item until state transitions.

### S3 — Happy path: clean restart resumes work
- **Setup:** Symphony is restarted. Three items are in `In Progress` from a prior run; workspaces exist on disk.
- **Action:** Symphony boots.
- **Expected:** Heartbeat lock acquired (no other instance present). Symphony's startup reconciliation queries Monday for items in `active_states`, finds the three; for each, the existing workspace is reused (no `after_create` re-run); a fresh Codex session starts and resumes work.

### S4 — Error: Monday API unavailable
- **Setup:** Mock Monday returns 5xx for 60 seconds.
- **Action:** Symphony enters its poll loop.
- **Expected:** Symphony logs operator-visible error per tick; does not dispatch new work; does not crash; in-memory item state unchanged. When Monday recovers, the next poll tick resumes normal dispatch.

### S5 — Error: another Symphony instance is already running on this board
- **Setup:** Heartbeat sentinel Update exists on `tracker.heartbeat_item_id` with a timestamp 30 seconds old, instance ID `xyz`.
- **Action:** Second Symphony instance attempts to boot.
- **Expected:** Symphony refuses to start, emits operator-visible error naming the conflicting instance ID and last heartbeat timestamp, exits with non-zero status.

### S6 — Edge: agent crashes mid-session
- **Setup:** Symphony has dispatched item to Codex; agent has run 5 turns. Codex App Server subprocess crashes.
- **Action:** Symphony observes the subprocess exit (abnormal).
- **Expected:** Symphony writes a final workpad summary noting the crash + last-known turn output, writes `symphony_status: Cancelled`, runs `before_remove` hooks, deletes the workspace, releases the claim.

### S7 — Edge: stranded item TTL
- **Setup:** An item dispatches and crashes 5 times in a row (each retry hits the same launch failure).
- **Action:** 6th poll tick.
- **Expected:** Symphony writes `symphony_status: Cancelled` and the failure summary to a new dedicated `## Symphony Failures` Update on the item (Symphony's only Update-write — distinct from the workpad which the agent owns), so operators see why dispatch stopped.

---

## 6. Tracker Layer Context Layers

### 6.1 Module Manifest

> Tracker primitive that polls Monday boards for items in active Symphony states, reads `symphony_status`, manages workspace dispatch, observes the agent's event stream, and writes outcomes back to Monday (status transitions, workpad summaries, PR URL). Agent has no Monday access; Symphony owns all writes per the captured DRIVER-board architecture.

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

#### Dependencies

| Dependency | Type | Description |
|---|---|---|
| Monday.com GraphQL API | sync API | Source of truth for item state, columns, updates |
| `SymphonyElixir.Config` | shared library | Reads `tracker.*` from WORKFLOW.md front matter |
| `:req` HTTP client | library (existing) | GraphQL transport |
| `MONDAY_API_TOKEN` env (dedicated service user) | secret | Auth header |

#### Dependents

| Dependent | Type | Description |
|---|---|---|
| `SymphonyElixir.Orchestrator` | sync calls | Polling, reconciliation, dispatch decisions; calls Monday writer functions on dispatch / state transitions / cleanup |
| `SymphonyElixir.AgentRunner` | sync calls | Calls Monday writer functions on session start, milestone events (PR URL detected, turn complete), and abnormal exit |
| `SymphonyElixir.PRDetector` | new module, indirect | Scans agent event stream for PR URL pattern; emits event consumed by AgentRunner |
| `SymphonyElixirWeb.DashboardLive` | sync calls | Item URL resolution |

#### Data Flows

| Direction | Source/Target | Data | Notes |
|---|---|---|---|
| Reads | Monday board items | id, name, column_values (`symphony_status`, priority, dependency, labels), updates | Filtered by `tracker.active_states` ∪ `tracker.handoff_states` |
| Writes (Symphony) | Monday `symphony_status` column | Status transitions on dispatch, milestone, cleanup | Tracker primitive owns all status writes per captured DRIVER-board model |
| Writes (Symphony) | Monday `## Symphony Workpad` Update | Session-start summary, milestone updates, completion summary, crash summary | Created at session start; edited in place via `edit_update` |
| Writes (Symphony) | Monday PR column | PR URL on detection in agent event stream | One write per item per session |
| Writes (Symphony) | Monday heartbeat sentinel item Update | Single-instance heartbeat refresh | Per `polling.interval_ms` |
| Writes (Symphony) | Monday `## Symphony Failures` Update | Failure summary for stranded items (post-TTL) | One write per stranded item |
| Reads | Workspace files | Agent's final summary file (markdown) for workpad rendering | Agent writes this in workspace; Symphony reads and renders into Monday Update |
| (NOT) Writes (agent) | Monday | — | Agent has no Monday access; no `monday_graphql` tool injection |

#### Shared Resources

| Resource | Shared With | Risk Notes |
|---|---|---|
| Monday API rate limit (5K complexity units/min) | `daily-report`, `appointment-data-gatherer` skills | Symphony's per-tick budget capped at 500 complexity (configurable); back-pressure on 429 by extending poll interval |

> **DARK CODE HOTSPOT:** Tech Board has 892 items, sprint-grouped. MUST filter by `symphony_status` at the GraphQL layer (`items_page` with column filter), never full board scan. Reviewer should verify the implementing agent does not introduce a fall-back full-scan path.

#### Deployment Model

- **Type:** Module within Symphony Elixir application (`lib/symphony_elixir/monday/*.ex`)
- **Runtime:** Elixir 1.19 / OTP 28
- **Infrastructure:** Single BEAM node; one instance per board (heartbeat-enforced)

#### Ownership

- **Team:** Symphony reference implementation (MyBCAT)
- **On-call:** Ankit Patel

### 6.2 Behavioral Contracts

**Context captured:** 2026-05-03 by Ankit Patel + Claude

---

#### `fetch_candidate_issues/0`

> Returns Monday items whose `symphony_status` ∈ `active_states` ∪ `handoff_states`.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure read. |
| **Failure behavior** | `{:error, reason}` on API/network/auth/schema failure. |
| **Performance envelope** | One GraphQL query per call. p50 200–800ms; p99 up to 5s. Complexity budgeted to ≤ `tracker.complexity_budget_per_tick`. |
| **Side effects** | None. |
| **Retry guidance** | Safe with exponential backoff. Observe 429 headers; extend poll interval before retry. |
| **Data classification** | Item titles may contain client names (PHI risk). Caller MUST apply redaction before logging per §12. |

##### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Network timeout | `{:error, :timeout}` | Skip tick; retry next |
| Auth failure | `{:error, :auth_failed}` | Operator alert; halt dispatch |
| Rate limited (429) | `{:error, :rate_limited}` | Extend poll interval; back off |
| Schema drift (column missing) | `{:error, {:schema, details}}` | Operator alert; pause dispatch |
| Complexity budget exceeded | `{:error, :complexity_budget}` | Extend poll interval; reduce per-tick query scope |

##### Warnings

- Subitem board `8173916705` ignored in v1.
- Items with `symphony_status` empty are not eligible (humans must explicitly set `Symphony Ready` to enroll).

---

#### `acquire_heartbeat/0` and `release_heartbeat/0`

> Acquires/releases the single-instance lock by writing/removing a heartbeat Update on the sentinel item.

| Property | Value |
|---|---|
| **Idempotent** | `acquire` is conditional — fails if a fresh heartbeat from a different instance exists. `release` is idempotent. |
| **Failure behavior** | `{:error, :lock_held_by_other}` on conflict. |
| **Performance envelope** | One GraphQL mutation per call. |
| **Side effects** | Mutates Monday Update on `tracker.heartbeat_item_id`. |
| **Retry guidance** | Acquire: do not retry — refuse to start. Release: safe, idempotent. |

##### Warnings

- Heartbeat TTL must exceed `polling.interval_ms` to avoid self-eviction. Default TTL 60s.
- The sentinel item MUST be a dedicated item operators agree never gets human writes; the heartbeat Update body is overwritten on every refresh.

---

#### `update_issue_state(item_id, state_name)` (all status writes — Tracker primitive)

> Writes `symphony_status` for all Symphony-driven transitions: dispatch (`In Progress`), milestone (`Human Review`), cleanup (`Cancelled`), and merge confirmation (`Done`).

| Property | Value |
|---|---|
| **Idempotent** | Yes. Same value is a no-op write. |
| **Failure behavior** | `{:error, reason}` on API failure or invalid state name. |
| **Performance envelope** | One GraphQL mutation, 300–1000ms. |
| **Side effects** | Mutates Monday board state visible to all users. May trigger automations attached to `symphony_status` (separate column from team's primary status, by design). |
| **Retry guidance** | Safe on network failures. Dangerous if a human moves the item manually during retry — caller MUST observe `:state_changed_during_write` and reconcile. |
| **Data classification** | Internal — state name is a label, not PHI. |

##### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Unknown state label | `{:error, :state_not_found}` | Operator config error — fix WORKFLOW.md states |
| Auth failure | `{:error, :auth_failed}` | Halt dispatch |
| Concurrent human write | `{:error, :state_changed_during_write}` | Reconcile on next poll |

##### Warnings

- All status transitions Symphony performs flow through this single function. Audit trail is via Monday's native column-history.
- A human-driven write to `symphony_status` always wins; Symphony reconciles on next poll rather than re-asserting.

---

#### `upsert_workpad(item_id, summary)` (Symphony-written workpad)

> Creates or updates the `## Symphony Workpad` Monday Update with a structured summary at session start, milestones, and completion.

| Property | Value |
|---|---|
| **Idempotent** | Conditional — find-or-create is idempotent on the marker; body content is overwritten. |
| **Failure behavior** | `{:error, :ambiguous_workpad}` if multiple workpad Updates exist (race or human duplication); `{:error, reason}` on API failure. |
| **Performance envelope** | 1 read + 0–1 mutation per call. 400–1500ms typical. |
| **Side effects** | Creates or modifies a Monday Update visible to all board members. |
| **Retry guidance** | Safe on network failures. On `:ambiguous_workpad`, do NOT auto-resolve — operator must disambiguate. |
| **Data classification** | Summary may contain workspace file paths and short agent commentary. Apply §12 redaction at boundary; never include full agent stdout in the body. |

##### Warnings

- The agent's workspace may contain a `_symphony_summary.md` file written by the agent for milestone surfacing. Symphony reads this file and folds it into the workpad. Symphony does NOT include arbitrary workspace files in the workpad.
- Workpad body length capped at 32KB; longer summaries are truncated with an explicit truncation marker.

---

#### `set_pr_url(item_id, pr_url)` (Symphony-written PR linkage)

> Writes the detected PR URL to the configured PR column.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Same URL is a no-op write. |
| **Failure behavior** | `{:error, reason}` on API failure. |
| **Performance envelope** | One GraphQL mutation, 300–1000ms. |
| **Side effects** | Mutates Monday board state. |
| **Retry guidance** | Safe. |
| **Data classification** | URL is a public github.com path; not PHI. |

##### Warnings

- PR URL is detected from the agent's event stream (`PRDetector` module). False-positive risk if the agent emits non-PR github URLs (e.g., issue links, gist URLs). Detector regex pinned to `pull/<digits>$` boundary.
- Only the FIRST detected PR URL is written. If the agent opens multiple PRs, subsequent URLs are ignored (operator can manually update if needed).

---

#### Agent has NO `monday_graphql` tool

> Per Tracker-primitive ownership in §2.2, no Monday write tool is injected into the agent session. The existing `linear_graphql` injection in `lib/symphony_elixir/codex/dynamic_tool.ex` is removed.

| Property | Value |
|---|---|
| **Rationale** | Captured architecture decision (OB_mybcat 2026-05-03): "Tracker primitive owns Monday writes." Mixing agent-side and Symphony-side writes creates double-write race conditions and breaks the 10-Layer Framework Layer 5 (writes require approval flag) and Layer 6 (default to "propose"). |
| **Agent-side substitutes** | The agent uses `gh` CLI (already on path in workspaces) to open PRs. The agent writes a `_symphony_summary.md` file in the workspace at completion; Symphony reads this for the workpad. |
| **Migration note** | Existing WORKFLOW.md prompt body must be rewritten to remove all "manage the Codex Workpad", "update_issue state", "comment on the issue" instructions. The new prompt body says only "do the work, open a PR, write `_symphony_summary.md` at completion." |

### 6.3 Decision Log

**Context captured:** 2026-05-03 by Ankit Patel + Claude

---

#### DL-001: Replace Linear with Monday.com (single tracker, not multi-tracker)

- **Date:** 2026-05-03
- **Context:** MyBCAT operates on Monday. Linear is not used. No present need for multi-tracker abstraction.
- **Alternatives considered:**
  - Multi-tracker with adapter pattern: Rejected — adds spec surface for no current need. Gemini disagreed (HIGH) and recommended preserving openness; Codex flagged staging risk (HIGH); we proceed with Monday-only but split into Spec 1 (this) and Spec 2 to reduce concurrent seam-replacement risk.
  - Keep Linear, add Monday: Rejected — leaves Linear-specific fields obscuring intent.
- **Consequences:**
  - Enables: smaller spec; Monday-specific config (`board_id`, column ids).
  - Constrains: forks wanting Linear must revert this spec.
- **Warning:** If reversed, `tracker` config schema diverges between trackers; `Tracker.adapter/0` dispatch must grow multi-kind. Identifier semantics differ — Linear has `MT-620` natively; Monday derives.

---

#### DL-002: State source = dedicated `symphony_status` Status column

- **Date:** 2026-05-03
- **Context:** Tech Board has 892 items, an existing `status` column wired into automations + a quality-score formula, and sprint-based groups.
- **Alternatives considered:**
  - Group-as-state: Rejected — Groups are organizational on this board.
  - Share existing `status`: Rejected — Symphony writes (or agent writes via injected tool) would trigger team automations not designed for AI transitions.
- **Consequences:**
  - Enables: zero blast radius on existing automations; explicit per-item opt-in.
  - Constrains: each Symphony-tracked board needs a new column.
- **Warning:** If reversed, every transition fires team automations including the Total Quality Score formula. Audit every existing automation on the team's status column before reversing.

---

#### DL-003: Workpad as a Monday Item Update (agent-owned)

- **Date:** 2026-05-03
- **Context:** Linear had `## Codex Workpad` comment. Monday Updates feed is the closest analog.
- **Alternatives considered:**
  - Long Text column: Rejected — column edits lack diff/edit semantics.
  - External store: Rejected — adds infra; loses board visibility.
- **Consequences:**
  - Enables: in-board visibility; native edit history.
  - Constrains: searchable only by header marker; race conditions if multiple Symphony instances target the same item (locked DL-008 single-instance constraint).
- **Warning:** If reversed (e.g., move workpad off Updates), every workpad reference in the spec must be retargeted; marker-based find logic becomes irrelevant; loses native Monday board visibility.

---

#### DL-004: Identifier scheme = `<prefix>-<item_id>` derived

- **Date:** 2026-05-03
- **Context:** Linear has `MT-620` style keys natively. Monday has only numeric item IDs (10-digit).
- **Alternatives considered:**
  - User-maintained Text column: Rejected — humans forget to fill it.
  - Monday formula column with sequence: Rejected — formulas don't persist; ID changes if rows are deleted.
- **Consequences:**
  - Enables: deterministic, zero-config.
  - Constrains: identifiers are long ugly numbers (e.g., `SYM-9482736152`); branch names are uglier. Implementing agent must verify branch-name regex tolerance and PR-title scanners (existing `dynamic_tool.ex` tool wiring).
- **Warning:** If reversed (using a user-maintained column), every existing identifier in workspaces, branches, PR titles becomes invalid. Migration required.

---

#### DL-005: Tracker primitive (Symphony) owns ALL Monday writes; agent has no Monday access

- **Date:** 2026-05-03 (captured-architecture-driven; supersedes earlier review-driven preservation)
- **Context:** The MyBCAT agent factory architecture captured in OB_mybcat on 2026-05-03 declares: *"Tier 1: Monday boards hold canonical state for human + agent coordination. Item status is source of truth. Tracker primitive owns Monday writes."* Boards are classified as DRIVER / REFERENCE / MIRROR; Tech Board is a DRIVER (status changes trigger agents). This decision binds Symphony, which fills both the Orchestrator and Tracker-primitive roles for Tech Board.
- **Alternatives considered:**
  - Agent-owned writes (preserves existing Linear model; Codex review's recommendation): Rejected — superseded by the captured factory architecture. Agent-owned writes break the 10-Layer Framework Layer 5 (writes require approval flag) and Layer 6 (default to "propose"). They also create double-write race conditions noted by Codex's own review.
  - Mixed writes (Symphony status, agent workpad): Rejected — same race-condition class.
  - Symphony-owned writes (Tracker primitive owns Monday): Selected. Aligns with captured architecture, 10-Layer Framework, and Codex's HIGH §1 finding.
- **Consequences:**
  - Enables: clean ownership boundary; auditable Monday writes (one writer); 10-Layer Framework alignment; no double-write race; supports future approval-gate integration (per Layer 6) without rearchitecting.
  - Constrains: existing WORKFLOW.md prompt body MUST be rewritten — removes all "update_issue state", "manage Codex Workpad", "create_comment" instructions for the agent. Agent's substitute: `gh` CLI for PRs, `_symphony_summary.md` workspace file for completion summary.
  - Constrains: Symphony must implement `PRDetector` to scan agent event stream for PR URLs; must read workspace summary file at completion; must own the workpad render logic.
- **Warning:** If reversed (re-introducing agent-side Monday writes via injected tool), the captured agent-factory architecture diverges between Symphony and the rest of the MyBCAT agent system, breaking the principle that Tracker primitive ownership is uniform. Race conditions return on `In Progress → Human Review` transitions. Audit trail becomes ambiguous (was that write Symphony or the agent?).

---

#### DL-006: `handoff_states` distinct from `active_states`

- **Date:** 2026-05-03 (review-driven amendment)
- **Context:** Codex flagged HIGH that the original `active_states: [Symphony Ready, In Progress, Human Review, Merging, Rework]` would cause the orchestrator to keep dispatching turns for items in `Human Review`, since the existing orchestrator continues every active state. Linear's existing workflow handles this implicitly because the agent stays alive in `Human Review` polling for review feedback; Monday's new model needs explicit handling.
- **Alternatives considered:**
  - Single `active_states` list: Rejected (HIGH bug per Codex).
  - Drop `Human Review`/`Merging` entirely: Rejected — they're load-bearing for the existing workflow.
  - New `handoff_states` set, semantically "claim the item but don't dispatch new turns": Selected.
- **Consequences:**
  - Enables: clean state-machine semantics; Symphony stops dispatching turns in handoff but keeps the workspace alive for resumption.
  - Constrains: orchestrator state-machine grows a new transition class.
- **Warning:** If reversed (collapsing back to single active list), the orchestrator infinite-loops on Human Review and Merging items — exactly the bug the original spec had.

---

#### DL-007: Reuse existing `mybcat/integrations/api-keys/monday` token; dedicated service user is Phase 2 hardening

- **Date:** 2026-05-03 (review-driven amendment locking AW-4; **amended in-flight** by operator decision 2026-05-03 to ship v1 against the existing shared MyBCAT Monday integration token rather than create a new dedicated user)
- **Context:** AWS Secrets Manager already holds `mybcat/integrations/api-keys/monday` — the general MyBCAT Monday integration token used by `daily-report`, `appointment-data-gatherer`, and (now) Symphony. Creating a dedicated `symphony@mybcat.com` user is a workspace-admin operation that adds setup friction. For Spec 1's tracker-swap velocity, reuse beats provisioning.
- **Alternatives considered:**
  - Dedicated service user (`symphony@mybcat.com`) — original DL-007: Rejected for v1 because the existing shared token already exists and works; deferred to a Phase 2 hardening task once Symphony usage patterns are observed.
  - Use Ankit's personal Monday token: Rejected — couples Symphony to a personal account; rotation risk.
  - Reuse existing `mybcat/integrations/api-keys/monday` shared integration token: Selected for v1.
- **Consequences:**
  - Enables: zero workspace-admin setup; ships immediately; co-evolves rate-limit budget with sibling integrations.
  - Constrains: workpad `edit_update` is bound to the token-owner's user_id (whoever generated the integration token); rotation to a different user requires coordinated rollout across `daily-report` + `appointment-data-gatherer` + Symphony; Monday audit log shows Symphony actions under the integration-token user, not under a Symphony-specific identity.
  - Constrains: rate-limit budget (5K complexity/min) is shared — Symphony's `complexity_budget_per_tick: 500` (§5.3.1) leaves headroom for sibling integrations; spike risk requires monitoring.
- **Warning:** If reversed (re-introducing a dedicated service user later), workpad Updates created against the integration-token user_id may not be editable by a new dedicated-user token. Migration plan: on cutover, post a fresh workpad as the new user (one Update transition per active item) before rotating; OR delete and re-create workpads. Treat this as a Phase 2 hardening project, not a v1 task.
- **Hardening backlog (Phase 2):** Create `symphony@mybcat.com` Monday user with board-scoped permissions; rotate Symphony to use a new secret `symphony/monday/api-token`; verify per-instance quota isolation; update DL-007 to lock dedicated-user posture.

---

#### DL-008: Single Symphony instance per board enforced via heartbeat lock

- **Date:** 2026-05-03 (review-driven amendment, locks AW-3)
- **Context:** All three review agents flagged that two Symphony instances polling the same board would silently double-dispatch. No Monday-side claim mechanism exists.
- **Alternatives considered:**
  - Document single-instance assumption without enforcement: Rejected (review consensus: this is a correctness precondition, not a guideline).
  - Distributed lock via external service (e.g., Redis): Rejected — adds infra dependency; Symphony has none today.
  - Heartbeat Update on a sentinel item: Selected. Self-contained within Monday.
- **Consequences:**
  - Enables: hard correctness guarantee; no double-dispatch; clear operator signal on conflict.
  - Constrains: requires one dedicated sentinel item per board; heartbeat Update consumes minor API quota (≤1 mutation per `polling.interval_ms`).
- **Warning:** If reversed (no enforcement), failover/restart scenarios produce double-dispatch silently. Two Codex sessions would race on the same workspace, causing file conflicts and corrupted PRs.

---

#### DL-009: PHI logging policy authored inline (not deferred to absent doc)

- **Date:** 2026-05-03 (review-driven amendment)
- **Context:** Codex's grounded review found `docs/logging.md` does not exist in the repo, despite being referenced from `elixir/AGENTS.md` and (in the original design) from §12 implementation constraints. Original spec deferred PHI redaction rules to that absent doc.
- **Alternatives considered:**
  - Defer to `docs/logging.md` (original): Rejected — doc is missing, would create a brittle link.
  - Author rules inline in §12: Selected.
  - Author a fresh `docs/logging.md` and link: Reasonable; can be done as a follow-up doc PR but spec must be self-contained.
- **Consequences:**
  - Enables: spec self-contained; review-grade redaction rules visible to implementing agent.
  - Constrains: §12 grows; if `docs/logging.md` is later authored, content must stay in sync (note in §12 to merge).
- **Warning:** If reversed (deferring to a doc that doesn't exist), implementing agent has no actionable redaction rules and may log full Monday item titles containing client names.

---

#### DL-010: Tech Board is a DRIVER board (per captured 3-role taxonomy)

- **Date:** 2026-05-03 (captured-architecture-driven)
- **Context:** OB_mybcat captured 2026-05-03 classifies MyBCAT's ~30 Monday boards into DRIVER (status changes trigger agents/humans into action), REFERENCE (read-only context, agents read but don't write), and MIRROR (reflects work happening elsewhere). Only 6-8 boards should be Drivers. Tech Board is one of them — humans flip Symphony Status to enroll engineering work; Symphony picks it up and transitions state.
- **Alternatives considered:**
  - Treat Tech Board as MIRROR (Symphony just reflects state from another system): Rejected — there is no other authoritative system for engineering work intake.
  - Treat as REFERENCE (read-only): Rejected — Symphony explicitly transitions state.
- **Consequences:**
  - Enables: clear taxonomy alignment; sets precedent for future Symphony-target boards.
  - Constrains: Tech Board's existing 5-status human workflow must accommodate the new `Symphony Status` column without conflict (already addressed via separate column DL-002).
- **Warning:** If reversed (downgrade Tech Board to non-DRIVER), Symphony cannot legitimately write status, and the entire orchestration loop becomes one-way (read-only on Monday). Dispatch is impossible.

---

#### DL-011: Tech Board contains no PHI (per Monday Enterprise BAA gating)

- **Date:** 2026-05-03 (captured-gating-driven)
- **Context:** The captured architecture identifies a binary gating dependency: *"Monday Enterprise BAA must be confirmed for any board holding PHI. Without BAA, Monday boards hold refs only and content stays in S3."* Tech Board's BAA status is unknown at spec time; the safe default is "Tech Board = no PHI." Engineering tasks reference clients only by anonymized identifier or by an S3 reference for any sensitive content.
- **Alternatives considered:**
  - Allow PHI in Tech Board items (assumes Enterprise BAA): Rejected — BAA status not confirmed; failure mode is HIPAA breach.
  - Reject items with PHI patterns at ingestion (defense in depth): Selected.
  - Encrypt PHI in items (custom encryption): Rejected — custom crypto outside compliance perimeter.
- **Consequences:**
  - Enables: Symphony operates safely on Tech Board regardless of BAA status; PHI never enters Symphony's processing path; agent prompts derived from items inherit no-PHI guarantee.
  - Constrains: pattern-detect SSN, DOB, plausible patient name format at ingestion; refuse dispatch with operator alert on hit. Engineers writing engineering items must use anonymized references.
- **Warning:** If reversed (allow PHI), Symphony becomes a HIPAA-relevant component. Audit trail, encryption-in-flight, BAA verification with every downstream service (Codex, Claude, Gemini), and breach-notification readiness all become required scope. Out of scope for this spec.

---

#### DL-012: 10-Layer Agent Operating Framework alignment (Layers 5, 6, 8)

- **Date:** 2026-05-03 (captured-framework-driven)
- **Context:** OB_mybcat captured 2026-05-03 references the MyBCAT 10-Layer Agent Operating Framework. Every agent must specify all 10 layers before shipping. Symphony-dispatched Codex sessions must comply.
- **Layers most directly affected by this spec:**
  - Layer 5 (Tool/Action) — "Writes require explicit approval flag set by a human." Symphony-owned Monday writes (DL-005) satisfy this: humans set `Symphony Ready` to authorize dispatch.
  - Layer 6 (Control/Approval) — "Default to 'propose' for anything consequential." Symphony does not auto-merge; humans must transition `Human Review → Merging`. PR open is "propose"; merge is operator-gated.
  - Layer 8 (Monitoring/Audit) — "Log every LLM interaction, tool call, state transition." Symphony's structured logs at the AgentRunner / Orchestrator boundary cover this; per-runtime token counts (Spec 2 territory) extend this.
- **Alternatives considered:**
  - Skip framework alignment for Symphony (Symphony as developer-tooling exception): Rejected — Symphony dispatches autonomous coding agents in production workspaces; same accountability as any operational agent.
  - Full framework specification of all 10 layers in this spec: Rejected — overweight; Layers 1, 2, 4, 7, 9, 10 are addressed implicitly via WORKFLOW.md, the workflow body, and Spec 2's profile design.
- **Consequences:**
  - Enables: Symphony fits into the broader MyBCAT agent governance model.
  - Constrains: Layer 6's "default to propose" makes auto-merge a non-feature; Symphony explicitly hands off via `Human Review` state.
- **Warning:** If reversed (auto-merge enabled), Layer 6 violation becomes a governance escape hatch the team must justify per agent. Maintain explicit human gate.

---

## 7. SPEC.md Concrete Diff Plan (Spec 1 scope only)

### Sections to retarget
- §3 System Overview — replace "Linear" mentions with "Monday.com"; preserve "agent owns ticket writes" framing.
- §4.1.1 Issue — replace `branch_name` semantics; broaden `identifier` definition to allow tracker-derived schemes.
- §5.3.1 tracker — full retargeting to Monday config fields; add `handoff_states`, `heartbeat_item_id`, `heartbeat_ttl_ms`, `complexity_budget_per_tick`, `backoff_factor`, `max_polling_interval_ms`, `failure_ttl_count`.
- §6.4 Cheat Sheet — rewrite tracker rows; add new rate-limit and heartbeat fields.
- §7 Orchestration — add `handoff_states` semantics to the state machine; add stranded-item TTL transition.

### New sections
- §6.6 PHI Logging Policy (inline; see §12 of this design doc for content).
- §7.x Single-instance heartbeat enforcement.

### Removed sections / fields
- All `tracker.kind: linear` references throughout SPEC.md.

### Renames (global)
- `## Codex Workpad` → `## Symphony Workpad` (across SPEC.md, WORKFLOW.md, and codex tool prompts).
- `linear_graphql` injected tool → REMOVED entirely (no `monday_graphql` replacement). Per DL-005, agents have no Monday access; Symphony owns writes.

### Prompt-body migration (required)
- Existing `elixir/WORKFLOW.md` body has 200+ lines of agent-side Linear management instructions ("Open the tracking workpad comment", "update_issue(..., state: ...)", "Search existing comments for marker header", etc.). All of this must be removed.
- Replace with a short prompt body matching §13 Sample WORKFLOW.md: "Do the engineering work, open a PR, write `_symphony_summary.md`. Symphony manages Monday."

---

## 8. Reference Implementation Deltas

| Existing path | New path / change |
|---|---|
| `lib/symphony_elixir/linear/` | renamed to `lib/symphony_elixir/monday/` |
| `lib/symphony_elixir/linear/client.ex` | rewritten — Linear GraphQL → Monday GraphQL |
| `lib/symphony_elixir/linear/adapter.ex` | rewritten as `monday/adapter.ex`; still implements `Tracker` behaviour |
| `lib/symphony_elixir/linear/issue.ex` | renamed `monday/item.ex`; identifier derivation logic added; PHI-pattern detector added (refuse items with SSN/DOB/patient-name patterns per DL-011) |
| `lib/symphony_elixir/codex/dynamic_tool.ex` | REMOVE `linear_graphql` tool injection; do not replace with `monday_graphql`. Module retained as the injection-mechanism scaffold for any future Symphony-specific (non-Monday) tool. |
| `lib/symphony_elixir/tracker.ex` | rewrite as the Tracker primitive contract: `update_issue_state/2`, `upsert_workpad/2`, `set_pr_url/2`, `post_failure_update/2`, `acquire_heartbeat/0`, `release_heartbeat/0`, `validate_no_phi/1`. All Monday writes flow through this module. |
| n/a | new `lib/symphony_elixir/monday/pr_detector.ex` — scans agent event stream for PR URL pattern; emits typed event |
| n/a | new `lib/symphony_elixir/monday/workpad.ex` — renders Monday Update body from session state + workspace summary file at milestone events |
| `lib/symphony_elixir/orchestrator.ex` | add `handoff_states` handling; add heartbeat acquire/release lifecycle; add stranded-item TTL counter; add Symphony-side write triggers on dispatch / milestone / cleanup |
| `lib/symphony_elixir/agent_runner.ex` | add: read `_symphony_summary.md` at agent completion; subscribe to PRDetector events; trigger Tracker writes on milestone events |
| `WORKFLOW.md` | rewrite example with Monday tracker; **rewrite prompt body** to remove all agent-side Monday management; add `_symphony_summary.md` workspace contract |
| `mix.exs` | `ignore_modules` list updated for renames; new modules added |
| `make e2e` | live test rewritten to create disposable Monday board+items; verifies Symphony-side writes (status, workpad, PR URL) appear correctly without agent-side Monday access |

Behaviour expansion summary (`tracker.ex`):
- `fetch_candidate_issues/0`, `fetch_issues_by_states/1`, `fetch_issue_states_by_ids/1` — read paths (unchanged in shape)
- `update_issue_state/2` — Symphony-driven status writes (NOT cleanup-only as in earlier draft)
- `upsert_workpad/2` — NEW: Symphony-driven workpad writes
- `set_pr_url/2` — NEW: Symphony-driven PR linkage
- `post_failure_update/2` — NEW: stranded-item failure summary
- `acquire_heartbeat/0`, `release_heartbeat/0` — NEW: single-instance enforcement
- `validate_no_phi/1` — NEW: PHI-pattern check (DL-011)
- (REMOVED) `create_comment/2` — no longer needed; agent has no Monday access

---

## 9. Tech Board Setup Checklist (board `8173460438`)

1. Create the dedicated `Symphony Status` Status column. Labels: `Symphony Ready`, `In Progress`, `Human Review`, `Merging`, `Rework`, `Done` (mark as done), `Cancelled`. Note: `Human Review` and `Merging` will be configured as `handoff_states` in WORKFLOW.md, not `active_states`.
2. Create the `Symphony PR` Link column.
3. Create a dedicated heartbeat sentinel item (e.g., named `[Symphony Heartbeat — DO NOT EDIT]`) and capture its item ID for `tracker.heartbeat_item_id`.
4. Create a dedicated Monday user `symphony@mybcat.com` (or similar). Grant board-level read+write permissions ONLY to Tech Board. Create the API token under that user.
5. Store the token in AWS Secrets Manager via `secret-store create symphony/monday/api-token "Symphony service-user token"`.
6. Record the resulting column IDs in WORKFLOW.md `tracker.*_column_id` fields.
7. Verify token has `boards:read`, `boards:write`, `updates:write` scopes.

---

## 10. Out of Scope for Spec 1 (Deferred to Spec 2)

1. Multi-runtime agent abstraction (Codex remains the only supported runtime in Spec 1).
2. Named profiles + per-issue routing.
3. Per-profile concurrency caps.
4. Profile column on Tech Board.
5. Sandbox safety floor for non-Codex runtimes.

These are addressed in `2026-05-03-symphony-multi-runtime-profiles.md`, which depends on Spec 1 having shipped.

Permanent out-of-scope (both specs):
- Multi-board polling.
- Multi-tracker support.
- Sub-item handling (Tech Board's subitem board `8173916705` ignored).
- Cross-instance Symphony clustering (heartbeat enforces single-instance).

---

## 11. Ambiguity Warnings — All Locked

Per Ankit's 2026-05-03 instruction ("don't keep answering questions, use captured context"), all four open ambiguities are now locked. The implementing agent treats these as binding constraints, not optional defaults.

### AW-1 — Description fallback behavior — LOCKED: HARD FAIL
- **Decision:** If `tracker.description_column_id` is unconfigured, Symphony refuses to boot. Operator MUST explicitly set the column ID or set the value to `"first_update"` to opt into the fallback.
- **Rationale:** Aligns with 10-Layer Framework Layer 3 (least-privilege whitelist of specific columns) — explicit configuration over silent fallback.
- **Implementation:** Startup config validation rejects unconfigured `description_column_id`; orchestrator does not enter polling until resolved.

### AW-2 — Branch column fallback — LOCKED: SILENT FALLBACK to identifier
- **Decision:** If `tracker.branch_column_id` is empty for an item (or unset globally), branch_name = `<identifier_prefix>-<item_id>`.
- **Rationale:** Branch name is derived data, not security-critical. Existing Linear behavior matches this pattern. Forcing operators to populate a branch column for every engineering item is friction with no safety value.
- **Implementation:** `Monday.Item` derivation function falls back to identifier without warning.

### AW-3 — Heartbeat sentinel item must exist — LOCKED: HARD FAIL
- **Decision:** If `tracker.heartbeat_item_id` points to a non-existent or deleted item, Symphony refuses to boot.
- **Rationale:** Single-instance enforcement (DL-008) is a correctness precondition. A missing heartbeat item silently disables the lock and re-introduces the double-dispatch failure mode all three review agents flagged.
- **Implementation:** Startup `acquire_heartbeat/0` returns `{:error, :sentinel_missing}` on 404; Symphony exits non-zero with operator-actionable error.

### AW-4 — Stranded item TTL window — LOCKED: COUNT-ONLY, default 5
- **Decision:** `failure_ttl_count: 5` is the only stranded-item TTL mechanism in v1. Five consecutive dispatch failures → write `Cancelled` + failure summary. Time-based TTL is deferred to a future spec.
- **Rationale:** Count-based is simpler to reason about and test; time-based adds clock-drift edge cases. v1 needs a tractable default; tune later based on observed failure patterns.
- **Implementation:** Per-item failure counter in orchestrator state; resets on successful dispatch; triggers cleanup on 5th consecutive failure.

---

## 12. Implementation Constraints (with inline PHI logging policy)

### General
- Reference language: Elixir 1.19 / OTP 28.
- Quality gates: `make all` must pass — `mix format --check`, `mix lint`, `mix test --cover`, `mix dialyzer`.
- `@spec` requirement: every public `def` in `lib/` MUST have an adjacent `@spec`.
- Shell command formatting: any shell command shown in the spec, WORKFLOW.md examples, or repo docs MUST be a single-line bash block.
- No new infra dependencies.

### PHI / Data Handling Policy (inline; per DL-009)

The `docs/logging.md` referenced from `elixir/AGENTS.md` does not exist in the repo as of 2026-05-03. This section authoritatively states the redaction rules until that doc is authored.

**Rule 1 — Required context fields in logs:**
- `issue_id` (Monday item id, numeric, stable foreign key)
- `issue_identifier` (derived `<prefix>-<item_id>`, no PHI by construction)
- `session_id` (Codex thread/turn ID, no PHI)

**Rule 2 — Forbidden in logs:**
- `issue.title` body in plaintext
- `issue.description` body in plaintext
- Monday Update bodies (workpad content, failure-summary content) in plaintext
- Tool-call payloads from the agent's `monday_graphql` tool in plaintext

**Rule 3 — Required redaction at the adapter boundary:**
- The Monday adapter (`lib/symphony_elixir/monday/adapter.ex`) MUST implement a `redact/1` helper applied to issue records before any logging.
- `redact/1` MUST replace `title` and `description` with `<redacted:n_chars>` placeholders preserving length only.
- Update bodies MUST be hashed (SHA-256, first 8 hex chars) when referenced in logs, not stored verbatim.

**Rule 4 — Redaction enforcement:**
- A unit test MUST assert that the adapter never returns a logged term containing the literal title/description bytes.
- A `dialyzer` contract OR a custom `credo` check MUST flag any direct `Logger.info`/`Logger.error` call passing `issue.title` or `issue.description` arguments.

**Rule 5 — `monday_graphql` tool prompts:**
- Prompts that the agent emits via the `monday_graphql` tool may legitimately contain PHI in queries/mutations. Symphony does NOT inspect tool payloads. The Monday API token's user-level permissions are the trust boundary.

**Rule 6 — Workpad content:**
- The workpad is NOT a log surface. It's an item-scoped Monday Update visible only to authorized board members. Symphony does not extract or relog its content.

### Backwards compatibility
- None required for Spec 1. Linear support is removed. This is a clean spec line break.

---

## 13. Sample WORKFLOW.md (informative)

```yaml
---
tracker:
  kind: monday
  api_token: $MONDAY_API_TOKEN
  endpoint: https://api.monday.com/v2
  board_id: 8173460438
  identifier_prefix: "SYM"
  symphony_status_column_id: "color_mm30c3vb"
  pr_column_id: "link_mm30ak49"
  heartbeat_item_id: 11909898073
  heartbeat_ttl_ms: 60000
  complexity_budget_per_tick: 500
  backoff_factor: 2.0
  max_polling_interval_ms: 60000
  failure_ttl_count: 5
  priority_column_id: "status_1_mkm9bt8j"
  description_column_id: null
  branch_column_id: null
  labels_column_id: "dropdown_mkwbsh98"
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
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: "codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on a Monday.com item `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the item is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
  {% endif %}

Item context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current Symphony status: {{ issue.state }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. You do NOT have access to Monday.com. Symphony manages all Monday writes (status transitions, workpad updates, PR linkage) based on observing your event stream and the workspace files you write.
3. Do the engineering work needed to satisfy the item description.
4. Open a pull request via `gh pr create` when the work is ready for human review. Symphony detects the PR URL in your output and writes it to Monday.
5. At completion, write a markdown summary to `_symphony_summary.md` in the workspace root. Include:
   - One-paragraph description of what changed
   - Test plan executed
   - Any open concerns or follow-ups
   - Symphony will fold this into the Monday workpad on completion.
6. Do not exit voluntarily until the PR is open. If blocked by missing tools, secrets, or permissions, write the blocker to `_symphony_summary.md` and exit with a clear final message.
```

---

## 14. Approval Checklist

- [ ] §1 — System overview reflects Monday-only retarget; agent-owned write model preserved.
- [ ] §2 — Behavioral contract correctly partitions Symphony-reads vs agent-writes (DL-005); handoff_states semantics clear (DL-006).
- [ ] §3 — Non-behaviors lock single-instance, dedicated token, agent-owned writes.
- [ ] §4 — Integration boundaries show Monday API + Codex CLI + filesystem + git.
- [ ] §5 — 7 scenarios (3 happy, 2 error, 2 edge); S1 walks the full agent-owned-write lifecycle.
- [ ] §6 — Tracker layer Module Manifest + Behavioral Contracts + Decision Log present.
- [ ] §7 — SPEC.md diff plan is concrete and tracker-scoped (no agent-runtime changes).
- [ ] §8 — Reference impl deltas tracker-scoped; Codex adapter unchanged.
- [ ] §9 — Tech Board setup includes heartbeat item + dedicated service user.
- [ ] §10 — Out-of-scope items deferred to Spec 2 are explicit.
- [ ] §11 — 4 remaining ambiguities are minor; all major review findings locked.
- [ ] §12 — PHI logging policy authored inline; no defer to absent doc.
- [ ] §13 — Sample WORKFLOW.md uses single Codex profile, agent-owned writes, handoff_states.
