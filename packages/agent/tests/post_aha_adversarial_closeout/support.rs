//! Static gates for the post-AHA adversarial closeout campaign.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/post-aha-adversarial-closeout-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/post-aha-adversarial-closeout-evidence-manifest.md";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/post_aha_adversarial_closeout_invariants.rs";

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

pub(super) fn markdown_code_spans(text: &str) -> BTreeSet<String> {
    text.split('`')
        .skip(1)
        .step_by(2)
        .map(str::to_owned)
        .collect()
}

pub(super) fn create_table_names(text: &str) -> BTreeSet<String> {
    text.lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            let rest = trimmed.strip_prefix("CREATE TABLE IF NOT EXISTS ")?;
            let name = rest
                .split(|ch: char| ch == '(' || ch.is_whitespace())
                .next()
                .unwrap_or_default()
                .trim_matches('"');
            (!name.is_empty()).then(|| name.to_owned())
        })
        .collect()
}
