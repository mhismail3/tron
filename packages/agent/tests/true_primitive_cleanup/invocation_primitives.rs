use super::support::*;

#[test]
fn invocation_host_and_primitive_store_roots_are_narrow() {
    for (path, limit) in [
        ("packages/agent/src/engine/invocation/host/mod.rs", 750),
        ("packages/agent/src/engine/primitives/mod.rs", 750),
        ("packages/agent/src/engine/tests/runtime/triggers.rs", 800),
    ] {
        let lines = line_count(&repo_path(path));
        assert!(
            lines <= limit,
            "TPC-3 file {path} has {lines} LOC, limit {limit}"
        );
    }

    for path in [
        "packages/agent/src/engine/invocation/host/bootstrap.rs",
        "packages/agent/src/engine/invocation/host/meta_invocation.rs",
        "packages/agent/src/engine/primitives/stores.rs",
        "packages/agent/src/engine/primitives/workers.rs",
        "packages/agent/src/engine/tests/runtime/trigger_helpers.rs",
    ] {
        assert!(
            repo_path(path).exists(),
            "TPC-3 expected split owner missing: {path}"
        );
    }

    let host = read_repo_file("packages/agent/src/engine/invocation/host/mod.rs");
    assert!(
        host.matches("pub use ").count() <= 1,
        "host root must not grow convenience re-export sprawl"
    );

    let primitives = read_repo_file("packages/agent/src/engine/primitives/mod.rs");
    assert!(
        !primitives.contains("OnceLock") && !primitives.contains("Weak<AsyncMutex<EngineHost>>"),
        "primitive store host-handle plumbing must live in stores.rs"
    );
}
