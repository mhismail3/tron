# Swift apps

## Purpose

Hosts interpreted single-file SwiftUI apps in Tron's chrome: the inline display card, the runner
sheet and the node views that turn interpreter values into SwiftUI.

## Owns

`SwiftAppDisplayCard`, `SwiftAppRunnerSheet`, `SwiftAppViews`, `SwiftAppNodeViews`,
`InstalledAppsSheet`. Gateway native access admission replaces install review.

## Contract

- The interpreter is the separate static module `TronSwiftAppEngine`, which imports only system
  frameworks and nothing of Tron's presentation, state or Core; this module is its only host.
- The feature, supported subset, card and safety contract are specified in
  [Swift apps](../../../docs/swift-apps.md).
- Apps whose root owns its navigation (a TabView) use `TronDocumentSheet` with
  `hostsNavigation: false`; interpreted alerts use the shared confirmation sheets.

## Invariants

- No Tron state or presentation types cross into the interpreter.
- Catalog rows use the shared primary-theme list standard. Native first-open
  access is separate from listing. Client file deletion is not shipped; saved
  values have an independent lifetime and require separate authorization to clear.

## Entry points

`SwiftAppRunnerSheet.swift`, `SwiftAppDisplayCard.swift`.

## Signals

None of its own.

## Verify

The `TronSwiftAppUITests` target's journeys and commands:
[Swift apps validation](../../../docs/swift-apps.md#validation).

## Not here

The interpreter: `SwiftAppEngine/`. Display routing: [Chat](../Chat/README.md).
