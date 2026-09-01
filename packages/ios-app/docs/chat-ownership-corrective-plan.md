# Chat ownership corrective plan

Status: active SwiftUI-preserving hardening. Milestone 3 transcript ownership remains implemented: the session snapshot is the sole whole-session authority and the mounted transcript window retains only an exact prefix before the Gateway tail. The completed first slices give anchored and anchorless paging one coordinator-owned operation, cancel it on background, propagate layout settlement/abandonment/overflow to the sole viewport command owner, revision-scope repeating participants, close the pre-admission entrance race, promote pending insertions after abandonment, freeze transcript-coupled composer chrome with the installed commit, and prevent opening starvation by revealing one complete same-runtime commit before coalescing to newest. A sparse positive-start open now schedules one optional exact page through the existing mounted paging owner, bounded to a combined 512-row recent window without delaying synchronization. The existing SwiftUI hierarchy, renderer, composer, animation constants, and visual styling are unchanged. Further coordinator reduction, integrated reconnect coverage, and physical flow acceptance remain open; this status makes no physical acceptance claim.

## Goal

A mounted chat renders one immutable, internally consistent commit from one normalized iOS session reducer. Canonical JSONL and the one Gateway runtime remain authoritative. Paging, formatting, scrolling, cache, composer optimism, tools, and extension activity remain bounded disposable projections and never become alternate session owners.

## Root cause

The failures are one architecture defect expressed in several domains: **temporal aliasing across denormalized projections**.

One admitted Gateway stream is currently copied into multiple independently advancing representations:

- `SessionPresentationStore.snapshot` as whole-session authority;
- `MountedTranscriptWindow` as transcript-only exact prefix coverage (never a copied tail);
- the current canonical snapshot and asynchronously installed transcript projection;
- queue state in the session snapshot, transcript projection, and local command-response shortcuts;
- canonical tool declarations/results, streaming declarations, runtime tool overlays, and duplicated extension activity bodies;
- projection tags/local generations beside the authoritative runtime/event cursor;
- scroll settlement state that can currently trigger transcript eviction.

SwiftUI can therefore render controls from commit N, rows from N-1 or no installed commit, and composer/queue state from another projection. Exact transport sequencing cannot repair atomicity after iOS forks one event stream into competing mutable owners.

Concrete manifestations:

1. **Only Load earlier is visible:** the pill is derived from the newest `SessionSnapshot`, while rows are derived from a frame-delayed projection that may have been cleared or not yet installed.
2. **Load earlier is inert:** canonical paging is incorrectly gated by a currently measured semantic scroll anchor. An empty transcript can advertise history but can never obtain that anchor, so no request starts.
3. **Rows appear and disappear:** generic bottom/keyboard/geometry settlement must never replace the exact mounted prefix coverage; the transcript projection now remains derived from the authority tail plus mounted prefix.
4. **Resume can mount no recent rows:** fresh open accepts a fitted empty positive-start tail and publishes it without a client compatibility backfill.
5. **Projection gaps and jumps:** same-session replacement resets scroll state and can clear the old installed projection before the replacement is ready.
6. **Prepend can wedge:** live projection intake is suppressed during prepend; missing semantic/geometry callbacks have no bounded terminal path.
7. **Stale steering containers:** composer admission settles only after asynchronously installed presentation/content matching. Attachment-only canonical text can differ from empty display text, and a missed transient queue frame leaves the admission blocking later sends.
8. **Duplicate tools/activity:** one logical invocation/activity has several authoritative-looking bodies that are joined through heuristics.

## Ownership target

### Gateway runtime

The existing `RuntimeSlot` remains the sole live runtime owner. It serializes typed facts and emits immutable bounded frames stamped with:

- runtime generation and event sequence;
- canonical branch/leaf identity;
- exact transcript window `[start, end, total]`;
- normalized queue/tool/activity state and domain revisions.

No Engine, worker layer, event journal, SQLite mirror, or second runtime is introduced.

### iOS session reducer

`SessionPresentationStore` owns one normalized mounted state. Transcript state is a typed window, not two mutable snapshots plus booleans:

```swift
struct MountedTranscriptWindow {
    let coverage: MountedTranscriptCoverage
    let prefixItems: [TranscriptItem] // strictly before snapshot.transcriptStart
}
```

Visible coverage, availability of earlier history, and retained-history status are derived from exact ranges. Baselines, sequenced deltas, and validated pages enter only this reducer.

### Installed chat commit

The formatting worker remains pure and disposable. Its output is one immutable installed commit containing every layout-affecting fact for the same source cursor:

- transcript rows and semantic mappings;
- Load earlier state;
- runtime/system rows;
- outgoing/pending handoff rows;
- queue rows and revision.

`ChatTranscriptHandoffCommit` freezes pending prompt presentation or outgoing presentation plus
bounded submitted attachment DTOs. Its compact `HandoffIdentity` includes all row-affecting
text, behavior, counts, transport, metadata, and preview identities without storing preview bytes
in the tag. The prior complete commit remains visible until a complete replacement is ready.
`ChatView` never combines controls from one commit with rows from another; canonical reconciliation
publishes the canonical timeline with handoff `none`.

### Scroll coordinator

`ChatScrollCoordinator` remains the sole app-generated viewport-command owner and never mutates transcript retention. Paging authority is independent of geometry: one bounded coordinator operation owns both anchored restoration and successful geometry-free installation, while an anchor is optional evidence only. Exact layout terminal events release matching command leases on settlement or abandonment; no independent unanchored paging task exists in the view owner.

### Composer and queue

The Gateway owns queue/pending-prompt truth. Mutation responses do not perform unstamped local queue writes. `ComposerDraftCoordinator` owns one optimistic submission and reconciles directly from every admitted authoritative session commit, using stable operation/queue identity when available and bounded canonical attachment evidence as fallback. Transcript formatting cannot be the settlement channel.

### Tools and extension activity

Canonical declarations own transcript placement. Runtime execution decorates the canonical call. Runtime-only work requires an explicit protocol anchor. One activity map owns activity bodies; tool progress refers to activity identity rather than carrying another authoritative body.

## Milestones

### 0 — Characterize and lock invariants

- Add focused state-machine tests for mixed-epoch frames, empty positive-start open, anchorless paging, scroll settlement, retained same-session handoff, prepend timeout, streaming during prepend, attachment-only steering settlement, and queue revision ownership.
- Tests use bounded scripted transports, injected frames/clocks, and hosted UI probes; no broad simulator suite is required while iterating.
- Add invariant assertions: one commit cursor per rendered tree, contiguous transcript coverage, one queue revision per installed queue, one mounted tool site per call, and no scroll callback mutating transcript coverage.

Exit: every reported failure has a deterministic owner-level reproduction.

### 1 — Restore usable recent-tail and paging behavior

- Implemented without extending the sync quarantine: after the usable authoritative tail mounts, a positive-start window below 512 rows schedules one optional exact backward page through the mounted subscription owner. Exact runtime/leaf/total/range/next-ID/target admission is reused, the combined recent window is trimmed to 512, and failure silently retains the usable tail.
- History fetch always starts when the session reducer says a page is available. A semantic anchor is optional and cannot gate transport.
- Remove scroll-driven `discardLoadedTranscriptHistory`. Mounted history stays until navigation, explicit bounded retention/memory policy, or branch/runtime invalidation.
- Paging returns a typed result (`installed`, `stale`, `conflict`, `failed`) instead of silent guard exits. The UI queues or reports a real state rather than presenting an enabled no-op.

Exit: fresh and in-progress resume shows the bounded latest canonical window; Load earlier always initiates or visibly reports a request; keyboard/bottom settlement cannot delete rows.

### 2 — Atomic source-to-visible commit

- Preserve the last complete installed transcript during same-session/runtime replacement until its validated replacement is ready.
- Derive Load earlier, rows, queue rows, runtime rows, response signature, and layout-affecting composer chrome from the same installed commit.
- Replace independent readiness booleans with one exact ready identity containing presentation target, installed commit cursor, and mutation authority.
- Same-session reconnect uses viewport-retaining reset and never issues reset-to-bottom merely because the presentation generation changes.

Exit: no legal frame contains new controls with absent/old rows; retained reconnect has no blank interval or tail jump.

### 3 — Normalize transcript ownership

- Complete: `snapshot` is the sole whole-session authority; transcript consumers use a transient projection assembled from `MountedTranscriptWindow` plus the authority tail.
- Complete: exact runtime/structure-revision/range/ID admission reconciles only contiguous, disjoint prefixes; total decreases and gaps discard the prefix, while leaf changes and total growth require exact canonical overlap and tail expansion trims only exact index/ID overlap.
- Complete: removed continuity merge heuristics, duplicated-tail flags/hooks, and snapshot cache persistence; summary cache remains backward-compatible with snapshot-bearing files.
- Keep the recent-tail/page byte and item bounds. The ordinary resume window remains the Gateway’s established bounded latest page (up to 512 items and wire budgets); the display-bearing continuity floor is only a pressure fallback, not a second user-visible paging policy.
- Cache only the bounded cold recent-tail DTO if an actual offline presentation consumes it; otherwise remove unused snapshot persistence and retain summary caching only.

Exit: every transcript item is stored once in the mounted reducer, visible coverage is derived, and branch changes fail closed without replacing a whole session snapshot from a side copy.

### 4 — Bound projection and scroll transactions

- Complete for the current boundary: layout transactions publish bounded settled/abandoned terminal events, overflow cancels transient leases, watchdog abandonment releases only its exact materialization lease, pending work is promoted safely, repeating participants use exact revision tickets, and entrance completion is order-independent with local lifecycle admission.
- Complete for the current boundary: anchored and anchorless history share one coordinator-owned operation and deadline, background cancellation retires both, and the retired view-owned fallback task and production compatibility API are removed. Disposable source churn is coalesced during the exact page transaction; an exact prior window, including a monotonic canonical suffix append, may restore, then newest authority installs immediately after settlement.
- Complete for opening churn: automatic intake pauses behind the opaque surface, the first complete same-runtime commit may reveal, and the newest desired source is coalesced immediately after the first ready frame.
- Projection intake never stops during prepend; newer desired commits coalesce and install immediately after the exact prepend transaction.
- Every prepend, automatic-tail command, opening settlement, and layout mutation ends by physical acknowledgement, supersession, direct interaction, cancellation, or deadline.
- Projection installation emits an explicit receipt with transition classification and semantic mapping; scroll does not observe its own epoch through SwiftUI to manufacture acknowledgement.
- Wire keyboard/focus transition start to the real viewport transition. Composer and extension-pill geometry provide layout facts, not separate scroll authority.

Exit: no spinner/command can wedge; streaming during prepend is not lost; keyboard and composer changes retain pinned/detached intent without jitter.

### 5 — Normalize queue and steering settlement

- Reconcile composer submissions directly from authoritative session reducer commits, not `ChatTranscriptPresentationStore.installed` callbacks.
- Carry exact command/operation/queue identity through the optimistic admission when the protocol exposes it.
- Add attachment-only canonical matching that verifies submitted attachment identity/count and does not require synthesized canonical text to equal empty display text.
- Remove local queue clear writes; install the Gateway’s sequenced queue revision or an exact reducer-admissible commit cursor.
- Make an unresolved previous submission a typed visible state, never a generic cancellation popup.

Exit: attachment-only steer/follow-up settles, its empty container disappears, and the next submission obtains a new command ID and reaches the Gateway exactly once.

### 6 — Normalize tool/activity ownership

- Keep Gateway finalized invocation groups and canonical thinking/content barriers.
- Canonical declaration owns position/group identity; execution updates only decorate that declaration.
- Every admitted runtime-only call remains visible through exact canonical transfer or authoritative retirement; terminal status never silently removes it.
- Maintain one extension-activity body map; progress and tool projections reference activity IDs.
- Preserve current-frame output replacement and terminal latching.

Exit: every call/action/thinking/result is in canonical order, one mounted chip exists per position/group, and no duplicate activity body can resurrect.

### 7 — Cleanup, review, and physical acceptance

- Delete retired booleans, side snapshots, local chronology, dead cache paths, compatibility comments, and superseded tests in the same milestones that replace them.
- Update architecture/events/hardening documentation to describe only the final owners.
- Run focused owner suites and generic compile after each milestone. Reserve broad suites for the final checkpoint.
- On the pinned physical device verify resume, active compaction, reconnect, anchorless and anchored paging, streaming, keyboard, detached reading, tool settlement, and repeated attachment-only steering.

Exit: fresh independent reviewers find no ownership blocker; focused tests and physical flows pass; personal-info and diff guards pass.

## Validation contract

Required user-visible outcomes:

1. A session with fewer rows than the bounded recent window opens with all available rows.
2. A larger session opens with the latest bounded canonical window and Load earlier above it.
3. Active/compacting sessions obey the same rule.
4. Content never disappears due to keyboard, scrolling, tail settlement, live output, tool completion, extension activity, or projection rebuild.
5. Load earlier is never an enabled no-op, including when the current transcript is empty.
6. Paging preserves exact canonical order and the visible anchor when one exists.
7. Reconnect and same-session resume preserve the last complete visible commit until replacement is installed.
8. Consecutive tools coalesce only without visible thinking/content barriers; terminal duplicates do not remain at the bottom.
9. Live output updates in place.
10. Attachment-only steering/follow-up settles and cannot leave a stale container blocking later sends.

Focused evidence per milestone:

- owner-level tests for exact state transitions;
- `npm run build` plus focused Gateway Vitest files;
- iOS `build-for-testing` plus only named owner suites;
- `git diff --check` and `scripts/personal-info-guard.sh`;
- final physical-device install and direct flow verification;
- Stable Gateway promotion only through explicit in-app confirmation.
