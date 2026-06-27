use std::collections::BTreeSet;

use super::support::{
    EVIDENCE_PATH, INVARIANT_TEST_PATH, INVENTORY_PATH, INVENTORY_TSV_PATH, SCORECARD_PATH,
    git_ls_files, inventory_by_path, parse_inventory, parse_scorecard_rows, read_repo_file,
    repo_path, security_marker_paths,
};

#[test]
fn sacb_campaign_harness_is_linked_and_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Security Authority Capability Boundaries Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "| SACB-0 | Campaign harness, red gates, README/CI links, evidence/inventory scaffolding | 5 | passed_after_fix |",
        "| SACB-1 | Whole-repo security boundary inventory for Rust, iOS, Mac, scripts, docs | 10 | passed_after_fix |",
        "| SACB-2 | Public transport auth, route exposure, bearer handling, loopback worker boundary | 10 | passed_after_fix |",
        "| SACB-3 | Transport context trust: remove/deny untrusted authority scope and runtime metadata injection | 14 | passed_after_fix |",
        "| SACB-4 | Authority grant model: derivation, file roots, network policy, budgets, bootstrap grants | 12 | passed_after_fix |",
        "| SACB-5 | Catalog visibility and direct invocation boundaries, including `engine::invoke` delegation | 10 | passed_after_fix |",
        "| SACB-6 | `capability::execute` least privilege for file/process/state/trace/log/replay/catalog-discovery operations | 12 | passed_after_fix |",
        "| SACB-7 | External worker protocol isolation: scoped token, namespace, trigger, stream, result ownership | 8 | passed_after_fix |",
        "| SACB-8 | Secrets, token storage, redaction, auth.json permissions, provider credential custody | 7 | passed_after_fix |",
        "| SACB-9 | iOS/Mac pairing lifecycle: Keychain, QR/deep-link parsing, forget/re-pair/unauthorized flow | 7 | passed_after_fix |",
        "| SACB-10 | Final closeout, static gates, full verification, clean status | 5 | passed_after_fix |",
        "| POST-1 | Durable grant invocation budgets and scoped worker token grant hashes | passed_after_fix |",
        "| POST-2 | Delegated `engine::invoke` parent-budget ordering | passed_after_fix |",
        "`../tests/security_authority_capability_boundaries_invariants.rs`",
    ] {
        assert!(
            scorecard.contains(required),
            "SACB scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Security Authority Capability Boundaries Evidence Manifest",
        "Status: **complete**",
        "Current score: **100/100**",
        "| SACB-0 | passed_after_fix |",
        "| SACB-1 | passed_after_fix |",
        "| SACB-2 | passed_after_fix |",
        "| SACB-3 | passed_after_fix |",
        "| SACB-4 | passed_after_fix |",
        "| SACB-5 | passed_after_fix |",
        "| SACB-6 | passed_after_fix |",
        "| SACB-7 | passed_after_fix |",
        "| SACB-8 | passed_after_fix |",
        "| SACB-9 | passed_after_fix |",
        "| SACB-10 | passed_after_fix |",
        "| SACB-POST-1 | passed_after_fix |",
        "| SACB-POST-2 | passed_after_fix |",
        "## Baseline Evidence",
        "## Post-Audit Evidence",
    ] {
        assert!(
            evidence.contains(required),
            "SACB evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# Security Authority Capability Boundaries Inventory",
        "Status: SACB campaign `complete`; 975 security boundary rows inventoried and",
        "## Boundary Classes",
        "`public_transport`",
        "`authority_grant`",
        "`execute_primitive`",
        "## Coverage Policy",
        "## Closeout Notes",
    ] {
        assert!(
            inventory.contains(required),
            "SACB inventory missing required text: {required}"
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
fn sacb_scorecard_weights_sum_to_100_and_current_score_matches_closed_rows() {
    let rows = parse_scorecard_rows();
    assert_eq!(
        rows.len(),
        11,
        "SACB scorecard must contain rows SACB-0..10"
    );
    let total: u32 = rows.iter().map(|row| row.points).sum();
    assert_eq!(total, 100, "SACB scorecard row weights must sum to 100");

    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.points)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "SACB current score must equal closed row weights"
    );
}

#[test]
fn sacb_invariant_target_is_in_closeout_ci_lists() {
    let target = "security_authority_capability_boundaries_invariants";
    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(target),
            "{path} must list the SACB invariant target in closeout CI documentation"
        );
    }

    let readme = read_repo_file("README.md");
    assert!(
        readme.contains(target),
        "README closeout CI documentation missing target: {target}"
    );
}

#[test]
fn sacb_inventory_rows_are_structured_and_reference_tracked_paths() {
    let rows = parse_inventory();
    assert!(rows.len() >= 611, "SACB inventory row count regressed");
    let tracked: BTreeSet<_> = git_ls_files().into_iter().collect();
    let mut paths = BTreeSet::new();
    for row in &rows {
        assert!(
            paths.insert(row.path.clone()),
            "duplicate SACB row: {}",
            row.path
        );
        assert!(
            tracked.contains(&row.path) || repo_path(&row.path).exists(),
            "SACB row path must be tracked or already staged for tracking: {}",
            row.path
        );
        for (field, value) in [
            ("language", &row.language),
            ("surface", &row.surface),
            ("boundary_class", &row.boundary_class),
            ("trusted_owner", &row.trusted_owner),
            ("untrusted_input", &row.untrusted_input),
            ("authority_source", &row.authority_source),
            ("enforcement_point", &row.enforcement_point),
            ("deny_policy", &row.deny_policy),
            ("secret_or_token_policy", &row.secret_or_token_policy),
            ("test_evidence", &row.test_evidence),
            ("sacb_rows", &row.sacb_rows),
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
            row.sacb_rows.contains("SACB-"),
            "{} must reference SACB rows",
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
        "packages/agent/src/transport/engine/socket/wire.rs",
        "packages/agent/src/transport/engine/mod.rs",
        "packages/agent/src/engine/authority/grants/derivation.rs",
        "packages/agent/src/engine/authority/grants/policy_hash.rs",
        "packages/agent/src/domains/capability/operations/filesystem.rs",
        "packages/agent/tests/true_primitive_cleanup/inventory.rs",
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant_module_validation_tests.rs",
        "packages/agent/src/domains/capability/module_validation_contract.rs",
        "packages/agent/src/domains/capability/operations/module_validation.rs",
        "packages/agent/src/domains/module_validation/authority.rs",
        "packages/agent/src/domains/module_validation/contract.rs",
        "packages/agent/src/domains/module_validation/mod.rs",
        "packages/agent/src/domains/module_validation/projection.rs",
        "packages/agent/src/domains/module_validation/service.rs",
        "packages/agent/src/domains/module_validation/shell_ref_tests.rs",
        "packages/agent/src/domains/module_validation/tests.rs",
        "packages/agent/src/domains/module_validation/validation.rs",
        "packages/agent/src/engine/durability/resources/module_validation_definitions.rs",
    ] {
        assert!(
            by_path.contains_key(required),
            "SACB inventory missing seed row: {required}"
        );
    }
}

#[test]
fn sacb_inventory_covers_all_tracked_security_marker_files() {
    let inventory = inventory_by_path();
    let missing = security_marker_paths()
        .into_iter()
        .filter(|path| !inventory.contains_key(path))
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "SACB inventory missing security marker files:\n{}",
        missing.join("\n")
    );
}

#[test]
fn sacb_closeout_artifacts_reject_stale_state_after_completion() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains("Current score: **100/100**")
            && scorecard.contains("Status: **complete**"),
        "SACB closeout must remain complete after SACB-10"
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
            "pending |",
            "current_gap",
            "TODO",
        ] {
            assert!(
                !content.contains(forbidden),
                "{name} contains stale SACB closeout marker: {forbidden}"
            );
        }
    }
}
