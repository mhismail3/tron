//! Static gate helpers for the True Modularity Boundary campaign.

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

pub(super) fn tracked_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run in repository tests");
    assert!(
        output.status.success(),
        "git ls-files failed with status {:?}",
        output.status.code()
    );
    String::from_utf8(output.stdout)
        .expect("git ls-files output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

pub(super) fn tracked_boundary_sources() -> Vec<String> {
    tracked_files()
        .into_iter()
        .filter(|path| {
            (path.starts_with("packages/agent/src/") && path.ends_with(".rs"))
                || (path.starts_with("packages/ios-app/Sources/") && path.ends_with(".swift"))
        })
        .filter(|path| !is_test_support_path(path))
        .collect()
}

pub(super) fn is_test_support_path(path: &str) -> bool {
    path.contains("/tests/")
        || path.contains("/Tests/")
        || path.ends_with("_tests.rs")
        || path.ends_with("test_support.rs")
        || path.contains("SourceGuardTests")
}

pub(super) fn strip_cfg_test_modules(text: &str) -> String {
    let mut output = String::new();
    let mut skip_depth: Option<i32> = None;
    let mut pending_cfg_test = false;

    for line in text.lines() {
        let trimmed = line.trim();
        if skip_depth.is_some() {
            let mut depth = skip_depth.unwrap_or(0);
            depth += brace_delta(line);
            if depth <= 0 {
                skip_depth = None;
            } else {
                skip_depth = Some(depth);
            }
            continue;
        }

        if trimmed.starts_with("#[cfg(test)]") {
            pending_cfg_test = true;
            continue;
        }

        if pending_cfg_test && trimmed.starts_with("mod tests") {
            let depth = brace_delta(line);
            if depth > 0 {
                skip_depth = Some(depth);
            }
            pending_cfg_test = false;
            continue;
        }

        if pending_cfg_test {
            pending_cfg_test = false;
        }

        output.push_str(line);
        output.push('\n');
    }

    output
}

fn brace_delta(line: &str) -> i32 {
    let opens = line.chars().filter(|character| *character == '{').count() as i32;
    let closes = line.chars().filter(|character| *character == '}').count() as i32;
    opens - closes
}
