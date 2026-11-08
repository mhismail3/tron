# Verify

`scripts/tron verify` runs the fast affected checks before merge; `verify --batch` runs full
coverage asynchronously on landed main and causally reverts a proven culprit. The manifests (owners, `verify`
declarations and `dynamicEdges`) are the selection authority. No merge queue, landing gate or hosted
CI is involved ([principles P2](../../docs/PRINCIPLES.md#p2-whole-system-health-is-a-batch-signal-not-a-commit-gate)). A previous test pass never substitutes for
this change's affected checks; only stamped build products are reused. See the
[oracle policy](test-oracles.md).

```bash
scripts/tron verify [--base <ref>]             # affected checks since merge-base(<ref>, HEAD)
scripts/tron verify --plan                     # tier, paths, reasons and exact commands; dirty trees allowed
scripts/tron verify --changed [--base <ref>]   # explicit diff selection, also used by mutation sampling
scripts/tron verify --module <id>               # scoped baseline: owner tests + declarations + launching UI locks
scripts/tron verify --all                       # all locks + serial files deferred by this base..HEAD diff
scripts/tron verify --batch --base <main-anchor> # initialize coverage in a dedicated clean main worktree
scripts/tron verify --batch [--repeat] [--plan] # next pinned batch, or rerun every lane at the green HEAD
scripts/tron verify --batch --review <culprit> --decision ACCEPT|BLOCK --reviewer <id> --binding <digest>
scripts/tron verify --update-locks <id>         # rewrite <id>'s goldens (lock or approved migration slices)
scripts/tron verify ... --skip ios,mac,relay    # accept, explicitly, selections this run will not run
scripts/tron verify ... --gateway-host mini     # run the Gateway Vitest lanes on the Mac mini, not this Mac
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
resource directory, under `/tmp` rather than the caller's TMPDIR, so fixture and socket path
lengths do not depend on who runs the suite. It waits for Vitest before removing those directories, also
forwarding cancellation to the owned child. Every tool that stops it (verify, batch, mutate) sends
SIGTERM first and SIGKILL only after a grace (mutate 10 s, the others 30 s), so a root is left behind
only by an outside SIGKILL or by a Vitest still tearing down when the grace ends.
It never installs this checkout's missing packages.
One test fixture is the exception: when the selection can include
`browser-fork-receipts.integration.test.ts` (the default config with no file filter, or one it
matches), the runner hands Vitest `TRON_P99_17_BROWSER_FORK_COPY`, a checkout of the
agent-browser fork commit pinned in `browser-live-view-adapter.ts`. It is fetched by SHA, built from
the fork's lockfile (`npm ci --ignore-scripts`, then its build), and kept once per clone in
`.git/verify/fixtures/`, so a batch's Gateway lane covers both cases instead of skipping them. The
test's native case runs the `agent-browser` first on `PATH`, so the runner puts there the engine the
fork itself declares (`TARGET_AGENT_BROWSER_VERSION` in the fork's own agent-browser target script):
this host's native binary from the registry's `agent-browser@<version>` package (`npm pack
--ignore-scripts`), kept once per version beside the fork after it reports that version. Bumping
the fork pin is the only engine update. An ambiguous pin or declaration, or failed provisioning,
fails the run. It first waits
its turn for the host's `/tmp/tron-full-gateway.lock` (printing the holder and earlier waiters) and
records itself there, so Gateway runs never overlap each other or a `verify --batch` Gateway lane,
which holds it only while that lane runs ([batch](batch.md)). Waiters, batch included, take the lock first-come first-served: each holds the
flock of a numbered ticket in `/tmp/tron-full-gateway.lock.queue/` while it waits, so a dead
waiter's ticket is pruned, and only the earliest live ticket tries the lock. `host_lock.py` is
the lock's one owner; the runner and the batch import it.
Migration fixtures seed explicit historical JSON; they never copy the invoking
user's settings or profile. Test input and output must not depend on live stores.

## Gateway lanes on the Mac mini

`--gateway-host mini` (or `scripts/tron test gateway --mini [vitest args]`) runs the Gateway Vitest lanes on the
Mac mini through `mini.py`; the default, and `--update-locks` always, runs them here. Making the mini the default
waits on an exact pass/fail match with this Mac at one commit (#2334). `mini.py` refuses a dirty tree, or a HEAD
other than the commit verify records, and pushes HEAD to the mini's `~/tron-ci/tron.git`. One job at a time
(`~/tron-ci/jobs/gateway.lock`) checks out exactly that commit in `~/tron-ci/jobs/gateway`, cleaned except for the
Gateway `node_modules`, refuses a Node binary or npm off the commit's `config/ci-toolchain.env`, reruns `npm ci`
only when `package.json`, `package-lock.json`, `third_party/` or the Node binary changed, and runs that commit's
`gateway.py` with a minimal PATH and only the mini user's HOME, USER, LOGNAME, SHELL and LANG. Output streams
live; the Vitest output files come back with paths rewritten to this checkout, and the lane's exit code is the step's. An unconfigured or unreachable mini,
an off-pin toolchain or a session without a result exits 2; nothing falls back to this Mac. Stopping verify ends
the session and SIGTERMs the mini job's child. Setup: `git config tron.verify.mini <user@host>` and
`tron.verify.miniIdentity <key file>`, and a bare `~/tron-ci/tron.git` on the mini; until the pinned Node is
installed there, the first job refuses with the `scripts/tron-node install` command to run in its checkout.
`verify --batch` and `mutate` run their Gateway lanes here.

## Run output

Execution reads committed state: uncommitted or untracked changes are refused
(exit 2). `--plan` additionally includes staged, working and untracked paths; add new
files to Git before relying on their ownership. Each step prints `[i/N] name …`, its
live log, result and wall time. The first failure stops the run and prints its tail.
`test-results/verify/<sha>.json` is atomically updated before/after every step;
`running` and `interrupted` are not passes. SIGINT/SIGTERM stops and joins the owned
step process group while retaining partial results. Full logs are in
`test-results/verify/<sha>/`. `--changed` prints and records a `delta`: source, test and doc lines
added and removed (tests include fixtures, support and goldens), added and deleted test files,
each new or renamed-in test file beside an existing test of the same stem, and each added source line naming
legacy, compat, shim or deprecated code. It never fails a run; the reviewer ACCEPTs against it
([oracle policy](test-oracles.md)). Repeating a selection at one SHA overwrites this local
report; batch evidence is copied separately before another run. The `resultDigest` covers the
selection, each step's outcome and test count, and the verdict, but not timing,
so two runs of one commit against one base can be compared (a reused iOS build compares equal to
the build that stamped it). The iOS shards count as one entry there (their status, passing count and
failed and deferred tests), because packing and lanes vary between runs. Python unittest counts exclude skipped and expected-failure
cases; a file with no executed passes cannot hide beside a passing neighbour.

## Static checks (existing tools only)
1. `scripts/tron ownership`, including the repository layout
2. `scripts/tron tidy --here --landing`: no untracked file or ignored path without a named writer
3. `scripts/tron budgets HEAD` (sizes are reported; few cases fail)
4. documentation policy and `scripts/check-agent-policy.sh`; `scripts/tron docs check
   --base <base>` when Markdown, a manifest or the Gateway changed; `--all` and empty-diff
   baselines check every block without `--base` (loaded generators need Gateway dependencies).
5. the privacy guard over `git diff <base>..HEAD`
6. `git diff --check`
7. When the selection touches the Gateway: `npm run check` (production and test
   support typecheck), `npm run lint`, and `scripts/tron layers gateway`.
8. `scripts/tron layers ios` on this commit's Xcode index store (see the iOS lane
   below). A selection without the iOS lane runs it only when a fresh index
   exists; otherwise it is reported as skipped, never as passed.

### No exemptions

There is no known-failure registry, quarantine, waiver, expiry or qualified verdict
([P2](../../docs/PRINCIPLES.md#p2-whole-system-health-is-a-batch-signal-not-a-commit-gate)). Every
executed failure is `failed` (exit 1); it is fixed at its root or causally reverted.

## Selection

Paths changed between the merge base and HEAD, both old and new names, map to
their owning manifests (`tools/ownership`; deleted paths are owned as of the
base). Each module contributes its owned tests:
- `*.test.ts` and `*.test.mjs`;
- `test-*.py` and `test-*.sh`;
- Swift `*Tests.swift` under test targets.

Recorders under `test-fixtures/` are never run. A change is gated by its own
modules' tests ([principles P1](../../docs/PRINCIPLES.md#p1-a-module-owns-its-code-and-its-tests)):
`--changed` and `--module` add no `dependsOn` consumer's tests; those run in the
batch. The one consumer added is a module whose `dynamicEdges` name a selected
module (today only the iOS UI tests' spawn edges to the hosted app): its locks are
that module's rendered tests. A module with no test declares its proving tests (`verify`, below), usually its
`gateway/e2e` journeys; directory modules may also declare `verify`. A Gateway E2E golden
selects only the lock in its directory whose `lockPaths(import.meta.url, …)` names it (a computed argument counts when the lock spells the name as a string); a golden no lock reads refuses.
`--module` does not widen to unrelated kernel locks; `--update-locks` stays with its owner.

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
| **partial** | Tests/goldens only, or ordinary owned code (including Swift UI) | Changed tests; golden owner's locks; otherwise owner tests, owner declarations and launching UI locks |
| **full** | Production changes in L0–L2, `gateway/package`, `gateway/test-support`, `gateway/pi-sdk`; declared kernel/contracts/persistence/security/lifecycle/mac-installer risk; manifest/layer-baseline/toolchain/project configuration; unknown ownership | The same affected checks **now**, plus all-lock/full-lane coverage in the next batch |

Test/golden-only narrowing precedes module risk; a manifest/configuration edit still
requires a full batch. Unchanged files in the existing serial `gateway-nested` list
are deferred, never dropped, unless explicitly declared as owner verification evidence;
declared tests run immediately. Production changes selecting undeclared serial tests need
a full tier.
A changed serial test file and locks selected by a golden edit run immediately.
`--all --base <green>` includes every serial file selected by that covered diff,
including changed tests already run before landing: later integration may affect
them too. It is not limited to the one nested lock. Explicit `--module` baselines still run
the complete scoped set. A serial-only selection may pass its affected static checks
while explicitly reporting deferred tests; it is not a test pass or a green batch. `ios-ui` risk alone does not widen beyond the affected UI build
and journeys. Renames include both paths; deleted paths use base ownership. Retired
owners retain risk, but cannot declare commands. Risk is read
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
| `ios` | `scripts/tron-ios-test run --only-testing <target>/<class>/<test>` shards: the UIValidation targets |
| `ios-lanes` / `mac` / `relay` | not driven by verify |

When `ios-lanes` (the Gateway E2E and profiling targets, and the UIValidation
journeys that need their harness's fixture: `scripts/ios-gateway-e2e-test`,
`scripts/ios-mac-terminal-journey`), `mac` or `relay` tests
are selected, the run is `incomplete` (exit 1) unless `--skip` names them
(`--skip ios` covers `ios-lanes`); they need their own lanes or the relay's own
dependencies. A selection that runs zero passing tests fails: an empty run is not
evidence.

## Manifest `verify` declarations

Modules may declare extra verification using explicit tracked inputs:

```json
"verify": [
  "scripts/tron test tooling tools/verify/tests/test-verify.py scripts/verify-gateway-protocol-contract.py",
  "scripts/tron test gateway src/transport/command-receipts.lock.integration.test.ts",
  "scripts/tron test ios run --only-testing TronMobileUITests/SnapshotCachePersistenceContractTests"
]
```

These strings select files for the existing runners; verify never executes them
as shell commands. Tooling accepts only `scripts/test-*.py`, `scripts/verify-*.py` and `tools/<tool>/tests/test-*.py`;
Gateway accepts `src/**/*.test.ts` and Gateway-relative `*.test.mjs`. iOS accepts one or
more `--only-testing Target/Class` pairs, resolved to tracked UIValidation test
files; method selectors, broad runs, build flags, unknown classes/paths and
other command forms fail selection (exit 2). Harnessed classes retain their
`ios-lanes` classification. There is no implicit install or alternate runner.

Changed/module selection includes the declarations of the selected modules (and of a
launching module); full batch coverage and `--all` include every declaration.
Markdown/test-only narrowing and lock-only `--update-locks` remain unchanged.
Files are deduplicated across ownership and declarations, then use normal
counts, explicit skips and incomplete verdicts. A zero-test Python suite fails
even beside another passing suite. `--plan` shows selection, not test evidence.

## iOS lane

`--all`, `ios` tests, or a changed `ios-app/` module runs the iOS lane unless `--skip ios`:
source policy, a stamped build, `layers ios`, then the selected UI test methods packed into runner
processes on concurrent lanes. Its contract is in [ios.md](ios.md).

## Asynchronous full-main batches

`verify --batch` runs every required lane on landed main after merge and causally
reverts a proven culprit once enabled; its contract, enable step and review command
are in [batch.md](batch.md).

## Mutation sampling

`scripts/tron mutate <packages/gateway/src file> [--count 30] [--seed 1465] [--timeout 300]`
measures lock sensitivity, never per-slice eligibility. It samples seeded single-operator
flips (`===`/`!==`, `&&`/`||`, booleans, comparisons, `±1`) and runs the locks selected
for that source once per mutant, not the module's ordinary journeys. Each run goes through the Gateway
test runner (`gateway.py`: temporary HOME and scratch), and `mutate` holds the host's full-Gateway lock
for the whole sampling. Waiting for that lock is not bounded and does not count toward `--timeout`;
the holder is printed to stderr while it waits. Unmutated locks
must pass first. A failing test/suite in the Vitest report or a timed-out process is a
kill; timeout stops the whole owned group (default 300 s, including infinite loops).
Missing reports are harness errors, excluded from the rate, and exit 1. Source is
restored after each mutant, interrupt or SIGTERM. Incremental `test-results/mutate/`
reports retain partial results (`complete: false` until finished). Stryker remains
deferred until a known-kill probe proves activation with pinned Vitest.

## Verify

`scripts/tron test tooling tools/verify/tests/test-verify.py tools/verify/tests/test-verify-tiers.py tools/verify/tests/test-verify-batch.py`
drives real Git/CLI fixtures: affected selection, known-bad small changes, zero-test
refusal, reproducible digests, dirty planning, unnamed ignored residue failing the run, descendant cleanup, batch ranges/overlap,
bisection, causal revert publication and refused issue authority. The iOS stand-in compiles real Swift indexes
and stamps, exercises real `layers ios`, and emits XCTest-style summaries: locks-only
selection, reuse, extensions, empty/failing runs and busy deferral. Every Gateway case
failure is a raw red; deleted non-Markdown docs pass static checks while zero-test code still fails.
Hardware-free
`scripts/test-ios-test-infrastructure.py HostSlotFixture RunnerFixture.test_run_forwards_bounded_host_slot_wait_before_simulator_work RunnerFixture.test_run_waits_for_a_host_slot_while_all_are_held`
proves bounded acquisition cleanup, forwarding, the unchanged cap and default waiting.
A fake Gateway runner covers `mutate` timeout/interrupt; logs: `test-results/verify-cli/`.
Batch fixtures are listed in [batch.md](batch.md#verify); logs: `test-results/verify-batch/`.
