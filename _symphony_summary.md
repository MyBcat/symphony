# SYM-11941611091 — Summary

## What changed

The Codex runtime adapter was rewritten to talk Codex CLI 0.128's
`codex exec --json` JSONL protocol instead of the deprecated `codex
app-server` JSON-RPC stdio protocol. Each `send_turn/3` invocation now
spawns a fresh `codex exec --json` process, pipes the prompt over stdin
(local) or as a positional argument (remote SSH), and parses
`ThreadEvent` JSONL frames (`thread.started`, `turn.started`,
`turn.completed`, `turn.failed`, `error`, `item.{started,updated,completed}`)
until the turn terminates. Symphony's existing event vocabulary
(`:session_started`, `:turn_completed`, `:turn_failed`,
`:startup_failed`, `:tool_call_*`, `:notification`, `:malformed`) is
preserved, so `AgentRunner.observe_codex_message/3` and the M-3 cost-cap
token math (`AgentRunner.extract_token_delta_from_usage/1`) continue
firing without changes. The `Codex.ProjectTrust` module + tests were
deleted because exec mode does not gate on `remoteControl/status`. The
`codex_gpt55_xhigh` profile and legacy `codex.command` in WORKFLOW.md
moved to `codex exec --json` with `-c` overrides for sandbox/approval/
model. Downstream tests in `core_test.exs` and `agent_runner_test.exs`
that spun fake codex binaries against the old JSON-RPC stdin shape were
migrated to emit JSONL events on stdout.

## Plan vs reality

The plan in `_symphony_plan.md` matched the executed work with three
deltas worth flagging:

1. **Remote (SSH) prompt passing.** The plan said "stream prompt over
   stdin via SSH". Implementation found that Erlang ports cannot
   half-close stdin (closing the port kills the SSH connection before
   codex finishes reading). Switched to a shell-escaped positional
   argument inside the remote bash command. Tradeoff: ARG_MAX caps
   prompts at ~128 KB (well above Symphony's typical ~50 KB), and the
   prompt is briefly visible in `ps aux` on the worker. Local mode
   still uses the temp-file + stdin redirect approach because it has
   no such constraint. Documented in `adapter.ex` `spawn_port/3`
   remote branch.

2. **Multi-turn continuation.** The plan acknowledged this as a known
   risk; the implementation made it explicit. Each `send_turn/3` =
   one fresh `codex exec --json` process. AgentRunner's existing
   continuation logic still loops up to `agent.max_turns`, but each
   loop iteration is a brand-new Codex thread. Continuity comes from
   workspace state (committed code, branch, workpad) — Codex has no
   knowledge of prior turns. The continuation test in
   `core_test.exs` was updated to assert this new shape (one process
   spawn per turn with the continuation guidance text in stdin).

3. **`SymphonyElixir.Codex.DynamicTool` left in place.** The plan
   considered deletion. The module is now dead code (no callers) but
   has its own test (`test/symphony_elixir/dynamic_tool_test.exs`)
   that still passes (asserts `tool_specs() == []` and `execute/3`
   returns unsupported). Left intact to keep the diff focused on the
   protocol switch. A follow-up cleanup PR can remove it.

The plan's other deltas — schema default flip, env-var scrub,
sandbox-floor preservation, JSONL event mapping, runtime token shape —
all landed exactly as specified.

## Test plan executed

- `mix test --no-start test/symphony_elixir/codex/adapter_test.exs` →
  **25/25 green**. Coverage spans: workspace cwd / symlink-escape
  rejection (2), happy path with token capture (2), token telemetry
  + AgentRunner usage extraction (2), turn.failed propagation, fatal
  `error` event, exit-without-turn_completed, stderr scrubbing,
  malformed JSONL, partial-line buffering, item events
  (command_execution × 2, agent_message), stream_events buffer
  contract, profile-config command override, sandbox floor refusal,
  remote SSH launch, and 6 `passes_safety_floor?/2` cases.
- `mix test --no-start` (full suite) → **705 tests, 44 failures, 8
  skipped**. Baseline on `main` is 730 / 45 / 8 — net `-25` tests
  (project_trust removal + adapter consolidation) and `-1` failure.
  None of the 44 remaining failures are caused by this change. Each
  was confirmed pre-existing by running the same suite on `main` with
  my changes stashed: same Phoenix LiveView / snapshot-fixture /
  HeartbeatTest / Monday-tracker timing flakes appear in both.
- Live smoke test: **NOT executed**. The orchestration sandbox blocks
  invocation of the real `codex` binary (bash allowlist refuses
  `codex --version`). The protocol shape was verified against the
  upstream Rust source `openai/codex/codex-rs/exec/src/exec_events.rs`
  (downloaded via `gh api`) which is the canonical
  `serde::Serialize` definition for the JSONL stream. End-to-end
  smoke (real model dispatch, real PR open, M-8 transition) is left
  for the post-merge verification step described in
  `.claude/CLAUDE.md` — operator runs the smoke after `/codex:rescue`
  passes.

## Open concerns / follow-ups

- **`SymphonyElixir.Codex.DynamicTool`** (and its test) is now
  unreachable. Cleanup candidate.
- **Live smoke** for the new `codex_gpt55_xhigh` profile must be run
  manually (orchestration session can't invoke `codex` directly).
  Recommended: dispatch a tiny test Monday item with
  `codex_gpt55_xhigh`, watch `symphony.log.1` for
  `{"type":"thread.started", ...}` and the
  `:turn_completed`/`:usage` token write to CostMeter.
- **ARG_MAX cap on remote prompts.** Symphony's `PromptBuilder` output
  for typical issues is well under the ~128 KB Linux ARG_MAX, but a
  pathological issue with multi-MB description text could fail at
  `execve()` time. Worth a follow-up if it ever bites: ship the
  prompt to remote via `cat | base64 -d` decoded server-side, or
  upgrade to remote temp file via a two-step `ssh + scp`.
- **`agent_runner_test.exs:1203` "repo allowed_profiles blocks"**
  failure was already present on `main`. It crashes on a real
  `git clone` over SSH (PERMISSION denied by publickey) and is a
  test-infrastructure issue unrelated to this change.

## PR

Branch: `symphony/SYM-11941611091/attempt-1`.
PR URL: https://github.com/MyBcat/symphony/pull/28
