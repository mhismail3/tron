# gateway/test-support

## Purpose

The Gateway test harness shared by integration and E2E suites: hang-bounded waits,
network isolation, fixture process ownership, lock harnesses and real-runtime
fixtures. Its manifest is `../test-support.module.json` (it also owns fixtures under
`test-fixtures/` and two `scripts/` tests).

## Owns

`wait-for.ts`, `network-isolation.ts`, `fixture-process-owner.mjs`,
`runtime-registry-fixture.ts`, `gateway-lock-harness.ts`, `gateway-process.ts`, `gateway-registry.ts`, `scenario-lock.ts`,
`tron-store-*.ts`, the Tron-home environment guard and preflight, and the Home task
and crash fixtures. `settings-action-crash-child.ts` runs the real approval engine
against a file-backed action, exposing the effect/before-settlement cut so its parent
can kill and reopen it to prove interrupted actions are not replayed. Its lifecycle
mode holds a real pending-read return to prove concurrent start and disposal join
one accepted recovery through the existing work owner.

`gateway-process.ts` runs one real source Gateway process (`src/index.ts`) on an
isolated root with a scripted OpenAI-compatible HTTP provider as its only scripted
party. Clients cross the production loopback WebSocket with the root's local
credential; `restart()` is the iOS fixture's restart (SIGTERM, join, respawn on the
same root and port). Its files run in the nested pass. Disposal runs in a hook:
a SIGTERM join within `HOOK_HANG_BOUND_MS`, then a 3 s SIGKILL join; a failed start
or disposal reports every failure and keeps the root while the process may still write.
`gateway-lock-harness.ts` builds an in-process Gateway over one root. Its disposal
joins work the Gateway already admitted before it removes the root, so a request
whose caller stopped waiting cannot still be writing there.
`attention-recovery-hold-preload.mjs`, inert unless its variable is set for one
launch, holds startup attention recovery's last marker read so a client reaches
the Gateway inside the post-listen recovery window.

`native-exec-stall-capture.ts` runs a native engine fixture binary through
`execFileSync` with stdin input, unchanged, while a separate process group watches it:
past 5 s it writes host load, the parent and child, the child's stdio endpoints and a
stack sample of each to `test-results/native-exec-stalls/` and names the record on
stderr (#2226).

`catalog-metadata-crash-child.ts` saves two synthetic catalog cuts from
`catalog-metadata-fixture.ts` alternately until its parent kills it, so a
SIGKILL lands at an arbitrary point of a sharded catalog save.

`apps-crash-child.ts` and its preload hold Apps receipt/publication cuts in a real
Registry process. The fixture releases its workspace lease before the parent kills
it; this proves Apps recovery at those cuts, not whole-Gateway ungraceful crash,
stale-lock or power-loss recovery.

## Contract

- **Waits are hang bounds, not speed budgets.** Every awaited condition must be
  correct at any speed. `waitFor(condition, label)` polls on real timers;
  `awaitsWithin(promise, label)` bounds an exposed event or promise. Both fail with
  their label at `WAIT_HANG_BOUND_MS` (below the 15 s `testTimeout`, so the failure
  names the condition) and never move a fake clock a test installed. Hooks pass
  `HOOK_HANG_BOUND_MS` (Vitest's 10 s `hookTimeout` would truncate the label). A call
  site with its own measurement budget passes `boundMs` and says why. Do not use
  `vi.waitFor`.
- Prefer awaiting the event or promise the owner exposes. Keep an explicit time or
  count bound only where it is the contract (throughput, pass count, storm length).
- Gate a Stop, abort or steer on the run's own entry (the faux response function
  signals when called), not on `slot.isBusy` or a phase: those turn true at slot
  admission, before the SDK admits the run. Keep streamed faux replies short; the faux
  provider paces each chunk with a timer.
- **Slow-link locks.** `LockClient.holdWrites()` holds the real server socket's
  next write while its production outbound queue coalesces. Release in `finally`
  after the named state transition; closing the client also releases it. No kernel
  projection or queue is replaced.
- **Network isolation.** Tests own every remote boundary through injected fetchers,
  resolvers and HTTP stubs. `network-isolation.ts` refuses any non-loopback TCP
  connection from an in-process socket and fails the current test (or file). It does
  not cover child processes or DNS.
- **Worker routing.** Scripted providers identify finite Home workers in system messages
  through pi-ai `getSystemMessageText`, including structured sections. User-role
  content is task input, not the worker discriminator. Canonical JSONL context guards
  inspect message roles: structured system context is retained, never injected into users.
- **Authority journeys.** The lock harness's `knowledge` option constructs the real
  Knowledge store/service and supplies Home the same settings/profile approval owner as
  transport. Model tool dispatch never receives the paired client's decision RPCs.
- **Wire inputs.** The protocol lock selects unbranded runtime provenance before
  constructing its real Gateway. A separate supervised case checks the three
  explicit identity values and full hello/`system.info` shapes against that base
  wire plus provenance. Captured frames are never stripped or normalized to hide
  inherited supervisor fields, and environment restoration follows Gateway disposal.
- **Two Vitest passes.** `vitest.config.ts` runs the parallel suite with at most four
  workers (shared-host bound, not test selection). `vitest.nested.config.ts` runs, one
  file at a time with its own hang bounds, the files that spawn nested Vitest or real
  pi children or activate the real managed provider; its list is the only owner of
  which files are nested. The invalid-entry fixture registers only its parent cases
  or its staged child oracle, according to the existing fixture selector. Each parent
  also verifies the child's JSON result has exactly one pass and no failures/skips;
  a successful empty child process is not evidence.
- **Fixture processes.** `fixture-process-owner.mjs` records spawned handles and
  groups, stops and joins them (TERM then one KILL) before roots are removed, and
  writes join failures to `TRON_TEST_PROCESS_OWNER_FAILURE`. A KILL permission
  denial retains its error while the existing bounded join observes terminal
  state, without resending or extending the deadline. Only a fully joined tree
  succeeds; a still-live target fails with the original denial and live PIDs.
- Home task fixtures await an offline model refresh after provider registration,
  before returning either the Gateway-wide or a session runtime. Early refusal tests
  can otherwise delete their root while registration still holds its catalog lock.
- The task fixture Root constructs one actual settings model/change owner per Registry,
  supplies it directly to Home and native installation, and starts expiry explicitly.
  `f.settings` reads the current Root-created actual owners, not Registry readback;
  cold restart constructs and exposes the successor. Registry disposal joins expiry before stores.
- `settings-outcome-crash-child.ts` owns the SDK session only after the parent Registry
  is disposed. Its before/after canonical-append cuts use process loss, not graceful
  disposal, to test native outcome recovery; the parent stops and joins that child.
- The pinned browser-fork receipt fixture recognizes `--version` after wrapper-owned
  global safety flags. Its isolated copy must pass the real fork's version validation
  and direct/nested/reload/abort receipt assertions; the fork copy is never the user
  installation. `tools/verify/gateway.py` provisions that copy and sets its variable
  (tools/verify/README.md). The native CLI case runs the `agent-browser` engine found on `PATH`.
- MCP fixtures join the direct-tool registration boundary before scripting a call
  (runtime creation does not mean HTTP discovery finished). Git cleanup proof is
  `ENOENT` plus the branch decision, never an arbitrary filesystem error.

## Invariants

- `profile-v1-fixture.ts` arranges historical profile notes through the real privileged
  partition-restore owner. It grants no legacy-create exemption to ordinary note APIs.
  Migration fixtures select active legacy members; completed seed-operation backups
  are removed before the operation under test, retaining canonical heads and bodies.
  A migration fixture retaining two text editions has three revisions: admitted v2
  creation, v2 text edit, then exact historical placement restore.
- The bounded profile child takes an explicit migration/reorganization mode. The
  v2 deep-history case exercises reorganization with a real 96 MiB process ceiling.
- The 5,800-session migration/startup corpus is synthetic and owns a short `/tmp`
  root through its normal per-case cleanup. Canonical paths and cwd strings count
  against the catalog acquisition byte budget; an inherited nested TMPDIR must not
  turn that in-budget startup case into an over-budget catalog refusal. The budget
  and the real over-budget acquisition refusal tests remain unchanged.
- The Home activation/wake lock supplies the existing lock harness a short `/tmp`
  root, owned by its Gateway disposer. The real workspace path is part of episodic
  node text, so unbounded caller TMPDIR length must not cross the positive fixture's
  512-byte free-parent boundary. The node limit, captured frames and golden stay fixed.
- No test reaches the network or a real Tron home.
- A test owns and removes its processes, temp homes and fixtures on success and
  failure.

## Entry points

`waitFor`, `awaitsWithin`, `initializeRegistry` and `createColdRegistryFixture`
(`runtime-registry-fixture.ts`), `createTestRegistry` (`gateway-registry.ts`: the production module
composition a test registry takes, with deferred registry-owned module ports), `scenario-lock.ts` ([scenario locks](../docs/scenario-locks.md)).

## Signals

| Signal | One-step diagnosis |
| --- | --- |
| Fixture process join failure | Read the JSONL file named by `TRON_TEST_PROCESS_OWNER_FAILURE`: `pids` identifies remaining live targets, `attemptedSignals` lists the requested signal passes, and `error` preserves the cause. Keep the failed fixture root while any target could write. |

## Verify

```bash
scripts/tron verify --module gateway/test-support
cd packages/gateway && npx vitest run --config vitest.nested.config.ts <file>
```

## Not here

Test policy (no unit tests, real boundaries): the charter, `AGENTS.md`. Runner
commands: [Gateway agent guide](../AGENTS.md#test-lanes).
