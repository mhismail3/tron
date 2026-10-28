# gateway/apps

## Purpose

Installed single-file SwiftUI apps: their source, manifest and key/value data.
The Gateway owns them; the iPhone runner consumes bounded projections. The
[installed-app contract](../../../docs/swift-apps.md) specifies storage and limits.

## Owns

`module.ts` constructs one `SwiftAppStore` in descriptor `start`, using the
workspace module's contract. Both descriptor RPCs and `swift_app` use that store.
It serializes operations over `<workspace>/state/apps/<appId>/`: `app.json`,
`App.swift` and `data.sqlite`. There is no second store in the registry or phone.

## Contract

- Descriptor `tron-swift-apps` advertises `swift-apps.v1`. Its `swift_app` tool is
  available in ordinary sessions, not Home's curated profile.
- Reads: `apps.list`, `apps.get`, `apps.state`, coherent `apps.open` (source + state).
  Mutation: `apps.commit`, under transport command receipts and the expected state revision;
  interpreter writes additionally fence the source revision that produced them.
- Tool actions: list, install, state, commit and remove. Install reads a visible,
  link-free `.swift` source relative to the session or internal workspace files.
- Sources and state are exact executable/restorable data: RPCs bypass transcript
  string/array clipping, with the store enforcing their bounds. No change event
  is currently broadcast.
- `SwiftAppManifest`, `SwiftAppStateSnapshot` and `SwiftAppCommit` currently live
  in `swift-app-store.ts`. They are the existing public values for a future pure
  contract extraction; the descriptor and store remain behavior owners, not a
  second schema or a re-export facade.

## Invariants

- First installation may create state; missing or unsafe established storage
  refuses rather than resetting it. Reads do not initialize an absent store.
- Reinstallation replaces source/metadata but keeps data. Source hash mismatch
  refuses a torn publication instead of serving unverified source.
- Source and state revisions are separate. Stale state/source-fenced commits refuse;
  launch reads serialize with install/remove/commit, and bounds are checked within
  the SQLite transaction before publication.
- Removal renames the directory aside durably before deleting source and data.
  Short-lived database connections close before the serialized operation ends.

## Entry points

`module.ts` owns registration, RPC validation and store construction;
`tron-swift-app-extension.ts` owns tool admission and source resolution;
`swift-app-store.ts` owns persistence and revision admission. The iOS runner
contract is [documented separately](../../../../ios-app/docs/swift-apps.md).

## Signals

`GatewayError` refusals distinguish invalid input, missing apps and conflicting
or unsafe state. Missing/unsafe databases and unsupported schemas are restoration
problems, not permission to retry with revision zero. No module-specific log
signal or background timer is registered.

## Verify

```bash
scripts/tron verify --module gateway/apps
scripts/tron test gateway src/modules/apps/swift-app-store.integration.test.ts
```

`apps.store.lock.integration.test.ts` protects persisted state. The integration
journey drives the tool through a real runtime/faux model and RPCs through
`GatewayService`: exact source, receipt replay, stale/bounded commits, reinstall,
restart, removal and unsafe/missing storage. It writes
`test-results/swift-app-store/report.json`. `run-prompt-stream` additionally
locks the ordinary-session tool surface; `protocol.wire` guards shared wire
values. These consumer locks do not replace the module's store journey.

## Not here

Workspace root authority: [workspace](../../workspace/README.md). RPC receipt,
drain and disconnect ownership: transport. Swift interpretation and rendering:
the iPhone Swift app engine. No feeds, scheduling, source execution or app-state
migration is implemented here.
