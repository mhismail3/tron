---
name: xcode
description: Build, install, launch, stop, or check a local Tron iOS app variant on a physical iOS device from this workspace.
autoInject: false
version: "1.0.0"
tools:
  - Bash
tags:
  - ios
  - xcode
  - tron
---

Use this skill for local physical-device Tron iOS workflows. The default variant
is the side-by-side beta app.

## Commands

Run commands from the repository root:

```bash
scripts/tron-ios-beta install
scripts/tron-ios-beta launch
scripts/tron-ios-beta stop
scripts/tron-ios-beta status
```

`install` regenerates the Xcode project, builds the `Tron Beta` scheme with the
`Beta` configuration by default for a physical iOS destination, installs the app
with `xcrun devicectl`, and launches the resolved bundle ID unless `--no-launch`
is provided. Set `TRON_IOS_SCHEME` and `TRON_IOS_CONFIGURATION` to build a local
variant such as `Tron Fast` / `ProdDebug`.

`launch` launches the already-installed app for the selected scheme/configuration
without rebuilding. Use it after unlocking the device if install succeeded but
launch was denied because the device was locked. Launch is bounded by
`TRON_IOS_LAUNCH_TIMEOUT_SECONDS`, defaulting to 20 seconds.

`stop` finds running `TronMobile.app/TronMobile` processes on the target device
and terminates their PIDs with `xcrun devicectl device process terminate`.

The Codex app toolbar actions are split by generic device class:

```bash
env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-beta install
env TRON_IOS_DEVICE_NAME=iPhone TRON_IOS_SCHEME='Tron Fast' TRON_IOS_CONFIGURATION=ProdDebug scripts/tron-ios-beta install
env TRON_IOS_DEVICE_NAME=iPad scripts/tron-ios-beta install
env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-beta launch
env TRON_IOS_DEVICE_NAME=iPad scripts/tron-ios-beta launch
```

## Device Selection

The script selects the only selectable physical iOS device, where selectable
means CoreDevice reports it as `available` or `connected`. If more than one is
selectable, set one of these local environment overrides before running it:

```bash
export TRON_IOS_DEVICE_ID=<device-identifier>
export TRON_IOS_DEVICE_NAME=<device-name>
```

For a custom Xcode destination, set:

```bash
export TRON_IOS_DESTINATION='platform=iOS,id=<device-identifier>'
```

For intentional local variants, set:

```bash
export TRON_IOS_SCHEME='Tron Fast'
export TRON_IOS_CONFIGURATION=ProdDebug
```

Do not hardcode personal device names or identifiers in tracked code or skill
docs.
