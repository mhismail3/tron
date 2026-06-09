use super::support::*;

#[test]
fn replay_reference_rows_are_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Current score: **94/100**",
        "| DRC-7 | Replay references across idempotency, queue, stream, and trace records | 8 | passed_after_fix |",
        "| DRC-8 | Offline replay roundtrip harness | 8 | passed_after_fix |",
        "No open loops after DRC-7/DRC-8.",
    ] {
        assert!(
            scorecard.contains(required),
            "DRC replay reference proof missing required scorecard text: {required}"
        );
    }
}

#[test]
fn replay_manifest_carries_cross_record_hashes_and_refs() {
    let source = read_source_tree_text();
    for required in [
        "engine_idempotency_entries",
        "list_idempotency_by_session",
        "ledger_idempotency_by_session",
        "payload_fingerprint",
        "request_hash",
        "outcome_hash",
        "result_hash",
        "payload_hash",
        "first_invocation_id",
        "latest_invocation_id",
        "resultInvocationId",
        "replayedFromInvocationId",
    ] {
        assert!(
            source.contains(required),
            "DRC replay reference implementation missing required source marker: {required}"
        );
    }
}
