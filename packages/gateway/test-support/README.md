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
and crash fixtures.

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
- **Network isolation.** Tests own every remote boundary through injected fetchers,
  resolvers and HTTP stubs. `network-isolation.ts` refuses any non-loopback TCP
  connection from an in-process socket and fails the current test (or file). It does
  not cover child processes or DNS.
- **Two Vitest passes.** `vitest.config.ts` runs the parallel suite with at most four
  workers (shared-host bound, not test selection). `vitest.nested.config.ts` runs, one
  file at a time with its own hang bounds, the files that spawn nested Vitest or real
  pi children or activate the real managed provider; its list is the only owner of
  which files are nested.
- **Fixture processes.** `fixture-process-owner.mjs` records spawned handles and
  groups, stops and joins them (TERM then one KILL) before roots are removed, and
  writes join failures to `TRON_TEST_PROCESS_OWNER_FAILURE`.
- MCP fixtures join the direct-tool registration boundary before scripting a call
  (runtime creation does not mean HTTP discovery finished). Git cleanup proof is
  `ENOENT` plus the branch decision, never an arbitrary filesystem error.

## Invariants

- No test reaches the network or a real Tron home.
- A test owns and removes its processes, temp homes and fixtures on success and
  failure.

## Entry points

`waitFor`, `awaitsWithin`, `initializeRegistry` and `createColdRegistryFixture`
(`runtime-registry-fixture.ts`), `createTestRegistry` (`gateway-registry.ts`: the production module
composition a test registry takes), `scenario-lock.ts` ([scenario locks](../docs/scenario-locks.md)).

## Signals

None; failures surface as labelled test errors.

## Verify

```bash
scripts/tron verify --module gateway/test-support
cd packages/gateway && npx vitest run --config vitest.nested.config.ts <file>
```

## Not here

Test policy (no unit tests, real boundaries): the charter, `AGENTS.md`. Runner
commands: [Gateway README](../README.md#development).
