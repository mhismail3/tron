# Automations

## Purpose

The Tron menu and the two sheets it opens over the Sessions dashboard: Automations (list, detail,
run detail, create/edit) and Knowledge.

## Owns

`DashboardModeMenuButton`, `DashboardChrome`, `AutomationsSheet`, `AutomationDetailView`,
`AutomationRunDetailView`, `AutomationFormView`, `AutomationPresentation`,
`AutomationStatusPresentation`, `KnowledgeDashboardView` (`KnowledgeSheet`, the Knowledge settings
editors), `KnowledgeFormSheet`, `KnowledgeMutation`,
`KnowledgeObservationPresentation`.

## Contract

- **Tron menu.** Sessions is the only dashboard. The Tron logo opens one native menu: Settings;
  Automations and Knowledge, each a sheet over the dashboard; New Session. On the Home dashboard
  the one floating Tron button is Home's: a tap opens the Home chat; a 0.2 s hold
  (`menuHoldDuration`) opens the same menu through a menu-primary sibling button, its only
  presenter.
- **Automations sheet.** Medium and large detents; every identity-qualified, connected Gateway
  advertising `automations.v2` contributes rows (others are absent, never a warning). Rows draw
  through the dashboard's shared `DashboardListRow` (action icon, name, schedule · server, trailing
  state or last run). Toolbar New Automation; a floating Filter opens the filter sheet, which owns
  status, action and Gateway choices, persisted with the shell's preferences by
  `AutomationDashboardPreferencesOwner`. No search. Opening a session from an Automation, or a push
  route, dismisses the sheet first. No pull-to-refresh: `automation.changed` drives refresh while
  presented.
- **Reads.** List pages omit action bodies, require one exact catalog revision, and cap each Gateway
  at 1,024 definitions; prompt or notification content comes only from authenticated,
  surface-scoped `automation.get`. iOS builds no schedule engine and infers no execution state; the
  editor uses the Gateway's schedule preview.
- **Targets.** A strict union: Home (`homeId` and `routeGeneration`, plain messages only),
  an existing session, or a workspace with `newPerRun` (prompts only; each run's session is
  an ordinary user session). Home availability reads are disposable and fenced to the
  presentation, selected Gateway connection and foreground generation; editing retains
  the saved route instead of silently rebinding it. Home messages wait through busy,
  paused, disabled, blocked or cooling states; the 60-second cooldown is per automation. Create/edit supports session prompts with
  optional skill/prompt invocations, and notifications to an existing session. New-session interval
  schedules are limited to one run per 24 hours by Gateway policy. Shell, webhook,
  extension-command, attachment, deployment and Gateway lifecycle actions have no UI or wire path.
- **Mutations.** Command IDs through the focused profile's `ConfirmedMutationExecutor`; a background
  Gateway stays read-only until **Use This Gateway**. Run now, enable, cancel, delete and
  uncertain-outcome resolution require confirmation and keep revision fences.
- **Prompt provenance.** A canonical Automation prompt renders in the Automation-accent container
  only with the complete Gateway-authored invocation tuple (`automation:<run UUID>`); partial
  provenance fails closed to the ordinary prompt. Receipt-attributed Home trigger messages
  reuse the inbound context chip as **Automation · name**, opening the full request and
  technical details. They never render as maintainer prompts or approval outcomes.
- **Knowledge sheet.** A bounded, Gateway-authoritative projection with the `Color.tronKnowledge`
  accent, in the Automations sheet's pattern. It lists Sources (thumbnail, title, domain · type),
  Syntheses or Legacy history, filtered by visibility and Personal/Research scope from the toolbar
  Filter, with the shared floating search. iOS creates no Knowledge itself: capture belongs to the
  share extension and agents. One cancellable reconciliation flight plus one continuation; each read fences the
  surface token, Gateway identity, filter/query key and generation. `knowledge.changed` (revision and
  changed IDs, coalesced) drives targeted refresh of up to 64 identities, otherwise a full pass over
  the retained window; reconciliation acknowledges only its captured cut. Search rebuilds to the
  reader's loaded depth in one fresh cursor cut.
- **Knowledge detail.** `KnowledgeDetailSheet` opens at medium, shows one originating-session row,
  and puts revision, range, digest and attribution behind its info button. Source objects load via
  `knowledge.object.read` for the exact record and revision. Citations open the cited entry through
  the history owner. **Needs attention** opens `KnowledgeCoverageDetailSheet` with only pending,
  failed and unavailable cuts (`knowledge-coverage-filter.v1`); Clear uses a revision-fenced receipt.
  Mutations publish the returned record into the open detail before refreshing. Note confirmation
  is explicit. Starting a session from an entry opens New Session and seeds only an unsent draft.
  Source assessment calls `knowledge.source.assess` with `assessor: "model"`. A detail action
  dismisses the Knowledge sheet before New Session or the cited chat presents.
- **Knowledge settings.** Connected Services' Knowledge group opens Current interests
  (`KnowledgeConfigurationView`, `knowledge.config`) and Needs attention
  (`KnowledgeCoverageSheetHost`); a cited session opens through Settings' own route callback.

## Invariants

- No local automation journal, schedule engine or Knowledge corpus cache; Gateway reads are the
  only authority and are fenced per surface.
- Handoffs carry explicit untrusted-evidence wording and never replay or auto-send a prompt.
- Accepted mutations remain with the confirmed executor across dismissal.

## Entry points

`DashboardModeMenuButton.swift`, `DashboardChrome.swift`, `AutomationsSheet.swift`, `AutomationFormView.swift`,
`KnowledgeDashboardView.swift`.

## Signals

None of its own; catalog reads report through the State owners.

## Verify

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronKnowledgeDetailUITests \
  --only-testing TronMobileUITests/TronAccessibilityUITests \
  --only-testing TronMobileUITests/TronSmokeUITests/testAutomationsSheetFromTronMenu \
  --only-testing TronMobileUITests/TronSmokeUITests/testAutomationEditDateControlsVisualParity \
  --only-testing TronMobileUITests/TronSmokeUITests/testDashboardMenuStaysOpenDuringParentUpdates
```

`TronKnowledgeDetailUITests` mounts the production Knowledge sheet over a held byte/socket Gateway
(refresh, continuation, filter-sheet cover, Legacy history, summary and correction receipts).
`TronAccessibilityUITests` drives the real Sessions dashboard: menu entries, the Knowledge sheet
over it, and Knowledge settings in Connected Services. The Automations fixture accepts no
mutations.

## Not here

`AutomationCatalogCoordinator`, `KnowledgeRPCClient` and the Knowledge stores:
[State](../../State/README.md). Knowledge source handling:
[knowledge sources](../../../docs/knowledge-sources.md).
