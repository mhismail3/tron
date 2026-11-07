# gateway/e2e

## Purpose

The Gateway's system journeys: test files that boot the real `RuntimeRegistry`
(`test-support/gateway-registry.ts`) with the Pi SDK, owners and stores in one Vitest
process. They prove behaviour across modules, so they belong to no single module.

## Contract

- **Layout.** A journey keeps the path of the module it mainly exercises:
  `src/e2e/<path under src>/`. A red journey is filed against that module.
- **When it runs.** `verify --batch` runs every journey in its Gateway lanes (the default
  pass, and the serial `vitest.nested.config.ts` pass); `mac-terminal.e2e.test.ts` needs a
  tailnet host and runs only through `npm run test:mac-terminal`. `verify --changed` runs a
  journey when the journey itself changes, or when the manifest of a selected module
  (changed, or reached as a dependent) declares it as that module's verification. Modules
  that own no test of their own (`gateway/pi`, `gateway/resources`, `gateway/projects`,
  `gateway/run-model`) declare their journeys that way. A module's own tests stay in the module; scenario locks
  (`*.lock.integration.test.ts`) and their goldens stay with their owner.
- **Running one.** `scripts/tron test gateway src/e2e/<path>.test.ts`.
