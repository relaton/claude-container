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

There are two launchers, with the same contract and the same workflow — they differ only in what
enforces the boundary. `bin/cw` uses Docker (below). `bin/cwl` skips Docker entirely and runs
Claude Code on the host inside the Anthropic Sandbox Runtime — see
[Running without Docker](#running-without-docker-cwl).

If a change needs another project, the workflow never edits it — it writes a self-contained
**hand-off prompt** to the shared inbox at `workspace/HANDOFFS/` (created by `cw`, alongside the
org dirs), named `<org>__<repo>__<slug>.md` — e.g. `relaton__relaton-bib__add-http-retry.md`.
Mounted at `/work/HANDOFFS`, this inbox is the only writable spot outside the target repo, and it
takes hand-off prompts only, never code. Next time you run `cw` in the repo a hand-off is addressed
to, that session reads its pending hand-offs while planning and tells you about them — so there's
nothing to copy around by hand. Delete a hand-off file when it's done; nothing else will.

## One-time setup

```bash
# clone this repo as a sibling of your project repos, under the shared root:
cd workspace
git clone https://github.com/relaton/claude-container.git

cd claude-container
docker compose build           # ruby 3.4 + node 20 + git + gh + java + Claude Code
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

### Output style

Both launchers append the same instruction to the system prompt, so a session reads the same way
whichever one you start it with:

- **ASD-STE100 Simplified Technical English** — the aerospace controlled-language standard.
  Approved vocabulary, one meaning per word, active voice, a maximum of 20 words in an instruction
  and 25 in a description, no gerund or participle used as a noun.
- **A definition on first use** — any term you have not used yet in the conversation gets a
  one-line explanation the first time it appears.

Identifiers, paths, commands, flags and quoted output are carved out explicitly. Without that
carve-out, STE rewriting mangles the very things that have to stay verbatim.

The text lives in the `style_prompt` heredoc near the end of each launcher. Edit it there; the two
copies are identical on purpose, in the same way both scripts carry their own copy of the repo
resolution logic.

### Raw equivalent (no wrapper)

```bash
docker compose -f compose.yml run --rm \
  -w /work/relaton/relaton-bib \
  -v "$(cd ../relaton/relaton-bib && pwd)":/work/relaton/relaton-bib \
  dev claude --permission-mode plan --allow-dangerously-skip-permissions "/feature add retry logic"
```

## Running without Docker (`cwl`)

`bin/cwl` gives you the same single-project boundary without building or running a container.
It uses **two layers**, because no single host mechanism covers everything:

- **Bash and every process it spawns** — Claude Code's built-in sandbox (Seatbelt on macOS).
  Kernel-enforced: writes confined to the target repo, reads confined to the workspace plus a
  short toolchain allowlist, network egress restricted to an allowlist.
- **Read / Edit / Write, MCP servers, hooks** — these run inside the Claude Code process and the
  sandbox does not reach them, so `cwl` generates explicit `permissions.deny` rules for every
  other repo in the workspace and for everything outside it (~500 entries for a typical target).

Because the file tools are gated by the permission layer rather than the kernel, `cwl` does **not**
pass `--allow-dangerously-skip-permissions` the way `cw` does — that flag would skip the very deny
rules doing the work. Bash still runs prompt-free via the sandbox's auto-allow, which is where
nearly all the prompts came from anyway.

### Setup

```bash
./bin/install-local    # symlinks /feature + mkworktree, checks prerequisites
```

It symlinks (not copies) `image/commands/feature.md` into `~/.claude/commands/` and
`image/bin/mkworktree` into `~/.local/bin/`, so edits under `image/` take effect immediately —
the same freshness the entrypoint's re-seed gives the container.

### Use

Identical to `cw`:

```bash
cd workspace/relaton/support
cwl "add retry logic to the HTTP client"
# or:  cwl relaton/support "add retry logic to the HTTP client"
```

`CWL_DRY_RUN=1 cwl <org>/<repo>` prints the resolved boundary and keeps the generated settings
file for inspection. `CWL_EXTRA_DOMAINS="host,*.example.com"` widens the network allowlist, and
`CWL_EXTRA_READ="/path/a,/path/b"` widens the read allowlist.

### The boundary

| | `cw` (Docker) | `cwl` (native sandbox) |
|---|---|---|
| Writable | target repo, `HANDOFFS` | same, plus the gem caches bundler needs |
| Readable | all of `workspace/` (`:ro`) | same, via `--add-dir`, plus the toolchain paths listed below; nothing else under `/Users` or `/Volumes` |
| Bash confinement | mount namespace | Seatbelt, `failIfUnavailable: true` so it never silently degrades |
| File-tool confinement | mount namespace (kernel) | `permissions.deny` rules (permission layer) |
| Network | **unrestricted** | deny-all except an allowlist |
| Toolchain | pinned in the image | the host's — so asdf gives each repo *its own* Ruby |

#### The read allowlist

Under `cw` the read boundary came for free: only `workspace/` was mounted, so nothing else on the
host existed. `cwl` runs on the real filesystem, so `/Users` and `/Volumes` are denied wholesale and
re-opened only for the workspace and the paths a session genuinely needs — the Ruby toolchain
(`~/.asdf`, `~/.rvm`, `~/.gem`, `~/.gemrc`, `~/.bundle`, `~/.cache`, `~/.npm`), Claude Code's own
binary and state (`~/.claude`, `~/.claude.json`, `~/.local/bin`, `~/.local/share/claude`,
`~/.local/state`), and the config the Bash tool reads at startup (`~/.gitconfig`, `~/.config/gh`,
the shell rc files). Add more with `CWL_EXTRA_READ`.

The two layers express this differently. The sandbox honours `allowRead` over `denyRead`, so it
needs only the two blanket denies. The Read *tool* is a permission-layer check where deny beats
allow, so a blanket rule there could not be re-opened — `cwl` walks from `/Users` down to the
workspace and denies everything standing beside the path, descending into any directory that is an
ancestor of an allowed path (so `~/.config` is denied while `~/.config/gh` survives).

`core.excludesfile` and friends are read out of your global git config at launch and allowed
automatically — git warns on every invocation and silently drops those settings if it cannot read
the file they point at, and hardcoding the filename would only work on one machine.

`~/.local/share/gem` holds the RubyGems API key and stays denied, so `gem push` fails — exactly as
it did in the container, which never had that file either.

Verified end to end: writing a sibling repo fails from both the Write tool ("directory denied by
permission settings") and Bash ("Operation not permitted"); reading a sibling succeeds; writing the
target repo and `HANDOFFS` succeeds; reading `~/Documents` or `~/.ssh` fails from Bash and the Read
tool alike while `~/.zshrc`, `~/.asdf` and the workspace stay readable; `curl https://example.com`
is refused by the proxy while `git`, `gh`, `ruby`, `bundle` and rubygems.org all work.
`bundle install` and `bundle update` both complete under the read boundary — including native
extension compilation and git-sourced gems — and `rubygems.pkg.github.com` stays reachable for the
private metanorma gems.

### The honest caveat

This is the one place `cwl` is weaker than the container. In `cw`, a write to another repo is
impossible because the filesystem is mounted read-only. In `cwl`, a write by the **file tools** is
blocked by a permission rule — strong in practice, but policy rather than physics, and it depends
on the deny list being complete. The list is regenerated from the actual directory contents on
every launch, so a newly cloned repo is covered the next time you start a session.

`sandbox.allowUnsandboxedCommands` is set to `false`, which closes the escape hatch that would
otherwise let a blocked Bash command be re-run outside the sandbox.

### Folder trust

`cwl` pre-accepts the folder-trust prompt for the target repo by setting
`projects[<repo>].hasTrustDialogAccepted` in `~/.claude.json` before launching — the same thing
`entrypoint.sh` does inside the container. Trust is stored **per project directory**, so a repo you
have never opened before would otherwise prompt on every start. The container never hits this:
`~/.claude` is a persisted named volume, so the decision was recorded on first use.

Note this also silently accepts any permissions a repo pre-approves in its own
`.claude/settings.local.json` — `relaton/support`, for example, pre-approves `Bash(gem which:*)`
and `Bash(gh api:*)`. `cw` behaves identically.

### Why not the sandbox runtime?

An earlier version of `cwl` wrapped the whole process in `@anthropic-ai/sandbox-runtime` (`srt`),
which would have put the file tools inside a kernel boundary too. **It does not work for
interactive sessions on macOS.** srt's Seatbelt profile permits the terminal `ioctl` only on a
hardcoded path list (`/dev/tty`, `/dev/null`, `/dev/random`, …) that excludes the real controlling
terminal, `/dev/ttysNNN`. So `tcsetattr` fails with `EPERM`, Claude Code can never turn echo off,
and the result is unusable: the terminal's replies to Claude's capability probes land in the input
box as literal escape text, and keys arrive kitty-encoded (`Ctrl-C` as `^[[27;5;99~`) while the
parser expects raw bytes.

Reopening stdio via `/dev/tty` — the one allowed path — does fix raw mode, but then Claude Code
receives no keystrokes at all. Giving it a private pty would work, except the sandbox denies
`openpty`. Headless (`-p`) runs under srt are fine; only the TUI is affected.

## How to organize your repos

The container mounts the **parent** of `claude-container/` (the whole `workspace/` tree) read-only at
`/work`, and `cw` derives the target from an `<org>/<repo>` layout. So put `claude-container/` and
your project repos side by side under one root, with each repo two levels down as `<org>/<repo>`:

```text
workspace/                       # ← mounted read-only at /work (cross-project context)
├── claude-container/         # this tooling repo (a sibling, not a project to work on)
├── HANDOFFS/                 # shared cross-project hand-off inbox (writable at /work/HANDOFFS)
├── relaton/                  # <org>
│   ├── relaton-bib/          #   └─ <repo>   → cw relaton/relaton-bib "..."
│   └── relaton-cli/          #   └─ <repo>
└── metanorma/                # <org>
    └── metanorma-cli/        #   └─ <repo>   → cw metanorma/metanorma-cli "..."
```

- The root can have any name/location — `cw` finds it as the parent of `claude-container/`.
- Each `<org>/<repo>` must be a **git repo** (`cw` checks for `.git`); only it is overlaid
  read-write, with worktrees under its own `.claude/worktrees/`. Everything else stays read-only,
  except the `HANDOFFS/` inbox, which `cw` creates and mounts read-write for hand-off prompts only.
- `claude-container` itself is reserved as the tooling dir, so it can't be a `cw` target.

## How it works

| Piece | Role |
|-------|------|
| `Dockerfile` | ruby 3.4 + node 20 + git + gh + ripgrep + java (JRE for ruby-jing) + native-gem build deps + Claude Code; non-root `dev` user. |
| `compose.yml` | mounts `workspace/` read-only at `/work`, the `HANDOFFS/` inbox read-write, host gh/git config, and a `claude-home` volume for login persistence. |
| `bin/cw` | host launcher (Docker); resolves the target repo, adds the read-write overlay, and creates the hand-off inbox. |
| `bin/cwl` | host launcher (no Docker); same resolution, but generates per-session sandbox settings and file-tool deny rules. |
| `bin/install-local` | one-time host setup for `cwl`: symlinks the skill and `mkworktree`, checks prerequisites. |
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

## Updating Claude Code

Claude Code is installed into the image (via npm), so updating it means rebuilding.
The version is a build arg, `CLAUDE_CODE_VERSION`, defaulting to `latest`.

**Recommended — pin to a specific new version.** Changing the arg value busts the cache
for just that layer, and gives you reproducible builds and easy rollback:

```bash
docker compose build --build-arg CLAUDE_CODE_VERSION=2.0.34
```

**Stay on `latest`.** Since the arg value doesn't change, Docker would reuse the cached
layer and keep the old version — so force a clean rebuild:

```bash
docker compose build --no-cache
```

(This also recompiles git from source, so it's slower; pinning a version is the quicker path.)

The next `cw` run uses the rebuilt image automatically (each call is ephemeral `run --rm`).
Your login is unaffected — it lives in the `claude-home` volume, not the image.

## Notes & caveats

- The session starts in **plan mode** (`--permission-mode plan`), so Claude must present a plan
  and have it approved before it can edit anything — a harness-level gate, not just an instruction.
  It's paired with `--allow-dangerously-skip-permissions` so that, once you approve the plan
  (choose "accept edits", or `Shift+Tab` to the bypass mode), implementation runs autonomously.
  That bypass is acceptable here because the container + read-only mount are the isolation
  boundary and writes are limited to the single target repo. The isolation-choice gate and the
  "never commit/push/merge/PR — stop and hand back the diff" rule are enforced by the skill, not
  the permission layer, so they rely on Claude following the workflow prompt.
- `cwl` deliberately does **not** use that flag. Its file-tool boundary is the generated
  `permissions.deny` list, and `--allow-dangerously-skip-permissions` would skip it. Bash still
  runs without prompts, via `autoAllowBashIfSandboxed`, so in practice the two feel the same.
- Most repos need Ruby ≥ 3.3 (image ships 3.4). A repo pinned to an older Ruby may need a
  tweaked base image — or just use `cwl`, which picks up the repo's own asdf Ruby.
- The network allowlist (both launchers' sandboxes) matches on the client-supplied hostname
  without inspecting TLS, so it is a guardrail against accidental egress, not a defence against
  deliberate exfiltration.
- `cwl`'s deny list is regenerated from the workspace contents at every launch, so a repo cloned
  mid-session is not covered until the next start.
- Each `cw` call is ephemeral (`run --rm`). Repos persist on the host mount; Claude login
  persists in the `claude-home` volume. In-container bundles are not cached between runs.
