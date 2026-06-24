//! Static gates for the post-HRA adversarial hardening campaign.

use std::path::{Path, PathBuf};
use std::process::Command;

pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/post-hra-adversarial-hardening-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/post-hra-adversarial-hardening-evidence-manifest.md";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/post_hra_adversarial_hardening_invariants.rs";

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

pub(super) fn list_tracked_files_with_extension(extension: &str) -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| Path::new(path).extension().and_then(|ext| ext.to_str()) == Some(extension))
        .collect()
}

pub(super) fn source_line_count(path: &str) -> usize {
    read_repo_file(path).lines().count()
}

pub(super) fn assert_no_hits(label: &str, hits: Vec<String>) {
    assert!(hits.is_empty(), "{label}: {hits:#?}");
}

pub(super) fn command_output(command: &mut Command) -> (bool, String) {
    let output = command.output().expect("command should run");
    let mut text = String::new();
    text.push_str(&String::from_utf8_lossy(&output.stdout));
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    (output.status.success(), text)
}
