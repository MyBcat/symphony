# Symphony — Production Readiness (Spec 4)

**Status:** Draft for review
**Date:** 2026-05-04
**Authors:** Ankit Patel + Claude (Opus 4.7, 1M context). Multi-AI scope brainstorm via Gemini 2.5 Pro + Claude Explore subagent (synthesis appended in §14).
**Sequencing:** Spec 4. **Depends on Spec 1, 2, 3 + dispatch-fix PR + carlos_low_vision wire-up** all merged. As of this draft those are at HEAD on main; one fix branch (`fix/claude-adapter-cli-flags`) is open and addresses §2.1 below.
**Modifies:** New modules under `lib/symphony_elixir/{cost,observability,secrets,pr_safety,dashboard_web}/**`; `lib/symphony_elixir/{orchestrator,agent_runner,workspace,monday/adapter}*` for hookups; `WORKFLOW.md` for `agent.cost_caps`, `repos.<key>.secrets`, `agent.dashboard`; `elixir/lib/symphony_elixir/{claude,codex,gemini}/adapter.ex` for any §2.2 verification gaps.
**Does NOT modify:** Spec 1 tracker contract; Spec 2 agent runtime contract; Spec 3 multi-repo dispatch contract. All extension points stay in their owning specs.
**Skills applied:** `agent_spec_writer` (format), `agent-team` (multi-AI scope brainstorm — Gemini + Claude Explore; Codex skipped since `/codex:review` is git-context-only and this is forward-looking design), `context-layer-generator` (per-part artifacts in §6).

| Locked decision | Source |
|---|---|
| Layered cost guardrails: hard daily kill switch + per-profile per-day cap + per-session cap | DL-001 |
| Phoenix LiveView dashboard at `localhost:4000` (read-only) — already in deps; no separate web app | DL-002 |
| Per-repo secret injection via `repos.<key>.secrets: [SECRET_REF, ...]` resolved from AWS Secrets Manager into agent env at spawn time | DL-003 |
| Mandatory PHI gate before agent dispatch (Spec 3 already has `PHIDetector.scan` on title + description; this spec hardens it to a refuse-default) | DL-004 |
| Heartbeat-based leader election: status-column transition is the atomic lock; no external consensus | DL-005 |
| PR naming convention `symphony/SYM-<id>/<profile>/<attempt>`; never force-push; retry attempt opens new PR if prior PR still open | DL-006 |
| Max retry limit (default 3) → item moves to terminal `Cancelled` with `## Symphony Failures` update | DL-007 |
| Live e2e test harness uses a dedicated test board + a sandbox repo; runs nightly via GitHub Actions | DL-008 |
| Symphony writes back failures to the item's Monday Workpad on every error path (not just on completion) | DL-009 |
| Token accounting stays per-runtime per Spec 2 DL-007; cost caps are computed from those native counters, not normalized | DL-010 |

---

## 1. System Overview

Spec 4 takes Symphony from "dispatches and runs" (state at end of Spec 3) to "safe to leave running unattended on real MyBCAT repos." It's a packaging spec: nine cross-cutting concerns that each have a small implementation footprint individually but only matter when a non-engineer founder is asleep and an agent loop has gone wrong.

The nine concerns:
1. **Adapter flag injection** (§2.1) — already in `fix/claude-adapter-cli-flags`; spec captures it for completeness.
2. **Cost guardrails** (§2.2) — token spend caps so a hallucination loop can't drain $X overnight.
3. **Failure observability + Monday writebacks** (§2.3) — every error path posts a Monday Workpad update + structured event.
4. **Per-repo secret injection** (§2.4) — `HUBSPOT_TOKEN` lands in the agent's env without polluting WORKFLOW.md.
5. **PHI mandatory gate** (§2.5) — refuse-default if `PHIDetector.scan` flags either the title or description.
6. **Phoenix LiveView dashboard** (§2.6) — read-only `localhost:4000` showing queue, running, spend-vs-budget, recent failures.
7. **Heartbeat resilience** (§2.7) — two-instance racing, Monday outage, deleted sentinel.
8. **PR safety** (§2.8) — naming, no-force-push, retry-when-PR-already-open.
9. **Live e2e test harness** (§2.9) — automated end-to-end smoke without operator clicks.

Out of scope: cloud deployment, multi-board support (Spec 5), terminal/web UI for editing WORKFLOW.md (operator edits the file by hand).

---

## 2. Behavioral Contract (system-level)

### 2.1 Claude.Adapter CLI flag injection (already addressed in fix branch)
- **When** `Claude.Adapter.start_session/2` is called and the profile config provides `model`, `permission_mode`, or `allowed_tools`, **the system** appends them as CLI flags before spawning the bash port.
- **When** the base command isn't a `claude` invocation (test fixtures using `printf`, etc.), **the system** does NOT append the flags.
- Already implemented in `fix/claude-adapter-cli-flags` PR; spec captures it for completeness alongside Codex/Gemini-adapter verification.

### 2.2 Cost guardrails (layered)
- **When** Symphony is about to dispatch an item, **the system** checks three caps in order: per-session, per-profile-per-day, global-per-day. If any is exceeded, dispatch is refused with `{:error, {:cost_cap_exceeded, scope, current, cap}}`.
- **When** an agent's running session crosses its per-session cap mid-stream, **the system** sends `stop_session` to the runtime adapter and posts a Monday Workpad update naming the cap.
- **When** the global daily cap is hit, **the system** stops dispatching ALL items (regardless of profile) until the next UTC midnight or operator manual reset.
- **The system** computes cost from runtime-native token counters per Spec 2 DL-007 — no cross-runtime normalization.
- **The system** uses pricing from a static `agent.pricing` map in WORKFLOW.md (operator-maintained, decoupled from any vendor API).
- **When** the operator wants to reset a cap mid-day, **the system** exposes `Cost.reset_caps/1` callable from `iex` or via a Monday item with status `Reset Cost`.

### 2.3 Failure observability + Monday writeback contract
- **When** any error path fires (workspace failure, agent crash, PHI gate, cost cap, profile-not-allowed, unknown repo, Monday API failure), **the system** posts a Monday Workpad update on the affected item with marker `## Symphony Failures` and the structured error tuple.
- **When** the same item hits the same error N consecutive retries (default 3), **the system** moves the item to `Cancelled` and stops retrying.
- **When** a worker host or the orchestrator itself crashes, **the system** writes a structured event to the disk log AND triggers a Phoenix `LiveDashboard` PubSub broadcast for the dashboard (§2.6).
- **The system** does NOT emit telemetry to external services in v1 (no Prometheus, no CloudWatch, no Slack). All observability is local (disk log + Monday Workpad + dashboard).

### 2.4 Per-repo secret injection
- **When** a `repos.<key>.secrets: [SECRET_REF, ...]` list is configured, **the system** resolves each `SECRET_REF` from AWS Secrets Manager via the existing `secret_exec.py` wrapper and injects them as env vars into the agent's spawned process.
- **The system** does NOT echo or log secret values; it logs only the secret names being resolved.
- **When** secret resolution fails, **the system** refuses dispatch with `{:error, {:secret_resolution_failed, repo_key, secret_ref, reason}}`.
- **The system** does NOT inject secrets into the prompt template — secrets are env-only.
- **The system** scrubs the agent's stdout/stderr for the resolved secret values before they hit Symphony's logs (defense-in-depth match the secret_exec.py redaction pattern).

### 2.5 PHI mandatory gate
- **When** a Monday item is fetched, `PHIDetector.scan` runs against title + description (already implemented via Spec 1).
- **When** a finding is detected, **the system** refuses dispatch, posts `## Symphony Failures` with `{:error, {:phi_detected, finding_count}}` (no PHI in the log), and moves the item to `Cancelled`. Operator must clear the PHI before re-enrolling.
- **When** the operator enables `agent.phi_gate: false` (override flag in WORKFLOW.md), **the system** boots with a loud startup warning naming the override; refuses if the operator is in production mode.
- The system MUST NOT trust the agent to "self-scrub" or pass PHI through with any escape hatch.

### 2.6 Phoenix LiveView dashboard at `localhost:4000`
- **The system** exposes a read-only LiveView at `localhost:4000/dashboard` (port configurable via `agent.dashboard.port`) that renders:
  - Queue: items in `Symphony Ready` not yet dispatched
  - Running: per-agent rows with profile, repo, PID, age, native token totals, cost-so-far
  - Backoff: items in retry queue with attempt count + next-retry timestamp
  - Spend: today's spend per profile + global; cap utilization bars
  - Recent failures: last 10 errors with item identifier + error tuple
- **The system** uses the existing `SymphonyElixir.PubSub` (already in deps per Spec 1) for live updates; no polling.
- **The system** binds to `127.0.0.1` only (never 0.0.0.0). HIPAA boundary.
- **The system** does NOT expose item descriptions / titles in the dashboard if they would leak PHI; render a redacted placeholder when PHI was detected.
- **The system** keeps the existing TUI dashboard intact; LiveView is additive.

### 2.7 Heartbeat resilience
- **When** two Symphony instances boot against the same Monday board, **the system** uses the heartbeat sentinel item's status column as the atomic lock: only the instance whose `change_simple_column_value(heartbeat_item_id, status, "Active")` mutation succeeds first becomes leader. The runner-up enters standby and polls the sentinel every `heartbeat_ttl_ms`.
- **When** the leader's heartbeat update fails for `failure_ttl_count` consecutive ticks, **the leader** voluntarily steps down; the standby attempts promotion on next tick.
- **When** Monday API is unavailable for longer than `heartbeat_ttl_ms`, **the system** enters `degraded` mode: stops dispatching new items but keeps in-flight agents running, and broadcasts a dashboard alert.
- **When** the heartbeat sentinel item is deleted or missing at boot, **the system** refuses to boot with a clear operator-facing error: "Heartbeat sentinel item <id> not found. Recreate it on board <board_id> before booting."
- **The system** does NOT add a new external consensus dependency (no etcd, no DynamoDB lock).

### 2.8 PR safety
- **When** an agent opens a PR, **the system** records the URL on the item via the `Symphony PR` link column (Spec 1 behavior preserved).
- **The system** enforces a branch naming convention via the prompt template: `symphony/SYM-<id>/<profile>/attempt-<n>`. Symphony validates the branch name on the PR URL it detects; rejects with `{:error, {:bad_pr_branch, expected_pattern}}` if the agent opened a PR from a different branch.
- **The system** never force-pushes. The orchestrator does not run `git push`; the agent does. If the agent pushes, the agent is responsible for non-force operation. Symphony validates after-the-fact via `gh api` and posts a Monday alert if a force-push was detected.
- **When** a retry attempt finds an open PR for the same `SYM-<id>` (same item, prior attempt left a PR hanging), **the system** does NOT open a duplicate. Behavior: post a Monday Workpad warning and move the item to `Human Review` (operator merges or closes the prior PR before Symphony retries).

### 2.9 Live e2e test harness
- **The system** ships a `mix symphony.e2e_smoke` task that:
  1. Creates a single test item on a dedicated Monday test board (board ID configured via `agent.e2e.test_board_id`)
  2. Sets `Symphony Repo: symphony-test-repo`, `Symphony Profile: claude_opus`, `Symphony Status: Symphony Ready`
  3. Waits up to N seconds (default 600) for Symphony to dispatch + clone + run after_create + spawn agent
  4. Asserts the agent posted at least one stream-json event back
  5. Tears down: deletes the test item, removes the workspace
- **The system** runs this task nightly via GitHub Actions on a separate workflow file (`.github/workflows/e2e-smoke.yml`) that uses ephemeral AWS Secrets Manager credentials.
- **The system** posts a Slack alert if the e2e smoke fails (operator-configurable webhook in WORKFLOW.md `agent.e2e.alert_webhook`).
- **The system** does NOT use the production Tech Board for e2e tests — separate board minimizes cross-contamination.

---

## 3. Explicit Non-Behaviors

- The system MUST NOT cross-normalize tokens between runtimes (preserves Spec 2 DL-007).
- The system MUST NOT emit external telemetry (no Prometheus/CloudWatch/Slack-status) in v1 — all observability is local.
- The system MUST NOT auto-rotate secrets from AWS Secrets Manager — operator handles rotation manually.
- The system MUST NOT auto-merge PRs that agents open. Human review remains the gate.
- The system MUST NOT track per-item cost in the WORKFLOW.md schema — caps are profile-level + global. Per-item caps are extension territory.
- The system MUST NOT rely on external consensus (etcd, DynamoDB locks). Heartbeat-on-Monday is the leader-election mechanism.
- The system MUST NOT bind the dashboard to 0.0.0.0. Local-only is non-negotiable for HIPAA.
- The system MUST NOT log secret values, PHI text, or full prompt contents at INFO+ level.
- The system MUST NOT permit `agent.phi_gate: false` to ship to production deployments without an explicit `--i-understand-phi-bypass` boot flag (matches the Spec 1 `--i-understand-that-this-will-be-running-without-the-usual-guardrails` pattern).

---

## 4. Integration Boundaries

### Phoenix LiveView dashboard (new, additive)
- **Stack:** Phoenix 1.8 + LiveView 1.1 (already in mix.lock per Spec 1).
- **Endpoint:** `SymphonyElixirWeb.Endpoint` exists in `lib/symphony_elixir_web/` (per the existing http_server / endpoint per Spec 1 boot). New LiveView at `lib/symphony_elixir_web/live/dashboard_live.ex`.
- **PubSub:** topic `"orchestrator:dashboard"` already broadcast from `Orchestrator.notify_dashboard/0`; LiveView subscribes.
- **Auth:** none in v1 — local-only binding is the security boundary. Future spec adds session auth if exposed off-host.

### AWS Secrets Manager (existing path, new uses)
- **Wrapper:** `secret_exec.py` already vetted (used for `MONDAY_API_TOKEN`).
- **New uses:** per-repo secrets resolved at workspace creation time via the same wrapper.
- **Failure mode:** wrapper exits non-zero on missing secret → `{:secret_resolution_failed, repo_key, secret_ref, reason}` flows back through workspace error path.

### GitHub (existing, new validation)
- **PR detection:** existing PR-URL detector in `Monday.Adapter` (Spec 1).
- **New validation:** orchestrator posts `gh api` query for the detected PR's branch + force-push history; emits warnings if anomalies detected. No write actions from Symphony to GitHub.

### Slack (new, optional)
- **e2e smoke alert webhook only.** Configured via `agent.e2e.alert_webhook` (URL only — operator owns rotation). Used only by the e2e workflow on failure. Not used in production agent flows.

---

## 5. Behavioral Scenarios (eval-only)

### S1 — Cost cap hard stop
Setup: 5 items dispatched against `claude_opus`, profile per-day cap = $10. The 4th item is mid-session and just crossed $9.50 native token cost.
Action: 5th item polls and is about to dispatch.
Expected: Symphony refuses dispatch with `{:cost_cap_exceeded, profile_day, "claude_opus", 9.50, 10.00}`; Workpad on the 5th item logs the refusal; LiveView dashboard shows the cap utilization at >95%.

### S2 — PHI gate refuses dispatch
Setup: an item title contains a patient name (PHI).
Action: Symphony fetches the item.
Expected: `PHIDetector.scan` returns a finding; the orchestrator skips dispatch, posts `## Symphony Failures` Workpad with finding_count only (no PHI), moves item to `Cancelled`. No clone, no agent spawn.

### S3 — Per-repo secret injection
Setup: `repos.hubspot-funnel-site.secrets: ["HUBSPOT_TOKEN"]`. Operator created the secret in AWS at `mybcat/hubspot-funnel-site/api-token`.
Action: Symphony dispatches an item with `Symphony Repo: hubspot-funnel-site`.
Expected: Workspace creation invokes `secret_exec.py` for `HUBSPOT_TOKEN`; agent process inherits env with the resolved value; Symphony's logs say `Resolved secret HUBSPOT_TOKEN for repo hubspot-funnel-site` (no value); agent stdout/stderr is scrubbed for the resolved value before reaching disk_log.

### S4 — Two Symphonies, leader election
Setup: two Symphony binaries booted simultaneously against the same board.
Action: both attempt heartbeat write at boot.
Expected: one's `change_simple_column_value(heartbeat_item, status, "Active")` succeeds first; the other receives a stale-state response and enters standby. Standby polls heartbeat every TTL; if leader's heartbeat goes stale, standby promotes.

### S5 — Heartbeat sentinel deleted at boot
Setup: operator deleted the heartbeat sentinel item before booting.
Action: Symphony boots.
Expected: refuse to boot with operator-facing error: "Heartbeat sentinel item <id> not found. Recreate it on board <board_id> before booting." Exit non-zero.

### S6 — Retry-when-PR-already-open
Setup: item attempt 1 left an open PR (agent opened the PR but Symphony's retry fired before merge).
Action: Symphony retries the item.
Expected: orchestrator detects open PR for `SYM-<id>` via `gh pr list`, posts Monday Workpad warning, moves item to `Human Review`. Does NOT open a duplicate PR.

### S7 — Live e2e smoke nightly
Setup: GitHub Actions cron triggers `mix symphony.e2e_smoke` at 03:00 UTC.
Action: smoke task runs.
Expected: creates test item on test board, waits for dispatch + clone + after_create + agent first event (max 600s), asserts dispatch logs contain expected sequence, tears down. On failure: posts Slack alert with the disk log tail.

### S8 — Dashboard PubSub live update
Setup: dashboard open at `localhost:4000/dashboard`; an item starts dispatching.
Action: orchestrator broadcasts on `orchestrator:dashboard`.
Expected: dashboard's Running section gains a new row within 1s without page reload.

### S9 — Cost cap reset
Setup: global daily cap hit, no items dispatching, operator wants to bump cap.
Action: operator updates WORKFLOW.md `agent.cost_caps.global_daily_usd: 100` (was 50) and saves.
Expected: WORKFLOW.md hot-reload picks up the new cap on next tick; previously-blocked items resume dispatching. Dashboard reflects the new cap.

---

## 6. Per-Part Context Layers

### Part A — Cost Guardrails

#### A.1 Module Manifest

| Module | Path | Purpose |
|---|---|---|
| `SymphonyElixir.Cost.Calculator` | `lib/symphony_elixir/cost/calculator.ex` | Computes USD cost from native token counters using `agent.pricing` map |
| `SymphonyElixir.Cost.Caps` | `lib/symphony_elixir/cost/caps.ex` | Per-session, per-profile-day, global-day cap enforcement; persists daily counters via `:persistent_term` reset at UTC midnight |
| `SymphonyElixir.Cost.Reset` | `lib/symphony_elixir/cost/reset.ex` | `iex`-callable manual reset + scheduler for UTC midnight |

#### A.2 Behavioral Contracts
- `Calculator.usd/2 :: tokens_map, profile_kind → float` — never raises; falls back to 0 if pricing missing (and emits warning).
- `Caps.check/2 :: state, profile → :ok | {:error, {:cost_cap_exceeded, scope, current, cap}}` — pure, no side effects.
- `Caps.charge/3 :: state, profile, usd → state` — bumps per-profile + global counters.

#### A.3 Decision Log
##### DL-001: Layered cost guardrails (per-session + per-profile-day + global-day)
**Context:** A single hallucination loop can burn $X overnight. A non-engineer founder needs a hard wall.
**Choice:** Three layers, checked in order. Both AIs agreed but offered different defaults; pick all three so a single misconfig doesn't disable safety.
**Reversal cost:** Low — drop layers individually.
**What breaks if reversed:** Founder financial safety is degraded. Disabled global cap is the riskiest.

### Part B — Per-repo Secret Injection

#### B.1 Module Manifest

| Module | Path | Purpose |
|---|---|---|
| `SymphonyElixir.Secrets.Resolver` | `lib/symphony_elixir/secrets/resolver.ex` | Wraps `secret_exec.py` invocations; returns `{:ok, env_map}` or `{:error, ...}` |
| `SymphonyElixir.Secrets.Scrubber` | `lib/symphony_elixir/secrets/scrubber.ex` | Stream filter that redacts secret values from agent stdout/stderr |

#### B.2 Behavioral Contracts
- `Resolver.resolve/1 :: [SECRET_REF] → {:ok, %{ENV_NAME → value}} | {:error, ...}`. Process-isolated invocation; resolved values never returned in error paths.
- `Scrubber.wrap/2 :: stream, secret_values → filtered_stream`. Replaces literal occurrences of secret values with `[REDACTED]` before they hit downstream consumers.

#### B.3 Decision Log
##### DL-003: Per-repo secret injection via WORKFLOW.md `secrets:` list
**Context:** Some repos (hubspot-daily, billing) need API credentials. Hardcoding in WORKFLOW.md is a security violation; injecting via prompt template leaks into logs.
**Choice:** Symbolic refs in WORKFLOW.md (e.g., `["HUBSPOT_TOKEN"]`) resolved to actual values at workspace creation via existing `secret_exec.py` wrapper. Values land in agent process env, never in logs or prompts.
**Reversal cost:** Low.
**What breaks if reversed:** Secrets leak via WORKFLOW.md or prompt template; HIPAA exposure.

### Part C — Dashboard

#### C.1 Module Manifest

| Module | Path | Purpose |
|---|---|---|
| `SymphonyElixirWeb.DashboardLive` | `lib/symphony_elixir_web/live/dashboard_live.ex` | LiveView mounting at `/dashboard`; subscribes to `orchestrator:dashboard` |
| `SymphonyElixirWeb.DashboardComponents` | `lib/symphony_elixir_web/components/dashboard_components.ex` | Functional components for Queue, Running, Backoff, Spend, Failures sections |

#### C.2 Behavioral Contracts
- LiveView render is referentially transparent over `Orchestrator.snapshot/0` + `Cost.snapshot/0`.
- Update latency: < 1s from `notify_dashboard` to LiveView re-render.
- Binding: `127.0.0.1` only, configurable port (default 4000).

#### C.3 Decision Log
##### DL-002: Phoenix LiveView dashboard at localhost:4000
**Context:** Operator needs visibility beyond TUI without a separate web app.
**Choice:** LiveView (Phoenix already in deps; PubSub already broadcasting). Local-only bind.
**Alternatives rejected:** Slack integration (latency + Slack admin overhead for non-engineer founder); Monday widget (Monday platform limitations); separate web app (deployment burden).
**Reversal cost:** Low — drop the LiveView, TUI remains.
**What breaks if reversed:** Operator visibility is degraded.

### Part D — Heartbeat Resilience

#### D.1 Module Manifest
| Module | Path | Purpose |
|---|---|---|
| `SymphonyElixir.Leadership` | `lib/symphony_elixir/leadership.ex` | Standby-mode polling + leader promotion logic |

#### D.2 Behavioral Contracts
- `Leadership.attempt_lock/1` returns `:leader | :standby | {:error, ...}`.
- Standby polling interval = `heartbeat_ttl_ms`.
- Promotion is atomic via Monday status mutation; runner-up sees stale read on next tick.

#### D.3 Decision Log
##### DL-005: Monday-based leader election (no external consensus)
**Choice:** Use Monday status column of the heartbeat sentinel item as the lock.
**Reasons:** No new external dependency; Monday is already authoritative for Symphony's state; operator can intervene by manually flipping the sentinel's status.
**Reversal cost:** Medium — switching to etcd later means re-architecting heartbeat semantics.

### Part E — PR Safety

#### E.1 Module Manifest
| Module | Path | Purpose |
|---|---|---|
| `SymphonyElixir.PRSafety.BranchPolicy` | `lib/symphony_elixir/pr_safety/branch_policy.ex` | Validates PR URL against expected branch pattern; flags force-pushes via `gh api` |
| `SymphonyElixir.PRSafety.RetryGate` | `lib/symphony_elixir/pr_safety/retry_gate.ex` | Pre-dispatch: queries open PRs for SYM-id; refuses retry if duplicate would be created |

#### E.3 Decision Log
##### DL-006: Branch convention `symphony/SYM-<id>/<profile>/attempt-<n>` + retry-gate
**Choice:** Lock branch naming via prompt template; validate via PR-URL matcher; gate retries on existing-open-PR query.
**Reasons:** Prevents agents from accidentally pushing to `main` or another branch; prevents duplicate PRs from retries.
**Reversal cost:** Low.

---

## 7. SPEC.md Concrete Diff Plan (Spec 4 scope only)

### Sections to amend
- §3.1 Main Components: add `Cost Guardrails`, `Secrets Injector`, `Dashboard (LiveView)`, `Leadership`, `PR Safety`.
- §6 Workflow Configuration: add `agent.cost_caps`, `agent.pricing`, `agent.dashboard`, `agent.phi_gate`, `agent.e2e`, `repos.<key>.secrets`.
- §11 Workspace Lifecycle: add per-repo secret resolution step before agent spawn.

### New sections
- §6.X Cost cap configuration
- §6.X Per-repo secrets configuration
- §6.X Dashboard configuration
- §11.X Heartbeat leader election

### Removed sections / fields
- None.

---

## 8. Reference Implementation Deltas

Detailed file paths + insertion anchors are deferred to per-step PRs. Sequencing per §12 below.

---

## 9. Tech Board Setup Delta (Spec 4)

Operator-side: none. All Spec 4 features are configured via WORKFLOW.md edits + AWS Secrets Manager entries. No Monday columns added; the existing PHI gate already exists (Spec 1) and just gets stricter behavior.

---

## 10. Out of Scope

- Cloud deployment (separate spec)
- Multi-board support (Spec 5)
- Editing WORKFLOW.md via UI
- External telemetry (Prometheus, CloudWatch)
- Auto-merge of agent PRs
- Auto-rotation of AWS secrets
- Per-item cost caps
- External consensus dependencies (etcd, DynamoDB)

---

## 11. Ambiguity Warnings (locked at recommended defaults)

| ID | Decision | Rationale |
|---|---|---|
| AW-1 (locked) | Cost cap defaults: per-session $5, per-profile-day $20, global-day $50. Operator overrides in WORKFLOW.md. | Conservative starting points for a non-engineer founder; can raise as confidence grows. |
| AW-2 (locked) | PHI gate failures move item to `Cancelled` (not `Human Review`) so PHI doesn't sit in active states. | Minimizes PHI exposure window. |
| AW-3 (locked) | Dashboard auth: none in v1 (local-only bind is the security boundary). | Adding auth before exposing off-host is overkill. |
| AW-4 (locked) | Two-Symphony scenario: standby polls every `heartbeat_ttl_ms` (60s default). | Matches existing heartbeat cadence; no new tuning surface. |
| AW-5 (locked) | E2e smoke uses a separate Monday board ID configured via `agent.e2e.test_board_id`. Default behavior: skip if unset. | Avoids cross-contamination with production Tech Board. |
| AW-6 (locked) | Pricing data lives in WORKFLOW.md `agent.pricing` map (operator-maintained). | Decouples Symphony from vendor pricing API churn. |
| AW-7 (locked) | Force-push detection is post-hoc only — Symphony alerts but doesn't block. | Symphony doesn't run `git push` itself; cannot prevent agent push. |

---

## 12. Implementation Sequencing

| Step | Scope | PR title prefix | Estimated session |
|---|---|---|---|
| 1 | Adapter flag fix (already in `fix/claude-adapter-cli-flags`) | `fix(elixir):` | DONE |
| 2 | Cost guardrails (Cost.Calculator + Cost.Caps + WORKFLOW.md schema) | `feat(elixir): Spec 4 step 2 — cost guardrails` | 1 |
| 3 | Failure observability + Monday writeback | `feat(elixir): Spec 4 step 3 — Monday writebacks` | 1 |
| 4 | Per-repo secret injection (Resolver + Scrubber + Workspace integration) | `feat(elixir): Spec 4 step 4 — per-repo secrets` | 1 |
| 5 | PHI gate hardening (refuse-default + override flag) | `feat(elixir): Spec 4 step 5 — PHI gate hardening` | 0.5 |
| 6 | Phoenix LiveView dashboard | `feat(elixir): Spec 4 step 6 — LiveView dashboard` | 1.5 |
| 7 | Heartbeat resilience (Leadership module + standby loop) | `feat(elixir): Spec 4 step 7 — heartbeat resilience` | 1 |
| 8 | PR safety (BranchPolicy + RetryGate) | `feat(elixir): Spec 4 step 8 — PR safety` | 1 |
| 9 | Live e2e smoke harness | `feat(elixir): Spec 4 step 9 — e2e smoke harness` | 0.5 |

Total: ~8 sessions of focused work, sequenced per the dependency graph (cost + observability before secrets; secrets before dashboard reveals env-resolution status; dashboard depends on Cost.snapshot).

---

## 13. Test Plan Summary

| Layer | Cases | File |
|---|---|---|
| Cost.Calculator | usd/2 against synthetic token maps; missing pricing → 0 + warning | `cost/calculator_test.exs` |
| Cost.Caps | per-session refuse; per-profile-day refuse; global-day refuse; UTC midnight reset | `cost/caps_test.exs` |
| Secrets.Resolver | wrapper success; wrapper failure → propagated error; multiple-ref resolution | `secrets/resolver_test.exs` |
| Secrets.Scrubber | replaces literal occurrences; preserves stream order; handles binary chunks | `secrets/scrubber_test.exs` |
| PRSafety.BranchPolicy | accept symphony/SYM-x/profile/attempt-1; reject other patterns; force-push detected | `pr_safety/branch_policy_test.exs` |
| PRSafety.RetryGate | retry refused if open PR exists; retry permitted if no open PR | `pr_safety/retry_gate_test.exs` |
| Leadership | leader/standby split; promotion on stale heartbeat; refuse-boot on missing sentinel | `leadership_test.exs` |
| DashboardLive | renders queue, running, backoff, spend, failures; PubSub triggers re-render; binds 127.0.0.1 | `symphony_elixir_web/live/dashboard_live_test.exs` |
| E2e smoke (live) | `mix symphony.e2e_smoke` against test board returns 0; failure modes covered | `mix/tasks/symphony.e2e_smoke_test.exs` |

Targeted runs per step. Full suite must remain at the post-Spec-3 baseline (359/45/2) plus new tests added by each step.

---

## 14. Multi-AI Synthesis (agent-team output, captured for archaeology)

**Brainstorm conducted:** 2026-05-04 via `/agent-team` skill. Codex skipped (`/codex:review` is git-context-only, not suited for forward-looking design). Gemini 2.5 Pro + Claude Explore subagent each produced an independent ranked list of remaining work.

**Areas of agreement (high-confidence inclusions in this spec):**
- Adapter flag injection (§2.1) — both AIs flagged as #1 blocker; matches my pre-spec analysis.
- Cost guardrails (§2.2) — both flagged as critical; both proposed token caps.
- Per-repo secret injection (§2.4) — both flagged as security-critical.
- Heartbeat resilience (§2.7) — both flagged the two-Symphony race + Monday outage modes.
- PR safety (§2.8) — both flagged retry-when-PR-already-open.
- Operator docs / runbook — both flagged operator visibility gap.

**Areas of disagreement (resolved in this spec):**

1. **Cost guardrail granularity.** Claude proposed per-item + per-profile + global; Gemini advocated a global daily kill switch as the founder-friendly default. **Resolution:** Layered (DL-001) — global kill switch IS the founder-friendly default but per-profile + per-session add defense in depth without operator burden. WORKFLOW.md schema accommodates all three; only global is required.

2. **Dashboard form factor.** Claude proposed TUI + JSON endpoint; Gemini advocated Phoenix LiveView at local port. **Resolution:** Phoenix LiveView (DL-002). Phoenix is already in deps from Spec 1; the JSON endpoint isn't operator-friendly; Slack integration adds admin overhead. Local-only bind is the HIPAA boundary.

3. **Secret injection backend.** Claude proposed Vault; Gemini proposed profile-based env injection (no specific backend). **Resolution:** AWS Secrets Manager via existing `secret_exec.py` wrapper (DL-003). Vault is overkill for current MyBCAT scale; the existing wrapper already passes audit.

4. **Adapter contract shape.** Claude proposed a helper function `build_claude_command/1`; Gemini proposed a full `Profile`-struct → arglist mapping. **Resolution:** Helper function (`build_full_command/2` in `fix/claude-adapter-cli-flags`). Full struct mapping is overkill for the three flags currently needed; helper composes for future flags trivially.

**Blind spots Gemini surfaced that Claude missed:**
- Item rotation/stalling → infinite retry loop (Gemini #10). Locked as DL-007 (max retry = 3 → Cancelled).
- HIPAA gate as a mandatory refuse-default (Gemini #5). Locked as DL-004 + §2.5.

**Blind spots Claude surfaced that Gemini missed:**
- Codex/Gemini adapter verification (Claude #2) — already covered by §2.1's "verification gaps" note.
- Live e2e test harness as automated nightly (Claude #10). Locked as DL-008 + §2.9.

The spec adopts the union with conflicts resolved per the locks above.

---
