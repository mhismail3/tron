#!/usr/bin/env bash
# Deterministic fixture test for signed-artifact metadata validation.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tron-ios-artifact.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
app="$tmp/TronMobile.app"
ext="$app/PlugIns/com.tron.mobile.ShareExtension.appex"
mkdir -p "$ext/_CodeSignature" "$app/_CodeSignature"
cat >"$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tron.mobile</string>
<key>TRONBuildRole</key><string>local-device</string>
<key>TRONConfiguration</key><string>LocalDevice</string>
<key>TRONPushRoute</key><string>production-sandbox</string>
<key>TRONAPNsEnvironment</key><string>development</string>
<key>TRONAppAttestEnvironment</key><string>development</string>
<key>TRONPrivateBlurEnabled</key><string>YES</string>
<key>TRONGatewayProtocolVersion</key><string>4</string>
<key>TRONGatewayMinProtocolVersion</key><string>4</string>
</dict></plist>
PLIST
cat >"$ext/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tron.mobile.ShareExtension</string>
</dict></plist>
PLIST
touch "$app/_CodeSignature/CodeResources" "$ext/_CodeSignature/CodeResources"
touch "$app/embedded.mobileprovision" "$ext/embedded.mobileprovision"
fakebin="$tmp/bin"
mkdir -p "$fakebin"
cat >"$fakebin/codesign" <<'SH'
#!/usr/bin/env bash
set -eu
path="${@: -1}"
team="${CODESIGN_TEAM:-MYGKXH6TY4}"
printf '%s\n' "$*" >> "${CODESIGN_LOG:?}"
if [[ "${CODESIGN_FAIL:-0}" == "1" && "$*" == *"--verify"* ]]; then exit 1; fi
if [[ "$*" == *"-dvv"* ]]; then
  [[ "$path" == *.appex ]] && echo 'Identifier=com.tron.mobile.ShareExtension' >&2 || echo 'Identifier=com.tron.mobile' >&2
else
  if [[ "$path" == *.appex ]]; then
    cat >&2 <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>application-identifier</key><string>$team.com.tron.mobile.ShareExtension</string><key>com.apple.developer.team-identifier</key><string>$team</string><key>com.apple.security.application-groups</key><array><string>group.com.tron.shared</string></array><key>get-task-allow</key><true/></dict></plist>
PLIST
  else
    cat >&2 <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>aps-environment</key><string>development</string><key>com.apple.developer.devicecheck.appattest-environment</key><string>development</string><key>application-identifier</key><string>$team.com.tron.mobile</string><key>com.apple.developer.team-identifier</key><string>$team</string><key>com.apple.security.application-groups</key><array><string>group.com.tron.shared</string></array><key>get-task-allow</key><true/></dict></plist>
PLIST
  fi
fi
SH
chmod +x "$fakebin/codesign"
cat >"$fakebin/security" <<'SH'
#!/usr/bin/env bash
set -eu
path="${@: -1}"
team="${PROFILE_TEAM:-MYGKXH6TY4}"
if [[ "$path" == *.appex/* ]]; then
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>ProvisionedDevices</key><array><string>fixture-device</string></array><key>Entitlements</key><dict><key>application-identifier</key><string>$team.com.tron.mobile.ShareExtension</string><key>com.apple.developer.team-identifier</key><string>$team</string><key>com.apple.security.application-groups</key><array><string>group.com.tron.shared</string></array><key>get-task-allow</key><true/></dict></dict></plist>
PLIST
else
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>ProvisionedDevices</key><array><string>fixture-device</string></array><key>Entitlements</key><dict><key>aps-environment</key><string>${PROFILE_APNS:-development}</string><key>application-identifier</key><string>$team.com.tron.mobile</string><key>com.apple.developer.team-identifier</key><string>$team</string><key>com.apple.security.application-groups</key><array><string>group.com.tron.shared</string></array><key>get-task-allow</key><true/></dict></dict></plist>
PLIST
fi
SH
chmod +x "$fakebin/security"
: >"$tmp/codesign.log"
PATH="$fakebin:$PATH" CODESIGN_LOG="$tmp/codesign.log" \
  python3 "$root/scripts/validate-ios-artifact.py" "$app" --configuration LocalDevice --require-profile
grep -c -- '--verify' "$tmp/codesign.log" | grep -Fxq 2
python3 - "$app/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle: document = plistlib.load(handle)
document["TRONGatewayProtocolVersion"] = "3"
with open(sys.argv[1], "wb") as handle: plistlib.dump(document, handle)
PY
if PATH="$fakebin:$PATH" CODESIGN_LOG="$tmp/codesign.log" \
  python3 "$root/scripts/validate-ios-artifact.py" "$app" --configuration LocalDevice >/dev/null 2>&1; then
  echo "validator accepted an incompatible Gateway protocol" >&2
  exit 1
fi
python3 - "$app/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle: document = plistlib.load(handle)
document["TRONGatewayProtocolVersion"] = "4"
with open(sys.argv[1], "wb") as handle: plistlib.dump(document, handle)
PY
if PATH="$fakebin:$PATH" CODESIGN_LOG="$tmp/codesign.log" CODESIGN_FAIL=1 \
  python3 "$root/scripts/validate-ios-artifact.py" "$app" --configuration LocalDevice >/dev/null 2>&1; then
  echo "validator accepted a cryptographically invalid signature" >&2
  exit 1
fi
if PATH="$fakebin:$PATH" CODESIGN_LOG="$tmp/codesign.log" CODESIGN_TEAM=WRONGTEAM \
  python3 "$root/scripts/validate-ios-artifact.py" "$app" --configuration LocalDevice --require-profile >/dev/null 2>&1; then
  echo "validator accepted a non-canonical signed team" >&2
  exit 1
fi
if PATH="$fakebin:$PATH" CODESIGN_LOG="$tmp/codesign.log" PROFILE_APNS=production \
  python3 "$root/scripts/validate-ios-artifact.py" "$app" --configuration LocalDevice --require-profile >/dev/null 2>&1; then
  echo "validator accepted a provisioning profile with the wrong APNs environment" >&2
  exit 1
fi
mkdir -p "$tmp/outside.appex"
if PATH="$fakebin:$PATH" CODESIGN_LOG="$tmp/codesign.log" \
  python3 "$root/scripts/validate-ios-artifact.py" "$app" --configuration LocalDevice --extension "$tmp/outside.appex" >/dev/null 2>&1; then
  echo "validator accepted an extension outside PlugIns" >&2
  exit 1
fi
python3 - "$app/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle: document = plistlib.load(handle)
document["TRONPushRoute"] = "production"
with open(sys.argv[1], "wb") as handle: plistlib.dump(document, handle)
PY
if PATH="$fakebin:$PATH" python3 "$root/scripts/validate-ios-artifact.py" "$app" --configuration LocalDevice >/dev/null 2>&1; then
  echo "validator accepted a mismatched route" >&2
  exit 1
fi
echo "iOS artifact validator fixture tests passed"
