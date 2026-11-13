---
description: Plan → choose isolation (worktree/branch) → TDD implement → test → review → docs → show the diff → stop (you drive commit/PR) → drop merged worktrees, scoped to a single repo.
argument-hint: <task description>
---

You are running inside an isolated container, started with full tool access
(`--dangerously-skip-permissions`). Drive the following **gated** workflow for the task:

> $ARGUMENTS

**DO NOT COMMIT — unless the user explicitly tells you to.** By default, do not run `git commit`
(or `git add`, `git push`, `git merge`, `gh pr create`, `gh pr merge`) at any point. Implement,
test, and review the work, then **stop** and leave the changes uncommitted for the user. Committing
is the user's job, not yours — do not do it on your own initiative, not even if it seems like the
obvious final step. **The only exception is an explicit, unambiguous instruction from the user**
(e.g. "commit this", "commit and push", "open a PR") — then you may run exactly the git/`gh` action
they asked for, and nothing more.

**DO NOT DESTROY — unless Step 9 says you may.** The same rule covers `git worktree remove`,
`git branch -d`, `git branch -D`, `git pull`, and any `mv` or `rm` of a hand-off file. Run them only
through the gated cleanup in Step 9, and only after the user approves the list. The cleanup's pull
is always `--ff-only`; it never merges. **Never call `ExitWorktree` with `action: "remove"`.** That
deletes the worktree and the branch outside the gate. Step 9 removes a worktree, and only there.

## Hard rules (read first)

- **Single-project boundary.** The current repo (your working directory) is the ONLY project
  you may modify. Every other project in the workspace is **readable but not writable** — you may
  read them for context, but any write to them will fail. **Never** try to edit them.
  The one exception is the shared inbox at `$CW_HANDOFFS`, which IS writable: it takes
  hand-off prompts (Step 8), and Step 9 moves a finished one into `$CW_HANDOFFS/done/`. Nothing
  else. Never put code there, and never treat it as a way around the boundary.
- **You stop when the work is done — you do not finalize it on your own.** Your job ends at Step 7:
  implement, test, review, then show the user the diff and stop. (Steps 8 and 9 are conditional —
  they run only when the task needs a hand-off, or when the user approves a cleanup.) **Do not
  `git commit`, `git add`, `git push`, `git merge`, `gh pr create`, or `gh pr merge` on your own
  initiative** — leave the changes as uncommitted working-tree edits on the chosen branch/worktree.
  The user reviews them and decides what to commit, merge, or open a PR for — that is their call, in
  their own session or by hand. **If the user explicitly asks you to commit, push, merge, or open a
  PR, do it** — perform exactly the action requested, then stop.
- **Mandatory human gates** — you MUST stop and use `AskUserQuestion` (or wait for an explicit
  user reply) at each of these, and never skip them:
  1. plan confirmation, 2. isolation choice (worktree/branch), 3. cleanup confirmation — before you
  remove any worktree, delete any branch, or move any hand-off file.
- **You start in plan mode — that IS the plan gate.** The session launches in plan mode, so the
  harness blocks every edit until you present a plan and the user approves it (Step 1). Don't try
  to work around it. **Approving the plan is NOT authorization to edit in place:** the moment you
  leave plan mode your FIRST action is Step 2 (the isolation gate), and you may not modify a file
  until that gate is resolved.
- **Isolation-before-edit invariant.** You may not create or modify a single file until the
  Step 2 isolation gate is resolved — i.e. you are in the chosen worktree, on the chosen new
  branch, or the user has explicitly chosen to work on the current branch. Never start editing
  the repo's checked-out branch by default; working in place must be a deliberate, confirmed
  choice from Step 2.
- **Everything between the gates runs autonomously** — implementation, tests, and review need
  no questions. Do not ask permission for ordinary edits/commands; just do the work.
- **Cross-project changes are never made inline.** If the task needs a change in a related
  project, emit a hand-off prompt (see Step 8) instead of editing it.

## Steps

### 1. Plan (GATE)
You begin in **plan mode** — you cannot edit yet, which is intended. Identify the repo from the
working directory.

**Check the hand-off inbox first** for work another session addressed to this repo:
`ls "$CW_HANDOFFS"/<org>__<repo>__*.md 2>/dev/null`. If any exist, read them and tell the user
what is pending. If one covers or overlaps the requested task, fold it into the plan and say so;
otherwise just list them as known pending work and carry on with the task you were given. Never
delete a hand-off file. Step 9 archives one into `$CW_HANDOFFS/done/`, and only with the user's
approval — nothing else touches the inbox.

**Then sweep for finished worktrees** left by earlier sessions. A merged PR leaves its worktree and
branch behind, so they collect. Run the survey in the **main repo root**:

- `git fetch origin --prune` first. Both merge tests read stale refs otherwise, and a branch merged
  since the last fetch then looks unmerged.
- `git worktree list --porcelain` — this is the source of truth. Do **not** use `find`: it picks up
  sandbox artifacts such as `.claude/worktrees/.claude/.cc-writes` and reports them as worktrees.
  Skip the main worktree; consider only paths under `.claude/worktrees/`.
- `git worktree prune` — safe to run always. It clears registrations whose directory is already
  gone, and it never touches a live worktree.
- A directory under `.claude/worktrees/` that `git worktree list` does **not** name is an orphan.
  Report it and leave it alone — you cannot tell what is in it. Ignore `.claude/worktrees/.claude/`,
  which is a sandbox artifact and not a worktree.
- For each remaining worktree branch, decide **finished**:
  1. `gh pr list --head <branch> --state all --json number,state,mergedAt`. A non-null `mergedAt`
     means the PR is merged. Use `pr list`, not `pr view` — `pr view` errors when no PR exists.
  2. If there is no PR, or `gh` fails, fall back to
     `git branch --merged <default-branch> --list <branch>`.
  3. A closed but unmerged PR is reported only. Never drop it.
- For each finished branch, decide **safe to drop**: `git -C <worktree> status --porcelain` is empty,
  **and** `git log --oneline <default-branch>..<branch>` shows no commit that the merge did not take.
  A dirty or ahead worktree is reported and kept, whatever the PR says.
- Under `cwl` the sandbox refuses to delete a worktree that was already there when the session
  started. Step 9 tests for this, keeps such a worktree whole, and queues the drop for the launcher
  to run when the session ends. Say so in the report, so the user knows why a finished worktree
  stays until then.
- Report the result with the pending hand-offs. If anything is finished and safe, **GATE**: ask the
  user with `AskUserQuestion` which worktrees to drop, then run Step 9 on the approved ones before
  you continue with the plan.

Research with the `Explore` agent and by reading relevant files (including
read-only related projects if useful). Produce a concise plan: goal, files to change, test
strategy, and a short **branch name** — a conventional, type-prefixed, kebab-case name describing
the work: `<type>/<slug>` where `<type>` is one of `feat`, `fix`, `chore`, `docs`, or `refactor`
(e.g. `feat/add-http-retry`, `fix/null-deref`). Present the plan and
**iterate with the user until they approve it** (refine the details via conversation or
`AskUserQuestion`; the user approves through the plan-mode prompt). Do not proceed until approved.
Leaving plan mode does **not** mean "start editing" — your very next action is Step 2 (isolation).

### 2. Isolation (GATE — the moment the plan is confirmed, before any file change)
**As soon as the user approves the plan, your very first action — before editing, before any
other tool call — is to ask how to isolate the work** with `AskUserQuestion`. Do not write a
file first. Offer these options:
1. **Isolated worktree + new branch** (recommended — leaves the repo's checkout untouched and
   lets the user review the work from the host).
2. **New branch, in place** (work in the main checkout on a fresh branch, no separate worktree).
3. **Current branch, in place** (no new branch — only when the user explicitly wants this).

Let `<branch>` be the type-prefixed branch name from the plan (e.g. `feat/add-http-retry`). Then:
- **Option 1** — create and enter the worktree with the baked helper. Prefer `mkworktree` over a
  bare `git worktree add`: it places the worktree under the repo's own `.claude/worktrees/` (so
  it's physically present on the host), names the branch, and adds a local exclude so the dir
  never shows as untracked. The container's git (≥2.48) writes **relative** worktree links — and
  the container sets `worktree.useRelativePaths=true` globally — so the worktree is readable from
  both the container (`/workspaces/...`) and the host (`/Users/...`):
  ```
  mkworktree <branch>          # creates .claude/worktrees/<branch> on branch <branch>
  ```
  Then **move the session into it** with the `EnterWorktree` tool. Set `path` to the absolute
  worktree path — `$(git rev-parse --show-toplevel)/.claude/worktrees/<branch>` — and never set
  `name`: `mkworktree` already created the worktree, and `name` creates a second one without the
  relative links. `EnterWorktree` moves the **session** directory, so the file tools, the loaded
  `CLAUDE.md`, and the plans directory all follow. A `cd` moves the Bash tool only and leaves the
  rest of the session in the main checkout, so `cd` is the fallback, not the method.
  `EnterWorktree` asks for an explicit instruction to work in a worktree. Option 1 at this gate
  **is** that instruction: the user chose the worktree.
  If the tool is unavailable, or it refuses the path, run `cd .claude/worktrees/<branch>` instead
  and report the fallback in the Step 7 summary.

  Confirm: `git rev-parse --show-toplevel` prints a path ending in `/.claude/worktrees/<branch>`,
  and `git status --porcelain` in the main repo does **not** list `.claude/`.
- **Option 2** — `git checkout -b <branch>` in the repo root.
- **Option 3** — stay on the current branch; do nothing here.

Record three facts: the **working branch** (`<branch>` for options 1–2, else the current branch),
the **parent branch** (the branch you cut from — normally the repo's default branch), and
**whether a worktree was created**. The final hand-back (Step 7) reports the first and the third;
the cleanup (Step 9) uses all three. Do all subsequent work from the chosen location.

### 3. Implement — TDD (no questions)
**Self-check before the first edit:** confirm you are where Step 2 decided — inside the worktree
(Option 1: `pwd` and `git rev-parse --show-toplevel` both end in `/.claude/worktrees/<branch>`),
on the new branch via `git branch --show-current` (Option 2), or the current branch
the user explicitly approved (Option 3). If Step 2 hasn't happened yet, stop and do it now —
never default to editing the checked-out branch.
Tests-first loop:
1. Write **failing** rspec spec(s) under `spec/` capturing the new/changed behavior (a bug fix
   gets a regression spec).
2. Run just those specs and confirm they fail **for the right reason**.
3. Implement the code until those specs pass.
Keep cycles small. Make all edits in the worktree.

### 4. Test — full suite (no questions)
Run `bundle install` if dependencies changed, then the repo's full test command — prefer
`bundle exec rake` if a default task exists, else `bundle exec rspec`. Run `bundle exec rubocop`
if the repo is configured for it. The new specs **and** the entire existing suite must be green.
Iterate until green; if something genuinely can't be resolved, report it clearly.

### 5. Review (no questions)
Spawn the `code-reviewer` agent on the diff (`git diff main` or against the repo's default
branch). Summarize findings and apply fixes for anything material; re-run tests after.

### 6. Docs / CLAUDE.md (no questions)
If the change warrants it, update **this repo's** `CLAUDE.md` (new conventions, public API,
build/test commands, architecture notes) and, following the repo's existing convention, its
`README` / `CHANGELOG`. If nothing needs documenting, skip silently — do not manufacture churn.

### 7. Hand back — show the diff, then stop (no commit, no PR by default)
This is where you finish. **By default, do not commit, push, merge, or open a PR** — leave every
change as uncommitted working-tree edits on the branch/worktree from Step 2. (The sole exception is
an explicit user instruction to commit/push/merge/open a PR — then do exactly that and stop.)
Present a clear summary so the user can review and decide what to do next:
- the **working branch** and whether a **worktree** was created;
- if a worktree was used, its **host path** (`.claude/worktrees/<branch>`) so the user can open the
  files directly on their machine, and the fact that the session itself runs there. Tell the user
  that Claude Code asks to **keep or remove** the worktree when the session ends, and that the
  answer is **keep** — this workflow leaves the worktree and the branch in place. The user's own
  shell directory does not change; the launcher moves only its own process;
- the **changed-files list** (`git status --porcelain`) and a **diff overview** (`git diff --stat`,
  plus the key hunks so they can see what changed);
- the **test result** (and rubocop, if run);
- any **cross-project hand-off** files written to `$CW_HANDOFFS/` in Step 8, by full path;
- what the Step 1 sweep found — the worktrees Step 9 dropped, the ones it kept and why, or that
  there was nothing to drop.

Then stop and let the user take it from here — by default they will commit / merge / open a PR
themselves when and how they choose. Do not ask "should I commit?" or offer to do it; handing back
the reviewed, uncommitted changes is the end of your job — **unless** the user explicitly tells you
to commit / push / merge / open a PR, in which case carry out exactly that request and then stop.

### 8. Cross-project hand-off (only if needed)
If the task requires changes in a related project (e.g. this repo needs a new method in another
gem):
- Do **not** edit that project.
- Write a self-contained hand-off prompt — target project, what to change, required
  API/signature, why, and how this repo will consume it.
- Print it AND save it to the shared inbox at
  `$CW_HANDOFFS/<other-org>__<other-repo>__<slug>.md`, where `<slug>` is a kebab-case
  description of the change (e.g. `$CW_HANDOFFS/relaton__relaton-bib__add-http-retry.md`). The
  `<org>__<repo>__` prefix is what lets the target repo's next session find it, so get it right.
  If that exact filename already exists, do **not** clobber it — choose a distinct slug.
- Mention the file (by full path) in the Step 7 summary. Tell the user they can pick it up later
  by starting a session in `<other-org>/<other-repo>` (`cw` or `cwl`) — that session reads the inbox at Step 1 and
  will surface the hand-off itself, so there is nothing to paste.
- A hand-off you write is never yours to retire. The **target** repo's session archives it in its
  own Step 9, once the change is merged there.

### 9. Cleanup — drop a finished worktree (GATE)
This step is a procedure, not a stage. Two things call it, and nothing else:
- the **Step 1 sweep**, after the user approves the list of finished worktrees;
- the **end of an in-session merge** — the user explicitly told this session to open or merge a PR,
  and `gh pr view --json state,mergedAt` shows it merged.

Never start it on your own initiative, and never without the Step 1 gate. If the user did not
approve a specific worktree, leave it alone.

**First, update the parent branch.** The merge landed on the remote, so the local parent branch is
behind, and the branch you are about to delete holds the only local copy of that work. Update the
parent **before** the removal:

```
git fetch origin --prune
git pull --ff-only                  # only when the main checkout is ON <parent> and clean
git fetch origin <parent>:<parent>  # otherwise — fast-forwards the ref, no checkout change
```

The two cases are separate because `git fetch origin <parent>:<parent>` fails when `<parent>` is the
checked-out branch. Never pull a dirty checkout, and never merge. If the checkout is dirty, or the
fast-forward is refused because the local parent has diverged, report it and **stop the cleanup**.
The worktree and the branch stay until the user resolves it.

**Then remove.** Run this from the main repo root, because git refuses to remove the worktree you
are standing in. If the session entered the worktree with `EnterWorktree` (Step 2, Option 1),
leave it first with `ExitWorktree` and `action: "keep"`. Use **`keep`, never `remove`**:
`ExitWorktree` does not remove a worktree entered by `path`, and `remove` would skip this gated
procedure — the parent-branch update above, and the `gh`-evidence rule below. If the session only
ran `cd` into the worktree, `cd` back out.

**Test the boundary before you remove.** Under `cwl` the sandbox blocks the removal of a worktree
that existed when the session started. Claude Code reads `.git/worktrees/` at startup and denies
every write to `commondir` in each worktree it finds there. The deny also covers the directory that
holds the file, so git cannot delete the directory. The failure is not clean: git deletes a part of
the checkout first, and then it stops with

```
error: failed to delete '.git/worktrees/<id>': Operation not permitted
```

Test first. Remove only after the test passes:

```
pwd                                                    # the session directory, before any cd
admin="$(git -C .claude/worktrees/<branch> rev-parse --absolute-git-dir)"
touch "$admin/commondir"                               # changes the mtime and nothing else
```

`pwd` must print the main repo root. The **session** directory decides a second deny: a session that
still stands in the worktree cannot delete the worktree directory either. Only `ExitWorktree` moves
the session out. A `cd` in a Bash command does not: each Bash call starts in the session directory
again, and the sandbox reads that directory, not the shell. So `cd <repo> && git worktree remove ...`
still fails with

```
error: failed to delete '<worktree>': Operation not permitted
```

If `touch` prints `Operation not permitted`, **remove nothing here**. Queue the drop instead. `cwl`
runs the queue in bash when the session ends, outside the sandbox, and it asks the user again first:

```
printf '%s\t%s\t%s\n' "$(git rev-parse --show-toplevel)/.claude/worktrees/<branch>" \
  "<branch>" merged >> "$CW_DROPS"
```

Write `merged` in the third field only when `gh` reported a non-null `mergedAt` for that branch.
Write `unmerged` in every other case, the `git branch --merged` fallback included. The launcher
escalates to `git branch -D` only on `merged`, and it keeps the branch otherwise — the same rule as
below. Keep the branch here too, and tell the user that the drop is queued.

`$CW_DROPS` is empty under `cw`, and in a plain `claude` session. Report the worktree then, and give
the user this command for a terminal outside Claude Code:

```
git -C <repo> worktree remove .claude/worktrees/<branch> && git -C <repo> branch -d <branch>
```

`EnterWorktree` takes the list again when it moves the session. A worktree that this session entered
is therefore blocked as well, and `ExitWorktree` does not release it. Step 2, Option 1 enters the
worktree, so a `cwl` session cannot drop its own worktree either. Only a worktree that this session
created and never entered passes the test. Under `cw` the test always passes, because the container
has no sandbox.

```
git worktree remove .claude/worktrees/<branch>     # never --force; if it refuses, stop and report
git branch -d <branch>                             # see the note below
git worktree prune
rmdir .claude/worktrees/<type> 2>/dev/null || true  # <type>/ is left empty
```

`git branch -d` usually **refuses a squash-merged branch**. The squash writes a new commit, so the
branch is not an ancestor of the parent and git cannot see the merge. It still succeeds while
`origin/<branch>` exists, because git also accepts "merged to its upstream" — but GitHub deletes the
head branch on merge, and the `--prune` above then drops that ref, so the refusal is the normal case.
Escalate to `git branch -D` **only** when `gh` reported a non-null `mergedAt` for that branch. Never
use `-D` on the `git branch --merged` fallback alone.

Branch names are `<type>/<slug>`, so the worktree directory nests one level and the `<type>/` parent
survives the removal — hence the `rmdir`. `git worktree remove` refuses a worktree with modified or
untracked files; that refusal is the safety net, so never reach for `--force`.

**Then archive the hand-offs this repo implemented.** Inbound only:

- List them with `ls "$CW_HANDOFFS"/<org>__<repo>__*` — with **no** `.md` filter. A hand-off may
  have companion files (`....files.txt`, `....tsv`), and a file moves with its companions.
- Read each candidate and compare it to what the merged branch actually did. Only a hand-off the
  branch implemented is a candidate. Name the candidates in the gate; the user confirms each one.
- Archive, never delete:
  ```
  mkdir -p "$CW_HANDOFFS/done"
  mv "$CW_HANDOFFS/<org>__<repo>__<slug>".* "$CW_HANDOFFS/done/"
  ```
  `done/` is a subdirectory, so the Step 1 glob `<org>__<repo>__*.md` no longer finds it.
- Hand-offs **this** session wrote for other repos are never touched here. See Step 8.

Report what you dropped and what you kept, in the Step 7 summary.
