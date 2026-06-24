use super::support::*;

#[test]
fn drc_closeout_is_complete() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let inventory_tsv = read_repo_file(INVENTORY_TSV_PATH);

    for required in [
        "Current score: **100/100**",
        "Status: **complete**",
        "| DRC-10 | Final adversarial closeout | 6 | passed_after_fix |",
        "| DRC-10 | Final adversarial closeout | 6 | passed_after_fix | test_harness |",
        "No open loops remain.",
        "DRC-10 final closeout checkpoint",
    ] {
        assert!(
            scorecard.contains(required),
            "DRC closeout scorecard missing required text: {required}"
        );
    }

    assert!(
        evidence.contains("Current score: **100/100**")
            && evidence.contains("Status: **complete**")
            && evidence.contains("| DRC-10 | passed_after_fix |")
            && evidence.contains("## DRC-10 Evidence")
            && evidence.contains("No open loops remain."),
        "DRC evidence manifest must record final closeout state"
    );

    assert!(
        inventory.contains("Status: DRC-10 `passed_after_fix`; replay v1 campaign complete")
            && inventory.contains("## DRC-10 Closure Notes")
            && inventory.contains("No open loops remain."),
        "DRC inventory must record final closeout state"
    );

    assert!(
        inventory_tsv.contains("DRC-1-022\tproof\tfinal_closeout"),
        "DRC inventory TSV must include final closeout proof row"
    );

    for (path, text) in [
        (SCORECARD_PATH, scorecard.as_str()),
        (INVENTORY_PATH, inventory.as_str()),
    ] {
        for stale in [
            "Current score: **94/100**",
            "Status: **active**",
            "| DRC-10 | pending |",
            "| DRC-10 | Final adversarial closeout | 6 | pending |",
            "DRC-10 remains open",
            "Awaiting all implementation rows.",
            "must still",
            "may close only",
            "remaining proof",
        ] {
            assert!(
                !text.contains(stale),
                "{path} contains stale closeout wording: {stale}"
            );
        }
    }
}
