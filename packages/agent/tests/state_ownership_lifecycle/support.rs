use std::path::PathBuf;

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

pub(super) fn assert_contains_in_order(name: &str, text: &str, needles: &[&str]) {
    let mut offset = 0;
    for needle in needles {
        let Some(index) = text[offset..].find(needle) else {
            panic!("{name} missing `{needle}` after byte offset {offset}");
        };
        offset += index + needle.len();
    }
}
