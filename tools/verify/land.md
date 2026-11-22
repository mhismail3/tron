# Land

`scripts/tron land [-m <message>]` is the one way a task branch reaches `main`. Run it in the task's own worktree
with a clean, committed tree on the task branch. It runs fetched main's `land.py` and `host_lock.py` (copied into the worktree's
Git directory), never the branch's own, so a branch that lacks or predates them lands by main's rules once its
`scripts/tron` has this wrapper. A change to the `land.py`/`mini.py` contract therefore lands in two steps. It:

1. Waits its turn for the host's `/tmp/tron-land.lock` (first come, first served through `host_lock.py`, the same
   ticket queue as the full-Gateway lock), so one land runs per host and the rest wait in arrival order.
2. Fetches `main` into its private `FETCH_HEAD` and makes a `--no-ff` merge of the branch head onto it in a temporary
   linked worktree, so main's first-parent chain stays the landing history. A conflict refuses (exit 2): merge main
   into the branch, commit and land again.
3. Validates that exact merge commit on the Mac mini through `mini.py verify` under the mini job lock: the affected
   Tier 0 to 2 checks, `verify --changed --base <main> --skip ios,mac,python-here --gateway-host local`. The returned report must name the
   merge commit; its evidence is kept in `test-results/land/<merge>/`.
4. Pushes that merge to `main` only when the report passed. A red refuses (exit 1) and a missing or foreign report
   is no result (exit 75); main is unchanged either way. Push is a plain fast-forward, never forced.
5. If `main` moved while it validated, the push is refused by Git; land merges the branch onto the new main and
   validates that new merge before pushing it. A merge validated on an older main never lands. If the fetch that
   confirms the push fails, land exits 75 without knowing the outcome: main may already hold the merge, so read
   `git ls-remote origin refs/heads/main` before acting, and never land the same merge blindly again.

There is no GitHub ruleset, status check, token or hosted CI, and no skip or override flag: the validation lives in
the landing process. Not yet covered: Tier 3 (iOS) and the Mac integration tests, which the mini cannot sign, and
`python-here`, which reads this Mac's session store. `verify --changed` remains the worker's own fast check before
`land`.

## Main suite

Land runs only what the merge affects: a changed module's own tests always, and the tests it reaches through importers,
consumers and declarations, except unchanged serial `gateway-nested` files and unchanged files listed in
`tools/verify/post-merge.json` (the slow ones); those wait for the main suite. After each landing, `land` starts the
landed commit's `scripts/tron main-suite` detached on this host (log `<git-common-dir>/tron-main-suite/main-suite.log`).
One run at a time holds `tron-main-suite/lock`; it judges every main that lands while it runs, newest first, in one warm
checkout (`tron-main-suite/tree`, `npm ci` only when a lockfile changed). It runs here, not on the mini, so the mini stays
free for the gate; its Gateway lanes queue on this host's full-Gateway lock like any local Gateway run.

`verify --full` green records that commit as green. A red reruns only its red files (`verify --files`; every file of a
group whose failure list is incomplete) once at the same commit. A pass there is nondeterminism: nothing is reverted, the
commit is not recorded green, the log names the files, and both outcomes stay in the test ledger, where
`scripts/tron flakes` lists them for an issue. A red
that reproduces is bisected over main's first-parent merges since the last green, each probed against its own first
parent; a red file absent at a probed commit passes there. The first red merge is reverted `--no-ff` through `land`,
never by a forced push, and never twice. A conflict, a refused land or any missing report is no result (exit 75): main
stays as it is and the run says why. The first run records the last known green with `--green <sha>`.

`tools/verify/tests/test-land.py` proves the behaviour end to end with the real `land.py`, `mini.py` and
`host_lock.py`, a disposable origin and a stand-in mini.
