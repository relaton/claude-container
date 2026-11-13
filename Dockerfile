# The image for the workspace devcontainer, which `bin/cw` also uses.
#
# There is one container: ../.devcontainer/docker-compose.yml builds this context and
# runs `sleep infinity`. VS Code attaches to it, and `cw` runs `docker exec` into the
# same container. So Ruby, the gems and Claude Code install once, into the
# `home-local` and `claude-config` volumes.

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# --- modern git (>=2.48 for native relative worktrees) ----------------------
# Ubuntu 24.04 ships git 2.43, which lacks `git worktree add --relative-paths`
# / `worktree.useRelativePaths` (git 2.48+). Without relative links, git bakes
# the container's ABSOLUTE path (/workspaces/...) into a worktree, so host-side
# (/Users/...) git cannot read it. The PPA carries 2.51, so no source build is
# needed here.
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
 && apt-get install -y --no-install-recommends software-properties-common \
 && add-apt-repository -y ppa:git-core/ppa \
 && apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

# --- Ruby build deps, native-gem deps, session tools ------------------------
# libxml2-dev and libxslt1-dev build nokogiri. default-jre-headless runs Jing
# (ruby-jing), which the relaton work uses. Only rebuild when this list changes.
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
 && apt-get install -y --no-install-recommends \
      build-essential autoconf bison rustc pkg-config cmake \
      libssl-dev libyaml-dev libreadline-dev zlib1g-dev libgmp-dev libffi-dev \
      libxml2-dev libxslt1-dev \
      libpq-dev libsqlite3-dev postgresql-client \
      default-jre-headless \
      ripgrep jq less \
 && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI --------------------------------------------------------------
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- mise --------------------------------------------------------------------
# The binary only. The Ruby versions themselves live in the ~/.local volume, so
# they survive an image rebuild and both stacks see the same ones.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# --- bake the workflow skill + settings -------------------------------------
# Baked into /opt so cw-session-setup can re-seed them even when a named volume is
# mounted over /home/vscode/.claude (the volume wins over the image layer).
COPY image/commands/feature.md /opt/claude-skill/commands/feature.md
COPY image/settings.json       /opt/claude-skill/settings.json

# Host-compatible worktree helper (on PATH so the skill can call it directly).
COPY image/bin/mkworktree /usr/local/bin/mkworktree
# Not an ENTRYPOINT: `bin/cw` runs it explicitly through `docker exec`.
COPY session-setup.sh     /usr/local/bin/cw-session-setup
RUN chmod +x /usr/local/bin/mkworktree /usr/local/bin/cw-session-setup

USER vscode

# The mise SHIMS, not `mise activate`. Claude Code runs non-interactive shells,
# so ~/.bashrc never runs and an activated mise never reaches the Bash tool.
# The shims need no activation. ~/.local/bin holds the Claude Code install.
ENV PATH=/home/vscode/.local/share/mise/shims:/home/vscode/.local/bin:$PATH

# Honour a project's .ruby-version. mise calls these files idiomatic and ignores
# them unless the tool is named here.
ENV MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS=ruby

# Pre-create the volume mount points so the named volumes are owned by vscode,
# not root. The rc lines keep an interactive shell working as before.
RUN mkdir -p ~/.local/bin ~/.local/share ~/.claude/commands \
 && echo 'eval "$(mise activate bash)"' >> ~/.bashrc \
 && echo 'eval "$(mise activate zsh)"'  >> ~/.zshrc

# The global default Ruby, for a directory that pins no version of its own.
# It must be BAKED, not written at runtime: it lives in ~/.config, which is not
# one of the shared volumes, so an ephemeral `cw` container would otherwise get
# a shim with no version set. post-create.sh writes the same two lines.
RUN mkdir -p ~/.config/mise \
 && printf '[tools]\nruby = "3.4"\n' > ~/.config/mise/config.toml

# No ENTRYPOINT and no CMD, on purpose. The devcontainer runs `sleep infinity` on
# this image, and an ENTRYPOINT would wrap that command. `cw` needs no entrypoint
# either: it runs cw-session-setup itself, as the command of a `docker exec`.
