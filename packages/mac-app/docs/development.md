# Mac App Development

> Last verified: 2026-04-23 (Phase 5)

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

Dev builds produce `Tron-Dev.app` (bundle ID `com.tron.mac.dev`); Release builds produce `Tron.app` (bundle ID `com.tron.mac`). Both manage the same LaunchAgent (`com.tron.server`) and port (9847) — single-instance lock ensures they don't coexist at runtime. See [architecture.md](./architecture.md) for the full rationale.

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

1. `cargo build --release --bin tron --locked` (Ubuntu or macOS runner — cross-compile is avoided for code-signing reasons).
2. `bash packages/mac-app/scripts/bundle-agent.sh --skip-build --source target/release/tron`.
3. `xcodegen generate` inside `packages/mac-app/`.
4. `xcodebuild -scheme TronMac -configuration Release archive -archivePath build/TronMac.xcarchive`.
5. Export the `.app`, code-sign with Developer ID, notarize via `xcrun notarytool`, staple, package into DMG via `create-dmg`.
6. `gh release create mac-v$VERSION ./Tron-mac-v$VERSION.dmg`.

See [`.github/workflows/release-mac.yml`](../../../.github/workflows/release-mac.yml) (added in Phase 6).

## Common tasks

### Add a new wizard step

1. Add a case to `WizardStep` enum in `Sources/Wizard/WizardState.swift`.
2. Create a new view file under `Sources/Wizard/Steps/`.
3. Add a case to the `switch state.step` dispatcher in `WizardView.swift`.
4. Add tests to `Tests/Wizard/WizardStepTests.swift` — at minimum, verify the step renders and the back/next buttons behave correctly.
5. Update [`.claude/rules/wizard-steps.md`](../.claude/rules/wizard-steps.md) with the step's role.

### Add a new menu-bar item

1. Extend `MenuItemDescriptor` enum in `MenuBarItemBuilder.swift` if the row needs new semantics (most new items are `.action`, `.copy`, or `.openLink`).
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
| `SingleInstanceLock.acquire()` returns false on first launch | Stale lock file with a PID no longer alive. `rm ~/.tron/system/Tron.app.lock` and relaunch. |
| Wizard restarts every launch | `touchOnboardedSentinel` is not being called OR `~/.tron/system/` is not writable. Check permissions. |
| `launchctl bootstrap` fails with 119 | LaunchAgent already loaded. Unload first: `launchctl bootout gui/$(id -u)/com.tron.server`. |
