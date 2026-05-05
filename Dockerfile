# syntax=docker/dockerfile:1.6
#
# Symphony container image — multi-stage build.
#
# Builder stage compiles the Symphony escript with the same Erlang/Elixir
# versions pinned in elixir/mise.toml. Runtime stage carries only the BEAM
# runtime plus the produced escript binary.
#
# The Claude / Codex / Gemini CLIs are NOT bundled. They authenticate
# interactively via browser-based OAuth flows tied to the host user, so the
# host install must be mounted into the container at run time. See
# BOOTSTRAP.md for the recommended docker-compose mount layout.

# ----- Build args (override at build time if your local mise pins drift) ----
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.1.4
ARG DEBIAN_VERSION=bookworm-20251104

# ----- Builder ---------------------------------------------------------------
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        build-essential \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
 && mix local.rebar --force

WORKDIR /src/elixir

# Fetch deps first so the dep layer caches independently of source edits.
COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get --only prod

# Bring in the rest of the Elixir tree and build the escript.
COPY elixir/. ./
RUN mix deps.compile \
 && mix escript.build

# ----- Runtime ---------------------------------------------------------------
# erlang:${OTP_VERSION}-slim ships a matching BEAM VM without the build
# toolchain. The escript embeds Elixir's stdlib + all deps, so we do not need
# Elixir at runtime.
FROM erlang:${OTP_VERSION}-slim AS runtime

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SYMPHONY_WORKSPACE_ROOT=/workspace/issues \
    PATH=/opt/symphony/cli:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# `git` is needed because WORKFLOW.md `hooks.after_create` typically runs
# `git clone ... .` to seed each per-issue workspace. `openssh-client` lets
# Symphony talk to remote SSH workers (Spec 2 / Spec 3 multi-runtime). `tini`
# is a tiny PID 1 init that reaps zombies left by spawned CLI subprocesses.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        openssh-client \
        tini \
 && rm -rf /var/lib/apt/lists/*

# Run as a non-root user so files written into mounted host volumes carry a
# sane UID. UID/GID 1000 matches the typical first interactive user on
# Debian/Fedora/Ubuntu hosts; override via `docker run --user ...` if needed.
RUN groupadd --gid 1000 symphony \
 && useradd  --uid 1000 --gid 1000 --create-home --home-dir /home/symphony --shell /bin/bash symphony

COPY --from=builder /src/elixir/bin/symphony /usr/local/bin/symphony

# WORKFLOW.md is mounted at /workspace/WORKFLOW.md (see docker-compose.yml).
# The per-issue workspaces live under /workspace/issues so a single mount can
# back both the workflow file and the workspace tree.
RUN mkdir -p /workspace /workspace/issues /opt/symphony/cli \
 && chown -R symphony:symphony /workspace /home/symphony /opt/symphony

USER symphony
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/symphony"]
CMD ["/workspace/WORKFLOW.md"]
