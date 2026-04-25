# Mac App Architecture

> Last verified: 2026-04-24 (Phase 9 onboarding polish)

## Overview

`Tron.app` is the macOS SwiftUI wrapper around the headless Rust agent. It has two runtime modes:

- **Wizard mode** — shown on first launch, before `~/.tron/system/.onboarded` exists. Walks the user through Tailscale, existing-install detection, an explicit binary-install confirmation, permissions, and pairing-info display.
- **Menu-bar mode** — shown every launch after onboarding. An `NSStatusBar` item polls `system.ping` and exposes status + copy actions + diagnostics.

The switch is driven entirely by the `.onboarded` sentinel file — no UserDefaults flag on the Mac side. This keeps the gate consistent with `scripts/tron` (the CLI-install path writes the same file).

`Tron.app` does NOT embed the full Rust toolchain or build the agent at runtime. The release binary is produced by `cargo build --release --bin tron` and staged into `Tron.app/Contents/Resources/tron-agent` before the `.app` is code-signed. See [development.md](./development.md) for the build pipeline.

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
│   │   ├── MenuBarController.swift    # NSStatusItem lifecycle + timer
│   │   └── MenuBarItemBuilder.swift   # Pure builder: snapshot → [MenuItemDescriptor]
│   ├── Resources/                  # tron-agent + AppIcon.icns + bundled fonts staged into the wrapper bundle
│   │   └── Fonts/
│   │       └── Exo2-Variable.ttf   # bundled Google Fonts sans face for wizard typography
│   ├── Theme/
│   │   ├── TronColors.swift        # emerald palette + shared gradients
│   │   ├── TronFontLoader.swift    # CoreText registration for bundled fonts
│   │   └── TronTypography.swift    # compact Mac wizard type tokens
│   ├── Services/
│   │   ├── LaunchAgentManaging.swift # protocol + LiveLaunchAgentManager (shells launchctl)
│   │   ├── Models.swift            # TailscaleStatus, PermissionStatus, ExistingInstallStatus…
│   │   ├── TronPaths.swift         # Single source of truth for all on-disk paths
│   │   ├── Feedback/
│   │   │   ├── FeedbackComposer.swift      # pure: Mailto URL + log-tail extraction
│   │   │   └── MenuBarFeedbackAction.swift # menu-bar handler (NSWorkspace.open the Mailto URL)
│   │   ├── Observability/
│   │   │   └── SentryRedactor.swift        # beforeSend hook: strip paths, mask tokens, drop chat content (Phase 7)
│   │   ├── Onboarding/
│   │   │   ├── ExistingInstallDetector.swift
│   │   │   ├── InstallArtifactCleaner.swift # unload/remove launch artifacts while preserving user data
│   │   │   ├── InstallPlanner.swift    # pure-value plan + plist renderer
│   │   │   ├── PermissionProbe.swift
│   │   │   └── TailscaleProbe.swift
│   │   ├── Pairing/
│   │   │   ├── PairingURLBuilder.swift # builds `tron://pair?…` URL
│   │   │   └── QRCodeGenerator.swift   # CoreImage CIQRCodeGenerator wrapper
│   │   └── Server/
│   │       ├── BearerTokenReader.swift     # reads auth-token.json (+ legacy plain-string fallback) with 0o600 permission guard
│   │       ├── ServerPing.swift            # one-shot string-id system.ping over WS → ServerPingResult; skips broadcast/event frames
│   │       ├── ServerStatusPoller.swift    # 30s periodic poll for menu bar
│   │       ├── SingleInstanceLock.swift    # fcntl(F_SETLK) advisory lock
│   │       └── TronCLI.swift               # single source of truth for resolving the `tron` binary on PATH
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

Example: `InstallPlanner.plan(sourceBinary:paths:existingInstall:) -> Result<InstallPlan, Failure>` is entirely pure and tested with `InstallPlannerTests`. `BinaryInstaller.install(plan:)` runs it. `InstallStep` calls both.

### Protocol-bounded subprocess surface

`LaunchAgentManaging` is the only subprocess-style interface — load/unload/restart/isLoaded. `LiveLaunchAgentManager` shells `launchctl`; `MockLaunchAgentManager` records calls and returns configured outcomes. Everything else (permission probes, Tailscale checks) is internal to the wrapper.

### Wizard visual system

The wizard uses a single glass canvas with pinned chrome: the header row, progress pill, and bottom actions never participate in body measurement. The header is one `HStack` that owns the step icon, title, and progress pill, so all three share the same vertical center and the progress pill cannot drift during AppKit window resizes. The progress indicator has one flat outer capsule, bare `X / 7` text, and a tactile bar; avoid nesting another pill around the count. The bar fill is drawn by one animatable Canvas-backed `WizardProgressTrack`, so growth/shrink animation happens inside a single rendered track instead of moving as a separate SwiftUI subview while AppKit resizes between height bands. `TronTypography` registers and uses the bundled Exo 2 face for wizard title/body/button text across every step, while terminal/token surfaces stay monospaced. The welcome page centers its intro copy and optional detected-install banner as one middle group, and the banner sizes to its content instead of spanning the window. Tailscale and Existing Install center their body groups in the space between title and buttons. Existing Install recovery appears as its own compact "Need a fresh start?" cleanup card below the install status card, pads its copy away from the left edge, and uses the same square tertiary icon button style as the Permissions settings buttons. Permissions rows omit individual "Required" badges, align the Re-check link icon with the row status icons, and rely on the disabled branch of `WizardPrimaryButtonStyle` to make blocked Continue buttons visibly inactive.

### Single-instance lock via POSIX `fcntl`

`SingleInstanceLock.acquire()` opens `~/.tron/system/.mac-wrapper.lock` and tries `fcntl(F_SETLK, F_WRLCK)`. Second instance's call fails, `AppDelegate` logs + `NSApp.terminate(nil)`. Lock is automatically released on process exit (kernel drops fd locks with the process). Re-acquire from the same process is idempotent (returns true if a valid `fileDescriptor` is already held). The lock guards the wrapper (`com.tron.mac` / `com.tron.mac.dev`) only — the headless agent (`com.tron.agent`) has its own per-process locks under `~/.tron/system/database/log.db.lock`.

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
                    → .tailscale → .existingInstall → .install
                    → .permissions → .pairingInfo → .done
                └─ DoneStep taps "Finish"
                    ├─ setup.touchOnboardedSentinel()  ← atomic tempfile+rename
                    └─ post .tronWizardDidComplete
                         └─ AppDelegate observer
                             ├─ installMenuBar(setup:)
                             ├─ NSApp.setActivationPolicy(.accessory)
                             └─ orderOut all windows
```

The install heartbeat is intentionally permission-neutral: the LaunchAgent
may start the server, but ordinary agent startup must not probe TCC or open
System Settings. The Permissions step is the first place the wrapper asks the
agent for `system.probePermissions`, so Full Disk Access, Screen Recording,
and Accessibility prompts cannot race the install progress UI. The step
rechecks on app activation, but it only kickstarts launchd after consuming a
Settings round-trip opened by one of the wizard's permission buttons; focus
changes inside System Settings are not restart signals.

### Subsequent launches (menu-bar-only path)

```
TronMacApp.main()
  └─ AppDelegate.applicationDidFinishLaunching
       ├─ SingleInstanceLock.acquire()
       └─ setup.onboardedSentinelExists() → true
           └─ installMenuBar(setup:)
                └─ MenuBarController
                    ├─ NSStatusItem with template icon
                    └─ 30s Timer → ServerStatusPoller.snapshot()
                         ├─ setup.pingServer(token) → ServerPingResult
                         ├─ setup.readBearerToken()
                         └─ setup.readTailscaleIPFromSettings()
```

### Menu-bar → wizard re-entry (post-onboarding)

The "Show pairing info…" menu item reopens the wizard at `pairingInfo` without going through `AppDelegate`. Mode + activation policy are owned by `RootView` (SwiftUI `@State`); `AppDelegate` only owns the LaunchAgent and `.onboarded` sentinel side. See [`.claude/rules/wizard-steps.md`](../.claude/rules/wizard-steps.md) for the full sequence.

### Install pipeline (wizard's `InstallStep`)

```
0. Wait for user: Install CTA increments WizardState.installRequestID; no disk or launchd mutation happens before this
   - WizardState.handledInstallRequestID suppresses replay when page 4 remounts after back/forward navigation
1. Locate source: Bundle.main.url(forResource: "tron-agent")
2. Plan:          InstallPlanner.plan(…) → Result<InstallPlan, Failure>
3. Prepare app:   BinaryInstaller.install(plan:)   [tempfile + rename, chmod 755, write Info.plist/resources, codesign -]
4. Write plist:   BinaryInstaller.writePlist(plan:) [atomic write]
5. Load agent:    launchctl bootstrap, or kickstart -k when label is already loaded
6. Await ping:    poll setup.pingServer(token) for 30s on 1s cadence, ignoring connection events
→ state.installOutcome set; Pairing step unblocks when .success | .alreadyInstalled

The UI intentionally paces quick stages for a few hundred milliseconds
so the install does not visually jump from pending to three green checks
before the user can understand the sequence.
When revisiting the page after success, row state is derived
synchronously from terminal `installOutcome` so the completed icons are
part of the page transition rather than a post-mount update.

Recovery action:
ExistingInstallStep / failed InstallStep → InstallArtifactCleaner.clean(...)
→ launchctl bootout com.tron.server when loaded
→ remove ~/.tron/system/Tron.app and ~/Library/LaunchAgents/com.tron.server.plist
→ remove ~/.tron/system/deployment/ only when it is empty legacy state
→ preserve auth.json, auth-token.json, settings.json, database/, and workspace/
```

## Key Invariants

- **`Tron.app` never builds the Rust agent.** The binary is staged at release time by `scripts/bundle-agent.sh` and committed-to-gitignore. Missing → wizard surfaces `sourceBinaryMissing` with a "reinstall the DMG" message.
- **The Install step is not an `onAppear` side effect.** Landing on the page is read-only; the user must press Install before the wrapper copies the binary, writes the LaunchAgent plist, or calls launchd.
- **Install requests are consumed once.** `InstallStep` can remount during navigation, but it only mutates disk/launchd when `installRequestID > handledInstallRequestID`; success/failure pages are display-only until the user presses Retry.
- **Welcome install detection must not relayout the hero.** `WelcomeStep` overlays the existing-install banner below the centered copy; it must not switch the first page to a top-leading stack when detection completes.
- **The inner server bundle must be signed before launchd starts it.** `BinaryInstaller.install` ad-hoc signs `~/.tron/system/Tron.app` after writing `Info.plist` and resources so `codesign -dv` reports `Identifier=com.tron.server`, a bound Info.plist, and sealed resources. Accessibility TCC can flip grants back off when the bundle is left with only the executable's linker-generated ad-hoc identity.
- **Cleanup preserves user data.** The installer recovery action unloads the LaunchAgent, removes the installed app bundle + plist, and removes an empty legacy `deployment/` directory if present. It never removes auth, settings, sessions, databases, workspace files, or non-empty dev/deploy/update artifacts.
- **A loaded LaunchAgent label is not proof that the new binary is running.** After writing the plist, `.alreadyLoaded` is followed by `launchctl kickstart -k gui/<uid>/com.tron.server` so stale processes left from interrupted installs consume the just-copied bundle.
- **App activation is a recheck by default.** The Permissions step records which permission Settings pane it opened and consumes that return once; repeated focus changes from System Settings only refresh the RPC snapshot.
- **All atomic writes use tempfile + `replaceItemAt` (matching the Rust agent's `tempfile::Builder → sync_all → rename`).** See `OnboardedSentinelWriter.touch` and `BinaryInstaller.install`.
- **Wrapper and server share no in-memory state.** Every interaction is either a filesystem read (`auth-token.json`, `settings.json`, `.onboarded`) or a WS RPC call. Crashing the wrapper does not kill the server (LaunchAgent keeps it alive).
- **Single port (`9847`) and single LaunchAgent label (`com.tron.server`) across every workflow.** The DMG-installed `Tron.app` (`com.tron.mac`), the Xcode-built `TronMac.app` dogfood wrapper (`com.tron.mac.dev`), and the `tron dev` agent bundle at `~/.tron/system/deployment/Tron-Dev.app` (`com.tron.agent`) are all distinct on-disk artifacts that share the same server port and `~/.tron/system/` data tree. The installer does not write deployment artifacts; `deployment/` is for local dev/deploy/update state and may be absent or empty after a normal install. Mutual exclusion is enforced at runtime: the wrapper's `.mac-wrapper.lock` rejects a second wrapper, the agent's `log.db.lock` rejects a second agent, and `tron dev` explicitly stops the LaunchAgent before binding 9847. See [Workflows & Variants](#workflows--variants) below for the full breakdown.
- **TronPaths is the single source of truth.** If any path is referenced elsewhere, that's a bug. See `packages/agent/src/core/foundation/paths.rs` for the Rust-side mirror.

## Workflows & Variants

Three distinct workflows operate against the same `~/.tron/system/` data tree and share `port 9847` + `com.tron.server` LaunchAgent. Mutual exclusion at runtime keeps them from colliding.

### The three workflows

| Workflow | Audience | Build product | Bundle ID | On-disk path | What it ships | Server install path |
|---|---|---|---|---|---|---|
| **1. Production (DMG)** | End users downloading from GitHub Releases | `Tron.app` (notarized + stapled DMG) | `com.tron.mac` | `/Applications/Tron.app` | SwiftUI wrapper (wizard + menu bar) AND the embedded headless agent | `~/.tron/system/Tron.app/Contents/MacOS/tron` (copied during wizard's Install step) |
| **2. Wizard dogfood (Xcode Run)** | Contributors testing the wrapper UI | `TronMac.app` (Debug build, Xcode/xcodebuild) | `com.tron.mac.dev` | `~/Library/Developer/Xcode/DerivedData/TronMac-*/Build/Products/Debug/TronMac.app` | Same SwiftUI wrapper as Production but with a debug-profile bundled agent (faster recompiles) | Same as Production — wizard's Install step copies the bundled agent to `~/.tron/system/Tron.app/Contents/MacOS/tron` |
| **3. Agent dev (`tron dev`)** | Contributors iterating on the Rust agent without wrapper UI | `Tron-Dev.app` (no SwiftUI — just a `.app` bundle wrapping the dev Rust binary) | `com.tron.agent` | `~/.tron/system/deployment/Tron-Dev.app` | Headless Rust agent only (no menu bar, no wizard) | Takes over port 9847 in-process; the system-wide LaunchAgent is stopped first |

> **Naming guard.** `TronMac.app` (workflow 2's build product) and `Tron-Dev.app` (workflow 3's agent bundle) are unrelated. Workflow 2 is the wrapper UI compiled in Debug mode; workflow 3 is just the Rust agent recompiled in dev. They share neither code nor purpose.

> **Why Debug builds `TronMac.app` but Release builds `Tron.app`.** The XcodeGen target is `TronMac` (so `PRODUCT_NAME` defaults to `TronMac` for both configs), but `Configuration/Release.xcconfig` overrides it with `PRODUCT_NAME = Tron`. This produces the `Tron.app` bundle the DMG pipeline (`.github/workflows/release-mac.yml:98 → APP_BUNDLE: Tron.app`) and the `/Applications/Tron.app` end-user surface both expect. Debug intentionally keeps the default so the `TronMacTests` target's `BUNDLE_LOADER` / `TEST_HOST` (which reference `TronMac.app/Contents/MacOS/TronMac`) keep resolving without configuration drift.

### What every workflow shares

- **Port `9847`** — the WS bind. Always exclusive — see "Mutual exclusion" below.
- **LaunchAgent label `com.tron.server`** — the launchd job that owns the production server. Workflows 1 and 2 both load it (production install path is identical). Workflow 3 stops it before binding the port itself.
- **`~/.tron/system/`** data tree — settings, auth, bearer token, sentinel, sessions, log database. Wrappers in workflows 1 and 2 mutate the wrapper-side files (`.onboarded`, `.mac-wrapper.lock`); the agent (any workflow) owns the rest.
- **`auth-token.json`** — bearer issued by the agent on first start. Same token regardless of which workflow started the agent.
- **`~/.tron/skills/`** — managed skills synced from `packages/agent/skills/` by `tron install` / `tron dev` (NOT by the wrapper).

### Mutual exclusion (how they coexist without conflict)

| Layer | Guard | What it prevents |
|---|---|---|
| Wrapper instance | `~/.tron/system/.mac-wrapper.lock` (`fcntl(F_SETLK, F_WRLCK)`) | Two SwiftUI wrappers running at once (workflow 1 + 2 simultaneously). Second instance logs + terminates. |
| Agent instance | `~/.tron/system/database/log.db.lock` (cross-process exclusive `flock`) | Two Rust agents running at once. Server refuses to start if held. |
| Port `9847` | OS-level bind | Workflow 3 starting `tron dev` on top of workflow 1/2's running agent — `tron dev` first calls `launchctl bootout` on `com.tron.server`, then binds. |
| LaunchAgent | `launchctl bootout` / `bootstrap` | One job per session is enforced by launchd; double-load returns 119 (handled by `LaunchAgentManaging`). |

**Result**: a contributor can have the production DMG installed AND switch to `tron dev` to iterate on the agent without uninstalling anything. The DMG wrapper's menu bar shows "Server stopped" while `tron dev` runs; quitting `tron dev` and `launchctl bootstrap`-ing `com.tron.server` restores production behavior.

### Switching between workflows

```bash
# Start production (after DMG install or workflow 2's wizard completion):
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tron.server.plist

# Switch to agent dev (kills production agent, takes over port):
tron dev          # builds Tron-Dev.app, stops com.tron.server, binds 9847

# Stop agent dev and resume production:
# (Ctrl-C the tron dev process)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tron.server.plist
```

The wrapper (workflow 1 or 2) does not need to be relaunched — its `ServerStatusPoller` picks up the running agent on the next 30s tick.

### Two paths to the same install

Both wizard and CLI produce the same on-disk artifacts (`~/.tron/system/Tron.app/Contents/MacOS/tron`, `~/Library/LaunchAgents/com.tron.server.plist`, `~/.tron/system/auth-token.json` generated by the agent on first start, `~/.tron/system/.onboarded` sentinel):

| Path | Used by | Starts via | Notes |
|---|---|---|---|
| Wizard (`Sources/Wizard/Steps/InstallStep.swift`) | DMG users (workflow 1), wizard dogfood (workflow 2) | `LaunchAgentManaging.load` in-process | Self-sufficient; does not shell out to `scripts/tron` |
| CLI (`scripts/tron install`) | Contributors who don't want the wrapper UI | `launchd_start` at end of script | Supports `--gui-helper` (machine-readable JSON events) for headless contexts |

See [development.md](./development.md) for local dev + CI commands and the [README "Mac App" section](../../../README.md#mac-app-tronapp) for end-user-facing documentation.
