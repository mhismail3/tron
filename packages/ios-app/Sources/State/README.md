# State

## Purpose

The app's authoritative UI projection and its owners: the Gateway lifecycle, the mounted session,
the dashboard catalog, accepted-mutation receipts, drafts, and the per-domain coordinators that
feature UI reads. Canonical truth stays in the Gateway and Pi; everything here is a bounded,
disposable projection or an in-flight command owner.

## Owns

| Owner | Responsibility |
|---|---|
| `AppModel` | Shrinking MainActor composition façade: cross-owner orchestration, mounting and revocation, global error publication, navigation results. It stores no parallel lifecycle, token, snapshot graph or projection mirror. |
| `GatewayLifecycleCoordinator` | Enrollment, focused profile, connection state and identity, reconnect, foreground reconciliation, serial retire/close, teardown. |
| `DashboardGatewayConnectionPool` | Shallow catalog connections for the other paired Macs. |
| `SessionPresentationStore` | The mounted session: target, subscription lease, synchronization, cursor, paging, presentation lease, process activity, session-keyed secondary reads. |
| `SessionCatalogCoordinator`, `AutomationDashboardPreferencesOwner` (`DashboardStateOwners`) | Dashboard rows per `(profileID, sessionID)`; Automations sheet preferences. |
| `ConfirmedMutationExecutor`, `SessionMutationService`, `SessionImportCoordinator` | Receipt policy for every mutation; session command DTOs; file import under one captured lifecycle. |
| `ComposerDraftCoordinator`, `ComposerDraftStore` | Composer text, staged resources, annotations, attachments, uploads, submission. |
| `ChatMediaLoader`, `SessionExportArtifactStore` | Transcript media by `(profile, lifecycle, blob)`; export artifacts. |
| `TerminalCoordinator`, `TerminalReducer` | Session terminals: wire, presentation intents, attach/replay, resize. |
| `MacTerminalController`, `MacTerminalEnrollmentStore` | Mac Terminal enrollment and shells ([Terminal](../UI/Terminal/README.md)). |
| `SettingsTrustCoordinator` | Settings resolve/change/history/approvals and project trust. |
| `ProviderAuthCoordinator` | Provider/model catalogs, auth operations and prompts, MCP sign-in. |
| `PackageConfigurationCoordinator`, `CustomModelConfigurationCoordinator`, `ConfigurationAutosaveCoordinator` | Packages, custom models, autosaved configuration writes. |
| `HomeStatusPresentationOwner`, `HomeSheetReadOwner`, `HomeMutationCoordinator` | Home status, Home sheet reads, Home commands. |
| `AutomationCatalogCoordinator`, `AutomationRPCClient` | Automation summaries per Gateway. |
| `KnowledgeRPCClient`, `KnowledgePresentationStores`, `KnowledgePreviewStore` | Knowledge reads and receipted mutations. |
| `IntegrationsRPCClient` | Connection-owner projections and mutations. |
| `SessionHistoryStore`, `SessionProcessHistoryStore`, `ReadOnlySubagentSessionStore`, `PagedListStore` | History pages, subagent history, read-only child transcripts, shared paging. |
| `PresentationActivityCoordinator`, `PresentationScopedState` | Mounted-surface stack and presentation-lifetime state ([parity](../../docs/presentation-parity.md#presentation-activity)). |
| `InAppNoticeCenter` | The one in-app notice queue. |
| `SnapshotCache` | Disposable session-summary cache. |
| `AppDiagnostics`, `IOSMetricKitDiagnostics`, `GatewayDiagnosticsService` | Client log ring, Logs collection and export, MetricKit summaries, Git/log reads. |

## Contract

- **Connection and events** follow [Gateway connection and events](../../docs/events.md):
  lifecycle, reconnect schedule, receipts and session synchronization are specified there.
- **Typed targets.** Settings, providers, packages and custom models use typed `.global`,
  `.project(cwd:)`, `.workspace(cwd:)` or `.session(id:)` targets. Global reads never inherit the
  selected session's project; a newer same-target read rejects an older completion.
- **Settings.** Read only through `settings.resolve` and written only through `settings.change`
  ([settings model](../../../gateway/docs/settings-model.md)); hand-built screens send schema keys
  with `SettingsTarget.keyChange`, so iOS holds no settings-path table. Trust is the
  `permissions.projectTrust` key. `SettingsTrustCoordinator` keeps one bounded `SettingsSnapshot`
  per target that every renderer for that target reads; generic edits dry-run first.
- **Autosave.** `ConfigurationAutosaveCoordinator` admits writes only from user input, debounces,
  serializes, merges sparse patches per target, retains up to 64 batches (then rejects visibly),
  flushes on dismissal without cancelling accepted commands, and never auto-retries an uncertain
  outcome.
- **Provider auth.** Operations belong to the device identity; a 4-operation, 64-element,
  16 KiB pre-response quarantine admits events that arrive before `auth.begin` returns. Lost
  operations recover through `auth.begin` (`recovered: true`) and `replaceOperationId`; unsent input
  is memory-only and never resubmitted. Provider pages are bounded (1,000 rows, 4 MiB strings),
  model pages too (50 pages, 25,000 models, 16 MiB, 500 per page), published atomically per target.
  Usage is a separate `provider-usage.v1` read, never merged with session usage.
- **Drafts.** `ComposerDraftScope(profileID, sessionID)` keys text, staged resources and unsent
  attachments with monotonic revisions and a 24-inactive-draft LRU. `ComposerDraftStore` persists
  ≤ 256 KiB text plus the 10-item / 25 MiB attachment budget under a 24-draft / 256 MiB disk LRU
  (metadata manifest, digest-verified payload files, atomic swap). Text above the Gateway's
  192 KiB limit is rejected before any clearing. Staged upload IDs survive remount and reconnect to
  the same Mac (#916) and are never persisted.
- **Submission.** Admission installs one outgoing row synchronously; a definite rejection restores
  the exact draft; a possibly-sent outcome keeps the row and receipt; a runtime replacement before
  canonical delivery restores the draft for review and never replays.
- **Catalog.** User-scope 500-row pages, at most 50 pages / 25,000 identities, published only
  when complete. One traversal with a dirty bit absorbs invalidations; a mixed revision restarts
  silently once. The warning appears after three consecutive current-owner failures without
  stopping retry; projection failures never recycle a responsive socket.
- **Archive.** `session-archive.v1` owns membership. Archived rows come only from
  `archived: "only"` pages under a per-surface latest-request fence and are never cached; the count
  is summed per capable profile and never fabricated as zero.
- **Home.** `HomeStatusPresentationOwner` holds only the focused Gateway's in-memory status,
  read by the mounted surface's exact token; `HomeChatRouteKey.matches` decides whether a route
  claims Home. `HomeMutationCoordinator` is the sole Home command authority, receipt-only:
  `missing`/`pending` receipts never replay and one unresolved command per profile stays owned until
  an explicit completion check. `HomeSheetReadOwner` owns one disposable read per managed sheet.
- **Notices.** `InAppNoticeCenter` holds at most eight notices, 4 KiB each and 16 KiB total, FIFO,
  one card at a time; dwell 2–12 s (4 s normal, 8 s errors) on the injected clock. Notices are
  informational and scope-retired with their owner.
- **Cache.** `SnapshotCache` persists only ≤ 250 unique bounded summaries (128 KiB each, file
  < 8 MiB, backup-excluded, complete-until-first-authentication). It never stores transcripts or
  archived rows. Only catalog changes write it; live summaries coalesce into one trailing save;
  backgrounding writes inside the draft checkpoint's assertion.

## Invariants

- One authority per fact: no second lifecycle phase, receipt map, queue mirror or event journal.
- Every disposable read captures and rechecks profile, lifecycle generation, connection epoch,
  managed presentation activity and latest request across each await.
- Accepted mutations stay with their receipt owner across dismissal, cover and reconnect; nothing
  replays a command whose outcome is uncertain.
- Profile retirement synchronously revokes suspended work, presentation intake and provider auth;
  A → B → A replacement cannot resurrect stale work.
- Interrupted prompts are never replayed automatically.

## Entry points

`AppModel.swift`, `GatewayLifecycleCoordinator.swift`, `SessionPresentationStore.swift`,
`DashboardStateOwners.swift`, `ConfirmedMutationExecutor.swift`, `ComposerDraftCoordinator.swift`.

## Signals

| Signal | Meaning |
|---|---|
| `gateway.catalog` | Catalog admission and terminal decisions with generations, failure, page, revision and retry budget |
| `reconnect.parked` | Recovery parked on an unsatisfied path; resumes at the 30 s probe |
| `reconnect.skipped` | A reconnect request refused by a named guard |
| `model.catalog.rejected` | A model page refused: page, schema path and finite reason, never values |
| iOS client ring | 200 in-memory records (including typed decode failures) merged into Logs as `iOS client` |

## Verify

State is exercised through hosted journeys over a scripted Gateway socket and the real-Gateway
lane ([runbook](../../docs/development.md#efficient-focused-tests)):

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronIntegrationSheetsUITests/testEstablishedSocketLossThenOpenTimeoutsBecomeUnreachable \
  --only-testing TronMobileUITests/TronIntegrationSheetsUITests/testSecondaryRecoverySurvivesBackgroundAndResetsOnlyOnRetryOrSuccess \
  --only-testing TronMobileUITests/TronIntegrationSheetsUITests/testRetryConnectionRecoversReconnectingDetails
scripts/ios-gateway-e2e-test all
scripts/ios-gateway-e2e-test run-ui --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testInvitationLinkPairsCompletesSetupStreamsAndReconnectsAfterBackground
```

The first set drives the selected lifecycle and dashboard pool with a byte transport and an
accelerated clock. The real-UI journey keeps the mounted chat, draft and keyboard through a proxy
blackhole and a held replacement open. Gateway catalog bounds are owned by
`runtime-registry.integration.test.ts`.

## Not here

Transport and wire models: [Core](../../Core/README.md). Shared presentation rules:
[presentation parity](../../docs/presentation-parity.md). Rendering of chats, settings and
dashboards: the feature modules under [`Sources/UI`](../UI/README.md).
