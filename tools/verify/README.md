# Verify

## Gate

`scripts/tron gate` is the one admission to main. From a committed worktree it fetches
`origin/main`, merges the change `--no-ff` in a temporary worktree, runs every check below in
parallel, and pushes that exact merge to main only when all pass. The whole run, from invocation
to the push or refusal, has a 58 s deadline; each check has a 45 s budget. Vitest runs with `--allowOnly=false`; installed dependencies must match the merged lockfile. A check over budget,
a failure, a dirty tree or an expired deadline refuses and leaves main unchanged. There are no
retries, skips, quarantine, selection by risk tier or later full suite: what the gate does not run
is not a gate. One gate runs per clone at a time: it holds `tron-gate.lock` in the common Git directory, which every
linked worktree shares, and a second gate refuses at once, naming the holder's PID and worktree. `--check` runs the same gate and pushes nothing. Each run writes
`test-results/gate/<time>-<id>/` (one log per check and `result.json` with outcome, SHAs and per-step
seconds).

Checks: the privacy guard, the shrink-only determinism baseline (no new `.skip`/`.only`/sleeps), `scripts/tron ownership`, the protocol contract, documentation and agent
policy, no added code comments, the gate's own tests,
Gateway production and test-support typecheck, oxlint, and the fixed Gateway suite named in
`gate.py` (`GATEWAY_TESTS`, `PROCESS_TESTS`): caught regressions (extension artifact discovery,
Home task tool), authorization and privacy, migrations, crash recovery, concurrency/receipts, and real
Gateway-process boundaries. A test joins the gate only if it caught a real regression or guards
one of those classes, and only if the gate still fits its deadline.

`scripts/install-hooks.sh` installs a pre-push hook that runs the gate for any push to main not
already admitted by `scripts/tron gate`. **Enforcement is convention only:** `git push --no-verify`
or a push from another clone bypasses it, and GitHub enforces nothing beyond no force-push or
deletion on main.

Gateway dependencies come from this checkout's `packages/gateway/node_modules`
(`scripts/tron-node exec npm --prefix packages/gateway ci --include=dev`); the gate never installs.

## Lanes

`scripts/tron test <lane>` runs one lane here; `scripts/tron test --host <name> <lane>` runs the same
command on the host `git config tron.verify.<name>` names (an ssh destination; `mini` is the Mac mini),
at this exact commit. The lanes are `gateway` (Vitest files), `tooling` (every tracked `test-*.py`, or
the named files), `ios` (`scripts/tron-ios-test`: `build`, then `run` for the minimal set of in-process
view tests and hosted reconnect journeys, or `checkpoint` for both) and `mac`. The remote side
(`tools/verify/host.py`) refuses a dirty tree, pushes HEAD to the host's bare `~/tron-ci/tron.git`,
runs one job per lane at a time in `~/tron-ci/jobs/<lane>` (a second waits and names the holder),
`npm ci`s only when the Gateway lockfile or pinned Node changed, and streams the lane's own output and
exit. Exit 69 means no result (unreachable, unset or unprepared host), never a test verdict; closing
the session stops the remote lane. Real-Gateway iOS journeys stay `scripts/ios-gateway-e2e-test`.

A host needs Xcode with the pinned iOS runtime, `scripts/tron-node install` and
`scripts/install-ci-tools.sh xcodegen` with `TRON_CI_TOOLS_DIR=~/tron-ci/.ci-tools`, and
`git init --bare ~/tron-ci/tron.git`. Signed device and share builds on the mini use automatic
signing with the App Store Connect API key in `~/.appstoreconnect/private_keys` and an Apple
Development identity in `~/Library/Keychains/tron-signing.keychain-db`, whose random password is
`~/.tron-signing/keychain.pass` (600); unlock that keychain in the ssh session before signing.

## On-demand proof

Everything else is proof an agent runs when it chooses, never admission:
`scripts/tron test gateway <files>` (isolated HOME/TMPDIR under `/tmp`, scratch processes reaped,
Chrome for Testing provisioned for the browser journeys), `scripts/tron test mac`,
`scripts/tron test ios` and `scripts/ios-gateway-e2e-test` (simulator journeys), and
`scripts/tron determinism` / `scripts/tron context audit`. See the [oracle policy](test-oracles.md).
