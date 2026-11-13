#!/usr/bin/env bash
#
# session-setup.sh — prepare a `cw` session, then exec the command it was given.
#
# This is NOT a container entrypoint. `cw` shares the long-running devcontainer,
# so it runs this script explicitly through `docker exec`. Everything here must
# therefore be idempotent and must not disturb the VS Code sessions that use the
# same container.
#
# It deliberately does NOT write ~/.gitconfig. The dev containers extension owns
# that file: it copies the host identity in and installs a credential helper that
# proxies to the host. `bin/cw` sets its own git configuration per process with
# GIT_CONFIG_COUNT instead, so the VS Code sessions keep theirs.

set -euo pipefail

# The Ruby toolchain and Claude Code live in the `home-local` volume, which
# ../.devcontainer fills through post-create.sh. A container started by compose
# alone never runs that hook, so say what is missing instead of failing later.
if [ ! -d "${HOME}/.local/share/mise/installs/ruby" ]; then
  echo "cw: the shared volume holds no Ruby." >&2
  echo "cw: open the workspace devcontainer once so post-create.sh installs it." >&2
  exit 1
fi

# Re-seed the baked skill + settings. The ~/.claude volume can hide the image
# layer, and the skill is image-managed tooling, so it must track the image and
# not whatever stale copy the volume still holds.
mkdir -p "${HOME}/.claude/commands"
if [ -f /opt/claude-skill/commands/feature.md ]; then
  cp /opt/claude-skill/commands/feature.md "${HOME}/.claude/commands/feature.md"
fi
if [ ! -f "${HOME}/.claude/settings.json" ] && [ -f /opt/claude-skill/settings.json ]; then
  cp /opt/claude-skill/settings.json "${HOME}/.claude/settings.json"
fi

# Seed ~/.claude.json so Claude Code does not prompt. Two things:
#   - hasCompletedOnboarding: skips the theme/login flow ("open browser to auth").
#     Auth itself comes from CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY.
#   - per-project hasTrustDialogAccepted for the working dir: skips the
#     "Is this a folder you trust?" prompt for the repo `cw` launched us in
#     (cw sets the working dir to /workspaces/<org>/<repo>).
CLAUDE_JSON="${HOME}/.claude.json"
WORK_DIR="$(pwd)"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
tmp="$(mktemp)" && jq --arg dir "$WORK_DIR" '
  .hasCompletedOnboarding = true
  | .projects = (.projects // {})
  | .projects[$dir] = ((.projects[$dir] // {}) + {hasTrustDialogAccepted: true})
' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON" || true

exec "$@"
