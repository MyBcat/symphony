# Symphony — Monday.com Tracker + Multi-Runtime Agents + Profile Routing

> **STATUS: SUPERSEDED — DESIGN-INTENT REFERENCE ONLY**
>
> After multi-AI ensemble review (`/agent-team` 2026-05-03; Codex + Gemini + Claude code-reviewer), this unified spec was split into two staged execution specs to reduce concurrent seam-replacement risk and to apply HIGH-severity findings:
>
> 1. **Spec 1 — Monday tracker swap (single-runtime, Codex preserved):** `2026-05-03-symphony-monday-tracker-swap.md`
> 2. **Spec 2 — Multi-runtime + profiles (depends on Spec 1):** `2026-05-03-symphony-multi-runtime-profiles.md`
>
> Use this document only for design intent and locked-decision rationale. The two execution specs above carry the implementation contract.
>
> **Findings that drove the split (from review synthesis):**
> - Codex (HIGH): "spec collapses two large seam replacements into one PR"
> - Codex (HIGH): "spec says agent owns ticket writes, but workpad/status contracts make Symphony mutate Monday" — **Spec 1 reverts to agent-owned writes (existing Symphony model)**
> - Codex (HIGH): "Human Review in active_states would keep agents running" — **Spec 1 introduces handoff_states**
> - Claude (HIGH): "Profile column is a privilege-escalation path" — **Spec 2 adds sandbox safety floor**
> - Claude (HIGH): "Token accounting B.1 contradicts §2" — **Spec 2 picks runtime-native pass-through**
> - All three (HIGH): AW-3, AW-4, AW-5, AW-6 are correctness preconditions, not warnings — **locked in Spec 1 and Spec 2**

**Status:** Draft for review (superseded)
**Date:** 2026-05-03
**Authors:** Ankit Patel + Claude (Opus 4.7) via brainstorming session 2026-05-03
**Modifies:** `SPEC.md`, `elixir/WORKFLOW.md`, `elixir/lib/symphony_elixir/**`
**Skills applied:** `agent_spec_writer` (overall format), `context-layer-generator` (per-part Module Manifest + Behavioral Contracts + Decision Log)

---

## Locked Design Decisions (from brainstorming)

| # | Fork | Resolution |
|---|---|---|
| 1 | Tracker scope | Replace Linear with Monday.com (single tracker, no multi-tracker spec surface) |
| 2 | State source | Status column (not Group) |
| 3 | Greenfield vs brownfield | Brownfield — Tech Board (`8173460438`) is reference |
| 4 | State column model | Separate `symphony_status` column (not shared with team's primary status) |
| 5 | Agent runtime shape | First-class multi-runtime abstraction (Codex / Claude / Gemini, native adapters) |
| 6 | Routing model | Named profiles + per-issue Monday column override; default profile fallback |

---

## 1. System Overview

Symphony is a long-running orchestration service that polls an issue tracker, creates per-issue workspaces, and runs autonomous coding-agent sessions until tracker state transitions out of an active set. This spec retargets Symphony from Linear-only with Codex-only to Monday.com-only with multi-CLI agents (Codex, Claude, Gemini), and introduces named "agent profiles" so each Monday item can be routed to a specific runtime + model combination via a per-item dropdown column.

The system continues to be a scheduler/runner; ticket writes (state transitions, comments, PR links) are still performed by the agent using its own tooling, with Symphony providing the orchestration around it.

---

## 2. Behavioral Contract (system-level)

### Polling and dispatch
- **When** Symphony reaches a poll tick, **the system** queries Monday for items on `tracker.board_id` whose `symphony_status_column_id` value matches one of `tracker.active_states`.
- **When** a candidate item is unclaimed and global concurrency permits, **the system** resolves an agent profile per §3.3 routing rules, creates the per-item workspace, and starts an agent session.
- **When** an item's `symphony_status` transitions to a value in `tracker.terminal_states`, **the system** stops the active session for that item, runs `before_remove` hooks, and removes the workspace.

### Workpad
- **When** an agent session starts, **the system** ensures a `## Symphony Workpad` Monday Update exists on the item, creating one if absent.
- **When** the agent emits workpad-affecting actions, **the system** edits the existing Update in place via `edit_update`.
- **When** more than one workpad Update is present (concurrency or human duplication), **the system** refuses to write and emits an operator-visible ambiguity error.

### Routing resolution
- **When** a candidate item has a non-empty profile column value, **the system** uses `profiles[<value>]`.
- **When** the per-issue profile column is empty, **the system** falls back to `agent.default_profile`.
- **When** neither resolves to a profile defined in `profiles`, **the system** raises a configuration error, skips dispatch for that item, and emits an operator-visible warning.

### Multi-runtime
- **When** a profile selects `kind: codex`, **the system** uses the Codex adapter and the Codex App Server JSON-RPC protocol over stdio.
- **When** a profile selects `kind: claude`, **the system** uses the Claude adapter and the Claude Code SDK streaming JSON protocol over stdio.
- **When** a profile selects `kind: gemini`, **the system** uses the Gemini adapter and the Gemini CLI streaming JSON protocol over stdio.
- **When** a profile's `kind` is unrecognized, **the system** raises a configuration error at startup.

### Token accounting
- **When** an agent session reports token usage, **the system** stores tokens under runtime-neutral fields (`agent_input_tokens`, `agent_output_tokens`, `agent_total_tokens`). Cross-runtime normalization is not performed.

---

## 3. Explicit Non-Behaviors

- The system MUST NOT support `tracker.kind: linear`. Linear support is removed in this spec line.
- The system MUST NOT write to the team's existing primary Status column on the board. Symphony reads/writes only `symphony_status_column_id`.
- The system MUST NOT pick up Monday items unless their `symphony_status` value is in `tracker.active_states`. There is no implicit opt-in based on assignee, priority, or any other column.
- The system MUST NOT switch agent profiles mid-session. Profile changes apply on the next attempt.
- The system MUST NOT normalize token counts across runtimes.
- The system MUST NOT fall back across runtimes on failure. If `claude_opus` fails, the system retries with `claude_opus`, never with another profile.
- The system MUST NOT support multi-board polling in v1. Each WORKFLOW.md targets exactly one Monday board.
- The system MUST NOT support rule-based routing in v1. Only `default_profile` and per-issue column override are supported.
- The system MUST NOT auto-create the dedicated `symphony_status` column on the board. Operator setup is a precondition.

---

## 4. Integration Boundaries

### Monday.com API
- **In:** GraphQL queries — items list, item details, board metadata, item updates, column values.
- **Out:** GraphQL mutations — `change_simple_column_value` (status transitions), `create_update`, `edit_update`, `change_multiple_column_values` (PR URL).
- **Endpoint:** `https://api.monday.com/v2`. Auth via `Authorization: <api_token>` header.
- **Rate limits:** 5,000 complexity units per minute; 10,000 per query (Monday docs).
- **On unavailable:** Symphony emits operator-visible error, retains last successful state, retries on next poll tick with exponential backoff up to `agent.max_retry_backoff_ms`.
- **Dev twin:** `SymphonyElixir.Tracker.Memory` preserved for tests; new `SymphonyElixir.Monday.Memory` for tests that exercise Monday-specific shape.

### Coding-agent CLIs
- **Codex App Server** — JSON-RPC over stdio, launched via `codex app-server`.
- **Claude Code SDK** — streaming JSON over stdio via `claude --print --output-format stream-json`.
- **Gemini CLI** — streaming JSON over stdio via `gemini --output-format stream-json`.
- **On unavailable:** runtime adapter returns `{:error, :launch_failed}`; orchestrator schedules exponential-backoff retry.

### Filesystem
- **Reads/writes:** workspace directories under `workspace.root`; log files under configured `--logs-root`.
- **Constraint:** workspaces stay strictly under `workspace.root`. Symphony never executes agent commands in the source repo.

### Git / GitHub
- Out of scope for Symphony itself. Workspace `hooks.after_create` may clone repos; agents handle PR creation via their own tooling. Symphony stores/passes the resulting PR URL into the configured PR column.

---

## 5. Behavioral Scenarios (eval-only; agent must not see during dev)

### S1 — Happy path: default profile (Codex)
- **Setup:** WORKFLOW.md sets `agent.default_profile: codex_gpt55_xhigh`. New Tech Board item; user sets Symphony Status to `Symphony Ready`; Symphony Profile column empty.
- **Action:** Next poll tick.
- **Expected:** Symphony creates workspace, starts Codex App Server, transitions Symphony Status to `In Progress`, creates `## Symphony Workpad` Update. Profile resolves to `codex_gpt55_xhigh` (default fallback). Item URL appears in Symphony's running state.

### S2 — Happy path: per-issue profile override (Claude Opus)
- **Setup:** Same default as S1. New item; user sets Symphony Status to `Symphony Ready`; Symphony Profile dropdown set to `claude_opus`.
- **Action:** Next poll tick.
- **Expected:** Symphony resolves to `claude_opus`, launches Claude adapter, transitions Symphony Status to `In Progress`. Workpad created. Token accounting reflects Anthropic-side input/output counters.

### S3 — Happy path: handoff at Human Review
- **Setup:** Item is in Symphony Status = `In Progress`; agent finishes a turn and PR URL is written to the configured PR column.
- **Action:** Agent emits its completion event.
- **Expected:** Symphony Status transitions to `Human Review`. Workspace and session preserved for resumption if state flips to `Rework`. Symphony does not auto-merge.

### S4 — Error: Monday API unavailable
- **Setup:** Mock Monday returns 5xx for 60 seconds.
- **Action:** Symphony enters its poll loop.
- **Expected:** Symphony logs operator-visible error per tick; does not dispatch new work; does not crash; in-memory item state unchanged. When Monday recovers, the next poll tick resumes normal dispatch.

### S5 — Error: invalid profile reference
- **Setup:** Tech Board item has Symphony Profile = `claude_opus_v2`, but `profiles.claude_opus_v2` is not defined in WORKFLOW.md.
- **Action:** Next poll tick attempts dispatch.
- **Expected:** Symphony skips that item, leaves its Symphony Status unchanged, emits an operator-visible warning naming the missing profile and item identifier. Other items dispatch normally.

### S6 — Edge: Symphony Status changes mid-session
- **Setup:** Symphony has dispatched item to Codex; agent has run 5 turns. User manually changes Symphony Status from `In Progress` to `Cancelled` in the Monday UI.
- **Action:** Symphony's reconciliation tick observes the state change.
- **Expected:** Symphony stops the running session, runs `before_remove` hooks, deletes the workspace, releases the claim. The `## Symphony Workpad` reflects the last in-session edit by the agent (Symphony does not perform a forced final workpad write on cancellation; in-flight tool-use deltas may be lost).

### S7 — Edge: concurrent items, mixed profiles, concurrency cap
- **Setup:** 12 items in `Symphony Ready` — three with profile `claude_opus`, four with `codex_gpt55_xhigh`, five with no profile (default = `gemini_long_context`). `agent.max_concurrent_agents: 10`.
- **Action:** Poll tick.
- **Expected:** Exactly 10 sessions launch. Selection respects the concurrency cap, not profile distribution. Two items remain in `Symphony Ready` until slots free. Each profile's adapter is invoked correctly per its `kind`.

---

## 6. Per-Part Context Layers

Three artifacts per part, per `context-layer-generator` template: MODULE_MANIFEST, BEHAVIORAL_CONTRACTS, DECISION_LOG.

### Part A — Tracker Layer (Monday.com)

#### A.1 Module Manifest

> Adapter that polls Monday boards for items in active Symphony states, reads/writes the dedicated `symphony_status` column, and manages per-item Workpad Updates.

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

##### Dependencies

| Dependency | Type | Description |
|---|---|---|
| Monday.com GraphQL API | sync API | Source of truth for item state, descriptions, columns, updates |
| `SymphonyElixir.Config` | shared library | Reads `tracker.*` config from WORKFLOW.md front matter |
| `:req` HTTP client | library | GraphQL transport (existing dep) |
| `MONDAY_API_TOKEN` env var | secret | Auth header for Monday API (replaces `LINEAR_API_KEY`) |

##### Dependents

| Dependent | Type | Description |
|---|---|---|
| `SymphonyElixir.Orchestrator` | sync calls | `fetch_candidate_issues`, `fetch_issue_states_by_ids` per poll tick |
| `SymphonyElixir.AgentRunner` | sync calls | `update_issue_state`, `upsert_workpad` |
| `SymphonyElixirWeb.DashboardLive` | sync calls | Item URL resolution for status surface |

##### Data Flows

| Direction | Source/Target | Data | Notes |
|---|---|---|---|
| Reads | Monday board items | `item.id`, `item.name`, column values (`symphony_status`, profile, priority, dependency, labels), `item.updates` | Filtered by `tracker.active_states` |
| Writes | Monday item columns | `symphony_status` (state transitions), PR column (PR URL) | `change_simple_column_value` mutation |
| Writes | Monday item updates | Workpad markdown body | `create_update` first time, `edit_update` thereafter |

##### Shared Resources

| Resource | Shared With | Risk Notes |
|---|---|---|
| Monday API rate limit (5K complexity units/min) | All MyBCAT Monday integrations (`daily-report`, `appointment-data-gatherer`) | Coordinate poll cadence; budget complexity per query |

> **DARK CODE HOTSPOT:** Tech Board has 892 items, sprint-grouped. Filter by `symphony_status` column at the GraphQL layer (`items_page` with column filter), never full board scan.

##### Deployment Model

- **Type:** Module within Symphony Elixir application (`lib/symphony_elixir/monday/*.ex`)
- **Runtime:** Elixir 1.19 / OTP 28
- **Infrastructure:** runs wherever Symphony runs (single BEAM node by default)

##### Ownership

- **Team:** Symphony reference implementation (MyBCAT)
- **On-call:** Ankit Patel

#### A.2 Behavioral Contracts

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

---

##### `fetch_candidate_issues/0`

> Returns Monday items eligible for Symphony dispatch on the configured board.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure read; safe concurrently. |
| **Failure behavior** | `{:error, reason}` on API/network/auth failure. Caller must not crash. |
| **Performance envelope** | One GraphQL query per call. p50 200–800ms; p99 up to 5s under Monday load. Should be called at most once per poll interval. |
| **Side effects** | None. Read-only. |
| **Retry guidance** | Safe to retry. Exponential backoff per `agent.max_retry_backoff_ms`. Dangerous if: retries amplify Monday rate-limit pressure — observe headers. |
| **Data classification** | May include item titles containing client names (PHI risk). Symphony MUST NOT log full titles in transport logs without redaction. |

###### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Network timeout | `{:error, :timeout}` | Skip this poll tick; retry next |
| Auth failure (401/403) | `{:error, :auth_failed}` | Operator alert; halt dispatch until config fixed |
| Rate limited (429) | `{:error, :rate_limited}` | Back off per response headers |
| Schema drift | `{:error, {:schema, details}}` | Operator alert; pause dispatch |

###### Warnings

- Identifiers use derived `<prefix>-<item_id>` format — stable across runs but not globally unique outside the configured board.
- Subitem board `8173916705` (Tech Board's subitems) is ignored in v1.

---

##### `update_issue_state(item_id, state_name)`

> Writes a new value to the `symphony_status_column_id` Status column.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Same value is a no-op write. |
| **Failure behavior** | `{:error, reason}` on API failure or invalid state name. |
| **Performance envelope** | One GraphQL mutation, 300–1000ms. |
| **Side effects** | Mutates Monday board state visible to all users. May trigger Monday automations attached to that column (we deliberately chose a separate column to minimize this). |
| **Retry guidance** | Safe on network failures. Dangerous if: state semantics change between attempts (e.g., user manually moves item during retry). |
| **Data classification** | Internal — state name is a label, not PHI. |

###### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Unknown state label | `{:error, :state_not_found}` | Operator config error — fix WORKFLOW.md states |
| Auth failure | `{:error, :auth_failed}` | Halt dispatch |
| Mutation rejected | `{:error, {:api, body}}` | Log and skip; let next poll reconcile |

###### Warnings

- Symphony writes ONLY to `symphony_status_column_id`. Operator MUST configure this — Symphony does not auto-detect.
- Transitions do not roll back. If a downstream step fails, the item is left in the new state with workpad notes describing the gap.

---

##### `upsert_workpad(item_id, body)`

> Finds existing `## Symphony Workpad` Update or creates one; edits in place.

| Property | Value |
|---|---|
| **Idempotent** | Conditional — yes for body content (overwrites); no for ID — first call creates one Update, subsequent calls reuse it. |
| **Failure behavior** | `{:error, reason}`. Caller logs and continues. |
| **Performance envelope** | 1 read + 0–1 mutation per call. 400–1500ms typical. |
| **Side effects** | Creates or modifies a Monday Update visible to all board members. |
| **Retry guidance** | Safe — find-or-create is idempotent on `## Symphony Workpad` marker. |
| **Data classification** | May contain agent commentary referencing client work — apply title-redaction rules. |

###### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Marker found multiple times | `{:error, :ambiguous_workpad}` | Operator alert; Symphony refuses to write until disambiguated |
| Update too large (Monday ~1MB) | `{:error, :body_too_large}` | Truncate with explicit note; alert operator |

###### Warnings

- `## Symphony Workpad` is a magic-string marker. Renaming across versions requires a one-time migration step.
- `edit_update` requires the user_id of the API token's owner. Token rotation to a different user breaks edits silently — Symphony falls back to creating a new Update and alerting.

#### A.3 Decision Log

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

---

##### DL-001: Replace Linear with Monday.com (single tracker, not multi-tracker)

- **Date:** 2026-05-03
- **Context:** MyBCAT operates on Monday.com. Linear is not used. Symphony reference implementation needed Monday-only support, not a generic multi-tracker abstraction.
- **Alternatives considered:**
  - Multi-tracker with adapter pattern: Rejected — adds spec surface for no current need.
  - Keep Linear, add Monday adapter: Rejected — leaves Linear-specific fields in spec that obscure intent.
- **Consequences:**
  - Enables: smaller spec; cleaner Monday-specific config (`board_id`, column ids).
  - Constrains: a fork wanting Linear must revert this spec change; no in-spec path back.
- **Warning:** If reversed, the `tracker` config schema diverges between two trackers and the `Tracker.adapter/0` dispatch must grow to multi-kind. Each tracker's identifier semantics differ (Linear has `MT-620` natively; Monday derives), so the issue model identifier resolution becomes tracker-specific.

---

##### DL-002: State source = dedicated `symphony_status` Status column (not Group, not shared)

- **Date:** 2026-05-03
- **Context:** Tech Board `8173460438` has 892 items, an existing `status` column wired into team automations and a `formula_mkm9wekn` Total Quality Score formula, and sprint-based groups. Symphony's lifecycle (`Symphony Ready → In Progress → Human Review → Merging → Rework → Done`) needs an authoritative source.
- **Alternatives considered:**
  - Use Groups for state: Rejected — Groups are organizational (sprints) on this board.
  - Share the existing `status` column: Rejected — Symphony writes would trigger team automations and quality-score recalculations not designed for AI-driven transitions.
- **Consequences:**
  - Enables: zero blast radius on existing automations; explicit per-item opt-in via the dedicated column; spec keeps `active_states` / `terminal_states` as flat string lists.
  - Constrains: each Symphony-tracked board needs a new column added.
- **Warning:** If reversed (sharing the existing status column), every Symphony state transition fires team automations including the Total Quality Score formula. Items end up with phantom quality scores from AI runs that were never human-reviewed. Requires audit of every automation on the existing status column.

---

##### DL-003: Workpad as a Monday Item Update (not a Long Text column or external store)

- **Date:** 2026-05-03
- **Context:** Symphony's persistent workpad concept (Linear's `## Codex Workpad` comment) needs a Monday equivalent.
- **Alternatives considered:**
  - Long Text column: Rejected — column edits lack diff/edit semantics; older versions are lost.
  - External store (S3, DB): Rejected — adds infra; loses in-board visibility.
- **Consequences:**
  - Enables: in-board visibility; native edit history; matches Linear semantics closely.
  - Constrains: searchable only by header marker; race conditions if multiple Symphony instances target the same item.
- **Warning:** If reversed, every workpad reference in the spec must be retargeted; marker-based find logic becomes irrelevant; loses native Monday board visibility for stakeholders.

---

##### DL-004: Identifier scheme = `<prefix>-<item_id>` derived (no human-maintained ticket key)

- **Date:** 2026-05-03
- **Context:** Linear has `MT-620` style human-readable keys natively. Monday has only numeric item IDs (10-digit). Symphony needs identifiers for branch names, prompt rendering, log lines.
- **Alternatives considered:**
  - User-maintained Text column: Rejected — humans forget to fill it; non-deterministic for Symphony-only items.
  - Monday formula column with per-board sequence: Rejected — formulas don't persist; ID changes if rows are deleted.
- **Consequences:**
  - Enables: deterministic, zero-config identifier; works on day 1 without board changes beyond Symphony Status column.
  - Constrains: identifiers are long ugly numbers (e.g., `SYM-9482736152`); branch names are uglier.
- **Warning:** If reversed (using a user-maintained column), every existing identifier in workspaces, branches, and PR titles becomes invalid. A migration is required and PR/branch history may break.

---

### Part B — Agent Runtime Layer (multi-CLI)

#### B.1 Module Manifest

> Pluggable adapter layer that launches a coding-agent CLI session, sends turns, streams events, and reports token usage. One adapter per supported CLI (Codex / Claude / Gemini).

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

##### Dependencies

| Dependency | Type | Description |
|---|---|---|
| Coding-agent CLI binaries (`codex`, `claude`, `gemini`) | external process | Launched via `bash -lc` in workspace dir |
| `SymphonyElixir.Workspace` | shared library | Provides workspace path, hook execution |
| `SymphonyElixir.Config` | shared library | Reads `agent.kind` and per-kind config blocks |
| `:bandit` / `:phoenix` / `:phoenix_live_view` | library (existing) | Used unchanged |

##### Dependents

| Dependent | Type | Description |
|---|---|---|
| `SymphonyElixir.AgentRunner` | sync calls | Constructs adapter for resolved profile and invokes runtime callbacks |
| `SymphonyElixir.Orchestrator` | indirect | Receives streaming events via PubSub from adapter |
| `SymphonyElixirWeb.DashboardLive` | indirect | Renders adapter session metadata |

##### Data Flows

| Direction | Source/Target | Data | Notes |
|---|---|---|---|
| Reads | CLI stdout | streaming JSON events (turn deltas, token counts, tool calls, completion) | Per-runtime schema; adapter normalizes |
| Writes | CLI stdin | turn prompts, control messages | Per-runtime serialization |
| Writes | Workspace dir | agent-driven file edits | Sandboxed by per-kind sandbox config |

##### Shared Resources

| Resource | Shared With | Risk Notes |
|---|---|---|
| Workspace filesystem | Hook scripts, agent CLI | All writes go through per-kind sandbox; Symphony does not directly write workspace contents |
| Stdio | Single adapter session per item | One process per session |

> **DARK CODE HOTSPOT:** Token accounting differs across runtimes. Codex App Server reports per-turn input/output split. Claude Code SDK reports `cache_read` / `cache_creation` / `input` / `output`. Gemini reports yet differently. Each adapter MUST normalize to `{input, output, total}` and document any lossy mapping.

##### Deployment Model

- **Type:** Module within the Symphony Elixir application (`lib/symphony_elixir/codex/*`, `lib/symphony_elixir/claude/*`, `lib/symphony_elixir/gemini/*`)
- **Runtime:** Elixir 1.19 / OTP 28; subprocesses via Erlang Port
- **Infrastructure:** Each agent CLI must be installed on the Symphony host (or available via `mise`)

##### Ownership

- **Team:** Symphony reference implementation (MyBCAT)
- **On-call:** Ankit Patel

#### B.2 Behavioral Contracts

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

---

##### `AgentRuntime.start_session(workspace_path, config)`

> Launches the per-kind coding-agent CLI as a subprocess and returns an opaque session handle.

| Property | Value |
|---|---|
| **Idempotent** | No. Each call starts a new subprocess. Caller responsible for one-session-per-item invariant. |
| **Failure behavior** | `{:error, reason}` on launch failure (binary not found, workspace invalid, sandbox config rejected). |
| **Performance envelope** | Codex: 1–3s startup. Claude: 0.5–2s. Gemini: 1–4s. |
| **Side effects** | Spawns OS process; opens stdio pipes; allocates Erlang port; reserves workspace until session ends. |
| **Retry guidance** | Safe after a clean `stop_session`. Dangerous if previous session didn't fully exit — port leak. |
| **Data classification** | Internal. Launched process inherits env per `shell_environment_policy`. |

###### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Binary not found | `{:error, {:enoent, path}}` | Operator install missing CLI; abort dispatch for this profile |
| Workspace path invalid | `{:error, :invalid_workspace}` | Investigate `workspace.root` |
| Sandbox config rejected | `{:error, {:sandbox_rejected, body}}` | Check per-kind sandbox compatibility with installed CLI version |

###### Warnings

- Codex `approval_policy: never` is required for unattended runs. Other settings hang waiting for human input.
- Claude `permission_mode: acceptEdits` is the closest analog. `default` blocks on prompts.
- Gemini sandbox semantics differ — review per-version docs before changing.

---

##### `AgentRuntime.send_turn(session, prompt, opts)`

> Sends a turn to an active session. First call may be the full task prompt; later calls send continuation guidance.

| Property | Value |
|---|---|
| **Idempotent** | No. Each call appends a turn. |
| **Failure behavior** | `:ok` on accept; `{:error, reason}` if session is dead or stdio is broken. |
| **Performance envelope** | Submission is near-instant; response streams via `stream_events`. Per-turn duration: 30s–30min typical. |
| **Side effects** | Modifies session history; triggers model inference; may invoke tool calls touching workspace filesystem. |
| **Retry guidance** | Dangerous to retry — risks duplicate turns. Caller MUST check session liveness before retry. |
| **Data classification** | Prompts may contain client/issue context derived from Monday item titles and descriptions. Apply title-redaction rules. |

###### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Session dead | `{:error, :session_dead}` | Stop session cleanly; orchestrator schedules retry |
| Stdio broken | `{:error, :stdio_broken}` | Same as session dead |
| Turn rejected | `{:error, {:turn_rejected, reason}}` | Log; surface to workpad; do not auto-retry |

###### Warnings

- `agent.max_turns` caps `send_turn` calls per session lifetime. Default 20.
- First turn uses the full WORKFLOW.md-rendered prompt. Continuation turns send only continuation guidance — re-sending the full prompt wastes tokens and may confuse the model.

---

##### `AgentRuntime.stream_events(session)`

> Returns an enumerable that yields normalized events: turn deltas, tool calls, token deltas, completion, errors.

| Property | Value |
|---|---|
| **Idempotent** | Yes (read-only stream); each call to enumerate consumes events. Multi-consumer not supported. |
| **Failure behavior** | Stream terminates on session end. Errors surface as `{:event, {:error, reason}}` in-stream, not raised. |
| **Performance envelope** | Unbounded — driven by agent activity. Memory pressure if consumer lags producer. |
| **Side effects** | None directly. |
| **Retry guidance** | N/A — one-way consumption. |
| **Data classification** | Events may include partial agent output containing client context. |

###### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Stream timeout (no events for `stall_timeout_ms`) | `{:event, {:stalled, ms}}` | Orchestrator may stop session and retry |
| Adapter parse error | `{:event, {:parse_error, raw}}` | Log raw payload (redacted); continue stream if possible |

###### Warnings

- Each adapter normalizes to a common event vocabulary. Lossy fields documented per-adapter (e.g., Claude's `cache_read` tokens are summed into `input` for cross-runtime consistency).

---

##### `AgentRuntime.token_accounting(session)`

> Returns aggregate `{input, output, total}` token counts for the session.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure read of counters. |
| **Failure behavior** | Returns zeros if session is too young; never raises. |
| **Performance envelope** | O(1). |
| **Side effects** | None. |
| **Retry guidance** | Safe. |
| **Data classification** | Internal. Numbers only. |

###### Warnings

- Cross-runtime totals are NOT comparable. Codex GPT-5.5 input tokens cost differently than Claude Opus tokens cost differently than Gemini Pro tokens. Use per-runtime billing.

#### B.3 Decision Log

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

---

##### DL-005: First-class multi-runtime abstraction (not Codex App Server with shims)

- **Date:** 2026-05-03
- **Context:** Symphony was Codex-only. Ankit wants Codex + Claude + Gemini as first-class runtimes.
- **Alternatives considered:**
  - Single protocol (Codex App Server) with adapter shims for Claude/Gemini: Rejected — Claude Code and Gemini CLI have fundamentally different session models; shims re-invent App Server inside each shim.
  - Single-shot mode (CLI invoked per turn): Rejected — loses streaming events, token accounting, session affinity.
- **Consequences:**
  - Enables: native exploitation of each CLI's strengths; profile-based routing flows naturally; clean spec extension surface.
  - Constrains: three adapters to maintain instead of one; cross-runtime feature parity not guaranteed.
- **Warning:** If reversed (single-protocol shims), each non-Codex CLI must be wrapped in a JSON-RPC App Server-compatible binary. Existing agent feature usage (Claude `permission_mode`, Gemini long context) becomes coupled to shim translation logic.

---

##### DL-006: Sandbox/approval fields are per-kind (not unified spec fields)

- **Date:** 2026-05-03
- **Context:** Codex has `approval_policy`, `thread_sandbox`, `turn_sandbox_policy`. Claude has `permission_mode`, `allowed_tools`. Gemini has its own equivalents.
- **Alternatives considered:**
  - Unified sandbox model with cross-runtime mapping: Rejected — semantics differ enough that a unified model leaks abstractions or drops fidelity.
  - Lowest-common-denominator constraint: Rejected — kills runtime-specific features that motivate choosing them.
- **Consequences:**
  - Enables: each runtime's full sandbox vocabulary is available; spec stays out of the way.
  - Constrains: WORKFLOW.md authors learn three sandbox vocabularies if they use all three runtimes.
- **Warning:** If reversed (unifying sandbox config), runtime-specific sandbox features (e.g., Codex's `turn_sandbox_policy` map) must be either dropped or re-introduced as escape hatches. Both moves reduce safety.

---

##### DL-007: No mid-flight runtime swap

- **Date:** 2026-05-03
- **Context:** Profile changes mid-session require migrating in-flight conversation history across runtimes — fundamentally different message formats.
- **Alternatives considered:**
  - Hot-swap with prompt re-rendering: Rejected — loses agent's accumulated tool-use context; risks duplicate work.
  - Hot-swap by aborting current turn first: Rejected — same context loss; complexity for marginal value.
- **Consequences:**
  - Enables: simpler adapter contracts; clear ownership boundaries.
  - Constrains: profile changes apply on next session start, not current.
- **Warning:** If reversed (mid-flight swap), the AgentRuntime contract must support session-format conversion or transparent restart. The orchestrator's session-id model breaks (a single Symphony "run attempt" would span multiple runtime sessions).

---

### Part C — Routing Layer (named profiles)

#### C.1 Module Manifest

> Resolves which agent profile (kind + per-kind config) handles each Monday item, by precedence: per-issue Symphony Profile column → `agent.default_profile`.

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

##### Dependencies

| Dependency | Type | Description |
|---|---|---|
| `SymphonyElixir.Config` | shared library | Reads `profiles` map and `agent.default_profile` |
| `SymphonyElixir.Tracker` (Monday) | sync calls | Reads per-issue `tracker.profile_column_id` value |

##### Dependents

| Dependent | Type | Description |
|---|---|---|
| `SymphonyElixir.AgentRunner` | sync calls | Calls `ProfileResolver.resolve(issue) → profile` before launching the runtime |

##### Data Flows

| Direction | Source/Target | Data | Notes |
|---|---|---|---|
| Reads | WORKFLOW.md (via Config) | `profiles` map and `default_profile` | Single source for profile definitions |
| Reads | Monday item column | profile text/dropdown value | One field per item |

##### Shared Resources

| Resource | Shared With | Risk Notes |
|---|---|---|
| Profile name namespace | All boards using this WORKFLOW.md | Profiles are global per WORKFLOW.md; renaming a profile invalidates every Monday item that references it |

##### Deployment Model

- **Type:** Pure module (`lib/symphony_elixir/profile_resolver.ex`)
- **Runtime:** Elixir 1.19 / OTP 28
- **Infrastructure:** Stateless; no external calls

##### Ownership

- **Team:** Symphony reference implementation
- **On-call:** Ankit Patel

#### C.2 Behavioral Contracts

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

---

##### `ProfileResolver.resolve(issue)`

> Returns `{:ok, profile}` for the given Monday item using precedence rules, or `{:error, reason}` on misconfiguration.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure function of (issue.profile_value, profiles map, default_profile). |
| **Failure behavior** | `{:error, :unknown_profile}` if per-issue column names a profile not in `profiles`. `{:error, :no_default}` if column empty AND no default. |
| **Performance envelope** | O(1) — single map lookup. |
| **Side effects** | None. |
| **Retry guidance** | Safe; deterministic. |
| **Data classification** | Internal. |

###### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Per-issue profile name not in `profiles` map | `{:error, :unknown_profile}` | Operator alert; item skipped; suggest profile name typo or missing definition |
| Empty per-issue and no default | `{:error, :no_default}` | Operator config error |

###### Warnings

- Profile name comparison is case-sensitive. `Claude_Opus` ≠ `claude_opus`. Document in WORKFLOW.md examples.

#### C.3 Decision Log

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

---

##### DL-008: Named profiles (kind + config bundle), not raw kind switching

- **Date:** 2026-05-03
- **Context:** "Future options to route to different models" implies routing across runtimes AND across model variants of the same runtime (e.g., Claude Opus vs Sonnet, Codex gpt-5.5 vs gpt-5.5-mini).
- **Alternatives considered:**
  - Single config per kind with per-issue kind override: Rejected — only routes runtime, not model. Can't express "use Sonnet for cheap items, Opus for hard items."
  - LLM-as-router: Rejected — too magical for v1; cost overhead per dispatch.
- **Consequences:**
  - Enables: A/B testing models on real issues by flipping a column; future rule-based routing extends profiles cleanly.
  - Constrains: profile names are global per WORKFLOW.md; renaming requires updating every referenced item.
- **Warning:** If reversed (kind-only override), every existing item with a profile column value loses semantic meaning. Migration requires interpreting `claude_opus` as kind=claude with default model.

---

##### DL-009: Two-level precedence only (no rule-based routing in v1)

- **Date:** 2026-05-03
- **Context:** Spec extensibility doc allows rule-based routing as a future extension. v1 stays minimal.
- **Alternatives considered:**
  - Rule-based routing in v1 (`if priority=High → claude_opus`): Rejected — increases spec surface and validation complexity for marginal v1 value.
- **Consequences:**
  - Enables: spec ships fast; rules can be added later as a strict superset.
  - Constrains: dispatch routing logic is item-by-item; complex policy must be encoded by humans setting the column.
- **Warning:** If reversed (adding rules to v1), adapter test surface grows; rules need their own validation, ordering semantics, conflict resolution. Defer.

---

## 7. SPEC.md Concrete Diff Plan

### Sections to retarget
- §3 System Overview — replace "Linear" mentions with "Monday.com"; broaden coding-agent references from Codex-only to multi-runtime.
- §4.1.1 Issue — replace `branch_name` semantics; broaden `identifier` definition to allow tracker-derived schemes.
- §4.1.6 Live Session — rename `codex_*` fields to `agent_*`.
- §5.3.1 tracker — full retargeting to Monday config fields.
- §5.3.6 codex → §5.3.6 agent — multi-kind block.
- §6.4 Cheat Sheet — rewrite tracker rows; expand agent rows; add profile rows.
- §7 Orchestration — replace `codex_*` field names with `agent_*`.

### New sections
- §3.3 Native Runtime Interfaces (informative table per kind)
- §5.3.7 profiles (schema + precedence rules)
- §6.5 Routing Resolution (precedence algorithm)

### Removed sections / fields
- All `tracker.kind: linear` references throughout.
- §5.3.6's Codex-shaped enums (replaced by per-kind pass-through guidance).

### Renames (global)
- `Codex Workpad` → `Symphony Workpad`
- `codex_app_server_pid` → `agent_pid`
- `codex_input_tokens` → `agent_input_tokens` (and `output`, `total`, `last_reported_*` siblings)
- `codex_totals` → `agent_totals`
- `codex_rate_limits` → `agent_rate_limits`

---

## 8. Reference Implementation Deltas (informative)

| Existing path | New path / change |
|---|---|
| `lib/symphony_elixir/linear/` | renamed to `lib/symphony_elixir/monday/` |
| `lib/symphony_elixir/linear/client.ex` | rewritten — Linear GraphQL → Monday GraphQL |
| `lib/symphony_elixir/linear/adapter.ex` | rewritten as `monday/adapter.ex` (still implements `Tracker` behaviour) |
| `lib/symphony_elixir/linear/issue.ex` | renamed `monday/item.ex`; identifier derivation logic added |
| `lib/symphony_elixir/codex/app_server.ex` | renamed `codex/adapter.ex`; implements new `AgentRuntime` behaviour |
| `lib/symphony_elixir/codex/dynamic_tool.ex` | retained for Codex; review `linear_graphql` injected tool — replace with `monday_graphql` injection |
| n/a | new `lib/symphony_elixir/agent_runtime.ex` (behaviour) |
| n/a | new `lib/symphony_elixir/claude/adapter.ex` |
| n/a | new `lib/symphony_elixir/gemini/adapter.ex` |
| n/a | new `lib/symphony_elixir/profile_resolver.ex` |
| `WORKFLOW.md` | rewritten example with `profiles` block and Monday tracker |
| `mix.exs` | `ignore_modules` list updated for renames; add new modules to coverage exemptions if needed |
| `make e2e` | docker compose for SSH workers stays; live test rewritten to create disposable Monday board+items instead of Linear |

---

## 9. Tech Board Setup Checklist (board `8173460438`)

1. Create three new columns:
   - **Symphony Status** — type `status`
   - **Symphony Profile** — type `dropdown`
   - **Symphony PR** — type `link`
2. Configure Symphony Status labels: `Symphony Ready`, `In Progress`, `Human Review`, `Merging`, `Rework`, `Done` (mark as done), `Cancelled`.
3. Populate Symphony Profile dropdown values to match `profiles` keys in WORKFLOW.md (e.g., `claude_opus`, `claude_sonnet`, `codex_gpt55_xhigh`, `gemini_long_context`).
4. Verify the Monday API token has read+write access to the board.
5. Record the resulting column IDs in WORKFLOW.md `tracker.*_column_id` fields.
6. (Optional) Configure a Monday board view filtering items where Symphony Status = `Symphony Ready` for human triage of inbound work.

---

## 10. Out of Scope for v1

1. Rule-based routing (`agent.routing_rules`) — documented as future extension only.
2. Multi-board polling — single board per WORKFLOW.md.
3. Multi-tracker support — Linear is removed and not coming back in this spec line.
4. Mid-flight runtime swap — profile changes apply on next attempt.
5. Cross-runtime token accounting normalization.
6. Sub-item handling — Tech Board's subitem board (`8173916705`) is ignored.
7. Cross-instance Symphony clustering on the same board.

---

## 11. Ambiguity Warnings

The brainstorming session resolved the major design forks. The items below remain ambiguous; an implementation agent will need explicit answers before coding.

### AW-1 — Description fallback policy
- **Ambiguous:** If `tracker.description_column_id` is not configured, should Symphony fall back to "first Item Update" silently, or require the column to be set?
- **Likely assumption:** Silent fallback to first Item Update.
- **Question:** Confirm fallback OR enforce description column requirement.

### AW-2 — Branch column fallback
- **Ambiguous:** If `tracker.branch_column_id` is configured but empty for an item, derive from identifier or fail?
- **Likely assumption:** Derive from identifier.
- **Question:** Confirm fallback OR fail.

### AW-3 — Workpad write race
- **Ambiguous:** Two Symphony instances polling the same board could create duplicate workpad Updates.
- **Likely assumption:** Single Symphony instance per board (no clustering in v1).
- **Question:** Confirm single-instance or document concurrency handling.

### AW-4 — Monday API token user identity
- **Ambiguous:** `edit_update` requires the user_id of the token's owner. Token rotation to a different user breaks edits.
- **Likely assumption:** Symphony uses one stable Monday API token tied to a service user.
- **Question:** Should Symphony require a dedicated Monday user account?

### AW-5 — Profile column missing from board
- **Ambiguous:** If `tracker.profile_column_id` is configured but the column doesn't exist on the board, behavior is undefined.
- **Likely assumption:** Hard error at startup config validation.
- **Question:** Confirm hard-fail OR silent fallback to default_profile per item.

### AW-6 — Profile dropdown values out-of-sync with WORKFLOW.md
- **Ambiguous:** Monday dropdown columns store values as text. If dropdown options drift from `profiles` keys, items may have stale profile values.
- **Likely assumption (per DL-008):** Symphony hard-fails per item with `{:error, :unknown_profile}`.
- **Question:** Confirm hard-fail or auto-fall-back to default.

### AW-7 — Concurrency cap accounting per profile
- **Ambiguous:** `agent.max_concurrent_agents` is a global cap. Should there be per-profile sub-caps (e.g., max 2 Claude Opus at a time for cost control)?
- **Likely assumption:** Global cap only in v1.
- **Question:** Confirm global-only OR add per-profile caps to v1.

### AW-8 — Rate limit budgeting across MyBCAT Monday consumers
- **Ambiguous:** Other MyBCAT skills (`daily-report`, `appointment-data-gatherer`) consume the same Monday API quota. No coordination mechanism.
- **Likely assumption:** Symphony observes 429 responses and backs off; coordination is operator concern.
- **Question:** Confirm or specify a quota budget for Symphony.

---

## 12. Implementation Constraints

- **Reference language:** Elixir 1.19 / OTP 28 (no change from existing).
- **Quality gates:** `make all` must pass — `mix format --check`, `mix lint` (`specs.check` + `credo --strict`), `mix test --cover` to existing thresholds, `mix dialyzer`.
- **`@spec` requirement:** every public `def` in `lib/` MUST have an adjacent `@spec` per `elixir/AGENTS.md`.
- **Shell command formatting:** any shell command shown in the spec, WORKFLOW.md examples, or repo docs MUST be a single-line bash block (no backslash continuations, no multi-line shell — Ankit copy-paste workflow).
- **Dependencies:** no new infrastructure dependencies; preserve `:bandit`, `:phoenix`, `:phoenix_live_view`, `:req`, `:jason`, `:yaml_elixir`, `:solid`, `:ecto`.
- **HIPAA / data handling:** agent prompts may include client-derived item titles; redaction rules from `docs/logging.md` apply unchanged. Add Monday-specific redaction guidance: never log full item titles or update bodies in transport-level logs.
- **Backwards compatibility:** none required. This is a clean spec line break (`SPEC.md` v2 effectively).

---

## 13. Appendix A — Sample WORKFLOW.md (informative)

Concrete config an implementation agent can use as a starting point. Field semantics defined in §6 Part A and §6 Part C.

```yaml
---
tracker:
  kind: monday
  api_token: $MONDAY_API_TOKEN
  endpoint: https://api.monday.com/v2
  board_id: 8173460438
  identifier_prefix: "SYM"
  symphony_status_column_id: "<set after column creation>"
  profile_column_id: "<set after column creation>"
  priority_column_id: "status_1_mkm9bt8j"
  description_column_id: null
  branch_column_id: null
  labels_column_id: "dropdown_mkwbsh98"
  pr_column_id: "<set after column creation>"
  active_states:
    - "Symphony Ready"
    - "In Progress"
    - "Human Review"
    - "Merging"
    - "Rework"
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
profiles:
  claude_opus:
    kind: claude
    claude:
      command: "claude --print --output-format stream-json"
      model: "claude-opus-4-7"
      permission_mode: "acceptEdits"
  claude_sonnet:
    kind: claude
    claude:
      command: "claude --print --output-format stream-json"
      model: "claude-sonnet-4-6"
      permission_mode: "acceptEdits"
  codex_gpt55_xhigh:
    kind: codex
    codex:
      command: "codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
      approval_policy: never
      thread_sandbox: workspace-write
  gemini_long_context:
    kind: gemini
    gemini:
      command: "gemini --model gemini-2.5-pro --output-format stream-json"
agent:
  default_profile: claude_opus
  max_concurrent_agents: 10
  max_turns: 20
---

You are working on a Monday.com item `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the item is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
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
2. Use the `## Symphony Workpad` Update on this Monday item as the persistent scratchpad.
3. When PR is open, write the URL to the configured PR column on the item.
4. Move Symphony Status only when the matching quality bar is met (see your repo's `WORKFLOW.md` body for status flow).
```

---

## 14. Approval Checklist

- [ ] Section 1 — System overview accurately describes the change.
- [ ] Section 2 — Behavioral contract covers polling, workpad, routing, multi-runtime, token accounting.
- [ ] Section 3 — Non-behaviors are complete and binding.
- [ ] Section 4 — Integration boundaries cover Monday API, all three CLIs, filesystem, git/GitHub.
- [ ] Section 5 — At least 3 happy / 2 error / 2 edge scenarios.
- [ ] Section 6 — All three context-layer artifacts present for all three parts (Tracker, Agent Runtime, Routing).
- [ ] Section 7 — SPEC.md diff plan is concrete enough to execute.
- [ ] Section 8 — Reference implementation deltas are accurate against current `lib/`.
- [ ] Section 9 — Tech Board setup checklist is actionable.
- [ ] Section 10 — Scope boundaries are correct.
- [ ] Section 11 — All open ambiguities flagged with proposed assumptions.
- [ ] Section 12 — Implementation constraints inherit existing repo standards.
