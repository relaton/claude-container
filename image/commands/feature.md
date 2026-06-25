---
description: Plan → choose isolation (worktree/branch) → TDD implement → test → review → docs → review changes → commit → (merge or PR) → cleanup, scoped to a single repo.
argument-hint: <task description>
---

You are running inside an isolated container, started with full tool access
(`--dangerously-skip-permissions`). Drive the following **gated** workflow for the task:

> $ARGUMENTS

## Hard rules (read first)

- **Single-project boundary.** The current repo (your working directory) is the ONLY thing
  you may modify. Everything else under `/work` is mounted **read-only** — you may read
  related projects for context, but any write to them will fail. **Never** try to edit them.
- **Mandatory human gates** — you MUST stop and use `AskUserQuestion` (or wait for an explicit
  user reply) at each of these, and never skip them:
  1. plan confirmation, 2. isolation choice (worktree/branch), 3. **change review (you show the
  diff and the user approves it) — before anything is committed**, 4. commit-message review,
  5. **finalize choice: merge or open a PR**, 6. PR-body review (only if a PR was chosen),
  7. worktree removal (if one was created), 8. local-branch removal (if a new branch was created).
- **Nothing is committed or merged automatically.** A commit happens ONLY after gates 3 and 4 both
  pass. A merge into the default branch happens ONLY when the user explicitly picks "merge" at the
  finalize gate (gate 5). Never run `git commit`, `git merge`, or `gh pr merge` to push past a gate
  the user hasn't cleared — leaving the plan-mode prompt is not authorization to commit or merge.
- **You start in plan mode — that IS the plan gate.** The session launches in plan mode, so the
  harness blocks every edit until you present a plan and the user approves it (Step 1). Don't try
  to work around it. **Approving the plan is NOT authorization to edit in place:** the moment you
  leave plan mode your FIRST action is Step 2 (the isolation gate), and you may not modify a file
  until that gate is resolved. The diff-review / commit / finalize / cleanup gates still use
  `AskUserQuestion`.
- **Isolation-before-edit invariant.** You may not create or modify a single file until the
  Step 2 isolation gate is resolved — i.e. you are in the chosen worktree, on the chosen new
  branch, or the user has explicitly chosen to work on the current branch. Never start editing
  the repo's checked-out branch by default; working in place must be a deliberate, confirmed
  choice from Step 2.
- **Everything between the gates runs autonomously** — implementation, tests, and review need
  no questions. Do not ask permission for ordinary edits/commands; just do the work.
- **Cross-project changes are never made inline.** If the task needs a change in a related
  project, emit a hand-off prompt (see step 9) instead of editing it.

## Steps

### 1. Plan (GATE)
You begin in **plan mode** — you cannot edit yet, which is intended. Identify the repo from the
working directory. Research with the `Explore` agent and by reading relevant files (including
read-only related projects if useful). Produce a concise plan: goal, files to change, test
strategy, and a short **branch slug** (kebab-case, e.g. `add-http-retry`). Present the plan and
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

Let `<slug>` be the kebab-case branch slug from the plan. Then:
- **Option 1** — create and enter the worktree with the baked helper. **Do not run
  `git worktree add` yourself** — the container's git (2.39) would bake a container-only path
  into the worktree and make it unreadable from the host. The helper creates it under the repo's
  own `.claude/worktrees/` (so it's physically present on the host) and fixes the link so it
  works from both sides:
  ```
  mkworktree <slug>            # creates .claude/worktrees/<slug> on branch claude/<slug>
  cd .claude/worktrees/<slug>
  ```
  Confirm: `git rev-parse --show-toplevel` prints a path ending in `/.claude/worktrees/<slug>`,
  and `git status --porcelain` in the main repo does **not** list `.claude/`.
- **Option 2** — `git checkout -b claude/<slug>` in the repo root.
- **Option 3** — stay on the current branch; do nothing here.

Record the **working branch** (`claude/<slug>` for options 1–2, else the current branch) and
**whether a worktree was created** — later steps (push, cleanup) depend on both. Do all
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
Spawn the `code-reviewer` agent on the diff (`git diff main...HEAD` or against the repo's
default branch). Summarize findings and apply fixes for anything material; re-run tests after.

### 6. Docs / CLAUDE.md (no questions)
If the change warrants it, update **this repo's** `CLAUDE.md` (new conventions, public API,
build/test commands, architecture notes) and, following the repo's existing convention, its
`README` / `CHANGELOG`. If nothing needs documenting, skip silently — do not manufacture churn.

### 7. Review changes, then commit (GATES)
**Stop and let the user review the actual changes before anything is committed.** Present:
- the working branch, the changed-files list (`git status --porcelain`), and a diff overview
  (`git diff --stat`, plus the key hunks so they can see what changed);
- if a worktree was used, the host path (`.claude/worktrees/<slug>`) so they can open the files
  directly on their machine.

Use `AskUserQuestion` to ask whether the changes look good: **Approve & commit**, or **request
changes**. If they want changes, make them (re-running the relevant tests) and re-present — do
**not** proceed until the changes are approved.

Only after approval: stage everything (code + tests + docs), draft a Conventional-Commits message,
**show it via `AskUserQuestion`** for review/edit, then commit with the approved message. Never run
`git commit` before both of these gates pass.

### 8. Finalize — merge or open a PR (GATE)
The commit now exists locally, but **nothing has left the machine and nothing is merged.** Ask the
user how to finalize with `AskUserQuestion` — this choice is the *only* thing that authorizes a
merge; never merge on your own. Offer:

1. **Open a pull request** (recommended) — push the branch and open a PR for review.
2. **Merge into `<default-branch>`** — integrate the work locally and push the default branch.
3. **Stop here** — leave the commit on the working branch; the user finalizes manually.

**If "Open a PR":** push the working branch recorded in Step 2 (`claude/<slug>` for options 1–2,
else the current branch):
```
git push -u origin <working-branch>
```
Draft a PR title and body (summary, what/why, test plan, and any cross-project dependency from
step 9). **Show them for review/edit via `AskUserQuestion`**, then:
```
gh pr create --title "<approved title>" --body-file <file with approved body>
```
Print the PR URL.

**If "Merge into `<default-branch>`":** confirm the target (the repo's default branch) and, from the
main checkout, merge the working branch and push:
```
git -C /work/<ORG>/<REPO> checkout <default-branch>
git -C /work/<ORG>/<REPO> merge --no-ff <working-branch>
git -C /work/<ORG>/<REPO> push origin <default-branch>
```
(If the work was done in place on the default branch itself, there is nothing to merge — just
`git push`.) Report the resulting commit. Resolve conflicts before pushing; if they're non-trivial,
stop and tell the user rather than guessing.

**If "Stop here":** do nothing further here — report the branch and commit so the user can finalize
later.

### 9. Cross-project hand-off (only if needed)
If the task requires changes in a related project (e.g. this repo needs a new method in another
gem):
- Do **not** edit that project.
- Write a self-contained hand-off prompt — target project, what to change, required
  API/signature, why, and how this repo will consume it.
- Print it AND save it to `HANDOFFS/<other-org>__<other-repo>.md` in the worktree.
- Mention the dependency in the PR body. Tell the user they can run it later with:
  `cd /work/<other-org>/<other-repo>` then `cw "<paste the prompt>"` (a separate session).

### 10. Cleanup — explicit confirmations (GATES)
Skip whichever of these don't apply to the Step 2 choice (working in place on the current branch
leaves nothing to clean up here).
1. If you used a worktree (Option 1), `cd` back to the main repo (`/work/<ORG>/<REPO>`).
2. **If a worktree was created, ask** whether to remove it → on yes:
   `git worktree remove .claude/worktrees/<slug>`.
3. **If a new branch was created (options 1–2), ask** whether to delete the **local** branch →
   on yes: `git branch -D claude/<slug>`. If you opened a PR, keep the **remote** branch — the
   open PR needs it.

Finish with a short summary: branch, PR URL, test result, and any hand-off files written.
