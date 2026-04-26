---
paths:
  - "**/Onboarding/**"
  - "**/OnboardingState*"
  - "**/Pairing*"
  - "**/PresetTokenStore*"
  - "**/Binding+PasteAware*"
---

# Onboarding

First-run iOS onboarding is a concise swipeable sheet presented above
the normal dashboard. It is not a full-screen wizard.

## High-Level Flow

```
readyContent()
  ├─ always mounts ContentView
  └─ if onboardingComplete == false:
       present OnboardingFlowView as a medium-detent sheet

OnboardingFlowView
  ├─ Welcome page
  ├─ Mac install link page
  └─ PairingStep

OnboardingState.complete()
  └─ defaults.set(true, completionStorageKey)
```

## Persistence

| Key | Type | Storage | Reset by |
|-----|------|---------|----------|
| `onboardingComplete` | Bool | `@AppStorage` + injected UserDefaults | `OnboardingState.reset()` + forgetting the final server preset |
| `cachedConnectionPresets` | Data (JSON) | UserDefaults.standard | `SettingsState.replaceConnectionPresets(_:)` |

All onboarding-specific keys are exposed as `nonisolated static let` on
`OnboardingState`. Never duplicate the literal strings.

`telemetryEnabled` is intentionally owned by
`SettingsState.telemetryEnabledStorageKey`; telemetry is a Privacy
Settings concern, not an onboarding concern.

`@AppStorage` is intentionally backed by `UserDefaults.standard`, not
`NSUbiquitousKeyValueStore`. Cross-device iCloud sync of the gate would
mark an unpaired peer device as onboarded.

## Step Model

`OnboardingState.Step` owns the three onboarding pages:
`welcome -> installMac -> connect`. The step exists only to drive the
sheet's `TabView` selection and the `X / Y` counter. Pairing side effects
still live exclusively on the connect page.

`acceptPairingPayload(_:)` must jump to `.connect` because deep links,
QR scans, and pasted pairing URLs should all reveal the populated
pairing form immediately.

## Pairing Path

The pairing step performs three duties separated into pure helpers:

1. `PairingStepValidator.validate(host:port:token:label:)` trims and
   validates the form, returning `Result<PairingPayload, Failure>`.
2. `dependencies.pairingProbe.probe(host:port:token:)` opens a
   one-shot WebSocket upgrade with `Authorization: Bearer <token>`,
   sends `system.ping`, ignores unrelated event frames such as the
   server's initial `connection.established`, matches the response by
   request id, and returns `.ok | .unauthorized | .incompatible |
   .unreachable`.
3. `PairingPersistor.plan(payload:existing:)` returns the side-effect
   plan: active preset, token, host/port, and updated presets.

The view applies the plan in this order: Keychain write → local preset
cache → `dependencies.updateServerSettings(host:port:)` → best-effort
`settings.update` → `state.complete()`.

Universal-paste detection lives in
`Sources/Extensions/Binding+PasteAware.swift`. `PairingStep` and
`AddOrEditServerSheet` share the helper, so a full
`tron://pair?host=…&port=…&token=…[&label=…]` link can be pasted into
any field.

Deep-link pairing URLs are intercepted by `TronMobileApp.onOpenURL`
before `DeepLinkRouter`; the app fills the pairing form and presents the
sheet at the large detent.

QR scanning is handled by `QRCodeScannerSheet`, which returns the raw
QR string. `PairingStep` parses it with `PairingURLParser` and applies
the resulting payload through `OnboardingState.acceptPairingPayload(_:)`.

## Re-Entrancy

- Form fields are intentionally transient. Killing mid-form drops typed
  values; the user re-types, scans, or pastes.
- `pairing` only completes after probe + persist succeed.

## Per-Preset Bearer Tokens

`PresetTokenStore` wraps `KeychainItem` to give each
`ConnectionPreset.id` its own bearer token slot at
`com.tron.mobile.bearer.<presetId>`. Re-pair overwrites the token for
the preset; preset removal deletes it.

Forgetting a preset from Settings → Server uses
`ConnectionPresetRemoval.plan(...)`: inactive removal keeps the current
server, active removal switches to the next saved server, and removing
the final preset clears the first-run gate so onboarding reopens. The
view also unregisters the APNs device token from the active Mac before
switching away.

## Key Files

| File | Purpose |
|------|---------|
| `App/TronMobileApp.swift` | Dashboard root + onboarding sheet presentation |
| `Views/Onboarding/OnboardingFlowView.swift` | Three-page onboarding sheet root |
| `Views/Onboarding/OnboardingShell.swift` | Shared page/card/button chrome |
| `Views/Onboarding/QRCodeScannerSheet.swift` | Camera QR scanner for Mac pairing URLs |
| `Views/Onboarding/Steps/PairingStep.swift` | Pairing form + connect action |
| `ViewModels/State/OnboardingState.swift` | `@Observable` step/form state + completion key |
| `Services/Onboarding/PairingStepValidator.swift` | Pure trim + classify |
| `Services/Onboarding/PairingProbe.swift` | One-shot WS bearer probe + `system.ping` |
| `Services/Onboarding/PairingPersistor.swift` | Pure plan: Keychain + cache + RPC update |
| `Services/Settings/ConnectionPresetRemoval.swift` | Pure plan for forgetting paired Macs |
| `Services/PairingURLParser.swift` | `tron://pair?…` parse + URL builder |
| `Services/Storage/KeychainItem.swift` | Generic Keychain wrapper |
| `Services/Storage/PresetTokenStore.swift` | Per-preset bearer registry |
| `Extensions/Binding+PasteAware.swift` | Universal-paste helper |

## Rules

- `ContentView` must mount even when onboarding is incomplete.
- Pre-pairing pages on iOS stay concise. The Mac app still owns Mac
  installation, Tailscale detection, and macOS permission setup.
- Do not add a separate route stack. `OnboardingState.Step` is only the
  three-page sheet selection.
- Pure helpers (`Validator`, `Persistor`, `URLParser`) take primitives
  only — no DI container, no SwiftUI.
- Pairing storage keys live exactly once on `OnboardingState` /
  `SettingsState`.
- Universal-paste detection only runs inside `pasteAware`.
- QR scans, deep links, and paste all go through `PairingURLParser`.
- Push-notification permission requests live in Settings; startup and
  post-pairing may only register an already-authorized token.

---

## Update Triggers

Update this rule when:
- Changing the sheet presentation or first-run gate
- Changing pairing, preset, or token logic
- Adding new persistent UserDefaults keys for onboarding
- Changing `PresetTokenStore` accessibility or key format

Verification:
```bash
ls packages/ios-app/Sources/Views/Onboarding/Steps/
ls packages/ios-app/Sources/Services/Onboarding/
ls packages/ios-app/Tests/Onboarding/
grep -rn "completionStorageKey\\|onboardingComplete" packages/ios-app/Sources/ | head -5
```
