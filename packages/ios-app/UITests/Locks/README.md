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

## Visual locks

UI locks pin what the user sees in hosted-fixture screen states, so a
restructure slice can prove it changed nothing visible
([plan §6.6](../../../../docs/restructure/plan.md)). Each journey in
`TronUILockTests` only navigates to a state and calls `assertUILock(app, name)`.
Behavioral assertions stay in the feature journeys. The Home Settings hierarchy
includes off-screen rows: Agent & Tools starts with Agent Behavior, followed by
Tools, MCP Servers, Extensions and Hooks. Model, trust and connection controls
live inside Agent Behavior rather than separate root rows. The stopped-session lock
waits for the Session Settings title; model controls live in Manage Session, so
this screen has no Models section.

## What a lock compares

Each state has two goldens in `Goldens/`:

- **`<name>.a11y.txt`** is the app's accessibility hierarchy as text, and must
  match exactly. One line per element: type, identifier, label, value,
  placeholder, UIAccessibility traits, `disabled`/`focused`, and the frame
  rounded to whole points.
  - Normalization lives in one place, `UILockTree`.
  - `other` containers with no identifier, label, value or traits are SwiftUI
    hosting detail. They are elided and their children hoisted.
  - Hosted fixtures' `fixture.*` probes (request counters, routes) are test
    instrumentation and are dropped.
  - Trait bit 33, which XCTest sets on every element, is dropped.
- **`<name>.png`** is a screenshot, compared pixel by pixel.
  - System chrome is painted out: the status bar (top 62 pt: clock, battery)
    and the home indicator (bottom-centre 160×21 pt), whose colour adapts to
    the content beneath it on the system's schedule.
  - A pixel differs when any RGBA channel moves by more than 12/255. Between
    launches of the same build, materials and blurs vary by up to 3/255 and a
    tool chip's soft shadow over the light grain by up to 11/255.
  - The lock fails at more than 0 differing pixels.
  - The device is the one in `config/ci-toolchain.env` (iPhone 17 Pro, iOS
    26.5) in the lane `scripts/tron-ios-test` provisions. Another screen size
    fails with a pinned-device message.

Before capturing, a lock waits until two consecutive snapshots of the hierarchy
and of the screen are byte-identical (up to 10 s), so it never captures an
animation. A state that never settles fails and says so. A screen of any other
size fails before anything is compared or recorded. Byte-identical frames alone
cannot detect a stable fractional scroll offset left by animated sheet insets.
The lock launch harness sets `TRON_UI_LOCK_RENDERING=1`; only `HOSTED_TEST`
consumes it. App startup disables UIKit animations. Retained native sheet canvases
and actual `TronPresentationSurface` content roots disable SwiftUI animations:
`.sheet` creates an independent content transaction root, so the presenter's
transaction does not fence that content's later layout updates. The static setup
controls these separate update boundaries without relying on transaction inheritance
across a native presentation. Normal behavioral journeys retain animation. Locks still wait for content to settle and compare the unchanged
images and hierarchy.

Fixed inputs:

- launches pin `en_US`, English and `TZ=UTC`;
- each journey sets light or dark through its fixture's own argument;
- decorative randomness (`DecorativeRandom`: the backdrop grain and the
  composer's prompt line) is seeded in `HOSTED_TEST` builds only.

## Running

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileUITests/TronUILockTests
```

`scripts/tron verify` runs them in its iOS lane: on `--all`, and whenever a
change touches a module built into the hosted app.

Every run writes its captures to `test-results/ui-locks/<name>.{a11y.txt,png}`.
A failure adds:

- an a11y line diff in the message, with the `git diff --no-index` command
  for the full file;
- `<name>.diff.png`: the golden dimmed, with differing pixels in red, plus
  their count and bounds.

## Recording (`--update-locks`)

`TRON_UPDATE_LOCKS` names the modules (comma-separated, or `all`) whose goldens
a run may rewrite, as for the Gateway's
[scenario locks](../../../gateway/docs/scenario-locks.md). xcodebuild passes it
to the test process only with the `TEST_RUNNER_` prefix. These goldens belong
to `ios-app/ui-tests`. `scripts/tron verify --update-locks ios-app/ui-tests`
sets it ([verify's iOS lane](../../../../tools/verify/README.md#ios-lane)).

```bash
TEST_RUNNER_TRON_UPDATE_LOCKS=ios-app/ui-tests scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronUILockTests
scripts/tron-ios-test build   # goldens are source: rebuild before comparing
```

A missing golden fails; it is never recorded silently. A changed text golden
is a reviewable `git diff`. The maintainer reviews initial and changed goldens
(plan §14.7): the request shows the intended before/after of the user-visible
change next to the actual golden diff, and lists every other state that changed;
an unintended change blocks.

## Golden storage

- **Text goldens are committed** as ordinary files.
- **PNG goldens are committed in Git LFS** (`.gitattributes` tracks
  `Goldens/*.png`): Git holds a small pointer, GitHub's LFS store the image.
  Each state is about 0.3–2.7 MB (the backdrop grain does not compress); every
  changed PNG adds its full size to the owner's LFS storage, and every download
  counts against its LFS bandwidth.
- **Fresh clone:** install `git-lfs` (Homebrew) and run `git lfs install` once
  per user; `git clone` then fetches the images. In a clone made without it,
  `git lfs pull` replaces the pointers; a pointer left in place fails the lock
  with that hint.
- **Approve or re-record:** run the update command above, review each changed
  PNG (the run's `test-results/ui-locks/` captures), commit, and push; the push
  uploads the images. The maintainer approves the change in review.

## Not yet locked

- **A large Dynamic Type size per state** (plan §6.6). The first states lock
  only the default size; adding the size is a follow-up lock slice.
- **`DevicePerformance`** also defines `HOSTED_TEST` (its profiling bundle
  hosts tests), so its grain and composer line are seeded too. That build is
  for measurement only and never ships.

## Adding a state

Navigate with `require(_:in:)`. It throws on a missing element, so a
navigation failure stops the journey, while lock failures are recorded and the
journey moves on to the next state. Then:

1. Lock light and dark.
2. Record the goldens.
3. Run twice to prove the state is deterministic.
4. Show that a deliberate change fails the lock (known-bad, plan §6.6).
