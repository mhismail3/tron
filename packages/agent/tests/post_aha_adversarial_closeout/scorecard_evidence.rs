use super::support::*;

#[test]
fn post_aha_adversarial_closeout_scorecard_stays_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let manifest = read_repo_file(EVIDENCE_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Post-AHA Adversarial Closeout Scorecard",
        "Current score: **50/100**",
        "Status: **active**",
        "Total weight: **100**",
        "PAC-0 | Scorecard, evidence, README, and red-gate setup | 6 | passed_after_fix",
        "PAC-1 | Mac generated-project CI policy | 10 | passed_after_fix",
        "PAC-2 | README/AGENTS source-truth path repair | 12 | passed_after_fix",
        "PAC-3 | Runtime/docs parity and database inventory | 10 | passed_after_fix",
        "PAC-4 | Mac launch-agent/process ownership | 12 | passed_after_fix",
        "PAC-5 | Mac guard parity | 10 | pending",
        "PAC-6 | iOS hierarchy and mirrored tests | 9 | pending",
        "PAC-7 | Rust docs and LOC split budgets | 10 | pending",
        "PAC-8 | Local/GitHub CI parity | 8 | pending",
        "PAC-9 | Provenance, privacy, and residue policy | 7 | pending",
        "PAC-10 | Final closeout verification | 6 | pending",
        "mac_generated_project_policy_is_truthful",
        "documented_source_truth_paths_exist_or_use_supported_globs",
        "startup_domains_and_database_inventory_match_runtime_truth",
        "mac_launch_agent_and_subprocess_have_physical_owners",
        "mac_source_guards_cover_wrapper_contracts",
        "ios_transport_and_chat_tests_mirror_production_owners",
        "rust_progressive_docs_and_loc_split_plans_are_current",
        "local_and_github_ci_run_the_same_static_closeout_targets",
        "aha_provenance_privacy_and_residue_policy_are_in_repo",
    ] {
        assert!(
            scorecard.contains(required),
            "PAC scorecard missing required text: {required}"
        );
    }

    let score_total: u32 = scorecard
        .lines()
        .filter_map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            if columns.get(1).is_some_and(|cell| cell.starts_with("PAC-")) {
                columns.get(3).and_then(|cell| cell.parse::<u32>().ok())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(
        score_total, 100,
        "PAC scorecard row weights must sum to 100"
    );

    for required in [
        "# Post-AHA Adversarial Closeout Evidence Manifest",
        "Current score: **50/100**",
        "Status: **active**",
        "| PAC-0 | passed_after_fix |",
        "| PAC-1 | passed_after_fix |",
        "| PAC-2 | passed_after_fix |",
        "| PAC-3 | passed_after_fix |",
        "| PAC-4 | passed_after_fix |",
        "| PAC-10 | pending |",
        "## PAC-0 Red Proof",
        "## Residual Risk Log",
    ] {
        assert!(
            manifest.contains(required),
            "PAC evidence manifest missing required text: {required}"
        );
    }

    for required in [SCORECARD_PATH, EVIDENCE_PATH, INVARIANT_TEST_PATH] {
        assert!(
            readme.contains(required),
            "README living architecture docs must link {required}"
        );
    }
}
