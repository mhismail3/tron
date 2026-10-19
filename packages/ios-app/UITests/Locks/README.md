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
size fails before anything is compared or recorded.

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
