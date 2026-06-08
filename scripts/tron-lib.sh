#!/bin/bash
# tron-lib.sh - Shared library for Tron CLI scripts
#
# SINGLE SOURCE OF TRUTH for all paths, config, and shared functions.
# Sourced by: scripts/tron, scripts/tron-cli, scripts/reset-db
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
PROFILES_DIR="$TRON_HOME/profiles"
USER_PROFILE_DIR="$PROFILES_DIR/user"
DEFAULT_PROFILE_DIR="$PROFILES_DIR/default"
NORMAL_PROFILE_DIR="$PROFILES_DIR/normal"
CHAT_PROFILE_DIR="$PROFILES_DIR/chat"
LOCAL_PROFILE_DIR="$PROFILES_DIR/local"
USER_PROFILE_FILE="$USER_PROFILE_DIR/profile.toml"
WORKSPACE_DIR="$TRON_HOME/workspace"
WORKSPACE_VAULT_DIR="$WORKSPACE_DIR/vault"
WORKSPACE_KNOWLEDGE_DIR="$WORKSPACE_DIR/knowledge"
CONTRIBUTOR_DIR="$RUN_DIR"
DEPLOY_LOCK_FILE="$RUN_DIR/deploy.lock"
INSTALLED_BUNDLE="$CONTRIBUTOR_DIR/Tron-Deploy.app"
INSTALLED_BINARY="$INSTALLED_BUNDLE/Contents/MacOS/tron"
DEV_BUNDLE="$RUN_DIR/Tron-Dev.app"
DEV_BINARY="$DEV_BUNDLE/Contents/MacOS/tron"
DEV_BACKGROUND_LOG="$RUN_DIR/tron-dev-background.log"
DEV_BACKGROUND_PID_FILE="$RUN_DIR/tron-dev-background.pid"

# Keychain profile name for xcrun notarytool (see notarize_bundle).
# One-time setup per developer machine:
#   xcrun notarytool store-credentials "tron-notarize" \
#     --apple-id <email> --team-id <TEAM_ID>
NOTARIZE_PROFILE="tron-notarize"

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
AUTH_FILE="$PROFILES_DIR/auth.json"

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

tron_version_env_file() {
    local roots=()
    [ -n "${PROJECT_DIR:-}" ] && roots+=("$PROJECT_DIR")

    local script_root
    if script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"; then
        roots+=("$script_root")
    fi

    local workspace_root
    if workspace_root="$(cat "$CONTRIBUTOR_DIR/workspace-path" 2>/dev/null)" && [ -n "$workspace_root" ]; then
        roots+=("$workspace_root")
    fi

    local root candidate
    for root in "${roots[@]}"; do
        candidate="$root/VERSION.env"
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

tron_version_env_value() {
    local key="$1"
    local version_file
    version_file="$(tron_version_env_file)" || return 1
    awk -F= -v key="$key" '
        $1 == key {
            sub(/\r$/, "", $2)
            print $2
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$version_file"
}

tron_marketing_version() {
    local canonical="$1"
    case "$canonical" in
        *-*) echo "${canonical%%-*}" ;;
        *) echo "$canonical" ;;
    esac
}

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
# from a helper called transitively (codesign_bundle, notarize_bundle,
# ensure_default_configs, …) would corrupt that stream. Routing to
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

ensure_tron_home() {
    mkdir -p "$TRON_HOME"/internal/{database,run}
    mkdir -p "$DEFAULT_PROFILE_DIR" "$NORMAL_PROFILE_DIR" "$CHAT_PROFILE_DIR" "$LOCAL_PROFILE_DIR" "$USER_PROFILE_DIR"
    mkdir -p "$USER_PROFILE_DIR/prompts"
    mkdir -p "$DEFAULT_PROFILE_DIR"/{prompts,providers,context,tools}
    mkdir -p "$DEFAULT_PROFILE_DIR/prompts/processes"
    mkdir -p "$TRON_HOME"/memory/{rules,sessions}
    mkdir -p "$WORKSPACE_DIR"/{inbox,projects,automations,plans,reports,renders,screenshots,scratch,labs,archive}
    mkdir -p "$WORKSPACE_KNOWLEDGE_DIR" "$WORKSPACE_VAULT_DIR"
    mkdir -p "$TRON_HOME"/skills
    mkdir -p "$WORKSPACE_DIR/inbox/voice-notes"
}

ensure_default_configs() {
    # Standalone settings JSON is intentionally not created here. The Rust
    # profile seeder owns managed defaults in profiles/default/profile.toml,
    # while settings.update writes sparse [settings] overrides to
    # profiles/user/profile.toml.

    if [ ! -f "$AUTH_FILE" ]; then
        mkdir -p "$(dirname "$AUTH_FILE")"
        cat > "$AUTH_FILE" << 'EOF'
{
  "version": 1,
  "providers": {},
  "lastUpdated": ""
}
EOF
        chmod 600 "$AUTH_FILE"
        print_success "Created auth.json"
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
