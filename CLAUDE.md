# claude-container

This repo holds two launchers. Each one starts Claude Code on **one** sibling project under
`workspace/`. Only `cwl` confines the session to that project; `cw` names it but no longer
enforces it. Read `README.md` first for the user-facing
contract. This file records the rules that are easy to break.

## Layout

| Path | Role |
|---|---|
| `bin/cw` | Docker launcher. Runs in the shared devcontainer. **No write boundary.** |
| `bin/cwl` | Host launcher. Boundary is Claude Code's native sandbox plus permission rules. |
| `bin/install-local` | Symlinks `image/` assets onto the host for `cwl`. |
| `Dockerfile`, `session-setup.sh` | The image, built by `../.devcontainer/docker-compose.yml`, and the per-session setup that `cw` execs. |
| `image/settings.json` | Baked into the image. `cw` only. `cwl` does not read it. |
| `image/commands/feature.md` | The `/feature` workflow. Both launchers use it. |

`RIBOSE_ROOT` is the parent of this repo. Both launchers derive it the same way.

## The boundaries

`cw` has **no write boundary any more**. It runs `docker exec` into the workspace devcontainer,
which mounts the whole tree read-write at `/workspaces`, and it still passes
`--allow-dangerously-skip-permissions`. A `cw` session can write to any repo in the workspace.
Plan mode is the one gate left. Network egress is **unrestricted**. `cwl` is the launcher that
still confines writes to one repo.

`cwl` runs on the real filesystem, so it states the boundary in two layers:

- **Kernel (Seatbelt)** covers Bash and every process it starts. Set by `sandbox.*` in the
  generated settings.
- **Permission rules** cover Read, Edit, Write, MCP servers, and hooks. These run inside the
  Claude Code process, so the sandbox does not reach them. Set by `permissions.deny`.

A **hook** is in neither layer. Claude Code starts a hook command itself, so Seatbelt never wraps
it, and it runs with the full rights of the user — tested: a `SessionStart` hook wrote into a
sibling repo and into a path that the sandbox denies to Bash. The generated settings define no
hooks, and that is load-bearing.

The two layers resolve conflicts in opposite directions. The sandbox honours `allowRead` over
`denyRead`. The permission layer lets deny beat allow. A blanket permission deny is therefore
final, which is why `cwl` walks `/Users` and denies siblings one by one instead.

## Rules

**There is one container, and `cw` shares it.** `../.devcontainer/docker-compose.yml` is the only
compose file left; it builds this directory as `ribose-workspace:latest` and runs `sleep infinity`.
VS Code attaches to that container, and `bin/cw` runs `docker exec` into it. `claude-container` has
no `compose.yml` of its own. That is what the user asked for, and it is what removed the boundary
described above — do not present `cw` as confining anything.

**Nothing `cw` runs may write shared container state.** The container outlives every session and
serves VS Code at the same time. Two rules follow, and both are load-bearing:

- **Never write `~/.gitconfig`.** The dev containers extension owns that file. It copies the host
  identity in and installs a credential helper that proxies to the host, and a VS Code terminal
  needs both. `bin/cw` sets its git configuration per process with `GIT_CONFIG_COUNT`, the same way
  `bin/cwl` does. It also passes `user.name` and `user.email` from the host, because a container
  that `cw` started itself never got the extension's copy.
- **`session-setup.sh` must stay idempotent.** It re-seeds the skill, pre-accepts folder trust and
  execs the session command. It is not an `ENTRYPOINT`: the image has none, because the devcontainer
  runs `sleep infinity` on it and an `ENTRYPOINT` would wrap that command.

**The image puts the mise SHIMS on `PATH`, not `mise activate`.** Claude Code runs non-interactive
shells, so `~/.bashrc` never runs and an activated mise never reaches the Bash tool. The shims need
no activation.

**`cw` starts the container when VS Code has not.** `docker compose up -d` does **not** run
`post-create.sh` — that is a devcontainer lifecycle hook, not a compose feature. Such a container
can therefore lack Ruby and Claude Code, which live in the `home-local` volume. `session-setup.sh`
tests for the Ruby install and stops with a message that names the fix.

**Never add `--allow-dangerously-skip-permissions` to `cwl`.** That flag skips the deny rules that
form the file boundary. `cw` passes it, and nothing takes over the work any more — that is the
price of the shared container. If `cw` ever needs a boundary back, give it a generated
`--settings` file with `permissions.deny` rules for the sibling repos, the way `bin/cwl` builds
one. Do not try to restore it with a read-only mount: there is no `cw` mount left to make.

**Keep `cc-plugin-diff@builtin` off in both launchers.** Claude Code 2.1.323 moved `/diff` into
that built-in plugin. The plugin reads the cwd one time, at `session.start`, and no later hook
updates it. `/feature` enters the worktree after the start, so the plugin diffs the clean main
checkout and shows an empty panel. With `enabledPlugins` set to `false`, the old panel serves
`/diff`, and it reads the live cwd — tested in a real session. Set the key in the jq filter in
`bin/cwl` and in `image/settings.json`. Turn the plugin on again only when it follows the cwd.

**Edit the settings in the jq filter in `bin/cwl`** (around line 221). The launcher writes a
per-session `settings.json` into a temp directory and passes it with `--settings`. Do not put
launcher policy in `image/settings.json`; that file reaches `cw` only. The whole filter is one
single-quoted shell string, so no comment in it may contain an apostrophe. One apostrophe closes
the string, and jq then fails to compile.

**Keep one label in front of a `*.` domain.** The docs guarantee only that a leading `*.` is
honoured. They do not state how many labels it matches. `*.actions.githubusercontent.com` matches
`results-receiver.actions.githubusercontent.com` under either reading. `*.githubusercontent.com`
does not.

**`github.com` and `githubusercontent.com` are different apex domains.** `*.github.com` never
covers a content host. Name each one.

**The `/feature` cleanup is the only place the workflow removes anything.** Step 9 in
`image/commands/feature.md` drops a worktree and its branch, and it archives an implemented hand-off
into `$CW_HANDOFFS/done/`. Three properties hold it in place, so keep all three in any edit: the
user approves the list first (the third mandatory gate), the parent branch is updated from the
remote **before** the branch is deleted, and a hand-off is **moved**, never deleted. `git branch -D`
is allowed only on `gh` evidence of a merge, because a squash merge defeats `git branch -d`.
`ExitWorktree` with `action: "remove"` destroys the same worktree and branch outside the gate, so
the workflow bans it. Step 9 leaves the worktree with `action: "keep"`, then removes it in the gate.

**A worktree from an earlier session cannot be removed inside a `cwl` session.** Claude Code reads
`.git/worktrees/` when the session starts. It denies every write to `commondir` and `config.worktree`
in each worktree that it finds there. Its sandbox also denies `unlink` on each parent directory of a
denied path, so `.git/worktrees/<id>/` stays. `git worktree remove` then deletes a part of the
checkout and stops with `Operation not permitted`. A worktree that the same session created is not in
that startup list, so it removes normally. Step 9 in `image/commands/feature.md` tests with
`touch <admin-dir>/commondir`, and it queues a blocked worktree instead of removing it. Do not
answer this with `allowUnsandboxedCommands`, and not with a hook either: each one opens an
unsandboxed command channel for everything, not for this one removal.

The **session** directory adds a second deny of the same shape, on `<cwd>/.git/config` and its
parents, so the worktree directory cannot be deleted either. Claude Code takes the list again when
`EnterWorktree` moves the session, and neither `ExitWorktree` nor a `cd` releases it — tested. A
`cwl` session therefore cannot drop a worktree that it entered, not even the one that Step 2 made
for it. Only a worktree that the session created and never entered removes in the session.

**The drop queue is where a blocked worktree goes.** `cwl` exports `CW_DROPS`, a per-repo file
under `$CW_HANDOFFS/drops/`. Step 9 appends `<worktree path> TAB <branch> TAB merged|unmerged` to
it, and `process_drops` in `bin/cwl` runs the queue in bash — outside the sandbox — before the
session starts and again after it ends. Three properties hold that runner in place: the user
confirms on the terminal, the runner re-checks every claim itself (the path is inside this repo's
`.claude/worktrees/`, git still lists it as a worktree here, and the worktree is clean), and
`git worktree remove` never gets `--force`. `git branch -D` needs `merged` in the third field, which
Step 9 writes only on `gh` evidence. The queue is consumed on every run, answered or not.

**`cwl` must not `exec` the session.** The launcher has to outlive Claude Code to run the queue
above. `exec` also skipped the `EXIT` trap, so every session leaked its generated settings directory
into `$TMPDIR`.

**`cwl` names the repo in `sandbox.filesystem.allowWrite`.** Seatbelt writes default to the cwd,
and `/feature` moves the session into `.claude/worktrees/<branch>` with `EnterWorktree`. Git in a
worktree still writes to `.git/worktrees/` in the main repo, so the repo path must stay explicit.

**`cwl` gives the session an env file with `CLAUDE_ENV_FILE`.** Claude Code sources it in the
sandboxed Bash shell before each command. It sets `JAVA_HOME` and unsets `JAVA_TOOL_OPTIONS`, and
Jing needs both (see README, "Java"). Keep the file in `cfg_dir`, where the session cannot write.
Do not set Java options with `JAVA_TOOL_OPTIONS` or `JDK_JAVA_OPTIONS`: Java prints a
`Picked up` line for each one, and `ruby-jing` then fails. The file is not a hook, and it must
stay that way: it runs inside the sandbox, not beside it.

**The global `~/.claude/settings.json` is a separate boundary.** `cwl` passes its own allowlist, so
a `cwl` session is unaffected by it. A plain `claude` session sees only the global file. A fix in
`bin/cwl` does not reach plain sessions, and the reverse is also true.

## Testing a change to the boundary

1. `CWL_DRY_RUN=1 bin/cwl <org>/<repo>` prints the launch line and keeps the generated settings.
   Read them with `jq`.
2. Start a real session and run the command that failed. The dry run proves the JSON shape only.
   It does not prove the kernel accepts it.
3. Prove the boundary still holds. A widened allowlist must still refuse an unrelated host.
4. Remove the kept temp directories afterwards.

Do not write "verified" into a commit message or the README until step 2 has run.

## Style

Write documentation and commit messages in ASD-STE100 Simplified Technical English: short active
sentences, one idea each, one meaning per word. Never rewrite an identifier, a path, a command, a
flag, or quoted output.
