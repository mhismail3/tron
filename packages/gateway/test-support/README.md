# gateway/test-support

## Purpose

The Gateway test harness shared by integration and E2E suites: hang-bounded waits,
network isolation, fixture process ownership, lock harnesses and real-runtime
fixtures. Its manifest is `../test-support.module.json` (it also owns fixtures under
`test-fixtures/` and two `scripts/` tests).

## Owns

`wait-for.ts`, `network-isolation.ts`, `fixture-process-owner.mjs`,
`runtime-registry-fixture.ts`, `gateway-lock-harness.ts`, `gateway-registry.ts`, `scenario-lock.ts`,
`tron-store-*.ts`, the Tron-home environment guard and preflight, and the Home task
and crash fixtures. `settings-action-crash-child.ts` runs the real approval engine
against a file-backed action, exposing the effect/before-settlement cut so its parent
can kill and reopen it to prove interrupted actions are not replayed. Its lifecycle
mode holds a real pending-read return to prove concurrent start and disposal join
one accepted recovery through the existing work owner.

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
  which files are nested.
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
commands: [Gateway README](../README.md#development).
