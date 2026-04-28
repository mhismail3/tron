# Mac App Architecture

> Last verified: 2026-04-27 (clean SMAppService distribution layout)

## Overview

`Tron.app` is the macOS SwiftUI wrapper around the headless Rust agent. It has two runtime modes:

- **Wizard mode** — shown on first launch, before `~/.tron/system/run/.onboarded` exists. Walks the user through Tailscale, Login Item registration, permissions, and pairing-info display.
- **Menu-bar mode** — shown every launch after onboarding. An `NSStatusBar` item polls `system.ping` and exposes status + copy actions + diagnostics.

The switch is driven entirely by the `.onboarded` sentinel file — no UserDefaults flag on the Mac side.

`Tron.app` does NOT embed the full Rust toolchain or build the agent at runtime. The release binary is produced by `cargo build --release --bin tron` and staged into the bundled helper app at `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron`; the helper is signed before the outer app. See [development.md](./development.md) for the build pipeline.

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
│   ├── Resources/                  # bundled Library tree + AppIcon.icns + fonts
│   │   └── Fonts/
│   │       └── Exo2-Variable.ttf   # bundled Google Fonts sans face for wizard typography
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
│   │   ├── Feedback/
│   │   │   ├── FeedbackComposer.swift      # pure GitHub issue composer with redacted log context
│   │   │   └── MenuBarFeedbackAction.swift # menu-bar handler (NSWorkspace.open GitHub issue URL)
│   │   ├── Observability/
│   │   │   └── SentryRedactor.swift        # beforeSend hook: strip paths, mask tokens, drop chat content (Phase 7)
│   │   ├── Onboarding/
│   │   │   ├── ExistingInstallDetector.swift
│   │   │   ├── InstallPlanner.swift    # pure-value plan + plist renderer
│   │   │   ├── PermissionDeepLink.swift # System Settings deep-link URLs only; probes stay wrapper-owned
│   │   │   └── TailscaleProbe.swift
│   │   ├── Pairing/
│   │   │   ├── PairingURLBuilder.swift # builds `tron://pair?…` URL
│   │   │   └── QRCodeGenerator.swift   # CoreImage CIQRCodeGenerator wrapper
│   │   └── Server/
│   │       ├── BearerTokenReader.swift     # reads auth.json bearerToken; caches pairing Tailscale IP in settings.json
│   │       ├── ServerPing.swift            # one-shot string-id system.ping over WS → ServerPingResult; skips broadcast/event frames
│   │       ├── ServerStatusPoller.swift    # 30s periodic poll for menu bar
│   │       ├── SingleInstanceLock.swift    # fcntl(F_SETLK) advisory lock
│   └── Wizard/
│       ├── WizardState.swift       # @Observable, step persistence, navigation
│       ├── WizardView.swift        # NavigationStack + per-step dispatcher
│       └── Steps/                  # One view per WizardStep case
└── Tests/                          # Mirrors Sources layout
```

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

### Protocol-bounded subprocess surface

`LaunchAgentManaging` is the only launch-control interface — register/unregister/restart/isLoaded. `LiveLaunchAgentManager` uses `SMAppService` for registration and unregistration, and uses `launchctl print/kickstart` only for diagnostics/restart. Everything else (permission probes, Tailscale checks, logs) is internal to the wrapper or server RPC.

### Wizard visual system

The wizard uses a single glass canvas with pinned chrome: the header row, progress pill, and bottom actions never participate in body measurement. The shell reports one fixed `480 × WizardLayout.height` content size, where `WizardLayout.height` is the tallest step's preferred height, so every horizontal page transition runs inside one stable viewport and the window never grows mid-slide. The header is one `HStack` that owns the step icon, title, and progress pill, so all three share the same vertical center. The progress indicator has one flat outer capsule, bare `X / total` text, and a tactile bar; avoid nesting another pill around the count. The bar fill is drawn by one animatable Canvas-backed `WizardProgressTrack`, so growth/shrink animation happens inside a single rendered track instead of moving as a separate SwiftUI subview during page transitions. `TronTypography` registers and uses the bundled Exo 2 face for wizard title/body/button text across every step, while terminal/token surfaces stay monospaced. The welcome page shows only centered intro copy; existing-install state is reported on the Install step so detection cannot relayout the first page. Shared icon-led cards use `WizardInfoCard` + `WizardIconTextRow`, whose default horizontal inset equals the icon-to-text gap, whose fixed icon column prevents wide SF Symbols from visually hugging the card's left edge, and whose text column wraps instead of truncating subtext. Card backgrounds go through `WizardGlassCardBackground` / `.wizardGlassCard()` so dark-mode containers keep a subtle transparent emerald fill, glassy border, and shadow instead of a visible gradient or a flat window blend. Completed install rows use tighter spacing than active rows so the success cards sit in the content area instead of crowding the bottom buttons; those cards enter through the install summary transition rather than appearing as an abrupt layout insert. Permissions rows omit individual "Required" badges, use the short intro "Enable the Tron app named on each row in System Settings.", and use moderate card padding plus tightened text so the target-app instruction line stays clean in the 480pt wizard. Each row has one gear button that opens the matching System Settings pane. Screen Recording also has a single wrapper-app drag shortcut beside the gear button, with row copy telling the user to drag it into the list only if the wrapper app is missing. Re-check aligns to the permission status column and uses the disabled branch of `WizardPrimaryButtonStyle` to make blocked Continue buttons visibly inactive.

Low-density steps are deliberately top-biased rather than perfectly centered: Tailscale starts its copy/card group below the header with extra card padding, and the registered-service Install state places its status card in an upper content band. This keeps sparse pages from collapsing into a small cluster in the middle of the canvas. Welcome remains the centered exception: it has no cards, only intro copy.

### Single-instance lock via POSIX `fcntl`

`SingleInstanceLock.acquire()` opens `~/.tron/system/run/.mac-wrapper.lock` and tries `fcntl(F_SETLK, F_WRLCK)`. Second instance's call fails, `AppDelegate` logs + `NSApp.terminate(nil)`. Lock is automatically released on process exit (kernel drops fd locks with the process). Re-acquire from the same process is idempotent (returns true if a valid `fileDescriptor` is already held). The lock guards the wrapper (`com.tron.mac` / `com.tron.mac.dev`) only — the headless agent has its own per-process lock at `~/.tron/system/database/log.db.lock`.

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
                    → .permissions → .pairingInfo → .done
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
`~/.tron/system/run/`. Any wizard-opened Settings pane starts a short-lived
fast-probe watcher until that specific permission turns green. App activation,
Re-check, and the watcher never restart the server. Once all three rows are
green and the user presses Continue, the wizard restarts the helper once so
newly enabled launch-time grants are available before pairing.

The Pairing step does not require a pre-existing `settings.json`. It
reads the agent-issued `auth.json` bearer token, confirms the server is answering
`system.ping`, probes the current Mac Tailscale state live, and only then
caches `server.tailscaleIp` into `settings.json` for future wrapper/menu-bar
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
and `paused` is gray. If `system.ping` fails, the poller asks launchd whether
`com.tron.server` is loaded; unloaded maps to paused, loaded-but-unreachable
maps to failed.

### Menu-bar auxiliary windows

Post-onboarding surfaces stay in menu-bar mode. The first menu item is a custom
header view aligned with the normal menu rows: `Tron`, the current Tailscale
endpoint, a color-coded status line with PID when launchd reports one, and
uptime when `ps` can resolve the pid's elapsed time. "Show pairing info" is a
normal menu action below the header separator. The menu does not repeat the
pairing token because the pairing-only window owns QR/manual copy details for
host, port, token, and server name. That window reuses the
pairing resolver/QR/copy controls without wizard navigation or a progress pill.
The shared pairing surface resolves live when it opens, and copy actions quickly
swap to a checkmark for two seconds so the user gets deterministic visual
feedback. "Show logs" opens a native logs window fed by the read-only
`logs.recent` RPC, with refresh and copy controls.
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
2. Validate helper: Ensure bundled `Tron Server.app`, helper binary, LaunchAgent plist, `BundleProgram`, wrapper `AssociatedBundleIdentifiers`, and signature are present.
3. Plan:          InstallPlanner.plan(…) → Result<InstallPlan, Failure>
4. Register:      SMAppService.agent(plistName: "com.tron.server.plist").register()
   - Before registration, `LiveLaunchAgentManager` reads `launchctl print` to identify the loaded job's parent bundle. Debug (`com.tron.mac.dev`) may boot out an installed-release job before registering. Installed-release (`com.tron.mac`) does not take over from Debug.
   - An enabled SMAppService registration without a loaded launchd job is treated as registered-but-not-ready. The current app replaces that registration through SMAppService, then the pipeline waits for ping.
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

Menu-bar uninstall and `--tron-uninstall-and-quit` both call
`SMAppService.unregister`, remove runtime state
(`run/.onboarded`, `run/updater-state.json`, `run/auth.lock`, and
`run/.mac-wrapper.lock`), and quit the wrapper. By default, auth,
settings, databases, and workspace files remain intact, so the next app
launch returns to the onboarding wizard instead of a broken menu-bar-only
state. The menu confirmation dialog can also remove `settings.json`
and/or `auth.json`; databases and workspace files are still preserved.

## Key Invariants

- **`Tron.app` never builds the Rust agent.** The helper binary is staged at release time by `scripts/bundle-agent.sh` and committed-to-gitignore. Missing or corrupt helper/plist/signature → wizard surfaces a reinstall/move instruction. Any agent-side RPC/TCC/install change must be followed by rerunning the bundle script before Mac dogfood, because Xcode only copies `Sources/Resources/Library`.
- **The Install step is not an `onAppear` side effect.** Landing on the page is read-only; the user must press Install before the wrapper registers the service.
- **Install requests are consumed once.** `InstallStep` can remount during navigation, but it only mutates disk/launchd when `installRequestID > handledInstallRequestID`; success/failure pages are display-only until the user presses Retry.
- **Welcome install detection must not relayout the hero.** `WelcomeStep` does not render install detection state; the Install step owns that status.
- **The helper app must be signed before registration.** Release validation fails loudly if `Tron Server.app`, its binary, the bundled LaunchAgent plist, or the helper signature is missing/corrupt. The helper keeps bundle id `com.tron.server`; the LaunchAgent associates with the wrapper bundle ids because macOS presents some TCC services under the responsible wrapper app.
- **Uninstall preserves user data.** Menu-bar uninstall and `--tron-uninstall-and-quit` unregister the SMAppService agent and clear runtime state. Menu-bar uninstall may remove `settings.json` and/or `auth.json` only when the user explicitly checks the matching reset option; it never removes the database or workspace.
- **A loaded LaunchAgent label is not proof that the correct helper is running.** Registration inspects `launchctl print` for the loaded job's parent bundle identifier before deciding whether to reuse, take over, or fail. Debug wrapper builds may take over installed-release jobs for local dogfood; installed-release builds do not take over Debug jobs.
- **Permission checks are wrapper-owned and probe-only.** The Permissions step records when it opened System Settings only to decide whether to show the visible "Checking permissions..." activity state on return. App activation, Re-check, and the gear-button watcher call native wrapper probes without `launchctl kickstart`, and transient `.probeUnavailable` snapshots preserve the last concrete badge state instead of turning the page gray. The only permission-time restart is the one-time helper restart after all rows are green and the user presses Continue.
- **App bundles are immutable at runtime.** Mutable files live under `~/.tron`; ephemeral locks live under `~/.tron/system/run`; `Tron.app` is only replaced by a new notarized DMG.
- **Wrapper and server share no in-memory state.** Every interaction is either a filesystem read (`auth.json`, `settings.json`, `run/.onboarded`) or a WS RPC call. Crashing the wrapper does not kill the server (LaunchAgent keeps it alive).
- **Single port (`9847`) and single LaunchAgent label (`com.tron.server`) across every workflow.** The DMG-installed `Tron.app` (`com.tron.mac`), the Xcode-built `TronMac.app` dogfood wrapper (`com.tron.mac.dev`), and the `tron dev` agent bundle at `~/.tron/system/run/Tron-Dev.app` (`com.tron.agent`) are all distinct on-disk artifacts that share the same server port and `~/.tron/system/` data tree. The installer never writes app bundles or contributor CLI artifacts into `~/.tron`; all mutable local/runtime artifacts that do exist live directly under `system/run/`. Mutual exclusion is enforced at runtime: the wrapper's `run/.mac-wrapper.lock` rejects a second wrapper, the agent's `log.db.lock` rejects a second agent, and `tron dev` explicitly stops the LaunchAgent before binding 9847. See [Workflows & Variants](#workflows--variants) below for the full breakdown.
- **TronPaths is the single source of truth.** If any path is referenced elsewhere, that's a bug. See `packages/agent/src/core/foundation/paths.rs` for the Rust-side mirror.

## Workflows & Variants

Four workflows operate against the same `~/.tron/system/` data tree and share `port 9847` + `com.tron.server` LaunchAgent. Mutual exclusion at runtime keeps them from colliding.

### The four workflows

| Workflow | Audience | Build product | Bundle ID | On-disk path | What it ships | Server entry point |
|---|---|---|---|---|---|---|
| **1. Production (DMG)** | End users downloading from GitHub Releases | `Tron.app` (notarized + stapled DMG) | `com.tron.mac` | `/Applications/Tron.app` | SwiftUI wrapper (wizard + menu bar) AND the embedded headless agent | `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` inside `/Applications/Tron.app` |
| **2. Local Release test** | Contributors validating a Release build without the DMG wrapper | `Tron.app` (Release build copied into place) | `com.tron.mac` | `/Applications/Tron.app` | Same runtime shape as Production, usually not notarized | Same installed-release helper path inside `/Applications/Tron.app` |
| **3. Wizard dogfood (Xcode Run)** | Contributors testing the wrapper UI | `TronMac.app` (Debug build, Xcode/xcodebuild) | `com.tron.mac.dev` | `~/Library/Developer/Xcode/DerivedData/TronMac-*/Build/Products/Debug/TronMac.app` | Same SwiftUI wrapper as Production but with a debug-profile bundled helper (faster recompiles) | The helper bundled inside the Debug app |
| **4. Agent dev (`tron dev`)** | Contributors iterating on the Rust agent without wrapper UI | `Tron-Dev.app` (no SwiftUI — just a `.app` bundle wrapping the dev Rust binary) | `com.tron.agent` | `~/.tron/system/run/Tron-Dev.app` | Headless Rust agent only (no menu bar, no wizard) | Takes over port 9847 in-process; the system-wide LaunchAgent is stopped first |

> **Naming guard.** `TronMac.app` (workflow 3's build product) and `Tron-Dev.app` (workflow 4's agent bundle) are unrelated. Workflow 3 is the wrapper UI compiled in Debug mode; workflow 4 is just the Rust agent recompiled in dev. They share neither code nor purpose.

> **Why Debug builds `TronMac.app` but Release builds `Tron.app`.** The XcodeGen target is `TronMac` (so `PRODUCT_NAME` defaults to `TronMac` for both configs), but `Configuration/Release.xcconfig` overrides it with `PRODUCT_NAME = Tron`. This produces the `Tron.app` bundle the DMG pipeline (`.github/workflows/release-mac.yml:98 → APP_BUNDLE: Tron.app`) and the `/Applications/Tron.app` end-user surface both expect. Debug intentionally keeps the default so the `TronMacTests` target's `BUNDLE_LOADER` / `TEST_HOST` (which reference `TronMac.app/Contents/MacOS/TronMac`) keep resolving without configuration drift.

### What every workflow shares

- **Port `9847`** — the WS bind. Always exclusive — see "Mutual exclusion" below.
- **LaunchAgent label `com.tron.server`** — the launchd job that owns the installed server. Workflows 1, 2, and 3 register their bundled LaunchAgent through `SMAppService`. Workflow 4 stops it before binding the port itself.
- **`~/.tron/system/`** data tree — settings, auth, sessions, log database, and `run/` state. Wrappers in workflows 1, 2, and 3 mutate the wrapper-side files (`run/.onboarded`, `run/.mac-wrapper.lock`); the agent owns the rest.
- **`auth.json.bearerToken`** — bearer issued by the agent on first start. Same token regardless of which workflow started the agent.
- **`~/.tron/skills/`** — managed skills synced from `packages/agent/skills/` by `tron install` / `tron dev` (NOT by the wrapper).

### Mutual exclusion (how they coexist without conflict)

| Layer | Guard | What it prevents |
|---|---|---|
| Wrapper instance | `~/.tron/system/run/.mac-wrapper.lock` (`fcntl(F_SETLK, F_WRLCK)`) | More than one SwiftUI wrapper running at once (workflows 1/2/3). The second instance logs + terminates. |
| Agent instance | `~/.tron/system/database/log.db.lock` (cross-process exclusive `flock`) | Two Rust agents running at once. Server refuses to start if held. |
| Port `9847` | OS-level bind | Workflow 4 starting `tron dev` on top of workflow 1/2/3's running agent — `tron dev` first calls `launchctl bootout` on `com.tron.server`, then binds. |
| LaunchAgent | `SMAppService.register` / `unregister` | One Login Item agent per session is enforced by ServiceManagement; `requiresApproval` is surfaced to the user. |

Wrapper precedence is explicit: Debug (`com.tron.mac.dev`) outranks installed-release (`com.tron.mac`) because it is the contributor dogfood path. If Debug finds a loaded release-owned job, it boots it out before registering its own helper. If installed Release finds a Debug-owned job, it fails loudly and asks the contributor to stop that build first. Production and local Release testing share the same bundle ID/path, so they are intentionally indistinguishable at runtime.

If no LaunchAgent owns `com.tron.server` but port `9847` is already bound or `~/.tron/system/database/log.db.lock` is held, registration stops with an "another Tron server is running" error. The app never chooses an alternate port and never treats a direct dev server as a successful install.

**Result**: a contributor can have the production DMG installed AND switch to `tron dev` to iterate on the agent without uninstalling anything. The DMG wrapper's menu bar shows "Server stopped" while `tron dev` runs; quitting `tron dev` calls `/Applications/Tron.app/Contents/MacOS/Tron --tron-start-server-and-quit`, which registers/starts through `SMAppService` and exits without showing the wizard.

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

The wizard is the production install path. It validates `/Applications/Tron.app`, registers the bundled LaunchAgent through `SMAppService`, and lets the helper generate `bearerToken` inside `~/.tron/system/auth.json` on first start. `scripts/tron` remains contributor tooling and is not used by the distributed Mac app.

See [development.md](./development.md) for local dev + CI commands and the [README "Mac App" section](../../../README.md#mac-app-tronapp) for end-user-facing documentation.
