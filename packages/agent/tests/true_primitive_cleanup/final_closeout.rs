use super::support::*;

#[test]
fn final_closeout_is_complete() {
    let scorecard = read_repo_file("packages/agent/docs/true-primitive-cleanup-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/true-primitive-cleanup-evidence-manifest.md");

    for required in [
        "Current score: **100/100**",
        "Status: **complete**",
        "| TPC-11 | Final closeout | 5 | passed_after_fix |",
        "No open loops remain.",
    ] {
        assert!(
            scorecard.contains(required),
            "TPC-11 scorecard closeout missing `{required}`"
        );
    }

    for required in [
        "Current score: **100/100**",
        "Status: **complete**",
        "| TPC-11 | passed_after_fix |",
        "Full closeout verification",
        "ignored-artifact audit",
        "clean worktree proof",
    ] {
        assert!(
            manifest.contains(required),
            "TPC-11 evidence manifest missing `{required}`"
        );
    }

    assert!(
        !scorecard.contains("| TPC-11 | Final closeout | 5 | pending |")
            && !manifest.contains("| TPC-11 | pending |"),
        "TPC-11 must not remain pending after final closeout"
    );
}
