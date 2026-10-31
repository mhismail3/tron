# gateway/apps

## Purpose

Own installed single-file SwiftUI source, manifests, state and reviewed
installation. The [contract](../../../docs/swift-apps.md) owns versions, bounds,
RPCs and recovery. The iPhone interprets disposable projections, not server code.

## Owns

`module.ts` constructs one `SwiftAppStore` over the workspace contract and
receives the canonical display owner. RPCs and `swift_app` share that store.
`swift-app-format.ts` admits explicit v1/v2 manifests, source/config history and
session/artifact-bound offers. `swift-app-display.ts` reads exact granted UTF-8
artifact bytes with a bounded lease; it never invents artifact authority.

`swift-app-store.ts` serializes `state/apps/`: named v1 `App.swift`, v2 immutable
`sources/<sha>.swift` and atomic `app.json` head, unchanged SQLite v1, pending
offers and explicit v1 upgrade backups. It owns interrupted publication/removal
cleanup. `ios-builds-feed.ts` reads the existing publisher under its POSIX lock;
it does not publish, execute source, network or create a second index.

## Contract

- Descriptor `tron-swift-apps`, capability `swift-apps.v1`; ordinary-session
  `swift_app`, not Home's curated tool profile.
- `offer` creates an exact source/configuration display; it never installs.
  Review/install require its producing session/artifact grant, not caller SHA
  authority. Identical bytes in another display do not inherit an offer.
  Offers retain the granted immutable display inode without republishing its bytes;
  the source link precedes metadata publication, whose directory sync makes both
  entries durable before acknowledgement. Cross-filesystem offers keep the durable
  copy path. Readers validate both documents under the existing mutex; incomplete
  offers are never installable, and retained source survives artifact unlinking.
- Reviewed install/update uses existing transport mutation receipts and fences
  the reviewed head/instance. Accepted uncertain commands never replay on reconnect.
- V1 remains readable through the named reader. Only explicit opted-in update
  backs it up and publishes v2; no read/restart upgrade or SQLite migration.
  The named tool install contract remains v1-only and cannot downgrade v2.
- Source/state are exact data, never transcript-clipped. V2 opens additionally
  read fresh declared feeds; source/state themselves come from one store mutex cut.
- `ios-builds` reads only the configured Gateway home's publisher. Debug and
  Stable homes are distinct; no implicit live-data copy/fallback.
- Pending offer retirement uses DisplayOwner's canonical session/artifact retention,
  not a second catalog. First root access, catalog reads and a full-store offer
  attempt reclaim unreachable offer source/configuration under the store mutex;
  installed apps and live offers remain. Unprovable metadata is left unchanged.
- `apps.pending` derives valid uninstalled offers from the same store, verifying
  the producing canonical session/artifact and source bytes; no second index.
  `apps.review` returns the exact granted source for both Apps and chat review.
  Neither read installs; only the existing explicit install mutation does.
- No background feed polling or change broadcast.

## Invariants

- Established missing/unsafe storage refuses instead of initializing fresh data.
- Publication precedes the manifest head; new apps stage their entire directory.
  Updates preserve data and immutable instance identity.
- State/source/instance fences protect stale writes and removed/reinstalled apps.
- Remove syncs its retirement rename before erasing data. Restart reclaims only
  exact owner-controlled retirement/staging names.
- Explicit upgrade retries preserve old backups and create a current snapshot;
  backup attempts are bounded. Publication success precedes deferred cleanup.

## Entry points

`module.ts`: RPC admission/registration and store composition.
`tron-swift-app-extension.ts`: tool/source admission and display offer production.
The [iOS runner](../../../../ios-app/docs/swift-apps.md) owns execution and link UI.

## Signals

`GatewayError` distinguishes invalid input, missing grants/apps and conflicting
or unsafe state. `details.outcomeUnknown` identifies an interrupted receipt,
not replay permission. Feed `unavailable` is distinct from `empty`.
Missing/unsafe SQLite is a restoration problem, never permission for revision zero.

| Signal | One-step diagnosis / boundary |
| --- | --- |
| `ios-builds` unavailable | `ls -1 <configured-Gateway-home>/ios-builds/builds` identifies committed candidates. Both timestamp/commit and timestamp/UUID/commit names are valid; a retained release must not make the whole feed unavailable. Check the publisher lock and bounded record/IPA/manifest identity, not app state or reinstall. The mixed-publication RPC journey covers both names and unsafe-input refusal. |

## Verify

```bash
scripts/tron verify --module gateway/apps
scripts/tron test gateway src/modules/apps/apps-install.integration.test.ts
```

Store/lock journeys retain the named v1 and real SQLite oracles.
The install journey crosses RuntimeRegistry, canonical display grants,
GatewayService/receipts, real publisher files and the native interpreter.
The feed probe compiles once per file in bounded asynchronous suite preparation,
with a private compiler cache removed at suite teardown. Each native invocation
still starts a fresh interpreter process; compilation is not part of either
15-second feed journey's behavior deadline. No built artifact survives the run.
The 199-offer capacity journey joins RuntimeSlot state changes and bounds real
metadata synchronization work to 812 operations (four per offer plus fixed turn/store
initialization); host elapsed time is not its oracle. It still checks all 200 offers,
canonical deletion, byte reclamation, live/installed retention and capacity reuse.
Artifacts: `test-results/apps-install/report.json` includes the observed sync count.
Fixture kill cuts release the workspace lease first; they do not prove whole-Gateway
ungraceful crash or power-loss recovery.

## Not here

Workspace root authority, transport receipts, scheduling, source execution,
HTML apps, a full history browser, publisher changes or app-state migrations.
