# claude-container

A Docker container that runs **Claude Code** to work on **one** of the sibling projects under
`ribose/` through a fixed, gated workflow:

> **plan** → adjust & confirm → **implement** in an isolated git worktree (TDD, full access,
> no questions) → **run tests** → **review** → update **CLAUDE.md/docs** if needed →
> **commit** (message reviewed) → open **PR** (body reviewed) → **remove worktree** (confirm)
> → **remove branch** (confirm).

Writes are physically confined to the chosen repo: the whole `ribose/` tree is mounted
**read-only** for context, and only the target repo is overlaid read-write (worktrees live
inside it, under `.claude/worktrees/`).
If a change needs another project, the workflow emits a **hand-off prompt** for a separate
session instead of editing it.

## One-time setup

```bash
cd ribose/claude-container
docker compose build           # ruby 3.4 + node 20 + git + gh + Claude Code
chmod +x bin/cw entrypoint.sh
# optional: put bin/ on your PATH, e.g.
#   export PATH="$PWD/bin:$PATH"
```

### Authenticate Claude (once; persists in the `claude-home` volume)

On macOS, Claude Code's login lives in the **Keychain**, not in `~/.claude`, so it can't be
bind-mounted into a Linux container. Do one of:

```bash
# A) log in once inside the container (token persists in the named volume):
docker compose run --rm dev claude login

# B) or set CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) or ANTHROPIC_API_KEY in .env
cp .env.example .env && $EDITOR .env
```

`gh` and git just work via the mounted `~/.config/gh` and `~/.gitconfig`. Private gems use the
host's `BUNDLE_RUBYGEMS__PKG__GITHUB__COM`.

## Everyday use

Run from inside the project you want to work on:

```bash
cd ribose/relaton/relaton-bib
cw "add retry logic to the HTTP client"
```

`cw` derives `<org>/<repo>` from the current directory, launches an interactive Claude session
(with full tool access), and auto-invokes the `/feature` workflow with your task. Stay attached
to the terminal — the workflow pauses for you at the plan, commit-message, PR-body, and the two
cleanup confirmations.

Other forms:

```bash
cw relaton/relaton-bib "add retry logic"   # explicit repo, from anywhere
cw relaton/relaton-bib                      # interactive; type /feature yourself
```

### Raw equivalent (no wrapper)

```bash
docker compose -f compose.yml run --rm \
  -w /work/relaton/relaton-bib \
  -v "$(cd ../relaton/relaton-bib && pwd)":/work/relaton/relaton-bib \
  dev claude --permission-mode plan --allow-dangerously-skip-permissions "/feature add retry logic"
```

## How it works

| Piece | Role |
|-------|------|
| `Dockerfile` | ruby 3.4 + node 20 + git + gh + ripgrep + native-gem build deps + Claude Code; non-root `dev` user. |
| `compose.yml` | mounts `ribose/` read-only at `/work`, host gh/git config, and a `claude-home` volume for login persistence. |
| `bin/cw` | host launcher; resolves the target repo and adds the read-write overlay. |
| `image/commands/feature.md` | the `/feature` workflow skill (baked into the image). |
| `image/settings.json` | container Claude defaults (model = opus). |
| `entrypoint.sh` | sets `git safe.directory`, re-seeds the skill if the volume hid it. |

### Worktrees

When you choose isolation, the workflow creates the branch in a worktree **inside the repo**:

```
ribose/<org>/<repo>/.claude/worktrees/<branch>/
```

The dir is excluded locally via `.git/info/exclude`, so it never shows as untracked or gets
committed (no change to the repo's tracked `.gitignore`). Living inside the target repo, the
worktree rides its read-write mount — no separate mount needed.

**Host compatibility.** The container mounts the repo at `/work/...` but on the host it's at
`/Users/.../ribose/...`. Git normally bakes an absolute path into a worktree's `.git` link, which
would make host-side `git status` fail (`not a git repository: /work/...`). So the workflow
rewrites that link to a **relative** path (the worktree sits a fixed 3 levels deep in the repo),
leaving the repo-side backlink absolute. Result: you can `git status`/diff/commit inside the
worktree from **both** the container and the host. (Container git is 2.39, which mishandles a
relative backlink — hence only the forward link is relativized.)

Cleanup removes the worktree and (after confirmation) the local branch; the remote branch and its
PR are kept.

## Notes & caveats

- The session starts in **plan mode** (`--permission-mode plan`), so Claude must present a plan
  and have it approved before it can edit anything — a harness-level gate, not just an instruction.
  It's paired with `--allow-dangerously-skip-permissions` so that, once you approve the plan
  (choose "accept edits", or `Shift+Tab` to the bypass mode), implementation runs autonomously.
  That bypass is acceptable here because the container + read-only mount are the isolation
  boundary and writes are limited to the single target repo. The *remaining* gates (isolation
  choice, commit, PR, cleanup) are enforced by the skill, not the permission layer.
- Most repos need Ruby ≥ 3.3 (image ships 3.4). A repo pinned to an older Ruby may need a
  tweaked base image.
- Each `cw` call is ephemeral (`run --rm`). Repos persist on the host mount; Claude login
  persists in the `claude-home` volume. In-container bundles are not cached between runs.
