---
name: Xcode CLI
description: Build, run, stop, clean, and debug TronMobile on physical iOS devices and simulators using native xcodebuild and xcrun tools
autoInject: false
version: "3.0.0"
tools:
  - Bash
tags:
  - ios
  - device
  - xcode
  - build
  - simulator
---

Use `tron ios` for all routine build / run / stop / clean / test / logs operations on TronMobile. It wraps the raw `xcodebuild`, `xcrun devicectl`, `xcrun simctl`, and `log` commands and reads device UDIDs from `~/.tron/system/settings.json` (never committed). The low-level commands below are kept for debugging the wrapper itself or for cases `tron ios` does not cover.

When the user asks to run the app on their phone, build for simulator, stop the running app, view device logs, or clean build artifacts — reach for `tron ios` first. Run `tron ios --help` to see the full interface.

## Quick reference

```bash
tron ios                       # Build + run prod on default device
tron ios -b                    # Build + run beta on default device
tron ios -d ipad -b            # Build + run beta on 'ipad' alias
tron ios -s                    # Build + run on default simulator
tron ios build -g              # Compile check, no device needed
tron ios stop                  # Stop the last-launched app
tron ios clean                 # Scheme-aware clean
tron ios clean --nuclear       # Wipe all DerivedData (workspace + global)
tron ios test                  # Run test suite on simulator
tron ios logs                  # Last 5 min of device logs
tron ios logs --minutes 15     # Last 15 min
tron ios devices list          # Show saved devices (default marked with *)
tron ios devices add           # Register a connected device (interactive)
tron ios devices scan          # Show currently connected physical devices
tron ios gen                   # Regenerate .xcodeproj via xcodegen
tron ios -v                    # Any subcommand + -v streams full xcodebuild output
```

Flags compose: `tron ios -b -d ipad -v` builds and runs the Beta scheme on the iPad with verbose output.

## Project defaults

All paths are relative to the repo root.

```
PROJECT=packages/ios-app/TronMobile.xcodeproj
DERIVED_DATA=packages/ios-app/.build/DerivedData
```

| Variant | Scheme | Configuration | Bundle ID |
|---------|--------|---------------|-----------|
| Prod (default) | `Tron` | `Prod` | `com.tron.mobile` |
| Beta | `Tron Beta` | `Beta` | `com.tron.mobile.beta` |

Default is Prod. `-b` / `--beta` selects Beta.

## Configuration

Device preferences live under the `ios` key in `~/.tron/system/settings.json`:

```json
{
  "ios": {
    "defaultDevice": "iphone",
    "defaultSimulator": "iPhone 17 Pro",
    "defaultScheme": "prod",
    "devices": {
      "iphone": { "udid": "...", "label": "...", "platform": "iOS" }
    }
  }
}
```

First-run setup: `tron ios devices add` scans connected devices and prompts for an alias. UDIDs never appear in source control.

`tron ios` also writes `ios.lastLaunch` after every successful run so `tron ios stop` can terminate without arguments.

## Output formatting

`tron ios build` / `run` / `test` invocations produce Xcode-quality feedback:

- Success is quiet (one-line summary).
- Failure shows parsed `file:line:col: error: message` entries, failed-command block, signing / linker diagnostics, and paths to the full log + an `.xcresult` bundle (openable in Xcode).
- `-v` streams the raw `xcodebuild` output live.
- `xcbeautify` or `xcpretty` are auto-used if installed; otherwise a native filter keeps things readable.

Full log path per invocation: `/tmp/tron-ios-<ts>-<pid>.log`. The most recent paths are recorded at `/tmp/tron-ios-last-log` and `/tmp/tron-ios-last-xcresult`.

---

## Low-level reference (appendix)

The raw commands `tron ios` wraps. Use these when the wrapper doesn't cover the case, when debugging the wrapper itself, or when you need to compose something custom. Substitute `<UDID>` with a value from `tron ios devices list`.

### Detect connected devices

```bash
xcrun xctrace list devices 2>&1 | head -20
```

### Build & install (physical device, no launch)

```bash
cd packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme Tron \
    -configuration Prod \
    -destination 'platform=iOS,id=<UDID>' \
    -derivedDataPath .build/DerivedData \
    -resultBundlePath /tmp/tron-ios.xcresult \
    -quiet 2>&1 | tail -30
```

For Beta: swap `-scheme 'Tron Beta' -configuration Beta`.

### Compile check (no device needed)

```bash
cd packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme Tron \
    -destination 'generic/platform=iOS' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -20
```

### Launch on device

```bash
xcrun devicectl device process launch --device <UDID> com.tron.mobile
# Beta: com.tron.mobile.beta
```

Output includes `Process ID: N` — save it to terminate later.

### Stop app

```bash
# With PID from launch output
xcrun devicectl device process terminate --device <UDID> --pid <PID>

# Find PID if missing
xcrun devicectl device info processes --device <UDID> | grep -i tron
```

No bundle-ID-only termination exists — the PID is required.

### Simulator (build + launch)

```bash
cd packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme 'Tron Beta' \
    -configuration Beta \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -20

xcrun simctl boot 'iPhone 17 Pro' 2>/dev/null
xcrun simctl install booted \
  packages/ios-app/.build/DerivedData/Build/Products/Beta-iphonesimulator/TronMobile.app
xcrun simctl launch booted com.tron.mobile.beta
```

### Tests (simulator)

```bash
cd packages/ios-app && \
  xcodebuild test \
    -project TronMobile.xcodeproj \
    -scheme Tron \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -30
```

Target a specific test:

```bash
  -only-testing:TronMobileTests/SomeTestClass/testMethodName
```

### Clean

```bash
# Scheme-aware
cd packages/ios-app && \
  xcodebuild clean \
    -project TronMobile.xcodeproj \
    -scheme 'Tron Beta' \
    -derivedDataPath .build/DerivedData \
    -quiet

# Nuclear (all DerivedData)
rm -rf packages/ios-app/.build/DerivedData ~/Library/Developer/Xcode/DerivedData/TronMobile-*
```

### Device logs

```bash
# Collect last 5 minutes from the device
/usr/bin/log collect \
  --device-udid <UDID> \
  --last 5m \
  --output /tmp/tron-device-logs.logarchive

# View, filtered to the app
/usr/bin/log show /tmp/tron-device-logs.logarchive \
  --predicate 'subsystem == "com.tron.mobile.beta"' \
  --style compact

# Stream Mac-local logs (works for simulator; `log stream` has no --device flag)
/usr/bin/log stream --process TronMobile --level debug
```

### Utilities

```bash
# List schemes
xcodebuild -list -project packages/ios-app/TronMobile.xcodeproj

# Dump build settings
xcodebuild -showBuildSettings \
  -project packages/ios-app/TronMobile.xcodeproj \
  -scheme 'Tron Beta' \
  -configuration Beta 2>/dev/null | head -50

# Find the built .app bundle
find packages/ios-app/.build/DerivedData/Build/Products -name "TronMobile.app" -type d 2>/dev/null

# Check code signing of the built bundle
codesign -dv --verbose=4 \
  "$(find packages/ios-app/.build/DerivedData/Build/Products -name 'TronMobile.app' -type d | head -1)" 2>&1

# Regenerate .xcodeproj from project.yml
cd packages/ios-app && xcodegen generate
```
