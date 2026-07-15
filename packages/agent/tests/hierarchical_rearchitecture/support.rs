//! Living source-ownership guards retained from the hierarchy repair.

pub(super) use std::collections::HashSet;
use std::path::{Path, PathBuf};

pub(super) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

pub(super) fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

pub(super) fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

pub(super) fn source_line_count(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
        .lines()
        .count()
}
