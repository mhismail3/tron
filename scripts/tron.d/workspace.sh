#!/bin/bash
# workspace.sh - sourced by tron; do not execute directly.

require_project_dir() {
    if [ ! -f "$RUST_WORKSPACE/Cargo.toml" ]; then
        print_error "Not in project directory: $PROJECT_DIR"
        exit 1
    fi
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

    if [ -f "$RELEASE_BINARY" ] \
        && file "$RELEASE_BINARY" 2>/dev/null | grep -q "Mach-O"; then
        print_status "Restoring from release build..."
        create_app_bundle "$INSTALLED_BUNDLE" "$RELEASE_BINARY"
        codesign_bundle "$INSTALLED_BUNDLE"
        print_success "Restored from release build"
        return 0
    fi

    print_error "No valid contributor service binary found. Run: tron deploy"
    return 1
}

build_rust() {
    print_status "Building Rust workspace (release)..."
    (cd "$RUST_WORKSPACE" && cargo build --release) || { print_error "Build failed"; exit 1; }
    print_success "Build complete"
}

build_rust_dev() {
    print_status "Building Rust workspace (dev-server)..."
    (cd "$RUST_WORKSPACE" && cargo build --profile dev-server) || { print_error "Build failed"; exit 1; }
    print_success "Build complete"
}
