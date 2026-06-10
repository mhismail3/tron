use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/observability-diagnostics-auditability-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/observability-diagnostics-auditability-evidence-manifest.md";
pub(super) const INVENTORY_PATH: &str =
    "packages/agent/docs/observability-diagnostics-auditability-inventory.md";
pub(super) const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/observability-diagnostics-auditability-inventory.tsv";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/observability_diagnostics_auditability_invariants.rs";

pub(super) const INVENTORY_HEADER: &str = "path\tlanguage\tsurface\tobserved_signal\tcorrelation_ids\tredaction_boundary\tretention_or_query_behavior\tproof_target\toda_rows";

#[derive(Debug, Clone)]
pub(super) struct InventoryRow {
    pub(super) path: String,
    pub(super) language: String,
    pub(super) surface: String,
    pub(super) observed_signal: String,
    pub(super) correlation_ids: String,
    pub(super) redaction_boundary: String,
    pub(super) retention_or_query_behavior: String,
    pub(super) proof_target: String,
    pub(super) oda_rows: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ScorecardRow {
    pub(super) row: String,
    pub(super) points: u32,
    pub(super) status: String,
}

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
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

pub(super) fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| ODA-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            assert!(
                columns.len() >= 5,
                "scorecard row must have at least 5 columns: {line}"
            );
            ScorecardRow {
                row: columns[1].to_owned(),
                points: columns[3]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid ODA score in {line}: {error}")),
                status: columns[4].to_owned(),
            }
        })
        .collect()
}

pub(super) fn parse_inventory() -> Vec<InventoryRow> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    let header = lines.next().expect("inventory TSV must have a header");
    assert_eq!(header, INVENTORY_HEADER, "ODA inventory TSV header changed");

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                9,
                "inventory row {} must have 9 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                path: columns[0].to_owned(),
                language: columns[1].to_owned(),
                surface: columns[2].to_owned(),
                observed_signal: columns[3].to_owned(),
                correlation_ids: columns[4].to_owned(),
                redaction_boundary: columns[5].to_owned(),
                retention_or_query_behavior: columns[6].to_owned(),
                proof_target: columns[7].to_owned(),
                oda_rows: columns[8].to_owned(),
            }
        })
        .collect()
}

pub(super) fn inventory_by_path() -> BTreeMap<String, InventoryRow> {
    parse_inventory()
        .into_iter()
        .map(|row| (row.path.clone(), row))
        .collect()
}
