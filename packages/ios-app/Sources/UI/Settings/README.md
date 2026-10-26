# Settings

## Purpose

Mac and iPhone settings, the generic schema renderer shared by all settings surfaces, and management sheets for
providers, models, extensions, hooks, MCP servers, connected services, paired Macs and devices, notifications and logs.

## Owns

- Shell: `SettingsView` (`SettingsGroupKind` groups, `SettingsGroupCard`).
- Renderer: `SettingsRendererView`, `SettingsRendererRow`, `SettingsValueEditors`,
  `SettingsChoiceSlider`, `SettingsAutosave`.
- Audit and approvals: `SettingsChangesView`, `SettingsChangeRow`, `SettingsApprovalSheet`
  and `SettingsApprovalRequestSummary` (in `SettingsApprovalsSection.swift`).
- Agent configuration: `ConfigurationSlider(Surface)`,
  `CustomModelsSettingsView` with `CustomModelDraftTransformation`, `DefaultToolsSettingsSection`.
- Accounts: `ProviderSettingsView`, `ProviderUsageReadController`, `IntegrationsSettingsView`
  (`IntegrationSheetRoutes`), `MCPServersSettingsView`, `ConnectionSettingsView`,
  `PairedDeviceDetailView`, `MacReplacementSheet`.
- Extensions: `ExtensionsSettingsView`, `PackageDetailSheet`, `HooksSettingsView`,
  `ProjectResourcesView`, `TrustSettingsView`.
- This iPhone and diagnostics: `AppearanceSettingsView`, `AppLocalBehaviorSettings`,
  `PushNotificationsSettingsView`, `NotificationInboxView`, `GatewayLogsSettingsView`.

## Contract

- **Layout.** The gear opens one sheet: This iPhone (primary: Appearance, App Customizations),
  Accounts (indigo: Connections, Model Providers, Connected Services),
  Tools & Extensions (cyan: Tools, MCP Servers, Extensions, Hooks),
  System (slate: Agent Settings, Mac Terminal, Push Notifications, Setup, Logs). Agent Settings
  opens one primary-accent sheet with the Model, Workers & delegation, Compaction, Trusted Projects,
  Agent changes and Connection groups in place, not another level of section links. The
  groups are the app's; the Gateway serves schema sections, and unplaced sections join More.
  Models contains direct model/thinking, all three ordered model queues and the task budget.
  Queue drafts add available physical models through the shared picker, reorder/remove locally,
  and write only on Save; an empty list is distinct from Reset/Revert to inheritance. A list
  draft is keyed to its canonical input value so reopening after an accepted Save seeds the new
  list, while local draft changes keep stable row identity.
  Other routine settings have no editor exposure; explicit values retain read-only Reset/Revert and Project inspection. Compaction
  appears only while retained values need inspection or Revert. Scoped More Settings contains
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
  shared Overridden pill beside the row title and Revert after the value.
- **Writes.** Every write is a `settings.change`: dry run first, a refusal shows under its row and
  `confirm` text asks before sending. Secret drafts start empty and clear on dismissal; list and
  numeric-map drafts write only on Save; unknown fields stay read-only. Outside-change recovery
  remains an explicit Apply again action. The Gateway supplies override presence and permissions;
  rows never infer ownership from value equality.
- **Chat and Home settings.** Manage Session and Manage Home open `SessionSettingsView` (scopes:
  Project, Session, Global); Home writes its saved settings, a chat its own Session scope.
  Both reuse Global's renderer and editors. Manage model cards select the three chat-model keys:
  catalog header/Switch Model, Effort and an explicit model-qualified Context Window for inspection/Revert. They use the
  same writes, approvals and Revert path; changing the card changes no scope semantics. The model
  header is one line with a leading CPU glyph and no provider subtitle; model cards omit Overridden.
  Home Settings has one untitled Settings container (Models: workers/delegation only, Tools, More Settings).
  Session Settings has one Settings container (Compaction, Tools, Project Trust, More Settings),
  no Models subsheet. Overridable keys only; Project-owned controls are read-only with “Set by Project settings”;
  explicit overrides have Overridden and circular Revert. `SettingsProjectGroups` shows applied
  Repository Overrides last; `ProjectSettingsSections` owns the unchanged trust editor and ignored
  repository-field notices (no Workspace row in Session Settings). Summaries omit unset values. Trust still uses `TrustSettingsView`; another Mac requires **Use This Server**.
- **Changes.** Only Global has a Changes entry. `SettingsChangesView` pages `settings.history` by
  Project/Session/Global, pins approvals above history and keeps last-look per Mac. Undo and
  Apply again are receipt-backed through `SettingsTrustCoordinator`; outside MCP and custom-model
  entries never show their definition.
- **Approvals.** Chat request/outcome chips, push review and Changes reuse `SettingsApprovalSheet`.
  It re-reads `settings.approvals` and displays the Gateway's exact values or registered action
  preview. Only its red X/green check submits `settings.decide` with that displayed digest through
  `SettingsTrustCoordinator`'s receipt owner; pending has no Done or bottom action bar, and swipe
  dismissal leaves it pending. A two-minute push intent opens current requester candidates, never
  auto-decides. Manage Home/Session have no duplicate waiting sections. Proven receipts and canonical
  outcomes are read-only; missing pending state is not a terminal result. Historical request chips
  resolve a bounded history cut by request ID and every original change ID; incomplete cuts remain
  unavailable. Failure text retains uncertainty and is selectable/wrapping. Global Changes keeps
  fenced Undo for applied/approved values, never registered actions.
- **Providers.** Configured above Available. Connect/Configure opens one sheet showing every
  advertised method; the visible sheet owns the operation's prompts, and an answered choice
  restarts with `replaceOperationId` (`ProviderAuthSelectionTrail`). Usage rows reserve a skeleton
  only when `usageSupported`; `localOnly` shows Unlimited; `usageLentTo` hides the lender row.
  `ProviderUsageLoadingPlaceholder` also wraps dashboard value cells, preserving provider names
  and final column geometry; Reduce Motion keeps the same static rectangles.
- **Models and compaction.** Model names are the catalog's `name`; thinking choices come from the
  model's advertised levels; the default model comes from canonical settings, never catalog order.
  `compaction-policy.v1` adds per-field thinking and focus inheritance.
- **Default Tools.** Global Tools' Always include switches edit `tools.active`. While
  `sources.extensions` keeps the built-in from loading at that scope (Pi's rule: a Project entry
  overrides the Global list), the switch is dimmed, shows Off and says why; the saved entry is kept,
  and the row explains why.
- **Extensions.** Inventory counts, installed packages (Tron's bundled subagents provider without
  Update/Remove), Install Package, read-only Tron Modules and search paths. A package's detail lists
  what it Provides; `conflict` and `nodeRequirement` (#243) show as statuses. Hooks reads
  `hooks.list` (`hooks.v1`) per scope; an untrusted project says its hooks are not loaded.
- **Integrations.** Connected Services and MCP Servers use the Providers row layout; the instance
  ID is the only action identity. Setup accepts only opaque Mac Keychain references (X uses PKCE;
  the Gateway exchanges and stores tokens). Policy writes carry `expectedSetupRevision`. The open
  setup draft lives in `IntegrationSheetRoutes` above the presented content (#932). MCP Servers
  edits Pi's global `mcp.json` only. Jev is a provider credential, not a connection.
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
`ProviderSettingsView.swift`, `IntegrationsSettingsView.swift`, `ConnectionSettingsView.swift`.

## Signals

| Signal | Meaning |
|---|---|
| `xsetup.*` | X setup view, binding, begin and observer boundaries in the iOS log; no client, callback, OAuth or account values |

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
inspection. `TronSmokeUITests` keeps direct model/thinking, shared list/numeric-map editing,
approvals and Changes coverage. The surviving memory/provider/queued-editor journeys in
`TronForegroundCaptureUITests` own native-stack refresh, draft/focus preservation and invalid-child
retirement; retired Worker thinking and Transport editor cases do not define that lifecycle.

Hosted values are scripted, not persistence evidence. Real-UI journeys read their key inventory
from the fixture Gateway's built schema. The [three-layer design](../../../../gateway/docs/settings-three-layer-design.md)
has a capture-only `TronSettingsThreeLayerPreviewTests` fixture: synthetic SwiftUI layouts, not the
implemented settings contract. Before device sign-off, change values rapidly, dismiss while saving
and switch profile: no untouched inherited setting may become an override.

## Not here

Coordinators and settings state: [State](../../State/README.md). Shared row, tint and sheet
rules: [presentation parity](../../../docs/presentation-parity.md#settings-conventions). The
settings model: [Gateway settings model](../../../../gateway/docs/settings-model.md).
