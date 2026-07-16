# Mac App Development

## Setup

### Prerequisites

- Xcode 16+ (macOS 15 Sequoia deployment target)
- XcodeGen (`brew install xcodegen`)
- Rust toolchain (`rustup`) — for the bundled agent binary
- Signing: `Apple Development` for isolated Debug install testing;
  `Developer ID Application` is supplied by the Release/DMG workflow

### One-time setup

```bash
cd packages/mac-app
xcodegen generate
open TronMac.xcodeproj
```

Build products differ between configurations:

- **Debug** → `TronMac.app` (bundle ID `com.tron.mac.dev`, executable `TronMac`). Lives in `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/TronMac.app`. The default `PRODUCT_NAME = $(TARGET_NAME)` is intentionally left untouched here so the `TronMacTests` target's `BUNDLE_LOADER` / `TEST_HOST` (which reference `TronMac.app/Contents/MacOS/TronMac`) keep resolving without configuration drift.
- **Release** → `Tron.app` (bundle ID `com.tron.mac`, executable `Tron`). `Configuration/Release.xcconfig` sets `PRODUCT_NAME = Tron` so the archived bundle matches both the `.github/workflows/release-mac.yml` `APP_BUNDLE: Tron.app` expectation and the `/Applications/Tron.app` end-user surface. Built by the DMG pipeline and shipped notarized.

Release builds manage the production LaunchAgent (`com.tron.server`) and port (`9847`). `/Applications/Tron.app` is authoritative for that production label: if an older Debug/DerivedData build still owns `com.tron.server`, or launchd still reports an older parent bundle build for the installed app, the installed Release boots it out and re-registers the bundled helper before restart. The default Debug scheme is companion-only: it can run side by side with `/Applications/Tron.app`, show a second menu icon, and observe the same production server without registering, pausing, restarting, or uninstalling it. The wrapper lock is per bundle id (`~/.tron/internal/run/.mac-wrapper.<bundle-id>.lock`) so one release wrapper and one Debug companion can coexist, while duplicate launches of the same wrapper still exit cleanly.

Use the `TronMac Isolated Install` scheme only when testing first-run or reinstall flows from Xcode. That scheme sets `TRON_MAC_INSTALL_MODE=isolated` and `TRON_HOME_NAME=.tron-dev`, registers `com.tron.server.dev`, and runs the bundled `Tron Server Dev.app` helper on port `9848` against `~/.tron-dev` so it never clashes with the installed production server.

> **Disambiguation**: the Debug-config `TronMac.app` (wrapper UI dogfood or isolated install testing) is unrelated to `Tron-Dev.app` at `~/.tron/internal/run/Tron-Dev.app`, which is the headless agent built by `tron dev` (bundle ID `com.tron.agent`, no SwiftUI). See [architecture.md → Workflows & Variants](./architecture.md#workflows--variants) for the canonical workflow breakdown.

The wizard install path validates the bundled helper app + LaunchAgent plist, registers or refreshes the active scheme's LaunchAgent through `SMAppService`, and waits for the server heartbeat. A previously enabled Login Item registration is shown as registered, not ready; the user still has to press Start server and the wizard still waits for `system::ping` before continuing. Release builds must run from `/Applications/Tron.app`; default Debug builds may run from DerivedData for wrapper dogfood but cannot mutate the production Login Item; isolated Debug is the explicit install-test path. The wizard does not copy a server bundle into `~/.tron/internal/`, write `~/Library/LaunchAgents`, stage contributor CLI artifacts under `~/.tron/internal/run/`, or sync managed product assets. Menu-bar startup writes `~/.tron/internal/run/mac-app-version.json` after a successful first-run or update finalization; when that marker does not match the current app build, startup restarts the production helper once and records the marker only after `/health` is reachable.

## Workflow quick reference

Run these commands from the repo root unless a step says otherwise. The wrapper never builds the Rust agent at install time; every wrapper path below uses whichever `tron` binary was last staged into `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` and `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron`.

| Goal | Commands | Result |
|---|---|---|
| Xcode Debug menu/wizard UI dogfood | `bash packages/mac-app/scripts/bundle-agent.sh --profile debug`<br>`cd packages/mac-app && xcodegen generate`<br>Open `TronMac.xcodeproj`, select `TronMac`, Run | Builds `TronMac.app` in DerivedData with bundle id `com.tron.mac.dev`; coexists with `/Applications/Tron.app` and observes the production server without taking over its Login Item |
| Xcode isolated install/reinstall test | `bash packages/mac-app/scripts/bundle-agent.sh --profile debug`<br>`cd packages/mac-app && xcodegen generate`<br>Open `TronMac.xcodeproj`, select `TronMac Isolated Install`, Run | Runs the first-run wizard against `com.tron.server.dev`, port `9848`, and `~/.tron-dev`; safe while the production DMG app/server remain installed |
| Local Release install test | Follow [Local Release install testing](#local-release-install-testing) | Replaces the single installed-release slot with a local `com.tron.mac` build; exercises the same path and SMAppService registration as the DMG, without notarization/Gatekeeper |
| Rust server iteration only | `./scripts/tron dev` | Stops `com.tron.server`, runs `~/.tron/internal/run/Tron-Dev.app` on port `9847`, waits for `/health` in background mode, writes startup and exit output to `~/.tron/internal/run/tron-dev-background.log`, then restores `/Applications/Tron.app` through `--tron-start-server-and-quit` on exit. The internal wrapper command exits nonzero if ServiceManagement loads the helper but `/health` never becomes reachable. Background mode is LaunchAgent-backed so non-interactive agents do not own the server process group. Agent automation should prefer `./scripts/tron dev -bd --json --wait <seconds>` and verify with `./scripts/tron status --json`. |
| Production DMG release | Push a matching `server-v*` tag and let `.github/workflows/release-mac.yml` run with signing credentials | Builds and verifies `Tron.app`, signs and notarizes the app and DMG, then creates a draft or updates an existing release without changing its publish state; manual dispatch never publishes |

The workspace CLI dispatcher is intentionally small. Command families and
contributor bundle/signing live in `scripts/tron.d/`; runtime service/log/auth
helpers shared by the installed `tron-cli` live in `scripts/tron-lib.d/` and
are copied beside `tron-lib.sh` during `tron install` and contributor deploy
refreshes. `tron setup` instead links the workspace entrypoint only when no
installed pair owns it, so rerunning development setup cannot replace an
installed helper/CLI pair. Contributor `tron install` and `tron manual-deploy`
locally sign and validate their helper
bundles but never notarize them; `.github/workflows/release-mac.yml` is the sole
owner of distribution signing and notarization.

## Local dev loop

### Staging the bundled helper binaries

`Tron.app` embeds the Rust agent inside signed helper apps at `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/` and `Contents/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/`. `Tron Server.app` has bundle id `com.tron.server` for production/local Release; `Tron Server Dev.app` has bundle id `com.tron.server.dev` for isolated Debug install testing. The tracked helper `Info.plist` files own those identifiers and display names, the tracked LaunchAgent plists own registration metadata, and `TronPaths` selects the active release or isolated runtime variant. Each helper bundle identifier must equal its LaunchAgent label so signing and launchd agree, while its `Tron Server` display name stays distinct from the `Tron` wrapper shown for System Settings permissions. `tron` is the sole Cargo helper executable and LaunchAgent entrypoint. Bundled helpers run with `--quiet` and do not inject a logging environment override; database diagnostics remain fixed engine policy. The helper binary is gitignored under each helper's `Contents/MacOS/` and produced by:

```bash
# Build + stage the release agent (default)
packages/mac-app/scripts/bundle-agent.sh

# Or, for a faster debug-profile agent during wrapper dogfood:
packages/mac-app/scripts/bundle-agent.sh --profile debug

# Or, to use packages/agent/target/release/tron that was already built:
packages/mac-app/scripts/bundle-agent.sh --skip-build

# Or, to use a binary built elsewhere:
packages/mac-app/scripts/bundle-agent.sh --source /absolute/path/to/tron

# Or, to wipe the ignored generated helper payloads:
packages/mac-app/scripts/bundle-agent.sh --clean
```

`--clean` removes the ignored helper binaries and per-helper icon copies. It
preserves the single tracked icon source, both LaunchAgent plists, and both
helper `Info.plist` files. The next staging run recreates both icon copies from
`Sources/Resources/AppIcon.icns` before Xcode copies and signs the helper apps.

The two helper `Info.plist` files and two LaunchAgent plists under
`Sources/Resources/Library` are the authoritative packaged metadata.
`bundle-agent.sh` verifies that those tracked files exist; it does not generate
or repair them while staging a binary. Edit and review the tracked plist owner
directly when bundle identity, arguments, ports, or associations change.

The Xcode target also copies `packages/agent/defaults/` into `Contents/Resources/Constitution/` on every build. Constitution defaults seed `~/.tron/profiles/` on first Constitution initialization. Managed skills, transcription sidecars, and product capability assets are not bundled.

Generate the Xcode project after clone and after any change to `project.yml`
(the wrapper/test bundle-identity and shared deployment/Swift/project-shape
owner), configuration-specific compiler settings under `Configuration/`, or
the source/resource layout:

```bash
cd packages/mac-app
xcodegen generate
```

Restaging the ignored helper executable alone does not require regeneration;
the post-build script reads the tracked `Sources/Resources/Library` tree
directly.

If you ship the wrapper without the active staged helper executable or its bundled LaunchAgent plist, `InstallStep` surfaces a helper validation failure. The wizard refuses to advance past the Install step.

Xcode's `Copy Bundled Login Item` script copies the whole `Sources/Resources/Library` tree after compile, signs every nested helper app, then re-signs the outer wrapper so ServiceManagement sees the copied LaunchAgent plists as sealed resources. If that final outer-app re-sign is skipped, `SMAppService.register()` fails with code `-67054` (`a sealed resource is missing or invalid`).

If you change Rust agent code that the Mac wrapper depends on — engine capabilities, onboarding/install behavior, settings defaults, or anything used before pairing — rerun `packages/mac-app/scripts/bundle-agent.sh` before launching the Mac app from Xcode. Xcode copies the already-staged `Sources/Resources/Library` tree; it does not rebuild that binary for you. Forgetting this step makes the Swift UI talk to an older embedded server, which is especially confusing when testing new engine invocations such as `logs::recent`.

There is no installer cleanup path that edits production artifacts in place: the app bundle is immutable, launch registration is owned by `SMAppService`, and user data is preserved under `~/.tron`. Menu-bar uninstall unregisters `com.tron.server`, removes runtime state in `internal/run/`, and can optionally clear `[settings]` overrides from `profiles/user/profile.toml` and/or remove `profiles/auth.json`; database and workspace data stay intact. For pre-onboarding production cleanup where no menu bar exists, run `/Applications/Tron.app/Contents/MacOS/Tron --tron-uninstall-and-quit` so the same SMAppService unregister path executes without opening the wizard. The default Debug companion refuses that operation for production.

### Building

```bash
cd packages/mac-app

# Build only (no test run):
xcodebuild -project TronMac.xcodeproj -scheme TronMac -destination 'platform=macOS' -configuration Debug build

# Full test suite:
xcodebuild test -project TronMac.xcodeproj -scheme TronMac -destination 'platform=macOS'

# Local Release build (the release workflow supplies distribution signing/notarization):
xcodebuild -project TronMac.xcodeproj -scheme TronMac -destination 'platform=macOS' -configuration Release build
```

### Local Release install testing

To test the same filesystem and ServiceManagement path as the DMG without
packaging a DMG, first quit the installed Tron wrapper from its menu. The
LaunchAgent-owned server keeps running. Then build Release and replace the app
bundle before reopening it:

```bash
bash packages/mac-app/scripts/bundle-agent.sh
cd packages/mac-app
xcodegen generate
xcodebuild -project TronMac.xcodeproj -scheme TronMac -destination 'platform=macOS' -configuration Release -derivedDataPath build/dd build
test -d build/dd/Build/Products/Release/Tron.app
rm -rf /Applications/Tron.app
ditto build/dd/Build/Products/Release/Tron.app /Applications/Tron.app
open /Applications/Tron.app
```

This is intentionally the same runtime mode as a real DMG install: bundle ID `com.tron.mac`, helper at `Contents/Library/LoginItems/Tron Server.app`, LaunchAgent plist at `Contents/Library/LaunchAgents/com.tron.server.plist`, and data under `~/.tron`. A Release app launched from Downloads, the DMG mount, or DerivedData is blocked before registration.

If a real DMG build is already installed, local Release testing replaces that same `/Applications/Tron.app` slot; there is no second side-by-side Release identity. For an update-style test, copy the local Release over `/Applications/Tron.app`, then launch it or run `tron start`/`tron restart`; the wrapper should re-register/repair SMAppService, refresh stale launch constraints such as `needs LWCR update`, and restart the helper once for the new build before reporting success. For a first-run wizard test, choose **Uninstall Tron** from the existing menu bar app first (preserving database/workspace), copy the local Release into `/Applications/Tron.app`, then open it and run the wizard install.

For Rust-agent iteration without rebuilding the wrapper, use `tron dev`. It stops `com.tron.server`, runs `~/.tron/internal/run/Tron-Dev.app` on port `9847`, waits for `/health` before declaring a background takeover successful, writes startup and exit output to `~/.tron/internal/run/tron-dev-background.log`, then restores the installed `/Applications/Tron.app` helper through the wrapper's internal `--tron-start-server-and-quit` command when the dev process exits or candidate preparation/launch fails. That internal command reuses the wrapper's SMAppService path and exits nonzero if the helper loads but never reaches `/health`; stale installed helpers must be updated or reinstalled instead of masked by a successful launchd load. Background mode uses the transient `com.tron.server.dev-takeover` LaunchAgent so non-interactive agents do not own or accidentally reap the server process group. Machine-driven test loops should use `tron dev -bd --json --wait <seconds>` and treat `tron status --json` as the authoritative post-restart state instead of reading a transient launched child PID from human logs; the JSON status includes stale pid-file fields when a background process has exited.

### Xcode isolated install testing

Select the `TronMac Isolated Install` scheme when you need to test the Mac installer or reinstall flow from Xcode while keeping the installed DMG app/server intact. The scheme uses the Debug wrapper bundle id but changes only the install target:

- data root: `~/.tron-dev`
- LaunchAgent label: `com.tron.server.dev`
- bundled plist: `Contents/Library/LaunchAgents/com.tron.server.dev.plist`
- helper app: `Contents/Library/LoginItems/Tron Server Dev.app` with bundle id `com.tron.server.dev`
- `AssociatedBundleIdentifiers`: `com.tron.mac.dev`, then `com.tron.mac`
- server port: `9848`

Do not use this scheme for normal menu-bar UI iteration. The default `TronMac` Debug scheme is the companion mode for that.

### Test organization

```
Tests/
├── App/                  # Lifecycle and command-mode tests
├── Infrastructure/       # Test fakes such as MockLaunchAgentManager and TestTempDir
├── MenuBar/              # Controller and presentation tests
├── Server/               # Health, paths, pairing token, and process-control tests
├── Support/              # Diagnostics, feedback, foundation, onboarding, pairing tests
└── Wizard/               # Flow, step ordering, install-stage, and visual layout tests
```

All tests use **Swift Testing** (`@Test`, `@Suite`, `#expect`) rather than XCTest. `TestTempDir` creates throwaway directories under `NSTemporaryDirectory()` for any test that touches the filesystem.

Mac wrapper tests run through the `TronMac` scheme so `@testable import TronMac` exercises the real app target. The generated scheme and CI both set `TRON_MAC_TEST_HOST=1`, and the app also recognizes Xcode's test-host environment markers, then renders an inert 1x1 host instead of the onboarding wizard or menu bar. Keep that path side-effect free: CI must never register Login Items, acquire production wrapper locks, or manage a real server just to run unit tests; window configuration must also exit before applying production styling. If Xcode changes its test-host markers, update `TronMacRuntime.isRunningUnderTests` and its test in `MacRuntimeVariantTests.swift` together.

GitHub's Mac CI pins the destination to the runner architecture, uses
`xcodebuild build-for-testing` to compile the app plus the full Mac test
bundle, then limits hosted execution to the known-stable `TronPathsTests`,
`ServerStatusPollerTests`, and `TailscaleProbeTests` suites. Run the broader
app-hosted tests locally when changing wrapper logic, menu behavior, install
planning, or wizard flows.

## Running the wizard during dev

1. Stage a debug-profile agent: `bash packages/mac-app/scripts/bundle-agent.sh --profile debug`.
2. Generate the project: `cd packages/mac-app && xcodegen generate`.
3. Open `TronMac.xcodeproj`.
4. Select `TronMac` for companion UI dogfood; it can display the wizard but
   cannot complete production installation. Select `TronMac Isolated Install`
   for the complete wizard flow against `~/.tron-dev` and port `9848`.
5. To reset companion wizard state, remove
   `~/.tron/internal/run/.onboarded`; to reset isolated state, remove
   `~/.tron-dev/internal/run/.onboarded`. Clear the shared Debug progress suite
   with `defaults delete com.tron.mac.dev` when needed.

To simulate menu-bar-only mode, create the corresponding `.onboarded` sentinel
before launching. Release uses `~/.tron`; isolated Debug uses `~/.tron-dev`.

## CI pipeline

The exact release pipeline is owned by
[`.github/workflows/release-mac.yml`](../../../.github/workflows/release-mac.yml).
It verifies the `VERSION.env` mirrors, builds and stages the locked Rust agent,
generates the Xcode project, archives the wrapper, signs inside-out, notarizes
the app, and then builds a fail-closed DMG from a dedicated source directory.
The mounted DMG must contain the wrapper, production helper, and
`Applications -> /Applications` link before the separately signed/notarized
image can reach a draft release. `scripts/tron-release-notes` owns the dynamic
tag, changelog, and asset names; the workflow applies the release title exported
by `scripts/tron-version`.

Manual workflow dispatch defaults to structural dry-run and never publishes a
GitHub release; with `dry_run=false` and signing credentials, it can exercise
signed and notarized packaging. Only the explicit manual dry-run may omit the
five signing/notarization secrets; tag runs and manual `dry_run=false` runs
reject any missing secret before the build. PR CI compiles the full Mac test
bundle, runs focused stable suites, and remounts a headless unsigned DMG.
Missing build products, helpers, links, or failed packaging are hard failures.

## Common tasks

### Add a new wizard step

1. Add a case to `WizardStep` enum in `Sources/Support/Onboarding/OnboardingModels.swift`.
2. Create a new view file under `Sources/Wizard/Steps/`.
3. Add a case to the `switch state.step` dispatcher in `WizardView.swift`.
4. Add tests to `Tests/Wizard/Flow/`, `Tests/Wizard/Steps/`, or `Tests/Wizard/Components/` based on the behavior being pinned; at minimum, verify the step ordering, rendering, and back/next behavior.
5. Update `packages/mac-app/docs/architecture.md` with the step's role.

### Add a new menu-bar item

1. Add a `MenuBarAction` case and route it in `MenuBarActionHandler.perform(_:)` when the item has side effects; pairing/log detail belongs in dedicated windows.
2. Add the typed `.action` (or passive `.openLink`) descriptor in `MenuBarItemBuilder.build(snapshot:tronHome:defaultServerPort:canManageLaunchAgent:)`.
3. Pin the action mapping and ordering in `Tests/MenuBar/Presentation/MenuBarItemBuilderTests.swift`.

### Debug the `.onboarded` sentinel logic

`setup.onboardedSentinelExists()` is a single `FileManager.default.fileExists(atPath:)` call. If the wizard keeps re-showing, check:

The terminal **Open menu bar** action writes this sentinel before switching
modes. If that write fails, the current Done screen remains visible so the
action can be retried after fixing the filesystem problem.

```bash
ls -la ~/.tron/internal/run/.onboarded
# The current writer creates a nonempty ISO8601 timestamp line with fractional seconds.
```

If it's missing, the wizard will re-run. If it's a directory, something is very wrong — remove it.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Install reports missing helper executable | The active helper binary (`Tron Server.app` for production/Release or `Tron Server Dev.app` for isolated Debug) was not staged before archive/build. Run `bash packages/mac-app/scripts/bundle-agent.sh`, then rebuild; restaging alone does not require XcodeGen. |
| Install reports invalid LaunchAgent plist | The tracked `Sources/Resources/Library/LaunchAgents/<active-label>.plist` is missing `BundleProgram`, the exact active `tron --port <port> --quiet` argv, or the wrapper `AssociatedBundleIdentifiers`. Fix that authoritative plist, validate it with `plutil -lint`, then regenerate the project. |
| Install fails with `Codesigning failure loading plist ... code: -67054` | The copied `Contents/Library/LaunchAgents/*.plist` resources are not sealed by the outer app signature. Rebuild with the current XcodeGen project so the post-build script re-signs the helper apps and then the outer wrapper. |
| `SingleInstanceLock.acquire()` returns false on first launch | Another instance of the same wrapper bundle id is already running, or that specific lock file has broken permissions. Release uses `.mac-wrapper.com.tron.mac.lock`; Debug uses `.mac-wrapper.com.tron.mac.dev.lock`. |
| Tailscale step says not signed in even though `tailscale status` is healthy | Rebuild the wrapper with the latest `TailscaleProbe`; it tries every executable candidate and the "I have Tailscale" button re-probes instead of skipping the gate. |
| Wizard restarts every launch | `touchOnboardedSentinel` is not being called OR `~/.tron/internal/` is not writable. Check permissions. |
| Install shows Login Items approval required | macOS returned `SMAppService.Status.requiresApproval`. Open Login Items settings and enable Tron Server; the app does not write launchd plists manually. |
| Release install is blocked from Downloads or the DMG | Move the app to `/Applications/Tron.app` and relaunch. Release registration from any other path is intentionally unsupported. |
| Debug wrapper cannot pause/restart/uninstall the server | This is expected in companion mode. Use `/Applications/Tron.app` for production server controls, `tron dev` for server takeover, or `TronMac Isolated Install` for installer testing. If a stale Debug/DerivedData build owns the production label, launching the installed app repairs that registration during update finalization or the next Restart server action. |
| Need to run a dev server takeover | Start it from the checkout with `scripts/tron dev` or the installed `tron dev` CLI. The menu bar observes active `Tron-Dev.app` takeovers and keeps only the `Stop dev server` recovery action in the server-control section. |
| Stop dev server reports `Resume failed` after ServiceManagement loads the helper | The installed `/Applications/Tron.app` helper loaded but never passed `/health`, usually because the installed app is older than the current profile/defaults. Update or reinstall `/Applications/Tron.app`, then restart the server. |
| `internal/run/mac-app-version.json` stays on an older build after `tron start`/`restart` | Rebuild/copy the current Release app into `/Applications/Tron.app` and run `scripts/tron start` or `scripts/tron restart`. Command-mode startup records the marker only after the installed helper passes `/health`; stale markers with healthy current helpers indicate the wrapper start path needs investigation. |
| Release install repairs a stale DerivedData helper registration or `needs LWCR update` state | Expected. The installer reads `launchctl print`; if the loaded label points at a missing/mismatched helper executable, a stale parent bundle build, or stale launch constraints, the installed app replaces that stale SMAppService registration before waiting for heartbeat. |
| Debug install registers, then heartbeat times out with `launchctl` exit `78` | The isolated helper cannot spawn. Verify the active plist points at `Tron Server Dev.app`, that the helper bundle id is `com.tron.server.dev`, that the Debug wrapper is Apple Development signed, and that the outer wrapper signature verifies after the Library copy. |
| Full Disk Access row stays red even though System Settings shows a Tron app enabled | Enable the wrapper (`Tron.app` for Release, `TronMac.app` for Debug). Remove stale `Tron Server.app` rows if macOS shows them, then enable the wrapper row and press Re-check. |
| Install registers, then waits on heartbeat | Check `launchctl print gui/$(id -u)/com.tron.server`, `lsof -i :9847`, and `~/.tron/internal/database/tron.sqlite.lock`. A bound port or held DB lock means another Tron server is already running; the app will not choose a different port. |
