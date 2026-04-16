---
name: Xcode CLI
description: Build, run, stop, clean, and debug TronMobile on physical iOS devices and simulators using native xcodebuild and xcrun tools
autoInject: false
version: "2.0.0"
tools:
  - Bash
tags:
  - ios
  - device
  - xcode
  - build
  - simulator
---

Build, deploy, and manage TronMobile on physical iOS devices and simulators using native Apple tooling (`xcodebuild`, `xcrun devicectl`, `log`). Use this skill when the user asks to run the app on their phone, test a build on device or simulator, stop the running app, view device logs, or clean build artifacts.

## Known Devices

| Device | Name | UDID | OS |
|--------|------|------|----|
| iPhone (primary) | Moose's iPhone | `00008150-000154521E08401C` | iOS 26.3.1 |
| iPad Pro | Moose's iPad Pro | `00008142-000A25DA0E47801C` | iOS 26.3.1 |

The iPhone is the default target. The iPad is often offline. When the user says "run on device" or "test on my phone", use the iPhone UDID directly without detection.

## Project Defaults

All paths are relative to the repo root.

```
PROJECT=packages/ios-app/TronMobile.xcodeproj
DERIVED_DATA=packages/ios-app/.build/DerivedData
```

| Variant | Scheme | Configuration | Bundle ID |
|---------|--------|---------------|-----------|
| Prod (default) | `Tron` | `Prod` | `com.tron.mobile` |
| Beta | `Tron Beta` | `Beta` | `com.tron.mobile.beta` |

Default to **Prod** unless the user specifies beta.

---

## 1. Detect Connected Devices

List all connected physical devices and their UDIDs:

```bash
xcrun xctrace list devices 2>&1 | head -10
```

Only needed if a new/unknown device is connected. For the known devices above, skip detection and use the hardcoded UDID.

---

## 2. Build & Install

Compile and install the app onto a physical device. This does NOT launch it.

**Prod (default):**
```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme Tron \
    -configuration Prod \
    -destination 'platform=iOS,id=00008150-000154521E08401C' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -30
```

**Beta:**
```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme 'Tron Beta' \
    -configuration Beta \
    -destination 'platform=iOS,id=00008150-000154521E08401C' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -30
```

**Build-only check (no device needed):**
```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme Tron \
    -destination 'generic/platform=iOS' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -20
```

This compiles for the iOS architecture without targeting a specific device. Useful for checking if code compiles.

---

## 3. Launch App on Device

After building, launch the installed app:

```bash
xcrun devicectl device process launch \
  --device 00008150-000154521E08401C \
  com.tron.mobile
```

The output includes the PID of the launched process. Save it for the stop command.

Example output:
```
Launched application with com.tron.mobile on device.
  Process ID: 12345
```

**For beta:** replace `com.tron.mobile` with `com.tron.mobile.beta`.

---

## 4. Build + Install + Launch (Play Button)

The full "press play in Xcode" equivalent — build, install, and launch in one go:

**Prod (default):**
```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme Tron \
    -configuration Prod \
    -destination 'platform=iOS,id=00008150-000154521E08401C' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -30 && \
  xcrun devicectl device process launch \
    --device 00008150-000154521E08401C \
    com.tron.mobile
```

**Beta:**
```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme 'Tron Beta' \
    -configuration Beta \
    -destination 'platform=iOS,id=00008150-000154521E08401C' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -30 && \
  xcrun devicectl device process launch \
    --device 00008150-000154521E08401C \
    com.tron.mobile.beta
```

**On iPad Pro:**
```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme 'Tron Beta' \
    -configuration Beta \
    -destination 'platform=iOS,id=00008142-000A25DA0E47801C' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -30 && \
  xcrun devicectl device process launch \
    --device 00008142-000A25DA0E47801C \
    com.tron.mobile.beta
```

---

## 5. Stop App

Stop a running app on device. Requires the process ID.

**If you have the PID** (from the launch output):
```bash
xcrun devicectl device process terminate \
  --device 00008150-000154521E08401C \
  --pid <PID>
```

**If you don't have the PID** (e.g. app was launched from Xcode GUI or a previous session):
```bash
# Find the PID by searching running processes
xcrun devicectl device info processes \
  --device 00008150-000154521E08401C 2>/dev/null | grep -i tron
```

Then terminate with the discovered PID. There is no bundle-ID-only stop — you always need the PID.

---

## 6. Run on Simulator

Build and run on the iOS Simulator (no physical device needed):

```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild build \
    -project TronMobile.xcodeproj \
    -scheme 'Tron Beta' \
    -configuration Beta \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -20
```

To boot and launch in the simulator:
```bash
# Boot the simulator (if not already running)
xcrun simctl boot 'iPhone 17 Pro' 2>/dev/null

# Install the built app
xcrun simctl install booted \
  packages/ios-app/.build/DerivedData/Build/Products/Beta-iphonesimulator/TronMobile.app

# Launch
xcrun simctl launch booted com.tron.mobile.beta
```

---

## 7. Run Tests

Run the test suite on a simulator:

```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild test \
    -project TronMobile.xcodeproj \
    -scheme Tron \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -30
```

Run a specific test class or method:
```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild test \
    -project TronMobile.xcodeproj \
    -scheme Tron \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:TronMobileTests/SomeTestClass/testMethodName \
    -derivedDataPath .build/DerivedData \
    -quiet 2>&1 | tail -30
```

---

## 8. Clean

### Standard clean (scheme-aware)

```bash
cd /Users/moose/Downloads/projects/tron/packages/ios-app && \
  xcodebuild clean \
    -project TronMobile.xcodeproj \
    -scheme 'Tron Beta' \
    -derivedDataPath .build/DerivedData \
    -quiet
```

### Nuclear clean (all DerivedData)

Removes both CLI and Xcode GUI DerivedData. Next build will be a full rebuild.

```bash
rm -rf /Users/moose/Downloads/projects/tron/packages/ios-app/.build/DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/TronMobile-*
```

---

## 9. Device Logs

Collect recent logs from the device into a `.logarchive` file:

```bash
# Collect last 5 minutes of logs from the device
/usr/bin/log collect \
  --device-udid 00008150-000154521E08401C \
  --last 5m \
  --output /tmp/tron-device-logs.logarchive
```

View the collected logs, filtered to the app:

```bash
/usr/bin/log show /tmp/tron-device-logs.logarchive \
  --predicate 'subsystem == "com.tron.mobile.beta"' \
  --style compact
```

Stream live logs from the **local Mac** (useful when debugging on simulator):

```bash
/usr/bin/log stream \
  --process TronMobile \
  --level debug
```

Note: `log stream` does not support a `--device` flag. For physical device logs, use `log collect --device-udid` and then `log show` as above. Press Ctrl+C to stop streaming.

---

## 10. Utility Commands

```bash
# List all schemes in the project
xcodebuild -list -project packages/ios-app/TronMobile.xcodeproj

# Show build settings (useful for debugging signing, paths, etc.)
xcodebuild -showBuildSettings \
  -project packages/ios-app/TronMobile.xcodeproj \
  -scheme 'Tron Beta' \
  -configuration Beta 2>/dev/null | head -50

# Find the built .app bundle path
find packages/ios-app/.build/DerivedData/Build/Products -name "TronMobile.app" -type d 2>/dev/null

# Check code signing
codesign -dv --verbose=4 \
  "$(find packages/ios-app/.build/DerivedData/Build/Products -name 'TronMobile.app' -type d | head -1)" 2>&1

# Regenerate Xcode project from project.yml (if using XcodeGen)
cd /Users/moose/Downloads/projects/tron/packages/ios-app && xcodegen generate
```

---

## Quick Reference

```bash
# Build + run on iPhone (prod, default)
cd /Users/moose/Downloads/projects/tron/packages/ios-app && xcodebuild build -project TronMobile.xcodeproj -scheme Tron -configuration Prod -destination 'platform=iOS,id=00008150-000154521E08401C' -derivedDataPath .build/DerivedData -quiet 2>&1 | tail -30 && xcrun devicectl device process launch --device 00008150-000154521E08401C com.tron.mobile

# Build + run on iPhone (beta)
cd /Users/moose/Downloads/projects/tron/packages/ios-app && xcodebuild build -project TronMobile.xcodeproj -scheme 'Tron Beta' -configuration Beta -destination 'platform=iOS,id=00008150-000154521E08401C' -derivedDataPath .build/DerivedData -quiet 2>&1 | tail -30 && xcrun devicectl device process launch --device 00008150-000154521E08401C com.tron.mobile.beta

# Build-only check (no device)
cd /Users/moose/Downloads/projects/tron/packages/ios-app && xcodebuild build -project TronMobile.xcodeproj -scheme Tron -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData -quiet 2>&1 | tail -20

# Stop app (need PID from launch output)
xcrun devicectl device process terminate --device 00008150-000154521E08401C --pid <PID>

# Find running app PID
xcrun devicectl device info processes --device 00008150-000154521E08401C 2>/dev/null | grep -i tron

# Clean everything
rm -rf /Users/moose/Downloads/projects/tron/packages/ios-app/.build/DerivedData ~/Library/Developer/Xcode/DerivedData/TronMobile-*

# Collect device logs (last 5 min) then view
/usr/bin/log collect --device-udid 00008150-000154521E08401C --last 5m --output /tmp/tron-device-logs.logarchive
/usr/bin/log show /tmp/tron-device-logs.logarchive --predicate 'subsystem == "com.tron.mobile.beta"' --style compact

# Run tests
cd /Users/moose/Downloads/projects/tron/packages/ios-app && xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/DerivedData -quiet 2>&1 | tail -30
```
