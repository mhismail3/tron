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
