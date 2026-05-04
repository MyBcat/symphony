# Symphony repo-specific rules

Inherits everything from `/mnt/d_drive/repos/.claude/CLAUDE.md` and `~/.claude/CLAUDE.md`. The rules below are additive and only apply inside this repo.

## Merge gate — /codex:rescue before any merge to main

Before running `gh pr merge` (or any equivalent merge action) on this repo:

1. Run `/codex:rescue` against the PR with the same brief as the implementing session: state the PR number, branch, head commit, files changed, and the specific risks to scrutinize (correctness, caching, error paths, test coverage, regressions).
2. Wait for Codex to return. If Codex finds issues, apply its fixes (or have it apply them) and verify with `mix test --no-start` on the targeted file(s) at minimum, full suite if the change is broad.
3. Only after a clean Codex pass + green tests, merge to main using the existing pattern (`gh pr merge <N> --merge --subject "Merge: <description> (#N)"`).

This applies to **every** PR on Symphony, regardless of size. Symphony orchestrates real AI sessions writing real code into real repos — a bad merge here has cross-repo blast radius. The Spec 1, Spec 2, and dispatch-fix PRs all benefited from Codex review and surfaced real issues that were not caught by tests alone.

**Exception path:** none for normal work. If the situation requires bypassing this gate (e.g., emergency revert, hotfix that has independent verification), it must be called out explicitly to the user before the merge runs.

## Convention reminders

- Spec docs live at `docs/superpowers/specs/<YYYY-MM-DD>-symphony-<descriptor>.md`. Match the format of Spec 1 + Spec 2 when adding new specs.
- All Monday writes go through `SymphonyElixir.Monday.Adapter` (Spec 1 DL-005). No other module touches Monday.
- WORKFLOW.md is the single source of truth for tracker config, profiles, repos. No env vars or hardcoded URLs in the elixir code.
- The `agent_spec_writer` skill is the right tool when scoping a new feature here. It enforces the format Spec 1 + Spec 2 already follow.
