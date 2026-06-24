#[test]
fn server_registers_public_engine_protocol_messages_only() {
    let mut methods = vec!["discover", "inspect", "invoke", "promote", "watch"];
    methods.sort();
    assert_eq!(
        methods,
        vec!["discover", "inspect", "invoke", "promote", "watch",],
        "public engine protocol is intentionally limited to the engine transport surface"
    );
}

#[test]
fn removed_client_transport_scaffolding_stays_deleted() {
    let crate_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    for removed in [
        ["src", "server", "transport", &["json", "_rpc"].concat()]
            .iter()
            .collect::<std::path::PathBuf>(),
        ["src", "server", "websocket"]
            .iter()
            .collect::<std::path::PathBuf>(),
    ] {
        assert!(
            !crate_root.join(&removed).exists(),
            "{} must stay deleted",
            removed.display()
        );
    }

    let banned = [
        ["Json", "Rpc"].concat(),
        ["json", "_rpc"].concat(),
        ["Broadcast", "Manager"].concat(),
        ["/", "ws"].concat(),
        ["rpc", "::"].concat(),
        ["rpc", ".read"].concat(),
        ["rpc", ".write"].concat(),
    ];
    for rel in ["src/app", "src/main.rs"] {
        let path = crate_root.join(rel);
        for file in rust_files_under_path(&path) {
            let content = std::fs::read_to_string(&file)
                .unwrap_or_else(|error| panic!("failed to read {}: {error}", file.display()));
            for needle in &banned {
                assert!(
                    !content.contains(needle),
                    "{} still contains removed transport marker `{needle}`",
                    file.display()
                );
            }
        }
    }
}

#[test]
fn readme_documents_engine_protocol() {
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("agent crate should live under packages/agent");
    let readme_path = repo_root.join("README.md");
    let readme = std::fs::read_to_string(&readme_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", readme_path.display()));
    assert!(
        readme.contains("GET /engine"),
        "README must document the public engine protocol endpoint"
    );
}

fn rust_files_under_path(path: &std::path::Path) -> Vec<std::path::PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    let mut files = Vec::new();
    let entries = std::fs::read_dir(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
    for entry in entries {
        let entry = entry.unwrap_or_else(|error| panic!("failed to read dir entry: {error}"));
        let path = entry.path();
        if path.is_dir() {
            files.extend(rust_files_under_path(&path));
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            files.push(path);
        }
    }
    files
}
#[test]
fn ordinary_startup_delegates_to_constitution_seeders() {
    let source = include_str!("../mod.rs");
    assert!(source.contains("ensure_tron_home"));
    assert!(!source.contains("startup_system_subdirs"));
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
