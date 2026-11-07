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
- **When it runs.** `verify --batch` runs every journey in its Gateway lanes (the default
  pass, and the serial `vitest.nested.config.ts` pass); `mac-terminal.e2e.test.ts` needs a
  tailnet host and runs only through `npm run test:mac-terminal`. `verify --changed` runs a
  journey when the journey itself changes, or when a changed module's manifest declares it
  as that module's verification; a module with no test of its own declares the tests that
  prove it that way. A module's own tests stay in the module; scenario locks
  (`*.lock.integration.test.ts`) and their goldens stay with their owner.
- **Running one.** `scripts/tron test gateway src/e2e/<path>.test.ts`.
