# Verify

`scripts/tron verify` runs one slice's evidence locally: the static checkers, then
the tests its manifests select
([plan §6.2 V2](../../docs/restructure/plan.md#62-scriptstron-verify-v2-the-one-command)).
The worker owns it. It never queues, waits on another worker, caches a pass,
writes a receipt or gates a landing.

```bash
scripts/tron verify --changed [--base <ref>]   # a slice: the change since merge-base(<ref>, HEAD)
scripts/tron verify --module <id>               # one module's owned tests
scripts/tron verify --all                       # every lock (milestones, kernel changes)
scripts/tron verify --update-locks <id>         # rewrite <id>'s goldens (lock or approved migration slices)
scripts/tron verify ... --skip ios,mac,relay    # accept, explicitly, selections this run will not run
scripts/tron verify ... --plan                  # print the selection and steps only
```

It reads the committed state: uncommitted or untracked changes are refused
(exit 2). Each step prints `[i/N] name …` and its live log path when it starts,
and its result and time when it ends. The first failure stops the run and prints the log tail. Every
step's full log is in `test-results/verify/<sha>/`, and the report is
`test-results/verify/<sha>.json`. The report's `resultDigest` covers the
selection, each step's outcome and test count, and the verdict, but not timing,
so two runs of one commit against one base can be compared (a reused iOS build compares equal to
the build that stamped it).

## Static checks (existing tools only)

1. `scripts/tron ownership`
2. `scripts/tron budgets HEAD --base <base>`
3. documentation policy
4. the privacy guard over `git diff <base>..HEAD`
5. `git diff --check`
6. `scripts/tron work ledger`, which is **advisory**: issue state is shared
   coordination, not this commit's code, so its violations are reported but
   never fail the run.
7. When the selection touches the Gateway: `npm run check` (production and test
   support typecheck), `npm run lint`, and `scripts/tron layers gateway`.
8. `scripts/tron layers ios` on this commit's Xcode index store (see the iOS lane
   below). A selection without the iOS lane runs it only when a fresh index
   exists; otherwise it is reported as skipped, never as passed.

V10 also runs `scripts/tron measure <base> HEAD` as an advisory step, writing
per-file moved/rewrite counts to `test-results/measure/`. Neither counts nor
measurement errors fail verify; errors remain visible in its step status/log.

## Selection

Paths changed between the merge base and HEAD, both old and new names, map to
their owning manifests (`tools/ownership`; deleted paths are owned as of the
base). Each module contributes its owned tests:
- `*.test.ts` and `*.test.mjs`;
- `test-*.py` and `test-*.sh`;
- Swift `*Tests.swift` under test targets.

Recorders under `test-fixtures/` are never run. Modules whose `dependsOn` or
`dynamicEdges` reach a selected module add their locks, transitively.

The run widens to **every lock** when the change touches a module at layer
L0–L2 (platform, contracts, kernel), `gateway/package` (toolchain),
`gateway/test-support`, `gateway/pi-sdk`, or an unowned path. Locks are
`*.lock.integration.test.ts`, the Pi SDK behavior trace and persisted-state
corpus, and the iOS UI locks (`packages/ios-app/UITests/Locks/`).
`ios-app/ui-tests` declares a `spawn` dynamic edge to every module built into
the hosted app, so a change to any of them selects the UI locks.

Runners are the existing ones:

| Group | Runner |
|---|---|
| `gateway` / `gateway-nested` | Gateway vitest, main or `vitest.nested.config.ts` |
| `node-gateway` / `node` | `node --test` |
| `python` / `shell` | `python3` / `bash` per file |
| `ios` | `scripts/tron-ios-test run --only-testing <target>/<class>`: the UIValidation targets |
| `ios-lanes` / `mac` / `relay` | not driven by verify |

When `ios-lanes` (the Gateway E2E and profiling targets, and the UIValidation
journeys that need their harness's fixture: `scripts/ios-gateway-e2e-test`,
`scripts/ios-mac-terminal-journey`), `mac` or `relay` tests
are selected, the run is `incomplete` (exit 1) unless `--skip` names them
(`--skip ios` covers `ios-lanes`); they need their own lanes or the relay's own
dependencies. A selection that runs zero passing tests fails: an empty run is not
evidence.

## iOS lane

`--all`, a selection with `ios` tests, or a `--changed` change owned by an
`ios-app/` module runs the iOS lane unless `--skip ios`:
1. **`ios build`.** If this worktree's test products and index are stamped for
   this commit on a clean tree (the stamp `layers ios` trusts), they are reused. Otherwise
   it runs `scripts/tron-ios-test build`. So `verify` builds once per commit,
   and a second run reuses that build.
2. **`layers ios`** on that build's index store. A stale or missing index is a
   failure, never a skip; there is no symbol-scan fallback.
3. **`tests: ios`** runs the selected files on the same products. It runs one
   `--only-testing` owner per file: the target and the class the file is named
   for. The count is `passedTests` from the run's XCTest `summary.json`. A
   failure lists the summary's failing tests. `--update-locks` passes
   `TEST_RUNNER_TRON_UPDATE_LOCKS`; recorded goldens are source, so commit and
   rebuild before comparing.

`scripts/tron-ios-test` keeps the lane, lease (exit 73 when busy) and cleanup
ownership. Run one simulator job per worktree; verify never waits for another
worker.

## Mutation sampling

`scripts/tron mutate <packages/gateway/src file> [--count 30] [--seed 1465]` measures
lock sensitivity (plan §6.6; the maintainer's 0.10 decision). For one file it:
1. takes a seeded sample of single-operator flips (`===`/`!==`, `&&`/`||`,
   `true`/`false`, comparisons, `±1`);
2. runs the Gateway vitest **locks** `verify --changed` would select for a change
   to that file, once per mutant. M1 sensitivity is what locks catch, and module
   journeys can take minutes per run. The unmutated locks run first; if they do
   not pass cleanly, no mutant runs;
3. counts a mutant as killed only when its run's vitest report shows a failing
   test or a suite the mutant broke. A run with no readable report is a harness
   error, excluded from the rate, and makes the command exit 1.

The file is restored after every mutant. The report goes to
`test-results/mutate/`. It measures and never gates. Stryker is deferred until a
known-kill probe proves its vitest runner activates mutants with the pinned vitest.

## Verify

`scripts/tron test tooling scripts/test-tron-verify.py` drives verify in
disposable repositories whose modules own real Python tests. It covers
one-module selection and a loud failure, kernel/unowned widening, the
zero-test failure (structured verdict, runner exit and count, including unittest's
exit 5 on Python 3.14+ and exit 0 with zero tests on older Python), the uncommitted
refusal, and identical result digests. Its iOS lane case uses a stand-in
`scripts/tron-ios-test` that keeps the real contract: `build` compiles a real index
store with `swiftc` and writes the real stamp, and `run` writes an XCTest-style
`summary.json`. The case checks that a change selects only the UI locks, the build
runs once and is reused with an identical digest, the real `layers ios` runs on it,
and failing or empty summaries fail.
Output is kept in `test-results/verify-cli/`.
