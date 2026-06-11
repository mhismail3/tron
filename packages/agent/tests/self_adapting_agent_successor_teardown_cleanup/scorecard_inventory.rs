use std::collections::{BTreeMap, BTreeSet};

use crate::support::*;

#[test]
fn saastc_harness_docs_readme_and_ci_are_wired() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");
    let local_ci = read_repo_file("scripts/tron.d/quality.sh");
    let github_ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Scorecard",
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        BRANCH_NAME,
        BASELINE_COMMIT,
        INTEGRATION_HEAD,
        INVARIANT_TEST_PATH,
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Evidence Manifest",
        "Status: **complete**",
        "| SAASTC-0 | passed_after_fix |",
        "| SAASTC-11 | passed_after_fix |",
        "git diff --name-status b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7..HEAD",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Inventory",
        "Status: Complete",
        "`retained`",
        "`simplify`",
        "`remove`",
        "`docs-only`",
        "`predecessor-bookkeeping`",
    ] {
        assert!(inventory.contains(required), "inventory missing {required}");
    }
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
        "self_adapting_agent_successor_teardown_cleanup_invariants",
    ] {
        assert!(readme.contains(required), "README missing {required}");
    }
    for source in [local_ci, github_ci] {
        assert!(
            source.contains("self_adapting_agent_successor_teardown_cleanup_invariants"),
            "closeout CI must include SAASTC invariant target"
        );
    }
}

#[test]
fn saastc_scorecard_weights_statuses_and_current_score_are_consistent() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAASTC scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|row| row.weight).sum::<u32>(),
        100,
        "SAASTC row weights must sum to 100"
    );

    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.weight)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "current score must equal closed SAASTC row weights"
    );

    for row in rows {
        assert_eq!(
            row.status, "passed_after_fix",
            "{} must be closed after SAASTC final closeout",
            row.row
        );
    }
}

#[test]
fn saastc_inventory_covers_every_changed_file_since_oda_baseline() {
    let rows = parse_inventory();
    let changed = changed_paths_since_baseline();
    assert!(
        rows.len() >= changed.len(),
        "cleanup inventory must cover at least the current baseline diff"
    );

    let tracked = git_ls_files();
    let allowed_classifications = BTreeSet::from([
        "retained",
        "simplify",
        "remove",
        "docs-only",
        "predecessor-bookkeeping",
    ]);
    let mut ids = BTreeSet::new();
    let mut by_path = BTreeMap::new();

    for row in rows {
        assert!(
            ids.insert(row.id.clone()),
            "duplicate inventory id {}",
            row.id
        );
        assert!(
            row.id.starts_with("SAASTC-INV-"),
            "inventory id must use SAASTC prefix: {}",
            row.id
        );
        assert!(
            matches!(
                row.change.as_str(),
                "A" | "M" | "D" | "C" | "T" | "U" | "X" | "B"
            ) || row.change.starts_with('R'),
            "{} has unexpected git change marker {}",
            row.id,
            row.change
        );
        assert!(
            allowed_classifications.contains(row.classification.as_str()),
            "{} has invalid classification {}",
            row.id,
            row.classification
        );
        for (field, value) in [
            ("owner", row.owner.as_str()),
            ("action", row.action.as_str()),
            ("rationale", row.rationale.as_str()),
        ] {
            assert!(
                !value.trim().is_empty()
                    && !value.contains("TBD")
                    && !value.contains("TODO")
                    && !value.contains("unclassified"),
                "{} has invalid {} field: {}",
                row.id,
                field,
                value
            );
        }
        assert!(
            changed.contains_key(&row.path)
                || tracked.contains(&row.path)
                || repo_path(&row.path).exists(),
            "{} path must be in the baseline diff, tracked, or present: {}",
            row.id,
            row.path
        );
        assert!(
            by_path.insert(row.path.clone(), row.id.clone()).is_none(),
            "inventory has duplicate path {}",
            row.path
        );
    }

    for path in changed.keys() {
        assert!(
            by_path.contains_key(path),
            "inventory missing changed file from ODA baseline diff: {path}"
        );
    }
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
        "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup/support.rs",
        "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup/scorecard_inventory.rs",
        "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup/boundaries.rs",
        "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup/primitive_resources.rs",
        "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup/runtime_catalog_tests.rs",
    ] {
        assert!(
            by_path.contains_key(path),
            "inventory missing cleanup harness file: {path}"
        );
    }
}

#[test]
fn saastc_closeout_records_hard_cleanup_boundaries() {
    let joined = format!(
        "{}\n{}\n{}",
        read_repo_file(SCORECARD_PATH),
        read_repo_file(EVIDENCE_PATH),
        read_repo_file(INVENTORY_PATH)
    );
    for required in [
        "Do not add provider-visible tools",
        "Do not add public `/engine` surfaces",
        "Do not reintroduce repo-managed first-party skills",
        "Hard boundaries remain guarded after closeout",
    ] {
        assert!(
            joined.contains(required),
            "SAASTC docs must record cleanup boundary: {required}"
        );
    }
}
