#!/bin/bash
# automation.sh - sourced by tron; do not execute directly.

#=============================================================================
# AUTO-DEPLOY
#=============================================================================

AUTO_DEPLOY_PLIST_NAME="com.tron.auto-deploy"
AUTO_DEPLOY_PLIST_PATH="$HOME/Library/LaunchAgents/$AUTO_DEPLOY_PLIST_NAME.plist"
AUTO_DEPLOY_LOG="$CONTRIBUTOR_DIR/auto-deploy.log"
AUTO_DEPLOY_LAUNCHD_LOG="$CONTRIBUTOR_DIR/auto-deploy-launchd.log"
AUTO_DEPLOY_SCRIPT="$SCRIPT_DIR/auto-deploy"

cmd_auto_deploy() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true

    case "$subcmd" in
        install)  auto_deploy_install ;;
        uninstall) auto_deploy_uninstall ;;
        status)   auto_deploy_status ;;
        pause)    auto_deploy_pause ;;
        resume)   auto_deploy_resume ;;
        logs)     auto_deploy_logs "$@" ;;
        *)        echo "Usage: tron auto-deploy {install|uninstall|status|pause|resume|logs}"; exit 1 ;;
    esac
}

create_auto_deploy_plist() {
    mkdir -p "$CONTRIBUTOR_DIR"

    cat > "$AUTO_DEPLOY_PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AUTO_DEPLOY_PLIST_NAME</string>

    <key>ProgramArguments</key>
    <array>
        <string>$AUTO_DEPLOY_SCRIPT</string>
    </array>

    <key>StartInterval</key>
    <integer>60</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin</string>
        <key>TRON_DATA_DIR</key>
        <string>$TRON_HOME</string>
        <key>DEVELOPER_DIR</key>
        <string>/Applications/Xcode.app/Contents/Developer</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$AUTO_DEPLOY_LAUNCHD_LOG</string>

    <key>StandardErrorPath</key>
    <string>$AUTO_DEPLOY_LAUNCHD_LOG</string>
</dict>
</plist>
PLIST
}

auto_deploy_install() {
    require_project_dir

    print_header "Installing Auto-Deploy Watcher"

    # Unload existing job before overwriting plist
    if [ -f "$AUTO_DEPLOY_PLIST_PATH" ]; then
        launchd_stop "$AUTO_DEPLOY_PLIST_NAME"
    fi

    create_auto_deploy_plist
    print_success "Created: $AUTO_DEPLOY_PLIST_PATH"

    launchd_start "$AUTO_DEPLOY_PLIST_NAME"
    print_success "Loaded launchd job (polling every 60s)"

    rm -f "$AUTO_DEPLOY_PAUSE_FILE"
    echo ""
    echo "Auto-deploy is now active. Commands:"
    echo "  tron auto-deploy status  — check current state"
    echo "  tron auto-deploy pause   — temporarily disable"
    echo "  tron auto-deploy logs    — view deploy log"
}

auto_deploy_uninstall() {
    print_header "Uninstalling Auto-Deploy Watcher"

    if [ -f "$AUTO_DEPLOY_PLIST_PATH" ]; then
        launchd_stop "$AUTO_DEPLOY_PLIST_NAME"
        rm -f "$AUTO_DEPLOY_PLIST_PATH"
        print_success "Removed launchd job"
    else
        print_warning "No launchd job found"
    fi

    rm -f "$AUTO_DEPLOY_PAUSE_FILE"
    rm -f "$AUTO_DEPLOY_LOCK_FILE"
    print_success "Auto-deploy uninstalled"
}

auto_deploy_status() {
    echo ""
    echo -e "${CYAN}Auto-Deploy Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -f "$AUTO_DEPLOY_PLIST_PATH" ]; then
        if launchd_is_loaded "$AUTO_DEPLOY_PLIST_NAME"; then
            print_success "Launchd job: ${GREEN}LOADED${NC}"
        else
            print_warning "Launchd job: ${YELLOW}NOT LOADED${NC} (plist exists)"
        fi
    else
        print_warning "Not installed"
        echo ""
        return
    fi

    if [ -f "$AUTO_DEPLOY_PAUSE_FILE" ]; then
        print_warning "Status: ${YELLOW}PAUSED${NC}"
    else
        print_success "Status: ${GREEN}ACTIVE${NC}"
    fi

    if [ -f "$AUTO_DEPLOY_LOG" ]; then
        echo ""
        echo -e "${DIM}Last 5 log entries:${NC}"
        tail -5 "$AUTO_DEPLOY_LOG" | while IFS= read -r line; do
            echo -e "  ${DIM}$line${NC}"
        done
    fi

    echo ""
}

auto_deploy_pause() {
    mkdir -p "$(dirname "$AUTO_DEPLOY_PAUSE_FILE")"
    touch "$AUTO_DEPLOY_PAUSE_FILE"
    print_success "Auto-deploy paused"
    echo "  Resume with: tron auto-deploy resume"
}

auto_deploy_resume() {
    rm -f "$AUTO_DEPLOY_PAUSE_FILE"
    print_success "Auto-deploy resumed"
}

auto_deploy_logs() {
    local lines="${1:-50}"
    if [ -f "$AUTO_DEPLOY_LOG" ]; then
        tail -n "$lines" "$AUTO_DEPLOY_LOG"
    else
        echo "No auto-deploy log found yet."
    fi
}
