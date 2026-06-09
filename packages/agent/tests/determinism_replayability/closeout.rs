use super::support::*;

#[test]
fn drc_closeout_row_stays_open_until_score_is_complete() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains("| DRC-10 | Final adversarial closeout | 6 | pending |"),
        "DRC-10 must remain pending until the campaign reaches 100/100"
    );
}
