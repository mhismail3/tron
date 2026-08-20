#!/usr/bin/env bash
# Read-only verification for a manually installed Release Tron.app.
# This never changes the app, LaunchAgents, Gateway, or either Tron home.
set -u

APP="${TRON_APP_PATH:-/Applications/Tron.app}"
UID_VALUE="$(id -u)"
failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
regular_file() { [[ -f "$1" && ! -L "$1" ]]; }
regular_dir() { [[ -d "$1" && ! -L "$1" ]]; }
plist_value() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }

[[ -d "$APP" ]] && pass "installed app exists: $APP" || fail "installed app missing: $APP"

# Verify the installed signed helper before using its in-process canonical
# hasher. This keeps verification fast even with a full production dependency
# tree while remaining independent of the mutable updater script.
verify_codesign() {
  local path="$1" description="$2"
  if codesign --verify --deep --strict "$path" >/dev/null 2>&1; then pass "$description deep strict signature"; else fail "$description deep strict signature invalid"; fi
}
verify_codesign "$APP" "outer app"
for helper in "Tron Agent.app" "Tron Agent Dev.app"; do
  verify_codesign "$APP/Contents/Library/LoginItems/$helper" "$helper"
done
HASHER="$APP/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
hash_payload() {
  "$HASHER" --fingerprint "$1"
}

# Resolve each identity independently. A malformed current pointer never
# supplies identity; the bundled payload is only the bounded fallback.
payload_for() {
  local home="$1" channel="$2" bundled="$3" current version manifest fingerprint
  current="$home/gateway/payloads/$channel/current.json"
  if regular_file "$current"; then
    version="$(plist_value version "$current")"
    if [[ "$version" =~ ^[A-Za-z0-9._-]+$ && "$version" != . && "$version" != .. ]]; then
      manifest="$home/gateway/payloads/$channel/versions/$version/manifest.json"
      if regular_file "$manifest"; then
        fingerprint="$(plist_value payloadFingerprint "$manifest")"
        if [[ "$(plist_value schema "$current")" == 1 ]] && [[ "$(plist_value kind "$current")" == tron-gateway-selection ]] \
          && [[ "$(plist_value schema "$manifest")" == 1 ]] && [[ "$(plist_value kind "$manifest")" == tron-gateway-payload ]] \
          && [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] && [[ "$(plist_value channel "$current")" == "$channel" ]] \
          && [[ "$(plist_value channel "$manifest")" == "$channel" ]] \
          && [[ "$(plist_value payloadFingerprint "$current")" == "$fingerprint" ]]; then
          printf '%s\n' "$home/gateway/payloads/$channel/versions/$version"
          return 0
        fi
      fi
    fi
  fi
  printf '%s\n' "$bundled"
}

verify_payload() {
  local label="$1" home="$2" channel="$3" bundled="$4" payload manifest expected actual selected_version
  payload="$(payload_for "$home" "$channel" "$bundled")"
  manifest="$payload/manifest.json"
  if ! regular_file "$manifest"; then fail "$label payload manifest missing"; return; fi
  selected_version=""
  if regular_file "$home/gateway/payloads/$channel/current.json"; then
    selected_version="$(plist_value version "$home/gateway/payloads/$channel/current.json")"
    if [[ -n "$selected_version" ]]; then
      [[ "$(plist_value version "$manifest")" == "$selected_version" ]] \
        && pass "$label selection version matches manifest" \
        || fail "$label selection version does not match selected manifest"
    fi
  fi
  expected="$(plist_value payloadFingerprint "$manifest")"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then fail "$label payload manifest fingerprint invalid"; return; fi
  actual="$(hash_payload "$payload" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] && pass "$label selected payload fingerprint matches" || fail "$label selected payload fingerprint mismatch"
  for architecture in arm64 x64; do
    local runtime="${payload}/runtime/node-${architecture}" expected_arch archs version_output entitlements
    [[ -x "$runtime" ]] && pass "$label Node $architecture runtime executable" || fail "$label Node $architecture runtime missing/non-executable"
    if codesign --verify --deep --strict "$runtime" >/dev/null 2>&1; then
      entitlements="$(codesign -d --entitlements :- "$runtime" 2>/dev/null || true)"
      if [[ "$entitlements" == *'<key>com.apple.security.cs.allow-jit</key>'*'<true/>'* ]]; then
        pass "$label Node $architecture runtime has exact allow-jit=true entitlement"
      else
        fail "$label Node $architecture runtime lacks exact allow-jit=true entitlement"
      fi
    else
      fail "$label Node $architecture runtime signature invalid"
    fi
    expected_arch="$architecture"
    [[ "$architecture" == x64 ]] && expected_arch="x86_64"
    archs="$(lipo -archs "$runtime" 2>/dev/null || true)"
    grep -Eq "(^| )${expected_arch}( |$)" <<<"$archs" && pass "$label Node $architecture runtime architecture $expected_arch" || fail "$label Node $architecture runtime lacks architecture $expected_arch"
    version_output="$("$runtime" --version 2>&1)"
    [[ "$version_output" == v* ]] && pass "$label Node $architecture runtime executes --version" || fail "$label Node $architecture runtime --version failed: $version_output"
  done
  EXPECTED_FINGERPRINT["$label"]="$expected"
  EXPECTED_REVISION["$label"]="$(plist_value sourceRevision "$manifest")"
  EXPECTED_EPOCH["$label"]="$(plist_value runtimeEpoch "$manifest")"
  PAYLOAD_ROOT["$label"]="$payload"
}

declare -A EXPECTED_FINGERPRINT EXPECTED_REVISION EXPECTED_EPOCH PAYLOAD_ROOT
BUNDLED="$APP/Contents/Resources/Gateway"
verify_payload stable "$HOME/.tron" stable "$BUNDLED"
verify_payload dev "$HOME/.tron-dev" dev "$BUNDLED"

check_owner() {
  local label="$1" port="$2" home="$3" helper="$4" channel="$5" expected_home="$6" expected_agent="$7" optional="${8:-false}"
  local plist="$APP/Contents/Library/LaunchAgents/$label.plist" output pid command_line listener host health
  regular_file "$plist" || { fail "$label LaunchAgent plist missing"; return; }
  [[ "$(plist_value Label "$plist")" == "$label" ]] && pass "$label plist label" || fail "$label plist label mismatch"
  [[ "$(plist_value BundleProgram "$plist")" == "Contents/Library/LoginItems/$helper.app/Contents/MacOS/tron" ]] \
    && pass "$label exact helper path" || fail "$label helper path mismatch"
  [[ "$(plist_value EnvironmentVariables.TRON_GATEWAY_SUPERVISED "$plist")" == 1 ]] && pass "$label supervision marker" || fail "$label supervision marker"
  [[ "$(plist_value EnvironmentVariables.TRON_GATEWAY_CHANNEL "$plist")" == "$channel" ]] && pass "$label channel marker" || fail "$label channel marker"
  if [[ "$channel" == dev ]]; then
    [[ "$(plist_value EnvironmentVariables.TRON_HOME_NAME "$plist")" == "$expected_home" ]] && pass "$label home marker" || fail "$label home marker"
    [[ "$(plist_value EnvironmentVariables.TRON_AGENT_DIR_NAME "$plist")" == "$expected_agent" ]] && pass "$label agent-dir marker" || fail "$label agent-dir marker"
  else
    [[ -z "$(plist_value EnvironmentVariables.TRON_HOME_NAME "$plist")" ]] && pass "$label stable home marker absent" || fail "$label has Preview home marker"
    [[ -z "$(plist_value EnvironmentVariables.TRON_AGENT_DIR_NAME "$plist")" ]] && pass "$label stable agent-dir marker absent" || fail "$label has Preview agent-dir marker"
  fi
  output="$(launchctl print "gui/$UID_VALUE/$label" 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    [[ "$optional" == true ]] && { pass "$label is not registered (optional Preview)"; return; }
    fail "$label is not registered with launchd"; return
  fi
  pass "$label is registered with launchd"
  grep -q 'state = running' <<<"$output" && pass "$label is running" || fail "$label is not running"
  pid="$(awk '/^[[:space:]]*pid =/{print $3; exit}' <<<"$output")"
  [[ "$pid" =~ ^[0-9]+$ ]] || { fail "$label has no running PID"; return; }
  command_line="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  [[ "$command_line" == "$APP/Contents/Library/LoginItems/$helper.app/Contents/MacOS/tron"* ]] \
    && pass "$label PID uses exact installed helper" || fail "$label PID helper path mismatch"
  [[ "$output" == *"TRON_GATEWAY_SUPERVISED => 1"* || "$output" == *"TRON_GATEWAY_SUPERVISED = 1"* ]] || fail "$label runtime supervision marker missing"
  [[ "$output" == *"TRON_GATEWAY_CHANNEL => $channel"* || "$output" == *"TRON_GATEWAY_CHANNEL = $channel"* ]] || fail "$label runtime channel marker missing"
  if [[ "$channel" == dev ]]; then
    [[ "$output" == *"TRON_HOME_NAME => $expected_home"* || "$output" == *"TRON_HOME_NAME = $expected_home"* ]] || fail "$label runtime home marker missing"
    [[ "$output" == *"TRON_AGENT_DIR_NAME => $expected_agent"* || "$output" == *"TRON_AGENT_DIR_NAME = $expected_agent"* ]] || fail "$label runtime agent-dir marker missing"
  else
    [[ "$output" != *TRON_HOME_NAME* ]] || fail "$label runtime has Preview home marker"
    [[ "$output" != *TRON_AGENT_DIR_NAME* ]] || fail "$label runtime has Preview agent-dir marker"
  fi
  listener="$(lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9; exit}')"
  [[ -n "$listener" ]] || { fail "$label has no listening socket on port $port"; return; }
  host="${listener%:$port}"; host="${host#TCP }"; host="${host#[}"; host="${host%]}"
  [[ "$host" == '*' || "$host" == '0.0.0.0' || "$host" == '::' ]] && host=127.0.0.1
  local url_host="$host"
  [[ "$url_host" == *:* ]] && url_host="[$url_host]"
  health="$(curl --silent --show-error --max-time 3 "http://$url_host:$port/health" 2>/dev/null || true)"
  HEALTH="$health" FINGERPRINT="${EXPECTED_FINGERPRINT[$channel]:-}" REVISION="${EXPECTED_REVISION[$channel]:-}" EPOCH="${EXPECTED_EPOCH[$channel]:-}" python3 - <<'PY'
import json, os, sys
try:
    value=json.loads(os.environ["HEALTH"])
    ok=value.get("status")=="ok" and value.get("buildFingerprint")==os.environ["FINGERPRINT"] \
        and value.get("sourceRevision")==os.environ["REVISION"] and value.get("runtimeEpoch")==os.environ["EPOCH"]
except Exception: ok=False
sys.exit(0 if ok else 1)
PY
  [[ $? -eq 0 ]] && pass "$label health identity matches selected payload on $host" || fail "$label health probe/identity failed on listening host $host"
}

check_owner com.tron.server 9847 "$HOME/.tron" "Tron Agent" stable "" ""
check_owner com.tron.server.dev 9848 "$HOME/.tron-dev" "Tron Agent Dev" dev .tron-dev agent-dev true

if (( failures > 0 )); then
  printf '\nVerification failed with %s issue(s).\n' "$failures" >&2
  exit 1
fi
printf '\nInstalled Release Tron.app owns the verified stable Gateway and Preview registration.\n'
