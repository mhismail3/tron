//! Static gates for the primitive engine teardown planning scorecard.

use std::path::{Path, PathBuf};

pub(super) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

pub(super) fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

pub(super) fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

pub(super) fn assert_repo_path_absent(path: &str, label: &str) {
    let full_path = repo_path(path);
    assert!(
        !full_path.exists(),
        "{label} must be physically deleted from the primitive branch: {}",
        full_path.display()
    );
}

pub(super) fn assert_absent(haystack: &str, banned: &[&str], label: &str) {
    for needle in banned {
        assert!(
            !haystack.contains(needle),
            "{label} must not retain primitive-teardown-banned text `{needle}`"
        );
    }
}

pub(super) fn read_repo_source_trees(paths: &[&str]) -> String {
    fn append_file(output: &mut String, path: &Path) {
        if !matches!(
            path.extension().and_then(|extension| extension.to_str()),
            Some("rs" | "swift" | "yml" | "yaml")
        ) {
            return;
        }
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("SourceGuardTests"))
        {
            return;
        }
        let text = std::fs::read_to_string(path)
            .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()));
        output.push_str("\n// FILE: ");
        output.push_str(&path.display().to_string());
        output.push('\n');
        output.push_str(&text);
    }

    fn append_path(output: &mut String, path: &Path) {
        if path.is_file() {
            append_file(output, path);
            return;
        }
        let entries = std::fs::read_dir(path)
            .unwrap_or_else(|error| panic!("failed to enumerate {}: {error}", path.display()));
        for entry in entries {
            let entry = entry.expect("directory entry should be readable");
            let path = entry.path();
            if path.is_dir() {
                append_path(output, &path);
            } else {
                append_file(output, &path);
            }
        }
    }

    let mut output = String::new();
    for path in paths {
        append_path(&mut output, &repo_path(path));
    }
    output
}
