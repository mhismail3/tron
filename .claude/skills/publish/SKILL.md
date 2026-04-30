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
- **Distribution Identity**: the installed `Apple Distribution` certificate for team `MYGKXH6TY4`
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
  CODE_SIGN_IDENTITY="Apple Distribution" \
  | tail -1

# 3. Create IPA manually (bypasses Xcode 26 exportArchive rsync bug)
WORK_DIR=".build/ipa_work"
mkdir -p "$WORK_DIR/Payload"
/bin/cp -Rf .build/TronMobile.xcarchive/Products/Applications/TronMobile.app "$WORK_DIR/Payload/"

# 4. Embed App Store distribution profiles.
# Prefer profiles Xcode embedded into the archive; fall back to Xcode's profile cache.
TEAM_ID="MYGKXH6TY4"
PROFILE_DIRS=(
  "$HOME/Library/MobileDevice/Provisioning Profiles"
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)
APP_PAYLOAD="$WORK_DIR/Payload/TronMobile.app"
APPEX_PAYLOAD="$APP_PAYLOAD/PlugIns/TronShareExtension.appex"

profile_matches_store_bundle() {
  local bundle_id="$1" profile="$2"
  local tmpfile application_id provisions_all
  tmpfile="$(mktemp)"
  if ! security cms -D -i "$profile" -o "$tmpfile" 2>/dev/null; then
    rm -f "$tmpfile"
    return 1
  fi
  application_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$tmpfile" 2>/dev/null || true)"
  provisions_all="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$tmpfile" 2>/dev/null || true)"
  if [[ "$application_id" == "$TEAM_ID.$bundle_id" ]] \
    && [[ "$provisions_all" != "true" ]] \
    && ! /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$tmpfile" >/dev/null 2>&1; then
    rm -f "$tmpfile"
    return 0
  fi
  rm -f "$tmpfile"
  return 1
}

find_store_profile() {
  local bundle_id="$1" profile_dir profile
  shopt -s nullglob
  for profile_dir in "${PROFILE_DIRS[@]}"; do
    for profile in "$profile_dir"/*.mobileprovision; do
      if profile_matches_store_bundle "$bundle_id" "$profile"; then
        echo "$profile"
        return 0
      fi
    done
  done
  return 1
}

resolve_store_profile() {
  local bundle_id="$1" embedded_profile="$2"
  if [[ -f "$embedded_profile" ]] && profile_matches_store_bundle "$bundle_id" "$embedded_profile"; then
    echo "$embedded_profile"
    return 0
  fi
  find_store_profile "$bundle_id"
}

APP_PROFILE="$(resolve_store_profile "com.tron.mobile" "$APP_PAYLOAD/embedded.mobileprovision")"
SHARE_PROFILE="$(resolve_store_profile "com.tron.mobile.ShareExtension" "$APPEX_PAYLOAD/embedded.mobileprovision")"
test -n "$APP_PROFILE" && test -n "$SHARE_PROFILE"

if [[ "$APP_PROFILE" != "$APP_PAYLOAD/embedded.mobileprovision" ]]; then
  /bin/cp -f "$APP_PROFILE" "$APP_PAYLOAD/embedded.mobileprovision"
fi
if [[ "$SHARE_PROFILE" != "$APPEX_PAYLOAD/embedded.mobileprovision" ]]; then
  /bin/cp -f "$SHARE_PROFILE" "$APPEX_PAYLOAD/embedded.mobileprovision"
fi

# 5. Re-sign using the CHECKED-IN entitlements files (NOT profile entitlements)
#    Profile entitlements contain every granted capability and cause ITMS rejections.
DIST_IDENTITY="Apple Distribution"

# Extension first, then main app
/usr/bin/codesign --force --sign "$DIST_IDENTITY" \
  --entitlements ShareExtension/ShareExtensionProd.entitlements \
  --timestamp=none \
  "$APPEX_PAYLOAD"

/usr/bin/codesign --force --sign "$DIST_IDENTITY" \
  --entitlements TronMobileProd.entitlements \
  --timestamp=none \
  "$APP_PAYLOAD"

/usr/bin/codesign -vvv "$APP_PAYLOAD" 2>&1 | tail -2

# 6. Zip and upload
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
| Prod | `TronMobileProd.entitlements` | `ShareExtension/ShareExtensionProd.entitlements` |
| Beta | `TronMobileBeta.entitlements` | `ShareExtension/ShareExtension.entitlements` |

**CRITICAL**: Always re-sign using these files. Never extract entitlements from provisioning profiles — profiles contain every capability Apple has granted (NFC, HealthKit, push-to-talk, etc.) which causes ITMS rejections for capabilities the app doesn't use.

These files must include `application-identifier` (`MYGKXH6TY4.<bundle-id>`) and `com.apple.developer.team-identifier` (`MYGKXH6TY4`) — codesign does not inject these automatically during manual re-signing.

## Known Issues

- **Xcode 26 exportArchive bug**: `xcodebuild -exportArchive` fails with `rsync: --extended-attributes: unknown option` because macOS ships `openrsync` at `/usr/bin/rsync` which doesn't support the flag. Workaround: manually create the IPA as shown above.
- **Share extension bundle ID**: Uses capital S (`ShareExtension`), not lowercase. Profile searches must match exactly.
- **Build number lives in project.yml**: Not in `Base.xcconfig`. The pbxproj settings override xcconfig. Always bump in `project.yml` then run `xcodegen generate`.
