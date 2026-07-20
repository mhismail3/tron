#!/bin/bash
# state.sh - offline worker-first snapshot inspection and restore.

_run_tron_state_owner() {
    if [[ -n "${RUST_WORKSPACE:-}" ]] && command -v cargo >/dev/null 2>&1; then
        ( cd "$RUST_WORKSPACE" && cargo run --quiet --bin tron -- state "$@" )
        return
    fi
    if [[ ! -x "$INSTALLED_BINARY" ]]; then
        print_error "The installed Tron CLI has no paired helper binary."
        return 1
    fi
    "$INSTALLED_BINARY" state "$@"
}

cmd_state() {
    local action="${1:-}"
    case "$action" in
        snapshots)
            shift
            _run_tron_state_owner snapshots "$@"
            ;;
        restore)
            shift
            if [[ $# -ne 1 ]]; then
                print_error "Usage: tron state restore /absolute/path/to/snapshot"
                return 1
            fi
            _run_tron_state_owner restore "$1"
            ;;
        ""|-h|--help)
            echo ""
            echo "Usage: tron state <action>"
            echo ""
            echo "Actions:"
            echo "  snapshots                  List verified pre-worker migration snapshots"
            echo "  restore /absolute/path     Restore a verified snapshot while Tron is stopped"
            echo ""
            return 0
            ;;
        *)
            print_error "Unknown state action: $action"
            cmd_state --help
            return 1
            ;;
    esac
}
