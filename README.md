# claude-container

A Docker container that runs **Claude Code** to work on **one** of the sibling projects under
`workspace/` through a fixed, gated workflow:

> **plan** → adjust & confirm → **implement** in an isolated git worktree (TDD, full access,
> no questions) → **run tests** → **review** → update **CLAUDE.md/docs** if needed →
> **show you the diff and stop.**

The next session you start in that repo picks up where you left off: it looks for worktrees whose
PR is merged and offers to **drop the worktree, the branch, and the hand-offs the work implemented**.
It asks first, and it never touches a worktree that still has uncommitted changes.

Claude never commits, pushes, merges, or opens a PR. It leaves the finished work as **uncommitted
changes** on the chosen branch/worktree and hands it back to you — you decide what to commit, merge,
or open a PR for, in your own time.

There are two launchers, with the same contract and the same workflow. They differ in one thing
that matters: **only `cwl` confines writes to the chosen repo.**

- `bin/cw` runs the session inside the workspace devcontainer, which mounts the whole tree
  read-write. It names a target repo and starts there, but nothing stops a write elsewhere.
  Plan mode is the only gate.
- `bin/cwl` skips Docker and runs Claude Code on the host inside Claude Code's own sandbox, which
  does confine writes to the target repo — see
[Running without Docker](#running-without-docker-cwl).

If a change needs another project, the workflow never edits it — it writes a self-contained
**hand-off prompt** to the shared inbox at `workspace/HANDOFFS/` (created by `cw`, alongside the
org dirs), named `<org>__<repo>__<slug>.md` — e.g. `relaton__relaton-bib__add-http-retry.md`.
Mounted at `/workspaces/HANDOFFS`, this inbox is the only writable spot outside the target repo, and it
takes hand-off prompts only, never code. Next time you run `cw` in the repo a hand-off is addressed
to, that session reads its pending hand-offs while planning and tells you about them — so there's
nothing to copy around by hand. When the merged work implements a hand-off, that session offers to
archive the file into `workspace/HANDOFFS/done/` — it asks first, and it moves the file rather than
deleting it. Nothing else retires a hand-off, so you can always do it by hand.

## One-time setup

```bash
# clone this repo as a sibling of your project repos, under the shared root:
cd workspace
git clone https://github.com/relaton/claude-container.git

cd claude-container
chmod +x bin/cw session-setup.sh

# The image belongs to the workspace devcontainer, one level up:
docker compose -f ../.devcontainer/docker-compose.yml build

# Ruby and Claude Code live in the shared volumes, not in the image. Open the
# workspace devcontainer in VS Code once, so its post-create.sh fills them. `cw`
# stops with a message until it finds them.
# optional: put bin/ on your PATH, e.g.
#   export PATH="$PWD/bin:$PATH"
```

### Authenticate Claude (once; persists in the `claude-config` volume)

On macOS, Claude Code's login lives in the **Keychain**, not in `~/.claude`, so it can't be
bind-mounted into a Linux container. Do one of:

```bash
# A) log in once inside the container (token persists in the named volume):
docker exec -it "$(docker compose -f ../.devcontainer/docker-compose.yml ps -q dev)" claude login

# B) or export CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) or ANTHROPIC_API_KEY
#    in the shell you run `cw` from; `cw` forwards both.
```

A VS Code session in the same container shares this login.

For **pushing**, `cw` passes the host's GitHub token (via `gh auth token`, so it works even when the host keeps it in
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

Both launchers turn off the built-in plugin `cc-plugin-diff@builtin`. Claude Code 2.1.323 added
it as the new `/diff` panel. That panel reads the cwd one time, when the session starts. `/feature`
then moves the session into the worktree, so the panel shows the clean main checkout and is empty.
With the plugin off, the old panel serves `/diff`, and it follows the cwd. A plain `claude`
session needs the same key in `~/.claude/settings.json`:

```json
"enabledPlugins": { "cc-plugin-diff@builtin": false }
```

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
docker exec -it -w /workspaces/relaton/relaton-bib \
  -e GH_TOKEN -e CW_HANDOFFS=/workspaces/HANDOFFS \
  "$(docker compose -f ../.devcontainer/docker-compose.yml ps -q dev)" \
  /usr/local/bin/cw-session-setup \
  claude --permission-mode plan --allow-dangerously-skip-permissions "/feature add retry logic"
```

`bin/cw` also passes the git settings for the session (`GIT_CONFIG_COUNT` and friends), which the
line above leaves out for brevity.

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
the same freshness the session setup's re-seed gives the container.

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

| | `cw` (shared devcontainer) | `cwl` (native sandbox) |
|---|---|---|
| Writable | **all of `workspace/`** | target repo, `HANDOFFS`, plus the gem caches bundler needs |
| Readable | all of `workspace/` | same, via `--add-dir`, plus the toolchain paths listed below; nothing else under `/Users` or `/Volumes` |
| Bash confinement | **none** | Seatbelt, `failIfUnavailable: true` so it never silently degrades |
| File-tool confinement | **none** | `permissions.deny` rules (permission layer) |
| Network | **unrestricted** | deny-all except an allowlist |
| Toolchain | mise in the shared volume, so each repo gets the Ruby it pins | the host's — so asdf gives each repo *its own* Ruby |

`cw` had a boundary until the two stacks were merged into one container. Sharing the devcontainer
is what removed it: that container mounts the tree read-write for VS Code, and a `docker exec` into
it inherits exactly that. Use `cwl` when the boundary is the point.

#### The read allowlist

Under `cw` the read boundary comes for free: only `workspace/` is mounted into the container, so
nothing else on the host exists there. `cwl` runs on the real filesystem, so `/Users` and `/Volumes` are denied wholesale and
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
private metanorma gems. `gh run view --log-failed --job <id>` prints the job log rather than a
network denial.

#### Java

Metanorma validates XML with Jing, a Java program that the `ruby-jing` gem starts. Two defects
stop Java in the sandbox, so `cwl` writes a small env file and gives it to Claude Code as
`CLAUDE_ENV_FILE`. Claude Code sources that file in the Bash shell before each command:

```bash
export JAVA_HOME=/Library/Java/JavaVirtualMachines/<jdk>/Contents/Home
unset JAVA_TOOL_OPTIONS
```

- **`JAVA_HOME`.** The `/usr/bin/java` stub runs `java_home`, and `java_home` reads the sysctl
  `kern.grade_cputype`. The sandbox profile does not allow that sysctl, so `java` fails with
  `Unable to locate a Java Runtime`. With `JAVA_HOME` set, the stub does not run `java_home`.
  `cwl` uses your `JAVA_HOME`, or it asks `/usr/libexec/java_home` on the host.
- **`JAVA_TOOL_OPTIONS`.** The sandbox sets it to `-Djava.net.preferIPv4Stack=true`, so Java
  writes `Picked up JAVA_TOOL_OPTIONS: ...` to stderr. `ruby-jing` raises on each stderr line
  that it does not know, and metanorma then stops with `Jing failed with error`.

Settings cannot unset a variable, which is why a file does this work. The shell that sources the
file is inside the sandbox, and the session cannot write to the file.

Java has no network in `cwl`. Java ignores `HTTPS_PROXY`, and the sandbox proxy needs Basic auth,
which Java turns off for tunnels. `~/.m2` and `~/.gradle` are not in the read allowlist either, so
Maven and Gradle builds fail.

Verified in a session: Jing accepts a valid file and reports the error in an invalid one.

#### The network allowlist

Egress is deny-all. `cwl` opens four groups:

| Group | Domains |
|---|---|
| Anthropic | `api.anthropic.com`, `claude.ai`, `platform.claude.com`, `statsig.anthropic.com` |
| GitHub | `github.com`, `*.github.com`, `objects.githubusercontent.com`, `raw.githubusercontent.com`, `codeload.github.com` |
| Actions logs and artifacts | `*.actions.githubusercontent.com`, `*.blob.core.windows.net` |
| Package registries | `rubygems.org`, `*.rubygems.org`, `registry.npmjs.org`, `*.npmjs.org` |

`github.com` and `githubusercontent.com` are different apex domains, so `*.github.com` does not
cover the content hosts — each one has to be named.

The Actions pair is the reason a session can read CI. `gh run view --log` calls
`results-receiver.actions.githubusercontent.com`, then follows a signed redirect into
`productionresultssaNN.blob.core.windows.net`. Deny either one and the session sees only
`Process completed with exit code 1`, which is the least useful line in the log. The storage
account number rotates, so that entry has to be a wildcard; the cost is that every Azure blob
account is reachable. See the caveat below on what the allowlist is and is not.

Anything else goes in `CWL_EXTRA_DOMAINS`.

This allowlist reaches `cwl` sessions only. `cwl` passes it with `--settings`, so a plain `claude`
session started by hand never sees it and falls back to your global `~/.claude/settings.json`. If
that file sets `sandbox.network.strictAllowlist` without an `allowedDomains` list, the plain
session denies every host and does not prompt, which looks exactly like this bug and is not fixed
by anything in this repo. Give the global file its own list:

```json
"sandbox": {
  "network": {
    "strictAllowlist": true,
    "allowedDomains": ["*.actions.githubusercontent.com", "*.blob.core.windows.net"]
  }
}
```

Domains merge across settings sources, so this widens `cwl` too — by the same two hosts it already
carries.

### The honest caveat

In `cwl`, a write by the **file tools** is blocked by a permission rule — strong in practice, but
policy rather than physics, and it depends on the deny list being complete. It is still the
stronger of the two launchers: `cw` does not block that write at all. The list is regenerated from the actual directory contents on
every launch, so a newly cloned repo is covered the next time you start a session.

`sandbox.allowUnsandboxedCommands` is set to `false`, which closes the escape hatch that would
otherwise let a blocked Bash command be re-run outside the sandbox.

### Folder trust

`cwl` pre-accepts the folder-trust prompt for the target repo by setting
`projects[<repo>].hasTrustDialogAccepted` in `~/.claude.json` before launching — the same thing
`session-setup.sh` does inside the container. Trust is stored **per project directory**, so a repo
you have never opened before would otherwise prompt on every start.

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

The devcontainer mounts the **parent** of `claude-container/` (the whole `workspace/` tree) at
`/workspaces`, and `cw` derives the target from an `<org>/<repo>` layout. So put `claude-container/` and
your project repos side by side under one root, with each repo two levels down as `<org>/<repo>`:

```text
workspace/                       # ← mounted read-write at /workspaces
├── claude-container/         # this tooling repo (a sibling, not a project to work on)
├── HANDOFFS/                 # shared cross-project hand-off inbox (writable at /workspaces/HANDOFFS)
│   └── done/                 #   └─ archive for hand-offs that are implemented and merged
├── relaton/                  # <org>
│   ├── relaton-bib/          #   └─ <repo>   → cw relaton/relaton-bib "..."
│   └── relaton-cli/          #   └─ <repo>
└── metanorma/                # <org>
    └── metanorma-cli/        #   └─ <repo>   → cw metanorma/metanorma-cli "..."
```

- The root can have any name/location — `cw` finds it as the parent of `claude-container/`.
- Each `<org>/<repo>` must be a **git repo** (`cw` checks for `.git`). `cw` starts the session there
  and worktrees go under its own `.claude/worktrees/`, but the rest of the tree is writable too —
  see the boundary table above.
- `claude-container` itself is reserved as the tooling dir, so it can't be a `cw` target.

## How it works

| Piece | Role |
|-------|------|
| `Dockerfile` | the **single** image for this launcher and for `../.devcontainer`: ubuntu 24.04 + git ≥ 2.48 + gh + ripgrep + jq + java (JRE for ruby-jing) + native-gem build deps + mise; non-root `vscode` user. Ruby and Claude Code live in the shared volumes, not in the image. |
| `../.devcontainer/docker-compose.yml` | the only compose file: builds this directory, mounts `workspace/` at `/workspaces`, and owns the `home-local` and `claude-config` volumes. |
| `bin/cw` | host launcher; resolves the target repo, starts the devcontainer if it is down, and `docker exec`s the session into it with per-session git settings. |
| `bin/cwl` | host launcher (no Docker); same resolution, but generates per-session sandbox settings and file-tool deny rules. |
| `bin/install-local` | one-time host setup for `cwl`: symlinks the skill and `mkworktree`, checks prerequisites. |
| `image/commands/feature.md` | the `/feature` workflow skill (baked into the image). |
| `image/settings.json` | container Claude defaults (model = opus). |
| `session-setup.sh` | run by `cw` through `docker exec`: checks the Ruby install, re-seeds the skill if the volume hid it, pre-accepts folder trust. |

### Worktrees

Right after you approve the plan, the workflow **asks** whether to isolate the work. If you pick
an isolated worktree, it creates the branch in a worktree **inside the repo**:

```
workspace/<org>/<repo>/.claude/worktrees/<branch>/
```

The dir is excluded locally via `.git/info/exclude`, so it never shows as untracked or gets
committed (no change to the repo's tracked `.gitignore`). Living inside the target repo, the
worktree rides its read-write mount — no separate mount needed.

**The session moves in with it.** The workflow enters the worktree with Claude Code's
`EnterWorktree` tool, not with a `cd`, so every later tool call — file reads and edits, the loaded
`CLAUDE.md`, the plans directory — runs in the worktree. Your own shell is untouched: the launcher
changes the directory in its own process, so your terminal stays where you started it. When the
session ends, Claude Code asks whether to **keep or remove** the worktree. Answer **keep**: the
worktree and the branch are meant to survive, and the cleanup below is where they are dropped.

**Host compatibility.** The container mounts the repo at `/workspaces/...` but on the host it's at
`/Users/.../workspace/...`. Git normally bakes an absolute path into a worktree's `.git` link, which
would make host-side `git status` fail (`not a git repository: /workspaces/...`). The container ships
**git ≥ 2.48** and sets `worktree.useRelativePaths=true` globally, so `git worktree add` writes
**relative** links for both the forward `.git` link and the repo-side backlink — they resolve
whether the repo is seen at `/workspaces/...` or `/Users/...`. Result: you can `git status`/diff/commit
inside the worktree from **both** the container and the host, and even a bare `git worktree add`
(not just the helper) stays host-reachable. The baked **`mkworktree`** helper
(`image/bin/mkworktree`, on `PATH`) is still preferred — it just adds the convenience of a fixed
location under `.claude/worktrees/`, a conventional `<type>/<slug>` branch name (e.g.
`feat/add-http-retry`), and the local exclude.

> Git auto-sets the per-repo `extensions.relativeWorktrees` flag on the first relative worktree.
> Your host git (2.50) understands it; very old host git/libgit2 tooling may not.

The worktree and branch are left in place when Claude stops, so you can review and finalize the
changes from the host. You commit, open the PR, and merge in your own time.

**Cleanup happens on the next run.** When you next start `cw` or `cwl` in that repo, the workflow
surveys `.claude/worktrees/` before it plans anything. For each worktree it asks GitHub whether the
branch's PR is merged (`gh pr list --head <branch>`), and falls back to `git branch --merged` when
there is no PR — the `gh` check first, because a **squash merge** leaves git itself unable to see
the merge. It then offers to drop the finished ones. Approve, and it:

1. updates the parent branch from the remote (`git pull --ff-only`, or `git fetch origin
   <parent>:<parent>` when the checkout is on another branch) — **before** the removal, because the
   branch about to be deleted holds the only local copy of the merged work;
2. runs `git worktree remove`, deletes the branch, runs `git worktree prune`, and removes the empty
   `<type>/` parent directory that a slashed branch name leaves behind;
3. archives the hand-offs that the merged branch implemented into `HANDOFFS/done/`.

It asks before each of these, never uses `git worktree remove --force`, and keeps any worktree that
still has uncommitted changes or unmerged commits. So nothing disappears without your say-so — and
you can still do it by hand (`git worktree remove .claude/worktrees/<branch>`).

**One limit under `cwl`.** Claude Code lists `.git/worktrees/` when the session starts, and it
protects each entry from writes. A worktree that was already there therefore cannot be removed from
inside that session. It takes the list again when the session moves into a worktree, so the session
cannot drop that worktree either. The workflow tests for this first, so it keeps the worktree whole,
and it **queues** the drop instead. `cwl` runs the queue in plain bash when the session ends, and it
asks you once more on the terminal:

```
cwl: the session approved these worktree drops:
  fix/ecma-fetcher  ->  .claude/worktrees/fix/ecma-fetcher
cwl: remove them and their branches? [y/N]
```

Answer `n`, or press Enter, and nothing is removed. The launcher re-checks each entry itself before
it asks — the path must sit in this repo's `.claude/worktrees/`, git must still list it as a
worktree here, and the worktree must be clean — and it never uses `--force`. `cw` has no such limit,
because the container has no sandbox.

## Updating Claude Code

Claude Code is **not** in the image. It lives in the shared `home-local` volume, installed by
`../.devcontainer/post-create.sh`, so it updates itself in place and survives an image rebuild.
`cw` and the devcontainer always run the same version.

To force a version:

```bash
docker run --rm -v ribose-dev_home-local:/home/vscode/.local ribose-workspace:latest \
  npm install -g @anthropic-ai/claude-code@2.0.34 --prefix /home/vscode/.local
```

Rebuilding the image changes only the system toolchain (git, gh, java, the build deps):

```bash
docker compose -f ../.devcontainer/docker-compose.yml build   # add --no-cache for a clean build
```

Then **Rebuild Container** in VS Code, so the running container picks the new image up. Your login
is unaffected — it lives in the `claude-config` volume, not the image.

## One container for `cw` and VS Code

`Dockerfile` here is the only Dockerfile in the workspace, and
`../.devcontainer/docker-compose.yml` is the only compose file. It builds this directory as
`ribose-workspace:latest` and runs `sleep infinity`. VS Code attaches to that container, and `cw`
runs `docker exec` into the same one. Ruby, the gems and Claude Code live in the
`ribose-dev_home-local` volume, the login and history in `ribose-dev_claude-config`, so each
installs once and both see the same versions.

Four consequences to know about:

- **`cw` has no write boundary.** The container mounts the tree read-write for VS Code, and an
  `exec` into it inherits that. See the boundary table above.
- **Nothing `cw` runs may write `~/.gitconfig`.** The dev containers extension owns that file: it
  copies your host identity in and installs a credential helper that proxies to the host. `bin/cw`
  sets its git configuration **per process** instead, with `GIT_CONFIG_COUNT`, so your VS Code
  terminals keep theirs.
- The image carries **no `ENTRYPOINT`**. The container runs `sleep infinity` on it, and an
  entrypoint would wrap that command. `cw` runs `cw-session-setup` as the command of its `exec`.
- A `bundle install` in a VS Code terminal and one in a `cw` session write the same `GEM_HOME`.
  mise installs are idempotent, but two gem installs at the same time can race. Run one at a time.

## Notes & caveats

- The session starts in **plan mode** (`--permission-mode plan`), so Claude must present a plan
  and have it approved before it can edit anything — a harness-level gate, not just an instruction.
  It's paired with `--allow-dangerously-skip-permissions` so that, once you approve the plan
  (choose "accept edits", or `Shift+Tab` to the bypass mode), implementation runs autonomously.
  Since `cw` moved into the shared devcontainer, **nothing backs that bypass up**: the container
  mounts the whole tree read-write, so an approved plan can edit any repo. Plan mode is the gate.
  The isolation-choice gate and the "never commit/push/merge/PR — stop and hand back the diff"
  rule are enforced by the skill, not the permission layer, so they rely on Claude following the
  workflow prompt. Use `cwl` when you want the boundary enforced.
- `cwl` deliberately does **not** use that flag. Its file-tool boundary is the generated
  `permissions.deny` list, and `--allow-dangerously-skip-permissions` would skip it. Bash still
  runs without prompts, via `autoAllowBashIfSandboxed`, so in practice the two feel the same.
- Ruby comes from mise in the shared volume, so a repo with a `.ruby-version` gets that version
  if it is installed. `mise install` in the repo adds one. The global default is 3.4.
- The network allowlist (both launchers' sandboxes) matches on the client-supplied hostname
  without inspecting TLS, so it is a guardrail against accidental egress, not a defence against
  deliberate exfiltration.
- `cwl`'s deny list is regenerated from the workspace contents at every launch, so a repo cloned
  mid-session is not covered until the next start.
- Every `cw` call `exec`s into the same long-running container. Repos live on the host mount,
  the login in the `claude-config` volume and the gems in `home-local`, so a bundle installed in
  one session is there in the next one and in your VS Code terminals.
