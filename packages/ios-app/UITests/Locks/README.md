# iOS UI locks

UI locks pin what the user sees in hosted-fixture screen states, so a
restructure slice can prove it changed nothing visible
([plan §6.6](../../../../docs/restructure/plan.md)). Each journey in
`TronUILockTests` only navigates to a state and calls `assertUILock(app, name)`.
Behavioral assertions stay in the feature journeys.

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
  - The status bar (top 62 pt: clock, battery) is painted out.
  - A pixel differs when any RGBA channel moves by more than 8/255.
  - The lock fails at more than 0 differing pixels: runs on the pinned
    simulator are pixel-identical.
  - The device is the one in `config/ci-toolchain.env` (iPhone 17 Pro, iOS
    26.5) in the lane `scripts/tron-ios-test` provisions. Another screen size
    fails with a pinned-device message.

Before capturing, a lock waits until two consecutive snapshots of the hierarchy
and of the screen are identical (up to 10 s), so it never captures an
animation. A state that never settles fails and says so.

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
to `ios-app/ui-tests`. `scripts/tron verify --update-locks` (plan §6.2) will
set it.

```bash
TEST_RUNNER_TRON_UPDATE_LOCKS=ios-app/ui-tests scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronUILockTests
scripts/tron-ios-test build   # goldens are source: rebuild before comparing
```

A missing golden fails; it is never recorded silently. A changed text golden
is a reviewable `git diff`. The maintainer reviews initial and changed goldens
(plan §14.7).

## Golden storage

- **Text goldens are committed.**
- **PNG goldens are local baselines for now:** `Goldens/*.png` is gitignored
  until the maintainer decides how to store them (#1464).
  - A slice records them on its base commit (the update command above; the
    text goldens must show no diff), then compares after its change.
  - Native captures are about 0.3–2.7 MB per state, mostly the backdrop
    grain, which PNG cannot compress.

## Adding a state

Navigate with `require(_:in:)`. It throws on a missing element, so a
navigation failure stops the journey, while lock failures are recorded and the
journey moves on to the next state. Then:

1. Lock light and dark.
2. Record the goldens.
3. Run twice to prove the state is deterministic.
4. Show that a deliberate change fails the lock (known-bad, plan §6.6).
