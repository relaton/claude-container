#!/usr/bin/env bash
set -euo pipefail

# Build a writable global git config (the host's is mounted read-only at
# ~/.gitconfig.host). It inherits the host identity via include, then adds the
# container-only bits:
#   - safe.directory '*'   : mounted repos are owned by a foreign uid.
#   - url insteadOf        : the repos use SSH remotes (git@github.com:) but the
#                            container has no SSH key — route them over HTTPS.
#   - credential helper    : feed GH_TOKEN (set by `cw` from `gh auth token`) as the
#                            HTTPS password so `git push` authenticates.
cat > "${HOME}/.gitconfig" <<'EOF'
[include]
	path = /home/dev/.gitconfig.host
[safe]
	directory = *
[url "https://github.com/"]
	insteadOf = git@github.com:
[credential "https://github.com"]
	helper = "!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f"
EOF

# Re-seed the baked skill + settings in case a named volume mounted over
# ~/.claude hid them (the volume wins over the image layer on first run).
mkdir -p "${HOME}/.claude/commands"
# Always overwrite the baked skill command: it's image-managed tooling, so it must
# track the image, not whatever stale copy a persistent ~/.claude volume still holds.
if [ -f /opt/claude-skill/commands/feature.md ]; then
  cp /opt/claude-skill/commands/feature.md "${HOME}/.claude/commands/feature.md"
fi
if [ ! -f "${HOME}/.claude/settings.json" ] && [ -f /opt/claude-skill/settings.json ]; then
  cp /opt/claude-skill/settings.json "${HOME}/.claude/settings.json"
fi

# Seed ~/.claude.json on every run. It's a sibling FILE of the persisted
# ~/.claude dir, so it is NOT persisted — it's absent each ephemeral `run --rm`
# and Claude would otherwise re-prompt. We set two things:
#   - hasCompletedOnboarding: skips the theme/login flow ("open browser to auth").
#     Auth itself comes from CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY.
#   - per-project hasTrustDialogAccepted for the working dir: skips the
#     "Is this a folder you trust?" prompt for the repo `cw` launched us in
#     (cw sets the container workdir to /work/<org>/<repo>).
CLAUDE_JSON="${HOME}/.claude.json"
WORK_DIR="$(pwd)"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
tmp="$(mktemp)" && jq --arg dir "$WORK_DIR" '
  .hasCompletedOnboarding = true
  | .projects = (.projects // {})
  | .projects[$dir] = ((.projects[$dir] // {}) + {hasTrustDialogAccepted: true})
' "$CLAUDE_JSON" > "$tmp" && mv "$tmp" "$CLAUDE_JSON" || true

exec "$@"
