# Settings

## Purpose

Mac and iPhone settings, the generic schema renderer shared by all settings surfaces, and management sheets for
providers, models, extensions, hooks, MCP servers, connected services, paired Macs and devices, notifications and logs.

## Owns

- Shell: `SettingsView` (`SettingsGroupKind` groups, `SettingsGroupCard`).
- Renderer: `SettingsRendererView`, `SettingsRendererRow`, `SettingsValueEditors`,
  `SettingsChoiceSlider`, `SettingsAutosave`.
- Audit: `SettingsChangesView`, `SettingsChangeRow`; exact reviews use the shared
  `ChangeReviewSheet`.
- Agent configuration: `ConfigurationSlider(Surface)`,
  `DefaultToolsSettingsSection`.
- Accounts: `ProviderSettingsView`, `ProviderUsageReadController`, `IntegrationsSettingsView`
  (`IntegrationSheetRoutes`), `MCPServersSettingsView`, `ConnectionSettingsView`,
  `PairedDeviceDetailView`, `MacReplacementSheet`.
- Extensions: `ExtensionsSettingsView`, `PackageDetailSheet`, `HooksSettingsView`,
  `ProjectResourcesView`, `TrustSettingsView`.
- This iPhone and diagnostics: `AppearanceSettingsView`, `AppLocalBehaviorSettings`,
  `PushNotificationsSettingsView`, `NotificationInboxView`, `GatewayLogsSettingsView`.

## Contract

- **Layout.** The gear opens one sheet: This iPhone (primary: Appearance, App Customizations),
  Accounts (indigo: Connections, Model Providers),
  Agent & Tools (the fixed Emerald identity ink: Agent Behavior first, Tools, MCP Servers, Extensions, Hooks),
  System (steel blue: Mac Terminal, Push Notifications, Setup, Logs). Every category destination
  inherits its group tint for chrome, containers and icons; semantic statuses retain their colors.
  Emerald uses `ThemeColor.emerald.ink`; System uses `tronSteel`, not the neutral `tronSlate` role.
  Agent Behavior opens one emerald-accent sheet with the Model, Workers & delegation, Compaction, Trusted Projects,
  Agent changes and Connection groups in place, not another level of section links. Each
  group keeps its shared section heading, without section-description text. Trusted Projects
  uses the shared settings row so its icon inherits the same sheet tint; known settings use
  semantic glyphs in the shared renderer, with control-kind glyphs for unknown keys. The
  groups are the app's; the Gateway serves schema sections, and unplaced sections join More.
  Model contains direct model/thinking; Workers & delegation contains all three ordered model queues
  and the task budget. Scoped Home navigation still names its workers/delegation destination Models.
  Queue drafts add available physical models through the shared picker, reorder/remove locally,
  and write only on Save; an empty list is distinct from Reset/Revert to inheritance. The retained
  list editor is keyed by its canonical input so reopening reflects accepted saves. Local changes
  keep stable row identity until Save; the renderer’s existing presentation gate controls refresh.
  Other routine settings have no editor exposure; explicit values retain read-only Reset/Revert and Project inspection.
  Automatic compaction and Summary thinking are excluded by the shared iPhone row selection even
  when saved; canonical Gateway values, scope rules and writers are unchanged. Other Compaction
  values appear only while retained values need inspection or Revert. Scoped More Settings contains
  Agent changes and the HTTP proxy; Global embeds those groups directly. There is no Advanced section. Trusted Projects and the server's Mac Terminal section consume their declared
  groups without duplicating them in More Settings.
  Notifications and Changes sit in the toolbar; no Value & Source sheet. Dashboard Settings
  exposes only Global: editable keys plus explicit read-only values with Reset and Project inspection.
  Trusted Projects owns the default trust policy and per-project trust; Add Project records the
  chosen folder as Not trusted through `settings.change`, a folder inside a listed project too
  (the nearest saved decision governs).
- **Appearance.** Theme selection writes iPhone-local UserDefaults immediately and reloads in
  a fresh process. Emerald, Deep Burgundy and Olive Gold share adaptive primary roles;
  semantic statuses and resource identities do not change with the theme. Explicit theme
  selection also applies its bundled alternate app icon, with iOS's automatic change alert.
  Selection rows serialize while UIKit applies the icon; failure leaves the theme applied and
  explains how to retry. Restores and Light/Dark/Auto changes do not request icon changes.
  Home Screen light/dark/clear/tinted renditions remain system/user-controlled and need not match
  the in-app color mode. Section layouts use
  `TronSettingsSections`, including renderer-driven and conditional groups. Settings subsheets
  opt in with `hidesLoneHeading: true`: one container has no heading, multiple containers retain
  their headings, and explanatory detail remains. Top-level settings keep all group headings.
- **Renderer.** Sends `SettingsRendererContract` version 1 (`toggle`, `choice`, `text`,
  `secret`, `list`, `catalog`, `readOnly`) with `settings.resolve` and renders sections in Gateway
  order. An unimplemented control renders its `display` read-only; an
  undeclared group shows under its id. The Gateway declaration owns row exposure. Options come from
  `settings.options`, re-requested when a `dependsOn` key changes; catalog pages fence every
  completion and stop on repeated cursors. Choices open picker sheets of `TronCatalogOptionRow`
  (native menus fail inside nested sheets, #877); ordered choices use the shared
  anchored slider with Gateway-served choices; a tap anywhere outside it closes and saves it, even
  below a short embedded section. Embedded renderers inherit the enclosing sheet's slider host;
  only standalone renderers install one, so the editor uses the sheet viewport rather than its card.
  Session and Home retain their scope-specific section drill-in rows; overrides show the
  shared Overridden pill beside the row title. The shared settings row places Reset/Revert
  before the value: the value pill is rightmost, with independent 44-point targets.
- **Writes.** Every write is a `settings.change`: dry run first, a refusal shows under its row and
  `confirm` text asks before sending. Secret drafts start empty and clear on dismissal; string-list
  drafts write only on Save. Numeric-map list controls use read-only value/provenance rows instead of
  a native form; agents configure them through `settings`, including the shared native card for a
  task-budget raise and logged Undo for
  reversible changes. Unknown fields stay read-only. Outside-change recovery
  remains an explicit inline Apply again action beneath the same value control, not a row-opening
  detail link. The real-Gateway outside-change journey verifies the live value, receipt-backed restore
  and marker removal on that row. The Gateway supplies override presence and permissions;
  rows never infer ownership from value equality.
- **Chat and Home settings.** Manage Session and Manage Home open `SessionSettingsView` (scopes:
  Project, Session, Global); Home writes its saved settings, a chat its own Session scope.
  Both reuse Global's renderer and editors. Manage model cards select the three chat-model keys:
  catalog header/Switch Model, Effort and an explicit model-qualified Context Window for inspection/Revert. They use the
  same writes, approvals and Revert path; changing the card changes no scope semantics. The model
  header is one line with a leading CPU glyph and no provider subtitle; model cards omit Overridden.
  Home Settings embeds the former Models, Tools and More Settings sections directly under logical
  headers, keeping its introductory caption. Only that first level is flattened: shared row editors,
  pickers, source inspection and Revert stay unchanged. Worker settings render independently of
  delegation permission reads; an uninitialized task namespace must not hide saved profile editors.
  Session Settings has one untitled container (Compaction, Tools, Project Trust, More Settings),
  with its Global-inheritance caption immediately below as a footer;
  no Models subsheet. Overridable keys only; Project-owned controls are read-only with “Set by Project settings”;
  explicit overrides have Overridden and circular Revert. `SettingsProjectGroups` shows applied
  Repository Overrides last; `ProjectSettingsSections` owns the unchanged trust editor and ignored
  repository-field notices (no Workspace row in Session Settings). Summaries omit unset values. Trust still uses `TrustSettingsView`; another Mac requires **Use This Server**.
- **Changes.** Only Global has a Changes entry. `SettingsChangesView` pages `settings.history` by
  Project/Session/Global and keeps last-look per Mac. Undo and
  Apply again are receipt-backed through `SettingsTrustCoordinator`; outside MCP and custom-model
  entries never show their definition.
- **Exact reviews.** The maintainer's own edits apply directly. A row whose dry run requires a
  tap (trust, privacy or spend widening, installs, irreversible effects) opens the shared
  `ChangeReviewSheet`; Approve commits once bound to the shown digest, Cancel sends nothing.
- **Providers.** Configured above Available. Connect/Configure opens one sheet showing every
  advertised method; the visible sheet owns the operation's prompts, and an answered choice
  restarts with `replaceOperationId` (`ProviderAuthSelectionTrail`). Usage rows reserve a skeleton
  only when `usageSupported`; `localOnly` shows Unlimited; `usageLentTo` hides the lender row.
  `ProviderUsageLoadingPlaceholder` also wraps dashboard value cells, preserving provider names
  and final column geometry; Reduce Motion keeps the same static rectangles.
- **Models and compaction.** Model names are the catalog's `name`; thinking choices come from the
  model's advertised levels; the default model comes from canonical settings, never catalog order.
  Providers retains credentials, usage and catalog Refresh, not a separate custom-definition editor.
  Agents edit Pi's canonical `<tronHome>/agent/models.json` through the existing file tools;
  the Gateway keeps validation, redaction, outside-change history and model loading. A native
  source editor, guided draft, JSON draft and autosave coordinator do not mirror that file.
  Model-registry activation still needs a maintainer-initiated Gateway restart; file edits do
  not promise hot reload.
  `compaction-policy.v1` adds per-field thinking and focus inheritance.
- **Default Tools.** Global Tools' Always include switches edit `tools.active`. While
  `sources.extensions` keeps the built-in from loading at that scope (Pi's rule: a Project entry
  overrides the Global list), the switch is dimmed, shows Off and says why; the saved entry is kept,
  and the row explains why.
- **Extensions.** Inventory counts, installed packages (Tron's bundled subagents provider without
  Update/Remove), Install Package, read-only Tron Modules and search paths. A package's detail lists
  what it Provides; `conflict` and `nodeRequirement` (#243) show as statuses. Hooks reads
  `hooks.list` (`hooks.v1`) per scope; an untrusted project says its hooks are not loaded.
- **MCP.** MCP Servers uses the Providers row layout and edits Pi's global `mcp.json`
  only. Its add/auth drafts and accepted token follow-up retain the exact destination
  and receipt owner. Jev is a provider credential, not a connection. Retired Connected
  Services, X OAuth/credits and Raindrop setup have no native route or consumer.
- **Connections and devices.** Paired Macs then authorized devices, each opening its own detail
  sheet. Device rename (`device-label.v1`), source/install (`ios-device-install.v3`) and Gateway
  update, promote, rollback and **Rebuild from Source** need the focused profile (**Use This
  Server** first). Rebuild is user-initiated only: agents never press it or submit its RPC. Status
  polling is command-bound and stops at terminal state, reconnect or disappearance. Maintenance
  action containers inherit the sheet theme; Forget Server keeps semantic red. The selected
  server shows its Gateway-declared Mac Terminal key using the standard renderer;
  other servers require Use This Server before exposing this control-plane setting.
- **Logs.** Gateway records are fetched only while Logs is presented, merged with the iOS client
  ring, refreshed every 15 s while visible, and exported through Export Diagnostics.
- **Reloads.** Visible reads include `foregroundReconciliationGeneration` in their task identity,
  so foreground replaces stale offline errors without retrying or replaying mutations.

## Invariants

- No per-key native editors, defaults, placement lists or guidance: the Gateway schema is the
  single source for editing exposure, retained overrides and Project inspection.
- Opening or dismissing a sheet never writes.
- Accepted mutations stay with their receipt owner; presentation reads are disposable and fenced.
- iOS never handles provider tokens or credential values.

## Entry points

`SettingsView.swift`, `SettingsRendererView.swift`, `SettingsChangesView.swift`,
`ProviderSettingsView.swift`, `MCPServersSettingsView.swift`, `ConnectionSettingsView.swift`.

## Verify

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronExtensionsSettingsUITests \
  --only-testing TronMobileUITests/TronIntegrationSheetsUITests \
  --only-testing TronMobileUITests/TronMCPServerSheetsUITests \
  --only-testing TronMobileUITests/TronProjectTrustUITests \
  --only-testing TronMobileUITests/TronSettingsChangesReviewUITests \
  --only-testing TronMobileUITests/TronDiagnosticsExportUITests \
  --only-testing TronMobileUITests/TronSmokeUITests/testSettingsRowInspectionAndActionsStayIndependent \
  --only-testing TronMobileUITests/TronSmokeUITests/testIphoneDashboardPreferencesPersistAcrossRoutesAndRelaunch
scripts/ios-gateway-e2e-test run-ui \
  --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testRoutineEditorsDisappearAndExplicitGlobalValueResets \
  --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testSessionSettingsOmitsInheritedRoutineEditors \
  --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testGlobalSettingsServeExposedEditorsAndEditAtGlobalScope \
  --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testProjectSettingsExposeReadOnlyOverrides
```

`TronSettingsScopeRowsUITests` checks read-only queue values, independent Revert and Project
inspection. `TronSmokeUITests` keeps direct model/thinking, shared string-list/secret editing,
read-only numeric-map/no-write inspection, approvals and Changes coverage.
`TronAgentBehaviorRegressionUITests` checks numeric-map values without native editor/reset routes in
light/dark and XXXL; Gateway `native-change.e2e.test.ts` owns actual agent numeric-map changes,
next-Pi-session admission, spend-card acceptance and Undo. Its painted-geometry journey measures the primitive and generic
schema controls at both text sizes and appearances; background sampling stays outside the whole
action cluster so a left-hand reset cannot sample its neighboring value pill.
The surviving memory/provider/queued-editor journeys in
`TronForegroundCaptureUITests` own native-stack refresh, draft/focus preservation and invalid-child
retirement; retired Worker thinking and Transport editor cases do not define that lifecycle.

`TronAgentBehaviorRegressionUITests` exercises the production Global sheet, medium-first
project list, error/Retry and missing-response recovery over the hosted socket; it also checks
Global/Session value/reset order and captures both appearances. Hosted values are scripted,
not persistence evidence. Real-UI journeys read their key inventory
from the fixture Gateway's built schema. The [three-layer design](../../../../gateway/docs/settings-three-layer-design.md)
has a capture-only `TronSettingsThreeLayerPreviewTests` fixture: synthetic SwiftUI layouts, not the
implemented settings contract. Before device sign-off, change values rapidly, dismiss while saving
and switch profile: no untouched inherited setting may become an override.

## Project lifecycle presentation

`ProjectLifecyclePages.swift` owns the project list, Add/Create, details and Rename
presentation. Lists use `TronListGroup`/`TronListRow` without chevrons; fields keep
shared settings controls. Drill-ins use managed sub-sheets, never push routes.
Callers supply project paths, effective trust, archive refusal reasons, form bindings,
destinations and effect closures. The views do not infer eligibility or submit RPCs.
`TrustedProjectsSettingsView` is the single Global entrypoint into these sheets, using
`TronProgressiveSheetLink`'s medium-first/large-expandable presentation.
`ProjectLifecycleView` refreshes disposable `projects.list`/`projects.inspect`
projections on re-entry, reconnect and existing settings/trust/approval revisions;
profile, activity and generation fences retire stale reads. Saved outside folders
remain visible/read-only with Gateway reasons. The list omits the Gateway's hidden
archive namespace and saved deny tombstones whose inspection returns `not_found`;
these trust records remain untouched. Choose Existing only inspects: it never writes
an untrusted decision or creates a second project store.
`SettingsTrustCoordinator` sends `projects.change` through its existing receipt
executor, with a fresh command ID per call. The review creates nothing and opens the
shared `ChangeReviewSheet`; its Approve resubmits the exact digest and typed intent,
which the Gateway revalidates before effects. No agent-tool fallback is used.

`TronProjectLifecyclePreviewUITests` exercises these production-owned views through
`HOSTED_TEST`'s `HostedProjectLifecyclePreview` in light/dark at Large and XXXL.
Sample paths, drafts, busy reasons and the preview-only disclaimer stay in the fixture.
Archive, Untrust, Trust and Rename review reuse `ChangeReviewSheet` with synthetic
reviews; the preview sends no command. The route journey
opens and dismisses detail, rename, approval, Add/Create and folder sub-sheets.
Captures and route checks are not real-Gateway lifecycle acceptance.
`RealGatewayProjectLifecycleUITests` owns separate approve/move/archive, denial,
post-archive/departed-list and linked-worktree busy journeys through the real socket
and canonical filesystem/trust store. The harness seeds only its isolated busy repository; no real GitHub is created.

## Not here

Coordinators and settings state: [State](../../State/README.md). Shared row, tint and sheet
rules: [presentation parity](../../../docs/presentation-parity.md#settings-conventions). The
settings model: [Gateway settings model](../../../../gateway/docs/settings-model.md).
