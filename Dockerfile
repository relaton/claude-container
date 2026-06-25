FROM ruby:3.4-slim-bookworm

# --- system + native-gem build deps -----------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates gnupg ripgrep less jq \
      build-essential pkg-config cmake \
      libffi-dev libyaml-dev libxml2-dev libxslt1-dev zlib1g-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Node 20 (for Claude Code) ----------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

# --- GitHub CLI --------------------------------------------------------------
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- non-root user -----------------------------------------------------------
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN groupadd -g "${HOST_GID}" dev 2>/dev/null || true \
    && useradd -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash dev 2>/dev/null \
       || useradd -m -u "${HOST_UID}" -s /bin/bash dev

# --- bake the workflow skill + settings -------------------------------------
# Baked into /opt so the entrypoint can re-seed them even when a named volume
# is mounted over /home/dev/.claude (which would otherwise hide them).
COPY image/commands/feature.md /opt/claude-skill/commands/feature.md
COPY image/settings.json       /opt/claude-skill/settings.json
RUN mkdir -p /home/dev/.claude/commands \
    && cp /opt/claude-skill/commands/feature.md /home/dev/.claude/commands/feature.md \
    && cp /opt/claude-skill/settings.json       /home/dev/.claude/settings.json \
    && chown -R dev /home/dev/.claude

# Host-compatible worktree helper (on PATH so the skill can call it directly).
COPY image/bin/mkworktree /usr/local/bin/mkworktree
RUN chmod +x /usr/local/bin/mkworktree

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER dev
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
