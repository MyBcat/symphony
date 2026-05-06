# SYM-11941611091 — Codex adapter rewrite for codex CLI 0.128 (`exec --json`)

## Goal

Rewrite `SymphonyElixir.Codex.Adapter` to drive Codex via `codex exec --json` JSONL stream-output instead of the deprecated `codex app-server` JSON-RPC stdio protocol that silently fails on Codex 0.128.

## Acceptance criteria

- WORKFLOW.md `codex_gpt55_xhigh` profile uses `codex exec --json` (not `codex … app-server`).
- `elixir/lib/symphony_elixir/codex/adapter.ex` parses Codex 0.128 JSONL `ThreadEvent` shapes (`thread.started`, `turn.started`, `turn.completed`, `turn.failed`, `error`, `item.{started,updated,completed}`).
- The adapter spawns one `codex exec --json` subprocess per `send_turn/3` invocation (one-shot per turn).
- Adapter emits the same internal Symphony events as before (`:session_started`, `:turn_completed`, `:turn_failed`, `:startup_failed`, plus `:notification` and `:tool_call_*` for visibility) so `AgentRunner.observe_codex_message/3` keeps firing without changes.
- `runtime_native_tokens/1` returns Codex-native shape including `input`, `output`, `total`, `cached_input`, `reasoning_output`. M-3 cost cap (`AgentRunner.extract_token_delta_from_usage/1`) keeps reading `input_tokens`/`output_tokens` off the `:usage` map on `:turn_completed`.
- `passes_safety_floor?/2` semantics unchanged (`thread_sandbox` ≤ floor and `approval_policy == "never"`).
- `elixir/test/symphony_elixir/codex/adapter_test.exs` rewritten with fakes that emit the new JSONL stream; existing 23-test coverage replaced with equivalent or better coverage of:
  - workspace cwd / symlink-escape rejection
  - sandbox floor violation refusal
  - normal turn (thread.started → turn.completed) success path with token capture
  - turn.failed error propagation
  - error event propagation
  - stderr / stdout secret scrubbing
  - malformed JSONL line handling
  - SSH-backed remote worker invocation
  - explicit thread_sandbox passthrough into the spawned command
  - configurable command override (profile-config `command` overrides legacy `codex.command`)
- `SymphonyElixir.Codex.ProjectTrust` module + its test file deleted (no longer referenced; exec mode does not gate on project trust).
- `mix test --no-start elixir/test/symphony_elixir/codex/` is green.
- One PR opened against `origin` (`MyBcat/symphony`) on branch `symphony/SYM-11941611091/attempt-1`.

## Files to touch

- **Rewrite** `elixir/lib/symphony_elixir/codex/adapter.ex` — new exec-based protocol parser, new event mapping, drops JSON-RPC machinery and ProjectTrust call. Keeps validation guards, command resolution, secrets wrapping, SSH support, sandbox floor check, AgentRuntime callbacks.
- **Rewrite** `elixir/test/symphony_elixir/codex/adapter_test.exs` — fakes simulate `codex exec --json` JSONL output instead of JSON-RPC.
- **Modify** `elixir/WORKFLOW.md` — replace `codex_gpt55_xhigh.codex.command` and the legacy `codex.command` at the bottom of the file with `codex exec --json …` invocations. Sandbox/approval moved into `-c` overrides.
- **Modify** `elixir/lib/symphony_elixir/config/schema.ex` — change `Codex.command` default from `"codex app-server"` to `"codex exec --json"` so the default profile lines up with the new adapter.
- **Delete** `elixir/lib/symphony_elixir/codex/project_trust.ex` — no longer needed (exec mode runs without `remoteControl` gating).
- **Delete** `elixir/test/symphony_elixir/codex/project_trust_test.exs` — covers the deleted module.
- **Possibly modify** `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` — leave as-is; exec mode does not invoke `item/tool/call` JSON-RPC handshakes, so this becomes dead code only callable from legacy paths. Keep file (still compiles) but verify no `dialyzer` warnings; if it becomes unused entirely, leave a single-line `@moduledoc` note. (See "Open concerns" — fall-back is to leave the file untouched.)
- **Smoke** `elixir/lib/symphony_elixir/agent_runner.ex` — read-only verify the `:codex` event arms match the new event names. The plan does NOT modify AgentRunner; it asserts compatibility.

## Out of scope

- Codex MCP / app-server long-running daemon mode (rejected by the spec).
- AgentRuntime behaviour changes — the contract is unchanged.
- Sandbox tightening beyond what `codex exec` provides via `-c sandbox_mode=…`.
- Claude / Gemini adapters — untouched.
- Trust-file write paths — the existing `~/.codex/config.toml` is preserved (other tools may still read it). Only the Symphony-side ProjectTrust call is removed.

## Risks / unknowns

- **Cannot run `codex exec --json` live in this orchestration session** — the bash allowlist denies `codex …`, and `WebFetch` / `mcp` tools also need approval. The protocol shape is taken from the upstream source `openai/codex` repo, file `codex-rs/exec/src/exec_events.rs` (downloaded via `gh api repos/openai/codex/contents/...` which is allowlisted) — that's the canonical Rust-side `serde::Serialize` impl, so JSONL keys are guaranteed to match. If the version in this commit lags 0.128 it would be wrong, but the shape has been stable since exec --json shipped.
- **stdin EOF on Erlang ports** — Erlang doesn't expose "close stdin only". Solution: write the prompt to a temp file inside the workspace (`<workspace>/.symphony/codex_prompt_<unique>.txt`) and redirect stdin in the bash wrapper (`< /path/to/prompt.txt`). The temp file is deleted on session stop.
- **Multi-turn state** — `codex exec` is one-shot. Multi-turn (`AgentRunner.do_run_agent_turns`) currently keeps the same `session` across turns. The new adapter treats `session` as stateless config; each `send_turn` spawns a fresh `codex exec --json` process. Continuity comes from workspace state (git branch, committed code, workpad). This matches Spec 2's stateless turn model.
- **Stderr noise from codex** — codex may emit non-JSON warnings to stderr. The existing `:stderr_to_stdout` Port option folds these into the same byte stream; non-JSON lines get logged via `Logger.warning` after secret-scrubbing (preserved from the existing adapter).
- **Token telemetry** — `turn.completed` carries usage as `{input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens}`. `AgentRunner.extract_token_delta_from_usage/1` reads `input_tokens` / `output_tokens` keys, so the existing M-3 path keeps working. No CostMeter changes needed.
- **`CODEX_COMPANION_SESSION_ID` parent-session interference** — the parent Claude Code may have spawned a `cxc-*` codex broker with this env var set. Strip it (and `CODEX_HOME` overrides, etc.) from the spawn env so child codex uses a clean per-workspace state.
- **`SYMP_TEST_CODEx_TRACE` env var name mixing** — existing tests reference both `SYMP_TEST_CODEx_TRACE` and `SYMP_TEST_CODex_TRACE` (typo'd casing). The rewrite tests use a single canonical name.

## Plan vs reality boundary

The plan is the contract. Any deviation gets called out in `_symphony_summary.md` Plan vs Reality.
