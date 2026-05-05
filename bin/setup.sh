#!/bin/sh
# bin/setup.sh — idempotent host bootstrap for Symphony.
#
# Goals:
#   1. Detect or install mise (https://mise.jdx.dev/) for runtime version
#      management.
#   2. Install the Erlang / Elixir versions pinned in elixir/mise.toml.
#   3. Fetch deps and build the escript at elixir/bin/symphony.
#   4. Materialise an .env file from .env.example so docker-compose works.
#   5. Print clear next steps for CLI auth, WORKFLOW.md edits, and tracker
#      tokens.
#
# This script is POSIX-only (no bashisms). It is safe to re-run; every step
# checks the current state before mutating anything.
#
# Exit codes:
#   0   success or already-up-to-date
#   1   unrecoverable error (logged before exit)
#   2   blocked on host prerequisite the user must install manually

set -eu

# ---- Helpers ---------------------------------------------------------------

log()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARN: %s\n' "$*" >&2; }
die()  { printf '[setup] ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve repo root from this script's location so the script can be invoked
# from any working directory.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ELIXIR_DIR="$REPO_ROOT/elixir"

cd "$REPO_ROOT"

# ---- 1. Sanity-check the tree ---------------------------------------------

[ -f "$ELIXIR_DIR/mix.exs" ]    || die "expected $ELIXIR_DIR/mix.exs — run from a Symphony checkout"
[ -f "$ELIXIR_DIR/mise.toml" ]  || die "expected $ELIXIR_DIR/mise.toml — runtime versions are pinned there"
[ -f "$ELIXIR_DIR/WORKFLOW.md" ] || die "expected $ELIXIR_DIR/WORKFLOW.md — Symphony's config source of truth"

# ---- 2. .env scaffolding ---------------------------------------------------

if [ ! -f "$REPO_ROOT/.env" ]; then
    if [ -f "$REPO_ROOT/.env.example" ]; then
        cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
        log "created .env from .env.example (populate with real values before running)"
    else
        : > "$REPO_ROOT/.env"
        log "created empty .env"
    fi
else
    log ".env already present — leaving it alone"
fi

# ---- 3. Detect / install mise ---------------------------------------------

if ! have mise; then
    log "mise not found on PATH — installing via the official installer"
    if have curl; then
        curl -fsSL https://mise.run | sh
    elif have wget; then
        wget -qO- https://mise.run | sh
    else
        die "neither curl nor wget is installed; install one or install mise manually" 2
    fi

    # The official installer drops mise at $HOME/.local/bin/mise. Prepend it
    # for the rest of this script run.
    if [ -x "$HOME/.local/bin/mise" ]; then
        PATH="$HOME/.local/bin:$PATH"
        export PATH
    fi

    have mise || die "mise still not on PATH after install — see https://mise.jdx.dev/getting-started.html" 2
    log "mise installed; add \"$HOME/.local/bin\" to your shell PATH for future sessions"
else
    log "mise already installed: $(mise --version)"
fi

# ---- 4. Trust + install pinned tool versions ------------------------------

# `mise trust` is interactive by default; --yes makes it idempotent.
log "trusting $ELIXIR_DIR/mise.toml"
( cd "$ELIXIR_DIR" && mise trust --yes >/dev/null )

log "installing pinned Erlang/Elixir from elixir/mise.toml (this can take a while on first run)"
( cd "$ELIXIR_DIR" && mise install )

# Surface what's actually pinned, so the user can see what got installed.
( cd "$ELIXIR_DIR" && mise current ) | sed 's/^/[setup] mise current: /'

# ---- 5. Build the escript -------------------------------------------------

log "fetching mix deps"
( cd "$ELIXIR_DIR" && mise exec -- mix deps.get )

log "building escript -> elixir/bin/symphony"
( cd "$ELIXIR_DIR" && mise exec -- mix escript.build )

ESCRIPT="$ELIXIR_DIR/bin/symphony"
[ -x "$ESCRIPT" ] || die "escript build did not produce $ESCRIPT"

log "escript built: $ESCRIPT"

# ---- 6. Next steps --------------------------------------------------------

cat <<'EOF'

[setup] -----------------------------------------------------------------
[setup] Symphony bootstrap complete.
[setup]
[setup] Next steps:
[setup]   1. Edit elixir/WORKFLOW.md to point at your tracker (Monday board
[setup]      or Linear project), set repo URLs, and tune agent limits.
[setup]   2. Populate .env (gitignored). On MyBCAT machines:
[setup]        /mnt/d_drive/repos/finances/scripts/secret_exec.py \
[setup]            --emit-env-file .env mybcat/symphony
[setup]   3. Authenticate the coding-agent CLIs you plan to use. Each is
[setup]      an interactive browser login tied to the host user:
[setup]        claude  login          (or `claude /login`)
[setup]        codex   login
[setup]        gemini  auth login
[setup]   4. Run Symphony:
[setup]        ./elixir/bin/symphony ./elixir/WORKFLOW.md \
[setup]            --i-understand-that-this-will-be-running-without-the-usual-guardrails
[setup]      Or via Docker:
[setup]        docker compose up
[setup] -----------------------------------------------------------------
EOF
