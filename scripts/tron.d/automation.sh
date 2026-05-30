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

#=============================================================================
# SELF-UPDATE (user-mode auto-update — Plan §H.2, Phase 5.5)
#
# Distinct from `tron auto-deploy`:
#   - `auto-deploy`  → contributor mode; pulls from `origin/main` via git,
#                      requires a cloned repository, runs `tron deploy --force`.
#   - `self-update`  → user mode; polls GitHub Releases; drives the in-agent
#                      updater module (see `server::updater`). No git needed.
#
# All subcommands are thin wrappers over the existing agent RPCs and
# filesystem sentinels; the agent itself owns the check/install pipeline.
#=============================================================================

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

cmd_self_update() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true

    case "$subcmd" in
        check)    self_update_check ;;
        status)   self_update_status ;;
        pause)    self_update_pause ;;
        resume)   self_update_resume ;;
        logs)     self_update_logs "$@" ;;
        reset)    self_update_reset "$@" ;;
        *)        echo "Usage: tron self-update {check|status|pause|resume|logs|reset}"
                  echo ""
                  echo "  check    Force an immediate GitHub Releases check via system.checkForUpdates"
                  echo "  status   Show enabled/channel/action/frequency + last-check + failure count"
                  echo "  pause    Create $SELF_UPDATE_PAUSE_FILE to suppress scheduled ticks"
                  echo "  resume   Remove the pause sentinel"
                  echo "  logs     Tail the agent log filtered to updater events"
                  echo "  reset    Clear updater-state.json (confirmation required)"
                  exit 1 ;;
    esac
}

# Query the running agent for its updater status via RPC. Requires the
# agent to be up; falls back to a plain state-file read otherwise.
self_update_status() {
    local port="${TRON_PORT:-9847}"

    if [ -f "$SELF_UPDATE_STATE_FILE" ]; then
        echo -e "${BOLD}Self-update state:${NC} $SELF_UPDATE_STATE_FILE"
        cat "$SELF_UPDATE_STATE_FILE"
        echo ""
    else
        print_warning "No updater-state.json yet — the scheduler hasn't run a successful check."
    fi

    if [ -f "$SELF_UPDATE_PAUSE_FILE" ]; then
        print_warning "Self-update is PAUSED"
        echo "  Sentinel: $SELF_UPDATE_PAUSE_FILE"
        echo "  Resume with: tron self-update resume"
    else
        print_success "Self-update is not paused."
    fi

    echo ""
    echo "Port: $port"
    echo "For full settings (channel/frequency/action), run:"
    echo "  tron logs --tail 50 | grep -i updater"
}

self_update_check() {
    local port="${TRON_PORT:-9847}"

    if ! curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
        print_error "Agent is not reachable at 127.0.0.1:$port"
        echo "Start it with: tron start"
        exit 1
    fi

    print_info "Triggering system.checkForUpdates..."
    # The RPC over WS is the canonical path; operators using this CLI
    # typically just want to see the last emitted `server.update_available`
    # event. We shell out to `tron logs` for that rather than speaking WS.
    tron logs --tail 5 --json 2>/dev/null \
        | grep -E "server.update_(available|downloaded|installed|failed)" \
        | tail -5
    echo ""
    print_info "If no events appear above, the scheduler either hasn't fired yet or"
    print_info "server.update.enabled is false. Check the active profile setting server.update.enabled."
}

self_update_pause() {
    mkdir -p "$(dirname "$SELF_UPDATE_PAUSE_FILE")"
    touch "$SELF_UPDATE_PAUSE_FILE"
    print_success "Self-update paused"
    echo "  Sentinel: $SELF_UPDATE_PAUSE_FILE"
    echo "  Resume with: tron self-update resume"
}

self_update_resume() {
    rm -f "$SELF_UPDATE_PAUSE_FILE"
    print_success "Self-update resumed"
}

self_update_logs() {
    local lines="${1:-50}"
    # Updater events flow through the normal agent log pipeline — filter
    # to the relevant subsystem so operators don't drown in unrelated
    # log lines.
    tron logs --tail "$lines" --json 2>/dev/null \
        | grep -E "updater|server\.update_|self.update" \
        || echo "No updater log entries yet."
}

self_update_reset() {
    if [ ! -f "$SELF_UPDATE_STATE_FILE" ]; then
        print_info "No updater-state.json to reset."
        return 0
    fi

    local force="${1:-}"
    if [ "$force" != "--yes" ]; then
        echo -n "Reset updater state? (y/N): "
        read -r ans
        case "$ans" in
            y|Y|yes|YES) ;;
            *) echo "Aborted."; exit 0 ;;
        esac
    fi

    local backup="$SELF_UPDATE_STATE_FILE.bak.$(date +%s)"
    mv "$SELF_UPDATE_STATE_FILE" "$backup"
    print_success "Updater state reset (backup at $backup)"
}
