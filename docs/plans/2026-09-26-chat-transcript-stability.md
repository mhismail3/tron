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
| CT-10 | Done | Complete the baseline CT-2 trimmed: frame cost (chat performance signposts and display-link frame intervals) during streaming, sends and scrolling on `main`, the tall-reply-at-the-tail and 180+ row shapes, and why only the first of three submissions in the keyboard-cycles shape materialized a tail (`materialize:1`). CT-5 may not ship until CT-10's frame cost exists to compare against | CT-1| chat scroll investigation session, 2026-09-27 |
| CT-11 | Ready | Parallel test lanes: `scripts/tron-ios-test` picks a free owned simulator from a small pool (each with its own lease and state directory) instead of one shared simulator, so concurrent worktrees stop queueing; `clean` removes only its own lane's simulator and never another lane's retained runs; document the lane count against CPU and memory, and check the hosted timing fixtures under two concurrent lanes | CT-1 | |
| CT-3 | Done | Prototype A on a throwaway branch: segment long assistant content at Markdown block boundaries into bounded physical rows, with pinning from visible row identity; measure against CT-2. The prototype does not need product polish, but it must show whether the blank and the estimate swing disappear | CT-2 | chat scroll investigation session, 2026-09-26 |
| CT-12 | Done | Visual parity gate: a hosted frame-recording suite that captures today's chat (send, keyboard up/down, streaming growth, queued-card replacement, tool chips, long history open, earlier-page load, detached reader and catch-up) as reference frames and compares any candidate transcript container against them within a stated tolerance; the recorded reference comes from `main` before any container change | CT-1 | chat scroll investigation session, 2026-09-26 |
| CT-13 | Done | Option C prototype: replace the transcript `LazyVStack` with an eager stack over the existing bounded source window (at most 512 items) on a throwaway branch; measure blank boundaries, estimate error, opening time, frame cost and memory at 150, 300 and 512 heavy rows | CT-2 | chat scroll investigation session, 2026-09-26 |
| CT-4 | Done | The user chose B (a `UICollectionView` container hosting the unchanged SwiftUI rows) after CT-13 rejected C on cost and CT-12 provided the parity gate | CT-12, CT-13 | chat scroll investigation session, 2026-09-26 |
| CT-14 | Done | Motion parity: extend the CT-12 gate to capture every display frame during transitions (send entrance, keyboard, composer collapse, streaming growth, queued-card shrink, tool chip), so a 14 pt instead of 20 pt entrance rise fails; record the new reference from `main` before any container change | CT-12| chat scroll investigation session, 2026-09-27 |
| CT-21 | Ready | Unit plan skip list: `UnitTests.xctestplan`'s `skippedTests` is not honored for Swift Testing tests, so any Swift Testing entry in it runs in every unit run. Find those entries, move each to `UIValidationTier` or a real fix, and delete the list entries that do nothing | CT-10 | |
| CT-15 | Done | Container design: a written design, reviewed before code, for the `UICollectionView` container hosting the unchanged SwiftUI row views through `UIHostingConfiguration`: exact self-sizing and a per-row height cache keyed by row identity and width; bottom anchoring owned by the layout (content offset preserved from the bottom across inserts, size changes and keyboard insets); the current `ChatScrollCoordinator` contract mapped item by item to the container (pinned and detached modes, catch-up, prepend anchoring, opening position, unread tracking); how a row's animated height change (entrance growth, streaming growth, queued-card shrink) drives the cell height in the same frame; row identity and entrance leases; keyboard and composer inset ownership; accessibility, context menus and scroll-edge chrome. Lists every coordinator mechanism the container retires | CT-4| chat scroll investigation session, 2026-09-27 |
| CT-20 | Done | Spike on a throwaway branch: settle CT-15's four unverified assumptions with a minimal container hosting the real row views, judged by the CT-12 and CT-14 gates and CT-10's numbers. Starts after the user approves CT-15 | CT-15, CT-14, CT-10| chat scroll investigation session, 2026-09-27 |
| CT-25 | Ready | Oracle foundation, on `main` before any CT-23 judgement: window-coordinate bottom-band, newest-row and composer helpers replace every scroll-space tail/visibility helper; real-scroll detach driver; a safe-area keyboard scenario (`additionalSafeAreaInsets` on the keyboard curve plus multi-line composer growth); motion-direction probe; short-transcript and oldest-row parity scenarios; parity manifest records its source revision; blank counts and recorder truncation fail runs; scale and profiler drivers use the window helpers. Each proven on `main` with a negative control | none | |
| CT-26 | Ready | Hot-path foundation, on `main`: one stable transcript actions object and synthesized-Equatable per-row inputs (no closures into row hosts); `ChatView` observation split (projection driver, composer, installed-commit observer as their own views); one `ChatPhysicalRowIndex` per install owning row order; observation granularity (delete `displayedSemanticIDCount`, guard entrance-set writes, pass per-row entrance state down, evidence bookkeeping not observed); equality fast paths and per-install precomputation; render-count budgets in `scripts/tron-profile ios` scenarios; hosted probes mounted only under a hosted probe | none | |
| CT-27 | Ready | Row stability foundation, on `main`: entrance clip keeps one view structure; growth host owns height only while streaming; `ThinkingBlock` and display-card disclosure and prompt replacement move from measure-to-state loops to custom `Layout`s; display disclosure state store-owned; inline display loads per identity with reserved heights and retry; canonical-prompt branch switch removed; notification pill single structure; row-owned sheet routes hoisted; a row-stability E2E fixture with a per-mount resize counter | none | |
| CT-28 | Ready | Record-only invariant monitor in the product (pinned bottom band uncovered for more than 2 frames, detached anchor moved without input, opening revealed uncovered), deduplicated, reaching device exports and surviving relaunch; delete the noisy tail-edge trace records; write the missing send-choreography device checklist in `development.md` | CT-25 | |
| CT-24 | Claimed | Field-shape fixtures: the two 2026-09-28 device incidents as hosted journeys, (a) foreground resync that installs new rows under tall newest replies, (b) a send in a transcript whose newest replies are very tall, followed by several assistant rows; with an orientation-independent blank oracle (window coordinates), and proof that today's path goes blank in both | none | chat scroll session, 2026-09-28 |
| CT-23 | Claimed | Origin-anchored transcript spike: the transcript's scroll view is flipped so its content origin is the visual bottom, rows are counter-flipped and ordered newest first; judged by every yardstick plus the risk probes in Task details | CT-24 | chat scroll session, 2026-09-28 |
| CT-22 | Claimed | Exact tail prototype (keep the SwiftUI `ScrollView`, rows and animations): measure two ways of making the pinned bottom exact on a throwaway branch. (a) Previously measured rows keep their last measured height when they leave the viewport. (b) The newest rows render in an eager stack below a `LazyVStack` of older history, so the bottom and everything near it are measured, never estimated; the boundary moves in coarse steps so rows rarely change parent. Judged by the CT-2 fixtures, the parity gate, the harness and CT-10's scale numbers | CT-20 | chat scroll investigation session, 2026-09-27 |
| CT-16 | Needs scoping | Build the container beside today's `LazyVStack` transcript behind a single development switch; no row, composer or animation code changes. Split into rows by CT-15 | CT-15, CT-20 | |
| CT-17 | Needs scoping | Qualification: with the switch on, the CT-12 and CT-14 gates pass against the `main` reference, the CT-2 fixtures and a 512-row blank fixture read zero blank boundaries, every `ChatViewScrollHarnessTests` visible invariant holds, and frame cost, opening time and memory at 150, 300 and 512 heavy rows are no worse than CT-10's baseline | CT-16, CT-14, CT-10 | |
| CT-18 | Needs approval | Device comparison: the user runs both containers on the phone through the send, keyboard, streaming, long-session and resume checklist and approves the cutover | CT-17 | |
| CT-19 | Needs scoping | Cutover: make the container the only transcript, then delete the `LazyVStack` path and the compensations it needed, one per commit, each with its tests, trace events and docs (materialization lease and fail-open, 1 pt entrance footprint, lazy-realization opening proof, layout-epoch frame invalidation, tail-affordance overlap, past-end repair and physical tail repair if CT-17 shows them unused); update `packages/ios-app/docs/architecture.md` and `packages/ios-app/docs/development.md` | CT-18 | |
| CT-7 | Needs scoping | Final device validation with the user after cutover: the send choreography checklist in `packages/ios-app/docs/development.md`, plus long sessions with tall replies across keyboard, foreground and resume | CT-19 | |

## Task details

### CT-15 — transcript container design (proposed for review)

**Principle.** Replace only the transcript's scroll container. Every row view,
the composer, the opening cover, the top blur and every animation stay the
same SwiftUI code. The container owns three things SwiftUI's lazy stack
estimated: each row's measured height, where the bottom is, and which rows are
on screen. No content estimate may decide the visible position.

**Structure.** `ChatView` keeps its layout: the composer as the only bottom
safe-area inset, the top blur overlay, the floating display overlay and the
opening cover over the transcript. The `ScrollView { VStack { LazyVStack … } }`
in `ChatTranscriptScrollView` is replaced by a `UIViewControllerRepresentable`
around a `UICollectionView` with one custom `UICollectionViewLayout`. Each
physical row becomes one item, keyed by its existing physical row ID in a
diffable data source. A cell hosts that row's existing SwiftUI content (the
same `physicalRowHost` builder, unchanged), with the SwiftUI environment
forwarded explicitly, as `ChatMessageContextMenu.swift` already does for its
nested host. The "earlier messages" button is the first item. The 12 pt top
padding and the 12 pt tail space become section insets, so spacing is
identical.

**Sizing (exact, not estimated).**
- A row's height is measured by its own SwiftUI content when it is realized and
  cached by physical row ID and width. It is re-measured when its payload or
  animated height changes, and invalidated on width or Dynamic Type changes.
- A row never realized has a height estimate per row kind (user prompt,
  assistant text by length, tool run, notification), never an average over
  measured rows. Estimates only affect rows far from the viewport, and the
  layout compensates for them (next point), so they can never move what is on
  screen.
- Content-size changes above the viewport are applied with an equal offset
  correction in the same layout pass, so visible rows never move when an
  off-screen height becomes known.

**Anchoring (owned by the layout, synchronous).**
- Pinned: every layout pass places the content so the last item's measured
  bottom sits at the visible bottom (above the composer and keyboard insets).
  Content growth, row height animations and inset changes are absorbed in the
  same pass. There is no marker, no settlement proof and no repair: the bottom
  is computed from measured rows, not estimated.
- Detached reader: every pass keeps the reader's top visible item at the same
  screen position (item-relative), so streaming, estimate corrections and
  keyboard changes do not move what they are reading.
- Prepend: the same item-relative rule keeps the pre-load anchor row in place,
  replacing the current offset corrections and their deadlines.
- Opening: the first layout pass is already positioned at the bottom, before
  the first displayed frame. The opening cover and its fade and rise stay
  unchanged; its positioning proof becomes a single synchronous check.

**Motion.** Rows keep their SwiftUI animations. The container's job is to
follow a row's animated height every frame in the same transaction, so a
growing row pushes its neighbors exactly as it does today while a pinned tail
stays still. This is the design's main risk (see CT-20). If a SwiftUI hosting
cell does not report its animated height per frame, the fallback is for the
container to drive that row's cell height on the same curve the row uses; that
fallback must still pass the CT-14 motion gate.

**Interaction.** `UIScrollViewDelegate` provides exact dragging,
deceleration and scroll-to-top events, replacing today's inference from
geometry samples (the status-bar heuristic, `isPositionedByUser`,
rubber-band tolerance checks). Interactive keyboard dismissal, disabled
scrolling before ready, and the iOS 26 soft scroll-edge effect are set on the
collection view directly.

**Coordinator mapping.** `ChatScrollCoordinator` keeps what is policy and
loses what compensated for estimates:
- Keeps: the pinned and detached viewport modes and their reducer, unread
  tracking and the catch-up button (a smooth scroll to the bottom), history
  paging admission, the send `ChatLayoutTransaction`, entrance receipts in the
  presentation store, opening phases.
- Retires after cutover (CT-19): the tail marker and its classification,
  tail materialization leases and their fail-open, physical tail repair,
  past-end repair, layout-epoch frame invalidation, semantic frame caching for
  anchors, prepend and restore offset corrections and their deadlines, the
  opening marker proof and its retry budget, the 1 pt entrance footprint and the
  12 pt affordance overlap.

**Coexistence.** Both containers exist behind one development switch until
cutover. Row wrappers that publish SwiftUI scroll-space geometry
(`stableRow`'s geometry observation) are disabled in the new container, which
reports exact frames itself. No other shared code changes.

**Unverified assumptions (CT-20 must settle them before CT-16).**
1. A SwiftUI row hosted in a cell reports its height every animation frame for
   the entrance growth layout, the streaming growth host and the queued-card
   interpolation.
2. The hosting approach supports rows that contain
   `UIViewControllerRepresentable` (message context menus). If
   `UIHostingConfiguration` does not, cells host a reused `UIHostingController`
   with view-controller containment instead.
3. The iOS 26 navigation bar and scroll-edge integration behave the same with a
   `UICollectionView` inside the SwiftUI `NavigationStack`.
4. Opening, scrolling and streaming with 512 heavy rows cost no more than
   CT-10's baseline.

### CT-23 — origin-anchored transcript (design, 2026-09-28)

Why the bottom is unreliable today. Apple's WWDC26 session 321 ("Dive into
lazy stacks and scrolling with SwiftUI") states the mechanism: a lazy stack
lays out from its start, estimates every unloaded subview from the average of
those it has placed, and corrects the estimated space as it learns; the content
offset at the stack's start is exact, while its end, its total height and any
absolute offset are estimates. The session advises against depending on the
absolute content size or offset. Today's transcript anchors the newest message
at the stack's end, so the pinned bottom is computed from estimates; with tall
newest replies the device measured 5x (resync) and 17x (send) overestimates,
and the coordinator's compensations (tail materialization, physical-tail
repair, past-end net, opening-tail settlement, prepend restoration) chase them
after the fact and correctly stand down when the reader touches the screen.

The design. Put the newest message at the stack's start. The transcript
`ScrollView` is flipped vertically, each row is flipped back, and rows are
ordered newest first. The pinned bottom is then the content origin, which the
lazy stack lays out exactly and which does not depend on any estimate; history
the stack has not loaded lies beyond the viewport, where estimates only size the
scroll range. This is the established structure for chat: Telegram rotates its
`ListView` and every item, Exyte Chat rotates a `UITableView` so offset 0 is the
newest message, Stream's SwiftUI SDK (v5, 2026) flips a `ScrollView` and
`LazyVStack`, and React Native's inverted `FlatList` does the same.

What it makes structural rather than compensated:

- pinned follow, streaming growth and entrances: the newest row sits at the
  origin, so growth pushes history away from the anchor and the anchor never
  moves;
- opening: the first frame is already at the bottom, with no positioning pass;
- older history: it appends at the far end, so a prepend moves nothing on
  screen;
- detached reading: the reader's rows are exact once placed, the live
  projection stays frozen while detached (existing behaviour), and scroll
  position anchoring uses a visible row, never an estimate.

What it costs, each validated before production:

1. Safe areas and the keyboard: insets apply before the flip, so the composer
   and keyboard inset and the navigation inset must be applied as swapped
   content margins, and must track the keyboard's animation frame for frame.
2. Context menus: the row's UIKit context-menu interaction and its preview must
   be upright and lift in place.
3. Scroll edges: the soft scroll edge effect, `TronTopBlurOverlay` and the
   navigation chrome must look as today.
4. Accessibility: VoiceOver reading order and three-finger scroll direction
   must match today (published flipped lists get the scroll direction wrong);
   the status-bar tap must scroll to the oldest loaded history as today.
5. Motion: entrance rise and fade, streaming growth, tool chips, queued-card
   cross-fade and shrink, composer collapse and the opening reveal unchanged.
6. Interaction: text selection, links, sheets, interactive keyboard dismissal,
   rubber band at both ends.
7. Performance: at least the CT-10 baseline.

What it deletes at cutover (CT-19): the compensations listed above and the
CT-22 tail band, which exist only because the anchor was estimated.

Monitoring that stays: the interaction trace, plus an invariant monitor in the
product that records an anomaly with full state whenever a pinned transcript
shows no row at the visual bottom for more than two display frames, so a future
regression is named in the next device export.

Acceptance: 0 blank boundaries in every CT-2 shape and both CT-24 field shapes,
three runs each; the CT-12 parity gate 7/7; CT-14 motion evidence unchanged;
CT-10 numbers equal or better; each risk above passed by a hosted probe or,
where only a device can show it, on the CT-7 device checklist.

### CT-23 blueprint — findings of the 2026-09-28 audit

Five read-only reviews (scroll ownership, hot path, row stability, external
implementations, tests and observability) checked the design against `main`.
They changed the order of work: the current gates cannot judge a flipped
transcript, and several foundations are worth landing on `main` first because
they make today's chat faster and steadier and shrink the flip itself.

Gates before judgement (CT-25). Today's tail and visibility helpers measure
scroll-view offsets against the estimated content size, so after a flip they
point at the oldest history, and on today's path they call a blank screen
aligned. The parity gate drives the keyboard by resizing the window, which
never exercises the inset path a flip changes; detached-reader tests use
hand-written geometry rather than a real scroll; motion direction is not
checked, so a flipped 8 pt opening rise would pass as a drop. CT-25 fixes all of
these on `main`, where each new oracle must pass and must flag the known blank.

Orientation design (CT-23), settled by the audit:

- One orientation owner: the flip on the scroll view, one counter-flip as the
  outermost modifier of each `ForEach` element, newest-first order in the row
  index at the data level, a geometry adapter whose distance-from-newest is the
  exact visible origin, and the mapping of commands to edges. The coordinator
  speaks only newest and oldest.
- Insets: an unflipped `GeometryReader` reads the safe-area insets (composer,
  keyboard, navigation) in the same layout pass; the flipped scroll view ignores
  the vertical safe areas and re-applies them swapped with `safeAreaPadding`,
  so they stay scroll insets and ride the keyboard's transaction
  (`contentMargins` is the fallback). No state hop.
- Modifiers that assume orientation move with the owner: the 12 pt top
  padding, the opening 8 pt offsets, the bottom anchors, the tail affordance,
  the earlier-messages row.
- Detached readers anchor by row identity (`ScrollPosition` view ID), not by an
  edge, so neither expansions nor far-end estimates move the reader.
- Context menus: both mechanisms (the UIKit prompt menu and the SwiftUI
  display-card menus) get an explicit window preview target if the probe shows
  a flipped lift.
- Scroll edge effect: keep the chat top blur unflipped; hide the composer-edge
  effect only if iOS 26/27 shows snapshot artifacts.
- Status-bar tap and VoiceOver order: user decisions (handoff below).

What production deletes, once CT-25's gates pass with each mechanism disabled:
tail materialization, physical-tail repair, the past-end net and target-free
rebase (with their command origins, traces and harness counters); opening-tail
positioning, marker and terminal-row proofs and the post-reveal stability loop
(opening becomes install, one frame, reveal); prepend offset correction
(older rows append at the far end); the `ScrollPosition` lease and release
protocol (three destinations remain: newest, a row, none); the coordinator's
entrance-settlement relay; `layoutTransactionInFlight`; the relative layout
restore once the detached freeze proves it unreachable; test-only production
surface in `ChatLayoutTransaction`. What stays: the viewport mode reducer as the
core of one phase enum (opening, pinned, detached, catch-up, prepend), the
detached-reader freeze, the store-owned entrance ledger, the layout
transaction's single clock, activation and epoch fences, and the opening
reveal animation.

### CT-22 round 2 — height-bounded exact tail (design)

Principle: exact where the reader can see, lazy everywhere else. The cost must
scale with what is on screen, not with the row count. Round 1 (variant B above)
proved the structure removes the blank; its cost and misalignment came from a
row-count window (48 heavy rows is about 60,000 pt of eager layout, while today
mounts three or four rows) and from today's alignment code not recognising
eager rows.

1. **The window is measured in points.** Let `V` be the tallest content viewport
   the transcript can have (keyboard hidden). The window is the smallest suffix
   of the newest rows whose measured height reaches `T = 2V` (the viewport plus
   one viewport of prefetch margin). It shrinks only when it exceeds `T + V`,
   and then drops whole rows from its top until it is back at or above `T`. A
   single 1,300 pt row can be the whole window; forty one-line rows can too. With
   heavy rows that is two to four eager rows, close to what today mounts.
2. **Heights come from the existing row frame publication**
   (`ChatSemanticFrameObservation`), not a new channel. Eager rows are always
   measured. A row with no measurement counts as unknown, and the window never
   shrinks past an unknown row.
3. **One owner.** The boundary is scroll presentation state, so the coordinator
   owns it: it already owns pinned and detached state, the viewport, the drag
   phase and the row frames. The decision is one pure function of those inputs;
   the view only renders the split. There is no view-local window state.
4. **A row changes stack only when nobody can see it.** Boundary moves happen
   only while the transcript follows the bottom, with no drag or deceleration in
   progress, and only for rows whose frames lie wholly above the viewport top by
   at least the prefetch margin. Otherwise the move is deferred and re-evaluated
   on the next geometry change; there are no timers. While a reader is detached
   the boundary is frozen, except that newly arrived rows join the window at its
   end as always. The hysteresis band keeps a decision from reversing itself, so
   a geometry pass cannot cycle.
5. **Opening.** The opening cover already hides frames until the transcript is
   ready. The first pass seeds the window with a few newest rows; after it, the
   measured eager rows and the lazy rows realised in the viewport give the
   heights for one correction to the band, and readiness waits for that
   correction. Seed size is chosen by measurement.
6. **Fix the evidence, not the symptoms.** Where round 1 misaligned (resting
   bottom 40 pt off, a long opening 2,083 pt off, tail materialization evidence
   that stopped firing), the cause is that today's alignment code expects lazy
   rows. The fix makes that code's evidence correct for eager rows. It adds no
   eager-only repair. Compensations that become dead are listed for CT-19 and
   are not deleted in the prototype.
7. **Row state.** A row that changes stack remounts and loses view-local
   `@State`. Every user-visible piece of row state (expansion, selection, loaded
   media, caches) must be store-owned or shown to be harmless when a row
   remounts off screen.

Acceptance, measured on one lane against today's path:

- zero blank boundaries in both CT-2 shapes and a new short-row shape (many
  one-line messages with keyboard cycles), three runs each;
- first ready frame no more than 1.15× today at 150, 300 and 512 rows (median of
  three), streaming frame-interval median no worse, worst send frame no more
  than 1.2×, scroll step no more than 0.3 ms worse, memory no more than 5% higher;
- parity gate 7/7, scroll harness 54/54, per-boundary tail continuity no worse;
- no row changes stack on screen and no entrance replays, for tall and short
  rows.

Stop rule: if the opening stays above 1.3× today, or parity or the harness can
pass only through eager-only repairs, stop and report.

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
- Changes: this commit (`packages/ios-app/Sources/UI/Chat/ChatHostedProbe.swift`,
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

### CT-3 · Done · 2026-09-26 · chat scroll investigation session

- Result: option A (bounded rows) reduces the estimate swing but does not remove it or the blank, so it is not the fix. Long assistant text was cut into rows of at most about 1,200 bytes or 30 lines at paragraph breaks outside code fences, with long fences split into consecutive fences. After a keyboard dismissal the lazy stack still re-derived its estimate to about 38,000-51,500 pt for 8,800-12,100 pt of real content, and the pinned viewport followed the eager marker to that phantom bottom while every row was far above it. Whether a sampled boundary lands in the phantom region is timing, so blank counts vary between runs while the geometry is wrong in each.
- Evidence (prototype branch `ct-3-segment-prototype`, commits `f67d92c0b` to `496910745`, not merged; the last three measurement runs on a private simulator lane):

  | Metric | `main` baseline | Prototype, 3 runs |
  | --- | --- | --- |
  | many-tall blank boundaries | 12/72 | 0/72, 0/72, 0/72 (32/72 in 5 of 7 earlier runs on the shared lane) |
  | many-tall estimate maximum | 180,064 pt | 51,972-53,742 pt |
  | keyboard-cycles blank boundaries | 80/340, 140/340 | 40/340, 0/340, 0/340 |
  | keyboard-cycles estimate maximum | 63,819 pt | 31,547-37,610 pt |

  `ChatViewScrollHarnessTests` 55/55; full unit target 1,711 tests, 0 failures. A new hosted fixture showed a streamed segmented reply keeps one host per segment, takes one entrance and remounts nothing at canonical settlement.
- Changes: none on `main`; the prototype branch stays for reference.
- Kept on purpose: nothing from the prototype. It adds a segmentation owner, copy-menu and accessibility gaps and entrance rules without removing the cause.
- Deviations: pinning from visible row identity (`onScrollTargetVisibilityChange`) was tried and reverted. The callback never fired in the hosted harness with either placement, and deciding pinning differently would still leave the viewport pinned to an estimated bottom.
- For the next agent: CT-4 now chooses between B and a new option C, an eager, non-lazy stack over a bounded recent window with history paging. C removes estimation entirely at a layout cost that must be measured.

### CT-4 scoping · Done · 2026-09-26 · chat scroll investigation session

- Result: the user requires no visible UI change and a dependable result. Option A is ruled out by CT-3. The remaining choice is C (keep the SwiftUI rows, replace the lazy container with an eager one over the existing bounded window) or B (a `UICollectionView` container hosting the unchanged SwiftUI rows). An earlier UIKit rewrite (`agent/uikit-chat-rewrite`, reverted in `132aa9858`) re-implemented the rows and composer in UIKit and lost visual parity, so B here keeps every SwiftUI row and only replaces the container.
- Tasks added: CT-12 (visual parity gate, required before any container ships) and CT-13 (option C prototype and measurement). CT-4 now depends on both.

### CT-13 · Done · 2026-09-26 · chat scroll investigation session

- Result: an eager `VStack` over the whole loaded window removes the blank and the estimate swing completely, but it cannot carry the window: 300 and 512 heavy rows never reached a ready frame inside the product's 30-second opening deadline, and 150 heavy rows opened in about 2.3 s instead of 0.35 s. Option C as specified is therefore rejected on cost.
- Evidence (prototype branch `ct-13-eager-prototype`, commits `73f56edcd` to `d9e8e6856`, not merged; simulator lane CT13; one invocation per shape per side, simulator timings indicative only):

  | Metric | Lazy (`main`) | Eager |
  | --- | --- | --- |
  | many-tall blank boundaries, 3 runs | 44/72, 0/72, 12/72 | 0/72 x3 |
  | keyboard-cycles blank boundaries, 3 runs | 80/340 x3 | 0/340 x3 |
  | estimate swing (max/min) | 1.7-4.2 | 1.0 |
  | 150 heavy rows: first ready frame | 351 ms | 2,304 ms |
  | 150 heavy rows: memory at ready | +36 MB | +247 MB |
  | 150 heavy rows: scroll step median | 0.8 ms | 4.8 ms |
  | 300 / 512 heavy rows: first ready frame | 368 / 486 ms | never (30 s deadline) |
  | lazy content estimate after a send, 512 rows | 212,363 pt for 113,117 pt | measured, not estimated |

  `ChatViewScrollHarnessTests` on eager: 49/54; four failures assert the lazy materialization lease (their visible invariants held), one (`maximumRowOpeningNeverPresentsBlankViewport`, 275 light rows) timed out at 10 s against 0.58 s lazy.
- Changes: none on `main`.
- For the next agent: the prototype's code reading lists the coordinator mechanisms an exact-height container would make unnecessary (materialization lease and its fail-open, 1 pt entrance footprint, lazy-realization opening proof, layout-epoch frame invalidation, tail-affordance overlap). Physical tail repair and past-end repair were not shown redundant by these measurements.

### CT-12 · Done · 2026-09-26 · chat scroll investigation session

- Result: a visual parity gate exists on branch `ct-12-parity-gate` (commits `e23e0f388`, `3241da2be`, `10521718a`, not yet merged). `ChatVisualParityTests` drives the real `ChatView` through seven deterministic scenarios (long history at rest, send with keyboard contraction and dismissal, streaming growth, queued-card replacement, tool chip, earlier-page load, detached reader and catch-up), fingerprints every rendered display boundary (per-2 pt row bands and per-8 pt column bands of luminance), and compares against a committed 91-frame manifest; it writes a JSON report naming the worst frames.
- Evidence: three runs on unchanged code pass; stable-frame noise at most 0.0068 (bound 0.014), in-transition frames at most 0.047 (bound 0.060). Negative controls: row spacing 8 to 10 pt fails all seven scenarios; Markdown as plain text fails six of seven. An entrance rise of 14 pt instead of 20 pt is not detected, because the harness samples about every 110 ms and skips most frames of a 280 ms entrance; motion parity therefore still needs a device check (CT-7). Gate runtime 44-50 s; full unit tier 1,913 passed, 0 failures, gate skipped there.
- Deviations: motion sensitivity is below the requirement; layout and rendering sensitivity meet it.
- For the next agent: merge CT-12 before any container change so its manifest is the reference; improving motion sampling (per-frame capture during transitions) is worthwhile if B proceeds.

### CT-4 · Done · 2026-09-27 · chat scroll investigation session

- Result: the user chose B. A `UICollectionView` container will host the existing SwiftUI row views unchanged and own sizing and bottom anchoring, so no content estimate decides where the transcript's bottom is. It is built beside today's transcript behind a development switch and replaces it only after the parity gates, the blank fixtures, a performance comparison and the user's device approval.
- Evidence: CT-3 (bounded rows keep the swing and the blank), CT-13 (an eager container removes both but cannot open 300 heavy rows inside the 30-second deadline), CT-12 (parity gate on `main` as `edab6b36e`).
- Changes: tasks CT-5 and CT-6 are superseded by CT-15 to CT-19; CT-7 now follows the cutover.
- Tasks added: CT-14 to CT-19.
- Kept on purpose: the earlier UIKit rewrite (`agent/uikit-chat-rewrite`, reverted in `132aa9858`) re-implemented rows and the composer in UIKit and lost visual parity. This plan forbids changing row, composer or animation code in CT-16, and CT-17 gates the cutover on the recorded `main` reference.
- For the next agent: start with CT-14 and CT-10 (independent), and CT-15's design in parallel. CT-15 is reviewed by the user before CT-16 starts.

### CT-15 · Claimed · 2026-09-27 · chat scroll investigation session

- Result: design drafted in Task details from a contract map of the current transcript (every input, callback, scroll behavior, row-height animation, chrome dependency and per-row state). Awaiting the user's review; CT-20 and CT-16 do not start before approval.
- Changes: this plan; CT-20 added.
- Kept on purpose: the send `ChatLayoutTransaction`, entrance receipts, viewport modes and catch-up are policy, not estimate compensation, and survive.
- For the next agent: the four unverified assumptions decide whether B is feasible without touching row code. Assumption 1 is the largest risk.

### CT-10 · Done · 2026-09-27 · chat scroll investigation session

- Result: the baseline a new container must match or beat, on unchanged `main` product code, with the CT-13 scale fixture ported (no eager container).

  | Metric, median (spread) of 3 runs | 150 heavy rows | 300 | 512 |
  | --- | --- | --- | --- |
  | first ready frame | 324 ms (314-336) | 350 ms (347-358) | 475 ms (461-489) |
  | memory at ready | 497 MB | 583 MB | 613 MB |
  | scroll step median / max | 0.8 / 2.0 ms | 0.8 / 1.7 ms | 0.8 / 1.9 ms |
  | streaming frame interval median; frames over 33 ms | 33 ms; 55 of 90 | 50 ms; 59 of 90 | 50 ms; 62 of 90 |
  | send: worst frame interval | 175 ms | 404 ms | 637 ms |
  | blank boundaries in a keyboard cycle | 0/60 | 0/60 | 0/60 |

  Simulator timings are indicative and comparable only to each other.
- Evidence: runs `20260927T022805Z-run.wZRqcQ`, `20260927T022856Z-run.k9IXsJ`, `20260927T022947Z-run.i2Z35V` under `~/Library/Developer/Tron/ios/test-runs/`.
- Changes: merged in `4f94188f3` with CT-14. The CT-2 keyboard-cycles fixture never acknowledged its first send, and the composer correctly refuses a new prompt while one is unreconciled; with the acknowledgement all three sends materialize (four runs; the negative control without it fails). `CT2-METRICS` now reports whether its bounded buffers were truncated.
- Deviations: `UnitTests.xctestplan`'s `skippedTests` is not honored for Swift Testing tests, so the CT-2 fixtures and the CT-12 gate had been running in every unit run, contrary to the CT-2 correction entry and the CT-12 entry above. The merge replaces those list entries with one `UIValidationTier` gate; a full unit run reports all four suites skipped (1,709 tests pass) and the `ui-validation` tier runs them.
- Tasks added: CT-21.

### CT-14 · Done · 2026-09-27 · chat scroll investigation session

- Result: the parity gate captures every driven boundary through each transition (385 frames), at about 60 ms a boundary instead of 110 ms, against a reference re-recorded from unchanged code. Bounds: 0.025 for stable frames (measured worst 0.0050) and 0.065 for transition frames (measured worst 0.0528), from four runs.
- Evidence: row spacing +2 pt and Markdown as plain text fail seven of seven scenarios. Not resolved at this sampling floor: a 14 pt instead of 20 pt entrance rise, a 200 instead of 280 ms entrance, an instant queued-card shrink and an instant composer collapse. The forced screen update each sample needs costs about 40 ms, the harness cannot pause SwiftUI's animation clock, and the app commits its layer tree only a few times per transition, so a 280 ms entrance yields two to four samples.
- Deviations: the approved decision expected the instant-change controls to fail; they do not.
- For the next agent: exact entrance rise and duration, and the instant-change cases, stay on the CT-7 device checklist. For a container change, how a row's animated height is followed is judged by the hosted continuity evidence (native row frames per boundary, tail error, maximum rect step), not by this gate.

### CT-15 · Done · 2026-09-27 · chat scroll investigation session

- Result: the user approved the container design in Task details. CT-20, the spike that settles its four unverified assumptions, starts on a throwaway branch.
- Changes: this plan.

### CT-20 stage 1 · Blocked · 2026-09-27 · chat scroll investigation session

- Result: assumption 1 does not hold. A SwiftUI row hosted in a `UICollectionView` cell does not drive the cell's height during its own animation, by any of three hosting approaches or a per-display-frame measurement probe. The row's content animates inside the cell while the cell stays at its old height, jumps to the final height, or lags. So a container cannot follow a row's animated height by measuring it; it would have to drive the height itself on the row's curve, which means knowing every row animation's timing outside the row. Assumption 2 holds only for a reused `UIHostingController` with containment: under `UIHostingConfiguration` a user prompt row lost its context menu interaction and rendered at 18 pt instead of 44 pt.

  | Animation | Today (`LazyVStack`), pinned tail error | Best container approach, cell height versus row content | Container tail error |
  | --- | --- | --- | --- |
  | compact row entrance, 280 ms | 0.35 pt | 26 pt drift (cell jumps to final height) | 13-21 pt |
  | streaming growth | 0.80 pt | 101-134 pt drift (cell steps six times) | 52-77 pt |
  | queued-card shrink | 21.4 pt transient | 62 pt drift | 31 pt |

- Evidence: branch `ct-20-container-spike` (commits `f00e8ad0f` to `5ccd21e0c`, not merged; today's path unchanged with the switch off); run `20260927T073900Z-run.UAKWRO` with `ct20-spike-evidence.log` (15 measured journeys, 37-47 display boundaries each, native frames). The automated review step failed on a tool-permission error; the supervisor checked the claims against the evidence log and the diff.
- Changes: none on `main`.
- For the next agent: stage 2 did not run. The user decides how to proceed (see the options recorded when this is resolved).

### CT-20 · Done · 2026-09-27 · chat scroll investigation session

- Result: the user chose to keep today's SwiftUI container and fix only the estimated bottom (CT-22). Option B as designed in CT-15 is set aside because a hosted row cannot drive its cell's animated height (stage 1 above); CT-16 to CT-19 stay in the table until CT-22 shows whether they are needed.
- Kept on purpose: the spike branch `ct-20-container-spike` stays for reference.
- For the next agent: variant (a) cannot cover rows that were never measured (history above the tail on a fresh open), which is where the lazy stack's estimate comes from; variant (b) is the one expected to remove the blank. Its costs to measure are eager layout of the window and row remounts when the boundary moves (per-row `@State`, entrance receipts are store-owned and must not replay).

### CT-22 variant B · Measured · 2026-09-27 · chat scroll investigation session

- Result: an eager `VStack` of the newest 48 rows below a `LazyVStack` of older history removes the blank by construction, but fails on cost and on today's alignment code. Measured on lane CT22, three runs, switch on versus off:

  | Yardstick | Today | Eager tail, 48 rows |
  | --- | --- | --- |
  | CT-2 many tall replies, blank boundaries | 12/72 each run | 0/72 each run |
  | CT-2 keyboard cycles, blank boundaries | 20-123/340 | 0/340 each run |
  | Estimate swing | 1.7-4.2x | 1.0-1.2x |
  | First ready frame, 150/300/512 heavy rows | 356/390/560 ms | 1,320-2,232 / one of three never opened / 1,434-1,522 ms |
  | Streaming frame interval median | 33-50 ms | about 100 ms |
  | Parity gate | 7/7 pass | 4 of 7 fail, and rest tail error 39.7 pt |
  | Scroll harness | 54/54 pass | 26 issues in 9 tests (opening 2,083 pt off the bottom, tail-materialization evidence no longer fires) |
  | Tail error during entrance/streaming/shrink | 0.35/0.80/14-15 pt | 0.35/0.33/14-15 pt |
  | Rows changing stack on screen at a boundary move; entrance replays | n/a | 0; none |

  A 20-row window halves the opening cost but moves on-screen rows (39 events) and its harness run exceeded its deadline. A row-count window cannot suit both short and heavy rows.
- Evidence: branch `ct-22-exact-tail` (final commit `0cf021bb5`, switch default today's path); extracts `/tmp/ct22-evidence/`; run directories from `20260927T094401Z-run.v5MJIm` to `20260927T100831Z-run.aLyMHd`. Supervisor checked the CT-2 and scale figures against the extracts; no independent review yet.
- Deviations: variant A was not run; it cannot affect rows the stack never measured.
- For the next agent: the user decides the direction.

### CT-22 round 3 checkpoint · 2026-09-27 · chat scroll investigation session

- Result: the chat scroll coordinator no longer observes its per-frame layout evidence (row frames, scroll geometry, physical-tail evidence and repair bookkeeping). Row and scroll geometry callbacks run during layout and read and write those fields; no view body reads them, so observing them only let UIKit's layout observation tracking treat every callback as an invalidation of the hosting view. With several rows publishing per pass (the eager tail band) that produced `Observation tracking feedback loop detected` and repeated layout passes; after the change, five of five band runs had none.
- Evidence: `ChatScrollCoordinatorTests` and `ChatViewScrollHarnessTests`, 172 tests pass on `main` plus the change. The loop and its key paths are in the band runs' console (`[ObservationTracking] ... semanticFrames changed`).
- Changes: `ChatScrollCoordinator.swift` on `main`. The band itself stays on the throwaway branch `ct-22-exact-tail` (round 3: event-driven, boundary keyed by row identity, opening median 1.08x today). Open: streaming frame interval about 50 ms against 33 ms today; layout costs under 2 ms a frame on both paths, and main-thread time outside layout (28 ms a frame today, 38 ms with the band) is being measured.

### CT-22 round 3 streaming checkpoint · 2026-09-27 · chat scroll investigation session

- Result: `ChatTranscriptItems ==` now returns equal in O(1) for a commit compared with itself (shared buffers, equal overrides) and walks elements only otherwise (`1e90a8e02` on `main`). `scripts/tron-profile ios streaming-reply`: instructions -13.1%, beyond noise; `tool-loop` -3.0%, within noise. 369 transcript, coordinator and scroll-harness tests pass.
- Findings on the prototype branch `ct-22-exact-tail` (optimized hosted build, 150 heavy rows):
  - The simulator test host is a Debug build; timings of our own Swift code there overstate device cost several times. `scripts/tron-profile ios` (optimized `DevicePerformance`) is the instrument for decisions. In an optimized build, today's streaming frame interval is 16.7 ms median.
  - An eager band as a sibling below the history `LazyVStack` makes the history re-size several times per frame (about 10 layout passes per frame against 3), independent of band size or moves. With every row eager the passes return to normal, so the cause is the lazy history beside a growing eager sibling. The band as the lazy stack's last child keeps passes normal, opens faster than today (185-211 ms against 263-360 ms) and had 0 blank boundaries in every CT-2 run (keyboard cycles today: 80-120/340); unlike the sibling it is not exact by construction, since a lazy child's placement is SwiftUI's.
  - Every realized row host re-evaluated its body on every projection install (about 5,400 host bodies during 30 streaming tokens), because the host takes closures. A `ChatPhysicalRowBoundary` keyed by every non-observed row input cuts that to about 90; with it the band streams at 16.7 ms median and 33 ms p95. The key must include `admitsNativeCallbacks` (read by each row's geometry callback); with it the parity gate passed 7/7 twice. Not yet on `main`.
- Next: profile the row boundary on `main` with `scripts/tron-profile ios`, and decide the band with the user.

### CT-22 superseded pending CT-23 · 2026-09-28 · chat scroll session

- Result: two device incidents on 2026-09-28 (resync after subagent replies;
  a send) went blank with lazy-stack overestimates of about 5x and 17x, larger
  than any fixture. External research (Apple's WWDC26 session 321, Telegram,
  Exyte Chat, Stream's SwiftUI SDK) points to anchoring the newest message at
  the lazy stack's exact start instead of its estimated end; CT-23 tests that.
  CT-22 stays claimed on its branch until CT-23 settles which design ships.
- Evidence: device exports `e563c2ed3a251fa673b340c9d18146e7-2026-09-28T22-49-38-443Z`
  and `…T22-51-14-263Z`.
- Tasks added: CT-23, CT-24.


### CT-23 audit · 2026-09-28 · chat scroll session

- Result: the blueprint above. The CT-23 spike was stopped after CT-24's
  fixtures landed on its branch (`fc703f16e`, not yet on `main`): the audit found
  that its yardsticks would mismeasure a flipped transcript, so CT-25 comes
  first. CT-26 and CT-27 are independent of the flip and improve today's chat.
- Evidence: five review reports in the session's subagent artifacts (scroll
  ownership, hot path, rows, external implementations, tests).
- Tasks added: CT-25, CT-26, CT-27, CT-28.
- For the next agent: CT-23 resumes on its branch once CT-25 is on `main`, with
  the orientation design above; the status-bar and VoiceOver decisions are
  recorded here when the user makes them.
