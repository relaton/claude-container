# claude-container

A Docker container that runs **Claude Code** to work on **one** of the sibling projects under
`workspace/` through a fixed, gated workflow:

> **plan** → adjust & confirm → **implement** in an isolated git worktree (TDD, full access,
> no questions) → **run tests** → **review** → update **CLAUDE.md/docs** if needed →
> **show you the diff and stop.**

Claude never commits, pushes, merges, or opens a PR. It leaves the finished work as **uncommitted
changes** on the chosen branch/worktree and hands it back to you — you decide what to commit, merge,
or open a PR for, in your own time.

Writes are physically confined to the chosen repo: the whole `workspace/` tree is mounted
**read-only** for context, and only the target repo is overlaid read-write (worktrees live
inside it, under `.claude/worktrees/`).
If a change needs another project, the workflow emits a **hand-off prompt** for a separate
session instead of editing it.

## One-time setup

```bash
# clone this repo as a sibling of your project repos, under the shared root:
cd workspace
git clone https://github.com/relaton/claude-container.git

cd claude-container
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

`gh` and git work via the mounted `~/.config/gh` and `~/.gitconfig`. For **pushing**, `cw` also
passes the host's GitHub token (via `gh auth token`, so it works even when the host keeps it in
the macOS keyring) as `GH_TOKEN`, and the container routes GitHub SSH remotes (`git@github.com:`)
over HTTPS using that token — so `git push` works without SSH keys in the container. Private gems
use the host's `BUNDLE_RUBYGEMS__PKG__GITHUB__COM`.

## Everyday use

Run from inside the project you want to work on:

```bash
cd workspace/relaton/relaton-bib
cw "add retry logic to the HTTP client"
```

`cw` derives `<org>/<repo>` from the current directory, launches an interactive Claude session
(with full tool access), and auto-invokes the `/feature` workflow with your task. Stay attached
to the terminal — the workflow pauses for you at the plan and the isolation choice, then runs to
completion and stops with the diff laid out for your review. The commit/merge/PR are left to you.

Other forms:

```bash
cw                                          # bare: repo from $PWD, interactive; type /feature yourself
cw relaton/relaton-bib "add retry logic"   # explicit repo, from anywhere
cw relaton/relaton-bib                      # interactive; type /feature yourself
```

Bare `cw` (no options) just opens an interactive Claude session in the current repo — no task is
passed, so `/feature` isn't auto-invoked; run it yourself when you're ready.

To review the work, run the **`/diff`** command in the session — it walks you through the pending
changes so you can review them before deciding what to commit, merge, or open a PR for.

### Raw equivalent (no wrapper)

```bash
docker compose -f compose.yml run --rm \
  -w /work/relaton/relaton-bib \
  -v "$(cd ../relaton/relaton-bib && pwd)":/work/relaton/relaton-bib \
  dev claude --permission-mode plan --allow-dangerously-skip-permissions "/feature add retry logic"
```

## How to organize your repos

The container mounts the **parent** of `claude-container/` (the whole `workspace/` tree) read-only at
`/work`, and `cw` derives the target from an `<org>/<repo>` layout. So put `claude-container/` and
your project repos side by side under one root, with each repo two levels down as `<org>/<repo>`:

```text
workspace/                       # ← mounted read-only at /work (cross-project context)
├── claude-container/         # this tooling repo (a sibling, not a project to work on)
├── relaton/                  # <org>
│   ├── relaton-bib/          #   └─ <repo>   → cw relaton/relaton-bib "..."
│   └── relaton-cli/          #   └─ <repo>
└── metanorma/                # <org>
    └── metanorma-cli/        #   └─ <repo>   → cw metanorma/metanorma-cli "..."
```

- The root can have any name/location — `cw` finds it as the parent of `claude-container/`.
- Each `<org>/<repo>` must be a **git repo** (`cw` checks for `.git`); only it is overlaid
  read-write, with worktrees under its own `.claude/worktrees/`. Everything else stays read-only.
- `claude-container` itself is reserved as the tooling dir, so it can't be a `cw` target.

## How it works

| Piece | Role |
|-------|------|
| `Dockerfile` | ruby 3.4 + node 20 + git + gh + ripgrep + native-gem build deps + Claude Code; non-root `dev` user. |
| `compose.yml` | mounts `workspace/` read-only at `/work`, host gh/git config, and a `claude-home` volume for login persistence. |
| `bin/cw` | host launcher; resolves the target repo and adds the read-write overlay. |
| `image/commands/feature.md` | the `/feature` workflow skill (baked into the image). |
| `image/settings.json` | container Claude defaults (model = opus). |
| `entrypoint.sh` | sets `git safe.directory`, re-seeds the skill if the volume hid it. |

### Worktrees

Right after you approve the plan, the workflow **asks** whether to isolate the work. If you pick
an isolated worktree, it creates the branch in a worktree **inside the repo**:

```
workspace/<org>/<repo>/.claude/worktrees/<branch>/
```

The dir is excluded locally via `.git/info/exclude`, so it never shows as untracked or gets
committed (no change to the repo's tracked `.gitignore`). Living inside the target repo, the
worktree rides its read-write mount — no separate mount needed.

**Host compatibility.** The container mounts the repo at `/work/...` but on the host it's at
`/Users/.../workspace/...`. Git normally bakes an absolute path into a worktree's `.git` link, which
would make host-side `git status` fail (`not a git repository: /work/...`). The container ships
**git ≥ 2.48** and sets `worktree.useRelativePaths=true` globally, so `git worktree add` writes
**relative** links for both the forward `.git` link and the repo-side backlink — they resolve
whether the repo is seen at `/work/...` or `/Users/...`. Result: you can `git status`/diff/commit
inside the worktree from **both** the container and the host, and even a bare `git worktree add`
(not just the helper) stays host-reachable. The baked **`mkworktree`** helper
(`image/bin/mkworktree`, on `PATH`) is still preferred — it just adds the convenience of a fixed
location under `.claude/worktrees/`, a conventional `<type>/<slug>` branch name (e.g.
`feat/add-http-retry`), and the local exclude.

> Git auto-sets the per-repo `extensions.relativeWorktrees` flag on the first relative worktree.
> Your host git (2.50) understands it; very old host git/libgit2 tooling may not.

The worktree and branch are left in place when Claude stops, so you can review and finalize the
changes from the host. Remove the worktree yourself once you're done (`git worktree remove
.claude/worktrees/<branch>`).

## Notes & caveats

- The session starts in **plan mode** (`--permission-mode plan`), so Claude must present a plan
  and have it approved before it can edit anything — a harness-level gate, not just an instruction.
  It's paired with `--allow-dangerously-skip-permissions` so that, once you approve the plan
  (choose "accept edits", or `Shift+Tab` to the bypass mode), implementation runs autonomously.
  That bypass is acceptable here because the container + read-only mount are the isolation
  boundary and writes are limited to the single target repo. The isolation-choice gate and the
  "never commit/push/merge/PR — stop and hand back the diff" rule are enforced by the skill, not
  the permission layer, so they rely on Claude following the workflow prompt.
- Most repos need Ruby ≥ 3.3 (image ships 3.4). A repo pinned to an older Ruby may need a
  tweaked base image.
- Each `cw` call is ephemeral (`run --rm`). Repos persist on the host mount; Claude login
  persists in the `claude-home` volume. In-container bundles are not cached between runs.
