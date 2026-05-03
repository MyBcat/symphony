# Symphony — Multi-Runtime Agents + Profile Routing (Spec 2 of 2)

**Status:** Draft for review
**Date:** 2026-05-03
**Authors:** Ankit Patel + Claude (Opus 4.7)
**Sequencing:** Spec 2 of 2. **Depends on Spec 1** (`2026-05-03-symphony-monday-tracker-swap.md`) being shipped first. Do NOT begin Spec 2 implementation until Spec 1 has merged and is running stably against Tech Board.
**Modifies:** `SPEC.md` (agent sections only), `elixir/WORKFLOW.md`, `elixir/lib/symphony_elixir/codex/**`, adds `elixir/lib/symphony_elixir/{claude,gemini,agent_runtime,profile_resolver}/**`
**Does NOT modify:** Tracker layer (Spec 1's responsibility). Monday adapter shape is assumed shipped.
**Source design:** `2026-05-03-symphony-monday-multi-runtime-design.md` (superseded; design-intent reference only)
**Skills applied:** `agent_spec_writer` (format), `context-layer-generator` (per-part artifacts)
**Review-driven amendments + captured architecture context:**

| Amendment | Source | Applied where |
|---|---|---|
| **Default profile = `claude_opus`** (matches Ankit's actual Claude-as-orchestrator usage; Codex as QA/fix-it; Gemini as large-context) | Captured Fathom transcripts (Ankit/Vince 2026-04-16, Marcus 2026-02-02, Peter 2026-01-08) | §13 |
| **No `monday_graphql` tool injection in any runtime** — Spec 1 DL-005 puts all Monday writes in Symphony's Tracker primitive; agents have no Monday access | Captured factory architecture (OB_mybcat 2026-05-03) + Spec 1 DL-005 | §2, §4, §B.2 |
| Profile column = privileged input; sandbox safety floor enforced | Claude HIGH #1, Codex HIGH §6 | §2.2, §3, DL-006 |
| Token accounting = runtime-native pass-through (resolves B.1/§2 contradiction) | Claude HIGH #5 | §2.4, B.2 contracts, DL-007 |
| Profile re-resolves at retry boundary | Codex HIGH §1 | §2.3, DL-008 |
| Per-profile concurrency caps | Claude MED #7, Gemini MED #3, Codex MED §2 | §2.5, DL-009 |
| Startup validation of profile-name ↔ Monday dropdown drift | Claude MED #6, Codex HIGH §3 | §2.6, DL-010 |
| Gemini profile in sample WORKFLOW.md must specify sandbox baseline | Claude LOW #15 | §13 |
| AgentRuntime contract preserves Codex App Server thread/run_turn semantics | Codex HIGH §5 | §B.2 contracts |
| All 4 open ambiguities (AW-1..AW-4) locked | Direct user instruction "stop asking questions" 2026-05-03 | §11 |
| Each profile must declare its 10-Layer Framework alignment (Layers 5/6/8 minimum) | Captured 10-Layer Framework reference 2026-05-03 | DL-011 |

---

## 1. System Overview

This spec adds first-class support for non-Codex coding agents (Claude Code, Gemini CLI) and introduces named "agent profiles" for per-issue routing across runtime + model variants. Symphony's tracker layer (Monday.com) is unchanged from Spec 1.

The agent-owned writes model from Spec 1 is preserved unchanged. This spec adds:

1. An `AgentRuntime` behaviour with native adapters per CLI (Codex / Claude / Gemini).
2. A `profiles` block in WORKFLOW.md defining named runtime + config bundles.
3. A new `Symphony Profile` dropdown column on the Monday board for per-item routing.
4. A `ProfileResolver` module that picks the right profile per issue with strict precedence.

The trust boundary expands: the Monday Profile dropdown column is now a privileged input that can select agent runtimes with different sandbox capabilities. Symphony enforces a sandbox safety floor at dispatch time.

---

## 2. Behavioral Contract (system-level)

### 2.1 Runtime selection
- **When** Symphony dispatches an item, **the system** resolves a profile per §2.3 precedence rules and uses the runtime adapter matching the profile's `kind` (`codex`, `claude`, or `gemini`).
- **When** a profile selects `kind: codex`, **the system** uses `SymphonyElixir.Codex.Adapter` and the Codex App Server JSON-RPC protocol (preserves Spec 1 behavior).
- **When** a profile selects `kind: claude`, **the system** uses `SymphonyElixir.Claude.Adapter` and the Claude Code SDK streaming JSON protocol.
- **When** a profile selects `kind: gemini`, **the system** uses `SymphonyElixir.Gemini.Adapter` and the Gemini CLI streaming JSON protocol.
- **When** a profile's `kind` is unrecognized at startup, **the system** refuses to boot and emits a configuration error.

### 2.2 Sandbox safety floor (privileged input enforcement)
- **When** the system loads a profile at dispatch, **the system** asserts the profile's sandbox config does not exceed `agent.sandbox_safety_floor` (defaults to `workspace-write`-equivalent; per-kind mapping in §B.2).
- **When** a profile exceeds the floor, **the system** refuses to dispatch that profile and emits an operator-visible error naming the profile and the violation.
- **When** a profile's sandbox config is unrecognized for the resolved kind, **the system** refuses to dispatch that profile.
- **The agent runtime adapter** MUST NOT silently downgrade a sandbox setting that exceeds the floor; refusal is the only valid response.

### 2.3 Profile resolution and retry semantics
- **When** the system resolves a profile, **the system** reads the per-issue Monday `Symphony Profile` dropdown column. If the value is non-empty, the named profile is used.
- **When** the per-issue value is empty, **the system** uses `agent.default_profile`.
- **When** neither resolves to a profile defined in the WORKFLOW.md `profiles` map, **the system** skips dispatch for that item and emits an operator-visible error.
- **When** an attempt fails and the orchestrator schedules a retry, **the system** re-resolves the profile at the retry boundary by re-reading the per-issue column. This means: the operator can flip the dropdown mid-flight and the next retry attempt picks up the new profile. (Resolves Codex HIGH §1.)
- **When** an item is mid-session and the operator changes the profile column, **the system** does NOT swap the running adapter mid-session; the change applies on the next attempt.

### 2.4 Token accounting (runtime-native)
- **When** an agent session reports token usage, **the system** stores the runtime's native counters under `agent_native_tokens` keyed by `kind` (e.g., `agent_native_tokens.claude.input`, `agent_native_tokens.claude.cache_read`, `agent_native_tokens.codex.input`).
- **The system** does NOT compute a unified `total_tokens` across runtimes. Cross-runtime totals are not comparable and are explicitly out-of-spec. (Resolves Claude HIGH #5: removes the contradiction between original §2 "no normalization" and original B.1 "MUST normalize.")
- **The system** MAY surface a per-runtime total field in the dashboard for that runtime's own session.

### 2.5 Per-profile concurrency caps
- **The system** respects `agent.max_concurrent_agents` as the global cap.
- **The system** additionally respects per-profile caps if defined: `profiles.<name>.max_concurrent` (positive integer or unset).
- **When** a profile's per-profile cap is reached, **the system** holds candidate items in `Symphony Ready` until a session of that profile frees up. Other profiles continue to dispatch up to the global cap.

### 2.6 Startup validation of profile drift
- **When** Symphony starts, **the system** queries the Monday board for the `Symphony Profile` dropdown column's full list of label options.
- **When** any profile name in `profiles` is missing from the dropdown labels, **the system** emits an operator warning naming the gap.
- **When** any dropdown label has no corresponding entry in `profiles`, **the system** emits an operator warning naming the orphan.
- **When** the dropdown column does not exist on the board, **the system** refuses to boot. (Locks AW-5 from original spec.)

---

## 3. Explicit Non-Behaviors

- The system MUST NOT support `agent.kind` outside `{codex, claude, gemini}` in v1. Future kinds are extension territory.
- The system MUST NOT mid-flight swap an in-progress session's runtime. Profile changes apply on the next attempt only.
- The system MUST NOT fall back across runtimes on failure. If `claude_opus` fails, the system retries with `claude_opus`, never with another profile.
- The system MUST NOT compute or report a unified cross-runtime `total_tokens`. Per-runtime native counters only.
- The system MUST NOT auto-downgrade a sandbox setting that exceeds the safety floor. Refusal is the only valid response.
- The system MUST NOT silently fall back to `default_profile` when a per-issue profile name is invalid. Skip + warn is the only valid response.
- The system MUST NOT inspect the agent's tool-call payloads (e.g., `monday_graphql` calls the agent makes). Agent owns those.
- The system MUST NOT support rule-based routing in this spec. Only `default_profile` and per-issue column override (extension territory in a future spec).

---

## 4. Integration Boundaries

### Codex CLI (unchanged from Spec 1, but now adapter-shaped)
- **Protocol:** JSON-RPC over stdio via `codex app-server`.
- **Adapter:** `SymphonyElixir.Codex.Adapter` (existing `Codex.AppServer` module renamed/refactored to implement `AgentRuntime` behaviour).
- **Sandbox vocabulary:** `approval_policy` ∈ {`untrusted`, `on-failure`, `on-request`, `never`, object-form `reject`}; `thread_sandbox` ∈ {`read-only`, `workspace-write`, `danger-full-access`}; `turn_sandbox_policy` (object).
- **Safety floor mapping:** Codex profile passes the floor iff `thread_sandbox` ∈ {`read-only`, `workspace-write`} AND `approval_policy: never`.

### Claude Code SDK (new)
- **Protocol:** streaming JSON over stdio via `claude --print --output-format stream-json --input-format stream-json`.
- **Adapter:** `SymphonyElixir.Claude.Adapter`.
- **Session model:** Claude Code maintains a session-id internally; adapter passes prompts and tool-call results via `--continue <session_id>` for follow-up turns.
- **Sandbox vocabulary:** `permission_mode` ∈ {`default`, `acceptEdits`, `bypassPermissions`, `plan`}; `allowed_tools` (list of tool name globs).
- **Safety floor mapping:** Claude profile passes the floor iff `permission_mode: acceptEdits` AND no entry in `allowed_tools` matches `Bash(*sudo*|*rm -rf*|*chmod 777*)` (denylist enforced by adapter).

### Gemini CLI (new)
- **Protocol:** streaming JSON over stdio via `gemini --output-format stream-json` (per current Gemini CLI as of 2026-05-03; if the CLI gains a session API in a later release, the adapter MAY adopt it).
- **Adapter:** `SymphonyElixir.Gemini.Adapter`.
- **Sandbox vocabulary:** Gemini CLI exposes `--sandbox` and `--yolo` flags. Symphony maps these to its safety floor.
- **Safety floor mapping:** Gemini profile passes the floor iff `--sandbox` is set AND `--yolo` is NOT set.

### No agent-side Monday access (per Spec 1 DL-005)
- No runtime adapter injects a `monday_graphql` (or equivalent) tool. Per Spec 1 DL-005, the Tracker primitive (Symphony itself) owns all Monday writes; agents have no Monday access regardless of runtime kind.
- The Codex adapter does NOT inject a Monday tool (Spec 1 removed the existing `linear_graphql` injection).
- The Claude adapter does NOT inject a Monday tool.
- The Gemini adapter does NOT inject a Monday tool.
- All adapters DO inject the standard CLI's built-in tools (Read/Edit/Write/Bash for Claude; native tool calls for Codex; equivalents for Gemini). PR opening uses `gh` CLI from within the workspace (workspace path is on PATH or `mise`-resolved). Completion summary written by agent to `_symphony_summary.md` per Spec 1 §13.

---

## 5. Behavioral Scenarios (eval-only)

### S1 — Happy path: per-issue Claude Opus override
- **Setup:** WORKFLOW.md `agent.default_profile: codex_gpt55_xhigh`. New Tech Board item with `symphony_status: Symphony Ready` and `Symphony Profile: claude_opus`.
- **Action:** Symphony's poll tick.
- **Expected:** Symphony resolves to `claude_opus`, launches Claude adapter, injects `monday_graphql` tool, agent writes `symphony_status: In Progress` via the tool. Token counters land under `agent_native_tokens.claude.{input, cache_read, output}`. No cross-runtime totals computed.

### S2 — Happy path: profile flip mid-flight applies on retry
- **Setup:** Item dispatched to `claude_sonnet`. Codex CLI subprocess crashes. Operator changes Symphony Profile to `claude_opus` while Symphony is in retry backoff.
- **Action:** Retry timer fires.
- **Expected:** Symphony re-reads the Profile column at the retry boundary, resolves to `claude_opus` (not `claude_sonnet`), launches Claude Opus adapter for the retry attempt. Agent context (workspace) is preserved.

### S3 — Happy path: per-profile cap holds back work
- **Setup:** `agent.max_concurrent_agents: 10`. `profiles.claude_opus.max_concurrent: 2`. 5 items in `Symphony Ready`, all with profile `claude_opus`. 0 items currently running.
- **Action:** Poll tick.
- **Expected:** Exactly 2 Claude Opus sessions launch; 3 items remain in `Symphony Ready`. Global cap is not the constraint; per-profile cap is.

### S4 — Error: profile selects sandbox above safety floor
- **Setup:** WORKFLOW.md defines `profiles.claude_yolo.kind: claude` with `permission_mode: bypassPermissions`. Item assigned to `claude_yolo`.
- **Action:** Symphony attempts dispatch.
- **Expected:** Symphony refuses to dispatch this item; logs operator-visible error naming `claude_yolo` and the floor violation; item left in `Symphony Ready`. Other items dispatch normally.

### S5 — Error: profile name typo on Monday item
- **Setup:** Item has Symphony Profile = `claude_opus_v2`, but `profiles.claude_opus_v2` is not defined in WORKFLOW.md.
- **Action:** Poll tick.
- **Expected:** Symphony skips the item, leaves `symphony_status: Symphony Ready` unchanged, emits operator warning. After `failure_ttl_count` consecutive skips (per Spec 1 §2.5), Symphony writes `symphony_status: Cancelled` and posts a failure summary.

### S6 — Edge: startup detects profile drift
- **Setup:** `profiles` map has `{claude_opus, claude_sonnet, codex_gpt55_xhigh, gemini_long_context}`. Monday Symphony Profile dropdown labels are `{claude_opus, claude_sonnet, codex_old}` (drift: `codex_gpt55_xhigh` and `gemini_long_context` missing from dropdown; `codex_old` is orphan in dropdown).
- **Action:** Symphony boot.
- **Expected:** Symphony boots successfully but emits two operator warnings — one naming the missing dropdown labels, one naming the orphan label. Continues to dispatch items that resolve to known profiles; refuses items that try to use `codex_old` (per S5 logic).

### S7 — Edge: Gemini long-context session with size limit
- **Setup:** `profiles.gemini_long_context.kind: gemini`. Item description in Monday is small but the workspace contains 800K tokens of source files.
- **Action:** Agent uses the `monday_graphql` tool to query item details, then issues a turn that includes a substantial portion of the workspace context.
- **Expected:** Gemini adapter accepts the prompt. Token counters under `agent_native_tokens.gemini.input` reflect Gemini's native count. No cross-runtime normalization occurs.

---

## 6. Per-Part Context Layers

### Part A — Agent Runtime Layer

#### A.1 Module Manifest

> Pluggable adapter layer that launches a coding-agent CLI session, sends turns, streams events, and reports runtime-native token usage. One adapter per supported CLI (Codex / Claude / Gemini). Each adapter implements the `AgentRuntime` behaviour.

**Context captured:** 2026-05-03 by Ankit Patel + Claude
**Last validated:** 2026-05-03

##### Dependencies

| Dependency | Type | Description |
|---|---|---|
| Coding-agent CLI binaries (`codex`, `claude`, `gemini`) | external process | Launched via `bash -lc` in workspace dir |
| `SymphonyElixir.Workspace` | shared library | Workspace path, hook execution |
| `SymphonyElixir.Config` | shared library | `agent.kind` and per-kind config blocks |
| `SymphonyElixir.Monday.Adapter` | shared library | Provides `monday_graphql` tool implementation injected into each session |

##### Dependents

| Dependent | Type | Description |
|---|---|---|
| `SymphonyElixir.AgentRunner` | sync calls | Constructs adapter for resolved profile and invokes runtime callbacks |
| `SymphonyElixir.Orchestrator` | indirect | Receives streaming events via PubSub from adapter |
| `SymphonyElixirWeb.DashboardLive` | indirect | Renders adapter session metadata + per-runtime token counters |

##### Data Flows

| Direction | Source/Target | Data | Notes |
|---|---|---|---|
| Reads | CLI stdout | streaming JSON events (turn deltas, tool calls, completion, runtime-native token counts) | Per-runtime schema; adapter passes through |
| Writes | CLI stdin | turn prompts, tool results | Per-runtime serialization |
| Writes | Workspace dir | agent-driven file edits | Sandboxed by per-kind sandbox config; adapter enforces safety floor before launch |

##### Shared Resources

| Resource | Shared With | Risk Notes |
|---|---|---|
| Workspace filesystem | Hook scripts, agent CLI | Adapter does NOT directly write workspace contents — sandbox enforcement is the agent CLI's responsibility |
| Stdio | One process per session | One process per item per attempt |

> **DARK CODE HOTSPOT:** Token accounting differs across runtimes — Codex App Server reports per-turn input/output split; Claude Code SDK reports `cache_read` / `cache_creation` / `input` / `output`; Gemini reports yet differently. This spec resolves the original ambiguity by making accounting **runtime-native pass-through** (DL-007). Cross-runtime aggregation is OUT OF SCOPE.

##### Deployment Model

- **Type:** Modules within Symphony Elixir (`lib/symphony_elixir/codex/`, `lib/symphony_elixir/claude/`, `lib/symphony_elixir/gemini/`, `lib/symphony_elixir/agent_runtime.ex`)
- **Runtime:** Elixir 1.19 / OTP 28; subprocesses via Erlang Port
- **Infrastructure:** Each agent CLI must be installed on the Symphony host (via `mise` or system package manager)

##### Ownership

- **Team:** Symphony reference implementation (MyBCAT)
- **On-call:** Ankit Patel

#### A.2 Behavioral Contracts

**Context captured:** 2026-05-03 by Ankit Patel + Claude

---

##### `AgentRuntime.start_session(workspace_path, config)`

> Launches the per-kind CLI as a subprocess. Returns an opaque session handle.

| Property | Value |
|---|---|
| **Idempotent** | No. Each call starts a new subprocess. |
| **Failure behavior** | `{:error, reason}` on launch failure (binary not found, workspace invalid, **sandbox config exceeds safety floor**). |
| **Performance envelope** | Codex: 1–3s. Claude: 0.5–2s. Gemini: 1–4s. |
| **Side effects** | Spawns OS process; opens stdio pipes; allocates Erlang Port. |
| **Retry guidance** | Safe after a clean `stop_session`. Dangerous if previous session didn't fully exit (Erlang Port leak). |
| **Data classification** | Internal. Inherits env per `shell_environment_policy`. |

##### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Binary not found | `{:error, {:enoent, path}}` | Operator install; abort dispatch for this profile |
| Workspace path invalid | `{:error, :invalid_workspace}` | Investigate `workspace.root` |
| Sandbox exceeds floor | `{:error, {:sandbox_floor_violation, profile_name, kind, field, value}}` | Operator fix profile config; refuse to silently downgrade |

##### Warnings

- Codex `approval_policy: never` is required for unattended runs. Other settings hang.
- Claude `permission_mode: default` blocks on prompts. Use `acceptEdits` for unattended.
- Gemini `--yolo` exceeds safety floor and is rejected.

---

##### `AgentRuntime.send_turn(session, prompt, opts)`

> Sends a turn to an active session.

| Property | Value |
|---|---|
| **Idempotent** | No. Each call appends a turn. |
| **Failure behavior** | `:ok` on accept; `{:error, reason}` if session is dead or stdio is broken. |
| **Performance envelope** | Submission near-instant; response streams. Per-turn duration: 30s–30min. |
| **Side effects** | Modifies session history; triggers model inference; may invoke tool calls (Codex's run_turn semantics preserved for `Codex.Adapter`; Claude's tool-use turn-loop preserved for `Claude.Adapter`; Gemini's equivalent for `Gemini.Adapter`). |
| **Retry guidance** | Dangerous to retry — risks duplicate turns. Caller MUST check session liveness before retry. |
| **Data classification** | Prompts may contain client/issue context derived from Monday item titles and descriptions. Apply Spec 1 §12 redaction rules at the adapter boundary. |

##### Warnings

- `agent.max_turns` caps `send_turn` calls per session lifetime. Default 20.
- First turn uses the full WORKFLOW.md-rendered prompt. Continuation turns send only continuation guidance.
- Codex App Server's `thread_id`/`turn_id` semantics MUST be preserved by `Codex.Adapter` to keep the orchestrator's `session_id = "<thread_id>-<turn_id>"` invariant.

---

##### `AgentRuntime.stream_events(session)`

> Returns an enumerable that yields normalized adapter-level events: `{:turn_delta, payload}`, `{:tool_call, payload}`, `{:tokens, %{input: int, output: int, ...native_keys}}`, `{:completion, summary}`, `{:error, reason}`.

| Property | Value |
|---|---|
| **Idempotent** | Yes (read-only stream); each call to enumerate consumes events. Multi-consumer not supported. |
| **Failure behavior** | Stream terminates on session end. Errors surface as `{:event, {:error, reason}}` in-stream, not raised. |
| **Performance envelope** | Unbounded — driven by agent activity. Memory pressure if consumer lags. |
| **Side effects** | None directly. |
| **Retry guidance** | N/A — one-way consumption. |
| **Data classification** | Events may include partial agent output containing client context. |

##### Warnings

- The `{:tokens, ...}` event payload preserves runtime-native keys (e.g., Claude's `cache_read`). Consumer MUST NOT assume cross-runtime keys are uniform.
- Stall timeout is per-runtime: `codex.stall_timeout_ms`, `claude.stall_timeout_ms`, `gemini.stall_timeout_ms` (each defaults to 300000ms).

---

##### `AgentRuntime.runtime_native_tokens(session)`

> Returns the runtime's full native token map for the session.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure read. |
| **Failure behavior** | Returns empty map if session is too young; never raises. |
| **Performance envelope** | O(1). |
| **Side effects** | None. |
| **Retry guidance** | Safe. |
| **Data classification** | Internal. |

##### Warnings

- Cross-runtime totals are NOT comparable. The orchestrator stores these under `agent_native_tokens.<kind>` and does NOT roll up.
- `Codex.Adapter` returns `{input, output, total}` (Codex App Server's native shape).
- `Claude.Adapter` returns `{input, output, cache_read, cache_creation, total}` (Anthropic's shape).
- `Gemini.Adapter` returns `{prompt, candidates, cached, total}` (Gemini's shape).

#### A.3 Decision Log

**Context captured:** 2026-05-03 by Ankit Patel + Claude

---

##### DL-001: First-class multi-runtime abstraction (not Codex App Server with shims)

- **Date:** 2026-05-03
- **Context:** Original spec was Codex-only. Goal: Codex + Claude + Gemini as first-class runtimes for routing.
- **Alternatives considered:**
  - Codex App Server protocol with shims for Claude/Gemini: Rejected — Claude Code and Gemini have fundamentally different session models.
  - Single-shot mode (CLI invoked per turn): Rejected — loses streaming events, token accounting, session affinity.
- **Consequences:**
  - Enables: native exploitation of each CLI's strengths; clean profile-based routing.
  - Constrains: three adapters to maintain; cross-runtime feature parity not guaranteed.
- **Warning:** If reversed (single-protocol shims), each non-Codex CLI must be wrapped in an App Server-compatible binary; Claude `permission_mode` and Gemini long-context features become coupled to shim translation.

---

##### DL-002: Sandbox/approval fields are per-kind (not unified spec fields)

- **Date:** 2026-05-03
- **Context:** Codex has `approval_policy` / `thread_sandbox` / `turn_sandbox_policy`. Claude has `permission_mode` / `allowed_tools`. Gemini has its own.
- **Alternatives considered:**
  - Unified sandbox model with cross-runtime mapping: Rejected — semantics differ; either leaks or drops fidelity.
  - Lowest-common-denominator: Rejected — kills runtime-specific features.
- **Consequences:**
  - Enables: each runtime's full sandbox vocabulary.
  - Constrains: WORKFLOW.md authors learn three vocabularies if using all three runtimes.
- **Warning:** If reversed, runtime-specific features must be either dropped or re-introduced as escape hatches. Both reduce safety.

---

##### DL-003: No mid-flight runtime swap

- **Date:** 2026-05-03
- **Context:** Profile changes mid-session require migrating in-flight conversation history across fundamentally different message formats.
- **Alternatives considered:**
  - Hot-swap with prompt re-rendering: Rejected — loses agent's accumulated tool-use context.
  - Hot-swap by aborting current turn first: Rejected — same context loss; complexity for marginal value.
- **Consequences:**
  - Enables: simpler adapter contracts; clear ownership boundaries.
  - Constrains: profile changes apply on next session start, not current.
- **Warning:** If reversed, the AgentRuntime contract must support session-format conversion or transparent restart. The orchestrator's `session_id` model breaks.

---

##### DL-004: Named profiles (kind + config bundle)

- **Date:** 2026-05-03
- **Context:** Routing must support not just runtime selection but model-variant selection (Claude Opus vs Sonnet, gpt-5.5 vs gpt-5.5-mini).
- **Alternatives considered:**
  - Single config per kind with per-issue kind override: Rejected — only routes runtime, not model.
  - LLM-as-router: Rejected — too magical; cost overhead per dispatch.
- **Consequences:**
  - Enables: A/B testing models on real issues by flipping a column; future rule-based routing extends profiles cleanly.
  - Constrains: profile names are global per WORKFLOW.md.
- **Warning:** If reversed (kind-only override), every existing item with a profile column value loses semantic meaning.

---

##### DL-005: Two-level precedence only (no rule-based routing in v1)

- **Date:** 2026-05-03
- **Context:** Rule-based routing is documented as a future extension.
- **Alternatives considered:**
  - Rule-based in v1: Rejected — increases spec surface and validation complexity.
- **Consequences:**
  - Enables: spec ships fast; rules can be added later as a strict superset.
  - Constrains: complex policy must be encoded by humans setting the column.
- **Warning:** If reversed, adapter test surface grows; rules need their own validation, ordering, conflict resolution.

---

##### DL-006: Profile column = privileged input; sandbox safety floor enforced

- **Date:** 2026-05-03 (review-driven)
- **Context:** Claude HIGH #1 and Codex HIGH §6 flagged: anyone with Monday board edit rights can flip an item from `claude_sonnet` to `codex_yolo` or similar, escalating privilege on an unattended runtime. The Monday Profile column is now part of the trust boundary.
- **Alternatives considered:**
  - Trust the dropdown without enforcement: Rejected — privilege-escalation path.
  - Restrict the column via Monday permissions only (no Symphony enforcement): Rejected — defense-in-depth requires Symphony to also refuse violations.
  - Both Monday-side dropdown permission AND Symphony-side floor enforcement: Selected.
- **Consequences:**
  - Enables: hard refusal of unsafe profiles even if Monday permissions slip; explicit operator signal on violation.
  - Constrains: each runtime adapter must implement a `passes_safety_floor?(config) -> bool` function with explicit per-kind mapping; any spec/CLI release that adds new sandbox values requires updating the mapping.
- **Warning:** If reversed, a single Monday board edit can launch an unrestricted agent in a workspace with read access to the source repo — full HIPAA compliance regression risk. Treat the safety floor as a security invariant, not a config preference.

---

##### DL-007: Token accounting = runtime-native pass-through

- **Date:** 2026-05-03 (review-driven; resolves Claude HIGH #5)
- **Context:** Original spec contradicted itself: §2 said "no cross-runtime normalization"; B.1 said "MUST normalize to {input, output, total}." Implementing agent would silently fold Claude `cache_read` into `input`, breaking cost analysis.
- **Alternatives considered:**
  - Force normalization (lossy): Rejected — destroys signal needed for cost accounting.
  - Both native + normalized: Rejected — implementing agent would still silently lose data when normalization is the public surface.
  - Native pass-through, no rollup, store under `agent_native_tokens.<kind>.<field>`: Selected.
- **Consequences:**
  - Enables: full per-runtime fidelity; correct cost accounting per provider; no false equivalence.
  - Constrains: dashboard cannot show a single "total tokens" across multi-runtime sessions; consumers must aggregate per-runtime explicitly.
- **Warning:** If reversed (re-introducing normalization), Claude `cache_read` discounted-rate billing collapses into nominal `input` cost; analyses underweight Codex's higher per-token cost; cross-runtime A/B becomes apples-to-oranges silently.

---

##### DL-008: Profile re-resolves at every retry boundary

- **Date:** 2026-05-03 (review-driven; resolves Codex HIGH §1)
- **Context:** Original spec said "no fallback across runtimes" AND "profile changes apply on next attempt" — these are compatible only if profile resolution happens at each attempt's start.
- **Alternatives considered:**
  - Pin profile at first attempt; ignore mid-flight column changes: Rejected — operator can't intervene.
  - Re-resolve at every attempt boundary: Selected.
  - Re-resolve mid-session: Rejected (DL-003 forbids).
- **Consequences:**
  - Enables: operator override mid-flight (e.g., escalate from Sonnet to Opus on a stuck item by flipping the column).
  - Constrains: per-attempt API call to read the column (small overhead, already part of the poll cycle).
- **Warning:** If reversed (pinning at first attempt), operators can't escalate stuck items without manually canceling and re-creating; defeats one of the main use cases for per-issue routing.

---

##### DL-009: Per-profile concurrency caps (alongside global cap)

- **Date:** 2026-05-03 (review-driven; addresses Claude MED #7, Gemini MED #3)
- **Context:** A global concurrency cap of 10 with all items routed to `claude_opus` ($15/MTok input) means a typo in a long-running prompt loop could burn $1K/day.
- **Alternatives considered:**
  - Global cap only: Rejected — insufficient cost control.
  - Per-profile budget in dollars: Rejected — adds billing-API integration; overkill for v1.
  - Per-profile concurrency caps (positive int): Selected.
- **Consequences:**
  - Enables: bounded blast radius per expensive profile; team can set `claude_opus.max_concurrent: 2` while leaving `claude_sonnet.max_concurrent: 10`.
  - Constrains: orchestrator dispatch logic grows a per-profile counter alongside the global counter.
- **Warning:** If reversed, a single Symphony Profile typo applied via Monday batch-edit could enroll 100 items into Opus simultaneously and burn a month's API budget overnight. Treat as a cost-control invariant.

---

##### DL-010: Startup validation of profile-name ↔ Monday dropdown drift

- **Date:** 2026-05-03 (review-driven; locks original AW-5 + AW-6)
- **Context:** Monday dropdown columns store values as text. Drift between WORKFLOW.md `profiles` keys and Monday dropdown labels causes silent dispatch failures (AW-6) and misconfigured columns (AW-5).
- **Alternatives considered:**
  - Defer to runtime errors (status quo per AW-5/AW-6): Rejected — review consensus that this is a correctness precondition.
  - Auto-create dropdown labels: Rejected — Symphony does not write to board structure.
  - Read dropdown labels at startup; warn on drift; refuse to boot if column missing: Selected.
- **Consequences:**
  - Enables: operators see drift on startup, not on first dispatch failure; unknown-profile errors caught at config load.
  - Constrains: requires Monday API call at startup; small overhead.
- **Warning:** If reversed (no validation), the team renames a profile in WORKFLOW.md without updating the Monday dropdown; existing Monday items still have the old value; Symphony silently skips them; operators don't notice for hours.

---

##### DL-011: Each profile must declare 10-Layer Framework alignment (Layers 5/6/8 minimum)

- **Date:** 2026-05-03 (captured-framework-driven; aligns with Spec 1 DL-012)
- **Context:** OB_mybcat captured 2026-05-03: every agent must specify all 10 layers of the MyBCAT Agent Operating Framework before shipping. Profile definitions in this spec encode the runtime + sandbox + capabilities; each profile is effectively a deployed agent and must satisfy Layers 5 (Tool/Action: writes need approval flag), 6 (Control/Approval: default to "propose"), and 8 (Monitoring/Audit: log everything).
- **Layer 5 — Tool/Action enforcement per profile:**
  - Profile sandbox safety floor (DL-006) is the Layer 5 boundary; an agent dispatched on a profile cannot write outside its sandbox.
  - The agent has no Monday access (per Spec 1 DL-005), so Monday writes need no per-profile approval flag.
- **Layer 6 — "Default to 'propose'":**
  - All profiles use `--print` / `--non-interactive` / equivalent — sessions don't auto-merge or auto-deploy. Every "consequential" action (PR open) is a propose; merge is human-gated via `Human Review → Merging` transition.
- **Layer 8 — Monitoring/Audit:**
  - Per-runtime native token counters (DL-007) cover input/output/cache breakdowns.
  - Adapter event streams logged at `info` level (with PHI redaction) per Spec 1 §12.
  - Profile dispatch decisions logged with `profile_name`, `kind`, `model`, `safety_floor_passed: true|false`.
- **Alternatives considered:**
  - Skip framework alignment (developer-tooling exception): Rejected — same accountability bar as operational agents.
  - Full 10-layer specification per profile: Rejected — overweight; layers 1/2/4/7/9/10 are addressed at the WORKFLOW.md level, not per-profile.
- **Consequences:**
  - Enables: profiles are governance-aligned by construction.
  - Constrains: cannot ship a profile that violates the safety floor; cannot ship a profile that auto-merges.
- **Warning:** If reversed (skip alignment), profiles can be added that bypass the framework. Auditability degrades.

---

### Part B — Routing Layer

#### B.1 Module Manifest

> Resolves which agent profile handles each Monday item, by precedence: per-issue Monday `Symphony Profile` column → `agent.default_profile`. Re-resolves at every retry attempt boundary.

**Context captured:** 2026-05-03 by Ankit Patel + Claude

##### Dependencies

| Dependency | Type | Description |
|---|---|---|
| `SymphonyElixir.Config` | shared library | Reads `profiles` map and `agent.default_profile` |
| `SymphonyElixir.Monday.Adapter` | sync calls | Reads per-issue `tracker.profile_column_id` value |

##### Dependents

| Dependent | Type | Description |
|---|---|---|
| `SymphonyElixir.AgentRunner` | sync calls | Calls `ProfileResolver.resolve(issue) → profile` before launching the runtime; called at every attempt boundary (initial + each retry) |

##### Data Flows

| Direction | Source/Target | Data | Notes |
|---|---|---|---|
| Reads | WORKFLOW.md (via Config) | `profiles` map and `default_profile` | Single source for profile definitions |
| Reads | Monday item column | profile dropdown value | Read fresh at each attempt boundary |

##### Shared Resources

| Resource | Shared With | Risk Notes |
|---|---|---|
| Profile name namespace | All boards using this WORKFLOW.md | Profiles are global per WORKFLOW.md; renaming a profile invalidates every Monday item that references it (mitigated by DL-010 startup drift detection) |

##### Deployment Model

- **Type:** Pure module (`lib/symphony_elixir/profile_resolver.ex`)
- **Runtime:** Elixir 1.19 / OTP 28
- **Infrastructure:** Stateless

##### Ownership

- **Team:** Symphony reference implementation
- **On-call:** Ankit Patel

#### B.2 Behavioral Contracts

**Context captured:** 2026-05-03 by Ankit Patel + Claude

---

##### `ProfileResolver.resolve(issue, profiles_map, default_profile_name)`

> Returns `{:ok, profile}` for the given Monday item using precedence rules, or `{:error, reason}` on misconfiguration.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure function. |
| **Failure behavior** | `{:error, :unknown_profile}` if per-issue column names a profile not in `profiles_map`. `{:error, :no_default}` if column empty AND no default. `{:error, {:safety_floor_violation, ...}}` if resolved profile fails the safety floor. |
| **Performance envelope** | O(1) — single map lookup + safety floor check. |
| **Side effects** | None. |
| **Retry guidance** | Safe; deterministic on inputs. Note that *callers* re-resolve at retry boundaries to pick up Monday-side column changes. |
| **Data classification** | Internal. |

##### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Per-issue profile name not in `profiles_map` | `{:error, :unknown_profile}` | Operator alert; item skipped; suggest profile name typo or missing definition |
| Empty per-issue column AND no default | `{:error, :no_default}` | Operator config error |
| Resolved profile fails safety floor | `{:error, {:safety_floor_violation, profile_name, kind, field, value}}` | Operator must fix the profile config or remove it |

##### Warnings

- Profile name comparison is case-sensitive. `Claude_Opus` ≠ `claude_opus`. Document in WORKFLOW.md examples.
- Safety floor check belongs here (in resolver) so unsafe profiles are caught before any subprocess spawn cost.

---

##### `ProfileResolver.validate_drift(profiles_map, monday_dropdown_labels)`

> Compares WORKFLOW.md profile names against the Monday dropdown column's defined labels. Returns warnings (not errors) for drift.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure function. |
| **Failure behavior** | Never raises; always returns `{:ok, %{missing_in_dropdown: [...], orphan_dropdown_labels: [...]}}`. |
| **Performance envelope** | O(n) on profile count. |
| **Side effects** | None. |
| **Retry guidance** | Safe. Called at startup only. |
| **Data classification** | Internal. |

##### Warnings

- Drift is logged as warning, not error. Symphony continues to boot. Items that try to use missing profiles will hit `:unknown_profile` at dispatch time per `resolve/3`.

#### B.3 Decision Log

See Part A's DL-001..DL-010 above; the routing layer's decisions are interleaved with the runtime layer's decisions because they're tightly coupled (especially DL-006 safety floor, DL-008 retry re-resolution, DL-010 drift validation).

---

## 7. SPEC.md Concrete Diff Plan (Spec 2 scope only)

### Sections to amend
- §3 System Overview — broaden coding-agent references from Codex-only to multi-runtime; add Routing Layer note.
- §4.1.6 Live Session — rename `codex_*` token fields to `agent_native_tokens.<kind>.<field>` shape (per DL-007).
- §5.3.6 codex → §5.3.6 agent (multi-kind block).
- §6.4 Cheat Sheet — rewrite agent rows; add profile rows; add safety-floor field.
- §7 Orchestration — replace `codex_*` field names with `agent_*`; add per-profile concurrency tracking.

### New sections
- §3.3 Native Runtime Interfaces (informative table per kind; sandbox vocabulary mapping).
- §5.3.7 profiles (schema + safety floor rules + drift detection).
- §6.5 Routing Resolution (precedence + retry re-resolution).
- §6.6 Safety Floor (per-kind passes-floor predicates).

### Removed sections / fields
- §5.3.6's Codex-shaped fields (replaced by per-kind blocks).

### Renames (global)
- `codex_app_server_pid` → `agent_pid` (single field; kind-aware).
- `codex_input_tokens` etc. → `agent_native_tokens.<kind>.input` etc.
- `codex_totals` → REMOVED (per DL-007; per-runtime native maps replace).
- `codex_rate_limits` → `agent_native_rate_limits.<kind>`.

---

## 8. Reference Implementation Deltas

| Existing path | New path / change |
|---|---|
| `lib/symphony_elixir/codex/app_server.ex` | renamed `codex/adapter.ex`; refactored to implement new `AgentRuntime` behaviour; preserves all existing thread/run_turn semantics (Codex HIGH §5) |
| `lib/symphony_elixir/codex/dynamic_tool.ex` | unchanged from Spec 1 (already provides `monday_graphql` tool); now also reused by Claude.Adapter and Gemini.Adapter via shared module |
| n/a | new `lib/symphony_elixir/agent_runtime.ex` (behaviour) |
| n/a | new `lib/symphony_elixir/claude/adapter.ex` (implements `AgentRuntime`) |
| n/a | new `lib/symphony_elixir/gemini/adapter.ex` (implements `AgentRuntime`) |
| n/a | new `lib/symphony_elixir/profile_resolver.ex` (`resolve/3`, `validate_drift/2`, `passes_safety_floor?/2`) |
| `lib/symphony_elixir/agent_runner.ex` | calls `ProfileResolver.resolve` at start AND on retry; selects adapter module by `profile.kind` |
| `lib/symphony_elixir/orchestrator.ex` | adds per-profile concurrency counters alongside global counter |
| `lib/symphony_elixir/config.ex` | adds `profiles` map parse; `agent.default_profile`; `agent.sandbox_safety_floor`; per-kind sub-blocks |
| `WORKFLOW.md` | adds `profiles` block; renames `codex` block conventions |
| `mix.exs` | `ignore_modules` updated for renames; new modules added |

---

## 9. Tech Board Setup Delta (Spec 2 only)

Spec 1's setup is assumed complete. Spec 2 adds:

1. Create the `Symphony Profile` Dropdown column on Tech Board (`8173460438`).
2. Populate the dropdown with values matching `profiles` keys in WORKFLOW.md (e.g., `claude_opus`, `claude_sonnet`, `codex_gpt55_xhigh`, `gemini_long_context`).
3. (Recommended) Restrict the column's edit permission via Monday board permissions to a vetted role (e.g., admin or specific user group), so the privilege-escalation surface is bounded by Monday-side permissions in addition to Symphony's safety floor (defense-in-depth).
4. Record the column ID in WORKFLOW.md `tracker.profile_column_id`.

---

## 10. Out of Scope for Spec 2

1. Rule-based routing — remains future extension. `agent.routing_rules` is not implemented.
2. Cross-runtime token normalization — explicitly forbidden per DL-007.
3. Mid-flight runtime swap — explicitly forbidden per DL-003.
4. LLM-as-router — explicitly out per DL-004 alternatives.
5. Per-profile budget caps in dollars — only concurrency caps, not billing integration.
6. Auto-creation of Monday dropdown labels — Symphony refuses to write board structure (only operates within configured columns).

---

## 11. Ambiguity Warnings — All Locked

Per Ankit's 2026-05-03 instruction ("don't keep answering questions, use captured context"), all four open ambiguities are now locked. The implementing agent treats these as binding constraints.

### AW-1 — Claude session resumption across Symphony restarts — LOCKED: START FRESH
- **Decision:** On Symphony restart, the Claude adapter starts a fresh session per item. Pre-restart Claude session IDs are not preserved.
- **Rationale:** Workspace preservation from Spec 1 gives the agent full file-system context. Session-state continuity is luxury; freshness is correctness.
- **Implementation:** Claude adapter does not call `--continue <session_id>` after Symphony cold-start; first turn sends the full WORKFLOW.md prompt.

### AW-2 — Gemini CLI streaming JSON schema stability — LOCKED: PIN VERSION + RUNTIME ASSERT
- **Decision:** Pin Gemini CLI to a tested version range in `mise.toml`. Adapter asserts at startup that the installed version matches the supported range; refuses to dispatch if not.
- **Rationale:** Gemini CLI is fast-moving; schema drift between versions silently produces parse errors mid-session. Pinning + runtime assert catches this at boot, not at first agent dispatch.
- **Implementation:** `mise.toml` adds `gemini = "X.Y.Z..X.Y.W"` range; `Gemini.Adapter.startup_check/0` shells `gemini --version`, parses, refuses to register the runtime if outside range.

### AW-3 — Per-profile rate-limit budgeting — LOCKED: OUT OF SCOPE FOR v1
- **Decision:** v1 has no provider-aware quota tracking. Adapters surface `:rate_limited` events; orchestrator applies exponential backoff per-runtime.
- **Rationale:** Provider quota tracking requires per-provider billing API integration (Anthropic admin API, OpenAI usage API, Google quota API). Out of scope for tracker-runtime split.
- **Implementation:** Each adapter handles 429 responses by emitting `{:event, :rate_limited}`; orchestrator backs off and retries; per-profile `max_concurrent` (DL-009) is the v1 cost control.

### AW-4 — Tool-use vocabulary differences across runtimes — LOCKED: PER-ADAPTER OWNERSHIP (no shared injection)
- **Decision:** Each adapter exposes the runtime's native tool catalog (Codex's tools, Claude's `Read`/`Edit`/`Write`/`Bash`, Gemini's equivalents). Symphony does not inject a unified `monday_graphql` tool because — per Spec 1 DL-005 — agents do NOT write to Monday; Symphony's Tracker primitive does. This eliminates the cross-runtime translation layer entirely.
- **Rationale:** The captured architecture removes the cross-runtime tool-translation problem by removing the cross-runtime tool. Simpler.
- **Implementation:** Each adapter passes through native tool config from the profile (`profiles.<name>.<kind>.allowed_tools` for Claude, etc.) without modification.

---

## 12. Implementation Constraints

### General
- All Spec 1 constraints carry forward (Elixir 1.19/OTP 28; `mix all` quality gate; `@spec` requirement; single-line bash blocks; PHI logging policy from Spec 1 §12).
- New CLIs must be installed on the Symphony host: Codex (existing), Claude (`claude` ≥ 4.7 SDK supporting `--print --output-format stream-json`), Gemini (`gemini` ≥ 2.5 CLI with `stream-json`). Pin via `mise.toml`.
- Adapter token redaction: each adapter's logged events MUST go through the same `redact/1` boundary as the Monday adapter (Spec 1 §12 Rule 3).

### Sandbox safety floor implementation
- Each adapter MUST implement `passes_safety_floor?(profile_config, floor_config) -> boolean` returning `false` if any sandbox setting exceeds the floor.
- `Codex.Adapter.passes_safety_floor?/2` — checks `thread_sandbox` ∈ {`read-only`, `workspace-write`} AND `approval_policy: never`.
- `Claude.Adapter.passes_safety_floor?/2` — checks `permission_mode: acceptEdits` AND `allowed_tools` does not include any Bash glob matching denylist patterns.
- `Gemini.Adapter.passes_safety_floor?/2` — checks `--sandbox` is set AND `--yolo` is NOT set.
- A unit test per adapter MUST assert that exceeding-the-floor configurations return `false`.

### Token accounting
- Each adapter MUST emit `{:tokens, native_map}` events with the runtime's native key set (no normalization).
- The orchestrator stores `agent_native_tokens.<kind>.<field>` and does NOT compute cross-runtime `total_tokens`.
- Dashboard MUST render per-runtime token counters separately (no rollup).

---

## 13. Sample WORKFLOW.md (informative)

Builds on Spec 1's sample. Adds `profiles` block, `default_profile`, `sandbox_safety_floor`, and `Symphony Profile` column reference.

```yaml
---
tracker:
  kind: monday
  api_token: $MONDAY_API_TOKEN
  endpoint: https://api.monday.com/v2
  board_id: 8173460438
  identifier_prefix: "SYM"
  symphony_status_column_id: "<set>"
  profile_column_id: "<set after Symphony Profile column creation>"
  pr_column_id: "<set>"
  heartbeat_item_id: "<set>"
  heartbeat_ttl_ms: 60000
  complexity_budget_per_tick: 500
  backoff_factor: 2.0
  max_polling_interval_ms: 60000
  failure_ttl_count: 5
  description_column_id: null
  branch_column_id: null
  active_states: ["Symphony Ready", "In Progress", "Rework"]
  handoff_states: ["Human Review", "Merging"]
  terminal_states: ["Done", "Cancelled"]
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
profiles:
  claude_opus:
    kind: claude
    max_concurrent: 2
    claude:
      command: "claude --print --output-format stream-json --input-format stream-json"
      model: "claude-opus-4-7"
      permission_mode: "acceptEdits"
      allowed_tools: ["Read", "Edit", "Write", "Bash(git:*)", "Bash(make:*)", "Bash(mix:*)"]
  claude_sonnet:
    kind: claude
    max_concurrent: 6
    claude:
      command: "claude --print --output-format stream-json --input-format stream-json"
      model: "claude-sonnet-4-6"
      permission_mode: "acceptEdits"
      allowed_tools: ["Read", "Edit", "Write", "Bash(git:*)", "Bash(make:*)", "Bash(mix:*)"]
  codex_gpt55_xhigh:
    kind: codex
    max_concurrent: 4
    codex:
      command: "codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
      approval_policy: never
      thread_sandbox: workspace-write
  gemini_long_context:
    kind: gemini
    max_concurrent: 3
    gemini:
      command: "gemini --model gemini-2.5-pro --output-format stream-json --sandbox"
agent:
  default_profile: claude_opus
  sandbox_safety_floor:
    codex:
      thread_sandbox: workspace-write
      approval_policy: never
    claude:
      permission_mode: acceptEdits
      bash_denylist: ["*sudo*", "*rm -rf*", "*chmod 777*", "*curl * | sh*", "*wget * | sh*"]
    gemini:
      require_sandbox: true
      forbid_yolo: true
  max_concurrent_agents: 10
  max_turns: 20
---

You are working on a Monday.com item `{{ issue.identifier }}`.

(rest of prompt body inherited from Spec 1; the agent flow is unchanged from
Spec 1 except that the runtime invoking this prompt is now profile-determined.)
```

---

## 14. Approval Checklist

- [ ] §1 — System overview clearly scopes Spec 2 as runtime + routing only.
- [ ] §2 — Behavioral contract covers runtime selection, sandbox floor, profile resolution, retry re-resolution, runtime-native tokens, per-profile caps, drift validation.
- [ ] §3 — Non-behaviors lock no runtime fallback, no normalization, no auto-downgrade, no silent default fallback.
- [ ] §4 — Integration boundaries cover all three CLIs with native sandbox vocabulary AND safety-floor mapping.
- [ ] §5 — 7 scenarios; S4 covers safety-floor refusal, S5 covers profile typo, S6 covers drift detection.
- [ ] §6 — Both context-layer parts (Agent Runtime, Routing) have Module Manifest + Behavioral Contracts + Decision Log.
- [ ] §7 — SPEC.md diff plan is concrete and runtime-scoped.
- [ ] §8 — Reference impl deltas runtime-scoped; tracker layer untouched.
- [ ] §9 — Tech Board delta is just one column + permission restriction recommendation.
- [ ] §10 — Out-of-scope items align with deferred future extensions.
- [ ] §11 — 4 remaining ambiguities are minor; all major review findings locked via DL-006..DL-010.
- [ ] §12 — Sandbox floor implementation prescribed per adapter; token accounting native-only.
- [ ] §13 — Sample WORKFLOW.md includes profiles, sandbox_safety_floor, Gemini --sandbox baseline (Claude LOW #15 fix).
