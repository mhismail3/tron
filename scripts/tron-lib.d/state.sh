#!/bin/bash
# state.sh - sourced by tron-lib.sh; do not execute directly.

_run_tron_state_owner() {
    if [[ -n "${RUST_WORKSPACE:-}" ]] && command -v cargo >/dev/null 2>&1; then
        ( cd "$RUST_WORKSPACE" && cargo run --quiet --bin tron -- state "$@" )
        return
    fi

    if [[ ! -x "$INSTALLED_BINARY" ]]; then
        print_error "The installed Tron CLI has no paired helper binary. Run 'tron install' from the workspace."
        return 1
    fi
    "$INSTALLED_BINARY" state "$@"
}

cmd_state() {
    local action="${1:-}"
    case "$action" in
        snapshot|snapshots|verify|restore)
            _run_tron_state_owner "$@"
            ;;
        ""|-h|--help)
            echo ""
            echo "Usage: tron state <action>"
            echo ""
            echo "Actions:"
            echo "  snapshot                 Create and verify an owner-only profile archive"
            echo "  snapshots                List available profile archives"
            echo "  verify <archive>         Verify checksums without changing state"
            echo "  restore <archive>        Restore while the Tron server is stopped"
            echo ""
            echo "Restore first moves replaced state into a dated recovery directory."
            echo ""
            ;;
        *)
            print_error "Unknown state action: $action"
            cmd_state --help
            return 1
            ;;
    esac
}
