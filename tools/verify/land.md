# Land

`scripts/tron land [-m <message>]` is the one way a task branch reaches `main`. Run it in the task's own worktree
with a clean, committed tree on the task branch. It:

1. Waits its turn for the host's `/tmp/tron-land.lock` (first come, first served through `host_lock.py`, the same
   ticket queue as the full-Gateway lock), so one land runs per host and the rest wait in arrival order.
2. Fetches `main` into its private `FETCH_HEAD` and makes a `--no-ff` merge of the branch head onto it in a temporary
   linked worktree, so main's first-parent chain stays the landing history. A conflict refuses (exit 2): merge main
   into the branch, commit and land again.
3. Validates that exact merge commit on the Mac mini through `mini.py verify` under the mini job lock: Tiers 0 to 2,
   `verify --full --base <main> --skip ios,mac,python-here --gateway-host local`. The returned report must name the
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
`land`; the async `verify --batch` still runs on landed main until its retirement.

`tools/verify/tests/test-land.py` proves the behaviour end to end with the real `land.py`, `mini.py` and
`host_lock.py`, a disposable origin and a stand-in mini.
