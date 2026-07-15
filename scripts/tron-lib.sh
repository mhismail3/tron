#!/bin/bash
# tron-lib.sh - Shared library for Tron CLI scripts
#
# Shared contributor-shell paths and functions for scripts/tron and tron-cli.
# Rust foundation owners define the complete runtime home/profile layout.
#
# Do NOT execute this file directly.

#=============================================================================
# CONFIGURATION
#=============================================================================

TRON_HOME="${TRON_DATA_DIR:-$HOME/.tron}"
BIN_DIR="$HOME/.local/bin"

# Contributor app bundle paths. Production Mac distribution lives at
# `/Applications/Tron.app` and is registered by the Swift wrapper via SMAppService;
# these bundles are only for shell-script development flows.
TRON_BUNDLE_ID="com.tron.agent"
RUN_DIR="$TRON_HOME/internal/run"
USER_PROFILE_FILE="$TRON_HOME/profiles/user/profile.toml"
CONTRIBUTOR_DIR="$RUN_DIR"
DEPLOY_LOCK_FILE="$RUN_DIR/deploy.lock"
DEPLOY_UPDATE_FILE="$RUN_DIR/deploy.in-progress"
INSTALLED_BUNDLE="$CONTRIBUTOR_DIR/Tron-Deploy.app"
INSTALLED_BINARY="$INSTALLED_BUNDLE/Contents/MacOS/tron"
DEV_BUNDLE="$RUN_DIR/Tron-Dev.app"
DEV_BINARY="$DEV_BUNDLE/Contents/MacOS/tron"
DEV_BACKGROUND_LOG="$RUN_DIR/tron-dev-background.log"
DEV_BACKGROUND_PID_FILE="$RUN_DIR/tron-dev-background.pid"

# Service configuration
PLIST_NAME="com.tron.server"
DEV_PLIST_NAME="com.tron.server.dev-takeover"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
DEV_PLIST_PATH="$HOME/Library/LaunchAgents/$DEV_PLIST_NAME.plist"
RELEASE_APP="/Applications/Tron.app"
RELEASE_APP_BINARY="$RELEASE_APP/Contents/MacOS/Tron"
RELEASE_LAUNCH_AGENT_PLIST="$RELEASE_APP/Contents/Library/LaunchAgents/$PLIST_NAME.plist"
PROD_PORT=9847

# File paths
DEPLOYED_COMMIT_FILE="$CONTRIBUTOR_DIR/deployed-commit"
ONBOARDED_MARKER_PATH="$RUN_DIR/.onboarded"

# Database
DB_PATH="$TRON_HOME/internal/database/tron.sqlite"

# OAuth
AUTH_FILE="$TRON_HOME/profiles/auth.json"

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

# INVARIANT: every print_* helper writes to stderr (>&2). Stdout is
# reserved for machine-readable output — `tron install --gui-helper`
# emits one NDJSON event per line on stdout, and any decorative print
# from a helper called transitively (for example, codesign_bundle)
# would corrupt that stream. Routing to
# stderr lets us keep the gating-by-flag pattern as a UX nicety while
# making the stdout contract structurally enforced rather than
# discipline-enforced.
print_status()  { echo -e "${BLUE}▸${NC} $1" >&2; }
print_success() { echo -e "${GREEN}✓${NC} $1" >&2; }
print_error()   { echo -e "${RED}✗${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}!${NC} $1" >&2; }
# Neutral informational tone for explanatory CLI output.
print_info()    { echo -e "${DIM}ℹ${NC} $1" >&2; }
print_header()  { echo -e "\n${CYAN}$1${NC}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2; }

#=============================================================================
# UTILITY FUNCTIONS
#=============================================================================

require_installed() {
    if [ ! -f "$PLIST_PATH" ]; then
        print_error "Contributor service is not installed. Run: tron install"
        exit 1
    fi
}

confirm_action() {
    read -p "$1 (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

clear_user_profile_settings() {
    if [ ! -f "$USER_PROFILE_FILE" ]; then
        return 0
    fi

    local tmp_file="$USER_PROFILE_FILE.tmp.$$"
    awk '
        /^[[:space:]]*\[+[^][]+\]+[[:space:]]*($|#)/ {
            table = $0
            sub(/^[[:space:]]*\[+/, "", table)
            sub(/\]+[[:space:]]*($|#.*$)/, "", table)
            skip = (table == "settings" || table ~ /^settings\./)
            if (skip) {
                next
            }
        }
        !skip { print }
    ' "$USER_PROFILE_FILE" > "$tmp_file"

    if grep -q '[^[:space:]]' "$tmp_file"; then
        mv "$tmp_file" "$USER_PROFILE_FILE"
    else
        rm -f "$tmp_file" "$USER_PROFILE_FILE"
    fi
}

#=============================================================================
# COMMAND MODULES
#=============================================================================

TRON_LIB_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tron-lib.d"
for tron_lib_module in "$TRON_LIB_MODULE_DIR"/*.sh; do
    [ -e "$tron_lib_module" ] && source "$tron_lib_module"
done
unset tron_lib_module TRON_LIB_MODULE_DIR

# Shared runtime command ownership. Each entrypoint defines its own cmd_help
# before calling this dispatcher, so unknown commands retain the local help UX.
dispatch_runtime_command() {
    local command="$1"
    shift

    case "$command" in
        status)    cmd_status "$@" ;;
        start)     cmd_start ;;
        stop)      cmd_stop ;;
        restart)   cmd_restart ;;
        uninstall) cmd_uninstall "$@" ;;
        logs)      query_logs "$@" ;;
        errors)    query_logs --level error --limit 20 ;;
        rollback)  cmd_rollback "$@" ;;
        login)     cmd_login "$@" ;;
        auth)      cmd_auth "$@" ;;
        *)
            print_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}
