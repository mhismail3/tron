# Independent multi-agent work

Workers own a branch and worktree. They choose and run the tests relevant to the
change directly. No worker waits for another worker's tests. There is no gate,
check receipt, shared CPU/memory admission, merge queue, hosted check workflow,
post-merge checker or automatic revert.

## Start

Track work in a GitHub issue, then optionally use:

```bash
scripts/tron work start <issue> --area <path>
```

This creates a task branch and worktree under `../tron-worktrees/`, records the
issue/session claim and updates the Project. It does not install dependencies or
run tests. Claims prevent two writers taking the same issue, not parallel work on
different issues. Predicted `--area` overlaps are advice, never locks. A worker
may also use ordinary `git worktree add -b <branch> <path> origin/main`.

Keep active workers' worktrees and branches intact. `handoff`, `recover` and
`release` are explicit recovery/destructive-cleanup tools, not prerequisites to
landing. They retain their exact-head and owner-settlement safeguards: never
overwrite a live worker or discard unpublished work. Unknown state is not proof
that work is abandoned. Do not use `git stash` across these shared worktrees.

## Test directly

Choose the real boundary the change touches. These entry points run the suites,
without planning, caching a pass, admission, queues or required ordering:

```bash
scripts/tron test gateway src/sessions/runtime-registry.integration.test.ts
scripts/tron test gateway                         # default Gateway suite
scripts/tron-node exec npm --prefix packages/gateway run test:nested
scripts/tron test ios build
scripts/tron test ios run --only-testing TronMobileUITests/<Class>/<method>
scripts/tron test tooling scripts/test-work-land.py
scripts/tron build gateway
```

Install required dependencies explicitly in your worktree. Use the pinned Node
resolver (`scripts/tron-node exec`) for Node commands. The iOS tooling owns its
simulator and cleans up after each command. **One simulator job per worktree at a
time**, including profiling and Gateway E2E. Different workers do not share a job
queue. A lease on the same physical device or simulator prevents two commands
using that exact resource; it is not a test admission system.

## Land with Git

```bash
git config rerere.enabled true
git add <files>
git commit -m '<change>'
git fetch origin
git rebase origin/main          # or git merge --no-edit origin/main
# Run only the directly relevant tests, as judged by the worker.
git push origin HEAD:main
```

If the push is rejected as non-fast-forward, fetch and rebase/merge again. This
is Git's compare-and-swap, not a lock or queue. Only rerun tests if integration
changed files the change depends on. Resolve conflicts in the worker's worktree;
`rerere` remembers resolutions. Never force-push main.

Optional `scripts/tron work land` enables rerere, fetches origin/main, merges it
into the current committed task branch, and pushes HEAD to main. It runs **no**
tests and uses **no** GitHub API, PR, receipt or lock. On a conflict or push race it
stops with Git's error, preserving the candidate. Resolve/fetch/merge and retry.
`--dry-run` fetches and prints the operations, without merging or pushing. There
is no automatic retry or automatic revert. A summary file and PR are not needed.

After landing, close the issue with a concise account of the change, actual test
results and residual risks:

```bash
scripts/tron work issue close <issue> --reason completed --comment-file <evidence.md>
```

`scripts/tron work cleanup [--dry-run]` recognizes a closed issue whose exact
worktree head is reachable on origin/main, as well as historical exact-head
merged PRs. It preserves dirty/untracked files, live processes, branches that
moved, and unpublished work. Use it only for your own finished worktree; `--all`
is explicit broader cleanup, not part of landing. Sync the primary checkout only
when its tracked files are clean and main is strictly behind origin/main, using
`git merge --ff-only origin/main`. Preserve untracked files; never reset or
rebase the primary main.

## Other helpers

- `work dashboard [--html PATH] [--json PATH]`: live issues, claims, worktrees,
  stale work and classification. No CI, cap or queue projection.
- `work status [--area PATH]... [--json]`: fresh advisory overlaps. No admission.
- `work comment <issue> --body-file F`: privacy-checked public comment.
- `work issue create --title T --body-file F --kind kind:maintenance --area area:tooling`:
  create a classified task in the Project. Use the declared kind/area that fits.
- `work issue edit|labels|close|reopen|parent|block`: issue tracking; `--help` owns
  the exact arguments. A dependency link is coordination, not a landing lock.
- `work project add|set`: Project membership/status.
- `work bootstrap [--apply [--prune]]`: labels and Project vocabulary only; no
  repository protection or required checks are installed.
- `work review-export --output <new-path> [--base REF]`: optional immutable Git
  patch for an explicitly requested review. It grants no landing authority.
- `work auth setup|status`: the dedicated agent GitHub token in the Mac Keychain.
  If missing, a maintainer runs setup in Terminal; never print the token or ask
  agents to change the maintainer's gh login. GitHub writes use the work helper's
  bounded private audit and privacy guard; reads may use `gh` directly.

## Build and installation

Mac Replace chooses fetched `origin/main`, not a last-passed-main receipt. If
that revision differs from the checkout it uses its existing detached full-build
path. Debug builds remain explicitly worktree-owned. iOS build/test/install
contracts belong to the [iOS development guide](../../packages/ios-app/docs/development.md),
and the [Mac development guide](../../packages/mac-app/docs/development.md) owns
replacement. Agents must not install, deploy or restart Stable as part of a
landing.

No check or queue is to be reinstated without measured evidence of real catches
versus false failures and waiting in the multi-agent flow, followed by the
maintainer's decision. A recommendation is not authorization to wire it in.
