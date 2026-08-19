#!/usr/bin/env bash
# Read-only verification for the installed production Tron Mac app.
# This never changes the app, Login Item, Gateway, or ~/.tron.
set -u

APP="/Applications/Tron.app"
PLIST="$APP/Contents/Library/LaunchAgents/com.tron.server.plist"
PAYLOAD="$APP/Contents/Resources/Gateway/app/dist"
LABEL="com.tron.server"
UID_VALUE="$(id -u)"
failures=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }

if [[ -d "$APP" ]]; then pass "installed app exists: $APP"; else fail "installed app missing: $APP"; fi

if [[ -f "$PLIST" ]]; then
  pass "production LaunchAgent plist exists"
  marker="$(plutil -extract EnvironmentVariables.TRON_GATEWAY_SUPERVISED raw -o - "$PLIST" 2>/dev/null || true)"
  if [[ "$marker" == "1" ]]; then pass "bundled LaunchAgent advertises supervision"; else fail "bundled LaunchAgent lacks TRON_GATEWAY_SUPERVISED=1"; fi
else
  fail "production LaunchAgent plist missing"
fi

for required in \
  "$APP/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron" \
  "$APP/Contents/Resources/Gateway/runtime/node-arm64" \
  "$APP/Contents/Resources/Gateway/app/dist/index.js"; do
  if [[ -e "$required" ]]; then pass "bundle contains ${required#"$APP/"}"; else fail "bundle missing ${required#"$APP/"}"; fi
done

if [[ -d "$PAYLOAD" ]] && grep -R -q 'restart-supervised.v1' "$PAYLOAD" 2>/dev/null; then
  pass "Gateway payload contains restart supervision capability"
else
  fail "Gateway payload does not contain restart supervision capability"
fi
if [[ -d "$PAYLOAD" ]] && grep -R -q 'extensionActivities' "$PAYLOAD" 2>/dev/null; then
  pass "Gateway payload contains structured extension activity projection"
else
  fail "Gateway payload does not contain structured extension activity projection"
fi

MANIFEST="$APP/Contents/Resources/Gateway/manifest.json"
if [[ -s "$MANIFEST" ]] && plutil -p "$MANIFEST" >/dev/null 2>&1; then
  fingerprint="$(plutil -extract payloadFingerprint raw -o - "$MANIFEST" 2>/dev/null || true)"
  if [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]]; then pass "Gateway payload manifest is present ($fingerprint)"; else fail "Gateway payload manifest has no valid fingerprint"; fi
else
  fail "Gateway payload manifest is missing or invalid"
fi

launchctl_output="$(launchctl print "gui/$UID_VALUE/$LABEL" 2>/dev/null || true)"
if [[ -n "$launchctl_output" ]]; then
  pass "LaunchAgent is registered with launchd"
  if grep -q 'state = running' <<<"$launchctl_output"; then pass "LaunchAgent is running"; else fail "LaunchAgent is not running"; fi
  if grep -q 'TRON_GATEWAY_SUPERVISED => 1' <<<"$launchctl_output" || grep -q 'TRON_GATEWAY_SUPERVISED = 1' <<<"$launchctl_output"; then
    pass "running LaunchAgent carries supervision marker"
  else
    fail "running LaunchAgent does not carry supervision marker; re-register the current app"
  fi
  pid="$(awk '/^[[:space:]]*pid =/{print $3; exit}' <<<"$launchctl_output")"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    pass "running Gateway PID: $pid"
    command_line="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if [[ "$command_line" == "$APP/Contents/Library/LoginItems/Tron Agent.app/"* || "$command_line" == *"$APP/Contents/Library/LoginItems/Tron Agent.app/"* ]]; then
      pass "running Gateway executable belongs to installed app"
    else
      fail "running Gateway executable is not from $APP"
    fi
  else
    fail "LaunchAgent has no running PID"
  fi
else
  fail "LaunchAgent is not registered with launchd"
fi

if (( failures > 0 )); then
  printf '\nVerification failed with %s issue(s).\n' "$failures" >&2
  exit 1
fi
printf '\nInstalled Tron Mac Gateway is current, supervised, and running.\n'
