# gateway/e2e

## Purpose

The Gateway's system journeys: test files that boot the Gateway, either the in-process
`RuntimeRegistry` with the Pi SDK, owners and stores through a `test-support` harness
(`gateway-registry.ts`, `home-task-fixture.ts`, `runtime-registry-fixture.ts`,
`gateway-lock-harness.ts`), or a real Gateway process (`gateway-process.ts`). They prove
behaviour across modules, so they belong to no single module.

## Contract

- **Layout.** A journey keeps the path of the module it mainly exercises:
  `src/e2e/<path under src>/`. A red journey is filed against that module.
- **When it runs.** The gate runs the fixed set in `tools/verify/gate.py`; every other journey is
  on-demand proof (`scripts/tron test gateway <file>`); `mac-terminal.e2e.test.ts` needs a
  tailnet host (`npm run test:mac-terminal`); a module with no test of its own declares the tests that
  prove it that way. A module's own tests stay in the module. Scenario locks live here at
  `src/e2e/<path>`; store locks (`*.store.lock.integration.test.ts`) stay with their store's
  owner.
- **Running one.** `scripts/tron test gateway src/e2e/<path>.test.ts`.
