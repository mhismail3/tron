# Chat transcript stability

- **Started:** 2026-09-26
- **Status:** Active
- **Last updated:** 2026-09-26, CT-2
- **Goal:** The chat transcript stays on screen and pinned by construction, so the scroll repairs that compensate for SwiftUI's lazy-stack estimates can be deleted rather than extended.

## Goal and constraints

A long session goes blank, jumps, or stops short after a send, a keyboard change
or a foreground. Each earlier fix added a correction on top of the same cause.
This plan removes the cause, then deletes the corrections it made unnecessary.

What must not change:

- The send choreography: the outgoing row's 280 ms fade and 20 pt rise, composer
  collapse, keyboard dismissal and the pinned tail, all in one
  `ChatLayoutTransaction` generation. Streaming growth, tool-chip entrances, the
  queued-card cross-fade and shrink, the opening reveal, catch-up, earlier-page
  loading, detached readers and the bottom rubber band must look and behave the
  same. The contracts in `packages/ios-app/docs/development.md` and
  `packages/ios-app/docs/architecture.md` still hold unless a task changes them
  in the same commit.
- Chat identity: one physical host per row, no replayed entrance, prompt
  aliasing, copy and context menus acting on the whole message.
- Scrolling and streaming cost. Measure with the chat performance signposts and
  the hosted frame samples before and after each task; no task may make them
  worse.

Every task is one reviewable change with its hosted regression and a negative
control. No task may leave two owners for the same decision, and no task adds a
timer, retry or repair to compensate for estimated geometry.

## Context

Measured 2026-09-26 from device exports and hosted fixtures:

- Cause. A `LazyVStack` estimates unrealized rows from the average height of the
  rows it has placed. Apple documents this model and advises against logic built
  on absolute content size or offset (WWDC26 "Dive into lazy stacks and
  scrolling with SwiftUI"). Tron renders an assistant message as one physical
  row however long it is: the projection kernel splits only at tool calls
  (`packages/ios-app/Sources/UI/Chat/ChatTranscriptProjectionKernel.swift`), and
  Markdown blocks render eagerly (`packages/ios-app/Sources/UI/Chat/TronMarkdownView.swift`).
  When the container changes size (keyboard up or down) with a tall row in the
  measured set, the estimate is re-derived from it: on device 173 rows that really
  take about 14,000 pt were estimated at 219,825 pt, and stayed wrong for minutes.
- Symptom. The eager tail marker sits at the estimated bottom, so a pinned
  viewport stays aligned to it while every real row is elsewhere: a blank screen
  that every existing check reports as healthy. Hosted bisection: a keyboard change
  alone reproduces the re-derivation; a send without a keyboard change does not; a
  history without a tall row does not.
- Compensations. `packages/ios-app/Sources/UI/Chat/ChatScrollCoordinator.swift`
  is 3,174 lines on `main`. At least these exist because lazy estimates or
  realization are unreliable: opening two-frame physical proof, the tail
  materialization lease and its two-frame fail-open, physical tail repair, the
  past-end repair, layout-epoch invalidation of frame samples, and the 1 pt
  entrance footprint. The unmerged `fix/chat-blank-evidence` branch adds a
  mounted-row ledger, a blank sampler and a blank recovery (about 440 more lines).
  It is superseded by this plan, except for its hosted reproduction fixtures.
- Test environment. `scripts/tron-ios-test` shares one derived-data directory
  across worktrees and records no source identity for a run, so concurrent
  sessions' builds mixed and produced deterministic crashes and untrustworthy
  passes. The heavy hosted fixtures also fail intermittently under load. The
  shared directory was introduced deliberately (commit `8082a02dc`) to serialize
  and reuse builds, so CT-1 keeps reuse while isolating source identity.
- Baseline on `main` at `94f0fd217`, private derived data: the full
  `ChatViewScrollHarnessTests` passed 52/52, 51/52 and 52/52. The one failure,
  `hostedOpeningRevealIsMonotonic`, also appeared once in three runs on the
  branch, so it predates this plan.

Options ranked by the 2026-09-26 research:

| Option | Removes the cause | Cost |
| --- | --- | --- |
| A. Keep `ScrollView` + `LazyVStack`; bound every physical row's height by splitting long content into data-level segments; decide pinning from visible row identity, not estimated geometry; no layout change after a row appears except the pinned tail | Mostly: outliers are bounded, residual corrections remain small | Low to medium |
| B. `UICollectionView` with a bottom-anchored layout, hosting the existing SwiftUI rows through `UIHostingConfiguration` | Yes: sizing and anchoring become synchronous and owned | High: keyboard, pinning, paging and height animations are rebuilt |

`List` and inverted stacks were rejected: `List` lacks `defaultScrollAnchor`
and weakens row animation; inversion moves the estimate error to history and
breaks context-menu previews.

## Plan rules

- A fixture counts as green only after three consecutive passing runs, each built
  from its own worktree with its own derived data.
- A deletion task first shows its fixture set stays green with the mechanism
  disabled, then deletes the mechanism, its tests, its trace events and its doc
  paragraphs together.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| CT-1 | Done | Test isolation: `scripts/tron-ios-test` uses per-worktree derived data by default, records the source revision and worktree in each run's metadata, and refuses to run products built from another worktree; update `packages/ios-app/docs/development.md` | none | chat scroll investigation session, 2026-09-26 |
| CT-8 | Done | Stabilize `hostedOpeningRevealIsMonotonic`: find why the opening reveal's sampled distance is non-monotonic in about one run in three and fix the cause (product or oracle), with evidence from repeated runs | CT-1 | chat scroll investigation session, 2026-09-26 |
| CT-9 | Ready | `ChatViewScrollHarnessTests.displacedRetainedResume` exceeded its 15-second watchdog once in six full-suite runs while the host was contended (suite wall 88.7 s against 74 s); decide whether the fixture's own work or the watchdog budget owns it, as the plan's context notes for the heavy hosted fixtures | CT-1 | |
| CT-2 | Done | Baseline: port the hosted reproduction fixtures from `fix/chat-blank-evidence` to `main` as measurements, not pass/fail gates. Record blank boundaries, estimate-to-truth ratio after keyboard cycles, tail displacements, repair commands and frame cost on the worst shapes (tall reply at the tail, many tall replies, 180+ rows), three runs each | CT-1 | chat scroll investigation session, 2026-09-26 |
| CT-10 | Ready | Complete the baseline CT-2 trimmed: frame cost (chat performance signposts and display-link frame intervals) during streaming, sends and scrolling on `main`, the tall-reply-at-the-tail and 180+ row shapes, and why only the first of three submissions in the keyboard-cycles shape materialized a tail (`materialize:1`). CT-5 may not ship until CT-10's frame cost exists to compare against | CT-1 | |
| CT-11 | Ready | Parallel test lanes: `scripts/tron-ios-test` picks a free owned simulator from a small pool (each with its own lease and state directory) instead of one shared simulator, so concurrent worktrees stop queueing; `clean` removes only its own lane's simulator and never another lane's retained runs; document the lane count against CPU and memory, and check the hosted timing fixtures under two concurrent lanes | CT-1 | |
| CT-3 | Claimed | Prototype A on a throwaway branch: segment long assistant content at Markdown block boundaries into bounded physical rows, with pinning from visible row identity; measure against CT-2. The prototype does not need product polish, but it must show whether the blank and the estimate swing disappear | CT-2 | chat scroll investigation session, 2026-09-26 |
| CT-4 | Needs approval | The user chooses A or B from CT-3's numbers and a device build of the prototype | CT-3 | |
| CT-5 | Needs scoping | Implement the chosen option in production. For A: segment identity, streaming into the last segment, whole-message copy/menus/accessibility, one entrance per message, segment chrome; pinned state from visibility. Scope into rows once CT-4 decides | CT-4 | |
| CT-6 | Needs scoping | Delete the compensations CT-5 makes unnecessary, one per commit, each under the plan rules: past-end repair, physical tail repair, the materialization fail-open, geometry-based pinned evidence, and the trace fields that only diagnose them | CT-5 | |
| CT-7 | Needs scoping | Device validation with the user: the send choreography checklist in `packages/ios-app/docs/development.md`, plus long sessions with tall replies across keyboard, foreground and resume | CT-6 | |

## Handoff log

### CT-2 · Done · 2026-09-26 · chat scroll investigation session

- Result: the blank-transcript investigation's hosted reproduction fixtures are on
  `main` as measurements, not gates. `ChatViewScrollHarnessTests.ct2ManyTallRepliesMetrics`
  drives one keyboard-sized contraction, one send and the keyboard dismissal that
  lands in the same display window, over 140 rows whose last eight are ~1,300 pt
  tall. `ChatViewScrollHarnessTests.repeatedKeyboardAndSendCyclesKeepRealizedRowsOnScreen`
  drives three keyboard up/down cycles (20/20/60 display boundaries after a
  40-boundary settle), each submitting a prompt before the keyboard dismisses,
  over a history with one such row beside
  the tail. Each prints one `CT2-METRICS` line per invocation and asserts only
  that the scenario ran (every sampled boundary was taken, the single-send
  shape's tall row was realized and measured >1,000 pt, and the sends
  materialized a tail). The blank
  recovery, the mounted-row ledger, the gap sampler and the `visibleRows`/
  `terminalGap` trace fields are deliberately not ported: this plan deletes
  compensations rather than adding them. No product behavior changed — the only
  non-test change is the `HOSTED_TEST`-only geometry trace, which now carries the
  content estimate and container height because a re-derivation inside one frame
  is invisible without them.
- Evidence (all in `/private/tmp/tron-ct82`, products built from this worktree's
  own source state, run directories under `~/Library/Developer/Tron/ios/test-runs/`):
  - Both fixtures pass from the committed source state, 2.2 s and 6.5 s, 8.7 s
    together (`20260926T193600Z-run.wTjey8`); the same two passed 2.3 s and 6.6 s
    one build earlier (`20260926T193430Z-run.WCYJMY`).
  - Raw lines, both ported fixtures in each of those two invocations. The
    numbers move run to run with how much of the history the opening happened to
    realize; the blank count moves most of all:

    ```
    CT2-METRICS shape=many-tall-replies samples=72 blankBoundaries=12/72 blankAfterSettle=10 longestBlankRun=12 blankPhases=p1:12 maxEstimateRatio=2.8 estimateOpen=64430.0 estimateMin=64430.0 estimateMax=180064.0 pastBottomBoundaries=0 reDerivations=5 maxReDerivation=115634.0 tallRowHeight=1286.0 tailDisplacements=3 repairCommands=materialize:1,physical:0,pastEnd:0 pastEndRepairs=0 tailErrorSettled=0.0
    CT2-METRICS shape=keyboard-cycles-with-sends samples=340 blankBoundaries=80/340 blankAfterSettle=76 longestBlankRun=60 blankPhases=p5:20,p9:60 maxEstimateRatio=2.4 estimateOpen=27014.0 estimateMin=27014.0 estimateMax=63819.0 pastBottomBoundaries=0 reDerivations=15 maxReDerivation=64944.0 tallRowHeight=1286.0 tailDisplacements=10 repairCommands=materialize:1,physical:0,pastEnd:0 pastEndRepairs=0 tailErrorSettled=0.0
    CT2-METRICS shape=many-tall-replies samples=72 blankBoundaries=12/72 blankAfterSettle=10 longestBlankRun=12 blankPhases=p1:12 maxEstimateRatio=4.2 estimateOpen=43122.0 estimateMin=43122.0 estimateMax=180064.0 pastBottomBoundaries=0 reDerivations=6 maxReDerivation=136942.0 tallRowHeight=1286.0 tailDisplacements=3 repairCommands=materialize:1,physical:0,pastEnd:0 pastEndRepairs=0 tailErrorSettled=0.0
    CT2-METRICS shape=keyboard-cycles-with-sends samples=340 blankBoundaries=140/340 blankAfterSettle=134 longestBlankRun=60 blankPhases=p4:20,p6:60,p9:60 maxEstimateRatio=2.3 estimateOpen=28176.0 estimateMin=28176.0 estimateMax=63819.0 pastBottomBoundaries=0 reDerivations=19 maxReDerivation=63782.0 tallRowHeight=1286.0 tailDisplacements=10 repairCommands=materialize:1,physical:0,pastEnd:0 pastEndRepairs=0 tailErrorSettled=0.0
    ```

  - The blank reproduces on `main` in both fixtures' terms, and always as a whole
    phase: the many-tall-reply shape leaves the viewport with no mounted row for
    the entire 12-boundary keyboard-up phase, and the cycle shape for whole
    phases — one or two 20-boundary phases and one 60-boundary dismissal phase,
    longest consecutive run 60 — the same shape the branch measured at 240-280 of
    600 over eight cycles. The estimate is the swing the plan's context
    describes: the published content estimate reaches 180,064 pt, which is the 140-row count times the tall row's measured
    1,286 pt — a re-derivation that measured only the tall row.
  - One clean-build run of the wider shape set was taken before the user's time
    box trimmed it, single run each: tall reply at the tail 0/72 blank boundaries
    (ratio 1.9, largest single-frame re-derivation 161,825 pt), tall reply beside
    the tail 0/72 (1.2, 55,725 pt), 190 rows of mixed height 32/72 (1.4,
    99,814 pt, one physical-tail repair). The 190-row shape also failed to open
    once when four shapes ran in one invocation, so it is the one shape whose
    measurement is not trustworthy.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass. This plan entry was appended after the
    two runs above, so by CT-1's rule the products stamped before it are stale
    until the next build; the code they measured is this commit's.
- Changes: this commit (`packages/ios-app/Sources/Support/ChatHostedProbe.swift`,
  `packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`,
  `packages/ios-app/docs/development.md`, this plan).
- Tasks added: none.
- Kept on purpose: the branch's `ChatHostedGeometryTraceSample` content-estimate
  fields are the only probe surface the fixtures needed. The native,
  unmount-aware visible-row count already exists on `main` as the harness's
  `nativeRows(in:)`, which reads the row hosts in the live hierarchy and excludes
  markers without a window, so the ported sampler needed no new view scan. The
  branch's `close()` change (reset the root view before teardown) belongs to the
  recovery's retirement, not to the measurement, and stayed out.
- Deviations, all from the user's mid-task time box:
  - Only two shapes are ported and each is measured once per clean build, not
    three times: the plan rule's repetition is the runner's own repeated
    invocation, and the `CT2-METRICS` line carries no run number for that reason.
  - Not measured, with the reason: the tall-reply-at-the-tail and 180+-row shapes
    (only their single pre-trim run above exists), and frame cost — the line
    reports no per-frame cost, and neither the chat performance signposts nor
    display-link frame intervals were collected. If CT-3 needs them, they are new
    work, not a fix to this one.
  - `maxEstimateRatio` is a documented proxy: the largest published content
    estimate over the smallest. The harness has no independent measurement of the
    history's realized height — a lazy stack never realizes all of it, and the
    offsets of the rows it does place are themselves estimate-derived — so the
    proxy is the estimate's own excursion during the journey, with
    `estimateOpen`/`Min`/`Max` printed beside it.
  - Trying to drive the plan rule's three runs from one invocation (a
    `TRON_CT2_RUNS` scheme environment variable) did not work: an expanded scheme
    variable does not reach the simulator test process, and the attempt was
    reverted rather than left as a knob that does nothing.
- For the next agent: `scripts/tron-ios-test build` then
  `scripts/tron-ios-test run --only-testing TronMobileTests/ChatViewScrollHarnessTests`
  runs both fixtures in about 9 s on top of the suite, which is inside the task's
  budget. Read the `CT2-METRICS` lines from the run log or the retained
  `xcresult`. CT-3 should compare against the many-tall-reply numbers above first,
  because that shape reproduces both the blank and the 180,064 pt estimate in
  ~2 s; `blankAfterSettle` and `maxEstimateRatio` are the two fields that must
  move when the estimate stops driving the viewport.

### CT-8 · Done · 2026-09-26 · chat scroll investigation session

- Result: the oracle was measuring the wrong quantity. `hostedOpeningRevealIsMonotonic`
  projected each sampled frame onto the covered→settled axis, which is a
  *registration* measure: the visible entrance fades and rises the transcript by
  8 points in one `easeOut(0.26)` transaction, and while the glyphs are displaced
  that projection collapses towards 0 and then jumps back to ~1 as they land. A
  settled frame shifted 2.7 pt measures 0.006 instead of 1.0 (measured on retained
  frames: 1.000 at 0 pt, 0.787 at 0.7 pt, 0.376 at 1.3 pt, 0.051 at 2 pt, 0.006 at
  2.7 pt, 0.139 at 4 pt, 0.000 at 8 pt), so the sampled "distance" oscillated
  between a partly registered frame and a displaced one, and any drop over 0.035
  failed. The probability of that pair landing in one 18-frame window is what
  fixed the ~1-in-3 failure rate; the product's entrance is one monotone
  animation (rendered content 0.04 → 0.85 → 0.99 → 1.0 of the settled render, and
  the settled content's own registration 6.7 pt → 0.7 pt → 0), so no product
  change was made. The oracle now measures the revealed content — how far the
  sampled frame has moved from the covered frame, normalized by the settled
  frame's own distance — on a one-point-per-point grid: a 12-point grid
  moves that distance by up to 20 percent across the entrance's 8-point rise,
  while the one-point integral cancels the rise out to within 0.1 percent.
- Evidence (all in `/private/tmp/tron-ct82`, products built from this worktree's
  source state, each run's own identity record under
  `~/Library/Developer/Tron/ios/test-runs/`):
  - Reproduction first: with the old oracle, the sampled progress was
    `0.0000,0.0142,0.0037,0.0762,0.0254,0.2957,…` — a 0.0508 regression where the
    tolerance allows 0.035. Sampled distances were captured by printing each
    frame's projection, `meanAbs` from the covered frame and native geometry; the
    content's own growth from the covered frame was monotone in every run
    (`0.0000,0.0007,0.0254,0.0401,0.0472,0.0562,0.0622,…`), while the projection
    fell and sprang back, and the geometry (offset 2890, content 3681) never
    moved. Retained PNG frames of each sample (test attachments) show the settled
    glyphs at 6.7 pt below their final place in the first revealing frame, 0.7 pt
    in the next and 0 after that, with the same glyph pitch — a monotone rise, not
    a replayed or competing entrance.
  - 20 consecutive single runs after the fix: all pass
    (`20260926T183933Z-run.b24P2h` … `20260926T184242Z-run.bFflvt`). Over those 20
    runs plus the 20 measurement runs before them, the largest consecutive
    regression of the fixed metric was 0.022 against the 0.06 tolerance.
  - Negative control: a temporary second owner in `ChatView` re-covered the
    transcript on its own 150 ms clock during the reveal (a `TronBackdrop` shown
    again from `.presented`/`.ready`). The test failed 3 of 3 runs at the
    monotonicity check, with sampled progress `0.976,0.986,0.233,…`. The product
    injection was reverted before the commit.
  - Three consecutive `ChatViewScrollHarnessTests` runs: 52 tests passed each
    (74.5 s, 74.7 s, 74.9 s; `20260926T184259Z-run.WFxzyC`,
    `20260926T184421Z-run.CsOw2T`, `20260926T184544Z-run.uSjK98`).
  - One complete unit-target run: 1695 Swift Testing tests in 137 suites and 87
    XCTest tests, 0 failures in 172.8 s (`20260926T184714Z-run.jB5TrT`,
    summary `failedTests: 0`) — the first such run in this plan without
    the opening-reveal failure.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`,
  `packages/ios-app/docs/development.md`, this plan).
- Tasks added: CT-9, from one suite run that failed on
  `ChatViewScrollHarnessTests.displacedRetainedResume` instead: its 15-second
  watchdog expired with the suite running at 88.7 s wall instead of 74 s, on the
  same committed source that passed 52/52 in the runs either side. It is the
  plan's context's heavy-fixture-under-load case, not the reveal oracle, so it
  becomes a row rather than a change here.
- Kept on purpose: the opaque-cover check (`covered` versus the next frame at
  `.presenting`, < 0.02), the `.ready` phase check, the settled render's material
  difference from the cover (> 0.08), and the 18-sample window with the last
  sample as the settled reference. `renderedPixelProgress` is deleted with its
  only caller: it was the registration measure. The tolerance keeps its meaning as
  a noise allowance and moved 0.035 → 0.06 because the quantity changed: the
  measured worst regression of the new metric is 0.022, and a real replay or a
  second cover moves it by 0.7 or more (negative control), so the smaller number
  was tuned to the old, registration-sensitive quantity rather than to the
  render's own sub-point settling.
- Deviations: the fix is in the oracle, so the product animation is untouched and
  `development.md`'s opening-reveal contract is unchanged; only the paragraph
  describing the hosted visual-continuity oracles gains what this one measures.
  The new metric is an area statistic, so it is sensitive to the reveal's
  *amount* (a replayed entrance, a returning cover, a fade that reverses
  or stalls low) but deliberately not to the *rise's* registration, which is the
  quantity that made the old oracle flaky; a pure position reversal at constant
  opacity is not caught. Sampling at one point per point raises this test's own
  runtime to about 2.6 s.
- For the next agent: the plan's CT-2 baseline sits on the same harness. The
  oracle's `renderedRevealGrid` is the only one-point-per-point pixel sampler; keep
  it there, because a 12-point grid aliases the entrance's 8-point rise into the
  measurement. Swift Testing selectors for a single case need the
  parenthesis form, for example
  `--only-testing 'TronMobileTests/ChatViewScrollHarnessTests/hostedOpeningRevealIsMonotonic()'`.

### CT-1 · Done · 2026-09-26 · chat scroll investigation session

- Result: `scripts/tron-ios-test` can no longer execute products built by another
  worktree or from another source state. Products live in
  `$HOME/Library/Developer/Tron/ios/test-derived-data/<worktree-key>` (worktree
  directory name plus 12 hex of a hash of its path), `build` writes
  `build-identity.json` beside them only after a successful build (worktree path,
  HEAD revision, dirty flag, sha256 fingerprint of the tracked diff plus the
  content of every untracked non-ignored file), and `run` re-proves that stamp,
  exiting 74 and naming both identities when they differ. Every build's and
  run's `metadata.json` carries the same identity under `source`. The one
  serialized simulator lease, the shared retained-runs root with its `latest`
  symlink, and the `TRON_IOS_TEST_DERIVED_DATA` override are unchanged, as is
  reuse of the build cache within a worktree.
- Evidence (verified in `/private/tmp/tron-ct1` unless stated):
  - `python3 scripts/test-ios-test-infrastructure.py`: 25 tests pass in 27 s (13
    before; 12 new). Runner-level: products stamped for another worktree, for a
    changed source state, and with no stamp are all refused with exit 74; a real
    `build` stamps the products and records the same `source` in the run
    metadata; a real `run` records the identity it verified; the default products
    directory is `<HOME>/Library/Developer/Tron/ios/test-derived-data/<key>` under
    a synthetic HOME; `clean` removes this worktree's products and leaves a
    sibling worktree's directory. Identity-level (real temporary git repos): the
    key is stable for one path and different for another, tracked edits and
    untracked additions/edits each change the fingerprint, `verify` refuses a
    missing or foreign stamp, `write` refuses a foreign worktree document, and a
    nested directory is not accepted as the worktree.
  - `scripts/tron-ios-test build`: `** TEST BUILD SUCCEEDED **`, cold per-worktree
    products in 1 m 58 s, second incremental build 9 s (cache reuse kept).
  - `scripts/tron-ios-test run --only-testing TronMobileTests/GatewayLogExportTests`:
    17 tests in 1 suite passed, 14.6 s wall, run
    `20260926T173154Z-run.Yi0cES` under `~/Library/Developer/Tron/ios/test-runs/`,
    metadata `source` identical to the stamp.
  - Negative control: after the build, one comment line was appended to
    `packages/ios-app/Tests/Gateway/GatewayLogExportTests.swift` and `run` exited
    74 with `built from: … source fingerprint 4b222e595247` versus
    `current: … source fingerprint 19496bfa9b8b`, naming the worktree and
    revision on both sides. `git checkout --` the file, with no rebuild, returned
    `status` to "built from this worktree's current source state" and a rerun
    passed 17/17, so the guard is not over-strict.
  - Pre-change products are refused too: running with
    `TRON_IOS_TEST_DERIVED_DATA=$HOME/Library/Developer/Tron/ios/test-derived-data`
    (the old shared directory, still holding another session's products) exits 74
    with "carry no build identity", naming the missing stamp.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`scripts/ios-test-build-identity.py` new,
  `scripts/tron-ios-test`, `scripts/test-ios-test-infrastructure.py`,
  `packages/ios-app/docs/development.md`, `.agents/skills/tron-ios/SKILL.md`,
  `.github/workflows/ci.yml`).
- Tasks added: none.
- Kept on purpose: the serialized lease, the exact owned simulator, the shared
  `test-runs` retention and `clean`'s semantics, which is what commit `8082a02dc`
  set out to keep. Reuse survives inside a worktree (9 s incremental build), and
  `TRON_IOS_TEST_DERIVED_DATA` still overrides; the retained-runs root stays
  shared and is now attributable through `source.worktree` in each metadata.
- Deviations: the identity covers the whole non-ignored worktree rather than
  `packages/ios-app` alone, so an edit after a build — documentation included —
  needs a rebuild before `run`; both the doc and the helper say so, and it is the
  conservative reading of "the same source state as the build". The identity is
  measured once per command, so an interrupted build leaves the previous stamp.
  `status` now prints the worktree, the products directory and whether the
  products match the current source, replacing the bare products path line. This
  plan entry was appended after the runs above, which by the same rule makes the
  products stamped before it stale until the next build.
- For the next agent: CT-8 and CT-2 now get isolated products by default, so the
  plan rule "each built from its own worktree with its own derived data" is what
  `build` does when run in that worktree. A per-worktree products directory is
  about 1 GB; `clean` removes this worktree's, and a directory for a deleted
  worktree is removable by hand because it carries the runner's ownership marker.
  Do not point `TRON_IOS_TEST_DERIVED_DATA` at a path inside the worktree unless
  it is git-ignored, or the products themselves become part of the source state
  the stamp covers.

### CT-0 · Done · 2026-09-26 · chat scroll investigation session

- Result: drafted from four device incidents, the hosted bisection and the research brief.
- Evidence: device exports 2026-09-25T08-42, 2026-09-26T07-17, 08-04, 08-05 and 08-07; hosted fixtures on `fix/chat-blank-evidence`.
- Changes: this file, proposed.
- Tasks added: CT-1 to CT-8 (CT-8 added at approval from the `main` baseline runs).
- Kept on purpose: the past-end repair and trace changes already on `main` stay until CT-6 shows they are unnecessary.
- For the next agent: the paused chat motion system plan touches the same rows and animations; sequence it after CT-5. The simplification program's IOS-CHAT scoping should account for CT-5 and CT-6.

### CT-2 correction · Done · 2026-09-26 · chat scroll investigation session

- Result: corrects the CT-2 entry above after review. The two measurement fixtures now run only in the `ui-validation` tier (`UnitTests.xctestplan` skips them), so they add no time or failure risk to the default unit gate. The keyboard-cycles shape submits a prompt in each of its three cycles, but the recorded runs show one tail materialization (`materialize:1`); the entry's claim that each cycle carries a send is withdrawn until CT-10 explains it. The 180,064 pt estimate is compared with no measured history height; the "~9,000 pt history" figure belonged to a different fixture.
- Evidence: review of `ct-8-2-baseline` (P1 items 1-3, P2 item 5).
- Changes: `packages/ios-app/TestPlans/UnitTests.xctestplan`, `packages/ios-app/docs/development.md`, the shape comment in `ChatViewScrollHarnessTests`, this plan.
- Tasks added: CT-10.
- For the next agent: the review's remaining P2 items (probe trace and diagnostic ring bounds can undercount `reDerivations` and `tailDisplacements` without saying so; `maxEstimateRatio` is a swing, not a truth ratio) belong to CT-10.
