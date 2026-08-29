#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
package_root="$(cd "$script_dir/.." && pwd)"
verifier="$script_dir/verify-archive-privacy.sh"
manifest="$package_root/Sources/PrivacyInfo.xcprivacy"
root="$(mktemp -d "${TMPDIR:-/tmp}/tron-privacy-archive.XXXXXX")"
trap 'rm -rf "$root"' EXIT

fakebin="$root/bin"
mkdir -p "$fakebin"
cat >"$fakebin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
if [[ "$*" == *"--verify"* ]]; then
  exit 0
fi
if [[ "$*" == *"-dvv"* ]]; then
  if [[ "$path" == *.appex ]]; then
    echo 'Identifier=com.tron.mobile.ShareExtension' >&2
  else
    echo 'Identifier=com.tron.mobile' >&2
  fi
  exit 0
fi
if [[ "$path" == *.appex ]]; then
  cat >&2 <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>application-identifier</key><string>MYGKXH6TY4.com.tron.mobile.ShareExtension</string><key>com.apple.developer.team-identifier</key><string>MYGKXH6TY4</string><key>com.apple.security.application-groups</key><array><string>group.com.tron.shared</string></array><key>get-task-allow</key><false/></dict></plist>
PLIST
else
  cat >&2 <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>aps-environment</key><string>production</string><key>com.apple.developer.devicecheck.appattest-environment</key><string>production</string><key>application-identifier</key><string>MYGKXH6TY4.com.tron.mobile</string><key>com.apple.developer.team-identifier</key><string>MYGKXH6TY4</string><key>com.apple.security.application-groups</key><array><string>group.com.tron.shared</string></array><key>get-task-allow</key><false/></dict></plist>
PLIST
fi
SH
chmod +x "$fakebin/codesign"

cat >"$fakebin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
if [[ "$path" == *.appex/* ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Entitlements</key><dict><key>application-identifier</key><string>MYGKXH6TY4.com.tron.mobile.ShareExtension</string><key>com.apple.developer.team-identifier</key><string>MYGKXH6TY4</string><key>com.apple.security.application-groups</key><array><string>group.com.tron.shared</string></array><key>get-task-allow</key><false/></dict></dict></plist>
PLIST
else
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Entitlements</key><dict><key>aps-environment</key><string>production</string><key>application-identifier</key><string>MYGKXH6TY4.com.tron.mobile</string><key>com.apple.developer.team-identifier</key><string>MYGKXH6TY4</string><key>com.apple.security.application-groups</key><array><string>group.com.tron.shared</string></array><key>get-task-allow</key><false/></dict></dict></plist>
PLIST
fi
SH
chmod +x "$fakebin/security"
export PATH="$fakebin:$PATH"

fixture() {
  local name="$1"
  local archive="$root/$name.xcarchive"
  local app="$archive/Products/Applications/TronMobile.app"
  local extension="$app/PlugIns/TronShareExtension.appex"
  mkdir -p "$app/_CodeSignature" "$extension/_CodeSignature"
  cp "$manifest" "$app/PrivacyInfo.xcprivacy"
  cp "$manifest" "$extension/PrivacyInfo.xcprivacy"
  touch "$app/_CodeSignature/CodeResources" "$extension/_CodeSignature/CodeResources"
  touch "$app/embedded.mobileprovision" "$extension/embedded.mobileprovision"
  cat >"$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tron.mobile</string>
<key>TRONBuildRole</key><string>release</string>
<key>TRONConfiguration</key><string>Release</string>
<key>TRONPushRoute</key><string>production</string>
<key>TRONAPNsEnvironment</key><string>production</string>
<key>TRONAppAttestEnvironment</key><string>production</string>
<key>TRONPrivateBlurEnabled</key><string>NO</string>
</dict></plist>
PLIST
  cat >"$extension/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tron.mobile.ShareExtension</string>
</dict></plist>
PLIST
  printf '%s\n' "$archive"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$($verifier "$@" 2>&1)"; then
    echo "expected verifier failure containing: $expected" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "unexpected verifier failure: $output" >&2
    exit 1
  fi
}

valid="$(fixture valid)"
"$verifier" "$valid" >/dev/null

missing_app="$(fixture missing-app)"
rm "$missing_app/Products/Applications/TronMobile.app/PrivacyInfo.xcprivacy"
expect_failure "missing privacy manifest" "$missing_app"

duplicate_app="$(fixture duplicate-app)"
cp -R "$duplicate_app/Products/Applications/TronMobile.app" \
  "$duplicate_app/Products/Applications/Other.app"
expect_failure "expected exactly one app" "$duplicate_app"

duplicate_extension="$(fixture duplicate-extension)"
cp -R "$duplicate_extension/Products/Applications/TronMobile.app/PlugIns/TronShareExtension.appex" \
  "$duplicate_extension/Products/Applications/TronMobile.app/PlugIns/Other.appex"
expect_failure "expected exactly one extension" "$duplicate_extension"

malformed="$(fixture malformed)"
printf 'not a plist\n' > "$malformed/Products/Applications/TronMobile.app/PlugIns/TronShareExtension.appex/PrivacyInfo.xcprivacy"
expect_failure "PrivacyInfo.xcprivacy:" "$malformed"

echo "archive privacy and signing verifier fixtures passed"
