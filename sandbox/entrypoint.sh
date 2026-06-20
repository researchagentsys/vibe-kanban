#!/usr/bin/env bash
#
# Sandbox container entrypoint. Runs as the non-root `vk` user (uid 10001).
# Prepares the per-tenant writable dirs, sets a git identity, validates the
# required origin, then execs the vibe-kanban server (PID 1 via tini).
set -euo pipefail

# 1) Ensure per-tenant writable dirs exist. With a read-only root filesystem,
#    each of these paths MUST be backed by a mounted volume/tmpfs (see README's
#    volume contract); otherwise these mkdirs fail fast with a clear error.
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" /var/tmp/vibe-kanban "$NPM_CONFIG_CACHE"

# 2) Git identity — coding agents cannot create commits without it.
git config --global user.name  "${GIT_AUTHOR_NAME:-vibe-agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-agent@example.invalid}"
git config --global --add safe.directory '*'

# 2.5) Surface the project storage repo (/workspace) at the directory browser's
#      default location. vibe-kanban's repo picker opens at the server's $HOME and
#      lists git repos there; this symlink makes /workspace appear as a one-click
#      git repo, so users don't have to type the path manually (nor accidentally
#      create repos under $HOME instead of the mounted storage). The git-repos scan
#      follows the symlink and detects /workspace/.git. No-op if /workspace absent.
if [ -d /workspace ]; then
  ln -sfn /workspace "$HOME/workspace" || true
fi

# 3) REQUIRED: the orchestrator must inject the tenant's public gateway origin,
#    or the backend rejects browser/API requests with 403 (origin check).
: "${VK_ALLOWED_ORIGINS:?must be set by the orchestrator, e.g. https://t-<id>.app.example.com}"

# 4) Per-tenant LLM credentials (optional, injected by the orchestrator).
#    Strongly prefer pointing agents at YOUR proxy so the real upstream key never
#    enters the sandbox, e.g. ANTHROPIC_BASE_URL / OPENAI_BASE_URL + scoped tokens.
#    Nothing to do here — they arrive as env/secret mounts.

# 5) Pre-acknowledge onboarding so the embedded UI boots straight to Workspaces.
#    This is an ephemeral, single-user, server-side instance reached only through
#    the platform's authenticated reverse proxy — vibe-kanban's own local-account /
#    cloud-relay sign-in onboarding is meaningless here, so we skip it and disable
#    the cloud relay. Only seed when absent (don't clobber a persisted volume).
CONFIG_DIR="$XDG_DATA_HOME/vibe-kanban"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/config.json" <<EOF
{
  "config_version": "v8",
  "theme": "SYSTEM",
  "executor_profile": { "executor": "${VK_DEFAULT_EXECUTOR:-CLAUDE_CODE}" },
  "disclaimer_acknowledged": true,
  "onboarding_acknowledged": true,
  "remote_onboarding_acknowledged": true,
  "notifications": { "sound_enabled": false, "push_enabled": false, "sound_file": "ABSTRACT_SOUND4" },
  "editor": { "editor_type": "VS_CODE", "custom_command": null, "remote_ssh_host": null, "remote_ssh_user": null, "auto_install_extension": true },
  "github": { "pat": null, "oauth_token": null, "username": null, "primary_email": null, "default_pr_base": "main" },
  "analytics_enabled": false,
  "workspace_dir": null,
  "last_app_version": null,
  "show_release_notes": false,
  "language": "BROWSER",
  "git_branch_prefix": "vk",
  "showcases": { "seen_features": [] },
  "pr_auto_description_enabled": true,
  "commit_reminder_enabled": true,
  "send_message_shortcut": "ModifierEnter",
  "relay_enabled": false,
  "host_nickname": null
}
EOF
fi

# 6) Optional codex model-provider config (e.g. an OpenAI-compatible proxy),
#    injected by the orchestrator as base64-encoded TOML → ~/.codex/config.toml.
#    The key itself arrives as a normal env var the TOML references via env_key.
if [ -n "${CODEX_CONFIG_TOML_B64:-}" ]; then
  mkdir -p "$HOME/.codex"
  printf '%s' "$CODEX_CONFIG_TOML_B64" | base64 -d > "$HOME/.codex/config.toml"
fi

exec /usr/local/bin/vibe-kanban-server
