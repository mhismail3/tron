# Verify

`scripts/tron verify` runs affected checks locally and reports broader post-land coverage. The manifests and their dependency
and dynamic-edge graph are the selection authority. No merge queue, landing gate or hosted
CI is involved, and nothing here pushes or reverts main ([principles P2](../../docs/PRINCIPLES.md#p2-verification-gates-promotion-not-authorship)). A previous test pass never substitutes for
this change's affected checks; only stamped build products are reused. See the
[oracle policy](test-oracles.md) and [on-demand health contract](health-design.md#on-demand-command).

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
   --base <base>` when Markdown, a manifest or the Gateway changed; `--all` and empty-diff
   baselines check every block without `--base` (loaded generators need Gateway dependencies).
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
The commit must be an ancestor of HEAD. Expiry is 00:00 UTC on the named date,
strictly after the reproduction commit's UTC date and at most seven days later.
A case may be renewed once: retain the original entry, then append its renewal with
`renewedFrom` equal to the original `evidence.commit`. Renewal requires a new descendant
reproduction commit dated on/after the original expiry and a newly reproduced digest
(the same defect may have the same digest). Its own expiry has the same seven-day bound.
The validator checks reachable registry history, so deleting entries after a fix does
not reset a case's renewal budget. A second renewal is refused; fix or revert instead.
Gateway waivers require fresh current-main reproductions and raw logs/JSON. Swift cases under `packages/mac-app/Tests/Integration/` may instead record explicit branch observations with original commit, exact xcresult failure-text-array digest and owner issue; they never enter the waiver map or waive Mac failures. Restoring ancestry never makes branch evidence main evidence.

Tests execute unchanged. Exact, unexpired case AND digest matches allow exit 0
with verdict `quarantined` (qualified, never green); `failedTests`, passing counts,
logs and each expiry/issue remain visible. Exact expired matches instead yield
`expired` (exit 0 pre-land), retaining `expiredReds`, not waiving them as qualified.
Every selection lists all `expiredEntries`, even unrelated ones: expiry never blocks
authorship, but blocks checkpoint proposals. `--all` reports `expired` whenever any
entry is expired so the batch cannot qualify it. Unknown/changed signatures,
suite/runtime errors, missing reports and malformed registry data still exit 1.
Health retains expired/deferred verdicts and counts expired failures as unwaived reds.
Selections record `checkpointEligible: false`; only a complete batch establishes eligibility.
A maintainer-requested install despite expiry must list the expired red explicitly. No wildcard/file waiver, retries or alternate runner.

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
- **Documentation** (Markdown or assets owned by `repo/docs`, except module manifests)
  selects no module: static/documentation checks are its evidence. Deleted assets
  use base ownership too. Such a diff needs no Gateway dependencies
  ([tools/docs](../docs/README.md)); ordinary code without tests still fails.
- A module whose change is **only its own tests and goldens** (`*.golden.*`,
  `Goldens/`) runs those tests, plus its locks when a golden changed. Nothing
  else reads them, so it neither widens nor adds dependents' locks. Code
  beside them selects the module as usual.

A Swift or Gateway string edit is code: its tests and locks run (locks compare labels).

### Mechanical tier rule

| Tier | Changed inputs | Evidence before landing |
|---|---|---|
| **none** | Empty diff or documentation only | Static/documentation checks; no executable tests |
| **partial** | Tests/goldens only, or ordinary owned code (including Swift UI) | Changed tests; golden owner's locks; otherwise owner tests + transitive consumer locks/declarations |
| **full** | Production changes in L0–L2, `gateway/package`, `gateway/test-support`, `gateway/pi-sdk`; declared kernel/contracts/persistence/security/lifecycle/mac-installer risk; manifest/layer-baseline/toolchain/project configuration; unknown ownership | The same affected checks **now**, plus all-lock/full-lane coverage in the next batch |

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

`--all`, `ios` tests, or a changed `ios-app/` module runs this lane unless `--skip ios`:
1. **`ios build`** reuses clean, current-commit stamped products/index; otherwise builds
   with `scripts/tron-ios-test build`. Subsequent runs reuse that build.
2. **`layers ios`** reads that index. Stale/missing indexes fail; no symbol-scan fallback.
3. **`tests: ios`** uses the same products, one `--only-testing Target/Class` per class
   named or extended by the file. Harnessed journeys use their own lanes. A file naming
   neither fails unless iOS is skipped. Counts/failures come from XCTest `summary.json`
   (`passedTests`); `--update-locks` passes `TEST_RUNNER_TRON_UPDATE_LOCKS`. Goldens are
   source: commit and rebuild before comparing.

The existing runner owns lanes, leases, cleanup and the three host-wide slots; run
one job per worktree. Pre-land build/run passes `--host-slot-wait-seconds 30`, bounding
only acquisition, never admitted work. No option retains unbounded waiting (including
batch `--all`). Busy exit 73 records named checks/tests as `deferred`, exit 0, never
passed. A deferred build also defers its index/tests; other affected checks still run.
The batch covers those files. Genuine build/test errors and zero-test runs still fail.

## Explicit Mac batches

Home ([P2 owner](../../docs/PRINCIPLES.md#p2-verification-gates-promotion-not-authorship)) or Mohsin
runs `verify --batch` in a persistent clean worktree on fetched, landed main history.
No scheduler, application install, deployment, service restart, push or automatic main revert is included. Every terminal run emits JSON `batchResult`, head and report path;
the Home caller must deliver it, including red/uncovered. The trigger is a separate owner.

First use requires `--base <main-anchor>`, not a claim of prior green.
`verify/covered.json` owns the last green/qualified head; `verify/green.json` records strict green. `--base` cannot override coverage. A nonwaiting `batch.lock`
refuses overlap; same covered HEAD does nothing; `--plan` is read-only.
After local pinned Gateway/relay dependency preparation, every required lane runs even
after failures: locks/declared consumers (`verify --all`, not full Gateway), full default
and nested Gateway Vitest separately, signed Mac integration build/tests, relay Workers
Vitest, unsigned shipping iOS compile, UI smoke `checkpoint` (build/run), real-Gateway
boundary and real-UI journeys (installation disabled). Mac execution uses scratch HOME/TMPDIR.
Missing owners/reports, empty/skipped evidence, deferred lanes and failed setup/cleanup
are **uncovered**. Otherwise **green** means all passed; **qualified** requires every failure
to match an unexpired exact registry case/digest; **red** means unwaived failure. Qualified
advances covered history, never green; expired/changed digests waive nothing.
Immutable `<git-common-dir>/verify/batches/` reports retain commands, logs, range age,
lane wall times and attribution host seconds; task cleanup never removes them.

iOS lanes release host slots between lanes (cap three). All slots busy at admission means
deferred/uncovered, not a reservation or batch queue; races use the runner's owning lease.
Unsigned compile composes `ios-test-lock.py --host-slot`; its owner lacks a simulator slot.
Attribution follows coverage: probe one Vitest file plus anchored case filter, or an
available XCTest class/method selector, at both ends and along main's first-parent chain.
Never rerun a whole suite diagnostically. Missing selectors yield uncovered/inconclusive;
setup errors or changed signatures are inconclusive, a failing baseline is pre-existing.
A non-reproducing head retains flake attempts but needs a registry entry to qualify.
Proof requires a two-parent landing-shaped range, identical signature twice at culprit
and an observed good first parent; search costs approximately `ceil(log2(N)) + 3` probes; other history yields candidates only. Commit/lane/signature probes in `verify/probes/`
and range memos in `verify/attributions/` prevent repeated work. Culprit files use
`git diff <merge>^1 <merge>`; proof prepares local `revert/<sha>` via `git revert -m 1`,
never pushing. Conflicts and refused/interrupted resource cleanup preserve the probe
worktree and `attribution-*/progress.json` for exact-resource recovery.
Guarded issue writes journal before dispatch in `verify/issue-writes/`, keyed by lane
and normalized signature, not range. Later ranges comment on the same issue. Refused,
uncertain or unfinished writes require reconciliation, never blind replay.

## Mutation sampling

`scripts/tron mutate <packages/gateway/src file> [--count 30] [--seed 1465] [--timeout 300]`
measures lock sensitivity, never per-slice eligibility. It samples seeded single-operator
flips (`===`/`!==`, `&&`/`||`, booleans, comparisons, `±1`) and runs the locks selected
for that source once per mutant, not the module's ordinary journeys. Unmutated locks
must pass first. A failing test/suite in the Vitest report or a timed-out process is a
kill; timeout stops the whole owned group (default 300 s, including infinite loops).
Missing reports are harness errors, excluded from the rate, and exit 1. Source is
restored after each mutant, interrupt or SIGTERM. Incremental `test-results/mutate/`
reports retain partial results (`complete: false` until finished). Stryker remains
deferred until a known-kill probe proves activation with pinned Vitest.

## Verify

`scripts/tron test tooling scripts/test-tron-verify.py scripts/test-tron-verify-tiers.py scripts/test-tron-verify-batch.py`
drives real Git/CLI fixtures: affected selection, known-bad small changes, zero-test
refusal, reproducible digests, dirty planning, descendant cleanup, batch ranges/overlap,
bisection and refused issue authority. The iOS stand-in compiles real Swift indexes
and stamps, exercises real `layers ios`, and emits XCTest-style summaries: locks-only
selection, reuse, extensions, empty/failing runs and busy deferral. Registry cases cover
exact/changed/expired digests, seven-day admission, one retained renewal and deletion-reset
refusal; deleted non-Markdown docs pass static checks while zero-test code still fails.
Hardware-free
`scripts/test-ios-test-infrastructure.py HostSlotFixture RunnerFixture.test_run_forwards_bounded_host_slot_wait_before_simulator_work RunnerFixture.test_run_waits_for_a_host_slot_while_all_are_held`
proves bounded acquisition cleanup, forwarding, the unchanged cap and default waiting.
A fake Gateway runner covers `mutate` timeout/interrupt; logs: `test-results/verify-cli/`.
Batch fixtures cover all lanes, case-only merge proof, issue/probe reuse, local revert,
verdicts and interrupted cleanup preservation; logs: `test-results/verify-batch/`.
