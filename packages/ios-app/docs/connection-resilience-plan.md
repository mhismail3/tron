# Real-world connection and resource resilience plan

**Status: the focused iOS reconnect/search corrections are implemented; deployment and physical qualification are not complete.** Policy reads are demand/connection scoped, recovery attempts settle by identity across focused and secondary owners, fresh presentation opens do not adopt reconnect results, and Retry preserves existing lifecycle owners. Catalog producer invalidation/cost and the device-native opening-settlement trigger remain open; this change does not address them. Gateway preparation deadlines remain deferred. Automated evidence is not a blanket reliability guarantee.

Build on checkpoint `cba48f894` without weakening its resource bounds or accepted-command safety. The goal is reliable operation under mobile roaming, suspension, slow peers, busy sessions, partial failures, and sustained use—not merely quieter error labels. Reliability must be demonstrated within a documented workload envelope; neither this plan nor green unit tests can guarantee unlimited scale or zero bugs.

This plan covers the iOS/Gateway connection and recovery paths, their presentation and command consumers, and resource boundaries that can turn transient loss into an outage. It is not a replacement for the [chat ownership corrective plan](chat-ownership-corrective-plan.md), a new runtime architecture, or a general refactor of every subsystem. Keep [architecture](architecture.md), [events](events.md), [development](development.md), and the [Gateway diagnosis guide](../../gateway/docs/connection-resilience.md) as the implemented-contract authorities. Update those owners as each phase lands; do not copy this proposed behavior into them prematurely.

## 1. Investigation findings and evidence limits

The structural projection checkpoint is preserved. The implementation adds bounded recovery/retirement, finite read admission, truthful failure presentation, and isolated qualification without changing a running Gateway or canonical user sessions. Automated wire, state, rendered-harness and synthetic capacity checks are separate from cellular/Tailscale, physical-device and energy evidence; see the completion record below.

| Finding | Inspected owner / source fact | Disposition |
| --- | --- | --- |
| The earlier hello-timeout window did not establish Gateway overload | Phone hello/ping timeouts coincided with responsive local Gateway requests and empty outbound queues; the originally reported overflow was outside that supplied window | Keep that window's network-path interpretation separate from the later session-specific failure |
| A session-specific open failure was a structural payload-contract defect | A sub-1-MiB browser-result transcript crossed the native 32,768-node budget before typed decoding. Hello/open succeeded, then iOS closed before sync. The original capture failed and the fitted response passed actual native open admission with all 60 row IDs/text/displays/cursor preserved | FIXED in source: aggregate transcript/snapshot node fitting, common sender guard and correlated fallback; synthetic and real-capture validation, no canonical edits |
| Projection rejection can occur after mutation execution | `response_too_large` may represent an unencodable successful command or receipt result, not a definitive execution rejection | FIXED in source: confirmed mutation/status rejection preserves `outcome_unknown` and command identity without replay |
| Established-socket recovery is already immediate | `AppModel.handleDeliveredEvent` calls `requestReconnect(immediate: true)` | KEEP; do not add another fast retry loop |
| Path information is advisory | The existing path observer delivers hints to focused and admitted secondary owners | IMPLEMENTED: park/one fallback/eligible resume; hints cannot replace a handshake, invent connectivity or clear a terminal stop |
| Half-open detection can wait for the next probe | `GatewayClient.startLivenessWait`: 10-second interval, 8-second pong deadline; initial/reconnect hello deadlines are 15/5 seconds | Characterize detection separately from replacement speed; no blind heartbeat reduction |
| Recovery allowance spans roles | Focused and secondary executors share profile-keyed failure and active-time accounting while keeping exact socket owners and per-profile retirement barriers | IMPLEMENTED: role changes cannot mint attempts; exact pre-hello attempt IDs settle intentional retirement only; free maintenance hello cannot refund ordinary faults |
| Catalog failure admission must be finite | Both owners fence automatic invalidation and read entrypoints after three application failures | IMPLEMENTED: retained rows are explicitly stale; profile/connection-scoped Retry rearms the catalog without replacing a healthy socket. Already-cancelled demand cannot acquire a traversal or reopen the exhausted retry budget |
| Global control intake must not wait on projections | Session recovery synchronously claims the existing bounded quarantine and delegates only the read wait; auth completion commits ownership before one bounded optional-refresh worker | IMPLEMENTED: no additional event queue or task per auth event; current-generation cleanup cannot erase a successor |
| Persistent failure needs truthful action | The first transport loss owns a two-second notice deadline; mounted authority, transport and display remain distinct | IMPLEMENTED: scoped Retry/Logs, separate catalog Retry, retained chat/draft/geometry, no false Send grant |
| Planned maintenance is separate authority | Focused and secondary owners retain a profile-bound 90-second intent/watchdog | IMPLEMENTED: no ordinary debit/refund; deadline is terminal until explicit Retry; predecessor disconnects cannot change roaming history |
| Optional refresh must not gate useful restoration | Mounted authority and accepted receipts retain their owners; the existing optional connection-refresh task stages catalog before provider/settings/device reads and retires on background | IMPLEMENTED: replacement readiness no longer awaits the first or continuation catalog page; later optional reads require renewed live-connection admission. Healthy foreground shares the catalog owner without cancelling unfinished connection refresh. Focused regressions protect authority/draft retention, atomic list publication, retirement during a pending catalog, and foregrounding during catalog or later optional reads. Per-read epoch retirement after the later reads have started remains a separate qualification gap |
| Hidden composer derivation must not compete with the visible surface | The canonical command store remains live; only the derived picker index follows presentation/scene activity | IMPLEMENTED: guard before detached preparation and after completion, retain the last installed value, and prepare the latest source on uncover. Hosted managed-sheet/scene, unchanged-source resume, and late-completion regressions protect admission, publication, native editor identity/draft selection, and tail geometry. Retained indexes carry source provenance; synchronous consumers reject stale rows/actions during reload or replacement preparation. Submission independently checks skill capability before draft/ledger mutation, including implicit staged-skill fallback. Broken consumer/capability guards fail negative controls; no latency or energy improvement is asserted |
| HTTP needs both logical and physical bounds | Transport budgets cover raw sockets, address/pipeline/identity requests and pending upgrades; resource owners reserve before metadata/open | IMPLEMENTED: cancellable credential/display queues, bounded late leases, startup/close joining and claimed-upload protection. Broken filesystem recovery remains a documented capacity limit |
| A bounded output does not bound its production cost | Branch/catalog/history paths still do input-dependent work | MEASURED: reuse one branch cut per projection; preserve full canonical tool-result ownership. Progressive warm histories reached 100k entries; no speculative index, mirror or worker was introduced |
| Global summaries intentionally reach dashboards | Revisioned summary publication reaches ready peers, including unsubscribed sessions | QUALIFIED in isolated fanout waves through 32 peers; preserved freshness/ordering. Summary publication no longer triggers optional search-policy reads; current profile/connection demand still refreshes policy |
| Diagnostics must retain initiating and latest evidence | Typed decoder/platform/HTTP/close facts and validated client/attempt incident identities use the existing bounded stores | IMPLEMENTED: reserve first causes of eight recently observed incidents under count and byte pressure. URLSession can expose a no-status sentinel instead of the peer's exact code; do not invent missing facts |
| Foreground notifications are a separate seam | Gateway presence is token-bound and removed on disconnect; `AppDelegate.willPresent` requests banner/sound | Test completion during recovery; do not extend obsolete server presence to hide a disconnect |

### Coverage

Parent inspection and three read-only investigations covered recovery/UI, event/sync/command safety, and Gateway/runtime/auxiliary capacity. Load-bearing findings above were checked against their owning code. Coverage is by operation slice, not a claim that every function in the large files was reviewed.

- **Reviewed slices:** socket epoch/admission/retirement; lifecycle/background/foreground/retry; selected/secondary catalog retry; synchronization quarantine and atomic installation; confirmed mutation receipt policy; notice/diagnostic ownership; Gateway WebSocket/HTTP lifecycle; sampled runtime projection/fanout/disposal and auxiliary leases; focused test and runner registration.
- **Sampled/not closed:** all secondary UI readiness consumers, all runtime maps/rebind paths, HTTP revocation/drain combinations, notification recovery presentation, and long-history saturation. Each has an implementation/qualification gate below.
- **Native viewer activity:** native notifications own the generation fence; SwiftUI phase directly gates admission/rendering without a redundant generation callback. `BrowserLiveMountedViewingTests.floatingFrameGeometryAdaptsWithoutRemounting` and the coalesced-activity regressions protect rapid resume after DELETE for both producers. These mounted checks do not replace installed Mac capture and physical-device validation; see [display lifecycle](display-artifacts.md#live-browser-and-native-mac-views).
- **Not certified:** physical roaming, Tailscale route migration behavior, battery/thermal cost, long-running heap/descriptor stability, all third-party SDK/provider internals, and the full Mac supervisor/release path.
- Concurrent browser work landed separately as `0f376b197` while this plan was drafted. Its stable mounted renderer and bounded first-frame wait were inspected as integration context, not reimplemented or runtime-certified here. Preserve those fixes and their new rendered-pixel/first-frame regressions. Browser resource findings describe the earlier reviewed checkpoint; recheck those boundaries against the actual implementation revision.

## 2. Non-negotiable invariants

1. **One canonical runtime per session.** JSONL, accepted work, receipts, settings and credentials remain in their existing owners. No second runtime, transcript mirror, event journal, or canonical-session truncation.
2. **Three different facts stay different:** actual transport availability; synchronized session/action authority; user-visible outage presentation. A quiet UI can never grant a socket, subscription, command, or notification-presence lease.
3. **One recovery executor per profile at a time.** Selected and secondary clients remain independently owned; a role handoff transfers/reuses failure allowance rather than manufacturing a fresh budget. No global lock serializes unrelated Macs.
4. **Exact ownership through every await.** Profile/credential authority, lifecycle generation, attempt/connection epoch, presentation target, and subscription token are checked where relevant. Old completions cannot publish values, errors, flags, or cleanup over successors.
5. **Accepted commands outlive transport.** Keep local definitely-not-sent versus possibly-sent provenance; exact command IDs; durable receipt reconciliation; no automatic replay after unknown outcome or cancellation. A terminal response already received owns completion.
6. **Presentation reads are disposable.** Cancel/retire obsolete reads and viewer/terminal observers, not accepted domain work. Keep the last complete transcript, route, draft, keyboard and scroll state during same-profile recovery.
7. **No indefinite active recovery loops.** Attempt, duration, task, queue and resource bounds apply to failure recovery. Waiting passively for network restoration is not a retry loop. Path events, repeated invalidations, navigation and short hellos cannot erase persistent failure evidence.
8. **Only genuine progress restores confidence.** Hello alone is not stable recovery. Intentional healthy background retirement is not a fault. Stable-epoch accounting must not count time spent suspended or unknowingly dead as proven healthy progress.
9. **No artificial “finished” or “sent.”** Retained activity is last-known state, not proof of current liveness. Canonical completion and confirmed mutation outcomes alone drive success/delivery UI.
10. **Local failure containment.** One bad profile, slow stream, overflowing peer, projection failure or browser viewer cannot cancel another session or reset the service.
11. **Diagnostics are bounded and content-free.** Fixed categories, numeric codes, counts, sizes, timing and validated opaque correlation IDs only. No raw URLs, close-reason payloads, credentials, provider output or user text.
12. **Deployment remains manual.** No agent-driven Gateway transition, production deployment, app install, VPN/network change, or manipulation of active sessions for testing.

## 3. Recovery contract to freeze before implementation

### Ownership model

Keep `GatewayClient` as the socket/epoch authority. Keep focused lifecycle and secondary pool as their existing connection executors. Factor their common recovery policy into the existing support layer; compose one bounded profile-keyed allowance owner (or an explicit single-owner transfer) so role changes cannot bypass a stop. Do not introduce a third component that also opens sockets.

Use typed attempt outcomes and exact executor leases. Every admitted attempt settles once as successful, failed, intentionally retired, or superseded. First-fault identity, allowance, active-time deadline and stop reason belong to that recovery episode. Profile label edits do not reset it; explicit Retry, genuine stable recovery, removal, or authorized endpoint/credential replacement have explicit semantics. Removing a profile prunes only its disposable policy state, not accepted commands or unrelated drafts.

Presentation is a bounded read-only projection of these facts. Its only independent state is the minimum needed for an episode-owned display deadline/announcement identity; it cannot schedule transport work or invent canonical readiness.

### Failure classes and actions

| Observation | Required action |
| --- | --- |
| Path/interface change but the exact socket is still viable | Keep it. Coalesce a hint; join/advance its existing liveness probe if needed. Never create a second ping or handshake |
| OS reports no usable path | Avoid launching pointless replacement attempts; preserve existing socket until actual failure. After presentation grace, say waiting for network. Park without periodic retry churn |
| Path returns / meaningful foreground activation | Resume an eligible parked episode or accelerate a delay once. Do not replace an in-flight handshake or re-arm an exhausted/nonretryable stop |
| Exact socket is dead | Retire promptly, start the existing immediate replacement path, then bounded jittered backoff |
| Repeated short successful hello followed by actual loss | Retain failure history; do not silently reset the budget |
| Short healthy intentional background/profile retirement | Preserve earlier failures, but do not turn three ordinary app visits into an outage. Resolve retirement against the exact old epoch, including races with an already-observed failure |
| Authentication, identity, protocol, or permanent configuration failure | Stop promptly with specific action; no roaming grace that hides security failure. Policy close code alone is insufficient to guess “re-pair” |
| Explicitly accepted planned restart | Use the existing maintenance intent and a bounded maintenance deadline; do not exhaust ordinary roaming allowance while a healthy replacement starts. A stale restart intent cannot extend the deadline |
| Server overload/capacity | Respect bounded backoff and server limits; no immediate reconnect storm. Retain first cause; stop visibly on exhaustion |
| Responsive socket with stale/invalid projection | Retry only the owning projection within a finite budget. Keep the socket and unrelated actions usable; expose persistent catch-up failure |
| Stale callback / cancellation / normal teardown | Exact cleanup, no error notification, no successor budget mutation |

`NWPathMonitor` is not endpoint/Tailscale reachability proof. Its callbacks may be delayed, coalesced, or absent during tunnel changes. Correctness must still hold without any path hint.

### Starting policy values—not performance promises

- Keep the established-connection immediate retry and existing 15/5-second hello deadlines while measuring.
- Start with the checkpoint's **three automatic transport attempts**, shared across role handoff, and **30-second stable-epoch** requirement. Add a finite active-recovery deadline so cancellations/replacements cannot extend an episode forever. Implemented ordinary active-repair admission allowance: **30 seconds**, excluding passive no-path/background time and usable transport. An already-admitted handshake retains its existing finite deadline; this is not a hard real-time promise. Provisional hello pauses repair work without forgiving attempt history.
- Preserve the existing **90-second planned-restart** bound as a distinct explicit intent; prove the policy works when a valid restart takes longer than three replacement handshakes.
- Proposed **two-second outage-presentation grace**, measured from the first relevant failure, not from each retry/path callback. It delays only presentation, never recovery. A provisional hello cannot clear it while the mounted session is still unusable.
- Give catalog/projection recovery an actual finite failed-attempt allowance, initially **three**, not a saturating retry counter. Coalesce invalidations; repeated failure-triggered or high-rate invalidations cannot re-arm a failure storm. Successful normal refreshes are not subject to a lifetime cap.
- Do not shorten heartbeat deadlines, enlarge queues, or increase these allowances to make a failing test pass. Confirm final values with the scenario matrix and physical measurements.

## 4. Implementation phases

Each phase is a reviewable checkpoint: code + focused tests + owning documentation. One writer per checkout. Reopen affected reviews after changes; do not combine every phase into a large unreviewable patch.

### P0 — Characterization, ownership contracts, and failure fixtures

**Owners:** existing Gateway/iOS owner tests, `ScriptedGatewaySocket`, `ManualClock`, `TestReadGate`, `SessionScenarioBuilder`, hosted chat harness, `scripts/ios-gateway-e2e-test`.

- Freeze baseline revision/build identity and scenario inputs; inventory all retry loops, resource ceilings, release paths and `.connected` consumers in scope.
- Add deterministic characterization for the newly identified catalog loop, slow planned restart, role-budget handoff, slow-sync global event blocking, and slow HTTP response/drain.
- Reuse scripted transport controls for suspended send/ping/close and late callbacks. Add only missing test-only route/fault gates; no production fault hooks.
- Map every readiness consumer to transport, mounted authority, catalog readiness, accepted-mutation state, or display state. Include automation/settings, push routing, terminal, browser, uploads, and Logs—not only Chat.
- Define resource-envelope inputs and expected overload behavior before recording performance results.

**Gate:** each claimed defect has a reachable source path and an observable reproduction, or is explicitly retained as measurement work. Tests must not rely on arbitrary yields/sleeps or a helper merely returning its own counters.

### P1 — Typed failure and first-incident diagnostics

**Owners:** `GatewaySocketTransport`, `GatewayClient`, `GatewayDiagnosticsService`, `IOSDiagnosticMailbox`, performance signposts, Gateway transport/logger.

- Preserve numeric WebSocket close code and HTTP upgrade status when supplied by the platform; keep unavailable/abnormal cases explicit. Read official URLSession delegate contracts before selecting callback plumbing.
- Record local retirement intent separately from remote failure. First-cause capture precedes cancellation/close callbacks that otherwise replace it with a generic error.
- Keep routing/retry classification typed. Never classify by localized error prose or arbitrary server close reason; unknown stays unknown.
- Add episode correlation and stage timing: observed loss, attempt start, hello, event activation, mounted sync, first usable presented frame, visible warning/quiet recovery, and stop cause. Correlate server/client IDs only through validated existing hello identity or an explicitly reviewed contract—not by equating different namespaces.
- Reserve bounded retention for first incident plus latest outcome within current store count/byte/age caps; do not add a second diagnostic database or retain all events. Preserve freshness/build/capture-range labels offline.

**Tests:** close/error races, local background versus remote close, absent close code, 401/403/1012/1013/policy close classification, privacy fuzz/oversized fields, first fault surviving hundreds of routine records, old-episode callback isolation, Logs never issuing pre-hello RPCs.

**Gate:** an export can distinguish suspected path loss, transport timeout, event overflow, overload and projection failure without claiming unsupported attribution or leaking content.

### P2 — Roaming-aware bounded recovery and role handoff

**Owners:** `GatewayRecoveryPolicy`, `ReconnectDelayPolicy`, `GatewayLifecycleCoordinator`, `DashboardGatewayConnectionPool`, app path/scene composition.

- Replace duplicated allowance semantics with the ownership contract above; reuse one jitter policy rather than deterministic secondary retry bursts. At focused/secondary handoff, synchronously revoke the old executor and await its bounded local transport retirement before activating the successor for that profile. Do not wait indefinitely for a remote close or serialize unrelated profiles. Late old retirement cannot consume/refund the transferred allowance.
- Deliver coalesced path hints under scene/profile/epoch admission. Advance/join the existing liveness owner; never independently invoke overlapping socket pings.
- Park new attempts when there is known no path; resume only an eligible episode when a path returns. Leave satisfied-but-unreachable behavior on real handshake/liveness evidence and bounded failure handling. A stale/default-path hint cannot permanently veto an explicit Retry or fresh foreground endpoint check: loopback/overlay reachability may differ, and restoration callbacks can be missed. Include at most one fallback endpoint verification during a parked episode, scheduled by the existing recovery-delay owner within the remaining attempt/active-time allowance, even if no return callback arrives. If it fails, retain a visible waiting/offline state with Retry and first-fault context; no endless fallback polling. Later automatic recovery needs a genuinely fresh eligible path/foreground trigger; unconditional recovery without any trigger is not promised. All checks remain single-flight and cannot automatically re-arm an exhausted episode.
- Preserve immediate reconnect and delay-only acceleration. Repeated foreground events, explicit Retry taps, or path hints cannot replace an active attempt or extend its deadline.
- Separate planned maintenance from ordinary transport failure; preserve immediate auth/protocol stops and exact endpoint rebinding on Retry. Classify an admitted `system.stopping` before generic disconnect accounting: expected maintenance loss and its replacement handshake failures must not consume the ordinary roaming allowance. Its own finite deadline controls failure; unrelated or stale stop events cannot establish/extend maintenance authority.
- Resolve cancellation/refund/stability from exact attempt outcomes. Pre-hello intentional retirement refunds its UUID-qualified charge once; an actual timeout remains charged. A late cancellation cannot poison or forgive a successor's failures. `AppModelReconnectTests.repeatedPreHelloRetirement` and `DashboardStateOwnerTests.secondaryPreHelloRetirementAndActiveRefresh` exercise the actual executors across more visits than the automatic allowance.

**Tests:** same policy sequence through focused and secondary executors; A→B→A handoff; healthy short visits; actual rapid drops; no-path waiting without attempts before its one permitted verification; path return during delay/handshake/stop; foreground/background during suspended close; endpoint/token replacement; Mac asleep/waking; a 20–60-second valid restart; exhausted budget remains stopped despite path/scene chatter.

**Gate:** bounded sockets/tasks/attempts per profile, no duplicate active handshake, no bypass through navigation, and no artificial outage from normal healthy app visits.

### P3 — Nonblocking synchronization intake and finite projection recovery

**Owners:** `AppModel` event/catalog paths, `SessionPresentationStore`, `SessionSynchronizationCoordinator`, secondary pool catalog owner; Gateway sync/barrier tests.

- After reproducing starvation, remove network waiting from the global event-consumer path. Acquire the existing synchronization lease/quarantine **synchronously before returning**; run one owned recovery task, not one task per event and not a second consumer.
- Continue draining unrelated control/catalog/auth/terminal events while the mounted session synchronizes. Same-session events enter the existing bounded quarantine, never the live reducer prematurely.
- Retire the task on exact connection/presentation replacement; resolve joined waiters once; preserve provisional-token cleanup on its originating connection. A fresh open waits for an incompatible reconnect, revalidates its exact pending generation, then acquires its own bounded baseline; it never adopts the predecessor's Boolean result or paged history. Superseded/cancelled opens report cancellation, not an unavailable conversation. `SessionPresentationStoreTests.freshPresentationAfterReconnect` covers predecessor success/failure, supersession, cancellation and fresh-tail installation.
- Keep response-before-suffix ordering, sync acknowledgement, contiguous cursor validation, atomic baseline+suffix installation and bounded authoritative overflow recovery unchanged.
- Bound actual failed catalog attempts in both owners. Separate successful dirty-bit convergence from persistent schema/application errors; coalesce invalidations and stop failure-driven rescheduling. A new invalidation is not permission for unlimited retries of the same failure.
- Make persistent mounted-projection failure observable even if transport is connected. Do not recycle a healthy socket or leave a permanently disabled composer without explanation.

**Tests:** hold open/sync while delivering `transport.disconnected`, auth, terminal, dashboard and same-session events; verify unrelated intake and quarantine. Overflow count and bytes independently. Race close/route/runtime/profile replacement at every await. Repeat malformed catalogs and assert exact wire-read count, no further scheduled retry, retained rows, and scoped explicit retry. Rebaseline/cursor gaps never publish partial or duplicated rows.

**Gate:** slow recovery cannot block lifecycle control delivery; all queued/quarantined/task state is bounded and retired; snapshot authority remains atomic.

### P4 — Stable presentation and actionable persistent failures

**Owners:** lifecycle/pool-derived display state, `SessionShellView`, `ChatView`/composer, Connection Settings, `InAppNoticeCenter`, relevant accessibility/notification consumers.

- Add the single episode-owned display grace only after auditing real consumers. Do not leave `connectionState` falsely connected, and do not use the unused theme badge as the sole integration point.
- Retain mounted rows, route, scroll anchor, keyboard, input selection and draft throughout brief recovery; do not remount Chat to change connection status.
- If readiness returns within grace, no new outage notice, sound, haptic or VoiceOver announcement. If not, show one stable recovering/catching-up state; update it by episode, not per attempt.
- Exhausted/permanent failure provides one accessible Retry action and useful Logs guidance on the current surface. Secondary failures remain profile-local rather than global alert storms.
- Clear only the matching episode's notice. Exact replacement transport admission clears its outage warning while mounted reconciliation still fences rendering and Send. Late success/failure and profile changes cannot clear or show a successor notice. Explicit restart/auth failures retain truthful distinct treatment. `AppModelReconnectTests.recoveryWarningTimerAndAuthorityFence` holds the replacement open response to verify this separation.
- Preserve current Send admission: no new implicit offline-send queue. Typing remains possible; already-admitted mutations retain their owner. The confirmed executor's existing bounded pre-transmission wait is not permission to bypass Chat authority.
- Keep Abort's existing exact-operation escape hatch; it must not be disabled just because mounted projection is catching up.
- Test APNs completion during a reconnect gap. Keep server presence token-bound; never extend stale visibility or blanket-suppress genuine agent alerts during UI grace. Any suppression of an already represented/acknowledged foreground event needs exact route/event evidence, must not alter durable inbox/read truth, and must preserve other-session/input-needed/background notifications. A connection-warning policy is not permission to hide an agent completion the user has not received.

**Tests:** actual presented-frame continuity for short/long gaps; exact row identities/anchor and first responder; user scrolling/typing during recovery; one visible notice and one accessibility announcement on persistent failure; no transient notices; profile-local Retry; late grace timer after success. During grace assert `AppModel.admitsLiveSessionCommands` is false and Chat's Send admission remains disabled, while typing/draft/route/scroll survive. Quiet presentation does not promise enabled Send while authority is absent. For APNs, finish an agent while the socket is lost/backgrounded and no completion event reaches iOS; verify real notification intent/inbox persistence and eligible presentation independently of connection state.

**Gate:** presentation can be quiet while transport is unavailable, but cannot imply sent/accepted/live authority or hide a persistent unusable view.

### P5 — Critical-path recovery and command-safety integration

**Owners:** lifecycle reconciliation, `SessionPresentationStore`, `ConfirmedMutationExecutor`, `SessionMutationService`, composer, provider-auth/terminal/catalog owners, Gateway receipts.

- Prioritize handshake/event activation, exact mounted-session baseline, and already-accepted command reconciliation. Preserve early transport availability for direct push/session routes.
- Avoid a startup-style burst of nonessential settings/provider/device reads after every flicker. Coalesce or defer optional work through its existing presentation owner; do not add a generic scheduler/cache layer.
- Remove broad reconciliation gating from an action only when its exact authority contract is independently satisfied. Conversely, a catalog-dependent action cannot use transport connectivity as a proxy for current catalog truth.
- Keep terminals behind exact session subscription installation; resume provider-auth with its existing operation identity. Browser/video observer failure stays local and does not restart the control WebSocket. Preserve the stable browser activity host and bounded first-frame wait from `0f376b197`; do not add a static-frame heartbeat or remount-on-frame behavior.
- Preserve receipts and all existing send provenance. No receipt-policy rewrite is required unless a new failing test demonstrates a defect.

**Tests:** slow provider/settings/catalog cannot prevent mounted readiness or exact route opening; Send before write/during write/after acceptance with lost response; statuses completed/pending/missing/unknown; corrupt/expired receipt evidence; cancellation before confirmed-missing replay; profile switch during receipt polling; terminal attach on the replacement token; Abort never targets a successor operation. Verify actual command execution/canonical row counts, not just matching IDs.

**Gate:** no duplicate command or false draft restoration; no accepted command cancelled by transport; optional refresh does not block the smallest safe action boundary.

### P6 — Gateway-wide resource admission and bounded retirement

**Owners:** `GatewayServer`, `UploadStore`, `BlobStore`, display/live-view leases, terminal service, runtime registry/work ownership, HTTP integration tests.

- Inventory global/per-identity/per-connection counts, bytes, lifetime, admission cut and release path for HTTP requests/streams, files, viewers, terminals, synchronizations and runtime starts. Include pre-authentication sockets/held headers and post-authentication streams. Account for simultaneous ceilings, not each limit in isolation.
- Reproduce slow upload/download, authentication-versus-shutdown, and HTTP drain races. Introduce a single bounded HTTP transport/lease admission boundary where shared accounting is missing; reuse route leases rather than duplicate independent counters.
- Recheck shutdown admission after asynchronous authentication/acquisition. Bound disposable stream inactivity/drain and release on finish/close/error/cancellation/revocation, including responses whose headers were already written.
- Distinguish HTTP receipt-independent reads/staging from accepted domain mutations: abandoned reads/viewers/staging may retire; accepted prompts and claimed canonical assets must not be cancelled or deleted. Do not register every disposable stream as uncancellable domain work.
- Verify HTTP, upgraded sockets and WebSocket writers reach terminal cleanup under a stalled peer. Node default request/header timeouts are not a complete response-stream drain policy; confirm behavior against the pinned Node version.
- Test terminal attachment maxima against existing terminal/session limits before adding another cap. Audit map/timer/watcher/descriptor retirement across runtime disposal, rebind, failed initialization and eviction; do not label reachable retained state a leak without lifecycle evidence.

**Tests:** healthy control peer beside saturated slow peer; stalled body and response stream; upload/blob/display/live-frame limits; exact capacity release after abort; revocation/shutdown after authentication await; bounded test-fixture close; accepted command settlement while observers retire; repeated viewer/terminal/reconnect churn returning lease/descriptor counts to baseline.

**Gate:** saturation is explicit and local, physical cleanup is bounded, canonical work survives, and no auxiliary route bypasses the shared budget.

### P7 — Measured projection/fanout/long-history hardening

**Owners:** `RuntimeSlot`, `RuntimeRegistry`, projection/catalog metadata owners, summary wiring, public pinned SDK seams.

- Measure cold open, warm snapshot, branch changes, catalog rebuild, tool-result projection and summary fanout separately. Count input entries/bytes and recipients as well as output bytes; record event-loop delay, allocation/heap/retained memory and authoritative freshness.
- Reuse existing stage timings/signposts first. Distinguish one-time work, steady-state work and saturation; freeze a workload and comparison rule before changing code.
- Remove redundant scans/serialization only when canonical equality and measured benefit are proved. The full tool-result ownership scan prevents duplicate runtime rows when canonical results are paged out—bounding it by the visible tail is not a safe optimization.
- Coalesce only semantically replaceable projection updates, with bounded pending state and a final flush. Never coalesce command outcomes, terminal bytes, authentication interactions or ordered session deltas. Preserve global dashboard discovery and monotonic summary revisions; no subscription-only routing that hides other sessions.
- Any derived index must remain bounded, disposable and tied to exact canonical branch/runtime invalidation. Do not invent a transcript mirror or silently evict a needed ownership fact.
- If the pinned SDK cannot safely bound synchronous cold-read work, record the supported-capacity limitation and investigate a public upstream fix/qualified dependency upgrade. No worker architecture, parallel canonical client, or JSONL truncation workaround.

**Qualification workloads:** ordinary small/warm sessions; long active branches and cold catalog rebuild; large provider results; 1/4/16 active sessions × 1/4/16/32 client peers, constrained by configured runtime admission; one slow peer among healthy peers; bounded browser/terminal/upload concurrency. Include near-limit and one-over-limit cases. Grow histories progressively under test-owned memory/time ceilings rather than starting with a million-entry stress test.

**Gate:** correctness equality first; meaningful tail-latency/resource improvement beyond noise; no removal of intended dashboard freshness or chat behavior. If benefit is inconclusive, retain the simpler existing implementation and document the capacity result.

### P8 — Cross-layer qualification, documentation, and manual delivery

- Run focused owners after each slice; full gateway/native checkpoints only after those pass. Re-run actual tests at the integrated final revision.
- Extend the existing isolated real-Gateway/iOS fixture with test-owned fault gates: silent traffic blackhole, hard close, delayed hello/sync, slow reader, and response loss after command acceptance. Do not run faults against a user's Gateway or session.
- Use the hosted real Chat/scroll harness for presented UI evidence. State tests or snapshot-install counters alone cannot establish no visible jump/flicker.
- After source checks, perform user-approved physical testing on an owned device and separate test Gateway: Wi-Fi/cellular handoff, loss/return of tunnel reachability, Mac sleep/wake, screen lock/background, constrained network, and long foreground use. Never alter a shared Mac's network or active production sessions for the experiment.
- Record reproducible inputs, actual build identities, sample count, median/tail timings, failures, screen/geometry evidence and cleanup. Simulator results do not certify cellular behavior or energy cost.
- Replace stale recovery/background/restart claims in architecture/events/development/Gateway docs; describe limits and exact Retry meaning. Do not retain contradictory historical completion claims.
- No automatic rollout/rollback or lifecycle action. Prepare artifacts and validation receipts only; the maintainer performs Gateway/app transitions under existing runbooks. Validate protocol/signing identity before any user-authorized device installation. Preserve app/Keychain/Tron data.

**Gate:** every acceptance scenario below passes or is explicitly unresolved; no “maximally reliable” completion claim while critical gaps are simply deferred.

## 5. Acceptance scenario matrix

| Scenario | Observable result required | Primary oracle |
| --- | --- | --- |
| 250 ms–2 s loss, same socket survives | No forced reconnect or outage announcement; no duplicate ping/command | Scripted transport + presented UI |
| Socket closes, replacement ready inside grace | One replacement, no outage notice/remount, same draft/anchor | Lifecycle + native Chat harness |
| Path absent for 30 s then returns; return callback missing in a second case | No periodic socket churn; at most one bounded fallback verification; visible waiting/Retry if still unavailable; fresh foreground/path trigger resumes only eligible work | Injected path/clock + wire count |
| Path says satisfied but Mac is unreachable | Bounded real attempts; no fabricated connected state; actionable stop | Handshake/liveness fixture |
| Repeated handoffs/short hello-drop cycles | Failure history survives; no endless quiet/retry resets | Both executors + handoff test |
| Five healthy short foreground visits | No artificial exhaustion; one epoch per visit | Existing regression, expanded with path events |
| Repeated path/Retry/foreground events during hello | One attempt; no deadline extension or stale completion | Suspended send/hello + exact epoch |
| Profile/credential switch or focused/pool handoff at any await | No old data/error/token/receipt crosses identity; old executor retires before successor activation; late retirement cannot mutate successor allowance | Gate-controlled A→B→A tests |
| Planned restart takes 20–60 s | Maintenance state/deadline survives; ordinary roaming allowance unchanged; no generic exhaustion; reconnects without prompt replay | Isolated lifecycle fixture |
| Sync suspended during `transport.disconnected` / auth / terminal / catalog traffic | Actual disconnect control reaches lifecycle without waiting for open/sync; other events continue; mounted suffix stays quarantined | AppModel integration + both sync ends |
| Sync gap/overflow/invalid response | Bounded recovery; no partial baseline, duplicate rows or leaked token | Quarantine/ack/cursor oracle |
| Persistent responsive catalog failure | Finite reads; no endless timer or invalidation re-arm; old rows retained | Actual RPC counts + UI retry |
| Replacement connection with a held first/continuation catalog page | Mounted synchronization and safe command authority complete before catalog publication; retained target/draft survive; background rejects late optional results | Actual background/replacement executor + scripted wire barriers; physical rendered-frame qualification remains required |
| Send loses response after acceptance | Exact receipt resolves or unknown is explicit; canonical execution once | Real fixture + durable receipt/JSONL |
| Cancel/profile change during receipt recovery | No automatic replay on another profile; uncertainty retained | Confirmed executor + wire capture |
| Abort during recovery | Exact existing operation only; unrelated/successor work unaffected | Mutation/service integration |
| Agent finishes during socket loss/background with no local completion delivery | No fabricated completion or suppressed unseen result; durable notification intent/inbox and eligible user notification verified independently | Presence + notification tests |
| Slow HTTP/WS peer beside healthy peer | Local capacity rejection/cleanup, healthy peer remains usable | Real two-peer transport fixture |
| Late close/pong/read/write after successor | No successor retirement, UI notice or budget mutation | Scripted late-callback tests |
| Browser/terminal/upload churn across reconnect | Bounded pixels/bytes/leases/files; no browser automation kill or terminal-byte loss/duplication | Auxiliary owners + HTTP/terminal integration |
| Long-history/fanout saturation and recovery soak | Correct canonical projections; bounded resource counts; no sustained retained-memory/descriptor slope after settling | Controlled Gateway workload + independent memory/FD evidence |
| Long foreground idle / app suspension | No needless socket churn/energy polling; clean retirement, correct return | Liveness tests + physical observation |

### Test confidence and stop rules

- Reuse `GatewayClientTransportTests`, `GatewayEventHubTests`, `AppModelReconnectTests`, `GatewayRecoveryPolicyTests`, `DashboardStateOwnerTests`, `AppModelCatalogSyncTests`, `SessionEventSynchronizerTests`, `SessionPresentationStoreTests`, `SessionMutationServiceTests`, `AppModelPerformanceSignpostTests`, terminal/provider-auth/notice/diagnostic/push suites, and hosted chat continuity tests.
- Gateway owners include `server-capacity`, `server-frame`, `server-revocation`, `sync-protocol`, `session-sync`, `command-receipts`, runtime-registry/projection, upload/blob/live-view and terminal tests. Inspect actual suite registration; the real Gateway boundary test skips outside its owning fixture and cannot count as passed integration coverage there.
- Negative controls must break real behavior: remove a generation fence; disable retry exhaustion; restore inline sync waiting; erase first-fault retention; remove a resource release; reset the UI grace on every failed attempt. Confirm the corresponding oracle fails, then restore exact test-owned edits. No production hooks.
- Use registered await barriers and injected clocks, not sleeps/repeated yields as evidence. Every test owns its tasks, files, ports, simulator lease and cleanup on success/failure/timeout.
- Source/build/guards: `npm run build` and focused `npx vitest run` in `packages/gateway`; `scripts/tron-ios-test build` and focused `run --only-testing` selectors; `scripts/personal-info-guard.sh`, `git diff --check`, and documentation-policy validation. The isolated E2E script's fixture lifecycle is separate from, and must never target, a running user Gateway.
- Freeze physical latency/energy and server resource budgets after baseline measurement, before evaluating a candidate. Hard gates are no duplicate/lost accepted command, no stale publication, exact bounds/releases, finite failed recovery, and correct visible behavior. RSS need not return byte-for-byte to startup because allocators/caches retain capacity; sustained unbounded growth and leaked leases/descriptors are failures.
- Stop and investigate if a scenario produces unknown mutation execution, false authority, canonical damage, cross-profile leakage, unbounded work, loss of genuine notifications, or native chat identity/geometry regression. Do not trade correctness for faster numbers.

## 6. Delivery order and completion record

Recommended order: **P0 → P1 → P2 → P3 → P4 → P5**, with P6's independent Gateway characterization/source work in isolated ownership if parallelized; **P7 only after measurements justify it**; P8 integrates and qualifies everything. Each checkpoint includes fresh adversarial review, finding disposition, actual validation output and updated owning docs before the next dependent change.

Maintain a run-owned evidence ledger linking requirement → source revision → scenario → test/measurement → result → remaining limitation. The final report must distinguish implemented, source-verified, synthetically tested, physically verified and not tested. Counted tests, inspected code, and live behavior are different kinds of evidence.

### Current implementation/qualification record

- **P0–P6 source:** bounded profile recovery/maintenance and single-flight handoff;
  current-command authority separate from retained chat; synchronous quarantine;
  finite automatic catalog/session recovery with scoped Retry; bounded first-fault
  diagnostics; and HTTP/resource cancellation/retirement are implemented with
  owning tests and documentation. Source review findings were repaired at their
  owners rather than hidden by wider buffers or socket recycling.
- **Gateway checkpoint:** source build, 1,173 tests in 119 files, 26 SDK-script
  tests and two fault-proxy tests passed on the pinned Node 22.22.0 toolchain.
  Four focused negative controls failed when queued cancellation, post-I/O auth
  fencing, and single branch acquisition were disabled; exact source was restored.
- **Native qualification:** the combined checkpoint passed 1,618 tests with four
  expected skips, including 1,585 Swift Testing cases in 119 suites. The separate
  real-Gateway case runs only through its fixture. An unmodified
  `ChatAttachmentStripTests` photo-animation sampling case failed intermittently
  in an earlier full run, then passed both isolation and the integrated checkpoint.
  Its fixture now waits for the committed attachment state and rendered terminal
  frames while retaining the centered intermediate-frame and zero-height or
  disappearance oracles; the focused three-case attachment checkpoint passed.
  Focused recovery, metadata, auth, catalog
  and synchronization checks also passed at their owning boundaries.
- **Real isolated boundary:** delayed actual URLSession hello/open/sync,
  blackholed traffic, HTTP 401/403/503, platform-supplied close metadata, lost
  accepted response, durable receipt resolution, and exactly-once canonical
  prompt/tool settlement passed. The fixture explicitly selects its faux model,
  proves its upstream process/listener ownership, fails on a skipped test, and
  is included in CI for source changes. No user Gateway/session was used.
- **P7 evidence:** balanced warm projection measurements at 100/1k/10k/25k/100k
  entries preserved canonical/row/content/cursor equality; the 100k case reduced
  median stage time from about 34.5 to 28.8 ms on the recorded host. A separate
  isolated 1/4/16-active-faux-session workload (1k entries/session) observed complete
  canonical settlement, bounded snapshots, and descriptor counts returning to
  baseline. These are workload-specific observations, not unlimited scale or
  physical-device performance promises.
- **P8 remains open for manual qualification:** real cellular/Wi-Fi/Tailscale
  roaming, physical sleep/lock/energy/thermal behavior, eligible APNs delivery
  during unseen completion, and deployment-specific long-running soak. The
  attachment-animation timing sensitivity above also warrants follow-up before
  making a release/long-soak reliability claim. Gateway/app activation is still a manual maintainer step.

This plan intentionally does **not** prescribe higher buffers, endless retries, a new network protocol, a second socket/runtime, blanket cancellation, arbitrary caches, or an app-wide rewrite. The first priority is to repair misplaced ownership and bounded recovery; optimize only the measured work that remains.
