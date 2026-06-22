#!/usr/bin/env bash
set -euo pipefail

# Mounted repos are owned by a foreign uid; allow git to operate on them.
git config --global --add safe.directory '*' 2>/dev/null || true

# Re-seed the baked skill + settings in case a named volume mounted over
# ~/.claude hid them (the volume wins over the image layer on first run).
mkdir -p "${HOME}/.claude/commands"
if [ ! -f "${HOME}/.claude/commands/feature.md" ] && [ -f /opt/claude-skill/commands/feature.md ]; then
  cp /opt/claude-skill/commands/feature.md "${HOME}/.claude/commands/feature.md"
fi
if [ ! -f "${HOME}/.claude/settings.json" ] && [ -f /opt/claude-skill/settings.json ]; then
  cp /opt/claude-skill/settings.json "${HOME}/.claude/settings.json"
fi

# Mark first-run onboarding complete so interactive `claude` doesn't show the
# theme/login flow ("open browser to auth") on every ephemeral `run --rm`.
# Auth itself comes from CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY in the env;
# ~/.claude.json (a sibling FILE of the persisted ~/.claude dir) isn't persisted,
# so it's absent each run and must be re-seeded here.
CLAUDE_JSON="${HOME}/.claude.json"
if [ -f "$CLAUDE_JSON" ]; then
  tmp="$(mktemp)" && jq '.hasCompletedOnboarding = true' "$CLAUDE_JSON" > "$tmp" \
    && mv "$tmp" "$CLAUDE_JSON" || true
else
  echo '{"hasCompletedOnboarding": true}' > "$CLAUDE_JSON"
fi

exec "$@"
