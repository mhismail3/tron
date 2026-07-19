use std::path::PathBuf;
use std::process::Command;

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

pub(super) fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

pub(super) fn is_production_rust_or_swift(path: &str) -> bool {
    let is_rust = path.starts_with("packages/agent/src/") && path.ends_with(".rs");
    let is_swift = path.starts_with("packages/ios-app/Sources/") && path.ends_with(".swift");
    (is_rust || is_swift)
        && !path.contains("/tests/")
        && !path.ends_with("/tests.rs")
        && !path.ends_with("/test_utils.rs")
}
