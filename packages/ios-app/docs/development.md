# Tron iOS development

## Fresh-clone prerequisites

Use the CI-test Xcode, iOS runtime, and XcodeGen versions pinned in
`config/ci-toolchain.env`. The Xcode project is generated and intentionally
untracked:

```bash
scripts/install-ci-tools.sh xcodegen
scripts/tron ios generate
```

## Dashboard controls

Sessions, Automations, and Knowledge compose `DashboardChrome`: a leading
34-point base-size heading, a scroll-revealed top blur, and one bottom-right
56-point glass button containing a 34-point Tron logo. Titles and controls use each
dashboard's accent; long headings fit narrow/accessibility layouts before motion is applied.
The header and content start 25 points lower. Over the first 80 points of upward
scroll, the header rises to its original position and gently scales from 34 to
32 points; the list's extra 25-point content margin scrolls away natively. Pull-down leaves that 25-point resting position intact while stretching
the title by at most 6%, reached at 120 points of native rubber-band displacement.
Smooth-ended transforms follow the signed, inset-normalized native scroll offset;
there is no extra animator, gesture recognizer, timer, or scroll-dependent content inset.
Only the title and backdrop observe `DashboardHeaderState`, not the catalogue or row
builders. The native scroll viewport and its insets stay stationary throughout the
gesture; non-scrolling loading placeholders use the same static initial offset.
The logo/search controls stay stationary. Reduce Motion
keeps the original fixed position and title size while retaining the existing blur fade.
Row identity, search state, and managed-sheet/mutation owners remain dashboard-owned.

The native `UIButton`/`UIMenu` keeps four inline sections in fixed top-to-bottom order:
Settings and configuration actions; Filter/Search and view-specific controls;
Sessions/Automations/Knowledge; creation actions. Knowledge settings sits directly below
Settings in the first section. UIKit owns the presented menu tree through all submenu
navigation. `DashboardModeMenuButton` refreshes its coordinator on SwiftUI updates,
but builds a fresh menu only at creation and the native `menuActionTriggered` opening
boundary—not in `updateUIView`. Assigning `UIButton.menu` during presentation can
collapse a submenu. Each new opening uses the latest action closures and view-specific
controls without an extra timer, menu cache, or dismissal/reopening workaround.
`DashboardChromeTests` checks menu identity during parent updates and fresh callbacks
on reopening. The `HOSTED_TEST`-only `HostedDashboardMenuFixtureView` and
`TronSmokeUITests.testKnowledgeSettingsSubmenuStaysOpenDuringParentUpdates` tap the
actual Knowledge submenu, then apply thirty updates while it remains visible and
select Configuration; updates are gated on rendered submenu content so XCTest's
idle waiting cannot run the test entirely after the updates. Filter has no subtext. Settings always opens
the shell's existing app settings sheet. Sessions ends with New Session; Automations
ends with Create Automation and retains Choose agenda date in Upcoming; Knowledge
uses one Knowledge settings submenu in both Chronicle and Library for Observation
configuration, Needs attention, and Chronicle info, with Capture URL and New note
visible in the root menu's final creation section rather than in settings. Search on Automations
explicitly selects All through its persistent preference owner before focusing the
existing inventory search. Keyboard overlays cover the unchanged floating button,
which is not interactive or accessible while searching. `DashboardChromeTests` mounts
all three dashboards and checks menu/scroll identity, inset/offset stability, animated
scroll return, stationary native controls, accents, and search/sheet ownership.
Programmatic animation starts from a settled legal offset, not a synthetic overscroll
without a drag lifecycle. `TronAccessibilityUITests` performs a real pull/release and
observes actual heading frames at normal/accessibility sizes, popup placement/order,
and the original destinations through native taps.

## Knowledge dashboard

The dashboard opens on **Chronicle**, the observation timeline. The top-level **Library**
area contains **Sources** and **Syntheses** as nested sections. Both navigation levels use
`TronSegmentedControl`, matching Manage Session → Workspace's custom glass tabs and
40-point minimum height, with the Knowledge accent and readable text color—not native
segmented pickers. Notes are treated as
syntheses only when their canonical role is `synthesis`, never relabeled from their source
or manual-note identity. Pending
intake and archived sources live behind a separate **Intake & archive** control and are
not mixed into the retained Sources page. Sources show a usable title, safe original
HTTP(S) domain/link, and compact capture coverage; partial, metadata/media-only,
inaccessible, failed, and reference-only states do not imply complete text; a complete
object without extracted text is identified as an object, not as readable text. Detail
shows only captured text that exists, exact capture limitations, origin/provenance, and
any user-approved admission reason. Secondary assessment metadata includes provider
classification/coverage and version/usage fields without conflating them with capture
coverage or epistemic confidence. Source detail keeps the original title, domain, and safe link
above the capture-coverage warning and the one captured-content body; origin/provenance and
technical revision/object/assessment metadata remain secondary. The existing Gateway list
contract has no synthesis-role filter, so the Syntheses view filters the bounded canonical note
page and states that limitation rather than inventing a synthesis endpoint. Filtered pages retain
their Gateway cursor and keep **Load more** available even when a page contributes no visible rows.
The `HOSTED_TEST` Knowledge layout fixture captures Chronicle/Library, source disposition
examples, and an empty Syntheses page with continuation; captures are synthetic rendering
evidence, not live Gateway or VoiceOver validation.

Knowledge is styled as its own adaptive identity rather than inheriting the Sessions emerald or
Automations cyan palette: use `Color.tronKnowledge` for deep violet in light appearance and lavender
in dark appearance, with `tronKnowledgeText` only where readable text contrast requires it. Keep warning,
success, and destructive states semantic. The dashboard uses the shared heading and floating logo menu,
`TronSearchBar`, `TronDashboardFilterSheet`, `TronPlaceholderState`, loading pulse, and edge chrome. Coverage and records share one scroll owner with bottom-control
clearance; closing search clears its query instead of hiding an active filter. Configuration, connector,
import, capture, note, and correction forms compose `KnowledgeFormSheet` with the existing
`TronSettingsGroup`, selection, toggle, inline-field, editor, caption, and notice controls—not native
Form chrome. The shared wrapper only owns presentation; each form keeps its draft and command owner.
Model selection opens the existing progressive picker rather than nesting a scrolling picker in a form. Type and scope selections remain
obvious in the filter sheet. Observation cards are the dense catalogue form: one type step below the
detail sheet, a three-line statement preview, Personal/Research tag, and localized source date—not a
repeated Observation title/type, eye icon, raw timestamp, or revision counter, and not a separate
per-row inspector. Source, note, and other non-observation rows follow the same density with a
smaller row title, a two-line summary, and caption metadata. Corrections do not redate the source observation. Opening a record uses
`KnowledgeDetailSheet`, initially medium and expandable to large, with the standard violet title,
Done control, edge chrome, and hidden grabber. It inherits the same native sheet background as technical
details, without a dashboard-black override. Observation detail shows the full statement once and a
single originating-session row with the shared capsule-shaped Open session control. Catalog names are presentation-only; the action
retains the exact Gateway/session/entry citation even if the session is off-page. The top-left info
button opens `KnowledgeObservationTechnicalDetailsSheet` using the shared technical metadata/JSON
components for revisions, ranges, digests, attribution, certainty, model, and complete evidence. Entry IDs
are comma-separated and wrap naturally rather than allocating one line per ID.
Reflection remains available in the actions menu rather than a redundant Observed items section.
Session navigation and editable drafts are handed off only after the record sheet dismisses, with the
originating Gateway identity rechecked. `KnowledgeModelsTests` and the focused observation case in
`SessionSheetPresentationTests` cover retained evidence/source dates and real medium/large sheets.
Coverage is an informational overview above the catalogue: a section label with the settled count, then the
observed/empty/excluded breakdown and one button naming the cuts that need attention. The overview carries
no list and no action of its own, so a healthy corpus costs two short rows; a Gateway that cannot filter
coverage is told to update instead of being shown a button with no list behind it. That button opens
`KnowledgeCoverageDetailSheet`, a standard medium/large managed sheet (violet title, Done control, edge
chrome, hidden grabber) whose host owns the NavigationStack and medium initial detent from its first frame;
loading, errors, and content therefore keep the same shell and user-selected large detent while the read settles. The page is filtered by disposition
(`knowledge-coverage-filter.v1`, `pending`/`failed`/`unavailable`), so settled rows never enter the list,
and the client rejects a response that ignores the filter. When the loaded page holds fewer cuts than the
Gateway reports, the sheet states "Showing N of M cuts needing attention" and offers **Load more cuts
needing attention**; a continuation appends across a revision change (replacing a re-recorded cut rather
than restarting at the head) so that control always advances.
Each cut row keeps its own icon, disposition title,
reason, and bounded entry-range/session citation, and a separate 44-point Open and (for
failed/unavailable) Clear target—never one combined container element that hides the actions from
VoiceOver. `Open` dismisses the sheet and then navigates with the exact session/entry citation, rechecking
the Gateway identity captured when the sheet opened; `Clear` is only offered on a failed/unavailable cut
and confirms in the sheet, which owns that presented surface while the dashboard keeps the mutation and
reload ownership. Coverage read and mutation failures stay visible in the sheet. `KnowledgeCoveragePresentationPolicy` owns the attention copy, the
requested dispositions, and the
bounded citation; `KnowledgeDashboardLayoutTests` mounts the real row, overview, and sheet to pin the dense
row height, the statement cap, the overview cost, the tighter catalogue row gap, the sheet's separate cut
actions, and the update-guidance state for a Gateway without the filter.
Coverage retains its rows through sheet dismissal and same-Gateway refresh. An unchanged canonical
revision reuses the loaded page/cursor; a changed revision replaces it after arrival, without a loading
placeholder. Initial/new-Gateway reads still show loading. Dashboard catalogue rows likewise remain visible
through a covered read; a genuine same-query failure is an inline retryable notice, while a changed profile,
filter, or search clears the foreign page before loading its exact context. Clear on a failed/unavailable cut uses the
confirmed mutation owner and requires `knowledge-coverage-dismiss.v1`; it preserves an exact terminal
skip, not a deleted gap or a session exclusion. A covered parent must not suppress a legitimate child
correction callback: the callback checks the originating Knowledge presentation identity while the
managed child owns presentation publication.

Observation configuration owns the observer model, current interests, and one explicit
**Observe all Tron sessions** on/off control in a single sheet and Save operation.
It does not enumerate conversations or projects; enabling the control explicitly persists `allSessions` and applies to
future primary Tron conversations only. Exclusions remain authoritative, delegated transcripts stay
out of scope, and no past turns are backfilled. The control requires
`knowledge-global-observation.v1`; without it, show update guidance and reject global configuration
before sending a mutation.

Paged dashboard, evidence-reader, workspace-history, subagent-history, and transcript continuations
use the shared compact pull-style `TronPaginationButton`, with the owning surface accent, loading
state, and accessibility label supplied by each caller. This keeps Load more/Load earlier controls
visually consistent with Chat's pull pill without changing cursor ownership or generic retry actions.
Knowledge source visibility uses a server-side `sourceAdmission` partition before paging, so Archived
and Pending do not consume retained rows from the first page; search uses the same authority.

## Automations dashboard

The shared logo menu's selection callback feeds an exhaustive root-mode switch between the
independent Sessions, Automations, and Knowledge projections; adding a future mode therefore requires an
explicit destination instead of compiling into a Sessions fallback. Switching does not replace
session navigation state. The logo's template tint comes
from the selected dashboard mode—emerald for Sessions and a saturated automation blue
(`#31889A` in light appearance and `#74CBDC` in dark appearance) for Automations—and adding
a future mode requires declaring its matching accent. Automations uses the `.tronAutomation`
visual theme across its dashboard and managed sheets. The logo menu's
Filter action uses the shared dashboard filter sheet chrome, retaining a medium-only presentation; Sessions' server filter starts at medium and expands to large before scrolling;
it owns the Upcoming/All view choice, status/action filters, and connected-Gateway selection.
The shared sheet forces short and long content into the same top-aligned frame, padding, title,
selection transition, and scroll behavior. All-only controls fade into that stable layout rather
than entering through a separate motion path. The selected Upcoming/All mode, inventory status,
action type, and Gateway are stored as one bounded versioned preference owner in the persistent dashboard
shell. The shell's binding writes every accepted dashboard mutation before returning it to the child view,
so the settings survive both dashboard switching and app relaunch; transient search text and the agenda date
are not persisted. Search opens the existing All-mode overlay from the logo menu,
selecting All when invoked from Upcoming. The search field does not permanently occupy dashboard space. Upcoming retains its current agenda or neutral empty state while
refreshing; its no-occurrence placeholder stays centered in the available dashboard viewport
above the bottom controls. Only a refresh that outlasts the short presentation delay adds a compact
activity badge, so transient reloads never replace the dashboard content. Upcoming extends in canonical
seven-day Gateway-generated windows, retains at most eight windows/8,192 presentation items, and requires
`automations.timeline.v1`. Drafts remain inventory-only until enabled, so they appear in All but do not
produce Upcoming occurrences. Only currently connected Gateways advertising
`automations.v2` enter the catalog; disconnected or incompatible profiles stay absent
instead of publishing warning rows or replacing the neutral empty state. Catalog rows
are summary-only and action content is fetched only for a visible detail/run surface.
A secondary Gateway is read-only until **Use This Gateway** transfers focused lifecycle
ownership; mutations then remain revision-fenced and use the existing command-receipt
reconciler. The create/edit form uses shared inline navigation chrome, settings groups,
rows, fields, segmented controls, and keyboard dismissal behavior; do not reintroduce a
large-title reservation or custom control styling there. Selection rows put the current value in the
standard action pill; new prompt automations default to New Session in Workspace, while loaded edits
retain their canonical target. Date values use localized standard action pills: the date opens a native calendar and the time
opens a time-only wheel, each bound to the same field without changing the other component.
Inventory cards and the expanded detail summary share `AutomationSummaryCard` and the same facts.
Inventory puts the icon/title on the left and plain lifecycle/current-run status in the upper-right.
Below, cadence/server and inline Last run/Updated values use two tight, edge-aligned rows with no divider.
Timestamp labels have a six-point baseline-aligned gap before their values, rather than a text-space separator.
Rows fall back to a vertical layout when their full values cannot fit. Inventory timestamps are relative;
the expanded summary retains its divided layout, full localized dates, and untruncated headline. The latest started execution is Last run, falling back to the previous run's start, completion,
or scheduled time when needed; a future occurrence is never presented as a past run. Titles, cadence,
server names, and timestamps wrap, with stacked metrics at accessibility sizes. The entire inventory
card, including padded blank space, opens the existing detail route. Its VoiceOver label includes all
summary facts and attention reasons. The open sheet builds its summary from the authoritative record,
not the possibly older selection/catalog value; its toolbar is titled Automation.

Below the summary, remaining action, schedule, target, current-run, and provenance facts use the same
`TronMetadataTable` as tool/subagent details: divided glass rows, reading-family labels, selectable code
values, no type qualifiers, and no row navigation. Text-led rows stack at accessibility sizes. Summary
fields are not repeated in these tables. The four controls remain a bare 2×2 action grid with Run Now
before Edit; Cancel run joins Controls only for a current execution. Recent Runs is last, below all
controls, and retains its existing run-detail route. Confirmation, color, and disabled behavior remain
with the existing action owner. Action availability separates selected-Gateway ownership from readiness and
in-flight mutation state; a lagging or absent catalog row cannot veto an authoritative detail read.
The Gateway still checks each command's expected revision. Save uses an accessible blue checkmark-only
control, and deadline steppers share the compact pill height. Existing-session target selection uses a large, scoped picker with dashboard
project grouping. An unset workspace omits the browse path so the Gateway resolves its own default;
explicit selections retain their exact path. Validate changes with
`AutomationProtocolTests`, `AutomationCoordinatorTests`, and `AutomationPresentationTests`; hosted
`SessionSheetPresentationTests` cover summary geometry and `StructuredJSONTableLayoutTests` protects
shared row sizing. The native Automation UI regression covers all inventory facts, a newer detail
record replacing stale catalog metadata, non-tappable table rows, controls-before-history ordering,
and the retained run-detail route. Its read-only `HOSTED_TEST` transport accepts no mutations. Workspace targets are selected through the existing focused-Gateway WorkspaceBrowser and trust
flow, and their paths remain transient form state. Every workspace run creates and retains a new
ordinary session; Run Details offers Open Session only through the owning profile/session route.
Do not add recurrence calculation, workspace mirrors, prompt/notification text to caches, or local
automation journals in iOS.

## App Settings and model search

Settings → App Settings owns iPhone-local behavior, separate from Mac/runtime configuration.
Its two eager row groups use the shared emerald Liquid Glass surface, matching the title and
controls; subagent retention inherits this settings theme rather than the activity palette.
**Chats per project** accepts 1–100 (default 10) through the shared numeric settings field. It sets
both the initial project row count and Show more batch size; Show less returns to that baseline.
The two actions stay leading-aligned with a 24-point gap, rather than placing Show less beneath the
bottom-right dashboard menu. Accessibility sizes stack the actions; either sole action remains leading.
Hosted sizing and the native `testSessionPaginationKeepsShowLessBesideShowMoreAndClearOfLogo` regression
cover single/paired controls, the scroll-end logo boundary, and both action callbacks.
Changes apply when the dashboard becomes visible, without resetting project disclosure or changing
Recent Activity ordering or Gateway catalog reads. Pagination retires pending animations while
retaining generation counters so old completions cannot affect the new setting.
`AppLocalBehaviorSettingsTests`, `SessionListPaginationTests`, and the focused
`SessionSheetPresentationTests.testAppSettingsCommitsChatsPerProject` cover persistence,
bounds, staged-transition retirement, and the real field's edit/commit path.

**Show finished subagents** persists a 0–5 minute choice (default 5); **Only active** hides the
composer orb as soon as all subagents finish. The orb and its recent list use admitted canonical
terminal timestamps, never sheet-open time. The last eligible completion owns orb expiry;
expired rows are filtered even on first mount. Subagent History remains unchanged and available
through Manage Session. `AppLocalBehaviorSettingsTests` and `SessionProcessModelsTests` cover
persistence, bounds, staggered completion, immediate expiry, and running-only presentation.

Every shared model picker starts with an icon-only search action in the top-leading toolbar,
not a persistent bottom control. Tapping reveals the shared bottom search field and focuses it;
close/focus loss retains the existing keyboard-settlement and sheet-dismissal guards. Native
`SessionSheetPresentationTests` verifies the leading toolbar paint in light/dark appearances
and absence of an initially mounted field; `ModelPickerSearchTests` covers filtering.

## UI motion and loading surfaces

Compact in-progress UI uses `TronPulseLoadingIndicator`, an in-house SwiftUI
Canvas pulse. Its rendered footprint is 20% larger than the requested nominal size to compensate for the faded outer wave. It is lifecycle-aware, stops with the view, and pauses for Reduce
Motion or inactive scenes. The session-opening cover shows only a centered pulse at twice its former nominal size while retaining an accessibility label. Keep `ProgressView(value:total:)` for determinate
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
scripts/tron-ios-simulator remember SIMULATOR_ID
scripts/tron-ios-simulator install
```

The generated Xcode project is not architectural truth; edit `project.yml` and
source files, then regenerate. Because the application uses a checked-in plist, `Sources/Info.plist` is the sole runtime orientation authority: iPhone is portrait-only while iPad supports portrait, upside-down portrait, and both landscape orientations. Do not add competing `INFOPLIST_KEY_UISupportedInterfaceOrientations*` settings to `project.yml`; run `packages/ios-app/scripts/test-source-policy.sh` from the repository root to guard this boundary, the bundled notification sound, and the rule that app-owned sheets use the activity-managed presentation modifiers.

### Build matrix

| Configuration | Intended workflow | Bundle identity | Push environment |
|---|---|---|---|
| `Development` | Simulator app iteration | `com.tron.mobile.beta` | beta route, APNs sandbox |
| `Test` | Hosted unit/UI tests | `com.tron.mobile.testhost` | no real APNs lane |
| `LocalDevice` | Optimized ordinary physical-device development and profiling; supervised UI install can opt into Fast debug | `com.tron.mobile` | production-sandbox route |
| `DevicePerformance` | Physical hosted performance fixture | `com.tron.mobile` | production-sandbox route |
| `Release` | Manual distribution archive only | `com.tron.mobile` | production route |

The corresponding schemes are `Tron Development`, `Tron Device`, `Tron UI
Validation`, `Tron Device Performance`, and archive-only `Tron Release`. `Tron
Device` has the one explicit Profile action for the optimized `LocalDevice`
binary; its ordinary Run action has `debugEnabled: false`, so a normal launch is
not debugger-attached. `Tron Release` remains archive/analyze/profile-only and is
not an install target for this workflow. `LocalDevice` and `DevicePerformance`
replace the same installed app identity; never run the performance fixture on a
device another workflow owns. Runtime build role and push route are emitted into
`Info.plist`, but the final signed entitlements and provisioning profile remain
authoritative for Apple service environments.

`LocalDevice` deliberately uses the release-like compiler path (`-O`, whole
module Swift compilation, normal Clang optimization, testability disabled,
non-active-architecture-only builds) while retaining development signing and
`dwarf-with-dsym` output. This makes ordinary use representative of the
optimized app while preserving Instruments attachment. For supervised UI
iteration, the Rebuild and Install confirmation defaults to **Fast debug
rebuild**. That immutable command choice uses the same `Tron Device` scheme,
production-sandbox bundle identity, signing, and protocol checks, but passes
`--fast-debug` to `scripts/tron-ios-device`, which uses unoptimized single-file
Swift compilation, debug symbols, active-architecture-only compilation, and a
separate `build/DerivedData-fast-debug` cache. Turning it off selects the normal
optimized `build/DerivedData` path. This is not a Release install mode. Do not add
`get-task-allow` manually or strip it from the development-signed artifact.
`Tron Device`'s Run action is only a scheme convenience; the device helper's
launch and a launch from the device itself are not debugger sessions.

### Profiling a real slowdown

Use the same optimized app for the normal-use → capture → fix → repeat loop; do
not maintain a profiling-only product or copy app state into a shadow bundle.
The user-owned, physical-device workflow is:

1. Generate the project with `scripts/tron ios generate`, select a physical
device, and choose **Product → Profile** with scheme `Tron Device`. This uses
`LocalDevice` and opens Instruments without changing the app's bundle, push
route, attestation, private blur, or local state. Alternatively launch the
already-built app normally, then attach Instruments to its process.
2. Start with **Time Profiler** and **Points of Interest**. Correlate a single
reproduction with Tron signposts and Logs → Share; inspect operation duration,
waiting/serialization/transport/rendering ownership, then rank contributors
before editing. Add **SwiftUI** to inspect body/update/layout cost and the
**Concurrency** tools/System Trace when actor or queue contention is plausible.
3. Stop the capture, retain the `.trace` and the bounded exported Logs file
locally, fix one owner, and repeat the same interaction under the same device,
thermal, cache, and Gateway conditions. Keep a focused regression test and
record only measured improvements; simulator/debug timings are diagnostic, not
device performance evidence.

Profiles require the matching dSYM from the same build. For a prepared artifact,
confirm UUID identity before interpreting symbols:

```bash
dwarfdump --uuid <TronMobile.app/TronMobile>
dwarfdump --uuid <TronMobile.app.dSYM/Contents/Resources/DWARF/TronMobile>
```

The UUID printed for the app binary must also appear in its dSYM. Do not strip,
replace, or mix dSYMs between builds. The optimized development-signed binary
is release-like, not a distribution-signed Release archive; signing and service
routing remain intentionally different.

Apple's [Optimize SwiftUI performance with Instruments (WWDC25/306)](https://developer.apple.com/videos/play/wwdc2025/306/)
and [Profile and optimize power usage (WWDC25/226)](https://developer.apple.com/videos/play/wwdc2025/226/)
cover the corresponding SwiftUI and energy workflows. On-device Performance
Trace/processor tracing is optional hardware-assisted evidence, not a default
capture mode: availability depends on the physical Apple device and OS, it can
produce large traces, and it does not replace Time Profiler, SwiftUI, or
signpost correlation. Treat its output as a bounded deep-dive and compare
matched captures rather than enabling it during normal use.

### Opt-in normal-use capture

For a slowdown that only appears during real work, keep using the ordinary
optimized app and open **Settings → Logs → Diagnostic Capture → Start** just
before reproducing it. Stop immediately afterward, then choose **Export
Diagnostic Capture** and share the copied path with the matching Logs export.
The capture is local and process-lifetime only: five minutes by default, ten
minutes maximum, 2,000 events, and 480 KiB. It records operation elapsed time,
Gateway RPC method/request correlation, catalog results, and chat opening
milestones; it never records prompts, transcript text, paths, credentials,
frames, or payloads. No capture task or event retention runs while it is off.
Use the exported timestamps and request IDs to rank the slow boundary, inspect
that boundary in Instruments when needed, make one causal fix, and repeat the
same interaction under matched conditions. A capture is evidence for diagnosis,
not proof of a physical-device speedup; retain the focused regression and
matched device measurements for that claim.

Hosted tests define `HOSTED_TEST` and expose test-only helpers. A green test build
does not prove the shipping app compiles. Changes to app views or their model APIs
also require a non-hosted compile using the canonical device configuration:

```bash
scripts/tron ios generate
(cd packages/ios-app && xcodebuild build -project TronMobile.xcodeproj \
  -scheme 'Tron Device' -configuration LocalDevice \
  -destination 'generic/platform=iOS' -derivedDataPath build/device-compile-derived-data \
  CODE_SIGNING_ALLOWED=NO)
```

To inspect the effective optimized settings without compiling (including the
embedded share extension), use the owning build-policy check:

```bash
packages/ios-app/scripts/test-build-matrix-policy.sh
```

The check runs `xcodebuild -showBuildSettings` for the generated `Tron Device`
scheme and verifies both `TronMobile` and `TronShareExtension` retain `-O`, whole
module compilation, dSYM output, and disabled testability.

This compile-only check neither installs an app nor validates signing. Keep
physical installs on `scripts/tron-ios-device`; its signed-artifact and Gateway
protocol checks remain required. Production views use `authoritativeSnapshot(for:)`
for session-scoped facts, not the hosted-only AppModel selection conveniences.

## Connection recovery diagnostics

The WebSocket hello attempt has one monotonic deadline covering both the hello send and receive. Its exact socket is closed before a timed-out or canceled operation is joined. Foreground liveness waits ten seconds between independent probes and observes each pong callback with an eight-second bound; successful probes are not logged. Logs can be opened and refreshed while Connecting, Reconnecting, or Offline: the bounded process-local iOS connection ring is shown immediately with profile ownership, stage, outcome, duration, fixed retirement reason, typed numeric closeCode/HTTP status metadata (kept separate and exact to the retired epoch), and overflow count where applicable, while unavailable Gateway records are retained as stale. Separately, production composes a device-local incident store for ordinary relaunch recovery: it persists only structurally admitted iOS connection/client-work records, bounded to 96 rows, 96 KiB, and seven days. The store reserves the first warning/error of up to eight recently observed, validated client/attempt identities alongside the newest window, under both count and byte pressure; an older incident on the same profile cannot replace the current incident's first cause. The optional incident identity is native diagnostic metadata, not a canonical session/credential record. The persistence mailbox retains newest occurrence timestamps under stalled-writer pressure; it contains no URLs, tokens, prompts, or arbitrary transport error text, and persistence failure cannot affect transport or presentation. Remote log RPCs are skipped until diagnostic readiness so opening Logs cannot interfere with hello; cached remote rows remain visible. Probe durations measure the actual pong wait and transport durations measure the retired epoch's age. Native URL-loading error codes survive failure normalization; intentional cancellation is categorized separately. Failed HTTP upgrades distinguish 401 credentials, 403 permission, and retryable 503 capacity/unavailability. Close codes remain platform-supplied facts: URLSession can report 1005/1006 instead of the peer's exact close frame, so logs never invent that missing code. A bounded dynamic-JSON rejection records a typed `decode_limit` incident before strict transport retirement, including the fixed limit kind, observed/maximum bound, sanitized source path, inbound frame byte count, and existing client/attempt/connection/profile ownership. It does not relax decoding or recover a malformed request locally. Separately, `response_too_large` from a confirmed mutation or its receipt read is an `outcome_unknown`, not proof of execution failure: the command may have completed before response projection was rejected. Its stable command identity is retained and iOS does not replay it or restore a possibly accepted send as definitely failed. Logs export capture time, represented bounds, app build, Gateway identity, and per-source freshness/status so retained local rows and failed remote sources are explicit rather than presented as fresh Gateway state. When visible rows exist, the Logs Share action remains available while capability data is loading or unsupported; tapping it explains the unavailable state with a transient notice instead of silently doing nothing. A successful receipt is the only point that copies the server path, and presentation retirement clears stale pending feedback without canceling the accepted mutation.

Automatic recovery is profile-owned and bounded: three connection attempts (including the initial connect) exhaust a transport owner's per-profile allowance if they fail or repeatedly drop before becoming stable and leave the last-good projection offline until the user taps **Retry Connection**. Initial connect and profile switches claim one connection-admission task before cache I/O and retain it through hello; foreground/path callbacks and repeated startup cannot create a peer flight during that suspension. Path hints only revive an existing recovery state, never initiate cold startup or retry an unpaired/unauthorized selection. Replacement attempts receive the exact selected profile and credential from their lifecycle owner, so foreground recovery also works when background retirement canceled startup before the client was configured. Late canceled cache reads cannot replace the resumed authoritative catalog. Budget reset/refund uses the exact epoch's consecutive transport liveness proof (three timely pong intervals); hello or wall-clock duration alone cannot establish stability. Focused and dashboard executors share that allowance, so a role handoff cannot mint attempts; the old dashboard socket is retired through a bounded local-close barrier before its successor handshakes. Background retirement and navigation preserve an exhausted budget while pausing active recovery time. A 30-second active transport-repair allowance gates new attempts; already-admitted handshakes retain their existing deadlines. Healthy/provisional transport pauses repair time without refunding failure history; only its own paid successful attempt can be refunded, never a free maintenance connection. Parked no-path waiting is distinct from a terminal deadline stop, which path/scene chatter cannot re-arm; a fresh hello does not reset it unless that epoch supplies three timely liveness-proof intervals. Suspension, no-path waiting, and passive wall time do not create stability. Explicit Retry re-arms only that profile. Path callbacks are hints only: no-path parks replacement work after one bounded fallback verification, while a satisfied path hint can revive the selected profile even after a missed return callback; a fresh foreground or explicit Retry can also resume an eligible episode. Episode start/deadline, no-path, fallback, and stopped state live in the shared profile allowance, so switching profiles cannot inherit another profile's exhaustion. Planned `system.stopping` recovery uses its separate bounded 90-second maintenance intent and does not debit ordinary roaming recovery. Protocol and paired-identity mismatches stop immediately rather than consuming a hot retry loop. Accepted domain mutations keep their existing receipt/possibly-sent ownership and never re-arm transport recovery. Recovery presentation has one episode-owned two-second grace: it does not reset on retry/path chatter, keeps mounted Chat rows, route, draft, keyboard, and scroll identity untouched, and cannot enable Send while `admitsLiveSessionCommands` is false. Persistent failure presents one selected-profile warning with accessible Retry and View Logs actions; matching successful mounted reconciliation clears it, while provisional hello alone does not. If the verified transport is live but mounted synchronization fails, the warning instead belongs to the conversation: **Retry Conversation** refreshes only its subscription on that socket, retaining rows/draft and keeping Send disabled. Foreground refresh failure does not re-arm transport recovery. Optional provider/settings/device/catalog refreshes run through their existing owners after mounted authority and transport readiness, rather than gating Chat, direct push/session routes, terminal subscription installation, or receipt reconciliation.

`GatewayClientTransportTests` cover cancellation before ping continuation installation, late/duplicate callback settlement, RPC rejection before hello/event activation, complete handshake deadlines, missing-pong retirement, genuine send-failure provenance, overflow diagnostics, and frame decode-limit diagnostics. `GatewayDiagnosticsServiceTests` additionally retain a first fault under saturation while redacting transport content. Recovery-budget tests cover the three-attempt stop, rapid post-hello failure, stable-epoch reset, and explicit Retry re-arm. `AppModelReconnectTests` covers path delivery before cold startup, authoritative session-list loading without manual Retry, cache-suspended startup/profile switches, repeated startup admission, background-before-hello recovery, and canceled cache publication, alongside no-path parking with one fallback and explicit Retry after a missed path-return callback. Dashboard owner tests cover the finite three-failure catalog allowance and no further timer after exhaustion; role-handoff coverage uses the shared profile store. Dashboard socket retirement barriers are keyed by profile and exact entry generation, so a predecessor cannot erase its successor's pending close, and unrelated profile starts do not wait on a slow old close; the automatic budget debit occurs only after that profile's close barrier and current-entry fence. `DashboardStateOwnerTests.chainedRetirementKeepsLatestBarrier` holds two retirement boundaries independently; `SettingsLayoutStyleTests.testVisiblePackagesRefreshAfterForegroundWithoutRetry` checks visible-page refresh without imposing an order on independent catalog reads. `AppModelInboxDrainTests.stalledOptionalRead` likewise withholds both replacement catalog/inbox responses until foreground readiness and correlates each request by method/ID. `AppModelReconnectTests` also leave the disconnect event queued while a failed mounted restore finishes, proving readiness consults the client rather than stale UI identity. Auth completion consumes exact terminal ownership synchronously; one auth-owned worker and one replaceable pending completion perform optional refresh, with canceled/profile-stale publication fenced. The mounted event owner reduces admitted events synchronously into the bounded `SessionSynchronizationCoordinator`; only a claimed synchronization lease enters its single network task, and exact processing-generation fencing prevents retired tasks from clearing successor work. During automatic recovery the last canonical snapshot remains available for rendering, but its old subscription is not a live command grant. A failed bounded recovery transaction stops repeated resync invalidations on that presentation/connection and supplies a persistent, scoped **Retry Conversation** action; a new connection or explicit retry can obtain fresh authority without replaying a prompt. `SessionMutationServiceTests` reconcile uncertain sends on a replacement socket with the same command ID; the signpost and configuration/import/terminal/control-plane receipt tests use responsive-socket RPC timeouts, which must not force reconnect. Their manual clock advances only after the original request is sent and the exact request deadline and between-probe timer are registered. `GatewayDiagnosticsServiceTests` open Logs during a stalled hello and verify immediate local evidence without a remote RPC.

## Efficient focused tests

Do not rerun the full suite for each edit. Compile test products once, then run
only the owning suite without rebuilding:

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileTests/SnapshotCacheTests
```

Multiple `-only-testing:` arguments may select adjacent owners. After source
changes, rerun the incremental `build-for-testing` (normally seconds), then
continue with `test-without-building`. Run the complete unit target only after
focused suites pass:

```bash
scripts/tron-ios-test run
```

`scripts/tron-ios-test checkpoint` is the shared local/CI unit checkpoint: it
verifies the pinned toolchain, provisions the exact owned test simulator,
generates, builds once, and runs the complete unit target serially. CI's
`scripts/ios-ci-test.sh` is only a thin artifact/cleanup adapter.

Swift 6 complete strict concurrency is explicit in `project.yml` and therefore
applies to every canonical build without command-line overrides.

The runner keeps a separate repository-owned test simulator on the exact pinned
runtime and serializes unit/E2E access with one lease. `status` is read-only;
`clean` deletes only state carrying the runner's ownership markers. Routine runs
always use diagnostics `Never` plus `-collect-test-diagnostics never`. Use
`diagnose --only-testing …` only when verbose collection is explicitly needed;
it has a larger finite bound and never runs as an automatic retry. Every attempt
retains a full log, metadata, process evidence, and a unique xcresult under
`packages/ios-app/build/test-runs`, with `latest` outside the bundle. Exit 65 is
a product-test failure, 66 a destination failure, 70 a build failure, 73 a busy
lease, 74 a runner failure, and 75 a process timeout.

```bash
scripts/tron-ios-test status
scripts/tron-ios-test diagnose --only-testing TronMobileTests/<Suite>
scripts/tron-ios-test clean
```

### Test runner safety contract

- Provisioning resolves the exact pinned runtime and device type, proves the
  repository ownership marker, and passes only
  `platform=iOS Simulator,id=<exact-udid>` to Xcode. It never selects, erases, or
  deletes the persistent Development simulator.
- `scripts/ios-test-process.py` owns each Xcode process group, streams the full
  log, enforces overall and no-output deadlines, captures bounded process and
  partial-result evidence, then terminates only that owned group. Product
  failures are never converted into infrastructure retries.
- The `HOSTED_TEST` app entry remains inert: it starts no Gateway, push,
  dashboard, artifact-pruning, or other ambient production owner. Tests create
  only the exact model or presentation boundary they exercise.
- CI uses the same runner core, uploads complete or partial logs, metadata,
  metrics, results, and timeout evidence unconditionally, and deletes only its
  exact owned simulator in final cleanup. UI E2E retains its distinct Gateway
  fixture while sharing the simulator lease and process owner.

Gateway transport tests inject `ManualClock`, `SequenceUUIDSource`, and
`ScriptedGatewaySocket` below `GatewayClient`. Pairing generates a local UUID for
connection identity; persisted profiles decode older records with
`machineGroupID == machineId` and `isEnabled == true`. The dashboard pool admits
at most one profile per verified physical-machine group and excludes disabled
profiles, while retaining their pairing metadata, credentials, and bounded last-known
session buckets across transport retirement and focused-server changes. It validates each
secondary handshake against the paired machine identity, prefers token-bearing profiles when
choosing a group representative, and retries malformed bounded catalogs instead of leaving a
connection stuck in connecting. A foreground reconnect uses a five-second handshake deadline (initial pairing remains fifteen seconds), publishes transport readiness before slower projection/terminal restoration, and treats `system.stopping` as an immediate maintenance retry without charging ordinary recovery. Session events are admitted into the bounded synchronization quarantine synchronously; open/sync reads run on one owned task so unrelated lifecycle, catalog, auth, and terminal events continue draining. Focused profile switches likewise return after handshake/event activation while refresh, mounted-session restoration, and terminal reattachment continue under admission. `AppModelLifecycleTests` owns the façade and
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
scripts/tron-ios-test run \
  --only-testing TronMobileTests/GatewayClientTransportTests
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
chrome lives in a separate presentation component file with unchanged UIKit/SwiftUI behavior. Onboarding navigation
uses leading `‹ Back` and trailing `Next ›` labels with matching spacing; the hosted onboarding toolbar capture
in `SessionSheetPresentationTests` supports visual review of the label order. Workspace browsing
uses one generation-owned cancellable load flight; only the newest path request may clear its exclusive busy
phase, publish an error, or request transient reconnect recovery, and dismissal synchronously retires that
presentation state. Possibly-sent folder creation may finish canonically, but navigation/dismissal generation-gates
its completion UI and an intervening path request prevents its parent refresh from replacing newer navigation. The dashboard shell
and new-session sheet are separate presentation owners; the sheet retains the same configuration/creation state
owners, focus behavior, controls, detents, and mutation admission.
`ChatView` retains route/composer/transcript composition while attachment controls and chips, entrance/render
rows, and extension-widget implementation live in separate presentation files with unchanged identities and
transitions. Session History uses the same settings semantic roles as the surrounding management sheets: body-sized row titles, secondary-description explanatory text, and sheet-section headers for paging/context labels. Subagent History uses the same section-header and secondary-description roles; only bounded tool/output previews remain monospaced. Long canonical previews wrap without increasing the base row scale. Widget/status state remains canonical, but both native presentations are temporarily gated off.
Conversation-turn rendering and lifecycle-safe media chips remain in `TranscriptRow.swift`; transcript event
controls and tool-run/detail routing live in dedicated owners without widening their private helper state. Tool
run detail lists order newest invocation first from producer `startedAt` values, with reverse invocation-source ties and
locale-aware invocation copy; progress/result/completion timestamps never reorder or relabel a call. The primary
tool sheet, diff destination, technical-payload destination, and shared navigation chrome also have separate
presentation owners; only their directly shared layout/diff primitives use module-internal access.
The settings shell and its appearance, connection/import, provider, runtime-behavior (including model defaults), dedicated compaction, resource-path,
package, trust, custom-model, connected-service, and MCP destinations live in separate source owners while retaining the same progressive sheet links and shared draft/state coordinators. Every shared toggle row keeps a fixed 50×30 control while its thumb briefly stretches horizontally during the state slide and settles without moving row layout; Reduce Motion preserves state/tint feedback but disables that spatial stretch. The main settings sheet uses four eager divider-owned Liquid Glass groups: emerald App & Connections, purple Agent Behavior, cyan Integrations, and blue Workspace & Diagnostics. Each row icon and divider matches its group, each row carries a concise secondary summary, and project scope inserts Project Trust while dashboard scope inserts Import. A progressive destination inherits that row accent for its titles, controls, icons, dividers, and ordinary containers, including nested sheets. Connected Services and MCP root destinations are ordinary content inside that progressive navigation owner (one Done control); only setup and detail forms own standalone form navigation and action toolbars. Informational text cards—including the bottom guidance in Custom Models, Available Resources, integrations, and Project Trust—retain the originating hue but mix toward slate so they stay lighter and visually secondary. Settings-row and full-width action labels use white in dark mode and their accent in light mode; Project Trust and Gateway actions keep semantic button tints that match their light-mode text, while warning, error, destructive, and log-level state semantics keep their explicit colors. Connections owns the server-management surface: paired-server rows open per-server detail sheets, authorized devices remain below the server list, and push-notification readiness follows the authorized-device section. Each authorized-device row opens a detail sheet and shows its paired server's connection status instead of a redundant disclosure chevron; after explicitly focusing its server, a supervised `ios-device-install.v3` Gateway can configure a validated source checkout and request the fixed development-signed LocalDevice overwrite install for that authorized device. The Mac requires an explicit owner-only physical binding established by `scripts/tron-ios-device-bind.mjs`; every install rediscovers that exact connected Developer Mode target and refuses missing targets rather than selecting another phone. Use the helper's `--list` mode to obtain paired-device IDs, and `xcrun devicectl list devices` for physical targets. Existing Settings clients need no iOS rebuild for this setup path. Manual acceptance must cover unavailable/multiple target discovery, Developer Mode disabled, signing/provisioning failure, Stable protocol mismatch, background socket replacement during the build, successful app relaunch without data or Keychain reset, reconnect recovery of terminal install status, emerald sheet dismissal, and stable parent-sheet presentation after the repository browser closes. The UI must never display or retain a CoreDevice identifier. Logs are a separate final top-level Settings destination, so Connections and its detail sheets never fetch or render Gateway log history. The Logs destination performs one bounded Gateway read when opened, merges the app's bounded in-memory iOS response-diagnostic ring, indexes level filters once per admitted load, and renders stable record identities directly through a lazy compact list. Each row keeps action, server/source, colored level text, and timestamp in one leading-aligned metadata line with separators and one shared compact type style; the message remains directly below and no icon column is reserved. Initial and foreground refreshes are structured tasks keyed to a diagnostics-readiness generation that advances only after admitted reconnect or in-place foreground reconciliation completes. An automatic empty result cannot erase a useful visible projection, manual refresh remains available, and loading/empty copy uses Tron typography and surfaces instead of stock placeholders. An actionable invalid-response in-app notification can open Logs directly. Gateway Update status/config decoding is bounded and capability-aware. The live update state sits directly below connection state and one exact command-owned polling lane follows file-authoritative helper progress through transient reconnect; an older command marker cannot cancel a newly acknowledged observation, and multi-await detail loading cannot overwrite that lane. Authenticated replacement transport becomes Connected before subordinate projection reconciliation finishes. Lifecycle and restart-drain additions use the same icon/title/detail row structure so long status copy wraps beneath its title instead of competing for a trailing column. The per-server sheet carries no inline gateway metadata: its leading info button opens **Server Info**, whose **Gateway** table (machine, gateway, agent runtime, protocol, restart supervision) and **Runtime identities** table (source revision, runtime epoch, payload identity) both use the shared `TronTechnicalMetadataSection` metadata table, so opaque runtime/deployment identities stay one tap away instead of on the server surface. That sheet is the standard component for any metadata/value table. Maintenance actions drop the redundant "Gateway" from their labels and render as a two-column grid of lifecycle actions under one accent, followed by the full-width error-accent **Forget Server**; source configuration remains one row whose selected-path capsule reuses the Gateway-backed workspace browser before submitting the selected Mac path through lifecycle admission and command receipts. Update and rollback confirmations remain separate full-width actions outside the configuration container. Stable on 9847 and local Debug on 9848 remain separately paired profiles with their own persisted credentials. Pairing, initial hello, reconnect hello, and authenticated `system.info` require an asserted `stable`/`dev` channel matching that profile; missing, malformed, or endpoint-mismatched identities fail closed. A planned Debug `system.stopping` event uses the existing immediate reconnect path with the same profile endpoint and token, then installs the replacement runtime epoch and authoritative projections without replaying an accepted prompt. A Debug-origin candidate exposes the confirmed **Promote Debug Gateway to Stable** action only when its focused Stable-channel status carries an available exact version, lowercase SHA-256 fingerprint, source revision, tested Debug runtime epoch, and candidate runtime epoch whose provenance matches the verified candidate identity; the confirmation pins the immutable version and fingerprint. The separate **Rebuild from Source** maintenance action is user-initiated only, requires a valid configured source root, and sends source mode only; repository agents may prepare and validate the change but must not press the action or submit its RPC. Its copy does not imply a pending update, and generic or unpinned artifact candidates are never promoted automatically. The dashboard server filter keeps multi-selection separate from ordering: the default groups by project/server, while Recent Activity renders active sessions first with stable active-period ordering, followed by reverse-chronological history with project/server context beneath each row. The filter action lives in the bottom-right logo menu. Its server sheet starts at medium on every presentation, lets an upward content drag expand to large before scrolling, and keeps filter changes independent of the current height. The Sessions logo menu's Search action presents the existing keyboard-avoiding overlay and dismisses on close, focus loss, or a downward swipe. Sessions no longer has a separate search button or filter/settings toolbar group; New Session is the last section of the logo menu. Its leading Tron title uses the shared bounded rise, slight shrink, and pull-down stretch described under Dashboard controls. Pull-down overscroll stays unblurred. Narrow presentation wrappers observe scroll state, not the session projection or rows; the fixed safe-area header footprint avoids inset feedback and exposes a heading rather than a toolbar button. Chat destinations explicitly restore their native navigation bar. The floating logo retains the old + button's 56-point target, glass treatment, and bottom/right insets, with list clearance unchanged. The blur fade follows scrolling directly without a trailing animation, including with Reduce Motion. `DashboardChromeTests` covers the shared menu sections/routing, progress bounds, and mounted dashboard presentation. Shared model/session search fields hide placeholder copy while focused and use a regular, more opaque tinted glass treatment. Model search keeps its parent sheet non-dismissible while active and lets keyboard dismissal settle before removing the field, so its close action cannot fall through into sheet dismissal. Its selection guidance belongs in a compact header block directly below the Servers section label, with stronger separation above that block, and uses the shared 11-point secondary-description scale matching the other adjusted sheet descriptions. The selected ordering and bounded server-ID selection are stored together in a versioned local UI preference and restored when the app launches; transient search text is never persisted. Empty startup source projections retain the saved selection until a non-empty authoritative server set can prune removed identities without corrupting the all-servers sentinel. Project headers show the project folder in bold monospace with the server name as a right-aligned secondary monospace label. The dashboard settings overview uses an eager stack so the Gateway Import destination is materialized with the initial sheet; project-scoped settings intentionally omit that dashboard-only action.
Runtime Behavior uses the standard Liquid Glass group surface; Model Defaults order is Model, Thinking, Context Window, and the shared slider host and row identity fences remain unchanged. The Custom Models editor uses the same inherited Liquid Glass group as Connection and Protocol, with no separately tinted input surface. `SettingsLayoutStyleTests.testCustomModelEditorUsesSurroundingSettingsGlass` captures the production editor beside those shared surfaces in light and dark mode.

Available Resources is one destination: a Liquid Glass scope summary with inventory counts and project-trust access, a Liquid Glass Installed group, a standalone Install Package row, then inline Skills, Prompts and Themes containers. Those resource groups opt out of the page-wide tint to preserve the session resource colors (emerald, cyan, teal); resolved extensions are not listed twice. Source titles without whitespace stay continuous in a bounded horizontal viewport, while ordinary names/provenance wrap. Locations and Overrides is a separate standard sheet in Workspace & Diagnostics, with the same scoped autosave owner. Resolved Skills/Prompts/Themes use friendly display names; common source/scope is a caption below each category rather than repeated in rows. Empty categories have no info card; scope counts describe inventory rather than tools loaded in existing conversations. Full paths, metadata and additive categories remain available in Technical Details. Package reload
refreshes the inventory and update projection together: SwiftUI’s structured `.task(id:)` owns and awaits automatic
refresh, target/invalidation changes reject stale completions, and confirmed mutation reloads have priority over
ordinary refresh. Successful foreground/reconnect reconciliation also keys the visible Settings read tasks;
the entire captured package request identity fences values, errors and loading flags after both awaits.
A stale offline banner clears through a fresh authoritative read without user Retry. Other direct Settings
reads share the same successful-foreground signal, while dirty drafts remain protected. No reconnect timer
or automatic mutation replay is added. Installation controls remain an explicit command in their medium/large sheet.
Ordinary settings have no Save buttons or page-specific save tasks. `SettingsAutosave` admits only user
bindings; `ConfigurationAutosaveCoordinator` debounces briefly, serializes writes, coalesces sparse
same-target/session patches, and retains reversions/null resets while another write is pending.
Projection installs do not write. Scope-generation guards reject old input callbacks independently
of exact-revision receipt settlement. Accepted edits survive sheet dismissal; pending writes never
cross a profile replacement. Errors retain Retry, and `outcome_unknown` cannot replay automatically.
Executable resource locations and proxy URLs are accepted on editor dismissal rather than persisting
partial strings. Shared numeric fields stage plain integer text until focus/submit/dismissal, rejecting
partial/overflowing strings; changing the input scope discards the old draft without saving into a
same-valued successor. Input fences use synchronous configuration retirement, not delayed facade
profile notifications. Custom Models coalesces complete snapshots, validates before put, and never restarts
the Gateway automatically; registry activation is a manual maintenance action. Incomplete identifiers
and invalid advanced JSON retain the previous valid configuration. Reset/inheritance intents clear
only on confirmed exact-revision completion, and proxy text is then scrubbed. Every textual toolbar action uses the shared system-weight label with a leading SF Symbol (or its
in-progress indicator); toolbar typography does not impose bold, semibold, or medium text. Explicit credential/message-edit submit actions retain the shared outline `externaldrive` symbol; ordinary preference editing no longer has Save actions. The dashboard Settings
action is deliberately icon-only and retains an explicit accessibility label. Technical-detail sheets use the shared
`TronMetadataTable`/`TronTechnicalSectionLabel` treatment and drill into bounded JSON through
`TronTechnicalJSONRow` instead of inventing sheet-local metadata cards or displaying large raw payloads inline.
One component owns the section label, the divided glass card, and the row geometry, so the icon-led
`TronTechnicalMetadataSection` (runtime facts, tool metadata, server info) and the generalized JSON table
(`TronStructuredJSONView`, and every nested field sheet it opens) read identically; a layout test pins their
equal height for equal rows. The JSON table is that same table without icons: each row keeps its title,
qualifies it with the value's JSON type in the smaller secondary scale, and right-aligns a bounded
preview — the complete value stays behind the row's progressive target. Custom provider editors use shared plain value fields and an API-format value capsule. Their sheet
identity follows the stable provider draft ID, not the identifier being typed. Each row has one Configure
capsule; a leading Remove action inside its editor opens `TronConfirmationSheet`. Provider field bindings
resolve by UUID and cannot update a removed or reordered neighbor during dismissal.
Full-content empty/unavailable states use `TronPlaceholderState`: Tron headline/body typography,
wrapping secondary details, a decorative category-colored icon, and an independently accessible recovery
button when the owner supplies one. An explicit category accent wins over the inherited settings theme;
otherwise the sheet theme supplies the hue. Terminal and Project Resources do not use native
`ContentUnavailableView`. Notifications/history, Automations, Packages, queue editing, and subagent
placeholders share this composition; subagents retain their owning glass surface. Loading stays with
`TronLoadingState`/the Tron pulse. Compact picker misses, inline resource/file notices, and camera/media
overlays retain their existing themed geometry and contrast rather than expanding into full-page states.
`SessionSheetPresentationTests` checks light/dark inherited and explicit icon colors, long-detail wrapping,
and mounted placeholder previews; recovery ownership and loading/error transitions remain unchanged.

Passive Settings explanations use `TronSettingsCaption` / `tronSettingsCaption` immediately below their
owning group or action, with no glass container or icon. `TronSettingsNotice` is reserved for actionable
failures, using the shared icon column, reading typography and right-aligned Retry pill. Do not introduce
page-local info cards or banner layouts. `SettingsLayoutStyleTests` exercises the real Packages view
through an offline read and successful foreground reconciliation without tapping Retry, plus caption
and resource previews; `ConfigurationAutosaveTests` covers removed/reordered provider bindings. Provider and model catalogs use the shared
`ModelDisplayFormatting` projections everywhere they are shown; canonical IDs remain unchanged for
search, persistence, and mutation while labels use product casing such as “OpenAI Codex / GPT 5.6 Luna”.
Provider rows are configured-first and deterministic within each Configured / Available group. When the
Gateway advertises `provider-usage.v1`, a provider list performs one bounded account-usage read; rows show
short and weekly windows with explicit labels, while the existing configuration sheet fetches the selected
provider's exact snapshot and lists every window, reset, balance, stale, and safe error state. Detail rows,
including reset and updated lines, use the standard settings secondary sub-text size and color rather than
the smaller caption scale. The provider catalog's `usageSupported` flag marks the rows that will answer, so
a supported configured row reserves its usage line with an animated skeleton and crossfades to the resolved
summary instead of growing mid-load; a failed read retires that skeleton rather than leaving it pending, and
a Gateway without the flag reserves nothing. Configured rows are
whole-row Details links; unconfigured rows retain their Connect action and automatic single-method setup. Both actions
use the shared compact settings-pill treatment, and usage appears beneath the connection subtitle in the leading provider text stack when present. The Providers sheet starts with Model Catalog (available-model count and explicit forced Refresh) above its rounded Configured and Available containers. The catalog row uses the Providers accent and the exact global/session provider target, with presentation/identity/request fences for refresh results; Runtime Behavior keeps model defaults but no separate catalog action. Provider containers use standard dividers between rows; standalone onboarding rows retain their own surface.
Usage is an account projection only: it never represents session context or local token totals, and a missing capability
leaves connection controls usable without issuing a failed usage RPC. Foreground/display refresh and explicit
Refresh are the only refresh triggers; profile or presentation retirement fences all late reads.
New Session quick selectors carry both server and project identity; source-control choices use a vertically centered selection-symbol column. Worktree fields sit directly under their section headings without a parent card: new names remain editable, while existing branches and committed bases use selection menus from the exact workspace inspection (up to 200 local branches and 100 recent commits). Occupied branches cannot be selected for a second checkout. Models text fields in custom provider details likewise use a single purple field surface with standard (noncompact) text padding and no enclosing card. When a selected workspace requires a trust decision, an animated **Project Trust** configuration row presents it as untrusted and opens a balanced Cancel/Trust confirmation; creating without trusting first records the blocked decision so the session opens without project resources. The Server, Workspace, Source Control, Model, and Project Trust configuration cards are full-container actions; pinned-server restrictions remain enforced by the existing owner. Session creation is sent through the confirmed `session.create` mutation, and Gateway owns Git worktree creation, trust propagation, and rollback. Dashboard server filters use the shared trailing checkmark confirmation action, and the opening composer dims its placeholder until authoritative transcript readiness without disabling local drafting. Project Resources normalizes producer whitespace before display, caps overview subtitles to one line, and keeps detailed tool/resource content in the tapped detail sheet so scrolling remains lightweight. Provider settings cards and Custom Models provider rows use the same centered 22-point leading icon column and 14-point leading inset, with vertically centered icons and leading-aligned text; custom provider summaries reserve the trailing menu width and are produced by a lazy provider stack. Runtime provider rows never use a local action menu or an icon beside their trailing Connect/Configure text: either action opens one medium/large standardized sheet at normal inline-navigation content height. The sheet presents every advertised API-key/login method, replacement-account actions, and credential clearing while retaining exact operation-keyed auth cancellation; API-key prompts install an inline header, credential field, and value-gated Save action in that same sheet rather than opening another page. Manage Session’s leading toolbar places Terminal before Rename. The Manage Session workspace path
uses a trailing inline group-header detail rather than a second header line.
Terminal sheet composition, presentation lifecycle/error state, and native SwiftTerm/keyboard rendering live
in separate source files. The presentation owner permits one active start/show/open flight and one newest pending
route; read replacement cancels safely, while attach/open replacement waits for stale compensation before launching
the pending route. Focused cases also require completed stale-open compensation, prevent confirmed-missing
open replay after revocation, and keep terminate/write/resize failures visible while the renderer remains installed.
The style guard pins that boundary so renderer code cannot regain Gateway/AppModel work.
`SessionPresentationStoreTests` own observation forwarding, cold-cache non-authority,
disconnect/profile-reset semantics, all-topic revocation, old-close/new-open arbitration for both
`closed:true` and already-retired `closed:false` responses, stale and
revoked secondary-response rejection, exact subscription-token admission, and suspended paging
revalidation across revocation, token replacement, and disconnect. `SessionMutationServiceTests`
own explicit session command identity, wire construction, typed outcomes, stable-ID replay only
after a confirmed-missing receipt, and cancellation before replay wire emission. AppModel performance
tests retain cross-owner create/fork/delete, prompt-attachment, queue, navigation-editor, and tree-reload
ordering coverage. `SessionImportCoordinatorTests` own exact lifecycle/profile admission across
file access, upload, and mutation; security-scope balancing; and import-result independence from a
later catalog refresh. `ComposerDraftStoreTests` own version/bounds/corruption cleanup, separate exact-byte payloads, SHA-256 profile/session paths, profile deletion, and the 24-draft disk LRU. Its 25 symbolic-link cases cross root/profile/session/manifest/payload boundaries with load, save, empty-save cleanup, session removal, and profile removal; loads reject aliases and synthetic outside-target bytes remain unchanged. `ComposerDraftAppLifecycleTests` owns the background checkpoint boundary. `ComposerDraftCoordinatorTests` own bounded profile/session text and attachment retention across coordinator restart,
exact presentation mounting/revocation/remount re-upload, deterministic inactive-draft LRU, one-time route seeding,
independent barrier-controlled out-of-order uploads with exact byte/name/MIME capture, cancellation cleanup,
editor policy/use/keep disposition, confirmed/failure/uncertain submission semantics, A → B → A rejection,
and nested façade observation. `SessionShellProfileRouteOwnerTests` prove that selected-profile round trips
synchronously revoke and pop the production route. AppModel performance tests retain the real
`session.prompt` integration proof, post-mount admission-failure cleanup, attachment removal only after
confirmation, and direct share prompts that never inherit staged composer IDs. Run the focused mutation, import, and
composer owners with:

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileTests/SessionMutationServiceTests \
  --only-testing TronMobileTests/SessionImportCoordinatorTests \
  --only-testing TronMobileTests/ComposerDraftStoreTests \
  --only-testing TronMobileTests/ComposerDraftCoordinatorTests \
  --only-testing TronMobileTests/ComposerDraftAppLifecycleTests \
  --only-testing TronMobileTests/SessionShellProfileRouteOwnerTests \
  --only-testing TronMobileTests/MultilineComposerTextViewTests
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
scripts/tron-ios-test run \
  --only-testing TronMobileTests/SessionPresentationStoreTests \
  --only-testing TronMobileTests/AppModelPerformanceSignpostTests
```

Camera boundary tests inject authorization and capture-session providers into
`CameraModel`; QR boundary tests use the same authorization seam plus a scanner-specific
session provider. They never invoke camera hardware or replace AVFoundation in production.
Keep provider callbacks MainActor-bound and keep the two unchecked Sendable AVFoundation
envelopes limited to the photo provider's serial queue boundary. The QR permission task
must recheck cancellation before configuration. Camera setup, capture, torch, and
permission callbacks carry lifecycle/configuration identity so dismissal cannot publish late state.

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileTests/CameraBoundaryTests \
  --only-testing TronMobileTests/QRCodeScannerBoundaryTests
```

Share boundary tests cover provider-fragment reduction, prompt composition, and the
single-value app-group store without loading extension UI. `PrivacyManifestTests` verify
both source manifests and both built bundles. The separate archive check is read-only and
must run after a maintainer-created archive; it never archives, exports, or uploads.

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileTests/SharedContentTests \
  --only-testing TronMobileTests/PrivacyManifestTests
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
successful result. Share exports that same redacted visible snapshot through the exact active Gateway
using the authenticated idempotent `system.logs.export` command; the Gateway writes a private bounded
file under `/tmp/tron-diagnostics`, and iOS copies its server-selected path only after the original
connection admission is still current. Export failures are transient notices and never change the
existing clipboard value. DTO fields and per-profile failure metadata remain in the service/state boundary,
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
scripts/tron-ios-test run \
  --only-testing TronMobileTests/SettingsTrustCoordinatorTests \
  --only-testing TronMobileTests/ProviderAuthCoordinatorTests \
  --only-testing TronMobileTests/ProviderOAuthBrowserTests \
  --only-testing TronMobileTests/PackageConfigurationCoordinatorTests \
  --only-testing TronMobileTests/CustomModelConfigurationCoordinatorTests \
  --only-testing TronMobileTests/AppModelInvalidationTests \
  --only-testing TronMobileTests/AppModelEventTests/globalConfigurationInvalidations \
  --only-testing TronMobileTests/NewSessionConfigurationOwnerTests \
  --only-testing TronMobileTests/SettingsRouteIdentityTests \
  --only-testing TronMobileTests/SettingsDraftStoreTests
```

Pairing tests keep policy above byte transport. `GatewayPairingTransportTests`
feed raw HTTP response bytes and inspect the exact `/v1/pair` request.
`AppModelPairingAttemptTests` use barriers whose late responses intentionally
outlive task cancellation, plus an injected commit recorder, so stale-path tests
never write Keychain. Run the attempt race suite repeatedly when changing its
ownership checks:

```bash
for run in 1 2 3; do
  scripts/tron-ios-test run \
    --only-testing TronMobileTests/GatewayPairingTransportTests \
    --only-testing TronMobileTests/AppModelPairingAttemptTests \
    --only-testing TronMobileTests/PairingInvitationParserTests || exit 1
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
scripts/tron-ios-test run \
  --only-testing TronMobileTests/SessionScenarioBuilderTests \
  --only-testing TronMobileTests/MarkdownPresentationTests \
  --only-testing TronMobileTests/ChatTextPreparationTests \
  --only-testing TronMobileTests/ChatMediaLoaderTests \
  --only-testing TronMobileTests/ChatTranscriptPresentationStoreTests
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
and app-lifetime memory-pressure cleanup. Images and files share that single exact preview lease/priority slot;
file bytes are fetched only after sheet intent and are never cached. The production row retains its 64-point
loading/retry surface. Photos open the existing medium preview immediately from a nonoptional thumbnail-backed
item route while full resolution loads; the thumbnail remains ordinary view input so the mounted zoom view receives
the decoded full-resolution replacement instead of preserving the initial image as sheet-local state. Every file chip opens a nonconditional loading/content/unavailable sheet:
Markdown uses the immutable document renderer, plain/code text uses native selectable TextKit, Unicode-safe
rendering is capped at the existing 320,000-byte source bound with explicit omission, and PDFKit provides native
multi-page scrolling up to the 512-page safety cap. Live composer files retain exact bytes within the existing
25 MiB aggregate limit; frozen handoff strips them before queued/canonical settlement. Physical pixel and
peak-memory calibration remains required.

`ChatView` is the lifecycle/composition root. `ChatTranscriptScrollView` owns one bounded `LazyVStack`, one mode-qualified native size-change anchor, semantic frames, and hosted evidence. One physical row namespace spans committed, live/runtime, local lifecycle, and authoritative queue rows while `ChatCommittedLedger` and equatable row payloads preserve frozen-history performance. The zero-copy lazy adapter retains every physical row in one collection through acknowledgement and successor insertion. The surrounding transcript stack registers one target layout for both exact physical row IDs and the eager marker. Native anchoring owns short-content alignment and routine size/payload changes; there is no minimum-height transcript shim, child target registration, or special short-send command path. A genuinely new lazy physical row may receive one disabled command targeting its exact stable physical ID; the token-owned target is retained until fresh layout-epoch semantic geometry proves that exact row mounted and current near-tail marker evidence proves the viewport. A zero-height lazy row that emits no geometry receives one visual-only two-frame entrance admission and target retry, while a one-second failure boundary releases missing evidence back to native pinning instead of stranding `ScrollPosition`. Rows inserted before an authoritative queue tail, runtime notifications, and local lifecycle rows use the same bounded physical-spine search. Explicit retained pinned resume re-enters the marker positioning gate; retained detached readers remain anchored and are never repinned. Only a changed physical row spine advances the layout epoch; same-spine streaming and shallow tool-state payload updates retain their mounted hosts and current geometry evidence, while delayed callbacks from a replaced spine remain invalid. Impossible underflow offsets are rejected, and short content alone cannot certify opening without a visible current-layout marker. Its scroll-view-relative bottom is the lesser of content and container height, without double-subtracting the composer inset. Neither path targets an index or content revision, eagerly realizes transcript history, or creates a recurring follow loop. Prompt aliases are exact-causal, one-to-one, and fail closed; tool rows may additionally retain one unambiguous prior physical host across late finalized-group metadata while canonical semantic IDs continue to own geometry, anchoring, entrance evidence, and hosted frame samples. The row spine is a zero-copy random-access adapter with an O(1) no-alias admission path. Its native geometry feeds the coordinator directly instead of invalidating root view state; `ChatComposerView` is value/intent driven inside the root's single bottom inset; `ChatRoutes` owns modal modifiers; and `ChatSessionPresentation` groups disposable opening, import, queue-deferral, route, and handoff-ledger state without copying canonical session facts. `ChatSessionPresentationTests` require cold reopen to discard those local receipts/routes, require suspension to cancel import/picker targets while retaining compatible presentation authority, and pin exact-generation opening deadlines plus one-shot post-dismiss fork navigation. The complete open/synchronize/projection/ready transaction has a 30-second outer deadline; timeout cancels owned transcript and scroll work and presents an explicit retry state instead of leaving an ownerless opening surface. The inner 750-millisecond marker acknowledgement begins only after command application and is a bounded repair cadence, never a second terminal deadline. Its canceled task lease remains installed until the operation actually drains, so retry and foreground resume can join it but can never overlap another `session.open`. A drained attempt becomes a visible unsettled error only while its exact task, foreground scene, presentation surface, and model admission all remain current; cancellation, backgrounding, or route coverage stays silently resumable. `ChatViewScrollHarnessTests` mount the actual `ChatView`, bounded lazy transcript stack, composer inset, and native `UIScrollView` in a fixed hosted window. Send/acknowledgement/successor regressions query test-only mounted native row/composer markers and SwiftUI host identities at display boundaries for short history, an oversized short-to-overflow send, and long mixed-height history. Short streaming/appends cross the composer-inset band and viewport contraction checks actual composer clearance. The fixed-window harness identifies its largest non-editor scroll viewport independently of overflow or lazy-child mounting. Cached semantic frames and raw lazy content-size/offset changes are not visual-continuity oracles; projection installation is not a rendered-frame fence. `ChatInteractionTraceTests` pin schema/build metadata, bounded content-free identity correlation, SwiftUI-observed first-displacement/recovery edges excluding user-owned scrolling, physical target position, export-safe command ordinals, semantic handoff evidence, and retired-context checkpoint rejection. Coordinator tests pin marker-owned freshness, no retarget during an unsettled entrance, canonical lease transfer, and a two-attempt repair budget that geometry jitter cannot replenish. The aggregate composer host stays mounted inside that one inset and measures natural content before its bottom-aligned frame. Editor-only height changes install atomically for TextKit caret ownership; attachment, selected-skill, and command/skill-result identity changes receive one value-scoped smooth host-height transition. Pending attachment chips use a presentation-owned ordered projection: batch additions reveal in selection order with a 40 ms stagger and a centered 50-to-100 percent scale/fade, removal reverses that same transform, retained siblings reflow on the same smooth transaction, and the final removal still collapses the bottom-aligned host so content reclaims the strip height. Submission transport is scope-owned across route generations and is projected, never replayed, on remount. Submission retains one explicit layout generation for composer, keyboard, row admission, and target settlement. The outgoing prompt is laid out once at full natural height using the canonical user row's full-width proposal and final horizontal alignment, then its complete text/resource/photo/file/steering/follow-up row fades while translating straight upward by 20 points over 280 ms. The matching width prevents long optimistic text from rewrapping and changing row height when canonical content replaces it. No source or destination geometry is sampled, no row height is interpolated, and no overlay or handoff phase exists. Canonical authority installs atomically beneath the aliased physical host's retained transform owner, so a fast acknowledgement cannot truncate or replay the entrance or introduce a blank frame. Send-time attachment/resource/picker removals are atomic beneath the outer composer-height owner rather than running child clocks. Lifecycle/queue-to-canonical prompt payloads install atomically without a replacement animation; active-to-completed compaction retains its own shallow transition. An ordinary full-height outgoing prompt leases its exact lazy physical host. Its owned entrance/composer/keyboard layout must settle before a large displacement can retarget it; an intermediate lazy estimate is not settlement evidence. Canonical acknowledgement consumes the old entrance entitlement and transfers semantic evidence onto that same lease without readmission. The host stays in its collection when a successor arrives. All exact-row leases include the complete 12-point affordance in the target; the full-size measurable marker overlaps that same band while the lease is held. The total layout extent and both target bottom edges remain identical through release, avoiding fractional-height pixel rounding. The physical row host has no container-level content transition; tool capsules animate only their own shallow value state so rapid parallel groups cannot leave overlapping snapshot copies. Newly admitted compact rows keep their hidden one-shot state across lazy geometry admission and use one measured-height reveal so tool chips and other arrivals move existing content continuously; the entitlement retires only after local animation completion and cannot replay after remount. Already-mounted streaming assistant rows install authoritative thinking/response content immediately while a separate 160 ms local height owner clips and expands ordinary additions; width changes, shrink/replacement, covered content, Reduce Motion, and growth above 2,000 points install atomically. Rows taller than 8,000 points retain their full natural layout height and use only the existing opacity/transform entrance, preventing pathological prompts or Markdown from interpolating an unbounded transcript height. The vertical admission clip expands inside a layout-neutral effect gutter and is removed after admission, preserving prompt shadows and giving settled transcript tool chips an unconstrained native press-and-drag region. All three paths respect Reduce Motion and add no second inset, root geometry loop, or scroll command. The multiline composer uses pure synchronous capped representable fitting plus post-layout TextKit overflow/caret reconciliation. Nil, nonfinite, and nonpositive proposed or resolved widths fail closed; internal scrolling enters only above the cap plus 0.5 point and remains owned until below the cap minus 0.5 point. Focused tests pin speculative infinity-to-finite measurement, wrapped cap stability, trailing-newline caret visibility, manual-scroll-then-type direction, 9→8 collapse, and inset ownership. Active-turn admission validates the Gateway's 192 KiB UTF-8 prompt boundary before changing responder, viewport, layout, draft, or row state, then opens one layout generation before grafting one immutable lifecycle row into the current complete installed projection. Composer measurement carries that exact generation, so unchanged one-line sends settle from a post-layout measurement while multiline/chip/skill/photo/file collapse retargets one completion-revision-checked animation; the removed two-frame equality fallback cannot release scroll ownership during an active height transition. Viewport submission intent preserves `.pinned` or `.anchored`; focused coordinator/composer/store tests pin native bottom size-change anchoring across streaming, discrete growth, keyboard/composer contraction, retained resume, and manual tail return. Opening, catch-up, semantic restore, and prepend leases remain stronger; direct interaction leaves anchored mode physically unpositioned. Tests also cover detached semantic preservation, direct-interaction cancellation, active-upload rejection/retry, immediate collapse, metadata-only reuse, stale-worker rejection, and snapshot-before-response provisional queue identity without granting canonical settlement. Manual UI validation owns the full-height, transform-only outgoing entrance and its Reduce Motion behavior. `ChatLayoutTransactionTests` distinguish successful settlement from watchdog/background abandonment; abandoned generations cannot release scroll leases, and bounded settlement events preserve every consecutive completed generation when SwiftUI coalesces updates. Device checks must additionally send with text, photos, and files while streaming, then background/foreground and relaunch both active and passive sessions: current canonical rows must appear immediately and no pre-suspension entrance may replay. Test-only authority
admission bypasses network I/O without bypassing `AppModel`'s authoritative read
gate. Raw geometry, visible semantic IDs, and row frames are reduced to one latest
sample on each `CADisplayLink` tick; added evidence is aggregate command/frame/count
data only. A maximum-512-row opening case requires the very first ready sample to contain
the exact physical tail marker and latest message in the same plausible native bottom
viewport, so an eventual manual/lazy correction cannot make the test pass. Optional recent-tail
backfill now resolves or reaches its one-second silent deadline inside the opaque open, so no second
speculative history spine can install immediately after that ready sample. The production
`DisplayFrameScheduler` is a one-shot, cancellation-aware display-link boundary used by
first-ready, frame-gated unrealized-tail correction, and long-distance
catch-up staging. Semantic prepend settlement instead waits passively
for exact epoch-qualified row callbacks and requires a strictly newer callback after
each correction. First-ready timing cannot end before the exact initial transcript
projection installs and its frame resumes. Automatic live intake remains coalesced until current non-lifted
marker/geometry evidence settles the opening target, the exact release callback is consumed, and the visible entrance completes. A ScrollPosition command must receive newer marker and geometry evidence after native application, so estimated pre-measurement dimensions cannot certify the tail. When the Equatable native geometry observation remains unchanged, the existing post-application display-frame owner records a narrow proof tied to the exact command, presentation, and layout that the last-observed valid viewport remained unchanged; it does not invent a global geometry revision or wait for an unguaranteed duplicate callback. Post-reveal stability requires two current physically aligned frames rather than equality with a stale geometry sample; this permits a running session to grow while its bottom owner remains aligned without requiring a keyboard resize. Before that proof, an installed projection remains visible beneath a noninteractive loading indicator; only the pre-projection state is opaque. This keeps a real transcript visible while native layout settles without admitting scrolling, repair, paging, submission, or live projection changes. The same lease excludes those mutations through the first ready frame, and missing physical proof fails with the already-mounted transcript still available for diagnosis rather than making a loaded session look empty. `ChatTranscriptPresentationStoreTests` use a
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
and relaunch has no local entrance receipt to replay. The
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
the native bottom alignment/size-change anchors own short and overflowing content without a forced minimum height or separate short-chat state; one surrounding target layout contains the lazy physical rows and eager marker; pinned continuous stream/composer/keyboard and existing-row growth retain zero app offset writes; an ordinary full-height outgoing prompt retains one exact physical-row lease and stable collection parent through canonical acknowledgement and successor insertion, while a genuinely new collapsed lazy physical row retains its exact-row materialization lease until fresh current-layout semantic geometry, row-frame-before-request and request-before-row-frame ordering both settle, and burst requests transfer directly without a target-free frame; a zero-height row can receive one bounded retry and every missing-evidence lease releases after one second, while detached growth remains target-free;
direct return clears catch-up and unread; a foreground chat on the active presentation lineage publishes its exact synchronized
subscription visibility lease before scroll positioning finishes, renews it before expiry, retains it while descendant tool/command/detail sheets are open, keeps their bounded tool projection current without hidden viewport callbacks or chip/row motion, rebases the newest complete projection once on uncover, and retires the lease on unrelated coverage/inactivity/navigation/connection
replacement, and acknowledges later unread summary revisions through the same token-gated absolute read;
bottom rubber-band callbacks remain pinned and keep catch-up
hidden in both geometry/ownership orders when overshoot is within a bounded physical tolerance, while
extreme past-bottom geometry and the same gesture moving beyond the tail detach immediately; composer reflow
in empty, short, or overflowing pinned content cannot impersonate the offset-only status-bar retreat;
no placeholder or correctly installed underflow marker may arm physical repair, and covering the viewport
retires a repair target without changing pinned/anchored intent; catch-up emits one explicit tail intent, restores unread if interrupted,
and rechecks geometry-first physical settlement when command application arrives so draft authority cannot
remain stranded; retained resets preserve anchoring; opening targets only the exact physical tail; semantic
frames remain bounded; and anchor correction preserves the captured offset. Exact layout-epoch restore
and prepend transactions still require newer semantic and geometry evidence, remain bounded to two
corrections, and retire missing restore evidence after one second. Explicit paging supersedes a stale
semantic-restore command while active opening/catch-up rejects paging; anchorless page work is
session-owned and cancels on suspension. Hosted controls drive the production coordinator/executor and record bounded aggregate
callback, command, frame, and maximum-excursion evidence.
Hosted streaming bursts must install only their newest exact source while detached composer/viewport work
remains writable and creates no projection work. Separate hosted journeys exercise catch-up settlement and
a retained detached authoritative generation replacement before admitting that newest source. Canonical/live tool handoff tests also assert that adjacent equal nonempty producer segments compose into one display-only row with the first physical ID, canonical payload precedence, incremented membership, and any-member-running state; barriers or missing/conflicting segments remain separate. `ChatCompactPillTests` own intrinsic-width trailing placement for short prompts, the 364-point
long-prompt bound, intrinsic-width glass selection, equal user-prompt vertical padding, logical-leading
line alignment, agent-matched Dynamic Type body sizing, shared prompt/queue Liquid Glass geometry, and
flat/detail material policy. Manual UI validation owns role classification, trailing composer-edge
prompt/queue motion, aligned activity motion, and the identity transform required by Reduce Motion.
Hosted scroll tests remain the authority that these visual transforms do not grant detached readers
automatic writes or replay same-ID entrances. Lifecycle entrance receipts live in the projection owner rather than lazy row state, survive memory-pressure text eviction, and are pruned with their installed outgoing/pending/queue identities.
`GatewayProtocolContractTests`, `SharedProtocolFixtureTests`, and
`SessionMutationServiceTests` cover revisioned queue projection and replacement commands.
`QueuedMessagePresentationTests` own capability/field admission for editing, prove that advancing
transcript projection tags do not revoke an installed queue card's authority, and cover exact-token
settlement/stale-completion immunity plus the loading evidence policy. Queue controls remain
owned by the installed commit's queue revision/items plus its exact Gateway capability fact, never generic transcript
build lag. The earlier pill remains loading from explicit admission through paging, projection installation,
and anchored (or unanchored) settlement; presentation retirement cancels its local owner. Runtime presentation owners
retain intrinsic cards capped at the user-prompt bound, full-shape whole-card interactive Liquid Glass,
leading-toolbar removal, an explicit legacy lock, and Tron surfaces instead of stock forms.
Native bottom evidence compares `ScrollGeometry.visibleRect.maxY` with the physical
content edge (`contentSize.height + contentInsets.bottom`); the hosted native helper retains signed
UIKit offset evidence so past-bottom overshoot cannot pass as zero distance. Direct detachment freezes
the immutable installed transcript, cancels in-flight automatic projection derivation, and observes only
the scalar authoritative timeline generation for unread state. Manual tail return installs one newest
coalesced cut; catch-up keeps the freeze until its explicit old-tail command settles. Focused coordinator
and hosted burst cases prove no detached projection install or repeated committed-row evaluation occurs.
Pinned structural shrink
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
internally scrolling rows and the native editor at four visible lines. Every outgoing prompt uses one full-height straight fade/slide entrance; prompt length and optional chip content do not select another animation path.
A mounted retained snapshot remains readable during reconnect, but command
admission requires the exact live subscription; queue command confirmations trigger
mounted synchronization before queue controls retire.
The obsolete visibility modifier is removed; the native SwiftUI geometry modifier still
reports a multiple-update-per-frame diagnostic in hosted runs and remains a physical checkpoint.

Intermittent resumed-session blanking or post-send displacement is diagnosed with the
bounded **Chat trace** records in Settings → Logs. Reproduce the issue, keep the app
running, then open Logs; Chat trace rows are labeled **iOS client · Chat trace**.
Use the Error level for automatic anomaly markers or copy the All view to retain the
available causal context. Preserve the `context` and `sequence` fields when sharing
evidence. The 256-record process-local ring evicts repeated geometry, viewport, and checkpoint information before causal lifecycle edges, context starts, warnings, or errors; when every retained record has diagnostic priority it falls back to FIFO. Command publication, applied native-target ownership, and pending release are separate diagnostic bits. It intentionally records no prompt,
transcript text, protocol identity, path, filename, or model/provider value. Ordinary
streaming-token projection updates are not logged, so tracing does not create a new
per-token publication or layout workload.

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
scripts/tron-ios-test run \
  --only-testing TronMobileTests/ChatScrollCoordinatorTests \
  --only-testing TronMobileTests/ChatTranscriptPresentationStoreTests \
  --only-testing TronMobileTests/ChatTranscriptPresentationTests \
  --only-testing TronMobileTests/ChatCompactPillTests \
  --only-testing TronMobileTests/ChatViewScrollHarnessTests \
  --only-testing TronMobileTests/ChatPerformanceTrackerTests
```

`ChatPerformanceBaselineTests` is diagnostic-only and opt-in. The default
checkpoint discovers and skips its three entry points, so they contribute no
correctness evidence. An explicit baseline run records five post-warm-up timing,
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

The checked-in `UIValidation.xctestplan` keeps routine UI diagnostics disabled.
UI journeys run the `HOSTED_TEST` app through the `Tron UI Validation` scheme's
Test configuration, only on the exact owned test simulator; they never use the
persistent Development simulator. `TronSmokeUITests` includes the rendered Ask User
journey and the Knowledge submenu regression. The unit helper selects `UnitTests`,
not UI tests. SwiftUI accessibility semantics must be asserted through this
out-of-process UI-validation route; in-process hosted `UIHostingController`
inspection can expose uninitialized proxy elements rather than the native AX
labels and traits. `TronAccessibilityUITests` covers dashboard chrome, server metadata,
maintenance geometry, typed JSON navigation, and live-to-completed subagent values.
Its `HOSTED_TEST` fixture renders production surfaces and applies canonical snapshot
inputs; it does not mirror accessibility labels or enable private accessibility APIs.
Shared-row sizing, native scroll identity/detent, and toolbar paint stay in unit tests.
XCUI does not expose exact spoken hints/header traits; those still require VoiceOver
qualification. Run these selectors with `xcodebuild test`, scheme `Tron UI Validation`,
configuration `Test`, and plan `UIValidation`, under `scripts/ios-test-lock.py` and
`scripts/ios-test-process.py`; resolve the exact owned destination through
`scripts/ios-test-simulator.py validate`. Use `-only-testing:TronMobileUITests/TronSmokeUITests/<test>`
for focused interaction checks rather than running every journey during diagnosis.

`TronSmokeUITests.testRuntimeBehaviorThinkingSliderOpensAfterDefaultsConsolidation`
launches the test-only Runtime Behavior fixture and taps the real moved Thinking control,
then verifies its slider opens. It guards against losing the configuration-slider host when
consolidating sheets. Hosted layout tests retain root, account-list, inline-defaults and
accessibility-sized resource captures; those captures are not live-provider validation.
`TronSmokeUITests.testIntegrationDestinationsHaveOneDoneButtonThroughSettings` enters
Connected Services and MCP Servers through the real Settings root in light mode, asserts
one hittable Done control, and verifies dismissal back to Settings. Its offline fixture
isolates navigation ownership without contacting a Gateway or any provider.
`SettingsLayoutStyleTests.testIntegrationMutationSettlementRejoinsAfterPresentationSuspension`
checks that accepted success/failure settles while covered, publishes only when active again,
and never replays the command. Global default trust retains the standard autosave error/retry notice.

The Ask User fixture's socket is test-only and records the real `extension.respond` RPC;
no Gateway or provider is contacted. The test taps the rendered form controls,
checks allow-cancel versus close behavior, restores the ID-keyed draft, and
checks the completed read-only form. The styled active-form case also checks that
Close and Cancel occupy separate toolbar controls, selection guidance remains in
the fixed top status row, and selection still gates submission. Cancelled history
uses one compact status row alongside page progress, with a shorter visible label
when space is limited and the full cancellation message retained for accessibility. Context and
option descriptions use the existing body-small font plus 0.3 points; the send
control retains the title's amber accent, including its disabled state. Its retained
active-form screenshots support visual inspection of these details.
`HOSTED_TEST` is absent from Release
configuration and the fixture source is guarded accordingly.

The hosted real-Gateway boundary test owns one narrow integration contract: the
iOS pairing and transport clients connect to the selected Pi runtime, accepted
work survives transport retirement, a new connection decodes canonical
completion, extension interactions round-trip, and a parallel tool group settles
once. It deliberately excludes SwiftUI, visual, settings, picker, navigation,
and general accessibility coverage.

Preparation and the first build happen once; `run` renews the one-use Gateway
fixture, then executes the focused hosted test without reinstalling dependencies
or rebuilding:

```bash
scripts/ios-gateway-e2e-test prepare
scripts/ios-gateway-e2e-test build
scripts/ios-gateway-e2e-test run

# After an affected Swift edit:
scripts/ios-gateway-e2e-test iterate
```

The Gateway uses a fixture-owned home, state directory, agent directory, and
workspace. Use `logs`, `status`, `stop`, and `clean` to inspect or manage those
resources. On CI, focused result/log evidence is uploaded before owned state is
removed. This simulator boundary is an explicit Pi-graph/release checkpoint, not
an ordinary edit-loop or general UI regression suite.

Typography and control styling are presentation concerns; review them through
manual UI validation rather than source-occurrence tests. Runtime lifecycle,
transport, bounds, accessibility identifiers, and authorization remain covered
by their owning behavior tests. OS-owned alerts, menus, and pickers remain
intentional platform exceptions.

`TronSmokeUITests` owns bounded onboarding visual and accessibility checks.
Focused presentation policy tests separately pin stable export-row identity and
single-row progress ownership. The hosted Pi-boundary test does not duplicate
either owner.
`SessionExportArtifactStoreTests` owns archive-specific item/aggregate/count/reservation/age/protection policy through real staged-file reservation/adoption, including unique protected paths, cancellation, active-artifact retention, and outside-file preservation. Fixture helpers create only synthetic staged bytes; they do not implement another export ingress. In particular, the versioned download-admission case crosses the media-sized legacy ceiling rather than merely asserting policy constants. Meanwhile,
`BoundedHTTPFileTransportTests` owns reservation-backed, resumable file transfer and exact byte ceilings. Gateway integration fixtures cross the legacy
25 MiB boundary and exercise running-session JSONL/HTML cuts without placing those bytes in iOS test memory.

`InAppNoticeCenterTests` await actual timer registration and observable notice-count
changes under a watchdog. Virtual time advances only by the asserted dwell; scheduler
yield counts are not expiry evidence, and automatic-timer fixtures dismiss remaining
notices during cleanup. The chat send harness retains its native direction assertion
and includes measured prior-tail positions in failures instead of loosening geometry
tolerances. Its send observation spans two display boundaries after release consumption:
clearing the command is not proof that the resulting native layout has been presented.
The old fractional marker/padding split fails this isolated regression; the overlapping
full-affordance layout must preserve monotonic mounted rows through the same boundary.

The Processes route still requires a real composer interaction in manual UI validation;
directly calling a hosted probe recorder is not route-wiring coverage. Presentation-reset
coverage remains with `ChatSessionPresentationTests`.

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
Agent Instructions, Project Resources, Session History, Runtime Behavior, Providers,
and model selection; dense rows must retain static tinted geometry without visible
material churn. Open a large instructions/JSON document and verify immediate native
scrolling. Manage Session checkpoints verify a compact emerald usage card and purple model card matching
Settings' Agent group, then the adaptive teal Session order (Current Branch, Agent Instructions, Project Resources,
Project Hooks, Session History, Subagent History) and headerless gray Export as HTML / Export as JSON actions. Project Hooks
shows the selected runtime's registered handlers and separate load issues only; it never claims last-run or health state. Its By Extension and By Event views are two projections of the same fenced inventory; By Event can optionally show supported zero-handler events, while unknown runtime event names remain explicit.
Project Hooks stays in the teal Manage Session section. Its By Event view is the default, while By Extension remains available for ownership-oriented inspection. The same teal accent must flow into its generic titles, controls, icons, and ordinary containers in both appearances.
The cyan/teal accent uses a darker readable light-mode value and a lifted dark-mode value; the
management shell stays emerald, model settings stay purple, and export stays neutral. Transcript
and tool semantic colors do not inherit navigation teal. Usage counts and percentage share
one metadata line above the progress-as-divider; automatic compaction appears only in the
model card beside Compact Now. The model name matches the remaining-token headline scale;
the serif provider line sits closely beneath it and the action reads Switch Model. Thinking,
Context Window (when supported), and Automatic Compaction appear in that order, using the
same icon column, indented dividers, label scale, and padding as the Session rows. Context Window when supported and Thinking
show their values in trailing capsules. Both open the same configuration-slider host and
container; Thinking must no longer open a menu. Tap Context Window to grow the glass slider;
verify smooth finger tracking, gentle magnetic stops, exact minimum/maximum, and the default
near 200k/272k plus 500k/750k for million-token models. Other capacities use rounded quarters.
Thinking must show only the live runtime's ordered supported choices; Runtime Behavior → Model Defaults
retains the full model-independent list. Verify discrete dragging/tapping and selection haptics,
with the top-right header updating live (Extra High displayed while `xhigh` remains the raw
selection). Thinking has no lower label section and uses a 140-point nominal panel rather than
Context Window's unchanged 170 points. Supported names remain available to VoiceOver.
Empty/no-alternative lists are read-only; an unlisted
current value has no invented selected stop and is unchanged until explicitly edited.
Outside tap (or VoiceOver Save and close/escape) must shrink back to the original capsule and submit only one edited value;
opening/closing without adjustment must not create an override. Returning Thinking to its
original level must submit nothing. Manage Session's Done first closes an open editor. In Settings,
the single final preview value enters autosave only when its editor closes. Switching settings
target, model/runtime, supported choices or managed presentation must discard the old editor,
even when replacement values match. Beginning close revokes gesture/accessibility editing
synchronously; duplicate or late animation callbacks cannot write or cancel a reopened editor.
Selecting the default detent
(or VoiceOver reset action) clears the override; Default is now a label beneath that detent,
not a button. Verify endpoint labels use the track's endpoint centers, with a second label
line only when needed to avoid a collision. The larger title/value share a center-aligned row.
Scrub opening and closing captures: no title, track, thumb, or label may escape the growing
or shrinking rounded glass. The 280 ms finite transition must settle without an overshoot
or a delayed interactive tail. Clear glass's light neutral fill must soften its finish while
retaining translucent depth rather than solid lavender. Nearby background softening must be visible outside the panel and feather away,
leaving distant rows and toolbar readable. The native blur view keeps alpha 1; only its
UIView mask changes strength and is reinstalled after resizing, as required by UIKit.
`ContextWindowSliderLayoutTests` renders intermediate native surface
fractions with a contrasting-content containment oracle (including destination-sized Reduce
Motion), checks nearby versus distant stripe contrast for the real backdrop effect, and retains
narrow light/dark and large-text previews. `ThinkingSliderTests` covers discrete bounds, raw
values, missing/single/duplicate choices, live draft readout, final-only commits and exact editor
replacement/once-only completion. `ThinkingSliderLayoutTests` verifies the compact native
viewport and that the header/rail fit without lower labels, exercises native close completion
and a surface retired during closing before its activity projection updates, and retains seven
normal/narrow/dark/large-text/subset/unlisted-value captures. Short large-text editors must scroll
to all their content rather than clip it permanently. The presentation owner rechecks its live
registry at completion, not only the potentially stale environment projection.
`ContextWindowSliderMotionTests` runs the actual morph surface over representative settings
content, pins payload reconstruction to input changes rather than display cadence, and attaches
six warmed CPU/run-loop-delivery samples after two warmups. It uses the shipping 280 ms
ease-in-out expansion/collapse curve; keep that workload aligned with the container when
investigating perceived morph smoothness. Run with
`scripts/tron-ios-test run --only-testing TronMobileTests/ContextWindowSliderMotionTests`.
The shared slider presentation also emits `configurationSliderExpand` and `configurationSliderCollapse`
intervals through the existing Diagnostic Capture and Instruments signpost owners. They record only elapsed
time and success/cancellation: no settings values, content, per-frame logs, polling, or extra display link.
Replacement, close interruption, and surface retirement finish only the exact current measurement once.
To investigate an intermittent hitch, start Diagnostic Capture in Settings → Logs, exercise both sliders,
then stop and export the capture; the intervals identify slow transitions for correlation with Instruments.
Elapsed transition time alone cannot establish GPU frame smoothness.
These simulator/test-process measurements do not establish device GPU frame time or release
performance. Its temporary window and display link are owned and released by the test.
Try narrow sheets, both appearances, large text, VoiceOver adjustment/escape, and Reduce Motion.
Settings roots and progressive destinations apply `tronSettingsLayout`; row geometry is owned by
`TronSettingsRow`, including `TronValueRow` and the shared selection, picker-sheet, text and numeric
controls. Do not copy the enlarged Manage Session model heading into settings. `SettingsLayoutStyleTests`
checks native capsule height, plain numeric glyph advances/alignment, rendered dark toggle contrast and
continuous opaque titles, and captures light/dark/large-text component previews. `ConfigurationAutosaveTests`
covers coalescing, in-flight reversion, scope order, old-profile dispatch, stale bindings, incomplete custom
models and explicit retry after uncertain outcomes. Before device sign-off, change values rapidly, dismiss
while saving, switch scope/profile, induce a disconnected failure and Retry, and verify no untouched
inherited settings become overrides. Compaction's runtime facts use standard read-only rows; focus uses
an instruction field and compact reset actions, with neutral informational text rather than yellow.
Verify Context Window and Thinking changes revert on failure and cannot carry into another
model/runtime or overwrite a newer authoritative value. `ContextWindowSliderTests` covers the
bounded detent/attraction math and draft/reset semantics; hands-on animation/haptic tuning is a
separate device checkpoint before broader UI hardening. Extra-high labels read Extra High
across defaults, session controls, transcript notices, and history while raw values remain
unchanged. Statistic values match their captions' point size. Current Branch places the
branch name beneath the title and the working-tree status at the trailing edge. Rename and
Terminal use a grouped leading icon-only toolbar with accessible labels, not content rows.
Compact Now must retain idle, running-prompt queue, queued, in-progress, retry, and export
admission behavior. Slim action/value capsules retain full touch height. Every small
metadata face is half a point larger only within this sheet. The model picker must
inherit purple across title, search, icons, and cards while keeping its ordinary type scale.
Its title reads Models both from Manage Session and from Settings → Runtime Behavior → Model Defaults.
`SessionSummaryLayoutTests` measures the actual native cards/actions, retains light/dark and
long-name/accessibility captures, and excludes screen safe areas from card-size assertions.
Compact action rows must match equivalent ordinary Session row heights without adding row
padding around an already 44-point action target; the regression compares rendered rows
with and without actions instead of relying only on a loose total-card height bound.
`ChatCompactPillTests` pins combined usage copy, missing estimates, exact provider/model
catalog labels, and existing compaction admission; `SessionPresentationStoreTests` protects
pending model selection and narrow authoritative projection. `SessionSettingPresentationTests`
covers immediate pending choices, reset semantics, exact-request rollback, scope replacement,
and shared Extra High labels without rewriting authored content. Project Resources must omit Context Files
and `AGENTS.md` rows. Agent Instructions opens the full document directly with no summary
or capabilities screen, using the same large-only adaptive teal document chrome as the workspace sheet:
custom top blur, icon-only Done, and no opaque bottom bar. Project Resources, Session History, and
Subagent History titles and toolbar actions must use the inherited teal accent. Resource
categories are ordered Prompts, Skills, Tools, then Extensions. Resource detail sheets show only the description and bounded body content; their toolbar info action opens the complete metadata and technical JSON without a second content read. Titles, Done actions, icons, and cards explicitly use the chat resource theme for prompts and skills rather than inheriting the overview tint: prompts are purple and skills cyan; extension and tool categories retain their existing colors. Project Resources and chat share the body renderer and info sheet. Completed empty reads show an empty-content message; unavailable session reads settle with a retry instead of an indefinite loading state. Tools and extensions without supported body reads retain their metadata behind Info. Skill chips use the same cyan as their picker, not the general information-blue palette. Subagent pills use their card accent for icons and text, with compact vertical padding. Started timestamps and terminal timestamps (history, immediately before elapsed duration with a small middle-dot separator on the same line) share monospace styling; missing terminal times stay absent. Session History toolbar and older/newer paging actions explicitly use the sheet teal for icons and text in both appearances. Session History entry details have no end-of-content or metadata footer; navigation controls appear only for multipart content. Verify package/inline extension names
instead of index filenames, friendly skill/prompt/tool titles, and unchanged raw invocations.
`ProjectResourceTitlePresentationTests` pins those naming boundaries. `ManageSessionThemeTests` pins the
adaptive light/dark teal values, contrast, and destination theme routing. `SessionSheetPresentationTests`
presents actual native sheets, verifies large document detents, the custom blur and hidden
bottom toolbar, markdown instructions, full selectable plain documents, and medium-first subagent lists on repeated
presentations. Instructions use the shared block markdown renderer. Plain document readers are rendered in light and dark mode:
their text viewport must reach behind the navigation bar and through the bottom safe area,
while native insets keep the first line visible on opening. Scrolled text must fade beneath
the custom blur, not stop at a solid horizontal cutoff; counting a blur view alone does not
verify this boundary. Expanding a sheet must survive data refresh and returning from its child.
`ChatCompactPillTests` pins the resource categories and instruction-preview ownership.
Confirmation checkpoints verify grey cancellation text, a short trailing
toolbar action, and a sentence-length action in the Liquid Glass container below
content at both default and accessibility Dynamic Type sizes. Dashboard swipe checks verify emerald Rename and neutral-gray Mark Read and Mark Unread actions. Open Rename from both a dashboard row and Manage Session: the centered trailing circle-x must clear the field, remain fixed while a long name scrolls beneath it, and keep Save disabled for empty or whitespace-only input. Dashboard deletion additionally swipes, cancels, and repeats against the same canonical row; the row must remain mounted until confirmation and no delete request may be sent on cancellation. A confirmed mutation response or replayed completion receipt removes the selected projection immediately, and the authoritative catalog event converges every connected dashboard without view-local row suppression or navigating away and back. Chat checkpoints must also verify
trailing alignment for user turns, historical transcript/tool insertion motion,
the Settings gear in the chat toolbar, and the context ring at the trailing edge of an empty idle composer. Resume a cold session and verify that the ring is mounted immediately at zero, visibly disabled while loading, then animates once to the authoritative percentage without changing in-bar geometry; Reduce Motion must update it without the spring. Also verify the nonstructural short bottom blur at default running state, its background-layer
movement between the device-bottom inset and beneath the keyboard's rounded top corners, static subtle emerald under Reduce Motion,
retained compact compaction/retry rows, and emerald toolbar/sheet actions. A transient
provider failure must show only “Retrying”; it must disappear on resumed agent activity,
not wait for the response to end or the retry-attempt metadata to clear. Provider/model
attribution must remain absent throughout streaming and appear only when that message
is finalized, without hiding canonical error notices or attribution on earlier replies.
`ChatTranscriptPresentationTests` covers retry metadata retained during resumption, repeated
retry phases, isolated/common live projection, and stable canonical attribution settlement. Physical chat spacing acceptance additionally checks that
a one-visual-line prompt has intrinsic height, sent photo/file chips stay above and outside prompt glass,
tool pills retain six-point vertical insets, use the shared metadata-pill 13-point leading symbol or 20%-compensated nominal 13-point pulse shifted one point toward the leading edge and a five-point label gap, and avoid a 44-point label minimum; attachment/context/send visuals share the 16-point metric inside 40-point targets,
elapsed timing hugs its intrinsic width, and a pending photo's 22-point remove
circle sits half outside the 64-point preview within a 30-point target centered on its top-trailing corner.
Active-chat reliability checks must advance a desired completion before the displayed running tool receives
geometry and verify that the running chip still reveals exactly once. Submission-to-pending-to-canonical prompts
retain one mounted visual handoff, submitted attachment chips leave the composer before the transcript replacement,
and attachment-only prompts reconcile by attachment metadata. Streaming assistant settlement and runtime-to-canonical
tool grouping retain their visual row identities. Run at least fifteen sequential tool-only assistant messages while prior runtime states remain retained: exact finalized producer groups carrying one equal Gateway-owned `toolSegmentId` must remain independently indexed inside one consecutive display run, its first group must keep the physical chip identity, and foreground catch-up must match continuous delivery without appending phantom rows. Include a completed single tool and a completed **N tools** run followed by another running tool-only continuation: each existing chip must transition in place to an in-progress aggregate whose sheet includes the new call. Repeat with a different or missing segment ID and verify the calls remain separate. Pressing Stop must not be required to restore grouping. Agent text and thinking traces reveal only newly admitted words while
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
Technical details sheet. Informational omission footers use plain muted-gray caption text, not an amber
warning/icon; the bounded-output metadata chip uses the neutral slate accent. With VoiceOver enabled, verify pathological path/glob metadata speaks only the concise
preview plus the Technical details disclosure. Verify compact selectable execution metadata remains first and
records bounded-command completeness, followed by Request JSON then Result JSON containers. Open each
container and verify it immediately presents selectable, vertically scrollable raw JSON for the complete
response-first, content-only string, distinct-fallback, request-only, and missing-result cases without a
readable-output duplicate or third fallback section.
Verify live updates and true-only truncation metadata without moving the primary sheet's reading position. With
a nonempty focused composer, open the native attachment menu, verify the keyboard remains visible before and after choosing a destination, verify its
option symbols are emerald while text retains native system styling, and activate camera, photos, files, Add Skills, Add Prompts, and Add Commands on the first option tap. Commands and prompts have separate picker surfaces; slash completion still searches both while preserving each entry's canonical source. Record the command/prompt/skill panel frame by frame: its material must reveal upward on the same continuous height curve that reduces the transcript viewport, with no full-size flash, delayed chat jump, or second settle. Rapid open/filter/dismiss retargets must continue from the current presentation; dismissal returns downward toward the composer, and a detached reader's visible message must not move to the tail. Verify `@` opens the cyan skill glass, query typing filters without caret
jumps, selection removes only the active token and places one tool-height removable skill chip below photo/file chips, and
a newer skill replaces it. Picker rows use compact icon circles and friendly bold titles, followed by one provenance badge: Project for any project-scoped entry, or User only for directly authored global entries (top-level origin with user scope). Global package resources and entries without sufficient provenance are untagged; Project and User never appear together. The same badge presentation follows titles in selected chips, Project Resources rows, and resource details. Package resource groups use the same prompt purple, skill cyan, extension purple, and tool amber category accents as their chat counterparts. Commands use indigo/command, prompts purple/text.quote, and skills cyan/sparkles consistently across their panels, selected chips, transcript resource chips, and detail/info sheets. Resource descriptions reflow source soft line breaks without changing the underlying content. Both the row info action
and selected chip open the same medium-first titled detail sheet. Its main body contains only description and
lazily fetched content. The top-left info button opens a separate medium-first Resource Info sheet containing the
existing exact invocation, type/source/scope/origin/path, argument hint, and byte facts; it does not fetch again.
Both toolbar symbols and the info sheet's Done match the resource title accent. Check info → Done returns to the
same reading position without clearing the body or reloading it. Extension command excerpts stop after 480
characters or 10 source lines, whichever comes first; skills and prompts retain their full admitted body. Any local or Gateway
omission gets one muted-gray Content truncated note below the excerpt, not an amber warning above it. Markdown front matter already projected as title/description is hidden from the body; ordinary producer
hard-wraps in skill/prompt prose and list continuations become natural layout wraps, while blank lines, block
boundaries, fenced code, intentional Markdown hard breaks, malformed front matter, and extension source remain
preserved before preview bounding. The body uses the static scroll surface shared by provider rows rather than Liquid Glass.
The shared secondary-description size is used for bounded-content notices and disclosure-row subtitles;
compact chips, counters, clocks, code/diff text, and technical metadata retain their intentional dense scales.
`ComposerResourcePickerTests` pins Unicode-safe excerpts, exact boundaries, source truncation, and unchanged skill
bodies. Native sheet tests check toolbar paint in isolated action regions and that the short main sheet has no
metadata table; resource-card layout tests bound rendered excerpt height. Static info-sheet captures do not replace
the manual info-button round-trip check. Verify `/` at the leading command boundary opens the combined Commands & Prompts completion panel, with per-resource icon/color and globally prefix-ranked results. The attachment-menu panels remain category-exclusive. Selection removes the trigger text and stages a source-qualified chip with editable arguments; deleting either active trigger dismisses its picker. Refreshing the catalog must preserve @ skill-only filtering and / command-plus-prompt filtering (`ChatViewScrollHarnessTests.resourcePickerSourceSelection`).
Producer-triggered extension/subagent session messages remain one tool-height status row with a bold owner title,
icon, status, and duration when supplied; tapping retains the complete message, provenance, and payload sheet.
Under Reduce Motion picker height installs without spatial motion; with VoiceOver, picker rows, info controls, and
skill removal are separately reachable. Text, one selected skill/prompt, photos, and files must each independently
enable Send; attachment-only submissions show their chips without an empty user bubble. Prompt-template submissions show the original typed text as entered, never a placeholder or the expanded instructions; with no input text, only the prompt chip and any attachments remain. Verify this remains stable across optimistic → pending/queued → canonical handoff and history reload, with files/photos retained; the chip still opens the template contents. Long-press a user text bubble to open the native UIKit context menu with **Copy**. A retained, bubble-sized native host owns one `UIContextMenuInteraction` and the existing SwiftUI bubble contents. Its ancestor interaction preserves descendant taps instead of placing a touch-stealing overlay over attachments; a background-only interaction would lose hits to the native glass layer. The host is reused across updates and supplies its actual bubble view for the rounded preview, without another preview controller. The action provider returns only app-authored actions and deliberately omits UIKit's `suggestedActions`. SwiftUI updates configure future openings, never call `updateVisibleMenu`, and cannot replace a menu already being handed to Siri. Copy retains the complete displayed text from menu opening, including whitespace and Unicode, not expanded template instructions, resource metadata, or attachment bytes. Queued messages retain their reorder/clear actions, but selecting one rechecks the current row identity, window attachment, and allowed action set before invoking the current command. Busy/read-only queues expose Copy alone; empty text offers no Copy. Source retirement dismisses its own interaction, with no scene-wide observer, private API, timers, or polling. Separate resource/attachment taps retain their original ownership. `SessionSheetPresentationTests` verifies native hit routing, short/wrapped text measurement parity, the explicit Copy-only action list, exact clipboard contents, immutable open-menu text, and revocation/reuse of queue commands. Confirm native preview/tap behavior and exclusion of system-injected Siri actions on the target iOS 27 device; local tests cannot exercise Siri itself. Template substitution determines model-input ordering, not when the chip was added. Queue editing and sending retain raw arguments; the display-only suppression never changes model input. Skill-only submissions retain their existing chip-only presentation. Ordinary
skill/prompt, photo, and file chips translate together inside the same full-height outgoing row, while Reduce Motion and
queued card shapes retain their existing nonspatial entrance. Begin an attachment upload and verify Send disables; a
stale send action must retain text and skill, then retry exactly once after upload completion. The 40-point plus
control and native menu appearance must remain unchanged; the three resource actions stay ordered Add Skills, Add Prompts, Add Commands. Terminal checkpoints must exercise
the native keyboard plus the floating shortcut and command-key surfaces rather
than validating only PTY output.

### Composer image paste

The native composer Paste action accepts one or multiple copied images, using the
same `ComposerDraftCoordinator.uploadBatch` admission, thumbnail chips, previews,
removal, and send path as Select Photos. Image items take precedence over alternate
text/URL clipboard flavors; text-only paste retains UIKit's normal editing behavior.
Only the user's Paste action reads clipboard contents. `ComposerPastedImages` reads
bounded provider files during their callback lifetime without decoding full-size
images; the existing 10-file/25-MiB draft limits still apply. Oversized selections
are reported instead of silently losing images. Preparation is scoped to the exact
chat and cancelled on retirement/coverage; after admission, uploads belong to the
draft coordinator. Repeated pastes append rather than cancelling previous uploads.

`ComposerPastedImagesTests` covers provider loading, byte limits, image ordering,
unchanged text/selection, overflow, stale editor scope, and late cancellation.
`ChatViewScrollHarnessTests.pastedImagesUsePhotoAttachmentFlow` mounts the real
composer, proves batch chips appear before transport completes, captures a simulator
preview, and checks repeated image paste plus ordinary text paste. On-device manual
validation should also copy multiple photos from Photos and paste into a focused
chat using the native editing menu and hardware Command-V; verify preview, removal,
and send after upload. No clipboard polling or separate attachment UI is introduced.

### Tool results and question actions

All plain-text Result/Live output containers in `ToolDetailSheet` use the same
literal, selectable 12-point code font, including subagent and other extension
tools. Tool names no longer switch these containers to Markdown. Structured JSON,
diffs, other subagent sections, and assistant Markdown keep their existing renderers.
`SessionSheetPresentationTests.testAllToolResultContainersUseLiteralMonospace`
compares rendered extension results with the standard built-in result container.

The Ask User form toolbar places Cancel alone on the left and Close (X) immediately
left of Send on the right, with separate native surfaces. Close retains the draft;
Cancel still resolves the request. The native Ask User cancellation UI test checks
button frames and the single scoped cancellation receipt.

Other answers use the queued/steering message editor's native `TextEditor` and
shared `tronTextEditor` surface. Selecting Other smoothly reveals it without
requesting focus before it is mounted; deselection fades it out and releases focus.
Reduce Motion installs the size change without animation. Tapping the editor selects
the large sheet detent as it takes focus, keeping the paged question viewport usable
while the keyboard appears; changing question pages clears focus. The Other button
and editor have separate hit targets and accessibility values, with glass drawn only
as their decorative background. A retiring editor cannot write an answer back after
Other was deselected. Native Ask User UI regressions exercise medium-to-large typing,
multiline input, both kinds of deselection, close/reopen drafts, and exact submission.

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

Gateway RuntimeSlot owns automatic agent-terminal alerts after Pi's `agent_settled` and the canonical terminal receipt, including final errors, aborts, output limits, and stops without final prose. Admitted no-agent failures and orderly shutdown interruptions use their exact invocation ownership instead of inventing assistant content. Separately, every Gateway-admitted semantic interaction owns one fixed input-needed alert; the Gateway suppresses it when the exact session already has a current token-bound visible-presentation lease, matching terminal-alert foreground behavior. Both flows carry the exact machine/session route, while terminal alerts additionally use the bounded session title and fixed outcome-specific body. The existing `agent_finished` wire category is neutral and appears as “Agent finished” with a stop icon, not a success checkmark. A notification tap resolves the paired owner and joins an existing same-profile foreground reconnect once its exact event-enabled transport is active; it never replaces that reconnect or waits for provider, settings, device, terminal, mounted-chat, or paginated dashboard reconciliation. The admitted payload routes directly to canonical `session.open`, which owns existence and authorization. The mounted chat remains visible during preparation, an exact same-route tap stays mounted, and only a different target performs the smooth dashboard pop and chat push. Reduce Motion removes the spatial transition. Background and cold-launch taps remain in memory until the SwiftUI navigation owner is installed, and activation/lifecycle generations prevent stale work from committing after a newer transition.

Settings owns the notification entry point: verify the leading bell changes to `bell.badge.fill` when any paired Gateway reports unread inbox rows and VoiceOver announces the aggregate count. The Notifications sheet defaults to Unread while All and View More retain notification history. It must retain standard title/Done chrome, top blur, medium/large detents, a directly mounted All/Unread control with no redundant outer card or Inbox label, Tron-typography empty states for both filters, newest-first glass cards, mark-one/mark-all read behavior, profile labels, and detail-to-chat routing. Reconnect or relaunch may show the bounded cached projection, but Gateway list/read truth must replace it; never infer unread state from APNs timestamps, titles, or session text. Test whole- and fractional-second ordering, profile aggregation, pagination conflict retry, malformed-row rejection, optimistic read rollback through refresh, and APNs request-ID tap admission. Open a chat from the dashboard, a push, an Automation route, and a restored foreground route; all pre-existing notifications for that exact Gateway/session must become read without blocking chat. Leave immediately or disconnect during persistence and verify background settlement still clears the captured rows. Newer alerts and other sessions/Gateways must remain unread; a visibility heartbeat must not mark newer alerts read, while leaving and reopening must. Opening technical/background session subscriptions must not clear notifications. `NotificationInboxCoordinatorTests` covers authoritative session-read refresh, stale-page rejection, other-Gateway isolation, and cache restoration; Gateway read-cut tests cover durable writes, background retry with the relay unavailable, admission order, and late delivery settlement.

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
scripts/tron-ios-test run \
  --only-testing TronMobileTests/PushNotificationCoordinatorTests
```

## Session subagent activity

Subagent activity is observation-only and admits only structured synchronous/asynchronous delegated runs. iOS must not add a command executor, treat assistant bash as subagent activity, infer a detached child from shell text, enumerate OS processes, or acquire a writable child runtime. Activity support is detected from the additive snapshot pair; the bundled Gateway advertises `process-activity.v1`, `process-history.v1`, and `process-transcript.v2` for live projection, canonical history, and child viewing. Missing fields or capabilities hide the composer affordance or present an explicit unavailable history/viewer state rather than reviving Extension Activity.

The native orb is a minimal adaptation of the upstream thinking-orbs motion language rather than a geometry port. The subagent instance uses the shared seafoam accent; the assistant working indicator retains emerald. Active work uses sixteen larger depth-aware points in a slowly rotating, slice-shifting sphere; recent resting work preserves the original spherical ribbon projection and two traveling waves while joining reduced mirrored samples into eleven continuous cubic strands with rounded caps instead of 208 separate dots. A stable animatable Canvas owner crossfades the two live geometries over 340 milliseconds when lifecycle changes mode, computes both only during that transition, and otherwise renders one mode. The tiny bounded Canvas draws synchronously so it stays frame-aligned with the composer's glass host while live transcript updates arrive. Keep `Sources/Resources/ThirdPartyNotices/thinking-orbs-LICENSE.txt` in the application resources and preserve deterministic coverage for primitive counts, bounds, motion, and painter order. The composer's matched-geometry glass transition exclusively owns the button's geometry morph; the orb content only fades and must not add a competing move/scale transition. Reduce Motion renders a deterministic frame, and explicit visibility plus scene inactivity pause the `TimelineView`.

Focused validation:

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileTests/SessionProcessModelsTests \
  --only-testing TronMobileTests/ReadOnlyProcessTranscriptMergeTests \
  --only-testing TronMobileTests/SessionProcessHistoryStoreTests \
  --only-testing TronMobileTests/SessionSheetPresentationTests/testCompletedSubagentTranscriptOpensWithVisibleContentWithoutScrolling \
  --only-testing TronMobileTests/ProcessActivityHostedProbeTests \
  --only-testing TronMobileTests/AppModelEventTests \
  --only-testing TronMobileTests/ChatSessionPresentationTests
```

On a physical device verify solving-to-thinking-to-hidden expiry, simultaneous synchronous and asynchronous rows, and live-to-terminal updates. A no-edit worker used only as a visual lifecycle fixture must declare `agentContract: { version: 1 }` and an explicit reason-bearing `acceptance: { level: "none", reason: "visual lifecycle probe" }`; otherwise the legacy implementation completion guard can pause the worker after its command and final output have finished, which is canonical resumable state rather than a running process. The composer subagent orb must enter and leave with the same scoped spring as the catch-up arrow; Subagents, a tapped child transcript, and Subagent History open at medium and can expand to large. Row taps present a bottom sheet instead of a rightward push. Activity and History cards share the aggregate tool cards' scroll-optimized surface, 12-point corners, 12/11-point horizontal/vertical padding, and 8-point section spacing. The title leads; plain colored lifecycle text sits at the top-right immediately left of elapsed time on the same baseline, separated by a middle dot, with no status pill or icon. Accessibility text sizes place the status/timing line below the title instead of squeezing the heading. A DETAILS block renders model/thinking/Started and counts/execution mode in the tool FILE/COMMAND field's 12-point medium code font, natural line spacing, and a 4-point caption gap. Metadata wraps rather than dropping counts. The LIVE OUTPUT (or terminal RESULT/ERROR) block uses the tool result's 11-point medium code font and shared bounded-tail fade, retaining three newest nonempty logical lines without clipping away the newest line when they wrap. Queued and paused previews say LATEST OUTPUT. The existing authoritative process projection updates the open sheet's output and lifecycle without a separate poller or transcript read; VoiceOver includes this bounded latest result. Activity uses one lazy row collection across running/completed headers and retained extension content, so an exact process keeps one identity rather than handing a stale live cell between separate collections. Orb-sheet rows retain the friendly local **Started** timestamp. Verify running counters advance each second without incoming progress, continue across scroll/remount and child-sheet round trips, and settle to the authoritative final duration; queued and paused rows stay fixed. Backgrounded or covered sheets stop refreshing, then catch up from the same receipt-local clock when visible. The lifecycle text and active-sheet container color identify status: amber while in progress, success green after completion, and red after failure, stop, rejection, or interruption. History also uses amber for in-progress rows; terminal history cards and child-session chrome use `tronSubagent` seafoam (`#03C3A8`, darkened in light mode for contrast), as do subagent context/update/fork pills. The History title and Done action retain their originating Manage Session theme. `ManageSessionThemeTests` covers the palette and lifecycle scope; focused `SessionSheetPresentationTests` inspect rendered toolbar colors and capture light/dark rows under an unrelated inherited theme. Confirm queued and paused producer states say `QUEUED` and `PAUSED` rather than `LIVE ACTIVITY`; a paused completion guard is resumable canonical state, not a still-running child process. Both subagent lists use the same scroll-optimized card treatment; history retains its bounded 400-row projection incrementally through a standard Load More pill. `TronAccessibilityUITests.testActivityValuesUpdateInTheSamePresentedSheet` verifies successive canonical output samples and terminal results replace the accessible preview. The native `Button` owns its label/value/hint directly: adding a second accessibility grouping creates a non-button proxy and duplicate actionable child. `SessionSheetPresentationTests.testSubagentResultsUpdateInOpenActivitySheet` waits for rendered input and a display frame before verifying native scroll identity, offset, and sheet detent. Active rows remain tappable before child-session binding, show a waiting state, and open the canonical tail once that binding appears. Short/empty child transcripts stay top-aligned while long newest pages open at the tail. Verify content is already visible without dragging on first open and after medium/large resizing, including long prepared Markdown; scrolling away must disable tail-following during subsequent resizing. Closing a child must reveal the same loaded history and cursor without an extra request, automatic Load More, or a spurious History changed card. An active child sheet shows the leading stop icon only when `process-transcript-abort.v1` is advertised; it stays muted gray while the lease loads, transitions to enabled red only after abort authority arrives, and tapping it disables the control and stops only that exact lease-bound execution through the synchronous parent abort or asynchronous trusted-controller path. Terminal sheets omit it, and earlier-page loading uses the same compact transcript pill as the main chat. Child transcript checks must verify the main transcript's zero-spacing stack, shared 16-point horizontal inset, 12-point top/tail affordances, eight-point row spacing, prepared Markdown in thinking and assistant text, one reconciled run chip per exact invocation/result identity during both live refresh and history paging, preserved orphan results, and no second process-summary tool/output card; explicit earlier paging, append-aware transcript refresh, VoiceOver, large Dynamic Type, and Reduce Motion remain correct. Assistant bash—including `nohup x &`—remains ordinary transcript/tool activity and never appears in Subagents.

## Manual iOS release validation and delivery

The repository does not archive or upload production iOS artifacts. A maintainer
performs every TestFlight or App Store delivery deliberately:

1. Select the exact commit whose CI checks passed, confirm a clean tracked
   checkout, and run `scripts/tron version check`.
2. Generate the project and complete the release checkpoint: the full iOS unit
   target, required UI/E2E journeys, and eyes-on physical iPhone/iPad review of
   onboarding, pairing, chat/attachments, system-keyboard dictation, terminal,
   settings, accessibility, and signed-device networking.
3. Run `scripts/ios-release-toolchain-doctor.sh` as the explicit manual
   toolchain/capacity gate. It validates only and never archives or uploads. With
   maintainer-controlled signing credentials, archive the `Tron Release` scheme
   in `Release`. Run
   `packages/ios-app/scripts/verify-archive-privacy.sh <path-to-xcarchive>`, then inspect
   the app and share extension bundle identifiers, versions/builds, and signatures before export.
4. Use Xcode Organizer/App Store Connect to export and upload manually, then make
   any TestFlight group assignment or App Store release choice explicitly. Record
   the source commit, version/build, and validation results with the release.

Never add or invoke a repository workflow or command that performs production
archive upload, TestFlight distribution, or App Store release automatically.

## Gateway fixture work

Protocol DTO changes require matching gateway tests and Swift decoding tests.
Pi SDK rollback fixtures belong to `packages/gateway/test-fixtures/pi-sdk` and
are disposable JSONL only; they never use iOS app data, Keychain, or a live
Gateway. The simulator-only `pi-sdk-e2e` workflow runs the hosted real-Gateway boundary
only when the Pi package graph changes (workflow dispatch forces it),
and always cleans its owned simulator and fixture state. It is an upgrade gate,
not a general iOS test replacement.
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

### Diagnostic source identity

The app build stamps `TronBuildIdentity.json` into its signed resources with the source commit and dirty state. Logs Share uses that app identity independently of the connected Gateway revision. Export retains only bounded RPC method/request IDs, outcome, code, fixed admission reason, and duration; it never serializes request parameters or arbitrary error details. Missing build identity is reported as unknown.
