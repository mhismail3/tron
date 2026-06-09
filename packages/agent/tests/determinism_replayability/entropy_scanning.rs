use super::support::*;

#[test]
fn drc_entropy_inventory_names_replay_critical_patterns() {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    for required in [
        "utc_now",
        "system_time_now",
        "instant_now",
        "uuid_now_v7",
        "rand_random",
    ] {
        assert!(
            inventory.contains(required),
            "DRC entropy inventory must include {required}"
        );
    }
}

#[test]
fn replay_entropy_guard_module_is_wired_to_closeout_target() {
    let source = read_source_tree_text();
    assert!(
        source.contains("determinism_replayability_invariants"),
        "local/GitHub closeout wiring must run the DRC invariant target"
    );
}
