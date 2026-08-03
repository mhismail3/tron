---
name: tron-ios
description: Build, test, install, launch, stop, or inspect Tron iOS app variants on simulators and physical devices. Use for Codex simulator testing, fast physical-device iteration, and user-facing Prod installs from this workspace.
---

Run commands from the repository root.

## Variant policy

Apply this policy unless the user explicitly requests another variant:

- Use `Tron Beta` / `Beta` for simulator app-path work and simulator tests.
- Use `Tron Fast` / `ProdDebug` only when Codex needs fast iteration on a
  physical device.
- Use `Tron` / `Prod` whenever installing an app on the user's physical device
  for the user to evaluate.
- Do not install the Beta bundle on the user's physical device by default.
- Do not describe a locally development-signed Prod build as a production APNs
  acceptance build. The device helper deliberately uses APNs sandbox for local
  Prod installs; require TestFlight or an App Store export for a production
  provider claim.

Prefer the simulator for Codex-owned testing. Use a physical device only for a
user-requested install or device-only behavior such as APNs, camera, or hardware
integration.

## Simulator

The simulator helper intentionally fixes the app variant to Beta and preserves
the remembered simulator's paired app container:

```bash
scripts/tron-ios-simulator install
scripts/tron-ios-simulator start
scripts/tron-ios-simulator status
scripts/tron-ios-simulator remember
```

For hosted simulator tests, select the `Tron Beta` scheme. Its test action uses
the isolated `Test` configuration by project design:

```bash
cd packages/ios-app && xcodegen generate && xcodebuild test -scheme 'Tron Beta' -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Physical device

The physical-device helper defaults to Prod Release. Pass an explicit variant
for clarity in automated commands.

Install Prod Release for the user:

```bash
env TRON_IOS_DEVICE_NAME=iPhone TRON_IOS_SCHEME=Tron TRON_IOS_CONFIGURATION=Prod scripts/tron-ios-device install
```

Use Prod Fast for Codex-owned physical-device iteration:

```bash
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer TRON_IOS_REQUIRED_SDK_MAJOR=27 TRON_IOS_DEVICE_NAME=iPhone TRON_IOS_SCHEME='Tron Fast' TRON_IOS_CONFIGURATION=ProdDebug scripts/tron-ios-device install
```

Operate on an already-installed production-bundle app:

```bash
env TRON_IOS_DEVICE_NAME=iPhone TRON_IOS_SCHEME=Tron TRON_IOS_CONFIGURATION=Prod scripts/tron-ios-device launch
env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-device stop
env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-device status
```

`install` regenerates `TronMobile.xcodeproj` from authoritative `project.yml`,
builds that project directly, installs through `xcrun devicectl`, and launches
unless `--no-launch` is supplied. `TRON_IOS_REQUIRED_SDK_MAJOR` makes
SDK-sensitive workflows fail before building with a mismatched toolchain.
`launch` is bounded by `TRON_IOS_LAUNCH_TIMEOUT_SECONDS`, defaulting to 20
seconds.

The script auto-selects the only selectable physical iOS device, where
selectable means CoreDevice reports it as `available` or `connected`. If
multiple devices are selectable, set either `TRON_IOS_DEVICE_ID` or
`TRON_IOS_DEVICE_NAME`.
