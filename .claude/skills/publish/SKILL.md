---
name: publish
description: Build, upload, and manage TronMobile on TestFlight and App Store Connect using the asc CLI
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Grep, Glob
argument-hint: [build|status|testers|bump|submit]
tags:
  - ios
  - deploy
---

# /publish — TestFlight Lifecycle Management

Manage the full TestFlight lifecycle for TronMobile: build, upload, version management, tester distribution, and submission.

## Project Constants

- **App ID**: `6761511764`
- **Bundle ID**: `com.tron.mobile`
- **Share Extension Bundle ID**: `com.tron.mobile.ShareExtension` (capital S)
- **Team ID**: `MYGKXH6TY4`
- **Distribution Identity**: `Apple Distribution: MOHSIN H ISMAIL (MYGKXH6TY4)`
- **Scheme**: `Tron` (prod), `Tron Beta` (beta)
- **Archive Configuration**: `Prod`
- **Project root**: `packages/ios-app/`
- **Build output**: `packages/ios-app/.build/` (gitignored)
- **Version source of truth**: `packages/ios-app/project.yml` (lines with `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION`)

## Subcommands

### `/publish build` — Archive, Export, Upload

**IMPORTANT: Always run `/publish bump` first to increment the build number.**

Run from `packages/ios-app/`:

```bash
cd packages/ios-app

# 1. Clean
rm -rf .build/ipa_work .build/TronMobile.ipa .build/TronMobile.xcarchive

# 2. Archive
xcodebuild archive \
  -scheme Tron \
  -configuration Prod \
  -archivePath .build/TronMobile.xcarchive \
  -destination "generic/platform=iOS" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  | tail -1

# 3. Find distribution provisioning profiles
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
APP_PROFILE="" SHARE_PROFILE=""
for p in "$PROFILE_DIR"/*.mobileprovision; do
  tmpfile=$(mktemp)
  security cms -D -i "$p" -o "$tmpfile" 2>/dev/null
  if grep -q "Store Provisioning Profile" "$tmpfile"; then
    if grep -q "com.tron.mobile<" "$tmpfile"; then APP_PROFILE="$p"; fi
    if grep -q "com.tron.mobile.ShareExtension<" "$tmpfile"; then SHARE_PROFILE="$p"; fi
  fi
  rm -f "$tmpfile" 2>/dev/null
done
# Verify both were found before continuing

# 4. Create IPA manually (bypasses Xcode 26 exportArchive rsync bug)
WORK_DIR=".build/ipa_work"
mkdir -p "$WORK_DIR/Payload"
/bin/cp -Rf .build/TronMobile.xcarchive/Products/Applications/TronMobile.app "$WORK_DIR/Payload/"

# 5. Embed distribution profiles
/bin/cp -f "$APP_PROFILE" "$WORK_DIR/Payload/TronMobile.app/embedded.mobileprovision"
/bin/cp -f "$SHARE_PROFILE" "$WORK_DIR/Payload/TronMobile.app/PlugIns/TronShareExtension.appex/embedded.mobileprovision"

# 6. Re-sign using the CHECKED-IN entitlements files (NOT profile entitlements)
#    Profile entitlements contain every granted capability and cause ITMS rejections.
DIST_IDENTITY="Apple Distribution: MOHSIN H ISMAIL (MYGKXH6TY4)"

# Extension first, then main app
/usr/bin/codesign --force --sign "$DIST_IDENTITY" \
  --entitlements ShareExtension/ShareExtension.entitlements \
  --timestamp=none \
  "$WORK_DIR/Payload/TronMobile.app/PlugIns/TronShareExtension.appex"

/usr/bin/codesign --force --sign "$DIST_IDENTITY" \
  --entitlements TronMobileProd.entitlements \
  --timestamp=none \
  "$WORK_DIR/Payload/TronMobile.app"

/usr/bin/codesign -vvv "$WORK_DIR/Payload/TronMobile.app" 2>&1 | tail -2

# 7. Zip and upload
(cd "$WORK_DIR" && zip -qr "../TronMobile.ipa" Payload/)
asc builds upload --app 6761511764 --ipa .build/TronMobile.ipa
```

**If archive fails** with a signing error: open the project in Xcode to let it resolve signing.

**If upload fails** with "Invalid Provisioning Profile" for the share extension:
- Open project in Xcode, select the **TronShareExtension** target
- Ensure automatic signing is enabled, then **Product > Archive** once to generate the store profile
- Re-run `/publish build`

### `/publish status` — Check Build Processing

```bash
asc builds list --app 6761511764 --limit 5 --output table
```

Build states: `PROCESSING` → `VALID` (ready) or `INVALID` (error).

### `/publish testers` — Manage Beta Groups & Testers

```bash
# List groups
asc testflight groups list --app 6761511764 --output table

# Create a group
asc testflight groups create --app 6761511764 --name "Beta Testers"

# Add a tester
asc testflight testers add --app 6761511764 --email "user@example.com" \
  --first-name "First" --last-name "Last" --group "Beta Testers"

# List testers
asc testflight testers list --app 6761511764 --output table
```

### `/publish bump` — Increment Version Numbers

Version numbers live in `project.yml` (NOT Base.xcconfig — pbxproj overrides xcconfig).

```bash
grep -E 'CURRENT_PROJECT_VERSION|MARKETING_VERSION' project.yml
```

**Bump build number** (required before each upload):
1. Use the Edit tool to increment `CURRENT_PROJECT_VERSION` in `project.yml` (appears twice — main app and share extension, both must match)
2. Run `xcodegen generate` to regenerate the pbxproj

**Bump marketing version** (new release like 1.0.0 → 1.1.0):
1. Ask the user for the new version string
2. Update `MARKETING_VERSION` in `project.yml` (appears twice)
3. Run `xcodegen generate`

### `/publish submit` — Submit for Review

```bash
# Submit for external beta review
asc testflight submissions create --app 6761511764 --build "<build_number>"

# Submit for App Store review
asc appstore submissions create --app 6761511764
```

The first external TestFlight build triggers Apple review (~24-48 hours). Subsequent builds to the same group typically skip re-review.

## Entitlements Files

The project has checked-in entitlements files per configuration:

| Config | Main App | Share Extension |
|---|---|---|
| Prod | `TronMobileProd.entitlements` | `ShareExtension/ShareExtension.entitlements` |
| Beta | `TronMobileBeta.entitlements` | `ShareExtension/ShareExtension.entitlements` |

**CRITICAL**: Always re-sign using these files. Never extract entitlements from provisioning profiles — profiles contain every capability Apple has granted (NFC, HealthKit, push-to-talk, etc.) which causes ITMS rejections for capabilities the app doesn't use.

These files must include `application-identifier` (`MYGKXH6TY4.<bundle-id>`) and `com.apple.developer.team-identifier` (`MYGKXH6TY4`) — codesign does not inject these automatically during manual re-signing.

## Known Issues

- **Xcode 26 exportArchive bug**: `xcodebuild -exportArchive` fails with `rsync: --extended-attributes: unknown option` because macOS ships `openrsync` at `/usr/bin/rsync` which doesn't support the flag. Workaround: manually create the IPA as shown above.
- **Share extension bundle ID**: Uses capital S (`ShareExtension`), not lowercase. Profile searches must match exactly.
- **Build number lives in project.yml**: Not in `Base.xcconfig`. The pbxproj settings override xcconfig. Always bump in `project.yml` then run `xcodegen generate`.
