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
scripts/tron verify --batch --base <main-anchor> # initialize coverage in a clean linked worktree (git worktree add --detach <path> origin/main)
scripts/tron verify --batch [--repeat] [--plan] # next pinned batch, or rerun every lane at the green HEAD
scripts/tron verify --batch --review <culprit> --decision ACCEPT|BLOCK --reviewer <id> --binding <digest>
scripts/tron verify --update-locks <id>         # rewrite <id>'s goldens (lock or approved migration slices)
scripts/tron verify ... --ios-jobs 3             # more simulator lanes (1|2|3; default 1), when the brief says the Mac is free
scripts/tron verify ... --skip ios,mac,relay    # accept, explicitly, selections this run will not run
scripts/tron verify ... --gateway-host local    # override the test-host pool: run the Gateway Vitest lanes here
```

## Worktree dependencies

Worktree creation does not install dependencies. Before running any test step or a
selection that uses the Gateway, prepare **that worktree**, including development
dependencies (tests in `scripts/` and `tools/` import the Gateway's packages too):

```bash
scripts/tron-node exec npm --prefix packages/gateway ci --include=dev
```

Verify never installs dependencies automatically or borrows another checkout's
`node_modules`. Before step 1 of a run with any test step it requires npm's record of
the install (`node_modules/.package-lock.json`) to match `package-lock.json`, apart
from absent platform-optional packages. For a Gateway selection it also requires the installed TypeScript version
to match `packages/gateway/package.json` and npm's local `.bin/tsc` to resolve to
that package's executable. A missing, stale or broken install fails early (exit 2)
with the preparation command; a global `tsc` on PATH cannot satisfy it. `tron-node`
resolves the pinned Node independently of interactive shell setup. `--plan` and
selections with no test step and no Gateway path need no Gateway install.

## Gateway test isolation

Both `scripts/tron test gateway` and verify's Gateway Vitest groups use
`tools/verify/gateway.py`. Without an explicit `--config`, file filters that select only files a
listing config names (`vitest.nested.config.ts`, `vitest.mac-terminal.config.ts`, read by
`vitest_configs.py`) run under that config; filters spanning configs are refused (exit 2) with
each config's command, and nothing runs. It resolves pinned development Node first, then gives
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
records itself there, so local Gateway runs never overlap each other or a `mutate` sampling, which holds it
throughout. Waiters take the lock first-come first-served: each holds the
flock of a numbered ticket in `/tmp/tron-full-gateway.lock.queue/` while it waits, so a dead
waiter's ticket is pruned, and only the earliest live ticket tries the lock. `host_lock.py` is
the lock's one owner; the runner and `mutate` import it.
Migration fixtures seed explicit historical JSON; they never copy the invoking
user's settings or profile. Test input and output must not depend on live stores.

## Gateway and Python lanes on the test-host pool

The Gateway Vitest lanes (`gateway`, `gateway-nested`) of `verify` and `scripts/tron test gateway`, and verify's Python group (not `python-here`), run on the pool {the Mac mini, this Mac}:
`mini.py`'s `choose_host` picks the mini when it is configured, the tree is committed and an ssh probe (5 s to
connect, 30 s in all) finds it set up with its job lock free, and otherwise this Mac. Each run prints which host
ran its lanes and why; verify records it (`gatewayHostReason`). `--gateway-host local|mini` (for both kinds of lane; `test gateway --local|--mini`) overrides the pool; `--update-locks` always runs here, and the pool runs a lane here when its arguments name a path outside the checkout (a relative one resolved against `packages/gateway`). The Gateway `node-gateway` lane (`node --test` files) runs on this Mac under the pool and under `--gateway-host local`, and on the mini only when `--gateway-host mini` names it explicitly; the pool never probes the mini for a node-only selection. Verify's node-gateway lane is not part of `scripts/tron test gateway`, which forwards Vitest arguments only.
On the mini, `mini.py` refuses a dirty tree, or a HEAD other than the commit verify records, and pushes HEAD to the mini's `~/tron-ci/tron.git` as the one shared `refs/tron-jobs/incoming`, which each push
overwrites, so a push whose job never starts leaves nothing that grows. One job at a time
(`~/tron-ci/jobs/gateway.lock`) checks out exactly that commit in `~/tron-ci/jobs/gateway`, cleaned except for the
Gateway `node_modules`, refuses a Node binary or npm off the commit's `config/ci-toolchain.env`, reruns `npm ci`
only when `package.json`, `package-lock.json`, `third_party/` or the Node binary changed, and runs that commit's
`gateway.py`, the Gateway's `node --test` files on the pinned Node (`mini.py node`), or the Python group's per-file command (stderr merged, the pinned Node first on PATH), each in its own process group killed before the lock is released, with a minimal PATH and only the mini user's HOME, USER, LOGNAME, SHELL and LANG. Output streams
live; the Vitest output files come back with paths rewritten to this checkout, and the lane's exit code is the step's. With `--mini`, an unconfigured or
unreachable mini, a failed push, an off-pin toolchain, a job lock still held when the caller's `TRON_MINI_JOB_WAIT_SECONDS` runs out, or a session without a result exits 75 with a last `mini: no result: <reason>` line, never falling back here (a lane that itself exits 75 stays a lane result); verify records that step as `no result` with its reason and the run as `incomplete`, not failed. Stopping verify, or killing
its whole process group, ends the session and SIGTERMs the mini job's child. Setup: `git config tron.verify.mini <user@host>` and
`tron.verify.miniIdentity <key file>`, and a bare `~/tron-ci/tron.git` on the mini; until the pinned Node and Dafny are
installed there, a job refuses with the `scripts/tron-node install` or (Python lanes) `scripts/tron proof bootstrap` command for its checkout. `verify --batch` runs every Gateway and Python run it starts on the mini, except the `mac-terminal` and `python-here` groups, which need this host ([batch](batch.md)); `mutate` runs its lanes here.

## Run output

Execution reads committed state: uncommitted or untracked changes are refused
(exit 2). `--plan` additionally includes staged, working and untracked paths; add new
files to Git before relying on their ownership. Each step prints `[i/N] name …`, its
live log, result and wall time. The cheap tier runs static/type checks, iOS source policy,
Python tooling tests, shell/Node tests and selected Gateway/Relay tests before any simulator build,
UI journey or Mac test stage. It collects every cheap-tier failure; the verdict lists them in
step order, first red first. A cheap-tier failure prevents all expensive stages from starting.
After that boundary, expensive stages stop on red; pending stages remain selected and are
reported as skipped, never passed. A failed `ios build` also skips `layers ios`.
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
3. documentation policy and `scripts/check-agent-policy.sh`; `scripts/tron docs check
   --base <base>` when Markdown, a manifest or the Gateway changed; `--all` and empty-diff
   baselines check every block without `--base` (loaded generators need Gateway dependencies).
4. the privacy guard over `git diff <base>..HEAD`, except the guard's own needle file, which its
   full and staged scans exempt too
5. `git diff --check`, then `tools/verify/comments.py`: a comment that starts on a line the change adds
   fails the run (charter: code carries no comments), except shebangs, the directives a tool reads and the
   tooling purpose line: one line at the file's head (after the shebang and directives), and not while the
   file still holds an earlier purpose comment (identical string/heredoc text is not a comment);
   whether that line states a purpose is review's call. It reads
   TypeScript/JavaScript (not JSX), Python, shell, Swift and CSS; Dafny (its `///` docs and `// @wire` feed `dafny2wire`), C/Objective-C and
   generated files are out of its scope
6. When the selection touches the Gateway: `npm run check` (production and test
   support typecheck), `npm run lint`, and `scripts/tron layers gateway`.
7. `scripts/tron layers ios` on this commit's Xcode index store (see the iOS lane
   below). A selection without the iOS lane runs it only when a fresh index
   exists; otherwise it is reported as skipped, never as passed.

### Context audit

`scripts/tron context audit` renders source-owned core, Home, worker-contract and direct
child-handoff layers plus this repository's rules and Home profile index. Diagnostics name
layer/source owners without printing their text. Sentence comparison joins prose hard wraps,
including list-item continuations, but keeps paragraphs, separate list/index entries and
Markdown heading, tag, table and fence lines apart. Normalized sentences of at least 60
characters are near-duplicates at Jaccard ≥0.8; budgets and byte/4 token estimates are review signals, not
provider counts. Source checks count each check-in/approval literal, including repeats within one owner,
and locate the current kind-filtered Home declaration expression; they do not prove runtime wiring. `--input <json>` accepts `{layers, sources}` for isolated regression
proofs; errors exit 2, diagnostics exit 1.

The module exports the same `render` and `audit` functions used by the CLI so bounded
reports can compare an explicitly supplied global-rules draft against canonical rendered
layers without collecting live stores or duplicating the renderer.

Verify runs `context audit --report-only` for Gateway changes and audit-tool edits while
the context plan's producer slices are landing. This transitional invocation retains every
diagnostic but does not make today's duplicates a red gate. Direct audit remains strict.
Stage 2 resolves duplicated prose; Stage 3.3 supplies canonical index markup. Strict
verify wiring waits for both inputs. Home's composed system/profile comes from
`homeSystemPrompt`; changing model/thinking/activation state stays outside those layers.
The report compares rendered role totals with the review budgets in the plan's
`PRINCIPLES.md` section 9. These are partial source-rendered totals, not whole-request sizes:
global user files, installed skills, tool declarations and workflow child prompts remain
explicitly unavailable. Missing coverage is not a clean bill or a provider measurement.

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
that module's rendered tests. `--changed` also adds the importers no compiler checks: a changed
source file's Python importers (`import`/`from` by module name, or its path handed to
`importlib`) and JavaScript importers (relative specifiers) in other modules run their module's
owned tests, or only themselves when the importer is a test (one hop). Typed importers (TypeScript,
Swift) are left to their compilers. A module with no test declares its proving tests (`verify`, below), usually its
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
| `python` / `python-here` / `shell` | `python3` / `bash` per file; `python-here` (`PYTHON_HERE`: tests reading this Mac's Pi session store) runs on this Mac, never the pool |
| `ios` | `scripts/tron-ios-test run --only-testing <target>/<class>/<test>` shards: the UIValidation targets |
| `ios-journeys` | `scripts/ios-gateway-e2e-test run-ui --only-testing <journey>`: the real-UI journeys |
| `ios-boundary` | `scripts/ios-gateway-e2e-test check --only-testing <method>`: the Gateway E2E target, with its own build and private fixture |
| `relay` | the relay's Vitest: `npm test` in `packages/push-relay`, as `verify --batch`'s relay lane |
| `mac` / `mac-terminal` | `scripts/tron test mac <class>...` (`tools/verify/mac.py`, also the batch's Mac integration lane; Mac Swift sources declare it) / `vitest.mac-terminal.config.ts`, on this Mac |
| `ios-lanes:<owner>:<entry>` | module-owned Python validation command, after the joined phone/Pad matrix |
| `ios-scenarios:<owner>` | the profiler's functional scenarios for the declared ProfilingTests classes, after the joined phone/Pad matrix ([below](#owner-declared-profiling-scenarios)) |
| `ios-lanes` | undeclared legacy harnesses, not driven by verify (including ProfilingTests classes no owner declares) |

`ios-journeys` are the `RealGatewayPairAndChatUITests` files. A `--changed` diff confined to their
test methods selects those methods, in the class or its extensions. The shared compiler reader
([iOS lane](ios.md)) supplies base/current declaration ranges; every changed line must belong to a
changed test or its adjacent blank-line separator. Documentation and literal `ui_owned_journeys`
entry edits may accompany it; any other harness or non-journey code change selects the complete owned set.
Shared helpers/state, test-method references in sibling sources, removals, unreadable syntax/metadata
and empty attribution also select the complete owned set, protecting cross-file callers without a
guessed call graph. Deleted journey files retain that selection through their base ownership, even
when no surviving journey file changed. `--module` and full
selections stay complete. An empty ownership set or a discovered test absent from the harness's
`ui_owned_journeys` fails selection (exit 2). They run
through the harness, which takes its own host slots, on one lane by default or up to `--ios-jobs`
(`TRON_IOS_E2E_UI_LANES`); `verify --batch` explicitly requests 3 lanes for both shards and journeys. A journey passes only with a
`report.json` whose `report.sha256` matches, `journey_status` is 0, `evidence_complete` is true and
`source` is this commit, clean; the step's `journeyReports` records each report's path, sha256,
status and revision. `--skip ios` skips them.

`ios-boundary` selects every test method in each selected `E2ETests` class. Its methods must match
exactly the owning harness's literal normal, LAN and diagnostic catalogs; unreadable, missing or
unregistered methods fail selection. The harness builds and stamps its own GatewayE2E products,
renews a private Gateway per case, enables LAN only for the LAN cases, and stops its fixture on
success, failure or cancellation. It needs no live Gateway, production install or restart. A case
counts only with its successful completion record and its own XCTest summary proving exactly one
pass, zero failures and zero skips; verify records each summary's path and SHA-256. Missing, empty,
skipped, duplicate or failed cases fail the group. The unrelated UIValidation build is not needed
for an E2E-only selection. `--skip ios` remains explicit; acquisition-only exit 73 is incomplete.

When `ios-lanes` (undeclared ProfilingTests classes and the UIValidation
journeys that need another harness's fixture: `scripts/ios-mac-terminal-journey`) are selected,
the run is `incomplete` (exit 1) unless `--skip ios` names them. `--skip mac` covers `mac-terminal`. A `relay` run needs the relay's installed
lockfile, else verify refuses before step 1 with its `npm ci` command. An empty run fails: it is not evidence.

## Owner-declared iOS validation

An explicit module manifest may bind complete UIValidation classes to its Python artifact validator:

```json
"iosLanes": [
  {
    "classes": ["TronMobileUITests/ExampleDiagnosticUITests"],
    "command": ["<owned-script.py>", "<validation-mode>"]
  }
]
```

The command's first argument must be a tracked `.py` script owned by the declaring module; arguments
are passed literally, never through a shell. Classes must resolve to tracked UIValidation sources,
with only one owner command per class. Invalid, missing or unowned replacements fail selection
(exit 2), before any class is removed from ordinary shards. A class without a declaration is not
excluded by this mechanism. Existing undeclared legacy harnesses retain their incomplete result.

Selected classes use one owner job per declaration, not ordinary shards. Selecting the declaring
module also selects its classes, including test-only validator edits; `--all` includes every owner
job, so the batch's full-verify lane uses the same route. Lock-only recording stays lock-only.
Jobs execute serially after the ordinary phone/Pad matrix joins, and after any real-UI journey group.
The validator owns its fresh leased runs and artifact assertions; verification adds no callbacks or
runtime evidence format. It must exit 0 and emit actual successful unittest suites with no skips or
expected failures. Empty/plain-success commands, incomplete artifact coverage and command failures
cannot borrow another group's passing count. Acquisition-only exit 73 is incomplete, never coverage;
a missing current iOS build also leaves owner validation incomplete. `--skip ios` remains explicit.

### Owner-declared profiling scenarios

A module that owns the profiler lists its ProfilingTests classes in `iosScenarios` (class names only). The list
must match exactly the classes `scripts/tron-profile-ios` runs, and the declaring module must own that profiler
and its receipt owner (`scripts/tron_profile_report.py`); otherwise selection fails (exit 2). Selected classes'
XCTest methods must match their table entries exactly: a method without a scenario, a scenario without a method,
or an unreadable class fails selection (exit 2) naming it. Unrelated selections do not invoke the Swift reader.
As with ordinary UI discovery, the reader inspects the working tree; executable verification refuses dirty trees,
while `--plan` may inspect uncommitted edits. A selected class
runs its table scenarios once (`--iterations 1`, after the phone/Pad matrix joins), in a results root this verify
run owns. A scenario passes only with exactly one receipt from this invocation: its XCTest passed as the one
executed test on this commit from a clean tree, with this iteration count, a workload measurement key (a
`scenario.` measurement that is not `scenario.render.`), and, for product scenarios, a render counter
(`scenario.render.`; the self-test controls have no render check). Workload key presence is not an independent
completion oracle: the real harness's passing XCTest enforces workload completion and render checks.
Measured values, numeric budgets and deltas are never judged. Scenario profiling waits for a host slot,
printing the holders, without changing XCTest deadlines. A missing, stale, wrong, duplicate or failed
receipt fails the run; a busy lane (exit 73) is incomplete. A failed current iOS build prevents the
invocation. An undeclared ProfilingTests class is `ios-lanes` and stays incomplete.

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
other command forms fail selection (exit 2). Harnessed classes keep their
`ios-journeys` or `ios-lanes` classification. There is no implicit install or alternate runner.

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
the holder is printed to stderr while it waits. Unmutated locks must pass first (unbounded); a mutant's
deadline is twice their time plus `--timeout` (default 300 s), so host load slows all runs alike. A failing
test/suite in the Vitest report or a run past its deadline is a kill that stops the whole owned group.
Missing reports are harness errors, excluded from the rate, and exit 1. Source is
restored after each mutant, interrupt or SIGTERM. Every lock run ends with its group SIGKILLed and reaped: a further
interrupt during the SIGTERM grace cannot skip that, SIGINT/SIGTERM are held while it spawns and while it is
killed, and the child starts with them unblocked. Incremental `test-results/mutate/`
reports retain partial results (`complete: false` until finished). Stryker remains
deferred until a known-kill probe proves activation with pinned Vitest.

## Verify

`scripts/tron test tooling tools/verify/tests/test-verify.py tools/verify/tests/test-verify-tiers.py tools/verify/tests/test-verify-batch.py`
drives real Git/CLI fixtures: affected selection, known-bad small changes, zero-test
refusal, reproducible digests, dirty planning, unnamed ignored residue failing the run, descendant cleanup, batch ranges/overlap,
bisection, causal revert publication and refused issue authority. The iOS stand-in compiles real Swift indexes
and stamps, exercises real `layers ios`, and emits XCTest-style summaries: locks-only
selection, reuse, extensions, empty/failing runs, default serial lanes and failed acquisition. Every Gateway case
failure is a raw red; deleted non-Markdown docs pass static checks while zero-test code still fails.
Hardware-free
`scripts/test-ios-test-infrastructure.py HostSlotFixture RunnerFixture.test_run_forwards_bounded_host_slot_wait_before_simulator_work RunnerFixture.test_run_waits_for_a_host_slot_while_all_are_held`
proves bounded acquisition cleanup, forwarding, the unchanged cap and default waiting.
A fake Gateway runner covers `mutate` timeout/interrupt and a second interrupt during the grace; logs: `test-results/verify-cli/`.
Batch fixtures are listed in [batch.md](batch.md#verify); logs: `test-results/verify-batch/`.
