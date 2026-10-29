# Swift-app state

## Purpose
Own disposable app projections and accepted writes. Gateway `modules/apps` is
canonical; the interpreter stays synchronous without transport or credentials.

## Owns
- `InstalledSwiftAppWire`: explicit bounded launch/state and commit wire values.
- `InstalledSwiftApps`: latest-request-fenced catalog/opens, retained sessions,
  confirmed data management and explicit discard of unsaved work.
- `InstalledSwiftAppSession`: optimistic JSON, coalesced unsent keys and immutable
  dispatched commands; failed/uncertain work remains owned after its view closes.
- `Sources/State/InstalledSwiftAppsGateway`: pinned-connection read ports and
  confirmed-mutation receipts. AppModel only calls this composition.

## Contract
Reads pin the selected Gateway and connection epoch through every await. Writes
use `ConfirmedMutationExecutor` and stable command IDs. A queued request cannot
be routed into another Gateway authority. No review/installation coordinator or
pending-offer list exists; the Gateway folder contract is the paired-client target.

Feed wire payloads remain bounded JSON in this L2 owner; it imports no interpreter
types. The L3 runner decodes/admit feeds before executing or publishing a runtime.
Link ceilings come from that same snapshot, not a separate feed projection.

Committed JSON enters one session-owned drain task. Closing stops timers, not
writes. Clean opens read again; dirty/failed sessions stay owned. Presented
versions remain retained so a fresh reader cannot orphan an existing writer.
Refresh admits the new runtime before publishing its session. Only clean,
unpresented sessions may be evicted.

## Invariants
- At most 1,000 keys/512 KiB JSON, 256 keys per batch and 200 retained sessions/
  opens. Never mutate a dispatched command.
- Failure retains the pending command and newer dirty values. Never automatically
  reload/resubmit or silently discard unsaved work.
- Data management rechecks unresolved local writes after asynchronous operations.
- No local database, second canonical catalog or implicit format migration.

## Entry points
`open`, session `accept`/`settle`, confirmed data management and explicit discard.
`SwiftAppRunnerSheet` hosts retained sessions.

## Signals
App notices and runner error overlays identify unsaved/unconfirmed operations.
`pending.commandId` identifies the receipt. No source or app-data logging.

## Verify
```sh
scripts/tron test gateway src/modules/apps/apps-folder-runtime.integration.test.ts
```
This checks real Gateway/native interpreter/SQLite/receipt durability, not iPhone
UI acceptance. Folder catalog and permission journeys validate the paired client.

## Not here
Interpreter evaluation, sheet styling, HTML execution, publisher ownership,
provenance browsing or SQLite migration.
