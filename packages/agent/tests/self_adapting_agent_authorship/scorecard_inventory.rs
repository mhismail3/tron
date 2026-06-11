use std::collections::BTreeSet;

use super::support::{
    EVIDENCE_PATH, INVARIANT_TEST_PATH, INVENTORY_PATH, INVENTORY_TSV_PATH, SCORECARD_PATH,
    git_ls_files, inventory_by_path, parse_inventory, parse_scorecard_rows, read_repo_file,
    repo_path,
};

#[test]
fn saa_campaign_harness_is_linked_and_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Self-Adapting Agent Authorship Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "Baseline commit: `b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7`",
        "| SAA-0 | Harness | 7 | passed_after_fix |",
        "| SAA-1 | Source Inventory | 9 | passed_after_fix |",
        "| SAA-2 | Self-Authorship Contract | 10 | passed_after_fix |",
        "| SAA-3 | Durable Memory/Rule Substrate | 12 | passed_after_fix |",
        "| SAA-10 | Closeout | 8 | passed_after_fix |",
        "`../tests/self_adapting_agent_authorship_invariants.rs`",
    ] {
        assert!(
            scorecard.contains(required),
            "SAA scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Self-Adapting Agent Authorship Evidence Manifest",
        "Status: **complete**",
        "## Baseline Evidence",
        "## Verification Log",
        "| SAA-0 | passed_after_fix |",
        "| SAA-1 | passed_after_fix |",
        "| SAA-2 | passed_after_fix |",
        "| SAA-3 | passed_after_fix |",
        "| SAA-4 | passed_after_fix |",
        "| SAA-5 | passed_after_fix |",
        "| SAA-6 | passed_after_fix |",
        "| SAA-7 | passed_after_fix |",
        "| SAA-8 | passed_after_fix |",
        "| SAA-9 | passed_after_fix |",
        "| SAA-10 | passed_after_fix |",
    ] {
        assert!(
            evidence.contains(required),
            "SAA evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# Self-Adapting Agent Authorship Inventory",
        "Status: SAA campaign `complete`;",
        "## Surface Classes",
        "`model_surface`",
        "`execute_operation`",
        "`typed_resource`",
        "`promotion_boundary`",
        "`runtime_ui`",
        "## Closeout Notes",
    ] {
        assert!(
            inventory.contains(required),
            "SAA inventory missing required text: {required}"
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
fn saa_scorecard_weights_sum_to_100_and_current_score_matches_closed_rows() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 11, "SAA scorecard must contain rows SAA-0..10");
    let total: u32 = rows.iter().map(|row| row.points).sum();
    assert_eq!(total, 100, "SAA scorecard row weights must sum to 100");

    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.points)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "SAA current score must equal closed row weights"
    );
}

#[test]
fn saa_invariant_target_is_in_closeout_ci_lists() {
    let target = "self_adapting_agent_authorship_invariants";
    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(target),
            "{path} must list the SAA invariant target in closeout CI documentation"
        );
    }

    let readme = read_repo_file("README.md");
    assert!(
        readme.contains(target),
        "README closeout CI documentation missing target: {target}"
    );
}

#[test]
fn saa_evidence_rows_cover_every_closed_scorecard_checkpoint() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row in parse_scorecard_rows()
        .into_iter()
        .filter(|row| row.status == "passed_after_fix")
    {
        let required = format!("| {} | passed_after_fix |", row.row);
        assert!(
            evidence.contains(&required),
            "SAA evidence manifest missing row for closed checkpoint: {required}"
        );
    }
}

#[test]
fn saa_inventory_rows_are_structured_and_reference_tracked_paths() {
    let rows = parse_inventory();
    assert!(rows.len() >= 35, "SAA inventory row count regressed");
    let tracked: BTreeSet<_> = git_ls_files().into_iter().collect();
    let mut ids = BTreeSet::new();
    for row in &rows {
        assert!(
            ids.insert(row.id.clone()),
            "duplicate SAA row id: {}",
            row.id
        );
        assert!(
            tracked.contains(&row.path) || repo_path(&row.path).exists(),
            "SAA row path must be tracked or already staged for tracking: {}",
            row.path
        );
        for (field, value) in [
            ("language", &row.language),
            ("surface", &row.surface),
            ("current_role", &row.current_role),
            ("saa_rows", &row.saa_rows),
            ("proof", &row.proof),
            ("residual_risk", &row.residual_risk),
        ] {
            assert!(
                !value.trim().is_empty() && !value.contains("unclassified"),
                "{} has invalid {} field: `{}`",
                row.id,
                field,
                value
            );
        }
        assert!(
            row.saa_rows.contains("SAA-"),
            "{} must reference SAA rows",
            row.id
        );
    }

    let by_path = inventory_by_path();
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
        "packages/agent/src/domains/capability/contract.rs",
        "packages/agent/src/domains/capability/operations/resource.rs",
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs",
        "packages/agent/src/engine/durability/resources/definitions.rs",
        "packages/agent/src/engine/durability/resources/ui_surface.rs",
        "packages/agent/src/engine/runtime/external_workers/validation.rs",
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
        "packages/ios-app/Tests/UI/RuntimeSurfaces/GeneratedUIRendererTests.swift",
        "packages/mac-app/Tests/Infrastructure/Guards/MacSourceGuardTests.swift",
        "scripts/tron.d/quality.sh",
        ".github/workflows/ci.yml",
    ] {
        assert!(
            by_path.contains_key(required),
            "SAA inventory missing required path: {required}"
        );
    }
}

#[test]
fn saa_closeout_artifacts_reject_stale_state_after_completion() {
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
            "Open:",
            "Not started.",
            "pending final run",
            "pending |",
            "current_gap",
            "TODO",
        ] {
            assert!(
                !content.contains(forbidden),
                "{name} contains stale SAA closeout marker: {forbidden}"
            );
        }
    }
}
