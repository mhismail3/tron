#!/bin/bash
# tron-ios.sh - iOS development commands for tron (workspace-only, macOS-only)
#
# Sourced by scripts/tron. Provides `tron ios ...` for building, running,
# stopping, cleaning, testing, and managing the TronMobile app on physical
# iOS devices and simulators.
#
# Device UDIDs and preferences live under the "ios" key in
# ~/.tron/system/settings.json. Unknown keys are preserved by the Rust
# server's JSON deep-merge (see settings/storage/loader.rs), so no Rust
# schema change is needed.
#
# This file is never sourced by scripts/tron-cli or any production
# runtime path — iOS commands only reach the workspace via tron-cli's
# delegation shim.

#=============================================================================
# CONSTANTS
#=============================================================================

IOS_PROJECT_REL="packages/ios-app/TronMobile.xcodeproj"
IOS_DERIVED_DATA_REL="packages/ios-app/.build/DerivedData"
IOS_GLOBAL_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
IOS_DEFAULT_SIMULATOR_FALLBACK="iPhone 17 Pro"
IOS_LAST_LOG_PATH="/tmp/tron-ios-last-log"
IOS_LAST_XCRESULT_PATH="/tmp/tron-ios-last-xcresult"

#=============================================================================
# PREREQUISITE CHECKS
#=============================================================================

_ios_require_macos() {
    if [[ "$(uname)" != "Darwin" ]]; then
        print_error "iOS commands require macOS"
        exit 1
    fi
}

_ios_require_xcode() {
    if ! command -v xcodebuild >/dev/null 2>&1; then
        print_error "xcodebuild not found. Install Xcode from the App Store."
        exit 1
    fi
    local xcode_path
    xcode_path="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$xcode_path" == *"CommandLineTools"* ]]; then
        print_error "xcode-select points at Command Line Tools only."
        echo "  Install full Xcode from the App Store, then run:"
        echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        exit 1
    fi
}

_ios_require_devicectl() {
    if ! xcrun -f devicectl >/dev/null 2>&1; then
        print_error "xcrun devicectl not available. Requires Xcode 15 or later."
        exit 1
    fi
}

_ios_require_project() {
    if [[ ! -d "$PROJECT_DIR/$IOS_PROJECT_REL" ]]; then
        print_error "iOS project not found: $PROJECT_DIR/$IOS_PROJECT_REL"
        echo "  This command requires a full workspace checkout."
        exit 1
    fi
}

#=============================================================================
# SETTINGS I/O
# ----------------------------------------------------------------------------
# Uses python3 (always present on macOS) instead of jq for consistency with
# the existing auth.json handling in build_rust. All writes go through
# atomic tempfile + os.replace so concurrent readers never see a partial
# settings.json.
#=============================================================================

_ios_settings_path() {
    echo "$TRON_HOME/system/settings.json"
}

# Usage: _ios_read_json <dot.path> [default]
# Prints scalar value at the path, or a JSON-encoded object/array for non-scalars.
# Returns empty (or the default) if the path is missing or the file is absent.
_ios_read_json() {
    local path="$1"
    local default="${2:-}"
    local file
    file="$(_ios_settings_path)"
    python3 - "$file" "$path" "$default" <<'PY' 2>/dev/null || echo "$default"
import json, sys
file, path, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(file) as f:
        data = json.load(f)
except FileNotFoundError:
    print(default)
    sys.exit(0)
except json.JSONDecodeError as e:
    sys.stderr.write(f"settings.json parse error: {e}\n")
    sys.exit(2)
cur = data
for part in path.split('.'):
    if not part:
        continue
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print(default)
        sys.exit(0)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
elif cur is None:
    print(default)
else:
    print(cur)
PY
}

# Usage: _ios_write_scalar <dot.path> <value>
# Writes a string scalar. Pass "__DELETE__" as value to unset the key.
_ios_write_scalar() {
    local path="$1" value="$2" file
    file="$(_ios_settings_path)"
    mkdir -p "$(dirname "$file")"
    [[ ! -f "$file" ]] && echo "{}" > "$file"
    python3 - "$file" "$path" "$value" <<'PY' || { print_error "Failed to write $file"; return 1; }
import json, os, sys, tempfile
file, path, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(file) as f:
    data = json.load(f)
parts = [p for p in path.split('.') if p]
cur = data
for part in parts[:-1]:
    if part not in cur or not isinstance(cur[part], dict):
        cur[part] = {}
    cur = cur[part]
if value == "__DELETE__":
    cur.pop(parts[-1], None)
else:
    cur[parts[-1]] = value
dirn = os.path.dirname(file) or "."
with tempfile.NamedTemporaryFile("w", dir=dirn, delete=False) as tf:
    json.dump(data, tf, indent=2)
    tf.write("\n")
    tmp = tf.name
os.replace(tmp, file)
PY
}

_ios_has_config() {
    local devices
    devices="$(_ios_read_json "ios.devices")"
    [[ -n "$devices" && "$devices" != "{}" ]]
}

_ios_get_default_device()    { _ios_read_json "ios.defaultDevice"; }
_ios_get_device_udid()       { _ios_read_json "ios.devices.$1.udid"; }
_ios_get_device_label()      { _ios_read_json "ios.devices.$1.label"; }
_ios_get_last_launch_field() { _ios_read_json "ios.lastLaunch.$1"; }

_ios_get_default_simulator() {
    local sim
    sim="$(_ios_read_json "ios.defaultSimulator")"
    [[ -z "$sim" ]] && sim="$IOS_DEFAULT_SIMULATOR_FALLBACK"
    echo "$sim"
}

# Save a device to ios.devices.<alias>. Arguments are argv-passed so special
# characters in labels (apostrophes, quotes) don't break shell quoting.
_ios_device_save() {
    local alias="$1" udid="$2" label="$3"
    local file
    file="$(_ios_settings_path)"
    mkdir -p "$(dirname "$file")"
    [[ ! -f "$file" ]] && echo "{}" > "$file"
    python3 - "$file" "$alias" "$udid" "$label" <<'PY' || { print_error "Failed to save device"; return 1; }
import json, os, sys, tempfile
file, alias, udid, label = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(file) as f:
    data = json.load(f)
ios = data.setdefault("ios", {})
ios.setdefault("devices", {})[alias] = {
    "udid": udid,
    "label": label.strip(),
    "platform": "iOS",
}
dirn = os.path.dirname(file) or "."
with tempfile.NamedTemporaryFile("w", dir=dirn, delete=False) as tf:
    json.dump(data, tf, indent=2)
    tf.write("\n")
    tmp = tf.name
os.replace(tmp, file)
PY
    local default_now
    default_now="$(_ios_get_default_device)"
    if [[ -z "$default_now" ]]; then
        _ios_write_scalar "ios.defaultDevice" "$alias"
        print_success "Saved '$alias' ($udid) and set as default"
    else
        print_success "Saved '$alias' ($udid)"
    fi
}

_ios_save_last_launch() {
    local udid="$1" bundle_id="$2" pid="$3" ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local file
    file="$(_ios_settings_path)"
    [[ ! -f "$file" ]] && echo "{}" > "$file"
    python3 - "$file" "$udid" "$bundle_id" "$pid" "$ts" <<'PY' 2>/dev/null || true
import json, os, sys, tempfile
file, udid, bundle, pid, ts = sys.argv[1:6]
try:
    with open(file) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data.setdefault("ios", {})["lastLaunch"] = {
    "udid": udid, "bundleId": bundle, "pid": int(pid), "launchedAt": ts,
}
dirn = os.path.dirname(file) or "."
with tempfile.NamedTemporaryFile("w", dir=dirn, delete=False) as tf:
    json.dump(data, tf, indent=2)
    tf.write("\n")
    tmp = tf.name
os.replace(tmp, file)
PY
}

#=============================================================================
# FLAG PARSING
# ----------------------------------------------------------------------------
# All flag parsers set shared IOS_* globals. Callers should invoke
# _ios_reset_flags() before _ios_parse_common_flags() to start fresh.
# Unmatched args are collected in IOS_ARGS (array).
#=============================================================================

_ios_reset_flags() {
    IOS_SCHEME=""
    IOS_CONFIG=""
    IOS_BUNDLE_ID=""
    IOS_DEST=""
    IOS_UDID=""
    IOS_IS_SIM="false"
    IOS_IS_GENERIC="false"
    IOS_VERBOSE="false"
    IOS_SIM_NAME=""
    IOS_ARGS=()
    _IOS_SCHEME_SET=""
    _IOS_TARGET_SET=""
}

_ios_parse_common_flags() {
    _ios_reset_flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--beta)
                if [[ -n "$_IOS_SCHEME_SET" && "$_IOS_SCHEME_SET" != "beta" ]]; then
                    print_error "Use -b OR -p, not both"; exit 1
                fi
                IOS_SCHEME="Tron Beta"
                IOS_CONFIG="Beta"
                IOS_BUNDLE_ID="com.tron.mobile.beta"
                _IOS_SCHEME_SET="beta"
                shift ;;
            -p|--prod)
                if [[ -n "$_IOS_SCHEME_SET" && "$_IOS_SCHEME_SET" != "prod" ]]; then
                    print_error "Use -b OR -p, not both"; exit 1
                fi
                IOS_SCHEME="Tron"
                IOS_CONFIG="Prod"
                IOS_BUNDLE_ID="com.tron.mobile"
                _IOS_SCHEME_SET="prod"
                shift ;;
            --scheme)
                [[ -z "${2:-}" ]] && { print_error "--scheme requires a name"; exit 1; }
                IOS_SCHEME="$2"
                _IOS_SCHEME_SET="custom"
                shift 2 ;;
            --bundle-id)
                [[ -z "${2:-}" ]] && { print_error "--bundle-id requires an id"; exit 1; }
                IOS_BUNDLE_ID="$2"
                shift 2 ;;
            -d|--device)
                [[ -n "$_IOS_TARGET_SET" ]] && { print_error "Only one target flag allowed (-d/-u/-s/-g)"; exit 1; }
                [[ -z "${2:-}" ]] && { print_error "-d requires an alias"; exit 1; }
                IOS_UDID="$(_ios_get_device_udid "$2")"
                if [[ -z "$IOS_UDID" ]]; then
                    print_error "Unknown device alias: $2"
                    local known
                    known="$(_ios_read_json "ios.devices" | python3 -c "
import json, sys
raw = sys.stdin.read().strip()
d = json.loads(raw) if raw else {}
print(', '.join(sorted(d.keys())) if d else '(none)')
" 2>/dev/null || echo "(none)")"
                    echo "  Known aliases: $known"
                    echo "  Try:           tron ios devices list"
                    exit 1
                fi
                IOS_DEST="platform=iOS,id=$IOS_UDID"
                _IOS_TARGET_SET="device"
                shift 2 ;;
            -u|--udid)
                [[ -n "$_IOS_TARGET_SET" ]] && { print_error "Only one target flag allowed (-d/-u/-s/-g)"; exit 1; }
                [[ -z "${2:-}" ]] && { print_error "-u requires a UDID"; exit 1; }
                IOS_UDID="$2"
                IOS_DEST="platform=iOS,id=$IOS_UDID"
                _IOS_TARGET_SET="udid"
                shift 2 ;;
            -s|--sim)
                [[ -n "$_IOS_TARGET_SET" ]] && { print_error "Only one target flag allowed (-d/-u/-s/-g)"; exit 1; }
                IOS_IS_SIM="true"
                if [[ -n "${2:-}" && "$2" != -* ]]; then
                    IOS_SIM_NAME="$2"
                    shift 2
                else
                    IOS_SIM_NAME="$(_ios_get_default_simulator)"
                    shift
                fi
                IOS_DEST="platform=iOS Simulator,name=$IOS_SIM_NAME"
                _IOS_TARGET_SET="sim"
                ;;
            -g|--generic)
                [[ -n "$_IOS_TARGET_SET" ]] && { print_error "Only one target flag allowed (-d/-u/-s/-g)"; exit 1; }
                IOS_IS_GENERIC="true"
                IOS_DEST="generic/platform=iOS"
                _IOS_TARGET_SET="generic"
                shift ;;
            -v|--verbose)
                IOS_VERBOSE="true"
                shift ;;
            *)
                IOS_ARGS+=("$1")
                shift ;;
        esac
    done

    # Default scheme if none specified
    if [[ -z "$_IOS_SCHEME_SET" ]]; then
        local default_scheme
        default_scheme="$(_ios_read_json "ios.defaultScheme" "prod")"
        if [[ "$default_scheme" == "beta" ]]; then
            IOS_SCHEME="Tron Beta"
            IOS_CONFIG="Beta"
            IOS_BUNDLE_ID="com.tron.mobile.beta"
        else
            IOS_SCHEME="Tron"
            IOS_CONFIG="Prod"
            IOS_BUNDLE_ID="com.tron.mobile"
        fi
    fi

    # Custom scheme requires explicit bundle ID
    if [[ "$_IOS_SCHEME_SET" == "custom" && -z "$IOS_BUNDLE_ID" ]]; then
        print_error "--scheme requires --bundle-id"
        exit 1
    fi
}

#=============================================================================
# XCODEBUILD WRAPPER WITH XCODE-QUALITY ERROR SURFACING
# ----------------------------------------------------------------------------
# All xcodebuild invocations go through _ios_run_xcodebuild. It:
#   1. Adds -resultBundlePath so a .xcresult is always produced (openable in Xcode).
#   2. Tees full output to /tmp/tron-ios-<ts>-<pid>.log.
#   3. Pipes through the best available formatter (xcbeautify > xcpretty > native).
#   4. On failure, parses the log and prints a structured post-mortem:
#        - Unique file:line:col compile errors (Xcode-navigator quality)
#        - Failed-command summary block
#        - Code-signing / provisioning diagnostics
#        - Linker errors
#        - Full log path + xcresult path
#
# -v (IOS_VERBOSE=true) bypasses filtering: raw xcodebuild streams live,
# but the logfile is still saved and the post-mortem still runs.
#=============================================================================

_ios_format_filter() {
    awk '
        /[^ ].*:[0-9]+:[0-9]+: (error|warning|note):/ { print; next }
        /^\*\* (BUILD|CLEAN|TEST|ARCHIVE|ANALYZE) (SUCCEEDED|FAILED|CANCELED) \*\*/ { print; next }
        /^The following build commands failed:/ { print; in_fail=1; next }
        in_fail && /^\([0-9]+ failures?\)$/ { print; in_fail=0; next }
        in_fail { print; next }
        /^(Undefined symbols|ld: error|duplicate symbol|fatal error)/ { print; next }
        /^Code Sign(ing)? (error|failed)/ { print; next }
        /provisioning profile/ && /error|not found|does not/ { print; next }
        /^Test Case .* (failed|passed)/ { print; next }
        /XCTAssert.*failed/ { print; next }
    '
}

_ios_run_xcodebuild() {
    local ts logfile xcresult rc=0
    ts="$(date +%s)-$$"
    logfile="/tmp/tron-ios-${ts}.log"
    xcresult="/tmp/tron-ios-${ts}.xcresult"

    rm -rf "$xcresult"

    local -a cmd=(xcodebuild -resultBundlePath "$xcresult" "$@")

    if [[ "$IOS_VERBOSE" == "true" ]]; then
        "${cmd[@]}" 2>&1 | tee "$logfile"
        rc=${PIPESTATUS[0]}
    elif command -v xcbeautify >/dev/null 2>&1; then
        "${cmd[@]}" 2>&1 | tee "$logfile" | xcbeautify --quiet
        rc=${PIPESTATUS[0]}
    elif command -v xcpretty >/dev/null 2>&1; then
        "${cmd[@]}" 2>&1 | tee "$logfile" | xcpretty --color
        rc=${PIPESTATUS[0]}
    else
        "${cmd[@]}" 2>&1 | tee "$logfile" | _ios_format_filter
        rc=${PIPESTATUS[0]}
    fi

    echo "$logfile" > "$IOS_LAST_LOG_PATH"
    echo "$xcresult" > "$IOS_LAST_XCRESULT_PATH"

    if [[ $rc -ne 0 ]]; then
        _ios_print_build_failures "$logfile" "$xcresult"
    fi
    return "$rc"
}

_ios_print_build_failures() {
    local logfile="$1" xcresult="$2"
    echo ""
    print_header "Build failed"

    local errors
    errors="$(grep -E ':[0-9]+:[0-9]+: error:' "$logfile" 2>/dev/null | awk '!seen[$0]++' | head -20)"
    if [[ -n "$errors" ]]; then
        echo -e "${RED}Errors:${NC}"
        printf '  %s\n' "${errors//$'\n'/$'\n'  }"
        echo ""
    fi

    local cmd_failures
    cmd_failures="$(sed -En '/^The following build commands failed:/,/^\([0-9]+ failures?\)$/p' "$logfile" 2>/dev/null | head -15)"
    if [[ -n "$cmd_failures" ]]; then
        echo -e "${YELLOW}Failed commands:${NC}"
        printf '  %s\n' "${cmd_failures//$'\n'/$'\n'  }"
        echo ""
    fi

    local sign_errors
    sign_errors="$(grep -iE 'code ?sign|provisioning profile|signing identity' "$logfile" 2>/dev/null | grep -iE 'error|failed|does not|not found' | head -5)"
    if [[ -n "$sign_errors" ]]; then
        echo -e "${YELLOW}Signing:${NC}"
        printf '  %s\n' "${sign_errors//$'\n'/$'\n'  }"
        echo ""
    fi

    local linker_errors
    linker_errors="$(grep -E 'Undefined symbols|ld: error|duplicate symbol' "$logfile" 2>/dev/null | head -10)"
    if [[ -n "$linker_errors" ]]; then
        echo -e "${YELLOW}Linker:${NC}"
        printf '  %s\n' "${linker_errors//$'\n'/$'\n'  }"
        echo ""
    fi

    echo -e "${DIM}Full log: $logfile${NC}"
    echo -e "${DIM}xcresult: $xcresult  (open in Xcode: open \"$xcresult\")${NC}"
    if [[ "$IOS_VERBOSE" != "true" ]]; then
        echo -e "${DIM}Re-run with -v for live output during the build.${NC}"
    fi
}

#=============================================================================
# devicectl ERROR ENRICHMENT
# ----------------------------------------------------------------------------
# devicectl output is concise; we pass it through unchanged. On failure,
# we pattern-match for common issues and append actionable hints.
#=============================================================================

_ios_hint_for_launch_error() {
    local output="$1"
    local lower
    lower="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        *"developer mode"*)
            echo "Enable Developer Mode: Settings → Privacy & Security → Developer Mode, then reboot the device." ;;
        *"not installed on device"*|*"no installed application"*|*"application not found"*)
            echo "Run 'tron ios build' first to install the app." ;;
        *"locked for install"*|*"device is locked"*|*"passcode"*)
            echo "Unlock the device and try again." ;;
        *"device is busy"*|*"operation is already in progress"*)
            echo "Device busy. Wait a few seconds and retry." ;;
        *"not been trusted"*|*"not paired"*|*"trust"*)
            echo "Accept the 'Trust this computer' prompt on the device." ;;
        *"provisioning profile"*)
            echo "Open the project in Xcode once to refresh signing; then retry." ;;
        *"not available"*|*"not connected"*|*"device unavailable"*)
            echo "Connect the device via USB. Run 'tron ios devices scan' to verify." ;;
        *)
            return 1 ;;
    esac
}

#=============================================================================
# DEVICE HELPERS
#=============================================================================

_ios_validate_alias() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

_ios_ensure_target_or_bail() {
    if [[ -n "$_IOS_TARGET_SET" ]]; then
        return 0
    fi
    local default_alias
    default_alias="$(_ios_get_default_device)"
    if [[ -n "$default_alias" ]]; then
        local udid
        udid="$(_ios_get_device_udid "$default_alias")"
        if [[ -n "$udid" ]]; then
            IOS_UDID="$udid"
            IOS_DEST="platform=iOS,id=$udid"
            _IOS_TARGET_SET="device"
            return 0
        fi
        print_warning "Default device '$default_alias' no longer in settings"
    fi
    _ios_print_no_device_message
    exit 1
}

_ios_print_no_device_message() {
    echo ""
    print_warning "No iOS device configured"
    echo ""
    echo "  tron ios devices add      # register a connected device"
    echo "  tron ios devices scan     # show currently connected devices"
    echo "  tron ios -s               # build + run on simulator"
    echo "  tron ios -g               # compile check (no device needed)"
    echo ""
}

#=============================================================================
# devices SUBCOMMAND
#=============================================================================

_ios_cmd_devices() {
    local sub="${1:-list}"
    shift 2>/dev/null || true
    case "$sub" in
        list)           _ios_cmd_devices_list "$@" ;;
        add)            _ios_cmd_devices_add "$@" ;;
        remove|rm|del)  _ios_cmd_devices_remove "$@" ;;
        default)        _ios_cmd_devices_default "$@" ;;
        scan)           _ios_cmd_devices_scan "$@" ;;
        help|-h|--help)
            cat <<'HELP'

tron ios devices - Manage saved iOS devices

Subcommands:
  list                                 List saved devices (default)
  add [--udid <U> --name <alias>]      Register a device (interactive by default)
  remove <alias>                       Remove a saved device
  default <alias>                      Set the default device
  scan                                 Show currently connected devices

Devices live under ios.devices in ~/.tron/system/settings.json.
HELP
            ;;
        *)
            print_error "Unknown devices subcommand: $sub"
            exit 1 ;;
    esac
}

_ios_cmd_devices_list() {
    local devices_json default_alias
    devices_json="$(_ios_read_json "ios.devices")"
    default_alias="$(_ios_get_default_device)"
    if [[ -z "$devices_json" || "$devices_json" == "{}" ]]; then
        _ios_print_no_device_message
        return 0
    fi
    echo ""
    print_header "Saved iOS devices"
    python3 - "$devices_json" "$default_alias" <<'PY'
import json, sys
try:
    devs = json.loads(sys.argv[1])
except Exception:
    devs = {}
default = sys.argv[2]
if not devs:
    print("  (none)")
    sys.exit(0)
width = max((len(a) for a in devs), default=8)
for alias in sorted(devs):
    info = devs[alias] if isinstance(devs[alias], dict) else {}
    mark = "*" if alias == default else " "
    label = info.get("label", "")
    udid = info.get("udid", "")
    print(f"  {mark} {alias:<{width}}  {label}")
    print(f"    {' '*width}    {udid}")
PY
    echo ""
    echo "  * = default device"
}

_ios_cmd_devices_add() {
    _ios_require_devicectl
    local udid="" name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --udid) udid="$2"; shift 2 ;;
            --name) name="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: tron ios devices add [--udid <UDID> --name <alias>]"
                echo "Without flags, runs interactively: scans devices and prompts."
                return 0 ;;
            *) shift ;;
        esac
    done

    if [[ -n "$udid" && -n "$name" ]]; then
        if ! _ios_validate_alias "$name"; then
            print_error "Invalid alias '$name'. Use [a-z0-9][a-z0-9_-]*"
            exit 1
        fi
        local existing
        existing="$(_ios_get_device_udid "$name")"
        if [[ -n "$existing" ]]; then
            if ! confirm_action "Alias '$name' exists. Overwrite?"; then
                echo "Aborted."
                return 0
            fi
        fi
        _ios_device_save "$name" "$udid" "${name}"
        return 0
    fi

    # Interactive
    print_status "Scanning for connected devices..."
    local scan_output filtered=()
    scan_output="$(xcrun xctrace list devices 2>&1 || true)"

    # Lines between "== Devices ==" and "== Simulators ==" that contain a UDID
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if echo "$line" | grep -qE '\([A-F0-9][A-F0-9-]{7,}\)[[:space:]]*$'; then
            filtered+=("$line")
        fi
    done < <(echo "$scan_output" | awk '
        /^== Simulators ==/ { exit }
        /^== Devices ==/    { capture=1; next }
        capture { print }
    ')

    if [[ ${#filtered[@]} -eq 0 ]]; then
        print_warning "No physical devices connected."
        echo "  Plug in a device via USB and try again."
        return 0
    fi

    echo ""
    echo "Connected devices:"
    local i
    for i in "${!filtered[@]}"; do
        printf "  %d) %s\n" $((i+1)) "${filtered[$i]}"
    done
    echo ""

    local choice
    if [[ ${#filtered[@]} -eq 1 ]]; then
        choice=1
        echo "Using device 1 (only option)."
    else
        read -p "Select device (1-${#filtered[@]}): " -r choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#filtered[@]} )); then
            print_error "Invalid selection"
            exit 1
        fi
    fi

    local selected="${filtered[$((choice-1))]}"
    local label raw_udid
    label="$(echo "$selected" | sed -E 's/[[:space:]]*\([^)]+\)[[:space:]]*\([A-F0-9-]{8,}\)[[:space:]]*$//')"
    raw_udid="$(echo "$selected" | grep -oE '\([A-F0-9-]{8,}\)[[:space:]]*$' | tr -d '() \t')"
    if [[ -z "$raw_udid" ]]; then
        print_error "Could not parse UDID from: $selected"
        exit 1
    fi

    local alias attempts=0
    while true; do
        read -p "Alias for this device (e.g. iphone, ipad): " -r alias
        if [[ -z "$alias" ]]; then
            echo "Alias cannot be empty."
        elif ! _ios_validate_alias "$alias"; then
            echo "Invalid alias. Use lowercase letters, digits, underscore, hyphen (must start with letter/digit)."
        else
            local existing
            existing="$(_ios_get_device_udid "$alias")"
            if [[ -n "$existing" ]]; then
                if confirm_action "Alias '$alias' exists. Overwrite?"; then
                    break
                fi
            else
                break
            fi
        fi
        attempts=$((attempts+1))
        if (( attempts >= 3 )); then
            print_error "Too many attempts"
            exit 1
        fi
    done

    _ios_device_save "$alias" "$raw_udid" "$label"
}

_ios_cmd_devices_remove() {
    local alias="${1:-}"
    [[ -z "$alias" ]] && { print_error "Usage: tron ios devices remove <alias>"; exit 1; }
    local existing
    existing="$(_ios_get_device_udid "$alias")"
    [[ -z "$existing" ]] && { print_error "No such device: $alias"; exit 1; }

    _ios_write_scalar "ios.devices.$alias" "__DELETE__"

    local default_now
    default_now="$(_ios_get_default_device)"
    if [[ "$default_now" == "$alias" ]]; then
        _ios_write_scalar "ios.defaultDevice" "__DELETE__"
        print_warning "Cleared default device (was '$alias')"
    fi
    print_success "Removed '$alias'"
}

_ios_cmd_devices_default() {
    local alias="${1:-}"
    [[ -z "$alias" ]] && { print_error "Usage: tron ios devices default <alias>"; exit 1; }
    local existing
    existing="$(_ios_get_device_udid "$alias")"
    [[ -z "$existing" ]] && { print_error "No such device: $alias"; exit 1; }
    _ios_write_scalar "ios.defaultDevice" "$alias"
    print_success "Default device: $alias"
}

_ios_cmd_devices_scan() {
    _ios_require_devicectl
    print_status "Currently connected devices:"
    xcrun xctrace list devices 2>&1 | awk '
        /^== Simulators ==/ { exit }
        NF > 0 { print }
    '
}

#=============================================================================
# BUILD / RUN / STOP / CLEAN / TEST / LOGS / GEN
#=============================================================================

_ios_do_build() {
    print_status "Building $IOS_SCHEME ($IOS_CONFIG)"
    print_status "Destination: $IOS_DEST"

    local start_ts end_ts elapsed
    start_ts=$(date +%s)

    ( cd "$PROJECT_DIR/packages/ios-app" && _ios_run_xcodebuild \
        build \
        -project TronMobile.xcodeproj \
        -scheme "$IOS_SCHEME" \
        -configuration "$IOS_CONFIG" \
        -destination "$IOS_DEST" \
        -derivedDataPath .build/DerivedData ) || return 1

    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    print_success "Built in ${elapsed}s"
}

_ios_cmd_build() {
    _ios_parse_common_flags "$@"

    # -h/--help landed in IOS_ARGS
    local a
    for a in ${IOS_ARGS[@]+"${IOS_ARGS[@]}"}; do
        case "$a" in
            -h|--help)
                cat <<'HELP'

tron ios build - Compile the app (no launch)

Usage: tron ios build [scheme flags] [target flags] [-v]

Target defaults to --generic (no device required) if unspecified.

Examples:
  tron ios build                 # Compile check, prod scheme
  tron ios build -b              # Beta scheme, generic iOS
  tron ios build -d iphone       # Build targeting saved iPhone
  tron ios build -s              # Simulator build
HELP
                return 0 ;;
        esac
    done

    # Default to generic if no target set
    if [[ -z "$_IOS_TARGET_SET" ]]; then
        IOS_IS_GENERIC="true"
        IOS_DEST="generic/platform=iOS"
        _IOS_TARGET_SET="generic"
    fi

    _ios_do_build
}

_ios_cmd_run() {
    _ios_parse_common_flags "$@"

    local a
    for a in ${IOS_ARGS[@]+"${IOS_ARGS[@]}"}; do
        case "$a" in
            -h|--help)
                cat <<'HELP'

tron ios run - Build, install, and launch the app (default action)

Usage: tron ios run [scheme flags] [target flags] [-v]

Examples:
  tron ios                       # Prod on default device
  tron ios -b                    # Beta on default device
  tron ios -d ipad -b            # Beta on 'ipad' alias
  tron ios -s                    # Default simulator
  tron ios -s "iPhone 15 Pro"    # Specific simulator
HELP
                return 0 ;;
        esac
    done

    # Generic makes no sense for run — it has no device to install to
    if [[ "$IOS_IS_GENERIC" == "true" ]]; then
        print_error "'run' needs a device or simulator (not --generic)"
        echo "  Use 'tron ios build -g' for a compile check."
        exit 1
    fi

    _ios_ensure_target_or_bail
    _ios_do_build || exit 1

    if [[ "$IOS_IS_SIM" == "true" ]]; then
        _ios_launch_simulator
    else
        _ios_launch_device
    fi
}

_ios_launch_device() {
    _ios_require_devicectl
    print_status "Launching $IOS_BUNDLE_ID on $IOS_UDID"
    local output rc=0
    output="$(xcrun devicectl device process launch --device "$IOS_UDID" "$IOS_BUNDLE_ID" 2>&1)" || rc=$?
    echo "$output"

    if [[ $rc -ne 0 ]]; then
        echo ""
        local hint
        if hint="$(_ios_hint_for_launch_error "$output")"; then
            echo -e "${YELLOW}hint:${NC} $hint"
        fi
        exit $rc
    fi

    local pid
    pid="$(printf '%s\n' "$output" | grep -oE '(Process identifier|Process ID|PID)[: =]+[0-9]+' | grep -oE '[0-9]+$' | head -1)"
    if [[ -n "$pid" ]]; then
        _ios_save_last_launch "$IOS_UDID" "$IOS_BUNDLE_ID" "$pid"
        print_success "Launched (PID $pid)"
    else
        print_warning "Launched but PID not captured"
        echo "  'tron ios stop --udid $IOS_UDID' will search by bundle if needed."
    fi
}

_ios_launch_simulator() {
    local sim_name="${IOS_SIM_NAME:-$(_ios_get_default_simulator)}"
    print_status "Booting simulator: $sim_name"
    xcrun simctl boot "$sim_name" 2>/dev/null || true

    local app_path
    app_path="$(find "$PROJECT_DIR/packages/ios-app/.build/DerivedData/Build/Products" \
        -name "TronMobile.app" -type d 2>/dev/null | grep -i "iphonesimulator" | head -1)"
    if [[ -z "$app_path" ]]; then
        print_error "Could not find simulator .app bundle"
        echo "  Expected under: packages/ios-app/.build/DerivedData/Build/Products/*-iphonesimulator/"
        exit 1
    fi

    print_status "Installing $(basename "$app_path") on simulator"
    xcrun simctl install booted "$app_path" || { print_error "Install failed"; exit 1; }

    print_status "Launching $IOS_BUNDLE_ID"
    xcrun simctl launch booted "$IOS_BUNDLE_ID" || { print_error "Launch failed"; exit 1; }
    print_success "Launched on $sim_name"
}

_ios_cmd_stop() {
    _ios_require_devicectl
    local udid="" pid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --udid) udid="$2"; shift 2 ;;
            --pid)  pid="$2";  shift 2 ;;
            -h|--help)
                echo "Usage: tron ios stop [--udid <UDID>] [--pid <PID>]"
                echo "Without flags, reads last-launch state from settings."
                return 0 ;;
            *) shift ;;
        esac
    done

    [[ -z "$udid" ]] && udid="$(_ios_get_last_launch_field udid)"
    [[ -z "$pid"  ]] && pid="$(_ios_get_last_launch_field pid)"

    if [[ -z "$udid" ]]; then
        print_error "No device to target. Use --udid or run 'tron ios run' first."
        exit 1
    fi

    if [[ -z "$pid" ]]; then
        print_status "Searching for tron process on $udid..."
        local proc_output
        proc_output="$(xcrun devicectl device info processes --device "$udid" 2>/dev/null | grep -iE 'com\.tron\.mobile(\.beta)?' || true)"
        if [[ -z "$proc_output" ]]; then
            print_success "No matching process running (already stopped)"
            return 0
        fi
        pid="$(printf '%s\n' "$proc_output" | awk '{print $1}' | grep -E '^[0-9]+$' | head -1)"
        if [[ -z "$pid" ]]; then
            print_warning "Unparseable process listing:"
            echo "$proc_output"
            print_error "Specify --pid explicitly"
            exit 1
        fi
    fi

    print_status "Terminating PID $pid on $udid"
    if ! xcrun devicectl device process terminate --device "$udid" --pid "$pid" 2>&1; then
        print_success "No matching process running (already stopped)"
        return 0
    fi
    print_success "Stopped"
}

_ios_cmd_clean() {
    local nuclear=false clean_logs=false remaining=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nuclear) nuclear=true; shift ;;
            --logs)    clean_logs=true; shift ;;
            -h|--help)
                cat <<'HELP'
Usage: tron ios clean [--nuclear] [--logs] [scheme flags]

  (no flags)   Scheme-aware xcodebuild clean
  --nuclear    Wipe all DerivedData (workspace + ~/Library/.../DerivedData)
  --logs       Remove /tmp/tron-ios-*.log and .xcresult files
HELP
                return 0 ;;
            *) remaining+=("$1"); shift ;;
        esac
    done

    if $clean_logs; then
        local removed=0
        # Count matches first so we can report 0 cleanly
        shopt -s nullglob
        local matches=(/tmp/tron-ios-*.log /tmp/tron-ios-*.xcresult)
        shopt -u nullglob
        removed=${#matches[@]}
        rm -rf /tmp/tron-ios-*.log /tmp/tron-ios-*.xcresult 2>/dev/null || true
        rm -f "$IOS_LAST_LOG_PATH" "$IOS_LAST_XCRESULT_PATH" 2>/dev/null || true
        print_success "Removed $removed iOS log/xcresult artifact(s)"
        $nuclear || return 0
    fi

    if $nuclear; then
        print_status "Nuclear clean — removing all DerivedData"
        # Guarded paths: ${var:?} errors if the variable is unset/empty, preventing rm -rf /
        rm -rf "${PROJECT_DIR:?PROJECT_DIR unset}/${IOS_DERIVED_DATA_REL:?IOS_DERIVED_DATA_REL unset}" 2>/dev/null || true
        rm -rf "${IOS_GLOBAL_DERIVED_DATA:?IOS_GLOBAL_DERIVED_DATA unset}"/TronMobile-* 2>/dev/null || true
        print_success "Removed workspace and global DerivedData"
        return 0
    fi

    _ios_parse_common_flags ${remaining[@]+"${remaining[@]}"}
    print_status "Cleaning $IOS_SCHEME"
    ( cd "$PROJECT_DIR/packages/ios-app" && xcodebuild clean \
        -project TronMobile.xcodeproj \
        -scheme "$IOS_SCHEME" \
        -derivedDataPath .build/DerivedData \
        -quiet ) || { print_error "Clean failed"; exit 1; }
    print_success "Cleaned"
}

_ios_cmd_test() {
    local only_testing="" remaining=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only-testing) only_testing="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: tron ios test [-b] [-s [name]] [--only-testing <id>] [-v]"
                echo "Runs the test suite on a simulator (physical devices not supported here)."
                return 0 ;;
            *) remaining+=("$1"); shift ;;
        esac
    done

    _ios_parse_common_flags ${remaining[@]+"${remaining[@]}"}

    # Tests always run on simulator
    if [[ "$IOS_IS_SIM" != "true" ]]; then
        IOS_IS_SIM="true"
        IOS_SIM_NAME="$(_ios_get_default_simulator)"
        IOS_DEST="platform=iOS Simulator,name=$IOS_SIM_NAME"
    fi

    print_status "Testing $IOS_SCHEME on $IOS_SIM_NAME"
    local -a xargs=(
        test
        -project TronMobile.xcodeproj
        -scheme "$IOS_SCHEME"
        -destination "$IOS_DEST"
        -derivedDataPath .build/DerivedData
    )
    [[ -n "$only_testing" ]] && xargs+=(-only-testing "$only_testing")

    ( cd "$PROJECT_DIR/packages/ios-app" && _ios_run_xcodebuild "${xargs[@]}" ) || return 1
    print_success "Tests passed"
}

_ios_cmd_logs() {
    local minutes=5 remaining=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minutes) minutes="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: tron ios logs [--minutes N] [-b] [-d alias|-u UDID|-s] [-v]"
                echo "Device: collects last N minutes (default 5), filtered to the bundle."
                echo "Simulator (-s): streams live logs from the Mac."
                return 0 ;;
            *) remaining+=("$1"); shift ;;
        esac
    done

    _ios_parse_common_flags ${remaining[@]+"${remaining[@]}"}

    if [[ "$IOS_IS_SIM" == "true" ]]; then
        print_status "Streaming simulator logs for TronMobile (Ctrl+C to stop)"
        /usr/bin/log stream --process TronMobile --level debug
        return 0
    fi

    _ios_ensure_target_or_bail
    [[ -z "$IOS_UDID" ]] && { print_error "No UDID resolved"; exit 1; }

    local ts out
    ts="$(date +%s)"
    out="/tmp/tron-device-logs-${ts}.logarchive"
    print_status "Collecting last ${minutes}m of logs from $IOS_UDID"
    if ! /usr/bin/log collect --device-udid "$IOS_UDID" --last "${minutes}m" --output "$out"; then
        print_error "Log collection failed. Is the device connected?"
        exit 1
    fi

    print_success "Saved: $out"
    print_status "Showing entries matching $IOS_BUNDLE_ID"
    if [[ "$IOS_VERBOSE" == "true" ]]; then
        /usr/bin/log show "$out" --predicate "subsystem == \"$IOS_BUNDLE_ID\"" --style compact
    else
        /usr/bin/log show "$out" --predicate "subsystem == \"$IOS_BUNDLE_ID\"" --style compact | tail -100
    fi
}

_ios_cmd_gen() {
    if ! command -v xcodegen >/dev/null 2>&1; then
        print_error "xcodegen not installed"
        echo "  Install: brew install xcodegen"
        exit 1
    fi
    print_status "Regenerating Xcode project"
    ( cd "$PROJECT_DIR/packages/ios-app" && xcodegen generate ) \
        || { print_error "xcodegen failed"; exit 1; }
    print_success "Regenerated $IOS_PROJECT_REL"
}

#=============================================================================
# HELP
#=============================================================================

_ios_print_help() {
    cat <<'HELP'

tron ios - Build, run, and manage TronMobile on iOS devices and simulators

Usage: tron ios [subcommand] [options]

If no subcommand is given, defaults to `run` (build + install + launch).

Subcommands:
  build                 Compile only (no launch)
  run                   Build + install + launch (default)
  stop                  Terminate the running app
  clean                 Clean build artifacts (--nuclear for full wipe, --logs for temp logs)
  test                  Run the test suite on simulator
  logs                  Collect and view recent logs
  gen                   Regenerate Xcode project via xcodegen
  devices               Manage saved devices (list | add | remove | default | scan)

Scheme flags:
  -b, --beta            Tron Beta scheme (com.tron.mobile.beta)
  -p, --prod            Tron Prod scheme (default)
  --scheme <name>       Arbitrary scheme (requires --bundle-id)
  --bundle-id <id>      Bundle ID (only valid with --scheme)

Target flags (mutually exclusive):
  -d, --device <alias>  Saved device by alias
  -u, --udid <UDID>     Physical device by UDID
  -s, --sim [name]      Simulator (default from settings)
  -g, --generic         Compile for generic iOS (no device)

Output:
  -v, --verbose         Stream full xcodebuild output
  -h, --help            Subcommand-specific help

Examples:
  tron ios                       # Build + run prod on default device
  tron ios -b                    # Build + run beta on default device
  tron ios -d ipad -b            # Build + run beta on 'ipad' alias
  tron ios -s                    # Build + run on default simulator
  tron ios build -g              # Compile check (no device)
  tron ios stop                  # Stop last-launched app
  tron ios clean --nuclear       # Deep clean of DerivedData
  tron ios devices add           # Register a connected device
  tron ios devices default ipad  # Set default device

Device info is stored in ~/.tron/system/settings.json under the `ios` key.
Run `tron ios devices add` to register your devices on first use.

HELP
}

#=============================================================================
# PUBLIC ENTRY POINT
#=============================================================================

cmd_ios() {
    _ios_require_macos
    _ios_require_xcode
    _ios_require_project
    require_project_dir

    # Top-level help takes precedence over the default-to-run rule
    case "${1:-}" in
        help|-h|--help) _ios_print_help; return 0 ;;
    esac

    local subcommand=""
    if [[ $# -eq 0 || "$1" == -* ]]; then
        subcommand="run"
    else
        subcommand="$1"
        shift
    fi

    case "$subcommand" in
        build)    _ios_cmd_build "$@" ;;
        run)      _ios_cmd_run "$@" ;;
        stop)     _ios_cmd_stop "$@" ;;
        clean)    _ios_cmd_clean "$@" ;;
        test)     _ios_cmd_test "$@" ;;
        logs)     _ios_cmd_logs "$@" ;;
        gen)      _ios_cmd_gen "$@" ;;
        devices)  _ios_cmd_devices "$@" ;;
        *)
            print_error "Unknown ios subcommand: $subcommand"
            echo ""
            _ios_print_help
            exit 1 ;;
    esac
}
