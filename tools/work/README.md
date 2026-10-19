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

Keep active workers' worktrees and branches intact. Claims are coordination,
not permission to stop or overwrite an agent. Only branches with matching claim
trailers are owners; ordinary checkpoint names do not block `start`. A genuine
live foreign claim still requires explicit handoff rather than implicit takeover.
`start` preserves released work and colliding checkpoints, choosing a fresh path.
A failed claim push reports a lost race only after observing a competing session's
claim; otherwise it retains Git's error. Never `git stash` across shared worktrees.

`work release <issue> --reason TEXT` backs up the published/local heads and a
snapshot of tracked, untracked and non-regenerable ignored files under the common
Git directory (`work/releases/`). It releases only the exact leased remote claim
ref and returns the open issue to Ready. **Every local branch, worktree, index,
file and process stays intact**, including the caller's active checkout. Published
work and a live or unverifiable owner are not refusals; release never runs resource
cleanup hooks. Retained local work is deliberately parked, not disposable. Backup,
privacy, ambiguous canonical claims and remote-race failures still stop the write;
retry resumes an accepted remote release if its audit/Project update failed.
The optional `release --stale [--dry-run]` sweep remains conservative: older than
72 hours with an absent owner, re-proven immediately before the remote write, and
no published unlanded file changes. Only an explicit release may park those changes.
Incremental bundles contain objects beyond main; already-landed remote-only heads
need no empty bundle and remain reachable through their local preservation refs.

`work handoff <issue> --session RECEIVER --reason TEXT` explicitly transfers
coordination without a lifecycle/TTY override or changing files/index/processes.
It cannot prevent a prior owner from later using plain Git; coordinate in the issue.
Its exact local/remote publication fences remain: mismatched unpublished candidates
use `recover` rather than silently replacing a remote head. `recover` publishes an
exact clean settled-owner descendant as unverified work, not acceptance. None of
these helpers is a prerequisite to landing. Destructive deletion belongs only to
`work cleanup`, with its separate exact-head and unpublished-work safeguards.
`scripts/test-work-coordination.py`, `test-work-release.py`, `test-work-handoff.py`
and `test-work-start.py` exercise these contracts through real CLI/Git/socket fixtures.

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

Optional `scripts/tron work land` enables rerere, fetches main into Git's
worktree-private `FETCH_HEAD` (empty refmap, no shared tracking-ref update during
fetch), merges that snapshot into the current committed task branch, and pushes
HEAD to main. Linked worktrees share `origin/main`; another worker's fetch must
not invalidate this worker's snapshot or make its fetch fail on the shared ref.
Normal push may still refresh its remote-tracking ref; remote acceptance remains
Git's fast-forward check. The helper runs **no** tests and uses **no** GitHub API,
PR, receipt or lock. On a conflict or push race it stops with Git's error,
preserving the candidate. Resolve/fetch/merge and retry. `--dry-run` fetches and
prints the operations, without merging or pushing. There is no automatic retry
or automatic revert. A summary file and PR are not needed.

After landing, close the issue with a concise account of the change, actual test
results and residual risks:

```bash
scripts/tron work issue close <issue> --reason completed --comment-file <evidence.md>
```

`scripts/tron work cleanup [--dry-run]` recognizes a closed issue whose exact
worktree head is reachable on origin/main, as well as historical exact-head
merged PRs. It preserves dirty/untracked files, live processes, branches that
moved, and unpublished work. An integration merge needs no task-branch PR when
its ancestry contains the exact task head. A squash with identical files does
not prove that head landed: unique checkpoints remain preserved, even on a
closed issue. Cleanup does not infer content-subset equivalence or bundle and
then discard dirty/unique work. The real-Git integration/squash cases and dirty-file
preservation run with `scripts/tron test tooling scripts/test-work-cleanup.py`,
writing `test-results/work-cleanup.json`.
Use it only for your own finished worktree; `--all`
is explicit broader cleanup, not part of landing. Sync the primary checkout only
when its tracked files are clean and main is strictly behind origin/main, using
`git merge --ff-only origin/main`. Preserve untracked files; never reset or
rebase the primary main.

Closing an issue needs no claim ownership or Git-remote lookup. Ordinary checkpoint
branches, missing claim trailers and another session's claim do not block closure.
Closing posts the evidence and sets Status Done even if someone already closed the
issue; repeating the same command does not duplicate its comment. Epic closure still
requires all sub-issues to be closed.

The closed issue retires its active claim in the dashboard. Closure never deletes
Git branches, claim-history markers or worktrees: they may carry unpublished or live
work, and `work cleanup` separately proves an exact head is safe to remove. Audited
`release` and `handoff` change coordination while retaining local work; `recover`
and destructive `cleanup` keep their publication/deletion safeguards. None is a
step required to close an issue. Claim metadata is never a check receipt.

## Other helpers

- `work dashboard [--html PATH] [--json PATH]`: live issues, claims, worktrees,
  stale work and classification. In-progress rows come from open, non-excluded
  issues with an active Project status; a retained claim or that status never
  proves a worker is running. Closed claims stay visible as orphans, not active
  work. `scripts/test-work-start.py` exercises the read-only CLI's text/JSON/HTML
  with real Git claims. No CI, cap or queue projection.
- `work status [--area PATH]... [--json]`: fresh advisory overlaps. No admission.
- `work comment <issue> --body-file F`: privacy-checked public comment.
- `work issue create --title T --body-file F --kind kind:maintenance --area area:tooling`:
  create a classified task in the Project. Use the declared kind/area that fits.
- `work issue edit|labels|close|reopen|parent|block`: issue tracking; `--help` owns
  the exact arguments. `parent` links a task or a nested epic under an epic.
  A dependency link is coordination, not a landing lock.
- `work project add|set`: Project membership/status.
- `work bootstrap [--apply [--prune]]`: labels and Project vocabulary only; no
  repository protection or required checks are installed.
- `work review-export --output <new-path> [--base REF]`: optional immutable Git
  patch for an explicitly requested review. It grants no landing authority.
- `work auth setup|status`: the dedicated agent GitHub token in the Mac Keychain.
  If missing, a maintainer runs setup in Terminal; never print the token or ask
  agents to change the maintainer's gh login. GitHub writes use the work helper's
  bounded private audit and privacy guard; reads may use `gh` directly.
  A nonzero GraphQL mutation or compound-command exit is audited as `uncertain`,
  not proof that nothing committed: result-field errors can follow a write,
  even with null response data. Inspect remote state or use the command's
  existing idempotent recovery; the audit never authorizes blind mutation replay.
  Explicit single-request REST HTTP 4xx rejections remain `failed`. Historical
  audit rows are not rewritten.
  Full (16 MiB) or unreadable audit history refuses the next write before
  dispatch, without truncation or automatic rotation. Close/reopen, label and
  Project-field failure wrappers retain this owned local cause instead of calling
  a known refusal uncertain; opaque GitHub replies stay masked in those wrappers.
  Inspect the local audit before retrying. Linked worktrees share the Git common
  directory's journal; admission reserves result space for outstanding mutations
  before dispatch, so a later refusal cannot consume an accepted call's result.
  The real-CLI `scripts/test-work-close.py` journey covers these refusals,
  byte-preserved history, explicit recovery after fixture-owner repair, overlapping
  linked-worktree calls with reverse completion, and near-capacity reservation.

## Ledger

`scripts/tron work ledger` is the restructure audit ledger ([plan §9.2](../../docs/restructure/plan.md#92-module-issue-the-audit-ledger)).
It reads Git-tracked paths and their owners from `tools/ownership` (the one ownership
authority) and the module issues on GitHub: open or closed issues labeled
`restructure` whose body names `Module: \`<id>\``. Issues closed as not planned or
duplicate are retired. It reports, and never gates:
- ownership violations, unissued modules, and module issues that are duplicates, have
  no manifest or no Area parent;
- checklist entries that are stale (not tracked), owned by another module, listed
  twice or malformed; and owned files missing from their module's checklist;
- states (`unreviewed|keep|delete|simplify|move→<dest>|done`) rolled up per area,
  phase and epic.

Exit 0 means every path is checklisted exactly once; 1 means violations. 3 means
GitHub could not be read: the checklists were **not** checked, which is never
reported as clean. `--module <id>` prints a module's files without GitHub.

`--create <id> --epic <area>` files the module issue (Appendix B body, every file
`unreviewed`, labeled `restructure` at creation) unless one exists, then links it
under the Area. It is safe to re-run after an uncertain or partial failure.
`--sync <issue>` regenerates that issue's `## Files` checklist from the committed
manifests at `HEAD` and records the revision. It needs a committed index and clean
ownership, and re-reads the issue just before writing, refusing a concurrent edit.
- States are kept and follow Git renames (`diff -B -M`) since the recorded
  revision. This includes a path whose state another module issue holds, or a
  file that changed owner. A brand-new file never inherits a stale listing.
- New files are `unreviewed`; sync never marks a file audited. Scopers change
  states in the issue only with review evidence.
- An entry that moved to another module is dropped only after that module's
  issue lists it (sync it first), so sync order cannot lose state.
- An audited entry whose content vanished without a pairing Git can see is
  refused, not dropped. This covers a heavy rewrite during a move and a
  replacement below Git's 400-byte break size. Record its state on the new path
  by hand, set the entry to `delete` or `unreviewed`, and re-run. Only
  `unreviewed` or `delete` entries are dropped silently, and they are still named.
- Issues retired as not planned or duplicate are ignored entirely, including
  their states.

`scripts/tron test tooling scripts/test-work-ledger.py` runs these cases through
the real CLI and Git with a process-level `gh` fixture. Outputs are kept in
`test-results/work-ledger/`.

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
The [agent-first verification design](../../docs/agent-first-verification.md)
records measured costs, task-outcome evidence, conservative test selection and
integration ownership; its proposals add no mandatory checks or services.
