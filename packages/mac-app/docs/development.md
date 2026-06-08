# Mac App Development

> Last verified: 2026-06-08 (HRA-14 wrapper hierarchy audit, primitive helper bundle, health-gated recovery, isolated helper registration, and two-helper signing)

## Setup

### Prerequisites

- Xcode 16+ (macOS 15 Sequoia deployment target)
- XcodeGen (`brew install xcodegen`)
- Rust toolchain (`rustup`) — for the bundled agent binary
- Signing: `Apple Development` for Debug so `SMAppService` can spawn the bundled Login Item; `Developer ID Application` for Release/DMG distribution

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
| Local Release install test | `bash packages/mac-app/scripts/bundle-agent.sh`<br>`cd packages/mac-app && xcodegen generate`<br>`xcodebuild -scheme TronMac -destination 'platform=macOS' -configuration Release build`<br>`ditto "$HOME/Library/Developer/Xcode/DerivedData/TronMac-"*/Build/Products/Release/Tron.app /Applications/Tron.app`<br>`open /Applications/Tron.app` | Replaces the single installed-release slot with a local `com.tron.mac` build; exercises the same path and SMAppService registration as the DMG, without notarization/Gatekeeper |
| Rust server iteration only | `./scripts/tron dev` | Stops `com.tron.server`, runs `~/.tron/internal/run/Tron-Dev.app` on port `9847`, waits for `/health` in background mode, writes startup and exit output to `~/.tron/internal/run/tron-dev-background.log`, then restores `/Applications/Tron.app` through `--tron-start-server-and-quit` on exit. The internal wrapper command exits nonzero if ServiceManagement loads the helper but `/health` never becomes reachable. Background mode is LaunchAgent-backed so non-interactive agents do not own the server process group. Agent automation should prefer `./scripts/tron dev -bd --json --wait <seconds>` and verify with `./scripts/tron status --json`. |

The workspace CLI dispatcher is intentionally small. Command families live in
`scripts/tron.d/`; runtime helpers shared by the installed `tron-cli` live in
`scripts/tron-lib.d/` and are copied beside `tron-lib.sh` during
`tron install`, `tron setup`, and contributor deploy refreshes.
| Production DMG release | Push/run the `server-v*` release workflow in `.github/workflows/release-mac.yml` | Builds `tron`, stages it into `Tron.app`, verifies the bundled helper and LaunchAgent, signs helper then wrapper, notarizes/staples, creates the DMG, and publishes it |

## Local dev loop

### Staging the bundled helper binaries

`Tron.app` embeds the Rust agent inside signed helper apps at `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/` and `Contents/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/`. `Tron Server.app` has bundle id `com.tron.server` for production/local Release; `Tron Server Dev.app` has bundle id `com.tron.server.dev` for isolated Debug install testing. `tron` is the LaunchAgent entrypoint. The helper binary is gitignored under each helper's `Contents/MacOS/` and produced by:

```bash
# Build + stage the release agent (default)
packages/mac-app/scripts/bundle-agent.sh

# Or, for a faster debug-profile agent during wrapper dogfood:
packages/mac-app/scripts/bundle-agent.sh --profile debug

# Or, to use packages/agent/target/release/tron that was already built:
packages/mac-app/scripts/bundle-agent.sh --skip-build

# Or, to use a binary built elsewhere:
packages/mac-app/scripts/bundle-agent.sh --source /absolute/path/to/tron

# Or, to wipe only the ignored helper executables (for a clean `xcodebuild`):
packages/mac-app/scripts/bundle-agent.sh --clean
```

`--clean` preserves the tracked helper-resource layout: both LaunchAgent plists,
both helper `Info.plist` files, and helper icons stay in the repository. It only
removes ignored payload binaries under each helper's `Contents/MacOS/`.

The Xcode target also copies `packages/agent/defaults/` into `Contents/Resources/Constitution/` on every build. Constitution defaults seed `~/.tron/profiles/` on first Constitution initialization. The primitive branch does not bundle managed skills, transcription sidecars, or product capability assets.

After staging, regenerate the Xcode project so it picks up the file reference:

```bash
cd packages/mac-app
xcodegen generate
```

If you ship the wrapper without either staged helper executable or the bundled LaunchAgent plist for the active workflow, `InstallStep` surfaces a helper validation failure. The wizard refuses to advance past the Install step.

Xcode's `Copy Bundled Login Item` script copies the whole `Sources/Resources/Library` tree after compile, signs every nested helper app, then re-signs the outer wrapper so ServiceManagement sees the copied LaunchAgent plists as sealed resources. If that final outer-app re-sign is skipped, `SMAppService.register()` fails with code `-67054` (`a sealed resource is missing or invalid`).

If you change Rust agent code that the Mac wrapper depends on — engine capabilities, onboarding/install behavior, settings defaults, or anything used before pairing — rerun `packages/mac-app/scripts/bundle-agent.sh` before launching the Mac app from Xcode. Xcode copies the already-staged `Sources/Resources/Library` tree; it does not rebuild that binary for you. Forgetting this step makes the Swift UI talk to an older embedded server, which is especially confusing when testing new engine invocations such as `logs::recent`.

There is no installer cleanup path that edits production artifacts in place: the app bundle is immutable, launch registration is owned by `SMAppService`, and user data is preserved under `~/.tron`. Menu-bar uninstall unregisters `com.tron.server`, removes runtime state in `internal/run/`, and can optionally clear `[settings]` overrides from `profiles/user/profile.toml` and/or remove `profiles/auth.json`; database and workspace data stay intact. For pre-onboarding production cleanup where no menu bar exists, run `/Applications/Tron.app/Contents/MacOS/Tron --tron-uninstall-and-quit` so the same SMAppService unregister path executes without opening the wizard. The default Debug companion refuses that operation for production.

### Building

```bash
cd packages/mac-app

# Build only (no test run):
xcodebuild -scheme TronMac -destination 'platform=macOS' -configuration Debug build

# Full test suite:
xcodebuild test -scheme TronMac -destination 'platform=macOS'

# Release build (signed with Developer ID; required for DMG):
xcodebuild -scheme TronMac -destination 'platform=macOS' -configuration Release build
```

### Local Release install testing

To test the same filesystem and ServiceManagement path as the DMG without packaging a DMG, build Release and copy the product into `/Applications/Tron.app`:

```bash
bash packages/mac-app/scripts/bundle-agent.sh
cd packages/mac-app
xcodegen generate
xcodebuild -scheme TronMac -destination 'platform=macOS' -configuration Release build
ditto "$HOME/Library/Developer/Xcode/DerivedData/TronMac-"*/Build/Products/Release/Tron.app /Applications/Tron.app
open /Applications/Tron.app
```

This is intentionally the same runtime mode as a real DMG install: bundle ID `com.tron.mac`, helper at `Contents/Library/LoginItems/Tron Server.app`, LaunchAgent plist at `Contents/Library/LaunchAgents/com.tron.server.plist`, and data under `~/.tron`. A Release app launched from Downloads, the DMG mount, or DerivedData is blocked before registration.

If a real DMG build is already installed, local Release testing replaces that same `/Applications/Tron.app` slot; there is no second side-by-side Release identity. For an update-style test, copy the local Release over `/Applications/Tron.app`, then launch it or run `tron start`/`tron restart`; the wrapper should re-register/repair SMAppService, refresh stale launch constraints such as `needs LWCR update`, and restart the helper once for the new build before reporting success. For a first-run wizard test, choose **Uninstall Tron** from the existing menu bar app first (preserving database/workspace), copy the local Release into `/Applications/Tron.app`, then open it and run the wizard install.

For Rust-agent iteration without rebuilding the wrapper, use `tron dev`. It stops `com.tron.server`, runs `~/.tron/internal/run/Tron-Dev.app` on port `9847`, waits for `/health` before declaring a background takeover successful, writes startup and exit output to `~/.tron/internal/run/tron-dev-background.log`, then restores the installed `/Applications/Tron.app` helper through the wrapper's internal `--tron-start-server-and-quit` command when the dev process exits. That internal command reuses the wrapper's SMAppService path and exits nonzero if the helper loads but never reaches `/health`; stale installed helpers must be updated or reinstalled instead of masked by a successful launchd load. Background mode uses the transient `com.tron.server.dev-takeover` LaunchAgent so non-interactive agents do not own or accidentally reap the server process group. Machine-driven test loops should use `tron dev -bd --json --wait <seconds>` and treat `tron status --json` as the authoritative post-restart state instead of reading a transient launched child PID from human logs; the JSON status includes stale pid-file fields when a background process has exited.

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

GitHub's Mac CI pins the destination to the runner architecture, uses `xcodebuild build-for-testing` to compile the app plus the full Mac test bundle, then runs focused non-flaky wrapper suites for `TronPathsTests`, `ServerStatusPollerTests`, and `TailscaleProbeTests`. Those suites cover path ownership, server status polling, and Tailscale probing without exercising the hosted runner paths that can wedge before Swift Testing starts. Run the broader app-hosted Mac tests locally from Xcode or with `xcodebuild test` when changing wrapper logic, menu behavior, install planning, or wizard flows.

## Running the wizard during dev

1. Stage a debug-profile agent: `bash packages/mac-app/scripts/bundle-agent.sh --profile debug`
2. `xcodegen generate`
3. Open `TronMac.xcodeproj`, select `TronMac` scheme.
4. Run (Cmd+R) — the wizard shows if `~/.tron/internal/run/.onboarded` does NOT exist.
5. To re-run the wizard: `rm ~/.tron/internal/run/.onboarded && defaults delete com.tron.mac.dev` (for dev) or `com.tron.mac` (for release).

To simulate the menu-bar-only mode without onboarding, just `touch ~/.tron/internal/run/.onboarded` before launching.

## CI pipeline (Phase 6+)

Defined in `.github/workflows/release-mac.yml`. Broadly:

1. `scripts/tron version check` validates that `VERSION.env` matches Cargo, Cargo.lock, Mac/iOS XcodeGen settings, custom bundle canonical version keys, and release docs. Tag runs must match `server-v$(TRON_VERSION)`, so manual workflow input cannot create a mismatched artifact.
2. `cargo build --release --bin tron --locked` on the same `macos-15` runner (cross-compile is avoided for code-signing reasons).
3. `bash packages/mac-app/scripts/bundle-agent.sh --skip-build` inside `packages/mac-app`, which stages `packages/agent/target/release/tron`.
4. `xcodegen generate` inside `packages/mac-app/`.
5. `xcodebuild -scheme TronMac -configuration Release archive -archivePath build/TronMac.xcarchive`; the target post-build script copies the helper Library tree and Constitution defaults.
6. Export the `.app`, verify the helper executable and LaunchAgent plist are present, then code-sign inside-out with Developer ID (no `--deep` on the re-sign — `--deep` would clobber the helper signature; it's used only for read-only `--verify`).
7. Notarize the signed app via `xcrun notarytool submit --keychain-profile tron-notarize` (credentials live ONLY in an isolated path-based keychain at `$RUNNER_TEMP/tron-build.keychain-db`, never on argv), staple the app, package it into a DMG via `create-dmg`, sign the DMG, then notarize and staple the DMG separately because notary tickets are artifact-specific.
8. Keep dSYMs in the archive/release artifacts for Apple crash diagnostics.
9. `scripts/tron-release-notes` generates a bounded draft changelog body from first-parent git history since the previous release tag, with DMG, SHA256, and full compare-link details included. The body starts below GitHub's release title so the rendered page does not repeat the release name. The beta2 release intentionally compares against the historical Mac-scoped beta1 tag so the tag-prefix rename does not turn beta2 into an all-history changelog.
10. `gh release create server-v0.1.0-beta.1 ./tron-v0.1.0-beta1.dmg` creates or updates a draft pre-release titled `Tron Server v0.1 (Beta 1)` with the generated changelog.
11. `if: always()` cleanup: remove the keychain from the search list, delete it, dd-overwrite the password file, remove `cert.p12`.

PR builds (no tag) take a dry-run path: same `xcodebuild archive` + DMG assembly but ad-hoc-signed (`-`) so fork PRs without certs still validate the pipeline.

See [`.github/workflows/release-mac.yml`](../../../.github/workflows/release-mac.yml) (added in Phase 6, hardened in Phase 8).

## Common tasks

### Add a new wizard step

1. Add a case to `WizardStep` enum in `Sources/Support/Onboarding/OnboardingModels.swift`.
2. Create a new view file under `Sources/Wizard/Steps/`.
3. Add a case to the `switch state.step` dispatcher in `WizardView.swift`.
4. Add tests to `Tests/Wizard/Flow/`, `Tests/Wizard/Steps/`, or `Tests/Wizard/Components/` based on the behavior being pinned; at minimum, verify the step ordering, rendering, and back/next behavior.
5. Update `packages/mac-app/docs/architecture.md` with the step's role.

### Add a new menu-bar item

1. Extend `MenuItemDescriptor` enum in `MenuBarItemBuilder.swift` if the row needs new semantics (most new items are `.action` or `.openLink`; pairing/log detail belongs in dedicated windows).
2. Add the item to the returned array in `MenuBarItemBuilder.build(snapshot:paths:)`.
3. Pin the ordering in `Tests/MenuBar/Presentation/MenuBarItemBuilderTests.swift`.

### Debug the `.onboarded` sentinel logic

`setup.onboardedSentinelExists()` is a single `FileManager.default.fileExists(atPath:)` call. If the wizard keeps re-showing, check:

```bash
ls -la ~/.tron/internal/run/.onboarded
# Should be a 0-or-more-byte file; first line is an ISO8601 timestamp with millis.
```

If it's missing, the wizard will re-run. If it's a directory, something is very wrong — remove it.

## Linting + formatting

Run `swiftformat` if installed (same config as iOS):

```bash
swiftformat packages/mac-app/Sources packages/mac-app/Tests
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Install reports missing helper executable | The active helper binary (`Tron Server.app` for production/Release or `Tron Server Dev.app` for isolated Debug) was not staged before archive/build. Run `bash packages/mac-app/scripts/bundle-agent.sh`, then `xcodegen generate`. |
| Install reports invalid LaunchAgent plist | The bundled `Contents/Library/LaunchAgents/<active-label>.plist` is missing `BundleProgram`, the exact active `tron --port <port> --quiet` argv, or the wrapper `AssociatedBundleIdentifiers`. Re-run the bundle script and regenerate. |
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
