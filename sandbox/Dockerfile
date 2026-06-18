# syntax=docker/dockerfile:1.7
#
# Multi-tenant SANDBOX image: runs ONE vibe-kanban instance + the coding-agent
# CLIs per tenant, hardened for mutually-untrusted use.
#
# Build context MUST be the repo root:
#     docker build -f sandbox/Dockerfile -t vibe-kanban-sandbox:latest .
#
# It reuses the official frontend + Rust build stages (see ../Dockerfile), but
# the runtime stage differs in two essential ways the official image lacks:
#   1. a Node runtime + pre-installed coding-agent CLIs (executors spawn `npx`),
#   2. multi-tenant hardening + the /data volume contract (see sandbox/README.md).

############################
# Stage 1 — build frontend #
############################
FROM node:24-alpine AS fe-builder
ARG POSTHOG_API_KEY=""
ARG POSTHOG_API_ENDPOINT=""
WORKDIR /app
ENV PNPM_HOME=/pnpm
ENV PATH=${PNPM_HOME}:${PATH}
ENV VITE_PUBLIC_POSTHOG_KEY=${POSTHOG_API_KEY}
ENV VITE_PUBLIC_POSTHOG_HOST=${POSTHOG_API_ENDPOINT}
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN corepack enable && pnpm config set store-dir /pnpm/store

# Lockfile + workspace manifests first, for a cached install layer.
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY packages/local-web/package.json packages/local-web/package.json
COPY packages/ui/package.json packages/ui/package.json
COPY packages/web-core/package.json packages/web-core/package.json
# .npmrc (engine-strict) and pnpm patchedDependencies must exist before install,
# else `pnpm install --frozen-lockfile` fails (ENOENT on the patch file).
COPY .npmrc .npmrc
COPY patches/ patches/
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile

COPY packages/local-web/ packages/local-web/
COPY packages/public/ packages/public/
COPY packages/ui/ packages/ui/
COPY packages/web-core/ packages/web-core/
COPY shared/ shared/
RUN pnpm -C packages/local-web build   # -> packages/local-web/dist (rust-embed source)

############################
# Stage 2 — build binaries #
############################
FROM rust:1.93-slim-bookworm AS builder
# VK_SHARED_API_BASE is optional; leave empty to disable remote/cloud features.
ARG VK_SHARED_API_BASE=""
ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ENV CARGO_TARGET_DIR=/app/target
ENV SQLX_OFFLINE=true
ENV VK_SHARED_API_BASE=${VK_SHARED_API_BASE}
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates git libclang-dev libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

# rust-toolchain.toml pins the exact nightly; this line makes rustup install it.
COPY rust-toolchain.toml ./
RUN cargo --version >/dev/null

# Copy the whole workspace. Simpler and more robust than enumerating every crate
# manifest: cargo requires ALL workspace members' manifests to resolve the build.
# A repo-root .dockerignore should exclude target/, **/node_modules, dev_assets*/.
COPY Cargo.toml Cargo.lock ./
COPY crates/ crates/
COPY assets/ assets/
COPY --from=fe-builder /app/packages/local-web/dist packages/local-web/dist

# Build the server (frontend embedded) AND the MCP tool server binary.
RUN --mount=type=cache,id=cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=workspace-target,target=/app/target \
    cargo build --locked --release --bin server --bin vibe-kanban-mcp \
 && cp /app/target/release/server         /usr/local/bin/vibe-kanban-server \
 && cp /app/target/release/vibe-kanban-mcp /usr/local/bin/vibe-kanban-mcp

############################
# Stage 3 — hardened runtime
############################
FROM node:20-bookworm-slim AS runtime

# git: agent commits/worktrees. tini: PID-1 reaping. ripgrep: some agents shell
# out to `rg`. curl: healthcheck. openssh-client: git-over-ssh.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git tini ripgrep ca-certificates curl openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --home-dir /data/home --shell /usr/sbin/nologin vk

# Pre-install ONLY the two coding-agent CLIs this deployment uses (claude-code +
# codex). Versions MIRROR the base commands in crates/executors/src/executors/*.rs
# — keep in sync on upgrade. Add gemini/copilot/amp/opencode/qwen here when needed;
# cursor-agent and droid ship via their own binary installers.
RUN npm install -g --no-fund --no-audit \
      @anthropic-ai/claude-code@2.1.119 \
      @openai/codex@0.124.0 \
    && npm cache clean --force

COPY --from=builder /usr/local/bin/vibe-kanban-server /usr/local/bin/vibe-kanban-server
COPY --from=builder /usr/local/bin/vibe-kanban-mcp    /usr/local/bin/vibe-kanban-mcp

# Per-tenant writable roots. A fresh Docker named volume inherits this ownership;
# for k8s PVCs use securityContext.fsGroup: 10001 instead.
RUN mkdir -p /data/home /data/state /data/cache /var/tmp/vibe-kanban \
    && chown -R vk:vk /data /var/tmp/vibe-kanban

COPY sandbox/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Relocate every writable path onto the per-tenant volume (/data) or tmpfs (/tmp)
# so the root filesystem can stay read-only:
#   XDG_DATA_HOME  -> db.v2.sqlite, config.json, credentials.json, signing keys, logs
#   XDG_CACHE_HOME -> attachments
#   HOME           -> agent CLI state/auth (~/.claude, ~/.gemini, ...)
#   /var/tmp/vibe-kanban -> git worktrees (must be a real, exec-capable volume)
ENV HOME=/data/home \
    XDG_DATA_HOME=/data/state \
    XDG_CACHE_HOME=/data/cache \
    TMPDIR=/tmp \
    NPM_CONFIG_CACHE=/data/home/.npm \
    npm_config_prefer_offline=true \
    HOST=0.0.0.0 \
    PORT=8080

USER vk
WORKDIR /data/home
EXPOSE 8080

# External health endpoint is /api/health (/health is behind relay-sig middleware).
HEALTHCHECK --interval=15s --timeout=3s --start-period=25s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${PORT:-8080}/api/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
