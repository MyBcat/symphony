# Symphony — Project Resume

> **Pick-up command:** "read RESUME.md"
>
> Durable handoff. Last refreshed: **2026-05-06 evening session** (replaces the
> 2026-05-03 snapshot, which captured only PRs #1–#3).
>
> The auto-generated `resume.md` and `elixir/resume.md` (lowercase) are Stop-hook
> snapshots — ignore those, they regenerate on idle.

---

## Where things stand (the star)

**Repo:** `/mnt/d_drive/repos/symphony` (fork of `openai/symphony`)
**Origin remote:** `https://github.com/MyBcat/symphony.git` (Ankit's fork)
**Upstream remote:** `https://github.com/openai/symphony.git`
**Current branch:** `main` (clean, in sync with origin)
**Top of main:** `10f05d2 Merge: M-0c-D Symphony codex shipping finalizer (#32)`

**Live state right now:** Symphony **is running** locally — booted 2026-05-06 18:09, BEAM PID `2010832`, dashboard responding HTTP 200 at `http://127.0.0.1:4000/`. Boot wrapper: `/mnt/d_drive/repos/finances/scripts/secret_exec.py` (note: moved from `/podcast/scripts/...` since the old resume).

**Where v1.0 framing went:** Symphony is past "needs first smoke test." It has been actively dispatching real Codex/Claude sessions against MyBCAT repos for ~3 days, shipping its own M-series production-readiness PRs end-to-end through itself (e.g., M-9 SYM-11923096576, M-4a SYM-11942134820, M-0a SYM-11941611091). It has been hardened against real failure modes seen in those runs.

**Tally:** 32 PRs merged. Specs 1 → 7 written + delivered. M-0 through M-9 production-readiness milestones merged.

---

## What's been done

### Architecture timeline (all merged)

| Spec | Subject | Top PRs | What it added |
|---|---|---|---|
| **Spec 1** | Monday tracker swap | #1 | Linear adapter deleted; replaced with `SymphonyElixir.Monday.{Adapter, Client, Item, PHIDetector, PRDetector, Workpad}`. Tracker primitive owns all Monday writes. |
| **Spec 2** | Multi-runtime + profiles | #2, #3 | `AgentRuntime` behaviour + `Codex.Adapter` / `Claude.Adapter` / `Gemini.Adapter`. `Profile` struct + `ProfileResolver` (per-issue → default → error, safety floor, drift detection). `AgentRunner` polymorphic dispatch. |
| **Spec 3** | Multi-repo dispatch | #5, #6, #7 | Per-issue `Symphony Repo` Monday column (`dropdown_mm322hqn`). `repos:` map in WORKFLOW.md keys repo dispatch entries. Symphony performs the clone itself; `after_create` is post-clone setup only. Empty column → legacy `hooks.after_create` default. |
| **Spec 4** | Production readiness scope | #10 | Umbrella spec that fanned out into M-1 → M-9. |
| **Spec 4 §2.8a** | Auto-Codex-review + auto-merge | #24 | Symphony runs `/codex:rescue`-equivalent on each agent PR; conditionally auto-merges when (a) `auto_merge_on_codex_pass: true`, (b) Codex output matches pass pattern, (c) diff < `auto_merge_max_lines`, (d) base is main/master, (e) item not flipped during review. Symphony-repo auto-merge hard-coded OFF. |
| **Spec M-9** | Nightly e2e harness | #25 | `Symphony.E2eNightly` mix task + `nightly-e2e.yml` GitHub workflow. Hits a separate sandbox board. |
| **Spec — Codex finalizer** | Symphony-side codex shipping finalizer | #32 | When Codex marks an issue terminal, Symphony writes a `## Symphony Run Summary` workpad section. Skips if issue was already terminal at finalizer entry. |

Plus the M-series operational hardening:

| Milestone | PR | Subject |
|---|---|---|
| M-0 | #15 | Codex adapter `app-server` `response_timeout` fix |
| M-0a | #28 | Codex adapter rewrite for Codex CLI 0.128 `exec --json` (one-shot per turn, JSONL stream) |
| M-0b | #30 | Tighten Codex agent prompt + pre-create work branch; identifier sanitization + `gh repo view` |
| M-0c-D | #32 | Symphony-side codex shipping finalizer — reserves `## Symphony Run Summary` prefix on Workpad |
| M-1 | #13 | Portability — `Dockerfile`, `docker-compose.yml`, `setup.sh`, `BOOTSTRAP.md` |
| M-2 | #26 | Phoenix LiveView dashboard at `localhost:4000`. `/agents`, `/failures`, `/repos`. Loopback-only allowlist + PHI scrub + port range guard |
| M-3 | #18 | Cost cap kill switch — `cost_cap.daily_usd` (this repo currently runs `daily_usd: 1000`) |
| M-4 | #16 | Failure observability — Monday Workpad writeback on errors |
| M-4a | #29 | Consolidate failure updates; enforce retry cap (`tracker.failure_ttl_count: 5`); `## Symphony Failures` workpad history |
| M-4b | #31 | Drop per-crash workpad write — orchestrator owns the single summary |
| M-5 | #21 | Per-repo AWS Secrets Manager bootstrap (`SymphonyElixir.Secrets`) |
| M-6 | #22 | PHI gate hardening — `phi_gate.mode: strict` default; boot-time scan refuses to start if active/handoff items have PHI findings |
| M-7 | #23 | Heartbeat resilience — token lock + outage tolerance (`tracker.outage_threshold: 5`) |
| M-8 | #17 | PR safety — auto-transition + branch policy + force-push detection |
| M-8a | #24 | Auto-Codex-review + conditional auto-merge (Spec 4 §2.8a) |
| M-9 | #25 | Nightly e2e test harness |

### Tech Board configuration (Monday board `8173460438`)

| Field | Monday ID |
|---|---|
| `Symphony Status` column | `color_mm30c3vb` |
| `Symphony PR` link column | `link_mm30ak49` |
| `Symphony Profile` dropdown column | `dropdown_mm30zep` |
| `Symphony Repo` dropdown column **(new — Spec 3)** | `dropdown_mm322hqn` |
| `Priority` column | `status_1_mkm9bt8j` |
| `Labels` column | `dropdown_mkwbsh98` |
| Heartbeat sentinel item | `11909898073` |

Symphony Status labels: `Symphony Ready`, `In Progress`, `Human Review`, `Merging`, `Rework`, `Done`, `Cancelled`. Active states = first 3 + `Rework`; handoff = `Human Review` + `Merging`; terminal = `Done` + `Cancelled`.

Symphony Profile dropdown values: `claude_opus`, `claude_sonnet`, `codex_gpt55_xhigh`, `gemini_long_context`. Default profile: **`codex_gpt55_xhigh`**.

### Repos currently registered in WORKFLOW.md (15)

`call-analysis`, `carlos_low_vision`, `client-portal`, `cvc-new-site`, `eyecloud-ai`, `finance_seat`, `hal`, `hubspot-cleaner`, `hubspot-funnel-site`, `insurance-auto`, `mso`, `patient_cordinator`, `pivot`, `sales-agent`, `symphony`. The `symphony` entry has auto-merge hard-coded OFF per Spec 4 §2.8a constraint #5.

### Module footprint (`elixir/lib/symphony_elixir/`)

`agent_runner`, `agent_runtime`, `auto_merge/`, `claude/`, `codex/`, `codex_review/`, `config/`, `cost_meter`, `e2e/`, `finalizer/`, `gemini/`, `heartbeat`, `http_server`, `log_file`, `monday/`, `orchestrator`, `path_safety`, `pr_safety/`, `profile`, `profile_resolver`, `prompt_builder`, `secrets/`, `specs_check`, `ssh`, `status_dashboard`, `tracker/`, `workflow`, `workflow_store`, `workspace`. Web layer: `symphony_elixir_web/` (Phoenix LiveView dashboard).

### Secrets

- **Monday API token:** `mybcat/integrations/api-keys/monday` (JSON, field `api_token`).
- **Per-repo secrets bootstrap (M-5):** `SymphonyElixir.Secrets` resolves repo-specific secrets at workspace bootstrap.
- **Boot wrapper (current path):** `/mnt/d_drive/repos/finances/scripts/secret_exec.py` (was `/podcast/...` in the old resume).

### Specs + plans (all checked into `docs/`)

```
docs/superpowers/specs/2026-05-03-symphony-monday-multi-runtime-design.md       (superseded; design-intent reference)
docs/superpowers/specs/2026-05-03-symphony-monday-tracker-swap.md               (Spec 1)
docs/superpowers/specs/2026-05-03-symphony-multi-runtime-profiles.md            (Spec 2)
docs/superpowers/specs/2026-05-04-symphony-multi-repo-dispatch.md               (Spec 3)
docs/superpowers/specs/2026-05-04-symphony-production-readiness.md              (Spec 4 umbrella)
docs/superpowers/specs/2026-05-05-symphony-auto-codex-review-and-auto-merge.md  (Spec 4 §2.8a / M-8a)
docs/superpowers/specs/2026-05-06-symphony-codex-finalizer.md                   (M-0c-D)
docs/superpowers/plans/2026-05-03-symphony-monday-tracker-swap.md
docs/superpowers/plans/2026-05-03-symphony-multi-runtime-profiles.md
docs/superpowers/plans/2026-05-05-symphony-m2-web-dashboard.md
docs/superpowers/plans/2026-05-05-symphony-nightly-e2e-harness.md
```

---

## What's next

### Active backlog (no spec yet — ask before starting)

- [ ] **E2E sandbox board** — `e2e:` block in WORKFLOW.md is documented but commented out. M-9 nightly harness needs `SYMPHONY_E2E_BOARD_ID` + `SYMPHONY_E2E_MONDAY_TOKEN` set as GitHub secrets and a sandbox board ID populated before the nightly workflow will run.
- [ ] **Per-repo auto-merge enablement audit** — every repo currently defaults `auto_merge_on_codex_pass: false`. Walk through each repo and decide which ones the operator trusts to auto-merge vs. which stay manual. HIPAA-touching repos stay opt-out unless verified PHI-safe; symphony itself is hard-coded off.
- [ ] **Claude/Gemini live smoke** — Codex profile is field-tested via Symphony's own M-series shipping. Claude + Gemini adapters are tested at the unit level but haven't been observed dispatching real items end-to-end. One Tech Board item per profile would close the matrix.

### Recommended hardening backlog (not blocking)

- [ ] **CI on project-pinned OTP 28** — original Spec 1/2 work was done on a hand-installed OTP 26 prefix. The CI containers pin OTP 28 via `mise.toml`; lots of `mix format` corrections in #26 came from the OTP 28 / Elixir 1.19.5 jump. Still worth one explicit "all suites green on stock CI image" pass before any prod-style rollout.
- [ ] **Dedicated Monday service user** (Spec 1 DL-007 hardening) — currently sharing `mybcat/integrations/api-keys/monday` token. Cut over to `symphony/monday/api-token` with a dedicated `symphony@mybcat.com` Monday user scoped to Tech Board.
- [ ] **`stalled` timeout tuning** for Claude/Gemini long-silent agent turns.
- [ ] **Drop legacy `codex_default` safety floor bypass** — synthesized when no profiles configured. Now that multi-profile is the live shape, the bypass is dead code.

### Future extension territory (out of scope, mentioned in specs)

- Rule-based routing (`agent.routing_rules`: e.g., `priority=High → claude_opus`)
- Cross-runtime token cost normalization (currently runtime-native pass-through)
- Multi-board polling
- Multi-tracker support (Linear stays gone in this spec line)
- Tier 2 DynamoDB telemetry

---

## Key decisions & their rationale (load-bearing)

Full decision logs live in the spec files. The decisions most likely to come up:

- **DL-005 Spec 1 — Tracker primitive owns Monday writes.** Symphony writes status, workpad, PR URL based on observing the agent's event stream. Agents have no Monday access. Inverts the original Symphony model. Reversing reintroduces races on `In Progress → Human Review`.
- **DL-006 Spec 1 — `handoff_states` separate from `active_states`.** Without this, the orchestrator loops on items waiting for human review.
- **DL-008 Spec 1 — Single-instance heartbeat lock** with TTL conflict detection. Heartbeat sentinel item `11909898073` carries the lock. Two Symphony instances on the same board would otherwise silently double-dispatch.
- **DL-011 Spec 1 — Tech Board contains no PHI.** Engineering items only; PHI patterns rejected at ingestion via `Monday.PHIDetector`. M-6 hardened this further: strict default + boot-time scan.
- **DL-007 Spec 2 — Token accounting native pass-through.** `agent_native_tokens.<kind>.<field>` shape. Codex/Claude/Gemini fields are not comparable; do not normalize.
- **DL-008 Spec 2 — Profile re-resolves at every retry boundary.** Operators can flip the dropdown mid-flight to escalate; next retry picks up the new profile. Mid-session swap is forbidden (DL-003).
- **Spec 3 — Symphony performs the clone itself; `after_create` is post-clone setup only.** No `git clone` allowed in `after_create`. Empty Repo column on an item falls back to legacy `hooks.after_create`.
- **Spec 4 §2.8a constraint #5 — Symphony repo MUST stay opt-out for auto-merge.** Cross-repo blast radius is too high for unattended merges. Operator merges manually after `/codex:rescue` (see `.claude/CLAUDE.md`).
- **M-4a — One consolidated `## Symphony Failures` Update at retry cap.** Once `failure_ttl_count` (default 5) is hit, the orchestrator transitions the item to Cancelled and posts a single Update with all attempt history — instead of one Update per attempt. M-4b removed the per-crash workpad write so the orchestrator owns the single summary.
- **M-7 — Heartbeat outage tolerance.** Orchestrator keeps running through tracker 5xx/timeout outages; `outage_threshold: 5` controls only the operator-facing alert.
- **Codex finalizer (M-0c-D) — Skip if already terminal at entry.** Prevents Symphony from clobbering an existing terminal-state summary if the issue was already closed when Codex returned.

---

## Pick-up cheat sheet

**Inspect Tech Board live state:**

```bash
gh api repos/MyBcat/symphony/pulls --jq '.[] | {number, title, state, mergeStateStatus}' | head -20
```

**Check whether Symphony is currently running:**

```bash
ps -ef | grep -E '(bin/symphony|beam.smp)' | grep -v grep
```

**Check the dashboard:**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4000/
```

**Boot Symphony for a smoke test (local dev path):**

```bash
cd /mnt/d_drive/repos/symphony/elixir && /mnt/d_drive/repos/finances/scripts/secret_exec.py --secret-env MONDAY_API_TOKEN=mybcat/integrations/api-keys/monday:api_token -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

**Boot via docker-compose (M-1 portability path):**

```bash
cd /mnt/d_drive/repos/symphony && docker compose up
```

**Run targeted Spec 2 tests:**

```bash
cd /mnt/d_drive/repos/symphony/elixir && mix test test/symphony_elixir/profile_test.exs test/symphony_elixir/profile_resolver_test.exs test/symphony_elixir/agent_runtime_test.exs test/symphony_elixir/codex/ test/symphony_elixir/claude/ test/symphony_elixir/gemini/ test/symphony_elixir/monday/ test/symphony_elixir/tracker_test.exs test/symphony_elixir/orchestrator_test.exs test/symphony_elixir/agent_runner_test.exs test/symphony_elixir/config_schema_test.exs --no-start
```

**Rebuild the binary after code changes:**

```bash
cd /mnt/d_drive/repos/symphony/elixir && mix build
```

**Read live profile/repo state on a Monday item:** use the `/monday-com` skill with a `column_values` query against `8173460438` filtered by `dropdown_mm30zep` (profile) and `dropdown_mm322hqn` (repo).

**Merge gate (repo-specific rule, see `.claude/CLAUDE.md`):** every PR on this repo merges only after `/codex:rescue` returns clean + targeted tests green. No exceptions for normal work.

---

## What I'd do first when picking back up

1. **Verify Symphony is alive and dashboard renders.** `ps` for `bin/symphony` + `curl http://127.0.0.1:4000/`. If dead, boot via the cheat-sheet command above.
2. **Open the dashboard** at `http://127.0.0.1:4000/` and look at `/agents`, `/failures`, `/repos`. This is the fastest read on what's currently dispatched, what's failing, and which repos are active.
3. **Check the failure queue** in the dashboard or via the `## Symphony Failures` Updates on Tech Board items. M-4a consolidates per-issue failures into one Update once the retry cap (5) is hit, so a Cancelled item with that section is the signal to investigate.
4. **If picking up a specific thread:** read the matching summary file in repo root (`_symphony_summary.md`, `_symphony_plan.md`) — these are written by Symphony as it works and capture in-flight context.
5. **Before any merge to main on this repo:** `/codex:rescue` first per `.claude/CLAUDE.md`. No exception path for normal work.
