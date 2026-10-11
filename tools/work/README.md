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
| `handoff <issue> --reason TEXT [--session ID] [--force-maintainer]` | Transfers an existing claim in place; preserves the registered worktree and dirty files. Automatic transfer requires authoritative terminal settlement evidence from `packages/gateway/dist/client/work-owner-status.js`; prepare it with `PATH="$HOME/.nvm/versions/node/v$(cat .node-version)/bin:$PATH" npm --prefix packages/gateway run build`. The helper defaults `TRON_GATEWAY_HOST` to the local Tailscale address, matching terminal chat. Set `TRON_GATEWAY_HOST=127.0.0.1` when querying a loopback-bound development Gateway, or set it to a literal IP assigned to this Mac; it refuses other hosts before reading the local credential or opening a socket. Maintainer override requires a real TTY and exact typed confirmation. The public audit includes old/new owner, reason, and exact transition commit SHA. |
| `verify [--tests CMD]...` | Runs the checks the branch's paths require, then each `--tests` command, on the current commit. Exit 0 when all pass. |
| `land --summary-file <md> [--title T] [--tests CMD]... [--dry-run]` | Merges `origin/main` in, verifies the merged tree, pushes the branch, opens or updates its pull request (title = `--title` or the issue title; body = the summary file, verbatim), squash-merges at the verified commit, deletes the remote branch, and closes the issue as completed with Status Done. Prints `merged: <commit>`. |
| `cleanup [--all] [--dry-run]` | Removes a task worktree and its branches once its pull request merged at its head (or its issue is closed and it holds only its claim commit). Names what it keeps and why. |
| `dashboard [--html P] [--json P]` | Read-only view of claims, Status, epics, stale work, orphans and main CI. |
| `comment <issue> --body-file F` | Privacy-checks, then posts a public issue comment. |
| `issue create\|labels\|close\|parent\|block` | Files issues and changes labels and links. Labels are optional; only declared labels are accepted. `close` posts a comment, closes, and sets Status Done. Epics may close only when all linked children are closed (every page is checked before any write, for either close reason). |
| `project add\|set` | Adds an issue to the Project, or sets Status (Proposed, Ready, Blocked) and Priority. |
| `bootstrap [--apply]` | Plans or converges labels and the Project fields to `.github/work.json`. Adds and updates only. |

Every GitHub write goes through `scripts/tron work`, which appends it to a private,
bounded audit log at `<git common dir>/work/github-writes.jsonl` without its body.
Reads are plain `gh` reads.

## `verify` and `land`

`verify` diffs `HEAD` against the merge base with `<remote>/<base>` and selects checks
by path. A package's check runs only for code paths: markdown and `docs/` changes never
start a build:

- always: the privacy guard (`scripts/personal-info-guard.sh`) and `git diff --check`;
- `packages/gateway`: `npm ci` only when the lockfile changed or `node_modules` is
  missing, then `npm run check`, then `vitest related` for the changed sources and
  `vitest run` for the changed test files, under the default and nested configs;
- `packages/push-relay`: `npm run check` and `npm run build`;
- `packages/ios-app`: `scripts/tron-ios-test build`;
- `packages/mac-app`: `scripts/tron mac generate`, then a Debug `xcodebuild build-for-testing` (it also compiles the integration target);
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
times. A refused merge after the base moved is retried the same way. A head that a
pull request already merged is refused, so a repeat run cannot open a second one.
Other refusals stop `land` with nothing merged. Claim handoff serializes through a read-only descriptor on the pre-existing common Git directory (it creates no lock file), checks operation markers in the selected worktree's private Git directory (including linked-worktree merge/rebase/cherry-pick/revert state), and rechecks local and remote heads before changing a ref. An exact accepted transition commit can repair local ref state after a partial push; unrelated or malformed remote objects are never treated as proof.

## `cleanup`

A worktree is removed only when its head is proven done and nothing local would be
lost: no uncommitted or untracked files, no non-regenerable ignored files, no operation in
progress, no process working inside it. Release commands from `cleanup.releaseCommands`
run first (`scripts/ios-gateway-e2e-test clean`, `scripts/tron-ios-test clean`). Removal
deletes the local branch and the remote branch with a lease on the proven head.
`--dry-run` changes nothing.

## Failure modes this protects

- **A claim is taken twice.** The claim is a remote branch created without force; the
  smallest branch name wins the race and the loser deletes only its own ref. `handoff`
  appends the new owner trailer using an exact remote expected-head lease and updates
  the local branch only at its expected old head. The audit marker is keyed by the exact handoff commit.
- **A foreign session's claim is changed.** `issue close` refuses when another session
  holds a claim on the issue.
- **Public text leaks personal data.** Issues, comments, and pull request text pass the
  privacy guard first; a refusal prints no matching line.
- **A conflict is merged by hand.** `land` aborts a conflicting merge and names the files.
- **Unverified code is merged.** The squash merge names the verified commit, so GitHub
  refuses it if the branch changed. A base that moved is re-merged and re-verified first.
  A base that moves in the instant between that check and GitHub's merge call is not
  caught; the merge still composes the base with the verified branch.
- **Unmerged work is removed.** `cleanup` needs a merged pull request at the local head,
  or a closed issue whose branch holds only its empty claim commit.
- **A closed or blocked issue is claimed.** `start` refuses a closed issue, an excluded
  label (epics), or an issue blocked by an open issue.

## Tests

The tooling has no unit tests. Changes are validated by running the real commands: a
`verify` or `land --dry-run` on the branch, and an integration run against a temporary
repository when a change touches Git, GitHub or cleanup behavior.

`python3 scripts/test-work-close.py` exercises epic/task close through the real CLI
and Git with a process-level GitHub fixture in an isolated temporary home. It covers
completed epics, unfinished children on later pages, failed reads, foreign claims,
and idempotent recovery after a partial close. Regenerable evidence is written to
`test-results/work-close.json`; the fixture repository and home are removed on exit.

`python3 scripts/test-work-handoff.py` exercises handoff through the real CLI and Git
in an isolated fixture, with owner-status evidence served by real Gateway WebSockets
using the built client helper. It checks refusal of an unassigned IP before socket
access, acceptance of a locally assigned interface IP when one is available, active-only
refusal without status reads, pagination to a finished matching owner, malformed
evidence, natural completion with zero stopped subagents, refusal preservation of
refs/index/dirty bytes, ordinary and TTY-confirmed takeover, idempotent audit, and
missing-worktree refusal without recreation. Evidence is written to
`test-results/work-handoff.json`; build the Gateway first with the pinned Node runtime
using `npm --prefix packages/gateway run build`. The fixture sets
`TRON_GATEWAY_HOST=127.0.0.1` by default so it remains independent of host Tailscale.
