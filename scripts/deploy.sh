#!/usr/bin/env bash
#
# Tron Deployment Script
#
# Handles deployment for prod and public tiers:
# - Builds the appropriate tier
# - Installs binaries
# - Sets up auto-start service
# - Manages server lifecycle
#
# Usage:
#   ./scripts/deploy.sh [tier] [command]
#
# Tiers:
#   prod    - Deploy personal production (default)
#   public  - Deploy public release
#
# Commands:
#   install   - Build and install (default)
#   uninstall - Remove installation
#   upgrade   - Rebuild and reinstall
#   status    - Show deployment status
#   start     - Start the server
#   stop      - Stop the server
#   restart   - Restart the server
#   logs      - View server logs
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TRON_HOME="${TRON_DATA_DIR:-$HOME/.tron}"
BIN_DIR="$HOME/.local/bin"

# Service identifiers
LAUNCHD_LABEL="com.tron.server"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

# Defaults
TIER="prod"
COMMAND="install"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        prod|public)
            TIER="$1"
            shift
            ;;
        install|uninstall|upgrade|status|start|stop|restart|logs)
            COMMAND="$1"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [tier] [command]"
            echo ""
            echo "Tiers:"
            echo "  prod    Personal production (default)"
            echo "  public  Public release"
            echo ""
            echo "Commands:"
            echo "  install   Build and install (default)"
            echo "  uninstall Remove installation"
            echo "  upgrade   Rebuild and reinstall"
            echo "  status    Show deployment status"
            echo "  start     Start the server"
            echo "  stop      Stop the server"
            echo "  restart   Restart the server"
            echo "  logs      View server logs"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

log() { echo -e "${BLUE}[deploy:$TIER]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

header() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}${BOLD}                   Tron Deployment                             ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Tier:    ${BOLD}$TIER${NC}"
    echo -e "  Command: $COMMAND"
    echo ""
}

# Check if server is running
is_server_running() {
    launchctl list 2>/dev/null | grep -q "$LAUNCHD_LABEL"
}

# Get install directory
get_install_dir() {
    if [ "$TIER" = "prod" ]; then
        echo "$TRON_HOME/install/prod"
    else
        echo "/usr/local/lib/tron"
    fi
}

# Create launchd plist
create_launchd_plist() {
    local install_dir="$1"
    local node_path
    node_path=$(which node)

    log "Creating launchd service..."

    mkdir -p "$(dirname "$LAUNCHD_PLIST")"
    mkdir -p "$TRON_HOME/logs"

    cat > "$LAUNCHD_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$node_path</string>
        <string>$install_dir/packages/tui/dist/cli.js</string>
        <string>--server</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>5</integer>

    <key>StandardOutPath</key>
    <string>$TRON_HOME/logs/server-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>$TRON_HOME/logs/server-stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>NODE_ENV</key>
        <string>production</string>
        <key>TRON_BUILD_TIER</key>
        <string>$TIER</string>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>$(dirname "$node_path"):/usr/local/bin:/usr/bin:/bin</string>
        <key>TRON_DATA_DIR</key>
        <string>$TRON_HOME</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>$install_dir</string>

    <key>ProcessType</key>
    <string>Background</string>

    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>4096</integer>
    </dict>
</dict>
</plist>
EOF

    success "Created launchd plist at $LAUNCHD_PLIST"
}

# Start server
start_server() {
    if is_server_running; then
        warn "Server is already running"
        return 0
    fi

    if [ ! -f "$LAUNCHD_PLIST" ]; then
        error "Service not installed. Run '$0 $TIER install' first."
    fi

    log "Starting server..."
    launchctl load -w "$LAUNCHD_PLIST"

    sleep 2
    if is_server_running; then
        success "Server started"

        # Show connection info
        local ws_port="${TRON_WS_PORT:-8080}"
        local health_port="${TRON_HEALTH_PORT:-8081}"
        echo ""
        echo "  WebSocket: ws://localhost:$ws_port/ws"
        echo "  Health:    http://localhost:$health_port/health"
        echo ""
    else
        error "Failed to start server. Check logs: $TRON_HOME/logs/server-stderr.log"
    fi
}

# Stop server
stop_server() {
    if ! is_server_running; then
        warn "Server is not running"
        return 0
    fi

    log "Stopping server..."
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true

    sleep 1
    if ! is_server_running; then
        success "Server stopped"
    else
        warn "Server may still be running"
    fi
}

# Install
do_install() {
    log "Installing Tron ($TIER tier)..."

    local install_dir
    install_dir=$(get_install_dir)

    # Build first
    "$SCRIPT_DIR/build.sh" "$TIER" --install

    # Create bin wrapper
    mkdir -p "$BIN_DIR"

    if [ "$TIER" = "prod" ]; then
        cat > "$BIN_DIR/tron" << EOF
#!/usr/bin/env bash
# Tron CLI (prod build)
export TRON_BUILD_TIER=prod
export NODE_ENV=production
exec node "$install_dir/packages/tui/dist/cli.js" "\$@"
EOF
    else
        cat > "$BIN_DIR/tron" << EOF
#!/usr/bin/env bash
# Tron CLI (public build)
export TRON_BUILD_TIER=public
export NODE_ENV=production
export TRON_PUBLIC=1
exec node "$install_dir/packages/tui/dist/cli.js" "\$@"
EOF
    fi

    chmod +x "$BIN_DIR/tron"
    success "Installed tron binary to $BIN_DIR/tron"

    # Setup launchd service
    create_launchd_plist "$install_dir"

    # Start server
    start_server

    echo ""
    success "Installation complete!"
    echo ""
    echo "  Usage:"
    echo "    tron              Launch interactive TUI"
    echo "    tron login        Authenticate with Claude Max"
    echo "    tron --server     Start standalone server"
    echo "    tron --help       Show all options"
    echo ""
}

# Uninstall
do_uninstall() {
    log "Uninstalling Tron ($TIER tier)..."

    # Stop server first
    stop_server

    # Remove launchd plist
    if [ -f "$LAUNCHD_PLIST" ]; then
        rm -f "$LAUNCHD_PLIST"
        success "Removed launchd service"
    fi

    # Remove binary
    if [ -f "$BIN_DIR/tron" ]; then
        rm -f "$BIN_DIR/tron"
        success "Removed tron binary"
    fi

    # Remove install directory
    local install_dir
    install_dir=$(get_install_dir)
    if [ -d "$install_dir" ]; then
        rm -rf "$install_dir"
        success "Removed install directory"
    fi

    echo ""
    success "Uninstall complete!"
    echo ""
    echo "  Note: ~/.tron data directory was preserved."
    echo "  To remove all data: rm -rf ~/.tron"
    echo ""
}

# Upgrade
do_upgrade() {
    log "Upgrading Tron ($TIER tier)..."

    # Stop server
    stop_server

    # Rebuild and install
    do_install

    success "Upgrade complete!"
}

# Show status
do_status() {
    echo ""
    echo -e "${BOLD}Tron Deployment Status${NC}"
    echo ""

    # Binary
    if [ -f "$BIN_DIR/tron" ]; then
        echo -e "  Binary:   ${GREEN}Installed${NC} ($BIN_DIR/tron)"
        local version
        version=$("$BIN_DIR/tron" --version 2>/dev/null || echo "unknown")
        echo "            Version: $version"
    else
        echo -e "  Binary:   ${RED}Not installed${NC}"
    fi

    # Install directory
    local install_dir
    install_dir=$(get_install_dir)
    if [ -d "$install_dir" ]; then
        echo -e "  Install:  ${GREEN}Present${NC} ($install_dir)"
    else
        echo -e "  Install:  ${RED}Missing${NC}"
    fi

    # Launchd service
    if [ -f "$LAUNCHD_PLIST" ]; then
        echo -e "  Service:  ${GREEN}Configured${NC}"
        if is_server_running; then
            echo -e "  Status:   ${GREEN}Running${NC}"

            # Check health endpoint
            local health_port="${TRON_HEALTH_PORT:-8081}"
            if curl -s "http://localhost:$health_port/health" > /dev/null 2>&1; then
                echo -e "  Health:   ${GREEN}Healthy${NC}"
            else
                echo -e "  Health:   ${YELLOW}Not responding${NC}"
            fi
        else
            echo -e "  Status:   ${RED}Stopped${NC}"
        fi
    else
        echo -e "  Service:  ${RED}Not configured${NC}"
    fi

    # Data directory
    if [ -d "$TRON_HOME" ]; then
        local size
        size=$(du -sh "$TRON_HOME" 2>/dev/null | cut -f1)
        echo -e "  Data:     ${GREEN}Present${NC} ($TRON_HOME, $size)"
    else
        echo -e "  Data:     ${YELLOW}Not initialized${NC}"
    fi

    echo ""
}

# View logs
do_logs() {
    local log_file="$TRON_HOME/logs/server-stderr.log"

    if [ ! -f "$log_file" ]; then
        warn "No log file found at $log_file"
        return 1
    fi

    log "Tailing logs (Ctrl+C to exit)..."
    tail -f "$log_file"
}

# Main
header

case "$COMMAND" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    upgrade)
        do_upgrade
        ;;
    status)
        do_status
        ;;
    start)
        start_server
        ;;
    stop)
        stop_server
        ;;
    restart)
        stop_server
        start_server
        ;;
    logs)
        do_logs
        ;;
    *)
        error "Unknown command: $COMMAND"
        ;;
esac
