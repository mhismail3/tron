# Chat motion system

- **Started:** 2026-09-24
- **Status:** Paused (waits for the simplification program's chat scoping, S-IOS-CHAT-1, so it builds on the cleaned-up chat code)
- **Last updated:** 2026-09-24, approved and paused
- **Goal:** Every visible change in the iOS chat animates through one motion vocabulary and one row motion owner, so a new interaction is smooth by default and a single-frame jump fails a test.

## Goal and constraints

Today each glitch is fixed where it is found. This plan replaces that with one
system: named motion tokens for every curve, one owner that animates any
transcript row's arrival, replacement, resize and departure, and a conformance
test that measures every transition frame by frame.

What must not change:

- Chat identity, scroll continuity, the pinned tail, composer and keyboard
  behavior (`AGENTS.md`, "Preserve the product"). The native size-change anchor
  and `ChatLayoutTransaction` stay the geometry owners; the motion owner never
  issues scroll commands.
- The documented transcript contracts in `packages/ios-app/docs/development.md`:
  one physical host per row, no replayed entrance, prompt aliasing, the 8,000 pt
  and 2,000 pt interpolation bounds, and Reduce Motion behavior. Where this plan
  changes a contract, the same change updates that paragraph.
- Scrolling performance. Rows that are not changing do no extra work per frame;
  measure with the existing chat performance signposts before and after each
  migration.

Each task is one reviewable change with a hosted frame test and its negative
control. No task may leave two owners for the same transition.

## Context

Inspected 2026-09-24 in `packages/ios-app/Sources/UI/Chat`:

- 111 animation call sites (`withAnimation`, `Transaction(animation:)`,
  `.animation`, `.transition`) across 17 files, using about 15 distinct literal
  durations and curves (0.10 to 0.36 s, `.smooth` and several springs). Only some
  go through the policies in `ChatContentTransition.swift`.
- Four transaction flags admit animation past the stable-update filter
  (`admitsChatToolChipAnimation`, `admitsChatEntranceAnimation`,
  `admitsChatNotificationReplacementAnimation`,
  `admitsChatIncrementalGrowthAnimation`).
- Three separate row-height owners: the entrance growth layout
  (`ChatEntranceGrowthLayout` in `ChatEntranceRows.swift`), the streaming growth
  host (`ChatIncrementalContentGrowthHost`), and the prompt replacement host in
  `ChatTranscriptScrollView.swift`, which since 2026-09-24 also cross-fades and
  interpolates height.
- Not animated at all: queue item removal, edit, reorder and "clear queue", and
  any row that leaves the transcript. Removal is impossible to animate today,
  because a removed row leaves the row spine in the same frame.
- The hosted harness (`ChatViewScrollHarnessTests`) can sample native row frames
  and rendered pixels at display boundaries; pixel sampling slows frames, so
  geometry and pixels are measured in separate runs.

## Plan rules

- A **motion token** is a named curve with its Reduce Motion variant, defined in
  one file. Call sites use tokens; a source test fails on a literal duration or
  spring outside that file.
- A **transition kind** is one of arrive, replace, resize, depart or move. The
  row motion owner chooses the kind from the before and after row, never the
  call site.
- Every transition passes one gate: Reduce Motion, whether the surface is
  active, the size bounds, and whether the viewport is being positioned. A
  transition that fails the gate installs atomically.
- Evidence for each task: the conformance test for the transitions it touches
  (no geometry step above a named bound in one frame, the pinned tail held,
  pixel change spread over several frames), its negative control, the full iOS
  suite, and signpost timings before and after.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| MO-1 | Ready | Inventory every chat animation site and every unanimated visible change (file, trigger, curve, owner); map each to a token and a transition kind; list contracts that would change | none | |
| MO-2 | Ready | Motion tokens: one file of named curves with Reduce Motion variants; migrate every chat call site; delete literal durations; add the source test that forbids new literals | MO-1 | |
| MO-3 | Ready | Conformance harness: one parameterized hosted test that drives each transition kind on a representative row and asserts the frame rules; each existing transition gets a case before any owner changes | MO-1 | |
| MO-4 | Ready | Row motion owner: merge the replacement host, the streaming growth host and the entrance growth layout into one per-row owner for arrive, replace and resize; collapse the four transaction flags to one | MO-2, MO-3 | |
| MO-5 | Ready | Departing rows: the row spine retains a removed row until its collapse finishes (bounded count and time, never a second identity); queue remove, clear and edit use it | MO-4 | |
| MO-6 | Ready | Moves: animate queue reorder inside the layout transaction, with the pinned tail held | MO-4 | |
| MO-7 | Ready | Non-transcript chat surfaces (composer accessories, floating displays, overlays, catch-up) adopt the tokens and join the conformance cases | MO-2, MO-3 | |
| MO-8 | Needs scoping | Device check by the user on a rebuilt iPhone app: send, queue, steer, edit, reorder and clear, with Reduce Motion on and off | MO-5, MO-6, MO-7 | |

## Task details

### MO-1 — Inventory

Read-only. Produce a findings block: every site with its current curve, owner
and trigger; every visible change without animation; proposed tokens (expected
about five: arrive, replace, resize, depart, and a spring for controls and
catch-up); and each documented contract the later tasks would touch.

### MO-3 — Conformance harness

Reuse the harness's display-boundary sampling. One case per transition, each
reporting the largest single-frame geometry step, the tail distance, and how
many frames changed pixels. The bounds are named constants. Cases for
transitions that are not animated yet are marked as expected failures, so each
later task flips its own cases.

### MO-5 — Departing rows

A removed row stays in the spine as a departing entry that collapses to zero
height on the depart token, then leaves. It cannot be interacted with, never
takes a new identity, and is dropped at once if its session, projection or
viewport activation changes. The number of departing rows and their lifetime are
bounded.

## Handoff log

### MO-0 · Done · 2026-09-24 · chat transitions session

- Result: drafted from the queued-to-canonical cross-fade (`87d96d003`) and
  shrink (`0c4584231`) work, which showed each fix needing its own owner.
- Evidence: the counts in Context, from a grep of `packages/ios-app/Sources/UI/Chat`.
- Changes: this file. The user approved it on 2026-09-24 and paused it until the simplification program has scoped and cleaned the chat code (S-IOS-CHAT-1 and its cleanup rows), because the motion owner is easier to build on that code.
- Tasks added: MO-1 to MO-8.
- For the next agent: when resuming, re-run MO-1's counts against the cleaned
  code first. MO-1 and MO-3 come first; no owner changes before the conformance
  cases exist.
