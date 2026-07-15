#!/bin/bash
# manual-deploy.sh - sourced by tron; do not execute directly.

# INVARIANT (L3, trusted-local): the plist is written to
# `$HOME/Library/LaunchAgents/` with the default user umask. macOS
# LaunchAgents are per-user by design; under the trusted-local threat model
# (single Mac user, Tailnet-reachable daemon) this is acceptable. Hardening
# path for a shared-host model: chmod 0700 the LaunchAgents directory and
# 0600 the plist, then validate a checksum sentinel before trusting the
# launchd-installed binary.
create_launchd_plist() {
    cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>

    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_BINARY</string>
        <string>--port</string>
        <string>$PROD_PORT</string>
        <string>--quiet</string>
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
    <integer>10</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>TRON_DATA_DIR</key>
        <string>$TRON_HOME</string>
        <key>TRON_REPO_ROOT</key>
        <string>$RUST_WORKSPACE</string>
    </dict>

    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>4096</integer>
    </dict>

    <key>AssociatedBundleIdentifiers</key>
    <string>$TRON_BUNDLE_ID</string>
</dict>
</plist>
PLIST
}

install_runtime_cli_payload() {
    if ! contributor_pair_update_is_owned; then
        print_error "Installing the contributor CLI requires the helper update lock"
        return 1
    fi
    mkdir -p "$CONTRIBUTOR_DIR" || return 1
    cp "$SCRIPT_DIR"/{tron-cli,tron-lib.sh,tron-agent.entitlements} "$CONTRIBUTOR_DIR/" \
        || return 1
    cp "$PROJECT_DIR/packages/mac-app/Sources/Resources/AppIcon.icns" \
        "$CONTRIBUTOR_DIR/AppIcon.icns" || return 1
    chmod +x "$CONTRIBUTOR_DIR/tron-cli" || return 1
    rm -rf "$CONTRIBUTOR_DIR/tron-lib.d" || return 1
    mkdir -p "$CONTRIBUTOR_DIR/tron-lib.d" || return 1
    cp "$SCRIPT_DIR"/tron-lib.d/*.sh "$CONTRIBUTOR_DIR/tron-lib.d/" || return 1
    printf '%s\n' "$PROJECT_DIR" > "$CONTRIBUTOR_DIR/workspace-path" || return 1
}

write_restart_sentinel() {
    local action="$1"
    local commit="$2"
    local previous_commit="$3"
    local status="$4"
    local completed_at="null"
    if [ "$status" != "restarting" ]; then
        completed_at="\"$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")\""
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    mkdir -p "$CONTRIBUTOR_DIR"
    cat > "$CONTRIBUTOR_DIR/restart-sentinel.json" <<SENTINEL
{
  "action": "$action",
  "timestamp": "$now",
  "commit": "$commit",
  "previousCommit": "$previous_commit",
  "status": "$status",
  "completedAt": $completed_at,
  "initiatedBy": "cli"
}
SENTINEL
}

restore_contributor_backup() {
    local pair_backup="$CONTRIBUTOR_DIR/contributor-pair.bak"
    local backup_binary="$pair_backup/Tron-Deploy.app/Contents/MacOS/tron"
    if [[ "$(contributor_pair_backup_kind 2>/dev/null || true)" != "pair" \
        || ! -f "$backup_binary" \
        || ! -f "$pair_backup/tron-cli" \
        || ! -f "$pair_backup/tron-lib.sh" \
        || ! -d "$pair_backup/tron-lib.d" ]] \
        || ! file "$backup_binary" 2>/dev/null | grep -q "Mach-O"; then
        print_error "No complete helper and contributor CLI backup found for rollback"
        return 1
    fi
    if ! contributor_pair_update_is_owned; then
        print_error "Contributor rollback requires the helper update lock"
        return 1
    fi

    print_status "Rolling back..."
    launchd_stop "$PLIST_NAME"
    wait_for_port_free "$PROD_PORT" 10 || return 1

    restore_contributor_pair_plan || return 1
    launchd_start "$PLIST_NAME"

    if wait_for_service_health 12; then
        local pid
        pid=$(get_service_pid)
        print_success "Rolled back to previous healthy version (PID: ${pid:-unknown})"
        return 0
    fi

    print_error "Rollback helper did not become healthy"
    return 1
}

record_failed_contributor_deploy() {
    local new_commit="$1"
    local previous_commit="$2"
    local failure_reason="$3"
    local restored=false

    if restore_contributor_backup; then
        restored=true
        write_restart_sentinel \
            "deploy" "$new_commit" "$previous_commit" "rolled_back" || true
        failure_reason="$failure_reason; rolled back to previous helper and CLI"
        discard_contributor_pair_backup rollback || return 1
    else
        write_restart_sentinel \
            "deploy" "$new_commit" "$previous_commit" "failed" || true
        failure_reason="$failure_reason; paired rollback failed"
    fi
    TRON_DEPLOYMENT_COMMIT="$new_commit" \
        TRON_DEPLOYMENT_PREVIOUS_COMMIT="$previous_commit" \
        write_deployment_result "failed" "$failure_reason" || true
    if $restored; then
        end_contributor_pair_update || true
    fi
    return 1
}

cmd_preflight() {
    require_project_dir

    print_header "Deploy Pre-flight Check"
    local all_ok=true

    # 1. Rust workspace
    if [ -f "$RUST_WORKSPACE/Cargo.toml" ]; then
        print_success "Rust workspace found"
    else
        print_error "Rust workspace not found at $RUST_WORKSPACE"
        all_ok=false
    fi

    # 2. Working tree clean
    if git -C "$PROJECT_DIR" diff-index --quiet HEAD -- 2>/dev/null; then
        print_success "Working tree clean"
    else
        print_warning "Uncommitted changes"
    fi

    # 3. Release binary exists
    if [ -f "$RELEASE_BINARY" ] \
        && file "$RELEASE_BINARY" | grep -q "Mach-O"; then
        print_success "Release binary exists ($(ls -lh "$RELEASE_BINARY" | awk '{print $5}'))"
    else
        print_warning "Release helper binary incomplete — build required"
    fi

    # 4. Service installed
    if [ -f "$PLIST_PATH" ]; then
        print_success "Launchd service installed"
    else
        print_error "Service not installed (run: tron install)"
        all_ok=false
    fi

    # 5. Service running
    if service_is_running; then
        local pid
        pid=$(get_service_pid)
        print_success "Service is running (PID: ${pid:-unknown})"
    else
        print_warning "Service not running"
    fi

    # 6. Health check
    if health_check; then
        print_success "Server healthy"
    else
        print_warning "Health check failed (server may be starting)"
    fi

    # 7. No dev takeover
    if ! service_is_running; then
        local dev_pid
        dev_pid=$(lsof -t -i :$PROD_PORT -sTCP:LISTEN 2>/dev/null || true)
        if [ -n "$dev_pid" ]; then
            print_error "Dev takeover active (PID: $dev_pid) — stop with: tron dev --stop"
            all_ok=false
        fi
    fi

    # 8. No stuck sentinel
    local sentinel_file="$CONTRIBUTOR_DIR/restart-sentinel.json"
    if [ -f "$sentinel_file" ]; then
        local sentinel_status
        sentinel_status=$(python3 -c "import json; print(json.load(open('$sentinel_file')).get('status',''))" 2>/dev/null || true)
        if [ "$sentinel_status" = "restarting" ]; then
            print_error "Stuck sentinel (status=restarting) — previous deploy may have failed"
            all_ok=false
        else
            print_success "No stuck deploy sentinel"
        fi
    fi

    # 9. Disk space
    local free_mb
    free_mb=$(df -m "$TRON_HOME" | awk 'NR==2 {print $4}')
    if [ "$free_mb" -gt 500 ]; then
        print_success "Disk space OK (${free_mb}MB free)"
    else
        print_warning "Low disk space: ${free_mb}MB"
    fi

    echo ""
    if [ "$all_ok" = true ]; then
        print_success "All pre-flight checks passed"
    else
        print_error "Some checks failed"
    fi
    echo ""
}

cmd_manual_deploy() {
    local force=false
    local ci_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --ci)    ci_mode=true; shift ;;
            *) shift ;;
        esac
    done

    require_project_dir
    require_installed

    # Abort if dev takeover is active
    if ! service_is_running; then
        local dev_pid
        dev_pid=$(lsof -t -i :$PROD_PORT -sTCP:LISTEN 2>/dev/null || true)
        if [ -n "$dev_pid" ]; then
            print_error "Dev server is running on port $PROD_PORT (PID: $dev_pid)"
            echo "  Stop dev first with Ctrl+C or: tron dev --stop"
            return 1
        fi
    fi

    print_header "Manual Contributor Deploy"
    echo "  Workspace: $PROJECT_DIR"
    echo ""

    # Check for uncommitted changes
    if ! git -C "$PROJECT_DIR" diff-index --quiet HEAD -- 2>/dev/null; then
        if $ci_mode; then
            print_error "Uncommitted changes — cannot deploy in --ci mode"
            exit 1
        fi
        print_warning "You have uncommitted changes!"
        echo ""
        git -C "$PROJECT_DIR" status --short
        echo ""
        if ! $force && ! confirm_action "Deploy anyway?"; then
            print_error "Aborted. Commit your changes first."
            exit 1
        fi
    fi

    # Build and test
    build_rust

    if ! run_tests; then
        if $ci_mode; then
            print_error "Tests failed — cannot deploy in --ci mode"
            exit 1
        fi
        print_error "Tests failed"
        if ! $force && ! confirm_action "Continue deployment anyway?"; then
            print_error "Deployment cancelled."
            exit 1
        fi
        print_warning "Continuing deployment despite test failure..."
    fi

    if $ci_mode; then
        if ! run_bench_gate; then
            print_error "Benchmark gate failed — cannot deploy in --ci mode"
            exit 1
        fi
    fi

    begin_contributor_pair_update manual-deploy || return 1

    # Atomically publish the complete helper/CLI/launch rollback unit before
    # replacing any member of the installed pair.
    if ! contributor_pair_is_complete; then
        print_error "Contributor helper/CLI pair is incomplete; rollback it or run tron uninstall, then tron install"
        return 1
    fi
    if ! backup_contributor_pair; then
        return 1
    fi
    if ! install_runtime_cli_payload; then
        if restore_contributor_pair_plan; then
            discard_contributor_pair_backup rollback || return 1
            end_contributor_pair_update || true
        fi
        return 1
    fi

    # Record previous commit
    local previous_commit
    previous_commit=$(cat "$DEPLOYED_COMMIT_FILE" 2>/dev/null || echo "unknown")
    local new_commit
    new_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")

    # Stop service
    print_status "Stopping service..."
    launchd_stop "$PLIST_NAME"
    sleep 1

    # Create app bundle with new binary, sign with Developer ID (if available),
    # and notarize + staple so the bundle is distribution-ready and TCC
    # permissions persist across deploys.
    print_status "Creating app bundle..."
    local preparation_failure=""
    if ! create_app_bundle "$INSTALLED_BUNDLE" "$RELEASE_BINARY"; then
        preparation_failure="Failed to create candidate helper bundle"
    elif ! sign_and_notarize "$INSTALLED_BUNDLE" \
        || ! validate_contributor_bundle "$INSTALLED_BUNDLE"; then
        preparation_failure="Failed to sign candidate helper bundle"
    else
        print_status "Updating launchd plist..."
        if ! create_launchd_plist; then
            preparation_failure="Failed to update contributor launchd plist"
        elif ! write_restart_sentinel \
            "deploy" "$new_commit" "$previous_commit" "restarting"; then
            preparation_failure="Failed to record contributor restart state"
        else
            print_status "Starting service..."
            if ! launchd_start "$PLIST_NAME"; then
                preparation_failure="Failed to request contributor helper start"
            fi
        fi
    fi
    if [ -n "$preparation_failure" ]; then
        record_failed_contributor_deploy \
            "$new_commit" "$previous_commit" "$preparation_failure" || return 1
    fi

    if service_is_running && wait_for_service_health 12; then
        local pid
        pid=$(get_service_pid)
        print_success "Service started (PID: ${pid:-unknown})"

        # Health check passed. Only now does the candidate become the deployed truth.
        local finalization_failure=""
        if ! printf '%s\n' "$new_commit" > "$DEPLOYED_COMMIT_FILE"; then
            finalization_failure="Failed to record deployed contributor commit"
        elif ! write_restart_sentinel \
            "deploy" "$new_commit" "$previous_commit" "completed"; then
            finalization_failure="Failed to complete contributor restart state"
        elif ! TRON_DEPLOYMENT_COMMIT="$new_commit" \
            TRON_DEPLOYMENT_PREVIOUS_COMMIT="$previous_commit" \
            write_deployment_result "success"; then
            finalization_failure="Failed to record successful contributor deployment"
        fi
        if [ -n "$finalization_failure" ]; then
            record_failed_contributor_deploy \
                "$new_commit" "$previous_commit" "$finalization_failure" || return 1
        fi
        discard_contributor_pair_backup || return 1
        end_contributor_pair_update || return 1
    else
        if service_is_running; then
            print_error "Service started but did not pass /health; failing deploy closed."
        else
            print_error "Service failed to start!"
        fi

        record_failed_contributor_deploy \
            "$new_commit" "$previous_commit" \
            "Service failed to start or pass health" || return 1
    fi

    echo ""
    echo -e "${GREEN}Manual deploy successful!${NC}"
    echo "  Commit: ${new_commit:0:7}"
    [ "$previous_commit" != "unknown" ] && echo "  Previous: ${previous_commit:0:7}"
    echo ""
}

cmd_install() {
    # --gui-helper: machine-readable contributor mode. Emits one JSON
    # event per line on stdout, keeping stderr for anything else.
    # Suppresses decorative banners and interactive prompts.
    #
    # Event shape: {"phase":"<name>","status":"start|ok|fail","detail":"..."}
    # Phases (ordered): dirs, build, cli, bundle, plist, symlink, launchd
    # The distributed Mac app does not call this path. Production
    # installs are `/Applications/Tron.app` + SMAppService only.
    local gui_helper=0
    local skip_service_start=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --gui-helper)       gui_helper=1; shift ;;
            --skip-service-start) skip_service_start=1; shift ;;
            *) shift ;;
        esac
    done

    _emit_event() {
        # $1=phase $2=status $3=detail
        if [ "$gui_helper" -eq 1 ]; then
            # JSON-escape detail: backslash + double-quote.
            local detail="${3:-}"
            detail="${detail//\\/\\\\}"
            detail="${detail//\"/\\\"}"
            printf '{"phase":"%s","status":"%s","detail":"%s"}\n' \
                "$1" "$2" "$detail"
        fi
    }

    require_project_dir

    if [ "$gui_helper" -eq 0 ]; then
        print_header "Installing Tron Service"
        echo "  Workspace: $PROJECT_DIR"
        echo ""
    fi

    _emit_event dirs start ""
    mkdir -p "$BIN_DIR"
    mkdir -p "$CONTRIBUTOR_DIR"
    mkdir -p "$HOME/Library/LaunchAgents"
    _emit_event dirs ok "$BIN_DIR,$CONTRIBUTOR_DIR,$HOME/Library/LaunchAgents"

    _emit_event build start "cargo build --release"
    if ! build_rust; then
        _emit_event build fail "cargo build exited non-zero"
        return 1
    fi
    _emit_event build ok "$RELEASE_BINARY"

    if ! begin_contributor_pair_update install; then
        _emit_event cli fail "another contributor helper update is active"
        return 1
    fi

    # Publish either the complete prior pair or an explicit clean-install plan
    # before replacing any helper, CLI, plist, entrypoint, or commit marker.
    if ! backup_contributor_pair; then
        _emit_event cli fail "contributor rollback plan publication failed"
        return 1
    fi
    rm -f "$DEPLOYED_COMMIT_FILE"

    _emit_event cli start ""
    if ! install_runtime_cli_payload; then
        _emit_event cli fail "runtime payload installation failed"
        return 1
    fi
    [ "$gui_helper" -eq 0 ] && print_success "Installed runtime CLI"
    _emit_event cli ok "$CONTRIBUTOR_DIR/tron-cli"

    _emit_event bundle start "$INSTALLED_BUNDLE"
    [ "$gui_helper" -eq 0 ] && print_status "Creating app bundle..."
    if ! create_app_bundle "$INSTALLED_BUNDLE" "$RELEASE_BINARY" \
        || ! sign_and_notarize "$INSTALLED_BUNDLE" \
        || ! validate_contributor_bundle "$INSTALLED_BUNDLE"; then
        _emit_event bundle fail "bundle construction or signing failed"
        return 1
    fi
    [ "$gui_helper" -eq 0 ] && print_success "Installed app bundle"
    _emit_event bundle ok "$INSTALLED_BUNDLE"

    _emit_event plist start "$PLIST_PATH"
    [ "$gui_helper" -eq 0 ] && print_status "Creating launchd service..."
    if ! create_launchd_plist; then
        _emit_event plist fail "launchd plist creation failed"
        return 1
    fi
    [ "$gui_helper" -eq 0 ] && print_success "Created: $PLIST_PATH"
    _emit_event plist ok "$PLIST_PATH"

    _emit_event symlink start "$BIN_DIR/tron"
    [ "$gui_helper" -eq 0 ] && print_status "Installing tron CLI..."
    if ! ln -sf "$CONTRIBUTOR_DIR/tron-cli" "$BIN_DIR/tron"; then
        _emit_event symlink fail "CLI symlink creation failed"
        return 1
    fi
    [ "$gui_helper" -eq 0 ] && print_success "Installed: $BIN_DIR/tron -> $CONTRIBUTOR_DIR/tron-cli"
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        [ "$gui_helper" -eq 0 ] && print_warning "Add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
        _emit_event symlink ok "path-missing:$BIN_DIR"
    else
        _emit_event symlink ok ""
    fi

    # Machine-readable contributor runs skip launchctl; interactive
    # CLI-install runs keep the full behavior.
    if [ "$skip_service_start" -eq 0 ] && [ "$gui_helper" -eq 0 ]; then
        _emit_event launchd start ""
        print_status "Starting service..."
        launchd_start "$PLIST_NAME"
        sleep 2
        if service_is_running && wait_for_service_health 12; then
            local pid
            pid=$(get_service_pid)
            local current_commit
            current_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
            if ! printf '%s\n' "$current_commit" > "$DEPLOYED_COMMIT_FILE"; then
                _emit_event launchd fail "deployed commit recording failed"
                return 1
            fi
            print_success "Service started (PID: ${pid:-unknown})"
            _emit_event launchd ok "pid=${pid:-unknown}"
        else
            print_error "Installed contributor helper did not pass /health"
            _emit_event launchd fail "health check failed"
            return 1
        fi
    else
        _emit_event launchd ok "skipped (gui-helper or --skip-service-start)"
    fi
    discard_contributor_pair_backup || return 1
    end_contributor_pair_update || return 1

    if [ "$gui_helper" -eq 0 ]; then
        echo ""
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}                    Tron Installation Complete!${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "  Server:  http://localhost:$PROD_PORT"
        echo "  Health:  http://localhost:$PROD_PORT/health"
        echo "  Binary:  $INSTALLED_BINARY"
        echo "  CLI:     $BIN_DIR/tron"
        echo ""
        echo "  Next steps:"
        echo "    tron login       # Authenticate with a provider"
        echo "    tron dev         # Start dev server"
        echo "    tron status      # Check service status"
        echo ""
        echo "  Code signing (one-time, only if you will deploy or distribute):"
        echo "    xcrun notarytool store-credentials \"$NOTARIZE_PROFILE\" \\"
        echo "      --apple-id <email> --team-id <TEAM_ID>"
        echo ""
        echo "  Get an app-specific password at: https://appleid.apple.com"
        echo ""
    fi
}

cmd_setup() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                        Tron Setup                             ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local dev_mode=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dev) dev_mode=true; shift ;;
            -h|--help)
                echo "Usage: tron setup [--dev]"
                echo ""
                echo "Options:"
                echo "  --dev    Also run tests after setup"
                exit 0
                ;;
            *) shift ;;
        esac
    done

    # Check prerequisites
    print_status "Checking prerequisites..."

    if ! command -v cargo &> /dev/null; then
        print_error "Rust is not installed. Install from https://rustup.rs"
        exit 1
    fi
    print_success "cargo $(cargo --version | cut -d' ' -f2) found"

    if ! command -v rustc &> /dev/null; then
        print_error "rustc not found."
        exit 1
    fi
    print_success "rustc $(rustc --version | cut -d' ' -f2) found"

    command -v git &> /dev/null && print_success "git $(git --version | cut -d' ' -f3) found"

    # Build
    build_rust

    if [ "$dev_mode" = true ]; then
        run_tests || print_warning "Some tests failed (continuing anyway)"
    fi

    # Keep development setup workspace-owned. The installed runtime CLI is a
    # version-paired service artifact and is staged only by install/deploy.
    print_status "Setting up tron command..."
    mkdir -p "$BIN_DIR"
    begin_contributor_pair_update setup || return 1
    if contributor_pair_is_complete; then
        print_success "Preserved installed CLI: $BIN_DIR/tron"
    elif contributor_pair_has_runtime_members; then
        print_error "Contributor helper/CLI pair is incomplete; rollback it or uninstall before setup"
        return 1
    else
        ln -sf "$SCRIPT_DIR/tron" "$BIN_DIR/tron" || return 1
        print_success "Created symlink: $BIN_DIR/tron -> $SCRIPT_DIR/tron"
    fi
    end_contributor_pair_update || return 1

    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        print_warning "~/.local/bin is not in your PATH"
        echo "  Add this to your shell config (~/.zshrc or ~/.bashrc):"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                      Tron Setup Complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Data directory: $TRON_HOME (completed on first server start)"
    echo "  Project path:   $PROJECT_DIR"
    echo ""
    echo "  Next steps:"
    echo "    tron dev -d      # Start server and initialize runtime state"
    echo "    tron login       # Authenticate with a provider"
    echo "    tron install     # Install as launchd service"
    echo ""
}
