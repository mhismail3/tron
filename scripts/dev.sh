#!/usr/bin/env bash
#
# Tron Development Script
#
# Manages local development workspaces for feature development and testing.
#
# Usage:
#   ./scripts/dev.sh [command] [options]
#
# Commands:
#   start       Start development server (default)
#   workspace   Create/switch development workspace
#   list        List all workspaces
#   clean       Clean workspace artifacts
#   test        Run tests in watch mode
#   typecheck   Run continuous type checking
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACES_DIR="$PROJECT_DIR/.workspaces"
TRON_HOME="${TRON_DATA_DIR:-$HOME/.tron}"

# Defaults
COMMAND="start"
WORKSPACE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        start|workspace|list|clean|test|typecheck)
            COMMAND="$1"
            shift
            ;;
        -w|--workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [command] [options]"
            echo ""
            echo "Commands:"
            echo "  start       Start development server (default)"
            echo "  workspace   Create/switch development workspace"
            echo "  list        List all workspaces"
            echo "  clean       Clean workspace artifacts"
            echo "  test        Run tests in watch mode"
            echo "  typecheck   Run continuous type checking"
            echo ""
            echo "Options:"
            echo "  -w, --workspace NAME   Workspace name"
            echo "  -h, --help             Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                           Start dev in main workspace"
            echo "  $0 workspace feature-x       Create/switch to feature-x workspace"
            echo "  $0 -w feature-x start        Start dev in feature-x workspace"
            echo "  $0 list                      List all workspaces"
            exit 0
            ;;
        *)
            # Treat unknown args as workspace name for 'workspace' command
            if [ "$COMMAND" = "workspace" ] && [ -z "$WORKSPACE" ]; then
                WORKSPACE="$1"
            else
                echo -e "${RED}Unknown option: $1${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

log() { echo -e "${BLUE}[dev]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

header() {
    echo ""
    echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}${BOLD}                Tron Development Environment                   ${NC}${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Get current workspace
get_current_workspace() {
    if [ -f "$PROJECT_DIR/.current-workspace" ]; then
        cat "$PROJECT_DIR/.current-workspace"
    else
        echo "main"
    fi
}

# Set current workspace
set_current_workspace() {
    echo "$1" > "$PROJECT_DIR/.current-workspace"
}

# Create or switch to workspace
create_workspace() {
    local name="$1"

    if [ -z "$name" ]; then
        error "Workspace name required"
    fi

    if [ "$name" = "main" ]; then
        log "Switching to main workspace..."
        set_current_workspace "main"
        success "Now using main workspace"
        return 0
    fi

    local workspace_dir="$WORKSPACES_DIR/$name"

    if [ -d "$workspace_dir" ]; then
        log "Switching to existing workspace: $name"
        set_current_workspace "$name"
        success "Now using workspace: $name"
    else
        log "Creating new workspace: $name"

        mkdir -p "$workspace_dir"

        # Create worktree if in git repo
        if git rev-parse --git-dir > /dev/null 2>&1; then
            local current_branch
            current_branch=$(git branch --show-current)

            # Create a new branch for the workspace
            local branch_name="workspace/$name"
            if git show-ref --verify --quiet "refs/heads/$branch_name"; then
                warn "Branch $branch_name already exists"
            else
                log "Creating branch: $branch_name"
                git branch "$branch_name" 2>/dev/null || true
            fi

            # Create worktree
            log "Creating git worktree..."
            git worktree add "$workspace_dir" "$branch_name" 2>/dev/null || {
                warn "Could not create worktree, using symlink instead"
                rm -rf "$workspace_dir"
                # Create symlink-based workspace
                mkdir -p "$workspace_dir"
                ln -sf "$PROJECT_DIR/packages" "$workspace_dir/packages"
                ln -sf "$PROJECT_DIR/node_modules" "$workspace_dir/node_modules"
                ln -sf "$PROJECT_DIR/package.json" "$workspace_dir/package.json"
                ln -sf "$PROJECT_DIR/tsconfig.json" "$workspace_dir/tsconfig.json"
            }
        else
            # Non-git: create symlink-based workspace
            mkdir -p "$workspace_dir"
            ln -sf "$PROJECT_DIR/packages" "$workspace_dir/packages"
            ln -sf "$PROJECT_DIR/node_modules" "$workspace_dir/node_modules"
            ln -sf "$PROJECT_DIR/package.json" "$workspace_dir/package.json"
            ln -sf "$PROJECT_DIR/tsconfig.json" "$workspace_dir/tsconfig.json"
        fi

        set_current_workspace "$name"
        success "Created workspace: $name"
        echo ""
        echo "  Location: $workspace_dir"
        echo ""
    fi
}

# List workspaces
list_workspaces() {
    echo ""
    echo -e "${BOLD}Development Workspaces${NC}"
    echo ""

    local current
    current=$(get_current_workspace)

    # Main workspace
    if [ "$current" = "main" ]; then
        echo -e "  ${GREEN}●${NC} main (active)"
    else
        echo -e "  ○ main"
    fi

    # Other workspaces
    if [ -d "$WORKSPACES_DIR" ]; then
        for ws in "$WORKSPACES_DIR"/*/; do
            [ -d "$ws" ] || continue
            local name
            name=$(basename "$ws")
            if [ "$current" = "$name" ]; then
                echo -e "  ${GREEN}●${NC} $name (active)"
            else
                echo -e "  ○ $name"
            fi
        done
    fi

    echo ""
}

# Clean workspace
clean_workspace() {
    local name="${WORKSPACE:-$(get_current_workspace)}"

    if [ "$name" = "main" ]; then
        log "Cleaning main workspace..."
        cd "$PROJECT_DIR"
        npm run clean
        success "Main workspace cleaned"
    else
        local workspace_dir="$WORKSPACES_DIR/$name"
        if [ -d "$workspace_dir" ]; then
            log "Cleaning workspace: $name"

            # Check if it's a worktree
            if git worktree list 2>/dev/null | grep -q "$workspace_dir"; then
                git worktree remove "$workspace_dir" --force 2>/dev/null || rm -rf "$workspace_dir"
            else
                rm -rf "$workspace_dir"
            fi

            # If this was current workspace, switch to main
            if [ "$(get_current_workspace)" = "$name" ]; then
                set_current_workspace "main"
            fi

            success "Workspace $name removed"
        else
            warn "Workspace not found: $name"
        fi
    fi
}

# Start development server
start_dev() {
    local workspace
    workspace=$(get_current_workspace)

    local work_dir="$PROJECT_DIR"
    if [ "$workspace" != "main" ]; then
        work_dir="$WORKSPACES_DIR/$workspace"
        if [ ! -d "$work_dir" ]; then
            error "Workspace not found: $workspace. Run '$0 workspace $workspace' first."
        fi
    fi

    header
    echo -e "  Workspace: ${BOLD}$workspace${NC}"
    echo -e "  Directory: $work_dir"
    echo ""

    cd "$work_dir"

    # Set development environment
    export NODE_ENV=development
    export TRON_BUILD_TIER=beta
    export TRON_DEV=1

    log "Starting Tron TUI in development mode..."
    echo ""
    echo -e "  ${CYAN}Press Ctrl+C to exit${NC}"
    echo ""

    # Use tsx for dev with hot reload
    exec npx tsx packages/tui/src/cli.ts
}

# Run tests
run_tests() {
    local workspace
    workspace=$(get_current_workspace)

    local work_dir="$PROJECT_DIR"
    if [ "$workspace" != "main" ]; then
        work_dir="$WORKSPACES_DIR/$workspace"
    fi

    cd "$work_dir"
    log "Running tests in watch mode..."
    exec npm run test:watch
}

# Run type checking
run_typecheck() {
    local workspace
    workspace=$(get_current_workspace)

    local work_dir="$PROJECT_DIR"
    if [ "$workspace" != "main" ]; then
        work_dir="$WORKSPACES_DIR/$workspace"
    fi

    cd "$work_dir"
    log "Running continuous type checking..."
    exec npx tsc --noEmit --watch
}

# Main
case "$COMMAND" in
    start)
        start_dev
        ;;
    workspace)
        create_workspace "$WORKSPACE"
        ;;
    list)
        list_workspaces
        ;;
    clean)
        clean_workspace
        ;;
    test)
        run_tests
        ;;
    typecheck)
        run_typecheck
        ;;
    *)
        error "Unknown command: $COMMAND"
        ;;
esac
