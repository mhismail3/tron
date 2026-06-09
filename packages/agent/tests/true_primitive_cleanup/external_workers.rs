use super::support::*;

#[test]
fn external_worker_runtime_is_loopback_split_and_proven() {
    for (path, limit) in [
        (
            "packages/agent/src/engine/runtime/external_workers/mod.rs",
            750,
        ),
        (
            "packages/agent/src/engine/tests/runtime/external_worker.rs",
            800,
        ),
    ] {
        let lines = line_count(&repo_path(path));
        assert!(
            lines <= limit,
            "{path} has {lines} LOC, expected <= {limit}"
        );
    }

    for path in [
        "packages/agent/src/engine/runtime/external_workers/lifecycle.rs",
        "packages/agent/src/engine/runtime/external_workers/registration.rs",
        "packages/agent/src/engine/runtime/external_workers/validation.rs",
        "packages/agent/src/engine/tests/runtime/external_worker_helpers.rs",
        "packages/agent/src/engine/tests/runtime/external_worker_protocol.rs",
    ] {
        assert!(
            repo_path(path).exists(),
            "TPC-4 split owner file missing: {path}"
        );
    }

    let root = read_repo_file("packages/agent/src/engine/runtime/external_workers/mod.rs");
    let lifecycle =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/lifecycle.rs");
    assert!(
        lifecycle.contains("external workers are loopback-only in this package"),
        "external worker lifecycle owner must retain the loopback-only policy"
    );
    assert!(
        !root.contains("fn validate_external_capability_metadata(")
            && !root.contains("fn validate_worker_token("),
        "external worker root must not own token/capability validation bodies"
    );

    assert!(
        lifecycle.contains("mark_durable_worker_disconnected"),
        "durable external worker disconnect behavior must stay explicitly owned"
    );

    let validation =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/validation.rs");
    assert!(
        validation.contains("validate_worker_token")
            && validation.contains("validate_external_capability_metadata"),
        "external worker validation owner must retain token and capability checks"
    );
}
