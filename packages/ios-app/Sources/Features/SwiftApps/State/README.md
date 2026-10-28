# Installed Swift-app state

## Purpose
Own installed-app projections and accepted writes. Gateway `modules/apps` remains
canonical; the interpreter stays synchronous without transport or credentials.

## Owns
- `InstalledSwiftAppWire`: bounded explicit v1/v2 launch admission, exact source,
  declared feed and source/state/instance revision fences.
- `SwiftAppInstallWire`: source/configuration review and immutable install command.
- `InstalledSwiftApps`: latest-request-fenced catalog/opens, retained sessions and
  installation coordinators, confirmed Manage operations and explicit discard.
- `SwiftAppInstallation`: one accepted install command/result across dismissal.
- `InstalledSwiftAppSession`: optimistic JSON, coalesced unsent keys and an immutable
  dispatched command; failed/uncertain work remains owned after its view closes.
- `Sources/State/InstalledSwiftAppsGateway` composes existing pinned-connection
  read ports and confirmed-mutation receipts; AppModel only calls that composition.

## Contract
Reads pin the selected Gateway and connection epoch through every await.
Writes use `ConfirmedMutationExecutor` and stable command IDs. A queued request
must not be routed into another Gateway authority.

A review binds the exact producer session/artifact, source SHA and configuration
to the reviewed existing head. Accepted installation belongs to the Apps owner,
not its sheet Task. A repeated presentation reuses unresolved work; a settled
success cannot present Open after an authoritative review observes removal.
Confirmed removal invalidates completed installation projections.

The runner injects persistence/feed ports only for an installed session.
Its committed JSON enters one session-owned drain task. Closing stops timers,
not writes. Clean opens read the Gateway again; dirty/failed sessions stay owned.
Presented program versions are retained independently so a fresh reader cannot
orphan a still-presented writer. Refresh admits the new runtime before publishing
its session and refuses a dirty/no-op replacement. Only disposable clean,
unpresented sessions may be evicted.

## Invariants
- At most 1,000 keys/512 KiB JSON, 256 keys per dispatched batch, 200 retained
  sessions/opens and 200 installation identities. Never mutate a dispatched command.
- Failure retains pending command/new dirty values, uses existing notices/overlays
  and never automatically reloads or resubmits. Installation failures are terminal
  for that review identity; prepare a fresh offer for another explicit attempt.
- Rename, reset, removal and source update refuse unresolved local writes or an
  active installation. Recheck writes after asynchronous management operations.
- No local database, second canonical app catalog or implicit format migration.

## Entry points
`review`, `installation`, `open`, session `accept`/`settle`, confirmed Manage.
`SwiftAppRunnerSheet` and `SwiftAppInstallReviewSheet` host these projections.
Only explicit confirmed discard gives up accepted unsaved work.

## Signals
The app notice and runner/review error overlays identify unsaved or unconfirmed
operations. Retained `pending.commandId` / installation command identifies its
receipt. No source or app-data logging.

## Verify
```bash
scripts/tron test gateway src/modules/apps/apps-install.integration.test.ts
scripts/ios-gateway-e2e-test run-ui --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testBuildsInstallLight
```
Also retain the existing installed-app reopen, refused-save and confirmed Manage
real-Gateway journeys. The Builds journeys use canonical interpreted source,
synthetic publisher records and actual production pairing/chat/review/Apps paths;
they inspect but never invoke OS build installation.

## Not here
Interpreter evaluation, sheet styling, HTML execution, publisher ownership,
full history/provenance browsing or SQLite migration.
