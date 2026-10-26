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
  Deep Burgundy or Olive Gold. The same `ThemeColor` enum owns bundled app-icon names and
  light/dark ink; `packages/ios-app/scripts/generate-theme-icons.sh` compiles it to generate Icon Composer
  variants and alternate-icon build settings. `AppearanceSettings.selectTheme` persists the
  explicit selection and requests its bundled icon through UIKit, serializing that operation.
  It never changes icons on restoration, foregrounding or color-mode switches. An icon failure
  preserves the selected in-app theme and allows an explicit retry; no second saved icon choice.
  `Color.tronPrimary` reads that observable owner; ink, title,
  icon, container and pill tint share the adaptive ink without recreating navigation or chats.
  Dark Burgundy separates saturated purple-leaning `tronPrimary` ink from deep-wine
  `tronPrimarySurface` glass tint. Home dashboard surfaces and the Home/settings sheet family
  consume those canonical roles; light Burgundy and other themes resolve both to the same ink.
  Dark Burgundy primary ink has a 3:1 rendered contrast floor, an explicit WCAG AA exception
  for small primary-colored text; light retains 4.5:1.
  `TronSettingsVisualTheme` carries foreground and surface accents together through inherited
  destinations; an explicit semantic accent keeps its own surface unless one is supplied.
  Semantic status and resource identities stay independent. UIKit inputs refresh primary ink
  on update, not only creation. Composer placeholders use the shared muted text role, not
  saturated primary ink. Normal usage labels, context-ring arcs and Changes states use primary;
  warning and failure colors remain semantic. Memory kind icons use smaller primary symbols.
  `ProcessActivityOrb` defaults to primary ink for both solving dots and thinking strands;
  dashboard activity and the composer's active/recent activity and extension-content glyph
  share that identity. Their geometry, motion and neutral glass surfaces stay unchanged.
- Section headings are visible by default, including dashboard and top-level Settings groups.
  Settings drill-in pages opt in with `TronSettingsSections(hidesLoneHeading: true)`;
  only a structurally lone section loses its heading, never its explanatory detail.
  `TronSettingsSections` counts structural section slots before eager or lazy layout; it supplies
  the count to groups and custom `tronSectionHeading` labels. Standalone captions opt out of
  the count with `containerValue`; attached captions stay with their section. Each presentation
  surface resets the scope, so a single-section child never inherits its parent’s section count.
  `TronListGroup` likewise hides a lone heading/count only in an opted-in subsheet.
- `ResourceTagLabel` is the one capsule for distribution (External, Module, Local) and scope
  (User, Project) tags; Project takes precedence and the tags are mutually exclusive.
- `InAppNoticeHost` renders the State-owned notice center in one non-key, pass-through window per
  scene above sheets: one card, 24-point corners, 240 ms transitions (180 ms fade under Reduce
  Motion), swipe or accessibility dismissal, no buttons. Success, progress and information icons/glass
  accents follow `tronPrimary`; warnings and errors retain semantic amber/red.
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

`TronMobileUITests/TronThemeIconUITests/testThemeSelectionAppliesBundledIconsAndRestoresSilently`
uses the production Appearance view, the built iPhone/iPad icon declarations and UIKit's native
selected icon (read by a hosted-only fixture); it selects all three themes and relaunches the app.
`TronThemeIconPreviewUITests` captures the dashboard mark and Appearance in every theme/mode
for visual review. These are not physical-device or notification-icon guarantees.

Activity primary ink is checked against the rendered primary title/plus across all themes,
light/dark, dashboard working dots and composer active/recent/extension states:
`TronMobileUITests/TronActivityPrimaryColorUITests/testActivityInkFollowsPrimaryThemeLightAndDark`.
Wine glass hue, native ink contrast and unchanged light ink are checked through Home → Home
Settings by `TronMobileUITests/TronBurgundyGlassUITests/testWineGlassKeepsInkReadableAndLightBurgundyUnchanged`.

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
