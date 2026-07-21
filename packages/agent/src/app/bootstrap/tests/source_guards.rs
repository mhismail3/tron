#[test]
fn readme_documents_engine_protocol() {
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("agent crate should live under packages/agent");
    let readme_path = repo_root.join("packages/agent/docs/project-reference.md");
    let readme = std::fs::read_to_string(&readme_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", readme_path.display()));
    assert!(
        readme.contains("GET /engine"),
        "README must document the public engine protocol endpoint"
    );
}

#[test]
fn ordinary_startup_does_not_probe_tcc_permissions() {
    let source = include_str!("../mod.rs");
    let spawn_body = source
        .split("fn spawn_background_tasks")
        .nth(1)
        .and_then(|tail| tail.split("pub async fn run_server").next())
        .expect("spawn_background_tasks body should be discoverable");

    for forbidden in ["Privacy_AllFiles", "x-apple.systempreferences"] {
        assert!(
            !spawn_body.contains(forbidden),
            "ordinary startup must not touch macOS TCC or open permission UI; found {forbidden}"
        );
    }
}
