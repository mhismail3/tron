#!/bin/bash
# service.sh - sourced by tron-lib.sh; do not execute directly.

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

_launchd_target() { echo "gui/$(id -u)/$1"; }

launchd_stop() {
    launchctl bootout "$(_launchd_target "$1")" 2>/dev/null || true
}

launchd_start() {
    local plist="$HOME/Library/LaunchAgents/$1.plist"
    local target="$(_launchd_target "$1")"
    if launchctl print "$target" &>/dev/null; then
        launchctl kickstart -k "$target" 2>/dev/null || true
        return 0
    fi

    if [ "$1" = "$PLIST_NAME" ] && [ -x "$RELEASE_APP_BINARY" ] && [ -f "$RELEASE_LAUNCH_AGENT_PLIST" ]; then
        "$RELEASE_APP_BINARY" --tron-start-server-and-quit >/dev/null 2>&1 || true
        sleep 1
        launchctl kickstart -k "$target" 2>/dev/null || true
        return 0
    fi

    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
}

launchd_restart() {
    launchctl kickstart -k "$(_launchd_target "$1")" 2>/dev/null \
        || { launchd_stop "$1"; sleep 1; launchd_start "$1"; }
}

launchd_is_loaded() {
    launchctl print "$(_launchd_target "$1")" &>/dev/null
}

service_is_running() {
    launchd_is_loaded "$PLIST_NAME"
}

get_service_pid() {
    lsof -t -i :$PROD_PORT -sTCP:LISTEN 2>/dev/null || true
}

validate_prod_binary() {
    [ -f "$INSTALLED_BINARY" ] \
        && file "$INSTALLED_BINARY" 2>/dev/null | grep -q "Mach-O"
}

release_wrapper_available() {
    [ -x "$RELEASE_APP_BINARY" ] && [ -f "$RELEASE_LAUNCH_AGENT_PLIST" ]
}

ensure_prod_binary() {
    if validate_prod_binary; then
        return 0
    fi

    print_warning "Contributor service binary is missing or corrupt"

    if [ -f "$CONTRIBUTOR_DIR/tron.bak" ] \
        && file "$CONTRIBUTOR_DIR/tron.bak" 2>/dev/null | grep -q "Mach-O"; then
        print_status "Restoring from backup..."
        if ! create_app_bundle "$INSTALLED_BUNDLE" "$CONTRIBUTOR_DIR/tron.bak"; then
            return 1
        fi
        codesign_bundle "$INSTALLED_BUNDLE"
        print_success "Restored from backup"
        return 0
    fi

    print_error "No valid contributor service binary found. Run: tron manual-deploy"
    return 1
}

ensure_restartable_prod_server() {
    if release_wrapper_available; then
        return 0
    fi
    ensure_prod_binary
}

service_start() {
    if release_wrapper_available; then
        print_status "Starting service..."
        if "$RELEASE_APP_BINARY" --tron-start-server-and-quit >/dev/null 2>&1 \
            && wait_for_service_health 5; then
            local pid
            pid="$(listener_pid_for_port "$PROD_PORT")"
            print_success "Service started (PID: ${pid:-unknown})"
            echo "  Server: http://localhost:$PROD_PORT"
            echo "  Health: http://localhost:$PROD_PORT/health"
            return 0
        fi
        print_installed_service_restart_diagnostic
        return 1
    fi

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

wait_for_service_health() {
    local wait_seconds="${1:-12}"
    local attempt max_attempts
    if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]] || [ "$wait_seconds" -lt 1 ]; then
        wait_seconds=12
    fi
    max_attempts=$((wait_seconds * 2))
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if health_check && [ -n "$(listener_pid_for_port "$PROD_PORT")" ]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

print_installed_service_restart_diagnostic() {
    print_error "Installed service restart was requested, but /health never passed."
    echo "  The installed helper was not reported as restarted because no healthy listener was observed."
    if [ -x "$RELEASE_APP_BINARY" ]; then
        echo "  /Applications/Tron.app may be stale relative to the current profile defaults."
        echo "  Stale helpers can fail while parsing capability schema providerSurface values."
        echo "  Reinstall or update /Applications/Tron.app, then run: tron start"
    else
        echo "  /Applications/Tron.app is missing or not executable; install it before relying on production restore."
    fi
}

restart_installed_service_after_dev() {
    local wait_seconds="${1:-12}"
    print_status "Restarting installed service..."
    if ! ensure_restartable_prod_server; then
        print_error "Cannot restart: install Tron.app at /Applications/Tron.app"
        return 1
    fi
    launchd_start "$PLIST_NAME"
    if wait_for_service_health "$wait_seconds"; then
        local pid
        pid="$(listener_pid_for_port "$PROD_PORT")"
        print_success "Installed service restarted (PID: ${pid:-unknown})"
        return 0
    fi
    print_installed_service_restart_diagnostic
    return 1
}

listener_pid_for_port() {
    local port="${1:-$PROD_PORT}"
    lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -n 1 || true
}

pid_uptime() {
    local pid="$1"
    [ -n "$pid" ] || return 0
    ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || true
}

server_health_bool() {
    if health_check; then
        echo "true"
    else
        echo "false"
    fi
}

cmd_status_json() {
    local service_loaded=false
    local dev_loaded=false
    local mode="stopped"
    local listener_pid
    local pid_file_pid=""
    local pid_file_stale=false
    local uptime=""
    local healthy

    if service_is_running; then
        service_loaded=true
        mode="prod"
    fi
    if launchd_is_loaded "$DEV_PLIST_NAME"; then
        dev_loaded=true
        if [ "$mode" = "stopped" ]; then
            mode="dev_starting"
        fi
    fi

    listener_pid="$(listener_pid_for_port "$PROD_PORT")"
    if [ -f "$DEV_BACKGROUND_PID_FILE" ]; then
        pid_file_pid="$(cat "$DEV_BACKGROUND_PID_FILE" 2>/dev/null || true)"
    fi
    if [ -n "$listener_pid" ]; then
        if [ "$service_loaded" = true ]; then
            mode="prod"
        elif [ "$dev_loaded" = true ]; then
            mode="dev_takeover"
        else
            mode="dev_takeover"
        fi
        uptime="$(pid_uptime "$listener_pid")"
    elif [ -n "$pid_file_pid" ]; then
        pid_file_stale=true
    fi

    healthy="$(server_health_bool)"

    TRON_STATUS_MODE="$mode" \
    TRON_STATUS_SERVICE_LOADED="$service_loaded" \
    TRON_STATUS_DEV_LOADED="$dev_loaded" \
    TRON_STATUS_DEV_LABEL="$DEV_PLIST_NAME" \
    TRON_STATUS_LISTENER_PID="$listener_pid" \
    TRON_STATUS_PID_FILE_PID="$pid_file_pid" \
    TRON_STATUS_PID_FILE_STALE="$pid_file_stale" \
    TRON_STATUS_HEALTHY="$healthy" \
    TRON_STATUS_UPTIME="$uptime" \
    TRON_STATUS_SERVER_URL="http://localhost:$PROD_PORT" \
    TRON_STATUS_HEALTH_URL="http://localhost:$PROD_PORT/health" \
    TRON_STATUS_DB_PATH="$DB_PATH" \
    TRON_STATUS_LOG_PATH="$DEV_BACKGROUND_LOG" \
    TRON_STATUS_PID_FILE_PATH="$DEV_BACKGROUND_PID_FILE" \
    python3 - <<'PY'
import json
import os

pid = os.environ.get("TRON_STATUS_LISTENER_PID") or None
pid_file_pid = os.environ.get("TRON_STATUS_PID_FILE_PID") or None
print(json.dumps({
    "mode": os.environ["TRON_STATUS_MODE"],
    "serviceLoaded": os.environ["TRON_STATUS_SERVICE_LOADED"] == "true",
    "devLaunchdLoaded": os.environ["TRON_STATUS_DEV_LOADED"] == "true",
    "devLaunchdLabel": os.environ["TRON_STATUS_DEV_LABEL"],
    "listenerPid": int(pid) if pid and pid.isdigit() else None,
    "pidFilePid": int(pid_file_pid) if pid_file_pid and pid_file_pid.isdigit() else None,
    "pidFileStale": os.environ["TRON_STATUS_PID_FILE_STALE"] == "true",
    "healthy": os.environ["TRON_STATUS_HEALTHY"] == "true",
    "uptime": os.environ.get("TRON_STATUS_UPTIME") or None,
    "server": os.environ["TRON_STATUS_SERVER_URL"],
    "health": os.environ["TRON_STATUS_HEALTH_URL"],
    "databasePath": os.environ["TRON_STATUS_DB_PATH"],
    "logPath": os.environ["TRON_STATUS_LOG_PATH"],
    "pidFilePath": os.environ["TRON_STATUS_PID_FILE_PATH"],
}, sort_keys=True))
PY
}

cmd_status() {
    local output_json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) output_json=true; shift ;;
            -h|--help)
                echo ""
                echo -e "${CYAN}tron status${NC} - Show service/dev takeover status"
                echo ""
                echo "Usage: tron status [--json]"
                echo ""
                echo "Options:"
                echo "  --json  Emit machine-readable status on stdout"
                echo ""
                return 0
                ;;
            *) shift ;;
        esac
    done

    if [ "$output_json" = true ]; then
        cmd_status_json
        return
    fi

    # $PROJECT_DIR is set by workspace script; otherwise try workspace-path file
    local git_dir="${PROJECT_DIR:-}"
    if [ -z "$git_dir" ] && [ -f "$CONTRIBUTOR_DIR/workspace-path" ]; then
        git_dir=$(cat "$CONTRIBUTOR_DIR/workspace-path")
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
        dev_pid=$(listener_pid_for_port "$PROD_PORT")
        if [ -n "$dev_pid" ]; then
            echo ""
            print_success "Dev takeover: ${GREEN}ACTIVE${NC} (PID: $dev_pid)"
            echo "  Server: http://localhost:$PROD_PORT"
            echo "  Health: http://localhost:$PROD_PORT/health"
            local dev_uptime=$(ps -o etime= -p "$dev_pid" 2>/dev/null | tr -d ' ')
            [ -n "$dev_uptime" ] && echo "  Uptime: $dev_uptime"
            if health_check; then
                echo -e "  Status: ${GREEN}Healthy${NC}"
            else
                echo -e "  Status: ${YELLOW}Not responding${NC}"
            fi
        elif launchd_is_loaded "$DEV_PLIST_NAME"; then
            echo ""
            print_warning "Dev takeover launchd job is loaded but no listener is active"
            echo "  Label: $DEV_PLIST_NAME"
            echo "  Log file: $DEV_BACKGROUND_LOG"
        fi
    fi

    if ! service_is_running; then
        local stale_pid_file="$DEV_BACKGROUND_PID_FILE"
        local stale_pid=""
        if [ -f "$stale_pid_file" ]; then
            stale_pid="$(cat "$stale_pid_file" 2>/dev/null || true)"
            if [ -n "$stale_pid" ] && [ -z "$(listener_pid_for_port "$PROD_PORT")" ]; then
                echo ""
                print_warning "Dev takeover pid file is stale (recorded PID: $stale_pid)"
                echo "  PID file: $stale_pid_file"
                echo "  Log file: $DEV_BACKGROUND_LOG"
            fi
        fi
    fi

    echo ""
    echo -e "${DIM}Logs:${NC}"
    echo -e "  ${DIM}Query: tron logs [-l level] [-q search] [-s session] [-w workspace] [-t trace]${NC}"
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

cmd_uninstall() {
    local reset_settings=false
    local reset_credentials=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reset-settings)
                reset_settings=true
                shift
                ;;
            --reset-credentials)
                reset_credentials=true
                shift
                ;;
            -h|--help)
                echo "Usage: tron uninstall [--reset-settings] [--reset-credentials]"
                echo ""
                echo "Removes the LaunchAgent, CLI entrypoint, runtime bundles, and Mac onboarding marker."
                echo "Preserves ~/.tron/internal/database and ~/.tron/workspace. Optional flags remove"
                echo "settings overrides in ~/.tron/profiles/user/profile.toml and/or ~/.tron/profiles/auth.json."
                return 0
                ;;
            *)
                print_error "Unknown uninstall option: $1"
                echo "Usage: tron uninstall [--reset-settings] [--reset-credentials]"
                return 2
                ;;
        esac
    done

    print_header "Uninstalling Tron"

    if service_is_running; then
        print_status "Stopping service..."
        launchd_stop "$PLIST_NAME"
        sleep 1
    fi

    print_status "Removing launchd service..."
    rm -f "$PLIST_PATH"

    print_status "Removing CLI entrypoint..."
    rm -f "$BIN_DIR/tron"

    print_status "Removing contributor runtime artifacts..."
    rm -rf "$INSTALLED_BUNDLE" "$DEV_BUNDLE" "$CONTRIBUTOR_DIR/tron-lib.d"
    rm -f \
        "$CONTRIBUTOR_DIR/tron.bak" \
        "$CONTRIBUTOR_DIR/tron-cli" \
        "$CONTRIBUTOR_DIR/tron-lib.sh" \
        "$CONTRIBUTOR_DIR/tron-agent.entitlements" \
        "$CONTRIBUTOR_DIR/AppIcon.icns" \
        "$CONTRIBUTOR_DIR/workspace-path" \
        "$CONTRIBUTOR_DIR/deployed-commit" \
        "$CONTRIBUTOR_DIR/last-deployment.json" \
        "$CONTRIBUTOR_DIR/restart-sentinel.json"

    print_status "Resetting Mac onboarding state..."
    rm -f "$ONBOARDED_MARKER_PATH"

    if [ "$reset_settings" = true ]; then
        print_status "Clearing profile settings overrides..."
        clear_user_profile_settings
    fi

    if [ "$reset_credentials" = true ]; then
        print_status "Removing saved credentials..."
        rm -f "$AUTH_FILE"
    fi

    echo ""
    print_success "Tron uninstalled"
    print_warning "Database and workspace data preserved in: $TRON_HOME"
    echo ""
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

    if [ ! -f "$CONTRIBUTOR_DIR/tron.bak" ]; then
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
    if ! create_app_bundle "$INSTALLED_BUNDLE" "$CONTRIBUTOR_DIR/tron.bak"; then
        exit 1
    fi
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
