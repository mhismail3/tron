# Settings

## Purpose

Mac and iPhone settings, and management sheets for
providers, models, extensions, MCP servers, connected services, paired Macs and devices, notifications and logs.

## Owns

- Shell: `SettingsView` (`SettingsGroupKind` groups, `SettingsGroupCard`).
- Choices: `SettingsChoiceSlider`.
- Exact reviews use the shared `ChangeReviewSheet`.
- Agent configuration: `ConfigurationSlider(Surface)`.
- Accounts: `ProviderSettingsView`, `ProviderUsageReadController`, `IntegrationsSettingsView`
  (`IntegrationSheetRoutes`), `MCPServersSettingsView`, `ConnectionSettingsView`,
  `PairedDeviceDetailView`, `MacReplacementSheet`.
- Trust: `TrustSettingsView`.
- This iPhone and diagnostics: `AppearanceSettingsView`, `AppLocalBehaviorSettings`,
  `NotificationInboxView`, `GatewayLogsSettingsView`.

## Contract

- **Layout.** The gear opens one sheet: This iPhone (primary: Appearance, one sheet: Dashboard, Subagent Activity, Color Mode, Theme color, Text Font and Code Font),
  Accounts (primary: Connections, Model Providers),
  Agent & Tools (MCP Servers),
  System (steel blue: Mac Terminal, Setup, Logs). Every category destination
  inherits its group tint for chrome, containers and icons; semantic statuses retain their colors.
  Primary groups use the selected theme's `tronPrimary`; System uses `tronSteel`, not the neutral `tronSlate` role.
  The `trust` group has no Global view; the
  `connections` group (Mac Terminal key and private SSH service) is owned by the Mac Terminal sheet.
  Notifications sit in the toolbar; there is no Value & Source sheet.
  The app has no Trusted Projects list: the agent changes `permissions.projectTrust` and
  `permissions.defaultProjectTrust` behind the native card; the untrusted-project prompt and the
  Project Settings trust row (`TrustSettingsView`) also write `permissions.projectTrust`.
- **Appearance.** Theme selection writes iPhone-local UserDefaults immediately and reloads in
  a fresh process. Emerald, Deep Burgundy and Olive Gold share adaptive primary roles;
  semantic statuses and resource identities do not change with the theme. Explicit theme
  selection also applies its bundled alternate app icon, with iOS's automatic change alert.
  Selection rows serialize while UIKit applies the icon; failure leaves the theme applied and
  explains how to retry. Restores and Light/Dark/Auto changes do not request icon changes.
  Home Screen light/dark/clear/tinted renditions remain system/user-controlled and need not match
  the in-app color mode. Section layouts use
  `TronSettingsSections`, including conditional groups. Settings subsheets
  opt in with `hidesLoneHeading: true`: one container has no heading, multiple containers retain
  their headings, and explanatory detail remains. Top-level settings keep all group headings.
- **Settings rows.** The shared settings row places Reset/Revert before the value: the value pill is
  rightmost, with independent 44-point targets. Overrides show the shared Overridden pill beside the row title.
- **Writes.** Every write is a `settings.change`: dry run first, a refusal shows under its row and
  `confirm` text asks before sending. Secret drafts start empty and clear on dismissal; string-list
  drafts write only on Save. Numeric-map list controls use read-only value/provenance rows instead of
  a native form; agents configure them through `settings`, including the shared native card for a
  task-budget raise and logged Undo for
  reversible changes. Unknown fields stay read-only. Model cards share the pending
  receipt and the session owner's admission state with `ModelSelectionAvailability`: model browsing
  stays available while choices, Revert and picker reset are disabled. Their existing change gate
  still serializes writes; no presentation value grants mutation authority. Outside-change recovery
  remains an explicit inline Apply again action beneath the same value control, not a row-opening
  detail link. The real-Gateway outside-change journey verifies the live value, receipt-backed restore
  and marker removal on that row. The Gateway supplies override presence and permissions;
  rows never infer ownership from value equality.
- **Manage Home and the chat model card.** Manage Home lists Controls (`HomeControlsSection`) and Task
  Permissions (`HomeTaskSheet(permissionsFor:)`) as navigation rows beside Profile, Memory, Chapters and Tasks.
  The chat model card (`ManageModelConfigurationCard`, `session-model-summary` or `home-model-summary`) reads
  `settings.resolve` for the three chat-model keys. Switch Model lists the catalog, Thinking lists the session's
  thinking levels, and Context Window lists the selected model's limits. Writes are `settings.change` at the
  chat's Session scope (Home writes its saved settings). A Project-owned value is read-only and names its file.
  The Project sheet keeps the trust row (`TrustSettingsView`) and the Workspace row; the app does not show
  repository overrides, which the settings tool inspects.
- **Changes.** The app has no settings audit view; the agent pages `history` and `undo` through the
  `settings` tool, and the durable record stays under `~/.tron`.
- **Exact reviews.** The maintainer's own edits apply directly; picking the value the edited
  layer already stores sends nothing, while picking an inherited or default value pins it there. A row whose dry run requires a
  tap (trust, privacy or spend widening, installs, irreversible effects) opens the shared
  `ChangeReviewSheet`; Approve commits once bound to the shown digest, Cancel sends nothing.
  The shared card, its actions and native review title use `tronPrimary`, including read-only
  history. Generic questions retain their own accent; theme never changes approval authority.
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
  source editor, guided draft and JSON draft do not mirror that file.
  Model-registry activation still needs a maintainer-initiated Gateway restart; file edits do
  not promise hot reload.
  `compaction-policy.v1` adds per-field thinking and focus inheritance.
- **Tools and extensions.** Global Settings has no Tools, Extensions or package rows: the agent
  changes `tools.*` and `sources.*` (installs and enables behind the native card), updates a
  package with the `settings` tool's `update`, and reads packages, modules and hooks through
  `inventory`. Session and Home Tools sections stay.
- **MCP.** MCP Servers uses the Providers row layout and edits Pi's global `mcp.json`
  only, through `settings.change` on `tools.mcp.server` with each row's `mcp.list` `value`:
  it previews the change and shows the shared `ChangeReviewSheet` when the preview taps
  (add, enable, new address or bearer reference, wider visibility). A bearer token goes
  only to `mcp.token.set`, whose Keychain reference the change then carries. A server whose
  configuration the change path cannot carry offers sign-in and sign-out only; it is edited in `mcp.json` on the Mac. Add and auth
  drafts and an approved change retain the exact destination and receipt owner. Jev is a provider credential, not a connection. Retired Connected
  Services, X OAuth/credits and Raindrop setup have no native route or consumer.
- **Connections and devices.** Paired Macs then authorized devices, each opening its own detail
  sheet. Device rename (`device-label.v1`), source/install (`ios-device-install.v3`) and Gateway
  update, promote, rollback and **Rebuild from Source** need the focused profile (**Use This
  Server** first). Rebuild is user-initiated only: agents never press it or submit its RPC. Status
  polling is command-bound and stops at terminal state, reconnect or disappearance. Maintenance
  action containers inherit the sheet theme; Forget Server keeps semantic red.
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

`SettingsView.swift`,
`ProviderSettingsView.swift`, `MCPServersSettingsView.swift`, `ConnectionSettingsView.swift`.

## Verify

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronIntegrationSheetsUITests \
  --only-testing TronMobileUITests/TronMCPServerSheetsUITests \
  --only-testing TronMobileUITests/TronProjectTrustUITests \
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
inspection. `TronSmokeUITests` keeps direct model/thinking and shared string-list editing,
read-only numeric-map/no-write inspection and approvals coverage.
`TronAgentBehaviorRegressionUITests` checks numeric-map values without native editor/reset routes in
light/dark and XXXL; Gateway `native-change.e2e.test.ts` owns actual agent numeric-map changes,
next-Pi-session admission, spend-card acceptance and Undo. Its painted-geometry journey measures the primitive and generic
schema controls at both text sizes and appearances; background sampling stays outside the whole
action cluster so a left-hand reset cannot sample its neighboring value pill.
The surviving memory/provider/queued-editor journeys in
`TronForegroundCaptureUITests` own native-stack refresh, draft/focus preservation and invalid-child
retirement; retired Worker thinking and Transport editor cases do not define that lifecycle.

`TronAgentBehaviorRegressionUITests` exercises the production Global sheet over the hosted
socket; it checks numeric-map values, retired rows, Global/Session value/reset order and captures both appearances. Hosted values are scripted,
not persistence evidence. Real-UI journeys read their key inventory
from the fixture Gateway's built schema. Before device sign-off, change values rapidly, dismiss while saving
and switch profile: no untouched inherited setting may become an override.

## Not here

Coordinators and settings state: [State](../../State/README.md). Shared row, tint and sheet
rules: [presentation parity](../../../docs/presentation-parity.md#settings-conventions). The
settings model: [Gateway settings model](../../../../gateway/docs/settings-model.md).
