# Swift apps

## Purpose

Hosts interpreted single-file SwiftUI apps in Tron's chrome: the inline display card, the runner
sheet and the node views that turn interpreter values into SwiftUI.

## Owns

`SwiftAppDisplayCard`, `SwiftAppRunnerSheet`, `SwiftAppViews`, `SwiftAppNodeViews`,
`InstalledAppsSheet` and `SwiftAppInstallReviewSheet` (including its pending-offer loader).

## Contract

- The interpreter is the separate static module `TronSwiftAppEngine`, which imports only system
  frameworks and nothing of Tron's presentation, state or Core; this module is its only host.
- The feature, supported subset, card and safety contract are specified in
  [Swift apps](../../../docs/swift-apps.md).
- Apps whose root owns its navigation (a TabView) use `TronDocumentSheet` with
  `hostsNavigation: false`; interpreted alerts use the shared confirmation sheets.

## Invariants

- No Tron state or presentation types cross into the interpreter.
- Apps pending rows use the shared primary-theme list standard. They open the
  existing source/access review; listing or opening never installs. The retained
  Apps state owner coordinates explicit installation, not the sheet task.
- Source/access review has Info and Install/Update controls, not Done; it dismisses
  by dragging its own navigation bar. Hosted journeys retain the failed-command
  refusal before dismissing review and checking installed source/data removal.
  Same-offer reinstallation opens the original producing session by its exact
  offer reference after the dashboard admits that row, before any scrolling.

## Entry points

`SwiftAppRunnerSheet.swift`, `SwiftAppDisplayCard.swift`.

## Signals

None of its own.

## Verify

The `TronSwiftAppUITests` target's journeys and commands:
[Swift apps validation](../../../docs/swift-apps.md#validation).

## Not here

The interpreter: `SwiftAppEngine/`. Display routing: [Chat](../Chat/README.md).
