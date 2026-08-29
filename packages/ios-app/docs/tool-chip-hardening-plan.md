# Tool Chip Presentation Hardening Plan

Status: Implemented; focused projection regression validation passed, physical UX verification pending

## Objective

Make transcript tool activity deterministic, identity-stable, and locally animated across streaming, execution, canonical settlement, reconnect, and rapid overlapping updates.

The completed behavior must satisfy all of the following:

1. A finalized same-message group of five tool calls first appears as one **Using 5 tools** chip, not as a sequence such as a single tool, **Using 2 tools**, and **Using 5 tools**.
2. When all calls settle, the chip smoothly becomes **Used 5 tools**.
3. A single tool always displays its actual tool name, including extension-owned tools.
4. Transcript tool chips never use **Extension activity** as a replacement for a tool name.
5. A tool run keeps one stable presentation identity through live progress, canonical persistence, result arrival, reconnect, and idle settlement.
6. Rapid visual updates use a latest-target-wins transition policy rather than queueing competing animations.
7. Timing, output, and progress payload updates do not restart structural chip animations.
8. Detail-sheet title, membership, and tool rows update atomically.
9. Reduce Motion receives an opacity-only or immediate transition.
10. Canonical Pi messages, tool-call IDs, results, ordinals, and ordering remain authoritative.

This plan does not change canonical JSONL semantics or infer parallel execution from timing.

## Scope and invariants

The work spans Gateway projection and iOS transcript presentation. The relevant owners are:

### Gateway

- `packages/gateway/src/sessions/runtime-slot.ts`
- `packages/gateway/src/sessions/projection.ts`
- `packages/gateway/src/protocol/types.ts`
- `packages/gateway/src/sessions/runtime-registry.integration.test.ts`
- `packages/gateway/src/sessions/projection.test.ts`

### iOS

- `packages/ios-app/Sources/Models/SessionRuntimeModels.swift`
- `packages/ios-app/Sources/State/SessionPresentationStore.swift`
- `packages/ios-app/Sources/State/ToolExecutionStatePolicy.swift`
- `packages/ios-app/Sources/UI/Chat/ChatTranscriptProjectionKernel.swift`
- `packages/ios-app/Sources/UI/Chat/ChatTranscriptPresentation.swift`
- `packages/ios-app/Sources/UI/Chat/ChatTranscriptPresentationStore.swift`
- `packages/ios-app/Sources/UI/Chat/ChatToolRunViews.swift`
- `packages/ios-app/Sources/UI/Chat/ChatCompactPill.swift`
- `packages/ios-app/Sources/UI/Chat/ChatContentTransition.swift`
- `packages/ios-app/Sources/UI/Chat/ChatEntranceRows.swift`
- `packages/ios-app/Sources/Support/ChatHostedProbe.swift`

The implementation must preserve these invariants:

- Gateway event sequence and per-call `progressSequence` remain authoritative.
- Gateway monotonic tool `order` remains the invocation ordering source. Opaque IDs are never used as the primary ordering rule.
- Canonical tool calls and results continue to join by exact `toolCallId`.
- Presentation metadata never replaces canonical session entry identity.
- Disposable runtime group metadata remains bounded and is not added to canonical JSONL.
- Transcript structure and scroll updates do not inherit chip animations.
- Entrance animation remains owned by semantic row admission and occurs at most once.
- No timestamp-distance heuristic is used to infer concurrency or group membership.
- Extension provenance remains available for extension summaries, diagnostics, and native run presentation, but never owns a transcript tool-chip title.

## Audit findings

### 1. Parallel execution produces sequential start events

Pi knows the full assistant tool-call list before execution, but even in parallel mode the pinned agent loop serially performs the start and preparation phase:

```text
start A -> prepare A -> start B -> prepare B -> start C -> prepare C
```

Only after preparation does it launch prepared executions together. Completion and update events may then interleave in execution order, while canonical tool-result messages are appended in original declaration order.

Gateway currently publishes every `tool_execution_start` immediately. iOS can therefore receive valid runtime prefixes containing:

```text
[A]
[A, B]
[A, B, C]
```

No current `ToolExecutionState` field says that these calls belong to one finalized declaration group. Per-call `order` stabilizes sibling ordering but is not a batch identifier.

Multiple tool calls in one assistant message prove common declaration membership. They do not necessarily prove parallel execution because one tool may force the group to execute sequentially. The UI does not need to claim parallel execution; it only needs a deterministic finalized invocation group.

### 2. Finalized membership does not have an explicit publication boundary

Gateway streams assistant `message_update` projections while tool calls are still being discovered. Interim projections may therefore contain a partial call list.

At assistant `message_end`, Gateway flushes pending progress, binds the assistant to canonical presentation identity, and schedules a snapshot. It does not currently establish a distinct protocol fact saying:

```text
This assistant message is finalized, and these are all members of this invocation group.
```

Although the final SDK update commonly reaches the client, the contract permits iOS to present partial membership before the complete group is authoritative.

### 3. Group identity depends on the first currently visible tool

`ChatToolRunPresentation` currently defaults to an identity based on the first ordered descriptor:

```swift
anchorID = tools.first?.id
id = "tool-run-" + anchorID
```

`ChatTranscriptProjectionKernel` groups pending tools by current presentation adjacency. It does not receive or preserve a Gateway-owned invocation-group identity.

Consequences include:

- Adding a newly earlier-ordered tool can replace the row ID.
- Removing the first tool replaces the row ID.
- Moving unanchored runtime calls into canonical message placement can merge, split, or move runs.
- All tool call IDs map to the row, but preferred semantic identity remains first-tool-owned.
- An anchor change can cause a real SwiftUI remount and a second entrance decision.

The projection store correctly rejects stale worker completions. The observed churn is primarily publication of valid intermediate topologies rather than competing stale timelines.

### 4. A one-tool run becoming multi-tool is a structural view replacement

`ChatToolRunView` currently renders one tool and multiple tools through different branches:

```text
one tool  -> ToolCard
many tools -> ToolRunChip
```

When the second tool appears, SwiftUI replaces the complete child hierarchy: glass surface, label hierarchy, symbol or spinner, elapsed-clock view, intrinsic width, and interaction path.

This replacement can occur while the outer row's entrance spring is still active. Entrance and tool payload/topology changes have separate owners and no completion coordination.

### 5. Chip changes do not have a deterministic local animation owner

Tool views currently use `.contentTransition(.interpolate)`, but installed transcript updates pass through `chatStableTranscriptUpdates()`, which clears inherited transaction animation. There is no tool-local `.animation(value:)`, controlled `withAnimation`, or latest-target transition coordinator.

As a result:

- Title, count, status, and tone changes usually snap.
- Any animation that does occur depends on an ambient transaction.
- Spinner-to-icon, warning-to-accent, status removal, title replacement, and width changes are separate conditional view updates.
- A rapid sequence has no explicit coalescing or supersession policy.

`ChatCompactPillVisualState` resembles an intended shallow animation key, but it is unused. It also includes duration. Duration or progress updates must not trigger structural animation.

### 6. `Extension activity` flashing has a direct title-selection cause

Two transcript presentation paths currently replace the tool name when extension provenance exists:

- `ToolCard.displayTitle` returns **Extension activity** when `timing?.extensionOrigin != nil`.
- `ChatToolRunPresentation.title` returns **Extension activity** when `isExtensionActivity` is true.

`extensionOrigin` is disposable provenance. It may be present in live execution state, absent from the canonical invocation projection, and present again after result metadata is joined. Live-to-canonical reconciliation can therefore alternate the same chip between the actual tool name and **Extension activity**.

The visible single-tool label must instead derive from the invocation's tool name. Provenance may still affect dedicated extension summaries and diagnostics, but must never replace the transcript chip label.

### 7. Current tests validate settlement more strongly than transition history

Existing tests cover deterministic tool order, grouping, sparse status patches, canonical settlement, timing, detail ordering, frame-coalesced projection installation, and final end-to-end presence of one **Used 3 tools** chip.

They do not currently sample each presented intermediate state across:

```text
partial declaration
-> finalized declaration
-> serialized starts
-> overlapping updates
-> out-of-order completions
-> canonical results
-> idle settlement
```

The current hosted probes observe projection installs, entrance resolution, scroll behavior, and semantic remounts, but do not record per-frame chip title, variant, membership, transition token, or detail-sheet generation.

### 8. Scroll-animation policy is explicit

Native size-change anchoring owns routine pinned growth and chip-local semantic motion remains separate from transcript scrolling. The coordinator writes only explicit opening/catch-up/semantic/prepend commands or a token-guarded, frame-coalesced physical-tail repair admitted from signed marker evidence. Detached readers receive no automatic write, Reduce Motion executes admitted commands without spatial animation, and repair is cancelled by interaction or a newer layout epoch.

### 9. Detail surfaces can briefly combine generations

`ChatToolRunView` receives a new run immediately, while retained `resolvedDetail` or `resolvedGroup` state refreshes in a later `onChange` step. A sheet may briefly combine a new aggregate title with an older tool-row set.

The route identity is mostly stable, but summary and resolved detail data should be published as one exact-generation value.

## Deterministic ownership model

### Gateway owns invocation-group facts

At finalized assistant `message_end`, Gateway must own:

- stable active-turn `toolSegmentId` shared across its tool-only assistant messages;
- stable group identity;
- complete ordered call membership;
- call index and count;
- finalized status;
- disposable mapping from tool call ID to group metadata.

It must publish the finalized assistant declaration before any corresponding `session.toolProgress` start event can be observed.

### iOS projection owns display-run assembly

The projection kernel owns:

- exact placement relative to text, thinking, and transcript barriers;
- joining canonical calls, live execution state, and canonical results;
- consolidation of adjacent tool-only invocation groups only under one equal nonempty Gateway-owned segment identity;
- stable display-run identity based on the first owning finalized group, not the first currently visible call;
- sparse payload/status updates when topology remains unchanged.

### The tool chip owns local visual transitions

One mounted chip owner derives and transitions a shallow visual state. It does not own canonical tool truth, grouping truth, transcript entrance, or scrolling.

### Entrance owns only row admission

Entrance remains:

```text
absent -> pending(exact admission token) -> admitted -> visible
```

Payload and chip-state changes during entrance must not start another row entrance. Pending tasks and failsafe resolution should remain exact-tag or exact-token guarded.

### Detail routing owns one exact generation

The sheet route remains keyed by semantic run/tool identity, while its summary and resolved content are installed atomically with one presentation tag.

## Implementation phases

### Phase 0: Instrument and reproduce before changing behavior

Add deterministic hosted instrumentation that records, per presented frame:

- display-run ID;
- ordered tool call IDs;
- group IDs;
- chip variant;
- title;
- count;
- running and failure state;
- projection installation tag;
- semantic remount count;
- active transition token.

Add a fixture replay covering:

```text
partial declarations A, then A/B, then A/B/C
-> finalized A/B/C
-> serialized start events
-> mixed updates
-> out-of-order end events
-> canonical results in declaration order
-> final assistant text
-> idle settlement
```

Add an extension-provenance replay:

```text
subagent without origin
-> subagent with extension origin
-> canonical subagent without origin
-> enriched result with origin
```

Every sampled single-tool title must remain `subagent`.

### Phase 1: Establish the finalized Gateway declaration boundary

At assistant `message_end`:

1. Explicitly project the finalized assistant message.
2. Partition finalized content into maximal contiguous tool-call groups using content ordinals.
3. Assign each group a stable disposable ID derived from:

   ```text
   assistant presentationId + first tool-call ordinal
   ```

4. Latch ordered group membership before execution starts.
5. Emit the finalized `session.progress` projection before any corresponding tool start event.
6. Attach the latched group metadata to later `ToolExecutionState` events and snapshots.
7. Retain bounded terminal group summaries until operation settlement so reconnect snapshots within the same runtime do not lose group identity prematurely.
8. Clear disposable group state after the owning operation settles, subject to existing bounded projection needs.

Do not label the group parallel unless Pi provides an authoritative execution-mode signal. If observed concurrency is needed later, represent it separately from declaration membership.

### Phase 2: Add explicit protocol group metadata

Extend disposable projected tool-call and live execution models with group facts equivalent to:

```text
groupId
groupIndex
groupCount
groupFinalized
```

Requirements:

- `groupId` is stable for the finalized assistant declaration.
- `groupIndex` follows canonical content order.
- `groupCount` is the complete finalized membership count.
- Interim streaming tool-call parts are not admitted as finalized chips.
- Canonical transcript tool-call parts reconstruct the same group identity from presentation ID and content ordinal.
- Runtime starts use the previously latched metadata rather than arrival timing.
- Protocol fixture and decoder validation reject malformed negative indices, inconsistent counts, duplicate indices, or conflicting group IDs.
- Snapshot fitting preserves group identity and order under ordinary pressure.

### Phase 3: Make display-run identity independent of tool arrival order

Update `ChatTranscriptProjectionKernel` and `ChatToolRunPresentation` so that:

- a finalized group enters with complete declared membership;
- the display-run ID is based on the first finalized owning group ID;
- later members never re-anchor the row;
- unanchored runtime states join by exact group or `toolSegmentId` rather than adjacency or timing heuristics;
- canonical placement can move payload ownership without replacing semantic run identity;
- every call ID still routes to the same run;
- the preferred semantic ID is the stable run/group identity;
- text, thinking, notification, and transcript barriers still split separate runs;
- adjacent tool-only groups consolidate only when producer segment identity proves they belong to the same turn; missing or conflicting identity fails closed to separate rows.

Do not weaken current sparse patch guards. Membership changes should become topology-preserving only after an assembler-proven stable group identity exists.

### Phase 4: Remove extension provenance from transcript titles

Apply the following title contract:

- Single tool: actual normalized tool name.
- Live multi-tool run: **Using N tools**.
- Terminal multi-tool run: **Used N tools**.
- Transcript tool chips never display **Extension activity**.

Remove extension-origin title overrides from `ToolCard` and `ChatToolRunPresentation`.

Keep extension provenance available for:

- dedicated extension summary surfaces;
- composer or Manage Session extension activity summaries;
- diagnostics;
- native delegated-run presentation;
- detail metadata where provenance is useful.

Update tests that currently require `run.title == "Extension activity"` for extension-owned tool chips. Dedicated extension summary tests may continue to expect labels such as **Extension activity · 1 running**.

### Phase 5: Replace the single/multi structural branch with one chip hierarchy

Introduce one transcript `ToolActivityChip` hierarchy driven by an immutable presentation value containing at least:

```text
runId
toolIds
singleToolName
count
running
failureCount
title
status
tone
icon
```

Requirements:

- The outer chip view remains mounted when one tool becomes multiple tools.
- Single and aggregate modes share the same glass, label, icon slot, clock slot, and tap target hierarchy.
- Interaction may route to a single detail or grouped detail based on current count without replacing the visible chip.
- `ToolCard` may remain as the individual tool row inside detail sheets.
- Accessibility label and identifier update from the same atomic visual state.

### Phase 6: Add one explicit latest-target chip transition owner

Introduce a presentation-only coordinator with these rules:

1. Accept one shallow target visual state per installed projection.
2. Coalesce new targets to the next display frame.
3. If a transition is active, replace its target rather than enqueue another animation.
4. Guard completion with a monotonic transition token.
5. While row entrance is active, update chip content without starting a competing entrance animation.
6. Animate only discrete semantic changes:
   - membership/count;
   - single-to-aggregate title;
   - running-to-terminal phase;
   - failure count and tone;
   - spinner-to-symbol replacement.
7. Exclude duration, request, response, output, partial output, progress sequence, timestamps, and extension provenance from the structural animation key.
8. Keep elapsed text monospaced and update it without restarting chip animation.
9. Keep detail routing tied to the newest authoritative run rather than any delayed visual target.
10. Keep transcript insertion, layout, and scroll transactions outside this animation boundary.

Suggested motion policy:

- Normal motion: `.smooth(duration: 0.18...0.22)`.
- Count: numeric text transition.
- Symbol: replace or opacity crossfade.
- Title/status: opacity/interpolation within the stable hierarchy.
- Reduce Motion: short opacity-only transition or immediate state installation.

The coordinator must never queue a series such as one-to-two, two-to-three, and running-to-terminal after the authoritative state has already advanced to terminal three. The latest target supersedes all earlier incomplete targets.

### Phase 7: Publish detail summary and rows atomically

Replace separately refreshed run and resolved-detail state with one value containing:

```text
installationTag
runSummary
resolvedToolDetails
```

Requirements:

- The sheet title and tool rows always represent the same installation generation.
- The route identity remains stable while membership or status changes.
- Grouped detail rows remain keyed by exact tool call ID.
- Ordering does not switch merely because optional timing metadata arrives. Canonical order remains authoritative.
- Dismissal and presentation state survive ordinary status/result patches.

### Phase 8: Align scroll and entrance policy

Adopt and test one policy:

- Tool-row entrance may animate once when semantically novel and visible.
- A semantically novel visible agent row shares one short, frame-coalesced smooth pinned-tail follow with streamed growth; detached readers receive no write, Reduce Motion executes without spatial animation, and physical overshoot correction remains animation-disabled.
- Chip-internal transitions remain locally animated.
- Chip updates never replay row entrance.
- Rapid pending installation-tag replacement restarts or supersedes the exact-token failsafe correctly; a stale token cannot resolve a newer pending entrance.

Update `ChatView`, `ChatScrollCoordinator` documentation, hosted tests, and `PresentationStyleGuardTests` so they assert the same production policy.

## Validation plan

Use the narrowest owning checks while iterating. Avoid broad simulator combinations known to hang.

### Gateway tests

Add focused coverage for:

1. Finalized three-call progress is emitted before the first tool start.
2. Serialized start events all carry the same finalized group ID and complete count.
3. Slow argument preparation delays later starts without changing membership or group order.
4. An immediate validation/preparation failure before a later start still exposes the complete group.
5. A tool forcing sequential execution does not change declaration-group membership or falsely claim parallel execution.
6. Out-of-order completion does not reorder the group.
7. Canonical result append order remains declaration order.
8. Runtime tool state retires only after canonical result ownership is established.
9. Reconnect snapshot preserves active group identity and current terminal/running state.
10. Snapshot debounce may skip intermediate progress but converges to the same finalized group.
11. Snapshot pressure preserves tool/group identity under ordinary fitting and follows documented behavior at the severe bounded fallback.
12. Malformed or conflicting group metadata is rejected.

Run:

```bash
cd packages/gateway
npm run build
npx vitest run <owning-test-files>
```

### iOS pure projection and store tests

Add focused tests asserting:

1. The first visible finalized five-call group has count five.
2. No finalized-group replay exposes one-to-four-member intermediate variants.
3. One stable run ID survives live-to-canonical-to-result-to-idle settlement.
4. Extension provenance appearing and disappearing never changes the single-tool title.
5. Multi-tool extension-owned runs use **Using N tools** and **Used N tools**, never **Extension activity**.
6. A newly earlier `order` cannot remount a group whose canonical group order is already finalized.
7. Thinking and text barriers still split presentation runs.
8. Same-segment adjacent tool-only consolidation preserves its first stable group-based run ID, while missing or different segments remain separate.
9. Rapid target updates leave at most one active transition token and settle to the newest target.
10. Duration/progress updates do not increment the structural animation revision.
11. Reduce Motion uses the approved non-spatial transition.
12. Detail title and detail row IDs install in the same generation.
13. No extra entrance, semantic remount, or failsafe counter is recorded during membership/status updates.
14. Stale projection work remains rejected by exact tags.

### Hosted presentation tests

Extend `ChatHostedProbe` to frame-sample the tool button and assert:

- exactly one chip exists for a finalized display run;
- no sampled frame has a missing or duplicated chip;
- no sampled title is **Extension activity**;
- label/count changes follow only admitted visual states;
- one-to-many expansion does not replace the outer chip identity;
- rapid targets do not replay entrance;
- detail title and membership update atomically;
- tail scroll behavior remains independent of chip animation.

### Compilation and source checks

After focused tests pass:

```bash
cd packages/ios-app
xcodegen generate
xcodebuild build-for-testing \
  -project TronMobile.xcodeproj \
  -scheme 'Tron Development' \
  -configuration Test \
  -destination 'generic/platform=iOS'
```

Also run:

```bash
git diff --check
scripts/personal-info-guard.sh
```

### Physical-device validation

Use the physical iPhone for final UX validation. Exercise a scripted provider or fixture that produces:

- one extension-owned tool such as `subagent`;
- a finalized five-tool group;
- mixed short and long durations;
- rapid progress updates;
- out-of-order completion;
- at least one failure while another tool remains running;
- canonical result settlement;
- reconnect during active execution;
- final idle settlement.

Verify:

1. A single extension-owned chip always reads `subagent` or its actual tool name.
2. A finalized five-call declaration first appears as **Using 5 tools**.
3. The chip changes once to **Used 5 tools** after terminal settlement.
4. No tool chip ever reads **Extension activity**.
5. No row disappears, duplicates, remounts, or replays entrance.
6. Rapid transitions retarget smoothly rather than queueing old states.
7. Opening the detail sheet during execution retains stable routing and current membership.
8. Reconnect does not change the run identity or visible title.
9. Reduce Motion behaves according to policy.
10. Transcript following remains stable without global scroll/layout animation artifacts.

## Acceptance criteria

The change is complete only when all of these are demonstrated by focused automated evidence and physical-device validation:

- [x] Gateway publishes finalized invocation-group membership before corresponding tool starts.
- [x] The protocol carries stable, validated, bounded group identity and order.
- [x] iOS displays one stable row per admitted display run.
- [x] The first visible finalized multi-tool state contains its complete count.
- [x] A single tool always displays its actual tool name.
- [x] Transcript tool chips never display **Extension activity**.
- [x] Live, canonical, result, reconnect, and idle states retain one run identity.
- [x] One-to-many presentation does not replace the chip hierarchy.
- [x] Rapid state changes use one latest-target transition owner.
- [x] Duration and payload progress do not retrigger structural animation.
- [x] Entrance and scroll animation remain separate from chip animation.
- [x] Detail summaries and rows install atomically.
- [x] Reduce Motion is honored.
- [x] Canonical tool IDs, results, ordering, and JSONL remain unchanged.
- [x] Focused Gateway tests pass.
- [ ] Focused iOS projection/store/hosted tests pass (test bundle compiles; execution intentionally deferred to avoid simulator hangs).
- [x] Generic iOS build-for-testing succeeds.
- [x] `git diff --check` passes.
- [x] `scripts/personal-info-guard.sh` passes.
- [ ] Physical-device validation passes.

## Residual risks and explicit non-goals

### Residual risks

- The pinned Pi lifecycle may change in a future dependency update. Gateway contract tests must lock the required finalized-publication ordering at Tron's boundary.
- Canonical history cannot reconstruct actual execution overlap after restart unless concurrency metadata is separately persisted. This plan does not require that fact for chip grouping.
- Severe bounded snapshot pressure may omit disposable live execution overlays. Canonical call identity and reconnect settlement must still recover deterministically.
- SwiftUI animation rendering can differ across OS versions. Pure transition tests must be supplemented by hosted frame probes and physical-device observation.
- A page prepend that reveals an earlier canonical tool group may legitimately alter a historical display-run boundary. It must not replay entrance or affect canonical identity.

### Non-goals

- Do not infer parallelism from near-equal timestamps, consecutive `order`, or start-event timing.
- Do not modify canonical Pi JSONL to persist presentation batches.
- Do not add a second continuity or fallback identity system.
- Do not animate the entire transcript or scroll container to make chip changes appear smooth.
- Do not use extension provenance as a user-visible replacement for the tool name.
- Do not recreate runtime ownership or event-journal infrastructure.
- Do not run broad simulator suites repeatedly during diagnosis.

## Recommended implementation order

Implement the work as one coordinated Gateway and iOS change with a single mutation owner. The highest-value root fixes are:

1. finalized Gateway invocation-group publication before execution starts;
2. stable group identity independent of the first arriving tool;
3. removal of extension-provenance title substitution;
4. one unified chip hierarchy;
5. one explicit latest-target local animation owner;
6. exact-generation detail routing and focused frame-level validation.

Do not attempt to solve the flicker only with a debounce or a global SwiftUI animation. Either approach would hide symptoms while retaining unstable membership, identity, and title ownership.
