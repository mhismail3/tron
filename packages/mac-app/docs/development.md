# Mac App Development

> Last verified: 2026-04-24 (Phase 9 onboarding polish)

## Setup

### Prerequisites

- Xcode 16+ (macOS 14 Sonoma SDK minimum)
- XcodeGen (`brew install xcodegen`)
- Rust toolchain (`rustup`) — for the bundled agent binary
- Signing: ad-hoc for Debug; `Developer ID Application` for Release (optional, only for DMG distribution)

### One-time setup

```bash
cd packages/mac-app
xcodegen generate
open TronMac.xcodeproj
```

Build products differ between configurations:

- **Debug** → `TronMac.app` (bundle ID `com.tron.mac.dev`, executable `TronMac`). Lives in `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/TronMac.app`. The default `PRODUCT_NAME = $(TARGET_NAME)` is intentionally left untouched here so the `TronMacTests` target's `BUNDLE_LOADER` / `TEST_HOST` (which reference `TronMac.app/Contents/MacOS/TronMac`) keep resolving without configuration drift.
- **Release** → `Tron.app` (bundle ID `com.tron.mac`, executable `Tron`). `Configuration/Release.xcconfig` sets `PRODUCT_NAME = Tron` so the archived bundle matches both the `.github/workflows/release-mac.yml` `APP_BUNDLE: Tron.app` expectation and the `/Applications/Tron.app` end-user surface. Built by the DMG pipeline and shipped notarized.

Both configurations manage the same LaunchAgent (`com.tron.server`) and port (`9847`) — the wrapper's `~/.tron/system/.mac-wrapper.lock` ensures only one wrapper runs at a time, regardless of which configuration built it.

> **Disambiguation**: the Debug-config `TronMac.app` (workflow 2 — wizard dogfood) is unrelated to `Tron-Dev.app` at `~/.tron/system/deployment/Tron-Dev.app`, which is workflow 3's headless agent built by `tron dev` (bundle ID `com.tron.agent`, no SwiftUI). See [architecture.md → Workflows & Variants](./architecture.md#workflows--variants) for the canonical three-workflow breakdown.

The wizard install path is intentionally smaller than `tron dev` or `tron deploy`: it copies the server into `~/.tron/system/Tron.app`, writes `~/Library/LaunchAgents/com.tron.server.plist`, and waits for the server heartbeat. It does not stage deploy scripts or dev bundles under `~/.tron/system/deployment/`; that directory is local dev/deploy/update state and can be absent or empty after a normal installer run.

## Local dev loop

### Staging the bundled agent binary

`Tron.app` embeds the Rust agent as `Contents/Resources/tron-agent`. The file is gitignored (`Sources/Resources/tron-agent`) and produced by:

```bash
# Build + stage the release agent (default)
packages/mac-app/scripts/bundle-agent.sh

# Or, for a faster debug-profile agent during wizard dogfood:
packages/mac-app/scripts/bundle-agent.sh --profile debug

# Or, to use a binary built elsewhere (e.g., via `cargo build` in a sibling shell):
packages/mac-app/scripts/bundle-agent.sh --skip-build

# Or, to wipe the stage (for a clean `xcodebuild`):
packages/mac-app/scripts/bundle-agent.sh --clean
```

After staging, regenerate the Xcode project so it picks up the file reference:

```bash
cd packages/mac-app
xcodegen generate
```

If you ship the wrapper without the staged binary, `InstallStep` surfaces `.sourceBinaryMissing`. The wizard refuses to advance past the Install step.

If you change Rust agent code that the Mac wrapper depends on — RPC handlers, onboarding/install behavior, permission/TCC probes, or anything used before pairing — rerun `packages/mac-app/scripts/bundle-agent.sh` before launching the Mac app from Xcode. Xcode copies the already-staged `Sources/Resources/tron-agent`; it does not rebuild that binary for you. Forgetting this step makes the Swift UI talk to an older embedded server, which is especially confusing when testing new RPCs such as `system.requestPermission`.

If the installer is interrupted after writing launch artifacts, use the cleanup action on the Install step. Cleanup unloads `com.tron.server`, removes `~/.tron/system/Tron.app` plus `~/Library/LaunchAgents/com.tron.server.plist`, and removes `~/.tron/system/deployment/` only when it is empty. Auth, settings, databases, workspace files, and non-empty dev/deploy/update artifacts are preserved.

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
4. Run (Cmd+R) — the wizard shows if `~/.tron/system/.onboarded` does NOT exist.
5. To re-run the wizard: `rm ~/.tron/system/.onboarded && defaults delete com.tron.mac.dev` (for dev) or `com.tron.mac` (for release).

To simulate the menu-bar-only mode without onboarding, just `touch ~/.tron/system/.onboarded` before launching.

## CI pipeline (Phase 6+)

Defined in `.github/workflows/release-mac.yml`. Broadly:

1. `cargo build --release --bin tron --locked` on the same `macos-14` runner (cross-compile is avoided for code-signing reasons).
2. `bash packages/mac-app/scripts/bundle-agent.sh --skip-build --source target/release/tron`.
3. `xcodegen generate` inside `packages/mac-app/`.
4. `xcodebuild -scheme TronMac -configuration Release archive -archivePath build/TronMac.xcarchive`.
5. Export the `.app`, code-sign inside-out with Developer ID (no `--deep` on the re-sign — `--deep` would clobber the helper signature; it's used only for read-only `--verify`), notarize via `xcrun notarytool submit --keychain-profile tron-notarize` (credentials live ONLY in an isolated path-based keychain at `$RUNNER_TEMP/tron-build.keychain-db`, never on argv), staple, package into DMG via `create-dmg`.
6. Optional dSYM upload via `sentry-cli` (Phase 7; `continue-on-error` so a missing DSN doesn't fail the release).
7. `gh release create mac-v$VERSION ./Tron-mac-v$VERSION.dmg --clobber` (idempotent on re-run).
8. `if: always()` cleanup: remove the keychain from the search list, delete it, dd-overwrite the password file, remove `cert.p12`.

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
ls -la ~/.tron/system/.onboarded
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
| `Bundle.main.url(forResource: "tron-agent")` returns nil | `Sources/Resources/tron-agent` not staged before `xcodegen generate`. Run `bash scripts/bundle-agent.sh` then regenerate. |
| `BUILD FAILED` with "No such file or directory" for `tron-agent` | Same as above — resource file reference stale after a clean. Run `xcodegen generate` again. |
| `SingleInstanceLock.acquire()` returns false on first launch | Stale lock file with a PID no longer alive (rare — `fcntl(F_SETLK)` locks are kernel-released on process exit, so this only happens if the file's perms got broken). `rm ~/.tron/system/.mac-wrapper.lock` and relaunch. |
| Wizard restarts every launch | `touchOnboardedSentinel` is not being called OR `~/.tron/system/` is not writable. Check permissions. |
| `launchctl bootstrap` fails with 119 | LaunchAgent already loaded. Unload first: `launchctl bootout gui/$(id -u)/com.tron.server`. |
| Existing-install step reports only a LaunchAgent plist | `~/Library/LaunchAgents/com.tron.server.plist` exists but `~/.tron/system/Tron.app/Contents/MacOS/tron` does not. This is usually an interrupted wrapper install or a removed app bundle; pressing Install will replace the plist and copy the bundled server. |
| Accessibility toggle turns itself back off | The installed inner `~/.tron/system/Tron.app` is not signed as `com.tron.server` (old dogfood builds left the executable's linker-generated ad-hoc identity). Use installer cleanup and reinstall; the current installer signs the assembled bundle before launchd starts it. Verify with `codesign -dv --verbose=4 ~/.tron/system/Tron.app`. |
| Install shows copy/write/load complete, then waits on heartbeat | Check whether launchd is running a stale process image: `launchctl print gui/$(id -u)/com.tron.server` then `lsof -p <pid>`. The wizard's install path should now kickstart an already-loaded label after rewriting the plist. |
