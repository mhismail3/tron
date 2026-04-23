---
paths:
  - "**/Onboarding/**"
  - "**/OnboardingState*"
  - "**/Pairing*"
  - "**/PresetTokenStore*"
  - "**/Binding+PasteAware*"
---

# Onboarding

First-run wizard: gating, step coordination, persistence, pairing, and migration.

## High-Level Flow

```
TronMobileApp.init()
  └─ OnboardingMigrationDecider.runMigrationIfNeeded()
       └─ if cachedConnectionPresets non-empty AND onboardingComplete unset:
            set onboardingComplete = true   (existing TestFlight users)

@AppStorage("onboardingComplete")
  ├─ false → OnboardingFlowView   (this rule's domain)
  └─ true  → ContentView           (chat)

OnboardingFlowView
  └─ switch state.step in:
       welcome → tailscale → macInstall → pairing → provider → telemetryConsent → notifications → done

OnboardingState.complete()
  └─ defaults.set(true, forKey: completionStorageKey)   ← flips the gate
  └─ step = .done                                        ← visible while view dismisses
```

## Step Catalog

| Step | View | Skippable? | Side effects |
|------|------|------------|--------------|
| `welcome` | `WelcomeStep` | Power-user button → `pairing` | none |
| `tailscale` | `TailscaleStep` | "I have Tailscale" advance | none |
| `macInstall` | `MacInstallStep` | "Continue when installed" | none |
| `pairing` | `PairingStep` | NO — must succeed to advance | Keychain write, UserDefaults cache, RPC client rebuild, server `settings.update` (best-effort) |
| `provider` | `ProviderStep` | "Add later in Settings" or empty Continue | OAuth sheet may write provider auth |
| `telemetryConsent` | `TelemetryConsentStep` | Both buttons advance | persists `telemetryEnabled` flag |
| `notifications` | `NotificationsStep` | "Skip for now" | requests UNUserNotificationCenter authorization |
| `done` | `DoneStep` | "Get started" → flip gate | calls `state.complete()` + `onComplete()` |

The order is canonical. `OnboardingStep.allCases` is the persisted
ordering; renaming a case requires a migration in
`OnboardingState.init` (currently no migration — `OnboardingStepTests`
guards against silent rename).

## Persistence

| Key | Type | Storage | Reset by |
|-----|------|---------|----------|
| `onboardingComplete` | Bool | `@AppStorage` + injected UserDefaults | `OnboardingState.reset()` + diagnostics |
| `onboardingStep` | String (rawValue) | injected UserDefaults | `OnboardingState.reset()` |
| `telemetryEnabled` | Bool | injected UserDefaults | `OnboardingState.reset()` |
| `cachedConnectionPresets` | Data (JSON) | UserDefaults.standard | `SettingsState` reset path AND `OnboardingState.reset()` |

All onboarding-specific keys are exposed as `nonisolated static let` on
`OnboardingState` so the migration decider (a plain enum) can reference
them without crossing actor boundaries. **Never duplicate the literal
strings** — they're a single source of truth.

`@AppStorage` is intentionally backed by `UserDefaults.standard` (not
`NSUbiquitousKeyValueStore`). Cross-device iCloud sync of the gate would
silently mark the iPhone as onboarded after the iPad finishes — even
when the iPhone has no paired server. Per Section N.18 of the plan.

## Pairing Path (the hardest step)

The Pairing step performs three disjoint duties separated into pure
helpers so they're all testable without RPC / Keychain / SwiftUI:

1. **Validation**: `PairingStepValidator.validate(host:port:token:label:)`
   trims, classifies empty/invalid, returns
   `Result<PairingURLParser.PairingPayload, Failure>`.
2. **Probe**: `dependencies.pairingProbe.probe(host:port:token:)` opens
   a one-shot WS upgrade with the supplied bearer + sends `system.ping`,
   returning `.ok | .unauthorized | .incompatible | .unreachable`. The
   probe knows nothing about preset storage.
3. **Persist plan**: `PairingPersistor.plan(payload:existing:)` returns
   the side-effect plan: which preset gets the new token, what the
   updated `connectionPresets[]` is, what `host`/`port` to switch to.
   The View applies the plan: Keychain write → cache write →
   `dependencies.updateServerSettings(host:port:)` → best-effort
   `settings.update`.

Universal-paste detection lives in
`Sources/Extensions/Binding+PasteAware.swift` — `Binding<String>`
extension that intercepts `tron://pair?host=…&port=…&token=…[&label=…]`
in the binding's `set` so the URL never renders as literal text.
`PairingStep` AND `AddOrEditServerSheet` (settings re-pair) share the
same helper. Tests in `Tests/Onboarding/BindingPasteAwareTests.swift`
guard the safety properties.

## Re-Entrancy

The wizard is kill-and-relaunch safe at every step boundary:

- `step` is persisted on every `didSet`, so resuming jumps to the saved
  step.
- All input fields are transient (`@State` on the View OR mutable
  properties on `OnboardingState` that don't persist). Killing mid-form
  drops typed values — fine, the user re-types or re-pastes.
- `pairing` doesn't advance to `provider` until the probe + persist
  succeed, so partial-pairing is impossible to land in a half-state.
- `provider` doesn't require auth (skip path is first-class); existing
  auth is detected via `dependencies.authVersion` so re-entry after
  authenticating in another flow shows "Connected".

## Migration (existing TestFlight users)

`OnboardingMigrationDecider.runMigrationIfNeeded()` is a one-shot,
idempotent helper called from `TronMobileApp.init()` BEFORE
`@AppStorage` is read. It only flips `onboardingComplete = true` when:

- `cachedConnectionPresets` (the cache key shared with `SettingsState`)
  has at least one entry, AND
- `onboardingComplete` is currently false.

Reset paths (diagnostics page, `OnboardingState.reset()`) clear BOTH
keys, so the migration won't silently re-skip. Tests in
`OnboardingMigrationTests` cover both paths plus the cache-key canary
(`OnboardingState.cachedPresetsKey == SettingsState.cachedPresetsKey`).

## Per-Preset Bearer Tokens

`PresetTokenStore` (`Services/Storage/PresetTokenStore.swift`) wraps
`KeychainItem` to give each `ConnectionPreset.id` its own bearer token
slot at `com.tron.mobile.bearer.<presetId>`. Accessibility:
`accessibleAfterFirstUnlock` so background reconnect after reboot works
before the user unlocks. Re-pair (settings or onboarding) overwrites
the token for the preset; preset removal deletes its token.

## Key Files

| File | Purpose |
|------|---------|
| `Views/Onboarding/OnboardingFlowView.swift` | Step coordinator, dispatches by `state.step` |
| `Views/Onboarding/OnboardingShell.swift` | Shared chrome (header, content, footer, back button) |
| `Views/Onboarding/Steps/*.swift` | One file per `OnboardingStep` case |
| `ViewModels/State/OnboardingState.swift` | `@Observable` step + form state, AppStorage keys |
| `Services/Onboarding/OnboardingMigrationDecider.swift` | One-shot legacy-install flag flip |
| `Services/Onboarding/PairingStepValidator.swift` | Pure trim + classify + classify-from-probe-error |
| `Services/Onboarding/PairingProbe.swift` | One-shot WS bearer probe + `system.ping` |
| `Services/Onboarding/PairingPersistor.swift` | Pure plan: Keychain + cache + RPC update |
| `Services/PairingURLParser.swift` | `tron://pair?…` parse + URL builder |
| `Services/Storage/KeychainItem.swift` | Generic Keychain wrapper |
| `Services/Storage/PresetTokenStore.swift` | Per-preset bearer registry |
| `Extensions/Binding+PasteAware.swift` | Universal-paste helper, shared with re-pair sheet |

## Rules

- Always advance via `state.advance()` / `state.skipToPairing()`,
  never assign `state.step` directly outside of `complete()` / `reset()`.
- Pure helpers (`Validator`, `Persistor`, `MigrationDecider`,
  `URLParser`) take primitives only — no DI container, no SwiftUI.
- Pairing storage keys live exactly once on `OnboardingState` /
  `SettingsState`. Don't duplicate literals.
- The first-run gate is `@AppStorage("onboardingComplete")` and
  nothing else. Don't add a parallel "is onboarded" predicate.
- Universal-paste detection only runs inside `pasteAware` — don't
  reimplement it ad-hoc in step views.
- Push-notification permission requests live in `NotificationsStep`,
  not `initializeApp()`.

---

## Update Triggers

Update this rule when:
- Adding/removing/reordering an `OnboardingStep` case
- Changing the first-run gate or migration logic
- Adding new pairing-pure helpers or moving logic between View and helper
- Adding new persistent UserDefaults keys for the wizard
- Changing `PresetTokenStore` accessibility or key format

Verification:
```bash
ls packages/ios-app/Sources/Views/Onboarding/Steps/
ls packages/ios-app/Sources/Services/Onboarding/
ls packages/ios-app/Tests/Onboarding/
grep -rn "completionStorageKey\|onboardingComplete" packages/ios-app/Sources/ | head -5
```
