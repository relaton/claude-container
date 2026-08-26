# claude-container

This repo holds two launchers. Each one starts Claude Code on **one** sibling project under
`workspace/` and confines the session to that project. Read `README.md` first for the user-facing
contract. This file records the rules that are easy to break.

## Layout

| Path | Role |
|---|---|
| `bin/cw` | Docker launcher. Boundary is the mount namespace. |
| `bin/cwl` | Host launcher. Boundary is Claude Code's native sandbox plus permission rules. |
| `bin/install-local` | Symlinks `image/` assets onto the host for `cwl`. |
| `Dockerfile`, `compose.yml`, `entrypoint.sh` | The `cw` image and its startup. |
| `image/settings.json` | Baked into the image. `cw` only. `cwl` does not read it. |
| `image/commands/feature.md` | The `/feature` workflow. Both launchers use it. |

`RIBOSE_ROOT` is the parent of this repo. Both launchers derive it the same way.

## The two boundaries

`cw` mounts `workspace/` read-only and overlays the target repo read-write. Writes are impossible
elsewhere. Network egress is **unrestricted**.

`cwl` runs on the real filesystem, so it states the boundary in two layers:

- **Kernel (Seatbelt)** covers Bash and every process it starts. Set by `sandbox.*` in the
  generated settings.
- **Permission rules** cover Read, Edit, Write, MCP servers, and hooks. These run inside the
  Claude Code process, so the sandbox does not reach them. Set by `permissions.deny`.

The two layers resolve conflicts in opposite directions. The sandbox honours `allowRead` over
`denyRead`. The permission layer lets deny beat allow. A blanket permission deny is therefore
final, which is why `cwl` walks `/Users` and denies siblings one by one instead.

## Rules

**Never add `--allow-dangerously-skip-permissions` to `cwl`.** That flag skips the deny rules that
form the file boundary. `cw` can use it because the mount namespace does the work.

**Edit the settings in the jq filter in `bin/cwl`** (around line 221). The launcher writes a
per-session `settings.json` into a temp directory and passes it with `--settings`. Do not put
launcher policy in `image/settings.json`; that file reaches `cw` only.

**Keep one label in front of a `*.` domain.** The docs guarantee only that a leading `*.` is
honoured. They do not state how many labels it matches. `*.actions.githubusercontent.com` matches
`results-receiver.actions.githubusercontent.com` under either reading. `*.githubusercontent.com`
does not.

**`github.com` and `githubusercontent.com` are different apex domains.** `*.github.com` never
covers a content host. Name each one.

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
