use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::Command;

pub(crate) const BASELINE_COMMIT: &str = "b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7";
pub(crate) const INTEGRATION_HEAD: &str = "9e8ccb1cf129ba8ef1dc14d9050e84da5ee7e3b3";
pub(crate) const BRANCH_NAME: &str = "codex/self-adapting-agent-successor-teardown-cleanup";
pub(crate) const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-scorecard.md";
pub(crate) const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-evidence-manifest.md";
pub(crate) const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-inventory.md";
pub(crate) const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-inventory.tsv";
pub(crate) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup_invariants.rs";
pub(crate) const INVENTORY_HEADER: &str =
    "id\tchange\tpath\tclassification\towner\taction\trationale";

#[derive(Debug)]
pub(crate) struct ScorecardRow {
    pub(crate) row: String,
    pub(crate) weight: u32,
    pub(crate) status: String,
}

#[derive(Debug, Clone)]
pub(crate) struct InventoryRow {
    pub(crate) id: String,
    pub(crate) change: String,
    pub(crate) path: String,
    pub(crate) classification: String,
    pub(crate) owner: String,
    pub(crate) action: String,
    pub(crate) rationale: String,
}

pub(crate) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

pub(crate) fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

pub(crate) fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

pub(crate) fn git_output(args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo_root())
        .output()
        .unwrap_or_else(|error| panic!("git command failed to start: {args:?}: {error}"));
    assert!(
        output.status.success(),
        "git command failed: {:?}\nstdout:\n{}\nstderr:\n{}",
        args,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("git output should be UTF-8")
}

pub(crate) fn git_ls_files() -> BTreeSet<String> {
    git_output(&["ls-files"])
        .lines()
        .map(str::to_owned)
        .collect()
}

pub(crate) fn changed_paths_since_baseline() -> BTreeMap<String, String> {
    git_output(&["diff", "--name-status", BASELINE_COMMIT])
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let columns: Vec<_> = line.split('\t').collect();
            let change = columns
                .first()
                .expect("git diff --name-status must emit a status")
                .to_string();
            let path = columns
                .last()
                .expect("git diff --name-status must emit a path")
                .to_string();
            (path, change)
        })
        .collect()
}

pub(crate) fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SAASTC-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            assert!(
                columns.len() >= 5,
                "scorecard row must have at least 5 columns: {line}"
            );
            ScorecardRow {
                row: columns[1].to_owned(),
                weight: columns[3]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid score in {line}: {error}")),
                status: columns[4].to_owned(),
            }
        })
        .collect()
}

pub(crate) fn parse_inventory() -> Vec<InventoryRow> {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = inventory.lines();
    assert_eq!(
        lines.next().expect("inventory TSV must have a header"),
        INVENTORY_HEADER
    );

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                7,
                "inventory row {} must have 7 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                id: columns[0].to_owned(),
                change: columns[1].to_owned(),
                path: columns[2].to_owned(),
                classification: columns[3].to_owned(),
                owner: columns[4].to_owned(),
                action: columns[5].to_owned(),
                rationale: columns[6].to_owned(),
            }
        })
        .collect()
}
