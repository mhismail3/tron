# Presentation parity

The shared iOS presentation contract. It binds every feature module; the components it names
live in the presentation module ([`Sources/UI`](../Sources/UI/README.md)) unless a path says
otherwise. Feature-specific layouts belong to their module README.

## Owner rule

- Every UI/UX change first inspects its neighboring surface owners and this contract. Runtime
  correctness does not authorize a one-off visual pattern: availability explanations use the
  existing information/navigation treatment, and actual in-flight work uses the existing
  control/selection loading.
- Preserve touch and VoiceOver access, Dynamic Type, identity, focus and native layout.
- An approved pattern change updates the shared component and this contract together.
- New features compose these primitives instead of `.body`, `.caption`, stock bordered controls,
  rounded UIKit fields, or system search and segmented styles.
- The pre-Gateway client is the interaction baseline; the Gateway migration defines no new visual
  language. The session shell stays mounted under the adaptive first-run sheet, and session
  creation keeps the floating action.
- Prefer real-app journeys over source-string checks or broad golden snapshots. Layout assertions
  use bounded tolerances only for an identified width/chrome risk; screenshots are diagnostic
  evidence, not a substitute for a successful interaction. Simulator captures are not
  physical-device acceptance.

## App-wide boundary

`TronPresentation.swift` is the app-wide presentation boundary. The app root installs the
selected type family and the emerald interaction tint. Every app-owned Form/List uses the Tron
collection surface; section headers, titles, search, segmented choices, fields, editors, toolbar
typography, row actions, icon buttons, loading labels and prominent actions use shared semantic
components. Toolbar and sheet action icons are emerald while their container geometry and
Liquid Glass stay default iOS styling, never a second app-drawn container.

- **Surfaces.** App-owned rows, cards, composer surfaces, chips, tool details, structured-data
  rows, Manage Session content and ordinary settings groups use Tron's tinted Liquid Glass.
  High-cardinality or very tall collections use the shared static scroll surface (same tint,
  border, geometry and hit regions, no live backdrop filter per row). Long settings screens use
  lazy outer stacks; small divider-owned sections stay eager. Bounded card stacks that host a
  presenter (Settings sections, Manage Session) stay in an ordinary stack, because lazy eviction
  of glass cards invalidates SwiftUI's layout graph and can end a nested presenter's lifetime.
- **Code insets.** `ToolDetailCodeBlock` uses a flat, lightly tinted inset, never Liquid Glass.
  Memory entries and tool argument/error sheets share it, so an entry card owns the only glass
  container around its monospace content.
- **Long content.** Containers above `TronLongContentPolicy.flatSurfaceCharacterThreshold` use
  `tronScrollSurface`; shorter ones keep glass with identical padding and typography. Prompt text
  keeps about `promptVisibleLines` lines and masks only the text's bottom ink on overflow; the
  parent glass is never inset-filtered or painted. Only an overflowing prompt opens the full
  shared Markdown reader, routed by the transcript so lazy row retirement cannot dismiss it.
- **Typography.** `TronFontLoader` builds descriptor fonts (custom weights, Recursive `MONO`/`CASL`,
  Source Serif optical sizing) from the bundled catalog and the `fontFamily`, `monoFontFamily` and
  `fontAxisValues` preferences, falling back to the matching system role. Created fonts are reused,
  bounded, keyed by every shaping input; Dynamic Type scaling stays with SwiftUI and
  `UIFontMetrics`. Left-aligned secondary copy uses the reading family (serif by default);
  monospace is reserved for right-aligned values, durations and tool identifiers.
- **Pills.** Every compact chat pill and tool status/metadata chip uses one leading rhythm: a
  13-point symbol (or a pulse at that nominal size with 20% footprint compensation), then a
  five-point gap. Only a pill with real detail is an interactive Liquid Glass button; no-detail
  pills use a flat tinted fill with identical type and geometry. Tones are `Sendable` semantic
  values resolved to colors only at the view boundary. Every tappable pill/chip opening a sheet
  uses tinted Liquid Glass through its shared surface. Provider-error runs retain centered
  alignment and semantic red glass with contrast-safe error ink; no flat error override.
- **Role palette.** User input emerald, commands indigo, tools emerald, attributed extension
  context violet, informational notifications primary-themed, unknown context slate, warnings amber,
  failures red. Producer and category stay in text so color is never the only signal.

## Sheets and chrome

- **Managed sheets.** All app-owned sheets and binding-owned picker/alert boundaries use the
  managed presentation modifiers (`tronManagedSheet`, progressive links); `packages/ios-app/scripts/test-source-policy.sh`
  rejects raw native sheet calls. Their state rules are in
  [Presentation-scoped state](#presentation-scoped-state).
- **Presentation haptics.** Managed sheets (including nested and interpreted Swift-app sheets)
  and system pickers play one medium, full-intensity impact through `TronHaptics`, respecting System Haptics.
  Semantic interaction patterns and exclusions are in the [UI haptic map](../Sources/UI/README.md#haptic-map).
  Presenters adopt already-presented state silently; detent changes, replacements, re-renders and
  dismissals do not tap. The question interaction keeps only its existing live attention cue;
  state-driven onboarding and pending editor confirmations remain silent across launch/reconnect.
- **Toolbar tint.** Every sheet a row opens inherits its card's accent through
  `TronProgressiveSheetLink`. Every toolbar action uses `tronToolbarAction(accent:role:)` with the
  accent the sheet gives `TronSheetTitle`; both resolve through `TronSheetTint` (inherited Settings
  tint, else the sheet's accent, else emerald). Only `.destructive` (red) and `.neutral`
  Close/Cancel (grey) differ, and a disabled action greys itself; never paint toolbar icons
  directly. `TronSheetTintUITests` compares each icon's ink with its title (`assertToolbarTint`).
- **Dismissal.** Modal detail flows dismiss with the native top-right check; top-left dismissal is
  reserved for navigation. Sheets never use pull-to-refresh: History, packages and providers expose
  Reload in the toolbar, and dashboards converge through live Gateway invalidations.
- **Info.** Every sheet with technical or metadata details opens them from the top-leading
  `TronSheetInfoButton`.
- **Documents.** Document-style sheets use `TronDocumentSheet` (`TronSheetTitle`/Done, shared top chrome,
  hidden drag indicator, `tronPresentation`); an explicit initial detent keeps the other detents
  draggable. Content that owns its own stacks passes `hostsNavigation: false` and applies
  `tronDocumentSheetChrome` at each stack root, never nesting a second NavigationStack.
- **Top blur.** One shared backdrop with a continuous proportional fade, never a solid band;
  `TronTopBlurStyle` owns the depths, radius and adaptive tint. `tronTopBlurSurface` attaches it
  to the concrete scroll surface inside each NavigationStack, below titles and glass controls.
  The loading reveal applies to scroll content before this overlay: the blur stays at its final
  opacity and position while cards fade and rise beneath it. Every native scroll edge is soft
  (the hard style renders an opaque cutoff on device); system bar backgrounds stay hidden.
  Establish full width before edge chrome; never replace native material or paint an opaque page.
- **Loading.** Whole-content loading is a `TronSheetLoadingState` preference that the enclosing
  `TronPresentationSurface` draws once as a centered pulse; while present it sets
  `tronSheetContentLoading`, hiding every `tronScrollEdgeChrome` scroll view (title and Done stay
  usable). The pulse leaves without a fade and content fades and rises 8 points with
  `ChatMotion.transcriptViewReveal` (Reduce Motion: fade only). Owners request it only while they
  have no content, so cached or refreshed content is never hidden or replayed. Non-scroll sheets
  (media, terminal, camera, Swift-app preparation) keep their own preparation surfaces.
- **Chat details.** Provider-error and nested tool-call details reuse `ChatDetailSheet` for
  navigation, Done, top chrome, insets and detents. Error content composes the existing themed
  sections/groups/rows and flat code inset, not a second sheet or card style.
- **Detents.** Progressive and Home sub-sheets open at medium and drag to large; a presentation's
  managed scope owns its chosen detent, so refreshes and child round trips do not reset it.

## Confirmations, entry and notices

- App-owned confirmations, acknowledgements and rename/bookmark entry use `TronConfirmationSheet`,
  `tronConfirmation` and `tronTextEntrySheet` (including interpreted Swift apps' alerts), with a
  grey leading cancel. A short primary label stays in toolbar glass; a long, multi-line or
  accessibility-size label moves to the shared glass action container below the content.
  Destructive roles stay red. Cancel and interactive dismissal never submit a domain command;
  adapters close their exact presentation binding and capture the accepted action before clearing
  item-backed state. OS permission prompts, menus, document/photo pickers and terminal emulation
  stay platform-owned.
- Destructive, security, text-entry and ambiguous decisions are modal. In-app notices
  (`InAppNoticeCenter`, owned by State) are informational only: no buttons, tap actions,
  navigation or recovery commands. They render in a per-scene pass-through window above sheets
  (`InAppNoticeHost`), one card at a time, with shared 24-point corners and type. Success, progress
  and information use the active `tronPrimary` icon and accent; warning/error roles stay semantic.

## Settings conventions

- **Reuse.** Settings, Manage and Project changes reuse `TronSettingsGroup`, `TronSettingsRow`,
  `TronSelectionRow`, `TronGlassCard`, the shared typography/colors and the managed or progressive
  sheet owner; no local rounded-card backgrounds or duplicated navigation/Done chrome.
  `TronSettingsSections` derives the section count structurally before lazy layout. Groups and
  custom section labels omit a lone heading by default, retaining explanatory detail; standalone
  captions do not count as sections. Presentation surfaces reset this scope for child sheets.
  `TronValueRow`, `TronNumberSettingRow` and `TronTextSettingRow` delegate geometry to
  `TronSettingsRow`. `TronCatalogOptionRow` also composes that row: facts use standard subtext,
  identifier footnotes use the shared code family at the same size, and applying uses the fixed icon slot.
  Sub-destinations disclose as progressively stacked sheets, not pushes.
- **Geometry.** `tronSettingsLayout`: 14-point leading inset, 22-point centered icon column,
  common icon-to-text gap; the decorative glyph is capped at `.large` Dynamic Type so it never
  spills from its column while labels keep full Dynamic Type. Section-owned rows add no second
  inset.
- **Inline actions (#939).** Icon-only actions use `TronInlineActionLabel` without an empty text
  slot: a 28-point circle trailing-aligned in a 44-point target. Invisible target width is
  leading, so the zero-gap value/reset cluster shows a 16-point visible gap and the 14-point
  inset without overlapping hit regions. Every owned override's reset uses this capsule.
- **Overrides.** Inherited values have no source affordance. Session/Home overrides show the
  shared Overridden status pill beside the row title (the value's trailing room is the same with
  or without it) and Revert after the value. An applied Project value replaces the editor with a
  read-only value and a shared Project pill opening file/key information. Absent non-secret values
  render a dash. Values, pills and resets remain independent sibling targets, not nested buttons;
  the Overridden pill and a tool selection's "N of M tools" count never truncate. At
  accessibility sizes, or when the cluster would leave the title less than a 96-point column,
  the cluster stacks under the text column.
- **Reset.** Uses the renderer's preview/confirmation/receipted `settings.change` unset at the
  writable layer. Inherited values have no reset; nothing invents a default locally.
- **Text entry** ends through `tronTextEntryDone` (return reads Done; multi-line or
  return-less keyboards show Done above the keyboard). Entry guidance is the schema's `entry`
  (`hint`, `example`); iOS writes no per-key guidance. Free text shows a muted `(empty)`
  placeholder.
- **Accents.** Group accents flow from `SettingsGroupCard` through every progressive sheet; a
  destination reachable elsewhere reads the inherited theme and names only its standalone
  fallback (`tronSettingsVisualTheme(inheriting:)`). Project Trust, Gateway actions and
  warning/error/destructive/log-level colors stay semantic. A theme carries readable ink and
  its surface tint together; inheriting a destination preserves both. Dark Burgundy's primary
  Home surfaces use canonical deep-wine `tronPrimarySurface` glass with lifted `tronPrimary`
  text/icons. Light Burgundy and other primary themes resolve both roles identically; explicit
  semantic accents retain their own ink/tint unless the caller supplies a surface role.
- **Captions and notices.** Passive explanations use `TronSettingsCaption` in
  `TronTypography.settingsRowSubtext` (never smaller than rows), attached eight points below with
  `tronSettingsCaption`. Actionable failures use `TronSettingsNotice` with a trailing Retry.
- **Saving.** Ordinary settings have no Save toolbar: valid edits autosave with target-local
  error/Retry. Authentication, package installation and maintenance stay explicit commands.
- **Setup cards.** New Session cards are one `TronSetupCardLabel` with
  `TronTypography.settingsRowSubtext`.

## Approval presentation

Chat request/outcome chips, settings push review and Changes use `SettingsApprovalSheet`
(`UI/Settings/SettingsApprovalsSection.swift`) and the existing receipt-backed
`SettingsTrustCoordinator`. `SettingsApprovalPresentationModels` reads canonical structured
facts, never prose. The transcript route owner retains approval sheets above lazy rows;
Manage Home/Session do not duplicate them. Pending uses the Approve title and top-right red
X/green check, no Done/bottom bar; native dismissal never submits. Current Gateway values/action
previews and digest bind a deliberate tap. Terminal receipts/outcomes are read-only, with full
wrapping uncertainty text; missing or incomplete proof stays unavailable, not applied/failed.
Global Changes remains the audit/Undo surface; owner actions have no generic Undo. Positive
compact status extends the shared pill palette's semantic success role, not per-chip colors.

## Shared lists and readers

- Manage Home/Session list sheets share `Components/TronList.swift`. Fixed sets (Profile,
  Chapters, Instructions, Resources) are a `TronListGroup`: one glass container per section, its
  header and count above it only when multiple nonempty sections remain; a single-category
  section (a Resources kind) keeps its category tint instead of the primary identity. Feeds (Memory, Tasks, Session History, Subagent History) are a
  `TronFeed` of `TronFeedCard`s, with the next page loaded by `FeedStore` while 5 rows remain.
  Long feeds overlay a bottom-centred position chip whose 44-pt target takes every touch (tap:
  newest); the feed ends with room to clear it. An empty feed (and an empty
  Profile) is a `TronFeedEmptyState`: caption on top, the shared `TronPlaceholderState` centred
  below, no card.
  Each `TronListRow` has: a centred kind icon or ordinal, the title, one status pill top-right,
  12 pt subtext, then tags and time; a row with neither status nor time carries its tags top-right
  (below the title when both do not fit). Actions are in the detail and a matching long-press menu.
  Instructions subsheet entries are `TronSettingsRow`s: centred icon, trailing source tag.
  Manage Home's Memory subtitle counts catalog messages and current tree-view lines (built
  plus unbuilt), not stored summary nodes or the last activation's frozen view. Chapters
  names the active chapter's soft-limit share: the larger of bytes/24 MiB and entries/50,000.
  Memory summary rows tag exact current-view members; a primary-tinted divider after the
  oldest contiguous individual message explains the resolution change, not exclusion.
  Reads are revisioned snapshots, labelled as such; a new canonical Home snapshot retires
  old pages/cursors and hides stale resolution markers before its replacement read.
  The revision reads AppModel's canonical snapshot forwarding accessor in both hosted
  validation and signed device builds; it does not maintain separate snapshot state.
- Technical detail uses `TronMetadataTable` for metadata and JSON (field, short type, trailing code
  preview; stacked at accessibility sizes); the raw JSON reader is one selectable, wrapping,
  vertically scrolling sheet, never a horizontal viewport.
- Large selectable text (instructions, raw JSON, file previews) uses the read-only TextKit viewer;
  preparation runs off the main actor, keyed to its exact source so coverage reuses it.
- Markdown renders through `TronMarkdownView` from one immutable prepared document.

## Presentation-scoped state

Returning to the app, reconnecting, resyncing or reloading never dismisses a presented sheet,
re-presents it, or clears what it holds: drafts, text fields, terminal output and scrollback,
scroll position, selection, or a nested sheet (#1073). Data updates in place.

The managed source owns a presentation, not a disposable rendering of its content. Native
SwiftUI presentation graphs can otherwise be reconstructed on foregrounding, discarding local
state and replaying nested transitions. Shared owners keep native lifetime and domain state
separate:

- `tronManagedSheet` gives each presentation a `PresentationStateScope` in the scene's
  `PresentationStateStore` (`TronPresentationStateRoot`), keyed by the presenter's scope path plus
  the sheet identity (and an item sheet's `id`). Rebuilt content finds the same scope; an actual
  dismissal or replacement item retires it and every scope presented from inside it. Route
  surfaces (dashboard, chat route) are the parent scope of their sheets. Presenter state is
  keyed by call site (plus the identity string for `isPresented:`; an item sheet's key has no
  item), so a presenter repeated inside one surface (a chip, row or card) passes `instance:`.
  Siblings sharing a key let only the last-rendered one present; the presenter logs a
  `ManagedSheetPresentation` fault when a shared one starts presenting and traps under
  `HOSTED_TEST`.
- Managed sources publish render-input preferences without adding a background view or AX node
  to a control. `TronNativeSheetCanvas`, mounted at each scene/surface root, contains scope-owned
  `RetainedNativeSheetHost` nodes in one retained SwiftUI hosting controller per surface. Native
  sheet nodes mount while their presenters are idle, before the first binding request; the first
  tap changes an existing node rather than installing an already-presenting graph. Home destinations
  share medium/large detents, including Canonical transcript's document chrome. Keeping child
  controllers under a disposable container does not retain their presentations. Hosts forward
  inherited environment and transactions; explicit scene-phase and dependency-read observation keep
  activation/freshness live. Invisible mounting stays outside control labels. Native chrome, detents,
  gestures and focus remain platform-owned. Attached active renders reconcile missing sources;
  transient content disappearance is not retirement. Source/scope/scene retirement clears intent
  and empties retained graphs. No second modal stack, route registry or replay is installed.
- Sheet content declares state that must outlive a rebuild with `@PresentationState`; a view
  appearing more than once in one sheet passes `key:`.
- Sheet-content teardown goes in `PresentationScopedResource.presentationDidRetire()` or
  `.onPresentationRetire { }`, never the content's `onDisappear`. Start hooks are idempotent.
  The source's own disappearance ends its presentation, including conditional schema rows.
- `TerminalEmulatorHost` keeps a sheet's SwiftTerm view, so screen, scrollback, scroll and
  selection survive and no output is replayed.

`packages/ios-app/scripts/presentation-source-policy.py` makes this the default: managed-sheet
content may not declare `@State` unless the line says `// view-local: <reason>`. Native focus
behavior is not overridden. `TronForegroundCaptureUITests` observes native controller lifetime,
retained paging/viewport, keyboard input routing, socket read demand and anchor deallocation in
the hosted UI lane. `RealGatewayPairAndChatUITests/testForegroundAndReconnectKeepSheetsAndTheirContent`
exercises the paired-Gateway path.

## Presentation activity

A scene-owned `PresentationActivityCoordinator` (State) owns the ephemeral stack of mounted
surfaces, including the notice window. It is separate from Gateway session visibility and
canonical state, is never persisted, and is not a second state authority.

- Only the topmost surface gets surface-owned publication, continuous animation and viewport
  work. Its ancestors continue only bounded data publication a visible descendant needs
  (`allowsDataPublication`), so tool output and completion stay current without covered loads,
  polls, automatic presentation, animation or viewport observation.
- Surface tokens are generation-qualified; a bounded tombstone ledger rejects content arriving
  after its generation retired. Binding intent registers a child before its transition, and a
  dismissal lease keeps the retiring generation until SwiftUI's callback. The sheet haptic
  waits for that registered child's content to appear; a request retired unseen is silent
  and reported (`managed-sheet.never-appeared`).
- Disposable loads, media preparation and polls include surface activity in their task identity:
  cover or an inactive scene cancels them, uncover restarts from current inputs. Visible reads
  that need the transport wait for foreground reconciliation; accepted operations do not. Publication rejects cancellation
  (a sent read may throw `GatewayPossiblySentError`, not `CancellationError`) and stale
  ownership. Keep the last complete data.
- Foreground transport recovery continues independently of disposable reads. The foremost
  surface declares required `PresentationRefreshDependency` values: session authority propagates
  down its lineage, queued editing requires the exact session/message, and catalog demand belongs
  only to a surface consuming the roster. Independent Home/global settings and immutable details
  do not restore a covered chat. On reveal, opening readiness checks live subscription authority,
  not just a retained local ready frame; while a reconnect is still reconciling, the model owns
  that restoration, so a foreground never re-covers a retained transcript with its opening
  surface. The dashboard resumes a stale catalog on reveal.
- A schema editor consumes its shared target snapshot through `PresentationDependencyRead`;
  the foremost surface admits the refresh and the settings owner deduplicates it. Providers and
  authorized devices refresh through their visible owners, not an unconditional reconnect pair.
  The dashboard usage card owns its provider-catalog read separately from usage; changed provider
  IDs restart usage without recursively reloading the catalog.
- Compatible read admission changes retain the last complete frame, cursor and viewport until
  replacement data is admitted. New sources clear it; new reads and mutations still require
  current authority. Navigation resets a viewport once per new request, not again on refresh.
- Cover never cancels Gateway intake, sequence admission, canonical reduction, accepted
  mutations, drafts, receipts, terminal connections or notifications. User-started diagnostics
  capture/export also retains result publication across cover or scene inactivity; surface
  retirement and destination authority still fence stale results, and newer share
  intent fences share artifacts and superseded local-capture errors. On uncover each branch's owner installs one current aggregate; chat rebases its viewport once against the newest
  installation and suppresses accumulated entrances; the dashboard publishes one row cut.
