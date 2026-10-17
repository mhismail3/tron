# Affected-test selector pilot (#1259): outcome

Status: **dropped**. Manual owner selection stays. No selector ships on main.

The pilot built a fail-closed shadow map from real Git diffs (rename/delete aware,
both sides of each change) and reference edges: imports, literal paths, globs,
directories and dynamic resource sites. Owner closures are not proven complete
(regex edges miss computed APIs, oversized blobs and Swift/host consumers), so the
selector always falls back to every owner. The static graph is advisory evidence only.

- Parent counterexamples (real Git, real child processes; dynamic module, filesystem,
  child process): initial heuristic 3/3 missed; corrected full fallback 0/3 missed,
  15/15 selected, zero gross saving.
- Real defect #1258 (pre-fix `land.py` restored in the mutated tree): broad sweep
  detected by `scripts/test-work-land.py`. The initial candidate selected 11/15 and
  would have been 0/1 by that criterion only; its selections were unsafe because it
  missed 3/3 seeded counterexamples, so that saving is invalid.
- Frozen recent-main replay (7 first-parent commits, including a 19-deletion commit
  and a 2-rename commit): all fallback, selected 15/15, selector overhead 2.8-12.1 s.

Net projected saving is zero gross minus selector overhead, so it is negative.
Private sources, controls, replay and raw JSON live under
`~/.tron/workspace/files/agent-checks/pilots/selector/` (not committed).
Gateway, iOS and Mac owners remain unexecuted and unknown.
