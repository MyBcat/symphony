# Symphony — Codex Shipping Finalizer (M-0c-D)

**Status:** Draft for implementation
**Date:** 2026-05-06
**Authors:** Ankit Patel + Claude (Opus 4.7, 1M context). Root-cause diagnosis by Codex CLI via `/codex:rescue` on canary SYM-11684552415 (cvc-new-site, codex_gpt55_xhigh, ~1h44m runtime, 28 sessions, 0 PRs).
**Sequencing:** M-0c. **Depends on M-0a (codex 0.128 protocol), M-0b (codex prompt scaffolding), M-4a/M-4b (failure-update consolidation)** all merged at HEAD.
**Modifies:** New `lib/symphony_elixir/finalizer.ex`; hook in `lib/symphony_elixir/agent_runner.ex` after the agent run completes; new `test/symphony_elixir/finalizer_test.exs`.
**Does NOT modify:** WORKFLOW.md prompt template (M-0c-A), `workspace.ex` re-entry branch setup (M-0c-B), continuation-turn prompt threading (M-0c-C). Those are separate sub-tickets we may file later if D alone doesn't close the gap.
**Skills applied:** `agent_spec_writer` (format), `codex:rescue` (diagnosis).

| Locked decision | Source |
|---|---|
| Finalizer runs from Symphony's process, NOT from inside the codex sandbox | DL-001 (codex's own sandbox blocked git push + GitHub DNS during canary) |
| Finalizer pushes + opens PR using whatever git/gh credentials are available to the Symphony daemon (host-level `gh auth` for ankit; same path the codex review uses) | DL-002 |
| Finalizer is idempotent: re-running on a workspace that already has a pushed branch + open PR is a no-op | DL-003 |
| Finalizer runs at the end of EVERY agent run completion path, including: normal completion, max_turns, retries, and Cancelled. NOT on crashes (those go through `finalize_crash`) | DL-004 |
| Finalizer never force-pushes, never rewrites history, never deletes branches | DL-005 (matches Spec 4 PR safety) |
| Finalizer logs success/failure to Symphony disk log + posts a Monday update via the existing `## Symphony Run Summary` consolidated marker (does NOT spawn a new marker) | DL-006 |
| If git push fails (DNS, auth, rejected ref), finalizer logs the failure and surfaces it to the M-4a summary; does NOT loop or retry from inside the finalizer | DL-007 |
| Finalizer's per-issue work is gated on the issue's profile being a codex profile. Claude/Gemini profiles already ship correctly via their adapters; finalizer is a no-op for them in v1 | DL-008 |

---

## 1. System Overview

The canary on SYM-11684552415 ran 28 codex sessions over 1h44m and never opened a PR. Diagnosis: codex chose `git format-patch` after hitting `.git/index.lock` errors and GitHub DNS failures inside the codex sandbox. Even with a perfect prompt, the sandbox + DNS path can keep blocking git push.

The fix: at the end of every agent run, Symphony — running as the host process with the operator's real `gh auth` credentials — checks whether the work branch has a PR open on the target repo. If not, Symphony does the `git push -u origin <branch>` + `gh pr create` itself. This works regardless of what happened inside the codex session, because Symphony bypasses the sandbox entirely.

Out of scope for M-0c-D:
- M-0c-A: WORKFLOW.md prompt strengthening (Codex provided the literal text; deferred unless D alone is insufficient).
- M-0c-B: workspace.ex re-entry branch setup (deferred; D doesn't need the work branch to be pre-set because finalizer detects whatever branch has commits).
- M-0c-C: continuation-turn prompt threading (deferred; same reason as A).
- Any change to Workpad write contract (M-4a/M-4b own that).

---

## 2. Behavioral Contract

### 2.1 When finalizer runs

- **When** an agent run completes via the normal `Completed agent run` path AND the issue's profile is a codex runtime, **the system** invokes `Finalizer.finalize/2` synchronously before the orchestrator transitions the issue to its next state.
- **When** an agent run hits `max_turns` AND the issue's profile is a codex runtime AND the orchestrator is about to transition to retry or terminal, **the system** invokes `Finalizer.finalize/2`.
- **When** the issue is already in a terminal state (e.g., the operator flipped it to Cancelled mid-run), **the system** does NOT invoke the finalizer. The crash path (`finalize_crash`) does not invoke the finalizer either.
- **When** the issue's profile is `claude_*` or `gemini_*`, **the system** does NOT invoke the finalizer. Those adapters already open PRs via their own runtime patterns.

### 2.2 What the finalizer does

- **When** invoked, **the finalizer** runs entirely from the Symphony process (not from inside the codex sandbox), in the issue's workspace directory at `~/code/symphony-workspaces/SYM-<id>`.
- **The finalizer** uses `System.cmd/3` for all git/gh shell-outs with explicit `cd:` opt and a 30s timeout per call.
- **The finalizer** logs the start, each shell command's exit status, and the end with a structured `:finalizer_result` tuple.
- **The finalizer** scrubs any token-like substrings (regex match for `ghp_`, `Bearer `, `sk-`) from logged stderr before writing to Symphony's disk log.

### 2.3 Decision tree

The finalizer's decision tree, in order:

1. **Workspace exists?** If `~/code/symphony-workspaces/SYM-<id>` doesn't exist, finalizer is a no-op (logs `{:noop, :no_workspace}`).
2. **Any local commits beyond the base branch?** Run `git rev-list --count <base>..HEAD`. If 0, finalizer is a no-op (logs `{:noop, :no_commits}`).
3. **Detect work branch.** Run `git branch --show-current`. If the current branch is the base branch (e.g., `main`), the finalizer creates the canonical work branch with `git switch -C symphony/SYM-<id>/attempt-1` and proceeds.
4. **Push the branch.** Run `git push -u origin <work_branch>`. Capture exit status + stderr.
   - If push succeeds, proceed to step 5.
   - If push fails with `Updates were rejected because the remote contains work that you do not have locally` (non-fast-forward), the finalizer does NOT force-push. It logs the failure, returns `{:error, {:push_rejected_non_ff, branch}}`, and surfaces to M-4a summary.
   - If push fails for any other reason (DNS, auth, etc.), logs `{:error, {:push_failed, reason}}`.
5. **Detect target repo.** Run `gh repo view --json nameWithOwner` from the workspace cwd. The output is the GitHub `owner/name`. If this fails, log `{:error, {:gh_repo_view_failed, reason}}` and stop.
6. **Check for existing PR.** Run `gh pr list --repo <owner/name> --head <work_branch> --json number,url --state open`. If a PR already exists, log `{:noop, :pr_already_open, pr_url}` and stop.
7. **Open the PR.** Run `gh pr create --repo <owner/name> --base <base> --head <work_branch> --title "<title>" --body "<body>"`. Title format: `<SYM-id>: <issue title truncated to 64 chars>`. Body format includes:
   - First line: `Closes Monday item <SYM-id>.`
   - Second line: `Symphony profile: <profile_name>.`
   - Third line: `<issue description if available, truncated to 1000 chars>`
   - Sentinel footer: `<!-- symphony-finalizer:M-0c-D -->`
8. **Log result.** On success: `{:ok, pr_url}`. The orchestrator's M-4a summary path picks this up and includes the PR URL in the consolidated `## Symphony Run Summary` update.

### 2.4 Idempotency

- **When** the finalizer is invoked twice on the same workspace (e.g., a retry), the second invocation MUST detect the existing pushed branch (step 4 will be a no-op fast-forward) and the existing PR (step 6 will short-circuit) and return `{:noop, :pr_already_open, pr_url}`.
- **The finalizer** never deletes the work branch or the workspace.

### 2.5 What the finalizer does NOT do

- It does NOT commit anything. If there are uncommitted changes in the workspace at finalizer time, those are codex's failure to commit; finalizer logs `{:error, {:uncommitted_changes, files}}` and stops without staging or committing on codex's behalf. (Rationale: finalizer is a shipping helper, not an editor.)
- It does NOT modify `.symphony/attempt-*` directories or any patch files codex left behind.
- It does NOT call any external APIs other than git and gh.
- It does NOT touch Monday directly. The orchestrator's M-4a path is the single Monday writer; finalizer only returns a structured tuple to the caller.

---

## 3. Decision Log (DL)

| ID | Decision | Rationale |
|---|---|---|
| DL-001 | Run from Symphony process, not codex sandbox | Codex sandbox + DNS were the actual blockers in the canary; bypassing them is the whole point of D |
| DL-002 | Use host-level `gh auth` (same as codex review path) | Symphony already shells out via flatpak-spawn --host for the codex review subagent; finalizer reuses that path |
| DL-003 | Idempotent — safe to re-run | Retries and stranded-TTL paths can fire the finalizer multiple times; non-idempotent would create duplicate PRs |
| DL-004 | Skip on crash + skip on Cancelled | finalize_crash already owns those paths; double-firing finalizer would race with the cleanup |
| DL-005 | Never force-push, never delete branches | Matches Spec 4 PR safety §2.8; force-push has cross-repo blast radius |
| DL-006 | Surface result via M-4a summary, not new Monday marker | M-4a contract is "ONE consolidated summary on retry-cap"; finalizer feeds into that, not around it |
| DL-007 | No retry loop inside finalizer | Symphony already has the orchestrator's retry machinery; finalizer is a single-shot helper |
| DL-008 | Codex-only in v1 | Claude (claude --print + commit hooks) and Gemini already ship; only codex needs this rescue path |

---

## 4. Acceptance Work (AW)

| ID | Task | Owner |
|---|---|---|
| AW-001 | Add `lib/symphony_elixir/finalizer.ex` implementing `finalize/2` (workspace-path, issue-context tuple) per §2.3 decision tree | implementing agent |
| AW-002 | Add `lib/symphony_elixir/finalizer.ex` private helpers: `git/3`, `gh/3` (System.cmd wrappers with timeout + scrubber), `detect_branch/1`, `count_commits/2`, `find_pr/3` | implementing agent |
| AW-003 | Hook in `agent_runner.ex` at the post-`Completed agent run` path: invoke `Finalizer.finalize/2` for codex profiles only, after the agent run concludes and BEFORE the orchestrator's retry decision | implementing agent |
| AW-004 | Hook in `agent_runner.ex` at the post-`Reached agent.max_turns` path: same finalizer invocation | implementing agent |
| AW-005 | Verify `finalize_crash/3` does NOT call the finalizer (the crash path goes Cancelled directly per M-4b) | implementing agent |
| AW-006 | Surface `Finalizer.finalize/2` result tuples to the orchestrator's M-4a summary builder so the consolidated `## Symphony Run Summary` update includes the PR URL on success or the failure reason on error | implementing agent |
| AW-007 | Tests in `test/symphony_elixir/finalizer_test.exs` covering: success path (commits → push → PR created), no-commits path (no-op), uncommitted-changes path (error tuple), PR-already-open path (no-op), gh repo view failure path, push rejected non-ff path | implementing agent |
| AW-008 | Tests use `Mox`-style stubbing of `git/3` and `gh/3`. Real System.cmd is not invoked in unit tests | implementing agent |
| AW-009 | Add a Cred-style log test verifying the scrubber regex catches `ghp_`, `Bearer `, `sk-` token shapes in logged stderr | implementing agent |
| AW-010 | Update `WORKFLOW.md` if needed: confirm no behavior currently depends on codex shipping the PR itself. The codex prompt block from M-0b can stay (still useful as a hint); the finalizer is the safety net | implementing agent |
| AW-011 | Run `mix test --no-start` and confirm all new tests pass + no existing tests regress | implementing agent |
| AW-012 | Open PR. Codex review via `/codex:rescue` per repo `.claude/CLAUDE.md` merge gate | implementing agent |
| AW-013 | After merge, rebuild escript + restart daemon. Verify on next codex run that the finalizer fires and opens a real PR | operator (Ankit) |

---

## 5. Test Plan

| ID | Scenario | Expected outcome |
|---|---|---|
| T-001 | Codex run completes, work branch has 2 commits, no PR exists yet | Finalizer pushes branch, opens PR, returns `{:ok, pr_url}` |
| T-002 | Codex run completes, no commits beyond base | Returns `{:noop, :no_commits}`; no push; no PR |
| T-003 | Codex run completes, uncommitted changes in workspace | Returns `{:error, {:uncommitted_changes, file_count}}`; no push; no PR |
| T-004 | Workspace already has pushed branch + open PR (rerun scenario) | Returns `{:noop, :pr_already_open, pr_url}`; no duplicate push or PR |
| T-005 | `git push` fails with non-fast-forward | Returns `{:error, {:push_rejected_non_ff, branch}}`; no force-push attempted |
| T-006 | `gh repo view` fails (auth missing, network down) | Returns `{:error, {:gh_repo_view_failed, reason}}`; no PR attempted |
| T-007 | Codex profile name is `claude_opus`, not a codex profile | Finalizer is a no-op; returns `{:noop, :not_a_codex_profile}` |
| T-008 | Issue is already in terminal state Cancelled when finalizer would fire | Finalizer is a no-op; returns `{:noop, :issue_terminal}` |
| T-009 | Stderr contains `ghp_test_AAAAAAAA` | Logged stderr has token replaced with `[REDACTED]` |
| T-010 | Finalizer is invoked twice for the same issue (M-4a retry path) | Second invocation is fully idempotent: same `{:noop, :pr_already_open}` result |

---

## 6. Implementation Constraints

- Elixir 1.19.5 + OTP 26 (matches host runtime).
- All shell-outs go through `System.cmd/3` with `:stderr_to_stdout` false (we want stderr separately for scrubbing) and an explicit `:cd` opt.
- All shell-outs have a 30s timeout. Finalizer total time budget: ~2 minutes worst case (4 × 30s).
- No new dependencies. Reuse existing `Logger`, existing `Secrets.Scrubber` if it has a token-redact helper; otherwise add one in finalizer.
- No env var inspection in production code. Tests can override the binary paths via `Application.get_env(:symphony_elixir, :finalizer_git_bin, "git")` etc., default to `git` and `gh` from PATH.
- Module path: `SymphonyElixir.Finalizer`.

---

## 7. Ambiguity Warnings

- **AW-1: gh auth source.** Symphony today launches via `secret_exec.py` with `MONDAY_API_TOKEN` injected. It does NOT inject a `GH_TOKEN` or `GITHUB_TOKEN`. The host's `~/.config/gh/hosts.yml` has the operator's gh auth. **Assumption:** the Symphony process inherits read access to the operator's gh auth via the file system, same as the codex review path does. If this is wrong (e.g., Symphony runs as a different user), the finalizer's `gh` calls will fail and we need to inject a token via secret_exec. Operator should verify by running `gh auth status` from inside the Symphony process's environment.
- **AW-2: base branch detection.** The finalizer assumes the issue's repo has `main` as the default branch. cvc-new-site does. If a future repo uses `master` or another default, finalizer needs to detect via `gh repo view --json defaultBranchRef`. **Recommendation:** detect dynamically in step 5.
- **AW-3: branch-name collisions.** If the operator already created a branch named `symphony/SYM-<id>/attempt-1` for an unrelated reason and committed to it, finalizer would push that branch's commits — possibly not what we want. **Mitigation:** the diagnostic detects this via `git rev-list --count <base>..HEAD` returning 0 if the work branch's commits are ALL behind the base (impossible scenario); for the realistic case (codex-authored commits only), the branch shape matches what we want.

---

## 8. References

- `/codex:rescue` diagnostic on this canary: see prior turn in this session
- M-0a PR #28 (codex 0.128 protocol) — `lib/symphony_elixir/codex/adapter.ex`
- M-0b PR #30 (codex prompt scaffolding) — `lib/symphony_elixir/workspace.ex`, `lib/symphony_elixir/prompt_builder.ex`, `WORKFLOW.md` codex block
- M-4a PR #29 (consolidated retry-cap summary) — `lib/symphony_elixir/orchestrator.ex`
- M-4b PR #31 (no per-crash workpad) — `lib/symphony_elixir/agent_runner.ex` `finalize_crash/3`
- Spec 4 §2.8 PR safety — sets the no-force-push convention
