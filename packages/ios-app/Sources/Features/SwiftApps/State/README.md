# Installed Swift-app state

## Purpose
Own the phone's installed-app projections and accepted write lifecycle. The Gateway's
`modules/apps` store remains canonical. The interpreter stays synchronous and has no
transport, credentials or ambient installed identity.

## Owns
- `InstalledSwiftAppWire`: coherent launch, source/state revision fences and bounded DTO admission.
- `InstalledSwiftApps`: latest-request-fenced opens and at most 200 retained app sessions.
- `InstalledSwiftAppSession`: optimistic JSON projection, bounded unsent key coalescing,
  immutable dispatched command and failed/uncertain changes retained past sheet dismissal.

## Contract
`AppModel` only composes the read/commit ports. Reads pin the selected Gateway and connection
epoch and require that admission after their await. Writes use the existing
`ConfirmedMutationExecutor`; each immutable command carries its source revision, state
revision and stable command ID. The composition may not route a queued request into a new
Gateway connection authority.

The runner injects `SwiftAppPersistence` only for an installed session. Its committed JSON
batches enter `accept`; one unstructured session-owned task drains them. Closing the sheet
stops interpreter timers, not accepted writes. Reopening a clean app loads `apps.open` again;
reopening an unsaved app retains its projection and failure instead of discarding data.

## Invariants
- At most 1,000 keys/512 KiB of projected JSON, 256 keys per dispatched batch, 200 retained
  sessions/opens. A dispatched command is never mutated by newer actions.
- A save failure retains the exact pending command and newer dirty values, surfaces through
  the existing app notice/error owners and never automatically reloads or resubmits.
- No source/storage schema migration, local database or second installed-app catalog.
- Clean reads may be discarded; accepted/uncertain writes may not be evicted.

## Entry points
`InstalledSwiftApps.open(appID:profileID:)`, `InstalledSwiftAppSession.accept`, `settle`.
`SwiftAppRunnerSheet` hosts the projection. The Apps menu/catalog is a separate consumer.

## Signals
The existing app error notice and runner error overlay report unsaved writes; the retained
`pending.commandId` identifies the command for receipt diagnosis. No content logging.

## Verify
```bash
scripts/tron test gateway src/modules/apps/swift-app-store.integration.test.ts
scripts/ios-gateway-e2e-test run-ui --only-testing TronMobileUITests/TronInstalledSwiftAppUITests/testInstalledValuesSurviveRunnerCloseAndReopen
```
The latter installs through a real Pi tool and proves fresh runtime state versus stored
state through the real Gateway, not a fixture key/value store.

## Not here
Interpreter evaluation, sheet visuals, app installation, feeds, HTML execution, catalog UI,
history/provenance and app-store migrations.
