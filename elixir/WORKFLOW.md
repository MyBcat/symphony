---
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
  failure_ttl_count: 5
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
repos:
  symphony:
    clone_url: https://github.com/MyBcat/symphony.git
    # Symphony performs the clone itself per Spec 3 §2.2. after_create is
    # post-clone setup only and MUST NOT contain `git clone`.
    after_create: |
      if command -v mise >/dev/null 2>&1; then
        cd elixir && mise trust && mise exec -- mix deps.get
      fi
    allowed_profiles:
      - claude_opus
      - claude_sonnet
    default_branch: main
  client-portal:
    clone_url: https://github.com/MyBcat/client-portal.git
    after_create: |
      if [ -f package.json ]; then
        npm ci
      fi
    allowed_profiles:
      - claude_opus
      - claude_sonnet
    default_branch: main
  hubspot-funnel-site:
    clone_url: https://github.com/MyBcat/hubspot-funnel-site.git
    after_create: |
      if [ -f package.json ]; then
        npm ci
      fi
    allowed_profiles:
      - claude_opus
      - claude_sonnet
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
codex:
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

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. You do NOT have access to Monday.com. Symphony manages all Monday writes (status transitions, workpad updates, PR linkage) based on observing your event stream and the workspace files you write.
3. Do the engineering work needed to satisfy the item description. Work only in the provided repository copy. Do not touch any other path.
4. Open a pull request via `gh pr create` when the work is ready for human review. Symphony detects the PR URL in your output and writes it to Monday.
5. At completion, write a markdown summary to `_symphony_summary.md` in the workspace root. Include:
   - One-paragraph description of what changed
   - Test plan executed
   - Any open concerns or follow-ups
   - Symphony will fold this into the Monday workpad on completion.
6. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, write the blocker to `_symphony_summary.md` and exit with a clear final message.
7. Do not exit voluntarily until the PR is open or you are explicitly blocked.
