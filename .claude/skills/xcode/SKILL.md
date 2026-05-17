---
name: xcode
description: Build, install, launch, stop, or check the local Tron Beta iOS app on a physical iOS device from this workspace.
autoInject: false
version: "1.0.0"
tools:
  - Bash
tags:
  - ios
  - xcode
  - tron
---

Use this skill for local physical-device Tron iOS Beta workflows.

## Commands

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

`launch` launches the already-installed beta app without rebuilding. Use it
after unlocking the device if install succeeded but launch was denied because
the device was locked.

`stop` finds running `TronMobile.app/TronMobile` processes on the target device
and terminates their PIDs with `xcrun devicectl device process terminate`.

## Device Selection

The script selects the only available physical iOS device. If more than one is
available, set one of these local environment overrides before running it:

```bash
export TRON_IOS_DEVICE_ID=<device-identifier>
export TRON_IOS_DEVICE_NAME=<device-name>
```

For a custom Xcode destination, set:

```bash
export TRON_IOS_DESTINATION='platform=iOS,id=<device-identifier>'
```

Do not hardcode personal device names or identifiers in tracked code or skill
docs.
