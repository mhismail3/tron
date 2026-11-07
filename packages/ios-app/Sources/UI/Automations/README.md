# Automations

## Purpose

The Tron menu and the Automations sheet (list, detail, run detail, create/edit) over the Sessions dashboard.

## Owns

`DashboardModeMenuButton`, `DashboardChrome`, `AutomationsSheet`, `AutomationDetailView`,
`AutomationRunDetailView`, `AutomationFormView`, `AutomationPresentation`,
`AutomationStatusPresentation`, `KnowledgeFormSheet` and `KnowledgeMutation` (shared form/accepted-mutation primitives used by surviving settings and auth).

## Contract

- **Tron menu.** Sessions is the only dashboard. The Tron logo opens one native menu: Settings;
  Automations and Apps, each a sheet over the dashboard; New Session. On the Home dashboard
  the one floating Tron button is Home's: a tap opens the Home chat; a 0.2 s hold
  (`menuHoldDuration`) opens the same menu through a menu-primary sibling button, its only
  presenter.
- **Dashboard title.** `DashboardChrome` hides the navigation bar and draws the "Tron" title in
  the top safe-area inset. In iPadOS windowed mode the title row drops by the window's top-leading
  container corner inset (`containerCornerInsets`) so the system window controls never overlap it,
  at rest or collapsed. Without window controls that inset is zero and the layout is unchanged.
- **Automations sheet.** Medium and large detents; every identity-qualified, connected Gateway
  advertising `automations.v2` contributes rows (others are absent, never a warning). Active
  Automations list first, then paused, drafts and finished ones (attention, running, next
  occurrence, name, ID within each group). `AutomationInventory` projects every row's strings once
  per sheet body evaluation, never while rows scroll; an equatable lazy list draws them as shared `TronListRow` feed cards
  (action icon, name with one status pill, cadence, Gateway tag, last run). Toolbar New Automation; a floating Filter opens the filter sheet, which owns
  status, action and Gateway choices, persisted with the shell's preferences by
  `AutomationDashboardPreferencesOwner`. No search. Opening a session from an Automation, or a push
  route, dismisses the sheet first. No pull-to-refresh: `automation.changed` drives refresh while
  presented.
- **Styling.** Automations follow the user's primary theme; only attention and failure read
  red and success green. Detail and run detail open with a header card (name, status pill,
  context) and read their facts as titled settings groups of title-over-value rows, named as
  the editor's sections are (Basics, Action, Target, Schedule, Behavior); controls are standard
  action rows with Delete last and red. The editor uses the same rows, with text entries under
  their row title. Its sections are not lazy: scrolling a lazy stack of these mixed-height
  editor cards looped layout on the main thread.
- **Expiry.** Every automation may have an expiry, displayed in detail. Expired
  automations remain visible but cannot run or enable. Home uses the normal inventory
  and editor; there are no monitor-specific restrictions or controls.
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
- **Prompt provenance.** A canonical Automation prompt renders in the prompt container under an
  Automation label only with the complete Gateway-authored invocation tuple (`automation:<run UUID>`); partial
  provenance fails closed to the ordinary prompt. Receipt-attributed Home trigger messages
  reuse the inbound context chip as **Automation · name**, opening the full request and
  technical details. They never render as maintainer prompts or approval outcomes.
- **Research files.** No Knowledge library, search, source detail or coverage settings route exists. Profile keeps its separate Home sheets and command owner.

## Invariants

- No local automation journal or schedule engine; Gateway reads are the
  only authority and are fenced per surface.
- Handoffs carry explicit untrusted-evidence wording and never replay or auto-send a prompt.
- Accepted mutations remain with the confirmed executor across dismissal.

## Entry points

`DashboardModeMenuButton.swift`, `DashboardChrome.swift`, `AutomationsSheet.swift`, `AutomationFormView.swift`.

## Signals

None of its own; catalog reads report through the State owners.

## Verify

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronAccessibilityUITests \
  --only-testing TronMobileUITests/TronSmokeUITests/testAutomationsSheetFromTronMenu \
  --only-testing TronMobileUITests/TronSmokeUITests/testAutomationsListActiveBeforePaused \
  --only-testing TronMobileUITests/TronSmokeUITests/testAutomationEditDateControlsVisualParity \
  --only-testing TronMobileUITests/TronSmokeUITests/testDashboardMenuStaysOpenDuringParentUpdates \
  --only-testing TronMobileUITests/TronDashboardWindowControlsUITests
```

`TronAccessibilityUITests` drives the real dashboard destinations and checks that Knowledge is absent from the menu and Connected Services in Light/Dark/large type. The parent-update menu journey retains its Automations selection and thirty-update witness. The Automations fixture accepts no mutations.
Explicit, non-gating: `TronAutomationsVisualUITests` captures list, detail, run detail and editor
in light, dark and XXXL for design review; `TronAutomationsListPerformanceUITests` measures app
CPU and memory while flinging through 400 Automations (`-automation-large`).
`TronDashboardWindowControlsUITests` checks that the title sits below the status bar in a
full-screen window (the canonical iPhone lane, full-screen iPad). On an iPad
simulator in Windowed Apps mode it also resizes the window and checks the title clears the
controls at rest and collapsed; no lane runs iPad, so run that destination by hand.

## Not here

`AutomationCatalogCoordinator`: [State](../../State/README.md). Ordinary research files:
[knowledge sources](../../../docs/knowledge-sources.md).
