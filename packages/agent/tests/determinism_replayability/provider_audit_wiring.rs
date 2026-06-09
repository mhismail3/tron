use super::support::*;

#[test]
fn provider_request_audit_row_is_open_until_behavior_lands() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard
            .contains("| DRC-4 | Provider request audit before model streaming | 12 | pending |"),
        "DRC-4 must stay visibly open until provider audit persistence is implemented"
    );
}
