#!/usr/bin/env bash
#
# Tron Service Installation Script
#
# This script installs Tron as a system service:
# - macOS: launchd (LaunchAgent)
# - Linux: systemd (user service)
#
# Usage: ./scripts/install-service.sh [--uninstall]
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TRON_HOME="${TRON_DATA_DIR:-$HOME/.tron}"

# Service identifiers
LAUNCHD_LABEL="com.tron.server"
SYSTEMD_SERVICE="tron"

log() { echo -e "${BLUE}[tron]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            echo "macos"
            ;;
        Linux*)
            echo "linux"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Check if service is running
is_service_running() {
    local os="$1"

    case "$os" in
        macos)
            launchctl list | grep -q "$LAUNCHD_LABEL" 2>/dev/null
            ;;
        linux)
            systemctl --user is-active --quiet "$SYSTEMD_SERVICE" 2>/dev/null
            ;;
    esac
}

# Install on macOS using launchd
install_macos() {
    log "Installing launchd service..."

    local plist_src="$PROJECT_DIR/deploy/launchd/com.tron.server.plist"
    local plist_dest="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
    local log_dir="$TRON_HOME/logs"

    # Check source exists
    if [ ! -f "$plist_src" ]; then
        error "launchd plist not found at $plist_src"
    fi

    # Create log directory
    mkdir -p "$log_dir"

    # Stop existing service if running
    if is_service_running "macos"; then
        log "Stopping existing service..."
        launchctl unload "$plist_dest" 2>/dev/null || true
    fi

    # Copy and configure plist
    log "Configuring launchd plist..."
    sed -e "s|__TRON_INSTALL_PATH__|$PROJECT_DIR|g" \
        -e "s|__HOME__|$HOME|g" \
        "$plist_src" > "$plist_dest"

    # Set permissions
    chmod 644 "$plist_dest"

    # Load the service
    log "Loading service..."
    launchctl load -w "$plist_dest"

    # Verify
    sleep 2
    if is_service_running "macos"; then
        success "Service installed and running"
    else
        warn "Service installed but not running. Check logs at $log_dir"
    fi

    echo ""
    echo "Service management commands:"
    echo "  Start:   launchctl load ~/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
    echo "  Stop:    launchctl unload ~/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
    echo "  Status:  launchctl list | grep $LAUNCHD_LABEL"
    echo "  Logs:    tail -f $log_dir/stdout.log"
}

# Uninstall on macOS
uninstall_macos() {
    log "Uninstalling launchd service..."

    local plist_dest="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

    if [ -f "$plist_dest" ]; then
        # Unload service
        launchctl unload "$plist_dest" 2>/dev/null || true

        # Remove plist
        rm -f "$plist_dest"

        success "Service uninstalled"
    else
        warn "Service not installed"
    fi
}

# Install on Linux using systemd
install_linux() {
    log "Installing systemd user service..."

    local service_src="$PROJECT_DIR/deploy/systemd/tron.service"
    local service_dest="$HOME/.config/systemd/user/$SYSTEMD_SERVICE.service"

    # Check source exists
    if [ ! -f "$service_src" ]; then
        error "systemd service file not found at $service_src"
    fi

    # Create systemd user directory
    mkdir -p "$HOME/.config/systemd/user"

    # Stop existing service if running
    if is_service_running "linux"; then
        log "Stopping existing service..."
        systemctl --user stop "$SYSTEMD_SERVICE" 2>/dev/null || true
    fi

    # Copy and configure service file
    log "Configuring systemd service..."
    sed -e "s|__TRON_INSTALL_PATH__|$PROJECT_DIR|g" \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__USER__|$(whoami)|g" \
        -e "s|__GROUP__|$(id -gn)|g" \
        "$service_src" > "$service_dest"

    # Set permissions
    chmod 644 "$service_dest"

    # Reload systemd
    log "Reloading systemd..."
    systemctl --user daemon-reload

    # Enable and start service
    log "Enabling and starting service..."
    systemctl --user enable "$SYSTEMD_SERVICE"
    systemctl --user start "$SYSTEMD_SERVICE"

    # Enable lingering (keeps user services running after logout)
    if command -v loginctl &> /dev/null; then
        loginctl enable-linger "$(whoami)" 2>/dev/null || true
    fi

    # Verify
    sleep 2
    if is_service_running "linux"; then
        success "Service installed and running"
    else
        warn "Service installed but not running. Check: journalctl --user -u $SYSTEMD_SERVICE"
    fi

    echo ""
    echo "Service management commands:"
    echo "  Start:   systemctl --user start $SYSTEMD_SERVICE"
    echo "  Stop:    systemctl --user stop $SYSTEMD_SERVICE"
    echo "  Status:  systemctl --user status $SYSTEMD_SERVICE"
    echo "  Logs:    journalctl --user -u $SYSTEMD_SERVICE -f"
}

# Uninstall on Linux
uninstall_linux() {
    log "Uninstalling systemd service..."

    local service_dest="$HOME/.config/systemd/user/$SYSTEMD_SERVICE.service"

    if [ -f "$service_dest" ]; then
        # Stop and disable service
        systemctl --user stop "$SYSTEMD_SERVICE" 2>/dev/null || true
        systemctl --user disable "$SYSTEMD_SERVICE" 2>/dev/null || true

        # Remove service file
        rm -f "$service_dest"

        # Reload systemd
        systemctl --user daemon-reload

        success "Service uninstalled"
    else
        warn "Service not installed"
    fi
}

# Show status
show_status() {
    local os="$1"

    echo ""
    log "Service Status"
    echo ""

    case "$os" in
        macos)
            if is_service_running "macos"; then
                echo -e "  Status: ${GREEN}Running${NC}"
                launchctl list "$LAUNCHD_LABEL" 2>/dev/null | head -5 || true
            else
                echo -e "  Status: ${RED}Not Running${NC}"
            fi
            ;;
        linux)
            if is_service_running "linux"; then
                echo -e "  Status: ${GREEN}Running${NC}"
                systemctl --user status "$SYSTEMD_SERVICE" --no-pager 2>/dev/null | head -10 || true
            else
                echo -e "  Status: ${RED}Not Running${NC}"
            fi
            ;;
    esac
}

# Print usage
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  install    Install Tron as a system service (default)"
    echo "  uninstall  Remove the system service"
    echo "  status     Show service status"
    echo "  help       Show this help message"
    echo ""
}

# Main execution
main() {
    local command="${1:-install}"
    local os
    os=$(detect_os)

    if [ "$os" = "unknown" ]; then
        error "Unsupported operating system. Only macOS and Linux are supported."
    fi

    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                   Tron Service Manager                        ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  OS: $os"
    echo "  Project: $PROJECT_DIR"
    echo ""

    case "$command" in
        install)
            case "$os" in
                macos) install_macos ;;
                linux) install_linux ;;
            esac
            ;;
        uninstall)
            case "$os" in
                macos) uninstall_macos ;;
                linux) uninstall_linux ;;
            esac
            ;;
        status)
            show_status "$os"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            error "Unknown command: $command. Use '$0 help' for usage."
            ;;
    esac
}

main "$@"
