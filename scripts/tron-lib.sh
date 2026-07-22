#!/bin/bash
# tron-lib.sh - Shared library for Tron CLI scripts
#
# Shared contributor-shell paths and functions for scripts/tron and tron-cli.
# Rust foundation owners define the complete runtime home layout.
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
RUN_DIR="$TRON_HOME/internal/run"
SETTINGS_FILE="$TRON_HOME/settings.toml"
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
AUTH_FILE="$TRON_HOME/auth.json"

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

# INVARIANT: every print_* helper writes to stderr (>&2). Stdout is reserved
# for command-owned machine-readable output, so decorative output from a
# transitive helper (for example, codesign_bundle) must never corrupt it.
print_status()  { echo -e "${BLUE}▸${NC} $1" >&2; }
print_success() { echo -e "${GREEN}✓${NC} $1" >&2; }
print_error()   { echo -e "${RED}✗${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}!${NC} $1" >&2; }
print_header()  { echo -e "\n${CYAN}$1${NC}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2; }

# Canonical help for commands routed by dispatch_runtime_command. Entrypoints
# own their workspace/delegation sections but must not duplicate runtime rows.
show_runtime_command_help() {
    echo -e "${BOLD}Runtime:${NC}"
    echo "  status          Show service status"
    echo "  start           Start launchd service"
    echo "  stop            Stop service"
    echo "  restart         Restart service"
    echo "  uninstall       Remove service and reset Mac onboarding (add --reset-settings and/or --reset-credentials)"
    echo "  rollback        Restore previous binary (--yes to skip confirmation)"
    echo "  login           Authenticate with a provider (--provider <name>, --label <name>)"
    echo "  auth rotate     Rotate the WebSocket bearer token (forces iOS re-pair)"
    echo "  logs            Query database logs (use -h for options)"
    echo "  errors          Show recent errors"
    echo ""
}

#=============================================================================
# UTILITY FUNCTIONS
#=============================================================================

confirm_action() {
    read -p "$1 (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

clear_user_settings() {
    rm -f "$SETTINGS_FILE"
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
