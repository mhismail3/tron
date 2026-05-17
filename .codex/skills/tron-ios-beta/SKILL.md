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
`xcrun devicectl`, and launches the resolved bundle ID.

`launch` launches the already-installed beta app without rebuilding.

`stop` finds running `TronMobile.app/TronMobile` processes on the selected
device and terminates them by PID.

The script auto-selects the only available physical iOS device. If multiple
devices are available, set `TRON_IOS_DEVICE_ID`, `TRON_IOS_DEVICE_NAME`, or
`TRON_IOS_DESTINATION` locally before running it.
