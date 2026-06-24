use super::support::*;

#[test]
fn inventory_requires_non_timestamp_only_replay_ordering() {
    let inventory = read_repo_file(INVENTORY_PATH);
    for required in [
        "sequence order",
        "cursor ASC",
        "timestamp ASC + id ASC",
        "queue ASC + created_at ASC + receipt_id ASC",
        "No timestamp-only ordering in replay-critical sections.",
    ] {
        assert!(
            inventory.contains(required) || read_repo_file(SCORECARD_PATH).contains(required),
            "DRC replay ordering docs missing required text: {required}"
        );
    }
}

#[test]
fn replay_ordering_methods_use_stable_tie_breakers() {
    let source = read_source_tree_text();
    for required in [
        "list_trace_records_for_replay",
        "ORDER BY timestamp ASC, id ASC",
        "ORDER BY cursor ASC",
        "ORDER BY rowid ASC, invocation_id ASC",
        "ORDER BY queue ASC, created_at ASC, receipt_id ASC",
        "ledger_invocations_by_session",
        "replay_snapshot",
    ] {
        assert!(
            source.contains(required),
            "DRC replay ordering implementation missing required source marker: {required}"
        );
    }
}
