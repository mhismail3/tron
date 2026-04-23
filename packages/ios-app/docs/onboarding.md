# Onboarding (iOS first-run wizard)

> Reference companion to `.claude/rules/onboarding.md` (load-on-demand
> rule consumed by Claude). This file is the human-readable narrative —
> when in doubt, the rule is normative.

The iOS app gates `ContentView` behind a multi-step wizard on first
launch. The wizard collects a Tailscale-reachable Mac address, a bearer
token, optional model-provider auth, telemetry consent, and notification
permission — then hands off to the chat experience.

---

## Flow Diagram

```
                        ┌──────────────────────────────────────┐
                        │      TronMobileApp (App entry)       │
                        │                                      │
                        │  init():                             │
                        │   • TronFontLoader.registerFonts()   │
                        │   • EventRegistry.shared.registerAll │
                        │   • OnboardingMigrationDecider.run() │◀──── one-shot:
                        │                                      │      cachedPresets non-empty
                        │  body → WindowGroup.task:            │      ⇒ flips onboardingComplete
                        │   • container.initialize()           │
                        └──────────────┬───────────────────────┘
                                       │
                                       ▼
                          ┌──────────────────────────────┐
                          │  AppInitializer.state        │
                          ├──────────────────────────────┤
                          │ .loading  → ProgressView     │
                          │ .failed   → InitErrorView    │
                          │ .ready    → readyContent()   │
                          └──────────────┬───────────────┘
                                         │
                          ┌──────────────▼───────────────────────┐
                          │  @AppStorage("onboardingComplete")   │
                          ├──────────────────────────────────────┤
                          │  true  → ContentView (chat)          │
                          │  false → OnboardingFlowView          │
                          └──────────────┬───────────────────────┘
                                         │
                                         ▼
                          ┌──────────────────────────────────────┐
                          │       OnboardingFlowView             │
                          │  switch state.step:                  │
                          │                                      │
                          │   welcome ───── "I have Tron" ─────┐ │
                          │      │                             │ │
                          │      ▼                             │ │
                          │   tailscale                        │ │
                          │      │                             │ │
                          │      ▼                             │ │
                          │   macInstall                       │ │
                          │      │                             │ │
                          │      ▼ ◀───────────────────────────┘ │
                          │   pairing  ─── connect succeeds ─┐   │
                          │      │   (validate → probe →     │   │
                          │      │    persist plan)          │   │
                          │      ▼                           │   │
                          │   provider  ── skip / connect ──┘   │
                          │      │                              │
                          │      ▼                              │
                          │   telemetryConsent                  │
                          │      │                              │
                          │      ▼                              │
                          │   notifications                     │
                          │      │                              │
                          │      ▼                              │
                          │   done  ── "Get started" ─────┐    │
                          │                                │    │
                          │   state.complete()             │    │
                          │      └─ defaults.set(true,     │    │
                          │           onboardingComplete)  │    │
                          └────────────────────────────────┘────┘
                                                           │
                                                           ▼
                                                    ContentView
```

---

## Step Sequence

| Order | Step | View | Key behavior |
|-------|------|------|---------------|
| 1 | `welcome` | `WelcomeStep` | Branding + two CTAs (start / skip-to-pairing) |
| 2 | `tailscale` | `TailscaleStep` | Tailscale prerequisite, App Store deep link |
| 3 | `macInstall` | `MacInstallStep` | DMG download URL + "Continue when installed" |
| 4 | `pairing` | `PairingStep` | Three text fields + universal-paste; Connect runs validate → probe → persist |
| 5 | `provider` | `ProviderStep` | OAuth via `OAuthLoginSheet` for Anthropic/OpenAI/Google; Skip is first-class |
| 6 | `telemetryConsent` | `TelemetryConsentStep` | Two cards (sent / not sent); both buttons advance |
| 7 | `notifications` | `NotificationsStep` | Allow vs Skip; Allow calls `pushNotificationService.requestAuthorization()` |
| 8 | `done` | `DoneStep` | "Get started" → `state.complete()` flips the gate |

A power-user shortcut on `welcome` skips straight to `pairing` for
users who already have Tron running.

---

## Pairing — the Hard Step

`PairingStep` is the only step that mutates persistent storage AND can
fail mid-flight. It's split into pure helpers so each branch is
testable without RPC, Keychain, or SwiftUI:

```
   user taps Connect
        │
        ▼
   PairingStepValidator.validate(...)         ── pure, returns Result<Payload, Failure>
        │   .failure  → state.pairingError = ...
        │
        │   .success(payload)
        ▼
   dependencies.pairingProbe.probe(...)        ── one-shot WS upgrade + system.ping
        │   .unauthorized | .incompatible | .unreachable → classify + show
        │
        │   .ok
        ▼
   PairingPersistor.plan(payload, existing)    ── pure, returns Plan
        │
        ▼
   side effects (View applies the plan):
     1. presetTokenStore.setToken(...)
     2. UserDefaults cache write (cachedConnectionPresets)
     3. dependencies.updateServerSettings(host:port:)
     4. best-effort settings.update RPC (push presets to server)
        │
        ▼
   state.advance() → provider step
```

Universal-paste: at every text field on this step, pasting a
`tron://pair?host=…&port=…&token=…[&label=…]` URL fires
`OnboardingState.acceptPairingPayload(_)` instead of writing the URL
literal to the field. The same `Binding+PasteAware` helper powers the
Settings re-pair sheet.

---

## Persistence Keys

All keys live exactly once, on `OnboardingState` (or `SettingsState`
for the cache) — never duplicated as inline string literals.

| Key | Purpose | Type |
|-----|---------|------|
| `onboardingComplete` | First-run gate | Bool |
| `onboardingStep` | Resume marker | String (rawValue) |
| `telemetryEnabled` | Consent flag (default OFF) | Bool |
| `cachedConnectionPresets` | Local copy of server-side preset list | Data (JSON) |

`@AppStorage` uses `UserDefaults.standard` (NOT
`NSUbiquitousKeyValueStore`). Cross-device iCloud sync of the gate
would falsely mark a peer device as onboarded — see Section N.18 of
the onboarding plan for the rationale.

---

## Existing-User Migration

`OnboardingMigrationDecider.runMigrationIfNeeded()` runs synchronously
inside `TronMobileApp.init()`, BEFORE the `@AppStorage` flag is read.
On first launch with this build:

- If `cachedConnectionPresets` is non-empty AND `onboardingComplete`
  is false → flip the flag to true. (TestFlight users with existing
  presets bypass the wizard.)
- Otherwise → no-op. (Fresh installs hit the wizard normally; users
  who explicitly reset onboarding stay in the wizard.)

Tests in `Tests/Onboarding/OnboardingMigrationTests.swift` cover both
paths plus a canary that pins
`OnboardingState.cachedPresetsKey == SettingsState.cachedPresetsKey`.

---

## Per-Preset Bearer Tokens

Every `ConnectionPreset.id` gets a distinct Keychain slot at
`com.tron.mobile.bearer.<presetId>`. The bearer is written by the
pairing step (and the re-pair sheet) and read by the WS upgrade
handler when it builds the `Authorization: Bearer …` header.

Accessibility class: `accessibleAfterFirstUnlock`. Background
reconnects after reboot can read the bearer before the user unlocks —
trade-off documented in `PresetTokenStore` (see plan Section N.17).

---

## Re-Entrancy

The wizard is kill-and-relaunch safe at every step boundary:

- `OnboardingState.step` persists on every `didSet`. Resume jumps
  back to the saved step.
- Form-field state on `OnboardingState` doesn't persist. Killing
  mid-form drops typed values (the user re-types or re-pastes).
- `pairing` only advances after probe + persist succeed — no half-state
  is reachable.
- Provider/telemetry/notifications skip paths are first-class; killing
  inside any of them resumes at that step (not the next).

---

## File Map

```
Sources/Views/Onboarding/
  ├── OnboardingFlowView.swift          ← step dispatcher
  ├── OnboardingShell.swift             ← shared chrome
  └── Steps/
      ├── WelcomeStep.swift
      ├── TailscaleStep.swift
      ├── MacInstallStep.swift
      ├── PairingStep.swift
      ├── ProviderStep.swift
      ├── TelemetryConsentStep.swift
      ├── NotificationsStep.swift
      └── DoneStep.swift

Sources/Services/Onboarding/
  ├── OnboardingMigrationDecider.swift  ← one-shot legacy-install flag flip
  ├── PairingStepValidator.swift        ← pure validation
  ├── PairingProbe.swift                ← WS bearer probe + system.ping
  └── PairingPersistor.swift            ← pure persist plan

Sources/Services/PairingURLParser.swift  ← tron://pair?… parse + builder
Sources/Services/Storage/PresetTokenStore.swift
Sources/Services/Storage/KeychainItem.swift
Sources/Extensions/Binding+PasteAware.swift  ← shared with re-pair sheet
Sources/ViewModels/State/OnboardingState.swift

Tests/Onboarding/
  ├── OnboardingStepTests.swift         ← step ordering + skipToPairing()
  ├── OnboardingStateTests.swift        ← persistence + reset()
  ├── OnboardingMigrationTests.swift    ← migration decider + canary
  ├── PairingPersistorTests.swift       ← pure plan branches
  ├── PairingProbeTests.swift           ← probe outcome classification
  ├── PairingValidationTests.swift      ← validator branches
  ├── PairingURLParserTests.swift       ← parser happy path + every error
  └── BindingPasteAwareTests.swift      ← universal-paste helper safety
```
