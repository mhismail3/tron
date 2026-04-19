#!/bin/bash
# tron-lib.sh - Shared library for Tron CLI scripts
#
# SINGLE SOURCE OF TRUTH for all paths, config, and shared functions.
# Sourced by: scripts/tron, scripts/tron-cli, scripts/auto-deploy, scripts/reset-db
#
# Do NOT execute this file directly.

#=============================================================================
# CONFIGURATION
#=============================================================================

TRON_HOME="${TRON_DATA_DIR:-$HOME/.tron}"
BIN_DIR="$HOME/.local/bin"

# App bundle paths — macOS TCC identifies apps by CFBundleIdentifier, so wrapping
# the binary in a .app bundle ensures permissions persist across binary replacements.
TRON_BUNDLE_ID="com.tron.agent"
INSTALLED_BUNDLE="$TRON_HOME/system/Tron.app"
INSTALLED_BINARY="$INSTALLED_BUNDLE/Contents/MacOS/tron"
DEV_BUNDLE="$TRON_HOME/system/deployment/Tron-Dev.app"
DEV_BINARY="$DEV_BUNDLE/Contents/MacOS/tron"

# Keychain profile name for xcrun notarytool (see notarize_bundle).
# One-time setup per developer machine:
#   xcrun notarytool store-credentials "tron-notarize" \
#     --apple-id <email> --team-id <TEAM_ID>
NOTARIZE_PROFILE="tron-notarize"

# Service configuration
PLIST_NAME="com.tron.server"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
PROD_PORT=9847

# File paths
DEPLOY_DIR="$TRON_HOME/system/deployment"
DEPLOYED_COMMIT_FILE="$DEPLOY_DIR/deployed-commit"

# Database
DB_PATH="$TRON_HOME/system/database/log.db"

# OAuth
AUTH_FILE="$TRON_HOME/system/auth.json"

# Anthropic OAuth
ANTHROPIC_OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
ANTHROPIC_OAUTH_AUTH_ENDPOINT="https://claude.ai/oauth/authorize"
ANTHROPIC_OAUTH_TOKEN_ENDPOINT="https://console.anthropic.com/v1/oauth/token"
ANTHROPIC_OAUTH_REDIRECT_URI="https://console.anthropic.com/oauth/code/callback"
ANTHROPIC_OAUTH_SCOPES="org:create_api_key user:profile user:inference"

# OpenAI OAuth
OPENAI_OAUTH_CLIENT_ID="app_EMoamEEZ73f0CkXaXp7hrann"
OPENAI_OAUTH_AUTH_ENDPOINT="https://auth.openai.com/oauth/authorize"
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token"
OPENAI_OAUTH_REDIRECT_URI="http://localhost:1455/auth/callback"
OPENAI_OAUTH_SCOPES="openid profile email offline_access"
OPENAI_OAUTH_PORT=1455

#=============================================================================
# COLORS & PRINT HELPERS
#=============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

print_status()  { echo -e "${BLUE}▸${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_header()  { echo -e "\n${CYAN}$1${NC}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

#=============================================================================
# UTILITY FUNCTIONS
#=============================================================================

require_installed() {
    if [ ! -f "$PLIST_PATH" ]; then
        print_error "Tron not installed. Run: tron install"
        exit 1
    fi
}

confirm_action() {
    read -p "$1 (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

ensure_tron_home() {
    mkdir -p "$TRON_HOME"/system/{database,deployment}
    mkdir -p "$TRON_HOME"/workspace/{knowledge,automations,scratch}
    mkdir -p "$TRON_HOME"/workspace/memory/{rules,sessions}
    mkdir -p "$TRON_HOME"/skills
    mkdir -p "$TRON_HOME/workspace/voice notes"
}

ensure_default_configs() {
    if [ ! -f "$TRON_HOME/system/settings.json" ]; then
        cat > "$TRON_HOME/system/settings.json" << 'EOF'
{
  "server": {
    "defaultModel": "claude-sonnet-4-20250514",
    "defaultProvider": "anthropic",
    "port": 9847
  },
  "logging": {
    "dbLogLevel": "info"
  },
  "tools": {
    "bash": { "defaultTimeoutMs": 120000 },
    "read": { "defaultLimitLines": 2000 }
  }
}
EOF
        print_success "Created settings.json"
    fi

    if [ ! -f "$TRON_HOME/system/auth.json" ]; then
        cat > "$TRON_HOME/system/auth.json" << 'EOF'
{
  "version": 1,
  "providers": {},
  "lastUpdated": ""
}
EOF
        chmod 600 "$TRON_HOME/system/auth.json"
        print_success "Created auth.json"
    fi
}

wait_for_port_free() {
    local port=$1
    local max_wait=${2:-10}
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if ! lsof -t -i :"$port" -sTCP:LISTEN &>/dev/null; then
            return 0
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    return 1
}

#=============================================================================
# LAUNCHD HELPERS — modern API (bootout/bootstrap/kickstart) with fallback
#=============================================================================

_launchd_target() { echo "gui/$(id -u)/$1"; }

launchd_stop() {
    launchctl bootout "$(_launchd_target "$1")" 2>/dev/null \
        || launchctl unload "$HOME/Library/LaunchAgents/$1.plist" 2>/dev/null \
        || true
}

launchd_start() {
    local plist="$HOME/Library/LaunchAgents/$1.plist"
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null \
        || launchctl load "$plist" 2>/dev/null \
        || true
}

launchd_restart() {
    launchctl kickstart -k "$(_launchd_target "$1")" 2>/dev/null \
        || { launchd_stop "$1"; sleep 1; launchd_start "$1"; }
}

launchd_is_loaded() {
    launchctl print "$(_launchd_target "$1")" &>/dev/null
}

#=============================================================================
# SERVICE FUNCTIONS
#=============================================================================

service_is_running() {
    launchd_is_loaded "$PLIST_NAME"
}

get_service_pid() {
    lsof -t -i :$PROD_PORT -sTCP:LISTEN 2>/dev/null || true
}

validate_prod_binary() {
    [ -f "$INSTALLED_BINARY" ] && file "$INSTALLED_BINARY" 2>/dev/null | grep -q "Mach-O"
}

# Base version: restores from backup only.
# Workspace script overrides this to also try $RELEASE_BINARY.
ensure_prod_binary() {
    if validate_prod_binary; then
        return 0
    fi

    print_warning "Production binary is missing or corrupt"

    if [ -f "$DEPLOY_DIR/tron.bak" ] && file "$DEPLOY_DIR/tron.bak" 2>/dev/null | grep -q "Mach-O"; then
        print_status "Restoring from backup..."
        create_app_bundle "$INSTALLED_BUNDLE" "$DEPLOY_DIR/tron.bak"
        codesign_bundle "$INSTALLED_BUNDLE"
        print_success "Restored from backup"
        return 0
    fi

    print_error "No valid binary found. Run: tron deploy"
    return 1
}

service_start() {
    if [ ! -f "$PLIST_PATH" ]; then
        print_error "Service not installed. Run: tron install"
        return 1
    fi
    if ! ensure_prod_binary; then
        return 1
    fi

    print_status "Starting service..."
    launchd_restart "$PLIST_NAME"
    sleep 2

    if service_is_running; then
        local pid=$(get_service_pid)
        print_success "Service started (PID: ${pid:-unknown})"
        echo "  Server: http://localhost:$PROD_PORT"
        echo "  Health: http://localhost:$PROD_PORT/health"
    else
        print_error "Failed to start service. Check: tron errors"
        return 1
    fi
}

service_stop() {
    if ! service_is_running; then
        print_warning "Service is not running"
        return 0
    fi

    print_status "Stopping service..."
    launchd_stop "$PLIST_NAME"

    if wait_for_port_free "$PROD_PORT" 10; then
        print_success "Service stopped"
    else
        print_error "Failed to stop service"
        return 1
    fi
}

health_check() {
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PROD_PORT/health" 2>/dev/null || echo "000")
    [ "$response" = "200" ]
}

# Create a minimal headless .app bundle for macOS TCC identity.
# macOS identifies app bundles by CFBundleIdentifier — a stable string that
# survives binary replacements. This is how permissions persist across deploys.
create_app_bundle() {
    local bundle_path="$1"
    local binary_src="$2"
    local version="${3:-1.0.0}"

    # Delete the entire .app bundle, not just its contents. macOS App
    # Management TCC protects files *inside* .app bundles from modification
    # by non-authorized processes (launchd agents). But deleting the .app
    # itself is a parent-directory operation on ~/.tron/system/, which is
    # not protected. codesign_bundle re-signs the new bundle afterward.
    rm -rf "$bundle_path"

    mkdir -p "$bundle_path/Contents/MacOS"
    mkdir -p "$bundle_path/Contents/Resources"

    cat > "$bundle_path/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$TRON_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Tron</string>
    <key>CFBundleDisplayName</key>
    <string>Tron</string>
    <key>CFBundleExecutable</key>
    <string>tron</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

    # Copy icon if available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "$script_dir/AppIcon.icns" \
        "$DEPLOY_DIR/AppIcon.icns"; do
        if [ -f "$candidate" ]; then
            cp "$candidate" "$bundle_path/Contents/Resources/AppIcon.icns"
            break
        fi
    done

    cp "$binary_src" "$bundle_path/Contents/MacOS/tron"
    chmod +x "$bundle_path/Contents/MacOS/tron"
}

# Sign an app bundle with the best available codesigning identity.
# Priority: Developer ID Application > Apple Development > any valid cert > ad-hoc.
# Uses hardened runtime + entitlements when possible, with tiered fallback.
codesign_bundle() {
    local bundle="$1"
    local identity entitlements

    # Find valid identity — filter revoked, prefer Developer ID > Apple Development
    identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -v "REVOKED" \
        | grep '"Developer ID Application' \
        | head -1 \
        | sed -n 's/.*"\(.*\)".*/\1/p')
    if [ -z "$identity" ]; then
        identity=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -v "REVOKED" \
            | grep '"Apple Development' \
            | head -1 \
            | sed -n 's/.*"\(.*\)".*/\1/p')
    fi
    if [ -z "$identity" ]; then
        identity=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -v "REVOKED" \
            | grep '"' \
            | head -1 \
            | sed -n 's/.*"\(.*\)".*/\1/p')
    fi

    # Locate entitlements file
    entitlements=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "$script_dir/tron-agent.entitlements" \
        "$DEPLOY_DIR/tron-agent.entitlements"; do
        if [ -f "$candidate" ]; then
            entitlements="$candidate"
            break
        fi
    done

    # Tier 1: Full signing (cert + hardened runtime + entitlements)
    if [ -n "$identity" ] && [ -n "$entitlements" ]; then
        if codesign --force --deep --sign "$identity" \
               --identifier "$TRON_BUNDLE_ID" \
               --options runtime \
               --entitlements "$entitlements" \
               "$bundle" 2>/dev/null && \
           codesign --verify --strict "$bundle" 2>/dev/null; then
            print_status "Signed bundle (${identity})"
            return 0
        fi
    fi

    # Tier 2: Cert + hardened runtime without entitlements
    if [ -n "$identity" ]; then
        if codesign --force --deep --sign "$identity" \
               --identifier "$TRON_BUNDLE_ID" \
               --options runtime \
               "$bundle" 2>/dev/null && \
           codesign --verify --strict "$bundle" 2>/dev/null; then
            print_status "Signed bundle without entitlements (${identity})"
            return 0
        fi
    fi

    # Tier 3: Ad-hoc signing (no cert — works for dev, not distribution)
    if codesign --force --deep --sign - \
           --identifier "$TRON_BUNDLE_ID" \
           "$bundle" 2>/dev/null; then
        print_status "Ad-hoc signed bundle"
        return 0
    fi

    print_status "Code signing failed — bundle will be unsigned"
}

# Notarize an app bundle via Apple's notary service and staple the ticket.
#
# Notarization is required for distributing signed binaries to other users
# without Gatekeeper friction. It also preserves TCC permissions for end
# users across updates (the stapled ticket + Developer ID identity form a
# stable identifier that survives binary replacement).
#
# Non-fatal by design: every failure path returns 0. Notarization is
# orthogonal to TCC persistence on the build machine itself (signing alone
# handles that). Deploy should never fail because notarization failed.
#
# Preconditions for notarization to actually run (all must be true; otherwise
# it skips with a clear warning):
#   1. Bundle exists and is a directory
#   2. Bundle is signed with a Developer ID Application cert (not ad-hoc,
#      not Apple Development — Apple's notary service rejects those)
#   3. `xcrun notarytool` is available (recent Xcode/Command Line Tools)
#   4. Keychain profile $NOTARIZE_PROFILE exists (one-time user setup)
notarize_bundle() {
    local bundle="$1"
    local temp_zip=""

    # Cleanup fires on any return path (success, skip, or error).
    # RETURN trap is function-scoped in bash; we clear it before returning
    # to avoid inheriting into the caller's frame on some bash versions.
    trap 'if [ -n "$temp_zip" ] && [ -f "$temp_zip" ]; then rm -f "$temp_zip"; fi; trap - RETURN' RETURN

    # Precondition 1: bundle exists
    if [ -z "$bundle" ] || [ ! -d "$bundle" ]; then
        print_status "Notarization skipped: bundle not found at ${bundle:-<empty>}"
        return 0
    fi

    # Precondition 2: bundle is signed with Developer ID Application.
    # Ad-hoc and Apple Development certs cannot be notarized.
    local sig_info
    sig_info=$(codesign -dvvv "$bundle" 2>&1 || true)
    if echo "$sig_info" | grep -q "Signature=adhoc"; then
        print_status "Notarization skipped: bundle is ad-hoc signed (requires Developer ID)"
        return 0
    fi
    if ! echo "$sig_info" | grep -q "Authority=Developer ID Application"; then
        print_status "Notarization skipped: bundle not signed with Developer ID Application"
        return 0
    fi

    # Precondition 3: xcrun notarytool must be available
    if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find notarytool >/dev/null 2>&1; then
        print_warning "Notarization skipped: xcrun notarytool not available (install Xcode Command Line Tools)"
        return 0
    fi

    # Precondition 4: keychain profile must exist and credentials must work.
    # We probe with `notarytool history` because there is no offline credential
    # check. This makes a small network call (~1-2s) but gives us a clean
    # fast-fail before zipping the bundle on misconfigured machines.
    local history_err
    if ! history_err=$(xcrun notarytool history --keychain-profile "$NOTARIZE_PROFILE" 2>&1); then
        # Distinguish "credentials missing" from "network / service issue"
        # so the hint we print is actually useful.
        if echo "$history_err" | grep -qiE "keychain profile|no such keychain|credentials|could not find"; then
            print_warning "Notarization skipped: keychain profile '$NOTARIZE_PROFILE' not configured"
            echo "  One-time setup:"
            echo "    xcrun notarytool store-credentials \"$NOTARIZE_PROFILE\" \\"
            echo "      --apple-id <email> --team-id <TEAM_ID>"
            echo "  Get an app-specific password at: https://appleid.apple.com"
        else
            print_warning "Notarization skipped: notarytool check failed (network or service issue)"
            echo "$history_err" | tail -3 | sed 's/^/    /'
        fi
        return 0
    fi

    # Create temp zip. mktemp creates the file; ditto needs a non-existent
    # target, so we remove it first.
    temp_zip=$(mktemp -t tron-notarize.XXXXXX).zip
    rm -f "$temp_zip"
    print_status "Preparing bundle for notarization..."
    if ! ditto -c -k --keepParent "$bundle" "$temp_zip" 2>/dev/null; then
        print_warning "Notarization skipped: failed to create zip archive"
        return 0
    fi

    # Submit and wait (up to 15 minutes — typical submission is 1-5 minutes).
    print_status "Submitting to Apple notary service (may take a few minutes)..."
    local notarize_output
    if notarize_output=$(xcrun notarytool submit "$temp_zip" \
            --keychain-profile "$NOTARIZE_PROFILE" \
            --wait --timeout 15m 2>&1); then

        if echo "$notarize_output" | grep -q "status: Accepted"; then
            print_success "Notarization accepted"

            # Staple the ticket to the bundle so it works offline.
            # Stapling writes to Contents/CodeResources — safe even if the
            # bundle's binary is currently running.
            if xcrun stapler staple "$bundle" >/dev/null 2>&1; then
                print_success "Stapled notarization ticket"
            else
                print_warning "Stapling failed (notarization is still valid on Apple's servers, ticket just isn't embedded)"
            fi
            return 0
        fi

        # Submission completed but not accepted (Invalid / Rejected)
        print_warning "Notarization was not accepted by Apple:"
        echo "$notarize_output" | tail -20 | sed 's/^/    /'

        # Try to surface the submission ID so the user can fetch detailed logs
        local submission_id
        submission_id=$(echo "$notarize_output" \
            | grep -oE 'id: [a-f0-9-]{36}' \
            | head -1 \
            | awk '{print $2}')
        if [ -n "$submission_id" ]; then
            echo "  For details:"
            echo "    xcrun notarytool log $submission_id --keychain-profile $NOTARIZE_PROFILE"
        fi
        return 0
    else
        # Submission itself failed (network timeout, auth error, ...).
        print_warning "Notarization submission failed (non-fatal):"
        echo "$notarize_output" | tail -10 | sed 's/^/    /'
        return 0
    fi
}

# Convenience wrapper: codesign + notarize in one call.
# Used by production flows (cmd_deploy, cmd_install). Dev flows and the
# emergency rollback path call codesign_bundle directly to stay fast.
sign_and_notarize() {
    local bundle="$1"
    codesign_bundle "$bundle"
    notarize_bundle "$bundle"
}

#=============================================================================
# LOG FUNCTIONS
#=============================================================================

query_logs() {
    local level=""
    local output=""
    local limit=50
    local session=""
    local search=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--level)   level="$2"; shift 2 ;;
            -o|--output)  output="$2"; shift 2 ;;
            -n|--limit)   limit="$2"; shift 2 ;;
            -s|--session) session="$2"; shift 2 ;;
            -q|--search)  search="$2"; shift 2 ;;
            -h|--help)
                echo ""
                echo -e "${CYAN}tron logs${NC} - Query database logs"
                echo ""
                echo "Usage: tron logs [options]"
                echo ""
                echo "Options:"
                echo "  -l, --level LEVEL    Filter by level (trace/debug/info/warn/error)"
                echo "  -n, --limit N        Number of logs to show (default: 50)"
                echo "  -o, --output FILE    Write output to file"
                echo "  -s, --session ID     Filter by session ID"
                echo "  -q, --search TEXT    Search log messages"
                echo ""
                return 0
                ;;
            *) shift ;;
        esac
    done

    # Database mode
    if [ ! -f "$DB_PATH" ]; then
        print_error "Database not found: $DB_PATH"
        echo "The server may not have been started yet."
        return 1
    fi

    local table_exists
    table_exists=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='logs';" 2>/dev/null)
    if [ -z "$table_exists" ]; then
        print_error "Logs table not found in database"
        return 1
    fi

    # Build SQL query
    local conditions=()

    if [ -n "$level" ]; then
        local level_num
        case "$level" in
            trace) level_num=10 ;;
            debug) level_num=20 ;;
            info)  level_num=30 ;;
            warn)  level_num=40 ;;
            error) level_num=50 ;;
            *)
                print_error "Invalid level: $level (valid: trace/debug/info/warn/error)"
                return 1
                ;;
        esac
        conditions+=("level_num >= $level_num")
    fi

    [ -n "$session" ] && conditions+=("session_id LIKE '%$session%'")

    local where_clause=""
    if [ ${#conditions[@]} -gt 0 ]; then
        where_clause="WHERE $(IFS=' AND '; echo "${conditions[*]}")"
    fi

    local sql
    if [ -n "$search" ]; then
        local escaped_search="${search//\'/\'\'}"
        local search_cond="(message LIKE '%${escaped_search}%' OR component LIKE '%${escaped_search}%' OR error_message LIKE '%${escaped_search}%')"
        sql="SELECT timestamp, level, component, message, session_id, error_message
             FROM logs
             WHERE ${search_cond}
             ${where_clause:+AND ${where_clause#WHERE }}
             ORDER BY timestamp DESC
             LIMIT $limit"
    else
        sql="SELECT timestamp, level, component, message, session_id, error_message
             FROM logs
             $where_clause
             ORDER BY timestamp DESC
             LIMIT $limit"
    fi

    local result
    result=$(sqlite3 -separator '|' "$DB_PATH" "$sql" 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Database query failed: $result"
        return 1
    fi

    if [ -z "$result" ]; then
        echo -e "${DIM}No logs found matching criteria${NC}"
        return 0
    fi

    if [ -n "$output" ]; then
        echo "$result" | while IFS='|' read -r ts lvl comp msg sess err; do
            local line="${ts} ${lvl} [${comp}] ${msg}"
            [ -n "$sess" ] && line="$line (${sess})"
            [ -n "$err" ] && line="$line | Error: $err"
            echo "$line"
        done > "$output"
        print_success "Wrote $(wc -l < "$output" | tr -d ' ') logs to $output"
    else
        echo -e "${CYAN}Database Logs${NC}"
        echo -e "${DIM}Database: $DB_PATH${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$result" | while IFS='|' read -r ts lvl comp msg sess err; do
            local color=""
            case "$lvl" in
                TRACE|DEBUG|trace|debug) color="$DIM" ;;
                INFO|info)  color="$GREEN" ;;
                WARN|warn)  color="$YELLOW" ;;
                ERROR|error) color="$RED" ;;
            esac

            local time_part="${ts:11:8}"
            local line="${time_part} ${color}${lvl}${NC} [${comp}] ${msg}"
            [ -n "$sess" ] && line="$line ${DIM}(${sess:0:12}...)${NC}"
            [ -n "$err" ] && line="$line\n  ${RED}Error: $err${NC}"

            echo -e "$line"
        done
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        local count=$(echo "$result" | wc -l | tr -d ' ')
        echo -e "${DIM}Showing $count logs (limit: $limit)${NC}"
    fi
}

#=============================================================================
# DEPLOYMENT HELPERS
#=============================================================================

write_deployment_result() {
    local status="$1"
    local error_msg="${2:-null}"
    local commit
    local previous_commit

    commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    previous_commit=$(cat "$DEPLOYED_COMMIT_FILE" 2>/dev/null || echo "unknown")

    if [ "$error_msg" = "null" ]; then
        error_msg="null"
    else
        error_msg="\"$error_msg\""
    fi

    cat > "$DEPLOY_DIR/last-deployment.json" << RESULT
{
  "status": "$status",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "commit": "$commit",
  "previousCommit": "$previous_commit",
  "error": $error_msg
}
RESULT
}

#=============================================================================
# COMMAND HANDLERS
#=============================================================================

cmd_status() {
    # $PROJECT_DIR is set by workspace script; otherwise try workspace-path file
    local git_dir="${PROJECT_DIR:-}"
    if [ -z "$git_dir" ] && [ -f "$DEPLOY_DIR/workspace-path" ]; then
        git_dir=$(cat "$DEPLOY_DIR/workspace-path")
    fi

    echo ""
    echo -e "${CYAN}Tron Service Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if service_is_running; then
        local pid=$(get_service_pid)
        print_success "Prod:    ${GREEN}RUNNING${NC} (PID: ${pid:-unknown})"
        echo "  Server: http://localhost:$PROD_PORT"
        echo "  Health: http://localhost:$PROD_PORT/health"

        if [ -n "$pid" ] && [ "$pid" != "-" ]; then
            local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
            [ -n "$uptime" ] && echo "  Uptime: $uptime"
        fi

        if health_check; then
            echo -e "  Status: ${GREEN}Healthy${NC}"
        else
            echo -e "  Status: ${YELLOW}Not responding${NC}"
        fi

        if [ -f "$DEPLOYED_COMMIT_FILE" ]; then
            local deployed_commit=$(cat "$DEPLOYED_COMMIT_FILE")
            local commit_msg=""
            if [ -n "$git_dir" ] && [ -d "$git_dir/.git" ]; then
                commit_msg=$(cd "$git_dir" 2>/dev/null && git log -1 --format="%s" "$deployed_commit" 2>/dev/null | head -c 50)
            fi
            if [ -n "$commit_msg" ]; then
                echo "  Deployed: ${deployed_commit:0:7} - $commit_msg"
            else
                echo "  Deployed: ${deployed_commit:0:7}"
            fi
        fi

        [ -f "$INSTALLED_BINARY" ] && echo "  Binary: $INSTALLED_BINARY"
    else
        print_warning "Service: ${YELLOW}STOPPED${NC}"
        [ -f "$DEPLOYED_COMMIT_FILE" ] && echo "  Last deployed: $(cat "$DEPLOYED_COMMIT_FILE" | head -c 7)"
        [ -f "$INSTALLED_BINARY" ] && echo "  Binary: $INSTALLED_BINARY"
    fi

    # Dev takeover status
    if ! service_is_running; then
        local dev_pid
        dev_pid=$(lsof -t -i :$PROD_PORT -sTCP:LISTEN 2>/dev/null || true)
        if [ -n "$dev_pid" ]; then
            echo ""
            print_success "Dev takeover: ${GREEN}ACTIVE${NC} (PID: $dev_pid)"
            echo "  Server: http://localhost:$PROD_PORT"
            local dev_uptime=$(ps -o etime= -p "$dev_pid" 2>/dev/null | tr -d ' ')
            [ -n "$dev_uptime" ] && echo "  Uptime: $dev_uptime"
        fi
    fi

    echo ""
    echo -e "${DIM}Logs:${NC}"
    echo -e "  ${DIM}Query: tron logs [-l level] [-q search] [-s session]${NC}"
    echo ""
}

cmd_start() {
    if service_is_running; then
        print_warning "Service is already running"
        return 0
    fi
    service_start
}

cmd_stop() {
    service_stop
}

cmd_restart() {
    print_status "Restarting service..."
    service_stop 2>/dev/null || true
    sleep 1
    service_start
}

cmd_errors() {
    if [ -f "$DB_PATH" ]; then
        echo -e "${RED}Recent errors from database:${NC}"
        sqlite3 -header -column "$DB_PATH" \
            "SELECT timestamp as time, level, message
             FROM logs
             WHERE level_num >= 50
             ORDER BY timestamp DESC
             LIMIT 20;" 2>/dev/null || echo "  No logs table found"
    fi

}

cmd_rollback() {
    local skip_confirm=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) skip_confirm=true; shift ;;
            *)     shift ;;
        esac
    done

    print_header "Rolling Back to Previous Binary"

    if [ ! -f "$DEPLOY_DIR/tron.bak" ]; then
        print_error "No backup found. Cannot rollback."
        echo "  A backup is only available immediately after a deploy."
        exit 1
    fi

    if ! $skip_confirm; then
        if ! confirm_action "Restore previous binary from backup?"; then
            print_error "Aborted."
            exit 1
        fi
    fi

    # Stop service
    print_status "Stopping service..."
    launchd_stop "$PLIST_NAME"
    sleep 1

    # Restore backup
    print_status "Restoring backup..."
    create_app_bundle "$INSTALLED_BUNDLE" "$DEPLOY_DIR/tron.bak"
    codesign_bundle "$INSTALLED_BUNDLE"

    # Start service
    launchd_start "$PLIST_NAME"
    sleep 3

    if service_is_running; then
        print_success "Service restarted from backup"
    else
        print_error "Failed to restart service after rollback"
    fi

    write_deployment_result "rolled_back" "Manual rollback"

    echo ""
    print_success "Rollback complete!"
    echo ""
}

#=============================================================================
# AUTH COMMANDS
#=============================================================================

base64url_encode() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

cmd_login() {
    local label=""
    local host_override=""
    local provider=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --label) label="$2"; shift 2 ;;
            --host) host_override="$2"; shift 2 ;;
            --provider) provider="$2"; shift 2 ;;
            --status) cmd_login_status; return ;;
            -h|--help)
                echo ""
                echo "Usage: tron login [--provider <name>] [--label <name>] [--host <hostname>] [--status]"
                echo ""
                echo "  --provider <name>    Provider: anthropic or openai (skips menu)"
                echo "  --label <name>       Account label (default: \$USER@hostname)"
                echo "  --host <hostname>    Override hostname portion of default label"
                echo "  --status             Show current auth status"
                echo ""
                echo "Each machine should have its own OAuth session to avoid token"
                echo "conflicts. The default label uses your hostname to ensure this."
                echo ""
                return ;;
            *) print_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Show existing accounts for all providers
    if [[ -f "$AUTH_FILE" ]]; then
        local now_ms=$(( $(date +%s) * 1000 ))
        _show_provider_accounts "anthropic" "Anthropic" "$now_ms"
        _show_provider_accounts "openai-codex" "OpenAI" "$now_ms"
    fi

    # Provider selection
    if [[ -z "$provider" ]]; then
        echo ""
        echo -e "${BOLD}Select provider:${NC}"
        echo "  1. Anthropic (Claude)"
        echo "  2. OpenAI (Codex)"
        echo ""
        printf "Choice [1]: "
        read -r choice
        case "${choice:-1}" in
            1|anthropic) provider="anthropic" ;;
            2|openai)    provider="openai" ;;
            *)
                print_error "Invalid choice: $choice"
                return 1 ;;
        esac
    fi

    case "$provider" in
        anthropic) cmd_login_anthropic "$label" "$host_override" ;;
        openai)    cmd_login_openai "$label" "$host_override" ;;
        *)
            print_error "Unknown provider: $provider (use 'anthropic' or 'openai')"
            return 1 ;;
    esac
}

_show_provider_accounts() {
    local provider_key="$1"
    local display_name="$2"
    local now_ms="$3"

    local account_count
    account_count=$(jq -r ".providers[\"${provider_key}\"].accounts // [] | length" "$AUTH_FILE" 2>/dev/null)
    if [[ "$account_count" -gt 0 ]]; then
        echo ""
        echo -e "${DIM}Existing ${display_name} accounts:${NC}"
        jq -r --argjson now "$now_ms" --arg pk "$provider_key" '
            .providers[$pk].accounts | to_entries[] |
            .value.label as $l |
            .value.oauth.expiresAt as $e |
            (.key + 1) as $i |
            if $e > $now then
                "  \($i). \($l)  (expires \($e / 1000 | strftime("%Y-%m-%d %H:%M")) \u2014 \u001b[32mvalid\u001b[0m)"
            else
                "  \($i). \($l)  (expires \($e / 1000 | strftime("%Y-%m-%d %H:%M")) \u2014 \u001b[31mEXPIRED\u001b[0m)"
            end
        ' "$AUTH_FILE" 2>/dev/null | while IFS= read -r line; do echo -e "$line"; done
        echo ""
    fi
}

_prompt_account_label() {
    local label="$1"
    local host_override="$2"

    if [[ -z "$label" ]]; then
        local hostname_short
        hostname_short="${host_override:-$(hostname -s 2>/dev/null || hostname | cut -d. -f1)}"
        local default_label="${USER:-default}@${hostname_short}"
        printf "Account label [${BOLD}%s${NC}]: " "$default_label" >&2
        read -r label
        label="${label:-$default_label}"
    fi

    echo "$label"
}

_save_oauth_tokens() {
    local provider_key="$1"
    local label="$2"
    local access_token="$3"
    local refresh_token="$4"
    local expires_at="$5"

    if [[ ! -f "$AUTH_FILE" ]]; then
        echo '{"version":1,"providers":{}}' > "$AUTH_FILE"
        chmod 600 "$AUTH_FILE"
    fi

    local tmp_file="${AUTH_FILE}.tmp"

    jq --arg pk "$provider_key" \
       --arg label "$label" \
       --arg at "$access_token" \
       --arg rt "$refresh_token" \
       --argjson ea "$expires_at" \
       '
       .providers[$pk].accounts //= [] |
       (.providers[$pk].accounts | map(.label) | index($label)) as $idx |
       if $idx != null then
           .providers[$pk].accounts[$idx].oauth = {accessToken: $at, refreshToken: $rt, expiresAt: $ea}
       else
           .providers[$pk].accounts += [{label: $label, oauth: {accessToken: $at, refreshToken: $rt, expiresAt: $ea}}]
       end |
       .lastUpdated = (now | todate)
       ' "$AUTH_FILE" > "$tmp_file" && mv "$tmp_file" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
}

cmd_login_anthropic() {
    local label="$1"
    local host_override="$2"

    label=$(_prompt_account_label "$label" "$host_override")

    # Generate PKCE
    local code_verifier
    code_verifier=$(openssl rand 32 | base64url_encode)
    local code_challenge
    code_challenge=$(printf '%s' "$code_verifier" | openssl dgst -sha256 -binary | base64url_encode)

    local encoded_redirect_uri encoded_scope
    encoded_redirect_uri=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${ANTHROPIC_OAUTH_REDIRECT_URI}''', safe=''))")
    encoded_scope=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${ANTHROPIC_OAUTH_SCOPES}''', safe=''))")
    local auth_url="${ANTHROPIC_OAUTH_AUTH_ENDPOINT}?code=true&client_id=${ANTHROPIC_OAUTH_CLIENT_ID}&response_type=code&redirect_uri=${encoded_redirect_uri}&scope=${encoded_scope}&code_challenge=${code_challenge}&code_challenge_method=S256&state=${code_verifier}"

    echo ""
    print_status "Opening browser for Anthropic authentication..."
    echo -e "  Account: ${BOLD}${label}${NC}"
    echo ""
    echo "If browser doesn't open, visit:"
    echo "$auth_url"
    echo ""

    open "$auth_url"

    echo "After signing in, copy the FULL URL from your browser's address bar."
    printf "Paste the redirect URL: "
    read -r auth_input
    echo ""

    if [[ -z "$auth_input" ]]; then
        print_error "No input provided"
        return 1
    fi

    local code=""
    local state=""

    if [[ "$auth_input" == http* ]]; then
        code=$(python3 -c "
import sys, urllib.parse
q = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
print(q.get('code',[''])[0])
" "$auth_input" 2>/dev/null)
        state=$(python3 -c "
import sys, urllib.parse
q = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)
print(q.get('state',[''])[0])
" "$auth_input" 2>/dev/null)
    else
        code="$auth_input"
        state="$code_verifier"
    fi

    if [[ -z "$code" ]]; then
        print_error "Could not extract authorization code from input"
        return 1
    fi

    print_status "Exchanging authorization code..."

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "$ANTHROPIC_OAUTH_TOKEN_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "User-Agent: tron-agent/1.0" \
        -d "{
            \"grant_type\": \"authorization_code\",
            \"client_id\": \"${ANTHROPIC_OAUTH_CLIENT_ID}\",
            \"code\": \"${code}\",
            \"state\": \"${state}\",
            \"redirect_uri\": \"${ANTHROPIC_OAUTH_REDIRECT_URI}\",
            \"code_verifier\": \"${code_verifier}\"
        }")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        print_error "Token exchange failed (HTTP $http_code): $body"
        return 1
    fi

    local access_token refresh_token expires_in expires_at
    access_token=$(echo "$body" | jq -r '.access_token')
    refresh_token=$(echo "$body" | jq -r '.refresh_token')
    expires_in=$(echo "$body" | jq -r '.expires_in')
    expires_at=$(( $(date +%s) * 1000 + expires_in * 1000 ))

    _save_oauth_tokens "anthropic" "$label" "$access_token" "$refresh_token" "$expires_at"

    print_success "Saved Anthropic tokens for account \"${label}\""

    local hours_left=$(( expires_in / 3600 ))
    echo -e "  ${DIM}Token expires in ~${hours_left}h${NC}"
    echo ""
}

cmd_login_openai() {
    local label="$1"
    local host_override="$2"

    label=$(_prompt_account_label "$label" "$host_override")

    # Check if port is available
    if lsof -i ":${OPENAI_OAUTH_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
        print_error "Port ${OPENAI_OAUTH_PORT} is already in use. Cannot start OAuth callback server."
        echo -e "  ${DIM}Check what's using it: lsof -i :${OPENAI_OAUTH_PORT}${NC}"
        return 1
    fi

    # Generate PKCE (OpenAI requires code_challenge)
    local code_verifier
    code_verifier=$(openssl rand 32 | base64url_encode)
    local code_challenge
    code_challenge=$(printf '%s' "$code_verifier" | openssl dgst -sha256 -binary | base64url_encode)

    local encoded_redirect_uri encoded_scope
    encoded_redirect_uri=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${OPENAI_OAUTH_REDIRECT_URI}''', safe=''))")
    encoded_scope=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${OPENAI_OAUTH_SCOPES}''', safe=''))")
    local auth_url="${OPENAI_OAUTH_AUTH_ENDPOINT}?response_type=code&client_id=${OPENAI_OAUTH_CLIENT_ID}&redirect_uri=${encoded_redirect_uri}&scope=${encoded_scope}&code_challenge=${code_challenge}&code_challenge_method=S256&state=${code_verifier}"

    echo ""
    print_status "Opening browser for OpenAI authentication..."
    echo -e "  Account: ${BOLD}${label}${NC}"
    echo ""

    # Start local callback server in background
    local code_file
    code_file=$(mktemp)
    local error_file
    error_file=$(mktemp)

    python3 -c "
import http.server, urllib.parse, sys, signal

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path != '/auth/callback':
            self.send_response(404)
            self.end_headers()
            return

        if 'error' in params:
            desc = params.get('error_description', params['error'])[0]
            with open('${error_file}', 'w') as f:
                f.write(desc)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<html><body><h2>Authorization Failed</h2><p>You can close this tab.</p></body></html>')
            raise SystemExit(1)

        code = params.get('code', [''])[0]
        recv_state = params.get('state', [''])[0]

        with open('${code_file}', 'w') as f:
            f.write(code + '\n' + recv_state)

        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(b'<html><body><h2>Authorization Complete</h2><p>You can close this tab and return to the terminal.</p></body></html>')
        raise SystemExit(0)

    def log_message(self, format, *args):
        pass  # suppress request logging

server = http.server.HTTPServer(('127.0.0.1', ${OPENAI_OAUTH_PORT}), Handler)
server.timeout = 300  # 5 minute timeout
signal.signal(signal.SIGALRM, lambda *_: sys.exit(1))
signal.alarm(300)
try:
    server.handle_request()
except SystemExit:
    pass
" &
    local server_pid=$!

    # Give server a moment to start
    sleep 0.3

    if ! kill -0 "$server_pid" 2>/dev/null; then
        print_error "Failed to start OAuth callback server on port ${OPENAI_OAUTH_PORT}"
        rm -f "$code_file" "$error_file"
        return 1
    fi

    echo "If browser doesn't open, visit:"
    echo "$auth_url"
    echo ""
    echo -e "${DIM}Waiting for authorization (listening on port ${OPENAI_OAUTH_PORT})...${NC}"

    open "$auth_url"

    # Wait for the callback server to complete
    wait "$server_pid" 2>/dev/null

    # Check for errors
    if [[ -s "$error_file" ]]; then
        local err_msg
        err_msg=$(<"$error_file")
        print_error "Authorization failed: $err_msg"
        rm -f "$code_file" "$error_file"
        return 1
    fi

    if [[ ! -s "$code_file" ]]; then
        print_error "No authorization code received (timed out or server error)"
        rm -f "$code_file" "$error_file"
        return 1
    fi

    local code recv_state
    code=$(head -1 "$code_file")
    recv_state=$(tail -1 "$code_file")
    rm -f "$code_file" "$error_file"

    if [[ -z "$code" ]]; then
        print_error "Empty authorization code received"
        return 1
    fi

    # Validate state matches (CSRF protection — verifier was used as state)
    if [[ "$recv_state" != "$code_verifier" ]]; then
        print_error "State parameter mismatch (possible CSRF attack)"
        return 1
    fi

    print_status "Exchanging authorization code..."

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "$OPENAI_OAUTH_TOKEN_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "User-Agent: tron-agent/1.0" \
        -d "{
            \"grant_type\": \"authorization_code\",
            \"client_id\": \"${OPENAI_OAUTH_CLIENT_ID}\",
            \"code\": \"${code}\",
            \"redirect_uri\": \"${OPENAI_OAUTH_REDIRECT_URI}\",
            \"code_verifier\": \"${code_verifier}\"
        }")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        print_error "Token exchange failed (HTTP $http_code): $body"
        return 1
    fi

    local access_token refresh_token expires_in expires_at
    access_token=$(echo "$body" | jq -r '.access_token')
    refresh_token=$(echo "$body" | jq -r '.refresh_token // ""')
    expires_in=$(echo "$body" | jq -r '.expires_in')
    expires_at=$(( $(date +%s) * 1000 + expires_in * 1000 ))

    _save_oauth_tokens "openai-codex" "$label" "$access_token" "$refresh_token" "$expires_at"

    print_success "Saved OpenAI tokens for account \"${label}\""

    local hours_left=$(( expires_in / 3600 ))
    echo -e "  ${DIM}Token expires in ~${hours_left}h${NC}"
    echo ""
}

cmd_login_status() {
    if [[ ! -f "$AUTH_FILE" ]]; then
        echo ""
        print_warning "No auth file found"
        echo ""
        return
    fi

    local now_ms=$(( $(date +%s) * 1000 ))

    _show_provider_login_status "anthropic" "Anthropic" "$now_ms"
    _show_provider_login_status "openai-codex" "OpenAI" "$now_ms"

    echo ""
}

_show_provider_login_status() {
    local provider_key="$1"
    local display_name="$2"
    local now_ms="$3"

    echo ""
    print_status "${display_name} auth status:"
    echo ""

    # Show active credential
    local active_type active_label
    active_type=$(jq -r ".providers[\"${provider_key}\"].activeCredential.type // empty" "$AUTH_FILE" 2>/dev/null)
    active_label=$(jq -r ".providers[\"${provider_key}\"].activeCredential.label // empty" "$AUTH_FILE" 2>/dev/null)

    # OAuth accounts
    local account_count
    account_count=$(jq -r ".providers[\"${provider_key}\"].accounts // [] | length" "$AUTH_FILE" 2>/dev/null)
    if [[ "$account_count" -gt 0 ]]; then
        echo -e "  ${DIM}OAuth accounts:${NC}"
        jq -r --argjson now "$now_ms" --arg pk "$provider_key" --arg active_label "$active_label" --arg active_type "$active_type" '
            .providers[$pk].accounts[] |
            .label as $l |
            .oauth.expiresAt as $e |
            .oauth.accessToken[0:20] as $t |
            (if $active_type == "oauth" and $active_label == $l then " *" else "  " end) as $marker |
            if $e > $now then
                "\($marker) \($l): \u001b[32mvalid\u001b[0m (~\(($e - $now) / 3600000 | floor)h)  \($t)..."
            else
                "\($marker) \($l): \u001b[31mexpired\u001b[0m  \($t)..."
            end
        ' "$AUTH_FILE" 2>/dev/null | while IFS= read -r line; do echo -e "$line"; done
    fi

    # Named API keys
    local key_count
    key_count=$(jq -r ".providers[\"${provider_key}\"].apiKeys // [] | length" "$AUTH_FILE" 2>/dev/null)
    if [[ "$key_count" -gt 0 ]]; then
        echo -e "  ${DIM}API keys:${NC}"
        jq -r --arg pk "$provider_key" --arg active_label "$active_label" --arg active_type "$active_type" '
            .providers[$pk].apiKeys[] |
            .label as $l |
            .key[0:12] as $hint |
            (if $active_type == "apiKey" and $active_label == $l then " *" else "  " end) as $marker |
            "\($marker) \($l): \($hint)..."
        ' "$AUTH_FILE" 2>/dev/null | while IFS= read -r line; do echo -e "$line"; done
    fi

    if [[ "$account_count" -eq 0 ]] && [[ "$key_count" -eq 0 ]]; then
        echo -e "  ${DIM}(not configured)${NC}"
    fi
}
