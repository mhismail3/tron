use std::collections::BTreeSet;

use super::support::{
    EVIDENCE_PATH, INVARIANT_TEST_PATH, INVENTORY_PATH, INVENTORY_TSV_PATH, SCORECARD_PATH,
    git_ls_files, inventory_by_path, parse_inventory, parse_scorecard_rows, read_repo_file,
    repo_path,
};

#[test]
fn oda_campaign_harness_is_linked_and_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Observability Diagnostics Auditability Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "| ODA-0 | Campaign harness, README/CI links, evidence/inventory scaffolding, invariant target | 7 | passed_after_fix |",
        "| ODA-1 | Source inventory for server, iOS, Mac, scripts, docs, and tests | 10 | passed_after_fix |",
        "| ODA-2 | Correlation through session events, provider audits, primitive traces, replay, and engine ledger rows | 13 | passed_after_fix |",
        "| ODA-4 | Logs are bounded, redacted, deduplicated, queryable, and loop-safe | 12 | passed_after_fix |",
        "| ODA-5 | Diagnostics bundles include useful local/server context while excluding secrets and private payloads | 10 | passed_after_fix |",
        "| ODA-8 | CLI and dev UX expose bounded machine-readable state | 8 | passed_after_fix |",
        "`../tests/observability_diagnostics_auditability_invariants.rs`",
    ] {
        assert!(
            scorecard.contains(required),
            "ODA scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Observability Diagnostics Auditability Evidence Manifest",
        "Status: **complete**",
        "Current score: **100/100**",
        "## Baseline Evidence",
        "## Verification Log",
        "| ODA-0 | passed_after_fix |",
        "| ODA-1 | passed_after_fix |",
        "| ODA-2 | passed_after_fix |",
        "| ODA-3 | passed_after_fix |",
        "| ODA-4 | passed_after_fix |",
        "| ODA-5 | passed_after_fix |",
        "| ODA-6 | passed_after_fix |",
        "| ODA-7 | passed_after_fix |",
        "| ODA-8 | passed_after_fix |",
        "| ODA-9 | passed_after_fix |",
    ] {
        assert!(
            evidence.contains(required),
            "ODA evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# Observability Diagnostics Auditability Inventory",
        "Status: ODA campaign `complete`;",
        "## Surface Classes",
        "`server_trace`",
        "`server_logs`",
        "`client_diagnostics`",
        "`cli_diagnostics`",
        "## Coverage Policy",
        "## Closeout Notes",
    ] {
        assert!(
            inventory.contains(required),
            "ODA inventory missing required text: {required}"
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
fn oda_scorecard_weights_sum_to_100_and_current_score_matches_closed_rows() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 10, "ODA scorecard must contain rows ODA-0..9");
    let total: u32 = rows.iter().map(|row| row.points).sum();
    assert_eq!(total, 100, "ODA scorecard row weights must sum to 100");

    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.points)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "ODA current score must equal closed row weights"
    );
}

#[test]
fn oda_invariant_target_is_in_closeout_ci_lists() {
    let target = "observability_diagnostics_auditability_invariants";
    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(target),
            "{path} must list the ODA invariant target in closeout CI documentation"
        );
    }

    let readme = read_repo_file("README.md");
    assert!(
        readme.contains(target),
        "README closeout CI documentation missing target: {target}"
    );
}

#[test]
fn oda_evidence_rows_cover_every_closed_scorecard_checkpoint() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row in parse_scorecard_rows()
        .into_iter()
        .filter(|row| row.status == "passed_after_fix")
    {
        let required = format!("| {} | passed_after_fix |", row.row);
        assert!(
            evidence.contains(&required),
            "ODA evidence manifest missing row for closed checkpoint: {required}"
        );
    }
}

#[test]
fn oda_inventory_rows_are_structured_and_reference_tracked_paths() {
    let rows = parse_inventory();
    assert!(rows.len() >= 50, "ODA inventory row count regressed");
    let tracked: BTreeSet<_> = git_ls_files().into_iter().collect();
    let mut paths = BTreeSet::new();
    for row in &rows {
        assert!(
            paths.insert(row.path.clone()),
            "duplicate ODA row: {}",
            row.path
        );
        assert!(
            tracked.contains(&row.path) || repo_path(&row.path).exists(),
            "ODA row path must be tracked or already staged for tracking: {}",
            row.path
        );
        for (field, value) in [
            ("language", &row.language),
            ("surface", &row.surface),
            ("observed_signal", &row.observed_signal),
            ("correlation_ids", &row.correlation_ids),
            ("redaction_boundary", &row.redaction_boundary),
            (
                "retention_or_query_behavior",
                &row.retention_or_query_behavior,
            ),
            ("proof_target", &row.proof_target),
            ("oda_rows", &row.oda_rows),
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
            row.oda_rows.contains("ODA-"),
            "{} must reference ODA rows",
            row.path
        );
    }

    let by_path = inventory_by_path();
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
        "packages/agent/src/domains/logs/mod.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/logs.rs",
        "packages/agent/src/domains/capability/operations/trace.rs",
        "packages/agent/src/domains/session/replay/mod.rs",
        "packages/agent/src/shared/protocol/model_audit.rs",
        "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift",
        "packages/mac-app/Sources/MenuBar/Presentation/MenuBarLogReader.swift",
        "scripts/tron-lib.d/logs.sh",
        "scripts/tron-lib.d/service.sh",
    ] {
        assert!(
            by_path.contains_key(required),
            "ODA inventory missing required observed path: {required}"
        );
    }
}

#[test]
fn oda_closeout_artifacts_reject_stale_state_after_completion() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains("Current score: **100/100**")
            && scorecard.contains("Status: **complete**"),
        "ODA closeout must remain complete after ODA-9"
    );

    let files = [
        ("scorecard", scorecard),
        ("evidence", read_repo_file(EVIDENCE_PATH)),
        ("inventory", read_repo_file(INVENTORY_PATH)),
        ("inventory_tsv", read_repo_file(INVENTORY_TSV_PATH)),
    ];
    for (name, content) in files {
        for forbidden in [
            "Status: **active**",
            "open loop",
            "open-loop",
            "Open:",
            "Not started.",
            "pending final run",
            "pending |",
            "current_gap",
            "TODO",
        ] {
            assert!(
                !content.contains(forbidden),
                "{name} contains stale ODA closeout marker: {forbidden}"
            );
        }
    }
}
