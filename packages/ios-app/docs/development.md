# Tron iOS development

## Fresh-clone prerequisites

Use Xcode 26 with the iOS 26.2 simulator runtime and XcodeGen 2.45.3. The Xcode
project is generated and intentionally untracked:

```bash
scripts/install-ci-tools.sh xcodegen
export PATH="$PWD/.ci-tools/bin:$PATH"
cd packages/ios-app
xcodegen generate
```

## Generate and build

```bash
cd packages/ios-app
xcodegen generate
xcodebuild build -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration ProdDebug \
  -destination 'generic/platform=iOS Simulator'
```

The generated Xcode project is not architectural truth; edit `project.yml` and
source files, then regenerate.

## Efficient focused tests

Do not rerun the full suite for each edit. Compile test products once, then run
only the owning suite without rebuilding:

```bash
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SnapshotCacheTests
```

Multiple `-only-testing:` arguments may select adjacent owners. After source
changes, rerun the incremental `build-for-testing` (normally seconds), then
continue with `test-without-building`. Run the complete unit target only after
focused suites pass:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests
```

`scripts/ios-ci-test.sh` is the fresh-clone unit checkpoint: it generates the
project, builds once, and runs the complete unit target without rebuilding.

Swift 6 complete strict concurrency is explicit in `project.yml`. Preserve that
baseline for focused builds that introduce or change concurrency boundaries:

```bash
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  SWIFT_STRICT_CONCURRENCY=complete
```

Gateway transport tests inject `ManualClock`, `SequenceUUIDSource`, and
`ScriptedGatewaySocket` below `GatewayClient`. Pairing generates a local UUID for
connection identity; persisted profiles decode older records with
`machineGroupID == machineId` and `isEnabled == true`. The dashboard pool admits
at most one profile per verified physical-machine group and excludes disabled
profiles, while retaining their pairing metadata, credentials, and bounded last-known
session buckets across transport retirement and focused-server changes. It validates each
secondary handshake against the paired machine identity, prefers token-bearing profiles when
choosing a group representative, and retries malformed bounded catalogs instead of leaving a
connection stuck in connecting. A foreground reconnect uses a five-second handshake deadline (initial pairing remains fifteen seconds), publishes transport readiness before slower projection/terminal restoration, and treats `system.stopping` as an immediate retry signal. Focused profile switches likewise return after handshake/event activation while refresh, mounted-session restoration, and terminal reattachment continue under admission. `AppModelLifecycleTests` owns the façade and
`GatewayLifecycleCoordinator` boundary above it: exact admissions are revoked by transition, profile-switch navigation may proceed at transport readiness before deferred projection convergence, and
concurrent profile transitions chain retire/close work before any replacement handshake, switch
closes the old socket before replacement connect, forget awaits close, concurrent final teardown
callers share completion, retired profile loads cannot publish errors or values, and final teardown
admits no event/reconnect work. `AppModelPairingAttemptTests` requires enrollment/commit failure
to restore the prior lifecycle and proves cancellation after credential commit leaves a separately
owned connection continuation rather than a stranded transitioning/connecting state.
`AppModelReconnectTests` injects
an ordered unit-interval source and records `ManualClock` sleeps to prove the nominal
2/3.4/5.78/9.826/15-second progression, bounded effective delay, foreground acceleration,
delay cancellation, single-attempt ownership, foreground reconciliation slot release on every
exit, and that a selected profile without a credential remains actionable `.unpaired` instead of
entering a reconnect loop. `AppModelCatalogSyncTests` owns scripted request barriers for known-summary
zero-read updates, unknown discovery, shared single-flight traversal, dirty follow-up, silent mixed-revision
recovery, page/item/identity bounds, typed retained/transport outcomes, background/foreground convergence,
and responsive-socket preservation. `DashboardStateOwnerTests` separately owns synchronous
cached/stale/live activity, ID-index integrity, and retention of existing dashboard buckets
when a background transport is retired. Advance the manual clock only after the expected sleeper/barrier is registered. Every test that
waits on a scripted orchestration barrier must run inside `withTestWatchdog`; never add an unbounded
wait or a clock that collapses liveness sleeps into a hot loop. Test-owned unstructured tasks
must be cancelled for their full lifetime and joined with `valueOfOwnedTask` so
the test watchdog propagates cancellation. Scripts enqueue and inspect raw frame
bytes; they must not implement protocol decoding, session state, receipt policy,
retry policy, or event admission. `GatewayClientTransportTests` injects only the narrow
frame-decoder function when proving one invocation per inbound response/event. Contract
cases must retain ignored scalar/missing/non-string/future discriminators, strict failure
for malformed recognized frames, raw unknown-topic payloads, typed large-session
preparation, and exact epoch rejection. Synchronizer tests must pair a valid unknown
envelope with malformed-envelope and malformed-known suffixes: only the valid unknown
sequence may pass pre-publication contiguity. The optional late-callback and suspended-close modes exist only
to prove that a retired epoch cannot install a hello/frame, emit a disconnect, or retain the client;
they never alter production transport behavior. Send barriers exercise queued/sending/sent
cancellation and cancellation-insensitive transports; only the local `GatewayPossiblySentError`
may activate mutation receipt resolution. Run the focused owner with:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/GatewayClientTransportTests
```

Performance intervals use `SystemPerformanceSignposts`; tests inject
`RecordingPerformanceSignposts` at the owning boundary. Metadata accepts only a
closed result code and nonnegative item/byte counts. Never add identifiers, paths,
methods, filenames, model names, prompts, transcript content, or other strings.
Gateway and cache interval contracts are owned by `GatewayClientTransportTests`
and `SnapshotCacheTests`. Gateway `session.list` materialization, authenticated cursor expiry/scope/client
binding, per-client/global count and byte limits, disconnect cleanup, one-scan traversal, and summary/catalog
revision atomicity are owned by `session-list-pagination.test.ts` and
`runtime-registry.integration.test.ts`. `AppModelPerformanceSignpostTests` drives raw Gateway
frames through visible open, synchronization/resynchronization, uncertain receipt,
and terminal replay boundaries. `AppModelTerminalLifecycleTests` retain cross-owner façade coverage for
presentation revocation, stale-attach compensation, out-of-order reset rejection, pending-event quarantine,
gap coalescing/follow-up, shared multi-presentation leases, post-detach rejection, final teardown, exact
list/write/resize/terminate wire contracts, canonical terminate-receipt retirement even when an exit event is lost, phase-aware sheet navigation cancellation/coalescing, and nested replay observation. `TerminalReducerTests` pin the
global 16-terminal, 256-chunk, and 1 MiB pending-event bounds, the three-attempt immediate recovery ceiling,
typed event reduction, and the install/reattach/discard decision for terminal-open responses that resolve on
the same, a replacement, or no current connection. `TerminalCoordinator` owns all terminal requests,
receipt-aware commands, attach/replay intervals, compensating detach cleanup, reconciliation, and reconnect
reattachment; `AppModel` only routes admitted events/lifecycle work and preserves its UI façade. The
same lifecycle suite drives an injected monotonic clock to prove the 120 ms resize boundary, same-intent
coalescing, established dimension clamps, independent presentation slots, and revocation with no late wire send.
The onboarding flow retains step/state orchestration while navigation-title, pairing-field, page, card, and info-row
chrome lives in a separate presentation component file with unchanged UIKit/SwiftUI behavior. Workspace browsing
uses one generation-owned cancellable load flight; only the newest path request may clear its exclusive busy
phase, publish an error, or request transient reconnect recovery, and dismissal synchronously retires that
presentation state. Possibly-sent folder creation may finish canonically, but navigation/dismissal generation-gates
its completion UI and an intervening path request prevents its parent refresh from replacing newer navigation. The dashboard shell
and new-session sheet are separate presentation owners; the sheet retains the same configuration/creation state
owners, focus behavior, controls, detents, and mutation admission.
`ChatView` retains route/composer/transcript composition while attachment controls and chips, entrance/render
rows, and extension-widget implementation live in separate presentation files with unchanged identities and
transitions. Session History uses the same compact settings-row typography, icon column, spacing, and padding
rhythm as the surrounding management sheets; long canonical previews wrap without increasing the base row scale. Widget/status state remains canonical, but both native presentations are temporarily gated off.
Conversation-turn rendering and lifecycle-safe media chips remain in `TranscriptRow.swift`; transcript event
controls and tool-run/detail routing live in dedicated owners without widening their private helper state. The
primary tool sheet, diff destination, technical-payload destination, and shared navigation chrome also have
separate presentation owners; only their directly shared layout/diff primitives use module-internal access.
The settings shell and its appearance, connection/import, provider, agent-default, runtime-behavior, resource-path,
package, trust, and custom-model destinations live in separate source owners while retaining the same progressive sheet links and shared draft/state coordinators. The main settings sheet is a single eager list of separated Liquid Glass row containers without category headers; each row carries a concise secondary summary, and project scope inserts Project Trust while dashboard scope inserts Import. Connections owns the server-management surface: paired-server rows open per-server detail sheets and authorized devices remain below the server list. Logs are a separate final top-level Settings destination, so Connections and its detail sheets never fetch or render log history. The Logs destination performs one bounded on-demand read when opened, renders through a lazy compact list, filters locally, and refreshes only when explicitly requested. Gateway Update status/config decoding is bounded and capability-aware; the source-repository sheet submits a typed Mac path through lifecycle admission and command receipts. Stable on 9847 and local Debug on 9848 remain separately paired profiles with their own persisted credentials. Pairing, initial hello, reconnect hello, and authenticated `system.info` require an asserted `stable`/`dev` channel matching that profile; missing, malformed, or endpoint-mismatched identities fail closed. A planned Debug `system.stopping` event uses the existing immediate reconnect path with the same profile endpoint and token, then installs the replacement runtime epoch and authoritative projections without replaying an accepted prompt. A Debug-origin candidate exposes the confirmed **Promote Debug Gateway to Stable** action only when its focused Stable-channel status carries an available exact version, lowercase SHA-256 fingerprint, source revision, tested Debug runtime epoch, and candidate runtime epoch whose provenance matches the verified candidate identity; the confirmation pins the immutable version and fingerprint. The separate **Build and update Gateway from source** action requires a valid configured source root and sends source mode only; generic or unpinned artifact candidates are never promoted automatically. The dashboard server filter keeps multi-selection separate from ordering: the default groups by project/server, while Recent Activity renders one reverse-chronological session list with project/server context beneath each row. Its selection guidance belongs in a compact header block directly below the Servers section label, with stronger separation above that block, and uses the shared 11-point secondary-description scale matching the other adjusted sheet descriptions. The selected ordering is stored as a bounded local UI preference and restored when the app launches. Project headers show the project folder in bold monospace with the server name as a right-aligned secondary monospace label. The dashboard settings overview uses an eager stack so the Gateway Import destination is materialized with the initial sheet; project-scoped settings intentionally omit that dashboard-only action.
Resolved package JSON is constructed only inside its progressive detail destination; the overview retains a
constant-depth top-level count instead of recursively rendering a potentially large resource tree. Package reload
refreshes the inventory and update projection together, while installation controls live in a medium/large
progressive sheet. Custom provider editors keep their three dense text fields together before the API-format row
and use the standard settings-group header treatment. Provider and model catalogs use the shared
`ModelDisplayFormatting` projections everywhere they are shown; canonical IDs remain unchanged for
search, persistence, and mutation while labels use product casing such as “OpenAI Codex / GPT 5.6 Luna”.
New Session quick selectors carry both server and project identity; source-control choices are sent
through the confirmed `session.create` mutation, and Gateway owns Git worktree creation, trust
propagation, and rollback. Project Resources normalizes producer whitespace before display, caps overview subtitles to one line, and keeps detailed tool/resource content in the tapped detail sheet so scrolling remains lightweight. Provider settings cards use one centered leading
icon column with vertically centered icons and leading-aligned text; the Manage Session workspace path
uses a trailing inline group-header detail rather than a second header line.
Terminal sheet composition, presentation lifecycle/error state, and native SwiftTerm/keyboard rendering live
in separate source files. The presentation owner permits one active start/show/open flight and one newest pending
route; read replacement cancels safely, while attach/open replacement waits for stale compensation before launching
the pending route. Focused cases also require completed stale-open compensation, prevent confirmed-missing
open replay after revocation, and keep terminate/write/resize failures visible while the renderer remains installed.
The style guard pins that boundary so renderer code cannot regain Gateway/AppModel work.
`SessionPresentationStoreTests` own observation forwarding, cold-cache non-authority,
disconnect/profile-reset semantics, all-topic revocation, old-close/new-open arbitration, stale and
revoked secondary-response rejection, exact subscription-token admission, and suspended paging
revalidation across revocation, token replacement, and disconnect. `SessionMutationServiceTests`
own explicit session command identity, wire construction, typed outcomes, stable-ID replay only
after a confirmed-missing receipt, and cancellation before replay wire emission. AppModel performance
tests retain cross-owner create/fork/delete, prompt-attachment, queue, navigation-editor, and tree-reload
ordering coverage. `SessionImportCoordinatorTests` own exact lifecycle/profile admission across
file access, upload, and mutation; security-scope balancing; and import-result independence from a
later catalog refresh. `ComposerDraftCoordinatorTests` own bounded profile/session text retention,
exact presentation mounting/revocation, deterministic inactive-draft LRU, one-time route seeding,
independent barrier-controlled out-of-order uploads with exact byte/name/MIME capture, cancellation cleanup,
editor policy/use/keep disposition, confirmed/failure/uncertain submission semantics, A → B → A rejection,
and nested façade observation. `SessionShellProfileRouteOwnerTests` prove that selected-profile round trips
synchronously revoke and pop the production route. AppModel performance tests retain the real
`session.prompt` integration proof, post-mount admission-failure cleanup, attachment removal only after
confirmation, and direct share prompts that never inherit staged composer IDs. Run the focused mutation, import, and
composer owners with:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionMutationServiceTests \
  -only-testing:TronMobileTests/SessionImportCoordinatorTests \
  -only-testing:TronMobileTests/ComposerDraftCoordinatorTests \
  -only-testing:TronMobileTests/SessionShellProfileRouteOwnerTests \
  -only-testing:TronMobileTests/MultilineComposerTextViewTests
```

`SessionEventSynchronizerTests` own the composed intent-keyed shared outcome and
event-quarantine invariants; `SessionSnapshotEventAdmissionTests` own the
live full-snapshot matrix (authority, route identity, runtime, duplicate/stale/exact-next/gap
cursor). Synchronizer coverage rejects a quarantined route/payload mismatch before baseline
publication, while the AppModel suites prove snapshots/tokens remain provisional through
acknowledgement, unmounted or synchronously revoked hints cannot create/advance state, and stale routes close their exact provisional token. The same suite proves a mounted route wins over divergent
dashboard selection, dashboard refresh cannot open an inferred transcript, mounted reconnect restores
the exact route, secondary reads cannot create hidden subscriptions, and create/fork return navigation
identity without opening it implicitly. Create additionally returns before any dashboard catalog read;
its route remains bound to the admitting gateway profile/lifecycle while `session.listChanged` owns
projection convergence. `DashboardStateOwnerTests` prove typed latest-load and
navigation admission, monotonic live-summary overlays, unknown-row discovery, safe cache/disconnect
projection, and removal, while `GlobalNoticeStoreTests` enforce the eight-entry, 4 KiB-message, and 16 KiB-total
budgets plus keyed progress coalescing. `ComposerDraftCoordinatorTests` prove profile/session draft
isolation and same-session-generation isolation for disposable attachment/editor/submission state;
event tests prove departing routes are excluded from share admission. Compatible synchronization callers now share one outcome without timing polls;
each actual authoritative open/resync attempt retains its own interval.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionPresentationStoreTests \
  -only-testing:TronMobileTests/AppModelPerformanceSignpostTests
```

Camera boundary tests inject authorization and capture-session providers into
`CameraModel`; QR boundary tests use the same authorization seam plus a scanner-specific
session provider. They never invoke camera hardware or replace AVFoundation in production.
Keep provider callbacks MainActor-bound and keep the two unchecked Sendable AVFoundation
envelopes limited to the photo provider's serial queue boundary. The QR permission task
must recheck cancellation before configuration. Phase 7 owns the remaining generation-scoped
camera setup/capture lifecycle changes.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/CameraBoundaryTests \
  -only-testing:TronMobileTests/QRCodeScannerBoundaryTests
```

Share boundary tests cover provider-fragment reduction, prompt composition, and the
single-value app-group store without loading extension UI. `PrivacyManifestTests` verify
both source manifests and both built bundles. The separate archive check is read-only and
must run after a maintainer-created archive; it never archives, exports, or uploads.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SharedContentTests \
  -only-testing:TronMobileTests/PrivacyManifestTests
packages/ios-app/scripts/test-verify-archive-privacy.sh
packages/ios-app/scripts/verify-archive-privacy.sh <path-to-xcarchive>
```

Global configuration surfaces key their SwiftUI reload task to event-only invalidation
generations. Successful settings, provider/model, package, and custom-model reads publish
values without changing those generations. `SettingsTrustCoordinatorTests` owns the extracted
settings/trust boundary: independent target admission, newest same-target publication, profile
retirement rejection at each suspended boundary, exact `true`/`false`/explicit-`null` trust
wire decisions, event-only revisions, centralized receipt replay, and nested Observation through
the `AppModel` façade. `ProviderAuthCoordinatorTests` owns the corresponding provider boundary:
target-isolated newest-load admission, atomic provider/model publication, bounded cursor validation,
transport-retired prompts, and stale operation responses that close without surfacing a broker not-found error.
profile-retirement rejection across parallel reads and pagination, operation-keyed prompt/event
state, bounded event-before-response quarantine and promotion, stale response/cancellation safety,
exact-target completion refresh, receipt-backed forced refresh/logout, event-only invalidation, and
nested façade observation. `PackageConfigurationCoordinatorTests` owns typed target isolation,
newest list/check admission, admitted-error handling, event-only invalidation, closed mutation
wires and timeouts, stable receipt replay, pre-confirmation marker stability, admitted-versus-stale
mutation failures, same-profile uncertainty preservation, exact-target reload, profile retirement,
and nested façade observation. `CustomModelConfigurationCoordinatorTests` owns newest read and
mutation admission, validate-before-put ordering, no-put failure/retirement, current-versus-retired
validation/put errors, stable put receipts, A → B → A rejection, lifecycle-bound restart failures,
cancellation-safe presentation, nested observation, and exact draft-revision save admission.
`GatewayDiagnosticsServiceTests` own the read-only view boundary for exact-path `git.inspect` and
bounded `system.logs` requests, typed projection, malformed-record skipping, and newest-first ordering.
The Logs destination uses AppModel's profile-targeted diagnostics façade; it never reaches
`model.client`. DTO fields remain in the service while log color/icon/date formatting remains in the dedicated logs UI.
`AppModelInvalidationTests` scripts every
successful response and proves publication cannot schedule its own next load; event tests
separately prove one generation advance per canonical invalidation. Settings requests use a
typed target: global requests omit CWD, while project requests carry their exact project CWD.
The focused suite deliberately completes global/project settings and global/session provider
catalogs out of order, then reverses two same-target reads; installed values must remain under
their request key and the newest same-target request must win. New-session owner coverage binds
configuration readiness to both workspace and gateway profile, exposes unresolved preparation, and
single-admits creation until terminal completion. It also proves auth completion retains its catalog
target after failed cancellation and unknown operations trigger no guessed reload.
Package and custom-model ordering and mutation cases now live with their extracted owners rather
than in `AppModelInvalidationTests`. `SettingsDraftStoreTests` prove target isolation,
pre-response editing, invalidation rejection,
provider-target load identity, stale save/scope-round-trip admission across model/default, runtime,
and resource drafts, changed-field-only wire patches, and explicit redacted proxy set/clear handling.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SettingsTrustCoordinatorTests \
  -only-testing:TronMobileTests/ProviderAuthCoordinatorTests \
  -only-testing:TronMobileTests/PackageConfigurationCoordinatorTests \
  -only-testing:TronMobileTests/CustomModelConfigurationCoordinatorTests \
  -only-testing:TronMobileTests/AppModelInvalidationTests \
  -only-testing:TronMobileTests/AppModelEventTests/globalConfigurationInvalidations \
  -only-testing:TronMobileTests/NewSessionConfigurationOwnerTests \
  -only-testing:TronMobileTests/SettingsRouteIdentityTests \
  -only-testing:TronMobileTests/SettingsDraftStoreTests
```

Pairing tests keep policy above byte transport. `GatewayPairingTransportTests`
feed raw HTTP response bytes and inspect the exact `/v1/pair` request.
`AppModelPairingAttemptTests` use barriers whose late responses intentionally
outlive task cancellation, plus an injected commit recorder, so stale-path tests
never write Keychain. Run the attempt race suite repeatedly when changing its
ownership checks:

```bash
for run in 1 2 3; do
  xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
    -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:TronMobileTests/GatewayPairingTransportTests \
    -only-testing:TronMobileTests/AppModelPairingAttemptTests \
    -only-testing:TronMobileTests/PairingInvitationParserTests || exit 1
done
```

`SessionScenarioBuilder` is test-only and generates deterministic synthetic
opening tails, on-demand history pages, tool bursts, true prefix-cumulative
Markdown streams, and attachment inputs. The 30/60 Hz stream crosses Unicode,
unmatched and completed inline syntax, open/closed fences, table promotion,
lists, quotes, headings, and rules. JPEG and PNG fixtures are generated from a
seeded pixel function at test time with explicit dimensions and orientation; no
opaque image binary or personal file is stored. The separate arbitrary-byte
high-resolution attachment remains an encoded-admission stress input, not a
decodable image. Record the seed and requested byte/count/rate/dimension inputs
with performance results. Validate the fixture contracts with:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionScenarioBuilderTests \
  -only-testing:TronMobileTests/MarkdownPresentationTests \
  -only-testing:TronMobileTests/ChatTextPreparationTests \
  -only-testing:TronMobileTests/ChatMediaLoaderTests \
  -only-testing:TronMobileTests/ChatTranscriptPresentationStoreTests \
  -only-testing:TronMobileTests/PresentationStyleGuardTests
```

Phase 6.0 source characterization and provisional budgets, Phase 6.1 pure Markdown
presentation, and the bounded Phase 6.2 Markdown/thinking preparation cache are complete.
Physical pixel, text selection, VoiceOver, Dynamic Type, frame, and memory acceptance
remains pending; the Phase 6 exit gate is not met. `MarkdownPresentation.swift` remains
the sole cold parser. The renderer consumes an exact immutable document with preconstructed
inline attribution and source-based accessibility text. The projection worker warms only the
bounded render-critical tail, prepares at most two values concurrently, admits newest source
per identity, and installs only exact row-local slices. The shared 4 MiB LRU, 512 Markdown,
4,096 thinking, and 320,000-byte source ceilings are conjunctive; memory pressure and scope
replacement clear prepared values. Misses and older explicitly paged rows retain the exact
cold fallback, so no placeholder or visual behavior was added. Do not add prefix reuse until
differential tests prove cold equivalence. Fence closure, table promotion, list/quote
continuation, and incomplete inline syntax can reclassify an earlier prefix, so every uncertain
state must retain a full-parse fallback.

Phase 6.3 routes transcript blobs through `ChatMediaLoader`; transcript views must not call
`GatewayClient.blob` directly. Identity includes profile, lifecycle generation, connection, and blob
ID. Tests own exact 192-pixel oriented downsampling, duplicate single-flight behavior, one shared
preparation slot, the 32-flight ceiling, 64-item and 4 MiB decoded LRU eviction, transport-level 25 MiB
response admission, stale-identity and late-publication rejection, uncached one-at-a-time full previews,
and app-lifetime memory-pressure cleanup. The production row retains its 64-point loading/retry
surface and opens the existing medium preview immediately from a nonoptional thumbnail-backed item route
while full resolution loads; a sheet must never be admitted with conditional empty content. Physical pixel and
peak-memory calibration remains required.

`ChatViewScrollHarnessTests` mount the actual `ChatView`, `LazyVStack`, composer
inset, and native `UIScrollView` in a fixed hosted window. Test-only authority
admission bypasses network I/O without bypassing `AppModel`'s authoritative read
gate. Raw geometry, visible semantic IDs, and row frames are reduced to one latest
sample on each `CADisplayLink` tick; added evidence is aggregate command/frame/count
data only. A maximum-512-row opening case requires the very first ready sample to contain
the exact physical tail marker and latest message in the same plausible native bottom
viewport, so an eventual manual/lazy correction cannot make the test pass. The production
`DisplayFrameScheduler` is a one-shot, cancellation-aware display-link boundary used by
first-ready, frame-gated unrealized-tail correction, pinned follow, and long-distance
catch-up staging. Semantic prepend settlement instead waits passively
for exact epoch-qualified row callbacks and requires a strictly newer callback after
each correction. First-ready timing cannot end before the exact initial transcript
projection installs and its frame resumes. `ChatTranscriptPresentationStoreTests` use a
watchdog-bounded synchronous `HOSTED_TEST`-only work gate immediately before the real production
kernel to prove serial off-main work, same-tag coalescing, newest-wins and A→B→A admission,
paging-tag distinction, monotonic reset retirement, session/runtime scope rejection, MainActor
responsiveness, and deterministic completed-before-frame replacement/reset races without sleeps or
polling. They also cover atomic installation, runtime-only exact-key reuse, 512-item FIFO bounds for
both pending and admitted geometry-owned entrances across more than 512 accumulated rows, and isolated
suffix work across thirty updates of a 10,000-entry text stream. The
gate can delay work but cannot manufacture output or disable production projection semantics.
`ChatTranscriptProjectionKernelTests` characterize raw atoms and the sole global assembler across
barriers, canonical call/result joins, orphan results, bootstrap configuration, exact compaction
ordinals, semantic maps, and visible history beyond one 512-item page. Sparse cases cover exact
prepend/append/rollover ordinal intersection, a one-entry middle replacement beyond 512, same-ID
payload changes, conservative inexact and duplicate behavior, canonical-result assembly, one patched
tool in 10,000 history rows and 100/256-tool runs, anchored completion, structural phase/membership/
order/start/duplicate/stream-placement fallbacks, newest-state duplicate delivery reversal,
streaming-call result placement (including malformed text/extension call references in cold-worker
and incremental paths), maximum-bound overflow rejection, bounded flat overrides across one
and multiple rows, assembly reset, and isolated suffix sharing. Every accepted incremental output is
compared with the cold oracle. The aggregate recorder
exposes only the closed `cold`, `fragmentReuse`, `toolPayloadPatch`, and `isolatedStreamingSuffix`
modes plus numeric entry/fragment/tool/atom/rendered counts; a pure patch must report zero source
entries and atoms, inspect the complete unique runtime membership, and count only distinct patched tools. `SessionPresentationStoreTests` also
prove exact page `start`/`end`/count admission and that return-to-latest compacts loaded
history back to the retained authoritative tail. `ChatScrollCoordinatorTests` use watchdog-bounded
barriers rather than sleeps or yields to prove callback-order equivalence, immediate
catch-up dismissal for geometry-first manual return to the tail, pinned keyboard/composer
following, one follow command per frame, nonanimated settlement for an admitted discrete
insertion, native-geometry acknowledgement before a subsequent follow, immediate continuous-stream following,
no writes for detached layout/stream/keyboard
settlement, viewport geometry-first expansion detachment, frame-separated catch-up with unread admission
through every interruption stage, Reduce Motion, exact reset/release command admission,
exact physical-tail opening settlement, phase-keyed native-geometry replay, bounded exact-binding fallback,
frame-gated unrealized-target correction without geometry, overflow-overshoot rejection, both geometry/frame callback orders,
empty/undersized top alignment, post-reveal stable-frame binding release, pre-settlement user cancellation,
stale-presentation rejection, repeat-prepend ownership, post-install layout-epoch rejection, unchanged-frame epoch
callbacks, and exact semantic remeasurement with at most one late correction and no
frame retry or total-height polling. Hosted controls drive the production
coordinator/executor; new evidence is bounded aggregate callback/command/frame and
maximum-excursion data only. Hosted discrete-insertion cases record aggregate entrance and automatic-follow
counts, prove a visible insertion admits once, and prove detached insertion emits no automatic write.
Hosted streaming bursts must install only their newest exact source while detached composer/viewport work
remains writable and creates no projection work. `ChatCompactPillTests` own intrinsic-width trailing placement for short prompts, the 364-point
long-prompt bound, intrinsic-width glass selection, equal user-prompt vertical padding, logical-leading
line alignment, agent-matched Dynamic Type body sizing, shared prompt/queue Liquid Glass geometry, and
flat/detail material policy. `ChatContentTransitionTests` own role
classification, trailing composer-edge prompt/queue motion, aligned activity motion, and the
identity transform required by Reduce Motion. Hosted scroll tests remain the authority that these
visual transforms do not grant detached readers automatic writes or replay same-ID entrances.
`GatewayProtocolContractTests`, `SharedProtocolFixtureTests`, and
`SessionMutationServiceTests` cover revisioned queue projection and replacement commands.
`QueuedMessagePresentationTests` own capability/field admission for editing; presentation guards
retain intrinsic cards capped at the user-prompt bound, full-shape whole-card interactive Liquid Glass,
leading-toolbar removal, an explicit legacy lock, and Tron surfaces instead of stock forms.
Native bottom evidence comes from `ScrollGeometry.visibleRect.maxY`
plus the bottom inset; the harness no longer substitutes a hard-coded settled distance.
The obsolete visibility modifier is removed; the native SwiftUI geometry modifier still
reports a multiple-update-per-frame diagnostic in hosted runs and remains a physical checkpoint.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Fast' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/ChatScrollCoordinatorTests \
  -only-testing:TronMobileTests/ChatTranscriptPresentationStoreTests \
  -only-testing:TronMobileTests/ChatTranscriptPresentationTests \
  -only-testing:TronMobileTests/ChatCompactPillTests \
  -only-testing:TronMobileTests/ChatViewScrollHarnessTests \
  -only-testing:TronMobileTests/ChatPerformanceTrackerTests
```

`ChatPerformanceBaselineTests` is opt-in and records five post-warm-up timing,
CPU, physical-memory, and malloc-zone allocation samples. Its opening benchmark
also records the scroll-animation signpost against the 10,000-entry hosted fixture;
separate microbenchmarks measure cumulative Markdown preparation throughput and
static thumbnail/full-preview decode boundaries without claiming arrival cadence,
projection coalescing, or media-owner lifecycle behavior. `Tron Device Performance` uses
the provisioned app identity with `HOSTED_TEST` for test/profile actions; its archive
action points to `Prod` so hosted hooks cannot enter an archive. Run the test only at
explicit checkpoints and keep device identifiers
out of source. The recorded Phase 0 environment, results, limitations, and commands
are in [performance-baseline.md](performance-baseline.md).

Run UI tests separately because simulator launch dominates their cost:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron UI Validation' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileUITests/TronSmokeUITests \
  -collect-test-diagnostics never
```

For real gateway-to-iOS E2E work, keep the deterministic gateway fixture and
DerivedData alive across edits. Preparation and the first build happen once;
`run` renews only the one-use enrollment/session fixture and executes the
focused UI test without reinstalling dependencies or rebuilding:

```bash
scripts/ios-gateway-e2e-test prepare
scripts/ios-gateway-e2e-test build
scripts/ios-gateway-e2e-test run

# After a Swift edit:
scripts/ios-gateway-e2e-test iterate

# Exercise only native attachment menu → camera/photo/file presentations:
TRON_E2E_ATTACHMENT_ONLY=1 scripts/ios-gateway-e2e-test iterate
```

The focused runner disables Xcode's failure sysdiagnose collection, which can
otherwise add a ten-minute timeout after a UI assertion. Its reconnect journey
cold-launches back to the authoritative dashboard and explicitly reopens the
session; transient `NavigationStack` state is not part of restoration or cache
truth. Use `logs`, `status`, `stop`, and `clean` to inspect or manage the
persistent fixture. CI owns the
complete unit target; smoke/accessibility and real-gateway UI journeys remain
explicit cross-module/release checkpoints because they are slower and depend on
simulator integration rather than ordinary source compilation. Full UI suites
remain final checkpoint validation, not an edit loop.

Typography or control-style changes must run
`TronMobileTests/FontSettingsTests` and
`TronMobileTests/PresentationStyleGuardTests`. The font tests verify all bundled
faces resolve, historical preference keys round-trip, and variable Source Serif
and Recursive code roles do not silently become system fonts. The presentation
guard rejects app-owned system fonts, stock bordered/search/segmented/field
styles, system-generated section/navigation titles, unstyled text inputs, and
Form/List surfaces that omit the Tron collection treatment. OS-owned alerts,
menus, and pickers are deliberate exceptions.

UI validation audits onboarding in light and dark modes and audits a
populated real-gateway chat, session management, settings, and appearance. The
real-gateway test retains named screenshot checkpoints for the completed chat,
Manage Session, root settings, and appearance in its result bundle. Manage Session
acceptance additionally verifies the compact context bar, exactly two primary groups,
textual Compact action, peer Project Resources details, the shared Technical JSON sheet,
user-oriented Agent Context, and the History-owned runtime summary. Focused presentation
policy tests separately pin stable export-row identity, single-row progress ownership, and
presentation-local failures without requiring a large live export. The end-to-end path also
relaunches at accessibility XXXL to verify standard SwiftUI controls that
XCTest's simulated Dynamic Type audit misclassifies. Any audit suppression must
name one exact element, have a retained rendered checkpoint, and have a separate
real-size assertion; category-wide suppression is not allowed.

Simulator screenshots are deterministic regression artifacts, not the final
system-chrome authority. At broad presentation checkpoints, build the actual
`Tron Fast` `ProdDebug` app for the connected iOS 27 device, install it without
removing its Keychain pairing, launch it against the isolated development
gateway, and capture chat, dashboard/setup, Manage Session, tool detail, and
settings screens with `devicectl`. Terminal lifecycle checkpoints additionally verify
that the signed app installs and launches on the connected device after the focused suites
pass; interactive PTY input remains a manual device check. Compare captures to the historical
references before declaring parity. A signed install, launch, and screenshot are
required together because default toolbar Liquid Glass can differ materially
between the simulator and physical hardware. Chat checkpoints must also verify
trailing alignment for user turns, historical transcript/tool insertion motion,
the Settings gear in the chat toolbar, the context ring at the trailing edge of
an empty idle composer, the nonstructural short bottom blur at default running state, its background-layer
movement between the device-bottom inset and beneath the keyboard's rounded top corners, static subtle emerald under Reduce Motion,
retained compact rows for custom/compaction/retry detail, and emerald toolbar/sheet actions. Physical chat spacing acceptance additionally checks that
a one-visual-line prompt has intrinsic height, sent photo/file chips stay above and outside prompt glass,
tool pills retain six-point vertical insets with the slightly larger tool-only symbol step and without a
44-point label minimum, attachment/context/send visuals share the 16-point metric inside 40-point targets,
elapsed timing hugs its intrinsic width, and a pending photo's 22-point remove
circle sits half outside the 64-point preview within a 30-point target centered on its top-trailing corner.
Active-chat reliability checks must advance a desired completion before the displayed running tool receives
geometry and verify that the running chip still reveals exactly once. Submission-to-pending-to-canonical prompts
retain one mounted visual handoff, submitted attachment chips leave the composer before the transcript replacement,
and attachment-only prompts reconcile by attachment metadata. Streaming assistant settlement and runtime-to-canonical
tool grouping retain their visual row identities. Agent text and thinking traces reveal only newly admitted words while
keeping full layout geometry stable; reconnecting to a long stream catches up instead of replaying the backlog, and
completion reveals the full source without a flash. Thinking traces remain one-line natural height until they
exceed four measured lines, then show only their latest four lines without scrolling; the oldest visible line fades
at the top to signal earlier content. Tapping the overflow opens the full trace sheet, which continues updating during
streaming. The sheet uses the shared Tron title/top-blur/toolbar
chrome with no drag handle. The same rendered tool/group row stays after non-tool streaming
across running-to-completed updates, retains at most one installed-identity-owned tail settlement while
pinned, uses one coordinated smooth viewport follow for a newly admitted tool chip,
preserves a surviving semantic anchor while detached, and emits no unowned automatic write when content
shrinks. Verify a tool entrance has one correlated chip reveal and viewport command rather than competing writes.
Tool-detail checkpoints open read, edit, bash, and one unknown/extension call at the medium detent: verify the compact status/metadata chips,
secondary-plus-accent path, faithful single-change diff glance, word-preserving wrapped bash commands in
the smaller code size, high-signal generic summary, and larger live result are visible before
protocol fields. A bounded command must not add an amber completeness row to the primary sheet. Pull one single-change sheet to large
and confirm its full bounded diff appears in place; separately verify multiple edits, extra header-only/binary
files, header-light multi-file patches, and malformed or combined patch hunks show only the focused Changes
row and dedicated Changes sub-sheet. At an Accessibility Dynamic Type size, confirm every status, metadata,
and activity chip hugs its intrinsic content instead of stretching across an available row; when content is wider
than the sheet, it remains within the sheet and wraps to at most two lines in the original VoiceOver order.
Open a running single-tool detail before a second tool joins its run and verify the original sheet and detent stay
mounted while its fields settle from the newest matching call ID. Exercise one pathological command/output and confirm the
primary preview wraps, explicitly marks omissions, and leaves the complete projected value in the final
Technical details sheet. With VoiceOver enabled, verify pathological path/glob metadata speaks only the concise
preview plus the Technical details disclosure. Verify compact selectable execution metadata remains first and
records bounded-command completeness, followed by Request JSON then Result JSON containers. Open each
container and verify it immediately presents selectable, vertically scrollable raw JSON for the complete
response-first, content-only string, distinct-fallback, request-only, and missing-result cases without a
readable-output duplicate or third fallback section.
Verify live updates and true-only truncation metadata without moving the primary sheet's reading position. With
a nonempty focused composer, open the native attachment menu, verify the keyboard remains visible, verify its
option symbols are emerald while text retains native system styling, and activate camera, photos, and files on
the first option tap; the 40-point plus control and native menu appearance/order must remain unchanged. Terminal checkpoints must exercise
the native keyboard plus the floating shortcut and command-key surfaces rather
than validating only PTY output.

Historical onboarding references captured by executing commit `c3f12c17c` live
under `docs/assets/parity/`. `TronSmokeUITests` keeps matching medium/pairing
screenshots in its result bundle. Compare the medium sheet crop as well as the
full screen: the mounted shell toolbar, detent, centered title, card geometry,
page dots, and toolbar navigation are all part of the parity contract. Copy may
change only where gateway security semantics require one-time enrollment rather
than a permanent pairing token.

## Chat top-blur validation

The chat's top-edge overlay is inspired by
[jtrivedi/VariableBlurView](https://github.com/jtrivedi/VariableBlurView). The
`Tron Fast` `ProdDebug` build enables its guarded private `CAFilter`
variable-radius path for local visual iteration only. The Objective-C bridge
catches runtime exceptions and falls back cleanly if the private filter or
backdrop hierarchy changes. Other configurations compile the App-Review-safe
public fallback: a gradient-masked `UIVisualEffectView`. Do not
add `TRON_PRIVATE_VARIABLE_BLUR` to an archived configuration; private API is
not eligible for App Store distribution.

Validate this chrome on a physical device while scrolling high-contrast content
beneath the chat, dashboard, and representative medium/large sheet toolbars.
Chat uses a 188-point fade, dashboard 176 points, and sheets a compact 124 points.
Check that each top stays legible, the lower edge has no visible cutoff, toolbar
controls remain tappable, and light/dark modes retain the same gradual
transition. Immersive camera and image-preview sheets intentionally have no
added backdrop.

## Manual iOS release validation and delivery

The repository does not archive or upload production iOS artifacts. A maintainer
performs every TestFlight or App Store delivery deliberately:

1. Select the exact commit whose CI checks passed, confirm a clean tracked
   checkout, and run `scripts/tron version check`.
2. Generate the project and complete the release checkpoint: the full iOS unit
   target, required UI/E2E journeys, and eyes-on physical iPhone/iPad review of
   onboarding, pairing, chat/attachments, system-keyboard dictation, terminal,
   settings, accessibility, and signed-device networking.
3. With a stable non-beta Xcode and maintainer-controlled signing credentials,
   archive the `Tron` scheme in `Prod`. Run
   `packages/ios-app/scripts/verify-archive-privacy.sh <path-to-xcarchive>`, then inspect
   the app and share extension bundle identifiers, versions/builds, and signatures before export.
4. Use Xcode Organizer/App Store Connect to export and upload manually, then make
   any TestFlight group assignment or App Store release choice explicitly. Record
   the source commit, version/build, and validation results with the release.

Never add or invoke a repository workflow or command that performs production
archive upload, TestFlight distribution, or App Store release automatically.

## Gateway fixture work

Protocol DTO changes require matching gateway tests and Swift decoding tests.
Keep Swift wire values in their authority-owned model files (`GatewayConnectionModels`,
`SessionCatalogModels`, `TranscriptModels`, `SessionRuntimeModels`,
`ResourceCatalogModels`, `WorkspaceModels`, and `TerminalModels`) without adding projection state or custom
cross-file serialization. Use provider-qualified models, preserve unknown JSON through
`JSONValue`, and make new mutation calls carry a UUID `commandId`.

## Privacy

The app declares local-network and camera usage. Voice input remains available
through system-keyboard dictation; the app does not currently own microphone or
speech-recognition capture. Provider credentials must never be placed in fixtures,
defaults, logs, or UserDefaults.
