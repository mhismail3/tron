# Work tooling

`scripts/tron work` coordinates parallel agents on Tron. Issues and the Tron Project
say who owns which work; branches and worktrees keep the edits apart; `land` merges
them. The tooling adds no review or hosted-check gate. The gate is a local verify of
the exact commit being merged. Policy is in [AGENTS.md](../../AGENTS.md#work-tracking);
the agent procedure is the [tron-work skill](../../.agents/skills/tron-work/SKILL.md).
Repository settings (labels, Project fields, claim and cleanup rules, the verify
prelude and privacy guard) are in [`.github/work.json`](../../.github/work.json).

## Commands

| Command | Does |
| --- | --- |
| `start <issue>` | Claims an open, unclaimed, non-epic issue: pushes a claim commit to `claim.remote`, sets Status In progress, comments the claim, and creates the worktree `../tron-worktrees/<issue>-<slug>` on `<type>/<issue>-<slug>`. A session resumes its own claim. |
| `verify [--tests CMD]...` | Runs the checks the branch's paths require, then each `--tests` command, on the current commit. Exit 0 when all pass. |
| `land --summary-file <md> [--title T] [--tests CMD]... [--dry-run]` | Merges `origin/main` in, verifies the merged tree, pushes the branch, opens or updates its pull request (body = the summary file, verbatim), squash-merges at the verified commit, deletes the remote branch, and closes the issue as completed with Status Done. Prints `merged: <commit>`. |
| `cleanup [--all] [--dry-run]` | Removes a task worktree and its branches once its pull request merged at its head (or its issue is closed and it holds only its claim commit). Names what it keeps and why. |
| `dashboard [--html P] [--json P]` | Read-only view of claims, Status, epics, stale work, orphans and main CI. |
| `comment <issue> --body-file F` | Privacy-checks, then posts a public issue comment. |
| `issue create\|labels\|close\|parent\|block` | Files issues and changes labels and links. Labels are optional; only declared labels are accepted. `close` posts a comment, closes, and sets Status Done. |
| `project add\|set` | Adds an issue to the Project, or sets Status (Proposed, Ready, Blocked) and Priority. |
| `bootstrap [--apply]` | Plans or converges labels and the Project fields to `.github/work.json`. Adds and updates only. |

Every GitHub write goes through `scripts/tron work`, which appends it to a private,
bounded audit log at `<git common dir>/work/github-writes.jsonl` without its body.
Reads are plain `gh` reads.

## `verify` and `land`

`verify` diffs `HEAD` against the merge base with `<remote>/<base>` and selects checks
by path:

- always: the privacy guard (`scripts/personal-info-guard.sh`) and `git diff --check`;
- `packages/gateway`: `npm ci` only when the lockfile changed or `node_modules` is
  missing, then `npm run check`, then `vitest related` for the changed sources and
  `vitest run` for the changed test files, under the default and nested configs;
- `packages/push-relay`: `npm run check` and `npm run build`;
- `packages/ios-app`: `scripts/tron-ios-test build`;
- `packages/mac-app`: `scripts/tron mac generate`, then a Debug `xcodebuild build`;
- changed scripts: `ast` parse for `.py`, `node --check` for `.mjs`/`.js`, `bash -n`
  for `.sh` and for shebang-shell files under `scripts/`;
- each `--tests` command, run from the repository root.

Checks run two at a time. Each log is kept under `<git dir>/work/logs/`, and a
failing check prints the end of its log. A tree that passed with the same check set is
recorded under `<git dir>/work/verified/` and is not run again. `verify` refuses
a dirty worktree, because it checks a commit.

`land` refuses a detached HEAD, a base branch, a dirty worktree, a merge or rebase in
progress, and a branch with no commits beyond the base. The privacy guard runs on the
title and summary before anything is pushed or posted. A merge conflict with the base
is aborted, and the conflicting files are listed for the agent to resolve and commit,
then `land` runs again. A moved base sends `land` back to merging it, at most three
times. A refused merge after the base moved is retried the same way. Other refusals
stop `land` with nothing merged.

## `cleanup`

A worktree is removed only when its head is proven done and nothing local would be
lost: no uncommitted or untracked files, no non-regenerable ignored files, no operation in
progress, no process working inside it. Release commands from `cleanup.releaseCommands`
run first (`scripts/ios-gateway-e2e-test clean`, `scripts/tron-ios-test clean`). Removal
deletes the local branch and the remote branch with a lease on the proven head.
`--dry-run` changes nothing.

## Failure modes this protects

- **A claim is taken twice.** The claim is a remote branch created without force; the
  smallest branch name wins the race and the loser deletes only its own ref.
- **A foreign session's claim is changed.** `issue close` refuses when another session
  holds a claim on the issue.
- **Public text leaks personal data.** Issues, comments, and pull request text pass the
  privacy guard first; a refusal prints no matching line.
- **A conflict is merged by hand.** `land` aborts a conflicting merge and names the files.
- **Unverified code is merged.** `land` merges only the commit it verified, with the
  squash-merge `sha` check, and never after the base moved past it.
- **Unmerged work is removed.** `cleanup` needs a merged pull request at the local head,
  or a closed issue whose branch holds only its empty claim commit.
- **A closed or blocked issue is claimed.** `start` refuses a closed issue, an excluded
  label (epics), or an issue blocked by an open issue.

## Tests

The tooling has no unit tests. Changes are validated by running the real commands: a
`verify` or `land --dry-run` on the branch, and an integration run against a temporary
repository when a change touches Git, GitHub or cleanup behavior.
