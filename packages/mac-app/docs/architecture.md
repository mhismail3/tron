# Mac App Architecture

> Last verified: 2026-04-23 (Phase 5)

## Overview

`Tron.app` is the macOS SwiftUI wrapper around the headless Rust agent. It has two runtime modes:

- **Wizard mode** — shown on first launch, before `~/.tron/system/.onboarded` exists. Walks the user through Tailscale, permissions, binary install, and pairing-info display.
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
│   ├── Info.plist                  # Bundle metadata (LSUIElement = YES)
│   ├── MenuBar/
│   │   ├── MenuBarController.swift # NSStatusItem lifecycle + timer
│   │   └── MenuBarItemBuilder.swift # Pure builder: snapshot → [MenuItemDescriptor]
│   ├── Resources/                  # tron-agent is staged here by CI
│   ├── Services/
│   │   ├── LaunchAgentManaging.swift # protocol + LiveLaunchAgentManager (shells launchctl)
│   │   ├── Models.swift            # TailscaleStatus, PermissionStatus, ExistingInstallStatus…
│   │   ├── TronPaths.swift         # Single source of truth for all on-disk paths
│   │   ├── Onboarding/
│   │   │   ├── ExistingInstallDetector.swift
│   │   │   ├── InstallPlanner.swift    # pure-value plan + plist renderer
│   │   │   ├── PermissionProbe.swift
│   │   │   └── TailscaleProbe.swift
│   │   ├── Pairing/
│   │   │   ├── PairingURLBuilder.swift # builds `tron://pair?…` URL
│   │   │   └── QRCodeGenerator.swift   # CoreImage CIQRCodeGenerator wrapper
│   │   └── Server/
│   │       ├── BearerTokenReader.swift     # reads auth-token.json (+ legacy fallback)
│   │       ├── ServerPing.swift            # one-shot system.ping over WS
│   │       ├── ServerStatusPoller.swift    # 30s periodic poll for menu bar
│   │       └── SingleInstanceLock.swift    # fcntl(F_SETLK) advisory lock
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

### Single-instance lock via POSIX `fcntl`

`SingleInstanceLock.acquire()` opens `~/.tron/system/Tron.app.lock` and tries `fcntl(F_SETLK, F_WRLCK)`. Second instance's call fails, `AppDelegate` logs + `NSApp.terminate(nil)`. Lock is automatically released on process exit (kernel drops fd locks with the process).

### Sendable concurrency hygiene

`SingleInstanceLock` is `@unchecked Sendable` because all mutable `fileDescriptor` access is funneled through a private serial `DispatchQueue.sync`. `MockLaunchAgentManager` uses `OSAllocatedUnfairLock<State>` (NSLock is unavailable in async contexts on Swift 6). `AppDelegate` is `@MainActor` — the `NotificationCenter` observer hops via `Task { @MainActor [weak self] in … }`.

## Data Flow

### First launch (wizard path)

```
TronMacApp.main()
  └─ AppDelegate.applicationDidFinishLaunching
       ├─ SingleInstanceLock.acquire()      ← refuses second instance
       └─ setup.onboardedSentinelExists() → false
           └─ RootView → WizardView
                └─ WizardState.step = .welcome
                    → .tailscale → .existingInstall → .permissions
                    → .install → .pairingInfo → .done
                └─ DoneStep taps "Finish"
                    ├─ setup.touchOnboardedSentinel()  ← atomic tempfile+rename
                    └─ post .tronWizardDidComplete
                         └─ AppDelegate observer
                             ├─ installMenuBar(setup:)
                             ├─ NSApp.setActivationPolicy(.accessory)
                             └─ orderOut all windows
```

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
                         ├─ setup.pingServer(token)
                         ├─ setup.readBearerToken()
                         └─ setup.readTailscaleIPFromSettings()
```

### Install pipeline (wizard's `InstallStep`)

```
1. Locate source:  Bundle.main.url(forResource: "tron-agent")
2. Plan:           InstallPlanner.plan(…) → Result<InstallPlan, Failure>
3. Copy binary:    BinaryInstaller.install(plan:)   [tempfile + rename, chmod 755]
4. Write plist:    BinaryInstaller.writePlist(plan:) [atomic write]
5. Load agent:     setup.launchAgentManager.load(plistPath:label:)
6. Await ping:     poll setup.pingServer(token) for 30s on 1s cadence
→ state.installOutcome set; Pairing step unblocks when .success | .alreadyInstalled
```

## Key Invariants

- **`Tron.app` never builds the Rust agent.** The binary is staged at release time by `scripts/bundle-agent.sh` and committed-to-gitignore. Missing → wizard surfaces `sourceBinaryMissing` with a "reinstall the DMG" message.
- **All atomic writes use tempfile + `replaceItemAt` (matching the Rust agent's `tempfile::Builder → sync_all → rename`).** See `OnboardedSentinelWriter.touch` and `BinaryInstaller.install`.
- **Wrapper and server share no in-memory state.** Every interaction is either a filesystem read (`auth-token.json`, `settings.json`, `.onboarded`) or a WS RPC call. Crashing the wrapper does not kill the server (LaunchAgent keeps it alive).
- **Single port (`9847`) for all variants.** `Tron.app` (prod) and `Tron-Dev.app` (debug, at `~/.tron/system/deployment/`) manage the same LaunchAgent label and port. Dev and release builds of the wrapper are mutually-exclusive instances (single-instance lock).
- **TronPaths is the single source of truth.** If any path is referenced elsewhere, that's a bug. See `packages/agent/src/core/foundation/paths.rs` for the Rust-side mirror.

## Relationship with `scripts/tron`

Two install paths co-exist:

| Path | Used by | Starts via | Notes |
|---|---|---|---|
| Wizard (`Sources/Wizard/Steps/InstallStep.swift`) | DMG users | `LaunchAgentManaging.load` in-process | Self-sufficient; does not shell out to `scripts/tron` |
| CLI (`scripts/tron install`) | Contributors | `launchd_start` at end of script | Supports `--gui-helper` (machine-readable JSON events) for headless contexts |

Both paths produce the same on-disk artifacts (`~/.tron/system/Tron.app/Contents/MacOS/tron`, `~/Library/LaunchAgents/com.tron.server.plist`, `~/.tron/system/auth-token.json` generated by the agent on first start, `~/.tron/system/.onboarded` sentinel).

See [development.md](./development.md) for local dev + CI commands.
