use super::support::*;

#[test]
fn rust_source_root_has_only_allowed_entry_files() {
    let allowed = HashSet::from(["lib.rs", "main.rs"]);
    let mut unexpected = Vec::new();
    for entry in std::fs::read_dir(repo_path("packages/agent/src"))
        .expect("Rust source root should be readable")
    {
        let path = entry.expect("source root entry should be readable").path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("rs") {
            let file_name = path
                .file_name()
                .and_then(|name| name.to_str())
                .expect("Rust source file should have UTF-8 name");
            if !allowed.contains(file_name) {
                unexpected.push(
                    path.strip_prefix(repo_root())
                        .unwrap()
                        .display()
                        .to_string(),
                );
            }
        }
    }

    assert!(
        unexpected.is_empty(),
        "Rust source root must contain only true crate entry files; move these into owned modules: {unexpected:#?}"
    );
}

#[test]
fn rust_engine_root_has_no_unowned_flat_modules() {
    let mut unexpected = Vec::new();
    for entry in
        std::fs::read_dir(repo_path("packages/agent/src/engine")).expect("engine root readable")
    {
        let path = entry.expect("engine entry should be readable").path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("rs")
            && path.file_name().and_then(|name| name.to_str()) != Some("mod.rs")
        {
            unexpected.push(
                path.strip_prefix(repo_root())
                    .unwrap()
                    .display()
                    .to_string(),
            );
        }
    }

    assert!(
        unexpected.is_empty(),
        "Rust engine root must be subsystem folders plus mod.rs, not unowned flat modules: {unexpected:#?}"
    );
}
