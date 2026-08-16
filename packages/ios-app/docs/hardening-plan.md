# Tron iOS hardening plan

Status: implementation in progress — Phases 0–2, Phase 3A–3D, and the separate provisional UI removal milestone are complete. Phase 6.0 source characterization/provisional budgets, Phase 6.1 pure Markdown presentation, the bounded Phase 6.2 Markdown/thinking preparation cache, and Phase 6.3 bounded transcript media loading are complete, but physical pixel, accessibility, frame, and memory acceptance remains pending and the Phase 6 exit gate is not met. The common Phase 4/5 chat path now has deterministic scroll ownership, exact-tagged off-main atomic projection, one raw-atom/global assembler with exact ordinal fragment reuse, flat sparse runtime-tool overrides, isolated streaming suffix sharing, bounded latest-tail/page contracts, exact post-layout opening-tail settlement, the completed tool-detail redesign, and role-aligned animated chat activity presentation. Phase 6.2 incremental-prefix parsing remains deferred behind cold differential proof; final physical-device chat acceptance and the remaining Phase 3E/7F UI cleanup are still pending.

Source and owning documentation in the current worktree are authoritative. The reviewed sparse transcript milestone builds on the common projection-kernel checkpoint at `5e5628cb9`. Untracked `.pi` runtime artifacts and historical audit line numbers are not.

Scope: all handwritten iOS app, share-extension, test, project, and owning documentation code under `packages/ios-app`, narrowly required Gateway contract work, and iOS release policy where repository rules require manual delivery.

## Goal

Make the existing Tron iPhone experience deterministic, smooth, bounded, and maintainable without changing product behavior or visual design. Chat is the highest-priority path, especially authoritative opening, streaming, large-session rendering, scrolling, history prepend, attachments, and reconnect.

This is a source-of-truth and ownership refactor, not a new local runtime. Canonical sessions, mutations, receipts, resources, credentials, and runtime state remain Gateway-owned. Every iOS cache or presentation model remains bounded and disposable.

## Required implementation discipline for every phase

Every phase is an architectural cleanup milestone, not an additive feature pass. Its default outcome must be fewer state owners, shorter state paths, fewer branches/tasks, and less code unless production behavior requires otherwise.

- Move each fact directly from its canonical boundary into one typed domain owner and then into the smallest disposable view projection. Do not route state through unrelated global selection, façade fields, views, or compatibility shims.
- Store a fact once. Derive read-only presentation values; never retain parallel booleans, mirrored collections, guessed targets, or a second lifecycle state machine.
- Replace an obsolete owner atomically and delete it in the same milestone. Retired architecture, dead/unused code, legacy names, redundant comments, polling loops, replay paths, and test-only production seams must not remain as an audit ledger.
- Prefer a precise value type or focused owner over a generic abstraction. A new type is justified only when it removes mutable state, invalid transitions, duplicated policy, or cross-domain coupling.
- Keep asynchronous ownership structured and keyed. Every suspension revalidates the smallest immutable identity needed to publish; cancellation and teardown have one idempotent path.
- Keep `AppModel` as a shrinking composition façade. New behavior belongs in the narrow owner; completed phases must remove façade state and pass-through logic rather than layering another coordinator beside it.
- Preserve UI, wire contracts, ordering, and canonical Gateway behavior. Robustness comes from deleting ambiguity and invalid state, not from compatibility branches or speculative fallback behavior.
- Add invariant tests at the owner boundary first, then integration coverage for the exact race. Update the owning docs and remove stale claims in the same commit.

Review for every phase must explicitly ask: what state, branch, task, abstraction, compatibility path, comment, or file can now be deleted? A phase is not complete while two owners represent the same fact or while state travels through an unrelated layer.

## Non-goals

- No UI redesign, new navigation model, or changed user workflow.
- No optimistic reconstruction of canonical session state.
- No local event journal, SQLite session mirror, worker system, or second agent runtime.
- No automatic replay of prompts after an uncertain or interrupted mutation.
- No speculative abstraction layer without a production owner and focused tests.
- No automated production release or deployment.

## Completion criteria

The pass is complete only when:

1. Every mutation, draft, attachment, secondary read, and subscription has one explicit gateway/profile/session/presentation owner.
2. Old tasks, responses, socket callbacks, and sheet lifecycles cannot mutate a newer owner.
3. Settings and resource loads are explicitly scope-keyed; reads cannot trigger their own invalidation loop.
4. Chat projection does not rebuild because of typing, geometry, toolbar, sheet, or unrelated state.
5. Large authoritative tails and explicitly paged history remain bounded, progressively prepared, and smooth on a pinned physical device.
6. Scroll commands are deterministic, coalesced, and subordinate to direct user interaction.
7. Markdown, JSON, image, tool-detail, cache, upload, export, and terminal memory/I/O have explicit budgets.
8. Transport, reconnect, open/sync, receipt, paging, share, and system-service races have deterministic tests using injected clocks and transports.
9. Focused owners, full native suites, controlled Gateway E2E, accessibility checks, personal-info guard, and physical-device performance checkpoints pass.
10. Every owning document—including architecture, events, development, onboarding, README, and release guidance—describes the final contract with no stale completion-plan or native-speech claims.
11. Automated production/TestFlight delivery is removed or disabled; release remains a manual maintainer action.
12. Each phase measurably shrinks or simplifies the ownership graph: no duplicate fact, retired owner, dead path, compatibility branch, or unnecessary state hop remains after its replacement lands.

## Audit summary

Eight independent read-only audits covered state architecture, chat scrolling/performance, transcript content, Gateway events, data/cache/privacy, non-chat UI, tests/determinism, and cross-cutting code quality. Their findings were reconciled against audit and implementation baseline `cee85b64a`, which includes the committed removal of unfinished app-owned iOS voice input; stale speech findings are excluded.

### Milestone status

**0A — Repository policy and canonical documentation: complete.** The automatic iOS production/TestFlight workflow was deleted; README, contributor, pull-request, and iOS development guidance now require manual maintainer delivery; the obsolete gateway-integration completion plan was deleted after its canonical architecture/event/onboarding facts were confirmed in owning docs and its signed-release checks were condensed into development guidance; and the architecture source map no longer claims app-owned native speech. System-keyboard dictation remains documented. This milestone changes no product behavior or UI.

**0B.1 — Deterministic Gateway boundary and strict baseline: complete.** `GatewayClient` now owns byte-level injectable WebSocket, monotonic-clock, and UUID seams; Gateway-related `AppModel` waits and command IDs use injected production-identical defaults. Focused transport tests characterize hello/request bytes, response/event admission, virtual timeout, exact socket close, and overflow signaling. Swift complete strict concurrency is explicit. These seams contain no session runtime, event journal, receipt policy, epoch fix, or UI change.

**Provisional UI removal — complete as a separate user-directed serial milestone.** The composer waveform, custom subagent session-management sheet, and `pi-subagents` async/fleet editor widgets were removed from chat presentation. Other extension widgets remain supported. Active visible working and retry feedback uses the established compact runtime row without changing composer or scroll ownership. Session kind/classification and dashboard filtering remain canonical; the dashboard retains user sessions and ordinary forks while hiding subagent backing sessions. This milestone does not advance or implement any pending numbered hardening milestone.

**0B.2 — Pairing transport and pre-commit attempt admission: complete.** `GatewayPairer` owns a narrow injectable HTTP-data transport and deterministic `/v1/pair` request/status/error decoding. `AppModel` owns one exact cancellable pairing task; supersession, forget, and switch invalidate it, with admission checks after HTTP, before profile/Keychain save, before connect, and through connect suspension boundaries. Barrier-controlled tests prove stale HTTP success cannot commit metadata/token or initiate connect. This does not claim Gateway connection-epoch safety or transactional profile replacement.

**0B.3a — Deterministic generated scenarios: complete.** A test-only seeded builder produces byte-bounded opening tails, on-demand 10,000-entry paging ranges, long history pages, 100–256-tool bursts, 30/60 Hz cumulative Markdown updates, and synthetic high-resolution attachment data. Focused tests fix exact counts, bounds, overlap/gap behavior, rates, IDs, and privacy-safe content. It creates no production cache, transcript mirror, runtime, or session owner. Phase 6.0 source characterization subsequently corrected Markdown updates to true prefix accumulation across adversarial syntax transitions and added test-time generated, valid oriented JPEG/PNG fixtures with deterministic pixels; no opaque binary was added. This source evidence does not claim physical visual or performance acceptance.

**0B.3b — Hosted presented-frame scroll harness: complete.** Test builds can admit a synthetic snapshot through the existing authoritative read gate and bypass only network opening. The harness mounts the real `ChatView`, lazy transcript, composer inset, and native scroll view; bounded semantic row frames and geometry are sampled per `CADisplayLink` frame, and hosted visibility is derived from measured viewport intersection rather than a production visibility callback. Focused tests prove native-scroll fidelity, latest-tail visibility, authority gating, watchdog-bounded waits, and at-most-one recorded sample per presented frame. No test hook ships in Beta or production.

**0B.4 — Privacy-safe instrumentation and performance evidence: complete.** The typed signpost vocabulary is installed. Gateway connection, disposable cache load/save, visible session open, authoritative sync/resync attempts, uncertain-command receipt resolution, and terminal attach/replay now expose only closed result codes and aggregate item/byte counts. Shared interval handling removed duplicate terminal replay installation and centralizes success/failure/cancellation closure. Focused spies characterize these boundaries without admitting profile IDs, session IDs, paths, command IDs, model names, prompts, transcript content, terminal output, or filenames. Deterministic chat projection records only projected row count, and first-ready timing ends on the next actual `CADisplayLink` presentation rather than model readiness. Generation-owned scroll and prepend intervals discard replaced commands, reject stale prepend completion, and cancel exactly once at teardown; stale paging defer blocks cannot clear a newer paging owner. Prepend success is recorded only after an exact post-install semantic-frame sample confirms the anchor within one point. The reproducible five-sample simulator and pinned-device timing, hitch, allocation, and memory evidence is recorded in `performance-baseline.md`; high-variance allocator deltas and internally inconsistent XCTest frame-rate estimates are reports, not gates.

**0B.5 — System-service seams: complete.** Camera authorization and capture-session ownership now sit behind narrow injectable providers while `CameraModel` retains the existing UI-facing state machine; deterministic tests cover grant/deny/setup failure, session commands, torch ownership, flip, and no-output capture without touching hardware. The pairing QR controller shares authorization, delegates serial session start/stop, cancels pending permission on disappearance, and admits exactly one result under hardware-free tests. The share extension reduces ordered fragments outside its controller, uses store/app-opener seams, and packages a privacy manifest alongside the app; focused bundle tests and a read-only archive verifier require both manifests. Presentation source guards now retain visual policy assertions without pinning moved projection, scroll-algorithm, or explanatory-comment spellings.

**Milestone 1 — Identity and invalidation defects: complete.** Settings, provider/model catalog, package, and custom-model views now key reloads to explicitly named event-only invalidation generations. Successful publications no longer advance those generations. Settings reads, writes, installed values, and SwiftUI load identities use typed `.global` or `.project(cwd:)` targets; the three settings screens have one automatic task owner instead of parallel scope-change tasks. Different targets cannot overwrite each other, newer same-target reads reject older completions, and global updates cannot inherit a selected project's path. New-session defaults use the workspace being created rather than a previously selected session, and workspace changes close creation admission until matching settings/trust reads complete. Watchdog-bounded scripted Gateway tests prove these ordering rules and that successful reads cannot trigger self-sustaining reload loops. Provider/model catalogs now use typed global/session targets, atomic paired publication, stale-request rejection, and auth-operation target retention through completion or confirmed cancellation. Package inventory, update checks, and mutations now use typed global/workspace targets with stale-request admission and target-keyed update markers. Trust reads/mutations now require typed nonempty project targets; project Settings captures its route identity, onboarding rejects stale workspace trust, and trust invalidation closes new-session admission until the matching workspace is re-inspected. Custom-model reads and writes now carry an explicit typed global target, generation-owned publication rejects older reads, and one draft owner protects both guided and advanced unsaved edits from invalidation reloads. Model/default, runtime-behavior, and resource-location settings now preserve revision-owned global/project drafts, reject invalidation overwrite while dirty, reject stale save completion, and emit only fields changed from the admitted baseline so project inheritance remains intact. Provider catalogs match the selected scope, and write-only proxy state is redacted, explicitly clearable, and scrubbed after save. Scope-keyed settings drafts and explicit route/session mutation identity are complete: mounted routes supply every session mutation and secondary read, secondary surfaces cannot create hidden subscriptions, and create/import/fork return navigation results without pre-emptively replacing selection or subscription ownership. Attachment uploads, staged attachment lists, sends, and editor requests are now keyed by session plus presentation generation; stale completions are rejected, route replacement revokes intake synchronously, and share delivery retains its payload until the sole admitted presentation confirms prompt admission. Dashboard discovery no longer selects or opens a transcript, global/project refresh targets are explicit, older catalog loads and import completions cannot replace newer dashboard intent, and reconnect restores only the still-mounted presentation. Dashboard synchronization now uses one user-scoped, page/item/identity-bounded single-flight traversal with a dirty-bit follow-up; known revisioned summaries update in O(1) without a list read, and unknown summaries discover without fabricating rows. Gateway pagination holds one authenticated, TTL/LRU/count/byte-bounded immutable catalog materialization per traversal while row summary revisions remain independent and atomically paired with their fields. Mixed legacy page revisions silently restart once and retain prior rows rather than showing the removed “Sessions changed while loading the dashboard” alert. Cached/stale activity is provenance, not a fabricated `.interrupted` phase: non-idle rows show a resuming spinner until a live summary/list arrives, and only a live authoritative interruption is amber. Backgrounding gates and cancels disposable catalog/foreground work without closing the route or socket; foreground and reconnect run catalog convergence concurrently with mounted-session restoration, then reattach terminals only after the exact connection subscription is installed; catalog failure cannot replace a responsive socket. Global notices have explicit 8-item, 4 KiB-per-message, and 16 KiB-total limits; duplicate and keyed progress notices coalesce, targeted completion removes only its own progress, and profile teardown clears the projection.

**Milestone 2 — Transport, synchronization, and receipts: complete.** `GatewayClient` now owns one cohesive connection epoch containing the exact socket, receive/liveness tasks, pending requests, liveness timestamp, overflow state, and handshake result. Concurrent connect/close invalidates older attempts before and after every suspended handshake boundary; stale hello, frame, receive failure, liveness, pending completion, teardown, and suspended close work cannot publish into or disconnect a replacement. Idle receive and liveness tasks weakly retain the client, current transport cancellation disconnects deterministically, and teardown emits at most one current-epoch disconnect. Pending requests own send and timeout tasks plus queued/sending/sent state; pre-send cancellation is definitive, while cancellation, timeout, failure, or disconnect after send begins carries a local non-wire-forgeable possibly-sent error. Mutation cancellation after that boundary never replays automatically, confirmed-missing replay rechecks cancellation, and definitive retryable Gateway responses do not enter receipt polling. Gateway receipts remove pending state after an observed application rejection but retain pending if completion persistence fails after successful execution. Session synchronization now has one intent-keyed coordinator instead of token polling: compatible callers await one typed outcome, incompatible fresh/reconnect intents arbitrate serially, and event quarantine, retry/fresh-install invalidation, and shared completion live in that owner rather than parallel AppModel sets. Open snapshots/subscription tokens remain provisional until sync acknowledgement and route revalidation; the baseline and prevalidated contiguous suffix publish in one MainActor turn. Stale or failed attempts close only their provisional token and cannot publish over cached or mounted state. The unused selection-based `openSession` path and recursive resync chain are deleted; immediate gap/overflow retries use one cancellation-aware three-attempt loop. One monotonic connection-lifecycle boundary governs pairing replacement, switch, forget, current-device revoke, foreground reconciliation, reconnect, debounced refresh, and final teardown; Phase 3A subsequently moved its sole stored state and task ownership from the façade into `GatewayLifecycleCoordinator`. Profile transitions synchronously revoke presentation intake and profile-scoped loads, await the exact socket close before replacement connect, and reject stale suspended publications. Event deliveries carry their local connection identity; lifecycle connects install that identity before activating receive/liveness work, so buffered old-profile frames are inadmissible. Possibly-sent mutation reconciliation and terminal reads are lifecycle-generation-bound, so they cannot publish, poll, or replay through a replacement profile. Final teardown cancels and joins the event listener and shares completion across callers without treating ordinary backgrounding as teardown. Reconnect preserves its nominal 2-second, ×1.7, 15-second-cap progression while independently jittering every delay within a hard-bounded 80–120% window. Foreground activation accelerates only a pending delay, duplicate activation cannot replace an active handshake, and exact attempt generations reject stale cancellation or unauthorized completion. Inbound response/event bytes now cross one discriminated frame decode; the client actor best-effort prepares large session DTOs before MainActor admission while retaining raw payloads for unknown-topic and malformed-inner-data compatibility. Unsolicited full snapshots now require the current live authority, matching route/runtime identity, and exactly the next cursor; duplicates and stale values are inert, gaps/runtime replacement/missing baselines resynchronize without publishing, and missing authority or route mismatch is discarded. Terminal lifecycle now has one presentation/intent coordinator: stale and out-of-order attach responses cannot publish, successful stale attachments are compensated on the originating connection, output/exit frames are admitted only for current shared leases, bounded pending frames join replay contiguously, and final-owner revocation removes intake synchronously. Replay reset advances explicit native renderer identity, so replacement content cannot append to a stale emulator buffer.

**Milestone 3 — Domain-owner extraction: in progress.** Phase 3A–3C are complete. The common Phase 4/5 projection—including sparse affected-tool/canonical-entry work—opening, paging, and scroll paths, Phase 6.0 source characterization/provisional budget decisions, Phase 6.1 pure Markdown presentation, the bounded Phase 6.2 text-preparation cache, and Phase 6.3 bounded media are complete. Physical Phase 6 acceptance and the remaining Phase 3E/7F UI boundary splits are the immediate priorities while incremental-prefix parsing remains gated on differential cold equality. `SessionCatalogCoordinator` owns disposable dashboard rows and load admission; `GatewayLifecycleCoordinator` owns enrollment/profile/connection lifecycle; and `SessionPresentationStore` solely owns the mounted immutable route, revocation, live snapshot, exact subscription, synchronization/quarantine, cursor reducer, strict snapshot admission, paging, and session-keyed context/tree/resources/commands. `SessionMutationService` owns every explicit session command DTO, wire method, timeout, and typed result, while the shared `ConfirmedMutationExecutor` owns lifecycle-generation-bound possibly-sent receipt resolution for all domains. `SessionImportCoordinator` owns the security-scoped read/upload/import pipeline and rejects every completion whose captured lifecycle generation or selected profile was replaced. `SettingsTrustCoordinator` solely owns target-keyed disposable settings projections, settings read admission and wire construction, trust operations, and event-only settings/trust revisions; profile retirement clears projections and revokes suspended completions atomically while screen-owned revisioned drafts remain local. `ProviderAuthCoordinator` solely owns typed-target atomic provider/model projections, paged load admission, event-only provider invalidation, auth prompt/event parsing, and operation-to-target retention; stale responses and profile retirement cannot clear or refresh replacement auth state. Separate `PackageConfigurationCoordinator` and `CustomModelConfigurationCoordinator` owners now contain their target-keyed disposable projections, newest-load/mutation admission, event-only invalidation, exact wire details, confirmed receipts, and profile revocation. Custom-model validation cannot put after retirement, stale mutation failures become cancellation while current-profile errors and uncertainty remain visible, Save and Restart retains one exact lifecycle admission, and its screen-owned draft clears only the submitted monotonic revision. `ComposerDraftCoordinator` owns profile/session-scoped revisioned text drafts, a deterministic 24-inactive-draft LRU, exact mounted-presentation leases, staged attachments, independent upload admissions, editor request disposition, and submission snapshots. Route close retains only text; staged attachment IDs, editor requests, uploads, sending state, and error admission are presentation-scoped and synchronously revoked. AppModel composes these owners and retains only narrow cross-domain effects; it no longer stores lifecycle facts, a snapshot graph, presentation/subscription maps, synchronization state, secondary session projections, session command construction, receipt policy, import file/upload sequencing, settings/trust projection and request state, provider/auth projection and routing state, package/custom-model projection and request generations, composer attachment/editor collections, or terminal reducer/request/cleanup/reconnect state. Cold cache snapshots cannot become live authority. Same-profile receipt resolution retains generation admission while connection-owned terminal results must reattach after replacement.

### Verified performance risks

- Ordinary text/thinking/image streaming shares its immutable canonical row/identity prefix and projects only the live suffix. Proven payload-only runtime-tool updates replace affected flat row indexes; structural or canonical-result changes conservatively return to fragment reuse plus the sole global assembler.
- Eligible render-critical Markdown and thinking revisions are prepared off-MainActor once and installed atomically with the exact projection. Cache misses, oversized sources, evicted history, and changed streaming revisions still use the sole complete cold parser; a single maximum-size changed message remains expensive even though its admitted preparation is no longer on the rendering path.
- Transcript thumbnails now use one profile/connection/blob-keyed single-flight owner, off-main 192-pixel downsampling, and a 64-item/4 MiB decoded LRU. Full previews remain intentionally uncached and one-at-a-time; their physical decoded peak still requires device calibration.
- Request/Result payloads are technical-detail-only and now require a second explicit per-payload disclosure before `TronStructuredJSONView` performs top-level projection; full raw formatting remains behind that component's separate user disclosure. Constant-depth payload summaries keep the technical overview bounded.
- Expanded-history merge, snapshot decode, JSON round trips, and full-file attachment work need tighter off-main and bounded ownership. Dashboard cache checkpoints are now newest-wins and serialized/coalesced, so revisioned summary bursts cannot publish older disk state.

### Measured before changed

Several visible severity claims remain hypotheses until Instruments establishes the baseline: exact frame-hitch contribution, MainActor cost, row-identity replacement impact, initial reveal timing, and cache/I/O contention. Phase 0 adds evidence before structural changes.

## Target ownership

Keep one MainActor `AppModel` environment façade during migration, but make it compose narrow owners instead of retaining every domain itself.

### `GatewayLifecycleCoordinator`

Owns pre-auth enrollment attempts, the selected profile, authenticated connection epoch, connection state, reconnect loop, foreground reconciliation, and teardown.

Invariants:

- Pairing has one cancellable attempt ID and revalidates ownership before credential commit or connect.
- Every result/event is tagged with an epoch.
- Identity is revalidated after every suspension.
- Forget, revoke, switch, and replacement cancel and await old-epoch work.
- One epoch emits at most one disconnect transition and owns one reconnect loop.

### `SessionCatalogCoordinator`

Owns paginated summaries, summary overlays, and catalog cache admission. Legacy local-hidden preferences remain migration-only façade state until their UI path is removed.

Invariants:

- Loads have generation, revision, page, and item ceilings.
- Cancelled/older loads never install.
- Catalog selection is not navigation and does not subscribe to a transcript.
- The store owns summaries and cache-admission policy, never a second transcript snapshot graph.

### `SessionPresentationStore`

One bounded store/lease per mounted immutable session presentation.

Owns the sole mounted live `SessionSnapshot`, open/sync tasks, provisional and installed subscription leases, event cursor/quarantine, presentation generation, authoritative merge, transcript paging, and session-keyed context/tree/resources/commands.

Invariants:

- The mount's immutable session ID is the only target.
- Synchronization work is keyed by connection epoch, session ID, presentation generation, and install intent. Only compatible callers share a result; a fresh-mount replacement cannot accidentally reuse reconnect-merge installation.
- Receiving `session.open` creates a provisional lease immediately. Cancellation, stale generation, sync failure, and teardown close that exact token; successful sync promotes it to the installed lease.
- No waiter succeeds until its requested installation intent, sync acknowledgement, quarantine completion, and contiguous replay finish.
- Fresh presentation replaces cached/expanded history; reconnect preserves only compatible explicitly loaded history.
- Close releases only the exact token and mount generation, and a stale close cannot clear a newer lease.
- Cached snapshots remain cold disposable inputs and cannot become readable live state before successful open/sync.

### `SessionMutationService`

All APIs require explicit session identity and preserve centralized command-receipt policy, for example:

```swift
prompt(sessionID:text:uploadIDs:behavior:)
abort(sessionID:kind:)
setModel(sessionID:model:)
fork(sessionID:entryID:position:) -> SessionForkOutcome
answerInteraction(sessionID:interactionID:value:cancelled:)
```

The service generates one stable command ID before each request; `ConfirmedMutationExecutor` reuses that exact ID if a confirmed-missing receipt permits replay. No mutation reads a global selected session. Fork returns a navigation result; the route owner changes destinations explicitly.

### `ScopedConfigurationStore`

Uses a typed key such as `.global`, `.project(cwd:)`, or `.session(id:)` for settings, providers, models, packages, trust, and related drafts.

Invariants:

- Request key equals installation key.
- Late results cannot overwrite another key.
- Gateway invalidations and successful mutations advance invalidation generations; reads do not.
- Each visible screen owns its draft and load/error state for one explicit key.

### `SessionImportCoordinator`

Owns security-scoped file access, file read, upload, and handoff to the existing session mutation owner under one exact lifecycle-generation/profile admission. It retains no upload registry or canonical session state.

Invariants:

- Access acquired for a file is released exactly once on success, failure, or cancellation.
- Read and upload completions revalidate the captured lifecycle generation and selected profile.
- An upload ID produced before profile replacement can never be submitted afterward.

### `ComposerDraftStore`

Owns text/editor requests, pending attachment upload IDs, thumbnails, limits, and errors per profile/session/presentation according to an explicit draft-retention policy.

Invariants:

- Upload completion verifies its original owner before installation.
- One session's attachment ID can never be submitted to another.
- Navigation never transfers staging implicitly.

### `ChatPresentationStore`

A bounded, disposable mounted projection derived from versioned immutable snapshots. It is not a transcript mirror or event journal: it never subscribes to, admits, replays, or independently merges Gateway events.

Owns the complete ordered lightweight descriptor spine, stable presentation identities, incremental projection, parsed-content caches, render-critical tail preparation, and projection revisions. Every off-main input/result is `Sendable` and tagged by session ID, presentation generation, runtime generation, authoritative revision, and monotonically increasing projection request revision; MainActor installation rejects any mismatch. Geometry is not a projection input.

### `TerminalCoordinator`

Owns terminal request execution, terminal/session identity, attach lifecycle, cleanup and reconnect tasks, replay epoch, bounded chunks, intent-keyed 120 ms resize debounce, and teardown around one pure `TerminalReducer`. A reset replay replaces native terminal content even when sequence numbers do not increase.

## Current worktree checkpoint

Completed since the sustained-chat milestone:

- Tool-detail sheets now use compact intrinsic metadata chips, restrained/accented paths, word-wrapped bash commands, larger results, faithful exact single-change inline diffs, dedicated multi-change sheets, and live immutable tool updates without automatic scrolling.
- Technical details now keeps compact selectable execution metadata first and then presents direct Request JSON followed by Result JSON, with no duplicated readable-output section, structured-field container, third fallback section, or raw JSON disclosure. Result resolution is response, then content, then a fallback distinct from the request, then JSON `null`.
- Session opening no longer consumes its final tail command before the newly revealed lazy transcript is laid out. Settlement requires the exact installed timeline-tail identity, current presentation/layout epoch, valid geometry, and target-specific frame evidence; transient boundary geometry, auxiliary rows, stale presentations, and direct user interaction cannot repin it.
- The attachment control retains the native `UIMenu`, 40-point plus target, option order, and picker routing while remaining usable with a focused nonempty editor and leaving the keyboard visible.
- User prompts remain right anchored: short prompts hug their intrinsic width, longer prompts stop at 364 points, and lines use logical-leading alignment with a 10% smaller Dynamic Type font plus explicit leading separation. Agent prose/tools remain left aligned, while canonical and runtime system activity is centered in one compact capsule language. Send feedback and one-shot geometry-admitted entrances now share that spatial model: prompts/queued intents rise from the trailing composer edge, tools from leading, system capsules from center, and prose vertically. No provisional row is created; Reduce Motion removes every spatial component, detached readers gain no follow authority, and stable same-ID morphs do not replay. Flat no-detail notifications, interactive glass details, stable compaction morphing, and discrete smooth tail following retain their existing ownership.
- Active-chat entrance geometry now belongs to the exact displayed installation rather than a model-ahead desired source. Only pending rows carry an entrance tag, installed row identity retains the bounded one-shot smooth-follow entitlement, and unanchored runtime tools remain after non-tool streaming regardless of status. Shrink remains inert; no automatic shrink-follow path was added.
- Focused owner suites, repeated hosted scroll-harness runs, the full native suite, strict unit/UI-test builds, privacy/diff guards, and production device builds/installations pass for the committed checkpoint; the subsequent chat role/activity work has the same automated validation but still awaits production device installation and physical acceptance.

Next sequence:

1. Physically accept the installed opening, attachment-menu, tool-detail, and Technical details behavior, including light/dark and accessibility checks.
2. Physically calibrate the completed Phase 6.2 text cache and Phase 6.3 media loader before tightening provisional limits. Keep incremental-prefix Markdown parsing deferred until differential tests prove exact cold equality.
3. Resume Phase 3D/3E terminal/event reducer and direct-boundary cleanup.
4. Do not implement bidirectional detached-history eviction until Gateway provides a safe forward-paging/reload contract.

## Execution plan

Work proceeds as serial milestones. Each milestone gets one writer, a bounded owner/file set, characterization tests first, named focused tests/commands, same-change owning documentation, independent review, and parent acceptance before the next milestone. Do not parallelize writes in the active checkout. The numbered phases are ordering groups; lettered owner milestones within them ship independently rather than as multi-domain rewrites.

### Phase 0 — Freeze contracts and establish evidence

Milestone 0A completed the repository-policy and canonical-documentation slice described above. Milestone 0B.1 completed the byte-level Gateway WebSocket factory/connection, monotonic clock/sleeper, UUID source, strict-concurrency setting, and focused transport characterization tests. Milestone 0B.2 completed the pairing-only HTTP-data seam and pre-commit attempt admission without broadening that seam to other HTTP owners or claiming a connection epoch. Milestone 0B.3 added deterministic test scenarios and a hosted real-scroll harness without production runtime state. The separate provisional UI removal changed only the user-directed presentation surfaces summarized above and did not begin any remaining hardening work. Milestone 0B.4 completed the display-frame scheduler, typed signposts, deterministic hosted performance fixture, and simulator/pinned-device baseline report. Milestone 0B.5 completed camera/QR authorization and capture-session adapters, share store/app-opener seams, extension pure logic, app/extension privacy-manifest package and archive assertions, the strict-concurrency checkpoint, and removal of brittle nonvisual source spellings from presentation guards.

Baseline fixtures:

- Maximum ordinary opening snapshot near the Gateway byte budget.
- 10,000-entry explicitly paged mixed session.
- Maximum history page with long rows.
- 100–256 parallel tools with live progress.
- Cumulative Markdown at 30 and 60 updates/second.
- High-resolution image attachments.

Exit gate:

- Existing behavior is captured without intentionally changing pixels, navigation, ordering, or mutation semantics.
- Baseline signpost, frame-hitch, allocation, and memory reports exist for simulator and a pinned device, recording device/OS, refresh-rate mode, build configuration, thermal/Low Power state, fixture, cache state, duration, and sample count.
- Manual release policy and canonical documentation no longer contradict repository rules or current source.

### Phase 1 — Fix verified identity and invalidation defects

Deliverables:

- Split invalidation generations from projection publication for providers, settings, packages, and custom models.
- Introduce explicit typed configuration targets and key installed values/drafts by scope.
- Add explicit session IDs to every session mutation and secondary read.
- Change fork to return a route result; remove pre-emptive subscription assignment and wrong-route mutation opportunity.
- Move editor requests and attachment staging under immutable session/presentation ownership.
- Make dashboard catalog/navigation state unable to silently become a hidden transcript subscription or project-scope selector.
- Bound global notices and coalesce replaceable progress messages.

Focused gates:

- One visible settings screen performs one initial read and no more until an actual invalidation or explicit reload.
- Out-of-order global/project/session responses remain in their keyed owners.
- Mounted chat A can never mutate B before route navigation.
- Delayed attachment completion from A cannot appear in B.

### Phase 2 — Harden transport, reconnect, synchronization, and receipts

Deliverables:

- Introduce a connection object/epoch containing socket, receiver, liveness task, pending requests, and teardown.
- Revalidate epoch after every suspended send, hello, receive, liveness, and decode boundary.
- Make pending requests own their send/timeout tasks and define pre-send, possibly-sent, and completed cancellation outcomes.
- Make mutation receipt reconciliation handle possibly-sent cancellation without automatic duplication.
- Replace session-sync token polling with intent-keyed shared work: compatible reconnect callers may share, while fresh-presentation replacement is arbitrated separately and cannot inherit reconnect installation semantics.
- Model provisional subscription-token cleanup explicitly across cancellation, stale generations, failed sync, and replacement.
- Make disconnect/reconnect idempotent per epoch; preserve backoff and add bounded jitter.
- **Complete:** reject stale, duplicate same-cursor, wrong-runtime, wrong-route, and unauthoritative snapshots outside explicit authoritative-install paths.
- Restrict receipt uncertainty to true transport-loss outcomes; do not treat definitive retryable application errors as lost responses.
- Add explicit AppModel/coordinator teardown.
- **Complete:** decode each inbound frame once and move large DTO decode/projection preparation off MainActor while preserving unknown frame/topic and malformed-inner-payload compatibility.

Focused fault injection:

- Late pairing result after forget, switch, or a newer enrollment attempt.
- Stale hello/frame/disconnect after replacement.
- Cancel before send, during suspended send, and after bytes may be accepted.
- Response/timeout/cancellation races with one continuation completion.
- Failed sync with multiple waiters.
- Gap, overflow, runtime replacement, replay, and stale close.
- Receipt completed/missing/pending/unknown/busy paths under a virtual clock.

### Phase 3 — Extract real domain ownership from `AppModel`

Independent owner milestones:

- **3A lifecycle/catalog — complete:** compose lifecycle and catalog owners behind the existing façade.
- **3B session presentation/mutations: complete.** Presentation/synchronization/secondary ownership lives in `SessionPresentationStore`; explicit command construction lives in `SessionMutationService`; one `ConfirmedMutationExecutor` resolves possibly-sent receipts across domains.
- **3C scoped configuration/drafts — complete:** 3C.1 moved security-scoped file access, read/upload sequencing, and exact lifecycle/profile admission into `SessionImportCoordinator`; 3C.2 extracted settings/trust projection and request ownership; 3C.3 extracted provider/model catalog and operation-keyed authentication ownership; 3C.4 extracted separate package and custom-model configuration owners plus revision-safe custom-model save admission; 3C.5 extracted bounded profile/session text drafts and exact-presentation attachment/upload/editor/submission ownership into `ComposerDraftCoordinator`. Existing session wire mutations remain in `SessionMutationService`, and confirmed receipts remain in `ConfirmedMutationExecutor`.
- **3D terminal/event reducers — complete:** terminal output/exit payloads decode once into typed `Sendable` preparations before MainActor routing. Observable `TerminalCoordinator` owns every terminal request DTO/wire operation, receipt-aware command, presentation/intent, cleanup task, compensating detach, attach/replay interval, gap reconciliation, reconnect reattachment, and the unchanged 120 ms intent-keyed resize debounce around its sole pure `TerminalReducer`. Resize requests clamp to the established 20...400 columns and 5...200 rows, coalesce only within one intent, run independently across presentations, and cancel on intent replacement, presentation close, or profile retirement. `AppModel` retains only façade delegation plus centralized connection event/lifecycle routing, and canonical session cursor/subscription ownership remains in `SessionPresentationStore`.
- **3E boundary cleanup — direct view calls and DTO decomposition complete; remaining UI cleanup pending:** transcript blobs route through the lifecycle-bound media owner, while project Git inspection and bounded logs route through `GatewayDiagnosticsService`. Views no longer construct Gateway requests or parse those wire objects; transport-safe log fields moved to the service while color/icon/date presentation remains UI-owned. One shared `ToolExecutionStatePolicy` owns newest-state and ordering semantics for both the canonical session reducer and sparse transcript projector, eliminating their drift risk. Gateway-connection, session-catalog, transcript, session-runtime, resource-catalog, workspace, and terminal DTOs now live in authority-cohesive files with their Codable contracts unchanged. Continue splitting remaining UI files at existing presentation boundaries without changing behavior.

Each submilestone leaves a compiling façade and moves its focused tests/docs with the owner; do not land all extractions in one diff.

Exit gate:

- No owner depends on mutable global selection to infer a request target.
- `AppModel` is composition and cross-domain routing, not a 2,000-line mutable domain store.
- Extraction tests prove no extra canonical source was created.

### Phase 4 — Make chat projection incremental, lightweight, and isolated

Deliverables:

- **Complete:** frame-coalesced typed scroll-command ownership is active before asynchronous projection work; publication cannot amplify a height-driven command loop.
- **Complete:** move timeline projection out of `ChatView.body` into `ChatTranscriptPresentationStore` and prepare it off-main from immutable tagged inputs.
- **Complete:** serialize detached builds, coalesce to one pending newest snapshot, and reject stale/out-of-order results by the full session/presentation/runtime/authoritative/paging tag, including A→B→A.
- **Complete:** share the immutable canonical row/identity prefix and recompute only the text/thinking/image live suffix; cold/incremental parity is exact across rows, order, tools, and semantic maps.
- **Sparse kernel complete:** one Sendable kernel builds exact per-entry raw atoms and is the sole global assembler for bootstrap filtering, call/result joining, orphan suppression, exact ordinals, barriers, grouping, runtime-tool placement, compatibility normalization, and complete semantic maps. Exact windows align reuse by global ordinal and require complete source equality; ambiguous legacy/duplicate windows fall back conservatively. Assembler-emitted unique tool sites permit payload-only immutable descriptor patches only under unchanged canonical, streaming, phase, membership, order/start, run, and placement proofs. Otherwise mixed reused/rebuilt fragments return to the same assembler. A flat immutable row base plus direct index overrides avoids chained overlays and resets on assembly. The worker retains one scoped complete basis/candidate, exact-key fast return, and monotonic reset retirement. The public cold oracle and detached worker use this kernel; the `HOSTED_TEST` work gate delays actual production work only. Aggregate reports contain only a closed mode and numeric entry/fragment/tool/atom/rendered counts, and raw fragments retain all explicitly loaded history beyond 512.
- **Complete:** publish only complete immutable timelines at a display-frame boundary; multiple completed sources before that boundary retain only the newest exact source.
- Atomically publish the complete ordered lightweight descriptor spine with shallow version equality before reveal; background cache fills do not publish a projection revision unless visible row output changes.
- Separate compact tool summaries from detail payloads through exact session/presentation/runtime/tool identity, never mutable global selection. **Presentation complete:** collapsed rows retain structured values, live detail routes resolve by immutable call identity, compact/intrinsic chips and semantic primary fields are installed, and no request/response JSON is eagerly formatted. Sparse payload-owner extraction remains.
- **Complete for projected tool rows and Technical details:** defer `JSONValue.prettyPrinted` until the detail sheet opens; render direct Request JSON then Result JSON only in that sheet. A detail-lifetime formatting cache remains an optional Phase 6 follow-up.
- **Complete for detail fidelity:** inline diffs require exactly one requested change and one fail-closed valid diff unit; malformed, combined, header-light multi-file, multi-change, and ambiguous patches use the dedicated Changes sheet. Preview omission identities and accessibility labels are stable and bounded.
- **Complete for detail-sheet geometry:** consolidated runs, individual tools, Changes, and Technical details share explicit inline navigation chrome, eliminating the empty large-title reservation so top-anchored content begins directly below the toolbar at every detent.
- **Complete for chat role geometry:** width-aware TextKit keeps short user prompts intrinsically sized at the trailing edge and bounds longer prompts to a right-anchored 364-point block. Lines use logical-leading alignment, a 10% smaller Dynamic Type font, and 28 points of external leading separation; agent prose/tools remain left and system events are centered.
- **Complete for compact activity presentation:** canonical notifications, runtime working/status, errors, and agent tool/run chips share one capsule primitive and semantic tone model. Real detail actions alone use interactive Liquid Glass; no-detail notifications remain flat and noninteractive. Exact compaction bounds permit an in-place pending-to-canonical transition without changing Gateway identity.
- Remove unused fields from unread-response observation.
- Preserve visible ordering and grouping with golden tests against the current timeline.
- Stabilize presentation identity across streaming-to-canonical settlement and overlapping tool-group expansion.
- **Complete:** every discrete tool-chip insertion and visible state/content change uses the shared compact motion policy, honors Reduce Motion, and preserves stable chip identity without replaying entrances after lazy realization.
- **Complete:** compact tool chips hug their intrinsic content; no flexible leading space precedes timestamps, so each chip is only as wide as its label, status, and timestamp require.

Exit gate:

- **Complete for whole-timeline projection:** typing, geometry, toolbar width, sheet state, attachment-menu state, and unchanged snapshots cause zero timeline projection work.
- A tool-progress event updates only the owning tool/run descriptor and dependent tail state.
- **Complete:** tool chips animate appearance and changes consistently with thinking traces, timestamp layout introduces no flexible unused leading gap, and unanchored runtime tools stay after non-tool streaming through running/completed/group transitions.
- Cancelled/out-of-order projection, reconnect replacement, and prepend-overlap completions cannot install.
- MainActor publication plus the defined SwiftUI diff/command boundary stays within the calibrated budget.

### Phase 5 — Make scrolling and prepend deterministic — production ownership and focused hosted gate complete; physical evidence pending

Deliverables:

- **Complete:** raw geometry and semantic row frames leave broad `ChatView` state and enter one scroll reducer; the obsolete production visibility callback is deleted.
- **Complete:** one owner emits a typed optional command, coalesces follow-tail to at most one command per display frame, and skips writes inside the practical bottom boundary. Physical bottom distance uses native `visibleRect.maxY` plus bottom inset rather than independently settling offset/container arithmetic.
- **Complete:** direct/native/accessibility interaction is absolute authority and synchronously cancels pending automatic commands; geometry-first manual return to the measured tail clears catch-up without requiring a button tap.
- **Complete:** the 60-frame prepend polling loop is replaced by one generation/token-scoped semantic-anchor transaction; canonical-to-rendered mapping survives page-boundary tool grouping.
- **Complete:** exact page install advances a layout epoch carried by the row geometry transform, so an unchanged numeric frame still emits an exact post-epoch sample. Prepend passively waits for that sample, requires a strictly newer exact sample after each correction, permits at most one late correction, and succeeds only within one point. No next-frame assumption or total tail/content height drives correction.
- **Complete:** the load token stays active through settlement, repeat taps are no-ops, and stale work cannot end a newer transaction.
- **Complete:** geometry-first detachment consumes its one-shot direct-return arm, so viewport expansion and later unattributed tail samples cannot release it; native/direct/accessibility return still releases at an attributed tail. Catch-up retains prior and newly arriving unread state through staged/final/settling phases, restores it on interruption, and clears it only after physical tail settlement.
- **Complete:** hosted aggregate evidence drives the actual coordinator/executor, bounds retained row frames, admits at most one automatic command per displayed frame, and records zero detached writes without exposing content or identifiers in the added counters.
- **Complete:** bounded discrete entrance ownership installs atomically with the exact projection and resolves from current row geometry. Geometry carries an optional exact installation tag only for pending rows; desired source advancement cannot suppress the displayed row, while an installed replacement must match exactly and re-emits evidence only where still pending. Visible/pinned rows reveal once with non-layout opacity/scale, realized offscreen or user-displaced rows never replay, continuous streaming remains nonanimated, and only installed rendered identity may retain one admitted smooth follow through a same-row tool/group completion.
- **Complete:** initial presentation settlement is layout-evidence-driven rather than timing-driven. The exact installed timeline-tail row and current layout epoch must agree with valid geometry before the final opening command can publish or settle; transient short geometry, auxiliary runtime rows, stale callbacks, and user interaction cannot consume or revive that ownership.
- **Complete for the common latest-tail path:** Gateway snapshots/pages are capped at 512 items as well as their byte budgets; exact page bounds reject truncation/gaps, only explicitly detached browsing retains earlier pages, and physical return to latest drops that disposable prefix while preserving the authoritative tail and existing UI.
- **Remaining checkpoint:** physical-device evidence for the final one-point/two-point excursion gate and the still-observed native SwiftUI geometry diagnostic.

Exit gate:

- Pinned readers remain pinned without shimmer, including keyboard focus and composer-height transitions.
- Detached readers receive no app position writes except explicit catch-up; keyboard focus preserves their semantic reading position.
- The down-arrow is derived only from detached state and disappears on an admitted manual return to the practical tail.
- History anchor settles within 1 point with no visible intermediate excursion above 2 points in the controlled harness.
- Repeat tap, page-boundary tool group, concurrent streaming, keyboard, composer resize, and user-gesture races pass.

### Phase 6 — Progressive content and bounded memory

Checkpoint status and deliverables:

- **6.0 source characterization and provisional budget decision complete; physical acceptance pending:** Markdown fixture updates are true prefix-cumulative at 30/60 Hz and deterministically cross Unicode, unmatched/completed inline syntax, open/closed fences, table promotion, lists, quotes, headings, and rules. Valid oriented JPEG/PNG fixtures are generated from deterministic pixels at test time; no opaque binary is stored.
- **6.1 source implementation complete; physical acceptance pending:** one pure `Sendable` Markdown document is the sole cold parser result and constructs inline attributed strings once per parse with existing fallback semantics. `TronMarkdownView` renders that supplied document and table cells remain raw `Text`. Block/list identity is exact content plus UTF-8 source range: an exact unchanged block preserves subtree-local state, while changed content or type resets identity so `CodeBlock` copy confirmation and other stale interaction state cannot transfer.
- **6.2 bounded preparation cache complete; physical calibration pending:** exact-source Markdown documents and attributed thinking segments share one disposable 4 MiB accounted source/presentation-byte LRU, with ceilings of 512 Markdown revisions, 4,096 thinking segments, and 320,000 bytes for one source. At most two preparations execute concurrently. Each projection warms at most 32 new Markdown and 128 new thinking values from the bounded render-critical 512-entry tail, newest-first by identity; misses and older explicitly paged history preserve the exact cold-render fallback. Exact row slices avoid comparing or retaining the full cache per row. Session/runtime/reset replacement and memory pressure clear prepared values, and stale preparation cannot republish after that clear.
- **6.2 pending:** retain an immutable parsed prefix and parse only an open suffix only after differential tests prove equality with a fresh full parse. Open or closed fences, table promotion, lists, quotes, incomplete inline syntax, and every uncertain state must fall back to the sole full parser because appended source can reclassify earlier blocks.
- **6.3 bounded media owner complete; physical calibration pending:** transcript images are keyed by profile, lifecycle generation, connection, and blob ID. Identity-single-flight work shares one fetch/decode slot and admits at most 32 distinct thumbnail flights; excess visible work retains the established retry affordance instead of creating more tasks. The HTTP delegate rejects declared or streamed bodies above 25 MiB before further accumulation, and off-main decoding produces an orientation-correct thumbnail no larger than 192 pixels. A deterministic LRU enforces 4 MiB decoded and 64-item ceilings. Exact invalidation generations prevent late fetch/decode publication after reconnect, profile retirement, or app-lifetime memory pressure; those boundaries cancel flights and clear decoded thumbnails. The row keeps its established loading/retry/64-point presentation. Opening a preview immediately uses the thumbnail while one prioritized, uncached full-image flight replaces it in place; exact sheet leases ensure one dismissal cannot cancel another owner, replacement or the final lease cancels the flight, and no full image enters the thumbnail cache.
- **Stable path ownership complete:** structured JSON sub-sheets retain semantic child paths and resolve them against the newest live root. Lazily realizing pathological large detail collections remains.
- Before reveal, atomically install the complete lightweight identity/order descriptor spine and render-critical tail plus overscan. Progressively prepare only non-observed heavyweight Markdown/JSON/image caches afterward; never insert canonical rows, change projection revision, swap height-changing placeholders near the viewport, or write scroll position merely because offscreen preparation completed.
- Keep explicit earlier-history loading request-only and visually unchanged.
- **Complete:** parse tool timestamps with shared cached `Sendable` ISO-8601 strategies supporting fractional and whole-second Gateway values.

The Phase 6 exit gate remains open pending physical pixel, text-selection,
VoiceOver, Dynamic Type, Reduce Motion, frame, and peak-memory evidence.

Exit gate:

- Large single messages, large tool results, and image-rich pages do not defeat memory or frame budgets.
- Full-resolution images are not retained by transcript chips.
- Text selection, VoiceOver order, Dynamic Type, Reduce Motion, tool details, and current pixels remain equivalent.

### Phase 7 — Harden non-chat feature lifecycles

Independent owner milestones:

- **7A workspace/onboarding — complete:** path-keyed trust and setup state reject stale responses.
- **7B provider auth — complete:** authentication remains operation-keyed from begin through cancellation/completion.
- **7C camera/QR — complete:** generation-scoped lifecycle phases and injected adapters own serialized AVFoundation work.
- **7D terminal — complete:** exact presentation intents own replay reset identity, attach cleanup, and resize work. The sheet presentation controller owns one phase-aware start/show/open lifecycle flight plus one bounded latest pending navigation: superseded reads cancel, while possibly-sent attach/open work finishes so the terminal owner can compensate stale success before admitting only the newest route. A revoked open may resolve a completed receipt for cleanup but cannot replay a confirmed-missing command into a new PTY. Input and explicit terminate mutations retain independent receipt-aware command semantics, and action failures remain visible without removing the installed renderer.
- **7E administrative surfaces:** explicit idle/loading/value/failure state, visible errors for user actions, and best-effort swallowing only for documented teardown.
- **7F file/UI ownership — terminal, settings-shell, onboarding-helper, and first chat splits complete; remaining UI splits pending:** terminal sheet composition, presentation lifecycle/error state, and the native SwiftTerm/keyboard renderer have separate source owners. The settings shell delegates unchanged appearance, connection/import, provider, agent-default, package, trust, custom-model, and diagnostics presentations to cohesive files. Onboarding step/state orchestration is separated from its reusable UIKit/SwiftUI chrome. Chat attachment controls/chips, entrance/render rows, and extension widgets are likewise separated from route/composer/transcript composition with exact source reconstruction. Resolved package resources now render only after opening the established progressive detail sheet, while the package overview computes a constant-depth count summary. Continue splitting oversized onboarding/chat owners and move any other large resolved detail payloads behind existing on-demand presentations while preserving the same UX.

Exit gate:

- Rapid scope/path/sheet/session changes cannot install stale state.
- Dismissal during permission, camera setup, terminal attach, auth, import, or reload leaves no active resource or wrong-screen completion.

### Phase 8 — Harden cache, profiles, shares, uploads, exports, and dynamic data

Independent owner milestones:

- **8A cache:** byte-bounded, generation-ordered/coalesced, duplicate-safe, profile-deletable, backup-excluded, protected-at-creation, corrupt/old self-cleaning `SnapshotCache`.
- **8B profiles/enrollment:** transactional metadata/Keychain replacement, validated persisted endpoints, no force-unwrapped URL construction, and attempt-owned pairing commit.
- **8C share inbox:** bounded UUID entries with capacity/expiry/eviction policy, protected backup-excluded atomic storage, corruption cleanup, and an explicit destination lease `(profile/auth epoch, session ID, presentation generation)`. Bind the lease at claim time; if none exists, retain unclaimed content. Clear only after acknowledged acceptance; uncertain outcomes remain claimed for receipt reconciliation and are never submitted again automatically. Share UX requires the approval below.
- **8D uploads:** attachment count/size preflight, streamed/file-backed transport, bounded draft thumbnails, and deterministic remote staged-upload cleanup/expiry through a narrowly owned Gateway contract where required.
- **8E blobs/exports:** owned ephemeral no-cache HTTP sessions, streamed downloads, and temporary-artifact cleanup on dismissal/completion/launch pruning.
- **8F dynamic data/pagination:** bounded JSON depth/nodes/string sizes, exact required integers, finite/range-safe conversion, page/item ceilings, and duplicate-ID validation.
- **8G packaging/privacy:** extension pure-logic tests plus archive assertions that app and share extension contain required privacy manifests.

Exit gate:

- Profile/session switch, removal, failure, relaunch, and memory-pressure tests prove deterministic cleanup.
- No secret moves out of Keychain/owned stores and no personal data enters fixtures or logs.

### Phase 9 — Final cleanup, review, and release checkpoint

Deliverables:

- Remove obsolete compatibility code only when the supported protocol/version contract proves it retired.
- Delete placeholders, duplicated helpers, stale source-string guards, and dead paths discovered during extraction.
- Rerun final strict-concurrency diagnostics and targeted sanitizer/leak checks after the per-milestone checks.
- Verify all same-change owning documentation is coherent; Phase 9 does not defer documentation that belonged to earlier milestones.
- Run independent fresh-context reviews for correctness, performance, simplicity, privacy/security, accessibility, tests, and docs.
- Apply accepted findings through one fix writer and repeat focused review when changes are material.

Final validation ladder:

1. `xcodegen generate` and generated-project/resource verification.
2. Focused owner build/tests after each milestone.
3. Complete `TronMobileTests` only after focused owners pass.
4. `scripts/ios-ci-test.sh` fresh-clone checkpoint.
5. Focused smoke/accessibility UI tests.
6. Controlled real-Gateway reconnect/tool/attachment/share journeys with deterministic fixture barriers.
7. Gateway owner tests for any companion contract changes.
8. Pinned physical-device release-like Time Profiler, SwiftUI, Core Animation Hitches, Allocations, and memory runs.
9. Physical-device visual/system-chrome parity in light/dark, Reduce Motion, VoiceOver, and accessibility sizes.
10. `scripts/personal-info-guard.sh`.

## Provisional performance budgets

Calibrate against Phase 0, then ratchet rather than weakening them to fit regressions.

| Boundary | Target |
|---|---|
| MainActor publication + defined SwiftUI diff/command boundary | provisional p95 ≤ 2 ms; p99 ≤ 4 ms |
| Total attributable main work per streaming event | provisional p95 ≤ 4 ms; p99 ≤ 8 ms |
| Follow-tail commands | ≤1 per display frame; zero inside bottom tolerance |
| Authoritative handshake completion to first ready tail frame | p95 ≤ 150 ms |
| Streaming presentation latency | p95 ≤ 50 ms at 30 updates/second |
| History anchor drift after settle | ≤1 point |
| Visible intermediate prepend displacement | ≤2 points |
| App-caused main-thread hangs | zero ≥100 ms in open, stream, prepend, and catch-up scenarios |
| Large-session scroll | calibrated Core Animation hitch ratio/duration must improve from baseline and meet an approved pinned-device threshold |
| Display cadence | report 60/120 Hz presented-frame cadence and investigate every app-attributable long hitch; do not gate on uncalibrated deadline percentages |
| Cache, thumbnails, uploads, notices, terminal chunks | explicit byte/count limits with boundary tests |

CI algorithmic gates should initially use calibrated relative-regression tolerances on the pinned runner. Phase 0 must define every signpost boundary and approve concrete cache/image/upload/notice/terminal byte/count limits before the corresponding owner milestone. Physical-device displayed-frame, hitch, and memory evidence remains the authority for chat smoothness.

## Decisions requiring approval before implementation

1. **Attachment retention beyond the current presentation:** Phase 3C explicitly discards staged attachment IDs on navigation/profile retirement while retaining only bounded profile/session text drafts. Preserving staged attachments, remote staged-upload cleanup, and any changed visible retention workflow remain a Phase 8D product/contract decision; silently transferring IDs is forbidden.
2. **Cleartext transport:** TLS/WSS and certificate identity would be a cross-product security/protocol rollout, not a behavior-neutral iOS refactor. Track it separately unless approved for this pass. At minimum, retain and document the trusted local/Tailscale threat boundary and narrow ATS/host policy where compatible.
3. **Share inbox and destination UX:** retaining failed content, surfacing retry, selecting a destination, capacity/expiry/eviction messaging, or staging into the composer all change today's silent clear-and-send behavior. Product approval must choose the visible workflow. Engineering will never infer a destination from catalog/default selection; automatic delivery is valid only for an explicitly bound mounted presentation lease.
4. **Pathological detail paging:** laziness and stable identity are behavior-neutral; adding visible pagination to huge JSON/resource lists requires UX approval.

## Risks and sequencing rules

- Do not combine transport epoch work, session projection extraction, and chat rendering changes in one milestone.
- Do not change the open/sync barrier, fresh-versus-reconnect merge, command receipts, or tool ordering without explicit characterization tests first.
- Do not introduce nested laziness or progressive insertion until anchor and tail-follow integration tests exist; late height changes can create the very jitter this pass must remove.
- Do not turn presentation caches into persisted mirrors.
- Keep one writer in the active checkout. Parallelize read-only audit, design review, and validation only.
- Code, focused tests, and the nearest owning documentation ship in every milestone; Phase 9 is only final reconciliation.
- Any Gateway companion change ships with Gateway tests and contract documentation in the same milestone.
- Full native/UI/device suites are checkpoints, not the edit loop.
