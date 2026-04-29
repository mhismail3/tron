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

When Settings launches onboarding for a new server, the same sheet opens
directly on the connect step with a top-left dismiss button and still requires
a QR scan, pasted pairing link, or manual token before Connect is enabled. When
Settings launches onboarding from an already paired server row, the connect page
is prefilled from the local paired-server record and may use that server's
Keychain token for the probe. Editing the prefilled host or port turns it back
into a fresh pairing attempt, so the user must provide a new token. First-run
onboarding remains non-dismissable until the user completes setup or explicitly
leaves from a Settings-launched sheet. Settings hosts dismiss their active
settings sheet before posting the onboarding launch, so nested settings pages do
not unwind one at a time before the connect sheet appears. The unauthorized
connection-status repair action uses the same app-level onboarding launch
notification and targets the active paired server directly instead of depending
on a nested Settings page listener.
The setup pages are not rendered until a fresh pairing attempt succeeds, so
opening onboarding from Settings cannot reveal stale settings from the currently
active server.

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
                 ├─ best-effort load auth.get for masked credential status
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
  5. best-effort load auth.get for masked credential status
  6. advance to the workspace/settings setup pages
```

If step 4 fails, onboarding rolls back the local paired-server store and
Keychain token for that attempt, restoring the previous token when a token
refresh fails, then leaves the user on the pairing page.
Pairing never writes the iOS server list to `settings.json`; the server only
owns server runtime settings and secrets.

## Settings Setup Pages

After pairing succeeds, onboarding continues with optional setup pages:

- **Default workspace** reuses `WorkspaceSelector` from the new-session
  flow and writes `server.defaultWorkspace`. The selected path also
  updates the local quick-chat workspace so long-press plus uses it
  immediately.
- **Anthropic** and **OpenAI** reuse `OAuthLoginSheet` for OAuth and
  expose a named API-key field for users who prefer keys. Saved OAuth
  credentials render as one compact status row: status icon, account label,
  and trailing `Logged in with OAuth`.
- **Other providers** exposes compact API-key rows for Google, MiniMax,
  and Kimi. Saved rows keep the provider name on the left and move
  `API key saved` plus the masked key preview into a right-aligned status
  column. These quick rows save the key under the `Default` label unless the
  user later renames it from Settings.
- **Search services** exposes API-key rows for Brave Search and Exa.
  Saved service keys use the same right-aligned masked preview layout as
  optional model providers.
- **Default model** reuses `ModelPickerSheet`, then writes both
  `server.defaultModel` and `memory.retainModel`.

Pairing hydrates an in-memory `OnboardingSetupSnapshot` from the newly active
server before the setup pages unlock. Existing server preferences from
`settings.get` prefill workspace and model choices, so pairing a forgotten but
still-running Mac can be completed by reviewing each page and swiping forward.
Existing provider and service credentials from `auth.get` are shown
only as server-returned labels and masked hints; secrets are never copied into
iOS storage. If `auth.get` fails after `settings.get` succeeds, onboarding
still proceeds with the settings snapshot and shows an inline credential-status
warning instead of blocking setup.

Every credential write in the setup pages consumes the fresh `AuthState`
returned by the server. OAuth completion, named provider API-key saves, and
service API-key saves all refresh the same in-memory snapshot immediately, so
the current page swaps from empty entry state to a saved credential card with
the masked label/hint before the user moves forward. The OAuth sheet also
reports its returned `AuthState` to callers; Settings uses the same callback so
the model providers page refreshes even if the server event arrives later.
Settings provider forms keep their local input until the auth RPC returns an
updated `AuthState`; failed saves leave labels, API keys, and Google Cloud
fields visible for correction or retry.
The Providers settings sheet starts with a dynamic summary card computed from
the loaded `AuthState`. Each model provider then uses cards for current
credential status and provider-specific details such as Google Cloud OAuth
configuration, followed by leading-aligned OAuth/API-key buttons. API-key-only
providers and search services use the same native Add API Key alert: provider
alerts collect a label plus the key, while service alerts collect only the
single service key. Failed saves re-present the alert with the draft intact so
typed secrets are not lost. Masked server-returned hints never share a
container with unsaved secret entry fields. Credential status cards keep OAuth
state and masked key hints in the trailing monospace slot next to an explicit
small red Clear pill. The Services group uses a stronger spaced header than
individual provider rows so the sheet reads as two clear sections: model
providers first, then search services.

Provider credentials are written through `auth.*` RPCs, so secrets land
in `auth.json`, not `settings.json`.

Server settings and app settings are intentionally separate. Settings backed
by `~/.tron/system/settings.json` live in the server-backed settings rows and
are shown only after the active server connects and `settings.get` returns real
values. Device-only preferences such as onboarding completion, paired servers,
active server id, appearance, dashboard presentation, telemetry consent, and
bearer tokens live in iOS `UserDefaults`/Keychain; App and Privacy use
cyan-tinted cards in the main sheet. When the user switches Macs, the app
clears server-backed controls immediately and reloads them from the newly active
Mac.
The Servers sheet starts with a dynamic summary card, then groups settings as:
header, one or more glass containers with control titles, and optional
description text below each container. Transcription, paired-device token
enforcement, and update checks all live in this sheet because they are active
Mac server settings; update controls sit at the bottom after security under one
Updates header.
The Agent and Context settings sheets follow the same top summary-card pattern
and divide server settings by ownership. Agent owns execution and lifecycle
behavior: quick-session defaults, hook model/error/context budgets,
built-in/user hooks, prompt-history capture/retention controls, queued-message
delivery, and protected branches. Hooks and Prompt Library each use one grouped
header, but each setting keeps its own glass container and description unless
the controls are intentionally coupled. The user hook directory card keeps the
folder label and `~/.tron/hooks/` value in one status row, then shows a small
empty-state placeholder until a hook-listing API exists. Context owns
context-management behavior: individual compaction controls, memory
auto-retain, retain model, and standalone rule discovery. Hooks and Prompt
Library no longer appear as separate Settings destinations; their
non-destructive controls live inside Agent. Clearing prompt history is a
destructive server action and therefore lives in the main Settings Danger Zone
above Archive All Sessions and Reset All Settings.

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

For new-server onboarding, the toolbar Connect button is disabled until the
pairing form contains a valid host, port, token, and server name from QR
scanning, paste, or manual entry. For an already paired server launched from
Settings, the blank token field means "use this server's saved Keychain token";
if that token is missing, the inline error asks the user to scan the Mac QR code
or enter the token manually. Pairing a host/port that already exists in the local
paired-server store updates that server's token and makes it active instead of
adding a duplicate; hostname matching is case-insensitive and ignores one
trailing dot.

## Forgetting a Mac

Settings → Servers → menu → "Forget" is the local reset path for a
paired server. It deletes the matching iOS Keychain bearer token and removes
the server from `PairedServerStore`; server settings and sessions on the Mac
are unchanged. If another paired server remains, iOS switches locally to it.
If no paired servers remain, Settings hides server settings and shows the
"Connect to a new server" CTA.
The paired-server ellipsis menu is scoped to the selected server row and offers
"Reconnect", "Set Up", and "Forget"; the separate "Connect to a new server" CTA
is only used for adding a fresh server. The menu hit target is overlaid outside
the row's glass card so the native menu presentation does not disturb the
card's Liquid Glass rendering when it closes.

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
Sources/ViewModels/State/OnboardingSetupSnapshot.swift
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
