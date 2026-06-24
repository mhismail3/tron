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

#[test]
fn replay_manifest_builder_and_hashing_are_wired() {
    let source = read_source_tree_text();
    for required in [
        "REPLAY_MANIFEST_FORMAT: &str = \"tron.replay.v1\"",
        "struct ReplaySectionHashes",
        "replay_hash",
        "canonicalize_value",
        "BTreeMap",
        "Sha256",
        "hex::encode",
        "session::replay_manifest",
        "session_replay_manifest_value",
        "\"replay_manifest\" => |invocation, deps|",
        "operation == \"replay_manifest\"",
        "replay_manifest must not mutate trace records",
    ] {
        assert!(
            source.contains(required),
            "DRC replay manifest implementation missing required source marker: {required}"
        );
    }
}
