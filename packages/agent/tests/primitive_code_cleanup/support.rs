//! Static gates for the whole-repo primitive code cleanup campaign.

pub(super) use std::collections::{HashMap, HashSet};
pub(super) use std::path::Path;
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

pub(super) fn git_ls_files() -> Vec<String> {
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

pub(super) fn line_count(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
        .lines()
        .count()
}

pub(super) fn collect_text_files(path: &Path, files: &mut Vec<PathBuf>) {
    if path.is_file() {
        if matches!(
            path.extension().and_then(|extension| extension.to_str()),
            Some("md" | "rs" | "swift")
        ) {
            files.push(path.to_path_buf());
        }
        return;
    }

    let Ok(entries) = std::fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        collect_text_files(&entry.path(), files);
    }
}

pub(super) fn is_static_or_evidence_path(path: &str) -> bool {
    path.contains("scorecard")
        || path.contains("evidence")
        || path.contains("inventory")
        || path.ends_with("primitive_engine_teardown_plan_invariants.rs")
        || path.ends_with("primitive_code_cleanup_invariants.rs")
        || path.contains("packages/agent/tests/primitive_engine_teardown/")
        || path.contains("packages/agent/tests/primitive_code_cleanup/")
        || path.contains("packages/agent/tests/hierarchical_rearchitecture/")
        || path.ends_with("SourceGuardTests.swift")
}
