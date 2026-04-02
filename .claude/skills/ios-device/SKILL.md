---
name: iOS Device Runner
description: Build, run, stop, and clean TronMobile on a physical iOS device using the xcodebuildmcp CLI
autoInject: false
version: "1.0.0"
tools:
  - Bash
tags:
  - ios
  - device
  - xcode
  - build
---

Build, deploy, and manage TronMobile on a physical iOS device using the `xcodebuildmcp` CLI. Use this skill when the user asks to run the app on their phone, test a build on device, stop the running app, or clean build artifacts.

## Project Defaults

All paths are relative to the repo root (`packages/ios-app/`).

```bash
PROJECT_PATH="packages/ios-app/TronMobile.xcodeproj"
DERIVED_DATA="packages/ios-app/.build/DerivedData"
```

| Variant | Scheme | Configuration | Bundle ID |
|---------|--------|---------------|-----------|
| Prod (default) | `TronMobile` | `Debug-Prod` | `com.tron.mobile` |
| Prod Release | `TronMobile` | `Release-Prod` | `com.tron.mobile` |
| Beta | `TronMobile-Beta` | `Debug-Beta` | `com.tron.mobile.beta` |
| Beta Release | `TronMobile-Beta` | `Release-Beta` | `com.tron.mobile.beta` |

## 1. Detect Connected Device

Before any device operation, get the UDID of the connected iPhone:

```bash
xcodebuildmcp device list
```

Parse the UDID from the output for the connected iPhone (look for `Connection: wired`). The user's primary device is "Moose's iPhone" but always auto-detect from the list.

## 2. Build & Run (Play Button)

Single command that builds, installs, and launches on device:

```bash
xcodebuildmcp device build-and-run \
  --project-path packages/ios-app/TronMobile.xcodeproj \
  --scheme TronMobile \
  --device-id <UDID> \
  --configuration Debug-Prod \
  --derived-data-path packages/ios-app/.build/DerivedData
```

**Variants:**
- Beta: `--scheme TronMobile-Beta --configuration Debug-Beta`
- Release: `--configuration Release-Prod`
- Beta Release: `--scheme TronMobile-Beta --configuration Release-Beta`

**Important:** The output contains the process ID needed to stop the app later. Look for the line:
```
Stop app on device: xcodebuildmcp device stop --device-id "..." --process-id "NNNNN"
```
Save the `--process-id` value for use with the stop command.

## 3. Stop (Stop Button)

Requires the process ID from the `build-and-run` output:

```bash
xcodebuildmcp device stop --device-id <UDID> --process-id <PID>
```

**Fallback** if you don't have the process ID (e.g. app was launched from Xcode GUI), find it first:

```bash
# Find PID by bundle ID
xcrun devicectl device info processes --device <UDID> 2>/dev/null | grep -i tron
```

Then stop with the discovered PID. Both `xcodebuildmcp device stop` and `xcrun devicectl device process terminate` require the PID — there is no bundle-ID-only stop.

## 4. Clean

### Standard clean (CLI build artifacts only)

```bash
xcodebuildmcp device clean \
  --project-path packages/ios-app/TronMobile.xcodeproj \
  --scheme TronMobile \
  --derived-data-path packages/ios-app/.build/DerivedData
```

### Nuclear clean (all DerivedData)

Removes CLI DerivedData and Xcode GUI DerivedData:

```bash
rm -rf packages/ios-app/.build/DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/TronMobile-*
```

After a nuclear clean, the next `build-and-run` will do a full rebuild.

## 5. Device Logs

Start capturing logs from the running app:

```bash
xcodebuildmcp device start-device-log-capture \
  --device-id <UDID> \
  --bundle-id com.tron.mobile
```

The output contains a `--log-session-id`. When done, stop capture and retrieve logs:

```bash
xcodebuildmcp device stop-device-log-capture \
  --log-session-id <SESSION_ID>
```

## 6. Other Useful Commands

```bash
# Show build settings for debugging config issues
xcodebuildmcp device show-build-settings \
  --project-path packages/ios-app/TronMobile.xcodeproj \
  --scheme TronMobile

# Get the path to the built .app
xcodebuildmcp device get-app-path \
  --scheme TronMobile

# List available schemes
xcodebuildmcp device list-schemes \
  --project-path packages/ios-app/TronMobile.xcodeproj
```

## Quick Reference

```bash
# Run on device (prod debug)
xcodebuildmcp device build-and-run --project-path packages/ios-app/TronMobile.xcodeproj --scheme TronMobile --device-id <UDID> --configuration Debug-Prod --derived-data-path packages/ios-app/.build/DerivedData

# Run on device (beta debug)
xcodebuildmcp device build-and-run --project-path packages/ios-app/TronMobile.xcodeproj --scheme TronMobile-Beta --device-id <UDID> --configuration Debug-Beta --derived-data-path packages/ios-app/.build/DerivedData

# Stop app
xcodebuildmcp device stop --device-id <UDID> --process-id <PID>

# Clean everything
rm -rf packages/ios-app/.build/DerivedData ~/Library/Developer/Xcode/DerivedData/TronMobile-*

# Device logs
xcodebuildmcp device start-device-log-capture --device-id <UDID> --bundle-id com.tron.mobile
```
