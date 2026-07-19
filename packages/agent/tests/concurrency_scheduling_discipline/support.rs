use std::path::PathBuf;
use std::process::Command;

pub(super) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

pub(super) fn read_repo_file(path: &str) -> String {
    let full_path = repo_root().join(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn git_ls_files() -> Vec<String> {
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

fn tracked_sources(matcher: impl Fn(&str) -> bool) -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| matcher(path))
        .filter(|path| repo_root().join(path).is_file())
        .collect()
}

pub(super) fn production_rust_paths() -> Vec<String> {
    tracked_sources(|path| {
        path.starts_with("packages/agent/src/")
            && path.ends_with(".rs")
            && !path.contains("/tests/")
            && !path.ends_with("/tests.rs")
            && !path.ends_with("/test_utils.rs")
    })
}

pub(super) fn production_ios_swift_paths() -> Vec<String> {
    tracked_sources(|path| {
        path.starts_with("packages/ios-app/Sources/") && path.ends_with(".swift")
    })
}

pub(super) fn production_swift_paths() -> Vec<String> {
    tracked_sources(|path| {
        (path.starts_with("packages/ios-app/Sources/")
            || path.starts_with("packages/mac-app/Sources/"))
            && path.ends_with(".swift")
    })
}

pub(super) fn text_has_any(text: &str, needles: &[&str]) -> bool {
    let lower = text.to_ascii_lowercase();
    needles
        .iter()
        .any(|needle| lower.contains(&needle.to_ascii_lowercase()))
}
