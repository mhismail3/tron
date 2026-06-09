use super::support::*;

#[test]
fn drc_scorecard_and_evidence_are_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Determinism Replayability Scorecard",
        "Current score: **90/100**",
        "Status: **active**",
        "Branch: `codex/primitive-engine-teardown`",
        "Replay v1 is audit and reconstruction replay",
        "No provider re-contact during replay.",
        "No timestamp-only ordering in replay-critical sections.",
        "| DRC-0 | Scorecard, evidence, inventory, invariant target, README, and CI wiring | 6 | passed_after_fix |",
        "| DRC-1 | Replay-critical source inventory | 8 | passed_after_fix |",
        "| DRC-2 | Entropy centralization and allow-list | 12 | passed_after_fix |",
        "| DRC-3 | Deterministic constructors and injection seams | 12 | passed_after_fix |",
        "| DRC-4 | Provider request audit before model streaming | 12 | passed_after_fix |",
        "| DRC-5 | Canonical `tron.replay.v1` manifest export | 14 | passed_after_fix |",
        "| DRC-6 | Byte-stable replay hashes and stable ordering | 10 | passed_after_fix |",
        "| DRC-7 | Replay references across idempotency, queue, stream, and trace records | 8 | passed_after_fix |",
        "| DRC-8 | Offline replay roundtrip harness | 8 | passed_after_fix |",
        "| DRC-9 | Progressive docs, README, protocol docs, and iOS decode parity | 4 | pending |",
        "| DRC-10 | Final adversarial closeout | 6 | pending |",
        "Total weight: **100**",
        "cargo test --manifest-path /Users/moose/Downloads/projects/tron/packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture",
    ] {
        assert!(
            scorecard.contains(required),
            "DRC scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Determinism Replayability Evidence Manifest",
        "Current score: **90/100**",
        "Status: **active**",
        "| DRC-0 | passed_after_fix |",
        "| DRC-1 | passed_after_fix |",
        "| DRC-2 | passed_after_fix |",
        "| DRC-3 | passed_after_fix |",
        "| DRC-4 | passed_after_fix |",
        "| DRC-5 | passed_after_fix |",
        "| DRC-6 | passed_after_fix |",
        "| DRC-7 | passed_after_fix |",
        "| DRC-8 | passed_after_fix |",
        "| DRC-10 | pending |",
        "## DRC-0 Evidence",
        "## DRC-1 Evidence",
        "## DRC-2 Evidence",
        "## DRC-3 Evidence",
        "## DRC-4 Evidence",
        "## DRC-5 Evidence",
        "## DRC-6 Evidence",
        "## DRC-7 Evidence",
        "## DRC-8 Evidence",
        "## Verification Log",
        "## Residual Risk Log",
    ] {
        assert!(
            evidence.contains(required),
            "DRC evidence manifest missing required text: {required}"
        );
    }

    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            readme.contains(required),
            "README living architecture docs must link {required}"
        );
    }
}

#[test]
fn drc_scorecard_weights_sum_to_100() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let total: u32 = scorecard
        .lines()
        .filter_map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            if columns.get(1).is_some_and(|cell| cell.starts_with("DRC-")) {
                columns.get(3).and_then(|cell| cell.parse::<u32>().ok())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(total, 100, "DRC row weights must sum to 100");
}

#[test]
fn drc_inventory_covers_all_replay_critical_sources() {
    let inventory = read_repo_file(INVENTORY_PATH);
    let inventory_tsv = read_repo_file(INVENTORY_TSV_PATH);

    for required in [
        "# Determinism Replayability Inventory",
        "Status: DRC-8 `passed_after_fix`; DRC-9 and DRC-10 remain open",
        "Session events",
        "Provider request audit",
        "Trace records",
        "Engine invocations",
        "Engine streams",
        "Queue items and attempts",
        "Resources",
        "Storage payload blobs",
        "`chrono::Utc::now` / `Utc::now`",
        "`std::time::SystemTime::now`",
        "`std::time::Instant::now`",
        "`Uuid::now_v7`",
        "`rand::random` / `rand::rng`",
        "`ORDER BY timestamp`",
        "`session::replay_manifest`",
        "`execute` operation `replay_manifest`",
        "`engineIdempotencyEntries`",
        "`roundtrip_manifest`",
    ] {
        assert!(
            inventory.contains(required),
            "DRC inventory missing required text: {required}"
        );
    }

    for required in [
        "DRC-1-001\tsource\tsession_events",
        "DRC-1-002\tsource\tprovider_request_audit",
        "DRC-1-003\tsource\ttrace_records",
        "DRC-1-004\tsource\tengine_invocations",
        "DRC-1-005\tsource\tengine_stream_events",
        "DRC-1-006\tsource\tengine_queue_items",
        "DRC-1-009\tentropy\tutc_now",
        "DRC-1-012\tentropy\tuuid_now_v7",
        "DRC-1-014\thash\tcanonical_json",
        "DRC-1-015\tapi\tsession_replay_manifest",
        "DRC-1-017\tproof\tinvariant_target",
        "DRC-1-019\tproof\toffline_roundtrip",
    ] {
        assert!(
            inventory_tsv.contains(required),
            "DRC inventory TSV missing required row: {required}"
        );
    }
}
