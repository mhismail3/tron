# iOS locks

## Gateway event delivery kernel

`GatewayEventDeliveryContractTests` crosses `GatewaySocketConnection` with real
serialized hello/event/response envelopes, the production GatewayClient decoder
and receive loop, admission, epoch retirement and AsyncSequence. Only the named
byte peer is synthetic: these are real Core kernel contracts, not isolated Hub
tests or real-network/TLS coverage. They observe delivered frames, connection
outcomes and bounded transport diagnostics, never private Hub state.

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
termination/relaunch. Version 3/4 readability, invalid/oversized envelope discard,
summary-only rows, archived count without archived rows, profile separation,
generation fencing and removal tombstones are storage contracts, not new formats.

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

## Visual witnesses

Use the smallest faithful rendered contract, not a full state × theme × size
matrix. `TronUILockTests` retains the following explicit witnesses:

| State | Pixel witnesses | AX witnesses | Focused owner |
|---|---|---|---|
| Home Settings | light + dark | light + dark | Shared chrome and #1607 source/control metadata |
| Memory-search tool detail | light + dark | light + dark | Shared chrome and #1607 source/control metadata |
| Empty chat | light + dark | none | Shared composer placeholder uses primary ink dimmed (#2093) |
| Settled chat | light + dark | none | Shared composer placeholder uses primary ink dimmed (#2093) |
| Onboarding welcome | dark | none | No focused equivalent for dark appearance |
| Session Settings | none | none | `TronSixSmallUIRegressionTests.testSessionSettingsOrder`; `TronConsolidatedUIRegressionTests.testSessionSettingsKeepsWorkerOverridesAndTrustReachable`; retained Home chrome |
| Onboarding light | none | none | `TronSmokeUITests.testOnboardingPreservesPagedSheetAndPairingJourney`: actual controls, hit geometry, historical feature-print |

Chat content/tool controls retain `TronWorkerToolRegressionTests.testTranscriptChipsUseFriendlyNames`,
`TronConsolidatedUIRegressionTests.testMemoryToolRowsAndCanonicalNavigation` and
the retained tool-detail interaction journey. Empty chat navigation/title are
required by `TronUILockTests.testChatEmpty`. The four chat pixel witnesses pin
`ComposerPlaceholder`'s shared `.inputPlaceholder` color, which is primary ink
at 60% opacity; the muted green tint is intentional in light and dark modes.
The four Home/tool-detail AX witnesses remain; an independent permission-row
test is not equivalent to their source metadata.

## Comparison and settling

Each call explicitly selects `assertUILock(app, name, accessibility: Bool)`.
Pixels are always compared. Only the four shared-chrome calls select AX; a
missing selected golden fails instead of silently dropping the contract.
AX equality uses `UILockTree`: type, identifier, label, value, placeholder,
traits, disabled/focused state and whole-point frames. Anonymous structural
containers are elided, fixture probes and XCTest's universal trait bit33 dropped.

Pixels use the pinned simulator in `config/ci-toolchain.env` (iPhone17 Pro,
iOS26.5): status bar62pt and adaptive home indicator160×21pt are masked.
A channel delta above12/255 counts; zero differing pixels are allowed.
Two consecutive selected AX/screenshot captures must be byte-identical within10s.
Another screen size fails before recording or comparison.

`TRON_UI_LOCK_RENDERING=1` is hosted-only static capture: UIKit animation is
disabled, with independent SwiftUI transactions fenced at native canvases and
content roots. Identical frames alone do not prove the correct initial inset.
Behavior journeys keep animation. Fixtures pin English/en_US/UTC and appearance;
hosted decorative grain and composer text are seeded.

## Run and evidence

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileUITests/TronUILockTests
```

The module's manifest/consumer graph selects these native tests for affected
verification. Count executed methods; an unmatched selector is no evidence.
Captures are retained under `test-results/ui-locks/`; a failure includes AX
line diff or highlighted pixel diff/count/bounds and the actual beside it.
The selected source golden is always required, including recorder mode.

## Record and storage

`TRON_UPDATE_LOCKS` names owning modules (or `all`); Xcode uses its
`TEST_RUNNER_` prefix. These witnesses belong to `ios-app/ui-tests`.

```bash
TEST_RUNNER_TRON_UPDATE_LOCKS=ios-app/ui-tests scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronUILockTests
scripts/tron-ios-test build
```

Qualify every exact diff before adoption. Human before/after review is for new
design, taste or intended visible changes, not unchanged behavior or duplicate
metadata. Never rerecord an unexplained red. Keep any witness without a faithful
successor; native semantic checks are not lossless incidental pixel/tree parity.

PNG files use Git LFS; AX witnesses are ordinary text. A remaining LFS pointer
fails with the `git lfs pull` hint. Rebuild after golden edits because they are
source resources. New witnesses need a bounded risk, known-bad activation and
repeatability evidence, not automatic theme/size expansion. Still images do not
prove motion continuity; use native temporal interaction checks.
