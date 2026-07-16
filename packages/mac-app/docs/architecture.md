# Mac App Architecture

## Overview

`Tron.app` is the macOS SwiftUI wrapper around the headless Rust agent. It has two runtime modes:

- **Wizard mode** — shown on first launch, before `~/.tron/internal/run/.onboarded` exists. Walks the user through Tailscale, Login Item registration, permissions, iOS beta installation, and pairing-info display.
- **Menu-bar mode** — shown every launch after onboarding. An `NSStatusBar` item polls `system::ping` and exposes status + copy actions + diagnostics. Passive poll/menu-open refreshes never overwrite an explicit busy action such as "Restarting"; the action handler owns the final status refresh when the command exits.

Health checks and SMAppService/launchd observations are translated into the
visible wizard or menu state by their owning runner or poller. The wrapper does
not maintain a parallel evidence model.

The switch is driven entirely by the `.onboarded` sentinel file. UserDefaults
stores only resumable wizard-step progress; it does not duplicate completion.

`Tron.app` does not embed the Rust toolchain or build the agent at runtime.
`scripts/bundle-agent.sh` stages a prebuilt `tron` executable into two bundled
helper apps: `Tron Server.app` for production/local Release and
`Tron Server Dev.app` for isolated Debug install testing. Helpers are signed
first, then the outer wrapper is re-signed after copying the `Contents/Library`
tree so ServiceManagement can verify the bundled LaunchAgent plists as sealed
resources. The Xcode target copies `packages/agent/defaults/` into the built
app's `Contents/Resources/Constitution/`; managed skills, transcription
sidecars, and product capability assets are not bundled. See
[development.md](./development.md) for the build pipeline.

## Directory Structure

```
packages/mac-app/
├── project.yml                     # XcodeGen project definition
├── TronMac.entitlements            # Hardened runtime entitlements
├── Configuration/                  # .xcconfig files (Debug/Release)
├── Sources/
│   ├── Info.plist                  # Bundle metadata (starts regular; switches to accessory after onboarding)
│   ├── App/
│   │   ├── Lifecycle/              # @main entry, AppDelegate, startup maintenance, runtime variant
│   │   ├── CommandMode/            # Internal start/uninstall command-mode entry points
│   │   └── Composition/            # Sendable DI struct (live + test values)
│   ├── MenuBar/
│   │   ├── Actions/                # Typed menu commands, action handler, and feedback issue action
│   │   ├── Controller/             # NSStatusItem and window lifecycle
│   │   └── Presentation/           # Pure typed-descriptor builder, logs reader, logs window
│   ├── Resources/                  # tracked icons, fonts, and helper/LaunchAgent metadata
│   │   ├── Fonts/
│   │   │   └── Exo2-Variable.ttf   # bundled Google Fonts sans face for wizard typography
│   │   └── Library/                # helper Info.plists + LaunchAgent plists; binaries are staged and ignored
│   ├── Server/
│   │   ├── LaunchAgent/            # protocol + SMAppService-backed LiveLaunchAgentManager
│   │   ├── Health/                 # one-shot ping, health waiting, status polling
│   │   ├── Paths/                  # TronPaths plus profile settings TOML cache
│   │   ├── PairingToken/           # auth.json bearer-token reader
│   │   └── ProcessControl/         # dev stopper, process probe, wrapper lock, uninstall
│   ├── Support/
│   │   ├── Diagnostics/
│   │   │   └── DiagnosticsRedactor.swift   # strip paths, mask bearer/API/OAuth fields, drop chat content
│   │   ├── Feedback/
│   │   │   └── FeedbackComposer.swift      # pure GitHub issue composer with redacted log context
│   │   ├── Foundation/
│   │   │   ├── Subprocess.swift
│   │   │   └── VersionDisplay.swift
│   │   ├── Onboarding/
│   │   │   ├── ExistingInstallDetector.swift
│   │   │   ├── MacPermissionProbe.swift
│   │   │   ├── OnboardedSentinelWriter.swift
│   │   │   ├── OnboardingModels.swift  # wizard/permission models + exhaustive System Settings URL
│   │   │   └── TailscaleProbe.swift
│   │   ├── Pairing/
│   │   │   ├── LocalComputerName.swift
│   │   │   ├── PairingURLBuilder.swift # builds `tron://pair?…` URL
│   │   │   └── QRCodeGenerator.swift   # CoreImage CIQRCodeGenerator wrapper
│   │   └── Theme/
│   │       ├── TronColors.swift        # adaptive color tokens + NSColor conversion
│   │       ├── TronFontLoader.swift    # CoreText registration for bundled fonts
│   │       └── TronTypography.swift    # compact Mac wizard type tokens
│   ├── Assets.xcassets/
│   └── Wizard/
│       ├── Flow/                   # @Observable state machine + NavigationStack shell
│       ├── Steps/                  # One view per WizardStep case
│       └── Components/             # Window sizing, button style, layout constants
└── Tests/                          # Behavior-oriented Mac wrapper tests mirroring App/Server/MenuBar/Support/Wizard
```

`Contents/Resources/Constitution/` is build output copied from
`packages/agent/defaults/` by `project.yml`; it is not a source directory.

## Key Architectural Patterns

### Dependency Injection via `EnvironmentSetup`

`EnvironmentSetup` is the composition seam for wizard/menu behavior that needs
host substitution: canonical paths, server probes, LaunchAgent control, and
onboarding actions. Leaf owners still encapsulate their bounded filesystem,
process, and timing effects. Tests replace the composition seam where useful
and use temporary directories for leaf filesystem behavior.

```swift
struct EnvironmentSetup: Sendable {
    var tronHome: URL
    var readBearerToken: @Sendable () -> String?
    var probeTailscale: @Sendable () async -> TailscaleStatus
    var launchAgentManager: LaunchAgentManaging
    // …
}
```

SwiftUI plumbing: injected via `.environment(\.environmentSetup, …)` on the root scene. Test views override the single key.
Pure presentation owners receive only the immutable values they consume:
`MenuBarController` projects the Tron-home URL, default port, and launch-control
authority into `MenuBarItemBuilder` instead of passing the effectful setup seam.

### Validation and side-effect boundaries

`MacRuntimeVariant` owns wrapper identity, application-placement policy, and
whether to take over an existing LaunchAgent registration based on its parent bundle.
`ExistingInstallDetector` owns bundled-helper validation: helper app,
executable, LaunchAgent plist, signature, and registration classification.
`InstallStep` orchestrates that validation and passes the active
`EnvironmentSetup.launchAgentPlistPath` directly to `LaunchAgentManaging` for
registration. The composition seam does not duplicate those helper paths or
revalidate them through a second planner.
`MacAppStartupMaintenance` owns one ordered launch decision: managed wizard
completion records the current build without reading ordinary-launch state or
probing the server process. Ordinary launches skip when they are not onboarded,
cannot manage the helper, observe dev takeover, or already recorded the build;
only the absence of a skip reason permits a restart.
`PairingURLBuilder` and `QRCodeGenerator` are likewise emitter-only production
owners. The iOS `PairingURLParser` owns runtime consumption; QR decoding stays
in the Mac test target so the wrapper does not ship a second inverse parser or
detector.

The menu bar observes `tron dev` takeover but does not start it. Contributors
start dev servers from the checkout-owned `scripts/tron` CLI; the app only
detects when `Tron-Dev.app` owns port 9847 and exposes the bounded stop/resume
action for that live process.
The CLI dispatcher stays in `scripts/tron`; workspace command families and
contributor bundle/signing live in `scripts/tron.d/`, while runtime
service/log/auth helpers shared with the installed `tron-cli` live in
`scripts/tron-lib.d/`. The Mac wrapper remains an observer/manager through
`SMAppService`; script modules must not become a second production policy
owner. `Sources/Resources/AppIcon.icns` is likewise
the single helper-icon source; ignored per-helper copies are staging outputs,
not independently maintained resources.

### Protocol-bounded subprocess surface

`LaunchAgentManaging` is the only launch-control interface — register/unregister/restart/isLoaded. `LiveLaunchAgentManager` lives under `Server/LaunchAgent`, uses `SMAppService` for registration and unregistration, and uses `launchctl print/kickstart` only for diagnostics/restart. `LaunchAgentLoader` in the same owner applies the shared load policy: return the registration outcome directly, except an already-loaded service is restarted so an app replacement cannot leave an older helper image running. The shared async `Subprocess` runner lives under `Support/Foundation` so health probing, launch-agent diagnostics, and process-control callers do not make `Server/Health` a second ownership bucket. Everything else (permission probes, Tailscale checks, logs) is internal to the wrapper or server engine protocol.

`LaunchAgentRuntimeInfo` retains only launchd fields consumed by replacement,
refresh, or status UI policy: PID/uptime, parent bundle identity/version, helper
executable path, and launch-constraint refresh state.

### Wizard visual system

The wizard uses one fixed-size glass canvas with pinned header, progress, and
action chrome so page transitions do not resize the window. `TronTypography`,
`WizardInfoCard`, `WizardIconTextRow`, and `WizardGlassCardBackground` own the
shared type and card language. Welcome stays visually stable; install state is
reported on the Install step. The Permissions step owns the single Full Disk
Access gate and renders blocked Continue actions as disabled. Exact layout and
transition values live with these components and their tests.

### Single-instance lock via POSIX `fcntl`

`SingleInstanceLock.acquire()` opens `~/.tron/internal/run/.mac-wrapper.<bundle-id>.lock` and tries `fcntl(F_SETLK, F_WRLCK)`. A second instance of the same wrapper build fails, `AppDelegate` logs + `NSApp.terminate(nil)`. Release (`com.tron.mac`) and Debug companion (`com.tron.mac.dev`) intentionally use different lock files so their menu icons can coexist while they observe the same production server. Locks are automatically released on process exit (kernel drops fd locks with the process). Re-acquire from the same process is idempotent (returns true if a valid `fileDescriptor` is already held). The headless agent has its own per-process lock at `~/.tron/internal/database/tron.sqlite.lock`.

**Test-host bypass**: `TronMacRuntime.isRunningUnderTests` recognizes the
scheme-owned `TRON_MAC_TEST_HOST` marker and Xcode's
`XCTestSessionIdentifier`, `XCTestConfigurationFilePath`, and
`XCTestBundlePath` markers. Test hosts render an inert view and skip wrapper
locks, wizard, menu, and ServiceManagement side effects. Production launches
do not carry these markers.

### Sendable concurrency hygiene

`SingleInstanceLock` is `@unchecked Sendable` because all mutable `fileDescriptor` access is funneled through a private `NSLock` (swapped from `DispatchQueue.sync` to avoid GCD overhead from `@MainActor` callers; semantically clearer for a single-writer guard). `MockLaunchAgentManager` uses `OSAllocatedUnfairLock<State>`. `AppDelegate` is `@MainActor` — the `NotificationCenter` observer hops via `Task { @MainActor [weak self] in … }`.

## Data Flow

### First launch (wizard path)

```
TronMacApp.main()
  └─ AppDelegate.applicationDidFinishLaunching
       ├─ SingleInstanceLock.acquire()      ← refuses second instance
       └─ setup.onboardedSentinelExists() → false
           └─ RootView → WizardView
                └─ WizardState.step = .welcome
                    → .tailscale → .install
                    → .permissions → .iosBeta
                    → .pairingInfo → .done
                └─ WizardShell taps "Open menu bar"
                    ├─ setup.touchOnboardedSentinel()  ← atomic tempfile+rename
                    └─ post .tronWizardDidComplete
                         └─ AppDelegate observer
                             ├─ installMenuBar(setup:)
                             ├─ NSApp.setActivationPolicy(.accessory)
                             └─ orderOut all windows
```

The Tailscale step probes every executable candidate in its known list
(`/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/usr/local/bin/tailscale`,
then `/opt/homebrew/bin/tailscale`) and accepts the first response with
`BackendState == "Running"` plus a Tailscale IPv4. A stale or GUI-flavoured
binary therefore cannot mask a healthy Homebrew CLI. The "I have Tailscale"
CTA performs the same live probe and only advances after a connected result.
The step's immediate one-second poll loop runs directly in a SwiftUI `.task`,
so leaving the page cancels its sole lifecycle owner before another status write.

The install heartbeat is intentionally permission-neutral: the LaunchAgent
may start the server, but ordinary agent startup must not probe TCC or open
System Settings. The Permissions step is the first place any TCC probe runs,
and that probe runs in the wrapper process because the LaunchAgent associates
the helper with the wrapper bundle IDs. Full Disk Access therefore points at
`Tron.app` or `TronMac.app`, matching the app entry macOS evaluates for the
running helper. `Permission.systemSettingsURL` exhaustively owns the matching
pane URL. The gear button only opens that System Settings pane and never calls
prompt APIs, so no second modal appears over the pane. The
wizard-opened Settings pane starts a short-lived fast-probe watcher until Full
Disk Access turns green. App activation, Re-check, and the watcher never
restart the server. Once Full Disk Access is green and the user presses
Continue, the wizard restarts the helper once so newly enabled launch-time
grants are available before pairing.

The iOS Beta step is a static handoff before pairing. It renders
`https://testflight.apple.com/join/xbuX1Grx` as a QR code so the user's iPhone
opens the public Tron TestFlight invite and installs the latest beta available
to that tester group. The page also exposes copy/open actions for the same
URL, but it does not call the server or mutate onboarding state beyond normal
step persistence.

The Pairing step does not require a pre-existing user profile. It reads the
agent-issued `auth.json` bearer token, confirms the server is answering
`system::ping`, and resolves the host in this order: a fresh Tailscale probe,
the wizard's latest Tailscale state, the ping response, then the settings
cache. The selected host is cached best-effort in
`profiles/user/profile.toml`; a cache write failure does not invalidate the QR
payload.
The QR/manual payload builder accepts only a bare DNS name, IPv4 address, or
unbracketed IPv6 address plus a `1...65535` port, mirroring iOS
`PairingURLParser`; it refuses URL-shaped, path, query, userinfo, bracketed,
or malformed host values before emitting `tron://pair`.

### Subsequent launches (menu-bar-only path)

```
TronMacApp.main()
  └─ AppDelegate.applicationDidFinishLaunching
       ├─ SingleInstanceLock.acquire()
       └─ setup.onboardedSentinelExists() → true
           └─ installMenuBar(setup:)
                └─ MenuBarController
                    ├─ NSStatusItem with tinted Tron logo
                    ├─ typed MenuBarAction → controller-owned MenuBarActionHandler
                    └─ 30s poller task → ServerStatusPoller.snapshots()
                         ├─ setup.pingServer(token) → ServerPingResult
                         ├─ launchAgentManager.isLoaded() when ping fails
                         ├─ setup.readBearerToken()
                         └─ setup.readTailscaleIPFromSettings()
```

The menu bar renders an explicit server state rather than a generic dot:
`running` is green, `checking`/busy/unauthorized are yellow, `failed` is red,
and `paused` is gray. `ServerStatusState` owns that tone and the running
version/port; consumers pattern-match `ServerPingResult` directly, while
snapshots store only orthogonal process and host metadata. The status poller,
pairing window, log window, and feedback action each read the bearer token
through `EnvironmentSetup.readBearerToken` at the point of use and never retain
it in presentation state. `MenuBarController` owns the setup used to compose
the pairing and log windows; `MenuBarActionHandler` dispatches those typed
window actions without resupplying composition. `MenuBarLogReader` accepts the
token as request input and does not own credential storage or path resolution.
The poller is an immutable `Sendable` value. `MenuBarController` owns and
cancels its consumer task, while each stream owns its producer task and buffers
only the newest snapshot so a stalled consumer cannot accumulate obsolete
30-second status values. Terminating or releasing the stream invokes
`onTermination` and cancels its producer. `ServerProcessProbe` owns local
port-process discovery plus `/bin/ps` command and elapsed-time lookups. It reads
the command only long enough to derive dev-server ownership; its projection
retains only PID, uptime, and that derived flag for policy/UI consumers. The
poller uses it after a successful ping; `LiveLaunchAgentManager` still parses
launchd's PID but reuses the same elapsed-time lookup. This lets `tron dev`
takeover report the `Tron-Dev.app` process instead of stale LaunchAgent metadata
and marks the header `Dev Server active`.
If `system::ping` fails, the poller asks launchd whether `com.tron.server` is
loaded; unloaded maps to paused, loaded-but-unreachable maps to failed.
Explicit menu actions that should leave the server running (`Restart server`,
`Resume server`, and `Stop dev server` recovery) share the bounded
`ServerHealthAwaiter` path after SMAppService reports loaded. They only post a
success notification after `/health` returns healthy; loaded-but-unreachable
helpers keep the menu in the failed state and surface an update/reinstall
message instead of claiming the server is running.

### Menu-bar auxiliary windows

Post-onboarding surfaces stay in menu-bar mode. The first menu item is a custom
header view aligned with the normal menu rows: `Tron`, the current Tailscale
endpoint, a color-coded status line, PID/uptime for the process actually
listening on port 9847, and a `Dev Server active` line when that process is the
`Tron-Dev.app` bundle created by `tron dev`. The menu refreshes this snapshot
when opened as well as on the background poll interval. "Show pairing info" is
a normal menu action below the header separator. The menu does not repeat the
pairing token because the pairing-only window owns QR/manual copy details for
host, port, token, and server name. That window reuses the
pairing resolver/QR/copy controls without wizard navigation or a progress pill.
The shared pairing surface resolves live when it opens, showing one centered
emerald spinner directly on the window background until the complete payload
and QR code are ready; the same strict QR payload builder used by onboarding
backs the pairing-only window. It keeps the generated QR image in state so the
spinner can crossfade smoothly into the QR/manual-value containers on a custom
timing curve. Copy actions quickly swap to a checkmark for two seconds so the
user gets deterministic visual feedback. "Show logs" opens a native logs window fed by
the read-only `logs::recent` engine protocol, with refresh and copy controls.
The uptime row normalizes raw `ps` elapsed-time strings such as `10:48` to the
same `HH:MM:SS` format used by the live one-second ticker, so opening the menu
does not briefly switch display styles.
While `Tron-Dev.app` owns port 9847, the server-control section shows `Stop dev
server`. Pause, restart, and uninstall remain disabled during dev takeover. The
stop action re-probes the port owner before signaling anything, sends TERM then
KILL only to the verified dev PID if needed, and then resumes the installed
Login Item through the same `SMAppService` load path as the normal Resume
action. If the installed helper loads but never becomes healthy, the action
shows a `Resume failed` alert and leaves the refreshed menu state failed rather
than advertising a successful recovery.
Menu rows use native `NSMenuItem` rendering with no item images, so the popup
keeps the standard macOS menu spacing used by apps like 1Password.
"Send feedback" builds a prefilled GitHub issue with app/server context and a
redacted log tail; oversized issue bodies are copied to the pasteboard and the
GitHub issue opens with a short note.

### Install pipeline (wizard's `InstallStep`)

```
0. Wait for user: Install CTA increments WizardState.installRequestID; no disk or launchd mutation happens before this
   - WizardState.handledInstallRequestID suppresses replay when the install page remounts after back/forward navigation
1. Validate location: Release builds must run from `/Applications/Tron.app`; Debug builds may run from DerivedData.
2. Validate helper: Ensure the active bundled helper app (`Tron Server.app` or `Tron Server Dev.app`), its executable, LaunchAgent plist, `BundleProgram`, wrapper `AssociatedBundleIdentifiers`, and signature are present.
3. Register:      SMAppService.agent(plistName: "<active-label>.plist").register()
   - Installed Release manages `com.tron.server` on port `9847`; the isolated install scheme manages `com.tron.server.dev` on port `9848`.
   - Default Xcode Debug is companion-only. If it reaches the Install step it fails before mutating Login Items and tells the contributor to use `/Applications/Tron.app` or the isolated install-testing scheme.
   - Before registration, `LiveLaunchAgentManager` reads `launchctl print` to identify the loaded job's parent bundle, event-trigger executable, and launch-constraint state. An enabled SMAppService registration without a loaded launchd job, one pointing at a missing/mismatched helper path, one owned by a stale parent bundle build, or one reporting launch-constraint drift such as `needs LWCR update` is treated as registered-but-not-ready. A manager build replaces that registration through SMAppService, then the pipeline waits for ping.
4. Await ping:    poll setup.pingServer(token) for 30s on 1s cadence, ignoring connection events; menu-bar and command-mode update finalization write `internal/run/mac-app-version.json` only after this health gate passes
→ state.installOutcome set; Pairing step unblocks only when .success

The UI intentionally paces quick stages for a few hundred milliseconds
so the install does not visually jump from pending to three green checks
before the user can understand the sequence.
Before the first Install click, the stage area shows only
"Installation not started"; if ServiceManagement already reports a
registration, the page says "Tron Server is registered" but still waits
for the explicit Start server CTA before mutating Login Items. Rows
appear progressively as stages begin instead of listing future pending work.
During the active install run, the success summary is allowed to appear
as soon as all local stage rows are succeeded; on remount, row state is
derived synchronously from terminal `installOutcome` so the completed
icons are part of the page transition rather than a post-mount update.
After success, the page shows an animated install-summary stack that
confirms Tron Server is ready and refreshes the current server status
through `setup.pingServer`.
```

Menu-bar uninstall and manager-mode `--tron-uninstall-and-quit` both call
`SMAppService.unregister`, remove runtime state
(`run/.onboarded`, `run/auth.lock`, and
the current `run/.mac-wrapper.<bundle-id>.lock`), and quit the wrapper. By default, auth,
profile settings, databases, and workspace files remain intact, so the next app
launch returns to the onboarding wizard instead of a broken menu-bar-only
state. The menu confirmation dialog can also clear `[settings]` overrides from
`profiles/user/profile.toml` and/or remove `auth.json`; databases and workspace
files are still preserved.

## Key Invariants

- **`Tron.app` never builds the Rust agent.** The `tron` helper executable is staged at release time by `scripts/bundle-agent.sh` and committed-to-gitignore. Missing or corrupt helpers/plist/signature → wizard surfaces a reinstall/move instruction. Any agent-side engine capability/TCC/install/settings-default change must be followed by rerunning the bundle script before Mac dogfood, because Xcode only copies `Sources/Resources/Library`.
- **The Install step is not an `onAppear` side effect.** Landing on the page is read-only; the user must press Install before the wrapper registers the service.
- **Install requests are consumed once.** `InstallStep` can remount during navigation, but it only mutates disk/launchd when `installRequestID > handledInstallRequestID`; success/failure pages are display-only until the user presses Retry.
- **Welcome install detection must not relayout the hero.** `WelcomeStep` does not render install detection state; the Install step owns that status.
- **The helper app must be signed before registration.** Validation fails loudly if the active helper app, its binary, the bundled LaunchAgent plist, or the helper signature is missing/corrupt. Production/local Release use `Tron Server.app` with bundle id `com.tron.server`; isolated Debug uses `Tron Server Dev.app` with bundle id `com.tron.server.dev`. The helper bundle id intentionally matches the active LaunchAgent label, while the LaunchAgent associates with the wrapper bundle ids because macOS presents some TCC services under the responsible wrapper app.
- **Uninstall preserves user data.** Menu-bar uninstall and manager-mode `--tron-uninstall-and-quit` unregister the SMAppService agent and clear runtime state. Default Debug companion mode refuses to uninstall production. Menu-bar uninstall may clear `[settings]` overrides from `profiles/user/profile.toml` and/or remove `auth.json` only when the user explicitly checks the matching reset option; it never removes the database or workspace.
- **A loaded LaunchAgent label is not proof that the correct helper is running.** Registration inspects `launchctl print` for the loaded job's parent bundle identifier and event-trigger executable before deciding whether to reuse, repair, or fail. Missing/mismatched helper executables are stale registrations and manager builds repair them; default Debug companion builds never repair or own production registration.
- **Permission checks are wrapper-owned and probe-only.** The Permissions step records when it opened System Settings only to decide whether to show the visible "Checking permissions..." activity state on return. Its recurring probe loop runs directly in the view's SwiftUI `.task`, which owns cancellation when the page disappears; the separate gear-button watcher remains bounded and explicitly cancelled because button actions can restart it. App activation, Re-check, and that watcher call native wrapper probes without `launchctl kickstart`, and transient `.probeUnavailable` snapshots preserve the last concrete badge state instead of turning the page gray. The only permission-time restart is the one-time helper restart after Full Disk Access is green and the user presses Continue.
- **Optional managed runtime assets stay out of the wrapper.** The build bundles helper apps and Constitution defaults. Skills, transcription sidecars, and product capability assets are not copied into the app or `~/.tron`.
- **Distributed app bundles are immutable at runtime.** Mutable files live under `~/.tron`; ephemeral locks live under `~/.tron/internal/run`. End users replace `Tron.app` from a notarized DMG; the documented local Release workflow is the explicit contributor-only exception.
- **DMG assembly has one fail-closed owner.** `scripts/package-dmg.sh` copies the complete wrapper, accepts only an explicit structural or release layout, makes one image-creation attempt, and remounts the result to require the app, embedded helper, and `Applications -> /Applications` link. PR CI and the release workflow delegate that transaction to the script; signing, notarization, and publication remain release-workflow concerns.
- **Wrapper and server share no in-memory state.** Interaction crosses persisted files, engine protocol calls, or OS service/process state. Crashing the wrapper does not kill the server because the LaunchAgent owns it.
- **Production uses one port (`9847`) and one LaunchAgent label (`com.tron.server`).** The DMG-installed `Tron.app` (`com.tron.mac`), local Release copies, the default Xcode Debug companion (`com.tron.mac.dev`), and the `tron dev` agent bundle at `~/.tron/internal/run/Tron-Dev.app` (`com.tron.agent`) all target the production `~/.tron` data tree. Debug companion observes production but does not manage its Login Item; `tron dev` is the explicit server takeover path and stops the production LaunchAgent before binding 9847. The isolated install scheme is the exception by design: it uses `com.tron.server.dev`, `Tron Server Dev.app`, port `9848`, and `~/.tron-dev`.
- **TronPaths owns canonical wrapper locations and identities.** Production Tron-home, bundle, label, and port constants belong there; leaf owners may derive transient or system paths from those values. See `packages/agent/src/shared/foundation/paths/mod.rs` for the Rust-side mirror.

## Workflows & Variants

Production workflows operate against the same `~/.tron/internal/` data tree and share `port 9847` + `com.tron.server` LaunchAgent. The isolated install workflow uses its own data tree, label, and port so reinstall testing can happen while production remains installed.

### The five workflows

| Workflow | Audience | Build product | Bundle ID | On-disk path | What it ships | Server entry point |
|---|---|---|---|---|---|---|
| **1. Production (DMG)** | End users downloading from GitHub Releases | `Tron.app` (notarized + stapled DMG) | `com.tron.mac` | `/Applications/Tron.app` | SwiftUI wrapper (wizard + menu bar), embedded headless agent, and Constitution defaults | `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` inside `/Applications/Tron.app` |
| **2. Local Release test** | Contributors validating a Release build without the DMG wrapper | `Tron.app` (Release build copied into place) | `com.tron.mac` | `/Applications/Tron.app` | Same runtime shape as Production, usually not notarized | Same installed-release helper path inside `/Applications/Tron.app` |
| **3. Debug companion (default Xcode Run)** | Contributors testing wrapper UI while production stays installed | `TronMac.app` (Debug build, Xcode/xcodebuild) | `com.tron.mac.dev` | `~/Library/Developer/Xcode/DerivedData/TronMac-*/Build/Products/Debug/TronMac.app` | Same SwiftUI wrapper as Production with a debug-profile bundled helper | Observes the production server on port 9847; does not register or mutate `com.tron.server` |
| **4. Isolated install test** | Contributors testing first-run/reinstall flows from Xcode | `TronMac.app` with `TRON_MAC_INSTALL_MODE=isolated` | `com.tron.mac.dev` | DerivedData | Debug wrapper and `Tron Server Dev.app`, separate install target | Registers `com.tron.server.dev`, runs port 9848, uses `~/.tron-dev` via `TRON_HOME_NAME=.tron-dev` |
| **5. Agent dev (`tron dev`)** | Contributors iterating on the Rust agent without wrapper UI | `Tron-Dev.app` (no SwiftUI — just a `.app` bundle wrapping the dev Rust binary) | `com.tron.agent` | `~/.tron/internal/run/Tron-Dev.app` | Headless Rust agent only (no menu bar, no wizard) | Takes over port 9847 in-process; the production LaunchAgent is stopped first |

> **Naming guard.** `TronMac.app` (workflows 3 and 4's build product) and `Tron-Dev.app` (workflow 5's agent bundle) are unrelated. `TronMac.app` is the wrapper UI compiled in Debug mode; `Tron-Dev.app` is just the Rust agent recompiled in dev. They share neither code nor purpose.

> **Why Debug builds `TronMac.app` but Release builds `Tron.app`.** The XcodeGen target is `TronMac` (so `PRODUCT_NAME` defaults to `TronMac` for both configs), but `Configuration/Release.xcconfig` overrides it with `PRODUCT_NAME = Tron`. This produces the `Tron.app` bundle expected by the release workflow's `APP_BUNDLE` contract and the `/Applications/Tron.app` end-user surface. Debug intentionally keeps the default so the `TronMacTests` target's `BUNDLE_LOADER` / `TEST_HOST` (which reference `TronMac.app/Contents/MacOS/TronMac`) keep resolving without configuration drift.

### Production-shared state and identities

- **Port `9847`** — the production WS bind. Always exclusive — see "Mutual exclusion" below. Workflow 4 uses `9848`.
- **LaunchAgent label `com.tron.server`** — the launchd job that owns the installed production server. Workflows 1 and 2 register it through `SMAppService`; workflow 3 observes it; workflow 5 stops it before binding the port itself. Workflow 4 registers only `com.tron.server.dev` and points `BundleProgram` at `Tron Server Dev.app`.
- **`~/.tron/` Constitution home** — production profiles/auth, workspace data, log database, and `internal/run/` state. Workflows 1, 2, 3, and 5 use it. Workflow 4 uses `~/.tron-dev`.
- **`auth.json.bearerToken`** — workflows 1, 2, 3, and 5 share the production token. The isolated workflow has a separate token under `~/.tron-dev`.
- **Release identity** — `VERSION.env` is the only hand-edited release source.
  `scripts/tron version sync` mirrors the canonical Cargo/GitHub version into
  the Mac bundle as `TRON_CANONICAL_VERSION`, while `MARKETING_VERSION` remains
  numeric for Apple tooling. Menu-bar feedback and server-version surfaces use
  `VersionDisplay`, so canonical beta versions render as `v0.1 (Beta N)`.

### Mutual exclusion (how they coexist without conflict)

| Layer | Guard | What it prevents |
|---|---|---|
| Wrapper instance | `~/.tron/internal/run/.mac-wrapper.<bundle-id>.lock` (`fcntl(F_SETLK, F_WRLCK)`) | More than one copy of the same SwiftUI wrapper. Release and Debug companion use different lock files and may coexist. |
| Agent instance | `~/.tron/internal/database/tron.sqlite.lock` (cross-process exclusive `flock`) | Two Rust agents running at once. Server refuses to start if held. |
| Port `9847` | OS-level bind | Workflow 5 starting `tron dev` on top of workflow 1/2's running agent — `tron dev` first calls `launchctl bootout` on `com.tron.server`, then binds. |
| LaunchAgent | `SMAppService.register` / `unregister` | One Login Item agent per session is enforced by ServiceManagement; `requiresApproval` is surfaced to the user. |

Wrapper ownership is explicit: installed Release owns production registration; default Debug is companion-only and never installs or repairs the production Login Item. The isolated install scheme is the Debug path that may register a server, but only under `com.tron.server.dev` and `~/.tron-dev`. Production and local Release testing share the same bundle ID/path, so they are intentionally indistinguishable at runtime.

If no LaunchAgent owns `com.tron.server` but port `9847` is already bound or `~/.tron/internal/database/tron.sqlite.lock` is held, registration stops with an "another Tron server is running" error. The app never chooses an alternate port and never treats a direct dev server as a successful install.

**Result**: a contributor can have the production DMG installed, run the default Xcode Debug wrapper for UI work, and switch to `tron dev` to iterate on the agent without uninstalling anything. Both wrappers observe the production port. While `tron dev` owns the port the menu bar shows `Dev Server active`; quitting `tron dev` calls `/Applications/Tron.app/Contents/MacOS/Tron --tron-start-server-and-quit`, registers/starts through `SMAppService`, records the finalized app-version marker only after `/health` passes, and exits without showing the wizard.

### Switching between workflows

```bash
# Start installed Release (after DMG install or a local Release copy):
# Use the wrapper menu. Registration is owned by SMAppService.

# Switch to agent dev (kills production agent, takes over port):
scripts/tron dev  # builds Tron-Dev.app, stops com.tron.server, binds 9847

# Stop agent dev and resume production:
# Ctrl-C the tron dev process. The EXIT trap invokes the wrapper's
# --tron-start-server-and-quit command and returns control to SMAppService.
```

The wrapper (workflow 1 or 2) does not need to be relaunched — its `ServerStatusPoller` picks up the running agent on the next 30s tick.

### One production install path

The wizard is the production install path. It validates `/Applications/Tron.app`, registers the bundled LaunchAgent through `SMAppService`, and lets the helper generate `bearerToken` inside `~/.tron/profiles/auth.json` on first start. `scripts/tron` remains contributor tooling and is not used by the distributed Mac app.

See [development.md](./development.md) for local dev + CI commands and the
[README install section](../../../README.md#install) for end-user-facing setup.
