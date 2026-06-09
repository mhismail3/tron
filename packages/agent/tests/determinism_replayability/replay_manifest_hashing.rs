use super::support::*;

#[test]
fn replay_manifest_hashing_row_is_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains("Canonical `tron.replay.v1` manifest export")
            && scorecard.contains("Byte-stable replay hashes and stable ordering"),
        "DRC manifest and hashing rows must be formalized"
    );
}
