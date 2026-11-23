# Land

`scripts/tron land [-m <message>]` is the one way a task branch reaches `main`. Run it in the task's own worktree
with a clean, committed tree on the task branch. It runs fetched main's `land.py` and `host_lock.py` (copied into the worktree's
Git directory), never the branch's own, so a branch that lacks or predates them lands by main's rules once its
`scripts/tron` has this wrapper. A change to the `land.py`/`mini.py` contract therefore lands in two steps. It:

1. Waits its turn for the host's `/tmp/tron-land.lock` (first come, first served through `host_lock.py`, the same
   ticket queue as the full-Gateway lock), so one land runs per host and the rest wait in arrival order.
2. Fetches `main` into its private `FETCH_HEAD` and makes a `--no-ff` merge of the branch head onto it in the clone's
   reused land tree (`<git-common-dir>/tron-land-tree`, whose `node_modules` stay; `npm ci` only when a package's inputs
   or the pinned Node changed), so main's first-parent chain stays the landing history. A conflict refuses (exit 2): merge main
   into the branch, commit and land again.
3. Validates that exact merge commit with the merge's own `verify --changed --base <main> --skip mac,python-here
   --ios-host mini --ios-jobs 3`. A merge whose selection has no iOS work runs here: its Gateway runs queue on the full-Gateway lock
   ahead of every other waiter (`TRON_LAND_GATE`), behind only the holder and earlier gates. A merge that selects iOS
   work runs whole on the mini under its lease (build, then the selected iOS tests on its three simulator lanes), and its report returns in
   `test-results/mini/<sha12>-<nonce>/verify.json`. The report must name the merge commit; its evidence is kept in
   `test-results/land/<merge>/`.
4. Pushes that merge to `main` only when the report passed. A red refuses (exit 1) and a missing or foreign report
   is no result (exit 75); main is unchanged either way. Push is a plain fast-forward, never forced.
5. If `main` moved while it validated, the push is refused by Git; land merges the branch onto the new main and
   validates that new merge before pushing it. A merge validated on an older main never lands. If the fetch that
   confirms the push fails, land exits 75 without knowing the outcome: main may already hold the merge, so read
   `git ls-remote origin refs/heads/main` before acting, and never land the same merge blindly again.

There is no GitHub ruleset, status check, token or hosted CI, and no skip or override flag: the validation lives in
the landing process. Not covered: the Mac integration tests and `python-here`, which own their lanes; a merge that selects only
those has no runnable test and is refused as an empty selection. `verify --changed` remains the worker's own fast check before
`land`.

## Main suite

Land runs only what the merge affects: a changed module's own tests always, and the tests it reaches through importers,
consumers and declarations, except unchanged serial `gateway-nested` files and unchanged files listed in
`tools/verify/post-merge.json` (the slow ones); those wait for the main suite. After each landing, `land` starts the
landed commit's `scripts/tron main-suite` detached (log `<git-common-dir>/tron-main-suite/main-suite.log`). One run at a
time holds `tron-main-suite/lock` and judges every main that lands while it runs, newest first. Each full run and probe
executes on the Mac mini through `mini.py verify` under the mini job lock, at exactly that commit, so the long heavy
run stays off this Mac; `tron-main-suite/tree` is only the local checkout it submits from.

`verify --full` green records that commit as green. A red reruns only its red files (`verify --files`; every file of a
group whose failure list is incomplete) once at the same commit. A pass there is nondeterminism: nothing is reverted, the
commit is not recorded green, the log names the files, and both outcomes stay in the test ledger, where
`scripts/tron flakes` lists them for an issue. A red
that reproduces is bisected over main's first-parent merges since the last green, each probed against its own first
parent; a red file absent at a probed commit passes there. The first red merge is reverted `--no-ff` through `land`,
never by a forced push, and never twice. A conflict, a refused land or any missing report is no result (exit 75): main
stays as it is and the run says why. A clone's first run needs the last known green recorded once, `scripts/tron main-suite --green <sha>`; until then each
started run exits 2 into its log.

`tools/verify/tests/test-land.py` proves the behaviour end to end with the real `land.py`, `main_suite.py`, `mini.py`
and `host_lock.py`, a disposable origin and a stand-in mini; `test-host-lock.py` proves the gate's queue priority.
