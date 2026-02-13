#!/usr/bin/env bash
#
# CI checks for the Tron Rust agent.
# Run from the workspace root: packages/agent-rs/
#
# Usage:
#   ./scripts/ci.sh          # run all checks
#   ./scripts/ci.sh check    # just cargo check
#   ./scripts/ci.sh test     # just cargo test
#   ./scripts/ci.sh clippy   # just clippy
#   ./scripts/ci.sh doc      # just doc build
#   ./scripts/ci.sh fmt      # just format check
#   ./scripts/ci.sh coverage # just coverage (requires cargo-tarpaulin)

set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WORKSPACE_ROOT"

run_check() {
    echo "==> cargo check (all targets)"
    cargo check --workspace --all-targets
}

run_test() {
    echo "==> cargo test"
    cargo test --workspace
}

run_clippy() {
    echo "==> cargo clippy"
    cargo clippy --workspace --all-targets -- -D warnings
}

run_doc() {
    echo "==> cargo doc"
    RUSTDOCFLAGS="-D warnings" cargo doc --workspace --no-deps
}

run_fmt() {
    echo "==> cargo fmt --check"
    cargo fmt --all -- --check
}

run_coverage() {
    echo "==> cargo tarpaulin"
    if ! command -v cargo-tarpaulin &> /dev/null; then
        echo "cargo-tarpaulin not installed. Install with: cargo install cargo-tarpaulin"
        exit 1
    fi
    cargo tarpaulin --workspace --fail-under 90 --out Html --output-dir target/coverage
}

if [ $# -eq 0 ]; then
    run_fmt
    run_check
    run_clippy
    run_test
    run_doc
    echo ""
    echo "All CI checks passed."
else
    case "$1" in
        check)    run_check ;;
        test)     run_test ;;
        clippy)   run_clippy ;;
        doc)      run_doc ;;
        fmt)      run_fmt ;;
        coverage) run_coverage ;;
        *)        echo "Unknown command: $1"; exit 1 ;;
    esac
fi
