# Symphony — Project Resume

> **Pick-up command:** "read RESUME.md"
>
> This file is the durable handoff. Last updated: **2026-05-03 evening session**.
> The auto-generated `resume.md` and `elixir/resume.md` (lowercase) are Stop-hook
> snapshots — ignore those, they get regenerated on idle.

---

## Where things stand (the star)

**Repo:** `/mnt/d_drive/repos/symphony` (fork of `openai/symphony`)
**Origin remote:** `https://github.com/MyBcat/symphony.git` (Ankit's fork)
**Upstream remote:** `https://github.com/openai/symphony.git` (OpenAI's repo)
**Current branch:** `main` (clean, in sync with origin)
**Latest merge:** `3f9f04b Merge: AgentRunner polymorphic dispatch (#3)`

**3 PRs shipped today:**
| PR | Subject | Merge SHA |
|---|---|---|
| #1 | Spec 1 — Monday.com tracker swap | `498395f` |
| #2 | Spec 2 — Multi-runtime + profiles | `58b7b7d` |
| #3 | AgentRunner polymorphic dispatch (Spec 2 follow-up) | `3f9f04b` |

**End state:** Symphony orchestrator is retargeted from Linear → Monday.com, supports Codex + Claude Code + Gemini CLI as first-class agent runtimes via named "profiles," and routes per-issue based on a Monday `Symphony Profile` dropdown column.

---

## What's been done

### Architecture (all merged)

1. **Tracker swap (Spec 1):** Linear adapter deleted; replaced with `SymphonyElixir.Monday.{Adapter, Client, Item, PHIDetector, PRDetector, Workpad}`. Symphony (Tracker primitive) owns all Monday writes per captured architecture decision (OB_mybcat 2026-05-03 "Tracker primitive owns Monday writes").
2. **Multi-runtime (Spec 2):** New `AgentRuntime` behaviour with three adapters (`Codex.Adapter`, `Claude.Adapter`, `Gemini.Adapter`). `Profile` struct with secret-redacting Inspect. `ProfileResolver` with precedence (per-issue → default → error) + safety floor + drift detection.
3. **Polymorphic dispatch (PR #3):** `AgentRunner.run/3` resolves profile + selects adapter via `adapter_for_kind/1` + drives session through AgentRuntime callbacks. Profile routing is **live at runtime**.

### Tech Board configuration (Monday board `8173460438`)

| Field | Monday ID |
|---|---|
| `Symphony Status` column | `color_mm30c3vb` |
| `Symphony PR` link column | `link_mm30ak49` |
| `Symphony Profile` dropdown column | `dropdown_mm30zep` |
| Heartbeat sentinel item | `11909898073` |

Symphony Status labels: `Symphony Ready`, `In Progress`, `Human Review`, `Merging`, `Rework`, `Done` (`is_done: true`), `Cancelled`.
Symphony Profile dropdown values: `claude_opus`, `claude_sonnet`, `codex_gpt55_xhigh`, `gemini_long_context`.

### Secrets

- **Monday API token:** AWS Secrets Manager — `mybcat/integrations/api-keys/monday` (JSON, field `api_token`). Reused from existing MyBCAT integration token (per Spec 1 DL-007 amendment); dedicated service user is Phase 2 hardening.
- **Wiring:** `elixir/.envrc.example` references `secret-get mybcat/integrations/api-keys/monday`. Live-boot uses `secret_exec.py --secret-env MONDAY_API_TOKEN=mybcat/integrations/api-keys/monday:api_token --` per CLAUDE.md secret rules.

### Toolchain

- Elixir 1.19.5 / OTP 26 prebuilt at `/tmp/elixir-extract/bin` + `/tmp/erlang-prefix/erlang/bin` (subagents installed manually because the host couldn't compile OTP 28 from source — project pins OTP 28 in `mise.toml`).
- All targeted tests run with `--no-start` because `TestSupport.stop_default_http_server/0` requires the application supervisor (pre-existing infrastructure quirk).

### Test status (last verified)

- **146/146 targeted Spec 2 + dispatch tests passing** under `--no-start` against the polymorphic dispatch branch
- `mix compile --warnings-as-errors` clean
- Live boot validated 4 times across the day — heartbeat acquire/release, polling, dashboard rendering, no errors

### Specs + plans (all checked into `docs/`)

```
docs/superpowers/specs/2026-05-03-symphony-monday-multi-runtime-design.md       (superseded; design-intent reference)
docs/superpowers/specs/2026-05-03-symphony-monday-tracker-swap.md               (Spec 1, shipped)
docs/superpowers/specs/2026-05-03-symphony-multi-runtime-profiles.md            (Spec 2, shipped)
docs/superpowers/plans/2026-05-03-symphony-monday-tracker-swap.md               (Spec 1 plan, executed)
docs/superpowers/plans/2026-05-03-symphony-multi-runtime-profiles.md            (Spec 2 plan, executed)
```

---

## What's next

### Required to declare Symphony "shipped to production"

- [ ] **Real-agent live smoke test.** Architecture is complete; all unit tests pass; live boot is clean — but no real agent has actually executed end-to-end through Claude or Gemini against a real Tech Board item. **One operator step closes this:**
  1. Authenticate Claude + Gemini CLIs on the host: `claude login` and `gemini auth login` (interactive flows; Ankit-only).
  2. Create one Tech Board item with `Symphony Status: Symphony Ready` and `Symphony Profile: claude_opus`.
  3. Boot Symphony: `cd /mnt/d_drive/repos/symphony/elixir && /mnt/d_drive/repos/podcast/scripts/secret_exec.py --secret-env MONDAY_API_TOKEN=mybcat/integrations/api-keys/monday:api_token -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md`
  4. Verify: `claude` subprocess spawns in `~/code/symphony-workspaces/SYM-<id>/`, agent does engineering work, opens a PR via `gh`, writes `_symphony_summary.md`, Symphony observes the event stream and writes `Symphony Status: Human Review` + workpad summary back to Monday.
  5. Tear down: set Symphony Status to `Cancelled` in Monday UI; Symphony stops the session and cleans up the workspace.

### Recommended hardening backlog (not blocking)

- [ ] **CI on project-pinned OTP 28** — subagents tested on OTP 26 (host limitation). CI should re-validate before any production rollout.
- [ ] **Dedicated Monday service user** (Spec 1 DL-007 hardening): create `symphony@mybcat.com` Monday user, scope token to Tech Board only, rotate from `mybcat/integrations/api-keys/monday` shared secret to a dedicated `symphony/monday/api-token` secret.
- [ ] **`stalled` timeout tuning** for Claude/Gemini long-silent agent turns (currently 60s in `stream_events` adapters). Long agent turns may time out if they go silent for >60s.
- [ ] **Legacy Codex profile safety floor enforcement** — currently the synthesized `codex_default` profile (when no profiles are configured) bypasses strict safety floor to preserve Spec 1 backward compat. Once operators migrate fully to multi-profile shape, drop the bypass.

### Future extension territory (out of scope for v1, documented in specs)

- Rule-based routing (`agent.routing_rules` map: e.g., `priority=High → claude_opus`)
- Cross-runtime token cost normalization (currently runtime-native pass-through per Spec 2 DL-007)
- Multi-board polling
- Multi-tracker support (Linear stays gone in this spec line)
- Tier 2 DynamoDB telemetry layer (per captured agent factory architecture; deferred from Spec 1)

---

## Key decisions & their rationale (load-bearing)

Full decision logs are in the spec files. The decisions most likely to come up:

- **DL-005 Spec 1: Tracker primitive owns Monday writes.** Symphony writes status, workpad, PR URL based on observing the agent's event stream. Agent has no Monday access. Inverts the existing Symphony model (which had agent writing via `linear_graphql` injected tool); driven by captured MyBCAT agent factory architecture. If reversed, race conditions return on `In Progress → Human Review` transitions.
- **DL-006 Spec 1: `handoff_states` separate from `active_states`.** `Human Review` and `Merging` are handoff states — Symphony claims the item but doesn't dispatch new turns. Without this, orchestrator loops forever on items waiting for human review.
- **DL-008 Spec 1: Single-instance heartbeat lock** with TTL conflict detection. Two Symphony instances on the same board would silently double-dispatch otherwise. Heartbeat sentinel item `11909898073` carries the lock.
- **DL-011 Spec 1: Tech Board contains no PHI.** Engineering items only; PHI patterns rejected at ingestion via `Monday.PHIDetector`. Per BAA gating.
- **DL-007 Spec 2: Token accounting native pass-through.** `agent_native_tokens.<kind>.<field>` shape. No cross-runtime normalization (Codex `{input,output,total}`, Claude `{input,output,cache_read,cache_creation,total}`, Gemini `{prompt,candidates,cached,total}` are NOT comparable).
- **DL-008 Spec 2: Profile re-resolves at every retry boundary.** Operators can flip the Symphony Profile dropdown mid-flight to escalate stuck items (e.g., from Sonnet to Opus); next retry picks up the new profile. Mid-session swap is forbidden (DL-003).

---

## Pick-up cheat sheet

**To inspect Tech Board live state:**

```bash
gh api repos/MyBcat/symphony/pulls --jq '.[] | {number, title, state, mergeStateStatus}' | head -20
```

**To boot Symphony for a smoke test:**

```bash
cd /mnt/d_drive/repos/symphony/elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" /mnt/d_drive/repos/podcast/scripts/secret_exec.py --secret-env MONDAY_API_TOKEN=mybcat/integrations/api-keys/monday:api_token -- timeout 30 ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md
```

**To run targeted Spec 2 tests:**

```bash
cd /mnt/d_drive/repos/symphony/elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/profile_test.exs test/symphony_elixir/profile_resolver_test.exs test/symphony_elixir/agent_runtime_test.exs test/symphony_elixir/codex/ test/symphony_elixir/claude/ test/symphony_elixir/gemini/ test/symphony_elixir/monday/ test/symphony_elixir/tracker_test.exs test/symphony_elixir/orchestrator_test.exs test/symphony_elixir/agent_runner_test.exs test/symphony_elixir/config_schema_test.exs --no-start
```

**To rebuild the binary after code changes:**

```bash
cd /mnt/d_drive/repos/symphony/elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix build
```

**To check current Symphony Profile values on Tech Board items:** use the `/monday-com` tool with a `column_values` query against `8173460438` filtered by `dropdown_mm30zep`.

---

## What I'd do first when picking back up

1. **Confirm CLI auth on host.** Run `claude --version && claude --print "hi"` and `gemini --version && gemini --output-format stream-json --prompt "hi"` to verify Claude + Gemini are authenticated. If not, `claude login` / `gemini auth login`.
2. **Create one Tech Board test item** with `Symphony Profile: claude_opus` — this validates the polymorphic routing actually works end-to-end.
3. **Boot Symphony, watch it dispatch.** If it works → Symphony is production-ready and you're at the "scale it" phase. If it fails → tell me the symptom and I'll dispatch a debug subagent.
4. After successful smoke: tag `v1.0` and start using Symphony for real Tech Board items.
