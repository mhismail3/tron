# Chat transcript stability

- **Started:** 2026-09-26
- **Status:** Active
 - **Last updated:** 2026-09-29, CT-23 flip2 parity/row-stability root causes and bounded wakeup investigation
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
| CT-25 | Done | Oracle foundation, on `main` before any CT-23 judgement: window-coordinate bottom-band, newest-row and composer helpers replace every scroll-space tail/visibility helper; real-scroll detach driver; a safe-area keyboard scenario (`additionalSafeAreaInsets` on the keyboard curve plus multi-line composer growth); motion-direction probe; short-transcript and oldest-row parity scenarios; parity manifest records its source revision; blank counts and recorder truncation fail runs; scale and profiler drivers use the window helpers. Each proven on `main` with a negative control | none | chat scroll session (worker lanes), 2026-09-28 |
| CT-26 | Ready | Hot-path foundation, on `main`: one stable transcript actions object and synthesized-Equatable per-row inputs (no closures into row hosts); `ChatView` observation split (projection driver, composer, installed-commit observer as their own views); one `ChatPhysicalRowIndex` per install owning row order; observation granularity (delete `displayedSemanticIDCount`, guard entrance-set writes, pass per-row entrance state down, evidence bookkeeping not observed); equality fast paths and per-install precomputation; render-count budgets in `scripts/tron-profile ios` scenarios; hosted probes mounted only under a hosted probe | none | |
| CT-27 | Done | Row stability foundation, on `main`: entrance clip keeps one view structure; growth host owns height only while streaming; `ThinkingBlock` and display-card disclosure and prompt replacement move from measure-to-state loops to custom `Layout`s; display disclosure state store-owned; inline display loads per identity with reserved heights and retry; canonical-prompt branch switch removed; notification pill single structure; row-owned sheet routes hoisted; a row-stability E2E fixture with a per-mount resize counter | none | chat scroll session (worker lane ct-27-rows), 2026-09-28 |
| CT-28 | Ready | Record-only invariant monitor in the product (pinned bottom band uncovered for more than 2 frames, detached anchor moved without input, opening revealed uncovered), deduplicated, reaching device exports and surviving relaunch; delete the noisy tail-edge trace records; write the missing send-choreography device checklist in `development.md` | CT-25 | |
| CT-24 | Done | Field-shape fixtures: the two 2026-09-28 device incidents as hosted journeys, (a) foreground resync that installs new rows under tall newest replies, (b) a send in a transcript whose newest replies are very tall, followed by several assistant rows; with an orientation-independent blank oracle (window coordinates), and proof that today's path goes blank in both | none | chat scroll session, 2026-09-28 |
| CT-23 | Blocked | One orientation owner, single-sample geometry and read-time frame reflection retained; origin's inner/outer safe-area exclusion fixes detached viewport clipping without offset commands. Four bottom gates ×3 pass with zero blank/uncovered boundaries; pinned/detached keyboard and catch-up pass. Final clean `9d606ec1d`: today parity 10/10, origin 9/10 (original opened-history residual; ordinary-send remains borderline across runs), row stability 14/14 both after correcting test traversal/settlement. Parity capture snaps today's estimated end only, never an exact origin pin; negative control reproduces keyboard detachment. Display SwiftUI preview, accessibility/status-bar requirements, navigation fade decision and additional full-checkpoint failures still block production cutover. Optimized streaming wakeups remain an open production-performance item after bounded bisection/trace investigation, not a device-evaluation blocker. Today's path/default unchanged; no Gateway/device lifecycle action. See the consolidated CT-23 flip2 status below for clean revisions, measurements, controls and remaining decisions | CT-24 | chat scroll session (worker lane ct23b), 2026-09-29 |
| CT-22 | Claimed | Exact tail prototype (keep the SwiftUI `ScrollView`, rows and animations): measure two ways of making the pinned bottom exact on a throwaway branch. (a) Previously measured rows keep their last measured height when they leave the viewport. (b) The newest rows render in an eager stack below a `LazyVStack` of older history, so the bottom and everything near it are measured, never estimated; the boundary moves in coarse steps so rows rarely change parent. Judged by the CT-2 fixtures, the parity gate, the harness and CT-10's scale numbers | CT-20 | chat scroll investigation session, 2026-09-27 |
| CT-16 | Needs scoping | Build the container beside today's `LazyVStack` transcript behind a single development switch; no row, composer or animation code changes. Split into rows by CT-15 | CT-15, CT-20 | |
| CT-17 | Needs scoping | Qualification: with the switch on, the CT-12 and CT-14 gates pass against the `main` reference, the CT-2 fixtures and a 512-row blank fixture read zero blank boundaries, every `ChatViewScrollHarnessTests` visible invariant holds, and frame cost, opening time and memory at 150, 300 and 512 heavy rows are no worse than CT-10's baseline | CT-16, CT-14, CT-10 | |
| CT-18 | Needs approval | Device comparison: the user runs both containers on the phone through the send, keyboard, streaming, long-session and resume checklist and approves the cutover | CT-17 | |
| CT-19 | Needs scoping | Cutover: make the container the only transcript, then delete the `LazyVStack` path and the compensations it needed, one per commit, each with its tests, trace events and docs (materialization lease and fail-open, 1 pt entrance footprint, lazy-realization opening proof, layout-epoch frame invalidation, tail-affordance overlap, past-end repair and physical tail repair if CT-17 shows them unused); update `packages/ios-app/docs/architecture.md` and `packages/ios-app/docs/development.md` | CT-18 | |
| CT-7 | Needs scoping | Final device validation with the user after cutover: the send choreography checklist in `packages/ios-app/docs/development.md`, plus long sessions with tall replies across keyboard, foreground and resume. Also the row-state durability the hosted harness cannot force a real remount for: a collapsed inline display card that comes back collapsed, a row-owned detail sheet surviving the row being discarded (CT-27 F11), and F1's Liquid Glass press region | CT-19 | |

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

### User decisions for CT-23 · 2026-09-28 · chat scroll session

- Status-bar tap must keep scrolling to the oldest loaded history. CT-23 probes
  for a clean way; if only a private UIKit reach-in would do it, it comes back
  to the user before any code.
- VoiceOver: close is acceptable. Scroll direction must be correct and
  VoiceOver fully usable; small ordering differences within far history are
  acceptable.
- Order: foundations first. CT-25 and CT-27 now in parallel, then CT-26, then
  CT-23 against CT-25's gates.
- CT-24 completes inside CT-25: its fixtures (`fc703f16e` on the CT-23 branch)
  move to `main` with CT-25, and CT-24 closes with its repro runs there.

### CT-24 · Done · 2026-09-28 · chat scroll session (CT-25 stage A)

- Result: both 2026-09-28 device field shapes are hosted journeys and both
  reproduce the blank on today's pinned `LazyVStack` path, three runs of three.
  Shape (a) opens a 250-row history whose newest six replies are ~1,620 pt tall
  and replaces the authoritative snapshot with one carrying four more very tall
  replies — the reconnect resync that went blank on the phone. Shape (b) submits
  a prompt with the keyboard-sized viewport in place and publishes five
  assistant replies of uneven tall heights (1,900/1,620/1,140/1,330/670 pt) over
  60 boundaries without further input. Both sample the window-coordinate blank
  oracle (`onScreenRows`) and print one `CT24-METRICS` line.
- Evidence (`~/Library/Developer/Tron/ios/test-runs/`, lane ct25, products built
  from this worktree's own source state, three consecutive invocations
  `20260928T234000Z-run.0kvZhI`, `20260928T234056Z-run.93woFZ`,
  `20260928T234203Z-run.xuwAjE`; 4 tests, 14 s of tests, 37 s wall each):

  ```
  CT24-METRICS shape=resync-under-tall-newest samples=90 blankBoundaries=79/90 blankAfterSettle=78 longestBlankRun=79 blankPhases=p1:79 maxEstimateRatio=96.7 estimateOpen=102398.0 estimateMax=156683.0 measuredRowsAtMax=1 measuredHeightAtMax=1619.7 tallestRowHeight=1619.7
  CT24-METRICS shape=send-under-tall-newest   samples=68 blankBoundaries=29/68 blankAfterSettle=29 longestBlankRun=21 blankPhases=p1:29 maxEstimateRatio=206.7 estimateOpen=177661.0 estimateMax=236234.0 measuredRowsAtMax=1 measuredHeightAtMax=1143.0 tallestRowHeight=1859.0
  CT24-METRICS shape=resync-under-tall-newest samples=90 blankBoundaries=77/90 blankAfterSettle=77 longestBlankRun=77 blankPhases=p1:77 maxEstimateRatio=103.0 estimateOpen=102398.0 estimateMax=166810.0 measuredRowsAtMax=1 measuredHeightAtMax=1619.7 tallestRowHeight=1619.7
  CT24-METRICS shape=send-under-tall-newest   samples=68 blankBoundaries=24/68 blankAfterSettle=24 longestBlankRun=15 blankPhases=p1:24 maxEstimateRatio=205.5 estimateOpen=177661.0 estimateMax=234928.0 measuredRowsAtMax=1 measuredHeightAtMax=1143.0 tallestRowHeight=1859.0
  CT24-METRICS shape=resync-under-tall-newest samples=90 blankBoundaries=77/90 blankAfterSettle=77 longestBlankRun=77 blankPhases=p1:77 maxEstimateRatio=103.0 estimateOpen=102398.0 estimateMax=166810.0 measuredRowsAtMax=1 measuredHeightAtMax=1619.7 tallestRowHeight=1619.7
  CT24-METRICS shape=send-under-tall-newest   samples=68 blankBoundaries=12/68 blankAfterSettle=12 longestBlankRun=12 blankPhases=p1:12 maxEstimateRatio=111.4 estimateOpen=177661.0 estimateMax=215490.0 measuredRowsAtMax=1 measuredHeightAtMax=1905.7 tallestRowHeight=1905.7
  ```

  Both shapes reproduce a blank in 3 of 3 runs, so no shape was adjusted. The
  resync shape blanks the whole 80-boundary phase after the install (`p1:77` of
  80; the first two boundaries of a phase are its transition landing); the send
  shape blanks 12-29 of its 60-boundary growth phase. `measuredRowsAtMax=1`
  beside `maxEstimateRatio` 97-207x is the field incident's mechanism in the
  harness: the published estimate rests on a single measured 1,143-1,906 pt row.
  The same invocation's CT-2 shapes read 1-44/72 (many tall replies) and
  20-120/340 (keyboard cycles with sends) blank boundaries.
- Changes: the fixtures and their oracle landed in `904faeae2`
  (`packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`, cherry-picked
  from `fc703f16e` on the CT-23 branch); this entry.
- Deviations: the fixtures measure; they do not gate. CT-25 stage A turns their
  blank counts and bottom-band coverage into failing gates with an explicit
  expected-failure switch, and the estimate-only fields (`maxEstimateRatio`,
  `reDerivations`, `tailDisplacements`, `repairCommands`) stay until CT-23 lands.
  The `tailDistance` fields read 0.0 in the resync shape even while 79 of 90
  boundaries were blank — the scroll-space tail measurement is exactly what
  CT-25 stage A replaces.
- For the next agent: run both shapes with
  `TRON_IOS_TEST_LANE=ct25 TRON_IOS_TEST_TIER=ui-validation scripts/tron-ios-test run
  --only-testing 'TronMobileTests/ChatViewScrollHarnessTests/ct24ResyncUnderVeryTallNewestReplies()'
  --only-testing 'TronMobileTests/ChatViewScrollHarnessTests/ct24SendUnderVeryTallNewestReplies()'`
  (14 s of tests on top of a built lane).

### CT-25 stage A · 2026-09-29 · chat scroll session (worker lanes)

- Result: the scroll-space tail and visibility helpers are gone from every chat
  suite, replaced by one window-coordinate oracle, and the CT-2 and CT-24 field
  shapes now gate their bottom coverage instead of only measuring it.

  **The oracle.** `TranscriptWindowOracle` (in
  `Tests/UI/ChatViewScrollHarnessTests.swift`, used by the parity gate, the scale
  suite and the profiling scenarios) reports, in window coordinates: each mounted
  row's `windowFrame`, `isOnScreen`, `isInBottomBand` and `composerClearance`; the
  composer marker's top edge; the pinned bottom band (the 12 pt tail spacing plus
  24 pt above the composer); the newest mounted row's bottom edge; the fraction of
  the visible transcript the rows cover; `isPinned`/`pinnedError`. Its rects come
  from the layer chain (`CALayer.convert`), not `UIView.convert`, because SwiftUI
  applies its transforms on layers and CT-23's flip must be visible to the oracle.
  `scrollReader(byVisualPoints:)` replaces `displaceNativeTranscriptFromTail` and
  places the real reader that many visual points from the newest end (0 is the
  pinned bottom), reading the flip from the render tree so the same call means the
  same thing on CT-23's transcript. Deleted: `nativeTranscriptSignedTailError`,
  `nativeTranscriptDistanceFromTail`, `displaceNativeTranscriptFromTail`,
  `nativeGeometryMatches` and its `containsNativeTranscriptScrollView`, the
  scroll-space `NativeRow` (`frame`/`isVisible`/`tailGap`), `OnScreenRow`, and the
  CT-2 `ct2BlankShape` wrapper. ~60 call sites moved, including
  `ChatVisualParityTests`, `ChatTranscriptScaleMeasurementTests` and
  `ProfileChatScenarioTests.renderCheck` (which now decides `followed` through
  `TranscriptWindowOracle.isPinned`, the same implementation the harness tests).

  **Two legal pinned positions.** The transcript keeps a 12 pt tail affordance
  after its newest row and *overlaps* it while the terminal row owns the tail
  target (an opening, or a send's materialization), which puts the newest row's
  bottom edge at the composer edge. The pinned band therefore spans both, with a
  6 pt margin: the rendered edge carries a row's own animated transforms, and the
  queued card's 80 → 44 pt shrink measured a 4.1-13.5 pt excursion below the band.
  A detached reader or a blank is tens to hundreds of points away.

  **The gates (F5).** `TranscriptCoverageSummary` folds each journey's samples
  into blank boundaries, uncovered-band boundaries, the longest blank run and the
  minimum visible-row fraction. `transcriptBottomGateOutcome` judges them against
  `TranscriptBottomGateExpectation.current`, today
  `uncoveringBottomIsTheKnownDefect`: the CT-2 and CT-24 shapes must reproduce the
  known blank, and a run that keeps the bottom covered fails as
  `fixtureStoppedReproducing` rather than passing silently. CT-23 flips the
  expectation to `coveringBottomIsRequired` in the change that flips the scroll
  view, and then every sampled boundary must keep the band covered and at least
  half the visible transcript in rows. `PresentedFrameRecorder` now counts dropped
  samples and `windowIsComplete(since:)` fails the three journeys that judge a
  frame window, so a truncated recorder window cannot pass by inspecting only its
  tail.

- Evidence (lane ct25, products from this worktree's own source state, all under
  `~/Library/Developer/Tron/ios/test-runs/`):
  - `ChatViewScrollHarnessTests` 58/58 twice, 90.6 s and 91.0 s
    (`20260929T005430Z-run.vLwdMp`, `20260929T005619Z-run.Apqp2p`), and 62/62 with
    the parity gate and the scale suite in one heavy invocation, 161.5 s
    (`20260929T005823Z-run.VOs5ZQ`) — the same suites that flaked under load
    earlier in this stage (the picker fixtures' RPC ordering and the queued
    fixture's shrink sampling) pass with the readiness fence restored below.
  - The new oracle flags the blank the old helpers call aligned. The CT-2
    many-tall-replies shape, three runs (`20260929T010133Z-run.vKslu9`,
    `…T010206Z-run.A5SmB1`, `…T010240Z-run.6EsYWZ`):

    ```
    CT2-METRICS shape=many-tall-replies samples=72 blankBoundaries=12/72 blankAfterSettle=10 longestBlankRun=12 blankPhases=p1:12 … uncoveredBandBoundaries=12 minVisibleRowFraction=0.0 tailClearanceSettled=12.3 traceCoverage=geometry:complete,chat:complete
    CT2-METRICS shape=many-tall-replies samples=72 blankBoundaries=13/72 blankAfterSettle=10 longestBlankRun=12 blankPhases=p1:12,p3:1 … uncoveredBandBoundaries=13 minVisibleRowFraction=0.0 tailClearanceSettled=12.0 traceCoverage=geometry:complete,chat:complete
    CT2-METRICS shape=many-tall-replies samples=72 blankBoundaries=12/72 blankAfterSettle=10 longestBlankRun=12 blankPhases=p1:12 … uncoveredBandBoundaries=12 minVisibleRowFraction=0.0 tailClearanceSettled=12.3 traceCoverage=geometry:complete,chat:complete
    ```

    `tailClearanceSettled=12.0-12.3` is the window-coordinate spelling of what the
    deleted offset measurement reported as `tailErrorSettled=0.0` while 12-13 of 72
    boundaries were blank: the newest row's bottom edge *is* 12 pt above the
    composer at the end, and the viewport was blank during the keyboard-up phase.
    The keyboard-cycles shape the same runs read 2-140 of 340 blank with 82-160
    uncovered-band boundaries; the CT-24 resync shape 77 of 90 blank and 77
    uncovered (`newestRowClearanceSettled=none`, nothing at the bottom at all), the
    CT-24 send shape 12-27 of 68 blank with 12-44 uncovered.
  - The gate's own control, twice over. `transcriptBottomGateExpectations` pins
    both of the gate's failure modes in isolation (a covered run on today's path
    is `fixtureStoppedReproducing`; an uncovered, partial or sparse run on CT-23's
    path is `bottomUncovered`), and an empirical control temporarily set
    `TranscriptBottomGateExpectation.current` to `coveringBottomIsRequired`: all
    four CT-2/CT-24 journeys then failed at their gate, and the three
    today's-path assertions of the gate test failed with them, so the switch has
    teeth in both directions. Restored, the same six tests pass in 14.0 s
    (`20260929T012617Z-run.wxWVxk`).
  - Negative control, `flippedTranscriptWithoutCounterFlippedRowsFailsTheOracle`:
    the real scroll view's layer is flipped the way CT-23 will and the rows are not
    counter-flipped, so the transcript renders mirrored. The removed measurement
    still reads the legal end (`abs(contentOffset - legalEnd) <= 2`), while the
    oracle reports `isPinned == false` with `pinnedError > 40` and the profiling
    decision `TranscriptWindowOracle.isPinned(tolerance: 24)` false. Passed in
    three consecutive runs (the three above) and in both 58/58 harness runs.
  - `ChatVisualParityTests` 7/7 pass, 46.1 s (`20260929T003258Z-run.scZjWy`); worst
    stable frame 0.0036 against 0.025, worst transition 0.0524 against 0.065 — the
    CT-12 reference still holds.
  - `ChatTranscriptScaleMeasurementTests` 3/3, 29.4 s
    (`20260929T004051Z-run.XoFiBE`): opening 273 ms at 150 rows (CT-10 median 324),
    scroll/stream/send frame intervals and memory (496.7 MB at ready) inside CT-10's
    spread, `CT13-BLANK` 0/60 blank boundaries at 150, 300 and 512 rows.
  - The scale suite now also shows the defect the old measurement hid: its send
    phase ends with `clearance=427.3 pinned=false` at 150 rows (`CT13-PHASE
    phase=send`), and its blank phase reports `uncoveredBandBoundaries=60/60` with
    `minVisibleRowFraction=0.2-0.3` — the "stops short" blank, where 2-3 rows are
    mounted but the pinned bottom is 400 pt away. The deleted
    `tailError` read that state as aligned.
  - The profiling decision, on the optimized `DevicePerformance` build:
    `scripts/tron-profile ios --scenario streaming-reply` passed in 47.7 s
    (`~/Library/Developer/Tron/profiles/ios/20260929T011759Z-streaming-reply-e7ead1`,
    `scenario.render.followed=1`), with the new detail fields visible in its log:

    ```
    TRON_PROFILE_RENDER_CHECK name=streaming-reply iteration=1 attempt=1 status=ok followed=1 tail_clearance=12 band_covered=true visible_fraction=0.98
    TRON_PROFILE_RENDER_CHECK name=streaming-reply iteration=2 attempt=1 status=diverged followed=0 tail_clearance=-120 band_covered=true visible_fraction=1.00
    TRON_PROFILE_RENDER_CHECK name=streaming-reply iteration=2 attempt=2 status=ok followed=1 tail_clearance=12 band_covered=true visible_fraction=0.98
    ```

    The second iteration's first attempt was a real past-the-bottom frame (the
    newest row 120 pt under the composer) and the profiler's own retry recovered
    it; the window-coordinate check reads the pinned tail at exactly the 12 pt
    tail spacing.
  - `ChatViewScrollHarnessTests` 59/59 with the gate test added, 92.3 s
    (`20260929T012710Z-run.agLVmB`).
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`,
  `packages/ios-app/Tests/UI/ChatVisualParityTests.swift`,
  `packages/ios-app/Tests/UI/ChatTranscriptScaleMeasurementTests.swift`,
  `packages/ios-app/Tests/Profiling/ProfileChatScenarioTests.swift`, this plan).
- Deviations:
  - The pinned band's margin is 6 pt, not the deleted offset check's 2 pt: the
    rendered edge carries the row's own animated transforms. The queued-card
    fixture therefore *reports* its transient (`maxTail` in its evidence line,
    4-30 pt measured) instead of gating it, and asserts that the replacement
    returns to the pinned bottom. F5's failing gates are the CT-2 and CT-24 field
    shapes, where the excursion is a whole phase.
  - The former `nativeGeometryMatches` waits became
    `Sample.nativeSettledAtBottom` = the oracle sees the newest row in the band
    *and* the coordinator's own viewport is within its 16 pt catch-up distance
    *and* the two agree about the content height. The oracle alone returns as soon
    as the row hosts land, which was early enough for two composer fixtures to
    send their catalog request before the app's presentation RPC; the content-height
    agreement restores the old fence's strength (both flaked fixtures pass in the
    62/62 heavy run).
  - Three `isPinnedToBottom()` assertions in
    `unifiedResponseAndNotificationSettlement` assert the *recorded* display frame
    (`sample.nativePinnedAtBottom`) rather than a live re-measure: the coordinator's
    semantic row set is retained across an install while the row hosts can be
    between layouts for a frame, so a live re-measure after the wait can see a
    mid-install frame. The waits now require the native pinned state, which the old
    `scrollSettledDistance` wait did not.
  - `ProfileChatScenarioTests.renderCheck` decides `followed` through the shared
    `TranscriptWindowOracle.isPinned`, and its 24 pt tolerance now lives in the
    oracle as `profilingTolerance`. Only `streaming-reply` was re-run; `idle-chat`
    and `tool-loop` use the same check on the same mounted transcript and were not
    re-evidenced here.
  - This entry was written after the runs above, so by CT-1's rule the products
    stamped before it are stale until the next build. The only source change after
    them is the oracle's `pinnedTolerance` comment; the code they measured is this
    commit's.
- Kept on purpose: the CT-2 and CT-24 estimate fields (`maxEstimateRatio`,
  `reDerivations`, `tailDisplacements`, `repairCommands`, `traceCoverage`) — F5
  deletes them once CT-23 lands, not before; the `offsetY`/`contentHeight` fields
  the CT-2 line and the scale reports print, which are measurements rather than
  decisions; `snapNativeTranscriptOffsetToWholePoint` (F9 removes it with the
  exact origin, not here).
- For the next agent: CT-25's remaining stages are the real-scroll detach driver
  and the fabricated-geometry deletions (F3), the safe-area keyboard scenario
  (P0-1), the motion-direction probe (F4), the short-transcript and oldest-row
  parity scenarios and the manifest's `recordedFrom` revision (F9), and the scale
  and profiler driver re-evidence (F2). The oracle is the seam they build on:
  `TranscriptWindowOracle.state(in:)` for a live sample, `Sample.nativeRows`/
  `nativeBottom` for a recorded display frame, and
  `TranscriptBottomGateExpectation` for what the pinned bottom must do before and
  after CT-23.

### CT-25 stage B1 · 2026-09-29 · chat scroll session (worker lanes)

- Result: the keyboard's own inset path is driven and recorded, the first oracle
  of stage B (external P0-1). `resize(height:)` changes the whole window, which
  the flip does not touch; a keyboard changes only the composer's own bottom safe
  area. The harness now drives that: `KeyboardInsetTransition` posts the keyboard
  notification UIKit posts (duration, curve, end frame, as `ChatKeyboardObserver`
  reads them) and then steps `additionalSafeAreaInsets.bottom` through the curve
  values `CAMediaTimingFunction` reports for it, one driven boundary per step, so
  a recorded boundary means one inset in every run. The journey
  `safeAreaKeyboardInsetKeepsNewestRowAtComposer` opens the CT-2 shape (140 rows,
  the last eight ~1,300 pt), samples the gap between the composer's top edge and
  the newest row's bottom edge in window coordinates at every boundary of the
  show transition, a multi-line draft's composer growth and the dismissal, prints
  one `CT25-KEYBOARD-METRICS` line, and gates the *settled* position: after each
  transition the newest row must land back at the pinned tail.
- Evidence (lane ct25, products from this worktree's own source state, all under
  `~/Library/Developer/Tron/ios/test-runs/`):
  - Three consecutive runs of the journey pass, 1.62-1.68 s each
    (`20260929T015148Z-run.x9cT3b`, `20260929T015210Z-run.TjH8ER`,
    `20260929T015233Z-run.YPKRSe`, plus two more with the control below):

    ```
    CT25-KEYBOARD-METRICS shape=safe-area-keyboard samples=56 blankBoundaries=0/56 uncoveredBandBoundaries=0 longestBlankRun=0 blankPhases=none minVisibleRowFraction=1.0 clearanceRange=[-660.2,12.7] settledClearance=12.7 composerHeightSpan=[49.0,110.3] composerTopSpan=[393.7,791.0] phaseClearances=p0:[5.8,10.6],p1:[-660.2,12.0],p2:[12.7,12.7],p3:[12.7,12.7],p4:[12.7,12.7]
    ```

    The inset the driver applies is real: the composer's own top edge spans
    393.7-791.0 pt and its height 49.0-110.3 pt, so the keyboard moved the
    composer and the multi-line draft grew it. Every phase's settled clearance is
    the 12 pt tail spacing.
  - Negative control, three consecutive passing runs
    (`20260929T015536Z-run.yACgdB`, `20260929T015613Z-run.k6xbpg`,
    `20260929T015636Z-run.o0YH7m`), 1.05-1.32 s each: flipping the transcript the
    way CT-23 will, without the rows counter-flipped, then driving the same
    keyboard inset, leaves the newest row away from the composer, so
    `keyboardInsetOverFlippedTranscriptFailsTheComposerGate` passes only because
    the gate it checks fails there — the same failure mode CT-23's unswapped
    insets would produce.
- Changes: this commit (`packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`,
  this plan).
- Deviations:
  - The gate is the transition's *settled* position, not every frame, and the
    per-boundary excursion is recorded rather than gated. Measured across the
    five runs above, the ramp's own excursion is not reproducible: the newest
    row's clearance reaches -660 or -246 pt at some boundary of the show
    transition in some runs and stays within the band in others, while the
    settled position is always the tail. The layout transaction's clock owns
    those frames, and the excursion is a measurement of that clock, not a stable
    gate: an `uncoveringBottomIsTheKnownDefect` gate here failed on the runs that
    happened to keep the band covered (0 of 56 boundaries), which would make the
    fixture flake rather than prove anything. P0-1's own proof is the settled
    check ("the new checks pass on `main`", with the flip as the negative
    control), which is what this gate is.
  - The keyboard notification is posted rather than produced by the simulator's
    software keyboard, so the app's `ChatKeyboardObserver`/layout-transaction path
    runs against a stated end frame. The inset itself is the real mechanism
    (UIKit owns it on a device); the P0-1 text suggested one UI test with the real
    software keyboard, which F10 tracks as an XCUITest journey and this stage did
    not add.
- For the next agent: the parity gate needs this scenario too (stage B2), and the
  manifest needs a per-scenario `recordedFrom` before any reference is recorded
  from this branch (F9).

### CT-25 stage B2 · 2026-09-29 · chat scroll session (worker lanes)

- Result: the parity gate now covers the keyboard's own inset path, the short
  transcript and the oldest row, and its reference carries the provenance F9
  asked for (P0-1's parity half, F9).

  **Three new scenarios**, taking the gate from seven to ten:
  - `keyboard-safe-area-inset` drives the harness keyboard transition (stage B1)
    over the mixed history: pinned rest, the show transition's eight intermediate
    insets, the composer's multi-line growth and clearing at full keyboard, the
    dismissal's eight intermediate insets, and the settled rest. `resize` changes
    the whole window, which the flip does not touch; this scenario changes only
    the composer's inset, which is the edge CT-23 has to re-apply swapped.
  - `short-transcript-at-rest` records a four-row history that does not fill the
    screen (newest row on the composer, blank space above it). No CT-12 scenario
    covered it, and a flip that anchors the wrong edge puts it at the visual top.
  - `oldest-row-at-visual-top` scrolls the real reader to the oldest loaded row
    of a 60-row history with 40 earlier messages, so the 12 pt top padding and the
    earlier-messages row are in the frames.

  **Provenance.** The manifest schema is now `tron.chat-visual-parity.v2`: every
  scenario names the source revision its frames came from, and verification
  refuses a manifest naming a revision `ChatVisualParityReference.recordedRevisions`
  (a reviewed set) does not list. A scenario the committed reference lacks is
  recorded, merged with every existing entry left byte-identical, and the run then
  *fails*, so the new revision has to be added to that reviewed set before the
  gate passes again. A recording run takes the worktree's revision from
  `TRON_SOURCE_REVISION`, which `scripts/tron-ios-test` now passes through the
  `TEST_RUNNER_` prefix the project already documents; a bare `xcodebuild` run can
  verify but cannot record. The seven CT-12/CT-14 entries are recorded from
  `eed1e15a5` (CT-14's own commit, the last to write the manifest, on the
  unchanged chat before any container change); the three CT-25 entries from
  `2297defc9`, this stage's branch state. Every existing frame is byte-identical —
  `python3` comparison of the committed manifest against `HEAD` confirmed the
  seven entries' frames unchanged.
- Evidence (lane ct25, products from this worktree's own source state, all under
  `~/Library/Developer/Tron/ios/test-runs/`):
  - Recording run `20260929T022650Z-run.Pdb8pN` (60.5 s, exit 65 by design):
    `PARITY-RECORD scenario=keyboard-safe-area-inset frames=27 revision=2297defc…`,
    `short-transcript-at-rest frames=8`, `oldest-row-at-visual-top frames=6`,
    `manifest=…/build/parity-reference/manifest.json scenarios=10 added=3`. The
    manifest copy was committed; the seven untouched entries are byte-identical.
  - Three consecutive verification runs, all ten scenarios pass, 58.9/59.4/61.4 s
    (`20260929T022846Z-run.tE5yLE`, `20260929T023010Z-run.7oz1eN`,
    `20260929T023149Z-run.rYiCDz`):

    | scenario | worst diff, three runs | bound |
    | --- | --- | --- |
    | opened-long-history-at-rest | 0.00671 / 0.00587 / 0.00372 | 0.025 |
    | ordinary-send-keyboard-up | 0.05252 / 0.05167 / 0.01497 | 0.065 |
    | streaming-tail-growth | 0.03681 / 0.03505 / 0.04149 | 0.065 |
    | queued-card-to-sent-row | 0.05046 / 0.05070 / 0.02759 | 0.065 |
    | tool-chip-entrance | 0.02039 / 0.02723 / 0.01962 | 0.065 |
    | earlier-page-load-at-rest | 0.00579 / 0.00564 / 0.00336 | 0.065 |
    | detached-reader-catch-up | 0.00597 / 0.00599 / 0.00382 | 0.065 |
    | keyboard-safe-area-inset (new) | 0.02861 / 0.02848 / 0.01215 | 0.065 |
    | short-transcript-at-rest (new) | 0.00714 / 0.00720 / 0.00282 | 0.025 |
    | oldest-row-at-visual-top (new) | 0.00294 / 0.00475 / 0.00305 | 0.025 |

  - `scripts/test-ios-test-infrastructure.py`: 86 tests pass in 192 s, so the
    runner's new `env TEST_RUNNER_TRON_SOURCE_REVISION=…` prefix keeps the
    documented run path intact.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/ios-app/Tests/UI/ChatVisualParityTests.swift`,
  `packages/ios-app/Tests/Fixtures/ChatVisualParityManifest.json`,
  `packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`,
  `scripts/tron-ios-test`, `packages/ios-app/docs/development.md`, this plan).
- Deviations:
  - `snapNativeTranscriptOffsetToWholePoint` is **kept**, and this is the measured
    reason F9 allows. The snap was removed and the three new scenarios re-recorded
    without it: the gate still passed ten of ten in three runs
    (`20260929T021319Z-run.f24B71`, `20260929T021515Z-run.oDO7I7`, and the
    re-recording run `20260929T021733Z-run.ZwLHv2`) — but the *existing*
    opened-long-history reference's stable frames then measured 0.01892 against
    their 0.025 bound in one of the three (`20260929T022222Z-run.DaAr6a`), where
    with the snap they measure 0.0037-0.0067. The snap is therefore still carrying
    the existing reference's determinism, and this stage must not re-record that
    reference: F9's removal belongs with CT-23's exact origin, which is where the
    plan's stage A handoff already placed it. The new scenarios' reference was
    re-recorded *with* the snap (its own recording run above).
  - The provenance rule is a reviewed revision set, not a comparison against the
    CT-23 base: a test process has no git ancestry to ask, so "recorded at or
    after the CT-23 base" is enforced as "recorded from a revision the review
    named", and a re-recording cannot pass until that review happens. The rule and
    its limit are stated in `ChatVisualParityReference` and in
    `packages/ios-app/docs/development.md`.
- For the next agent: the gate's reference now grows one scenario at a time;
  `README`-level gate docs live in the parity section of
  `packages/ios-app/docs/development.md`. F9's `snapNativeTranscriptOffsetToWholePoint`
  removal is still owed by CT-23.

### CT-25 stage B3 · 2026-09-29 · chat scroll session (worker lanes)

- Result: detached reading is driven through the real transcript scroll view, and
  the anchor invariant it exists for is now measured in window coordinates (F3).

  **The driver.** `ChatViewScrollHarness.detachReaderByRealScroll()` moves the
  transcript's own `UIScrollView` to the oldest loaded row — the path the
  coordinator reads as direct ownership, today's status-bar tap — and waits until
  the coordinator reports the detached mode *and* a row is on screen.
  `returnReaderToPinnedTailByCatchUp()` returns the reader through the product's
  own catch-up affordance, because a hosted test cannot synthesize the pan
  gesture whose `onScrollPhaseChange` callbacks re-pin a detached reader; the
  finger-driven return stays the device checklist's check (F10). The hand-written
  `ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight:
  400)` sequence is gone from every journey that only needed a detached viewport:
  `detachedDiscreteInsertion`, `catchUpReconcilesNewestProjection`,
  `retainedDetachedAuthorityReplacement`, `streamingBurstLatestProjection`,
  `cancelledDetachedReplacement` (4 cases) and
  `detachedReplacementAdmitsCurrentTarget` (2 cases) now detach for real.
  `manualTailReturnAndKeyboardFollow` detaches for real and keeps its synthetic
  part, which is explicitly the device-observed callback *order* a finger's
  return produces — the one input a hosted test cannot generate.

  **The anchor oracle.**
  `detachedReaderHoldsItsTopRowThroughStreamingKeyboardAndPage` opens a 60-row
  mixed history with 40 earlier messages, detaches for real, takes the topmost
  visible row as the reader's anchor, and asserts in window coordinates that its
  `minY` stays within ±0.5 pt through streaming (six updates), the keyboard's
  inset cycle (the stage B1 driver, up and down) and a page load — and that none
  of them writes an automatic scroll command. A real-scroll journey covering that
  also let two fabricated-geometry fixtures go:
  `drivenCoordinatorExecutor` and `shrinkDoesNotFollow` (audit F3/F8), whose whole
  subject was "no scroll writes while pinned or detached" through injected
  geometry.
- Evidence (lane ct25, products from this worktree's own source state, all under
  `~/Library/Developer/Tron/ios/test-runs/`):
  - Three consecutive runs of the real-scroll set (the anchor journey and the six
    converted journeys, 8 tests), 7.759 s and 7.870 s
    (`20260929T025916Z-run.H5TfzJ`, `20260929T025951Z-run.6Jjpzu`, plus
    `20260929T025453Z-run.S3cEra` for the anchor journey alone), each:

    ```
    CT25-DETACH-METRICS anchor=detach-anchor-turn-0 startY=64.0 movements=streaming:0.0,keyboard-up:0.0,keyboard-down:0.0,page-load:0.0
    ```

    The anchor row is the oldest loaded row (`detach-anchor-turn-0`, 64 pt from the
    top of the window) and it does not move by a hundredth of a point through any
    of the three phases, with zero automatic scroll commands in all of them.
  - Full `ChatViewScrollHarnessTests`: 60 tests pass in 81.9 s
    (`20260929T025525Z-run.Xxguyn`) — 62 before this stage (59 stage A + 2 B1 + 1
    B3) minus the two deleted fixtures.
  - The field shapes are unaffected: `CT2-METRICS shape=many-tall-replies … blankBoundaries=13/72`
    and `CT24-METRICS shape=resync-under-tall-newest … blankBoundaries=77/90` in
    `20260929T025825Z-run.8QBFXl` (2.0 s and 2.4 s), both still reproducing the
    known defect the stage A gates require.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (`packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`,
  `packages/ios-app/docs/development.md`, this plan).
- Deviations:
  - The audit's F3 also lists the coordinator suite's fixtures
    (`ChatScrollCoordinatorTests`) and `ChatVisualParityTests`' detached scenario
    as fabricated geometry. The coordinator suite tests the reducer's own
    transitions, which no end-to-end journey covers and which AGENTS.md's
    isolation rule allows; its fixtures stay until CT-23 rewrites them against one
    orientation-free geometry value (audit section A). The parity gate's detached
    scenario is a *rendered-frame* scenario whose geometry is the harness's
    driver by design; it is re-recorded, not rewritten, and F2's driver work is
    stage B5.
  - `displacedRetainedResume` (a real scroll, then the pinned-position
    re-application), `pinnedOvershootNeedsNoAppWrite` and
    `pastEndRepairReturnsToTail` keep their injected geometry: their subject is a
    mechanism CT-19 retires, the plan's deletion rule deletes those with the
    mechanism, and a real scroll view cannot be dragged past its legal content
    bottom in a hosted test (`scrollReader` clamps to the legal range). That is
    F8's work, not F3's.

### CT-25 stage B4 · 2026-09-29 · chat scroll session (worker lanes)

- Result: the opening reveal's motion direction is gated (F4), through the one
  measurement that carries it, and the harness's pixel instrument is recorded
  with the measured reason it cannot gate the same motion.

  **What is gated.** `hostedOpeningRevealRisesUpward` holds the opening at its
  `.presenting` frame, releases it, and samples twelve display boundaries. It
  gates the **committed** position of the newest row's bottom edge: the reveal
  steps the transcript upward by its 8 pt physical lift, so the edge must never
  move down across the reveal and its total step must be 8 ± 3 pt. That step is
  what a flip inverts (any offset applied outside a row's counter-flip becomes a
  drop), it is layout-true, and it needs no pixel resolution: measured as
  786.7 → 778.7 pt in every run.

  **What is recorded instead.** The probe F4 asked for —
  `RenderedVerticalProfile` / `inkCentre` / `inkShift` in the harness — measures
  the luminance-weighted vertical centre of the entering region (the transcript
  band above the composer, against the covered frame's own row means) at each
  boundary. Measured over the same reveal, that centre moves 657.1 → 583.4 pt
  (74 pt, with ±10 pt wiggles) because the revealed content is *realizing rows*
  while it moves: the 8 pt rise is a small part of a much larger realization
  movement in the same direction, so it cannot gate the direction. The test
  prints the per-frame centre and asserts only that the entering ink was
  measurable. The send's 20 pt rise is not measurable at all here: the row's
  entrance translate is never committed between display boundaries in the
  rendered tree (30 sampled boundaries inside the row's own marker frame moved
  its centre by 1.6 pt, downward, because the composer clips the start position)
  and the row marker does not carry the entrance offset. That is the same limit
  CT-12 and CT-14 recorded for motion, and the reason the entrance's exact rise
  and duration stay on the device checklist (F11).
- Evidence (lane ct25, products from this worktree's own source state, all under
  `~/Library/Developer/Tron/ios/test-runs/`):
  - Three consecutive passing runs, 0.97-1.03 s each
    (`20260929T032302Z-run.kGht7n`, `20260929T032327Z-run.m0k3EJ`,
    `20260929T032352Z-run.iT97tu`), each printing

    ```
    CT25-MOTION-OPENING edges=["786.7", "786.7", "786.7", "785.0", "781.6", "780.3", "779.1", "778.7", "778.7", "778.7", "778.7", "778.7"] centres=["586.3", "588.3", "632.7", "649.3", "592.9", "594.9", "579.1", "583.1", "583.2", "583.2", "583.3", "583.3"]
    ```

    the 8 pt step in every run (778.7 from 786.7, monotone), and the pixel
    centre's realization-driven 74 pt excursion beside it.
  - Negative control, three consecutive runs, the *inverted* offset in the
    product's own reveal (both `.offset(y: 8)` modifiers negated, reverted
    afterwards): all three fail
    (`20260929T032522Z-run.znryrc`, `20260929T032610Z-run.6cHsad`,
    `20260929T032701Z-run.XQ0M4O`), each with the test's own watchdog. Recorded
    honestly: the inverted offsets leave the opening unsettled (its traces show
    `openingTask=0 ready=0` and the harness never reaches its sampled frames), so
    these runs fail by timeout rather than by the direction assertions — the
    injection is blunter than the assertion it controls for. The direction
    assertions themselves are what the passing runs' `edges` sequence above
    reports, and the inverted sequence (`778.7 → 786.7`, and never monotone
    upward) fails both of them.
  - The gate that must not move: `ChatViewScrollHarnessTests` and
    `ChatVisualParityTests` together pass 62 tests in 2 suites in 160.0 s
    (`20260929T034229Z-run.i6Twmu`) and again in 154.5 s
    (`20260929T035259Z-run.t76yRr`), parity gate verdict pass (see stage B5).
    One heavy invocation between them failed `pickerRejectsRetiredCatalog` with
    2 issues (176.4 s, `20260929T034722Z-run.LvqoyA`); the same suite passed
    alone 61/61 in 96.5 s (`20260929T035052Z-run.fSGqcc`) and the fixture has no
    relationship to this stage's changes, so it is the load-related picker
    RPC-ordering flake stage A already recorded, not a regression.
- Changes: this commit (`packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`,
  this plan).
- Deviations:
  - F4's expected instrument (the luminance centre, 8 ± 3 pt and 20 ± 5 pt) is
    not the gate, with the measurement above as the reason. The *direction*
    protection exists (committed edge, 8 ± 3 pt, monotone) and the send's
    direction stays a device check. This is a deviation from F4's stated
    mechanism, not from its purpose.
  - The negative control fails 3/3 by watchdog instead of by assertion, as
    recorded above.

### CT-25 stage B5 · 2026-09-29 · chat scroll session (worker lanes)

- Result: the scale suite and the profiler drive the transcript through the
  window-coordinate helpers and their numbers still sit inside CT-10's spread
  (F2, and the last of CT-25's five stages). Both drivers moved in stage A
  (`ChatTranscriptScaleMeasurementTests` uses `harness.scrollReader(byVisualPoints:)`
  for its scroll and send phases; `ProfileChatScenarioTests.renderCheck` decides
  `followed` through `TranscriptWindowOracle.isPinned`), so this stage re-evidenced
  them against the CT-10 baseline on today's path.
- Evidence (lane ct25, products from this worktree's own source state):
  - `ChatTranscriptScaleMeasurementTests` 3/3 twice, 25.4 s and 26.1 s
    (`20260929T032917Z-run.11K04P`, `20260929T033004Z-run.LwngT3`), against
    CT-10's recorded medians (spread):

    | metric | 150 rows | 300 | 512 | CT-10 |
    | --- | --- | --- | --- | --- |
    | first ready frame | 321 / 284 ms | 212 / 191 ms | 213 / 235 ms | 324 (314-336) / 350 (347-358) / 475 (461-489) |
    | memory at ready | 497.3 / 497.2 MB | 575.8 / 575.4 | 594.9 / 595.1 | 497 / 583 / 613 |
    | scroll step median | 0.8 / 0.8 ms | 0.8 / 0.9 | 0.8 / 0.8 | 0.8 |
    | streaming interval median | 20.2 / 20.3 ms | 25.1 / 24.1 | 33.3 / 30.0 | 33 / 50 / 50 |
    | blank boundaries, keyboard cycle | 0/60 / 0/60 | 0/60 / 0/60 | 0/60 / 0/60 | 0/60 |

    No metric is outside CT-10's spread and the opening is faster at all three
    sizes. The send phase still ends `clearance=428.7 pinned=false` (the "stops
    short" state stage A reported the deleted tail measurement calling aligned),
    and the blank phase still reports `uncoveredBandBoundaries=60/60` with
    `minVisibleRowFraction=0.2-0.3`: the field defect's other half, unchanged.
  - `scripts/tron-profile ios --scenario streaming-reply --iterations 2`: one
    measured iteration pair, both `scenario.render.followed=1`, with the oracle's
    own detail fields in the log

    ```
    TRON_PROFILE_RENDER_CHECK name=streaming-reply iteration=1 attempt=1 status=ok followed=1 tail_clearance=12 band_covered=true visible_fraction=0.98 repair_exhausted=0
    ```

    (`~/Library/Developer/Tron/profiles/ios/20260929T034108Z-streaming-reply-d5cb5c`).
  - `ChatViewScrollHarnessTests` + `ChatVisualParityTests`: 62 tests in 2 suites,
    160.0 s, parity gate 10/10 pass (`20260929T034229Z-run.i6Twmu`). The harness
    suite alone is 60 tests in 81.9 s.
  - `python3 scripts/test-ios-test-infrastructure.py`: 86 tests pass in 192 s.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: this commit (this plan; the scale and profiler drivers themselves
  landed in stage A's commit).
- CT-25 is done: all five stages are on `main`'s tree in this worktree, each with
  its negative control where the audit asked for one, and the gates CT-23 needs
  now exist — window-coordinate oracle and bottom-coverage gates (stage A), the
  keyboard's own inset path (B1, B2), real-scroll detached reading with an anchor
  invariant (B3), the reveal's motion direction (B4), and re-evidenced scale and
  profile numbers (B5). Deferred deliberately, not by omission: F5's deletion of
  the estimate-only fields, F8's assertions on retiring compensations, the
  coordinator suite's fixtures and `snapNativeTranscriptOffsetToWholePoint` all
  belong to CT-19/CT-23, and the three injected-geometry fixtures stage B3 lists
  keep their geometry until the mechanisms they exercise retire.
- For the next agent: CT-23 resumes against these gates. The expectation switch
  is `TranscriptBottomGateExpectation.current`: flipping the transcript must flip
  it to `coveringBottomIsRequired` in the same change, and every scenario,
  journey and anchor assertion above then has to hold in the flipped orientation
  — that is what CT-25 was for.

### Review fixes (CT-25) · Done · 2026-09-29 · chat scroll session (worker lane)

- Result: the CT-25 review's findings are fixed on `ct-25-oracles`, with the
  parity reference re-recorded from a clean committed revision. Six commits:
  `139bb1b26` (provenance, keyboard control, motion instrument, isFlipped,
  restored coverage, mid-history detach), `66f2d8864` and `c18b3b084` (the fixes
  the first hosted runs found), `8e058ba35` (the re-recorded reference), and this
  plan entry. CT-23 stays out of scope.

  **P1 — a recording named a revision that cannot reproduce its frames.**
  `scripts/tron-ios-test` passed only `TRON_SOURCE_REVISION`, so a dirty tree
  recorded frames under the ancestor commit it happened to sit on
  (`20260929T022650Z-run.Pdb8pN`: `dirty: true` at `2297defc9`). It now passes
  the source state it verified as `TEST_RUNNER_TRON_SOURCE_DIRTY` beside the
  revision, and `ChatVisualParityGate.record` refuses unless that state is a
  proven clean commit — an unstated state is not a clean one. The three CT-25
  scenarios' stale entries were removed, the scenarios re-recorded from
  `c18b3b08402f533ce3b03d96eb6d1ca2d39e473a`, and that revision added to
  `ChatVisualParityReference.recordedRevisions`. `development.md`'s recording
  steps now commit the scenario code before recording, check
  `git status --porcelain`, and rebuild after the manifest commit before
  verifying (the products are stamped with the state they were built from).

  The far-end clamp (`e01863d88`) stays verbatim; its `-inset.top` lower bound
  moves the `oldest-row-at-visual-top` reader by the transcript's 116 pt top
  inset, which is why that scenario no longer matched the committed reference
  (0.0547 against 0.025) and was re-recorded with the other two.

  **P2 — the keyboard negative control mirrored the transcript.** It failed with
  or without a keyboard, so it never isolated the inset's edge. It now drives the
  keyboard's own transition (`driveKeyboardInsetAtWrongEdge`) while
  `reserveKeyboardHeightAtTranscriptFarEdge` reserves the height at the
  transcript's *far* edge — the offset past the legal bottom, which is the
  geometry a wrongly swapped margin produces, with every row keeping its own
  orientation and order. The control asserts the composer moved more than 200 pt
  with its inset, so the failure is the inset's edge and not a missing
  transition. Recorded for anyone re-trying the mechanism: a scroll-view
  translation is compensated by `UIScrollView` and measured no clearance change
  at all.

  **P2 — the motion gate's pixel instrument asserted nothing.** `verticalProfile`,
  `inkCentre` and `RenderedVerticalProfile` are deleted (their only assertion was
  `centres.count >= 3`), and the reveal's direction is one pure decision,
  `OpeningRevealDirection.failure(edges:)`: the newest row's committed window edge
  must never move down and must step up by the reveal's 8 ± 3 pt lift. The
  negative control feeds it the measured sequence and its reversal, plus a static
  and an empty sequence, so the inverted reveal reaches the assertions instead of
  the watchdog the three B4 attempts hit.

  **P2 — coverage lost with the two synthetic fixtures.** Restored on the real
  view, through the window oracle:
  - `pinnedGrowthAndShrinkWriteNoPosition`: a pinned reply arrives and leaves
    again; the only commands are the terminal row's own exact-realization lease,
    and the tail holds the pinned band (growth clearance 8.0, shrink 12.3).
  - `detachedRestructureAdmitsNoProjectionWork`: the keyboard's own inset cycle
    against a mid-history detached viewport admits no projection work, no
    projection install and no scroll command, and the window oracle holds the
    reader's anchor row within 0.5 pt of where it was; a reader who takes the
    viewport back while a catch-up is admitted is still away with their unread
    state.
  Two measurements recorded rather than hidden: shrinking the terminal row *in
  place* with zero writes leaves the tail 65 pt under the composer (a field-shape
  figure, not a requirement, so the shrink phase restores the baseline content
  instead); and `automaticScrollCommandCount` is dead evidence —
  `recordScrollCommand` is only ever called with `isAutomatic: false` — so the
  restored fixtures count every command that is not a tail-row lease. Making that
  counter live, or deleting it, belongs to the task that owns the probe's
  evidence surface.

  **P2 — the detach sat at the content's far edge.** `detachReaderMidHistory(byViewports: 1.5)`
  scrolls the real view 1.5 viewports up and reports the pan's own phase
  callbacks, so the streaming and keyboard phases of
  `detachedReaderHoldsItsTopRowThroughStreamingKeyboardAndPage` can actually move
  the anchor (the status-bar path's heuristic needs a visual top inside 2 pt, so
  it always left the reader at offset 0, where nothing above could move it). The
  status-bar helper stays for the journeys that only need a detached viewport.

  **P2 — `isFlipped` stopped at the first negative `m22`.** It multiplies the signs
  along the layer chain, so a container that flips both the scroll view and an
  ancestor reads as upright, and
  `orientationReadMultipliesTheFlipAlongTheChain` pins it: red against the
  pre-fix body (failed at the double flip), green with the fix.

- Evidence (lane ct25, products from this worktree's own source state, all under
  `~/Library/Developer/Tron/ios/test-runs/`):
  - A dirty run refuses to record: `20260929T074359Z-run.70qb1N` (revision
    `e01863d88`, `dirty: true`, exit 65), each scenario's frames driven, then
    `the parity reference was not recorded: this run's source tree is not proven
    clean …` and no `build/parity-reference/manifest.json` written. The pre-record
    tree carried exactly this defect, so the refusing run is the fix's own
    before/after.
  - The recording from the clean commit: `20260929T081225Z-run.FTfZyS`
    (`c18b3b084`, exit 65 by design), each of the three:

    ```
    PARITY-RECORD scenario=keyboard-safe-area-inset frames=27 revision=c18b3b08402f533ce3b03d96eb6d1ca2d39e473a
    PARITY-RECORD scenario=short-transcript-at-rest frames=8 revision=…
    PARITY-RECORD scenario=oldest-row-at-visual-top frames=6 revision=…
    ```

    The merged manifest's seven reviewed entries are identical to the ones they
    replaced (scenario-by-scenario comparison); only the three re-recorded
    scenarios and their `recordedFrom` changed.
  - `20260929T081608Z-run.MN2ESo` and, from the final committed revision,
    `20260929T083222Z-run.j4QYYF` (`f663f1fa3`, `dirty: false`):
    `ChatViewScrollHarnessTests` + `ChatVisualParityTests`, 66 tests in 2 suites,
    pass in 162.3 s and 158.7 s, parity gate 10/10 `verdict=pass` — the three
    re-recorded scenarios at 0.02258 (keyboard-safe-area-inset), 0.00455 (short
    transcript) and 0.00264 (oldest row at the visual top). The second run proves
    the reference still reproduces after the harness's last edit.
  - The harness suite alone: 65 tests (`20260929T080850Z-run.JOT2h1`, the
    UIValidation tier — 61 before this change plus the four new tests), with one
    failure in `retiredComposerCatalogDoesNotPublish` that the same heavy suite
    recorded twice in stage B4; it passes alone (`20260929T081137Z-run.io9XoI`) and
    passed in the combined run above, so it is the load-related picker RPC-ordering
    flake, not a regression.
  - The new and changed tests, focused: 8 pass in 8.9 s
    (`20260929T080731Z-run.IgrxxH`; the detached-restructure test re-run from the
    committed revision after its anchor assertion was added,
    `20260929T083030Z-run.V5BFXp`, `dirty: false`), including `CT25-KEYBOARD-METRICS …
    settledClearance=12.7 composerTopSpan=[393.7,791.0]` from the correct-inset
    journey beside the wrong-edge control,
    `CT25-DETACH-METRICS anchor=detach-anchor-turn-43 startY=-35.7
    movements=streaming:0.0,keyboard-up:0.0,keyboard-down:0.0,page-load:0.0` and
    `CT25-MOTION-OPENING edges=[786.7 … 780.2]`.
  - `isFlipped`'s test: red against the pre-fix body
    (`20260929T082048Z-run.TWVpeT`, failed at the double flip), green with the fix
    (`20260929T082202Z-run.xpAAyK`).
  - `python3 scripts/test-ios-test-infrastructure.py`: 87 tests pass in 193 s, and
    the new `RunnerFixture.test_run_passes_the_source_revision_and_its_state_to_the_test_process`
    fails against the pre-fix runner (`TRON_SOURCE_DIRTY=` empty) and passes with
    it.
  - `python3 scripts/check-documentation-policy.py` and
    `scripts/personal-info-guard.sh` pass.
- Changes: the commits named above (`scripts/tron-ios-test`,
  `scripts/test-ios-test-infrastructure.py`,
  `packages/ios-app/Tests/UI/ChatVisualParityTests.swift`,
  `packages/ios-app/Tests/Fixtures/ChatVisualParityManifest.json`,
  `packages/ios-app/Tests/UI/ChatViewScrollHarnessTests.swift`,
  `packages/ios-app/docs/development.md`, this plan).
- Deviations:
  - The direction gate's negative control is its own predicate over the measured
    sequence and its reversal, not a hosted inverted reveal: the B4 inversion
    (both `.offset(y: 8)` modifiers negated) left the opening unsettled and all
    three runs failed by watchdog, and a hosted inversion cannot be produced
    without editing the product. The control reaches the two conditions the gate
    enforces, which the watchdog runs never did.
  - The restored pinned-growth/shrink assertions are green against the pre-fix
    code as well: they restore coverage two deleted fixtures carried, they do not
    guard a new fix. The red-before-green evidence in this entry belongs to the
    provenance refusal, `isFlipped` and the two controls.
  - `ChatRowStabilityTests` (CT-27) still has to be ported onto these helpers
    when CT-27 rebases; this entry changes no helper CT-27 calls beyond
    `isFlipped`'s body and the two fixtures' coverage.
- For the next agent: CT-23 resumes against these gates, unchanged in substance —
  the expectation switch, the ten parity scenarios and the anchor invariant all
  hold, and a recording now needs a clean committed tree. The ui-validation tier
  (`TRON_IOS_TEST_TIER=ui-validation`) is required for the parity gate, the
  keyboard journey and the CT-2/CT-24 gates.

### CT-27 stage A1 (F13) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: the row-stability foundation's measurement fixture and the probe it
  reads. `ChatHostedProbe` now keeps a per-mount record per row — the first
  settled frame height under one installed projection and installed mount, and
  every later height change (>0.5 pt) as a post-mount resize — excluding rows
  whose own presentation owns their height (streaming, entrance, lifecycle
  replacement). It also records each row content's view identity through
  `ChatHostedRowIdentityProbe` (a `HOSTED_TEST`-only background inside
  `renderRow`), so a structural switch of a row's subtree is visible as a second
  instance for the same row.
- New fixture `packages/ios-app/Tests/UI/ChatRowStabilityTests.swift`
  (`ChatRowStabilityTests.rowStabilityJourney`): 24 ordinary history rows plus
  one row of every kind the audit names (a prompt with an image and a file
  attachment, wrapped thinking, two adjacent inline Markdown displays, a
  sheet-surface display card that renders collapsed, a tool run, a truncated
  error notice, a code-and-table response), one discrete insertion while pinned
  so an entrance runs, then a real native scroll to detach, to the oldest loaded
  row and back twice. It writes `packages/ios-app/build/row-stability/report.json`
  and prints one `ROW-STABILITY` line. It is a measurement: it asserts only that
  the journey ran (every fixture row was measured, every one left the lazy range
  and mounted again, the oldest phase reached offset 0 with the newest rows off
  screen).
- Measured on today's `main` (lane ct27, run `20260928T235449Z-run.F0UpSn` and
  two later runs, 1.5-1.9 s):
  `postMountResizes=0 maxPostMountResize=0.0 resizedRows=0 remounts=8-9/9
  collapsedStaysCollapsed=true inlineDisplaysPrepared=false
  inlineDisplaysStable=true entranceIdentityStable=false excludedRows=1`.
  So today's failures this fixture records are the entrance one: the inserted
  row's content identity changes at admission (F1 confirmed by probe, not by
  source reading), and an inline display cannot reach its prepared state because
  the hosted harness has no media source (F4's starvation path is not reachable
  here). No post-mount resize was measured for any row kind: the measuring loops
  the audit lists (F2 thinking, F3 disclosure, F5 growth host) re-derive their
  heights inside one display frame, and the row's own geometry callback delivers
  only the settled value.
- Deviations: (a) CT-25's real-scroll detach driver is not on this branch, so
  the journey moves the real native scroll view (real geometry, real lazy
  realization) and admits the reader's interaction phase through the
  coordinator's own phase path, with the probe in `.native` scroll-callback mode;
  (b) the audit's "collapsed display card" is a display whose requested surface
  is `sheet`, which renders the collapsed pill — collapsing an inline card needs
  a tap the harness cannot inject; (c) the audit's journey has no insertion, but
  the entrance-identity field is vacuous without one, so the journey inserts one
  row while pinned.
- Changes: `ChatHostedProbe.swift` (per-mount record, identity probe, observation
  fields), `ChatTranscriptScrollView.swift` (row stability at the row-frame seam,
  identity probe in `renderRow`), `ChatViewScrollHarnessTests.swift` (one new
  `scrollCallbackMode` parameter on the harness, `.synthetic` by default),
  `ChatRowStabilityTests.swift` (new).

### CT-27 stage A2 (F1) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: confirmed by probe, then fixed. The entrance clip's if/else did switch
  the row content's view structure at admission: the A1 journey measured
  `entranceIdentityStable=false` and `remountedRows=1:stability-entrance` for the
  inserted row before this change. `chatEntranceGrowthClip` now always applies
  one `clipShape`; at progress 1 its rect covers the row's bounds by 128 pt in
  every direction (past any Liquid Glass press expansion or shadow, and bounded
  so the clip stays a small surface) instead of the node being removed. The
  padding/negative-padding wrapper is gone with it, so a pending row is now
  measured at the same width as a settled one. `requiresClip` is deleted.
- Evidence (lane ct27, products rebuilt from this worktree):
  - `ChatRowStabilityTests` 2/2 in 2.2 s: `entranceIdentityStable=true`,
    `remountedRows=0`, `entranceIdentityStable` asserted directly by
    `entranceAdmissionKeepsRowContentIdentity` (identity instances for the
    inserted row = 1 across its admission).
  - Parity gate 7/7 (45.3 s), including the entrance transition frames
    (`tool-chip-entrance` worst 0.04919 against 0.065, `outgoing-entrance`
    worst 0.05227); the CT-14 motion evidence is unchanged within the gate's
    bounds.
- Deviations: the entrance's height interpolation now runs (the layout keeps its
  identity), which is the layout's intended behaviour but was previously lost
  with the switched branch. The gate's sampled transition frames did not move
  beyond their recorded bounds. The Liquid Glass press-and-drag region is
  covered by the gate's frames, not by a device check; F1's device check stays
  on CT-7 as the audit asked.
- Changes: `ChatEntranceRows.swift`, `ChatRowStabilityTests.swift`.

### CT-27 stage A3 (F5) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: `ChatIncrementalContentGrowthHost` now owns a height only while the row
  is streaming or a growth animation is in flight. A settled row leaves
  `presentedHeight` nil, so its layout is always its content's natural height and
  a width, Dynamic Type or document change cannot lay it out once at a stale,
  clipped height. The pinned height is released when a stream ends, deferred
  through `isAnimatingGrowth` and two `onChange` re-entries so ending a stream
  cannot truncate the last growth animation's frames. `install` still measures
  every row (the measurement feeds the identity/width bookkeeping) but writes no
  height for a settled one.
- Evidence (lane ct27):
  - Parity gate 7/7 (44.6 s): `streaming-tail-growth` worst 0.04034 against 0.065,
    `queued-card-to-sent-row` 0.02564, `tool-chip-entrance` 0.05231 — the
    streaming and replacement motion evidence is unchanged within the gate.
  - `ChatRowStabilityTests` 2/2 (2.7 s), same counters as A2
    (`postMountResizes=0`, `remounts=9/9`, `semanticFrameCallbacks=275`).
- Deviations: this fix has no hosted height oracle. Its cost is a state write and
  one relayout per mount, and the height it pinned was always the natural height,
  so no sampled row frame differs before or after it; the parity gate and the
  journey counters are the evidence, and the F13 counter still reads zero. The
  audit's `semanticFrameCallbackCount` proof therefore does not discriminate here
  (275 before, 275 after on this journey).
- Changes: `ChatEntranceRows.swift`.

### CT-27 stage A4 (F9) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: `transcriptRow` no longer selects between two structures by
  `canonicalSubmissionIDs.contains(semanticID)`. The state above already forces
  a canonical submission's entrance state to `.none`, and a `.none` entrance row
  is layout-neutral, so the membership test only decided whether the prompt
  subtree was wrapped in `ChatTranscriptEntranceRow` — adding the handoff ID
  therefore remounted the subtree, including its native context-menu
  interaction, for no layout reason. `isReplacementOverlay` remains the only
  branch.
- Evidence (lane ct27): parity gate 7/7 (45.7 s), including
  `queued-card-to-sent-row` (worst 0.04878 against 0.065) which is the canonical
  handoff's own scenario; `ChatRowStabilityTests` 3/3 (3.3 s) including
  `canonicalPromptHandoffKeepsRowContentIdentity`.
- Deviation, stated because the evidence is weaker than the finding: the hosted
  fixture could not reproduce the switch. In every flow reachable from the
  harness the handoff ID is remembered during the same projection intake that
  first installs the canonical row (`ChatView.intakeLatestTranscriptProjectionIfNeeded`
  calls `rememberCanonicalSubmissionHandoffs` before `transcriptPresentation.submit`),
  so the row's content identity is one instance before and after this change.
  The test stays as a regression guard on that invariant; F9's own proof rests on
  the source argument above and the handoff's parity scenario.
- Changes: `ChatTranscriptScrollView.swift`, `ChatRowStabilityTests.swift`.

### CT-27 stage A5 (F10) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: the notification pill is one structure at every value.
  `ChatNotificationView.body` no longer switches `Group { if showsDetailAction }`
  between an interactive pill and a plain one: hit testing, the 44-point target
  and the button trait are chosen by the value on the same view, and the detail
  action is guarded inside the tap handler. `ChatCompactPillSurface` no longer
  switches on its material: it applies one structure with the flat background and
  stroke driven to zero opacity when glass and `Glass.identity` when flat, so a
  flat-to-glass change is a value change and cannot remount the pill.
  `ChatCompactPillInteractionModifier` gained `addsButtonTrait` (default true) so
  a pill that owns no action keeps its own accessibility element without the
  button trait. A `HOSTED_TEST`-only environment box carries the hosted recorder
  to `ChatNotificationView.pill`, where `ChatHostedRowIdentityProbe` records the
  pill's own identity.
- Evidence (lane ct27):
  - `ChatRowStabilityTests` 4/4 (3.6 s), including
    `truncatedNoticeKeepsOnePillStructure`: the truncated error notice's pill
    records one identity across its truncation measurement.
  - Negative control: with `ChatNotificationView.body` restored to the
    `Group { if showsDetailAction }` form (and the rest of the change kept), the
    same test fails with `rowIdentityInstanceCounts["embedded-notice"] == 2` —
    the oracle catches the remount the finding describes.
  - Parity gate 7/7 (47.8 s) with the pill, surface and probe changes.
- Deviations: the first committed frame of a *truncated* notice is still the flat
  material, because truncation is only known from the measurement the first
  layout pass produces; what this change removes is the remount and the second
  structure. Making the first frame final would require deciding a
  `expandsOnTruncation` notice's material from data instead of its measured
  title, which would turn a non-truncated provider-error notice from a flat,
  non-interactive pill into a glass, tappable one — a visible product change this
  task does not ask for. The audit's "snapshot the first two frames" oracle
  therefore is not used; the identity probe replaces it.
- Changes: `ChatCompactPill.swift`, `ChatTranscriptEventViews.swift`,
  `ChatTranscriptScrollView.swift`, `ChatHostedProbe.swift`,
  `ChatRowStabilityTests.swift`.

### CT-27 stage A summary · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: CT-27's row-stability foundation stage A is on `ct-27-rows` in five
  commits, one per finding, each with its own evidence:
  `a8e9e3745` F13 (probe record + hosted journey, records today's failure),
  `e5d6ae642` F1 (one entrance clip structure), `fad397c93` F5 (a settled row
  owns no pinned height), `60159b86a` F9 (one prompt row structure across the
  canonical handoff), `c16acbe28` F10 (one notification pill structure).
- Evidence (lane ct27, all products rebuilt from this worktree; run directories
  under `~/Library/Developer/Tron/ios/test-runs/`):
  - `ChatRowStabilityTests` 4/4, 3.6-3.9 s (`…T004453Z-run.p62K3Y`,
    `…T004149Z-run.7BWDDF`): the journey, the entrance-admission identity gate,
    the canonical-handoff identity guard and the truncated-notice pill gate.
  - Parity gate 7/7 in 44.6-47.8 s after every finding
    (`…T004212Z-run.225ee8` for the last state; `…T235449Z-run.F0UpSn` for the
    A1 baseline). CT-14's motion evidence is the same suite's transition frames
    and moved within the recorded bounds each time.
  - Negative controls: the A1 journey recorded
    `entranceIdentityStable=false remountedRows=1:stability-entrance` before F1;
    the F10 pill gate failed with two identity instances when
    `ChatNotificationView.body` was temporarily restored to its
    `Group { if showsDetailAction }` form (`…T004043Z-run.Ioaikf`, exit 65).
  - Regression check: 206 unit tests in the four affected suites pass
    (`…T004418Z-run.oe3z0V`), and six entrance/growth/replacement harness tests
    pass (`…T004453Z-run.p62K3Y`).
- Deviations carried from the per-finding entries: CT-25's real-scroll detach
  driver is not on this branch (the journey moves the real native scroll view and
  admits the interaction phase through the coordinator's own path, probe in
  `.native` callback mode); the collapsed display card is a sheet-surface display
  because a tap that collapses an inline card cannot be injected; an inline
  display cannot reach its prepared state without a hosted media source, so the
  journey reports `inlineDisplaysPrepared=false` and height stability instead;
  F5 has no hosted height oracle; F9's switch could not be reproduced from the
  harness (the handoff ID is remembered in the same intake that installs the
  canonical row), so its test guards the invariant rather than demonstrating the
  switch.
- Not in this stage: the rest of CT-27's row list (ThinkingBlock and display-card
  disclosure `Layout`s, store-owned disclosure state, inline display loads per
  identity, row-owned sheet routes) is untouched, and the journey's
  `postMountResizes=0` is the measurement those changes will be judged against.
- For the next agent: the branch is ready for review; F1's device check for the
  Liquid Glass press region stays on the CT-7 checklist.

### CT-27 stage A follow-up · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: F5's growth animation now writes its height with the transaction that
  carries the animation *and* `admitsChatIncrementalGrowthAnimation`, instead of
  wrapping the write in a fresh `withAnimation` transaction. `withAnimation`
  supplies only the completion that clears `isAnimatingGrowth`, so a projection
  change in the same update cannot make `chatStableTranscriptUpdates` erase the
  growth animation by dropping the marker.
- Evidence (lane ct27): parity gate 7/7 (44.8 s), `streaming-tail-growth` worst
  0.03677 against 0.065; `ChatRowStabilityTests` 4/4 (3.7 s); harness
  `shortStreamingResponseClearsComposer` and `streamingBurstLatestProjection`
  pass.
- Changes: `ChatEntranceRows.swift`.

### CT-27 stage B1 (measurement) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: the measurement the stage's fixes are judged by. The journey now drains
  the native row samples at every phase boundary into a per-mount height history
  and reports the variants it finds: `withinMountVariants` (a row that presented
  a second height under one physical mount), `crossMountVariants` (a row whose
  height differs between mounts) and `phaseVariants` (a row whose published frame
  height differs between journey phases).
- Measured on stage A's code (lane ct27, run `20260929T011256Z-run.8jSUBv`, 1.5 s):
  `withinMountVariants=2` — both inline markdown display rows changed 242 → 222 pt
  under one mount (20 pt, F3's measured height arriving after admission) — and
  `phaseVariants=1: stability-thinking=82.7..132.7` (F2: the thinking trace's
  first mount committed the 16 pt line-estimate viewport and only a later remount
  reached the measured 66 pt one, a 50 pt difference between the row's own
  published heights).
- Why the A1 counter missed both: its record restarts at every physical mount and
  drops excluded frames, so a height that settles after a remount and a mount that
  only ever presents the estimate are invisible to it.
- This commit adds no assertion; it records what today's code does.
- Changes: `ChatRowStabilityTests.swift`.

### CT-27 stage B2 (F2) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: the compact thinking trace is measured in the layout that places it.
  `ThinkingTailLayout` (a `Layout` + `Animatable`) holds the paragraph and the
  four reference lines as its two subviews, returns `min(paragraph, reference)`
  from `sizeThatFits`, and offsets the paragraph by its tail. `ThinkingBlock` no
  longer derives its height from geometry→state: `contentHeight` and
  `referenceHeight` are measured by `onGeometryChange` on the layout's own
  subviews and now only decide the overflow flag (the tap target, the
  accessibility trait and the tail mask), which does not change layout. The
  hidden duplicate measurement text and its preference key are deleted, with
  `ChatThinkingTraceLayoutPolicy.initialViewportHeight` (the 16 pt a segment
  estimate) and the removed `maximumHeight` state.
- Growth motion is scoped to `sourceLength` (the trace's own source), so a mount,
  a width change or a measurement landing cannot grow the row; the layout's
  animatable `contentHeight` still interpolates the viewport and the tail offset
  while the trace streams.
- Evidence (lane ct27, all products rebuilt from this worktree):
  - `ChatRowStabilityTests` 4/4 (3.6-4.0 s, `…T013845Z-run.adYYKE`):
    `phaseVariants=0` (was `1: stability-thinking=82.7..132.7`), the thinking row
    now mounts at its measured 132.7 pt frame and keeps it at every phase, and the
    journey asserts that the wrapped trace measured itself
    (`thinking-run:thinking-0:line:0=content:99.0:reference:66.0:overflowing:true`;
    the viewport is the 66.0 pt four-line reference the trace overflows).
  - Parity gate 7/7 in 46.8 s (`…T013635Z-run.VTfJgW`); CT-14 motion evidence
    unchanged (`streaming-tail-growth` worst 0.03899, `outgoing-entrance` 0.05488
    against the gate's 0.065 transition bound).
  - Regression: `ThinkingTraceSheetTests`, `StreamingTextRevealContinuityTests`
    and `StreamingTextRevealPacingTests` pass; the full
    `ChatViewScrollHarnessTests` suite reports the same single pre-existing
    failure with and without this change (`displacedRetainedResume` exceeds its
    15 s watchdog on stage A's code too — verified by stashing this work).
- Negative control: the stage B1 run above is the pre-fix measurement of the same
  oracle (`phaseVariants=1`); the journey's new assertion fails on that code and
  passes here.
- Deviations: (a) the overflow flag still costs one geometry→state write per
  measurement (the audit allows it because it does not change layout); (b) no
  motion evidence exists for a thinking row's streaming growth in the parity gate
  — the gate has no thinking scenario — so the growth animation is preserved by
  construction (the same `smooth(0.16)` curve driven by the layout's animatable
  height) and is not gate-verified; (c) the trace's measurements are read through
  a new `HOSTED_TEST`-only probe because nothing else observes them.
- Changes: `TranscriptRow.swift`, `StreamingTextReveal.swift`,
  `ChatHostedProbe.swift`, `ChatTranscriptScrollView.swift`,
  `ChatRowStabilityTests.swift`.

### CT-27 stage B3 (F3) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: an inline display card's disclosure phase is transcript state, and the
  card's host measures both layers in the pass that places them.
  - `ChatTranscriptPresentationStore` owns the phase, keyed by the display's
    presentation identity, with `inlineDisclosurePhase(for:)`,
    `proposedInlineDisclosure`, `begin`/`complete`/`settle`, and prunes the
    dictionary to the installed rows' own display identities on every install
    (`pruneInlineDisclosurePhases`, cleared in `reset()`).
  - `DisclosureLayout` (a `Layout` + `Animatable`) replaces the ZStack and the
    measured heights: it holds the expanded card and the pill, returns
    `pill + (expanded − pill) × progress` through
    `DisplayInlineLayoutPolicy.disclosureHeight`, and keeps both layers at their
    natural height. `expandedHeight`, `pillHeight`, `recordDisclosureHeight` and
    the two `onGeometryChange` measurement writes are deleted.
  - The phase reaches the row as a *row input*
    (`ChatTranscriptRenderRow.inlineDisclosurePhase`, part of its `==`,
    threaded through `ToolRunView` to `DisplayToolView`), not only as an
    observable read: the rows are `.equatable()`, and an observable read below
    that boundary is skipped when the row's inputs are unchanged. Verified:
    without the input the card's body never re-rendered after the collapse and
    the row kept its expanded height until the next remount.
- Evidence (lane ct27, all products rebuilt from this worktree):
  - `ChatRowStabilityTests` 6/6 (6.1 s, `…T022607Z-run.BQW5ix`): the journey
    (`phaseVariants=0`, `withinMountVariants` limited to the two inline markdown
    displays whose card content arrives when the transcript becomes ready — F4,
    not this stage), `collapsedInlineDisplayKeepsPhaseAndMotion` (the collapse
    sequence frame by frame: ≥2 frames holding the expanded height during the
    fade, a monotonic contract, no frame carrying more than 60% of the change,
    ≥3 intermediate heights, and the collapsed height kept after the transcript
    scrolls to the oldest row and back), and
    `disclosurePhaseIsBoundedToInstalledRows` (a display that leaves the
    installed rows is reinstalled expanded).
  - Parity gate 7/7 in 49.7 s (`…T022001Z-run.J22i94`); `queued-card-to-sent-row`
    worst 0.04639 against the 0.065 transition bound.
  - `ChatTranscriptPresentationStoreTests` 54/54; the full
    `ChatViewScrollHarnessTests` suite reports only the same pre-existing
    `displacedRetainedResume` watchdog failure as stage A.
- Deviations: (a) the audit's F3 premise — a collapsed card comes back expanded
  because the row's `@State` is lost on remount — is **not reproducible in this
  hosted harness**: every fixture row keeps one native row identity (one mount,
  1 mount entry per row) and one content identity across the journey's detach
  and oldest-row scroll while `physicalRowAppearanceCounts` counts 2–4
  `onAppear` events, so SwiftUI preserves row `@State` here. The negative
  control (the pre-change row-local `@State` disclosure, with the store and the
  layout kept) still passes the collapse test. The store ownership therefore
  rests on the audit's direction, on the bounded-phase test, and on the
  structural deletion of the measure→state→frame loop; the collapse test is a
  guard, not a reproduction. (b) The journey's `remounts=8/9` field counts
  `onAppear` re-fires, not new mounts — stage A's label overstates what the
  journey exercises; it is left as-is here and noted for review.
- Changes: `ChatTranscriptPresentationStore.swift`, `ChatDisplayViews.swift`,
  `ChatTranscriptScrollView.swift`, `ChatEntranceRows.swift`,
  `ChatToolRunViews.swift`, `ChatViewScrollHarnessTests.swift`,
  `ChatRowStabilityTests.swift`, `ChatCommittedLedgerTests.swift`,
  `SessionSheetPresentationTests.swift`.

### CT-27 stage B4 (F8) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: the prompt replacement host renders from its `row` input and keeps only
  the outgoing queued card as state.
  - `displayed`, `naturalHeight`, `presentedHeight`,
    `awaitingReplacementHeightRevision` and the height-choreography
    `onGeometryChange`/`naturalHeightChanged` loop are deleted; the host renders
    `content(row, …)` directly and `onChange(of: row)` receives both values, so
    the retarget no longer needs a mirror.
  - `ReplacementHeightLayout` (a `Layout` + `Animatable`) holds the canonical row
    and the outgoing card, measures both in the pass that places them, and returns
    the interpolated height driven by the same `promptReplacementProgress` as the
    cross-fade. `ChatPromptReplacementHeightPolicy` still decides whether a
    replacement may interpolate (Reduce Motion, a covered surface or a change over
    2,000 pt installs the incoming height at once) with the heights the layout
    measured. The outgoing layer is clipped to the row's current height by its own
    placement, as before.
- Evidence (lane ct27, all products rebuilt from this worktree):
  - Parity gate 7/7 in 44.8 s (`…T030011Z-run.ovXKL6`); `queued-card-to-sent-row`
    worst 0.03307 against the 0.065 transition bound (CT-14's queued-card
    cross-fade and shrink evidence).
  - Harness `queuedPromptCanonicalReplacementShrinks`: heights
    `[80, 80, 80, 80, 75, 67, 59, 53, 50, 48, 46, 45, 45, 44, … 44]` — the fade
    still holds the queued card's height before a monotonic contract with ≥3
    intermediate heights and no jump, and `maxTail=0.0` (the tail is held).
  - `ChatRowStabilityTests` 7/7 (8.5 s), including
    `streamingRowEvaluatesOncePerInstall`: A/B on the same nine-install streaming
    fixture measured 28 host evaluations with the row-direct host and 36 with a
    mirror restored (+1 per changed row update, which is the mirror's stale
    render; the harness's own re-render rate is the noise floor).
  - The full `ChatViewScrollHarnessTests` suite reports only the same pre-existing
    `displacedRetainedResume` watchdog failure as stage A.
- Deviations: (a) the notification progress→settled animation moved from the row
  host's mirrored, marker-carrying state write into `ChatNotificationView`'s own
  content transition (the same `inPlaceContentReplacementAnimation` curve and the
  same `showsProgress` condition). A host-level animation cannot survive below the
  row content's `chatStableTranscriptUpdates`, and the audit's fix does not name
  this case. The deleted `admitsChatNotificationReplacementAnimation` marker had
  no other user. No oracle covers this motion — the parity gate has no runtime
  notification scenario — so it is preserved by construction, not gate-verified.
    (b) `ChatViewScrollHarnessTests`'s compaction-settlement wait now also requires
  a non-empty viewport observation, which is the intent its own comment already
  states for the earlier waits: a row that applies its content in the install
  frame makes that frame carry a not-yet-settled viewport, so the previous wait
  could sample the intermediate frame. Verified stable over six consecutive runs.
- Changes: `ChatTranscriptScrollView.swift`, `ChatTranscriptEventViews.swift`,
  `ChatContentTransition.swift`, `ChatHostedProbe.swift`,
  `ChatViewScrollHarnessTests.swift`, `ChatRowStabilityTests.swift`.

### CT-27 stage B summary · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: the three measure→state→frame loops the audit's F2, F3 and F8 name are
  gone, each with its own evidence, in four commits on `ct-27-rows`:
  `9999c265c` (per-mount and per-phase height variants in the row-stability
  journey, recording today's failures), `8ff12834a` F2 (`ThinkingTailLayout`),
  `bff461f27` F3 (store-owned disclosure phase + `DisclosureLayout`),
  `c6b48deaa` F8 (the replacement host renders from its row +
  `ReplacementHeightLayout`).
- Evidence (lane ct27, all products rebuilt from this worktree; run directories
  under `~/Library/Developer/Tron/ios/test-runs/`):
  - `ChatRowStabilityTests` 7/7 in 8.5 s (`…T022607Z-run.BQW5ix` for F3's
    six-test state): the journey, the F2 trace gate, the two disclosure tests,
    and the streaming host-evaluation count.
  - Parity gate 7/7 after every finding, worst frames 44.6–49.7 s
    (`…T022001Z-run.J22i94` for F3, `…T030011Z-run.ovXKL6` for F8); CT-14 motion
    evidence unchanged within the gate's bounds.
  - Full unit run: 1,772 tests in 148 suites with exactly one failure, the
    pre-existing `displacedRetainedResume` watchdog timeout, which fails
    identically on stage A's code (verified by stashing this work).
- Deviations and audit corrections:
  - **SwiftUI preserves a row's `@State` across this harness's lazy window
    changes.** Every fixture row keeps one native row identity (one mount, one
    entry in the journey's per-mount history) and one content identity across the
    journey's detach and oldest-row scroll, while
    `physicalRowAppearanceCounts` records 2–4 `onAppear` events. Therefore F3's
    premise (a collapsed card comes back expanded because the row's state is
    lost) is not reproducible here, and the journey's `remounts=8/9` field
    measures `onAppear` re-fires rather than lazy remounts. Stage A's claim that
    "every fixture row left the lazy range and mounted again" is not established
    by that counter; what the journey proves is that views leave and re-enter the
    viewport. A fixture that forces a real remount (or the device checklist) is
    the next step for the state-durability findings.
  - F8's notification case: the progress→settled animation moved from the row
    host's marker-carrying state write to `ChatNotificationView`'s own content
    transition. No oracle covers that motion.
  - The audit's "body-evaluation count per token" proof has a high noise floor in
    this harness (≈2 extra host evaluations per install from other re-renders);
    the A/B difference it measures is exactly +1 per changed row, so it is kept
    as reported evidence with a loose bound.
- Not in this stage: F4 (inline display loads per identity, reserved heights and
  retry), F11 (row-owned sheet routes), F12, and the flip-specific probes F6/F7;
  the two inline markdown displays' 20 pt post-mount change is their card content
  arriving when the transcript becomes ready (F4's path), reported by the journey
  rather than asserted away.
- For the next agent: the journey's per-mount record, its per-phase record, the
  collapsed-card sequence and the host-evaluation count are the stage's
  regression guards; the disclosure phase's durability should be re-checked on
  the CT-7 device checklist, where SwiftUI discards row state more aggressively
  than this harness shows.

### CT-27 stage C (F11) · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: a row's detail sheet is presented by the transcript, not by the row.
  `ChatTranscriptSheetRoutes.swift` (new) holds the three route values (a tool
  run's detail, a wrapped thinking trace, a transcript event's detail), the
  row-facing owner (`ChatTranscriptSheetRouteOwner`, owned by
  `ChatTranscriptPresentationStore` and cleared in its `reset()`) and
  `ChatTranscriptSheetHost`, mounted once above the rows in
  `ChatTranscriptScrollView` and in the read-only child transcript's own scroll
  view.
  - The host re-resolves an open tool run from the projection it owns on every
    install (`resolveToolDetails(callIDs:installationTag:)`), retires a route that
    no longer resolves, and owns the deferred `ToolDisplayHandoff` the row used to
    own. The opened run keeps its identity; only the install generation and the
    resolved payloads move with the projection.
  - A dismissal is not a cancellation. The interrupted checkpoint cancelled the
    staged handoff on every route change, including the transition to nil, so the
    deferred display command was dropped. Cancelling only when a *new* route is
    presented fixed it, caught by `SessionSheetPresentationTests`.
  - `ToolRunView`, `ThinkingBlock` and `ChatNotificationView` present through the
    environment owner. A row rendered outside a transcript (a bare fixture) has no
    detail action instead of a second owner; the read-only child transcript's rows
    keep their own owner.
- Evidence (lane ct27, all products rebuilt from this worktree):
  - `ChatRowStabilityTests` 10/10 in 9.8 s (`20260929T065153Z-run.y5mY7w`): the new
    `toolDetailOutlivesItsStreamingRow` printed
    `streamed=4575.0 viewports=6.8 rowLeftViewport=true sheetPresented=true
    detailMounted=true` — a grouped run's detail opens from the row's own chip,
    the reader streams 4,575 pt (6.8 viewports) until the row leaves the viewport,
    and the sheet with its own rows is still presented.
  - `SessionSheetPresentationTests` under the UI-validation tier: the five
    grouped-route tests pass after `checkGroupedHandoff`'s fixture mounts its run
    through `ChatTranscriptSheetHost`, as the mounted chat does.
  - Parity gate 7/7 in 45.7 s (`20260929T065433Z-run.ibWLJi`): worst frame
    `tool-chip-entrance` 0.05174 against the 0.065 transition bound,
    `streaming-tail-growth` 0.03704.
  - Full `ChatViewScrollHarnessTests` 54/55 in 103.7 s
    (`20260929T065558Z-run.F0U2rS`): the only failure is the pre-existing
    `displacedRetainedResume` 15 s watchdog timeout recorded since stage A;
    `hostedOpeningRevealIsMonotonic` passed here.
  - `ChatTranscriptPresentationStoreTests` 54/54 (`20260929T065937Z-run.7hTpZn`).
- Audit correction (negative control): F11's premise is **not reproducible in
  this hosted harness**. With the row-owned sheet restored (one build, then
  reverted), the same journey still passed — `rowLeftViewport=true` with the sheet
  still presented — because the harness keeps a lazy row's view alive: the row's
  own chip retires (`onDisappear`) while its view, and a row-owned sheet, survives.
  The fixture therefore proves the route path (open, refresh from the install, and
  presentation surviving streaming that pushes the row out of the viewport), not
  the discarded row. F11's discard case joins the state-durability items on the
  CT-7 device checklist, as stage B's correction already asked.
- Deviations: (a) the notification detail's presentation identity now carries its
  event id (`chat.transcript-event-detail.<id>`) instead of one constant identity;
  nothing else read the constant. (b) The attachment and file preview requests and
  the read-only child's tool detail stay row-owned: F11's list names the tool,
  thinking and notification details, and the child's tool rows are not part of the
  main transcript's lazy window.
- Changes: `ChatTranscriptSheetRoutes.swift` (new), `ChatToolRunViews.swift`,
  `ChatTranscriptEventViews.swift`, `ChatTranscriptPresentationStore.swift`,
  `ChatTranscriptScrollView.swift`, `SessionProcessSheets.swift`,
  `TranscriptRow.swift`, `ChatRowStabilityTests.swift`,
  `ChatViewScrollHarnessTests.swift`, `SessionSheetPresentationTests.swift`.

### CT-27 completed · 2026-09-28 · chat scroll session (worker lane ct-27-rows)

- Result: the row-stability foundation is done on `ct-27-rows` (not merged, not
  pushed), one commit per finding plus the branch's plan commits:
  `a8e9e3745` F13, `e5d6ae642` F1, `fad397c93` F5, `60159b86a` F9, `c16acbe28`
  F10, `9999c265c` B1 measurement, `8ff12834a` F2, `bff461f27` F3, `c6b48deaa` F8,
  `b4fdbddaa` F5 follow-up, `3b2ac8f79` F12, `a0e81d907` F4, `41c1ac37b` F11.
  The audit's F1-F5, F8-F13 are addressed; F6 and F7 are flip-specific and stay
  with CT-23.
- Final evidence (lane ct27, products rebuilt from this worktree, run directories
  under `~/Library/Developer/Tron/ios/test-runs/`):
  - Row stability: `ChatRowStabilityTests` 10/10. The journey reports
    `postMountResizes=0 remountedRows=0 phaseVariants=0` with
    `withinMountVariants=2` (both inline markdown displays' 20 pt change as their
    card content arrives at readiness, which is F4's path and *not* a settled
    row re-measuring itself), `entranceIdentityStable=true`,
    `collapsedStaysCollapsed=true`, `inlineDisplaysStable=true`,
    `excludedRows=1`, `semanticFrameCallbacks=233`.
  - Parity: 7/7, worst transition `tool-chip-entrance` 0.05174 against 0.065
    (CT-14 motion evidence unchanged within the gate).
  - Full `ChatViewScrollHarnessTests` 54/55, only the pre-existing
    `displacedRetainedResume` watchdog timeout.
  - `ChatTranscriptPresentationStoreTests` 54/54 and the previously run 206 unit
    tests in the store, ledger and sheet suites.
- Deviations and audit corrections the next agent must not rediscover:
  - **This harness never forces a real remount.** A row keeps one native and one
    content view identity across the journey's detach and oldest-row scroll while
    its own `onAppear`/`onDisappear` fire 2-4 times, so SwiftUI preserves row
    `@State` here. Therefore F3's (lost disclosure state), F9's (canonical handoff
    switch) and F11's (discarded row dismisses its sheet) premises are not
    reproducible hosted; their fixes rest on the source argument, their guards and
    the audit's direction. The journey's `remounts`/`remountedRows` fields count
    `onAppear` re-fires, not new mounts; stage A's wording overstated them.
  - F5 has no hosted height oracle (the height it pinned was always the natural
    height, and the F13 counter reads zero either way); F2's thinking growth and
    F8's notification replacement have no parity scenario, so their motion is
    preserved by construction rather than gate-verified. F10's first committed
    frame for a truncated notice is still the flat material, as recorded in stage
    A.
  - F4's inline starvation path needs a media source, so the plain stability
    harness reports `inlineDisplaysPrepared=false`; `twoAdjacentInlineDisplaysBothPrepare`
    and `inlineDisplayKeepsPreparedDocumentAcrossScroll` are the fixtures that
    serve artifacts and assert the prepared state, one fetch per identity.
  - CT-25's real-scroll detach driver is not on this branch: the journey moves the
    real native scroll view and admits the reader's interaction phase through the
    coordinator's own path, with the probe in `.native` callback mode.
- On the CT-7 device checklist (added to its scope): the collapsed inline display
  card coming back collapsed, a detail sheet surviving its row being discarded,
  and F1's Liquid Glass press-and-drag region — the three durability checks this
  hosted harness cannot force.
- Not in CT-27: F6/F7's flip probes, CT-25's oracle foundation and CT-26's hot
  path remain for their own tasks.

### Review fixes (CT-27 review) · 2026-09-29 · chat scroll session (worker lane ct27)

- Result: every blocking and non-blocking finding in the CT-27 review is fixed on
  `ct-27-rows` (not merged, not pushed), one commit per finding:
  `2e165adce` (inline artifacts, capacity, slot leak), `f405dd6c4` (detail sheets
  follow the install), `7bd65bb63` (thinking growth motion), `70a6d4087`
  (disclosure identity, settled clip, informational pills), `534ea6717`
  (revision-bump guard), `4989adcb0` (informational pill activation). All products
  were rebuilt from this worktree; every cited run is stamped `dirty: false` at
  `4989adcb0`.
- Findings, fixes and evidence:
  - **P0 inline artifacts over 1 MB never rendered.** The loader retains prepared
    inline artifacts in a bounded store and hands anything above one megabyte to
    its caller, but both cards rendered only from the store, so a large PDF or
    HTML loaded and then showed its placeholder forever. Each card now holds the
    value its own load returns and reads the store only for the first frame after
    a remount.
    Evidence: new `oversizedInlineArtifactRendersInItsCard` mounts a 3,150,578-byte
    inline PDF (the fixture itself prepares through the card's own policy) and
    reports `published=3150578 expected=3150578 fetches=1`; on the pre-fix code
    the card published nothing and the fixture timed out.
  - **P1 eviction stranded a mounted card.** Same ownership change: the mounted
    card owns its value, so the store's 8-artifact/4-MB bound and its eviction now
    reach remounts only. Evidence: the same fixture's card starts no second
    request (`fetches=1`) and `inlineDisplayKeepsPreparedDocumentAcrossScroll`
    keeps its prepared height across a real scroll out and back (`before`/`after`
    216.0, fetches 1,1).
  - **P1 capacity produced permanent failures.** A card that arrived when all four
    inline flights were busy threw `capacityExceeded` and (after one retry) failed
    for good. Requests now wait for a slot in arrival order; the one-shot retry in
    both cards is deleted. Evidence: `ChatMediaLoaderTests."an inline artifact
    request waits for a slot instead of failing"` starts one more card than the
    ceiling with every fetch held, then all of them complete; pre-fix the fifth
    threw `capacityExceeded`.
  - **P2 flight slots leaked on a failed flight whose waiter was cancelled.** A
    failed flight now retires even when the waiter that observes it was cancelled.
    Evidence: `ChatMediaLoaderTests."a failed inline flight whose waiter was
    cancelled releases its slot"` reports `inlineArtifactFlights=0` and loads the
    next artifact; pre-fix it reported 4 leaked flights and the next load threw
    `capacityExceeded`.
  - **P1 hoisted sheets froze their content.** A thinking-trace or event detail
    route carried the content its row resolved at tap time, so an open sheet never
    followed later installs and the trace sheet's tail-follow was dead code. The
    route now carries the identity its row presented (plus what the row resolved as
    a fallback) and the host resolves the content from the install it owns:
    `ChatTranscriptDetailResolution` serves the main transcript and the read-only
    child transcript, `ChatThinkingTraceContent` is the one assembly of a trace's
    inline, and the display moved off `ThinkingBlock`. Evidence: new
    `thinkingDetailFollowsLiveTraceContent` opens the trace from its row's own
    control and grows the newest row through two installs: `opened=185 longest=1910
    samples=3 offset=0.0->734.0` (the sheet shows the 60-line trace and follows its
    tail); pre-fix the same fixture reported `opened=185 longest=185 samples=1
    offset=0.0->0.0`.
  - **P1 thinking growth motion changed.** The viewport came from the layout's
    animatable content height while the tail offset came from the height the same
    pass had measured, and the animation was keyed on `sourceLength`, which
    changes in the install that suppresses row animations. Both values now come
    from the one interpolated content height and the animation is keyed on that
    pair (the frame-and-offset pair the animation this replaces keyed on), with the
    mount's first measurement explicitly not animating.
    - **Deviation from the instruction line.** The supervisor asked for
      "ThinkingTailLayout must not take a geometry→state input" as well. That is
      not implementable together with F2's invariant: an animated row height or
      tail offset is a view-level animatable value, so one must come from a
      previously measured height, and removing the input restores main's first-mount
      estimate and its `phaseVariants=1` (stage B1). The supervisor approved
      Option A (keep the input, derive both values from it) and asked for this
      deviation to be recorded with its reason.
    - Evidence: new `thinkingTraceGrowthMotionMatchesTheFrameAndOffsetAnimation`
      samples the trace's own rendered geometry at every display boundary through
      four installed projections. Under four lines the viewport grows 16.7 → 49.7 pt
      through 27 intermediate frames (largest step 4.0 pt) with the tail flush at
      0; past four lines the viewport stays pinned at 66.0 while the tail slides
      −16.3 → −98.7 through 44 frames (largest step 12.4 pt). The same fixture on
      the pre-fix code reports one intermediate frame for the viewport (largest
      step 16.7), two for the tail (largest step 33.0), and an under-four tail
      oscillating between 0 and −16.3 every frame. Sequences are written to
      `packages/ios-app/build/row-stability/trace-motion.json`.
    - Not run: the numeric **main-side** comparison the supervisor asked for. This
      harness has no thinking-trace geometry probe on `main` and the scenario uses
      branch-only harness APIs, so the comparison is reported as branch sequences
      plus the pre-fix control above; the motion is preserved by construction
      (one animation key of the same derived pair on the same 0.16 s curve). A
      main-side port is the honest way to close that gap.
  - **P2 disclosure identity included the revision.** The phase key is now
    `DisplayProjection.disclosureIdentity` (the display's own identity, and for a
    live view its display plus producer generation), so a content revision cannot
    re-expand a collapsed card and two live views never share one phase.
    Evidence: `collapsedInlineDisplayKeepsPhaseAndMotion` installs a revision-2
    display after the reader collapsed the card and reports `expanded=222.0
    collapsed=36.7 afterRevision=36.7`. Correction: this harness keeps the card
    collapsed even with the revision in the key, so that assertion guards the
    invariant rather than reproducing the re-expansion; the pre-fix key is
    observable in the collapse control's identity (`display-collapse:<callID>:1`
    versus `<callID>`), which is what the journey's own control lookup uses.
  - **P2 the 128 pt settled clip trimmed row overflow.** `settledOverflow` is now
    the bound of a display card's own expansion (its inline viewport, its header
    and the row's effect gutter) instead of 128 pt, which cut a card that keeps its
    expanded layer at natural height while its own host animates from the
    collapsed pill. Evidence: new `settledEntranceClipKeepsRowOverflow` renders a
    settled entrance row whose content reports 44 pt and draws 400 pt: the fixture
    red is visible at 80 and 300 pt (`settledOverflow=388.0`); pre-fix (128) the
    same fixture was trimmed past ~200 pt.
  - **P2 informational pills carried an activation action.** The interaction now
    takes an optional action; a notice that owns no detail action passes none and
    declares it does not respond to user interaction.
    - Deviation: the action is still attached at every value rather than being
      removed by a branch. A branch at that seam rebuilt the pill's own surface —
      `truncatedNoticeKeepsOnePillStructure` measured two pill instances for one
      notice while the branch was in place — so the F10 guard and the single
      structure were kept and the actionless pill is expressed as
      `accessibilityRespondsToUserInteraction(false)`. VoiceOver confirmation is a
      device check and is added to the CT-7 checklist below.
    Evidence: `truncatedNoticeKeepsOnePillStructure` passes with one pill instance
    (`rowIdentityInstanceCounts["embedded-notice"] == 1`).
  - **P2 F4 and F12 had no handoff evidence.**
    - F4 (`a0e81d907`) inline display loads per identity: `ChatRowStabilityTests`
      `twoAdjacentInlineDisplaysBothPrepare` reports `prepared=2/2 heights=216.0,216.0
      fetches=1,1` and `inlineDisplayKeepsPreparedDocumentAcrossScroll` reports
      `before=216.0,216.0 after=216.0,216.0 fetches=1,1 appearances=2,2`, so two
      adjacent cards prepare independently, each fetches its own artifact exactly
      once, and a card that leaves and re-enters the window renders what its
      identity already prepared. The new oversized-PDF fixture adds the boundary
      above the retention ceiling (`fetches=1`, published by the card itself).
    - F12 (`3b2ac8f79`) projection-less entries are filtered in the kernel:
      `ChatTranscriptProjectionKernelTests` (65 tests in the 144-test run)
      covers the added assertion, and the journey's `excludedRows=1` with
      `installedProjectionRowCount > RowStabilityFixture.rowIDs.count` is the
      hosted counterpart (a summary/model/thinking receipt is never installed as a
      padded lazy child).
- Runs (all lane ct27, products rebuilt from this worktree, `dirty: false` at
  `4989adcb0`, run directories under `~/Library/Developer/Tron/ios/test-runs/`):
  - `ChatRowStabilityTests` 14/14 in 14.6 s (`20260929T094534Z-run.ANbawH`).
  - Parity gate 7/7 in 45.6 s (`20260929T094638Z-run.a5ONuo`): worst transitions
    `ordinary-send-keyboard-up` 0.05483, `queued-card-to-sent-row` 0.03885,
    `streaming-tail-growth` 0.03579, `tool-chip-entrance` 0.03273 against the
    0.065 transition bound; at-rest worst 0.01319 against 0.025.
  - `ChatMediaLoaderTests` (25), `ChatTranscriptPresentationStoreTests` (54),
    `ChatTranscriptProjectionKernelTests` (65) and `ThinkingTraceSheetTests`: 144
    tests in 3 Swift Testing suites plus that XCTest suite, all passing
    (`20260929T094818Z-run.7cVw8Z`).
  - `SessionSheetPresentationTests` 23/23 in 67.3 s
    (`20260929T095057Z-run.blK32l`).
- Not done here, deliberately: `ChatRowStabilityTests` is **not** ported to
  CT-25's oracle (the supervisor merges CT-25 first), and the branch does not
  otherwise touch `ChatViewScrollHarnessTests.swift` beyond the probe seams CT-27
  already owned. The CT-25/CT-27 conflicts the review lists (harness parameters,
  `displaceNativeTranscriptFromTail` and the compacted-settlement predicate) are
  still open for the merge.
- On the CT-7 device checklist (added): device VoiceOver confirmation that an
  informational notice offers no activation and a detail-bearing notice still
  does, that a card above the retention ceiling renders on device, and that a
  trace's tail slides smoothly while it streams.

### CT-27 merged with CT-25 · 2026-09-29 · chat scroll session (worker lane ct27)

- Result: `ct-27-rows` builds and passes on the merged base. The merge
  (`4b27f3a21`) brought CT-25's window-coordinate oracles to `main` and deleted
  every scroll-space chat-test helper, which `ChatRowStabilityTests` still
  called, so the suite did not compile. It is ported onto CT-25's API; no
  product code changed.

  **The port** (fixture only, `ChatRowStabilityTests.swift`):
  - `scrollReader(byVisualPoints:)` replaces
    `displaceNativeTranscriptFromTail` for the oldest-row and return moves (the
    journey's oldest phases and `detachToOldestAndReturn`);
  - `detachReaderMidHistory()` replaces the journey's hand-driven detach: the
    reader moves 1.5 viewports up the real view and the pan's own phase
    callbacks are reported, instead of the deleted sequence writing an offset
    and a container height no scroll view produced;
  - `returnReaderToPinnedTail()` replaces the raw move back to offset 0, so a
    return waits for the coordinator's own pinned state;
  - native-row reads move from `isVisible`/`frame` to
    `isOnScreen`/`windowFrame`.

- Evidence (lane ct27, products built and stamped `dirty: false` at
  `da63e3ffbb7724dfa2f4a666c71db84ba1e7725f`, run directories under
  `~/Library/Developer/Tron/ios/test-runs/`):
  - `ChatRowStabilityTests` 14/14 in 18.2 s (`20260929T100509Z-run.HdFVVr`,
    ui-validation). The journey prints
    `ROW-STABILITY phases=open,entrance,detached,oldest-1,return-1,oldest-2,return-2
    postMountResizes=0 maxPostMountResize=0.0 resizedRows=0 remountedRows=0
    remounts=8/9 withinMountVariants=2:…display-inline-a=1/1@20.0,…display-inline-b=1/1@20.0
    crossMountVariants=0 phaseVariants=0 … entranceIdentityStable=true
    excludedRows=1 semanticFrameCallbacks=230`: the journey reaches the oldest
    loaded row and returns twice, and every settled-row invariant holds.
  - Parity gate 10/10 in 59.8 s (`20260929T100610Z-run.dKvnrj`, ui-validation)
    against the committed v2 manifest — not re-recorded; worst transitions
    `ordinary-send-keyboard-up` 0.05494, `tool-chip-entrance` 0.05220,
    `queued-card-to-sent-row` 0.05015, `streaming-tail-growth` 0.03748 against
    the 0.065 bound, at-rest worst 0.01418 against 0.025, `verdict=pass`.
  - `ChatViewScrollHarnessTests` 65/65 in 86.9 s
    (`20260929T101017Z-run.XpxNK1`). The first full-suite run
    (`20260929T100736Z-run.riFWq0`) failed one test,
    `displacedRetainedResume()`, by its 15 s watchdog under the full suite's
    load; it passes alone in 7.6 s (`20260929T100944Z-run.Kz8PNa`) and in the
    re-run, so it is the known load-related watchdog flake this stage and
    CT-25's stage A already recorded, not a CT-27 regression (the port touches
    no code that test drives).
  - `ChatMediaLoaderTests`, `ChatTranscriptPresentationStoreTests`,
    `ChatTranscriptProjectionKernelTests`, `ThinkingTraceSheetTests` and
    `SessionSheetPresentationTests` (unit tier): 147 tests pass in 6.8 s
    (`20260929T101219Z-run.96gomc`). The unit plan skips most of
    `SessionSheetPresentationTests`, so it also ran in the ui-validation tier:
    23/23 in 72.2 s (`20260929T101333Z-run.JzZtlX`).
- Changes: the merge commit `4b27f3a21` (supervisor) and `da63e3ffb`
  (`packages/ios-app/Tests/UI/ChatRowStabilityTests.swift`, this plan).
- Deviations:
  - `detachToOldestAndReturn` detaches through `detachReaderByRealScroll` (the
    status-bar path, which lands at the oldest loaded row) rather than a
    mid-history scroll, because its callers' subject is a row leaving and
    re-entering the lazy range. The journey's own detach phase keeps the
    mid-history `detachReaderMidHistory`, so the streaming and keyboard phases
    have a viewport above the anchor to move.
  - `ROW-STABILITY-INLINE` reads `heights=242.0,242.0` where the pre-merge
    review measured `216.0,216.0`: a measurement timing difference (the fixture
    reads the row frame as soon as the loader retains both artifacts), not a
    product change — the settled-height fixture still reports `216.0,216.0`.
- Not done here: `main` is not pushed and CT-23 stays out of scope. The
  `displacedRetainedResume` watchdog flake is recorded, not fixed; it is the
  heavy-suite load flake, not a correctness failure.
- For the next agent: CT-27 is complete and green on the merged base on
  `ct-27-rows`; the branch is ready for the supervisor's merge, and CT-23
  resumes against CT-25's gates unchanged.

### CT-23 re-application stage 3 · 2026-09-29 · chat scroll session (worker lane ct23b)

- Result: the owner now maps every frame, correction and scroll point (review
  P1-1, P1-2, P2-2, P2-3), the keyboard's own ramp and the flipped path's opening
  classification are gated (P2-4, P1-2), and the detached reader's failure is
  traced to its owner: **UIKit's overlay-inset adjustment**, not this app's
  anchors. P1-3 is not fixed and is left as the next stage's first task with the
  stack that names its cause.

  **(a) The frame space is measured, and frames now enter through the owner.**
  The flipped scroll view's own `ScrollView` frames measure *upward* from the
  visual bottom: at the pinned tail the 12 pt marker reports `[0, 12]` while it
  is drawn at `[663, 675]` (window), the composer edge being
  `containerHeight = 675` — so `transcriptFrame(_:containerHeight:)` reflects
  them about the container, and `semanticFrameChanged` is the one place that
  applies it. Consumers then read today's semantics: `semanticAnchor` picks the
  visually topmost row (it picked the visually *lowest* before), and the marker's
  own placement classifies as `aligned` when pinned. With that adapter the
  review's false `chat.anomaly.opening-viewport-displaced` at a *pinned* opening
  is gone (the pinned dump reads the marker at the composer edge), but the
  opening still passes through un-settled states that can record one: the
  keyboard journey measures `displaced=0` in seven focused runs and 1 in two of
  the three heavy suite runs, so the count is printed and not gated — that
  transient is the opening's own, not the pinned misclassification the review
  named.

  **(b) Every `.offsetY` command goes through the owner.** The staged catch-up's
  point, the layout restore's correction and the prepend correction were the
  three sites that handed the coordinator's model directly to `scrollTo(y:)`,
  which on the flipped path is the *reflection* of the scroll view's offset: the
  staged point alone landed ~6,900 pt into the oldest history, and the smooth
  second step then animated the whole transcript back. Now
  `correctedOffsetY(currentModelOffsetY:visualOffset:)` owns the correction's sign
  and the `max(0, …)` clamp (which is today's model only), and
  `scrollOffsetY(forModelOffsetY:geometry:)` maps the model point back at
  `ChatView`'s single `.offsetY` destination; `ChatScrollCoordinator
  .prependCorrectionOffset` is deleted. The new journey
  `a staged catch-up lands at the newest end on both transcript orientations`
  (reduceMotion false, both orientations) gates it on the staged step's own
  landing *and* on the reader's newest row staying on screen until the settle; its
  negative control (the mapping removed, one line) fails by 6,895.7 pt.

  **(c) The keyboard's ramp is gated, and it holds.** `CT25-KEYBOARD-RAMP`
  measures the gap at every driven boundary of both transitions: the flipped path
  reads worst gap **1.9-3.0 pt** across six runs against the ±3 the plan names
  (1.9-2.4 in five, 3.0 once), and today's path
  reads 257-96,305 pt, i.e. the same ramp reproduces the known drop and is gated
  by that reproduction (the two-sided expectation `KeyboardRampExpectation`).
  `keyboardInsetAtWrongEdgeFailsTheComposerGate` still passes.

  **(d) One owner, proven by grep.** `isFlipped`, `.newestAtOrigin`,
  `.newestAtEnd` appear only inside `ChatTranscriptOrientation` and the test
  oracle; the product's five gated sites ask the owner's semantic questions and
  the six end-naming sites go through its anchors, edges and padding sets.
  `physicalRowPositions`/`physicalTerminalPosition` now report the transcript's
  visual order through `visualPosition(ofSpinePosition:count:)` (review P2-3).

  **(e) The detached reader's throw is UIKit's, and it is measured.** With the
  reader detached mid-history on the flipped path, the keyboard show moves the
  scroll view's own offset from 1194 to -inset.top (the pinned end) in one step,
  with **no scroll command written** (`commands=0`). A harness-only KVO observer
  on the transcript `UIScrollView`'s `contentOffset` names the owner from the
  first move's stack: `-[UIScrollView setSafeAreaInsets:]` →
  `_UIScrollViewAdjustForOverlayInsetsChangeIfNecessary` → SwiftUI's
  `HostingScrollView.PlatformContainer.updateSafeAreaInsets()`. Nothing
  app-side: no SwiftUI default-scroll anchor, no `ScrollPosition`
  re-application. The per-step numbers (offset / `adjustedContentInset.top`):
  1194/53 → 1169.7/96.3 → 1135/131 → 1092.3/173.7 → 1045/221 → 997.7/268.3 →
  955/311 → 920.3/345.7 → **-805.3/345.7** (one -1,725.7 step past the legal
  minimum) → **-345.7/345.7** (clamped back to the pinned end). Today's path runs
  the same adjustment but its changing inset is the *bottom* one, which UIKit
  leaves alone (offset 5411 unchanged through the same steps), which is why the
  CT-25 journey passes there. Consequences, both measured: (1) the journey's
  earlier "5.7 / 10.0 pt" readings were the oracle comparing a *different* row
  after the throw (the reader's row identity changes with it), so its 0.5 pt bar
  was never about a drift; (2) the harness detaches with `setContentOffset`, not
  a pan, so SwiftUI never records a user-scrolled item and has nothing to keep
  (`userPosition=0` in the trace). A row `ScrollPosition` target *does* make
  SwiftUI keep the row (its window y held at -26.0 across show/hide/page-load,
  3 of the journey's 4 steps at exactly 0.0), but it installs by aligning a row
  edge to the viewport edge — a 151 pt jump (it targeted `detach-anchor-turn-55`
  at frame 8.67 while the reader's visible top was `detach-anchor-turn-43` at
  -35.3), a 4.3 pt/identity change at keyboard-up, and it broke
  `detached-reader-catch-up` parity (0.062 against 0.025). Removed; the tip tree
  has no row target, no detached-anchor question and no driver change.

- Evidence (lane ct23b, products built from this worktree's own source state,
  every run under `~/Library/Developer/Tron/ios/test-runs/`; orientation selected
  with `TEST_RUNNER_TRON_CHAT_TRANSCRIPT_ORIENTATION`):

  | what | run dirs |
  | --- | --- |
  | the frame space, both paths, one pinned dump each | `140834Z-run.yKw3IC` (today), `140919Z-run.qb8Usa` (flipped; marker `[0,12]` raw = `[779,791]` window) |
  | the catch-up journey and the keyboard journey, flipped | `152029Z-run.eBwr0U`, `153821Z-run.a6XFN8` and three runs after the gate's final form: all pass, ramp worst gap 1.9-2.4 pt, displaced opening viewports 0 |
  | the same, today's path | `152051Z-run.qi63RY`, `153847Z-run.flnhPH`: all pass, ramp 96,304.8-96,305.3 pt (the known drop reproduces) |
  | the staged step's negative control | `153724Z-run.pyyFVO`: the mapping removed, the staged step lands 6,895.7 pt from the newest end and the journey fails |
  | the four focused journeys, flipped | `153821Z-run.a6XFN8`: ramp 1.9, anomaly 0, catch-up and the wrong-edge control pass, the CT-25 detach journey fails exactly as at stage 2 |
  | the same, today's path | `153847Z-run.flnhPH`: all four pass |
  | the full harness, flipped | `152554Z-run.lkSUMH`: 67 tests, 48 events, all in the classes the plan already assigns to CT-19 (materialization/past-end lease counts 0 vs 2, the opening's own shape, the detach journey) |
  | the full harness and parity, today's path | `152146Z-run.ZSblHH`: 69 tests, 1 failure (`displacedRetainedResume`, the CT-9 flake), parity **10/10 pass** |
  | the full harness and parity, flipped, final tip | `155445Z-run.owG3tC`: 69 tests, 51 events, every failing name in the plan's classified lists (the materialization/lease mechanisms CT-19 deletes with their tests, the orientation-assuming oracle control, the CT-9 flake, the CT-25 detach journey, the parity gate) |
  | parity, flipped, twice | `151133Z-run.tROTu6`, `151307Z-run.GaHwOf`: **7/10** each, the three failures all the documented 0.333 px pinned-offset/ink-phase class (`opened-long-history-at-rest` 0.028-0.029, `ordinary-send-keyboard-up` 0.048-0.057, `keyboard-safe-area-inset` 0.047); transitions pass |
  | the offset's owner, KVO stack | `153228Z-run.C9vRIn`, `153255Z-run.8nlAR8` (harness-only probe, deleted) |

- Changes: `ChatTranscriptOrientation.swift` (`transcriptFrame`,
  `correctedOffsetY`, `scrollOffsetY`, `visualPosition`),
  `ChatScrollCoordinator.swift` (frames enter through the owner, corrections
  through the owner, `prependCorrectionOffset` deleted),
  `ChatView.swift` (the one `.offsetY` destination, the two position sites),
  `ChatViewScrollHarnessTests.swift` (the catch-up journey and its landing
  assertion, `KeyboardRampExpectation`, the ramp and opening-classification
  gates, `nativeNewestEndOffset`, the detach journey's zero-write assertions now
  counting every command), this plan.
- Deviations: the detach journey's `automaticScrollCommandCount` assertions could
  not fail (`isAutomatic` is the same on both sides of the only recorder), so
  they now count `scrollCommandCount`, which holds on both paths (measured) and
  is the invariant the journey means. The opening-displacement anomaly is gated
  only where the classification is now exact (the flipped path); today's path
  measures 0-1 of its own without a gate. The detached row target was implemented
  as reviewed, measured, and removed again with its measurements kept.
- Open, with owners, in the order the evidence supports:
  1. **P1-3, and its cause is now known (supervisor's direction, 2026-09-29).**
     On the flipped path the composer/keyboard inset arrives as the scroll view's
     safe-area inset, so UIKit's overlay-inset adjustment moves a detached
     reader's offset (measured above). The supervisor's prescribed fix, for the
     next stage: on the flipped path the scroll view ignores the vertical safe
     areas (container and keyboard) and the owner applies the two insets as
     content margins (`contentMargins` for `.scrollContent` and the indicators),
     sourced from an unflipped reader in the same layout pass — margins only, no
     safe-area application, so no overlay-inset adjustment. Then measure the
     pinned keyboard journey's ramp, the CT-25 detached journeys, parity both
     orientations, and today's keyboard journey. If the pinned origin does not
     follow a margin change, the reported fix is the pinned origin's own anchor
     (`defaultScrollAnchor` for `.sizeChanges` at the newest edge), not a scroll
     command. Only if that cannot hold both pinned and detached: SwiftUI's own
     preservation of a user-scrolled item, validated by an XCUITest with a real
     swipe and the real keyboard rather than by a harness fake.
  2. The flipped path's parity stays 7/10, the same class stage 2 documented (the
     committed reference carries today's 0.667 pt pin and the 2-point bands carry
     the capture's ink phase); the reference is re-recorded at CT-19's cutover.
  3. The flipped harness's remaining 48 events are the mechanisms CT-19 deletes
     (their tests with them), unchanged from stages 1-2.
- For the next agent: the tip is one clean stage-3 commit on top of stage 2. Start
  with 1 above (the inset seam), because it is the one change that can close P1-3
  without a harness fake; keep the catch-up journey and the ramp gate where they
  are, and re-run parity both ways before and after.

### CT-23 re-application stage 5 · 2026-09-29 · chat scroll session (worker lane ct23b)

- Result: the flipped scroll view now applies the swapped vertical safe-area
  values as `.scrollContent` and `.scrollIndicators` content margins, and ignores
  `.container` and `.keyboard` vertical safe areas before the orientation
  transform. Today's orientation remains the default and bypasses these changes.
  The first committed form built, but the keyboard gate measured a 166 pt
  overshoot and was reverted as a mechanism by the next step. The final order
  eliminated that extra inset: the flipped keyboard journey measured 0/56 blank
  boundaries, 0 uncovered-band boundaries, settled clearance 12 pt, and ramp
  worst gap 1.9 pt. The flipped detached journey then failed at keyboard-up:
  its visible anchor row moved 189.7 pt and changed identity, although streaming,
  keyboard-down and page-load samples moved 0.0 pt. This does not satisfy the
  pinned-and-detached contract; stop here, with no persistent anchor or command
  workaround added. CT-25's explicit fallback remains a real-swipe, real-keyboard
  XCUITest validating SwiftUI preservation of the user-scrolled item.
- Diagnostic evidence (the temporary test-only margin/offset/safe-area logging
  was removed before this handoff): keyboard plus detached run
  `20260929T171157Z-run.JdS3gS`, built from clean HEAD `a7f2804e3`, lane `ct23b`.
  At all 24 driven keyboard show/hide boundaries, native `contentOffset.y` equaled
  `-adjustedContentInset.top`; after the final modifier order the native scroll
  view's vertical `safeAreaInsets` were 0 at the sampled transitions (one
  intermediate bottom-only value was 79.3 pt). The keyboard gate passed, but
  the detached test failed on the keyboard show as noted above. Earlier probes:
  `20260929T170326Z-run.ja6st1` (initial pinned regression, 166 pt ramp error),
  `20260929T170656Z-run.CazgbR` (initial inset fix, detached stable 0.0 pt but
  pinned gap 166 pt), all from their respective clean committed HEADs.
- Changes: `ChatTranscriptOrientation.swift` owns margin mapping and the two
  explicit ignored safe-area regions; `ChatTranscriptScrollView.swift` reads the
  insets from the unflipped `GeometryReader` in the same pass and applies the
  inset modifier before the orientation transform. The temporary diagnostic
  edits to `ChatViewScrollHarnessTests.swift` have been removed; its existing
  keyboard and detach gates remain the behavior oracles.
- Open: the keyboard safe-area path is now pinned-correct, but the detached
  keyboard-show journey regresses at 189.7 pt. No final parity, bottom gates, or
  today's path confirmation was run because the user-directed stop condition
  (pinned and detached must both hold) was reached.
- For the next agent: resolve the detached-reader movement without introducing
  scroll commands or timers; if this margin-based path cannot preserve both
  contracts, implement only the approved fallback (SwiftUI preservation of a
  user-scrolled item under an XCUITest with real swipe and real keyboard).

### CT-23 re-application stage 2 · 2026-09-29 · chat scroll session (worker lane ct23b)

- Result: stage 2's two visible-rendering problems are diagnosed with controls.
  (a) The wash is the system's automatic soft scroll edge effect, and the product
  now suppresses it at the flipped transcript's pinned end: parity went **2/10 to
  9/10** on the flipped path, and today's path stays 10/10. (b) The tall-insertion
  transient is **measured and does not reproduce on this base**: the flipped
  shapes hold `minVisibleRowFraction` 0.984-1.0 at every boundary while today's
  path blanks in the same runs. The one frame still failing parity, and the
  under-bar fade the suppression removes, are both named below with their
  measurements; the fade's fix needs the supervisor's decision (reported).

  **(a1) The wash is the automatic scroll edge effect, measured on the screen and
  in one process.** With the flipped transcript pinned, iOS 26's automatic soft
  edge effect is drawn with a band as tall as the whole scroll view — its effect
  layer measures 844 pt against the 170.8 pt the unflipped transcript gets (106 pt
  with the `.hard` style), for every style, scroll position, content size, inset
  and keyboard state, with the band's *position* (the visual top) unchanged; only
  hiding it removes its contribution. The simulator's own screen (not just the
  capture path, so the spike's "capture artifact?" question is closed) shows the
  whole transcript washed out with the nav bar and composer crisp; suppressing the
  effect makes it crisp. In one run, the parity region's difference is 0.10458
  with the effect and 0.01805 with it suppressed at the same state, and
  re-enabling it brings the wash straight back (`origin-forced-on`). The review's
  fractional-pixel lead is disproved: every on-screen row's window frame lands on
  a whole device pixel in both orientations. Product: the owner answers
  `suppressesPinnedEndScrollEdgeEffect` and the scroll view applies
  `.scrollEdgeEffectHidden(..., for: newestEdge)`, so today's path keeps the
  effect it has always drawn (its own product state differs by 0.00058 from the
  same state with the effect forced on). Its gate is
  `only the origin-anchored transcript suppresses the pinned end's scroll edge
  effect`, which fails if the suppression is dropped or applied to the other path.

  **(a2) The one frame still failing parity is the reference's own sub-point
  pinned offset, and the finer alignment cannot absorb it.** Today's path pins to
  the lazy stack's *estimated* content height: it settles at a 12.667 pt tail
  clearance where the contract is 12 pt. An origin-anchored transcript pins
  exactly (12.000 in the same runs). The same rows land exactly 2 device px apart,
  integral on both sides, so the difference is a sub-point (0.667 pt) pinned
  offset — the class of imprecision CT-23 removes. The committed reference was
  recorded from today's container, so a candidate can only match it by
  reproducing that offset. The approved device-pixel alignment step was added
  (`ChatVisualParitySpec.transitionAlignmentStep` for transition frames, one
  display pixel for stable frames, whole-frame uniform shift only) and it *finds*
  the offset (the reported shift is 0.333-0.667 pt), but the residual stays
  0.0277-0.0285 against the 0.025 stable bound for `opened-long-history-at-rest`
  and 0.025-0.050 on `ordinary-send-keyboard-up`'s stable frames across two runs:
  the 2-point bands are sensitive to the capture's ink phase, so the difference is
  rendering rather than position and no shift can absorb it. Today's path reads
  0.0133 on the same scenario in the same runs. Recorded in
  `packages/ios-app/docs/development.md`, whose gate section now states the
  reference's 12.667 pt pin and this limit.

  **(a3) The chrome the suppression removes — reported, not yet fixed.** Today's
  under-bar fade *is* that effect: hiding it on today's path changes the
  navigation band by 0.059 and the parity region by 0.008, and the composer band
  by 0.000. On the flipped path the effect draws as the wash instead, so today's
  fade cannot be had from it: the system sizes the band to the viewport whatever
  the style, so no public knob yields a correct band under the flip. Keeping the
  suppression therefore leaves the flipped path with the chat's own top blur only
  (a small, real difference under the navigation bar), and a substitute would be
  transcript-owned chrome rather than the system effect. Reported to the
  supervisor with the options; nothing hand-drawn was built.

  **(b) The tall-insertion transient is measured and does not reproduce.**
  A 60-boundary per-frame dump of both CT-24 shapes on the flipped path (the
  resync shape's insertion included) reads `minVisibleRowFraction` 0.984-0.995 at
  every boundary, with the previous newest row always adjacent to the inserted
  rows and never pushed away: the 1 pt rows are the entrance's own measured
  footprint in the layout, so no boundary leaves the viewport bare, and the
  insertions grow from that footprint in place (measured heights 1.0 → 200.3 →
  607.0 → … → 1,854.7 pt over about ten boundaries). The review's 711 pt hole
  needs an inserted row to reserve an *estimated* slot while rendering its 1 pt
  footprint; that is not what this base's row structure does. The floor is already
  the CT-24 journeys' gate (0.5 via `TranscriptBottomGateExpectation`), its unit
  control covers the "band covered but viewport sparse" case (a 0.2 fraction is
  rejected), and the hosted control — today's path judged as if it had to cover
  the bottom — fails both journeys naming `minVisibleRowFraction=0.0`.

- Evidence (lane ct23b, products built from this worktree's own source state,
  every run under `~/Library/Developer/Tron/ios/test-runs/`; the orientation is
  selected with `TEST_RUNNER_TRON_CHAT_TRANSCRIPT_ORIENTATION=origin`):

  | what | run dirs |
  | --- | --- |
  | the six-field-shape gates + keyboard journey, flipped | `135245Z.rKwUsF`: 0/72, 0/340, 0/90, 0/68 blank, 0 uncovered, `minVisibleRowFraction=1.0`, `tailClearanceSettled=12.0`, `repairCommands=materialize:0,physical:0,pastEnd:0`; keyboard journey 0/56, clearance 12.0 |
  | the same, today's path | `135333Z.2NE9WQ`: 56/72, 62/340, 77/90, 27/68 blank, fraction 0.0, `tailClearanceSettled` 12.7 or none; keyboard journey 1/56 blank, clearance range [-674.2, 96317.3] |
  | parity, flipped (2 runs) | `134704Z.0UypI0`, `134821Z.JIGDhq`: 9/10 and 8/10; wash gone, `opened-long-history-at-rest` 0.0277/0.0285 at shift 0.667/0.333 |
  | parity, today's path | `135045Z.CGDglb`: 10/10 (worst stable 0.0133) |
  | the alignment change's control | `fingerprintAlignmentAbsorbsOnlyADevicePixelPinnedOffset`: a 0.667 pt pinned offset is absorbed, a 3 pt uniform shift is clamped at the allowance edge and fails, a 24% wash fails, a progressive row-spacing change fails |
  | the edge-effect finding, in one process | `123607Z.1WUHLd` (wash = the top edge effect; hiding it: 0.0181), `124004Z.ClOr38` (per-edge: hiding the bottom changes nothing), `130729Z.ikK5hF` (`origin-product` 0.01805 vs `origin-forced-on` 0.10458), `130335Z.ACJk50`, `132131Z.KJPYbG` (band and position dumps: 844 pt vs 170.8/106 pt; rows integral in device pixels) |
  | the tall-insertion dump | the same lane's CT-23-boundary probes: flipped 0.984-0.995 across 110 boundaries of both shapes, today's path 0.0 |
  | the floor gate's hosted control | `130559Z.Ymu2Iu`: today's path judged as covering fails both CT-24 journeys with `minVisibleRowFraction=0.0` |
  | the on-screen proof | `packages/ios-app/build/ct23-stage2/onscreen-*.png` (simulator screens, git-ignored): today, flipped with the wash, flipped suppressed, flipped with the effect forced back on |

- Changes: `ChatTranscriptOrientation.swift` (`suppressesPinnedEndScrollEdgeEffect`),
  `ChatTranscriptScrollView.swift` (the suppression at the transcript scroll
  view), `ChatVisualParityTests.swift` (the per-phase alignment step, the
  alignment's own failure-mode test), `ChatViewScrollHarnessTests.swift` (the
  suppression's two-sided gate), `packages/ios-app/docs/development.md` (the
  alignment step, the reference's 12.667 pt pin and the limit it creates), this
  plan.
- Deviations: the probes this stage used (the band dump, the effect-layer dump,
  the placement probe, the parity-shape diagnosis) were investigation tools and
  are deleted; the branch carries their runs' evidence and no print-only test.
- Kept on purpose: all five gated mechanisms with their command origins, traces
  and harness counters (CT-19 deletes them once the flip passes every gate);
  `snapNativeTranscriptOffsetToWholePoint`; the CT-2/CT-24 estimate fields.
- Open, with owners, in the order the evidence supports:
  1. **The under-bar chrome — decided, and it goes to the user as a product
     decision.** The system's soft edge effect cannot render its bar-sized band
     under the flip (measured: viewport-sized — 844 pt — for every style, scroll
     position, content size and inset, against 170.8 pt soft / 106 pt hard
     unflipped), and today's under-bar fade is that effect (its contribution:
     navigation band 0.059, parity region 0.008, composer band 0.000 — there is
     no separate composer-edge fade). The supervisor's decision (2026-09-29) is to
     keep the suppression and build no replica; the two options — keep the flipped
     path on the chat's own top blur alone, or add transcript-owned chrome that
     replaces the fade — are the user's to weigh on the device, with these
     measurements and the retained on-screen captures as the evidence.
  2. **The committed reference's 0.667 pt pinned offset and the capture's ink
     phase — accepted for this stage (supervisor, 2026-09-29).** The flipped path
     is 9/10 and that is the documented cause: today's container pins at a
     12.667 pt tail clearance against the 12.0 contract, the committed reference
     carries that offset, and the 2-point bands are sensitive to the capture's ink
     phase, so the finer device-pixel alignment finds the offset but cannot absorb
     it (0.0277-0.0285 for `opened-long-history-at-rest`; 0.025-0.050 on
     `ordinary-send-keyboard-up`'s stable frames across two runs; today's path
     10/10 at 0.0133). No gate is loosened further and the reference is not
     re-recorded now: it is re-recorded on the flipped path at CT-19's cutover,
     after the user approves the look on the device, under the existing
     provenance rules (a reviewed recording revision, never one from the
     candidate). `packages/ios-app/docs/development.md` states the same limit.
  3. The review's remaining flip-path items, unchanged from stage 1: the `.offsetY`
     catch-up mapping (P1-1), adapted or deleted row and marker frames with the
     anomaly classifier (P1-2), the detached reader's row-identity anchor (P1-3),
     the status-bar tap (P1-5), context menus, VoiceOver order and scroll
     direction, and optimized-profiler numbers (P2-6).
  4. `displacedRetainedResume`'s load flake is CT-9's.

### CT-23 re-application stage 1 · 2026-09-29 · chat scroll session (worker lane ct23b)

- Result: the origin-anchored transcript is re-applied on `main`'s post-CT-25/
  CT-27 structure and measured. `ChatTranscriptOrientation` is the one owner: the
  render flip on the scroll view, the counter-flip every content element applies
  through the same modifier, the row spine's newest-first order, the layout edge,
  anchor and padding set a transcript-relative name maps to, the sign a layout
  offset keeps, and the geometry the coordinator reads (the `ScrollGeometry` read
  moved out of the scroll view into the owner). No caller branches on the flip
  (review finding P2-2): the five gated sites ask one of three semantic questions
  — `presentsNewestRowFirst`, `mountsNewestRowWithContent`, `pinsToEstimatedOrigin`
  — and every end-naming site goes through the owner. The flip is the whole
  composer/keyboard inset mechanism (the flipped scroll view's own mirrored safe
  areas; no `GeometryReader`, no margin), the opening is install → one frame →
  reveal, and the five estimated-end mechanisms are gated off, not deleted.

  With the switch off today's path is unchanged: parity 10/10, the four field
  shapes still reproduce their blank, and the full harness is 64/65 with only the
  recorded `displacedRetainedResume` load flake (CT-9) — which passes in isolation
  in the same lane. With the switch on the four bottom gates pass three runs each
  with zero blank boundaries, zero uncovered-band boundaries,
  `minVisibleRowFraction=1.0` and the newest row settled at exactly 12.0 pt; the
  keyboard journey passes three runs at the same 12.0 pt. The spike's one-frame
  tall-insertion sliver (`minVisibleRowFraction` 0.0-0.1 on the CT-24 shapes) does
  not appear on CT-27's row structure in these runs. The one visible gate still
  failing is the parity region's wash, unchanged from the spike: 8 of 10 scenarios
  differ by 0.083-0.096 with every worst frame matching at `shift1.0`.

- Evidence (lane ct23b, products built from this worktree's own source state,
  clean: this branch's revisions `e1f1ff05d` (all runs below) and `5648eeba9`
  (the four-gate confirmation in (1)); every run under
  `~/Library/Developer/Tron/ios/test-runs/`; the orientation is selected with
  `TEST_RUNNER_TRON_CHAT_TRANSCRIPT_ORIENTATION=origin`):

  **(1) The four bottom gates with the switch on, three runs each** (each run is
  one invocation of all four journeys; `TranscriptBottomGateExpectation
  .current(for:)` = `coveringBottomIsRequired`):

  | shape | blank | uncovered band | min visible row fraction | newest-row clearance | run dirs |
  | --- | --- | --- | --- | --- | --- |
  | CT-2 many tall replies (72) | 0 | 0 | 1.0 | 12.0 | `114234Z.ODYqM9`, `114317Z.sfTJa8`, `114347Z.MEwz8J` |
  | CT-2 keyboard cycles + sends (340) | 0 | 0 | 1.0 | 12.0 | same three |
  | CT-24 resync under tall newest (90) | 0 | 0 | 1.0 | 12.0 | same three |
  | CT-24 send under tall newest (68) | 0 | 0 | 1.0 | 12.0 | same three |

  All twelve journeys report `repairCommands=materialize:0,physical:0,pastEnd:0`
  and `tailDisplacements=0`: nothing on the flipped path asks for a repair. The
  CT-24 shapes' realized tall rows measure 1,762.7 and 1,897.3 pt, and every
  CT-2/CT-24 line carries `orientation=origin`, so a line says which side of the
  switch produced it. The same four gates on the branch's revision after two
  readability edits with identical behaviour (a negated guard and the metrics
  label) read identically: `121920Z.FJGhEx`, 0 blank, 0 uncovered,
  `minVisibleRowFraction=1.0`, clearance 12.0 in all four shapes.

  **(2) The same gates and the keyboard journey with the switch off**
  (`114542Z.OXo8es`): the four shapes still reproduce the field defect — 56/72,
  183/340, 77/90 and 14/68 blank boundaries — so every gate passes as
  `uncoveringBottomIsTheKnownDefect`, and the journey is unchanged by the
  restructure. The keyboard journey settles at 12.3 pt on today's path, but its
  own ramp swings `[-674.2, 96317.3]` and one boundary in the keyboard phase
  blanks with `minVisibleRowFraction=0.0`.

  **(3) The keyboard's own inset path with the switch on, three runs**
  (`114512Z.Au7qjG`, `121014Z.tytsZm`, `121034Z.fSRAmi`): every run passes with
  `blankBoundaries=0/56`, `uncoveredBandBoundaries=0`,
  `minVisibleRowFraction=1.0`, `clearanceRange=[4.0,12.0]` and
  `settledClearance=12.0` at both settled boundaries (`p2`-`p4` are exactly 12.0;
  the low 4.0 is the phase before the keyboard's inset is driven, and `p1` reads
  9.0-9.6 as the inset lands). Today's path on the same journey: see (2).

  **(4) `ChatVisualParityTests`, all ten scenarios.**
  - Switch **off** (`114640Z.276JYr`): 10/10 pass (worst 0.05488 transition,
    0.01355 stable) — the content extraction, the owner-mapped anchors and the
    conditional orientation modifier do not move today's path.
  - Switch **on** (`114809Z.1DnXAg`): 2/10 pass. `short-transcript-at-rest`
    passes at 0.00293 and `oldest-row-at-visual-top` now passes at 0.01861 (the
    spike's orientation-specific far-top clamp is gone; `main`'s verbatim
    legal-range clamp and the committed reference agree). The other eight fail at
    0.08291-0.09553 from `frame0:rest` on against their 0.025 stable bound, every
    worst frame best-matching at `shift1.0` — the spike's ~24%-contrast wash over
    the parity band (`opened-long-history-at-rest`, `ordinary-send-keyboard-up`,
    `streaming-tail-growth`, `queued-card-to-sent-row`, `tool-chip-entrance`,
    `earlier-page-load-at-rest`, `detached-reader-catch-up`,
    `keyboard-safe-area-inset`). The keyboard scenario's failure is now the wash
    alone: the inset path it drives passes (3).

  **(5) The full `ChatViewScrollHarnessTests`, both orientations.**
  - Switch **off** (`120258Z.unRrkY`): 64/65 pass, 110.1 s suite; the single
    failure is `displacedRetainedResume`'s 15 s watchdog under the full suite, the
    load flake CT-9 records (`120921Z.OQ4a2s` passes it in isolation in the same
    lane). So the switch-off restructure is a no-op for the whole harness.
  - Switch **on** (`114955Z.8vxLGo`): 48/65 pass and 17 fail (33 issues, 273 s),
    all classified:
    - *Asserts a mechanism the flip retires (13, for CT-19 to delete with their
      tests)*: the tail-materialization command counts (`an ordinary send over a
      mixed-height lazy history settles on its native tail`,
      `agent response and compaction settlement retain mounted physical rows`,
      `ordinary discrete transcript insertion materializes and reveals exactly
      once`, `running tool entrance uses displayed install when desired completion
      advances first`, `real tool group topology inserts one chip under native
      viewport pinning`), the `ScrollPosition` target lease and its release
      (`resumed multiline send settles from native row geometry during keyboard
      resize`, and the watchdogs of `ordinary send keeps one stable tail through
      target release`, `short and long history preserve the mounted prompt through
      acknowledgement and successor`, `a real managed sheet freezes covered chat
      and uncovers to the latest native frame`, `retained detached authority
      replacement preserves its installed cut`), the target-free rebase
      (`dynamic-height retained pinned view rebases native rows after
      displacement`), the past-end net (`a sustained past-end pinned viewport
      returns to the tail through one disabled repair`), and the lease trace
      (`chat.lease.semantic-handoff`).
    - *The flipped opening's own shape (3)*: `production unfinished opening
      retains its exact subscription across cover and settles an accepted upload
      once` and `real opening deadline failures publish only for their current
      live owner` deadlock in their hosted waits, because install → one frame →
      reveal never publishes the physical settlement they hold, and `cancelled
      frame wait closes readiness exactly once` sees a different first-ready
      sequence because the flipped opening runs no positioning pass. These
      journeys are owed by the opening rewrite, not by this stage.
    - *A test premise that assumes today's orientation (1)*:
      `a flipped transcript without counter-flipped rows fails the window oracle`
      flips the native scroll view by hand and expects the removed scroll-space
      measurement to read the legal end; on a run whose spine is already
      newest-first that end is 3,006 pt away.
    - *Visible behaviour not yet implemented (1)*: `a detached reader holds its
      top row through streaming, a keyboard cycle and a page load` — the
      reader's top row moves 10.0 pt and changes identity
      (`detach-anchor-turn-43` → `detach-anchor-turn-54`) across the earlier-page
      load, and the keyboard cycle moves it too. This is the row-identity
      detached anchor the 2026-09-29 review decided, still owed.

- Changes: `ChatTranscriptOrientation.swift` (new, the owner and the one modifier
  both the transcript and each content element apply),
  `ChatTranscriptScrollView.swift` (the spine's newest-first order and `newest`
  accessor, the content split into `transcriptContent`/`earlierMessagesRow` with
  the orientation's end mapping and the counter-flip, the owner-mapped anchors and
  geometry reads, the gated lazy-tail request, the `ScrollGeometry` read moved to
  the owner), `ChatScrollCoordinator.swift` (the orientation and the four gated
  mechanisms), `ChatView.swift` (the orientation field, the semantic-question
  gates, the commands mapped through the owner's anchors and edge),
  `ChatViewScrollHarnessTests.swift` (per-run orientation selection,
  `TranscriptBottomGateExpectation.current(for:)`, the per-orientation
  materialization expectation, the orientation field on both metrics lines).
- Deviations from the spike, all deliberate:
  - Review P2-2 is fixed rather than carried: the spike's raw `isFlipped` branches
    at nine sites are three semantic questions on the owner, and the row
    counter-flip is the owner's modifier instead of an inline `scaleEffect`.
  - The print-only contrast probe (`ct23FlippedParityContrast`, `ct23Ink`) and its
    `CT24-TRANSIENT`/`CT25-KEYBOARD-TRACE` diagnostics were **not** ported: the
    testing policy excludes shipping tests that assert nothing, and this stage's
    evidence does not need them. The parity failure above is therefore named by
    the gate's own retained captures and its `shift1.0` framing, not by a new
    probe.
  - `main`'s verbatim legal-range clamp replaces the spike's orientation-specific
    far-top clamp, so `oldest-row-at-visual-top` passes on the flipped path (4).
  - The stage-1 spike's CT-24 `minVisibleRowFraction` deviation (1-2 of 90
    boundaries at 0.0-0.1, the "sliver") did not reproduce on `main`'s CT-27 row
    structure in three runs (1). It stays on the CT-7 device checklist rather than
    being declared fixed, because these are hosted runs of one fixture.
  - Row and collection *positions* (`physicalRowPositions`,
  `physicalTerminalPosition`) still read the spine's visual order, so the
  diagnostic `requestedRowOffsetFromTerminal` is inverted on the flipped path
  (review P2-3). Diagnostic only; left for the stage that owns the flip's traces.
- Kept on purpose: all five gated mechanisms with their command origins, traces
  and harness counters (CT-19 deletes them once the flip passes every gate);
  `snapNativeTranscriptOffsetToWholePoint`; the CT-2/CT-24 estimate fields; the
  `.offsetY` scroll destination unmapped (review P1-1 — the staged catch-up is the
  one command the flip still receives in mirrored coordinates, and replacing it
  with a row or edge target is a design decision, not a port).
- Open, with owners, in the order the evidence supports:
  1. **The parity wash** (P1-6): 8/10 scenarios, 0.083-0.096, every worst frame at
     `shift1.0`. The spike's bisection ruled out the capture path, capture scale,
     the inset swap, the reveal opacity, the entrance wrapper, the row content,
     the scroll structure, `scrollEdgeEffectStyle`, and a plain blur; what remains
     is the row/marker *host* layer, the anchor modifiers on the scroll view, and
     the UIKit-backed pieces inside rows.
  2. **The detached reader's row-identity anchor** (decided 2026-09-29): the CT-25
     B3 journey still fails on the flipped path (5).
  3. The review's other flip-path items, each unmeasured here: the `.offsetY`
     catch-up mapping (P1-1), adapted or deleted row and marker frames with the
     anomaly classifier (P1-2), a row-identity detached anchor (P1-3), an entrance
     that does not leave the viewport for a tall insertion (P1-4 — not observed in
     (1), still a CT-7 item), the status-bar tap (P1-5, a user decision if only a
     private reach-in would do it), context menus, VoiceOver order and scroll
     direction, and optimized-profiler numbers (P2-6).
  4. The `displacedRetainedResume` load flake is CT-9's, recorded again here; it is
     not a correctness failure and this stage did not change it.
- For the next agent: the flip is on `ct-23-flip2` (this worktree), today's path is
  untouched, and stage 2 should start with the parity wash because it gates every
  other visual probe, then the detached reader's row-identity anchor, then the
  `ChatViewScrollHarnessTests` journeys the flip retires, which CT-19 deletes with
  the mechanisms.

### CT-23 re-application stage 4 · 2026-09-29 · chat scroll session (worker lane ct23b)

- Result: stage 4 remains **Blocked**. The stage-4 source state was committed at
  `6c6665566` before its evidence runs; every run below used products from this
  worktree and a clean HEAD. The existing element-order, prompt preview, menu
  resolution and content-top gates pass. They do not close the distinct
  VoiceOver scrolling or display-card preview gates. The origin path makes the
  system's content-top landing the pinned newest row, so the user's
  oldest-loaded-history status-bar requirement is unmet. No private UIKit
  reach-in was added.
- Evidence (lane `ct23b`, run bundles in `~/Library/Developer/Tron/ios/test-runs/`):

  | Gate | Result | Evidence |
  | --- | --- | --- |
  | Prompt/UIKit context-menu preview, both orientations | Pass | `20260929T173535Z-run.1jsZxC`; preview is upright, identity target and centered over the source. |
  | Display-card/SwiftUI context menu | Menu-resolution gate passes both orientations; preview remains open | `20260929T173535Z-run.1jsZxC`; the public SwiftUI delegate probe (`20260929T172356Z-run.LPhoGC`) showed the origin preview container rendering flipped. A candidate source-owner swap to the existing UIKit interaction found two overlapping hosting surfaces on today's orientation and zero mounted-source intersections on the origin orientation; it was reverted without shipping. The earlier 7.25 pt displacement used the row marker, not the card's own source frame, and is not evidence of a card defect. |
  | VoiceOver element reading order | Pass, with negative controls for absent and reversed priorities | `20260929T173535Z-run.1jsZxC`; oldest-first order holds in both orientations. |
  | VoiceOver accessibility-scroll direction | Not gated | The stage-4 tests do not dispatch an accessibility scroll action and inspect the resulting visual row sequence. Still required before cutover. |
  | Status-bar tap | Blocked by public API surface | The hosted landing gate in `20260929T173535Z-run.1jsZxC` demonstrates today's content-top reaches oldest loaded history; on the origin path the content top is the newest/pinned end. SwiftUI provides public scroll-position/scroll-to commands but no public status-bar-tap callback that lets this `ScrollView` redirect that system command. `UIScrollViewDelegate` could receive it only if the SwiftUI-owned scroll view were reached/owned; no private reach-in was used. |
  | Scroll-edge parity | Known, intentional tradeoff; user confirmation remains open | iOS 26 soft edge layer: origin 844 pt, today 170.8 pt (hard-style control 106 pt); origin hides the pinned edge effect to prevent the viewport wash. Removing it on today's path changes the navigation band by 0.059, parity region by 0.008, composer band by 0.000. Keep suppression and do not build a replica per the 2026-09-29 decision. Device review must still show the nav band/fade side-by-side and confirm whether the suppressed fade is acceptable. |
  | 150/300/512 scale, origin | 3/3 complete runs for every shape | `20260929T173616Z-run.dLIlxo`, `20260929T173704Z-run.uYPBvi`, `20260929T173750Z-run.3Mj7Py`. All shapes end pinned at 12 pt; no compensation commands. Median first-ready: 181.7/145.5/150.4 ms; ready memory: 497.2/569.6/579.5 MB; median scroll step: 1.0/1.0/1.0 ms; median streaming interval: 18.2/25.4/33.3 ms. Against CT-10 (324/350/475 ms ready, 497/583/613 MB, 0.8 ms scroll step, 33/50/50 ms streaming), opening and memory are within-or-better, scroll step is 0.2 ms higher at each size, and streaming medians are equal-or-better. |
  | 150/300/512 scale, today's orientation | Only two complete measured runs; third run's 150-row opening missed readiness | `20260929T173839Z-run.S6C0oo`, `20260929T173933Z-run.g7JxcZ`, `20260929T174027Z-run.kzapZK`. First-ready at 150 in run 3 was not published within 60 s (two prior runs: 295.2/280.4 ms); 300/512 completed in all runs. Completed runs show 150/300/512 first-ready about 280–295/184–200/211–233 ms and memory around 500/518/592 MB. All today-path send phases end detached (`pinned=false`, 387–454 pt clearance); this is existing estimate-compensation behavior, not a scale fixture pass. The incomplete 150-row trial is retained as a blocker, not discarded. |
  | Optimized profiler (`streaming-reply`, `tool-loop`) | Not run in both orientations | `scripts/tron-profile ios --list` confirms the scenarios, but `ChatTranscriptOrientation.selected` reads the orientation variable only under `#if HOSTED_TEST`; the optimized DevicePerformance build cannot select `.newestAtOrigin`. No profile data is claimed. |

- Status-bar API finding was checked against the available iOS 26.5 SDK; no iOS 27 SDK was present in this worktree's Xcode, so no iOS 27 API claim is made. Options for the user: (1) keep the flipped transcript and accept that
  the system tap stays at the newest end (does not meet the stated requirement);
  (2) replace the system gesture with a product-owned “oldest loaded history”
  command/affordance, which is not the same status-bar interaction; or (3) use a
  scroll container Tron owns and can give the public UIKit scroll-to-top delegate
  callback, which is a container/architecture change and outside this spike. Do
  not intercept the status bar through private reach-in.
- Device checklist additions: compare today's under-navigation fade and the
  suppressed flipped band side-by-side on the same phone, then record the user's
  accept/reject decision; stream a tall newest row and inspect whether the
  `minVisibleRowFraction=0.984–0.995` one-frame dip observed across 110 hosted
  boundaries ever presents as a visible sliver on device; perform real VoiceOver
  element traversal and three-finger scrolling at mid-history in both directions;
  confirm the real status-bar-tap behavior if an approved replacement is chosen.
  Hosted scroll-edge metrics do not substitute for those device observations.
- CT-19 cutover remains gated. Once every gate is approved and passes, delete the
  development orientation switch and `newestAtEnd` path, the estimated-end
  materialization/physical-tail/past-end/opening-settlement/prepend-restoration
  compensations and their command traces/counters/tests, the tail-band workaround,
  and obsolete orientation-specific test branches. Keep the single
  `ChatTranscriptOrientation` owner, the invariant monitor, and the row-identity
  detached anchor. Do not delete a mechanism before its owning green regression
  runs; the tall-row device question and the navigation fade decision remain on
  the device checklist.
- Work committed on this branch after stage 3: the CT-23 stage-4 findings below
  are handoff evidence only; the temporary source-owner menu experiment was
  reverted (`6c6665566`) after it failed to identify one actual display-card
  source in both orientations. No product menu change remains from stage 4.

### CT-23 review fixes · 2026-09-29 · chat scroll session (worker lane ct23b)

- Result: review findings F2/F3/F7/F8 and the raw-frame portion of F1 are being
  addressed before evidence runs. The inset reader is mounted only for the
  origin-anchored branch; semantic row/marker samples retain raw frames and are
  reflected using the coordinator's current container height when read. VoiceOver
  priorities are always applied, and row positions are enumerated without an
  ID-keyed dictionary. Documentation now records the development orientation
  switch and the margin-based inset owner.
- Evidence: pending. Required checks remain parity in today's orientation 10/10,
  the full harness with the switch off, flipped keyboard-ramp alignment at every
  boundary, the flipped `ChatRowStabilityTests`, and applicable negative controls.
- Changes: `ChatScrollCoordinator.swift`, `ChatTranscriptOrientation.swift`,
  `ChatTranscriptScrollView.swift`, `ChatViewScrollHarnessTests.swift`,
  `packages/ios-app/docs/architecture.md`, this plan.
- Adapter contract (supervisor): each reported geometry is derived entirely
  from one `ScrollGeometry` callback, including container size and the actually
  applied `contentInsets`; the separate `GeometryReader` values only source the
  margins and are never mixed into observed geometry. Successive callbacks need
  no frame fence. Stored raw frames are reflected using that latest observed
  container height when read. This adapter contract is implemented; F4's
  keyboard-ramp gate remains pending.
- Open: evidence and the flipped-reflection negative control remain pending.


### CT-23 flip2 status · 2026-09-29 · worker lane ct23b

**Blocked for production cutover; available for user-owned device evaluation.**
The detached keyboard defect is fixed declaratively. Parity capture no longer
moves an exact pin, and both row-stability suites pass after correcting test
settlement/traversal. Preview orientation, the remaining parity residual and
accessibility/status-bar requirements remain open. Today's orientation is still
the default; no Gateway lifecycle or device action was performed.

Final product/test revision: **`9d606ec1d`**, source-identical to `eb81e2f71` after
all diagnostic controls were reverted. Final focused runs have
`source.dirty=false`; earlier bottom/scale/full-checkpoint evidence remains at
clean `448a97b79`. Optimized repeat/attribution evidence is at clean `eb81e2f71`.
Subsequent changes update this handoff only. Test artifacts are under
`~/Library/Developer/Tron/ios/test-runs/`, profiles under
`~/Library/Developer/Tron/profiles/ios/`.

#### Root cause and changes

- **F1/F4:** `1712fea02` already implements the supervisor's single-sample
  adapter contract. Geometry is exclusively one `ScrollGeometry` sample,
  including actually applied content insets; the unflipped reader only sources
  margins. Raw semantic frames are reflected when read using the latest
  container height. The pinned keyboard journey now gates distance-from-newest
  ≤0.5 pt and `tail=aligned` at all 24 ramp boundaries. The latter samples the
  newest bounded production tail trace, not a reconstructed classifier.
- **Detached keyboard show:** the previous overlay-inset offset throw is no
  longer the cause with margins. Harness-only KVO at clean `edff9c7b0`, run
  `20260929T181514Z-run.HAyuAc`, records **no offset movement**: offset 1213
  throughout, commands 0. SwiftUI's `HostingScrollView.updateContext` calls
  `setContentInset`/`setContentSize` and writes the same offset; no layout-restore
  or offsetY command moves it. Late in show, the native frame shrinks from
  y=0/h=844 to y=166/h=678. The original row remains at -35.3 but is clipped;
  the next row at 154.3 becomes the visible anchor. The reported 189.7 pt was
  this identity selection, not movement of the original row.
- **Fix:** the orientation owner excludes vertical safe areas outside the scroll
  flip as well as inside. Inner exclusion prevents UIKit overlay-inset
  adjustment; outer exclusion prevents the transformed viewport from shrinking
  and clipping the reader. `ChatTranscriptViewportModifier` owns margins, flip
  and both exclusions together; row counter-flips do not inherit viewport
  modifiers. Today's branch returns content without any of them. No position
  target, timer, retry or compensating command was added. Clean `befb6f540`
  (`20260929T181708Z-run.oaamdq`) first measured both pinned and detached holding;
  the permanent detached gate now checks row ID, instance, <0.5 pt and zero
  commands at every show/hide boundary as well as settled streaming/page load.
  The conditional real-swipe XCUITest fallback was not needed: the in-app
  declarative change holds both contracts in the hosted journey. This is not
  proof of the physical keyboard's transaction.
- **Controls:** clean `dc33ef1cc`, `20260929T182311Z-run.lowvrR`, reflects on
  arrival again and fails the new pinned marker gate at every ramp boundary.
  Clean `76774af55`, `20260929T182408Z-run.vkd4sQ`, removes only outer exclusion
  and fails detached row/instance preservation, reproducing 189.7 pt. Both
  controls are reverted; KVO and per-boundary native dumps are deleted.
- **Display menu:** clean `64606f008`, `20260929T182722Z-run.J7pAPF`, observes
  SwiftUI's actual public highlight-preview delegate. Its source is an upright
  `PortalGroupMarkerView`, 358×214 pt; its target is `HostingScrollView` with
  identity target transform, whose ancestor chain is flipped only on origin.
  Public SwiftUI `compositingGroup()` on the card does not change that target
  (`a86db8b71`, `20260929T182838Z-run.NMq0e4`); the experiment is reverted.
  The retained gate now judges the preview against **its actual card source**,
  not the larger row marker, and fails for the flipped container. Its existing
  negative controls reject a mirrored target/view/container, displacement and
  wrong size. No preview fix is claimed from this bounded investigation and no
  substitute card was shipped. SwiftUI's standard context-menu API offers no
  target-container argument. Options requiring further work/approval: explicit
  SwiftUI preview content (not the same live card lifted in place), a stable
  source-owned UIKit menu boundary, or a container without the ancestor flip.
  Delegate geometry proves the unresolved target transform; it is not an
  on-device menu-animation capture.
- **Optimized switch:** contrary to the prior review premise,
  `DevicePerformance.xcconfig` already compiles `HOSTED_TEST`; no production
  switch expansion was needed. Both optimized profile logs explicitly report
  `transcript_orientation=newestAtOrigin`/`newestAtEnd`. Documentation records
  the existing selection command; CT13 metrics now include orientation.

#### Clean gates (revision stated where newer than `448a97b79`)

| Gate | Latest result | Run directories |
| --- | --- | --- |
| Four CT-2/CT-24 bottom journeys ×3, origin | All 12 pass: 0 blank and uncovered boundaries, minVisibleRowFraction=1.0, settled clearance 12.0, no materialization/physical/past-end repairs | `20260929T184933Z-run.fMfwd5`, `20260929T185003Z-run.s7k0Ct`, `20260929T185033Z-run.nPnevI` |
| Same four ×3, today | All known-defect expectations reproduce: minVisibleRowFraction=0.0; blanks 56/72, 61–62/340, 78/90, 26–30/68. Not a claim of covering the bottom | `20260929T185103Z-run.cDNBAI`, `20260929T185136Z-run.UeJKvm`, `20260929T185209Z-run.6W7aR9` |
| Keyboard + staged catch-up + detached, origin | All pass at `9d606ec1d`. Ramp worst gap 2.4 pt from 12; distance ≤0.5 pt and aligned-marker gates pass at every ramp boundary. Detached streaming/show/hide/page movement 0.0, same ID/instance through keyboard, zero commands | `20260929T204625Z-run.FsVOxb` |
| Same journeys, today | All pass existing expectations at `9d606ec1d`. Detached 0.0 throughout; keyboard reproduces known ramp drop (93,399.7 pt), settles at 12.3 | `20260929T204813Z-run.5u2RG2` |
| Parity, today | **10/10** at `9d606ec1d` | `20260929T204813Z-run.5u2RG2` |
| Parity, origin | **9/10** at `9d606ec1d`; only opened-history 0.02766 fails. Ordinary-send stable maximum 0.0249985 is barely inside 0.025; earlier clean corrected run was 8/10 with 0.02515 ordinary-send, so repeat stability is not claimed | `20260929T204625Z-run.FsVOxb`; earlier `20260929T192640Z-run.q9vL2e` |
| Full harness + parity + row stability, origin | 88 tests, 42 issues. Contains retained estimated-end/lease/opening test assumptions, menu gate, row-stability journey and parity failures; **not green**. Additional covered-catalog/prepend watchdogs remain untriaged; not all failures are declared retired mechanisms | `20260929T183920Z-run.pKUJBZ` |
| Full harness + parity + row stability, today | 88 tests, 3 issues: the menu test explicitly runs origin too and fails there; `displacedRetainedResume` and `unifiedResponseAndNotificationSettlement` watchdogs. Both watchdog cases pass focused at same source | `20260929T184532Z-run.firSJ8`; focused `20260929T190539Z-run.s8qLIk` |
| ChatRowStabilityTests, origin | **14/14** at `9d606ec1d`: thinking 99/66 pt, overflowing; zero settled phase variants/post-mount resizes; native remounts 9/9; entrance identity stable. Two inline-display within-mount 20 pt changes remain measured, not newly fixed | `20260929T204625Z-run.FsVOxb` |
| ChatRowStabilityTests, today | **14/14**, same measurements at `9d606ec1d` | `20260929T204813Z-run.5u2RG2` |
| Prompt/UIKit preview and preview negative controls | Pass both orientations; display/SwiftUI preview separately fails | Both full runs above |
| Accessibility / status-bar | Existing priority-model test passes; **no hosted accessibility-tree or scroll-action proof**. Existing content-top test demonstrates origin reaches newest, not required oldest; **requirement unmet**, not a pass | Both full runs above |

#### Parity and row-stability regression attribution

The parity capture's `snapNativeTranscriptOffsetToWholePoint` rounded the exact
margin pin (for example −63.333 to −63). Subsequent inset changes preserve that
now-detached native offset, leaving the row 326 pt below the composer. The
normal keyboard journey never writes offsets and passes. The helper now keeps
normalization on today's estimated-end path and skips it only through the
orientation owner's `pinsToEstimatedOrigin`. The new settled keyboard/composer
pin assertions fail under clean negative control `0a13aa890`, run
`20260929T204423Z-run.f10mIr`: clearances −314 and −375.3 pt. Control reverted.
Removing only outer exclusion or restoring arrival-time reflection did not
repair parity (both 7/10); pre-margin viewport restored 9/10, and removing the
capture's offset write restored the keyboard scenario without a product change.

Scenario-by-scenario comparison to stage 2 (`cf6bb60b8`,
`20260929T134704Z-run.0UypI0`) versus final `9d606ec1d` follows. Values are
scenario-wide maxima, **not necessarily the failing stable frame**; transition
bound is 0.065, stable bound 0.025, both unchanged.

| Scenario | Stage 2 maximum/verdict | Final maximum/verdict |
| --- | --- | --- |
| opened long history | 0.02769 / fail | 0.02766 / fail |
| ordinary send | 0.05733 / pass | 0.05067 / pass |
| streaming tail | 0.04150 / pass | 0.03623 / pass |
| queued replacement | 0.04960 / pass | 0.04889 / pass |
| tool entrance | 0.04405 / pass | 0.02787 / pass |
| earlier page | 0.02012 / pass | 0.02025 / pass |
| detached catch-up | 0.02272 / pass | 0.02262 / pass |
| keyboard inset | 0.04705 / pass | 0.04682 / pass |
| short rest | 0.00337 / pass | 0.00204 / pass |
| oldest row | 0.01823 / pass | 0.01878 / pass |

The reference's documented 12.667 pt pin versus origin's exact 12.0 pt remains.
The borderline ordinary-send pinned frame measured 0.02498 pre-margin versus
0.02505 after removing only the capture write (later corrected run 0.02515,
final 0.0249985). Corresponding images differ by RMS 0.00165 with identical
measured row positions. This is evidence of a small ink/pin residual, not proof
that every failing pixel has one cause, nor permission to loosen the bound or
re-record the reference. Opened-history is the original stage-2 residual.
The final focused selection is 18/19 tests origin (one parity issue), 19/19 today;
it does not replace the earlier full-checkpoint failures above.

Row-stability's teleport skipped the thinking fixture's lazy range; its guessed
ten-boundary entrance wait also admitted animated heights that the production
stability recorder explicitly excludes. The journey now walks overlapping half
viewports and waits for the entrance's owning settled record. Phase comparisons
read that recorder's settled height rather than raw animated frames. No thinking
layout or counter-flip correction was warranted. Prior clean baseline
`1712fea02`, `20260929T181229Z-run.cFbUB1`, and `448a97b79` full origin run are the
negative traversal/settlement evidence; both final suites now actually mount and
measure thinking. Temporary logs, forced PNG retention and offset probes are
removed.

#### Scale and optimized profiles

Every 150/300/512 shape opened in all three trials in both orientations (the
prior today's 150-row readiness miss did not reproduce). CT13 opening snapshots
are still during the reveal (4.0–4.7 pt); the phase-end measurements below are the
settled evidence. Median values across the three trials:

| Orientation | First ready ms, 150/300/512 | Ready MB | Scroll step ms | Stream interval ms |
| --- | --- | --- | --- | --- |
| origin | 207.6 / 136.9 / 158.4 | 497.3 / 570.1 / 579.9 | 1.0 / 0.9 / 1.0 | 16.7 / 22.0 / 30.8 |
| today | 299.9 / 199.4 / 234.6 | 500.5 / 572.1 / 593.7 | 1.0 / 1.0 / 1.0 | 16.7 / 21.5 / 31.7 |

Origin ends every send phase pinned at 12.0; today ends detached at 387–432 pt,
as before. Scale is measurement, not proof of a passing send UX. Runs:
origin `20260929T185250Z-run.C1srBC`, `20260929T185331Z-run.j4Yqf7`,
`20260929T185411Z-run.J56pem`; today `20260929T185451Z-run.3L0HEh`,
`20260929T185535Z-run.je9QIa`, `20260929T185621Z-run.TAmXVA`.

`scripts/tron-profile ios --self-test` passed all CPU/disk/wakeup controls
(`20260929T183718Z-control-37a8c0`, `20260929T183741Z-control-cpu-6a3bd6`,
`20260929T183801Z-control-disk-2b40cd`, `20260929T183820Z-control-wakeups-6b0ff8`).
Both product scenarios ran five measured iterations with the optimized build:

| Scenario | Today → origin reports | `scripts/tron-profile compare` |
| --- | --- | --- |
| streaming-reply | `20260929T185716Z-streaming-reply-9dd4f3` → `20260929T190107Z-streaming-reply-c97d9a` | CPU 3.984→3.718 s (−6.7%), main thread −7.3%, peak footprint 73.83→69.50 MiB (−5.9%); **interrupt wakeups 2649→2849 (+7.6%) is a flagged regression**, 6 improvements |
| tool-loop | `20260929T185853Z-tool-loop-d854fd` → `20260929T190243Z-tool-loop-d22961` | CPU within noise (−1.0%), peak footprint 72.53→67.02 MiB (−7.6%); no flagged regressions |

Reports and logs retain clean source identity and actual orientation. Reproduce
with `TRON_IOS_TEST_LANE=ct23b TEST_RUNNER_TRON_CHAT_TRANSCRIPT_ORIENTATION=origin`
(or `end`) before `scripts/tron-profile ios --scenario streaming-reply --scenario
tool-loop`, then `scripts/tron-profile compare <today-report-dir> <origin-report-dir>`.
These are simulator comparisons, not device performance or energy proof.

**Bounded wakeup investigation (all controls reverted).** Five-iteration repeats
at `eb81e2f71`: today `20260929T194050Z-streaming-reply-071bd7`, origin
`20260929T193907Z-streaming-reply-841df9`, interrupt medians **2592→2808 (+8.3%)**,
MAD 58/18, identical 74 transport frames and 12.005 s windows. The owning
`compare` labels this repeat *within noise* (±257.972 wakeups), unlike the earlier
+7.6% flagged comparison; the direction reproduces but statistical acceptance
is not settled. Earlier CPU −6.7% and footprint −5.9% remain separate measurements,
not energy proof or justification to dismiss wakeups.

Time Profiler captures `20260929T193633Z-streaming-reply-trace-time-profiler-b07607`
(origin) and `20260929T193756Z-streaming-reply-trace-time-profiler-e49af0` (today)
attribute CPU to normal render/layout work. Exported `runloop-events`, filtered
to the report PID and measured window, show main-loop iterations 4331/4057,
SwiftUI.AsyncRenderer 101/46, UIKit animation-loop 530/528. These are **run-loop
iterations, not interrupt attribution**; `ProfileMainLoop.wait` is the enclosing
run-loop driver, not evidence of busy polling. No production timer was added.

Each approved bisection used a temporary clean commit, optimized rebuild and
three requested Time Profiler iterations; readiness failures yield no accepted
performance comparison. Figures below are medians; traced metrics are not fed
into `compare`.

| Control | Clean revision / profile run | Interrupts / AsyncRenderer iterations per window |
| --- | --- | --- |
| Freeze only inset reader to matched fixture margins | `320e5e9f1` / `20260929T195420Z-streaming-reply-trace-time-profiler-51e589` | 2750 (MAD47) / 104,106,105 |
| Restore automatic edge effect | `78a9af2a8` / `20260929T200145Z-streaming-reply-trace-time-profiler-bf98b4` | 2718 (MAD75) / 102,107,101 |
| Replace content margins with equivalent requested safe-area padding | `161a5b1cf` / `20260929T200909Z-streaming-reply-trace-time-profiler-fc777a` | Rejected before measurement: −71 pt tail clearance; not an equivalent rendered workload |
| Remove only row counter-flips | `72ed19d00` / `20260929T201526Z-streaming-reply-trace-time-profiler-0df7f7` | 2423 (MAD59) / 101,103,103; UIKit iterations drop to 349,264,336, but rows are visually inverted |
| Remove only viewport flip | `a2d288ae9` / `20260929T203444Z-streaming-reply-trace-time-profiler-c6ba23` | Rejected before measurement: −112 pt tail clearance, visible fraction 0.88 |

The row control implicates transformed rendering but does **not** isolate an
avoidable timer or explain AsyncRenderer's increase. An equivalent
nonanimating center reflection (`7330d1b5f`) kept pinned/detached/row-stability
journeys working but returned **2809 interrupts (MAD16)** over five untraced
iterations (`20260929T202709Z-streaming-reply-c3f5fe`); no gain, so reverted.
It also did not clear parity. No speculative transform replacement ships.

The approved temporary System Trace mapping (`a44eda2d9`) captured
`20260929T204100Z-streaming-reply-trace-system-trace-86dbf0`; the owning exporter
refused its 392 MiB trace because projected export memory was 7.6 GiB against
the 2 GiB limit. No budget bypass or scheduler-source claim; mapping reverted.
The 60-minute investigation ended with the source restored. A smaller, targeted
scheduler capture on a supported environment is the missing decisive signal;
this incident is **not closed**. Retained trace bundles and their
`attribution.json` window/PID fields allow re-export of `runloop-events` with
`xcrun xctrace export --input <trace> --xpath
'/trace-toc/run[@number="1"]/data/table[@schema="runloop-events"]'`.

#### Open items, user decisions and device checklist

1. Fix/validate display preview without replacing the real-card lift; origin
   parity must meet its unchanged bound consistently; diagnose remaining
   full-harness watchdogs. Row-stability traversal/settlement is fixed, not an
   outstanding product-row defect. No production cutover.
2. Continue interrupt-wakeup attribution before production performance acceptance;
   this open item does not block a user-owned device test build (supervisor
   direction). Measure per-keyboard-frame body work before an F3 CPU claim.
3. **Status-bar user decision still required:** keep origin and accept newest
   (violates the current requirement), add a product-owned oldest-history command
   (not the same interaction), or adopt a container Tron owns with the public
   UIKit scroll-to-top delegate. No private reach-in. Existing requirement is
   oldest loaded history, unchanged by this work.
4. **Navigation fade decision still required:** keep the approved suppression
   and chat's own top blur only, or approve transcript-owned replacement chrome.
   No replica added. Prior effect-band measurements remain 844 pt origin versus
   170.8 pt today (106 hard style); those are historical, not remeasured here.
5. Device checklist (user-owned; no install performed): real keyboard show/hide
   and interactive dismissal while pinned and detached, tall-streaming and
   insertion slivers, menu lift/selection/links/sheets, overscroll at both ends,
   VoiceOver traversal and three-finger scrolling, status-bar oldest-history
   behavior, side-by-side under-navigation fade acceptance, and scroll continuity
   through reconnect/page load. Hosted stills and driven insets do not prove
   these interactions. Accessibility tree/scroll-action tests remain owed.
6. CT-19 deletion list remains deferred until the owning gates and user decisions
   pass; neither today's path nor its five estimated-end mechanisms were removed.

Lane cleanup completed with `scripts/tron-ios-test lane-remove ct23b`;
`status --all` confirms no ct23b lane and no booted simulator. No other lane
was removed or released by hand. Retained run/profile roots and live-worktree
build products are separate from the deleted lane's simulator/state.


### CT-23 device evaluation build · 2026-09-29 · worker lane ct23b

User-approved evaluation only; CT-23 remains blocked for production cutover.
Implementation and validation are owned in `/private/tmp/tron-ct23b`; no Gateway
lifecycle, device installation, or upstream Git action is authorized.

- Step 1: guard the viewport-mode release probe with `HOSTED_TEST`, matching its
  declaration and the adjacent release path. Non-hosted LocalDevice and Release
  compilation are the regression gates, to run after the evaluation switch lands.
- Step 2: prepend excursion now consumes the same owner-adapted frame as anchor
  capture. Both ChatView installation paths look up the terminal ID in their
  existing visual-position map (including the earlier-messages fallback), not
  the spine's last index. Existing `hostedPrependBarrier` (≤2 pt excursion),
  terminal opening, and full origin harness are the regressions; no bounds or
  expectations changed. This corrects diagnostics, not observed reader movement.
- Step 3: LocalDevice alone compiles the evaluation preference and diagnostics
  toggle. The app eagerly freezes the static selection at launch (not first chat),
  defaulting to origin. Hosted selection still uses only the environment; Release
  keeps today and compiles neither the key nor Settings row. Owning development
  documentation describes the comparison and CT-19 removal.
- Evidence and user-owned install/checklist handoff follow below after clean commits.

Evaluation selection failure modes (before implementation): absent preference
must select origin; false must select today; changing Settings must not mutate
an already launched session; hosted environment selection must remain independent
of this preference; Release must not contain the preference or row. Validate the
compile boundaries with LocalDevice/Release builds, preserve hosted integration
gates in both orientations, and leave real Settings/relaunch comparison explicitly
on the user's device checklist. No isolated tests or production test hooks added.

#### Evaluation artifact and clean evidence

Implementation commits (all committed before evidence): `28f9142d8` guards the
hosted probe; `9172a19ec` corrects the two diagnostic-coordinate consumers;
`dc0387e9d` adds the LocalDevice-only preference/row and launch freeze. All runs
below have clean source identity `dc0387e9d` in `/private/tmp/tron-ct23b`.
No tests, expectations, tolerances, reference images or watchdogs were changed.
The existing hosted integration journeys and non-hosted compile checks are the
regressions; no isolated tests were added.

**Device-evaluation artifact prepared, not installed. Production cutover remains
blocked.** Signed generic-device builds both succeeded using project signing,
without `CODE_SIGNING_ALLOWED=NO`. The LocalDevice artifact additionally passes
`scripts/validate-ios-artifact.py --configuration LocalDevice --require-profile`.
Read-only `scripts/verify-gateway-protocol-contract.py` confirms source, this iOS
artifact and `/Applications/Tron.app` all use Gateway protocol v6 (minimum v6).
No Gateway action is required or authorized by this work.

Build root: `~/Library/Developer/Tron/ios/ct23-device-evaluation/`.
The prepared signed app is
`LocalDevice/Build/Products/LocalDevice-iphoneos/TronMobile.app` under that root;
its `TronBuildIdentity.json` records `dc0387e9d`, `dirty:false`.
`local-device-build.log`, `release-build.log`, and `hosted-build.log` retain build
output. Binary string inspection finds the evaluation key/label in LocalDevice
and neither in Release. Release's build is **compile validation only**: the
optional signed-artifact validator fails its development `aps-environment`
against Release's production requirement under the available project signing.
This is not a distribution-ready Release artifact; no signing policy was changed.

Generic-device compile commands, from the worktree root:

```bash
scripts/tron ios generate
(cd packages/ios-app && xcodebuild build -project TronMobile.xcodeproj \
  -scheme 'Tron Device' -configuration LocalDevice \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$HOME/Library/Developer/Tron/ios/ct23-device-evaluation/LocalDevice")
(cd packages/ios-app && xcodebuild build -project TronMobile.xcodeproj \
  -scheme 'Tron Release' -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$HOME/Library/Developer/Tron/ios/ct23-device-evaluation/Release")
TRON_IOS_TEST_LANE=ct23b scripts/tron-ios-test build
```

Hosted artifacts below are under `~/Library/Developer/Tron/ios/test-runs/`;
each retains `metadata.json`, `test.log`, `summary.json`, and `TestResults.xcresult`.

| Gate | Result | Run |
| --- | --- | --- |
| Origin page-barrier/prepend | 1/1 pass; unchanged ≤2 pt excursion gate | `20260929T211210Z-run.MRW8Qv` |
| Full `ChatViewScrollHarnessTests`, origin, once | 72 tests / 29 issues; all classified below, not green | `20260929T211235Z-run.ShLPKQ` |
| Four bottom journeys, origin, once each in that full run | 0 blank/uncovered at all 72/340/90/68 boundaries; minimum visible fraction 1.0; settled clearance 12.0 pt | Same full run; no redundant second bottom run |
| Focused origin keyboard, detached, staged catch-up | 3/3 pass; 24 ramp boundaries, worst gap 1.9 pt, distance/aligned gates pass; detached movement 0.0 in streaming/show/hide/page phases, same ID/instance, zero keyboard commands | `20260929T211731Z-run.fVTops` |
| Origin unchanged parity | **7/10 scenarios**, 3 issues: opened history 0.02826; ordinary-send pinned 0.02564; keyboard pinned 0.02550 and dismissal 0.02504 (stable bound 0.025) | Same focused origin run |
| Focused today keyboard, detached, catch-up and parity | 5/5 tests; parity **10/10 scenarios**; detached movement 0.0. Keyboard still reproduces today's known one blank boundary and 96,304.3 pt ramp excursion, then settles at 12.3 pt; not a bottom-coverage pass | `20260929T211902Z-run.CFRO0b` |
| Focused failure triage, origin | cancellation, forced retained displacement and detached authority replacement all reproduce, 3/3 fail; not labeled flakes | `20260929T212046Z-run.STgKmR` |

An initial prepend invocation omitted Swift Testing's `()` selector suffix:
`20260929T211144Z-run.n3ZIly` ran zero tests and the runner correctly rejected it.
It supplies no passing evidence; the corrected invocation above executed one.
Parity report copies are retained as `parity-origin-report.json` and
`parity-end-report.json` under the build root so today's run does not overwrite
origin's report. Source-policy checks (3 tests) and full personal-info guard pass.

Reproduce the full run and the corrected page gate:

```bash
TRON_IOS_TEST_LANE=ct23b TEST_RUNNER_TRON_CHAT_TRANSCRIPT_ORIENTATION=origin \
  scripts/tron-ios-test run \
  --only-testing 'TronMobileTests/ChatViewScrollHarnessTests/hostedPrependBarrier()'
TRON_IOS_TEST_LANE=ct23b TRON_IOS_TEST_TIER=ui-validation \
  TEST_RUNNER_TRON_CHAT_TRANSCRIPT_ORIENTATION=origin scripts/tron-ios-test run \
  --only-testing TronMobileTests/ChatViewScrollHarnessTests
```

For the focused journeys/parity, run once with `origin` and once with `end`:

```bash
TRON_IOS_TEST_LANE=ct23b TRON_IOS_TEST_TIER=ui-validation \
  TEST_RUNNER_TRON_CHAT_TRANSCRIPT_ORIENTATION=origin scripts/tron-ios-test run \
  --only-testing 'TronMobileTests/ChatViewScrollHarnessTests/safeAreaKeyboardInsetKeepsNewestRowAtComposer()' \
  --only-testing 'TronMobileTests/ChatViewScrollHarnessTests/detachedReaderHoldsItsTopRowThroughStreamingKeyboardAndPage()' \
  --only-testing 'TronMobileTests/ChatViewScrollHarnessTests/stagedCatchUpLandsAtTheNewestEnd()' \
  --only-testing TronMobileTests/ChatVisualParityTests
```

#### Full-origin failure triage (every remaining issue)

“Retired mechanism” here means disabled on origin, **not** permission to delete
its tests yet. CT-19 must replace the mechanism-specific waits with visible
behavior gates while removing the mechanism and today's path together. These
failures do not establish that all downstream assertions, never reached, pass.

| Case (issue count) | Classification and inspected cause |
| --- | --- |
| `ordinarySendKeepsStableTail` (1 watchdog) | Retired mechanism: waits for a materialization command and subsequent target release; origin issues neither. |
| `resumedMultilineSendSettlesDuringKeyboardResize` (1) | Retired mechanism: requires the materialization target-release increment. |
| `mixedHeightLazyHistorySendSettlesOnNativeTail` (1) | Retired mechanism: requires exactly one materialization command; origin records zero. |
| `resumedSendAcknowledgementSuccessor` (6 watchdogs, all parameters) | Retired mechanism: every sent-row wait also requires 1–2 materialization commands (and lease release phase). |
| `managedSheetFreezesCoveredChat` (1 watchdog) | Retired mechanism: uncover waits for the old target-release increment in addition to visible newest content. |
| `openingDeadlineRevalidatesOwner` (3 watchdogs, all owners) | Retired mechanism: holds the estimated-end post-reveal settlement/deadline callback; origin never enters that owner. |
| `displacedRetainedResume` (1 watchdog, repeats focused) | Retired mechanism: deliberately moves the native offset 180 pt while retaining pinned intent, then invokes foreground's physical-tail repair. Origin explicitly disables that repair; final clearance is −168 pt. This is not evidence that spontaneous native displacement is impossible; device foreground/reader continuity remains required. |
| `pastEndRepairReturnsToTail` (4) | Retired mechanism: demands repair/command increments at two boundaries; origin records zero. |
| `unifiedResponseAndNotificationSettlement` (2), `ordinaryDiscreteInsertionEntrance` (2), `toolGroupTopologySettlement` (1) | Retired mechanism: demand two materialization commands for insertion/settlement; origin records zero. |
| `displayedInstallOwnsRunningToolEntrance` (2) | Retired mechanism: expects the same two commands and the materialization handoff trace; neither exists on origin. |
| `flippedTranscriptWithoutCounterFlippedRowsFailsTheOracle` (1) | Retired measurement assumption: its auxiliary precondition reads the native maximum as newest; origin is pinned at native minimum (difference 3006 pt). Actual window-oracle negative expectations pass; no gate was removed. |
| `displayCardContextMenuResolvesAtTheCard` (1) | **Real behavior, reported/open:** actual SwiftUI preview container renders flipped on origin. Known blocker, not fixed. |
| `cancelledReadyFrame` (1, repeats focused) | **Real diagnostic behavior, reported/open:** cancellation in origin's covered-frame await ends the first-ready interval as `discarded`, not the test's `cancelled`. Source is `completePositionedOpening`'s origin catch. Intervals still close; no user-facing opening failure was demonstrated by this assertion. |
| `retainedDetachedAuthorityReplacement` (1 watchdog, repeats focused) | **Real behavior gate, reported/open:** after authority replacement and the harness's programmatic return to native newest, the old cut remains anchored; no new projection install arrives. Final old row is visible at 12 pt, coordinator mode remains anchored. The helper sends an offset, not a native pan phase; real manual-return semantics versus helper insufficiency are unresolved. Do not dismiss as retired or claim detached replacement passes. |

Total: **26 retired-mechanism/measurement issues + 3 real-behavior issues**.
**Flakes: none established in this run.** Covered-catalog cases and prepend pass
this checkpoint; earlier watchdogs are not silently carried forward as failures.
Origin's parity regressions/residuals above also remain real failing acceptance
gates; ordinary-send repeat stability was already open, and the new keyboard
stable-frame failure is reported rather than rerun away or the reference loosened.

#### User-owned install, toggle and device checklist

Run only when the user is ready to install, from this exact worktree:

```bash
cd /private/tmp/tron-ct23b
scripts/tron-ios-device install
```

The helper builds the canonical `Tron Device` / `LocalDevice` app, verifies the
then-current Stable Gateway protocol and installs/launches on the selected phone.
It may rebuild into its normal incremental products rather than reuse the generic
whole-module compile artifact. No protocol bypass or device performance scheme
is needed. The agent has **not** run this command or installed anything.

Flipped is **on by default**. In Settings → Data & Diagnostics, switch
**Flipped chat transcript (evaluation)** off for today's path or on for origin.
The footer says **Applies after relaunch**: fully quit/relaunch between modes;
changing it never changes an already launched chat. Confirm the default and both
relaunch selections on device (compile checks do not prove Settings interaction).
This preference, row and compile condition retire at CT-19, not in Release.

Compare both modes on the same phone, especially:

- Blank screens on foreground/resync and send under very tall newest replies.
- Keyboard open/close while pinned and while scrolled up; reading row and position
  hold. Include manual return to newest after a detached authority reconnect.
- Streaming and tall new-row **first-frame** coverage, not just settled pinning.
- Long-press menus on **messages and display cards**. Known: the display-card
  preview container renders flipped; prompt-menu hosted geometry passes.
- VoiceOver reading order and three-finger scrolling both directions; hosted
  priority checks are not an accessibility-tree/scroll-action proof.
- Status-bar tap: known origin behavior goes to **newest**, not oldest history.
- **Navigation-bar fade side by side**, using the toggle and relaunch; origin
  suppresses the native pinned-edge effect. Record accept/reject, not inference
  from hosted parity or a still image.
- Opening speed, foreground continuity, and anything that looks or feels different
  from today. Device keyboard timing, interaction animation and energy are unproven.

Cleanup completed: `scripts/tron-ios-test lane-remove ct23b` removed this worker's
lane and retained the live worktree's reusable products. Final
`scripts/tron-ios-test status --all` reports no booted simulators and no running
Simulator.app; no other lane was removed. The worktree and Git index are clean.
Review remains a separate required gate; this handoff is not production approval.

### CT-23 merged for device evaluation · 2026-09-29 · chat scroll session (supervisor)

- Result: at the user's request the origin-anchored transcript merges to
  `main` behind its switch, after the user's first device check ("looks good,
  all working well so far"). Today's path stays the default in Release and in
  hosted tests; `LocalDevice` builds default to the flipped transcript with the
  Settings evaluation toggle, so the user's normal device builds from `main`
  carry it. This is evaluation, not the CT-19 cutover: the switch, today's path
  and the estimated-end mechanisms stay until the open items close.
- Evidence: rebased on `main`; full default unit tier 1,920 tests: one failure,
  the pre-existing `displacedRetainedResume` load watchdog (passes focused twice,
  run `20260929T230657Z-run.m6OeqA`); the flipped display-card preview gate is a
  recorded known issue. `unifiedResponseAndNotificationSettlement` timed out once
  under suite load and passed focused twice.
- Open, in order: (1) the user's device finding: on the flipped path the pinned
  content jumps instead of following animated bottom obstructions (the command
  and skills sheet; likely also composer growth and the real keyboard), because
  the obstruction is applied as content margins rather than animated safe-area
  insets; the fix is designed in the stopped 'animated obstruction follow' task
  (reproduce with real animations, then make the clearance animate in the
  causing transaction without moving a detached reader). (2) Display-card
  context-menu preview renders flipped. (3) Status-bar tap reaches the newest
  row; user decision. (4) Navigation-bar fade; user decision after comparison.
  (5) Parity residual on the flipped path (7/10, pinned-offset class).
  (6) Streaming interrupt wakeups +7.6-8.3%.
