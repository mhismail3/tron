# Mac App Architecture

> Last verified: 2026-05-30 (menu dev takeover controls, health-gated starts, and isolated helper registration)

## Overview

`Tron.app` is the macOS SwiftUI wrapper around the headless Rust agent. It has two runtime modes:

- **Wizard mode** — shown on first launch, before `~/.tron/internal/run/.onboarded` exists. Walks the user through Tailscale, Login Item registration, permissions, optional local transcription setup, and pairing-info display.
- **Menu-bar mode** — shown every launch after onboarding. An `NSStatusBar` item polls `system::ping` and exposes status + copy actions + diagnostics. Passive poll/menu-open refreshes never overwrite an explicit busy action such as "Restarting"; the action handler owns the final status refresh when the command exits.

Mac wrapper regression evidence for the active post-100 operating scorecard is
tracked in `packages/agent/docs/post-100-operating-conditions-scorecard.md`.
Wrapper scenarios must keep `/health`, launchd, and SMAppService evidence tied
to the visible wizard/menu state.

The switch is driven entirely by the `.onboarded` sentinel file — no UserDefaults flag on the Mac side.

`Tron.app` does NOT embed the full Rust toolchain or build the agent at runtime. Helper executables are produced by `cargo build --release --bin tron --bin tron-program-worker` and staged into two bundled helper apps: `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/` for production/local Release and `Contents/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/` for isolated Debug install testing. `tron` is the LaunchAgent entrypoint and `tron-program-worker` is the required sibling process for `execute(mode: "program")`. Helpers are signed first, then the outer wrapper is re-signed after copying the `Contents/Library` tree so ServiceManagement can verify the bundled LaunchAgent plists as sealed resources. The agent binary embeds the first-party capability-search ONNX/tokenizer bundle during the Rust build, so semantic capability search is offline and independent of mutable runtime model files. The app bundle also carries managed skills under `Contents/Resources/Skills/`, Constitution defaults under `Contents/Resources/Constitution/`, and the transcription sidecar source files (`worker.py`, `requirements.txt`) under `Contents/Resources/Transcription/`; the venv and model cache are mutable user data under the active Tron home after the user enables transcription. See [development.md](./development.md) for the build pipeline.

## Directory Structure

```
packages/mac-app/
├── project.yml                     # XcodeGen project definition
├── TronMac.entitlements            # Hardened runtime entitlements
├── Configuration/                  # .xcconfig files (Debug/Release)
├── Sources/
│   ├── TronMacApp.swift            # @main entry, AppDelegate, RootView
│   ├── EnvironmentSetup.swift      # Sendable DI struct (live + test values)
│   ├── Info.plist                  # Bundle metadata (starts regular; switches to accessory after onboarding)
│   ├── MenuBar/
│   │   ├── MenuBarActionHandler.swift # routes menu-item descriptors → side effects (subprocess, NSWorkspace, notifications)
│   │   ├── MenuBarController.swift    # NSStatusItem lifecycle + poller task + custom header view
│   │   └── MenuBarItemBuilder.swift   # Pure builder: snapshot → [MenuItemDescriptor]
│   ├── Resources/                  # bundled Library tree, defaults, skills, AppIcon.icns, fonts, transcription source files
│   │   ├── Fonts/
│   │   │   └── Exo2-Variable.ttf   # bundled Google Fonts sans face for wizard typography
│   │   ├── Constitution/           # copied from packages/agent/defaults/
│   │   └── Transcription/
│   │       ├── worker.py           # copied to ~/.tron/internal/transcription/ by the wizard step
│   │       └── requirements.txt
│   ├── Theme/
│   │   ├── TronColors.swift        # emerald palette + shared gradients
│   │   ├── TronFontLoader.swift    # CoreText registration for bundled fonts
│   │   └── TronTypography.swift    # compact Mac wizard type tokens
│   ├── Services/
│   │   ├── LaunchAgentManaging.swift # protocol + SMAppService-backed LiveLaunchAgentManager
│   │   ├── MacCommandLineMode.swift  # internal wrapper commands for SMAppService start/uninstall
│   │   ├── MacRuntimeVariant.swift   # Debug vs installed-release path/ownership rules
│   │   ├── Models.swift            # TailscaleStatus, PermissionStatus, ExistingInstallStatus…
│   │   ├── TronPaths.swift         # Single source of truth for all on-disk paths
│   │   ├── TranscriptionSetup.swift # opt-in sidecar copy, settings write, helper restart
│   │   ├── Feedback/
│   │   │   ├── FeedbackComposer.swift      # pure GitHub issue composer with redacted log context
│   │   │   └── MenuBarFeedbackAction.swift # menu-bar handler (NSWorkspace.open GitHub issue URL)
│   │   ├── Observability/
│   │   │   └── DiagnosticsRedactor.swift   # strip paths, mask tokens, drop chat content
│   │   ├── Onboarding/
│   │   │   ├── ExistingInstallDetector.swift
│   │   │   ├── InstallPlanner.swift    # pure-value plan + plist renderer
│   │   │   ├── PermissionDeepLink.swift # System Settings deep-link URLs only; probes stay wrapper-owned
│   │   │   └── TailscaleProbe.swift
│   │   ├── Pairing/
│   │   │   ├── PairingURLBuilder.swift # builds `tron://pair?…` URL
│   │   │   └── QRCodeGenerator.swift   # CoreImage CIQRCodeGenerator wrapper
│   │   └── Server/
│   │       ├── BearerTokenReader.swift     # reads auth.json bearerToken; caches pairing Tailscale IP in profile.toml
│   │       ├── ServerHealthAwaiter.swift   # bounded /health polling after SMAppService start/load
│   │       ├── ServerPing.swift            # one-shot string-id system::ping over WS → ServerPingResult; skips broadcast/event frames
│   │       ├── ServerStatusPoller.swift    # 30s periodic poll for menu bar
│   │       ├── SingleInstanceLock.swift    # fcntl(F_SETLK) advisory lock
│   └── Wizard/
│       ├── WizardState.swift       # @Observable, step persistence, navigation
│       ├── WizardView.swift        # NavigationStack + per-step dispatcher
│       └── Steps/                  # One view per WizardStep case
└── Tests/                          # Mirrors Sources layout
```

`Contents/Resources/Skills/` is generated at build time from `packages/agent/skills/`; it is not checked into `packages/mac-app/Sources/Resources/`.

## Key Architectural Patterns

### Dependency Injection via `EnvironmentSetup`

Every filesystem read, subprocess shell-out, and time source funnels through
`EnvironmentSetup` — a `Sendable` struct with `@Sendable` closure properties.
Live values in `.live`; tests inject pure-value fakes so no tmp dirs are required.

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

### Pure-value planners + side-effect runners

Long-running operations (install, pairing, menu construction) are split into:
1. A pure-value **planner** — takes inputs, returns a struct describing the work.
2. A **runner** — executes the plan, returning outcomes.
3. A **view** — renders both the plan and the outcome.

Example: `InstallPlanner.plan(paths:) -> Result<InstallPlan, Failure>` is entirely pure and tested with `InstallPlannerTests`. `InstallStep` validates the bundled helper/plist/signature, then asks `LaunchAgentManaging` to register or refresh the service.

The menu bar observes `tron dev` takeover but does not start it. Contributors
start dev servers from the checkout-owned `scripts/tron` CLI; the app only
detects when `Tron-Dev.app` owns port 9847 and exposes the bounded stop/resume
action for that live process.
The CLI dispatcher stays in `scripts/tron`, workspace command families live in
`scripts/tron.d/`, and runtime service/log/auth/bundle helpers shared with the
installed `tron-cli` live in `scripts/tron-lib.d/`. The Mac wrapper remains an
observer/manager through `SMAppService`; script modules must not become a
second production policy owner.

### Protocol-bounded subprocess surface

`LaunchAgentManaging` is the only launch-control interface — register/unregister/restart/isLoaded. `LiveLaunchAgentManager` uses `SMAppService` for registration and unregistration, and uses `launchctl print/kickstart` only for diagnostics/restart. Everything else (permission probes, Tailscale checks, logs) is internal to the wrapper or server engine protocol.

### Wizard visual system

The wizard uses a single glass canvas with pinned chrome: the header row, progress pill, and bottom actions never participate in body measurement. The shell reports one fixed `480 × WizardLayout.height` content size, where `WizardLayout.height` is the tallest step's preferred height, so every horizontal page transition runs inside one stable viewport and the window never grows mid-slide. The header is one `HStack` that owns the step icon, title, and progress pill, so all three share the same vertical center. The progress indicator has one flat outer capsule, bare `X / total` text, and a tactile bar; avoid nesting another pill around the count. The bar fill is drawn by one animatable Canvas-backed `WizardProgressTrack`, so growth/shrink animation happens inside a single rendered track instead of moving as a separate SwiftUI subview during page transitions. `TronTypography` registers and uses the bundled Exo 2 face for wizard title/body/button text across every step, while terminal/token surfaces stay monospaced. The welcome page shows only centered intro copy; existing-install state is reported on the Install step so detection cannot relayout the first page. Shared icon-led cards use `WizardInfoCard` + `WizardIconTextRow`, whose default horizontal inset equals the icon-to-text gap, whose fixed icon column prevents wide SF Symbols from visually hugging the card's left edge, and whose text column wraps instead of truncating subtext. Card backgrounds go through `WizardGlassCardBackground` / `.wizardGlassCard()` so dark-mode containers keep a subtle transparent emerald fill, glassy border, and shadow instead of a visible gradient or a flat window blend. Completed install rows use tighter spacing than active rows so the success cards sit in the content area instead of crowding the bottom buttons; those cards enter through the install summary transition rather than appearing as an abrupt layout insert. Permissions rows omit individual "Required" badges, use the short intro "Enable the Tron app named on each row in System Settings.", and use moderate card padding plus tightened text so the target-app instruction line stays clean in the 480pt wizard. Each row has one gear button that opens the matching System Settings pane. Screen Recording also has a single wrapper-app drag shortcut beside the gear button, with row copy telling the user to drag it into the list only if the wrapper app is missing. Re-check aligns to the permission status column and uses the disabled branch of `WizardPrimaryButtonStyle` to make blocked Continue buttons visibly inactive.

Low-density steps are deliberately top-biased rather than perfectly centered: Tailscale starts its copy/card group below the header with extra card padding, and the registered-service Install state places its status card in an upper content band. This keeps sparse pages from collapsing into a small cluster in the middle of the canvas. Welcome remains the centered exception: it has no cards, only intro copy.

### Single-instance lock via POSIX `fcntl`

`SingleInstanceLock.acquire()` opens `~/.tron/internal/run/.mac-wrapper.<bundle-id>.lock` and tries `fcntl(F_SETLK, F_WRLCK)`. A second instance of the same wrapper build fails, `AppDelegate` logs + `NSApp.terminate(nil)`. Release (`com.tron.mac`) and Debug companion (`com.tron.mac.dev`) intentionally use different lock files so their menu icons can coexist while they observe the same production server. Locks are automatically released on process exit (kernel drops fd locks with the process). Re-acquire from the same process is idempotent (returns true if a valid `fileDescriptor` is already held). The headless agent has its own per-process lock at `~/.tron/internal/database/log.db.lock`.

**XCTest bypass**: `AppDelegate.applicationDidFinishLaunching` checks for `XCTestSessionIdentifier` in the process environment and skips `SingleInstanceLock.acquire()` entirely when it's set. Without this, `xcodebuild test` would fail to launch the test host whenever a real `Tron.app` is running on the same machine — a routine state for any contributor who dogfoods. The bypass is benign in production because Xcode never sets that env var outside test runs.

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
                    → .permissions → .transcription
                    → .iosBeta → .pairingInfo → .done
                └─ DoneStep taps "Finish"
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

The install heartbeat is intentionally permission-neutral: the LaunchAgent
may start the server, but ordinary agent startup must not probe TCC or open
System Settings. The Permissions step is the first place any TCC probe runs,
and those probes run in the wrapper process because the LaunchAgent associates
the helper with the wrapper bundle IDs. Full Disk Access, Screen Recording,
and Accessibility therefore all point at `Tron.app` or `TronMac.app`, matching
the app entry macOS evaluates for the running helper. Gear buttons only open
the matching System Settings pane; they never call prompt APIs, so no second
modal appears over the pane. Screen Recording first checks the current process
with `CGPreflightScreenCaptureAccess()`. If that process still has the stale
pre-relaunch answer after a Settings change, the wizard starts the same wrapper
executable once as a quiet child process and reads the fresh result from
`~/.tron/internal/run/`. Any wizard-opened Settings pane starts a short-lived
fast-probe watcher until that specific permission turns green. App activation,
Re-check, and the watcher never restart the server. Once all three rows are
green and the user presses Continue, the wizard restarts the helper once so
newly enabled launch-time grants are available before pairing.

The Transcription step runs after the server is reachable and permissions
are settled. Default settings keep `server.transcription.enabled = false`,
so a fresh server logs `transcription sidecar disabled` instead of trying to
download a model. Applying the step copies only `worker.py` and
`requirements.txt` from the signed app bundle into
`~/.tron/internal/transcription/`, making later iOS Settings enablement safe.
If the user enables the toggle, the wrapper writes
`server.transcription.enabled = true` into `profiles/user/profile.toml`, restarts
`com.tron.server`, and waits for `system::ping`. The helper then owns the
Python venv and HuggingFace cache under that same directory. If the user skips
the step, the wrapper writes `enabled = false` and does not restart the helper.

The iOS Beta step is a static handoff before pairing. It renders
`https://testflight.apple.com/join/xbuX1Grx` as a QR code so the user's iPhone
opens the public Tron TestFlight invite and installs the latest beta available
to that tester group. The page also exposes copy/open fallbacks for the same
URL, but it does not call the server or mutate onboarding state beyond normal
step persistence.

The Pairing step does not require a pre-existing user profile. It
reads the agent-issued `auth.json` bearer token, confirms the server is answering
`system::ping`, probes the current Mac Tailscale state live, and only then
caches `server.tailscaleIp` into `profiles/user/profile.toml` for future wrapper/menu-bar
reads and later server settings reloads. If the cache write fails, the freshly
resolved QR payload still works; settings are a fallback/cache, not a
prerequisite for first-run pairing.

### Subsequent launches (menu-bar-only path)

```
TronMacApp.main()
  └─ AppDelegate.applicationDidFinishLaunching
       ├─ SingleInstanceLock.acquire()
       └─ setup.onboardedSentinelExists() → true
           └─ installMenuBar(setup:)
                └─ MenuBarController
                    ├─ NSStatusItem with tinted Tron logo
                    └─ 30s poller task → ServerStatusPoller.snapshot()
                         ├─ setup.pingServer(token) → ServerPingResult
                         ├─ launchAgentManager.isLoaded() when ping fails
                         ├─ setup.readBearerToken()
                         └─ setup.readTailscaleIPFromSettings()
```

The menu bar renders an explicit server state rather than a generic dot:
`running` is green, `checking`/busy/unauthorized are yellow, `failed` is red,
and `paused` is gray. On a successful ping the poller asks the local port owner
for PID/uptime, so `tron dev` takeover reports the `Tron-Dev.app` process
instead of stale LaunchAgent metadata and marks the header `Dev Server active`.
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
and QR code are ready; it keeps the generated QR image in state so the spinner
can crossfade smoothly into the QR/manual-value containers on a custom timing
curve. Copy actions quickly swap to a checkmark for two seconds so the user gets
deterministic visual feedback. "Show logs" opens a native logs window fed by
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
2. Validate helper: Ensure the active bundled helper app (`Tron Server.app` or `Tron Server Dev.app`), both helper executables, LaunchAgent plist, `BundleProgram`, wrapper `AssociatedBundleIdentifiers`, and signature are present.
3. Plan:          InstallPlanner.plan(…) → Result<InstallPlan, Failure>
4. Register:      SMAppService.agent(plistName: "<active-label>.plist").register()
   - Installed Release manages `com.tron.server` on port `9847`; the isolated install scheme manages `com.tron.server.dev` on port `9848`.
   - Default Xcode Debug is companion-only. If it reaches the Install step it fails before mutating Login Items and tells the contributor to use `/Applications/Tron.app` or the isolated install-testing scheme.
   - Before registration, `LiveLaunchAgentManager` reads `launchctl print` to identify the loaded job's parent bundle and event-trigger executable. An enabled SMAppService registration without a loaded launchd job, or one pointing at a missing/mismatched helper path, is treated as registered-but-not-ready. A manager build replaces that registration through SMAppService, then the pipeline waits for ping.
5. Await ping:    poll setup.pingServer(token) for 30s on 1s cadence, ignoring connection events
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
(`run/.onboarded`, `run/updater-state.json`, `run/auth.lock`, and
the current `run/.mac-wrapper.<bundle-id>.lock`), and quit the wrapper. By default, auth,
profile settings, databases, and workspace files remain intact, so the next app
launch returns to the onboarding wizard instead of a broken menu-bar-only
state. The menu confirmation dialog can also clear `[settings]` overrides from
`profiles/user/profile.toml` and/or remove `auth.json`; databases and workspace
files are still preserved.

## Key Invariants

- **`Tron.app` never builds the Rust agent.** The `tron` and `tron-program-worker` helper executables are staged at release time by `scripts/bundle-agent.sh` and committed-to-gitignore. Missing or corrupt helpers/plist/signature → wizard surfaces a reinstall/move instruction. Any agent-side engine capability/TCC/install/settings-default change must be followed by rerunning the bundle script before Mac dogfood, because Xcode only copies `Sources/Resources/Library`. Local relay dogfood is configured through the ignored `packages/mac-app/.env.local` file that the bundle script reads before Cargo compiles the helpers; production releases use GitHub Actions secrets instead.
- **The Install step is not an `onAppear` side effect.** Landing on the page is read-only; the user must press Install before the wrapper registers the service.
- **Install requests are consumed once.** `InstallStep` can remount during navigation, but it only mutates disk/launchd when `installRequestID > handledInstallRequestID`; success/failure pages are display-only until the user presses Retry.
- **Welcome install detection must not relayout the hero.** `WelcomeStep` does not render install detection state; the Install step owns that status.
- **The helper app must be signed before registration.** Validation fails loudly if the active helper app, its binary, the bundled LaunchAgent plist, or the helper signature is missing/corrupt. Production/local Release use `Tron Server.app` with bundle id `com.tron.server`; isolated Debug uses `Tron Server Dev.app` with bundle id `com.tron.server.dev`. The helper bundle id intentionally matches the active LaunchAgent label, while the LaunchAgent associates with the wrapper bundle ids because macOS presents some TCC services under the responsible wrapper app.
- **Uninstall preserves user data.** Menu-bar uninstall and manager-mode `--tron-uninstall-and-quit` unregister the SMAppService agent and clear runtime state. Default Debug companion mode refuses to uninstall production. Menu-bar uninstall may clear `[settings]` overrides from `profiles/user/profile.toml` and/or remove `auth.json` only when the user explicitly checks the matching reset option; it never removes the database or workspace.
- **A loaded LaunchAgent label is not proof that the correct helper is running.** Registration inspects `launchctl print` for the loaded job's parent bundle identifier and event-trigger executable before deciding whether to reuse, repair, or fail. Missing/mismatched helper executables are stale registrations and manager builds repair them; default Debug companion builds never repair or own production registration.
- **Permission checks are wrapper-owned and probe-only.** The Permissions step records when it opened System Settings only to decide whether to show the visible "Checking permissions..." activity state on return. App activation, Re-check, and the gear-button watcher call native wrapper probes without `launchctl kickstart`, and transient `.probeUnavailable` snapshots preserve the last concrete badge state instead of turning the page gray. The only permission-time restart is the one-time helper restart after all rows are green and the user presses Continue.
- **Transcription is opt-in user data.** `worker.py` and `requirements.txt` ship read-only in the app bundle, and the wizard copies them to `~/.tron/internal/transcription/` when the user applies the Transcription step. The app bundle never contains the Python venv or Parakeet model cache, and skipping the step leaves the server setting false.
- **App bundles are immutable at runtime.** Mutable files live under `~/.tron`; ephemeral locks live under `~/.tron/internal/run`; `Tron.app` is only replaced by a new notarized DMG.
- **Wrapper and server share no in-memory state.** Every interaction is either a filesystem read (`auth.json`, `profile.toml`, `run/.onboarded`) or a engine protocol call. Crashing the wrapper does not kill the server (LaunchAgent keeps it alive).
- **Production uses one port (`9847`) and one LaunchAgent label (`com.tron.server`).** The DMG-installed `Tron.app` (`com.tron.mac`), local Release copies, the default Xcode Debug companion (`com.tron.mac.dev`), and the `tron dev` agent bundle at `~/.tron/internal/run/Tron-Dev.app` (`com.tron.agent`) all target the production `~/.tron` data tree. Debug companion observes production but does not manage its Login Item; `tron dev` is the explicit server takeover path and stops the production LaunchAgent before binding 9847. The isolated install scheme is the exception by design: it uses `com.tron.server.dev`, `Tron Server Dev.app`, port `9848`, and `~/.tron-dev`.
- **TronPaths is the single source of truth.** If any path is referenced elsewhere, that's a bug. See `packages/agent/src/core/foundation/paths.rs` for the Rust-side mirror.

## Workflows & Variants

Production workflows operate against the same `~/.tron/internal/` data tree and share `port 9847` + `com.tron.server` LaunchAgent. The isolated install workflow uses its own data tree, label, and port so reinstall testing can happen while production remains installed.

### The five workflows

| Workflow | Audience | Build product | Bundle ID | On-disk path | What it ships | Server entry point |
|---|---|---|---|---|---|---|
| **1. Production (DMG)** | End users downloading from GitHub Releases | `Tron.app` (notarized + stapled DMG) | `com.tron.mac` | `/Applications/Tron.app` | SwiftUI wrapper (wizard + menu bar), embedded headless agent, and transcription source files | `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` inside `/Applications/Tron.app` |
| **2. Local Release test** | Contributors validating a Release build without the DMG wrapper | `Tron.app` (Release build copied into place) | `com.tron.mac` | `/Applications/Tron.app` | Same runtime shape as Production, usually not notarized | Same installed-release helper path inside `/Applications/Tron.app` |
| **3. Debug companion (default Xcode Run)** | Contributors testing wrapper UI while production stays installed | `TronMac.app` (Debug build, Xcode/xcodebuild) | `com.tron.mac.dev` | `~/Library/Developer/Xcode/DerivedData/TronMac-*/Build/Products/Debug/TronMac.app` | Same SwiftUI wrapper as Production with a debug-profile bundled helper and transcription source files | Observes the production server on port 9847; does not register or mutate `com.tron.server` |
| **4. Isolated install test** | Contributors testing first-run/reinstall flows from Xcode | `TronMac.app` with `TRON_MAC_INSTALL_MODE=isolated` | `com.tron.mac.dev` | DerivedData | Debug wrapper and `Tron Server Dev.app`, separate install target | Registers `com.tron.server.dev`, runs port 9848, uses `~/.tron-dev` via `TRON_HOME_NAME=.tron-dev` |
| **5. Agent dev (`tron dev`)** | Contributors iterating on the Rust agent without wrapper UI | `Tron-Dev.app` (no SwiftUI — just a `.app` bundle wrapping the dev Rust binary) | `com.tron.agent` | `~/.tron/internal/run/Tron-Dev.app` | Headless Rust agent only (no menu bar, no wizard) | Takes over port 9847 in-process; the production LaunchAgent is stopped first |

> **Naming guard.** `TronMac.app` (workflows 3 and 4's build product) and `Tron-Dev.app` (workflow 5's agent bundle) are unrelated. `TronMac.app` is the wrapper UI compiled in Debug mode; `Tron-Dev.app` is just the Rust agent recompiled in dev. They share neither code nor purpose.

> **Why Debug builds `TronMac.app` but Release builds `Tron.app`.** The XcodeGen target is `TronMac` (so `PRODUCT_NAME` defaults to `TronMac` for both configs), but `Configuration/Release.xcconfig` overrides it with `PRODUCT_NAME = Tron`. This produces the `Tron.app` bundle the DMG pipeline (`.github/workflows/release-mac.yml:98 → APP_BUNDLE: Tron.app`) and the `/Applications/Tron.app` end-user surface both expect. Debug intentionally keeps the default so the `TronMacTests` target's `BUNDLE_LOADER` / `TEST_HOST` (which reference `TronMac.app/Contents/MacOS/TronMac`) keep resolving without configuration drift.

### What every workflow shares

- **Port `9847`** — the production WS bind. Always exclusive — see "Mutual exclusion" below. Workflow 4 uses `9848`.
- **LaunchAgent label `com.tron.server`** — the launchd job that owns the installed production server. Workflows 1 and 2 register it through `SMAppService`; workflow 3 observes it; workflow 5 stops it before binding the port itself. Workflow 4 registers only `com.tron.server.dev` and points `BundleProgram` at `Tron Server Dev.app`.
- **`~/.tron/` Constitution home** — production profiles/auth, memory, workspace data, log database, and `internal/run/` state. Workflows 1, 2, 3, and 5 use it. Workflow 4 uses `~/.tron-dev`.
- **`auth.json.bearerToken`** — bearer issued by the agent on first start. Same token regardless of which workflow started the agent.
- **`~/.tron/skills/`** — managed skills synced from the wrapper's bundled `Contents/Resources/Skills/` by production install/menu-bar start paths, and from `packages/agent/skills/` by `tron install` / `tron dev`. Same-name user-owned directories without `.managed` are preserved; stale `.managed` directories disappear when the bundled set no longer contains them.
- **Release identity** — `VERSION.env` is the only hand-edited release source.
  `scripts/tron version sync` mirrors the canonical Cargo/GitHub version into
  the Mac bundle as `TRON_CANONICAL_VERSION`, while `MARKETING_VERSION` remains
  numeric for Apple tooling. Menu-bar feedback and server-version surfaces use
  `VersionDisplay`, so `0.1.0-beta.1` renders as `v0.1 (Beta 1)`.

### Mutual exclusion (how they coexist without conflict)

| Layer | Guard | What it prevents |
|---|---|---|
| Wrapper instance | `~/.tron/internal/run/.mac-wrapper.<bundle-id>.lock` (`fcntl(F_SETLK, F_WRLCK)`) | More than one copy of the same SwiftUI wrapper. Release and Debug companion use different lock files and may coexist. |
| Agent instance | `~/.tron/internal/database/log.db.lock` (cross-process exclusive `flock`) | Two Rust agents running at once. Server refuses to start if held. |
| Port `9847` | OS-level bind | Workflow 5 starting `tron dev` on top of workflow 1/2's running agent — `tron dev` first calls `launchctl bootout` on `com.tron.server`, then binds. |
| LaunchAgent | `SMAppService.register` / `unregister` | One Login Item agent per session is enforced by ServiceManagement; `requiresApproval` is surfaced to the user. |

Wrapper ownership is explicit: installed Release owns production registration; default Debug is companion-only and never installs or repairs the production Login Item. The isolated install scheme is the Debug path that may register a server, but only under `com.tron.server.dev` and `~/.tron-dev`. Production and local Release testing share the same bundle ID/path, so they are intentionally indistinguishable at runtime.

If no LaunchAgent owns `com.tron.server` but port `9847` is already bound or `~/.tron/internal/database/log.db.lock` is held, registration stops with an "another Tron server is running" error. The app never chooses an alternate port and never treats a direct dev server as a successful install.

**Result**: a contributor can have the production DMG installed, run the default Xcode Debug wrapper for UI work, and switch to `tron dev` to iterate on the agent without uninstalling anything. Both wrappers observe the production port. While `tron dev` owns the port the menu bar shows `Dev Server active`; quitting `tron dev` calls `/Applications/Tron.app/Contents/MacOS/Tron --tron-start-server-and-quit`, which syncs bundled managed skills, registers/starts through `SMAppService`, and exits without showing the wizard. The same menu-bar startup sync is what makes a replaced `/Applications/Tron.app` refresh managed skills after a DMG update. Managed-skill sync is serialized within the wrapper process and skips directories whose bundled and installed contents already match, so an idle menu-bar launch does not rewrite `~/.tron/skills/`.

### Switching between workflows

```bash
# Start installed Release (after DMG install, local Release copy, or Debug wizard completion):
# Use the wrapper menu. Registration is owned by SMAppService.

# Switch to agent dev (kills production agent, takes over port):
tron dev          # builds Tron-Dev.app, stops com.tron.server, binds 9847

# Stop agent dev and resume production:
# Ctrl-C the tron dev process. The EXIT trap invokes the wrapper's
# --tron-start-server-and-quit command and returns control to SMAppService.
```

The wrapper (workflow 1 or 2) does not need to be relaunched — its `ServerStatusPoller` picks up the running agent on the next 30s tick.

### One production install path

The wizard is the production install path. It validates `/Applications/Tron.app`, syncs bundled managed skills into `~/.tron/skills/`, registers the bundled LaunchAgent through `SMAppService`, and lets the helper generate `bearerToken` inside `~/.tron/profiles/auth.json` on first start. `scripts/tron` remains contributor tooling and is not used by the distributed Mac app.

See [development.md](./development.md) for local dev + CI commands and the [README "Mac App" section](../../../README.md#mac-app-tronapp) for end-user-facing documentation.
