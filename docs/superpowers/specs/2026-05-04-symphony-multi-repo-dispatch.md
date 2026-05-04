# Symphony — Multi-Repo Dispatch (Spec 3)

**Status:** Draft for review
**Date:** 2026-05-04
**Authors:** Ankit Patel + Claude (Opus 4.7, 1M context)
**Sequencing:** Spec 3. **Depends on Spec 1** (`2026-05-03-symphony-monday-tracker-swap.md`) and **Spec 2** (`2026-05-03-symphony-multi-runtime-profiles.md`) being shipped first. Both merged as of 2026-05-04. PR #4 (`fix: translate Monday status labels to label IDs`) also merged before this spec begins — it unblocked end-to-end dispatch on the Tech Board.
**Modifies:** `elixir/WORKFLOW.md`, `elixir/lib/symphony_elixir/{config,monday/adapter,monday/item,workspace,profile_resolver,status_dashboard,tracker}*`
**Does NOT modify:** Agent runtime adapters (Spec 2's responsibility — Claude/Codex/Gemini adapters keep their session contracts); Tracker primitive's Monday-write path (Spec 1 DL-005 stays intact).
**Skills applied:** `agent_spec_writer` (format), based on Spec 2's per-part context-layer convention.

| Locked decision | Source |
|---|---|
| Repo selection via Monday dropdown column (not per-board, not per-profile encoding) | DL-001 |
| Default-repo fallback to existing `hooks.after_create` when column empty | DL-002 |
| Per-repo `allowed_profiles` allowlist for HIPAA-touching repos | DL-003 |
| Repo re-resolves at retry boundary (mirrors Spec 2 DL-008 profile re-resolve) | DL-004 |
| One Symphony per board; multi-board = Spec 4 territory | DL-005 |
| Operator edits `repos:` map by hand in WORKFLOW.md (no UI) | DL-006 |
| Startup drift validation of repo-key ↔ Monday dropdown labels | DL-007 |
| Repo selection is privileged input — clone URL must pass safety check at startup | DL-008 |

---

## 1. System Overview

Symphony today targets one hardcoded repo via `WORKFLOW.md hooks.after_create`. To run multiple MyBCAT repos through a single Symphony instance, this spec adds per-item repo selection from a new Monday dropdown column. The dropdown's value is a key into a new `repos:` map in WORKFLOW.md; each entry holds the clone URL and an after-create hook tailored to that repo's stack (npm vs pip vs mix, etc.).

The operator workflow becomes: pick repo from a Monday dropdown, pick AI profile from the existing dropdown (Spec 2), set `Symphony Status = Symphony Ready`. One board, one Symphony, N repos.

The trust boundary expands: the Monday `Symphony Repo` column is a privileged input that selects a `git clone` target. Symphony validates clone URLs at startup and refuses to dispatch items whose resolved repo is unrecognized.

---

## 2. Behavioral Contract (system-level)

### 2.1 Repo selection per item
- **When** Symphony dispatches an item, **the system** reads the per-issue Monday `Symphony Repo` dropdown column (column ID configured via `tracker.repo_column_id`). If non-empty, the named repo is used.
- **When** the per-issue value is empty, **the system** falls back to the existing global `hooks.after_create` block as the "default repo" (preserves Spec 1/2 backward compat).
- **When** the per-issue value resolves to a key that is not defined in WORKFLOW.md `repos`, **the system** skips dispatch for that item and emits an operator-visible error (`{:unknown_repo, repo_key}`). It does NOT silently fall back to the default.
- **The system** treats the resolved repo key as part of the issue's dispatch context: it is logged, surfaced on the dashboard, and threaded through retry scheduling.

### 2.2 Per-repo workspace creation
- **When** the resolved repo entry has its own `after_create` hook, **the system** runs that hook inside the per-issue workspace instead of the global `hooks.after_create`.
- **When** the resolved repo entry has its own `before_remove` hook, **the system** runs that hook on workspace cleanup. (Optional per-repo override of the global `hooks.before_remove`.)
- **When** the resolved repo has no `after_create` defined but the global one is set, **the system** uses the global hook as fallback within that repo's clone (allows minimal `repos:` entries that just specify `clone_url`).
- **The system** evaluates hook commands inside the workspace directory after `mkdir`, not before clone.

### 2.3 Per-repo profile allowlist (HIPAA gate)
- **When** a repo entry declares `allowed_profiles: [...]`, **the system** asserts the resolved profile name is in that list before dispatch.
- **When** the resolved profile is not in the allowlist, **the system** skips dispatch and emits an operator-visible error (`{:profile_not_allowed_on_repo, profile_name, repo_key}`).
- **When** a repo entry has no `allowed_profiles` field, all profiles in the WORKFLOW.md `profiles` map are permitted.
- **The system** treats this as a privileged-input safety floor: the operator cannot, e.g., flip a HIPAA-touching repo's profile to `gemini_long_context` if that profile isn't onboarded for the repo.

### 2.4 Repo re-resolves at retry boundary
- **When** an attempt fails and the orchestrator schedules a retry, **the system** re-reads the per-issue repo column at the retry boundary, mirroring Spec 2 DL-008's profile re-resolve.
- **When** the operator changes the repo column mid-session, **the system** does NOT teardown the running session; the change applies on the next attempt only. The current workspace remains under the previously-resolved repo.
- **When** a retry resolves to a different repo than the prior attempt, **the system** creates a fresh workspace for the new repo (does not reuse the prior workspace).

### 2.5 Status dashboard surfaces repo
- **When** the dashboard renders an active session, **the system** shows the resolved repo key alongside the profile, identifier, and PID.
- **When** the dashboard renders the global summary, **the system** does NOT aggregate by repo; aggregation by repo is out of scope for v1 (extension territory).

### 2.6 Startup validation of repo drift
- **When** Symphony starts, **the system** queries the Monday board for the `Symphony Repo` dropdown column's full list of label options.
- **When** any repo key in `repos:` is missing from the dropdown labels, **the system** emits an operator warning naming the gap.
- **When** any dropdown label has no corresponding entry in `repos:`, **the system** emits an operator warning naming the orphan.
- **When** the dropdown column does not exist on the board AND `tracker.repo_column_id` is configured, **the system** refuses to boot.
- **When** `tracker.repo_column_id` is unset, **the system** boots without the validation (single-repo legacy mode preserved).

### 2.7 Clone URL safety floor
- **When** Symphony starts, **the system** validates each `repos[*].clone_url` matches one of: `git@<host>:<path>.git` (SSH form) or `https://<host>/<path>.git` (HTTPS form). It rejects entries with embedded credentials in the URL (e.g. `https://user:token@host/...`), shell metacharacters, or paths that traverse outside the workspace.
- **When** any entry fails validation, **the system** refuses to boot and names the offending repo key + reason.
- **The system** does NOT verify the clone URL is reachable at startup (network-dependent; run-time clone failure is handled via Spec 1's existing workspace-hook-failed retry path).

---

## 3. Explicit Non-Behaviors

- The system MUST NOT permit Symphony itself to write to repos other than the resolved repo. (The agent CLI handles all repo writes inside its workspace; Symphony only reads Monday and writes Monday.)
- The system MUST NOT auto-create the `Symphony Repo` dropdown column on Monday. The operator creates it manually as part of the rollout (matches Spec 2's pattern for the `Symphony Profile` column).
- The system MUST NOT support per-repo secret injection in v1. Existing `MONDAY_API_TOKEN` indirection is the only env-var-from-secret path. Per-repo secrets (e.g., `HUBSPOT_TOKEN` for hubspot-daily) are extension territory (Spec 5 candidate).
- The system MUST NOT support multiple Tech Boards per Symphony instance. One board per Symphony (multi-board is Spec 4).
- The system MUST NOT auto-clone a "default repo" if the column is empty AND the global `hooks.after_create` is unset. Skip + warn is the only valid response in that case.
- The system MUST NOT fall back across repos on failure. If the resolved repo's clone fails, the orchestrator retries with the same repo, never switches.
- The system MUST NOT mid-flight swap a running session's workspace if the repo column changes. Change applies on next attempt only.
- The system MUST NOT inspect or modify `clone_url` beyond the safety-floor format check at startup. The clone command runs verbatim under existing process-spawn semantics.

---

## 4. Integration Boundaries

### Monday `Symphony Repo` column (new)
- **Type:** dropdown (`limit_select: true` — single-select, matching `Symphony Profile`).
- **Column ID:** TBD at column creation; configured into WORKFLOW.md via `tracker.repo_column_id`.
- **Labels:** one entry per managed repo (e.g., `mybcat-blog`, `hubspot-daily`, `podcast`, `mybcat-rag`, `OB`, `symphony`).
- **Symphony reads:** dropdown text value via `Monday.Adapter` items_page query (extension of `collect_column_ids`).
- **Symphony writes:** never. The column is operator-controlled only.
- **When unavailable:** if the GraphQL query for the column fails, dispatch falls through Spec 1's existing `{:unexpected_response, ...}` error path; orchestrator retries on next tick.

### Per-repo git remotes
- **Auth:** assumed via existing host-level git credentials (SSH key for `git@github.com:MyBcat/...` or HTTPS credential helper). Symphony does not provision credentials per repo.
- **Clone command:** runs verbatim from `repos[X].after_create` hook inside the workspace dir under existing process-spawn semantics. No shell escaping happens beyond what bash already provides.
- **When unavailable:** clone failure surfaces as `{:workspace_hook_failed, "after_create", exit_code, output}` per existing Spec 1 behavior; orchestrator retries.

### WORKFLOW.md `repos:` map (new top-level key)
- **Shape:**
  ```yaml
  repos:
    mybcat-blog:
      clone_url: git@github.com:MyBcat/mybcat-blog.git
      after_create: |
        git clone --depth 1 git@github.com:MyBcat/mybcat-blog.git .
        npm ci
      allowed_profiles: [claude_opus, claude_sonnet]
      default_branch: main
    hubspot-daily:
      clone_url: git@github.com:MyBcat/hubspot-daily.git
      after_create: |
        git clone --depth 1 git@github.com:MyBcat/hubspot-daily.git .
        python3 -m pip install -r requirements.txt
      allowed_profiles: [claude_opus, codex_gpt55_xhigh]
  ```
- **Required fields:** `clone_url`. (`after_create`, `allowed_profiles`, `default_branch` all optional.)
- **Validation at startup:** clone_url format check (per §2.7); `allowed_profiles` entries must reference profiles that exist in `profiles` map; `default_branch` is opaque text.

---

## 5. Behavioral Scenarios (eval-only)

### S1 — Happy path: per-item Claude Opus on mybcat-blog
- Setup: `Symphony Repo` = `mybcat-blog`, `Symphony Profile` = `claude_opus`, `Symphony Status` = `Symphony Ready`. WORKFLOW.md has `repos.mybcat-blog.after_create` with `git clone ... && npm ci`.
- Action: Symphony's next tick.
- Expected: Workspace created; `repos.mybcat-blog.after_create` hook runs (clones blog repo, installs deps); Claude Code session spawns with prompt rendered against issue title + description; Item status transitions Symphony Ready → In Progress; dashboard shows `repo=mybcat-blog profile=claude_opus`.

### S2 — Happy path: empty repo column falls back to global hook
- Setup: `Symphony Repo` empty, `Symphony Profile` = `claude_opus`. WORKFLOW.md has global `hooks.after_create` set (existing test/single-repo mode).
- Action: Symphony's next tick.
- Expected: Workspace created; global `hooks.after_create` runs (legacy openai/symphony clone); session spawns; dashboard shows `repo=<default> profile=claude_opus` (or omits repo with explanatory marker).

### S3 — Happy path: repo flip on retry applies to new attempt
- Setup: Item starts under `Symphony Repo = mybcat-blog`, attempt 1 fails (after_create hook crashes on `npm ci` due to network blip). Operator changes `Symphony Repo` to `hubspot-daily` mid-retry-backoff.
- Action: Retry timer fires.
- Expected: Symphony re-resolves repo, sees `hubspot-daily`, creates a fresh workspace under that key (does not reuse the mybcat-blog workspace), runs hubspot-daily's `after_create` (`pip install`), spawns session.

### S4 — Error: unknown repo key
- Setup: `Symphony Repo` = `does-not-exist` (label exists on Monday because operator added it but forgot to add the entry to WORKFLOW.md).
- Action: Symphony's next tick.
- Expected: Skip + warn `{:unknown_repo, "does-not-exist"}`; item left in `Symphony Ready`; orchestrator continues to other items; no workspace created; no agent spawned.

### S5 — Error: profile not in repo's allowlist
- Setup: `Symphony Repo` = `mybcat-blog` (allowed_profiles = `[claude_opus, claude_sonnet]`), `Symphony Profile` = `gemini_long_context`.
- Action: Symphony's next tick.
- Expected: Skip + warn `{:profile_not_allowed_on_repo, "gemini_long_context", "mybcat-blog"}`; no workspace; item left in `Symphony Ready`.

### S6 — Error: clone URL safety floor violation at startup
- Setup: WORKFLOW.md has `repos.bad.clone_url = https://user:t0ken@github.com/x/y.git` (embedded credentials).
- Action: Symphony boot.
- Expected: Boot refused with operator error naming `bad` + violation `embedded credentials in URL`. No tick runs.

### S7 — Edge: startup detects repo drift between WORKFLOW.md and Monday dropdown
- Setup: WORKFLOW.md `repos:` has keys `[mybcat-blog, hubspot-daily, podcast]`. Monday dropdown column has labels `[mybcat-blog, hubspot-daily, OB]` (operator added `OB` on Monday but forgot WORKFLOW.md; operator removed `podcast` from Monday but forgot WORKFLOW.md).
- Action: Symphony boot (with `tracker.repo_column_id` set).
- Expected: Orchestrator boots; emits two warnings: `repo "podcast" missing from Monday dropdown` and `Monday dropdown label "OB" has no entry in repos: map`. Dispatch proceeds normally for items using `mybcat-blog` or `hubspot-daily`.

---

## 6. Per-Part Context Layers

### Part A — Repo Resolution Layer

#### A.1 Module Manifest

| Module | Path | Purpose | Consumers |
|---|---|---|---|
| `SymphonyElixir.Config` | `lib/symphony_elixir/config.ex` | Loads `repos:` map from WORKFLOW.md; exposes `repos/0`, `repo!/1`, `repo_or_default/1` getters | Orchestrator, ProfileResolver, Workspace |
| `SymphonyElixir.Config.Schema` | `lib/symphony_elixir/config.ex` (parser) | Validates `repos:` shape at parse time; rejects malformed entries | Config |
| `SymphonyElixir.Monday.Item` | `lib/symphony_elixir/monday/item.ex` | Extends `from_monday/2` to surface the repo column value as `issue.repo` | Tracker.Issue normalization |
| `SymphonyElixir.Monday.Adapter` | `lib/symphony_elixir/monday/adapter.ex` | Adds `cfg.repo_column_id` to `collect_column_ids/1`; threads value into normalized issues | Orchestrator dispatch |
| `SymphonyElixir.ProfileResolver` | `lib/symphony_elixir/profile_resolver.ex` | Adds `allowed_profiles` allowlist check after profile resolution | Orchestrator dispatch |
| `SymphonyElixir.Workspace` | `lib/symphony_elixir/workspace.ex` | Renders the per-repo `after_create` hook from `Config.repo_or_default(issue.repo)` instead of the global hook | AgentRunner |
| `SymphonyElixir.StatusDashboard` | `lib/symphony_elixir/status_dashboard.ex` | Renders per-running-issue `repo=` field alongside profile/PID | Operator UI |

#### A.2 Behavioral Contracts

- `Config.repos/0 :: %{String.t() => repo_entry}` — returns the parsed repos map; empty if unset.
- `Config.repo!/1` — raises if key not present.
- `Config.repo_or_default/1` — returns `{:ok, repo_entry}` for known keys; `{:default, %{after_create: <global>}}` if key is empty/nil and global hook is set; `{:error, :unknown_repo}` if key is non-empty but not in `repos:` map; `{:error, :no_default}` if key is empty AND no global hook is set.
- `Item.from_monday/2` returns `%Tracker.Issue{}` with new field `:repo` (String.t() | nil). nil means column is empty or column ID not configured.
- `Workspace.create_for_issue/2` consults `Config.repo_or_default(issue.repo)` and runs the resolved hook. Existing behavior preserved when issue.repo is nil and global hook exists.
- `ProfileResolver.resolve/1` extends to take the resolved repo as input; emits `{:error, {:profile_not_allowed_on_repo, profile, repo_key}}` if `allowed_profiles` is set and resolved profile is not in it.

#### A.3 Decision Log

##### DL-001: Repo selection via Monday dropdown column (rejected: per-board, per-profile encoding, description-driven)
**Context:** Operator needs to pick a repo per item. Four candidate mechanisms: (a) per-item Monday column; (b) one Symphony per repo (per-board); (c) encode repo into profile name (`claude_opus_blog`); (d) parse from item description.
**Choice:** (a). Reasons: keeps the operator's mental model "pick a row in a dropdown"; reuses the column-driven pattern already established in Spec 2 (`Symphony Profile`); single Symphony instance preserves heartbeat sentinel uniqueness; doesn't couple AI selection to repo selection.
**Reversal cost:** Low — switching to per-board (b) means stopping this Symphony and bringing up N more; per-profile (c) means renaming dropdown options; description-driven (d) means changing prompt template.
**What breaks if reversed:** Operators lose the ability to change repo without changing AI; HIPAA gate (DL-003) becomes harder to enforce per-repo because there's no clean per-repo metadata layer.

##### DL-002: Default-repo fallback to global hooks.after_create when column empty
**Context:** What does Symphony do when `Symphony Repo` column is empty?
**Choice:** Fall back to the existing top-level `hooks.after_create` (legacy single-repo mode preserved). Skip + warn only when key is non-empty but unknown.
**Reasons:** Backward compatibility — Spec 1 + Spec 2 shipped with single-repo behavior, and this spec must not break any in-flight items that don't yet have the column set; matches the existing "absent = use default" semantics for the profile column (Spec 2 DL-008's profile fallback to `agent.default_profile`).
**Reversal cost:** Medium — would require migrating all existing items to set the column or providing a different default mechanism.
**What breaks if reversed:** All existing items in `Symphony Ready` would fail dispatch on first boot post-rollout.

##### DL-003: Per-repo allowed_profiles allowlist (HIPAA gate)
**Context:** MyBCAT has PHI-touching repos (e.g., billing, appointment KPIs) where running an unsandboxed AI like `gemini_long_context` (which doesn't yet have a vetted PHI redaction posture) is unacceptable.
**Choice:** Each `repos:` entry MAY declare `allowed_profiles: [...]`. ProfileResolver enforces the gate at dispatch time. No allowlist = all profiles allowed.
**Reasons:** Lets operators tighten security per-repo without a global toggle; default is permissive (no allowlist = no gate) so existing repos work without change; aligns with Spec 2's privileged-input + safety-floor pattern (DL-006 there).
**Reversal cost:** Low — drop the field, dispatch becomes unrestricted.
**What breaks if reversed:** PHI-bearing repos would be exposed to any onboarded profile, including ones without sandbox vetting.

##### DL-004: Repo re-resolves at retry boundary (mirrors Spec 2 DL-008 profile re-resolve)
**Context:** What happens if the operator flips the repo column while an item is mid-retry-backoff?
**Choice:** Re-resolve the repo (and re-resolve the profile, per Spec 2 DL-008) at every retry boundary. Mid-session swap NOT supported.
**Reasons:** Symmetry with Spec 2 — operator can correct a mid-flight mistake without manually cancelling and re-enrolling; a fresh workspace is created when the repo changes (no mixing of two repos' file trees).
**Reversal cost:** Low — pin the repo at first dispatch.
**What breaks if reversed:** Operator typo in repo column requires status flip to Cancelled + re-enroll, which adds friction.

##### DL-005: One Symphony per board; multi-board = Spec 4 territory
**Context:** Could one Symphony instance watch multiple boards (different teams, different sentinel items)?
**Choice:** No. Spec 3 keeps the one-board-per-Symphony invariant from Spec 1.
**Reasons:** Heartbeat sentinel logic + restart cleanup assume a single board; multi-board would require N sentinel items + a coordination primitive between boards; not justified by current MyBCAT use case (one Tech Board).
**Reversal cost:** High — heartbeat semantics, startup reconciliation, and orchestrator state would all need rethinking.
**What breaks if reversed:** Multi-tenant deployments where each MyBCAT subsidiary has its own board.

##### DL-006: Operator edits `repos:` map by hand in WORKFLOW.md (no UI)
**Context:** Should there be a Monday-driven or terminal-UI for managing the `repos:` map?
**Choice:** No. Operator edits WORKFLOW.md directly. Drift is detected at startup (DL-007).
**Reasons:** Matches existing Spec 2 model for `profiles:` (also hand-edited); WORKFLOW.md is git-versioned, which gives change history + PR review; UI is feature creep for a tool that's still in early production.
**Reversal cost:** Low — UI can be added later without changing the data shape.
**What breaks if reversed:** Operator needs to learn YAML, but `profiles:` already requires that.

##### DL-007: Startup drift validation of repo-key ↔ Monday dropdown labels
**Context:** What if the WORKFLOW.md `repos:` keys and the Monday dropdown labels diverge?
**Choice:** Symphony queries the dropdown column at startup. Emits warnings for missing-from-Monday and orphan-on-Monday; refuses to boot only if the column itself doesn't exist (and `tracker.repo_column_id` is set).
**Reasons:** Mirrors Spec 2 DL-010 profile drift validation. Warnings are recoverable — Ankit can run with drift while migrating; refusing boot on missing column protects against silent dispatch failures.
**Reversal cost:** Low — drop the validation.
**What breaks if reversed:** Operator misconfiguration silently produces `{:unknown_repo, ...}` errors at dispatch time, scattered across logs.

##### DL-008: Repo selection is privileged input — clone URL must pass safety check at startup
**Context:** A malicious or sloppy `clone_url` could exfiltrate credentials, escape the workspace, or run arbitrary shell.
**Choice:** Validate URL format at boot. Reject embedded credentials, shell metacharacters, path traversal. Match the spirit of Spec 2 DL-006's sandbox safety floor.
**Reasons:** WORKFLOW.md is committed to git and reviewed via PR — this is a defense-in-depth check, not the primary review gate, but it catches obvious mistakes before they hit production. Mirrors the operator-cannot-bypass posture of Spec 2.
**Reversal cost:** Low — drop the check.
**What breaks if reversed:** A typo in `clone_url` (e.g., `https://user:token@host/...` left in by mistake) would persist into runtime workspace shell commands.

---

## 7. SPEC.md Concrete Diff Plan (Spec 3 scope only)

### Sections to amend
- §3.1 Main Components: `Workspace Manager` description gains "consults per-issue repo selection from Tracker"; `Issue Tracker Client` description gains "surfaces per-issue repo column value".
- §3.2 Abstraction Levels: `Policy Layer` gains the `repos:` map alongside the `profiles:` map.
- §6 Workflow Configuration: add `tracker.repo_column_id` and the `repos:` block.
- §11 Workspace Lifecycle: add per-repo `after_create` resolution rule.

### New sections
- §6.X `repos:` map format (mirrors §6.X `profiles:` map from Spec 2).
- §11.X Per-issue repo dispatch rules.

### Removed sections / fields
- None. The global `hooks.after_create` stays as the default fallback (DL-002).

### Renames (global)
- None.

---

## 8. Reference Implementation Deltas

### `elixir/lib/symphony_elixir/config.ex`
- Extend the `tracker` Schema parser to accept optional `repo_column_id: String.t() | nil`.
- Add new top-level Schema parser entry for `repos: %{String.t() => repo_entry}` where `repo_entry = %{clone_url: String.t(), after_create: String.t() | nil, allowed_profiles: [String.t()] | nil, default_branch: String.t() | nil}`.
- Add `Config.repos/0`, `Config.repo!/1`, `Config.repo_or_default/1` getters.
- Add `Config.validate_semantics` checks (mirrors Spec 2 §13): clone_url format, allowed_profiles entries reference real profile names, repos-vs-Monday-dropdown drift warning at boot.

### `elixir/lib/symphony_elixir/monday/adapter.ex`
- Extend `collect_column_ids/1` to include `cfg[:repo_column_id]` when present.
- Extend `Item.from_monday/2` (in `monday/item.ex`) to surface the repo column value into `%Tracker.Issue{repo: String.t() | nil}`.
- Add new GraphQL query `SymphonyRepoLabels` for boot-time drift validation (mirrors `SymphonyStatusLabels` shape from PR #4 — same `settings_str` parser pattern).

### `elixir/lib/symphony_elixir/tracker.ex`
- Extend `%Tracker.Issue{}` struct with `repo: String.t() | nil` field.

### `elixir/lib/symphony_elixir/workspace.ex` (~line 210, `maybe_run_after_create_hook/4`)
- Resolve hook command from `Config.repo_or_default(issue.repo)` instead of `Config.workflow().hooks.after_create`.
- On `{:error, :unknown_repo}` or `{:error, :no_default}`, emit operator error and short-circuit dispatch (orchestrator path; existing error-handling pattern).

### `elixir/lib/symphony_elixir/profile_resolver.ex`
- After profile resolution succeeds, check `repo_or_default(issue.repo).allowed_profiles`; if set and profile name not in it, return `{:error, {:profile_not_allowed_on_repo, profile_name, repo_key}}`.

### `elixir/lib/symphony_elixir/orchestrator.ex` (~line 346, `maybe_dispatch/1`)
- Add new error pattern matches for `{:error, :unknown_repo}`, `{:error, :no_default}`, `{:error, {:profile_not_allowed_on_repo, _, _}}` — log + skip + leave item in `Symphony Ready`.

### `elixir/lib/symphony_elixir/status_dashboard.ex`
- Add `repo=<key>` rendering to the per-running-issue row alongside the existing profile + PID columns.

### `elixir/WORKFLOW.md`
- Add `tracker.repo_column_id: <new_column_id>`.
- Add top-level `repos:` map with at least 2 example entries (e.g., `mybcat-blog`, `hubspot-daily`) and the existing `openai/symphony` repo as a third entry for backward compat.
- Keep `hooks.after_create` as the default fallback.

### Tests
- `test/symphony_elixir/monday/adapter_test.exs` — add cases:
  - `Item.from_monday/2` extracts repo column value
  - `collect_column_ids/1` includes repo_column_id when set
  - `SymphonyRepoLabels` query mock + parse
- `test/symphony_elixir/profile_resolver_test.exs` — add cases:
  - `allowed_profiles` allowlist permits valid combo
  - `allowed_profiles` allowlist denies invalid combo
  - empty `allowed_profiles` field permits all profiles
- `test/symphony_elixir/workspace_test.exs` — add cases:
  - per-repo after_create hook runs
  - empty repo column falls back to global hook
  - unknown repo returns `:unknown_repo` error
- `test/symphony_elixir/orchestrator_*test.exs` — add dispatch happy-path tests for:
  - per-item repo dispatch (S1)
  - empty column fallback (S2)
  - retry with repo flip (S3)
  - unknown repo skip (S4)
  - profile-not-allowed skip (S5)
  - multi-repo concurrent dispatch (two items, two repos, both running simultaneously up to per-profile cap)
- `test/symphony_elixir/config_test.exs` — add cases:
  - clone_url safety floor accepts SSH + HTTPS forms
  - clone_url safety floor rejects embedded credentials
  - clone_url safety floor rejects shell metacharacters
  - allowed_profiles entries must reference real profile names

---

## 9. Tech Board Setup Delta (Spec 3 only)

Operator runs the following one-time setup before Symphony with Spec 3 boots:

1. On Monday board `8173460438`, add a new column:
   - **Type:** Dropdown
   - **Title:** Symphony Repo
   - **Description:** Per-item Symphony repo selection. Values must match WORKFLOW.md `repos:` map keys. Empty = use `hooks.after_create` default.
   - **Settings:** `limit_select: true` (single-select).
   - **Labels:** one per managed repo (start with `mybcat-blog`, `hubspot-daily`, plus whatever else is being onboarded).

2. Update `WORKFLOW.md`:
   - Set `tracker.repo_column_id` to the new column ID (operator looks up the ID via Monday's column metadata or `get_board_info`).
   - Add `repos:` map with one entry per dropdown label.
   - Keep `hooks.after_create` for legacy fallback.

3. Restart Symphony.

4. Smoke test: create a new Tech Board item with `Symphony Repo: mybcat-blog`, `Symphony Profile: claude_opus`, `Symphony Status: Symphony Ready`. Verify dispatch logs show the correct repo's `after_create` hook running.

---

## 10. Out of Scope for Spec 3

- Multi-board support (one Symphony per N boards). Future Spec 4.
- Per-repo secret injection (e.g., `HUBSPOT_TOKEN` per hubspot-daily). Future Spec 5.
- A terminal UI or web UI for editing the `repos:` map. Operator edits WORKFLOW.md by hand.
- Repo-aware token accounting / cost attribution. Per-runtime token accounting (Spec 2 §2.4) stays as is.
- Per-repo concurrency caps. Existing per-profile + global caps (Spec 2 §2.5) suffice.
- Rule-based routing (e.g., "if title contains 'blog' route to mybcat-blog"). Manual dropdown only.
- Auto-creating Monday dropdown labels from WORKFLOW.md `repos:` keys. Operator-controlled.

---

## 11. Ambiguity Warnings (locked at recommended defaults — 2026-05-04)

These five edge-case decisions are locked at the recommended defaults below. Direct user instruction during spec authoring: lock them so an autonomous agent can implement Spec 3 without further input. Each can be revisited via a follow-up spec amendment if implementation surfaces a real conflict.

| ID | Decision | Rationale |
|---|---|---|
| AW-1 (locked) | When per-issue repo column is empty AND `hooks.after_create` is unset, **skip + warn at dispatch time**. No hardcoded fallback. | Mirrors Spec 2 DL-008 "skip + warn over silent fallback" posture. Loud failure beats silent misdispatch. |
| AW-2 (locked) | When a retry resolves to a different repo than the prior attempt, **cleanup the prior workspace immediately** before creating the new one. | Prevents orphan workspaces from accumulating on disk across retry cycles. |
| AW-3 (locked) | `clone_url` does **NOT** support env-var indirection in v1. URLs are literal. | Reduces surface area; the existing `$MONDAY_API_TOKEN` precedent is justified by secret-handling, not URL templating. Future spec can add this if staging/prod hosts diverge. |
| AW-4 (locked) | A deactivated Monday dropdown label whose WORKFLOW.md `repos:` entry still exists is treated as **known-repo**; existing items dispatch normally. Boot-time drift warning surfaces the deactivation to the operator. | Don't strand work in flight when an operator deactivates a label without first cleaning up WORKFLOW.md. |
| AW-5 (locked) | `default_branch` is **metadata-only**. Exposed to the agent via `{{ issue.repo_default_branch }}` Liquid variable in the prompt template. Symphony does NOT enforce the branch on the agent's PR. | Agent gets the hint; reviewer catches a wrong-base PR. Symphony staying out of branch enforcement keeps the existing prompt-driven model intact. |

---

## 12. Implementation Sequencing

1. **Boot-time validation first.** Land Config.Schema parser changes + clone_url safety floor + drift detection before touching dispatch path. Failing here is loud and recoverable.
2. **Tracker layer next.** Item.from_monday + Adapter.collect_column_ids + Tracker.Issue.repo. No behavior change to dispatch yet.
3. **Workspace + ProfileResolver.** Wire repo into hook resolution + allowlist enforcement. This is where dispatch behavior actually changes.
4. **Orchestrator + StatusDashboard.** Surface the new error paths + dashboard rendering.
5. **WORKFLOW.md update + Tech Board operator setup.** Last — only after the code is merged.
6. **Smoke test with one repo (e.g., mybcat-blog) before adding more.**

Mirrors Spec 1 + Spec 2 sequencing: parser → tracker layer → dispatch layer → operator-visible surface.

---

## 13. Test Plan Summary

| Layer | Cases | File |
|---|---|---|
| Config parsing | repos: shape valid; clone_url format valid/invalid; allowed_profiles entries reference real profiles | `config_test.exs` |
| Monday read path | Item.from_monday surfaces repo; collect_column_ids includes repo_column_id; SymphonyRepoLabels parses | `monday/adapter_test.exs`, `monday/item_test.exs` |
| ProfileResolver | allowlist permits, denies, defaults | `profile_resolver_test.exs` |
| Workspace | per-repo hook runs; empty column falls back; unknown repo errors | `workspace_test.exs` |
| Orchestrator dispatch | S1 happy path; S2 fallback; S3 retry-flip; S4 unknown_repo; S5 profile_not_allowed; multi-repo concurrent | `orchestrator_*test.exs` |
| Boot-time validation | repo drift warnings; clone_url safety floor refusal | `config_test.exs`, `application_test.exs` (or whichever covers boot) |

Targeted run: `mix test test/symphony_elixir/{config,monday/adapter,monday/item,profile_resolver,workspace,orchestrator_status}_test.exs`. Full suite must remain at the prior baseline (post-Spec-2: 339 tests / 45 pre-existing failures / 2 skipped vs. main; new tests +N, no new failures).

---
