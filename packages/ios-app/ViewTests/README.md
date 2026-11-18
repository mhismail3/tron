# In-process view tests

`TronMobileViewTests` is the iOS in-process tier: an XCTest bundle hosted by the Test app, in the
`Tron UI Validation` scheme and `UIValidation` plan. XCTest launches the app once. Each test mounts a
hosted fixture in its own window inside that process and asserts on what the app draws: the
accessibility tree, layout frames and colours sampled from the rendered window. There is no second
process, relaunch or synthesized gesture.

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileViewTests
TEST_RUNNER_TRON_VIEW_TESTS_SEED=<seed> scripts/tron-ios-test run --only-testing TronMobileViewTests/<Class>
```

- **Mounting.** `MountedFixture` sets `HostedLaunch.arguments`, the hosted fixtures' one source of
  launch arguments, and the theme, then mounts `HostedFixtureRoot`, the root an XCUITest launch
  renders, at the device's screen size with scene phase active and animations off (UIKit and SwiftUI
  transactions). Closing restores the arguments, the theme and the dashboard filter.
- **Acting.** Navigation activates accessibility elements (`accessibilityActivate`), as VoiceOver does.
  A UIKit menu's action is performed directly; the menu's own presentation is not under test.
- **Waiting.** `until` re-checks its condition once per display frame while no presentation is in
  transition and no finite, non-repeating Core Animation runs. `still` (and `inked`, its ink form)
  waits until a sample exists and is unchanged across two frames. A wait that passes 600 frames fails with the accessibility tree.
- **Colour.** `ink` averages the chromatic pixels (channel spread above 60 of 255) of a frame in the
  rendered window; `chroma` averages per-pixel normalised chroma above a given channel spread and counts
  the pixels. The assertions compare those values, as the XCUITest twins compared screenshots.
- **Order.** Each class shuffles its tests and prints the seed; the seed variable above replays it.

What stays in XCUITest: claims only a second process observes, such as real gestures, keyboard focus,
alerts, menu presentation and persistence across relaunch.

## Gateway event delivery kernel

`Locks/GatewayEventDeliveryContractTests` crosses `GatewaySocketConnection` with real
serialized hello/event/response envelopes, the production GatewayClient decoder
and receive loop, admission, epoch retirement and AsyncSequence. Only the named
byte peer is synthetic: these are real Core kernel contracts, not isolated Hub
tests or real-network/TLS coverage. They observe delivered frames, connection
outcomes, typed process-activity response values and invalid_response diagnostics
for refused fractional/out-of-range integers, never private Hub state.

They run in the app process against its Core image. A peer response after events fences
receive-loop progress; peer-close gates expose overlapping retirement. The
existing run-local `HOSTED_TEST` admission gate delays already-decoded predecessor
work across successor admission; it is only a barrier, not an admission oracle.
Cancellation and lifetime completion must settle consumers without orphan waiters.
No Gateway process or goldens are needed. The `Locks/*Tests.swift` convention selects
these contracts for module baselines through the manifest's consumer graph.
