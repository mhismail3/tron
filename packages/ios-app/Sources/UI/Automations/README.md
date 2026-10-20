# Automations

## Purpose

The dashboard selector and the two non-session surfaces it reaches: the Automations sheet
(list, detail, run detail, create/edit) and the Knowledge dashboard.

## Owns

`DashboardModeMenuButton`, `DashboardChrome`, `AutomationsSheet`, `AutomationDetailView`,
`AutomationRunDetailView`, `AutomationFormView`, `AutomationPresentation`,
`AutomationStatusPresentation`, `KnowledgeDashboardView`, `KnowledgeFormSheet`, `KnowledgeMutation`,
`KnowledgeObservationPresentation`.

## Contract

- **Dashboard selector.** The Tron logo opens a native mode menu; the shell switches on an
  exhaustive `DashboardMode` (Sessions, Knowledge), so a new mode cannot silently fall back to
  Sessions. Each mode keeps independent root state. The menu's Automations entry is not a mode: it
  presents the Automations sheet over whichever dashboard is showing. On the Home dashboard the one
  floating Tron button is Home's: a tap opens the Home chat; a 0.2 s hold (`menuHoldDuration`)
  opens the same menu through a menu-primary sibling button, its only presenter.
- **Automations sheet.** Medium and large detents; every identity-qualified, connected Gateway
  advertising `automations.v2` contributes rows (others are absent, never a warning). Floating
  search, toolbar New Automation and Filter; the filter sheet owns status, action and Gateway
  choices, persisted with the shell's preferences by `AutomationDashboardPreferencesOwner` (search
  text stays presentation-only). Opening a session from an Automation, or a push route, dismisses
  the sheet first. No pull-to-refresh: `automation.changed` drives refresh while presented.
- **Reads.** List pages omit action bodies, require one exact catalog revision, and cap each Gateway
  at 1,024 definitions; prompt or notification content comes only from authenticated,
  surface-scoped `automation.get`. iOS builds no schedule engine and infers no execution state; the
  editor uses the Gateway's schedule preview.
- **Targets.** A strict union: an existing session, or a workspace with `newPerRun` (prompts only;
  each run's session is an ordinary user session). Create/edit supports session prompts with
  optional skill/prompt invocations, and notifications to an existing session. New-session interval
  schedules are limited to one run per 24 hours by Gateway policy. Shell, webhook,
  extension-command, attachment, deployment and Gateway lifecycle actions have no UI or wire path.
- **Mutations.** Command IDs through the focused profile's `ConfirmedMutationExecutor`; a background
  Gateway stays read-only until **Use This Gateway**. Run now, enable, cancel, delete and
  uncertain-outcome resolution require confirmation and keep revision fences.
- **Prompt provenance.** A canonical Automation prompt renders in the Automation-accent container
  only with the complete Gateway-authored invocation tuple (`automation:<run UUID>`); partial
  provenance fails closed to the ordinary prompt.
- **Knowledge dashboard.** A bounded, Gateway-authoritative projection with the `Color.tronKnowledge`
  accent. It lists All Knowledge (including links), filtered by record kind and Personal/Research
  scope, densely. One cancellable reconciliation flight plus one continuation; each read fences the
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
  Source assessment calls `knowledge.source.assess` with `assessor: "model"`.

## Invariants

- No local automation journal, schedule engine or Knowledge corpus cache; Gateway reads are the
  only authority and are fenced per surface.
- Handoffs carry explicit untrusted-evidence wording and never replay or auto-send a prompt.
- Accepted mutations remain with the confirmed executor across dismissal.

## Entry points

`DashboardModeMenuButton.swift`, `AutomationsSheet.swift`, `AutomationFormView.swift`,
`KnowledgeDashboardView.swift`.

## Signals

None of its own; catalog reads report through the State owners.

## Verify

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronKnowledgeDetailUITests \
  --only-testing TronMobileUITests/TronSmokeUITests/testAutomationsSheetFromTronMenu \
  --only-testing TronMobileUITests/TronSmokeUITests/testAutomationEditDateControlsVisualParity \
  --only-testing TronMobileUITests/TronSmokeUITests/testKnowledgeSettingsSubmenuStaysOpenDuringParentUpdates
```

`TronKnowledgeDetailUITests` mounts the production dashboard over a held byte/socket Gateway
(refresh, continuation, filter-sheet cover, Legacy history, summary and correction receipts).
`TronAccessibilityUITests` pulls the real dashboard heading. The Automations fixture accepts no
mutations.

## Not here

`AutomationCatalogCoordinator`, `KnowledgeRPCClient` and the Knowledge stores:
[State](../../State/README.md). Knowledge source handling:
[knowledge sources](../../../docs/knowledge-sources.md).
