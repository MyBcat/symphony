---
cost_cap:
  daily_usd: 1000
dashboard:
  enabled: true
  port: 4000
# Spec M-6 PHI gate. `strict` flips PHI-tainted items to "Cancelled" and posts
# a `## Symphony PHI Refusal` workpad with finding *kinds* only (never raw
# matched text). `warn` logs and continues dispatch. Strict is the refuse
# default; flip explicitly to `warn` only when you understand the trade-off.
# Boot-time scan refuses to start Symphony in strict mode if any active or
# handoff-state item has PHI findings.
phi_gate:
  mode: strict
tracker:
  kind: monday
  api_token: $MONDAY_API_TOKEN
  endpoint: https://api.monday.com/v2
  board_id: 8173460438
  identifier_prefix: "SYM"
  symphony_status_column_id: "color_mm30c3vb"
  profile_column_id: "dropdown_mm30zep"
  pr_column_id: "link_mm30ak49"
  heartbeat_item_id: 11909898073
  heartbeat_ttl_ms: 60000
  complexity_budget_per_tick: 500
  backoff_factor: 2.0
  max_polling_interval_ms: 60000
  # Symphony M-4a (SYM-11942134820): doubles as the per-issue retry cap and
  # the cap on consolidated `## Symphony Failures` history entries. Once an
  # issue hits this many consecutive failures the orchestrator transitions it
  # to Cancelled and posts ONE consolidated Update listing every captured
  # attempt — instead of one Update per attempt. Stalled-issue restarts also
  # count against this cap.
  failure_ttl_count: 5
  # Spec M-7 AC3: how many consecutive 5xx/timeout Tracker responses before
  # the orchestrator logs "outage entry" and pauses new dispatches. The
  # orchestrator keeps running through the outage; this only controls the
  # operator-facing alert threshold. Default 5.
  outage_threshold: 5
  priority_column_id: "status_1_mkm9bt8j"
  description_column_id: null
  branch_column_id: null
  labels_column_id: "dropdown_mkwbsh98"
  # Symphony Repo column (Spec 3). Labels match keys in the top-level `repos:`
  # map below. Empty column on an item = use legacy hooks.after_create default.
  repo_column_id: "dropdown_mm322hqn"
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
# Per-repo dispatch entries (Spec 3). Each key maps to one Monday Symphony Repo
# dropdown label. clone_url is required; after_create / before_remove / 
# allowed_profiles / default_branch are optional. When tracker.repo_column_id
# is set and an item resolves to a key here, this entry's after_create runs
# instead of the legacy hooks.after_create below. When the column is empty for
# an item, the legacy hooks.after_create below is used as the default.
#
# Auto-merge fields (Spec 4 §2.8a) are OPT-IN per repo:
#
#   auto_merge_on_codex_pass: true      # default false
#   auto_merge_max_lines: 500           # default 500; PRs >= this require human review
#   auto_merge_pass_pattern: "..."      # default "NO BLOCKING ISSUES"; regex literal
#
# When all three of (a) auto_merge_on_codex_pass=true, (b) Codex review output
# matches auto_merge_pass_pattern, (c) PR diff is < auto_merge_max_lines lines,
# AND the PR base is main/master AND the operator hasn't flipped the item
# during review, Symphony runs `gh pr merge --merge --auto`. The default for
# every repo is FALSE (human approval required). HIPAA-touching repos MUST
# stay opt-out unless the operator independently verifies the PR contents are
# PHI-safe. The symphony repo itself MUST stay opt-out — its blast radius
# (orchestrating other repos) is too high for unattended auto-merge.
repos:
  symphony:
    clone_url: https://github.com/MyBcat/symphony.git
    # Symphony auto-merge: hard-coded OFF. Spec 4 §2.8a constraint #5: the
    # symphony repo MUST stay opt-out — a bad merge here has cross-repo blast
    # radius (Symphony orchestrates real AI sessions writing real code into
    # real repos). Operator merges manually after `/codex:rescue` per the
    # convention in `.claude/CLAUDE.md`.
    auto_merge_on_codex_pass: false
    # Symphony performs the clone itself per Spec 3 §2.2. after_create is
    # post-clone setup only and MUST NOT contain `git clone`. Tolerant of
    # missing gcc / kerl dependencies in container/VPS contexts, while still
    # surfacing unrelated mix deps.get failures.
    after_create: |
      if ! command -v mise >/dev/null 2>&1; then
        echo "after_create(symphony): mise absent; skipping mix deps.get"
      elif ! command -v gcc >/dev/null 2>&1; then
        echo "after_create(symphony): gcc absent; skipping mix deps.get"
      else
        deps_log="${TMPDIR:-/tmp}/symphony-deps.$$"
        if (cd elixir && mise trust && mise exec -- mix deps.get) >"$deps_log" 2>&1; then
          cat "$deps_log"
          rm -f "$deps_log"
        else
          deps_status=$?
          cat "$deps_log"
          if grep -Eiq "(gcc|kerl|C compiler|compiler.*not found|build-essential|make: .*not found|cc: .*not found)" "$deps_log"; then
            echo "after_create(symphony): tolerated gcc/compiler setup failure from mix deps.get"
            rm -f "$deps_log"
            true
          else
            rm -f "$deps_log"
            exit "$deps_status"
          fi
        fi
      fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  client-portal:
    clone_url: https://github.com/MyBcat/client-portal.git
    after_create: |
      if [ -f package.json ]; then
        npm ci
      fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  hubspot-funnel-site:
    clone_url: https://github.com/MyBcat/hubspot-funnel-site.git
    after_create: |
      if [ -f package.json ]; then
        npm ci
      fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
    # Per-repo secrets (Spec 4 §2.4 / SYM-11923119480). Each entry is
    # "<aws_secret_id>:<env_var>[:<json_field>]". Symphony resolves them via
    # secret_exec.py at workspace bootstrap, writes to .env.symphony (mode
    # 0600), and wraps after_create + adapter port spawn to source the file.
    # Boot fails fast if any path is unresolvable. Uncomment after the secret
    # is created in AWS Secrets Manager via `secret-store create`.
    # secrets:
    #   - "mybcat/integrations/api-keys/hubspot:HUBSPOT_TOKEN"
  carlos_low_vision:
    clone_url: https://github.com/MyBcat/carlos_low_vision.git
    # Pure-Python research/orchestration repo, no package manifest at root.
    # No setup needed beyond the clone.
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  # Auto-discovered from /mnt/d_drive/repos local clones with MyBcat GitHub
  # remotes. All default to the safe profile allowlist + auto_merge OFF.
  # Operator must explicitly review + flip auto_merge_on_codex_pass to true
  # per repo before unattended merging is allowed.
  call-analysis:
    clone_url: https://github.com/MyBcat/call-analysis.git
    after_create: |
      if [ -f requirements.txt ]; then pip install -r requirements.txt || true; fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  eyecloud-ai:
    clone_url: https://github.com/MyBcat/eyecloud-ai.git
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  finance_seat:
    clone_url: https://github.com/MyBcat/finance_seat.git
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  hal:
    clone_url: https://github.com/MyBcat/hal.git
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  hubspot-cleaner:
    clone_url: https://github.com/MyBcat/hubspot-cleaner.git
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  insurance-auto:
    clone_url: https://github.com/MyBcat/insurance-auto.git
    after_create: |
      if [ -f package.json ]; then npm ci || true; fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  mso:
    clone_url: https://github.com/MyBcat/mso.git
    after_create: |
      if [ -f requirements.txt ]; then pip install -r requirements.txt || true; fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  OB-mybcat:
    clone_url: https://github.com/MyBcat/OB-mybcat.git
    after_create: |
      if [ -f requirements.txt ]; then pip install -r requirements.txt || true; fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  patient_cordinator:
    clone_url: https://github.com/MyBcat/patient_cordinator.git
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  pivot:
    clone_url: https://github.com/MyBcat/pivot.git
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  sales-agent:
    clone_url: https://github.com/MyBcat/sales-agent.git
    after_create: |
      if [ -f requirements.txt ]; then pip install -r requirements.txt || true; fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
  # CVC marketing site — owned by AnkitClassicVision (personal account), not
  # MyBcat org. Local clone at /mnt/d_drive/repos/cvc_grow/cvc-new.
  cvc-new-site:
    clone_url: https://github.com/AnkitClassicVision/cvc-new-site.git
    after_create: |
      if [ -f package.json ]; then npm ci || true; fi
    allowed_profiles:
      - codex_gpt55_xhigh
      - claude_opus
      - claude_sonnet
      - gemini_long_context
    default_branch: main
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
profiles:
  claude_opus:
    kind: claude
    max_concurrent: 2
    cost_per_input_token_usd: 0.000015
    cost_per_output_token_usd: 0.000075
    claude:
      command: "claude --print --output-format stream-json --input-format stream-json"
      model: "claude-opus-4-7"
      permission_mode: "acceptEdits"
      allowed_tools: ["Read", "Edit", "Write", "Skill", "TodoWrite", "Bash(git:*)", "Bash(gh:*)", "Bash(make:*)", "Bash(mix:*)", "Bash(mise:*)", "Bash(npm:*)", "Bash(pip:*)", "Bash(pytest:*)"]
  claude_sonnet:
    kind: claude
    max_concurrent: 6
    cost_per_input_token_usd: 0.000003
    cost_per_output_token_usd: 0.000015
    claude:
      command: "claude --print --output-format stream-json --input-format stream-json"
      model: "claude-sonnet-4-6"
      permission_mode: "acceptEdits"
      allowed_tools: ["Read", "Edit", "Write", "Skill", "TodoWrite", "Bash(git:*)", "Bash(gh:*)", "Bash(make:*)", "Bash(mix:*)", "Bash(mise:*)", "Bash(npm:*)", "Bash(pip:*)", "Bash(pytest:*)"]
  codex_gpt55_xhigh:
    kind: codex
    max_concurrent: 4
    cost_per_input_token_usd: 0.000010
    cost_per_output_token_usd: 0.000030
    codex:
      command: "codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
      approval_policy: never
      thread_sandbox: workspace-write
  gemini_long_context:
    kind: gemini
    max_concurrent: 3
    cost_per_input_token_usd: 0.00000125
    cost_per_output_token_usd: 0.000005
    gemini:
      command: "gemini --model gemini-2.5-pro --output-format stream-json --sandbox"
agent:
  default_profile: codex_gpt55_xhigh
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
# E2E nightly harness (Spec M-9 / SYM-11923096576). All keys are optional;
# env vars SYMPHONY_E2E_BOARD_ID and SYMPHONY_E2E_MONDAY_TOKEN take precedence
# at runtime and must be set as GitHub Actions secrets before the nightly-e2e
# workflow will run. Uncomment and populate once the sandbox board is created.
#
#   e2e:
#     test_board_id: <sandbox-board-id>  # MUST NOT equal 8173460438
#     timeout_s: 600                     # max seconds Symphony runs per smoke (default 600)
#     max_nonsynth_items: 5              # refuse if > N non-[E2E] items exist on sandbox board
#     alert_webhook: ""                  # optional Slack/webhook URL posted on nightly failure
codex:
  # Codex CLI (app-server mode) gates its JSON-RPC `remoteControl` interface
  # behind project trust. Workspaces under `workspace.root` whose `.codex/`
  # directory is not listed in `~/.codex/config.toml`'s `[projects]` table
  # cause Codex to emit a `configWarning` plus
  # `remoteControl/status/changed status=disabled` and never respond to
  # `initialize`, manifesting as `:response_timeout` in the adapter.
  #
  # Symphony's `Codex.Adapter.start_session/2` calls
  # `SymphonyElixir.Codex.ProjectTrust.ensure_trusted/1` before launching
  # the Codex process, which writes a `[projects."<canonical-workspace>"]`
  # block with `trust_level = "trusted"` to `~/.codex/config.toml`. The path
  # is overridable via the `SYMPHONY_CODEX_CONFIG_TOML` env var (used by the
  # test suite to redirect writes away from the operator's real config).
  # Only paths that pass `validate_workspace_cwd/2` (i.e. canonical paths
  # strictly under `workspace.root`) are auto-trusted; the SYM-11923259980
  # constraint "Do NOT auto-trust arbitrary paths" is enforced by the
  # validation upstream.
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Monday.com item `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the item is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the item remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Item context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current Symphony status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

This is an unattended orchestration session. Never ask a human to perform follow-up actions. You do NOT have access to Monday.com — Symphony manages all Monday writes based on your event stream and workspace files.

Work only in the provided repository copy. Do not touch any other path.

## Phase 1 — PLAN (always do this first)

Before changing any code:

1. If the description is ambiguous OR scope spans 3+ files OR there are design choices to make, invoke the `superpowers:brainstorming` skill to explore intent and tradeoffs. Skip only for trivial bug fixes or one-line config changes.
2. Invoke `superpowers:writing-plans` to produce a structured plan. Write the result to `_symphony_plan.md` in the workspace root with:
   - Goal (1 sentence)
   - Acceptance criteria (bulleted)
   - Files to touch (paths, with rationale per file)
   - Out of scope (explicit)
   - Risks / unknowns

**Commit and push `_symphony_plan.md` to your work branch BEFORE making any code or test changes.** The plan is the contract — committing it first means the "plan vs reality" delta in the summary is meaningful.

## Phase 2 — EXECUTE

3. Follow the plan. For new behavior or bug fixes, invoke `superpowers:test-driven-development` — write failing test first, watch it fail, then implement.
4. After significant changes, invoke `superpowers:requesting-code-review` to self-review before opening the PR.

(Sub-agent spawning via the `Task` tool is intentionally NOT enabled in the agent's allowed_tools allowlist until per-sub-agent workspace sandboxing is verified — Codex review on PR #27 flagged this. Treat all work as single-process for now.)

## Phase 3 — SHIP

6. **Git remote and PR target — strict rules.** Symphony has already cloned the repository and configured `origin`. The ONLY valid push target is `origin`. You MUST NOT:
   - run `gh repo create` (no permission)
   - change the remote URL with `git remote set-url`
   - push to a different remote / invented repo name
   - run `git push --force` or `--force-with-lease`
   To inspect the remote, run `git remote -v` and use that exact URL. Run `gh repo view --json nameWithOwner` to confirm.
7. **Branch naming.** Use `symphony/{{ issue.identifier }}/attempt-1` (or attempt-N for retry contexts). Push to `origin`. Never push to `main` or `master`.
8. **Open the PR.** Run `gh pr create --base main --head <your-branch>` against `origin`. Title and body must reference `{{ issue.identifier }}`. Body should summarize the plan and acceptance criteria. Symphony detects the PR URL in your output and writes it to Monday.
9. **Write `_symphony_summary.md`** in the workspace root with:
   - What changed (one paragraph)
   - **Plan vs reality** — what differed from `_symphony_plan.md` and why
   - Test plan executed
   - Open concerns or follow-ups
   - The PR URL (redundancy if URL detection misses it)

## Stopping rules

10. Only stop early for a true blocker (missing required auth/permissions/secrets that aren't addressable by the rules above). If blocked, write the blocker to `_symphony_summary.md` and exit with a clear final message.
11. Do not exit voluntarily until the PR is open or you are explicitly blocked.
