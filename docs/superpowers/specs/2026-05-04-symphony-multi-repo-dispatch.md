# Symphony — Multi-Repo Dispatch (Spec 3)

**Status:** Draft for review
**Date:** 2026-05-04
**Authors:** Ankit Patel + Claude (Opus 4.7, 1M context)
**Sequencing:** Spec 3. **Depends on Spec 1** (`2026-05-03-symphony-monday-tracker-swap.md`) and **Spec 2** (`2026-05-03-symphony-multi-runtime-profiles.md`) being shipped first. Both merged as of 2026-05-04. PR #4 (`fix: translate Monday status labels to label IDs`) also merged before this spec begins — it unblocked end-to-end dispatch on the Tech Board.
**Modifies:** `elixir/WORKFLOW.md`, `elixir/lib/symphony_elixir/{agent_runner,config,monday/adapter,monday/item,prompt_builder,workspace,profile_resolver,status_dashboard,tracker}*`
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
| Repo selection is privileged input — clone URL must pass host allowlist + safe-clone checks at startup | DL-008 |

---

## 1. System Overview

Symphony today targets one hardcoded repo via `WORKFLOW.md hooks.after_create`. To run multiple MyBCAT repos through a single Symphony instance, this spec adds per-item repo selection from a new Monday dropdown column. The dropdown's value is a key into a new `repos:` map in WORKFLOW.md; each entry holds the clone URL and optional post-clone hooks tailored to that repo's stack (npm vs pip vs mix, etc.).

The operator workflow becomes: pick repo from a Monday dropdown, pick AI profile from the existing dropdown (Spec 2), set `Symphony Status = Symphony Ready`. One board, one Symphony, N repos.

The trust boundary expands: the Monday `Symphony Repo` column is a privileged input that selects a `git clone` target. Symphony validates clone URLs at startup and refuses to dispatch items whose resolved repo is unrecognized.

---

## 2. Behavioral Contract (system-level)

### 2.1 Repo selection per item
- **When** `tracker.repo_column_id` is configured, **the system** reads the per-issue Monday `Symphony Repo` dropdown column through `SymphonyElixir.Monday.Adapter` (read-only; no Monday mutations are added). If non-empty, the named repo is used.
- **When** `tracker.repo_column_id` is unset, **the system** enters single-repo legacy mode: every issue resolves to `repo=<default>`, the `repos:` map is ignored for dispatch, and the existing global `hooks.after_create` block is used if present. Startup MUST log `repo_column_id unset; multi-repo dispatch disabled`; if `repos:` is non-empty, this MUST be a warning naming that `repos:` is ignored until the column ID is set.
- **When** `tracker.repo_column_id` is configured and the per-issue value is empty, **the system** falls back to the existing global `hooks.after_create` block as the "default repo" (preserves Spec 1/2 backward compat).
- **When** an issue resolves to `repo=<default>` and the global `hooks.after_create` block is unset or blank, **the system** skips dispatch for that item and emits an operator-visible error (`{:no_default_repo, issue.identifier}`). It does NOT create an empty "default repo" workspace.
- **When** the per-issue value resolves to a key that is not defined in WORKFLOW.md `repos`, **the system** skips dispatch for that item and emits an operator-visible error (`{:unknown_repo, repo_key}`). It does NOT silently fall back to the default.
- **The system** treats the resolved repo key as part of the issue's dispatch context: it is logged, surfaced on the dashboard, and threaded through retry scheduling.

### 2.2 Per-repo workspace creation
- **When** the resolved repo is a known `repos:` entry, **the system** performs the clone itself using that entry's validated `clone_url`; per-repo `after_create` is a post-clone setup hook only (e.g., `npm ci`, `mix deps.get`) and MUST NOT contain `git clone`, `git submodule`, or another network source checkout.
- **When** the resolved repo entry has its own non-blank `after_create` hook, **the system** runs that hook inside the cloned per-issue workspace instead of the global `hooks.after_create`.
- **When** the resolved repo entry omits `after_create` or sets it to an empty/whitespace-only string, **the system** treats setup as an intentional no-op after the clone succeeds.
- **When** the resolved repo entry has its own `before_remove` hook, **the system** runs that hook on workspace cleanup. (Optional per-repo override of the global `hooks.before_remove`.)
- **The global** `hooks.after_create` **is used only for `repo=<default>` legacy dispatch**. It is never run after a known `repos:` clone, because legacy hooks commonly include their own clone command.
- **The system** evaluates hook commands from the live Symphony WORKFLOW.md loaded by the orchestrator process, never from a WORKFLOW.md file inside the cloned agent workspace.

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
- **When** Symphony starts and `tracker.repo_column_id` is configured, **the system** queries the Monday board for the `Symphony Repo` dropdown column's full list of label options.
- **When** any repo key in `repos:` is missing from the dropdown labels, **the system** emits an operator warning naming the gap.
- **When** any dropdown label has no corresponding entry in `repos:`, **the system** emits an operator warning naming the orphan.
- **When** the dropdown column does not exist on the board AND `tracker.repo_column_id` is configured, **the system** refuses to boot.
- **When** `tracker.repo_column_id` is unset, **the system** boots without the Monday drift query (single-repo legacy mode preserved) but MUST log the legacy-mode message from §2.1 so operators do not silently believe multi-repo dispatch is active.

### 2.7 Clone URL safety floor
- **When** Symphony starts, **the system** validates each `repos[*].clone_url` before any dispatch. Accepted forms are `git@<host>:<org>/<repo>.git` (SSH scp form, user MUST be exactly `git`) or `https://<host>/<org>/<repo>.git` (HTTPS form, no userinfo). The raw URL MUST be ASCII-only, NFC-normalized, free of shell metacharacters/control characters, and contain no path traversal, backslashes, URL-encoded path separators, or empty path segments.
- **When** the parsed host is not an exact lower-case ASCII match for `repo_policy.allowed_clone_hosts` (default `["github.com"]`), **the system** refuses to boot and names the repo key + host. Subdomain suffix matches do not count (`github.com.evil.test` is not `github.com`).
- **When** any entry fails validation, **the system** refuses to boot and names the offending repo key + reason.
- **When** cloning a known repo, **the system** invokes git as argv (no shell interpolation) with the equivalent of: `git -c core.hooksPath=/dev/null -c protocol.file.allow=never -c protocol.ext.allow=never clone --depth 1 --no-recurse-submodules -- <clone_url> .`
- **The system** does NOT initialize or update git submodules in v1. Repos that require submodules need a future spec with an explicit submodule host allowlist.
- **The system** does NOT verify the clone URL is reachable at startup (network-dependent; run-time clone failure returns `{:workspace_clone_failed, repo_key, exit_code, output}` and uses the existing dispatch-failure retry path).

---

## 3. Explicit Non-Behaviors

- The system MUST NOT permit Symphony itself to write to repos other than the resolved repo. (The agent CLI handles all repo writes inside its workspace; Symphony only reads Monday and writes Monday.)
- The system MUST NOT auto-create the `Symphony Repo` dropdown column on Monday. The operator creates it manually as part of the rollout (matches Spec 2's pattern for the `Symphony Profile` column).
- The system MUST NOT support per-repo secret injection in v1. Existing `MONDAY_API_TOKEN` indirection is the only env-var-from-secret path. Per-repo secrets (e.g., `HUBSPOT_TOKEN` for hubspot-daily) are extension territory (Spec 5 candidate).
- The system MUST NOT support multiple Tech Boards per Symphony instance. One board per Symphony (multi-board is Spec 4).
- The system MUST NOT auto-clone a "default repo" if the column is empty AND the global `hooks.after_create` is unset. Skip + warn is the only valid response in that case.
- The system MUST NOT fall back across repos on failure. If the resolved repo's clone fails, the orchestrator retries with the same repo, never switches.
- The system MUST NOT mid-flight swap a running session's workspace if the repo column changes. Change applies on next attempt only.
- The system MUST NOT run a per-repo clone through `after_create`. Clone execution is owned by Symphony's safe-clone command (§2.7); `after_create` is post-clone setup only.
- The system MUST NOT support git submodule checkout in v1 (`--no-recurse-submodules`; no `git submodule` in per-repo hooks).
- The system MUST NOT support env-var indirection in `repos[*].clone_url`; URLs are literal WORKFLOW.md values reviewed in git.
- The system MUST NOT read hook definitions from files inside the cloned workspace. An agent may edit a repo's WORKFLOW.md copy, but that copy cannot alter the running Symphony instance's repo map or another repo's hook.

---

## 4. Integration Boundaries

### Monday `Symphony Repo` column (new)
- **Type:** dropdown (`limit_select: true` — single-select, matching `Symphony Profile`).
- **Column ID:** TBD at column creation; configured into WORKFLOW.md via `tracker.repo_column_id`.
- **Labels:** one entry per managed repo (e.g., `mybcat-blog`, `hubspot-daily`, `podcast`, `mybcat-rag`, `OB`, `symphony`).
- **Symphony reads:** dropdown text value via `Monday.Adapter` items_page query (extension of `collect_column_ids`) and dropdown metadata via `SymphonyRepoLabels` at startup. These are read-only GraphQL queries and do not alter Monday board data.
- **Symphony writes:** never. The column is operator-controlled only.
- **When unavailable:** if the GraphQL query for the column fails, dispatch falls through Spec 1's existing `{:unexpected_response, ...}` error path; orchestrator retries on next tick.

#### `SymphonyRepoLabels` GraphQL response shape

Query mirrors the existing `SymphonyStatusLabels` metadata query, with a separate operation name so test mocks can distinguish the drift-validation path:

```graphql
query SymphonyRepoLabels($boardId: ID!, $columnIds: [String!]) {
  boards(ids: [$boardId]) {
    columns(ids: $columnIds) {
      id
      title
      settings_str
    }
  }
}
```

Expected successful response shape:

```elixir
%{
  "data" => %{
    "boards" => [
      %{
        "columns" => [
          %{
            "id" => "<tracker.repo_column_id>",
            "title" => "Symphony Repo",
            "settings_str" => Jason.encode!(%{
              "labels" => %{"0" => "mybcat-blog", "1" => "hubspot-daily"},
              "deactivated_labels" => ["1"]
            })
          }
        ]
      }
    ]
  }
}
```

Parser contract: decode `settings_str`, read `labels` as a map of label-id string to label text, read `deactivated_labels` as optional label-id strings, and return `%{active_labels: [...], deactivated_labels: [...]}`. Unlike status labels, deactivated repo labels are not dropped; AW-4 defines how they behave.

### Per-repo git remotes
- **Auth:** assumed via existing host-level git credentials (SSH key for `git@github.com:MyBcat/...` or HTTPS credential helper). Symphony does not provision credentials per repo.
- **Clone command:** constructed by Symphony from `repos[X].clone_url` after §2.7 validation and executed as argv, not via `bash -lc`.
- **Post-clone setup:** optional `repos[X].after_create` runs inside the cloned workspace under the existing hook runner. This hook is trusted operator-reviewed WORKFLOW.md code and must not perform checkout/submodule/network-source operations.
- **When unavailable:** clone failure surfaces as `{:workspace_clone_failed, repo_key, exit_code, output}` and follows the existing dispatch-failure retry path.

### WORKFLOW.md `repos:` map (new top-level key)
- **Shape:**
  ```yaml
  repo_policy:
    allowed_clone_hosts: [github.com]
  repos:
    mybcat-blog:
      clone_url: git@github.com:MyBcat/mybcat-blog.git
      after_create: |
        npm ci
      allowed_profiles: [claude_opus, claude_sonnet]
      default_branch: main
    hubspot-daily:
      clone_url: git@github.com:MyBcat/hubspot-daily.git
      after_create: |
        python3 -m pip install -r requirements.txt
      allowed_profiles: [claude_opus, codex_gpt55_xhigh]
  ```
- **Required fields:** `clone_url`. (`after_create`, `allowed_profiles`, `default_branch` all optional.)
- **Optional policy:** `repo_policy.allowed_clone_hosts` defaults to `["github.com"]`; every host entry must be lower-case ASCII and exact-match only.
- **Validation at startup:** clone_url safety check (per §2.7); `allowed_profiles` entries must reference profiles that exist in `profiles` map; per-repo `after_create` must not contain `git clone` or `git submodule`; `default_branch` is opaque text.

---

## 5. Behavioral Scenarios (eval-only)

### S1 — Happy path: per-item Claude Opus on mybcat-blog
- **Setup:** `Symphony Repo` = `mybcat-blog`, `Symphony Profile` = `claude_opus`, `Symphony Status` = `Symphony Ready`. WORKFLOW.md has `repos.mybcat-blog.clone_url` and `repos.mybcat-blog.after_create` with `npm ci`.
- **Action:** Symphony's next tick.
- **Expected:** Workspace created; Symphony safely clones `repos.mybcat-blog.clone_url`; `repos.mybcat-blog.after_create` runs post-clone and installs deps; Claude Code session spawns with prompt rendered against issue title + description; Item status transitions Symphony Ready -> In Progress; dashboard shows `repo=mybcat-blog profile=claude_opus`.

### S2 — Happy path: empty repo column falls back to global hook
- **Setup:** `Symphony Repo` empty, `Symphony Profile` = `claude_opus`. WORKFLOW.md has global `hooks.after_create` set (existing test/single-repo mode).
- **Action:** Symphony's next tick.
- **Expected:** Workspace created; global `hooks.after_create` runs (legacy openai/symphony clone); session spawns; dashboard shows `repo=<default> profile=claude_opus` (or omits repo with explanatory marker).

### S3 — Happy path: repo flip on retry applies to new attempt
- **Setup:** Item starts under `Symphony Repo = mybcat-blog`, attempt 1 fails (post-clone `after_create` crashes on `npm ci` due to network blip). Operator changes `Symphony Repo` to `hubspot-daily` mid-retry-backoff.
- **Action:** Retry timer fires.
- **Expected:** Symphony re-resolves repo, sees `hubspot-daily`, cleans up the prior failed workspace, creates a fresh workspace under that key (does not reuse the mybcat-blog workspace), safely clones hubspot-daily, runs hubspot-daily's `after_create` (`pip install`), spawns session.

### S4 — Error: unknown repo key
- **Setup:** `Symphony Repo` = `does-not-exist` (label exists on Monday because operator added it but forgot to add the entry to WORKFLOW.md).
- **Action:** Symphony's next tick.
- **Expected:** Skip + warn `{:unknown_repo, "does-not-exist"}`; item left in `Symphony Ready`; orchestrator continues to other items; no workspace created; no agent spawned.

### S5 — Error: profile not in repo's allowlist
- **Setup:** `Symphony Repo` = `mybcat-blog` (allowed_profiles = `[claude_opus, claude_sonnet]`), `Symphony Profile` = `gemini_long_context`.
- **Action:** Symphony's next tick.
- **Expected:** Skip + warn `{:profile_not_allowed_on_repo, "gemini_long_context", "mybcat-blog"}`; no workspace; item left in `Symphony Ready`.

### S6 — Error: clone URL safety floor violation at startup
- **Setup:** WORKFLOW.md has `repos.bad.clone_url = https://user:t0ken@github.com/x/y.git` (embedded credentials).
- **Action:** Symphony boot.
- **Expected:** Boot refused with operator error naming `bad` + violation `embedded credentials in URL`. No tick runs.

### S7 — Edge: startup detects repo drift between WORKFLOW.md and Monday dropdown
- **Setup:** WORKFLOW.md `repos:` has keys `[mybcat-blog, hubspot-daily, podcast]`. Monday dropdown column has labels `[mybcat-blog, hubspot-daily, OB]` (operator added `OB` on Monday but forgot WORKFLOW.md; operator removed `podcast` from Monday but forgot WORKFLOW.md).
- **Action:** Symphony boot (with `tracker.repo_column_id` set).
- **Expected:** Orchestrator boots; emits two warnings: `repo "podcast" missing from Monday dropdown` and `Monday dropdown label "OB" has no entry in repos: map`. Dispatch proceeds normally for items using `mybcat-blog` or `hubspot-daily`.

### S8 — Error: host allowlist rejects Unicode-spoofed clone URL
- **Setup:** WORKFLOW.md has `repos.bad.clone_url = https://githu\u0432.com/MyBcat/repo.git` (Cyrillic small ve in the host) or `https://github.com.evil.test/MyBcat/repo.git`.
- **Action:** Symphony boot.
- **Expected:** Boot refused with operator error naming `bad` + violation `clone host not allowed` (or `non-ASCII clone_url`). The value is never passed to git.

### S9 — Edge: known repo with intentionally empty setup hook
- **Setup:** `Symphony Repo` = `symphony`, WORKFLOW.md has `repos.symphony.clone_url = git@github.com:MyBcat/symphony.git` and `repos.symphony.after_create = ""`.
- **Action:** Symphony's next tick.
- **Expected:** Workspace created; Symphony safely clones the repo; no post-clone hook runs; session spawns normally.

---

## 6. Per-Part Context Layers

### Part A — Repo Resolution and Workspace Binding Layer

#### A.1 Module Manifest

> Resolves the repository for each Monday item, validates repo config as privileged input, safely clones known repos, and binds profile allowlists to repo selection. Monday remains read-only for repo selection; all Monday writes stay under the Tracker primitive from Spec 1 DL-005.

**Context captured:** 2026-05-04 by Ankit Patel + Claude
**Last validated:** 2026-05-04

##### Dependencies

| Dependency | Type | Description |
|---|---|---|
| WORKFLOW.md `tracker.repo_column_id` | config | Enables multi-repo mode when set; unset means single-repo legacy mode with warning (§2.1, §2.6) |
| WORKFLOW.md `repo_policy.allowed_clone_hosts` | config | Exact host allowlist for `repos[*].clone_url`; defaults to `["github.com"]` |
| WORKFLOW.md `repos:` | config | Repo key -> clone/setup/allowlist/default-branch metadata |
| Monday `Symphony Repo` dropdown | external read | Per-item repo key, read through `Monday.Adapter` only |
| Git CLI | external process | Invoked by `Workspace` as argv for safe clone, not through `after_create` shell text |
| `SymphonyElixir.ProfileResolver` | shared library | Resolves Spec 2 profile and enforces repo `allowed_profiles` |

##### Dependents

| Dependent | Type | Description |
|---|---|---|
| `SymphonyElixir.Orchestrator` | sync calls | Dispatch gating, retry re-resolution, skip/warn error paths |
| `SymphonyElixir.AgentRunner` | sync calls | Calls `Workspace.create_for_issue/2` before runtime launch |
| `SymphonyElixir.StatusDashboard` | read render | Displays resolved repo key for active sessions |

##### Implementation Modules

| Module | Path | Purpose | Consumers |
|---|---|---|---|
| `SymphonyElixir.Config` | `lib/symphony_elixir/config.ex` | Loads `repo_policy` + `repos:`; exposes `repos/0`, `repo!/1`, `repo_or_default/1`; validates repo semantics | Orchestrator, ProfileResolver, Workspace |
| `SymphonyElixir.Config.Schema` | `lib/symphony_elixir/config/schema.ex` | Parses `tracker.repo_column_id`, `repo_policy`, and normalized repo entries | Config |
| `SymphonyElixir.Monday.Item` | `lib/symphony_elixir/monday/item.ex` | Extends `from_monday/2` to surface the repo column text as `issue.repo` | Tracker.Issue normalization |
| `SymphonyElixir.Monday.Adapter` | `lib/symphony_elixir/monday/adapter.ex` | Adds `cfg.repo_column_id` to `collect_column_ids/1`; adds `SymphonyRepoLabels` metadata query/parser | Orchestrator dispatch, startup validation |
| `SymphonyElixir.Tracker.Issue` | `lib/symphony_elixir/tracker/issue.ex` | Adds `repo: String.t() | nil` field | Orchestrator, AgentRunner, PromptBuilder |
| `SymphonyElixir.ProfileResolver` | `lib/symphony_elixir/profile_resolver.ex` | Enforces `allowed_profiles` after Spec 2 profile resolution | AgentRunner dispatch |
| `SymphonyElixir.Workspace` | `lib/symphony_elixir/workspace.ex` | Resolves repo/default, runs safe clone for known repos, then post-clone hook | AgentRunner |
| `SymphonyElixir.StatusDashboard` | `lib/symphony_elixir/status_dashboard.ex` | Renders `repo=<key>` in running rows | Operator UI |

##### Data Flows

| Direction | Source/Target | Data | Notes |
|---|---|---|---|
| Reads | Monday item column | `Symphony Repo` dropdown text | Read through `Monday.Adapter`; no Monday writes added |
| Reads | Monday column metadata | repo dropdown `settings_str` | Startup drift validation only |
| Reads | WORKFLOW.md | `repo_policy`, `repos`, global hooks | Live orchestrator config only; never workspace copy |
| Writes | Workspace dir | cloned repo contents | `Workspace` safe clone command owns checkout |
| Writes | Workspace dir | post-clone setup side effects | From trusted WORKFLOW.md `repos[*].after_create` only |
| (NOT) Writes | Monday | -- | Repo selection is read-only; Spec 1 DL-005 write invariant unchanged |

##### Shared Resources

| Resource | Shared With | Risk Notes |
|---|---|---|
| Git credentials on Symphony host | All managed repos | Host allowlist + no embedded URL credentials prevent obvious exfiltration paths |
| Workspace filesystem | Git clone, post-clone hook, agent runtime | Safe clone disables hooks/submodules; setup hook remains trusted operator code |
| WORKFLOW.md repo map | All dispatches | Agent workspace edits must not affect live config; deploy/restart is the only config activation path |

> **DARK CODE HOTSPOT:** `clone_url` validation is meaningful only if `Workspace` owns the clone command. Reviewers must reject any implementation that still requires per-repo `after_create` to run `git clone`, because that bypasses host allowlist, Unicode spoof checks, no-submodule policy, and no-hook clone flags.

##### Deployment Model

- **Type:** Modules inside Symphony Elixir (`lib/symphony_elixir/{config,monday,workspace,profile_resolver,status_dashboard}*`)
- **Runtime:** Elixir 1.19 / OTP 28; git subprocess spawned by `Workspace` using argv
- **Infrastructure:** Same single BEAM node and workspace root as Spec 1/2

##### Ownership

- **Team:** Symphony reference implementation (MyBCAT)
- **On-call:** Ankit Patel

#### A.2 Behavioral Contracts

**Context captured:** 2026-05-04 by Ankit Patel + Claude

---

##### `Config.repo_or_default(repo_key)`

> Resolves a raw Monday repo value into either a known repo entry or the legacy default hook.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure read of parsed config. |
| **Failure behavior** | `{:error, {:unknown_repo, repo_key}}` for non-empty unknown keys; `{:error, :no_default_repo}` for empty/nil key with no global `hooks.after_create`. |
| **Performance envelope** | O(1) map lookup. |
| **Side effects** | None. |
| **Retry guidance** | Safe; callers re-run at every attempt boundary to pick up Monday repo changes. |
| **Data classification** | Internal config. |

##### Return Shape

- `{:ok, {:repo, repo_key, repo_entry}}` for known repo keys.
- `{:ok, {:default, %{repo_key: "<default>", after_create: global_hook}}}` for nil/blank repo key when global hook is present.
- `{:error, {:unknown_repo, repo_key}}` for non-empty missing keys.
- `{:error, :no_default_repo}` for nil/blank repo key when no global hook exists.

##### Warnings

- Repo key comparison is case-sensitive. `mybcat-blog` and `MyBCAT-Blog` are different keys.
- Whitespace-only Monday values normalize to nil.

---

##### `Config.validate_repo_semantics(settings)`

> Validates repo config at startup before the first poll tick can dispatch work.

| Property | Value |
|---|---|
| **Idempotent** | Yes, except for logging warnings. |
| **Failure behavior** | Returns `{:error, reason}` for malformed repo entries, unsafe clone URLs, unknown profiles in `allowed_profiles`, forbidden clone/submodule commands in per-repo `after_create`, or missing configured repo column. |
| **Performance envelope** | O(repo count + allowed profile count); no network except optional Monday dropdown metadata fetch when `tracker.repo_column_id` is set. |
| **Side effects** | Logs warnings for drift and legacy-mode footguns. |
| **Retry guidance** | Safe at startup and per-poll config validation. |
| **Data classification** | Internal config; clone URLs may reveal private repo names but no credentials are allowed. |

##### Failure Modes

| Failure | Caller Sees | Recovery |
|---|---|---|
| Clone URL has embedded credentials | `{:error, {:unsafe_clone_url, repo_key, :embedded_credentials}}` | Remove credentials; rely on host-level git auth |
| Clone host not allowlisted | `{:error, {:unsafe_clone_url, repo_key, {:host_not_allowed, host}}}` | Add a reviewed host to `repo_policy.allowed_clone_hosts` or fix typo |
| Unicode/non-ASCII clone URL | `{:error, {:unsafe_clone_url, repo_key, :non_ascii}}` | Replace with ASCII canonical host/path |
| Per-repo hook contains checkout/submodule command | `{:error, {:unsafe_repo_hook, repo_key, reason}}` | Move checkout to `clone_url`; remove submodule use |
| `allowed_profiles` contains unknown profile | `{:error, {:repo_allowed_profile_not_found, repo_key, profile}}` | Fix profile name or add profile |

---

##### `Monday.Adapter.fetch_repo_dropdown_labels(cfg)`

> Fetches and parses `Symphony Repo` dropdown labels for drift validation. Mirrors `SymphonyStatusLabels` metadata-query structure but keeps deactivated labels visible.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure Monday read. |
| **Failure behavior** | `{:error, :repo_column_not_found}` when `tracker.repo_column_id` is set but missing; `{:error, :invalid_settings_str}` for malformed dropdown settings; `{:error, {:unexpected_response, response}}` for schema drift. |
| **Performance envelope** | One small GraphQL query at startup; same complexity class as status-label validation. |
| **Side effects** | None on Monday. |
| **Retry guidance** | Safe; startup refuses only when the configured column itself is missing or metadata is unreadable. |
| **Data classification** | Internal labels; no PHI. |

##### Warnings

- Deactivated repo labels return in `deactivated_labels` rather than being dropped. AW-4 decides dispatch behavior.
- If `tracker.repo_column_id` is nil, this function is not called.

---

##### `Workspace.create_for_issue(issue, worker_host)`

> Creates/reuses the issue workspace, resolves the repo, safely clones known repos, and runs the selected setup hook.

| Property | Value |
|---|---|
| **Idempotent** | Partially. Existing workspace reuse remains unchanged; safe clone + post-clone hook run only when the workspace is newly created. |
| **Failure behavior** | `{:error, {:unknown_repo, repo_key}}`, `{:error, :no_default_repo}`, `{:error, {:workspace_clone_failed, repo_key, status, output}}`, `{:error, {:workspace_hook_failed, "after_create", status, output}}`, or existing workspace path errors. |
| **Performance envelope** | Clone/network dependent; post-clone setup follows existing hook timeout. |
| **Side effects** | Creates directories under `workspace.root`; invokes git; runs trusted post-clone hook. |
| **Retry guidance** | Safe after cleanup. If retry resolves to a different repo, caller must remove the prior failed workspace first (AW-2). |
| **Data classification** | Repo source code and dependency logs; apply existing log redaction policy. |

##### Warnings

- Known repo clone uses `clone_url` only; per-repo `after_create` never clones.
- Global `hooks.after_create` is used only for `repo=<default>`.
- The hook source is live Symphony config, not any WORKFLOW.md in the cloned repo.

---

##### `ProfileResolver.resolve(issue, profiles, default_profile, floor, resolved_repo)`

> Extends Spec 2 profile resolution with repo-level allowlist enforcement.

| Property | Value |
|---|---|
| **Idempotent** | Yes. Pure function over issue/profile/repo inputs. |
| **Failure behavior** | Existing Spec 2 profile errors, plus `{:error, {:profile_not_allowed_on_repo, profile_name, repo_key}}` when a known repo declares `allowed_profiles` and the resolved profile is absent. |
| **Performance envelope** | O(1) profile lookup + O(allowed profile count). |
| **Side effects** | None. |
| **Retry guidance** | Safe. Call after repo re-resolution at every attempt boundary. |
| **Data classification** | Internal config. |

##### Warnings

- The default repo has no repo-level allowlist in v1. Gate HIPAA-sensitive repos by requiring explicit `Symphony Repo` labels and repo entries.
- Empty or missing `allowed_profiles` means all configured profiles are allowed.

#### A.3 Decision Log

##### DL-001: Repo selection via Monday dropdown column (rejected: per-board, per-profile encoding, description-driven)

- **Date:** 2026-05-04
- **Context:** Operator needs to pick a repo per item while keeping one Symphony instance on the Tech Board.
- **Alternatives considered:**
  - Per-item Monday dropdown: Selected.
  - One Symphony per repo: Rejected for v1; heartbeat and startup reconciliation stay one-board focused.
  - Encode repo into profile names: Rejected; couples AI choice to repo choice and weakens repo-level policy.
  - Parse repo from item description: Rejected; too implicit for a privileged input.
- **Consequences:**
  - Enables: explicit operator routing with the same dropdown mental model as Spec 2 profiles.
  - Constrains: repo names become a WORKFLOW.md/Monday label namespace that needs drift validation.
- **Warning:** If reversed to description parsing, a text edit in an issue body becomes a clone-target control plane.

---

##### DL-002: Default-repo fallback to global hooks.after_create when column empty

- **Date:** 2026-05-04
- **Context:** Existing Spec 1/2 items do not have a repo column set and rely on global `hooks.after_create`.
- **Alternatives considered:**
  - Empty repo column falls back to global hook: Selected.
  - Empty repo column skips: Rejected; breaks rollout and in-flight items.
  - Hardcode a repo key for empty values: Rejected; hidden default outside WORKFLOW.md.
- **Consequences:**
  - Enables: backward-compatible rollout with `tracker.repo_column_id` unset or partially populated.
  - Constrains: operators must keep a valid global hook until all legacy/default dispatch is intentionally retired.
- **Warning:** If the fallback is removed before migration, existing `Symphony Ready` rows fail on first post-rollout boot.

---

##### DL-003: Per-repo allowed_profiles allowlist (HIPAA gate)

- **Date:** 2026-05-04
- **Context:** Some MyBCAT repos may touch PHI or sensitive operational data and should not run on every onboarded profile.
- **Alternatives considered:**
  - Per-repo `allowed_profiles`: Selected.
  - Global profile denylist: Rejected; too coarse for mixed repo sensitivity.
  - Monday permissions only: Rejected; Symphony needs defense-in-depth at dispatch.
- **Consequences:**
  - Enables: repo-specific safety gates without duplicating profiles.
  - Constrains: profile renames must update any repo allowlists.
- **Warning:** If reversed, a Monday dropdown edit can route a sensitive repo to an unvetted runtime profile.

---

##### DL-004: Repo re-resolves at retry boundary (mirrors Spec 2 DL-008 profile re-resolve)

- **Date:** 2026-05-04
- **Context:** Spec 2 DL-008 re-resolves profiles on retry; repo selection has the same operator-correction need.
- **Alternatives considered:**
  - Pin repo at first attempt: Rejected; typo correction requires cancel/re-enroll.
  - Re-resolve at retry boundary: Selected.
  - Re-resolve mid-session: Rejected; would mix two repos in one running workspace.
- **Consequences:**
  - Enables: operator correction during backoff.
  - Constrains: retry with repo change must create a fresh workspace and cleanup prior failed workspace.
- **Warning:** If reversed, a bad repo choice remains stuck until manual cancellation.

---

##### DL-005: One Symphony per board; multi-board = Spec 4 territory

- **Date:** 2026-05-04
- **Context:** Multi-repo dispatch might invite multi-board polling, but Spec 1 heartbeat and reconciliation are board-scoped.
- **Alternatives considered:**
  - Keep one board per Symphony: Selected.
  - Watch multiple boards from one instance: Rejected for Spec 3; needs multiple sentinels and board-aware state.
- **Consequences:**
  - Enables: repo routing without destabilizing heartbeat semantics.
  - Constrains: multi-board deployments need Spec 4.
- **Warning:** If reversed casually, two boards can share one process without clear heartbeat ownership or failure isolation.

---

##### DL-006: Operator edits `repos:` map by hand in WORKFLOW.md (no UI)

- **Date:** 2026-05-04
- **Context:** Repo entries contain privileged clone targets and trusted setup hooks.
- **Alternatives considered:**
  - Hand-edit WORKFLOW.md through PR review: Selected.
  - Manage repos from Monday labels alone: Rejected; Monday labels cannot safely hold clone URLs/hooks.
  - Build a UI: Rejected for v1 scope.
- **Consequences:**
  - Enables: git history and PR review for privileged repo config.
  - Constrains: operators must edit YAML, matching Spec 2 `profiles:` practice.
- **Warning:** If reversed to Monday-only config, board editors can mutate clone targets outside git review.

---

##### DL-007: Startup drift validation of repo-key ↔ Monday dropdown labels

- **Date:** 2026-05-04
- **Context:** WORKFLOW.md repo keys and Monday dropdown labels can drift during rollout or cleanup.
- **Alternatives considered:**
  - Warn on drift, refuse only missing configured column: Selected.
  - Refuse on any drift: Rejected; migration needs tolerance.
  - Defer all drift to dispatch-time errors: Rejected; too quiet and scattered.
- **Consequences:**
  - Enables: startup-visible operator feedback without blocking recoverable migrations.
  - Constrains: startup needs one Monday metadata query when `repo_column_id` is set.
- **Warning:** If reversed to no validation, a typo in Monday labels creates per-item skips that can go unnoticed for hours.

---

##### DL-008: Repo selection is privileged input — clone URL must pass host allowlist + safe-clone checks at startup

- **Date:** 2026-05-04
- **Context:** A malicious or sloppy `clone_url` can exfiltrate credentials, spoof `github.com` with Unicode lookalikes, invoke git protocol helpers, pull unreviewed submodules, or bypass validation if the shell hook owns the clone.
- **Alternatives considered:**
  - Format validation only: Rejected; does not stop Unicode host spoofing, allowed-host drift, submodules, git hooks, or hook-level clone bypass.
  - Hardcoded `github.com` only: Rejected as too rigid for future staging/prod host divergence.
  - WORKFLOW.md `repo_policy.allowed_clone_hosts` + exact ASCII host match + safe clone owned by Workspace: Selected.
- **Consequences:**
  - Enables: defense-in-depth on clone targets while preserving reviewed per-environment WORKFLOW.md config.
  - Constrains: repos on new hosts require explicit PR-reviewed allowlist expansion; submodule repos are out of scope.
- **Warning:** If reversed to hook-owned clone or URL format-only validation, a reviewed-looking `clone_url` can be irrelevant while `after_create` clones arbitrary code into an agent workspace.

---

## 7. SPEC.md Concrete Diff Plan (Spec 3 scope only)

### Sections to amend
- §3.1 Main Components: `Workspace Manager` description gains "consults per-issue repo selection from Tracker"; `Issue Tracker Client` description gains "surfaces per-issue repo column value".
- §3.2 Abstraction Levels: `Policy Layer` gains the `repos:` map alongside the `profiles:` map.
- §6 Workflow Configuration: add `tracker.repo_column_id`, `repo_policy.allowed_clone_hosts`, and the `repos:` block.
- §11 Workspace Lifecycle: add safe clone + per-repo post-clone `after_create` resolution rule.

### New sections
- §6.X `repo_policy` + `repos:` map format (mirrors §6.X `profiles:` map from Spec 2).
- §11.X Per-issue repo dispatch rules.

### Removed sections / fields
- None. The global `hooks.after_create` stays as the default fallback (DL-002).

### Renames (global)
- None.

---

## 8. Reference Implementation Deltas

### `elixir/lib/symphony_elixir/config/schema.ex`
- Lines 47-69 (`Tracker.embedded_schema`) and 74-99 (`Tracker.changeset/2` cast list): add optional `repo_column_id: :string`.
- Insert after `Hooks` (lines 270-290) or before top-level `embedded_schema` (line 332): a repo-policy parser with `allowed_clone_hosts` defaulting to `["github.com"]`, plus repo-entry normalization for `%{clone_url, after_create, before_remove, allowed_profiles, default_branch}`.
- Lines 332-343 (top-level `embedded_schema`): add `repo_policy` and `repos` fields/embeds. Keep `profiles` unchanged.
- Lines 423-436 (`changeset/1`) and 438-471 (`parse_profiles/1` pattern): add `parse_repos/1` with the same normalize-then-struct pattern. Repo keys remain strings.
- Lines 542-553 (`resolve_env_value/2`) are intentionally NOT reused for `clone_url`; env-var indirection is forbidden by AW-3.

### `elixir/lib/symphony_elixir/config.ex`
- Lines 29-49 (after `settings!/0`): add `repos/0`, `repo!/1`, `repo_or_default/1`, and `repo_policy/0` getters.
- Lines 94-164 (`validate!/0` / `validate_semantics/1`): add repo semantic validation after profile validation and before returning `:ok`.
- Lines 117-164 insertion anchor: validation must cover `clone_url` ASCII/NFC/form/host allowlist, forbidden credentials/metacharacters/path traversal, forbidden per-repo hook clone/submodule commands, `allowed_profiles` existence, and `repo_column_id` legacy-mode warnings from §2.1/§2.6.
- Lines 166-220 helper area: add helper functions for `blank?`, host allowlist normalization, clone URL parsing, and repo hook validation. Do not parse clone URLs with shell-oriented string splitting; use `URI` for HTTPS and a narrow regex for SSH scp form.

### `elixir/lib/symphony_elixir/monday/adapter.ex`
- Lines 56-65 (`@status_labels_query`): add sibling `@repo_labels_query` named `SymphonyRepoLabels` with the exact response shape in §4.
- Lines 250-269 (`fetch_status_label_id_map/1` pattern): add `fetch_repo_dropdown_labels/1` for startup drift validation; return active and deactivated labels.
- Lines 271-305 (`parse_status_labels/1`, `deactivated_status_label_ids/1`): reuse the `settings_str` parser pattern, but do NOT drop deactivated repo labels. Return them separately for AW-4.
- Lines 307-317 (`collect_column_ids/1`): append `cfg[:repo_column_id]` when present.
- Lines 319-340 (`normalize_items/3`): no new Monday writes; only pass the extended cfg into `Item.from_monday/2`.

### `elixir/lib/symphony_elixir/monday/item.ex`
- Lines 15-23 (`@type config`): add `repo_column_id: String.t() | nil`.
- Lines 39-52 (`%Issue{}` construction): set `repo: repo_value(raw, config[:repo_column_id])`.
- Lines 125-139 (`profile_value/2` helper): add equivalent `repo_value/2` helper that trims whitespace and returns nil for missing/blank values.

### `elixir/lib/symphony_elixir/tracker/issue.ex`
- Lines 9-25 (`defstruct`): add `:repo`.
- Lines 27-42 (`@type t`): add `repo: String.t() | nil`.

### `elixir/lib/symphony_elixir/agent_runner.ex`
- Lines 88-114 (`run_on_worker_host/4`): resolve repo + profile allowlist before `Workspace.create_for_issue/2` so S5 creates no workspace. A valid implementation can call a new `ProfileResolver.resolve(..., resolved_repo)` before workspace creation or have a combined dispatch resolver return both profile and repo.
- Lines 124-142 (`resolve_profile_for_issue/1` call path): extend profile resolution to accept the resolved repo entry and surface `{:profile_resolution_failed, {:profile_not_allowed_on_repo, profile, repo_key}}` without starting a runtime.
- Lines 216-220 (`send_worker_runtime_info/4`): include resolved repo key in worker runtime info sent to the orchestrator/dashboard.

### `elixir/lib/symphony_elixir/workspace.ex`
- Lines 13-31 (`create_for_issue/2`): carry repo key through `issue_context`; log it in workspace errors.
- Lines 210-226 (`maybe_run_after_create_hook/4`): replace direct global-hook lookup with repo resolution. For `{:repo, key, entry}`, run safe clone first, then entry `after_create` if non-blank. For `{:default, default_entry}`, preserve existing global hook behavior. For errors, return `{:error, {:unknown_repo, key}}` or `{:error, :no_default_repo}`.
- Insert before line 210 or near hook helpers: `safe_clone_repo(workspace, repo_entry, worker_host)` that invokes git as argv for local workspaces and remote-safe equivalent for SSH workers, using §2.7 flags. Do not interpolate `clone_url` into a shell command.
- Lines 228-289 (`maybe_run_before_remove_hook/2`): when a known repo entry defines `before_remove`, prefer it over global `hooks.before_remove`; otherwise preserve global behavior.
- Lines 459-481 (`issue_context/1`, `issue_log_context/1`): include `repo` and `repo_default_branch` for hook rendering/logging.

### `elixir/lib/symphony_elixir/profile_resolver.ex`
- Lines 27-43 (`resolve/4`): extend signature to `resolve(issue, profiles, default, floor, resolved_repo)` or add a wrapper with that shape.
- Lines 56-73 (`check_safety_floor/2`): after safety-floor success, enforce `resolved_repo.allowed_profiles` when present. Return `{:error, {:profile_not_allowed_on_repo, profile_name, repo_key}}`.
- Lines 75-88 (`validate_drift/2` pattern): add `validate_repo_drift/2` if drift comparison is kept outside Config.

### `elixir/lib/symphony_elixir/orchestrator.ex`
- Lines 25-47 (`State`): add repo to running-entry metadata only if needed for dashboard snapshots.
- Lines 67-117 (per-profile counter helpers) and 745-758 (`should_dispatch_issue?/4`): ensure multi-repo dispatch still respects Spec 2 §2.5 per-profile caps. Two repos sharing `claude_opus` must contend for the same `claude_opus.max_concurrent` cap.
- Lines 346-403 (`maybe_dispatch/1`): add new error pattern matches for `{:unknown_repo, _}`, `:no_default_repo`, `{:profile_not_allowed_on_repo, _, _}`, and unsafe repo config errors. Log + skip + leave item in `Symphony Ready` unless startup validation mandates boot refusal.
- Lines 859-900 (`dispatch_issue/4` through `do_dispatch_issue_after_phi/4`): keep PHI validation before clone; then perform repo/profile gating before `Task.Supervisor.start_child`.
- Lines 904-943 (`spawn_issue_on_worker_host/5`): store `repo_key` in the running entry so snapshots can render it.
- Lines 1600-1618 (`refresh_runtime_config/1`, `dispatch_slots_available?/2`): include repo/profile cap checks in retry dispatch, not just initial dispatch.

### `elixir/lib/symphony_elixir/status_dashboard.ex`
- Lines 18-24 (running column widths): add fixed width for `REPO` or fold repo into the existing `STAGE`/event area without expanding beyond terminal width.
- Lines 591-631 (`format_running_summary/2`): render `repo=<key>` for known repos and `repo=<default>` for legacy fallback.
- Lines 740-767 (`running_table_header_row/1`, separator): update headers/sizing.
- `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs` lines 46-86 and 197-215: update snapshot fixtures to include repo metadata.

### `elixir/lib/symphony_elixir/prompt_builder.ex`
- Lines 19-22 (`Solid.render!` data map): ensure `issue.repo`, `issue.repo_key`, and `issue.repo_default_branch` are available to Liquid templates. `default_branch` remains metadata-only per AW-5.

### `elixir/WORKFLOW.md`
- Lines 2-30 (`tracker:`): add `repo_column_id: <new_column_id>` when the Monday column exists.
- Insert between lines 35-43 (`hooks:` and `profiles:`): add `repo_policy.allowed_clone_hosts` and top-level `repos:` map with at least 2 example entries (e.g., `mybcat-blog`, `hubspot-daily`) and the existing `MyBcat/symphony` repo as a third entry for backward compat.
- Per-repo `after_create` examples must be post-clone only (`npm ci`, `mix deps.get`, `pip install`), not `git clone`.
- Keep `hooks.after_create` as the default fallback.
- Lines 94-111 (prompt item context): add `Repo: {{ issue.repo }}` and `Default branch: {{ issue.repo_default_branch }}`.

### Tests
- `elixir/test/symphony_elixir/config_schema_test.exs` lines 46-93 and 95-207 — add cases:
  - parses `tracker.repo_column_id`, `repo_policy`, and `repos`
  - rejects env-var clone_url, Unicode/non-ASCII clone_url, host not allowlisted, embedded credentials, path traversal, shell metacharacters, `git clone` in per-repo hook, and `git submodule` in per-repo hook
  - accepts SSH + HTTPS forms for allowlisted hosts
  - warns when `tracker.repo_column_id` is unset but `repos:` is non-empty
  - `allowed_profiles` entries must reference real profile names
- `elixir/test/symphony_elixir/monday/adapter_test.exs` lines 21-37, 167-180, 276-364 — add cases:
  - `Item.from_monday/2` extracts repo column value
  - `collect_column_ids/1` includes repo_column_id when set
  - `SymphonyRepoLabels` query mock + parse active and deactivated labels
- `elixir/test/symphony_elixir/monday/item_test.exs` lines 19-27 and 78-131 — add repo extraction cases mirroring profile extraction.
- `elixir/test/symphony_elixir/profile_resolver_test.exs` lines 24-82 — add cases:
  - `allowed_profiles` allowlist permits valid combo
  - `allowed_profiles` allowlist denies invalid combo
  - empty `allowed_profiles` field permits all profiles
- `elixir/test/symphony_elixir/workspace_and_config_test.exs` lines 7-40, 193-253 — add cases:
  - safe clone uses `clone_url` before per-repo post-clone hook
  - per-repo after_create hook runs after clone
  - intentionally empty per-repo after_create is a no-op after clone
  - empty repo column falls back to global hook
  - unknown repo returns `:unknown_repo` error
  - no-default repo returns `:no_default_repo`
  - clone command does not recurse submodules and disables hooks
- `elixir/test/symphony_elixir/orchestrator_test.exs` lines 224-276 and `elixir/test/symphony_elixir/orchestrator_status_test.exs` lines 24-102 — add dispatch tests for:
  - per-item repo dispatch (S1)
  - empty column fallback (S2)
  - retry with repo flip (S3)
  - unknown repo skip (S4)
  - profile-not-allowed skip (S5)
  - multi-repo concurrent dispatch with two repos on different profiles up to global cap
  - multi-repo concurrent dispatch with two repos on the same capped profile; the second item remains `Symphony Ready` when `profiles.<name>.max_concurrent` is reached (Spec 2 §2.5 interaction)
- `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs` lines 46-86 and 197-215 — add `repo=<key>` snapshot coverage.

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
   - Set `repo_policy.allowed_clone_hosts` (default `[github.com]` is correct for current MyBCAT GitHub repos).
   - Add `repos:` map with one entry per dropdown label.
   - Keep per-repo `after_create` hooks post-clone only; the hook should install dependencies or run repo setup, not run `git clone` or `git submodule`.
   - Keep `hooks.after_create` for legacy fallback.

3. Restart Symphony.

4. Smoke test: create a new Tech Board item with `Symphony Repo: mybcat-blog`, `Symphony Profile: claude_opus`, `Symphony Status: Symphony Ready`. Verify dispatch logs show safe clone of `repos.mybcat-blog.clone_url`, then the correct repo's post-clone `after_create` hook running.

---

## 10. Out of Scope for Spec 3

- Multi-board support (one Symphony per N boards). Future Spec 4.
- Per-repo secret injection (e.g., `HUBSPOT_TOKEN` per hubspot-daily). Future Spec 5.
- Git submodule checkout. Future spec must add an explicit submodule host allowlist before enabling it.
- A terminal UI or web UI for editing the `repos:` map. Operator edits WORKFLOW.md by hand.
- Repo-aware token accounting / cost attribution. Per-runtime token accounting (Spec 2 §2.4) stays as is.
- Per-repo concurrency caps. Existing per-profile + global caps (Spec 2 §2.5) suffice.
- Rule-based routing (e.g., "if title contains 'blog' route to mybcat-blog"). Manual dropdown only.
- Auto-creating Monday dropdown labels from WORKFLOW.md `repos:` keys. Operator-controlled.

---

## 11. Ambiguity Warnings — All Locked

Per Ankit's 2026-05-04 instruction, all five open ambiguities are locked. The implementing agent treats these as binding constraints.

### AW-1 — Empty repo column and no global default — LOCKED: SKIP + WARN
- **Decision:** When `tracker.repo_column_id` is set, the per-issue repo column is empty, and global `hooks.after_create` is unset/blank, skip dispatch and emit `{:no_default_repo, issue.identifier}`. No hardcoded fallback.
- **Rationale:** Mirrors Spec 2's "skip + warn over silent fallback" posture. Loud failure beats silently creating an empty workspace and running an agent in the wrong repo context.
- **Implementation:** `Config.repo_or_default(nil)` returns `{:error, :no_default_repo}`; Orchestrator leaves the item in `Symphony Ready` and logs operator-visible remediation.

### AW-2 — Retry resolves to a different repo — LOCKED: CLEAN PRIOR FAILED WORKSPACE
- **Decision:** When a retry boundary resolves to a different repo than the prior failed attempt, cleanup the prior attempt's workspace before creating the new repo workspace.
- **Rationale:** Prevents mixed-repo file trees and unbounded workspace accumulation. The cleanup happens only after the prior attempt has ended; the system never deletes a workspace for a currently running session because a Monday column changed mid-session.
- **Implementation:** Store prior attempt `repo_key` in retry metadata; if the next resolved repo differs, run the normal workspace cleanup path before safe-cloning the new repo.

### AW-3 — `clone_url` env-var indirection — LOCKED: LITERAL URLS ONLY
- **Decision:** `repos[*].clone_url` does NOT support `$ENV_VAR` or template indirection in v1. URLs are literal WORKFLOW.md values.
- **Rationale:** Clone targets are privileged inputs and need git-reviewed, diff-visible values. Staging/prod git-host divergence is handled by per-environment WORKFLOW.md plus `repo_policy.allowed_clone_hosts`, not hidden environment expansion.
- **Implementation:** Repo parser rejects clone URLs beginning with `$` or containing template syntax. The only env-var config precedent that remains valid is secret handling such as `$MONDAY_API_TOKEN`.

### AW-4 — Deactivated Monday repo labels — LOCKED: KNOWN IF WORKFLOW ENTRY EXISTS
- **Decision:** A deactivated Monday dropdown label whose WORKFLOW.md `repos:` entry still exists is treated as known-repo; existing items dispatch normally. Boot-time drift warning names the deactivated label.
- **Rationale:** Deactivation prevents new selection in the Monday UI, but existing in-flight items can still carry that text value. Do not strand work solely because an operator deactivated the label before cleaning up WORKFLOW.md.
- **Implementation:** `SymphonyRepoLabels` parsing returns deactivated labels separately. Drift validation warns `repo label "<name>" is deactivated on Monday but still present in repos:`. Dispatch succeeds if `repos[name]` exists; dispatch returns `{:unknown_repo, name}` if the WORKFLOW entry is removed.

### AW-5 — `default_branch` semantics — LOCKED: METADATA ONLY
- **Decision:** `default_branch` is metadata-only. It is exposed to the agent via `{{ issue.repo_default_branch }}` and Symphony does NOT enforce the branch on PR creation or merge.
- **Rationale:** Branch correctness stays in the prompt/review model established by Spec 1 and Spec 2. Enforcing PR base inside Symphony would require GitHub-aware policy and merge validation that belongs in a future GitHub integration spec.
- **Implementation:** `PromptBuilder` includes the value in Liquid context when present. No GitHub API call or `gh pr` interception is added.

---

## 12. Implementation Sequencing

1. **Boot-time validation first.** Land Config.Schema parser changes + clone_url host allowlist/safe-clone validation + drift detection before touching dispatch path. Failing here is loud and recoverable.
2. **Tracker layer next.** Item.from_monday + Adapter.collect_column_ids + Tracker.Issue.repo. No behavior change to dispatch yet.
3. **ProfileResolver + Workspace.** Wire repo allowlist enforcement before clone, then safe clone + post-clone hook resolution. This is where dispatch behavior actually changes.
4. **Orchestrator + StatusDashboard.** Surface the new error paths + dashboard rendering.
5. **WORKFLOW.md update + Tech Board operator setup.** Last — only after the code is merged.
6. **Smoke test with one repo (e.g., mybcat-blog) before adding more.**

Mirrors Spec 1 + Spec 2 sequencing: parser → tracker layer → dispatch layer → operator-visible surface.

---

## 13. Test Plan Summary

| Layer | Cases | File |
|---|---|---|
| Config parsing | `repo_policy` + `repos:` shape valid; clone_url accepts SSH/HTTPS allowlisted hosts; rejects env-var indirection, Unicode/non-ASCII spoofing, embedded credentials, shell metacharacters, path traversal, host not allowlisted; per-repo hook rejects `git clone`/`git submodule`; allowed_profiles entries reference real profiles | `config_schema_test.exs` |
| Startup validation | repo drift warnings; deactivated-label warning; missing configured repo column boot refusal; `tracker.repo_column_id` unset logs legacy-mode warning when `repos:` is non-empty | `config_schema_test.exs`, `monday/adapter_test.exs`, `application_test.exs` (or whichever covers boot) |
| Monday read path | Item.from_monday surfaces repo; collect_column_ids includes repo_column_id; SymphonyRepoLabels parses active + deactivated labels | `monday/adapter_test.exs`, `monday/item_test.exs` |
| ProfileResolver | allowlist permits, denies, defaults | `profile_resolver_test.exs` |
| Workspace | safe clone runs before post-clone hook; no-op/empty per-repo after_create; empty repo column falls back; unknown repo errors; no-default repo errors; submodules/hooks disabled in clone command | `workspace_and_config_test.exs` |
| Orchestrator dispatch | S1 happy path; S2 fallback; S3 retry-flip with prior workspace cleanup; S4 unknown_repo; S5 profile_not_allowed creates no workspace; S8 Unicode host refusal; S9 empty hook; multi-repo concurrent on different profiles up to global cap | `orchestrator_test.exs`, `orchestrator_status_test.exs` |
| Spec 2 cap interaction | Two repos on the same profile respect `profiles.<name>.max_concurrent`; second item remains `Symphony Ready` when the profile cap is reached even if global capacity remains | `orchestrator_test.exs` |
| Dashboard | running rows render `repo=<key>` and `repo=<default>` without breaking narrow terminal layout | `status_dashboard_snapshot_test.exs` |

Targeted run: `mix test test/symphony_elixir/{config_schema,monday/adapter,monday/item,profile_resolver,workspace_and_config,orchestrator,orchestrator_status,status_dashboard_snapshot}_test.exs`. Full suite must remain at the prior baseline (post-Spec-2: 339 tests / 45 pre-existing failures / 2 skipped vs. main; new tests +N, no new failures).

---
