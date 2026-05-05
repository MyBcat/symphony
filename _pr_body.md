## Summary

Spec 4 §M-1 portability artifacts so Symphony can run on a fresh Fedora / Ubuntu / macOS host or VPS with a single bootstrap command — replaces the founder-toolbox-only path.

- **Dockerfile** — multi-stage. Builder uses `hexpm/elixir` pinned to `elixir/mise.toml` (Erlang 28.1.4 + Elixir 1.19.5; spec said "Erlang 26" but the repo runs Erlang 28 and the spec forbids editing `elixir/*`, so the Dockerfile matches the codebase). Runtime is `erlang:28.1.4-slim` with the produced escript on `PATH` and `tini` as PID 1 to reap CLI subprocess zombies. `claude` / `codex` / `gemini` CLIs are NOT bundled — `/opt/symphony/cli` is on `PATH` so host wrappers can be mounted.
- **docker-compose.yml** — service `symphony` with `WORKFLOW.md` mounted RO, workspace bind mount, `env_file: .env`, `network_mode: host` so OAuth callbacks resolve, plus host bind mounts for `~/.codex` / `~/.claude` / `~/.config/gemini` auth state and a CLI-bin mount.
- **bin/setup.sh** — POSIX, idempotent host bootstrap. Detects/installs mise, runs `mise install` per `elixir/mise.toml`, then `mix deps.get` + `mix escript.build`, materialises `.env` from `.env.example`, and prints next-step instructions for tracker config + CLI auth.
- **BOOTSTRAP.md** — 5 sections (prereqs, clone+install, configure WORKFLOW.md, CLI auth, run) covering both native and Docker paths on Linux + macOS. Documents AWS Secrets Manager / `secret_exec.py` as the recommended HIPAA-aware secrets workflow.
- Supporting: `.dockerignore`, `.gitignore`, `.env.example`.

No `elixir/*` source touched — pure packaging per the spec constraint.

Refs: `docs/superpowers/specs/2026-05-04-symphony-production-readiness.md` (Spec 4); Spec 1 DL-005; Spec 2; Spec 3.

## Test plan

- [ ] `docker compose build` succeeds on a clean checkout. _(Not run in this sandbox — no docker; reviewer should run.)_
- [ ] `docker compose run --rm symphony --help` returns escript usage text. _(Reviewer.)_
- [x] `bin/setup.sh` is POSIX (`#!/bin/sh`, `set -eu`, no bashisms) and idempotent: every step checks state before mutating. Mode preserved at `100755` in the index.
- [x] Artifacts read end-to-end and match the acceptance criteria in the Monday item.
- [ ] Walk through `BOOTSTRAP.md` on a fresh Fedora / Ubuntu / macOS host. _(Reviewer.)_

## Out of scope (deferred per spec)

- Kubernetes manifests
- systemd unit files
- CI/CD pipeline changes
- Any change to the Elixir source

Closes SYM-11923119084.
