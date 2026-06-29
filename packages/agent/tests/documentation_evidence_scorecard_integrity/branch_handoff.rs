use super::*;

#[test]
fn branch_handoff_and_remote_pickup_rules_are_recorded() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    for required in [
        "codex/documentation-evidence-scorecard-integrity-current",
        "codex/documentation-evidence-scorecard-integrity",
        "quarry-only",
        BASE_COMMIT,
        STALE_BRANCH_HEAD,
        "git status --short",
        "another thread can continue without chat history",
    ] {
        assert!(
            scorecard.contains(required)
                || evidence.contains(required)
                || inventory.contains(required),
            "DESI branch/handoff docs missing {required}"
        );
    }
    assert!(
        scorecard.find(BASE_COMMIT).expect("base commit marker")
            < scorecard.find("quarry-only").expect("quarry-only marker"),
        "scorecard must establish current lineage before stale-branch quarantine"
    );
}
