use super::support::*;

#[test]
fn offline_roundtrip_harness_is_wired_without_side_effect_handles() {
    let source = read_source_tree_text();
    for required in [
        "mod roundtrip;",
        "roundtrip_manifest",
        "ReplayRoundtripReport",
        "recomputed_replay_hash",
        "section_hash_mismatches",
        "cross_record_reference_errors",
        "recompute_section_hashes",
        "recompute_replay_hash",
        "validate_cross_record_references",
        "no event-store, engine, model",
        "provider re-contact or side effects",
    ] {
        assert!(
            source.contains(required),
            "DRC offline roundtrip implementation missing required source marker: {required}"
        );
    }
}
