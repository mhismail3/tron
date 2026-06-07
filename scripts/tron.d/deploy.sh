#!/bin/bash
# deploy.sh - sourced by tron; do not execute directly.

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
        <key>RUST_LOG</key>
        <string>info</string>
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

cmd_deploy() {
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

    print_header "Deploying to Production"
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

    # Write lock
    mkdir -p "$(dirname "$DEPLOY_LOCK_FILE")"
    echo "$$" > "$DEPLOY_LOCK_FILE"
    trap 'rm -f "$DEPLOY_LOCK_FILE"' EXIT

    # Record previous commit
    local previous_commit
    previous_commit=$(cat "$DEPLOYED_COMMIT_FILE" 2>/dev/null || echo "unknown")

    if [ -f "$INSTALLED_BINARY" ]; then
        print_status "Backing up current helper executable..."
        mkdir -p "$CONTRIBUTOR_DIR"
        cp "$INSTALLED_BINARY" "$CONTRIBUTOR_DIR/tron.bak"
    fi

    # Stop service
    print_status "Stopping service..."
    launchd_stop "$PLIST_NAME"
    sleep 1

    # Create app bundle with new binary, sign with Developer ID (if available),
    # and notarize + staple so the bundle is distribution-ready and TCC
    # permissions persist across deploys.
    print_status "Creating app bundle..."
    create_app_bundle "$INSTALLED_BUNDLE" "$RELEASE_BINARY"
    sign_and_notarize "$INSTALLED_BUNDLE"

    # Deploy transcription sidecar
    print_status "Deploying transcription sidecar..."
    deploy_transcription_sidecar

    # Sync managed skills from repo
    print_status "Syncing managed skills..."
    sync_managed_skills

    # Install runtime CLI, shared library, and entitlements (only if changed)
    for f in tron-cli tron-lib.sh tron-agent.entitlements AppIcon.icns; do
        if [ -f "$SCRIPT_DIR/$f" ] && ! cmp -s "$SCRIPT_DIR/$f" "$CONTRIBUTOR_DIR/$f"; then
            cp "$SCRIPT_DIR/$f" "$CONTRIBUTOR_DIR/$f"
            [ "$f" = "tron-cli" ] && chmod +x "$CONTRIBUTOR_DIR/$f"
            print_success "Updated $f"
        fi
    done
    rm -rf "$CONTRIBUTOR_DIR/tron-lib.d"
    mkdir -p "$CONTRIBUTOR_DIR/tron-lib.d"
    cp "$SCRIPT_DIR"/tron-lib.d/*.sh "$CONTRIBUTOR_DIR/tron-lib.d/"

    # Record workspace path
    echo "$PROJECT_DIR" > "$CONTRIBUTOR_DIR/workspace-path"

    # Regenerate plists so paths (e.g. log file) stay current
    print_status "Updating launchd plist..."
    create_launchd_plist

    # Record new commit
    local new_commit
    new_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
    echo "$new_commit" > "$DEPLOYED_COMMIT_FILE"

    # Write restart sentinel so the contributor service records deploy restart state.
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
    cat > "$CONTRIBUTOR_DIR/restart-sentinel.json" <<SENTINEL
{
  "action": "deploy",
  "timestamp": "$now",
  "commit": "$new_commit",
  "previousCommit": "$previous_commit",
  "status": "restarting",
  "completedAt": null,
  "initiatedBy": "cli"
}
SENTINEL

    # Start service
    print_status "Starting service..."
    launchd_start "$PLIST_NAME"
    sleep 3

    if service_is_running; then
        local pid
        pid=$(get_service_pid)
        print_success "Service started (PID: ${pid:-unknown})"

        # Health check
        sleep 2
        if health_check; then
            print_success "Health check passed"

            # Remove backup (deploy succeeded)
            rm -f "$CONTRIBUTOR_DIR/tron.bak"

            write_deployment_result "success"
        else
            print_warning "Health check failed — server may still be starting"
            echo "  Monitor with: tron status"
        fi
    else
        print_error "Service failed to start!"

        # Auto-rollback
        if [ -f "$CONTRIBUTOR_DIR/tron.bak" ]; then
            print_status "Rolling back..."
            if ! create_app_bundle "$INSTALLED_BUNDLE" "$CONTRIBUTOR_DIR/tron.bak"; then
                return 1
            fi
            codesign_bundle "$INSTALLED_BUNDLE"
            rm -f "$CONTRIBUTOR_DIR/tron.bak"
            launchd_start "$PLIST_NAME"
            sleep 2
            if service_is_running; then
                print_success "Rolled back to previous version"
            else
                print_error "Rollback also failed!"
            fi
        fi

        write_deployment_result "failed" "Service failed to start"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Deploy successful!${NC}"
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
    # Phases (ordered): dirs, configs, build, bundle, sidecar, skills,
    #                   plist, cli, symlink, launchd
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

    _emit_event configs start ""
    ensure_default_configs
    _emit_event configs ok ""

    if [ ! -f "$RELEASE_BINARY" ]; then
        _emit_event build start "cargo build --release"
        if ! build_rust; then
            _emit_event build fail "cargo build exited non-zero"
            return 1
        fi
        _emit_event build ok "$RELEASE_BINARY"
    else
        _emit_event build ok "prebuilt: $RELEASE_BINARY"
    fi

    _emit_event bundle start "$INSTALLED_BUNDLE"
    [ "$gui_helper" -eq 0 ] && print_status "Creating app bundle..."
    create_app_bundle "$INSTALLED_BUNDLE" "$RELEASE_BINARY"
    sign_and_notarize "$INSTALLED_BUNDLE"
    [ "$gui_helper" -eq 0 ] && print_success "Installed app bundle"
    _emit_event bundle ok "$INSTALLED_BUNDLE"

    _emit_event sidecar start ""
    [ "$gui_helper" -eq 0 ] && print_status "Deploying transcription sidecar..."
    deploy_transcription_sidecar
    [ "$gui_helper" -eq 0 ] && print_success "Deployed transcription sidecar"
    _emit_event sidecar ok ""

    _emit_event skills start ""
    [ "$gui_helper" -eq 0 ] && print_status "Syncing managed skills..."
    sync_managed_skills
    _emit_event skills ok ""

    _emit_event plist start "$PLIST_PATH"
    [ "$gui_helper" -eq 0 ] && print_status "Creating launchd service..."
    create_launchd_plist
    [ "$gui_helper" -eq 0 ] && print_success "Created: $PLIST_PATH"
    _emit_event plist ok "$PLIST_PATH"

    _emit_event cli start ""
    cp "$SCRIPT_DIR/tron-lib.sh" "$CONTRIBUTOR_DIR/tron-lib.sh"
    rm -rf "$CONTRIBUTOR_DIR/tron-lib.d"
    mkdir -p "$CONTRIBUTOR_DIR/tron-lib.d"
    cp "$SCRIPT_DIR"/tron-lib.d/*.sh "$CONTRIBUTOR_DIR/tron-lib.d/"
    cp "$SCRIPT_DIR/tron-cli" "$CONTRIBUTOR_DIR/tron-cli"
    cp "$SCRIPT_DIR/tron-agent.entitlements" "$CONTRIBUTOR_DIR/tron-agent.entitlements"
    cp "$SCRIPT_DIR/AppIcon.icns" "$CONTRIBUTOR_DIR/AppIcon.icns" 2>/dev/null || true
    chmod +x "$CONTRIBUTOR_DIR/tron-cli"
    [ "$gui_helper" -eq 0 ] && print_success "Installed runtime CLI"
    echo "$PROJECT_DIR" > "$CONTRIBUTOR_DIR/workspace-path"
    _emit_event cli ok "$CONTRIBUTOR_DIR/tron-cli"

    _emit_event symlink start "$BIN_DIR/tron"
    [ "$gui_helper" -eq 0 ] && print_status "Installing tron CLI..."
    ln -sf "$CONTRIBUTOR_DIR/tron-cli" "$BIN_DIR/tron"
    [ "$gui_helper" -eq 0 ] && print_success "Installed: $BIN_DIR/tron -> $CONTRIBUTOR_DIR/tron-cli"
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        [ "$gui_helper" -eq 0 ] && print_warning "Add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
        _emit_event symlink ok "path-missing:$BIN_DIR"
    else
        _emit_event symlink ok ""
    fi

    local current_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
    echo "$current_commit" > "$DEPLOYED_COMMIT_FILE"

    # Machine-readable contributor runs skip launchctl; interactive
    # CLI-install runs keep the full behavior.
    if [ "$skip_service_start" -eq 0 ] && [ "$gui_helper" -eq 0 ]; then
        _emit_event launchd start ""
        print_status "Starting service..."
        launchd_start "$PLIST_NAME"
        sleep 2
        if service_is_running; then
            local pid=$(get_service_pid)
            print_success "Service started (PID: ${pid:-unknown})"
            _emit_event launchd ok "pid=${pid:-unknown}"
        else
            print_warning "Service not running — check: tron errors"
            _emit_event launchd fail "no-pid-after-bootstrap"
        fi
    else
        _emit_event launchd ok "skipped (gui-helper or --skip-service-start)"
    fi

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

    # Create directory structure
    print_status "Creating directory structure..."
    ensure_tron_home
    print_success "Created $TRON_HOME directory structure"

    # Create default config files
    print_status "Creating configuration files..."
    ensure_default_configs

    # Build
    build_rust

    if [ "$dev_mode" = true ]; then
        run_tests || print_warning "Some tests failed (continuing anyway)"
    fi

    # Install runtime CLI, shared library, and create symlink
    print_status "Setting up tron command..."
    mkdir -p "$HOME/.local/bin"
    mkdir -p "$CONTRIBUTOR_DIR"

    cp "$SCRIPT_DIR/tron-lib.sh" "$CONTRIBUTOR_DIR/tron-lib.sh"
    rm -rf "$CONTRIBUTOR_DIR/tron-lib.d"
    mkdir -p "$CONTRIBUTOR_DIR/tron-lib.d"
    cp "$SCRIPT_DIR"/tron-lib.d/*.sh "$CONTRIBUTOR_DIR/tron-lib.d/"
    cp "$SCRIPT_DIR/tron-cli" "$CONTRIBUTOR_DIR/tron-cli"
    chmod +x "$CONTRIBUTOR_DIR/tron-cli"

    # Record workspace path
    echo "$PROJECT_DIR" > "$CONTRIBUTOR_DIR/workspace-path"

    ln -sf "$CONTRIBUTOR_DIR/tron-cli" "$HOME/.local/bin/tron"
    print_success "Created symlink: ~/.local/bin/tron -> $CONTRIBUTOR_DIR/tron-cli"

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
    echo "  Data directory: $TRON_HOME"
    echo "  Project path:   $PROJECT_DIR"
    echo ""
    echo "  Next steps:"
    echo "    tron login       # Authenticate with a provider"
    echo "    tron dev         # Start server in foreground"
    echo "    tron install     # Install as launchd service"
    echo ""
}
