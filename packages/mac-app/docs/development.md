# Mac App Development

> Last verified: 2026-04-28 (transcription opt-in + relay-secret release builds)

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

Release builds manage the production LaunchAgent (`com.tron.server`) and port (`9847`). The default Debug scheme is companion-only: it can run side by side with `/Applications/Tron.app`, show a second menu icon, and observe the same production server without registering, pausing, restarting, or uninstalling it. The wrapper lock is per bundle id (`~/.tron/system/run/.mac-wrapper.<bundle-id>.lock`) so one release wrapper and one Debug companion can coexist, while duplicate launches of the same wrapper still exit cleanly.

Use the `TronMac Isolated Install` scheme only when testing first-run or reinstall flows from Xcode. That scheme sets `TRON_MAC_INSTALL_MODE=isolated` and `TRON_HOME_NAME=.tron-dev`, registers `com.tron.server.dev`, and runs the bundled helper on port `9848` against `~/.tron-dev` so it never clashes with the installed production server.

> **Disambiguation**: the Debug-config `TronMac.app` (wrapper UI dogfood or isolated install testing) is unrelated to `Tron-Dev.app` at `~/.tron/system/run/Tron-Dev.app`, which is the headless agent built by `tron dev` (bundle ID `com.tron.agent`, no SwiftUI). See [architecture.md → Workflows & Variants](./architecture.md#workflows--variants) for the canonical workflow breakdown.

The wizard install path validates the bundled helper app + LaunchAgent plist, registers or refreshes the active scheme's LaunchAgent through `SMAppService`, and waits for the server heartbeat. A previously enabled Login Item registration is shown as registered, not ready; the user still has to press Start server and the wizard still waits for `system.ping` before continuing. Release builds must run from `/Applications/Tron.app`; default Debug builds may run from DerivedData for wrapper dogfood but cannot mutate the production Login Item; isolated Debug is the explicit install-test path. The wizard does not copy a server bundle into `~/.tron/system/`, write `~/Library/LaunchAgents`, or stage contributor CLI artifacts under `~/.tron/system/run/`. The only app-bundled files copied into the active data root are the transcription sidecar source files (`worker.py`, `requirements.txt`) when the user applies the transcription step.

## Workflow quick reference

Run these commands from the repo root unless a step says otherwise. The wrapper never builds the Rust agent at install time; every wrapper path below uses whichever `tron` binary was last staged into `packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron`.

| Goal | Commands | Result |
|---|---|---|
| Xcode Debug menu/wizard UI dogfood | `bash packages/mac-app/scripts/bundle-agent.sh --profile debug`<br>`cd packages/mac-app && xcodegen generate`<br>Open `TronMac.xcodeproj`, select `TronMac`, Run | Builds `TronMac.app` in DerivedData with bundle id `com.tron.mac.dev`; coexists with `/Applications/Tron.app` and observes the production server without taking over its Login Item |
| Xcode isolated install/reinstall test | `bash packages/mac-app/scripts/bundle-agent.sh --profile debug`<br>`cd packages/mac-app && xcodegen generate`<br>Open `TronMac.xcodeproj`, select `TronMac Isolated Install`, Run | Runs the first-run wizard against `com.tron.server.dev`, port `9848`, and `~/.tron-dev`; safe while the production DMG app/server remain installed |
| Local Release install test | `bash packages/mac-app/scripts/bundle-agent.sh`<br>`cd packages/mac-app && xcodegen generate`<br>`xcodebuild -scheme TronMac -destination 'platform=macOS' -configuration Release build`<br>`ditto "$HOME/Library/Developer/Xcode/DerivedData/TronMac-"*/Build/Products/Release/Tron.app /Applications/Tron.app`<br>`open /Applications/Tron.app` | Replaces the single installed-release slot with a local `com.tron.mac` build; exercises the same path and SMAppService registration as the DMG, without notarization/Gatekeeper |
| Rust server iteration only | `./scripts/tron dev` | Stops `com.tron.server`, runs `~/.tron/system/run/Tron-Dev.app` on port `9847`, then restores `/Applications/Tron.app` through `--tron-start-server-and-quit` on exit |
| Production DMG release | Push/run the `server-v*` release workflow in `.github/workflows/release-mac.yml` | Builds the release agent with relay secrets, stages it into `Tron.app`, verifies bundled transcription resources, signs helper then wrapper, notarizes/staples, creates the DMG, and publishes it |

## Local dev loop

### Staging the bundled agent binary

`Tron.app` embeds the Rust agent inside the signed helper app at `Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron`. The helper binary is gitignored at `Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` and produced by:

```bash
# Build + stage the release agent (default)
packages/mac-app/scripts/bundle-agent.sh

# Or, for a faster debug-profile agent during wrapper dogfood:
packages/mac-app/scripts/bundle-agent.sh --profile debug

# Or, to use packages/agent/target/release/tron that was already built:
packages/mac-app/scripts/bundle-agent.sh --skip-build

# Or, to use a binary built elsewhere:
packages/mac-app/scripts/bundle-agent.sh --source /absolute/path/to/tron

# Or, to wipe the stage (for a clean `xcodebuild`):
packages/mac-app/scripts/bundle-agent.sh --clean
```

For local push relay dogfood, copy `packages/mac-app/.env.local.example` to `packages/mac-app/.env.local` and fill in the Cloudflare Worker values once:

```bash
TRON_RELAY_URL=https://tron-push-relay.<subdomain>.workers.dev
TRON_RELAY_SECRET=<same HMAC secret set in Wrangler>
TRON_RELAY_ENVIRONMENT=production
```

`bundle-agent.sh` reads only `TRON_RELAY_URL`, `TRON_RELAY_SECRET`, and `TRON_RELAY_ENVIRONMENT` from that ignored file immediately before it runs Cargo, so every Debug or local Release helper you stage from Xcode has the same relay config without repeating shell exports. Already-exported environment variables still take precedence, which keeps CI and one-off builds explicit.

The Xcode target also copies `packages/agent/src/transcription/sidecar/worker.py` and `requirements.txt` into `Contents/Resources/Transcription/` on every build. These are source files only; the MLX venv and Parakeet model cache are created later under `~/.tron/system/transcription/` if the wizard or iOS settings enables transcription.

After staging, regenerate the Xcode project so it picks up the file reference:

```bash
cd packages/mac-app
xcodegen generate
```

If you ship the wrapper without the staged helper binary or bundled LaunchAgent plist, `InstallStep` surfaces a helper validation failure. The wizard refuses to advance past the Install step.

If you change Rust agent code that the Mac wrapper depends on — RPC handlers, onboarding/install behavior, settings defaults, or anything used before pairing — rerun `packages/mac-app/scripts/bundle-agent.sh` before launching the Mac app from Xcode. Xcode copies the already-staged `Sources/Resources/Library` tree; it does not rebuild that binary for you. Forgetting this step makes the Swift UI talk to an older embedded server, which is especially confusing when testing new RPCs such as `logs.recent`.

Push relay config is not read from `~/.tron/system/auth.json`. Production releases compile it from GitHub secrets. Local Mac wrapper dogfood uses `packages/mac-app/.env.local` through `bundle-agent.sh`; agent-only `tron dev` sessions can still use exported `TRON_RELAY_URL`, `TRON_RELAY_SECRET`, and optionally `TRON_RELAY_ENVIRONMENT` before starting the dev server.

There is no installer cleanup path that edits production artifacts in place: the app bundle is immutable, launch registration is owned by `SMAppService`, and user data is preserved under `~/.tron`. Menu-bar uninstall unregisters `com.tron.server`, removes runtime state in `system/run/`, and can optionally remove `settings.json` and/or `auth.json`; database and workspace data stay intact. For pre-onboarding production cleanup where no menu bar exists, run `/Applications/Tron.app/Contents/MacOS/Tron --tron-uninstall-and-quit` so the same SMAppService unregister path executes without opening the wizard. The default Debug companion refuses that operation for production.

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

If a real DMG build is already installed, local Release testing replaces that same `/Applications/Tron.app` slot; there is no second side-by-side Release identity. For an update-style test, stop the wrapper/server, copy the local Release over `/Applications/Tron.app`, then launch it and restart/resume the server so launchd executes the new helper. For a first-run wizard test, choose **Uninstall Tron** from the existing menu bar app first (preserving database/workspace), copy the local Release into `/Applications/Tron.app`, then open it and run the wizard install.

For Rust-agent iteration without rebuilding the wrapper, use `tron dev`. It stops `com.tron.server`, runs `~/.tron/system/run/Tron-Dev.app` on port `9847`, then restores the installed `/Applications/Tron.app` helper through the wrapper's internal `--tron-start-server-and-quit` command when the dev process exits.

### Xcode isolated install testing

Select the `TronMac Isolated Install` scheme when you need to test the Mac installer or reinstall flow from Xcode while keeping the installed DMG app/server intact. The scheme uses the Debug wrapper bundle id but changes only the install target:

- data root: `~/.tron-dev`
- LaunchAgent label: `com.tron.server.dev`
- bundled plist: `Contents/Library/LaunchAgents/com.tron.server.dev.plist`
- server port: `9848`

Do not use this scheme for normal menu-bar UI iteration. The default `TronMac` Debug scheme is the companion mode for that.

### Test organization

```
Tests/
├── MenuBar/              # MenuBarItemBuilderTests, ServerStatusPollerTests
├── Mocks/                # MockLaunchAgentManager, TestTempDir
├── Services/             # InstallPlannerTests, TailscaleProbeTests, …
└── Wizard/               # WizardStateTests, WizardStepTests, …
```

All tests use **Swift Testing** (`@Test`, `@Suite`, `#expect`) rather than XCTest. `TestTempDir` creates throwaway directories under `NSTemporaryDirectory()` for any test that touches the filesystem.

## Running the wizard during dev

1. Stage a debug-profile agent: `bash packages/mac-app/scripts/bundle-agent.sh --profile debug`
2. `xcodegen generate`
3. Open `TronMac.xcodeproj`, select `TronMac` scheme.
4. Run (Cmd+R) — the wizard shows if `~/.tron/system/run/.onboarded` does NOT exist.
5. To re-run the wizard: `rm ~/.tron/system/run/.onboarded && defaults delete com.tron.mac.dev` (for dev) or `com.tron.mac` (for release).

To simulate the menu-bar-only mode without onboarding, just `touch ~/.tron/system/run/.onboarded` before launching.

## CI pipeline (Phase 6+)

Defined in `.github/workflows/release-mac.yml`. Broadly:

1. `scripts/tron version check` validates that `VERSION.env` matches Cargo, Cargo.lock, Mac/iOS XcodeGen settings, custom bundle canonical version keys, and release docs. Tag runs must match `server-v$(TRON_VERSION)`, so manual workflow input cannot create a mismatched artifact.
2. `cargo build --release --bin tron --locked` on the same `macos-15` runner with `TRON_RELAY_URL`, `TRON_RELAY_SECRET`, and `TRON_RELAY_ENVIRONMENT=production` from GitHub secrets (cross-compile is avoided for code-signing reasons).
3. `bash packages/mac-app/scripts/bundle-agent.sh --skip-build` inside `packages/mac-app`, which stages `packages/agent/target/release/tron`.
4. `xcodegen generate` inside `packages/mac-app/`.
5. `xcodebuild -scheme TronMac -configuration Release archive -archivePath build/TronMac.xcarchive`; the target post-build script copies transcription sidecar source files into `Contents/Resources/Transcription/`.
6. Export the `.app`, verify the helper, LaunchAgent plist, managed skills, and transcription resource files are present, then code-sign inside-out with Developer ID (no `--deep` on the re-sign — `--deep` would clobber the helper signature; it's used only for read-only `--verify`).
7. Notarize the signed app via `xcrun notarytool submit --keychain-profile tron-notarize` (credentials live ONLY in an isolated path-based keychain at `$RUNNER_TEMP/tron-build.keychain-db`, never on argv), staple the app, package it into a DMG via `create-dmg`, sign the DMG, then notarize and staple the DMG separately because notary tickets are artifact-specific.
8. Optional dSYM upload via `sentry-cli` (Phase 7; `continue-on-error` so a missing DSN doesn't fail the release).
9. `scripts/tron-release-notes` generates the draft changelog from first-parent git history since the previous `server-v*` tag, with DMG and SHA256 details included.
10. `gh release create server-v0.1.0-beta.1 ./Tron-mac-v0.1.0-beta.1.dmg` creates or updates a draft pre-release titled `Tron Server v0.1 (Beta 1)` with the generated changelog.
11. `if: always()` cleanup: remove the keychain from the search list, delete it, dd-overwrite the password file, remove `cert.p12`.

PR builds (no tag) take a dry-run path: same `xcodebuild archive` + DMG assembly but ad-hoc-signed (`-`) so fork PRs without certs still validate the pipeline.

See [`.github/workflows/release-mac.yml`](../../../.github/workflows/release-mac.yml) (added in Phase 6, hardened in Phase 8).

## Common tasks

### Add a new wizard step

1. Add a case to `WizardStep` enum in `Sources/Wizard/WizardState.swift`.
2. Create a new view file under `Sources/Wizard/Steps/`.
3. Add a case to the `switch state.step` dispatcher in `WizardView.swift`.
4. Add tests to `Tests/Wizard/WizardStepTests.swift` — at minimum, verify the step renders and the back/next buttons behave correctly.
5. Update [`.claude/rules/wizard-steps.md`](../.claude/rules/wizard-steps.md) with the step's role.

### Add a new menu-bar item

1. Extend `MenuItemDescriptor` enum in `MenuBarItemBuilder.swift` if the row needs new semantics (most new items are `.action` or `.openLink`; pairing/log detail belongs in dedicated windows).
2. Add the item to the returned array in `MenuBarItemBuilder.build(snapshot:paths:)`.
3. Pin the ordering in `Tests/MenuBar/MenuBarItemBuilderTests.swift`.

### Debug the `.onboarded` sentinel logic

`setup.onboardedSentinelExists()` is a single `FileManager.default.fileExists(atPath:)` call. If the wizard keeps re-showing, check:

```bash
ls -la ~/.tron/system/run/.onboarded
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
| Install reports missing helper executable | `Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron` was not staged before archive/build. Run `bash packages/mac-app/scripts/bundle-agent.sh`, then `xcodegen generate`. |
| Install reports invalid LaunchAgent plist | The bundled `Contents/Library/LaunchAgents/<active-label>.plist` is missing `BundleProgram`, the exact active `tron --port <port> --quiet` argv, or the wrapper `AssociatedBundleIdentifiers`. Re-run the bundle script and regenerate. |
| `SingleInstanceLock.acquire()` returns false on first launch | Another instance of the same wrapper bundle id is already running, or that specific lock file has broken permissions. Release uses `.mac-wrapper.com.tron.mac.lock`; Debug uses `.mac-wrapper.com.tron.mac.dev.lock`. |
| Tailscale step says not signed in even though `tailscale status` is healthy | Rebuild the wrapper with the latest `TailscaleProbe`; it tries every executable candidate and the "I have Tailscale" button re-probes instead of skipping the gate. |
| Wizard restarts every launch | `touchOnboardedSentinel` is not being called OR `~/.tron/system/` is not writable. Check permissions. |
| Install shows Login Items approval required | macOS returned `SMAppService.Status.requiresApproval`. Open Login Items settings and enable Tron Server; the app does not fall back to writing launchd plists manually. |
| Release install is blocked from Downloads or the DMG | Move the app to `/Applications/Tron.app` and relaunch. Release registration from any other path is intentionally unsupported. |
| Debug wrapper cannot pause/restart/uninstall the server | This is expected in companion mode. Use `/Applications/Tron.app` for production server controls, `tron dev` for server takeover, or `TronMac Isolated Install` for installer testing. |
| Release install repairs a stale DerivedData helper registration | Expected. The installer reads `launchctl print`; if the loaded label points at a missing/mismatched helper executable, the installed app replaces that stale SMAppService registration before waiting for heartbeat. |
| Debug install registers, then heartbeat times out with `launchctl` exit `78` | The wrapper/helper were ad-hoc signed. `SMAppService` can register that bundle, but launchd refuses to spawn it. Regenerate the project after this refactor and let Xcode sign Debug with `Apple Development`; `codesign -dv` should show a TeamIdentifier. |
| Permission row stays red even though System Settings shows a Tron app enabled | All three rows should enable the wrapper (`Tron.app` for Release, `TronMac.app` for Debug). Screen Recording may require dragging the row's wrapper icon into System Settings before enabling it. Remove stale `Tron Server.app` rows if macOS shows them, then enable the wrapper row and press Re-check. |
| Accessibility toggle turns itself back off | The wrong Tron entry is enabled or the wrapper signature changed between builds. Enable the exact wrapper app shown in the row; for Release, reinstall from the notarized DMG and verify the outer app with `codesign --verify --deep --strict /Applications/Tron.app`. |
| Install registers, then waits on heartbeat | Check `launchctl print gui/$(id -u)/com.tron.server`, `lsof -i :9847`, and `~/.tron/system/database/log.db.lock`. A bound port or held DB lock means another Tron server is already running; the app will not choose a different port. |
