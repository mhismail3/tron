# Onboarding (iOS sheet)

> Reference companion to `.claude/rules/onboarding.md` (load-on-demand
> rule consumed by Claude). This file is the human-readable narrative;
> when in doubt, the rule is normative.

The iOS app always opens to the normal dashboard after initialization.
Fresh installs present a medium-detent onboarding sheet above the
dashboard when `@AppStorage("onboardingComplete")` is false. The sheet
is swipeable: welcome, install Tailscale on iPhone, install Tron Server
on Mac, connect, then a short settings setup flow for workspace,
credentials, services, and default model. Setup pages are locked until
the Mac connection succeeds. The sheet follows the app's
standard Liquid Glass chrome: hidden drag handle, principal toolbar
title, and a floating progress-dot indicator at the bottom.

When Settings launches onboarding to add or re-pair a server, the same sheet
opens directly on the connect step with a top-left dismiss button. First-run
onboarding remains non-dismissable until the user completes setup or explicitly
leaves from a Settings-launched sheet.

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
            ├─ WelcomeOnboardingPage
            ├─ InstallTailscaleOnboardingPage
            ├─ InstallMacOnboardingPage
            └─ PairingStep
                 ├─ scan QR / optionally reveal manual entry
                 ├─ validate host / port / token / server name
                 ├─ probe ws://host:port/ws with Authorization: Bearer token
                 ├─ send system.ping
                 ├─ persist Keychain bearer + local paired-server store
                 ├─ rebuild RPC client for the paired server
                 ├─ load settings.get from the paired server
                 └─ advance to setup pages
            ├─ WorkspaceSetupOnboardingPage
            ├─ ProviderSetupOnboardingPage(Anthropic)
            ├─ ProviderSetupOnboardingPage(OpenAI)
            ├─ RemainingProvidersOnboardingPage
            ├─ ServicesSetupOnboardingPage
            └─ ModelSetupOnboardingPage
                 └─ state.complete() → dismiss sheet
```

Pairing URLs (`tron://pair?host=…&port=…&token=…[&label=…]`) are
handled in three places:

- `TronMobileApp.onOpenURL` accepts QR/deep-link launches, fills the
  pairing form, jumps to the connect page, and presents the sheet at the
  large detent.
- `QRCodeScannerSheet` scans the Mac QR code, parses the same URL shape,
  fills the connect page, and starts the same Connect validation after
  the camera sheet dismisses.
- `Binding<String>.pasteAware` lets the user paste the full pairing URL
  into any pairing field and auto-distributes the values.

The optional `label` query item is the user-facing "Server Name" and is
filled automatically when scanning a Mac pairing QR code.

---

## Pairing

`PairingStep` is the first persistent onboarding step and the gate for
all setup pages that need a live server. It is split into pure helpers
so the branches are testable without SwiftUI or live networking:

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
  1. pairedServerTokenStore.setToken(...)
  2. PairedServerStore.replace(..., activeId:)
  3. rebuild RPC client for the active paired server
  4. connect and load settings.get from the paired server
  5. advance to the workspace/settings setup pages
```

If step 4 fails, onboarding rolls back the local paired-server store and
Keychain token for that attempt, then leaves the user on the pairing page.
Pairing never writes the iOS server list to `settings.json`; the server only
owns server runtime settings and secrets.

## Settings Setup Pages

After pairing succeeds, onboarding continues with optional setup pages:

- **Default workspace** reuses `WorkspaceSelector` from the new-session
  flow and writes `server.defaultWorkspace`. The selected path also
  updates the local quick-chat workspace so long-press plus uses it
  immediately.
- **Anthropic** and **OpenAI** reuse `OAuthLoginSheet` for OAuth and
  expose a named API-key field for users who prefer keys.
- **Other providers** exposes compact API-key rows for Google, MiniMax,
  and Kimi.
- **Search services** exposes API-key rows for Brave Search and Exa.
- **Default model** reuses `ModelPickerSheet`, then writes both
  `server.defaultModel` and `memory.retainModel`.

Provider credentials are written through `auth.*` RPCs, so secrets land
in `auth.json`, not `settings.json`.

Server settings and app settings are intentionally separate. Settings backed
by `~/.tron/system/settings.json` live in the Current Server section and are
shown only after the active server connects and `settings.get` returns real
values. Device-only preferences such as onboarding completion, paired servers,
active server id, appearance, dashboard presentation, telemetry consent, and
bearer tokens live in iOS `UserDefaults`/Keychain. When the user switches
Macs, the app clears server-backed controls immediately and reloads them from
the newly active Mac.

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

iOS does not expose a reliable public API for this app to inspect the
state of a third-party Tailscale VPN profile. The onboarding Tailscale
page therefore links to the App Store and asks the user to return once
Tailscale says Connected; the real validation happens during the
pairing probe.

## QR Scanning

`QRCodeScannerSheet` uses `AVCaptureMetadataOutput` for live QR detection
and returns only the raw code string. `PairingStep` is responsible for
parsing with `PairingURLParser`, so scanning, paste, manual links, and
deep links all converge on one parser and one `OnboardingState` mutation.
The visible pairing page is QR-first: manual entry stays hidden behind
the centered "Enter Manually" action until the user asks for it. A valid
QR scan dismisses the camera sheet, flips the toolbar Connect action into
its loading state, and automatically runs the normal probe/persist path.
Invalid scans or failed probes stay on the sheet and show the inline error
so the user can scan again or reveal manual entry. The scanner reuses the
chat camera sheet's compact medium-detent camera presentation. Camera
permission copy in `Info.plist` covers both pairing QR scans and chat
photo capture.

## Forgetting a Mac

Settings → Current Server → menu → "Forget" is the local reset path for a
paired server. It deletes the matching iOS Keychain bearer token and removes
the server from `PairedServerStore`; server settings and sessions on the Mac
are unchanged. If another paired server remains, iOS switches locally to it.
If no paired servers remain, Settings hides server settings and shows the
"Onboard to Server" CTA.

Forgetting an offline server is safe because it is local-only. Optional status
snapshots such as last connected time and last known status can remain local
metadata, but offline snapshots are never editable server settings.

---

## Persistence Keys

All keys live exactly once on `OnboardingState`, `SettingsState`, or
`PairedServerStore`.
Never duplicate these literals inline.

| Key | Purpose | Type |
|-----|---------|------|
| `onboardingComplete` | Presents/dismisses the first-run onboarding sheet | Bool |
| `pairedServers` | Local paired Mac list | Data (JSON) |
| `activePairedServerId` | Active paired server id | String |

`telemetryEnabled` belongs to `SettingsState.telemetryEnabledStorageKey`
because privacy/telemetry is configured from Settings, not onboarding.

`@AppStorage` uses `UserDefaults.standard`, not
`NSUbiquitousKeyValueStore`. Onboarding completion is per-device:
pairing an iPad must not silently mark an iPhone as paired.

---

## Per-Server Bearer Tokens

Every `PairedServer.id` has a Keychain slot at
`com.tron.mobile.bearer.<serverId>`. The onboarding sheet writes or refreshes
the token; `WebSocketService` reads it when building the
`Authorization: Bearer …` upgrade header.

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
  ├── QRCodeScannerSheet.swift
  └── Steps/
      ├── SetupSteps.swift
      └── PairingStep.swift

Sources/Services/Onboarding/
  ├── PairingStepValidator.swift
  ├── PairingProbe.swift
  └── PairingPersistor.swift

Sources/Services/PairingURLParser.swift
Sources/Services/Settings/PairedServerStore.swift
Sources/Services/Storage/PairedServerTokenStore.swift
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

Tests/Services/
  ├── PairedServerStoreTests.swift
  └── PairedServerTokenStoreTests.swift
```
