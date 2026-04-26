# Onboarding (iOS pairing sheet)

> Reference companion to `.claude/rules/onboarding.md` (load-on-demand
> rule consumed by Claude). This file is the human-readable narrative;
> when in doubt, the rule is normative.

The iOS app always opens to the normal dashboard after initialization.
Fresh installs present a medium-detent pairing sheet above the dashboard
when `@AppStorage("onboardingComplete")` is false. Pairing is the only
required first-run action on iOS: Mac installation, macOS permissions,
and the QR/token generation happen in the Mac app; providers,
notifications, telemetry, and feedback live in Settings.

---

## Flow Diagram

```
TronMobileApp.init()
  ├─ TronFontLoader.registerFonts()
  └─ EventRegistry.shared.registerAll()

WindowGroup.task
  └─ AppInitializer.initialize { DependencyContainer.initialize() }

readyContent()
  ├─ always mounts ContentView
  └─ sheet(isPresented: !onboardingComplete)
       └─ OnboardingFlowView
            └─ PairingStep
                 ├─ validate host / port / token / label
                 ├─ probe ws://host:port/ws with Authorization: Bearer token
                 ├─ send system.ping
                 ├─ persist preset + Keychain bearer
                 ├─ rebuild RPC client for the paired server
                 └─ state.complete() → dismiss sheet
```

Pairing URLs (`tron://pair?host=…&port=…&token=…[&label=…]`) are
handled in two places:

- `TronMobileApp.onOpenURL` accepts QR/deep-link launches, fills the
  pairing form, and presents the sheet at the large detent.
- `Binding<String>.pasteAware` lets the user paste the full pairing URL
  into any pairing field and auto-distributes the values.

---

## Pairing

`PairingStep` is the only onboarding step that mutates persistent
storage and can fail mid-flight. It is split into pure helpers so the
branches are testable without SwiftUI or live networking:

```
user taps Connect
  │
  ▼
PairingStepValidator.validate(...)
  │  .failure → state.pairingError
  │
  ▼
dependencies.pairingProbe.probe(...)
  │  .unauthorized | .incompatible | .unreachable → classify + show
  │
  ▼
PairingPersistor.plan(payload, existing)
  │
  ▼
side effects:
  1. presetTokenStore.setToken(...)
  2. cache updated connectionPresets in UserDefaults
  3. dependencies.updateServerSettings(host:port:)
  4. best-effort settings.update RPC to persist presets on the server
  5. state.complete()
```

`URLSessionPairingProbe` opens a one-shot WebSocket upgrade with the
pairing bearer token and sends `system.ping`. The server emits a
`connection.established` event immediately after upgrade, so the probe
matches the `system.ping` response by request id and ignores unrelated
event frames before classifying:

- `.ok` when the server replies successfully.
- `.unauthorized` when the WebSocket upgrade gets HTTP 401.
- `.incompatible` when `system.ping` returns
  `CLIENT_VERSION_UNSUPPORTED`.
- `.unreachable` for DNS, timeout, refused connection, and malformed
  responses.

If the Mac looks healthy but the iPhone reports unreachable, check that
Tailscale is connected on the iPhone and signed into the same tailnet.
The Mac server logs should show an inbound WebSocket connection when the
phone reaches it.

---

## Persistence Keys

All keys live exactly once on `OnboardingState` or `SettingsState`.
Never duplicate these literals inline.

| Key | Purpose | Type |
|-----|---------|------|
| `onboardingComplete` | Presents/dismisses the first-run pairing sheet | Bool |
| `cachedConnectionPresets` | Local copy of server-side preset list | Data (JSON) |

`telemetryEnabled` belongs to `SettingsState.telemetryEnabledStorageKey`
because privacy/telemetry is configured from Settings, not onboarding.

`@AppStorage` uses `UserDefaults.standard`, not
`NSUbiquitousKeyValueStore`. Onboarding completion is per-device:
pairing an iPad must not silently mark an iPhone as paired.

---

## Per-Preset Bearer Tokens

Every `ConnectionPreset.id` has a Keychain slot at
`com.tron.mobile.bearer.<presetId>`. The pairing sheet and settings
re-pair sheet write the token; `WebSocketService` reads it when building
the `Authorization: Bearer …` upgrade header.

Keychain accessibility is `accessibleAfterFirstUnlock` so background
reconnects after reboot can read the token once the device has been
unlocked at least once.

---

## File Map

```
Sources/App/TronMobileApp.swift
  └── owns the dashboard + onboarding sheet presentation

Sources/Views/Onboarding/
  ├── OnboardingFlowView.swift
  ├── OnboardingShell.swift
  └── Steps/
      └── PairingStep.swift

Sources/Services/Onboarding/
  ├── PairingStepValidator.swift
  ├── PairingProbe.swift
  └── PairingPersistor.swift

Sources/Services/PairingURLParser.swift
Sources/Services/Storage/PresetTokenStore.swift
Sources/Services/Storage/KeychainItem.swift
Sources/Extensions/Binding+PasteAware.swift
Sources/ViewModels/State/OnboardingState.swift

Tests/Onboarding/
  ├── OnboardingStateTests.swift
  ├── PairingPersistorTests.swift
  ├── PairingProbeTests.swift
  ├── PairingValidationTests.swift
  ├── PairingURLParserTests.swift
  └── BindingPasteAwareTests.swift
```
