---
description: Plan → choose isolation (worktree/branch) → TDD implement → test → review → docs → commit → PR → cleanup, scoped to a single repo.
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
  1. plan confirmation, 2. isolation choice (worktree/branch), 3. commit-message review,
  4. PR-body review, 5. worktree removal (if one was created),
  6. local-branch removal (if a new branch was created).
- **You start in plan mode — that IS the plan gate.** The session launches in plan mode, so the
  harness blocks every edit until you present a plan and the user approves it (Step 1). Don't try
  to work around it. **Approving the plan is NOT authorization to edit in place:** the moment you
  leave plan mode your FIRST action is Step 2 (the isolation gate), and you may not modify a file
  until that gate is resolved. The commit / PR / cleanup gates still use `AskUserQuestion`.
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

### 2. Isolation (GATE — before any file change)
Once the plan is confirmed, **ask the user how to isolate the work** with `AskUserQuestion`,
before editing anything. Offer these options:
1. **Isolated worktree + new branch** (recommended — leaves the repo's checkout untouched).
2. **New branch, in place** (work in the main checkout on a fresh branch, no separate worktree).
3. **Current branch, in place** (no new branch — only when the user explicitly wants this).

Let `ORG` and `REPO` be the two path components of the current repo under `/work`
(`/work/<ORG>/<REPO>`) and `<slug>` the kebab-case branch slug from the plan. Then:
- **Option 1** — create and enter a worktree under the repo's own `.claude/worktrees/`:
  ```
  # Ignore the worktrees dir locally so it never shows as untracked or gets committed
  # (uses .git/info/exclude — does NOT touch the repo's tracked .gitignore):
  grep -qxF '/.claude/worktrees/' .git/info/exclude 2>/dev/null \
    || echo '/.claude/worktrees/' >> .git/info/exclude
  git worktree add .claude/worktrees/<slug> -b claude/<slug>
  # Make the worktree usable from the HOST too. The container mounts this repo at a
  # different absolute path (/work/...) than the host (/Users/...), and git bakes an
  # ABSOLUTE path into the worktree's .git link — so host `git status` inside it would
  # fail with "not a git repository: /work/...". Rewrite ONLY the worktree's forward
  # .git link to a RELATIVE path (valid because it sits exactly 3 levels deep in the
  # repo). Leave the repo-side backlink (.git/worktrees/<slug>/gitdir) absolute, so the
  # container's git 2.39 worktree admin (list / remove / prune) keeps working.
  printf 'gitdir: ../../../.git/worktrees/<slug>\n' > .claude/worktrees/<slug>/.git
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

### 7. Commit — message reviewed (GATE)
Stage everything (code + tests + docs). Draft a Conventional-Commits message. **Show it to the
user for review/edit via `AskUserQuestion`**, then commit with the approved message.

### 8. PR — body reviewed (GATE)
Push the working branch recorded in Step 2 (`claude/<slug>` for options 1–2, else the current
branch):
```
git push -u origin <working-branch>
```
Draft a PR title and body (summary, what/why, test plan, and any cross-project dependency from
step 9). **Show them for review/edit via `AskUserQuestion`**, then:
```
gh pr create --title "<approved title>" --body-file <file with approved body>
```
Print the PR URL.

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
   on yes: `git branch -D claude/<slug>`. Keep the **remote** branch — the open PR needs it.

Finish with a short summary: branch, PR URL, test result, and any hand-off files written.
