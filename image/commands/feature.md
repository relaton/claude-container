---
description: Plan → choose isolation (worktree/branch) → TDD implement → test → review → docs → show the diff → stop (you drive commit/PR), scoped to a single repo.
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

## Hard rules (read first)

- **Single-project boundary.** The current repo (your working directory) is the ONLY thing
  you may modify. Everything else under `/work` is mounted **read-only** — you may read
  related projects for context, but any write to them will fail. **Never** try to edit them.
- **You stop when the work is done — you do not finalize it on your own.** Your job ends at Step 7:
  implement, test, review, then show the user the diff and stop. **Do not `git commit`, `git add`,
  `git push`, `git merge`, `gh pr create`, or `gh pr merge` on your own initiative** — leave the
  changes as uncommitted working-tree edits on the chosen branch/worktree. The user reviews them and
  decides what to commit, merge, or open a PR for — that is their call, in their own session or by
  hand. **If the user explicitly asks you to commit, push, merge, or open a PR, do it** — perform
  exactly the action requested, then stop.
- **Mandatory human gates** — you MUST stop and use `AskUserQuestion` (or wait for an explicit
  user reply) at each of these, and never skip them:
  1. plan confirmation, 2. isolation choice (worktree/branch).
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
working directory. Research with the `Explore` agent and by reading relevant files (including
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
  both the container (`/work/...`) and the host (`/Users/...`):
  ```
  mkworktree <branch>          # creates .claude/worktrees/<branch> on branch <branch>
  cd .claude/worktrees/<branch>
  ```
  Confirm: `git rev-parse --show-toplevel` prints a path ending in `/.claude/worktrees/<branch>`,
  and `git status --porcelain` in the main repo does **not** list `.claude/`.
- **Option 2** — `git checkout -b <branch>` in the repo root.
- **Option 3** — stay on the current branch; do nothing here.

Record the **working branch** (`<branch>` for options 1–2, else the current branch) and
**whether a worktree was created** — the final hand-back (Step 7) reports both. Do all
subsequent work from the chosen location.

### 3. Implement — TDD (no questions)
**Self-check before the first edit:** confirm you are where Step 2 decided — inside the worktree
(Option 1), on the new branch via `git branch --show-current` (Option 2), or the current branch
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
  files directly on their machine;
- the **changed-files list** (`git status --porcelain`) and a **diff overview** (`git diff --stat`,
  plus the key hunks so they can see what changed);
- the **test result** (and rubocop, if run);
- any **cross-project hand-off** files written in Step 8.

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
- Print it AND save it to `HANDOFFS/<other-org>__<other-repo>.md` in the worktree, and mention it
  in the Step 7 summary. Tell the user they can run it later with:
  `cd /work/<other-org>/<other-repo>` then `cw "<paste the prompt>"` (a separate session).
