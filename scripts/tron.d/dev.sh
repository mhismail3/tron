#!/bin/bash
# dev.sh - sourced by tron; do not execute directly.

create_dev_launchd_plist() {
    local log_level="${1:-}"
    local log_level_xml=""
    if [ -n "$log_level" ]; then
        log_level_xml="
        <string>--log-level</string>
        <string>$log_level</string>"
    fi

    cat > "$DEV_PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$DEV_PLIST_NAME</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>trap "" HUP; echo "wrapperPid=\$\$"; "\$TRON_DEV_BINARY" "\$@"; exit_code=\$?; echo "=== tron dev background exit \$(date -u +"%Y-%m-%dT%H:%M:%SZ") code=\$exit_code ==="; exit "\$exit_code"</string>
        <string>tron-dev-wrapper</string>
        <string>--port</string>
        <string>$PROD_PORT</string>
        <string>--quiet</string>$log_level_xml
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>TRON_DATA_DIR</key>
        <string>$TRON_HOME</string>
        <key>TRON_REPO_ROOT</key>
        <string>$RUST_WORKSPACE</string>
        <key>RUST_LOG</key>
        <string>${RUST_LOG:-info,ort=error}</string>
        <key>TRON_DEV_BINARY</key>
        <string>$DEV_BINARY</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$DEV_BACKGROUND_LOG</string>
    <key>StandardErrorPath</key>
    <string>$DEV_BACKGROUND_LOG</string>
</dict>
</plist>
PLIST
}

cmd_dev() {
    require_project_dir

    local do_build=false
    local do_test=false
    local do_background=false
    local output_json=false
    local wait_seconds=30
    local log_level=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--build)   do_build=true; shift ;;
            -t|--test)    do_test=true; shift ;;
            -d|--background) do_background=true; shift ;;
            -l|--log-level) log_level="$2"; shift 2 ;;
            --json)       output_json=true; shift ;;
            --wait)        wait_seconds="${2:-30}"; shift 2 ;;
            -bt|-tb)      do_build=true; do_test=true; shift ;;
            -bd|-db)      do_build=true; do_background=true; shift ;;
            -btd|-bdt|-tbd|-tdb|-dbt|-dtb) do_build=true; do_test=true; do_background=true; shift ;;
            -td|-dt)      do_test=true; do_background=true; shift ;;
            --stop)       dev_stop; return ;;
            --log|--logs) tail -f "$DEV_BACKGROUND_LOG"; return ;;
            -h|--help)
                echo ""
                echo -e "${CYAN}tron dev${NC} - Start dev server (takes over port $PROD_PORT from the installed helper)"
                echo ""
                echo "Stops the installed service, runs local binary on port $PROD_PORT."
                echo "Uses the dev-server profile (thin LTO, fast builds, debug backtraces)."
                echo "The installed service restarts automatically when dev exits (Ctrl+C)."
                echo ""
                echo "Usage: tron dev [options]"
                echo ""
                echo "Options:"
                echo "  -b, --build       Build before starting (dev-server profile)"
                echo "  -t, --test        Run tests before starting"
                echo "  -d, --background  Run in background (logs to database and $DEV_BACKGROUND_LOG)"
                echo "  -l, --log-level   Override database log level (trace/debug/info/warn/error)"
                echo "  --json            Emit final machine-readable server status on stdout"
                echo "  --wait SECONDS    Max health wait for background starts (default: 30)"
                echo "  --stop            Stop dev server and restart the installed service"
                echo "  --log             Tail the server log"
                echo ""
                echo "Examples:"
                echo "  tron dev          # Take over prod port (auto-builds with dev-server profile)"
                echo "  tron dev -b       # Explicit build then start"
                echo "  tron dev -bt      # Build, test, then start"
                echo "  tron dev -bd      # Build then start in background"
                echo "  tron dev -btd     # Build, test, then start in background"
                echo "  tron dev -bd --json --wait 30"
                echo "  tron dev --stop   # Stop dev, restart the installed service"
                echo ""
                echo "Note: kill -9 bypasses the cleanup trap. Use 'tron start' to"
                echo "restart the installed service manually if that happens."
                echo ""
                return 0
                ;;
            *) shift ;;
        esac
    done

    if [ "$do_build" = true ]; then
        build_rust_dev
    fi

    if [ "$do_test" = true ]; then
        if ! run_tests; then
            print_warning "Tests failed!"
            if ! confirm_action "Continue anyway?"; then
                exit 1
            fi
        fi
    fi

    if [ "$do_background" = true ]; then
        dev_start_background "$output_json" "$wait_seconds"
    else
        if [ "$output_json" = true ]; then
            print_warning "tron dev --json is only emitted after background starts; use -d/--background for automation"
        fi
        dev_start_foreground
    fi
}

dev_start_foreground() {
    # Stop any previous dev takeover job, then stop the installed helper for
    # dev takeover. The dev job is launchd-backed so agent command runners do
    # not own the server process group after startup.
    launchd_stop "$DEV_PLIST_NAME"

    if service_is_running; then
        print_status "Stopping installed service for dev takeover..."
        launchd_stop "$PLIST_NAME"
    fi

    # Wait for port to be freed (up to 5 seconds)
    if ! wait_for_port_free "$PROD_PORT" 10; then
        local existing_pid
        existing_pid=$(lsof -t -i :"$PROD_PORT" -sTCP:LISTEN 2>/dev/null || true)
        print_error "Port $PROD_PORT still in use (PID: $existing_pid) after waiting"
        print_status "Killing lingering process..."
        kill -9 "$existing_pid" 2>/dev/null || true
        sleep 1
        if lsof -t -i :"$PROD_PORT" -sTCP:LISTEN &>/dev/null; then
            print_error "Port $PROD_PORT still in use, cannot proceed"
            restart_installed_service_after_dev 12
            return 1
        fi
    fi

    # Restart the installed helper on ANY exit (Ctrl+C, error, normal exit).
    # IMPORTANT: no `exec` — must run as child so EXIT trap fires
    trap 'echo ""; restart_installed_service_after_dev 12' EXIT INT TERM

    echo ""
    echo -e "${CYAN}Starting Tron Dev Server (takeover)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Server: http://localhost:$PROD_PORT"
    echo "  Health: http://localhost:$PROD_PORT/health"
    echo ""
    echo -e "${YELLOW}Installed service stopped. Ctrl+C to stop dev and restart it.${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Build, then wrap in app bundle so macOS TCC permissions persist across rebuilds
    cargo build --profile dev-server --manifest-path "$RUST_WORKSPACE/Cargo.toml" --bin tron
    local dev_src="$RUST_WORKSPACE/target/dev-server/tron"
    create_app_bundle "$DEV_BUNDLE" "$dev_src"
    codesign_bundle "$DEV_BUNDLE"

    RUST_LOG="${RUST_LOG:-info,ort=error}" "$DEV_BINARY" \
        --port "$PROD_PORT" ${log_level:+--log-level "$log_level"}
}

dev_start_background() {
    local output_json="${1:-false}"
    local wait_seconds="${2:-30}"
    if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]] || [ "$wait_seconds" -lt 1 ]; then
        print_error "--wait must be a positive integer number of seconds"
        return 2
    fi

    # Stop any previous dev takeover job before bootstrapping a fresh one.
    # launchd can keep a loaded-but-not-running job after a forced process kill;
    # boot it out first so agent automation can repeat `tron dev -bd`.
    launchd_stop "$DEV_PLIST_NAME"

    # Stop the installed helper for dev takeover.
    if service_is_running; then
        print_status "Stopping installed service for dev takeover..."
        launchd_stop "$PLIST_NAME"
    fi

    # Wait for port to be freed (up to 5 seconds)
    if ! wait_for_port_free "$PROD_PORT" 10; then
        local existing_pid
        existing_pid=$(lsof -t -i :"$PROD_PORT" -sTCP:LISTEN 2>/dev/null || true)
        print_error "Port $PROD_PORT still in use (PID: $existing_pid) after waiting"
        print_status "Killing lingering process..."
        kill -9 "$existing_pid" 2>/dev/null || true
        sleep 1
        if lsof -t -i :"$PROD_PORT" -sTCP:LISTEN &>/dev/null; then
            print_error "Port $PROD_PORT still in use, cannot proceed"
            restart_installed_service_after_dev 12
            return 1
        fi
    fi

    # Build, then wrap in app bundle so macOS TCC permissions persist across rebuilds
    cargo build --profile dev-server --manifest-path "$RUST_WORKSPACE/Cargo.toml" --bin tron
    local dev_src="$RUST_WORKSPACE/target/dev-server/tron"
    create_app_bundle "$DEV_BUNDLE" "$dev_src"
    codesign_bundle "$DEV_BUNDLE"

    local dev_log="$DEV_BACKGROUND_LOG"
    local dev_pid_file="$DEV_BACKGROUND_PID_FILE"
    mkdir -p "$RUN_DIR"
    {
        echo "=== tron dev background start $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==="
        echo "binary=$DEV_BINARY"
        echo "port=$PROD_PORT"
        echo "rust_log=${RUST_LOG:-info,ort=error}"
    } > "$dev_log"

    create_dev_launchd_plist "$log_level"
    if ! launchctl bootstrap "gui/$(id -u)" "$DEV_PLIST_PATH" 2>>"$dev_log"; then
        print_error "Failed to load dev takeover LaunchAgent: $DEV_PLIST_PATH"
        if [ -s "$dev_log" ]; then
            print_status "Last dev server log lines ($dev_log):"
            tail -n 80 "$dev_log" >&2 || true
        fi
        restart_installed_service_after_dev 12
        return 1
    fi

    local health_ok=false
    local listener_pid=""
    local attempt
    local max_attempts=$((wait_seconds * 2))
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if curl -fsS --max-time 1 "http://127.0.0.1:$PROD_PORT/health" >/dev/null 2>&1; then
            listener_pid="$(listener_pid_for_port "$PROD_PORT")"
            if [ -n "$listener_pid" ]; then
                health_ok=true
                break
            fi
        fi
        sleep 0.5
    done

    if [ "$health_ok" = true ]; then
        local stable_ok=true
        for attempt in {1..6}; do
            if ! curl -fsS --max-time 1 "http://127.0.0.1:$PROD_PORT/health" >/dev/null 2>&1; then
                stable_ok=false
                break
            fi
            listener_pid="$(listener_pid_for_port "$PROD_PORT")"
            if [ -z "$listener_pid" ]; then
                stable_ok=false
                break
            fi
            sleep 0.5
        done
        if [ "$stable_ok" != true ]; then
            health_ok=false
        fi
    fi

    if [ "$health_ok" = true ]; then
        echo "$listener_pid" > "$dev_pid_file"
        echo ""
        echo -e "${CYAN}Tron Dev Server (background)${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Server:  http://localhost:$PROD_PORT"
        echo "  Health:  http://localhost:$PROD_PORT/health"
        echo "  PID:     $listener_pid"
        echo "  Logs:    $dev_log"
        echo ""
        echo -e "${YELLOW}Use 'tron dev --stop' to stop dev and restart the installed service.${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ "$output_json" = true ]; then
            cmd_status_json
        fi
    else
        print_warning "Dev server launchd job did not pass /health; stopping it before restoring the installed service."
        launchd_stop "$DEV_PLIST_NAME"
        rm -f "$dev_pid_file"
        print_error "Dev server failed to start or become healthy."
        if [ -s "$dev_log" ]; then
            print_status "Last dev server log lines ($dev_log):"
            tail -n 80 "$dev_log" >&2 || true
        else
            print_warning "Dev server log was empty: $dev_log"
        fi
        restart_installed_service_after_dev 12
        return 1
    fi
}

dev_stop() {
    # If launchd service is running, there's no dev to stop.
    if service_is_running; then
        print_warning "Installed service is running (no dev takeover active)"
        echo "  Use 'tron stop' to stop the installed service"
        return 0
    fi

    # Check if a dev process is on the port
    local pid
    pid=$(listener_pid_for_port "$PROD_PORT")
    if [ -n "$pid" ]; then
        print_status "Stopping dev server (PID: $pid)..."
        launchd_stop "$DEV_PLIST_NAME"
        kill "$pid" 2>/dev/null || true
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        print_success "Dev server stopped"
        rm -f "$DEV_BACKGROUND_PID_FILE"
        # The EXIT trap in the dev process should restart the installed helper.
        # If it was kill -9, restart manually:
        sleep 1
        if ! service_is_running; then
            restart_installed_service_after_dev 12
        fi
    else
        if launchd_is_loaded "$DEV_PLIST_NAME"; then
            print_status "Stopping dev takeover launchd job..."
            launchd_stop "$DEV_PLIST_NAME"
            rm -f "$DEV_BACKGROUND_PID_FILE"
            print_success "Dev takeover launchd job stopped"
            if ! service_is_running; then
                restart_installed_service_after_dev 12
            fi
        else
            rm -f "$DEV_BACKGROUND_PID_FILE"
            print_warning "No dev server running"
        fi
    fi
}
