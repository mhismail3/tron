#!/usr/bin/env bash
# Read-only verification for a manually installed Release Tron.app.
# This never changes the app, LaunchAgents, Gateway, or either Tron home.
set -u

APP="${TRON_APP_PATH:-/Applications/Tron.app}"
UID_VALUE="$(id -u)"
HOST_ARCH="$(uname -m)"
failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
regular_file() { [[ -f "$1" && ! -L "$1" ]]; }
regular_dir() { [[ -d "$1" && ! -L "$1" ]]; }
plist_value() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }
plist_json() { plutil -extract "$1" json -o - "$2" 2>/dev/null || true; }

[[ -d "$APP" ]] && pass "installed app exists: $APP" || fail "installed app missing: $APP"

# Verify the installed signed helper before using its in-process canonical
# hasher. This keeps verification fast even with a full production dependency
# tree while remaining independent of the mutable updater script.
verify_codesign() {
  local path="$1" description="$2"
  if codesign --verify --deep --strict "$path" >/dev/null 2>&1; then pass "$description deep strict signature"; else fail "$description deep strict signature invalid"; fi
}
verify_codesign "$APP" "outer app"
verify_codesign "$APP/Contents/Library/LoginItems/Tron Agent.app" "Tron Agent.app"
[[ ! -e "$APP/Contents/Library/LoginItems/Tron Agent Dev.app" ]] \
  && pass "Release app contains no Debug Login Item" \
  || fail "Release app unexpectedly contains a Debug Login Item"
[[ ! -e "$APP/Contents/Library/LaunchAgents/com.tron.server.dev.plist" ]] \
  && pass "Release app contains no Debug LaunchAgent plist" \
  || fail "Release app unexpectedly contains a Debug LaunchAgent plist"
HASHER="$APP/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
hash_payload() {
  "$HASHER" --fingerprint "$1"
}

# Resolve each identity independently. A malformed current pointer never
# supplies identity; the bundled payload is only the bounded fallback.
payload_for() {
  local home="$1" channel="$2" bundled="$3" current version manifest fingerprint actual
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
          actual="$(hash_payload "$home/gateway/payloads/$channel/versions/$version" 2>/dev/null || true)"
          if [[ "$actual" == "$fingerprint" ]]; then
            printf '%s\n' "$home/gateway/payloads/$channel/versions/$version"
            return 0
          fi
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
  local pi_cli="${payload}/app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
  [[ -f "$pi_cli" && ! -L "$pi_cli" && -x "$pi_cli" ]] && pass "$label bundled Pi CLI executable" || fail "$label bundled Pi CLI missing/substituted"
  for architecture in arm64 x64; do
    local runtime="${payload}/runtime/node-${architecture}" alias="${payload}/runtime/bin-${architecture}/node" pi_alias="${payload}/runtime/bin-${architecture}/pi" expected_arch archs version_output entitlements native_arch
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
    # A payload contains both runtimes so the same app can be copied between
    # Intel and Apple-silicon Macs.  Do not execute the foreign binary during
    # verification: Rosetta may be absent, and Node's JIT entitlement is not
    # reliable when a CLI is launched through translation.  The signed Mach-O
    # and exact architecture checks above are the portable validation for that
    # runtime; execute only the host-native one.
    native_arch="$HOST_ARCH"
    [[ "$native_arch" == x86_64 ]] && native_arch=x64
    if [[ "$architecture" == "$native_arch" ]]; then
      version_output="$("$runtime" --version 2>/dev/null | head -n 1 || true)"
      [[ "$version_output" == v* ]] && pass "$label Node $architecture runtime executes --version" || fail "$label Node $architecture runtime --version failed"
    else
      pass "$label Node $architecture runtime is cross-architecture; execution deferred"
    fi
    [[ -L "$alias" && "$(readlink "$alias")" == "../node-$architecture" \
        && "$(realpath "$alias")" == "$(realpath "$runtime")" && -x "$alias" ]] \
      && pass "$label Node $architecture command alias resolves to the signed runtime" \
      || fail "$label Node $architecture command alias is invalid"
    if [[ "$architecture" == "$native_arch" ]]; then
      [[ "$(PATH="$(dirname "$alias"):/usr/bin:/bin:/usr/sbin:/sbin" node --version 2>/dev/null | head -n 1 || true)" == "$version_output" ]] \
        && pass "$label Node $architecture command executes through a launchd-style PATH" \
        || fail "$label Node $architecture command failed through a launchd-style PATH"
    else
      pass "$label Node $architecture command alias is cross-architecture; execution deferred"
    fi
    [[ -L "$pi_alias" && "$(readlink "$pi_alias")" == "../../app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js" \
        && "$(realpath "$pi_alias")" == "$(realpath "$pi_cli")" && -x "$pi_alias" ]] \
      && pass "$label Pi $architecture command alias resolves to the bundled CLI" \
      || fail "$label Pi $architecture command alias is invalid"
    if [[ "$architecture" == "$native_arch" ]]; then
      PATH="$(dirname "$pi_alias"):/usr/bin:/bin:/usr/sbin:/sbin" pi --version >/dev/null 2>&1 \
        && pass "$label Pi $architecture command executes through a launchd-style PATH" \
        || fail "$label Pi $architecture command failed through a launchd-style PATH"
    else
      pass "$label Pi $architecture command alias is cross-architecture; execution deferred"
    fi
  done
  case "$label" in
    stable)
      STABLE_FINGERPRINT="$expected"
      STABLE_REVISION="$(plist_value sourceRevision "$manifest")"
      STABLE_EPOCH="$(plist_value runtimeEpoch "$manifest")"
      STABLE_PAYLOAD_ROOT="$payload"
      ;;
    dev)
      DEV_FINGERPRINT="$expected"
      DEV_REVISION="$(plist_value sourceRevision "$manifest")"
      DEV_EPOCH="$(plist_value runtimeEpoch "$manifest")"
      DEV_PAYLOAD_ROOT="$payload"
      ;;
  esac
}

STABLE_FINGERPRINT="" STABLE_REVISION="" STABLE_EPOCH="" STABLE_PAYLOAD_ROOT=""
DEV_FINGERPRINT="" DEV_REVISION="" DEV_EPOCH="" DEV_PAYLOAD_ROOT=""
BUNDLED="$APP/Contents/Resources/Gateway"
verify_payload stable "$HOME/.tron" stable "$BUNDLED"
if [[ -n "$STABLE_PAYLOAD_ROOT" ]] \
  && cmp -s "$STABLE_PAYLOAD_ROOT/app/PushService.xcconfig" "$BUNDLED/app/PushService.xcconfig"; then
  pass "stable selected payload push origin matches installed product"
else
  fail "stable selected payload push origin differs from installed product"
fi

authenticated_system_info() {
  local host="$1" port="$2" home="$3" payload_root="$4" token node_runtime url_host
  token="$(plist_value bearerToken "$home/gateway/local-auth.json")"
  [[ -n "$token" ]] || return 1
  node_runtime="$payload_root/runtime/node-arm64"
  [[ "$(uname -m)" == x86_64 ]] && node_runtime="$payload_root/runtime/node-x64"
  url_host="$host"; [[ "$url_host" == *:* ]] && url_host="[$url_host]"
  NODE_PATH="$payload_root/app/node_modules" VERIFY_URL="ws://$url_host:$port/v1/socket" VERIFY_TOKEN="$token" "$node_runtime" <<'NODE' 2>/dev/null
const WebSocket = require("ws");
const ws = new WebSocket(process.env.VERIFY_URL, { headers: { authorization: `Bearer ${process.env.VERIFY_TOKEN}` }, perMessageDeflate: false });
const timer = setTimeout(() => { ws.terminate(); process.exit(2); }, 3000);
const requestId = "verify-mac-system-info";
ws.on("open", () => ws.send(JSON.stringify({ type: "hello", protocolVersion: 4, minProtocolVersion: 4 })));
ws.on("message", raw => {
  let frame; try { frame = JSON.parse(raw.toString()); } catch { return; }
  if (frame.type === "hello") ws.send(JSON.stringify({ type: "request", id: requestId, method: "system.info", params: {} }));
  if (frame.type === "response" && frame.id === requestId) {
    clearTimeout(timer); if (frame.ok !== true) process.exit(3);
    process.stdout.write(JSON.stringify(frame.result)); ws.close();
  }
});
ws.on("error", () => { clearTimeout(timer); process.exit(4); });
NODE
}

check_owner() {
  local label="$1" port="$2" home="$3" helper="$4" channel="$5" expected_home="$6" expected_agent="$7"
  local plist="$APP/Contents/Library/LaunchAgents/$label.plist" output pid command_line listener_pids listener host info payload_root
  regular_file "$plist" || { fail "$label LaunchAgent plist missing"; return; }
  [[ "$(plist_value Label "$plist")" == "$label" ]] && pass "$label plist label" || fail "$label plist label mismatch"
  [[ "$(plist_json AssociatedBundleIdentifiers "$plist")" == '["com.tron.mac"]' ]] \
    && pass "$label has only the installed Release parent" || fail "$label parent association is not exactly installed Release"
  [[ "$(plist_value BundleProgram "$plist")" == "Contents/Library/LoginItems/$helper.app/Contents/MacOS/tron" ]] \
    && pass "$label exact helper path" || fail "$label helper path mismatch"
  [[ "$(plist_value EnvironmentVariables.TRON_GATEWAY_SUPERVISED "$plist")" == 1 ]] && pass "$label supervision marker" || fail "$label supervision marker"
  [[ "$(plist_value EnvironmentVariables.TRON_GATEWAY_CHANNEL "$plist")" == "$channel" ]] && pass "$label channel marker" || fail "$label channel marker"
  if [[ "$channel" == dev ]]; then
    [[ "$(plist_value EnvironmentVariables.TRON_HOME_NAME "$plist")" == "$expected_home" ]] && pass "$label home marker" || fail "$label home marker"
    [[ "$(plist_value EnvironmentVariables.TRON_AGENT_DIR_NAME "$plist")" == "$expected_agent" ]] && pass "$label agent-dir marker" || fail "$label agent-dir marker"
  else
    [[ -z "$(plist_value EnvironmentVariables.TRON_HOME_NAME "$plist")" ]] && pass "$label stable home marker absent" || fail "$label has Debug home marker"
    [[ -z "$(plist_value EnvironmentVariables.TRON_AGENT_DIR_NAME "$plist")" ]] && pass "$label stable agent-dir marker absent" || fail "$label has Debug agent-dir marker"
  fi
  output="$(launchctl print "gui/$UID_VALUE/$label" 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    fail "$label is not registered with launchd"; return
  fi
  pass "$label is registered with launchd"
  grep -q 'state = running' <<<"$output" && pass "$label is running" || fail "$label is not running"
  grep -q 'parent bundle identifier = com\.tron\.mac$' <<<"$output" \
    && pass "$label runtime parent is installed Release" || fail "$label runtime parent is not installed Release"
  pid="$(awk '/^[[:space:]]*pid =/{print $3; exit}' <<<"$output")"
  [[ "$pid" =~ ^[0-9]+$ ]] || { fail "$label has no running PID"; return; }
  command_line="$(ps -ww -o command= -p "$pid" 2>/dev/null || true)"
  if [[ "$channel" == stable ]]; then payload_root="$STABLE_PAYLOAD_ROOT"; else payload_root="$DEV_PAYLOAD_ROOT"; fi
  [[ "$command_line" == "$payload_root/runtime/node-"*" $payload_root/app/dist/index.js "* ]] \
    && pass "$label PID uses exact selected payload" || fail "$label PID selected payload path mismatch"
  [[ "$output" == *"TRON_GATEWAY_SUPERVISED => 1"* || "$output" == *"TRON_GATEWAY_SUPERVISED = 1"* ]] || fail "$label runtime supervision marker missing"
  [[ "$output" == *"TRON_GATEWAY_CHANNEL => $channel"* || "$output" == *"TRON_GATEWAY_CHANNEL = $channel"* ]] || fail "$label runtime channel marker missing"
  if [[ "$channel" == dev ]]; then
    [[ "$output" == *"TRON_HOME_NAME => $expected_home"* || "$output" == *"TRON_HOME_NAME = $expected_home"* ]] || fail "$label runtime home marker missing"
    [[ "$output" == *"TRON_AGENT_DIR_NAME => $expected_agent"* || "$output" == *"TRON_AGENT_DIR_NAME = $expected_agent"* ]] || fail "$label runtime agent-dir marker missing"
  else
    [[ "$output" != *TRON_HOME_NAME* ]] || fail "$label runtime has Debug home marker"
    [[ "$output" != *TRON_AGENT_DIR_NAME* ]] || fail "$label runtime has Debug agent-dir marker"
  fi
  listener_pids="$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed '/^$/d' || true)"
  [[ "$listener_pids" == "$pid" ]] \
    && pass "$label is the exact listener PID on port $port" \
    || { fail "$label listener PID set does not exactly match launchd PID"; return; }
  listener="$(lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9; exit}')"
  [[ -n "$listener" ]] || { fail "$label has no listening socket on port $port"; return; }
  host="${listener%:$port}"; host="${host#TCP }"; host="${host#[}"; host="${host%]}"
  [[ "$host" == '*' || "$host" == '0.0.0.0' || "$host" == '::' ]] && host=127.0.0.1
  info="$(authenticated_system_info "$host" "$port" "$home" "$payload_root" || true)"
  local expected_fingerprint expected_revision expected_epoch
  if [[ "$channel" == stable ]]; then
    expected_fingerprint="$STABLE_FINGERPRINT"
    expected_revision="$STABLE_REVISION"
    expected_epoch="$STABLE_EPOCH"
  else
    expected_fingerprint="$DEV_FINGERPRINT"
    expected_revision="$DEV_REVISION"
    expected_epoch="$DEV_EPOCH"
  fi
  INFO="$info" CHANNEL="$channel" FINGERPRINT="$expected_fingerprint" REVISION="$expected_revision" EPOCH="$expected_epoch" python3 - <<'PY'
import json, os, sys
try:
    value=json.loads(os.environ["INFO"])
    ok=value.get("gatewayChannel")==os.environ["CHANNEL"] \
        and value.get("buildFingerprint")==os.environ["FINGERPRINT"] \
        and value.get("sourceRevision")==os.environ["REVISION"] \
        and value.get("runtimeEpoch")==os.environ["EPOCH"]
except Exception: ok=False
sys.exit(0 if ok else 1)
PY
  [[ $? -eq 0 ]] \
    && pass "$label authenticated system.info matches selected payload and channel on $host" \
    || fail "$label authenticated system.info identity/channel mismatch on listening host $host"
}

check_owner com.tron.server 9847 "$HOME/.tron" "Tron Agent" stable "" ""

# Release must never own a second service identity.
if launchctl print "gui/$UID_VALUE/com.tron.server.preview" >/dev/null 2>&1; then
  fail "stray Release-owned com.tron.server.preview is loaded"
else
  pass "no stray com.tron.server.preview registration is loaded"
fi

observe_debug() {
  local legacy_output listener_pids listener_pid lifecycle lifecycle_state expected_port expected_home
  local supervisor_pid supervisor_start actual_supervisor_start child_pid child_start actual_start
  local command_line listener host auth_info
  legacy_output="$(launchctl print "gui/$UID_VALUE/com.tron.server.dev" 2>/dev/null || true)"
  if [[ -n "$legacy_output" ]]; then
    fail "legacy com.tron.server.dev SMAppService is loaded; scripts/tron dev must be the sole Debug owner"
  else
    pass "no legacy Debug SMAppService is loaded"
  fi

  listener_pids="$(lsof -nP -tiTCP:9848 -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -z "$listener_pids" ]]; then
    pass "Debug Gateway is absent (optional)"
    return
  fi
  if [[ "$(printf '%s\n' "$listener_pids" | sed '/^$/d' | wc -l | tr -d ' ')" != 1 ]]; then
    fail "multiple processes listen on Debug port 9848"
    return
  fi
  listener_pid="$listener_pids"
  [[ "$listener_pid" =~ ^[0-9]+$ ]] || { fail "Debug listener PID is invalid"; return; }

  lifecycle="$HOME/.tron-dev/gateway/lifecycle.json"
  regular_file "$lifecycle" || { fail "Debug listener has no regular scripts/tron-dev lifecycle record"; return; }
  lifecycle_state="$(plist_value lifecycle "$lifecycle")"
  expected_port="$(plist_value expectedPort "$lifecycle")"
  expected_home="$(plist_value expectedHome "$lifecycle")"
  supervisor_pid="$(plist_value supervisorPid "$lifecycle")"
  supervisor_start="$(plist_value supervisorStartIdentity "$lifecycle")"
  child_pid="$(plist_value childPid "$lifecycle")"
  child_start="$(plist_value childStartIdentity "$lifecycle")"
  [[ "$lifecycle_state" == ready && "$expected_port" == 9848 && "$expected_home" == "$HOME/.tron-dev" ]] \
    && pass "Debug lifecycle is ready for the exact home and port" \
    || fail "Debug lifecycle home/port/readiness mismatch"
  [[ "$supervisor_pid" =~ ^[0-9]+$ && "$child_pid" =~ ^[0-9]+$ && "$supervisor_pid" != "$child_pid" ]] \
    || { fail "Debug lifecycle supervisor/child PID identity is invalid"; return; }
  actual_supervisor_start="$(ps -o lstart= -p "$supervisor_pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
  [[ -n "$supervisor_start" && "$actual_supervisor_start" == "$supervisor_start" ]] \
    && pass "Debug supervisor PID/start identity is live and exact" \
    || { fail "Debug supervisor PID/start identity mismatch"; return; }
  [[ "$child_pid" == "$listener_pid" ]] \
    && pass "Debug listener PID matches lifecycle child" \
    || { fail "Debug listener PID does not match lifecycle child"; return; }
  actual_start="$(ps -o lstart= -p "$listener_pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
  [[ -n "$child_start" && "$actual_start" == "$child_start" ]] \
    && pass "Debug child PID/start identity is live and exact" \
    || { fail "Debug child PID/start identity mismatch"; return; }

  regular_file "$HOME/.tron-dev/gateway/payloads/dev/current.json" \
    || { fail "Debug listener has no immutable dev selection"; return; }
  verify_payload dev "$HOME/.tron-dev" dev "$BUNDLED"
  command_line="$(ps -ww -o command= -p "$listener_pid" 2>/dev/null || true)"
  [[ -n "$DEV_PAYLOAD_ROOT" && "$command_line" == "$DEV_PAYLOAD_ROOT/runtime/node-"*" $DEV_PAYLOAD_ROOT/app/dist/index.js "*" --port 9848"* ]] \
    && pass "Debug PID uses the exact selected immutable dev payload" \
    || { fail "Debug PID does not use the selected immutable dev payload"; return; }

  [[ "$(plist_value epoch "$lifecycle")" == "$DEV_EPOCH" \
      && "$(plist_value sourceRevision "$lifecycle")" == "$DEV_REVISION" \
      && "$(plist_value buildFingerprint "$lifecycle")" == "$DEV_FINGERPRINT" ]] \
    && pass "Debug lifecycle identity matches selected manifest" \
    || fail "Debug lifecycle identity does not match selected manifest"

  listener="$(lsof -nP -a -p "$listener_pid" -iTCP:9848 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9; exit}')"
  host="${listener%:9848}"; host="${host#TCP }"; host="${host#[}"; host="${host%]}"
  [[ "$host" == '*' || "$host" == '0.0.0.0' || "$host" == '::' ]] && host=127.0.0.1
  auth_info="$(authenticated_system_info "$host" 9848 "$HOME/.tron-dev" "$DEV_PAYLOAD_ROOT" || true)"
  INFO="$auth_info" CHANNEL=dev FINGERPRINT="$DEV_FINGERPRINT" REVISION="$DEV_REVISION" EPOCH="$DEV_EPOCH" python3 - <<'PY'
import json, os, sys
try:
    value=json.loads(os.environ["INFO"])
    ok=value.get("gatewayChannel")==os.environ["CHANNEL"] \
        and value.get("buildFingerprint")==os.environ["FINGERPRINT"] \
        and value.get("sourceRevision")==os.environ["REVISION"] \
        and value.get("runtimeEpoch")==os.environ["EPOCH"]
except Exception: ok=False
sys.exit(0 if ok else 1)
PY
  [[ $? -eq 0 ]] \
    && pass "Debug authenticated system.info matches selected manifest on $host" \
    || fail "Debug authenticated system.info identity mismatch"
}
observe_debug

if (( failures > 0 )); then
  printf '\nVerification failed with %s issue(s).\n' "$failures" >&2
  exit 1
fi
printf '\nInstalled Release Tron.app owns stable; optional Debug is developer-owned and read-only to Release.\n'
