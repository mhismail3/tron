---
name: tron-ios-beta
description: Build, install, launch, stop, or check a local Tron iOS app variant on a physical iOS device from this workspace.
---

Use this skill for local Tron iOS physical-device workflows. The default variant
is the side-by-side beta app.

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
without rebuilding. Launch is bounded by `TRON_IOS_LAUNCH_TIMEOUT_SECONDS`,
defaulting to 20 seconds.

`stop` finds running `TronMobile.app/TronMobile` processes on the selected
device and terminates them by PID.

Codex app toolbar actions are split by generic device class:

```bash
env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-beta install
env TRON_IOS_DEVICE_NAME=iPhone TRON_IOS_SCHEME='Tron Fast' TRON_IOS_CONFIGURATION=ProdDebug scripts/tron-ios-beta install
env TRON_IOS_DEVICE_NAME=iPad scripts/tron-ios-beta install
env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-beta launch
env TRON_IOS_DEVICE_NAME=iPad scripts/tron-ios-beta launch
```

The script auto-selects the only selectable physical iOS device, where
selectable means CoreDevice reports it as `available` or `connected`. If
multiple devices are selectable, set `TRON_IOS_DEVICE_ID`,
`TRON_IOS_DEVICE_NAME`, or `TRON_IOS_DESTINATION` locally before running it.
Use `TRON_IOS_SCHEME` and `TRON_IOS_CONFIGURATION` only for intentional
non-default variants; defaults remain the side-by-side beta app.
