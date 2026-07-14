#!/bin/bash
# workspace.sh - sourced by tron; do not execute directly.

require_project_dir() {
    if [ ! -f "$RUST_WORKSPACE/Cargo.toml" ]; then
        print_error "Not in project directory: $PROJECT_DIR"
        exit 1
    fi
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
