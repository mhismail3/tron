---
name: tron-ios-beta
description: Build, install, launch, stop, or check the local Tron Beta iOS app on a physical iOS device from this workspace.
---

Use this skill for local Tron iOS Beta physical-device workflows.

Run commands from the repository root:

```bash
scripts/tron-ios-beta install
scripts/tron-ios-beta launch
scripts/tron-ios-beta stop
scripts/tron-ios-beta status
```

`install` regenerates the Xcode project, builds the `Tron Beta` scheme with the
`Beta` configuration for a physical iOS destination, installs the app with
`xcrun devicectl`, and launches the resolved bundle ID unless `--no-launch` is
provided.

`launch` launches the already-installed beta app without rebuilding. Launch is
bounded by `TRON_IOS_LAUNCH_TIMEOUT_SECONDS`, defaulting to 20 seconds.

`stop` finds running `TronMobile.app/TronMobile` processes on the selected
device and terminates them by PID.

Codex app toolbar actions are split by generic device class:

```bash
env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-beta install
env TRON_IOS_DEVICE_NAME=iPad scripts/tron-ios-beta install
env TRON_IOS_DEVICE_NAME=iPhone scripts/tron-ios-beta launch
env TRON_IOS_DEVICE_NAME=iPad scripts/tron-ios-beta launch
```

The script auto-selects the only selectable physical iOS device, where
selectable means CoreDevice reports it as `available` or `connected`. If
multiple devices are selectable, set `TRON_IOS_DEVICE_ID`,
`TRON_IOS_DEVICE_NAME`, or `TRON_IOS_DESTINATION` locally before running it.
