# Verify

`scripts/tron verify` mechanically plans a change, runs its affected checks locally,
and reports broader coverage needed after landing. The manifests and their dependency
and dynamic-edge graph are the selection authority. No queue, landing gate, hosted CI,
automatic scheduler or revert is involved. A previous test pass never substitutes for
this change's affected checks; only stamped build products are reused.

```bash
scripts/tron verify [--base <ref>]             # affected checks since merge-base(<ref>, HEAD)
scripts/tron verify --plan                     # tier, paths, reasons and exact commands; dirty trees allowed
scripts/tron verify --changed [--base <ref>]   # explicit diff selection, also used by mutation sampling
scripts/tron verify --module <id>               # scoped baseline: owner tests + transitive consumer locks
scripts/tron verify --all                       # all locks + serial files deferred by this base..HEAD diff
scripts/tron verify --batch --base <green-sha>   # initialize coverage in a dedicated clean main worktree
scripts/tron verify --batch [--plan]            # next pinned batch since the local last green
scripts/tron verify --update-locks <id>         # rewrite <id>'s goldens (lock or approved migration slices)
scripts/tron verify ... --skip ios,mac,relay    # accept, explicitly, selections this run will not run
scripts/tron verify ... --plan                  # print the selection and steps only
```

## Worktree dependencies

Worktree creation does not install dependencies. Before running a selection that
uses the Gateway, prepare **that worktree**, including development dependencies:

```bash
scripts/tron-node exec npm --prefix packages/gateway ci --include=dev
```

Verify never installs dependencies automatically or borrows another checkout's
`node_modules`. Before running checks it requires the installed TypeScript version
to match `packages/gateway/package.json` and npm's local `.bin/tsc` to resolve to
that package's executable. A missing, stale or broken install fails early (exit 2)
with the preparation command; a global `tsc` on PATH cannot satisfy it. `tron-node`
resolves the pinned Node independently of interactive shell setup. `--plan` and
selections that do not use the Gateway need no Gateway compiler.

## Gateway test isolation

Both `scripts/tron test gateway` and verify's Gateway Vitest groups use
`tools/verify/gateway.py`. It resolves pinned development Node first, then gives
one test process its own temporary HOME, TMPDIR, Tron data directory and agent
resource directory. It waits for Vitest before removing those directories, also
forwarding cancellation to the owned child. It never installs missing packages.
Migration fixtures seed explicit historical JSON; they never copy the invoking
user's settings or profile. Test input and output must not depend on live stores.

## Run output

Execution reads committed state: uncommitted or untracked changes are refused
(exit 2). `--plan` additionally includes staged, working and untracked paths; add new
files to Git before relying on their ownership. Each step prints `[i/N] name …`, its
live log, result and wall time. The first failure stops the run and prints its tail.
`test-results/verify/<sha>.json` is atomically updated before/after every step;
`running` and `interrupted` are not passes. SIGINT/SIGTERM stops and joins the owned
step process group while retaining partial results. Full logs are in
`test-results/verify/<sha>/`. Repeating a selection at one SHA overwrites this local
report; batch evidence is copied separately before another run. The `resultDigest` covers the
selection, each step's outcome and test count, and the verdict, but not timing,
so two runs of one commit against one base can be compared (a reused iOS build compares equal to
the build that stamped it). Python unittest counts exclude skipped and expected-failure
cases; a file with no executed passes cannot hide beside a passing neighbour.

## Static checks (existing tools only)
1. `scripts/tron ownership`
2. `scripts/tron budgets HEAD --base <base>` (sizes are reported; few cases fail)
3. documentation policy and `scripts/check-agent-policy.sh`; `scripts/tron docs check
   --base <base>` when Markdown, a manifest or the Gateway changed (a Markdown-only
   change needs no Gateway `node_modules`; [tools/docs](../docs/README.md))
4. the privacy guard over `git diff <base>..HEAD`
5. `git diff --check`
6. When the selection touches the Gateway: `npm run check` (production and test
   support typecheck), `npm run lint`, and `scripts/tron layers gateway`.
7. `scripts/tron layers ios` on this commit's Xcode index store (see the iOS lane
   below). A selection without the iOS lane runs it only when a fresh index
   exists; otherwise it is reported as skipped, never as passed.

### Known failures

`tools/verify/known-failures.json` is validated on every selection, including plans.
Each entry names an exact `<repository-relative-test-path>::<full-case-name>`,
failing `evidence.command`, full base `evidence.commit`, SHA-256
`evidence.failureDigest`, owner `issue` number and ISO `expires` date. The digest
covers the full failure-message array (JSON, `ensure_ascii=False`), replacing only
the checkout root with `<repo>`; a changed failure inside the same test refuses.
The commit must be an ancestor of HEAD. Expiry is 00:00 UTC on the named date.
Gateway waiver entries require fresh current-main reproductions and raw logs/JSON.
Swift cases under `packages/mac-app/Tests/Integration/` may record explicitly
branch-observed intermittent failures with the original commit, exact xcresult
failure-text-array digest and owner issue. These are observational metadata only:
they are filtered out of the waiver map; Mac failures always remain failures.
An ancestry-preserving merge never turns branch evidence into main evidence.

Tests execute unchanged. Only exact, unexpired case AND digest matches allow exit 0
with verdict `quarantined`; `failedTests`, passing counts, logs and each expiry/issue
remain visible. This is not an unqualified pass. Unknown failures, suite/runtime
errors, missing reports, malformed or expired entries exit 1. Expiry blocks even
unselected cases; remove/repair entries, never silently renew without new evidence.
No wildcard/file waiver, retries, alternate runner or legacy verdict mode.

Verify runs `scripts/tron measure <base> HEAD` as an advisory step, writing per-file moved/rewrite
counts to `test-results/measure/`; its counts and errors never fail verify.

## Selection

Paths changed between the merge base and HEAD, both old and new names, map to
their owning manifests (`tools/ownership`; deleted paths are owned as of the
base). Each module contributes its owned tests:
- `*.test.ts` and `*.test.mjs`;
- `test-*.py` and `test-*.sh`;
- Swift `*Tests.swift` under test targets.

Recorders under `test-fixtures/` are never run. For `--changed` and `--module`,
modules whose `dependsOn` or `dynamicEdges` reach a selected module add their
locks, transitively. A source-only module baseline can therefore run its existing
hosted consumer locks without owning a second test list or selecting the consumers'
ordinary journeys. `--module` does not widen to unrelated kernel locks;
`--update-locks` remains confined to the named owner's locks.

Small changes run only what can catch a regression in them:
- **Markdown** selects no module: no test reads it, so the documentation
  checks are its evidence. A Markdown-only change passes on the static checks.
- A module whose change is **only its own tests and goldens** (`*.golden.*`,
  `Goldens/`) runs those tests, plus its locks when a golden changed. Nothing
  else reads them, so it neither widens nor adds dependents' locks. Code
  beside them selects the module as usual.

A Swift or Gateway string edit is code: its tests and locks run (locks compare labels).

### Mechanical tier rule

| Tier | Changed inputs | Evidence before landing |
|---|---|---|
| **none** | Empty diff or Markdown only | Static/documentation checks; no executable tests |
| **partial** | Tests/goldens only, or ordinary owned code (including Swift UI) | Changed tests; golden owner's locks; otherwise owner tests + transitive consumer locks/declarations |
| **full** | Production changes in L0–L2, `gateway/package`, `gateway/test-support`, `gateway/pi-sdk`; declared kernel/contracts/persistence/security/lifecycle/mac-installer risk; manifest/layer-baseline/toolchain/project configuration; unknown ownership | The same affected checks **now**, plus all-lock/full-lane coverage in the next explicit batch |

Test/golden-only narrowing precedes module risk; a manifest/configuration edit still
requires a full batch. Unchanged files in the existing serial `gateway-nested` list
are deferred, never dropped: production changes selecting them require a full tier.
A changed serial test file and locks selected by a golden edit run immediately.
`--all --base <green>` includes every serial file selected by that covered diff,
including changed tests already run before landing: later integration may affect
them too. It is not limited to the one nested lock. Explicit `--module` baselines still run
the complete scoped set. A serial-only selection may pass its affected static checks
while explicitly reporting deferred tests; it is not a test pass or a green batch. `ios-ui` risk alone does not widen beyond the affected UI build
and journeys. Renames include both paths; deleted paths use base ownership. Retired
owners retain consumer closure and risk, but cannot declare commands. Risk is read
from each changed producer's manifest, not inferred from every reverse consumer.
An unowned tracked path still fails ownership, not a green partial run. A new module
without executable evidence still fails; a tier never turns missing evidence into a pass.

`--plan` prints `selection.tier`, paths, reasons, immediate tests, `batchTests`, and
commands/cwds, `deferredTests` and their exact commands. A successful **full-tier** ordinary run proves affected checks only;
it does not claim the full batch passed. Locks are `*.lock.integration.test.ts`, the
Pi trace/persisted-state corpus and `UITests/Locks/`. `ios-app/ui-tests` declares
`spawn` edges to the hosted app modules, selecting their affected UI locks.

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

## Manifest `verify` declarations

Modules may declare extra consumer verification using explicit tracked inputs:

```json
"verify": [
  "scripts/tron test tooling scripts/test-tron-verify.py scripts/verify-gateway-protocol-contract.py",
  "scripts/tron test gateway src/transport/command-receipts.lock.integration.test.ts",
  "scripts/tron test ios run --only-testing TronMobileUITests/SnapshotCachePersistenceContractTests"
]
```

These strings select files for the existing runners; verify never executes them
as shell commands. Tooling accepts only `scripts/test-*.py` / `scripts/verify-*.py`;
Gateway accepts `src/**/*.test.ts` and Gateway-relative `*.test.mjs`. iOS accepts one or
more `--only-testing Target/Class` pairs, resolved to tracked UIValidation test
files; method selectors, broad runs, build flags, unknown classes/paths and
other command forms fail selection (exit 2). Harnessed classes retain their
`ios-lanes` classification. There is no implicit install or alternate runner.

Changed/module selection includes declarations of selected modules and their
reverse dependency closure; full batch coverage and `--all` include every declaration.
Markdown/test-only narrowing and lock-only `--update-locks` remain unchanged.
Files are deduplicated across ownership and declarations, then use normal
counts, explicit skips and incomplete verdicts. A zero-test Python suite fails
even beside another passing suite. `--plan` shows selection, not test evidence.

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
   `--only-testing` owner per class: the target and the class the file is named
   for, or else the class it `extension`s (a file of a harnessed journey runs
   in that journey's lane). A file naming neither fails the run, unless it
   skips iOS. The count is `passedTests` from the run's XCTest `summary.json`. A
   failure lists the summary's failing tests. `--update-locks` passes
   `TEST_RUNNER_TRON_UPDATE_LOCKS`; recorded goldens are source, so commit and
   rebuild before comparing.

`scripts/tron-ios-test` keeps the lane, lease (exit 73 when busy) and cleanup
ownership. Run one simulator job per worktree. Its `build` and `run` take one of the
three host-wide simulator slots and wait, naming the holders, when all are taken;
verify has no other wait.

## Explicit Mac batches

Mohsin or an explicitly requested Home task invokes `verify --batch` in a persistent,
clean worktree on landed main history. Ensure a simulator-job slot is available (at
most three across workers); the batch itself runs one lane at a time. No daemon or
schedule is created. Prepare that worktree's pinned Gateway development dependencies;
no application install, service restart, deployment or OTA command is part of a batch.

First invocation requires an explicit known-green `--base`; later invocations cannot
override it. One repository-local record at `<git-common-dir>/verify/green.json` owns
the previous green. A nonwaiting file lock refuses simultaneous batches. The command
pins HEAD, records **all** commits in `base..HEAD` (including merged branches), then
runs existing owners serially: all-lock verify, unsigned shipping-iOS compile, the UI
runner's smoke set on those products, real-Gateway boundary and real-UI journeys, and
fixture stop. Lanes absent from a repository are not invented; this repository has
all of them. Mac/relay-specific suites remain their owners' explicitly selected
checks, not implied coverage. `--skip` is not accepted for batches.

Each lane runs once per batch, not once per covered commit. The next batch reuses that
worktree's incremental build products after the normal source-stamp checks. Same green
HEAD runs nothing. Only complete success advances green. There is no prior green if
initialization fails. Immutable run directories under `<git-common-dir>/verify/batches/`
retain the exact range, commits/files, commands, wall times, logs and copied verify
report; no task-worktree cleanup removes them. `--batch --plan` changes no state.

Failure preserves completed lanes immediately and leaves green unchanged. In one
disposable worktree, the failing lane is rerun at previous green and HEAD with local
pinned dependencies, then bisected along main's first-parent integration commits only
when the **same failure signature** reproduces. Other failures/setup errors are
inconclusive; a failing baseline is pre-existing. A report never invents a culprit:
it records proven integration/files or candidate commits. The worktree retains its
incremental products between probes and cleans its own fixture/lane/products on exit.
If an owner refuses cleanup or cleanup is interrupted, it preserves that worktree and
journals its exact path and completed cleanup results in `attribution/progress.json`;
resolve those owned resources before discarding it.
A privacy-checked `scripts/tron work issue create` files the result; a refused or
uncertain write is recorded before dispatch in `<git-common-dir>/verify/issue-writes/`,
keyed by range/lane. Re-running that range retains the previous outcome, including an
unfinished attempt; resolve uncertain GitHub state manually, never create blindly again.
No unrelated worker waits,
main is never reverted, and failed coverage is not silently skipped by changing base.

## Mutation sampling

`scripts/tron mutate <packages/gateway/src file> [--count 30] [--seed 1465] [--timeout 300]` measures
lock sensitivity (plan §6.6; the maintainer's 0.10 decision). For one file it:
1. takes a seeded sample of single-operator flips (`===`/`!==`, `&&`/`||`,
   `true`/`false`, comparisons, `±1`);
2. runs the Gateway vitest **locks** `verify --changed` would select for a change
   to that file, once per mutant. M1 sensitivity is what locks catch, and module
   journeys can take minutes per run. The unmutated locks run first; if they do
   not pass cleanly, no mutant runs;
3. counts a mutant as killed only when its run's vitest report shows a failing
   test or a suite the mutant broke, or when the run outlives `--timeout`
   (default 300 s; an infinite loop starves vitest's own timers). A timed-out
   run is stopped with its whole process group and reported as `timeout`. A run
   with no readable report is a harness error, excluded from the rate, and makes
   the command exit 1.

The file is restored after every mutant, also on interrupt or SIGTERM. The
report goes to `test-results/mutate/` and is rewritten after each mutant
(`complete: false` until the run ends), so an interrupted run keeps its results. It is a milestone measurement (and a lock author's tool), never a per-slice gate. Stryker is deferred until a
known-kill probe proves its vitest runner activates mutants with the pinned vitest.

## Verify

`scripts/tron test tooling scripts/test-tron-verify.py scripts/test-tron-verify-tiers.py` drives verify in
disposable repositories whose modules own real Python tests: selection, widening,
the small-change paths with a known-bad case each, loud and zero-test failures,
the uncommitted refusal and identical digests. A stand-in `scripts/tron-ios-test`
keeps the real contract (`build` compiles a real index store with `swiftc` and
writes the real stamp; `run` writes an XCTest-style `summary.json`) for the iOS
lane: locks-only selection, one reused build, the real `layers ios`, failing or
empty summaries, and extension files. Real Git/process fixtures also exercise tiers,
dirty planning, interrupted descendant cleanup/partial reports, exact green ranges,
nonwaiting overlap refusal, failure bisection and unavailable issue authority. Over a fake Gateway runner it covers
`mutate`'s timeout and interrupt. Output is kept in `test-results/verify-cli/`.
