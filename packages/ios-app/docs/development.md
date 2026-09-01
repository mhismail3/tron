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

## UI motion and loading surfaces

Compact in-progress UI uses `TronPulseLoadingIndicator`, an in-house SwiftUI
Canvas pulse. It is lifecycle-aware, stops with the view, and pauses for Reduce
Motion or inactive scenes. Keep `ProgressView(value:total:)` for determinate
progress only; do not reintroduce stock indeterminate spinners in chat chips,
dashboard activity rows, or shared loading states. Diff content owns an
intrinsic horizontal code column so long lines scroll without competing with
the sheet's vertical gesture. Queue editing uses direct sheet content with
compact delivery tabs, a full-card tap target, and Tron typography for its
unavailable state. The chat scroll coordinator treats an uncommanded native
retreat from the pinned tail (including the status-bar scroll-to-top gesture) as
reader ownership, so it exposes catch-up rather than reapplying the tail anchor.

## Generate and build

```bash
cd packages/ios-app
xcodegen generate
xcodebuild build -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Development \
  -destination 'generic/platform=iOS Simulator'
```

The generated Xcode project is not architectural truth; edit `project.yml` and
source files, then regenerate. Because the application uses a checked-in plist, `Sources/Info.plist` is the sole runtime orientation authority: iPhone is portrait-only while iPad supports portrait, upside-down portrait, and both landscape orientations. Do not add competing `INFOPLIST_KEY_UISupportedInterfaceOrientations*` settings to `project.yml`; run `scripts/test-source-policy.sh` to guard this boundary and the bundled notification sound.

### Build matrix

| Configuration | Intended workflow | Bundle identity | Push environment |
|---|---|---|---|
| `Development` | Simulator app iteration | `com.tron.mobile.beta` | beta route, APNs sandbox |
| `Test` | Hosted unit/UI tests | `com.tron.mobile.testhost` | no real APNs lane |
| `LocalDevice` | Ordinary physical-device development | `com.tron.mobile` | production-sandbox route |
| `DevicePerformance` | Physical hosted performance fixture | `com.tron.mobile` | production-sandbox route |
| `Release` | Manual distribution archive only | `com.tron.mobile` | production route |

The corresponding schemes are `Tron Development`, `Tron Device`, `Tron UI
Validation`, `Tron Device Performance`, and archive-only `Tron Release`. Only
`Tron Release` contains Archive/Profile/Analyze actions. `LocalDevice` and
`DevicePerformance` replace the same installed app identity; never run the
performance fixture on a device another workflow owns. Runtime build role and
push route are emitted into `Info.plist`, but the final signed entitlements and
provisioning profile remain authoritative for Apple service environments.

## Efficient focused tests

Do not rerun the full suite for each edit. Compile test products once, then run
only the owning suite without rebuilding:

```bash
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SnapshotCacheTests
```

Multiple `-only-testing:` arguments may select adjacent owners. After source
changes, rerun the incremental `build-for-testing` (normally seconds), then
continue with `test-without-building`. Run the complete unit target only after
focused suites pass:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests
```

`scripts/ios-ci-test.sh` is the fresh-clone unit checkpoint: it generates the
project, builds once, and runs the complete unit target without rebuilding.

Swift 6 complete strict concurrency is explicit in `project.yml`. Preserve that
baseline for focused builds that introduce or change concurrency boundaries:

```bash
xcodebuild build-for-testing -project TronMobile.xcodeproj -scheme 'Tron Development' \
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
recovery, page/item/identity bounds, application-error retention on a responsive socket,
background/foreground convergence, and responsive-socket preservation. `DashboardStateOwnerTests` separately owns synchronous
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
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
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
package, trust, and custom-model destinations live in separate source owners while retaining the same progressive sheet links and shared draft/state coordinators. Every shared toggle row keeps a fixed 50×30 control while its thumb briefly stretches horizontally during the state slide and settles without moving row layout; Reduce Motion preserves state/tint feedback but disables that spatial stretch. The main settings sheet uses three eager divider-owned Liquid Glass groups: emerald App & Connections, purple Agent, and blue Workspace & Diagnostics. Each row icon and divider matches its group, each row carries a concise secondary summary, and project scope inserts Project Trust while dashboard scope inserts Import. A progressive destination inherits that row accent for its titles, controls, icons, dividers, and ordinary containers, including nested sheets. Informational text cards—including the bottom guidance in Custom Models, Packages, Resource Locations, and Project Trust—retain the originating hue but mix toward slate so they stay lighter and visually secondary. Settings-row and full-width action labels use white in dark mode and their accent in light mode; Project Trust and Gateway actions keep semantic button tints that match their light-mode text, while warning, error, destructive, and log-level state semantics keep their explicit colors. Connections owns the server-management surface: paired-server rows open per-server detail sheets, authorized devices remain below the server list, and push-notification readiness follows the authorized-device section. Each authorized-device row opens a detail sheet and shows its paired server's connection status instead of a redundant disclosure chevron; after explicitly focusing its server, a supervised `ios-device-install.v2` Gateway can configure a validated source checkout and request the fixed development-signed LocalDevice overwrite install for that authorized device. The Mac reuses an owner-only exact physical binding or admits only the sole Developer Mode physical iOS device, so multiple eligible targets fail closed without a target picker or display-name inference. Manual acceptance must cover unavailable/multiple target discovery, Developer Mode disabled, signing/provisioning failure, Stable protocol mismatch, background socket replacement during the build, successful app relaunch without data or Keychain reset, reconnect recovery of terminal install status, emerald sheet dismissal, and stable parent-sheet presentation after the repository browser closes. The UI must never display or retain a CoreDevice identifier. Logs are a separate final top-level Settings destination, so Connections and its detail sheets never fetch or render Gateway log history. The Logs destination performs one bounded Gateway read when opened, merges the app's bounded in-memory iOS response-diagnostic ring, indexes level filters once per admitted load, and renders stable record identities directly through a lazy compact list. Each row keeps action, server/source, colored level text, and timestamp in one leading-aligned metadata line with separators and one shared compact type style; the message remains directly below and no icon column is reserved. Initial and foreground refreshes are structured tasks keyed to a diagnostics-readiness generation that advances only after admitted reconnect or in-place foreground reconciliation completes. An automatic empty result cannot erase a useful visible projection, manual refresh remains available, and loading/empty copy uses Tron typography and surfaces instead of stock placeholders. An actionable invalid-response in-app notification can open Logs directly. Gateway Update status/config decoding is bounded and capability-aware. The live update state sits directly below connection state; lifecycle and restart-drain additions use the same icon/title/detail row structure so long status copy wraps beneath its title instead of competing for a trailing column. Opaque runtime/deployment identities live in a Technical Details sub-sheet, and source configuration is one row whose Configure action reuses the Gateway-backed workspace browser before submitting the selected Mac path through lifecycle admission and command receipts. Update and rollback confirmations remain separate full-width actions outside the configuration container. Stable on 9847 and local Debug on 9848 remain separately paired profiles with their own persisted credentials. Pairing, initial hello, reconnect hello, and authenticated `system.info` require an asserted `stable`/`dev` channel matching that profile; missing, malformed, or endpoint-mismatched identities fail closed. A planned Debug `system.stopping` event uses the existing immediate reconnect path with the same profile endpoint and token, then installs the replacement runtime epoch and authoritative projections without replaying an accepted prompt. A Debug-origin candidate exposes the confirmed **Promote Debug Gateway to Stable** action only when its focused Stable-channel status carries an available exact version, lowercase SHA-256 fingerprint, source revision, tested Debug runtime epoch, and candidate runtime epoch whose provenance matches the verified candidate identity; the confirmation pins the immutable version and fingerprint. The separate **Rebuild Gateway from Source** maintenance action is user-initiated only, requires a valid configured source root, and sends source mode only; repository agents may prepare and validate the change but must not press the action or submit its RPC. Its copy does not imply a pending update, and generic or unpinned artifact candidates are never promoted automatically. The dashboard server filter keeps multi-selection separate from ordering: the default groups by project/server, while Recent Activity renders active sessions first with stable active-period ordering, followed by reverse-chronological history with project/server context beneath each row. The filter action lives in the top toolbar; the bottom-leading search action presents a keyboard-avoiding overlay above the unchanged dashboard controls and dismisses on close, focus loss, or a downward swipe. Shared model/session search fields hide placeholder copy while focused and use a regular, more opaque tinted glass treatment. Model search keeps its parent sheet non-dismissible while active and lets keyboard dismissal settle before removing the field, so its close action cannot fall through into sheet dismissal. Its selection guidance belongs in a compact header block directly below the Servers section label, with stronger separation above that block, and uses the shared 11-point secondary-description scale matching the other adjusted sheet descriptions. The selected ordering and bounded server-ID selection are stored together in a versioned local UI preference and restored when the app launches; transient search text is never persisted. Empty startup source projections retain the saved selection until a non-empty authoritative server set can prune removed identities without corrupting the all-servers sentinel. Project headers show the project folder in bold monospace with the server name as a right-aligned secondary monospace label. The dashboard settings overview uses an eager stack so the Gateway Import destination is materialized with the initial sheet; project-scoped settings intentionally omit that dashboard-only action.
Resolved package presentation stays constant-depth: the overview counts the four known resource arrays, leads with ready/disabled totals, and progressively discloses friendly per-type names and source/scope descriptions. Paths, metadata, additive unknown categories, and the complete protocol value remain available only from nested Technical JSON sheets instead of becoming the default table. Package reload
refreshes the inventory and update projection together: SwiftUI’s structured `.task(id:)` owns and awaits automatic
refresh, target/invalidation changes reject stale completions, and confirmed mutation reloads have priority over
ordinary refresh. Installation controls live directly in a medium/large progressive sheet as dense source and scope sections rather than inside a second settings-group container. Explicit Save toolbars in Models
and Defaults, Runtime Behavior, Resource Locations, and Custom Models are disabled against the installed baseline.
The three scoped settings sheets seed each target baseline only once and compare the value currently presented by
SwiftUI directly with it, so refresh, enablement, and late-response admission do not wait for a subsequent `onChange`
callback or accidentally adopt an edit as a new baseline; a successful exact-draft save installs the resulting
baseline and disables Save again, while edits made during the request stay dirty.
Custom-model field bindings advance their revision in the same setter transaction and apply the same exact-revision
completion rule. Every textual toolbar action uses the shared system-weight label with a leading SF Symbol (or its
in-progress indicator); toolbar typography does not impose bold, semibold, or medium text. The dashboard Settings
action is deliberately icon-only and retains an explicit accessibility label. Technical-detail sheets use the shared
`TronTechnicalMetadataSection`/`TronTechnicalSectionLabel` treatment and drill into bounded JSON through
`TronTechnicalJSONRow` instead of inventing sheet-local metadata cards or displaying large raw payloads inline. Custom provider editors keep their three dense text fields together before the API-format row
and use the standard settings-group header treatment. Provider and model catalogs use the shared
`ModelDisplayFormatting` projections everywhere they are shown; canonical IDs remain unchanged for
search, persistence, and mutation while labels use product casing such as “OpenAI Codex / GPT 5.6 Luna”.
New Session quick selectors carry both server and project identity; source-control choices use a vertically centered selection-symbol column. When a selected workspace requires a trust decision, an animated **Project Trust** configuration row presents it as untrusted and opens a balanced Cancel/Trust confirmation; creating without trusting first records the blocked decision so the session opens without project resources. Session creation is sent through the confirmed `session.create` mutation, and Gateway owns Git worktree creation, trust propagation, and rollback. Dashboard server filters use the shared trailing checkmark confirmation action, and the opening composer dims its placeholder until authoritative transcript readiness without disabling local drafting. Project Resources normalizes producer whitespace before display, caps overview subtitles to one line, and keeps detailed tool/resource content in the tapped detail sheet so scrolling remains lightweight. Provider settings cards and Custom Models provider rows use the same centered 22-point leading icon column and 14-point leading inset, with vertically centered icons and leading-aligned text; custom provider summaries reserve the trailing menu width and are produced by a lazy provider stack. Runtime provider rows never use a local action menu or an icon beside their trailing Connect/Configure text: either action opens one medium/large standardized sheet at normal inline-navigation content height. The sheet presents every advertised API-key/login method, replacement-account actions, and credential clearing while retaining exact operation-keyed auth cancellation; API-key prompts install an inline header, credential field, and value-gated Save action in that same sheet rather than opening another page. The Manage Session workspace path
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
later catalog refresh. `ComposerDraftStoreTests` own version/bounds/corruption cleanup, separate exact-byte payloads, SHA-256 profile/session paths, profile deletion, and the 24-draft disk LRU. `ComposerDraftAppLifecycleTests` owns the background checkpoint boundary. `ComposerDraftCoordinatorTests` own bounded profile/session text and attachment retention across coordinator restart,
exact presentation mounting/revocation/remount re-upload, deterministic inactive-draft LRU, one-time route seeding,
independent barrier-controlled out-of-order uploads with exact byte/name/MIME capture, cancellation cleanup,
editor policy/use/keep disposition, confirmed/failure/uncertain submission semantics, A → B → A rejection,
and nested façade observation. `SessionShellProfileRouteOwnerTests` prove that selected-profile round trips
synchronously revoke and pop the production route. AppModel performance tests retain the real
`session.prompt` integration proof, post-mount admission-failure cleanup, attachment removal only after
confirmation, and direct share prompts that never inherit staged composer IDs. Run the focused mutation, import, and
composer owners with:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionMutationServiceTests \
  -only-testing:TronMobileTests/SessionImportCoordinatorTests \
  -only-testing:TronMobileTests/ComposerDraftStoreTests \
  -only-testing:TronMobileTests/ComposerDraftCoordinatorTests \
  -only-testing:TronMobileTests/ComposerDraftAppLifecycleTests \
  -only-testing:TronMobileTests/SessionShellProfileRouteOwnerTests \
  -only-testing:TronMobileTests/MultilineComposerTextViewTests
```

`SessionEventSynchronizerTests` own the composed intent-keyed shared outcome and
event-quarantine invariants; `SessionSnapshotEventAdmissionTests` own the
live full-snapshot matrix (authority, route identity, runtime, duplicate/stale/exact-next/gap
cursor). Synchronizer coverage rejects a quarantined route/payload mismatch before baseline
publication, while the AppModel suites prove snapshots/tokens remain provisional through
acknowledgement, unmounted or synchronously revoked hints cannot create/advance state, and stale routes close their exact provisional token. The same suite proves a mounted route wins over divergent
dashboard selection, dashboard synchronization cannot open an inferred transcript, mounted reconnect restores
the exact route, secondary reads cannot create hidden subscriptions, and create/fork return navigation
identity without opening it implicitly. Both routes remain bound to the admitting Gateway profile and
lifecycle. Fork fences the exact source presentation before transport so no new context/tree read can race
Pi's rekey; failure releases that fence, while canonical success revokes only the captured generation and
posts one app-scoped success notice. It then advances the route only after the confirmation, entry/history,
and context dismissal owners each retire their presentation lease. The dashboard shell never replaces one
non-`nil` NavigationStack item with another: it clears the source destination without animation, waits for that
exact chat surface token to retire, and only then mounts the fork. This guarantees a fresh chat task identity and
reactivates dashboard catalog publication during the handoff; authoritative catalog convergence runs independently.
Fork confirmation preserves the selected entry by default, while the explicit edit-prompt choice excludes
that prompt and restores its text to the composer. Dashboard fork markers live in the trailing status cluster,
immediately before elapsed activity, so the title column remains aligned across ordinary and forked rows.
Create additionally returns before any dashboard catalog read; the
Gateway-owned empty runtime row and `session.listChanged` own projection convergence. The row may disappear after idle retirement or
Gateway restart when Pi never persisted content. `DashboardStateOwnerTests` prove typed latest-load and
navigation admission, monotonic live-summary overlays, unknown-row discovery, bounded dirty coalescing,
safe cache/disconnect projection, and removal, while the bounded in-app notification tests enforce the single AppModel-owned center, eight-entry, 4 KiB-message, and 16 KiB-total
budgets plus keyed progress coalescing, non-extending unkeyed duplicates, passive single-card expiry, and actionable persistence. Their presentation guard also pins one scene-level pass-through notice window, toolbar-center discovery, opaque-backed glass, and bidirectional horizontal dismissal while forbidding sheet/content blur modifiers from reacquiring the render surface. `ComposerDraftCoordinatorTests` prove profile/session draft
isolation and same-session-generation isolation for disposable attachment/editor/submission state;
event tests prove departing routes are excluded from share admission. Compatible synchronization callers now share one outcome without timing polls;
each actual authoritative open/resync attempt retains its own interval.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionPresentationStoreTests \
  -only-testing:TronMobileTests/AppModelPerformanceSignpostTests
```

Camera boundary tests inject authorization and capture-session providers into
`CameraModel`; QR boundary tests use the same authorization seam plus a scanner-specific
session provider. They never invoke camera hardware or replace AVFoundation in production.
Keep provider callbacks MainActor-bound and keep the two unchecked Sendable AVFoundation
envelopes limited to the photo provider's serial queue boundary. The QR permission task
must recheck cancellation before configuration. Camera setup, capture, torch, and
permission callbacks carry lifecycle/configuration identity so dismissal cannot publish late state.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/CameraBoundaryTests \
  -only-testing:TronMobileTests/QRCodeScannerBoundaryTests
```

Share boundary tests cover provider-fragment reduction, prompt composition, and the
single-value app-group store without loading extension UI. `PrivacyManifestTests` verify
both source manifests and both built bundles. The separate archive check is read-only and
must run after a maintainer-created archive; it never archives, exports, or uploads.

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
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
transport-detached prompt delivery with stable-operation resume, stale operation responses that close
without surfacing a broker not-found error, profile-retirement rejection across parallel reads and
pagination, operation-keyed prompt/event state, bounded event-before-response quarantine and promotion,
manual-prompt versus callback-relay routing, stale response/cancellation safety, exact-target completion
refresh, receipt-backed forced refresh/logout, event-only invalidation, and nested façade observation.
`ProviderOAuthBrowserTests` owns callback policy and listener construction: HTTPS authorization
admission, exact provider/Gateway loopback descriptor agreement, IPv4/IPv6 loopback limits, simultaneous
fixed-port POSIX binding to explicit loopback addresses, bounded GET parsing, encoded query
preservation, and rejection of external destinations, bodies, absolute targets, wrong routes, fragments,
and missing authorization results. Hosted tests exercise the real one-shot loopback socket with fragmented
requests, exclusive ownership, and repeated cancellation/rebind verification, but do not open
`ASWebAuthenticationSession` or a provider login.
Before release, perform a physical-device smoke against a disposable provider account: confirm the
system authentication browser closes through the iPhone loopback handoff for Anthropic/OpenAI/OpenRouter,
Radius completes through the query-only relay, temporary background/network replacement resumes the same
operation, the selected Mac's canonical Pi `auth.json` becomes configured, and no callback query or token
appears in Gateway/iOS logs. Never add real callback values or credentials to fixtures.
`PackageConfigurationCoordinatorTests` owns typed target isolation,
newest list/check admission, admitted-error handling, event-only invalidation, closed mutation
wires and timeouts, stable receipt replay, pre-confirmation marker stability, admitted-versus-stale
mutation failures, same-profile uncertainty preservation, exact-target reload, profile retirement,
and nested façade observation. `CustomModelConfigurationCoordinatorTests` owns newest read and
mutation admission, validate-before-put ordering, no-put failure/retirement, current-versus-retired
validation/put errors, stable put receipts, A → B → A rejection, lifecycle-bound restart failures,
cancellation-safe presentation, nested observation, and exact draft-revision save admission.
`GatewayDiagnosticsServiceTests` own the read-only New Session boundary for exact-path `git.inspect`
and bounded `system.logs` requests, typed projection, malformed-record skipping, newest-first ordering,
collision-qualified row identity, and foreground merge policy. The Logs destination uses AppModel's
profile-targeted diagnostics façade; it never reaches `model.client`. AppModel publishes diagnostics
readiness only after admitted initial, reconnect, or in-place foreground projection completion, and
background retirement clears readiness before the transport changes. The visible sheet keys one
structured refresh to that completion generation, generation-gates stale results, retains its last
useful bounded rows on an automatic empty read, and merges fresh profiles with retained rows for any
profile whose reconnect-time diagnostics request failed. Manual refresh may admit a confirmed empty
successful result. DTO fields and per-profile failure metadata remain in the service/state boundary,
while log level color, compact metadata/date formatting, and Tron-styled loading/empty presentation remain in
the dedicated logs UI. `WorkspaceInspectionServiceTests` own the separate session-bound
`workspace-inspector.v1` wire, the capability-gated `workspace-history-diff.v1` commit/file request,
and pre-materialization collection limits. Manage Session never falls
back to `git.inspect`: its tappable Current Branch row and Files/Changes/History sheet read only
through the established session subscription. `WorkspaceInspectorOwner` generation-gates inspection,
directory navigation, and tip-pinned history independently, overlaps initial inspection/list reads, preserves
useful content through transient refresh failure, keeps established header/list geometry free of polling and
detail-load indicators, and cancels every flight on dismissal. Owner coverage proves late-response rejection,
atomic failed navigation, completed empty history, and the 400-commit retention ceiling. Service coverage keeps
bounded decoding off-main, while presentation guards require cached path indexes/history rows and off-main diff
preparation. Physical acceptance must switch branches and
edit/stage/rename/delete/create files while the sheet is open, inspect text, Markdown, image, PDF,
binary, and oversized files, verify staged/unstaged/untracked/conflicted and historical commit-file diffs,
page both history scopes, then repeat across coverage, background, reconnect, and Dynamic Type without stale branch or
path publication. `ChatCompactPillTests.workspaceHistoryGraph` owns deterministic fork/merge lane continuity;
presentation guards keep the workspace header, tabs, and active collection under one soft-edge scroll owner and
require file preview surfaces to remain large-only.
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
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SettingsTrustCoordinatorTests \
  -only-testing:TronMobileTests/ProviderAuthCoordinatorTests \
  -only-testing:TronMobileTests/ProviderOAuthBrowserTests \
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
  xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
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
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
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
ID. The UIKit transcript parity renderer consumes the same installed physical-row payload as SwiftUI:
message parts retain Markdown blocks and thinking tails, lifecycle/tool/notification rows retain their
compact state and detail callbacks, and attachment chips use the existing loader's cache and single-flight
authority. UIKit cells retain row-local Markdown/media children for payload updates and never own transcript
ordering, canonical data, or viewport offsets. UIKit admission rejects stale versions monotonically and
reports stale/cancelled/failure distinctly; its installed source-window fact exposes one earlier-message
affordance and one load-earlier action without a paging owner. Gesture updates restore measured semantic
row anchors and pixel offsets, including nearest-ordinal fallback after removal. An explicit activity
lease pauses streaming/tool/media tasks and indicators when covered, inactive, offscreen, or replaced;
reuse resets every Markdown/stream/media/tool child. Custom messages use the existing inbound producer
policy and trailing action semantics. Composer focus is authoritative and its bounded send handoff
releases rejected revisions for retry while suppressing duplicate accepted sends. Tests own exact 192-pixel oriented downsampling, duplicate single-flight behavior, one shared
preparation slot, the 32-flight ceiling, 64-item and 4 MiB decoded LRU eviction, transport-level 25 MiB
response admission, stale-identity and late-publication rejection, uncached one-at-a-time full previews,
and app-lifetime memory-pressure cleanup. Images and files share that single exact preview lease/priority slot;
file bytes are fetched only after sheet intent and are never cached. The production row retains its 64-point
loading/retry surface. Photos open the existing medium preview immediately from a nonoptional thumbnail-backed
item route while full resolution loads. Every file chip opens a nonconditional loading/content/unavailable sheet:
Markdown uses the immutable document renderer, plain/code text uses native selectable TextKit, Unicode-safe
rendering is capped at the existing 320,000-byte source bound with explicit omission, and PDFKit provides native
multi-page scrolling up to the 512-page safety cap. Live composer files retain exact bytes within the existing
25 MiB aggregate limit; frozen handoff strips them before queued/canonical settlement. Physical pixel and
peak-memory calibration remains required. The test-only `ChatUIKitParityHarnessTests` mounts the
native collection view and composer against immutable UIKit inputs, and checks the legal offset and
nonblank intersection across tail-follow, detached streaming growth/shrink, and native-drag updates.
It is intentionally not a production feature flag or a replacement for final device/pixel parity.

`ChatView` is the lifecycle/composition root. `ChatTranscriptScrollView` owns one bounded `LazyVStack`, one mode-qualified native size-change anchor, semantic frames, and hosted evidence. Its one physical `ForEach` spans committed, live/runtime, local lifecycle, and authoritative queue rows while `ChatCommittedLedger` and equatable row payloads preserve frozen-history performance. Native anchoring owns routine size and payload changes. A genuinely new lazy physical row may receive one disabled command targeting the stable tail sentinel; the token-owned target is retained until fresh layout-epoch semantic geometry proves that exact row mounted and a newer aligned physical marker proves the viewport, rather than being released by a one-frame timer. Rows inserted before an authoritative queue tail, runtime notifications, and local lifecycle rows use the same bounded physical-spine search. Explicit retained pinned resume re-enters the marker positioning gate; retained detached readers remain anchored and are never repinned. Every installed projection, including lifecycle-only and compaction/tool settlement changes, advances the layout epoch so delayed marker callbacks cannot prove a replacement tree. Impossible underflow offsets are rejected, and forced underflow height alone cannot certify opening without a visible current-layout marker. Neither path targets a changing row ID, eagerly realizes transcript history, or creates a recurring follow loop. Prompt aliases are exact-causal, one-to-one, and fail closed; tool rows may additionally retain one unambiguous prior physical host across late finalized-group metadata while canonical semantic IDs continue to own geometry, anchoring, entrance evidence, and hosted frame samples. The row spine is a zero-copy random-access adapter with an O(1) no-alias admission path. Its native geometry feeds the coordinator directly instead of invalidating root view state; `ChatComposerView` is value/intent driven inside the root's single bottom inset; `ChatRoutes` owns modal modifiers; and `ChatSessionPresentation` groups disposable opening, import, queue-deferral, route, and handoff-ledger state without copying canonical session facts. `ChatSessionPresentationTests` require cold reopen to discard those local receipts/routes, require suspension to cancel import/picker targets while retaining compatible presentation authority, and pin exact-generation opening deadlines plus one-shot post-dismiss fork navigation. The complete open/synchronize/projection/ready transaction has a 30-second outer deadline; timeout cancels owned transcript and scroll work and presents an explicit retry state instead of leaving an ownerless opening surface. Its canceled task lease remains installed until the operation actually drains, so retry and foreground resume can join it but can never overlap another `session.open`. `ChatViewScrollHarnessTests` mount the actual `ChatView`, bounded lazy transcript stack, composer inset, and native `UIScrollView` in a fixed hosted window. The aggregate composer host stays mounted inside that one inset and measures natural content before its bottom-aligned frame. Editor-only height changes install atomically for TextKit caret ownership; attachment, selected-skill, and command/skill-result identity changes receive one value-scoped smooth host-height transition. Pending attachment chips use a presentation-owned ordered projection: batch additions reveal in selection order with a 40 ms stagger and a centered 50-to-100 percent scale/fade, removal reverses that same transform, retained siblings reflow on the same smooth transaction, and the final removal still collapses the bottom-aligned host so content reclaims the strip height. Submission transport is scope-owned across route generations and is projected, never replayed, on remount. Submission and morph motion retain their explicit layout generation. The waiting flight paints the measured composer source immediately, waits for exact destination geometry without a wall-clock race, valid keyboard-settling endpoint changes retarget in place, and a 260 ms smooth curve carries ordinary, steering/follow-up, photo, and file sends without a blank frame or spring tail. Lifecycle-to-canonical header/container collapse and active-to-completed compaction are the only replacement animations admitted through the stable transcript boundary. The physical row host has no container-level content transition; tool capsules animate only their own shallow value state so rapid parallel groups cannot leave overlapping snapshot copies. Newly admitted rows use one measured-height reveal so existing content moves continuously; its vertical admission clip expands inside a layout-neutral effect gutter and is removed after admission, preserving prompt shadows and giving settled transcript tool chips an unconstrained native press-and-drag region. All three paths respect Reduce Motion and add no second inset, root geometry loop, or scroll command. The multiline composer uses pure synchronous capped representable fitting plus post-layout TextKit overflow/caret reconciliation. Nil, nonfinite, and nonpositive proposed or resolved widths fail closed; internal scrolling enters only above the cap plus 0.5 point and remains owned until below the cap minus 0.5 point. Focused tests pin speculative infinity-to-finite measurement, wrapped cap stability, trailing-newline caret visibility, manual-scroll-then-type direction, 9→8 collapse, and inset ownership. Active-turn admission opens one layout generation before grafting one immutable lifecycle row into the current complete installed projection. Viewport submission intent preserves `.pinned` or `.anchored`; focused coordinator/composer/store tests pin native bottom size-change anchoring across streaming, discrete growth, keyboard/composer contraction, retained resume, and manual tail return. Opening, catch-up, semantic restore, and prepend leases remain stronger; direct interaction leaves anchored mode physically unpositioned. Tests also cover detached semantic preservation, direct-interaction cancellation, active-upload rejection/retry, immediate collapse, metadata-only reuse, stale-worker rejection, and snapshot-before-response provisional queue identity without granting canonical settlement. `ChatMorphFlightTests` exercise bounded global-frame admission, lifecycle-derived endpoint uniqueness, missing-frame and Reduce Motion suppression, and idempotent reconciliation/background retirement. `ChatLayoutTransactionTests` distinguish successful settlement from watchdog/background abandonment; abandoned generations cannot release scroll leases, and bounded settlement events preserve every consecutive completed generation when SwiftUI coalesces updates. Device checks must additionally send with text, photos, and files while streaming, then background/foreground and relaunch both active and passive sessions: current canonical rows must appear immediately and no pre-suspension flight may replay. Test-only authority
admission bypasses network I/O without bypassing `AppModel`'s authoritative read
gate. Raw geometry, visible semantic IDs, and row frames are reduced to one latest
sample on each `CADisplayLink` tick; added evidence is aggregate command/frame/count
data only. A maximum-512-row opening case requires the very first ready sample to contain
the exact physical tail marker and latest message in the same plausible native bottom
viewport, so an eventual manual/lazy correction cannot make the test pass. The production
`DisplayFrameScheduler` is a one-shot, cancellation-aware display-link boundary used by
first-ready, frame-gated unrealized-tail correction, and long-distance
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
suffix work across thirty updates of a 10,000-entry text stream. `ChatCommittedLedgerTests` require
streaming and compatible foreground replacement to retain both the committed revision and every
committed row's equatable render identity; the hosted streaming-burst journey also requires the aggregate
committed-history body-evaluation counter to remain unchanged. Canonical append/prepend advance once, while a fresh store
rebuilds identical canonical rows deterministically at revision one. The same suite checks that
foreground entrance suppression remains empty on both retained and cold owners and that hidden thinking
labels appear only on thinking-row preparation slices. This is the active/passive resume contract: both
modes install one complete authoritative commit, live-region replacement never mutates history lineage,
and relaunch has no local entrance or morph receipt to replay. The
gate can delay work but cannot manufacture output or disable production projection semantics.
`ChatTranscriptProjectionKernelTests` characterize raw atoms and the sole global assembler across
barriers, assistant-message tool-run boundaries, canonical call/result joins, orphan results, bootstrap configuration, exact compaction
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
history back to the retained authoritative tail. Opening ownership is one mutually exclusive
`OpeningTailPhase` (`idle`, `positioning`, `positioned`, or `postReveal`). `ChatViewportModeTests`
prove that only explicit takeover, return, catch-up, opening, submission, prepend, and presentation
intents can change durable viewport authority. `ChatScrollCoordinatorTests` assert observable outcomes:
the native bottom size-change anchor absorbs pinned continuous stream/composer/keyboard and existing-row growth with zero app offset writes; a genuinely new lazy physical row owns at most one stable-sentinel materialization lease until fresh current-layout semantic geometry, row-frame-before-request and request-before-row-frame ordering both settle, and burst requests are retained/coalesced, while detached growth remains target-free;
direct return clears catch-up and unread; a foreground topmost chat publishes its exact synchronized
subscription visibility lease before scroll positioning finishes, renews it before expiry, retires it on covering sheets/inactivity/navigation/connection
replacement, and acknowledges later unread summary revisions through the same token-gated absolute read;
bottom rubber-band callbacks remain pinned and keep catch-up
hidden in both geometry/ownership orders, while the same gesture detaches as soon as valid geometry moves
beyond the tail boundary; composer reflow in empty, short, or overflowing pinned content cannot impersonate
the offset-only status-bar retreat; catch-up emits one explicit tail intent, restores unread if interrupted,
and rechecks geometry-first physical settlement when command application arrives so draft authority cannot
remain stranded; retained resets preserve anchoring; opening targets only the exact physical tail; semantic
frames remain bounded; and anchor correction preserves the captured offset. Exact layout-epoch restore
and prepend transactions still require newer semantic and geometry evidence, remain bounded to two
corrections, and retire missing restore evidence after one second. Explicit paging supersedes a stale
semantic-restore command while active opening/catch-up rejects paging; anchorless page work is
session-owned and cancels on suspension. Hosted controls drive the production coordinator/executor and record bounded aggregate
callback, command, frame, and maximum-excursion evidence.
Hosted streaming bursts must install only their newest exact source while detached composer/viewport work
remains writable and creates no projection work. Canonical/live tool handoff tests also assert that adjacent equal nonempty producer segments compose into one display-only row with the first physical ID, canonical payload precedence, incremented membership, and any-member-running state; barriers or missing/conflicting segments remain separate. `ChatCompactPillTests` own intrinsic-width trailing placement for short prompts, the 364-point
long-prompt bound, intrinsic-width glass selection, equal user-prompt vertical padding, logical-leading
line alignment, agent-matched Dynamic Type body sizing, shared prompt/queue Liquid Glass geometry, and
flat/detail material policy. `ChatContentTransitionTests` own role
classification, trailing composer-edge prompt/queue motion, aligned activity motion, and the
identity transform required by Reduce Motion. Hosted scroll tests remain the authority that these
visual transforms do not grant detached readers automatic writes or replay same-ID entrances. Lifecycle entrance receipts live in the projection owner rather than lazy row state, survive memory-pressure text eviction, and are pruned with their installed outgoing/pending/queue identities.
`GatewayProtocolContractTests`, `SharedProtocolFixtureTests`, and
`SessionMutationServiceTests` cover revisioned queue projection and replacement commands.
`QueuedMessagePresentationTests` own capability/field admission for editing, prove that advancing
transcript projection tags do not revoke an installed queue card's authority, and cover exact-token
settlement/stale-completion immunity plus the loading evidence policy. Queue controls remain
owned by the installed commit's queue revision/items plus its exact Gateway capability fact, never generic transcript
build lag. The earlier pill remains loading from explicit admission through paging, projection installation,
and anchored (or unanchored) settlement; presentation retirement cancels its local owner. Presentation guards
retain intrinsic cards capped at the user-prompt bound, full-shape whole-card interactive Liquid Glass,
leading-toolbar removal, an explicit legacy lock, and Tron surfaces instead of stock forms.
Native bottom evidence compares `ScrollGeometry.visibleRect.maxY` with the physical
content edge (`contentSize.height + contentInsets.bottom`); the hosted native helper retains signed
UIKit offset evidence so past-bottom overshoot cannot pass as zero distance. Pinned structural shrink
and viewport expansion are handled by the one native bottom size-change anchor; ordinary pinned mode
keeps `ScrollPosition` target-free, while anchored readers select top retention and remain native-owned.
Explicit command targets remain installed until exact opening/catch-up/semantic settlement and are
released on the next frame only by the applied token; no deferred unqualified ScrollPosition reset may
run across a send or keyboard transaction. A send retires a still-applied app target before its first
layout mutation. Short-content alignment is always bottom-owned by the native anchor; blank space remains above the physical tail.
Editor-only composer height changes install atomically. Attachment, selected-skill, and
resource-result identity changes use one value-scoped 240 ms smooth host-height transition with no
root geometry feedback or scroll command; Reduce Motion makes that transition atomic. With the
keyboard visible, the panel list caps at three
internally scrolling rows and the native editor at four visible lines. Spatial prompt morphs are clipped and admitted
only for compact measured prompts; long prompts use the bounded outgoing-row entrance.
A mounted retained snapshot remains readable during reconnect, but command
admission requires the exact live subscription; queue command confirmations trigger
mounted synchronization before queue controls retire.
The obsolete visibility modifier is removed; the native SwiftUI geometry modifier still
reports a multiple-update-per-frame diagnostic in hosted runs and remains a physical checkpoint.

### Viewport test migration matrix

The pre-pinning coordinator suite contained 81 cases. The 50 observable Group A cases keep
their original function names and now assert outcomes against native pinning: detached semantic
restore (12); shrink/overshoot ownership (23–25); detached composer and direct-return behavior
(32–34, 36, 38–40, 42–44); catch-up (46–49); opening (50–63); Reduce Motion and prepend
(64–77); and growth/row motion (78–81). The 31 deleted command-arbitration mechanism cases
have these explicit observable replacements:

| Retired tests | Observable replacement |
|---|---|
| `pinnedGrowthCoalesces` through `pinnedProjectionShorteningCorrectsPhysicalTail` (1–7), `appliedAutomaticTailDoesNotBlockShrinkCorrection` through `lifecycleGraftPreservesAuthoritativeMutation` (9–11) | `pinnedNativeEdgeEliminatesFollowCommandStream`, `stickyModeHasNoOffsetCommandDestination` — native bottom size-change anchoring owns continuous and discrete pinned growth with no app offset write. |
| `projectionShorteningDefersToDirectTakeover` (8) | `directTakeoverCancelsPendingSemanticRestore` — direct authority leaves anchored mode and no command. |
| `layoutCorrectionGeometryFirstSettlement` (13) | `anchoredRestoreRequiresFreshEvidence` — one semantic correction appears only after both newer semantic and geometry evidence. |
| `interactionCancelsProjectionMutation` through `catchUpCancelsAppliedLayoutBinding` (14–17) | `directTakeoverCancelsPendingSemanticRestore`, `stickyModeHasNoOffsetCommandDestination`, `nativeEdgeStateFollowsModeWithoutOffsetCommand` — takeover/catch-up replace mode; no release-binding command exists. |
| `installedRemovalPreservesContinuousFollow` (18), `continuousGrowthWhileSettling` through `noWriteInsideTolerance` (20–22) | `pinnedNativeBindingEliminatesFollowCommandStream` — native edge retention removes pending-follow arbitration and all ordinary writes. |
| `detachedDiscreteInsertionIsInert` (19) | `stickyModeHasNoOffsetCommandDestination`, `detachedGrowthIsInert` — anchored insertion remains anchored with zero writes. |
| `composerPreservesFreshNativeAuthority` through `geometryFirstComposerTransitionPreservesLocus` (26–31) | `composerMutationsDoNotOwnScrollCommands` — submission/composer/keyboard geometry preserves explicit mode and emits no command. |
| `geometryFirstDetachmentConsumesDirectReturn` (35) | `geometryCannotConsumeExplicitReturn` — only the explicit return intent pins. |
| `nativeVisibleEdgeAdmitsManualTail` (37) | `explicitReturnPinsDespiteStaleGeometry` — return intent wins independently of stale inset arithmetic. |
| `nativePositioningRetainsExplicitEdgeAuthority` (41) | `nativeEdgeStateFollowsModeWithoutOffsetCommand` — mode directly selects native edge authority without an offset command. |
| `interactionCancelsPendingFollow` (45) | `directTakeoverCancelsPendingAutomaticWork` plus the coordinator opening/catch-up/restore interruption cases — direct takeover wins synchronously and leaves no write. |

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
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
the provisioned app identity with `HOSTED_TEST` for its run/test actions; it has no
archive action, so hosted hooks cannot enter a release archive. Run the test only at
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
user-oriented Agent Context, and the History-owned runtime summary. Focused presentation policy tests separately pin stable export-row identity and single-row progress ownership.
`SessionExportArtifactStoreTests` owns archive-specific item/aggregate/count/reservation/age/protection policy, while
`BoundedHTTPFileTransportTests` owns reservation-backed, resumable file transfer and exact byte ceilings. Gateway integration fixtures cross the legacy
25 MiB boundary and exercise running-session JSONL/HTML cuts without placing those bytes in iOS test memory.
The end-to-end path also
relaunches at accessibility XXXL to verify standard SwiftUI controls that
XCTest's simulated Dynamic Type audit misclassifies. Any audit suppression must
name one exact element, have a retained rendered checkpoint, and have a separate
real-size assertion; category-wide suppression is not allowed.

Simulator screenshots are deterministic regression artifacts, not the final
system-chrome authority. A physical install is protocol-gated before
`devicectl`: the default Stable target requires a matching verified installed
Mac app, while an isolated source-built Debug Gateway requires the explicit
`TRON_IOS_GATEWAY_PROTOCOL_TARGET=source` helper input. For a protocol bump,
complete and verify the Mac Release reinstall first; never widen the wire range
or install iOS into a deterministic reconnect loop. At broad presentation
checkpoints, build the actual `Tron Device` `LocalDevice` app for the connected
iOS 27 device, install it without removing its Keychain pairing, launch it
against the selected verified gateway, and capture chat, dashboard/setup,
Manage Session, tool detail, and
settings screens with `devicectl`. Terminal lifecycle checkpoints additionally verify
that the signed app installs and launches on the connected device after the focused suites
pass; interactive PTY input remains a manual device check. Compare captures to the historical
references before declaring parity. A signed install, launch, and screenshot are
required together because default toolbar Liquid Glass can differ materially
between the simulator and physical hardware. Sheet checkpoints must fling-scroll
Agent Context, Project Resources, Session History, Runtime Behavior, Providers,
and model selection; dense rows must retain static tinted geometry without visible
material churn. Open a large instructions/JSON document and verify immediate native
scrolling. Confirmation checkpoints verify grey cancellation text, a short trailing
toolbar action, and a sentence-length action in the Liquid Glass container below
content at both default and accessibility Dynamic Type sizes. Dashboard swipe checks verify emerald Rename and neutral-gray Mark Read and Mark Unread actions. Open Rename from both a dashboard row and Manage Session: the centered trailing circle-x must clear the field, remain fixed while a long name scrolls beneath it, and keep Save disabled for empty or whitespace-only input. Dashboard deletion additionally swipes, cancels, and repeats against the same canonical row; the row must remain mounted until confirmation and no delete request may be sent on cancellation. A confirmed mutation response or replayed completion receipt removes the selected projection immediately, and the authoritative catalog event converges every connected dashboard without view-local row suppression or navigating away and back. Chat checkpoints must also verify
trailing alignment for user turns, historical transcript/tool insertion motion,
the Settings gear in the chat toolbar, and the context ring at the trailing edge of an empty idle composer. Resume a cold session and verify that the ring is mounted immediately at zero, visibly disabled while loading, then animates once to the authoritative percentage without changing in-bar geometry; Reduce Motion must update it without the spring. Also verify the nonstructural short bottom blur at default running state, its background-layer
movement between the device-bottom inset and beneath the keyboard's rounded top corners, static subtle emerald under Reduce Motion,
retained compact rows for custom/compaction/retry detail, and emerald toolbar/sheet actions. Physical chat spacing acceptance additionally checks that
a one-visual-line prompt has intrinsic height, sent photo/file chips stay above and outside prompt glass,
tool pills retain six-point vertical insets, use the shared metadata-pill 13-point leading icon/pulse and five-point label gap, and avoid a 44-point label minimum; attachment/context/send visuals share the 16-point metric inside 40-point targets,
elapsed timing hugs its intrinsic width, and a pending photo's 22-point remove
circle sits half outside the 64-point preview within a 30-point target centered on its top-trailing corner.
Active-chat reliability checks must advance a desired completion before the displayed running tool receives
geometry and verify that the running chip still reveals exactly once. Submission-to-pending-to-canonical prompts
retain one mounted visual handoff, submitted attachment chips leave the composer before the transcript replacement,
and attachment-only prompts reconcile by attachment metadata. Streaming assistant settlement and runtime-to-canonical
tool grouping retain their visual row identities. Run at least fifteen sequential tool-only assistant messages while prior runtime states remain retained: exact finalized producer groups carrying one equal Gateway-owned `toolSegmentId` must remain independently indexed inside one consecutive display run, its first group must keep the physical chip identity, and foreground catch-up must match continuous delivery without appending phantom rows. Repeat with a different or missing segment ID and verify the calls remain separate. Pressing Stop must not be required to restore grouping. Agent text and thinking traces reveal only newly admitted words while
keeping full layout geometry stable; reconnecting to a long stream catches up instead of replaying the backlog, and
completion reveals the full source without a flash. Thinking-line projection normalizes whitespace without adding or replacing terminal punctuation, so only punctuation supplied by the source is rendered. Thinking traces remain one-line natural height until they
exceed four measured lines, then show only their latest four lines without scrolling; the overflow sheet is titled **Thinking**, and the oldest visible line fades
at the top to signal earlier content. Both the growing viewport and the capped tail offset use one short row-local growth animation, while Reduce Motion installs them directly. Tapping the overflow opens the full trace sheet, which continues updating during
streaming. The sheet uses the shared Tron title/top-blur/toolbar
chrome with no drag handle. The same rendered tool/group row stays after non-tool streaming
across running-to-completed updates, retains at most one installed-identity-owned tail settlement while
pinned, uses one coordinated smooth viewport follow for a newly admitted transcript tool chip, and aggregate
**N tools** sheets render each invocation as a lazy full-width summary row with centered lifecycle status,
full-width request context below its label, and at most the newest two nonempty readable output lines. The
primary value fades at its bottom edge when more follows, while bounded result tails fade at the top instead
of adding an amber warning line. The row preserves a surviving semantic anchor while detached and emits no unowned automatic write for ordinary
shrink. If settlement shortens content beneath a released pinned offset, verify exactly one physical-tail
clamp; a detached or directly owned reader receives none. Verify a tool entrance has one correlated chip
reveal and viewport command rather than competing writes. The stable transcript boundary suppresses ambient animation only when the installed projection identity changes; it does not rewrite either the discrete Liquid Glass touch-down transaction or subsequent continuous direct-manipulation updates. Legacy and consolidated tool chips, plus detail-bearing compact notification pills, use native interactive Liquid Glass as their only touch-response owner and handle taps on that visible surface with explicit button accessibility semantics rather than a second `Button` press phase; verify initial contact, lateral drag, release, and morph remain fluid without an immediate stacked zoom or custom scale effect.
Tool-detail checkpoints open read, edit, bash, and one unknown/extension call at the medium detent: verify the compact status/metadata chips for individual details, and verify aggregate **N tools** sheets show lazy full-width rows and separate **In progress**/**Completed** status,
secondary-plus-accent path, faithful single-change diff glance, word-preserving wrapped bash commands in
the smaller code size, and centered title icons for command/file sheets with no duplicate icon in their
primary value container. Edit results must precede any View Changes action. Verify the
high-signal generic summary and larger live result are visible before protocol fields. A bounded command must not add an amber completeness row to the primary sheet. Pull one single-change sheet to large
and confirm its full bounded diff appears in place; separately verify multiple edits, extra header-only/binary
files, header-light multi-file patches, and malformed or combined patch hunks show only the focused Changes
row and dedicated Changes sub-sheet. Confirm that destination retains its existing nested scrolling and chip layout
while the diff container uses the static scroll surface rather than Liquid Glass. At an Accessibility Dynamic Type size, confirm every status, metadata,
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
a nonempty focused composer, open the native attachment menu, verify the keyboard remains visible before and after choosing a destination, verify its
option symbols are emerald while text retains native system styling, and activate camera, photos, files, Add Skills,
and Add Commands on the first option tap. Record the command/skill panel frame by frame: its material must reveal upward on the same continuous height curve that reduces the transcript viewport, with no full-size flash, delayed chat jump, or second settle. Rapid open/filter/dismiss retargets must continue from the current presentation; dismissal returns downward toward the composer, and a detached reader's visible message must not move to the tail. Verify `@` opens the cyan skill glass, query typing filters without caret
jumps, selection removes only the active token and places one tool-height removable skill chip below photo/file chips, and
a newer skill replaces it. Picker rows use compact icon circles and friendly bold titles. Both the row info action
and selected chip open the same medium-first titled detail sheet, which shows description, exact invocation,
resource type/source/scope/origin/path, argument hint, byte/truncation facts, and the lazily fetched bounded source
content. Markdown front matter already projected as title/description is hidden from the body, while malformed
front matter and extension source fail closed to exact content. The body uses the static scroll surface shared by
provider rows rather than Liquid Glass. Verify `/` at the leading command boundary opens the purple command glass, selection
completes editable command text with a trailing space, and deleting either active trigger dismisses its picker.
Producer-triggered extension/subagent session messages remain one tool-height status row with a bold owner title,
icon, status, and duration when supplied; tapping retains the complete message, provenance, and payload sheet.
Under Reduce Motion picker height installs without spatial motion; with VoiceOver, picker rows, info controls, and
skill removal are separately reachable. Begin an attachment upload and verify Send disables; a stale send action must retain text and skill, then retry exactly once after upload completion. The 40-point plus control and native menu appearance/order must remain
unchanged. Terminal checkpoints must exercise
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
`Tron Device` `LocalDevice` build enables its guarded private `CAFilter`
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

## Push notification release configuration

Pi's `agent_settled` lifecycle event owns automatic completion alerts. Separately, every Gateway-admitted semantic interaction owns one fixed input-needed alert; the Gateway suppresses it when the exact session already has a current token-bound visible-presentation lease, matching completion-alert foreground behavior. Both flows carry the exact machine/session route, while completion alerts additionally use the bounded session title and fixed “finished responding” body. A notification tap resolves the paired owner and joins an existing same-profile foreground reconnect once its exact event-enabled transport is active; it never replaces that reconnect or waits for provider, settings, device, terminal, mounted-chat, or paginated dashboard reconciliation. The admitted payload routes directly to canonical `session.open`, which owns existence and authorization. The mounted chat remains visible during preparation, an exact same-route tap stays mounted, and only a different target performs the smooth dashboard pop and chat push. Reduce Motion removes the spatial transition. Background and cold-launch taps remain in memory until the SwiftUI navigation owner is installed, and activation/lifecycle generations prevent stale work from committing after a newer transition.

Settings owns the notification entry point: verify the leading bell changes to `bell.badge.fill` when any paired Gateway reports unread inbox rows and VoiceOver announces the aggregate count. The Notifications sheet must retain standard title/Done chrome, top blur, medium/large detents, a directly mounted All/Unread control with no redundant outer card or Inbox label, Tron-typography empty states for both filters, newest-first glass cards, mark-one/mark-all read behavior, profile labels, and detail-to-chat routing. Reconnect or relaunch may show the bounded cached projection, but Gateway list/read truth must replace it; never infer unread state from APNs timestamps, titles, or session text. Test whole- and fractional-second ordering, profile aggregation, pagination conflict retry, malformed-row rejection, optimistic read rollback through refresh, and APNs request-ID tap admission.

The checked-in build contains no push credential and no user-configurable relay.
The `Test` configuration retains the beta relay route only for hosted fixture
compatibility; it has no real APNs entitlement or delivery lane.
Development and production builds read the public `TRON_PUSH_SERVICE_ORIGIN`
from the repository-canonical maintainer input `config/PushService.xcconfig`;
`Info.plist` and the bundled Mac Gateway embed the same exact HTTPS origin. The
repository currently targets the production Worker; `LocalDevice` therefore
exercises that service's `production-sandbox` route. The distinct named sandbox
Worker is not selected automatically. Testing it requires deliberately changing
the canonical origin to its public URL, rebuilding and installing the matching
Mac app first, then rebuilding iOS; restore and re-verify the production origin
before a release build. Non-install development builds also tolerate an
intentionally empty local override so the unavailable UI can be tested.
Archive/install validation and Mac payload packaging reject an empty or invalid
origin, and Mac installation verification rejects a selected stable payload
whose embedded origin differs from the installed signed product. The Worker admits the signed application environment
through App Attest: `com.tron.mobile.beta` development and `com.tron.mobile`
development (`Tron Device`/`LocalDevice`) use APNs sandbox, while
`com.tron.mobile` production uses APNs production. iOS cannot select an
arbitrary topic or environment. APNs payloads name the app-bundled `tron-notification.caf`; keep that CAF under 30 seconds, in a supported linear PCM/IMA4/µLaw/aLaw format, and included as a root bundle resource whenever the Worker sound name changes. The App Attest key identifier returned by Apple
remains verbatim in Keychain and is passed verbatim back to `DCAppAttestService`.
Only the Worker registration projection decodes its exact 32-byte credential ID
and re-encodes it as canonical unpadded base64url before computing the client-data
hash and sending the request; malformed or non-32-byte identifiers fail closed
before proof generation or relay admission. Every persisted endpoint grant also binds that normalized origin and route. Missing legacy identity, product-origin changes, and Gateway-certified invalid grants rotate the endpoint grant through the same bounded proof owner instead of endlessly transferring stale authority. The Keychain document versions that
wire projection. On first load after this format was introduced, only a legacy
missing-version document whose key was already marked rejected clears that key
and rejection marker, durably records the current version, and retries with a
fresh Apple key. APNs tokens, grants, pairing, and all other app data remain
unchanged. Current-version rejected keys remain rejected across relaunches so a
real fresh-attestation rejection cannot churn keys. While that exact stopped state is visible,
Settings offers one explicit **Retry Registration** action for use only after the relay's relying-party
configuration is corrected. It clears only the rejected App Attest key reference and starts one fresh
attestation; the APNs token, grants, profiles, pairings, and unrelated Keychain state remain intact.
Challenge requests retain a short network deadline; the non-blocking App Attest
installation uses a 60-second deadline so a cold mobile/Worker verification path
does not become a false registration failure. A registration operation retries only
ambiguous timeout or retryable 5xx twice, with bounded 250/750 ms backoff and a fresh
challenge/proof each time. It preserves the APNs token and Keychain document; unrelated valid grants remain unchanged, while only the stale profile grant is replaced;
only an assertion 401 or the exact typed `DCError.Code.invalidKey` may rotate one key
and admit one fresh attestation. Fresh-attestation rejection, nonretryable 4xx,
malformed data, persistence failure, and exhaustion stop without churn. Chat and
Gateway connectivity never wait on registration.

`TronMobileDevelopment.entitlements`, `TronMobileLocalDevice.entitlements`, and
`TronMobileRelease.entitlements` explicitly carry their APNs and App Attest
capabilities; the signed artifact supplies the final signing identifiers. The development App Attest environment defaults to sandbox when
that entitlement is omitted, so omission from a development provisioning profile is
not by itself an App Attest failure or a valid root-cause claim. Before shipping either
identity, validate APNs provisioning and the complete signed entitlements, pair a
physical device, rotate its APNs token through reinstall/update, and verify revoke,
offline retry, and the privacy-safe Settings registration stage. Simulator tests use
injected notification, App Attest, HTTP, credential, and backoff seams and are not
proof of APNs delivery.

Focused contract validation:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/PushNotificationCoordinatorTests
```

## Session subagent activity

Subagent activity is observation-only and admits only structured synchronous/asynchronous delegated runs. iOS must not add a command executor, treat assistant bash as subagent activity, infer a detached child from shell text, enumerate OS processes, or acquire a writable child runtime. Activity support is detected from the additive snapshot pair; the bundled Gateway advertises `process-activity.v1`, `process-history.v1`, and `process-transcript.v1` for live projection, canonical history, and child viewing. Missing fields or capabilities hide the composer affordance or present an explicit unavailable history/viewer state rather than reviving Extension Activity.

The native orb ports only the upstream 20-point solving and composing geometry; the demo's “Thinking…” treatment is the composing ribbon, not the breathing ring. Upstream switches those modes directly; the composer's matched-geometry glass transition owns the button's morph-away instead of inventing cross-mode geometry. Keep `Sources/Resources/ThirdPartyNotices/thinking-orbs-LICENSE.txt` in the application resources and preserve numeric golden-vector coverage. Emerald paint intentionally differs from upstream monochrome; geometry, radius, depth order, and source opacity inputs remain the parity boundary. Reduce Motion renders a deterministic frame, and explicit visibility plus scene inactivity pause the `TimelineView`.

Focused validation:

```bash
xcodebuild test-without-building -project TronMobile.xcodeproj -scheme 'Tron Development' \
  -configuration Test -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TronMobileTests/SessionProcessModelsTests \
  -only-testing:TronMobileTests/ReadOnlyProcessTranscriptMergeTests \
  -only-testing:TronMobileTests/ProcessActivityOrbTests \
  -only-testing:TronMobileTests/ProcessActivityHostedProbeTests \
  -only-testing:TronMobileTests/SessionProcessPresentationGuardTests \
  -only-testing:TronMobileTests/AppModelEventTests \
  -only-testing:TronMobileTests/ChatSessionPresentationTests
```

On a physical device verify solving-to-thinking-to-hidden expiry, simultaneous synchronous and asynchronous rows, and live-to-terminal updates. The composer subagent orb must enter and leave with the same scoped spring as the catch-up arrow; Subagents and a tapped child transcript open at medium, while Subagent History opens at large. Row taps present a bottom sheet instead of a rightward push; active/completed rows keep caption-scale lifecycle/mode/tool/turn pills in one flow, plain right-aligned durations, a small trailing duration-scaled solving/thinking orb, and one normalized latest-action/output preview. Liquid Glass containers exist only in the bounded active sheet; history uses scroll-optimized containers and retains its bounded 400-row projection incrementally. Active rows remain tappable before child-session binding, show a waiting state, and open the canonical tail once that binding appears. Short/empty child transcripts stay top-aligned while long newest pages open at the tail. Child transcript checks must verify the main transcript's zero-spacing stack, shared 16-point horizontal inset, 12-point top/tail affordances, eight-point row spacing, prepared Markdown in thinking and assistant text, one reconciled run chip per exact invocation/result identity during both live refresh and history paging, preserved orphan results, and no second process-summary tool/output card; explicit earlier paging, append-aware transcript refresh, VoiceOver, large Dynamic Type, and Reduce Motion remain correct. Assistant bash—including `nohup x &`—remains ordinary transcript/tool activity and never appears in Subagents.

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
   archive the `Tron Release` scheme in `Release`. Run
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
