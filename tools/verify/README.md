# Verify

## Gate

`scripts/tron gate` is the one admission to main. From a committed worktree it fetches
`origin/main`, merges the change `--no-ff` in a temporary worktree, runs every check below in
parallel, and pushes that exact merge to main only when all pass. The whole run, from invocation
to the push or refusal, has a 58 s deadline; each check has a 45 s budget. Vitest runs with `--allowOnly=false`; installed dependencies must match the merged lockfile. A check over budget,
a failure, a dirty tree or an expired deadline refuses and leaves main unchanged. There are no
retries, skips, quarantine, selection by risk tier or later full suite: what the gate does not run
is not a gate. `--check` runs the same gate and pushes nothing. Each run writes
`test-results/gate/<time>-<id>/` (one log per check and `result.json` with outcome, SHAs and per-step
seconds).

Checks: the privacy guard, the shrink-only determinism baseline (no new `.skip`/`.only`/sleeps), `scripts/tron ownership`, the protocol contract, documentation and agent
policy, no added code comments, the gate's own tests,
Gateway production and test-support typecheck, oxlint, and the fixed Gateway suite named in
`gate.py` (`GATEWAY_TESTS`; `LONG_TESTS` and `PROCESS_TESTS` each run as their own parallel step): caught regressions (extension artifact discovery,
Home task tool), authorization and privacy, migrations, crash recovery, concurrency/receipts, and real
Gateway-process boundaries. A test joins the gate only if it caught a real regression or guards
one of those classes, and only if the gate still fits its deadline.

`scripts/install-hooks.sh` installs a pre-push hook that runs the gate for any push to main not
already admitted by `scripts/tron gate`. **Enforcement is convention only:** `git push --no-verify`
or a push from another clone bypasses it, and GitHub enforces nothing beyond no force-push or
deletion on main.

Gateway dependencies come from this checkout's `packages/gateway/node_modules`
(`scripts/tron-node exec npm --prefix packages/gateway ci --include=dev`); the gate never installs.

## On-demand proof

Everything else is proof an agent runs when it chooses, never admission:
`scripts/tron test gateway <files>` (isolated HOME/TMPDIR under `/tmp`, scratch processes reaped,
Chrome for Testing provisioned for the browser journeys), `scripts/tron test mac`,
`scripts/tron test ios` and `scripts/ios-gateway-e2e-test` (simulator journeys), and
`scripts/tron determinism` / `scripts/tron context audit`. See the [oracle policy](test-oracles.md).
