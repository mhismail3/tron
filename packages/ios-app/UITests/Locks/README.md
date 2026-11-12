# iOS locks

## Gateway event delivery kernel

`GatewayEventDeliveryContractTests` crosses `GatewaySocketConnection` with real
serialized hello/event/response envelopes, the production GatewayClient decoder
and receive loop, admission, epoch retirement and AsyncSequence. Only the named
byte peer is synthetic: these are real Core kernel contracts, not isolated Hub
tests or real-network/TLS coverage. They observe delivered frames, connection
outcomes, typed process-activity response values and invalid_response diagnostics
for refused fractional/out-of-range integers, never private Hub state.

The ordinary `TronMobileUITests` runner embeds its own Core framework image,
separate from the app process's image. A peer response after events fences
receive-loop progress; peer-close gates expose overlapping retirement. The
existing run-local `HOSTED_TEST` admission gate delays already-decoded predecessor
work across successor admission; it is only a barrier, not an admission oracle.
Cancellation and lifetime completion must settle consumers without orphan waiters.
No Gateway process, new target, alternate runner or goldens are needed.

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileUITests/GatewayEventDeliveryContractTests
```

The existing `Locks/*Tests.swift` convention selects these contracts for module
baselines through the manifest's consumer graph. They do not record anything.

## Snapshot cache process/filesystem kernel

`SnapshotCachePersistenceContractTests` launches the hosted app with a UUID-scoped
temporary root and the production SnapshotCache/AppModel owners. It observes actual
file envelopes/digest names plus public catalog/snapshot values across app process
termination/relaunch. Version 4 readability, discard of version 3, future, invalid and oversized envelopes,
summary-only rows, archived count without archived rows, profile separation,
generation fencing and removal tombstones are storage contracts, not new formats. Row
compatibility covers only JS-safe integers a real v8 Gateway can send. It is proven against 45
version-4 rows captured from the previous app's own writer (`SnapshotCacheRowCompat.capturedRows`):
they read back in their own and three shuffled key orders, and every row the cache writes has the
captured members byte for byte, in declaration order; canonically equivalent Unicode encodings
remain byte-distinct in both comparison branches. An additional actual old-writer capture at
the conservative 128 KiB shape boundary retains its absent-revision row through load/save/load,
independently of presentation-wrapper nesting. Its repeated ASCII data is stored run-length encoded.
The one stored difference is a row without `summaryRevision`, written back with 0, which the catalog
reads exactly as before. An above-safe-max row discards its whole file (including a valid companion);
relaunch online fully refetches the Gateway catalog and archived count into the disposable cache.
Rows that refuse (a negative revision, nesting beyond the document's depth, node or member bounds)
discard the file, and a `session.list` page without its sessions keeps the catalog and the cache.

The serialized GatewaySocketConnection peer supplies catalog/snapshot/summary
input; it does not implement persistence. Existing clock and signpost ports hold
the summary delay and a real save before file I/O, exposing background API join
and profile-retirement ordering while the app UI remains responsive. Gates are
run-local and explicitly released during cleanup. No filesystem substitute,
private cache counters, new shipping hooks or goldens are used. This API-level
checkpoint test does not prove OS background-assertion expiration behavior.

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileUITests/SnapshotCachePersistenceContractTests
```

Each final fixture cleanup removes only its UUID root. The cold-relaunch case
intentionally retains that root between its two processes, then cleans it.

## Accessibility witnesses

Use the smallest faithful rendered contract, not a full state × theme × size
matrix. `TronUILockTests` retains these witnesses, light and dark each:

| State | Focused owner |
|---|---|
| Home Settings | Shared chrome and #1607 source/control metadata |
| Memory-search tool detail | Shared chrome and #1607 source/control metadata |

Chat content/tool controls retain `TronWorkerToolRegressionTests.testTranscriptChipsUseFriendlyNames`,
`TronConsolidatedUIRegressionTests.testMemoryToolRowsAndCanonicalNavigation` and
the retained tool-detail interaction journey. Session Settings retain
`TronSixSmallUIRegressionTests.testSessionSettingsOrder` and
`TronConsolidatedUIRegressionTests.testSessionSettingsKeepsWorkerOverridesAndTrustReachable`;
light onboarding retains `TronSmokeUITests.testOnboardingPreservesPagedSheetAndPairingJourney`.
There are no pixel goldens: the composer placeholder and subtitle tint (#2093) and dark onboarding
welcome have no rendered witness, nor do the project-lifecycle fixture's `busy` and
`trust-review` surfaces, which only the retired previews opened.

## Comparison and settling

Each call passes `assertUILock(app, name, accessibility:)` with the exact
`UILockTree` text, inline in `TronUILockTests` (`homeSettingsTree`,
`memorySearchToolSheetTree`; light and dark share each). AX equality uses
`UILockTree`: element order, nesting, type, identifier, label, value, placeholder,
traits, disabled/focused state and whole-point frames, so the frames also pin the
simulator in `config/ci-toolchain.env`. Anonymous structural containers are
elided, fixture probes and XCTest's universal trait bit33 dropped. Two
consecutive captures must be identical within 10 s.

`TRON_UI_LOCK_RENDERING=1` is hosted-only static capture: UIKit animation is
disabled, with independent SwiftUI transactions fenced at native canvases and
content roots. Behavior journeys keep animation. Fixtures pin English/en_US/UTC
and appearance.

## Run and evidence

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileUITests/TronUILockTests
```

The module's manifest/consumer graph selects these native tests for affected
verification. Count executed methods; an unmatched selector is no evidence.
Captures are retained under `test-results/ui-locks/`; a failure prints the AX
line diff.

Qualify every exact diff before adopting a new literal. Human before/after review
is for new design, taste or intended visible changes. Never adopt an unexplained
red. New witnesses need a bounded risk and known-bad activation, not automatic
theme/size expansion.
