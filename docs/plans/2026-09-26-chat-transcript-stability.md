# Chat transcript stability

- **Started:** 2026-09-26
- **Status:** Active
- **Last updated:** 2026-09-26, approved
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
| CT-1 | Ready | Test isolation: `scripts/tron-ios-test` uses per-worktree derived data by default, records the source revision and worktree in each run's metadata, and refuses to run products built from another worktree; update `packages/ios-app/docs/development.md` | none | |
| CT-8 | Ready | Stabilize `hostedOpeningRevealIsMonotonic`: find why the opening reveal's sampled distance is non-monotonic in about one run in three and fix the cause (product or oracle), with evidence from repeated runs | CT-1 | |
| CT-2 | Ready | Baseline: port the hosted reproduction fixtures from `fix/chat-blank-evidence` to `main` as measurements, not pass/fail gates. Record blank boundaries, estimate-to-truth ratio after keyboard cycles, tail displacements, repair commands and frame cost on the worst shapes (tall reply at the tail, many tall replies, 180+ rows), three runs each | CT-1 | |
| CT-3 | Ready | Prototype A on a throwaway branch: segment long assistant content at Markdown block boundaries into bounded physical rows, with pinning from visible row identity; measure against CT-2. The prototype does not need product polish, but it must show whether the blank and the estimate swing disappear | CT-2 | |
| CT-4 | Needs approval | The user chooses A or B from CT-3's numbers and a device build of the prototype | CT-3 | |
| CT-5 | Needs scoping | Implement the chosen option in production. For A: segment identity, streaming into the last segment, whole-message copy/menus/accessibility, one entrance per message, segment chrome; pinned state from visibility. Scope into rows once CT-4 decides | CT-4 | |
| CT-6 | Needs scoping | Delete the compensations CT-5 makes unnecessary, one per commit, each under the plan rules: past-end repair, physical tail repair, the materialization fail-open, geometry-based pinned evidence, and the trace fields that only diagnose them | CT-5 | |
| CT-7 | Needs scoping | Device validation with the user: the send choreography checklist in `packages/ios-app/docs/development.md`, plus long sessions with tall replies across keyboard, foreground and resume | CT-6 | |

## Handoff log

### CT-0 · Done · 2026-09-26 · chat scroll investigation session

- Result: drafted from four device incidents, the hosted bisection and the research brief.
- Evidence: device exports 2026-09-25T08-42, 2026-09-26T07-17, 08-04, 08-05 and 08-07; hosted fixtures on `fix/chat-blank-evidence`.
- Changes: this file, proposed.
- Tasks added: CT-1 to CT-8 (CT-8 added at approval from the `main` baseline runs).
- Kept on purpose: the past-end repair and trace changes already on `main` stay until CT-6 shows they are unnecessary.
- For the next agent: the paused chat motion system plan touches the same rows and animations; sequence it after CT-5. The simplification program's IOS-CHAT scoping should account for CT-5 and CT-6.
