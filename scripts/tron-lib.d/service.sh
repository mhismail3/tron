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

begin_contributor_pair_update() {
    local operation="${1:-update}"
    mkdir -p "$(dirname "$DEPLOY_LOCK_FILE")" || return 1
    if contributor_pair_update_is_owned; then
        print_error "This process already owns the contributor helper update lock"
        return 1
    fi

    # macOS lockf holds the BSD mutex on this shell-owned descriptor. The
    # operation-tagged sentinel survives process death so readers fail closed
    # and a different writer cannot reinterpret an incomplete transaction.
    exec 9>> "$DEPLOY_LOCK_FILE" || return 1
    local pending=""
    if ! /usr/bin/lockf -s -t 0 9; then
        exec 9>&-
        pending=$(cat "$DEPLOY_UPDATE_FILE" 2>/dev/null || true)
        if [[ "$pending" =~ ^([^:]+):([0-9]+)$ ]]; then
            print_error "Another contributor helper update is active (${BASH_REMATCH[1]}, PID: ${BASH_REMATCH[2]})"
        else
            print_error "Could not acquire the contributor helper update lock"
        fi
        return 1
    fi

    local backup_dir="$CONTRIBUTOR_DIR/contributor-pair.bak"
    if ! reconcile_contributor_pair_retirement; then
        exec 9>&-
        return 1
    fi
    if [ -e "$backup_dir" ] \
        && [ "$operation" != "rollback" ] \
        && [ "$operation" != "uninstall" ]; then
        exec 9>&-
        print_error "A prior contributor update needs rollback; run: tron rollback --yes"
        return 1
    fi
    if [ "$operation" = "rollback" ] \
        && ! contributor_pair_backup_is_complete "$backup_dir"; then
        exec 9>&-
        print_error "No complete contributor rollback plan found"
        return 1
    fi

    if ! printf '%s:%s\n' "$operation" "$$" > "$DEPLOY_UPDATE_FILE"; then
        exec 9>&-
        return 1
    fi
    CONTRIBUTOR_PAIR_LOCK_OWNER="$$"
    CONTRIBUTOR_PAIR_LOCK_OPERATION="$operation"
}

contributor_pair_update_is_owned() {
    [[ "${CONTRIBUTOR_PAIR_LOCK_OWNER:-}" = "$$" \
        && -n "${CONTRIBUTOR_PAIR_LOCK_OPERATION:-}" \
        && "$(cat "$DEPLOY_UPDATE_FILE" 2>/dev/null || true)" \
            = "${CONTRIBUTOR_PAIR_LOCK_OPERATION}:$$" ]]
}

begin_contributor_pair_read() {
    exec 8>> "$DEPLOY_LOCK_FILE" || return 1
    if ! /usr/bin/lockf -s -t 0 8; then
        exec 8>&-
        print_error "Contributor authentication is blocked by a helper/CLI update"
        return 1
    fi
    if [ -f "$DEPLOY_UPDATE_FILE" ] \
        || [ -e "$CONTRIBUTOR_DIR/contributor-pair.bak" ]; then
        exec 8>&-
        print_error "A contributor helper/CLI update needs recovery before authentication"
        return 1
    fi
    CONTRIBUTOR_PAIR_READER_OWNER="$$"
}

end_contributor_pair_read() {
    if [ "${CONTRIBUTOR_PAIR_READER_OWNER:-}" != "$$" ]; then
        print_error "Contributor helper/CLI reader lock is not owned by this process"
        return 1
    fi
    exec 8>&-
    unset CONTRIBUTOR_PAIR_READER_OWNER
}

end_contributor_pair_update() {
    if ! contributor_pair_update_is_owned; then
        print_error "Contributor helper update lock is not owned by this process"
        return 1
    fi
    rm -f "$DEPLOY_UPDATE_FILE" || return 1
    local cleanup_status=0
    reconcile_contributor_pair_retirement || cleanup_status=$?
    exec 9>&-
    unset CONTRIBUTOR_PAIR_LOCK_OWNER CONTRIBUTOR_PAIR_LOCK_OPERATION \
        CONTRIBUTOR_PAIR_RECOVERY_PENDING
    return "$cleanup_status"
}

runtime_cli_payload_entries() {
    printf '%s\n' \
        tron-cli \
        tron-lib.sh \
        tron-lib.d \
        tron-agent.entitlements \
        AppIcon.icns \
        workspace-path \
        deployed-commit
}

validate_contributor_bundle() {
    local bundle="$1"
    local binary="$bundle/Contents/MacOS/tron"
    [[ -d "$bundle" && -f "$binary" && -x "$binary" ]] \
        && file "$binary" 2>/dev/null | grep -q "Mach-O" \
        && /usr/bin/codesign --verify --deep --strict "$bundle" >/dev/null 2>&1
}

copy_contributor_path() {
    /bin/cp -pP "$1" "$2"
}

contributor_pair_has_runtime_members() {
    local entry
    { [ -e "$INSTALLED_BUNDLE" ] || [ -L "$INSTALLED_BUNDLE" ]; } && return 0
    while IFS= read -r entry; do
        { [ -e "$CONTRIBUTOR_DIR/$entry" ] \
            || [ -L "$CONTRIBUTOR_DIR/$entry" ]; } && return 0
    done < <(runtime_cli_payload_entries)
    return 1
}

contributor_pair_is_complete() {
    [[ -d "$INSTALLED_BUNDLE" \
        && ! -L "$INSTALLED_BUNDLE" \
        && -x "$CONTRIBUTOR_DIR/tron-cli" \
        && ! -L "$CONTRIBUTOR_DIR/tron-cli" \
        && -f "$CONTRIBUTOR_DIR/tron-lib.sh" \
        && ! -L "$CONTRIBUTOR_DIR/tron-lib.sh" \
        && -d "$CONTRIBUTOR_DIR/tron-lib.d" \
        && ! -L "$CONTRIBUTOR_DIR/tron-lib.d" \
        && -f "$CONTRIBUTOR_DIR/tron-agent.entitlements" \
        && ! -L "$CONTRIBUTOR_DIR/tron-agent.entitlements" \
        && -f "$CONTRIBUTOR_DIR/AppIcon.icns" \
        && ! -L "$CONTRIBUTOR_DIR/AppIcon.icns" \
        && -f "$CONTRIBUTOR_DIR/workspace-path" \
        && ! -L "$CONTRIBUTOR_DIR/workspace-path" \
        && -f "$PLIST_PATH" \
        && ! -L "$PLIST_PATH" \
        && -L "$BIN_DIR/tron" \
        && "$(readlink "$BIN_DIR/tron" 2>/dev/null || true)" \
            = "$CONTRIBUTOR_DIR/tron-cli" ]] \
        && validate_contributor_bundle "$INSTALLED_BUNDLE"
}

contributor_pair_backup_kind() {
    local backup_dir="${1:-$CONTRIBUTOR_DIR/contributor-pair.bak}"
    local kind=""
    kind=$(cat "$backup_dir/kind" 2>/dev/null || true)
    case "$kind" in
        pair|no-prior-pair) printf '%s\n' "$kind" ;;
        *) return 1 ;;
    esac
}

contributor_pair_backup_is_complete() {
    local backup_dir="${1:-$CONTRIBUTOR_DIR/contributor-pair.bak}"
    local kind=""
    kind=$(contributor_pair_backup_kind "$backup_dir") || return 1
    if [ "$kind" = "no-prior-pair" ]; then
        local entry
        if [ -e "$backup_dir/Tron-Deploy.app" ] \
            || [ -L "$backup_dir/Tron-Deploy.app" ]; then
            return 1
        fi
        while IFS= read -r entry; do
            if [ -e "$backup_dir/$entry" ] || [ -L "$backup_dir/$entry" ]; then
                return 1
            fi
        done < <(runtime_cli_payload_entries)
        return 0
    fi
    [[ -d "$backup_dir/Tron-Deploy.app" \
        && ! -L "$backup_dir/Tron-Deploy.app" \
        && -x "$backup_dir/tron-cli" \
        && ! -L "$backup_dir/tron-cli" \
        && -f "$backup_dir/tron-lib.sh" \
        && ! -L "$backup_dir/tron-lib.sh" \
        && -d "$backup_dir/tron-lib.d" \
        && ! -L "$backup_dir/tron-lib.d" \
        && -f "$backup_dir/tron-agent.entitlements" \
        && ! -L "$backup_dir/tron-agent.entitlements" \
        && -f "$backup_dir/AppIcon.icns" \
        && ! -L "$backup_dir/AppIcon.icns" \
        && -f "$backup_dir/workspace-path" \
        && ! -L "$backup_dir/workspace-path" \
        && -f "$backup_dir/launchd.plist" \
        && ! -L "$backup_dir/launchd.plist" \
        && -L "$backup_dir/cli-entrypoint" ]] \
        && validate_contributor_bundle "$backup_dir/Tron-Deploy.app"
}

reconcile_contributor_pair_retirement() {
    local committed="$CONTRIBUTOR_DIR/.contributor-pair.bak.committed"
    local restored="$CONTRIBUTOR_DIR/.contributor-pair.bak.restored"
    if [ -e "$committed" ] && [ -e "$restored" ]; then
        print_error "Conflicting contributor rollback retirement state"
        return 1
    fi
    if [ -e "$committed" ]; then
        contributor_pair_backup_kind "$committed" >/dev/null \
            && contributor_pair_is_complete || {
                print_error "Committed contributor pair is incomplete; recovery remains blocked"
                return 1
            }
        rm -rf "$committed" || return 1
    fi
    if [ -e "$restored" ]; then
        local restored_kind=""
        restored_kind=$(contributor_pair_backup_kind "$restored") || {
            print_error "Restored contributor rollback plan is invalid"
            return 1
        }
        if { [ "$restored_kind" = "pair" ] && ! contributor_pair_is_complete; } \
            || { [ "$restored_kind" = "no-prior-pair" ] \
                && contributor_pair_has_runtime_members; }; then
            print_error "Restored contributor state is incomplete; recovery remains blocked"
            return 1
        fi
        rm -rf "$restored" || return 1
    fi
}

backup_contributor_pair() {
    local backup_dir="$CONTRIBUTOR_DIR/contributor-pair.bak"
    local staging_dir="$CONTRIBUTOR_DIR/.contributor-pair.bak.staging"
    local kind=""
    if ! contributor_pair_update_is_owned; then
        print_error "Backing up the contributor pair requires the helper update lock"
        return 1
    fi
    rm -rf "$staging_dir" || return 1
    if [ -e "$backup_dir" ]; then
        print_error "A contributor CLI rollback payload already exists; resolve it before deploying."
        return 1
    fi
    if contributor_pair_is_complete; then
        kind="pair"
    elif contributor_pair_has_runtime_members; then
        print_error "Installed contributor pair is incomplete; refusing to preserve a partial state"
        return 1
    else
        kind="no-prior-pair"
    fi

    mkdir -p "$staging_dir" || return 1
    if [ "$kind" = "pair" ]; then
        local entry
        while IFS= read -r entry; do
            if [ -e "$CONTRIBUTOR_DIR/$entry" ]; then
                if ! ditto "$CONTRIBUTOR_DIR/$entry" "$staging_dir/$entry"; then
                    rm -rf "$staging_dir"
                    return 1
                fi
            fi
        done < <(runtime_cli_payload_entries)
        if ! ditto "$INSTALLED_BUNDLE" "$staging_dir/Tron-Deploy.app" \
            || ! validate_contributor_bundle "$staging_dir/Tron-Deploy.app"; then
            rm -rf "$staging_dir"
            return 1
        fi
    fi
    if [ -e "$PLIST_PATH" ] || [ -L "$PLIST_PATH" ]; then
        copy_contributor_path "$PLIST_PATH" "$staging_dir/launchd.plist" || return 1
    fi
    if [ -e "$BIN_DIR/tron" ] || [ -L "$BIN_DIR/tron" ]; then
        copy_contributor_path "$BIN_DIR/tron" "$staging_dir/cli-entrypoint" || return 1
    fi
    printf '%s\n' "$kind" > "$staging_dir/kind" || return 1
    contributor_pair_backup_is_complete "$staging_dir" || return 1
    if ! mv "$staging_dir" "$backup_dir"; then
        rm -rf "$staging_dir"
        return 1
    fi
}

restore_contributor_bundle() {
    if ! contributor_pair_update_is_owned; then
        print_error "Contributor helper rollback requires the helper update lock"
        return 1
    fi

    local backup_bundle="$CONTRIBUTOR_DIR/contributor-pair.bak/Tron-Deploy.app"
    local staging_bundle="$CONTRIBUTOR_DIR/.Tron-Deploy.app.restore"
    local discard_bundle="$CONTRIBUTOR_DIR/.Tron-Deploy.app.discard"
    if ! validate_contributor_bundle "$backup_bundle"; then
        print_error "No complete signed contributor helper bundle found for rollback"
        return 1
    fi

    rm -rf "$staging_bundle" "$discard_bundle" || return 1
    if ! ditto "$backup_bundle" "$staging_bundle" \
        || ! validate_contributor_bundle "$staging_bundle"; then
        rm -rf "$staging_bundle"
        return 1
    fi
    if [ -e "$INSTALLED_BUNDLE" ]; then
        mv "$INSTALLED_BUNDLE" "$discard_bundle" || return 1
    fi
    if ! mv "$staging_bundle" "$INSTALLED_BUNDLE"; then
        [ ! -e "$INSTALLED_BUNDLE" ] && [ -e "$discard_bundle" ] \
            && mv "$discard_bundle" "$INSTALLED_BUNDLE" 2>/dev/null || true
        return 1
    fi
    rm -rf "$discard_bundle"
}

restore_contributor_entrypoints() {
    if ! contributor_pair_update_is_owned; then
        print_error "Contributor entrypoint rollback requires the helper update lock"
        return 1
    fi
    local backup_dir="$CONTRIBUTOR_DIR/contributor-pair.bak"
    rm -f "$PLIST_PATH" || return 1
    if [ -e "$backup_dir/launchd.plist" ] \
        || [ -L "$backup_dir/launchd.plist" ]; then
        mkdir -p "$(dirname "$PLIST_PATH")" || return 1
        copy_contributor_path "$backup_dir/launchd.plist" "$PLIST_PATH" || return 1
    fi
    rm -rf "$BIN_DIR/tron" || return 1
    if [ -e "$backup_dir/cli-entrypoint" ] \
        || [ -L "$backup_dir/cli-entrypoint" ]; then
        mkdir -p "$BIN_DIR" || return 1
        copy_contributor_path "$backup_dir/cli-entrypoint" "$BIN_DIR/tron" || return 1
    fi
}

restore_runtime_cli_payload() {
    if ! contributor_pair_update_is_owned; then
        print_error "Contributor CLI rollback requires the helper update lock"
        return 1
    fi
    local backup_dir="$CONTRIBUTOR_DIR/contributor-pair.bak"
    if [[ ! -f "$backup_dir/tron-cli" \
        || ! -f "$backup_dir/tron-lib.sh" \
        || ! -d "$backup_dir/tron-lib.d" ]]; then
        print_error "No complete contributor CLI payload backup found for rollback"
        return 1
    fi

    local entry
    while IFS= read -r entry; do
        rm -rf "$CONTRIBUTOR_DIR/$entry"
        if [ -e "$backup_dir/$entry" ]; then
            ditto "$backup_dir/$entry" "$CONTRIBUTOR_DIR/$entry" || return 1
        fi
    done < <(runtime_cli_payload_entries)
}

remove_contributor_pair_runtime() {
    if ! contributor_pair_update_is_owned; then
        print_error "Contributor cleanup requires the helper update lock"
        return 1
    fi
    rm -rf "$INSTALLED_BUNDLE" || return 1
    local entry
    while IFS= read -r entry; do
        rm -rf "$CONTRIBUTOR_DIR/$entry" || return 1
    done < <(runtime_cli_payload_entries)
}

restore_contributor_pair_plan() {
    local kind=""
    kind=$(contributor_pair_backup_kind) || {
        print_error "No complete contributor rollback plan found"
        return 1
    }
    case "$kind" in
        pair)
            restore_contributor_bundle || return 1
            restore_runtime_cli_payload || return 1
            ;;
        no-prior-pair)
            remove_contributor_pair_runtime || return 1
            ;;
    esac
    restore_contributor_entrypoints
}

discard_contributor_pair_backup() {
    local outcome="${1:-commit}"
    if ! contributor_pair_update_is_owned; then
        print_error "Discarding the contributor rollback pair requires the helper update lock"
        return 1
    fi
    local backup_dir="$CONTRIBUTOR_DIR/contributor-pair.bak"
    local kind=""
    kind=$(contributor_pair_backup_kind "$backup_dir") || {
        print_error "No complete contributor rollback plan is ready to retire"
        return 1
    }
    case "$outcome" in
        commit)
            contributor_pair_is_complete || {
                print_error "Contributor pair is incomplete; refusing to commit update"
                return 1
            }
            ;;
        rollback)
            if { [ "$kind" = "pair" ] && ! contributor_pair_is_complete; } \
                || { [ "$kind" = "no-prior-pair" ] \
                    && contributor_pair_has_runtime_members; }; then
                print_error "Contributor rollback did not restore the prior state"
                return 1
            fi
            ;;
        *)
            print_error "Unknown contributor rollback retirement outcome: $outcome"
            return 1
            ;;
    esac
    local discard_dir="$CONTRIBUTOR_DIR/.contributor-pair.bak.committed"
    [ "$outcome" = "rollback" ] \
        && discard_dir="$CONTRIBUTOR_DIR/.contributor-pair.bak.restored"
    rm -rf "$discard_dir" || return 1
    if [ -e "$backup_dir" ]; then
        mv "$backup_dir" "$discard_dir" || return 1
    fi
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

finish_contributor_pair_recovery() {
    if [ "${CONTRIBUTOR_PAIR_RECOVERY_PENDING:-}" != "1" ]; then
        return 0
    fi
    discard_contributor_pair_backup rollback || return 1
    end_contributor_pair_update
}

ensure_prod_binary() {
    if [ -e "$CONTRIBUTOR_DIR/.contributor-pair.bak.committed" ] \
        || [ -e "$CONTRIBUTOR_DIR/.contributor-pair.bak.restored" ]; then
        begin_contributor_pair_update recovery || return 1
        end_contributor_pair_update || return 1
    fi

    local pair_backup="$CONTRIBUTOR_DIR/contributor-pair.bak"
    local backup_kind=""
    backup_kind=$(contributor_pair_backup_kind 2>/dev/null || true)
    if [ "$backup_kind" = "no-prior-pair" ]; then
        print_error "A clean contributor install is incomplete. Run: tron rollback --yes"
        return 1
    fi
    local backup_binary="$pair_backup/Tron-Deploy.app/Contents/MacOS/tron"
    if [ "$backup_kind" = "pair" ] \
        && [ -f "$backup_binary" ] \
        && file "$backup_binary" 2>/dev/null | grep -q "Mach-O"; then
        begin_contributor_pair_update rollback || return 1
        if [ "$(contributor_pair_backup_kind 2>/dev/null || true)" != "pair" ] \
            || ! contributor_pair_backup_is_complete "$pair_backup"; then
            print_error "Contributor rollback plan changed before recovery acquired the writer lock"
            return 1
        fi
        print_status "Restoring from backup..."
        restore_contributor_pair_plan || return 1
        CONTRIBUTOR_PAIR_RECOVERY_PENDING=1
        print_success "Restored from backup; awaiting /health before retiring rollback"
        return 0
    fi
    if [ -f "$DEPLOY_UPDATE_FILE" ]; then
        print_error "A contributor helper update needs recovery before service start"
        return 1
    fi
    if validate_prod_binary; then
        return 0
    fi

    print_warning "Contributor service binary is missing or corrupt"
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

    if ! ensure_prod_binary; then
        return 1
    fi
    if [ ! -f "$PLIST_PATH" ]; then
        print_error "Service not installed. Run: tron install"
        return 1
    fi

    print_status "Starting service..."
    launchd_restart "$PLIST_NAME"
    sleep 2

    if service_is_running && wait_for_service_health 12; then
        finish_contributor_pair_recovery || return 1
        local pid
        pid=$(get_service_pid)
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
        finish_contributor_pair_recovery || return 1
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

    begin_contributor_pair_update uninstall || return 1

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
    rm -rf \
        "$INSTALLED_BUNDLE" \
        "$DEV_BUNDLE" \
        "$CONTRIBUTOR_DIR/tron-lib.d" \
        "$CONTRIBUTOR_DIR/contributor-pair.bak" \
        "$CONTRIBUTOR_DIR/.contributor-pair.bak.staging" \
        "$CONTRIBUTOR_DIR/.contributor-pair.bak.committed" \
        "$CONTRIBUTOR_DIR/.contributor-pair.bak.restored" \
        "$CONTRIBUTOR_DIR/.Tron-Deploy.app.restore" \
        "$CONTRIBUTOR_DIR/.Tron-Deploy.app.discard"
    rm -f \
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

    end_contributor_pair_update || return 1

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

    print_header "Rolling Back Contributor Update"

    local pair_backup="$CONTRIBUTOR_DIR/contributor-pair.bak"
    local backup_kind=""
    if ! contributor_pair_backup_is_complete "$pair_backup"; then
        print_error "No complete contributor rollback plan found. Cannot rollback."
        echo "  A rollback plan exists only while an install or deploy is incomplete."
        exit 1
    fi
    local backup_identity=""
    backup_identity=$(stat -f '%d:%i' "$pair_backup") || exit 1
    backup_kind=$(contributor_pair_backup_kind)

    if ! $skip_confirm; then
        if ! confirm_action "Restore the previous contributor installation state?"; then
            print_error "Aborted."
            exit 1
        fi
    fi

    begin_contributor_pair_update rollback || exit 1
    if [ "$(stat -f '%d:%i' "$pair_backup" 2>/dev/null || true)" \
        != "$backup_identity" ] \
        || ! contributor_pair_backup_is_complete "$pair_backup"; then
        print_error "Contributor rollback plan changed before the writer lock was acquired"
        exit 1
    fi
    backup_kind=$(contributor_pair_backup_kind)

    # Stop service
    print_status "Stopping service..."
    launchd_stop "$PLIST_NAME"
    wait_for_port_free "$PROD_PORT" 10 || exit 1

    # Restore backup
    print_status "Restoring backup..."
    restore_contributor_pair_plan || exit 1

    if [ "$backup_kind" = "no-prior-pair" ]; then
        print_success "Removed the incomplete clean installation"
        discard_contributor_pair_backup rollback || exit 1
        end_contributor_pair_update || exit 1
    else
        launchd_start "$PLIST_NAME"
        if ! service_is_running || ! wait_for_service_health 12; then
            print_error "Rollback restored the backup, but the service did not become healthy"
            exit 1
        fi
        local pid
        pid="$(get_service_pid)"
        print_success "Service restarted from healthy backup (PID: ${pid:-unknown})"
        discard_contributor_pair_backup rollback || exit 1
        end_contributor_pair_update || exit 1
    fi

    echo ""
    print_success "Rollback complete!"
    echo ""
}
