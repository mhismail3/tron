# Presentation

## Purpose

The shared presentation layer every feature composes: theme, typography, sheet chrome and the
reusable components. Its binding rules are [presentation parity](../../docs/presentation-parity.md).

## Owns

- `Theme/`: `TronPresentation` (app-wide boundary: managed sheets, settings rows and groups,
  confirmations, loading, top blur, toolbar tint), `TronTheme`, `FontSettings`, `TronFontLoader`,
  `TronSettingControls`, `TronDateControls` (`TronDateValueButton`, `TronDatePickerSheet`, shared by
  Automations and Home), `TronCardRail`, `TronDisclosure`, `TronContentFitDetent`, `TronWidthCap`,
  `TronSafariView`.
- `Components/`: `TronDocumentSheet`, `TronPagedList`, `TronTextEntrySheet`, `StructuredJSONView`,
  `TechnicalDetailPresentation`, `InAppNoticePresentation` (`InAppNoticeHost`),
  `ProcessActivityOrb`, `ResourceTagLabel`, `ThinkingLevelPresentation`.

The feature folders under `UI/` are their own modules with their own READMEs: [Chat](Chat/README.md),
[Settings](Settings/README.md), [Automations](Automations/README.md),
[Onboarding](Onboarding/README.md), [Terminal](Terminal/README.md), [Swift apps](SwiftApps/README.md).

## Contract

- Components are presentation only: they take values and emit intents, own no Gateway reads,
  receipts or canonical state.
- One owner per pattern: a new or changed pattern changes the shared component and
  [presentation parity](../../docs/presentation-parity.md) together.
- Fonts are built from descriptors and reused, bounded, by every input that shapes them; adaptive
  palette colors parse their hex once and select by interface style only when resolved.
- `ResourceTagLabel` is the one capsule for distribution (External, Module, Local) and scope
  (User, Project) tags; Project takes precedence and the tags are mutually exclusive.
- `InAppNoticeHost` renders the State-owned notice center in one non-key, pass-through window per
  scene above sheets: one card, 24-point corners, 240 ms transitions (180 ms fade under Reduce
  Motion), swipe or accessibility dismissal, no buttons.
- `ThinkingLevelPresentation` renders `xhigh` and its variants as **Extra High** everywhere without
  rewriting wire values.

## Invariants

- Toolbar icons resolve tint through `TronSheetTint`; nothing paints them directly.
- Every app-owned sheet goes through the managed modifiers; raw `.sheet` calls fail
  `packages/ios-app/scripts/test-source-policy.sh`.

## Entry points

`Theme/TronPresentation.swift`, `Components/TronDocumentSheet.swift`, `Components/TronPagedList.swift`.

## Signals

None.

## Verify

```bash
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronSmokeUITests/testHomeSheetLoadingSurfaceRemainsFullWidth \
  --only-testing TronMobileUITests/TronHomeSheetsUITests/testHomeCursorPagesRetryAndRetainScroll \
  --only-testing TronMobileUITests/TronSheetTintUITests \
  --only-testing TronMobileUITests/TronAccessibilityUITests
packages/ios-app/scripts/test-source-policy.sh
```

The loading journey samples rendered material, not accessibility geometry; the paged-list journey
covers failure, retry and scroll retention. The source policy rejects raw sheets, system alerts
and stock loading placeholders. Typography, motion and Reduce Motion are reviewed on a device.

## Not here

Presentation-lifetime state and the surface activity stack live in [State](../State/README.md);
their rules are in [presentation parity](../../docs/presentation-parity.md).
