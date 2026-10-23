# Presentation

## Purpose

The shared presentation layer every feature composes: theme, typography, sheet chrome and the
reusable components. Its binding rules are [presentation parity](../../docs/presentation-parity.md).

## Owns

- `Theme/`: `TronPresentation` (app-wide boundary: managed sheets, settings rows and groups,
  confirmations, loading, top blur, toolbar tint), `TronTheme`, `ThemeColor`, `FontSettings`, `TronFontLoader`,
  `TronSettingControls`, `TronDateControls` (`TronDateValueButton`, `TronDatePickerSheet`, shared by
  Automations and Home), `TronCardRail`, `TronDisclosure`, `TronContentFitDetent`, `TronWidthCap`,
  `TronSafariView`.
- `Components/`: `TronDocumentSheet`, `TronList` (the list standard), `TronTextEntrySheet`, `StructuredJSONView`,
  `TechnicalDetailPresentation`, `TronNativeSheetCanvas` (surface-level native containment for
  State-scoped `RetainedNativeSheetHost` graphs), `InAppNoticePresentation` (`InAppNoticeHost`),
  `ProcessActivityOrb`, `ResourceTagLabel`, `ThinkingLevelPresentation`, `TronHaptics` (the app's one
  haptic seam; hosted journeys read `TronHapticsProbe`).

The feature folders under `UI/` are their own modules with their own READMEs: [Chat](Chat/README.md),
[Settings](Settings/README.md), [Automations](Automations/README.md),
[Onboarding](Onboarding/README.md), [Terminal](Terminal/README.md), [Swift apps](SwiftApps/README.md).

## Contract

- Components are presentation only: they take values and emit intents, own no Gateway reads,
  receipts or canonical state. Native sheet sources are preference inputs, not views inside controls;
  `TronNativeSheetCanvas` mounts retained ordinary SwiftUI sheets at the containing surface root.
- One owner per pattern: a new or changed pattern changes the shared component and
  [presentation parity](../../docs/presentation-parity.md) together.
- Fonts are built from descriptors and reused, bounded, by every input that shapes them; adaptive
  palette colors parse their hex once and select by interface style only when resolved.
- Appearance stores the app's primary identity in `AppearanceSettings.themeColor`: Emerald,
  Deep Burgundy or Olive Gold. `Color.tronPrimary` reads that observable owner; ink, title,
  icon, container and pill tint share the adaptive ink without recreating navigation or chats.
  Semantic status and resource identities stay independent. `TronSettingsGroup.sectionCount`
  suppresses the heading for a declared single-container sheet while preserving its detail.
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
- Managed sheets and system pickers dispatch one medium, full-intensity impact through
  `TronHaptics` on a live presentation, including nested sheets. Existing-at-mount sheets,
  replacements, detent changes, re-renders and dismissals are silent. Question interactions
  keep only their live attention cue; automatic onboarding and pending editor requests are silent.

## Haptic map

`Components/TronHaptics.swift` owns all generators. View-bound feedback respects System Haptics
and foreground activity. User-intent closures, not value observers, own control feedback.

| Event | Interaction | Generator / intensity | Why |
| --- | --- | --- | --- |
| `sheetPresented` | Shared live sheet presentation, when its content appears; system picker on request | Medium impact / full | A perceptible lift, without a sharp rigid snap; a refused or deferred request is silent until shown |
| `toggleChanged` | Shared toggle rows and schema renderer switches | Selection | One mechanical flip; no ticks on server/restored values |
| `selectionChanged` | Choice picker change; checklist add/remove | Selection | A detent, not a completion; choosing the current value is silent |
| `copied` | Message Copy (menu/AX); code-block Copy | Light impact / full | A small confirmation after the clipboard write |
| `answerSubmitted` | Accepted Ask form answer | Success notification | Confirms the Gateway accepted the atomic response; cancel stays silent |
| `actionFailed` | Rejected composer transport in the active chat | Error notification | Distinguishes refusal from an accepted send; cancellation stays silent |
| `terminalBell` | Existing terminal bell | Warning notification | Preserves the bell through the shared seam, foreground only |
| `menuOpened` | Tron-button hold opens menu | Medium impact / full | Marks the hold threshold, not the initial touch |
| `promptSent` | Gateway accepts prompt | Light impact / full | Marks acceptance |
| `attachmentAdded` | Newly attached items | Selection, up to six 70 ms apart | A bounded insertion cascade |
| `runFinished` | Live normal run completion | Success notification | Distinct completion |
| `workerMessage` | Live worker result in the open chat | Soft impact / full | Subtler than the main agent completion |
| `questionPresented` | Live input-needed sheet | Rigid impact / full | Attention only, never stacked with a presentation impact |

Scrolling, loads, reconnects, restored/replayed/background events, duplicate arrivals, sheet
resize/dismiss/restore and checklist Save are silent. Save only forwards a draft, so it must not
claim durable success. Destructive warnings and Home arrival cues are intentionally not added:
confirmations already communicate risk and another arrival cue could duplicate chat attention.
Physical feel and System Haptics off require a device; simulator journeys observe semantic output.

## Entry points

`Theme/TronPresentation.swift`, `Components/TronDocumentSheet.swift`, `Components/TronList.swift`.

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
scripts/tron-ios-test run --only-testing TronMobileUITests/TronChatHapticsUITests \
  --only-testing TronMobileUITests/TronInteractionHapticsUITests \
  --only-testing TronMobileUITests/TronSubsheetReliabilityUITests
```

The loading journey samples rendered material, not accessibility geometry; the paged-list journey
covers failure, retry and scroll retention. The source policy rejects raw sheets, system alerts
and stock loading placeholders. Typography, motion and Reduce Motion are reviewed on a device.

## Not here

Presentation-lifetime state and the surface activity stack live in [State](../State/README.md);
their rules are in [presentation parity](../../docs/presentation-parity.md).
