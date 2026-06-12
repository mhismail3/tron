use std::collections::BTreeSet;

use super::support::{
    ALLOWED_SCHEDULER_CLASSES, EVIDENCE_PATH, INVARIANT_TEST_PATH, INVENTORY_PATH,
    INVENTORY_TSV_PATH, SCORECARD_PATH, inventory_by_path, marker_paths, parse_inventory,
    read_repo_file, repo_path,
};

#[test]
fn csd_campaign_harness_is_linked_and_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Concurrency Scheduling Discipline Scorecard",
        "Status: **complete**",
        "Current score: **100/100**",
        "| CSD-0 | Campaign harness, red gates, README links, scorecard/evidence/inventory scaffolding | 5 | passed_after_fix |",
        "| CSD-1 | Whole-repo scheduling inventory | 10 | passed_after_fix |",
        "| CSD-2 | Spawn/task ownership | 12 | passed_after_fix |",
        "| CSD-3 | Channels, streams, and backpressure | 12 | passed_after_fix |",
        "| CSD-4 | Timer loops and scheduling fairness | 10 | passed_after_fix |",
        "| CSD-5 | Blocking and CPU/IO isolation | 8 | passed_after_fix |",
        "| CSD-6 | Agent/session turn concurrency | 10 | passed_after_fix |",
        "| CSD-7 | Engine queue and external worker scheduling | 10 | passed_after_fix |",
        "| CSD-8 | iOS transport/event/update scheduling | 12 | passed_after_fix |",
        "| CSD-9 | Deterministic scheduling tests | 6 | passed_after_fix |",
        "| CSD-10 | Final closeout | 5 | passed_after_fix |",
        "`../tests/concurrency_scheduling_discipline_invariants.rs`",
    ] {
        assert!(
            scorecard.contains(required),
            "CSD scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Concurrency Scheduling Discipline Evidence Manifest",
        "Status: **complete**",
        "Current score: **100/100**",
        "| CSD-0 | passed_after_fix |",
        "| CSD-10 | passed_after_fix |",
        "## Closed Findings",
    ] {
        assert!(
            evidence.contains(required),
            "CSD evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# Concurrency Scheduling Discipline Inventory",
        "Status: CSD-10 `passed_after_fix`; 113 scheduling-surface rows inventoried and classified.",
        "## Allowed Scheduler Classes",
        "`tracked_background_task`",
        "`bounded_queue`",
        "`ack_coalescer`",
        "## Rust Scheduling Proof",
        "## iOS Scheduling Proof",
        "## Closeout Policy",
    ] {
        assert!(
            inventory.contains(required),
            "CSD inventory missing required text: {required}"
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
            "README living-doc map must link {required}"
        );
    }
}

#[test]
fn csd_scorecard_weights_sum_to_100() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let total: u32 = scorecard
        .lines()
        .filter(|line| line.starts_with("| CSD-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            columns[3]
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid CSD scorecard weight in {line}: {error}"))
        })
        .sum();
    assert_eq!(total, 100, "CSD scorecard row weights must sum to 100");
}

#[test]
fn csd_invariant_target_is_in_closeout_ci_lists() {
    let target = "concurrency_scheduling_discipline_invariants";
    for (path, required) in [
        ("scripts/tron.d/quality.sh", target),
        (".github/workflows/ci.yml", target),
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains(required),
            "{path} must list the CSD invariant target in closeout CI documentation"
        );
    }

    let readme = read_repo_file("README.md");
    for required in [
        "primitive_engine_teardown_plan_invariants",
        "determinism_replayability_invariants",
        "primitive_code_cleanup_invariants",
        "hierarchical_rearchitecture_invariants",
        "post_hra_adversarial_hardening_invariants",
        "post_aha_adversarial_closeout_invariants",
        target,
        "primitive_trace_execution",
        "serial `integration`",
    ] {
        assert!(
            readme.contains(required),
            "README closeout CI documentation missing target: {required}"
        );
    }
}

#[test]
fn csd_inventory_rows_are_structured_and_cover_marker_files() {
    let rows = parse_inventory();
    assert_eq!(rows.len(), 115, "CSD inventory row count changed");

    let mut paths = BTreeSet::new();
    let allowed: BTreeSet<_> = ALLOWED_SCHEDULER_CLASSES.iter().copied().collect();
    for row in &rows {
        assert!(
            paths.insert(row.path.clone()),
            "duplicate CSD row: {}",
            row.path
        );
        assert!(
            repo_path(&row.path).exists(),
            "CSD row path must exist: {}",
            row.path
        );
        assert!(
            allowed.contains(row.scheduler_class.as_str()),
            "unexpected scheduler class `{}` for {}",
            row.scheduler_class,
            row.path
        );
        assert!(
            row.language == "Rust" || row.language == "Swift",
            "unexpected language `{}` for {}",
            row.language,
            row.path
        );
        for (field, value) in [
            ("surface", &row.surface),
            ("owner", &row.owner),
            ("start_site", &row.start_site),
            ("stop_or_cancel_site", &row.stop_or_cancel_site),
            ("backpressure_or_capacity", &row.backpressure_or_capacity),
            ("ordering_or_fairness", &row.ordering_or_fairness),
            ("timeout_or_deadline", &row.timeout_or_deadline),
            ("blocking_policy", &row.blocking_policy),
            ("test_evidence", &row.test_evidence),
            ("csd_rows", &row.csd_rows),
        ] {
            assert!(
                !value.trim().is_empty() && !value.contains("unclassified"),
                "{} has invalid {} field: `{}`",
                row.path,
                field,
                value
            );
        }
        assert!(
            row.csd_rows.contains("CSD-"),
            "{} must reference CSD rows",
            row.path
        );
    }

    let inventory = inventory_by_path();
    let missing = marker_paths()
        .into_iter()
        .filter(|path| !inventory.contains_key(path))
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "CSD inventory missing marker files:\n{}",
        missing.join("\n")
    );
}

#[test]
fn csd_closeout_artifacts_have_no_stale_state_wording() {
    let files = [
        ("scorecard", read_repo_file(SCORECARD_PATH)),
        ("evidence", read_repo_file(EVIDENCE_PATH)),
        ("inventory", read_repo_file(INVENTORY_PATH)),
        ("inventory_tsv", read_repo_file(INVENTORY_TSV_PATH)),
    ];
    for (name, content) in files {
        for forbidden in [
            "Status: **active**",
            "open loop",
            "open-loop",
            "remaining proof",
            "Not started.",
            "pending |",
            "current_gap",
            "TODO",
        ] {
            assert!(
                !content.contains(forbidden),
                "{name} contains stale CSD closeout marker: {forbidden}"
            );
        }
    }
}
