# Tron iOS hardening plan

Status: implementation in progress — Phase 0 and the separate provisional UI removal milestone are complete; milestones 1–9 are pending

Audit baseline: `cee85b64a`

Implementation baseline for 0B.1: `fb009f311`
Provisional UI removal baseline: `03aa3b9a6`
Implementation baseline for 0B.2: `4bac0090d`
Implementation baseline for 0B.3a: `028e39a5e`
Implementation baseline for 0B.3b: `67dd6825b`
Implementation baseline for 0B.4: `259952614`
Scope: all handwritten iOS app, share-extension, test, project, and owning documentation code under `packages/ios-app`, narrowly required Gateway contract work, and iOS release policy where repository rules require manual delivery.

Milestone 0A began from clean tracked HEAD `cee85b64a`. Milestone 0B.1 began from clean tracked HEAD `fb009f311`. The user-directed provisional UI removal began as a separate serial milestone from clean tracked HEAD `03aa3b9a6`. Milestone 0B.2 began from clean tracked HEAD `4bac0090d`, milestone 0B.3a from `028e39a5e`, milestone 0B.3b from `67dd6825b`, and milestone 0B.4 from `259952614`; untracked `.pi` runtime artifacts are outside these implementation baselines. No audit artifact or historical line number overrides source at these baselines.

## Goal

Make the existing Tron iPhone experience deterministic, smooth, bounded, and maintainable without changing product behavior or visual design. Chat is the highest-priority path, especially authoritative opening, streaming, large-session rendering, scrolling, history prepend, attachments, and reconnect.

This is a source-of-truth and ownership refactor, not a new local runtime. Canonical sessions, mutations, receipts, resources, credentials, and runtime state remain Gateway-owned. Every iOS cache or presentation model remains bounded and disposable.

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

## Audit summary

Eight independent read-only audits covered state architecture, chat scrolling/performance, transcript content, Gateway events, data/cache/privacy, non-chat UI, tests/determinism, and cross-cutting code quality. Their findings were reconciled against audit and implementation baseline `cee85b64a`, which includes the committed removal of unfinished app-owned iOS voice input; stale speech findings are excluded.

### Milestone status

**0A — Repository policy and canonical documentation: complete.** The automatic iOS production/TestFlight workflow was deleted; README, contributor, pull-request, and iOS development guidance now require manual maintainer delivery; the obsolete gateway-integration completion plan was deleted after its canonical architecture/event/onboarding facts were confirmed in owning docs and its signed-release checks were condensed into development guidance; and the architecture source map no longer claims app-owned native speech. System-keyboard dictation remains documented. This milestone changes no product behavior or UI.

**0B.1 — Deterministic Gateway boundary and strict baseline: complete.** `GatewayClient` now owns byte-level injectable WebSocket, monotonic-clock, and UUID seams; Gateway-related `AppModel` waits and command IDs use injected production-identical defaults. Focused transport tests characterize hello/request bytes, response/event admission, virtual timeout, exact socket close, and overflow signaling. Swift complete strict concurrency is explicit. These seams contain no session runtime, event journal, receipt policy, epoch fix, or UI change.

**Provisional UI removal — complete as a separate user-directed serial milestone.** The composer waveform, custom subagent session-management sheet, and `pi-subagents` async/fleet editor widgets were removed from chat presentation. Other extension widgets remain supported. Active visible working and retry feedback uses the established compact runtime row without changing composer or scroll ownership. Session kind/classification and dashboard filtering remain canonical; the dashboard retains user sessions and ordinary forks while hiding subagent backing sessions. This milestone does not advance or implement any pending numbered hardening milestone.

**0B.2 — Pairing transport and pre-commit attempt admission: complete.** `GatewayPairer` owns a narrow injectable HTTP-data transport and deterministic `/v1/pair` request/status/error decoding. `AppModel` owns one exact cancellable pairing task; supersession, forget, and switch invalidate it, with admission checks after HTTP, before profile/Keychain save, before connect, and through connect suspension boundaries. Barrier-controlled tests prove stale HTTP success cannot commit metadata/token or initiate connect. This does not claim Gateway connection-epoch safety or transactional profile replacement.

**0B.3a — Deterministic generated scenarios: complete.** A test-only seeded builder produces byte-bounded opening tails, on-demand 10,000-entry paging ranges, long history pages, 100–256-tool bursts, 30/60 Hz cumulative Markdown updates, and synthetic high-resolution attachment data. Focused tests fix exact counts, bounds, overlap/gap behavior, rates, IDs, and privacy-safe content. It creates no production cache, transcript mirror, runtime, or session owner.

**0B.3b — Hosted presented-frame scroll harness: complete.** Test builds can admit a synthetic snapshot through the existing authoritative read gate and bypass only network opening. The harness mounts the real `ChatView`, lazy transcript, composer inset, and native scroll view; semantic row frames, visibility, and geometry are coalesced to one latest sample per `CADisplayLink` frame. Focused tests prove native-scroll fidelity, latest-tail visibility, authority gating, watchdog-bounded waits, and at-most-one recorded sample per presented frame. No test hook ships in Beta or production.

**0B.4 — Privacy-safe instrumentation and performance evidence: complete.** The typed signpost vocabulary is installed. Gateway connection, disposable cache load/save, visible session open, authoritative sync/resync attempts, uncertain-command receipt resolution, and terminal attach/replay now expose only closed result codes and aggregate item/byte counts. Shared interval handling removed duplicate terminal replay installation and centralizes success/failure/cancellation closure. Focused spies characterize these boundaries without admitting profile IDs, session IDs, paths, command IDs, model names, prompts, transcript content, terminal output, or filenames. Deterministic chat projection records only projected row count, and first-ready timing ends on the next actual `CADisplayLink` presentation rather than model readiness. Generation-owned scroll and prepend intervals discard replaced commands, reject stale prepend completion, and cancel exactly once at teardown; stale paging defer blocks cannot clear a newer paging owner. Prepend success is recorded only after the next presented frame confirms the requested offset within one point. The reproducible five-sample simulator and pinned-device timing, hitch, allocation, and memory evidence is recorded in `performance-baseline.md`; high-variance allocator deltas and internally inconsistent XCTest frame-rate estimates are reports, not gates.

**0B.5 — System-service seams: complete.** Camera authorization and capture-session ownership now sit behind narrow injectable providers while `CameraModel` retains the existing UI-facing state machine; deterministic tests cover grant/deny/setup failure, session commands, torch ownership, flip, and no-output capture without touching hardware. The pairing QR controller shares authorization, delegates serial session start/stop, cancels pending permission on disappearance, and admits exactly one result under hardware-free tests. The share extension reduces ordered fragments outside its controller, uses store/app-opener seams, and packages a privacy manifest alongside the app; focused bundle tests and a read-only archive verifier require both manifests. Presentation source guards now retain visual policy assertions without pinning moved projection, scroll-algorithm, or explanatory-comment spellings. Milestones 1–9 remain pending.

### Verified correctness priorities

- Successful provider/settings/package/custom-model reads increment the same revision used by `.task(id:)`, creating self-triggering reload loops.
- Global and project settings share one unkeyed projection and several screens do not load the scope selected in their UI.
- Session navigation identity and mutation identity can diverge. Most mutations read global `selectedSessionID`; the fork flow changes it behind an already-mounted immutable chat route.
- Pending attachments and asynchronous import completion are global rather than profile/session/presentation-owned.
- Gateway connection generation is not revalidated after every suspended handshake/receive boundary.
- Cancelling a request can finish locally while its untracked send task still transmits a mutation.
- Concurrent session-sync callers poll token changes instead of awaiting one shared success/failure result.
- Forget/revoke/switch does not synchronously invalidate every reconnect/foreground/load owner.
- Share handoff is cleared before prompt acceptance and errors are suppressed.
- Workspace trust, provider auth, terminal attach/reset, camera/QR setup, and several settings loads can install stale or ambiguous state.

### Verified performance risks

- `ChatTranscriptPresentation.timeline(in:)` is built synchronously in `ChatView` and performs whole-transcript scans, allocations, deep equality, and eager JSON pretty-printing.
- Geometry and visibility are broad `ChatView` state, so viewport activity can re-enter transcript projection.
- Markdown and thinking repeatedly parse complete strings; a single large message defeats outer row laziness.
- Every measured height increase while pinned may issue another bottom `ScrollPosition` write.
- History prepend combines a semantic row command with up to 60 raw-offset corrections and permits a repeat-tap ownership race.
- Transcript thumbnails fetch, decode, and retain full-resolution images for 64-point chips without shared byte-bounded deduplication.
- Expanded-history merge, snapshot decode, JSON round trips, cache save scheduling, and full-file attachment work need tighter off-main and bounded ownership.

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

### `SessionCatalogStore`

Owns paginated summaries, summary overlays, hidden migration state, locally created/unindexed receipts, and catalog cache admission.

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
send(sessionID:commandID:text:uploadIDs:behavior:)
abort(sessionID:commandID:kind:)
setModel(sessionID:commandID:model:)
fork(sessionID:commandID:entryID:position:) -> SessionNavigationResult
answerInteraction(sessionID:commandID:interactionID:value:)
```

No mutation reads a global selected session. Fork returns a navigation result; the route owner changes destinations explicitly.

### `ScopedConfigurationStore`

Uses a typed key such as `.global`, `.project(cwd:)`, or `.session(id:)` for settings, providers, models, packages, trust, and related drafts.

Invariants:

- Request key equals installation key.
- Late results cannot overwrite another key.
- Gateway invalidations and successful mutations advance invalidation generations; reads do not.
- Each visible screen owns its draft and load/error state for one explicit key.

### `ComposerDraftStore`

Owns text/editor requests, import tasks, pending upload IDs, thumbnails, limits, and errors per profile/session/presentation according to an explicit draft-retention policy.

Invariants:

- Upload completion verifies its original owner before installation.
- One session's attachment ID can never be submitted to another.
- Navigation never transfers staging implicitly.

### `ChatPresentationStore`

A bounded, disposable mounted projection derived from versioned immutable snapshots. It is not a transcript mirror or event journal: it never subscribes to, admits, replays, or independently merges Gateway events.

Owns the complete ordered lightweight descriptor spine, stable presentation identities, incremental projection, parsed-content caches, render-critical tail preparation, and projection revisions. Every off-main input/result is `Sendable` and tagged by session ID, presentation generation, runtime generation, authoritative revision, and monotonically increasing projection request revision; MainActor installation rejects any mismatch. Geometry is not a projection input.

### `TerminalCoordinator`

Owns terminal/session identity, attach lifecycle, replay epoch, bounded chunks, resize debounce, and teardown. A reset replay replaces native terminal content even when sequence numbers do not increase.

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
- Reject stale and duplicate same-cursor snapshots outside explicit authoritative-install paths.
- Restrict receipt uncertainty to true transport-loss outcomes; do not treat definitive retryable application errors as lost responses.
- Add explicit AppModel/coordinator teardown.
- Decode each inbound frame once and move large DTO decode/projection preparation off MainActor while preserving unknown event-topic compatibility.

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

- **3A lifecycle/catalog:** compose lifecycle and catalog owners behind the existing façade.
- **3B session presentation/mutations:** move the sole live snapshot, intent-keyed sync, explicit mutations, and session-keyed context/resources/tree/commands.
- **3C scoped configuration/drafts:** move typed configuration targets and composer/import ownership.
- **3D terminal/event reducers:** move terminal ownership and typed reducers while keeping event admission and canonical cursor rules centralized.
- **3E boundary cleanup:** remove direct Gateway calls from views (`git.inspect`, blob, logs, and similar methods), split DTO/UI files at existing type boundaries without changing Codable/presentation contracts, and deduplicate tool-state ordering.

Each submilestone leaves a compiling façade and moves its focused tests/docs with the owner; do not land all extractions in one diff.

Exit gate:

- No owner depends on mutable global selection to infer a request target.
- `AppModel` is composition and cross-domain routing, not a 2,000-line mutable domain store.
- Extraction tests prove no extra canonical source was created.

### Phase 4 — Make chat projection incremental, lightweight, and isolated

Deliverables:

- First land frame-coalesced scroll-command ownership, or keep exactly one atomic row-list commit per admitted authoritative update until Phase 5's reducer is active; asynchronous publication must not amplify the current height-driven command loop.
- Move timeline projection out of `ChatView.body` into `ChatPresentationStore` and prepare it off-main from immutable tagged inputs.
- Use latest-request-wins cancellation/coalescing and reject stale/out-of-order results by the full session/presentation/runtime/authoritative/projection tag.
- Recompute only changed canonical entries, the streaming tail, affected tool groups, or a newly prepended page.
- Atomically publish the complete ordered lightweight descriptor spine with shallow version equality before reveal; background cache fills do not publish a projection revision unless visible row output changes.
- Separate compact tool summaries from detail payloads; resolve/format request, response, and output only when a detail sheet opens through the exact session/presentation/runtime/tool identity, never mutable global selection.
- Defer `JSONValue.prettyPrinted` and cache it only for the lifetime of visible detail.
- Remove unused fields from unread-response observation.
- Preserve visible ordering and grouping with golden tests against the current timeline.
- Stabilize presentation identity across streaming-to-canonical settlement and overlapping tool-group expansion.
- Animate every tool-chip insertion and visible state/content change with the established thinking-trace motion language, while honoring Reduce Motion and preserving stable chip identity.
- Make compact tool chips hug their intrinsic content: remove flexible leading space before timestamps so each chip is only as wide as its label, status, and timestamp require.

Exit gate:

- Typing, geometry, toolbar width, sheet state, attachment-menu state, and unchanged snapshots cause zero timeline projections.
- A tool-progress event updates only the owning tool/run descriptor and dependent tail state.
- Tool chips animate appearance and changes consistently with thinking traces, and timestamp layout introduces no flexible unused leading gap.
- Cancelled/out-of-order projection, reconnect replacement, and prepend-overlap completions cannot install.
- MainActor publication plus the defined SwiftUI diff/command boundary stays within the calibrated budget.

### Phase 5 — Make scrolling and prepend deterministic

Deliverables:

- Move raw geometry/visibility out of broad `ChatView` observed state into a scroll event reducer.
- Emit one optional scroll command from one owner; coalesce follow-tail to at most one command per display frame and skip writes already inside the practical bottom boundary.
- Preserve direct user interaction as absolute authority.
- Replace 60-frame prepend polling with a generation/token-scoped anchor transaction. Capture a semantic anchor's frame relative to the viewport in the real-scroll harness, and maintain canonical-item-to-rendered-anchor mapping even when page-boundary tool grouping changes the outer row.
- Restore in one disabled-animation transaction from before/after semantic anchor or inserted-prefix-boundary measurements. Permit at most one generation-scoped late correction, measuring only the inserted prefix and never unrelated tail/composer growth.
- Keep the load token active until anchor settlement; an old cancellation/defer cannot end a newer prepend.
- Keep detached readers detached during resize, stream, image settlement, and prepend.

Exit gate:

- Pinned readers remain pinned without shimmer.
- Detached readers receive no app position writes except explicit catch-up.
- History anchor settles within 1 point with no visible intermediate excursion above 2 points in the controlled harness.
- Repeat tap, page-boundary tool group, concurrent streaming, keyboard, composer resize, and user-gesture races pass.

### Phase 6 — Progressive content and bounded memory

Deliverables:

- Parse and cache Markdown blocks/inline attributed strings by stable content identity and exact text revision.
- For streaming Markdown, retain an immutable parsed prefix and reparse only the open suffix only when differential tests prove equality with a fresh full parse; fences, tables, lists, quotes, or any uncertain state fall back to full parsing.
- Cache attributed thinking segments so opacity animation does not reparse content.
- Preserve block state with content/range-derived IDs rather than ordinal IDs.
- Add a byte-bounded attachment thumbnail loader keyed by profile/auth epoch plus blob ID. It deduplicates requests, downsamples off-main, respects cancellation/memory pressure, and preserves characterized retry/loading/preview behavior while limiting full-resolution lifetime to the preview flow.
- Make structured JSON rows stable by child path/key and lazily realize large detail collections.
- Before reveal, atomically install the complete lightweight identity/order descriptor spine and render-critical tail plus overscan. Progressively prepare only non-observed heavyweight Markdown/JSON/image caches afterward; never insert canonical rows, change projection revision, swap height-changing placeholders near the viewport, or write scroll position merely because offscreen preparation completed.
- Keep explicit earlier-history loading request-only and visually unchanged.
- Parse tool timestamps once and share formatter strategy.

Exit gate:

- Large single messages, large tool results, and image-rich pages do not defeat memory or frame budgets.
- Full-resolution images are not retained by transcript chips.
- Text selection, VoiceOver order, Dynamic Type, Reduce Motion, tool details, and current pixels remain equivalent.

### Phase 7 — Harden non-chat feature lifecycles

Independent owner milestones:

- **7A workspace/onboarding:** path-keyed trust and setup state with stale-response rejection.
- **7B provider auth:** operation-keyed authentication from begin through cancellation/completion.
- **7C camera/QR:** generation-scoped lifecycle phases and serialized AVFoundation ownership through injected adapters.
- **7D terminal:** one cancellable lifecycle task, replay reset identity, resize ownership, and late-attach cleanup.
- **7E administrative surfaces:** explicit idle/loading/value/failure state, visible errors for user actions, and best-effort swallowing only for documented teardown.
- **7F file/UI ownership:** split oversized onboarding/settings/terminal files and move large resolved resources/packages behind existing on-demand detail sheets while preserving the same UX.

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

1. **Draft retention:** discard attachment drafts on navigation or preserve them per session. Either is safe if explicit; silently transferring them is not.
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
