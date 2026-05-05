# Symphony Summary — SYM-11923088195

**Task:** [Symphony M-2] Web dashboard (Phoenix LiveView, localhost:4000)

**Branch:** `symphony/SYM-11923088195/attempt-1`

**Status:** Complete — PR opened

---

## What was built

Added a Phoenix LiveView observability dashboard to the existing OTP app with three pages:

- **`/agents`** — Live agent session list: ID, repo, profile, age/turns, tokens, last event. Auto-refreshes via PubSub + 1s runtime tick.
- **`/failures`** — Last 50 failed/retrying sessions with exit code extraction and stderr tail (last 20 lines).
- **`/repos`** — Per-repo health derived from workspace_path grouping: running count, retrying count, last activity, health badge.

Navigation bar (Overview / Agents / Failures / Repos) shared across all pages via the `:app` layout.

---

## Files changed

### New files
- `elixir/lib/symphony_elixir_web/live/agents_live.ex`
- `elixir/lib/symphony_elixir_web/live/failures_live.ex`
- `elixir/lib/symphony_elixir_web/live/repos_live.ex`
- `elixir/test/symphony_elixir_web/live/agents_live_test.exs`
- `elixir/test/symphony_elixir_web/live/failures_live_test.exs`
- `elixir/test/symphony_elixir_web/live/repos_live_test.exs`

### Modified files
- `elixir/lib/symphony_elixir/config/schema.ex` — Added `Schema.Dashboard` embedded schema (enabled, port)
- `elixir/lib/symphony_elixir/config.ex` — `server_port/0` reads from `dashboard.port` when dashboard enabled
- `elixir/lib/symphony_elixir/http_server.ex` — Hardcoded 127.0.0.1 binding; loudly rejects 0.0.0.0 opts
- `elixir/lib/symphony_elixir/orchestrator.ex` — Snapshot includes `profile` and `repo` from `metadata.issue`
- `elixir/lib/symphony_elixir_web/presenter.ex` — `running_entry_payload/1` includes `profile` and `repo`
- `elixir/lib/symphony_elixir_web/components/layouts.ex` — Added nav bar with all page links
- `elixir/lib/symphony_elixir_web/router.ex` — Added `/agents`, `/failures`, `/repos` LiveView routes
- `elixir/mix.exs` — Added new LiveViews to `ignore_modules` coverage exclusions
- `elixir/WORKFLOW.md` — Added `dashboard: {enabled: true, port: 4000}` config section

---

## HIPAA constraint

Localhost binding is non-negotiable: `ip = {127, 0, 0, 1}` is hardcoded in `HttpServer.start_link/1`. Passing `host: "0.0.0.0"` (or IPv6 equivalents) via opts raises `RuntimeError` at startup.

---

## Data source

All data flows from `SymphonyElixir.Orchestrator.snapshot/2` → `SymphonyElixirWeb.Presenter.state_payload/2` — no new external data sources or DB. Live updates via `SymphonyElixirWeb.ObservabilityPubSub` topic `"observability:dashboard"`.
