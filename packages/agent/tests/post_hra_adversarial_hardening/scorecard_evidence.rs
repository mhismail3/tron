use super::support::*;

#[test]
fn post_hra_adversarial_hardening_scorecard_stays_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let manifest = read_repo_file(EVIDENCE_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Post-HRA Adversarial Hardening Scorecard",
        "Current score: **82/100**",
        "Status: **active**",
        "Total weight: **100**",
        "AHA-0 | Scorecard, evidence, and red-gate setup | 5 | passed_after_fix",
        "AHA-1 | Personal-info and source identity cleanup | 12 | passed_after_fix",
        "AHA-2 | Deleted-doc and template residue | 10 | passed_after_fix",
        "AHA-3 | CI and static-gate parity | 12 | passed_after_fix",
        "AHA-4 | Xcode project drift and Mac test execution | 8 | passed_after_fix",
        "AHA-5 | Rust module ownership cleanup | 10 | passed_after_fix",
        "AHA-6 | Rust progressive docs and near-budget guard | 6 | passed_after_fix",
        "AHA-7 | iOS transport/domain residue | 10 | passed_after_fix",
        "AHA-8 | iOS hierarchy, budgets, and docs | 9 | passed_after_fix",
        "AHA-9 | Inventory and provenance integrity | 8 | pending",
        "AHA-10 | Final adversarial closeout | 10 | pending",
        "## Static Gates",
    ] {
        assert!(
            scorecard.contains(required),
            "AHA scorecard missing required text: {required}"
        );
    }

    let score_total: u32 = scorecard
        .lines()
        .filter_map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            if columns.get(1).is_some_and(|cell| cell.starts_with("AHA-")) {
                columns.get(3).and_then(|cell| cell.parse::<u32>().ok())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(
        score_total, 100,
        "AHA scorecard row weights must sum to 100"
    );

    for required in [
        "# Post-HRA Adversarial Hardening Evidence Manifest",
        "Current score: **82/100**",
        "Status: **active**",
        "| AHA-0 | passed_after_fix |",
        "| AHA-1 | passed_after_fix |",
        "| AHA-2 | passed_after_fix |",
        "| AHA-3 | passed_after_fix |",
        "| AHA-4 | passed_after_fix |",
        "| AHA-5 | passed_after_fix |",
        "| AHA-6 | passed_after_fix |",
        "| AHA-7 | passed_after_fix |",
        "| AHA-8 | passed_after_fix |",
        "| AHA-10 | pending |",
        "## AHA-0 Red Proof",
        "## Residual Risk Log",
    ] {
        assert!(
            manifest.contains(required),
            "AHA evidence manifest missing required text: {required}"
        );
    }

    for required in [SCORECARD_PATH, EVIDENCE_PATH, INVARIANT_TEST_PATH] {
        assert!(
            readme.contains(required),
            "README living architecture docs must link {required}"
        );
    }
}
