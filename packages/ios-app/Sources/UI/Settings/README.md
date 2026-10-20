# Settings

## Purpose

Settings for this Mac and this iPhone, the generic schema renderer every settings surface uses,
and the management sheets for providers, models, extensions, hooks, MCP servers, connected
services, paired Macs and devices, notifications and logs.

## Owns

- Shell: `SettingsView` (`SettingsGroupKind` groups, `SettingsGroupCard`).
- Renderer: `SettingsRendererView`, `SettingsRendererRow`, `SettingsValueEditors`,
  `SettingsChoiceSlider`, `SettingsNumberSlider`, `SettingsConfigurationValueRow`, `SettingsAutosave`.
- Audit and approvals: `SettingsChangesView`, `SettingsChangeRow`, `SettingsApprovalsSection`.
- Agent configuration: `AgentConfigurationControls`, `ConfigurationSlider(Surface)`,
  `CustomModelsSettingsView` with `CustomModelDraftTransformation`, `DefaultToolsSettingsSection`.
- Accounts: `ProviderSettingsView`, `ProviderUsageReadController`, `IntegrationsSettingsView`
  (`IntegrationSheetRoutes`), `MCPServersSettingsView`, `ConnectionSettingsView`,
  `PairedDeviceDetailView`, `MacReplacementSheet`.
- Extensions: `ExtensionsSettingsView`, `PackageDetailSheet`, `HooksSettingsView`,
  `ProjectResourcesView`, `TrustSettingsView`.
- This iPhone and diagnostics: `AppearanceSettingsView`, `AppLocalBehaviorSettings`,
  `PushNotificationsSettingsView`, `NotificationInboxView`, `GatewayLogsSettingsView`.

## Contract

- **Layout.** The gear opens one sheet: This iPhone (emerald: Appearance, App Customizations),
  Accounts (indigo: Connections, Model Providers, Connected Services), Agent (purple: Models,
  Compaction, Trusted Projects, More Settings), Tools & Extensions (cyan: Tools, MCP Servers, Extensions, Hooks),
  System (slate: Mac Terminal, Push Notifications, Setup, Logs). The
  groups are the app's; the Gateway serves schema sections, and unplaced sections join More.
  Notifications and Changes sit in the toolbar. Dashboard Settings exposes only global scope.
  Trusted Projects owns the default trust policy and per-project trust; Add Project records the
  chosen folder as Not trusted through `settings.change`.
- **Renderer.** Sends `SettingsRendererContract` version 1 (`toggle`, `choice`, `number`, `text`,
  `secret`, `list`, `catalog`, `readOnly`) with `settings.resolve` and renders sections in Gateway
  order. An unimplemented control renders its `display` read-only, an unknown badge is neutral, an
  undeclared group shows under its id: a value is never hidden. Options come from
  `settings.options`, re-requested when a `dependsOn` key changes; catalog pages fence every
  completion and stop on repeated cursors. Choices open picker sheets of `TronCatalogOptionRow`
  (native menus fail inside nested sheets, #877); numbers and ordered choices use the shared
  anchored slider with Gateway-served bounds. `chatInline` metadata owns section placement.
- **Writes.** Every write is a `settings.change`: dry run first, a refusal shows under its row and
  `confirm` text asks before sending. Secret drafts start empty and clear on dismissal; list and
  numeric-map drafts write only on Save; unknown fields stay read-only. Source badges may carry
  `useCurrentDefault`, `followDefault` or `applyAgain`; unknown actions stay display-only. Rows
  outside the resolver's allowed layers are read-only links to their editor.
- **Chat and Home settings.** Manage Session and Manage Home open `SessionSettingsView`: Home
  resolves a `home` target and edits `profile`, ordinary chats edit `chat`. Each has one read-only
  Configuration destination; Manage Session keeps the live Models and Available Tools editors, so
  Session Settings never duplicates them. Project Settings (`ProjectSettingsContent`) lists actual
  repository overrides read-only and requires **Use This Server** for another Mac.
- **Changes.** `SettingsChangesView` pages `settings.history`, intersects filters with the
  surface's scope, pins approvals above history, and keeps last-look per Mac and scope. Undo and
  Apply again are receipt-backed through `SettingsTrustCoordinator`; outside MCP and custom-model
  entries never show their definition.
- **Approvals.** `SettingsApprovalsSection` re-reads `settings.approvals` on its revision and
  decides with `settings.decide` bound to the request digest, showing only Gateway text. It is
  mounted in both Manage Home and Manage Session. The `settings-approval` push stages a decision for
  two minutes; one matching request still needs an explicit confirmation tap.
- **Providers.** Configured above Available. Connect/Configure opens one sheet showing every
  advertised method; the visible sheet owns the operation's prompts, and an answered choice
  restarts with `replaceOperationId` (`ProviderAuthSelectionTrail`). Usage rows reserve a skeleton
  only when `usageSupported`; `localOnly` shows Unlimited; `usageLentTo` hides the lender row.
- **Models and compaction.** Model names are the catalog's `name`; thinking choices come from the
  model's advertised levels; the default model comes from canonical settings, never catalog order.
  `compaction-policy.v1` adds per-field thinking and focus inheritance.
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
  polling is command-bound and stops at terminal state, reconnect or disappearance.
- **Logs.** Gateway records are fetched only while Logs is presented, merged with the iOS client
  ring, refreshed every 15 s while visible, and exported through Export Diagnostics.
- **Reloads.** Visible reads include `foregroundReconciliationGeneration` in their task identity,
  so foreground replaces stale offline errors without retrying or replaying mutations.

## Invariants

- No per-key native editors, defaults, placement lists or guidance: the Gateway schema is the
  single source, and nothing is hidden.
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
  --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testChatSettingsServeEveryKeyAndEditAtChatLayer \
  --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testMacSettingsServeEveryKeyAndEditAtMacLayer \
  --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testProjectSettingsExposeReadOnlyOverrides
```

Hosted values are scripted: they prove routes and receipts, not persistence. The real-UI journeys
read their key inventory from the fixture Gateway's built schema. Visual reviews
(`testSettingsScopeVisualReviewInLightAndDark`) only capture; before device sign-off, change values
rapidly, dismiss while saving and switch profile: no untouched inherited setting may become an
override.

## Not here

Coordinators and settings state: [State](../../State/README.md). Shared row, tint and sheet
rules: [presentation parity](../../../docs/presentation-parity.md#settings-conventions). The
settings model: [Gateway settings model](../../../../gateway/docs/settings-model.md).
