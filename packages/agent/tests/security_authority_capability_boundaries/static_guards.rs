use super::support::{INVARIANT_TEST_PATH, read_repo_file};

#[test]
fn sacb_static_guard_module_is_active() {
    let target = read_repo_file(INVARIANT_TEST_PATH);
    assert!(
        target.contains("mod security_authority_capability_boundaries;"),
        "SACB invariant target must load focused guard modules"
    );

    let module =
        read_repo_file("packages/agent/tests/security_authority_capability_boundaries/mod.rs");
    for required in [
        "mod scorecard_inventory;",
        "mod static_guards;",
        "mod support;",
    ] {
        assert!(
            module.contains(required),
            "SACB module registry missing {required}"
        );
    }
}
