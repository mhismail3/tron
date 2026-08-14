# Tron Mac development

## Stage the bundled Gateway

A fresh clone has no generated Gateway payload. Stage the exact production
dependency tree, checksum-pinned Node runtimes, and universal launcher before
building:

```bash
packages/mac-app/scripts/bundle-gateway.sh
```

The script runs the locked Gateway install and build, creates an independent
production-only dependency tree, verifies Node 22.22.0 arm64 and x64 archives,
compiles `tron-gateway-launcher.c`, and stages it in both Login Items.

For local iteration:

```bash
packages/mac-app/scripts/bundle-gateway.sh --skip-install
packages/mac-app/scripts/bundle-gateway.sh --skip-install --skip-download
packages/mac-app/scripts/bundle-gateway.sh --clean
```

Generated Gateway payloads and launcher binaries are ignored by Git.

## Generate and build

The project has one `TronMac` scheme. Configuration selects the mode:

- Debug: `com.tron.gateway.dev`, `~/.tron-dev`, port 9848.
- Release: `com.tron.gateway`, `~/.tron`, port 9847.

```bash
cd packages/mac-app
xcodegen generate

xcodebuild build -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'

xcodebuild build -project TronMac.xcodeproj -scheme TronMac \
  -configuration Release -destination 'platform=macOS,arch=arm64'
```

Release registration requires `/Applications/Tron.app`. Debug is intentionally
isolated and can run from Xcode build products.

The internal command mode used by installation flows is:

```bash
# Debug
/path/to/TronMac.app/Contents/MacOS/TronMac --tron-start-gateway-and-quit

# Release
/Applications/Tron.app/Contents/MacOS/Tron --tron-start-gateway-and-quit
```

## Tests

Build once, run focused owners while iterating, then run the complete suite:

```bash
xcodebuild build-for-testing -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'

xcodebuild test-without-building -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -only-testing:TronMacTests/GatewayLifecycleCoordinatorTests \
  -only-testing:TronMacTests/GatewayOnboardingModelTests \
  -only-testing:TronMacTests/SingleInstanceLockTests

xcodebuild test -project TronMac.xcodeproj -scheme TronMac \
  -configuration Debug -destination 'platform=macOS,arch=arm64'
```

The tests use behavioral service doubles, parsed plist assertions, real atomic
filesystem operations, and a spawned process for lock exclusivity. They do not
assert Swift source text.

## Development lifecycle checkpoint

With Tailscale connected, exercise the Debug service without touching
production state:

1. Launch the Debug app and complete onboarding.
2. Confirm `com.tron.gateway.dev` is enabled and port 9848 is healthy.
3. Pause, resume, and restart from the menu bar.
4. Terminate the Gateway process and confirm launchd restarts it.
5. Quit and relaunch the Debug app; confirm reconciliation reuses the current
   healthy service without replacing it.
6. Refresh pairing and connect an iPhone using the current one-time code.
7. Uninstall, confirm the service is absent, and confirm durable Gateway data
   remains.

## Built-product inspection

```bash
APP=/path/to/TronMac.app

plutil -p "$APP/Contents/Library/LaunchAgents/com.tron.gateway.dev.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 \
  "$APP/Contents/Library/LoginItems/Tron Gateway Dev.app"
codesign -d --entitlements :- "$APP/Contents/Resources/Gateway/runtime/node-arm64"
```

For Release, inspect `com.tron.gateway.plist` and `Tron Gateway.app` instead.
The plist must preserve the exact label, helper path, arguments, environment,
associated wrapper ID, `RunAtLoad`, `KeepAlive`, and throttle interval.

## Release

Mac release remains manual. Stage the Gateway, generate the project, archive
with the maintainer's Developer ID identity, inspect signatures, notarize and
staple the app and DMG, then publish deliberately.
`packages/mac-app/scripts/package-dmg.sh` owns DMG layout verification and
requires `create-dmg` on `PATH`.
