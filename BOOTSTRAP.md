# Symphony — Bootstrap

This guide walks a fresh Linux or macOS host from `git clone` to a running
Symphony orchestrator. There are two supported paths:

- **Native** — install Erlang + Elixir via [mise](https://mise.jdx.dev/) and run
  the escript directly on the host. Recommended for local development on
  Fedora / Ubuntu / macOS workstations.
- **Docker** — build the bundled `Dockerfile` and run via `docker compose`.
  Recommended for VPS / server deployments, or when you want isolation
  between Symphony and the host environment.

Symphony itself ships **no** model CLIs. Claude / Codex / Gemini are
installed and authenticated on the host — Symphony just shells out to them.
This keeps interactive browser-based OAuth flows working and avoids baking
per-user credentials into images.

---

## 1. Prerequisites

Pick one of the two paths below.

### 1a. Native path

| Tool   | Why                                                      | Install                                       |
|--------|----------------------------------------------------------|-----------------------------------------------|
| `git`  | Cloning Symphony + cloning per-issue repos via `hooks.after_create`. | OS package manager.                           |
| `mise` | Pins Erlang `28` + Elixir `1.19.5-otp-28` per `elixir/mise.toml`.    | `bin/setup.sh` will install it for you, or `curl https://mise.run \| sh`. |
| One of `claude` / `codex` / `gemini` CLIs | The actual coding agents Symphony orchestrates. | See vendor docs (linked below). |

### 1b. Docker path

| Tool             | Why                                       | Install                          |
|------------------|-------------------------------------------|----------------------------------|
| `git`            | Clone Symphony.                           | OS package manager.              |
| `docker`         | Builds + runs the Symphony image.         | https://docs.docker.com/engine/install/ |
| `docker compose` | Compose v2 plugin (`docker compose`, not the legacy `docker-compose`). Bundled with Docker Desktop and most modern Engine installs. | Same install. |
| One of `claude` / `codex` / `gemini` CLIs on the host | Symphony invokes them; the container does not bundle them. | See vendor docs. |

> **Note (Docker on Linux):** the bundled `docker-compose.yml` uses
> `network_mode: host`. That is required so the OAuth redirect URLs the
> coding agents hand out — `http://localhost:<port>/...` — round-trip
> through the same loopback stack the host browser hits. Host networking is
> Linux-only for native Docker; on macOS / Windows the Docker VM does not
> share the host network, so prefer the **native path** there.

---

## 2. Clone and install

```bash
git clone https://github.com/MyBcat/symphony.git
cd symphony
```

### 2a. Native path

Run the bootstrap script. It is idempotent — safe to re-run after pulling
new commits.

```bash
./bin/setup.sh
```

What it does, in order:

1. Creates `.env` from `.env.example` if missing.
2. Installs `mise` to `~/.local/bin/mise` if it is not already on `PATH`.
3. Trusts `elixir/mise.toml` and installs the pinned Erlang / Elixir.
4. Runs `mix deps.get` and `mix escript.build` inside `elixir/`.
5. Prints next-step instructions.

After it finishes, make sure `~/.local/bin` is on your shell `PATH` for
future sessions. On `bash`/`zsh`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc   # or ~/.zshrc
```

### 2b. Docker path

```bash
docker compose build
```

The build is a multi-stage process: a builder stage compiles the escript
with the same Erlang/Elixir versions pinned in `elixir/mise.toml`; the
runtime stage carries only the BEAM runtime plus the produced binary.

You can pin different versions at build time if `elixir/mise.toml` drifts:

```bash
docker compose build --build-arg ELIXIR_VERSION=1.19.5 --build-arg OTP_VERSION=28.1.4
```

---

## 3. Configure WORKFLOW.md

Symphony's only configuration source is `elixir/WORKFLOW.md`. There is no
`.env`-shaped runtime config; secrets are pulled in via env vars but
behavioural config (tracker, repo URLs, agent limits, prompt templates)
all live in YAML front matter inside this file.

Open `elixir/WORKFLOW.md` and update at minimum:

- `tracker.kind` — `monday` or `linear`.
- For Monday: `tracker.board_id` and the status-column mapping.
- For Linear: `tracker.project_slug`.
- `tracker.api_key` — set to `$MONDAY_API_TOKEN` (Monday) or
  `$LINEAR_API_KEY` (Linear). Never paste the literal token here; it would
  be committed.
- `workspace.root` — where per-issue workspaces are written.
- `hooks.after_create` — the `git clone <repo> .` line that seeds each new
  workspace with your codebase.
- `agent.max_concurrent_agents` and `agent.max_turns` — concurrency caps.
- `codex.command` — the actual command Symphony shells out to. Defaults to
  `codex app-server`. Use `$CODEX_BIN` if you want to pin to a specific
  binary path.

A minimal Monday-tracker example:

```yaml
---
tracker:
  kind: monday
  board_id: 8173460438
  api_key: $MONDAY_API_TOKEN
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 5
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Monday item {{ issue.identifier }}.

Title: {{ issue.title }}

Body: {{ issue.description }}
```

### Secrets — do not paste tokens into committed files

Populate `.env` (which is gitignored) with the env-var values referenced
from `WORKFLOW.md`. On MyBCAT machines, generate `.env` directly from AWS
Secrets Manager rather than typing tokens into the file:

```bash
/mnt/d_drive/repos/finances/scripts/secret_exec.py --emit-env-file .env mybcat/symphony
```

`secret_exec.py` reads the `mybcat/symphony` namespace in AWS Secrets
Manager and writes the resulting `KEY=VALUE` pairs to `.env`. Re-run any
time you rotate a secret. The script is the recommended path for HIPAA
operating-environment compliance because it keeps secrets off shell
history, terminal scrollback, and disk in any other form.

For non-MyBCAT installs, edit `.env` by hand. Only commit `.env.example`.

---

## 4. CLI auth (claude / codex / gemini)

Each coding agent ships its own browser-based OAuth flow. Run the login
once per host user; auth state is cached in the user's home directory and
re-used by subsequent runs.

| CLI              | Login command                            | Auth state path           |
|------------------|------------------------------------------|---------------------------|
| Claude Code      | `claude /login`                          | `~/.claude/`              |
| Codex            | `codex login`                            | `~/.codex/`               |
| Gemini           | `gemini auth login`                      | `~/.config/gemini/`       |

If Symphony is running inside Docker, the bundled `docker-compose.yml`
already mounts those three host directories into the container, so a host
login carries through automatically.

The CLIs themselves still need to be reachable on the container's `PATH`.
The compose file mounts `${SYMPHONY_HOST_CLI_DIR:-./bin}` at
`/opt/symphony/cli`, which is on `PATH` ahead of system binaries. Drop
symlinks or thin wrappers to your host installs in there:

```bash
mkdir -p bin
ln -sf "$(command -v claude)"  bin/claude
ln -sf "$(command -v codex)"   bin/codex
ln -sf "$(command -v gemini)"  bin/gemini
```

(Adjust `SYMPHONY_HOST_CLI_DIR` in `.env` if you'd rather point at
`~/.local/bin` or another directory directly.)

---

## 5. Run

### 5a. Native run

The escript requires an explicit acknowledgement flag — Symphony Elixir is
a low-key engineering preview and intentionally has no guardrails on the
spawned coding-agent CLIs.

```bash
./elixir/bin/symphony ./elixir/WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Optional flags:

- `--logs-root <path>` — write logs under a different directory (default `./log`).
- `--port <port>` — start the optional Phoenix LiveView dashboard at
  `http://localhost:<port>/`.

Symphony will:

1. Tail the configured tracker for candidate work.
2. Create a per-issue workspace under `workspace.root`.
3. Invoke the configured coding-agent CLI inside that workspace.
4. Update the tracker as work progresses.

Stop with `Ctrl-C`.

### 5b. Docker run

```bash
docker compose up
```

This starts the `symphony` service in the foreground using
`./elixir/WORKFLOW.md` as the workflow file. To run a smoke check that
just exercises the escript:

```bash
docker compose run --rm symphony --help
```

The escript does not implement an explicit `--help` switch; it falls
through to the usage banner. That is expected — the smoke test is checking
that the binary inside the image actually executes.

To pass additional flags through to Symphony:

```bash
docker compose run --rm symphony /workspace/WORKFLOW.md --port 4000 \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

---

## Troubleshooting

| Symptom                                                         | Likely cause                                                                                         |
|-----------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `setup.sh` fails on `mise install` with "no precompiled binary" | Your platform/architecture is not in mise's prebuilt set. Install Erlang + Elixir directly via your package manager and re-run. |
| `docker compose build` fails on `mix deps.get`                  | No network from the build sandbox. Configure your Docker daemon's HTTP proxy or use `docker compose build --network host`. |
| `docker compose up` cannot find `claude` / `codex` / `gemini`   | The CLI is not in `${SYMPHONY_HOST_CLI_DIR:-./bin}`. Drop a symlink there as shown in §4.            |
| `Workflow file not found: /workspace/WORKFLOW.md`               | The compose file expects `elixir/WORKFLOW.md` to exist. Make sure you ran `git clone` from the repo root. |
| Symphony exits immediately with the red acknowledgement banner  | You forgot the `--i-understand-that-this-will-be-running-without-the-usual-guardrails` flag.         |
| Auth flow prompts in container but redirect URL fails           | Host networking is required so OAuth callbacks resolve. On macOS/Windows, prefer the native path.    |

---

## What this guide does not cover

- Kubernetes manifests (deferred; Symphony is single-host today).
- systemd unit files (deferred).
- CI/CD pipeline configuration.
- Modifying the Elixir source itself — see `elixir/AGENTS.md` for that.
