---
description: Plan → TDD implement in an isolated worktree → test → review → docs → commit → PR → cleanup, scoped to a single repo.
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
  1. plan confirmation, 2. commit-message review, 3. PR-body review,
  4. worktree removal, 5. local-branch removal.
- **Everything between the gates runs autonomously** — implementation, tests, and review need
  no questions. Do not ask permission for ordinary edits/commands; just do the work.
- **Cross-project changes are never made inline.** If the task needs a change in a related
  project, emit a hand-off prompt (see step 9) instead of editing it.

## Steps

### 1. Plan (GATE)
Identify the repo from the working directory. Research with the `Explore` agent and by reading
relevant files (including read-only related projects if useful). Produce a concise plan:
goal, files to change, test strategy, and a short **branch slug** (kebab-case, e.g.
`add-http-retry`). Present the plan and **iterate with the user until they explicitly confirm**
(use `AskUserQuestion`). Do not proceed until confirmed.

### 2. Isolated worktree
Let `ORG` and `REPO` be the two path components of the current repo under `/work`
(`/work/<ORG>/<REPO>`). From the repo root create the worktree on a new branch:
```
git worktree add /work/<ORG>/.worktrees/<REPO>__<slug> -b claude/<slug>
cd /work/<ORG>/.worktrees/<REPO>__<slug>
```
Do all subsequent work from this worktree directory.

### 3. Implement — TDD (no questions)
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
```
git push -u origin claude/<slug>
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
1. `cd` back to the main repo (`/work/<ORG>/<REPO>`).
2. **Ask** whether to remove the worktree → on yes:
   `git worktree remove /work/<ORG>/.worktrees/<REPO>__<slug>`.
3. **Ask** whether to delete the **local** branch → on yes: `git branch -D claude/<slug>`.
   Keep the **remote** branch — the open PR needs it.

Finish with a short summary: branch, PR URL, test result, and any hand-off files written.
