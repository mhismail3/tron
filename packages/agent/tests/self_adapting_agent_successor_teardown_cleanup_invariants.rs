//! Static gates for the Self-Adapting Agent Successor Teardown Cleanup scorecard.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::Command;

const BASELINE_COMMIT: &str = "b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7";
const INTEGRATION_HEAD: &str = "9e8ccb1cf129ba8ef1dc14d9050e84da5ee7e3b3";
const BRANCH_NAME: &str = "codex/self-adapting-agent-successor-teardown-cleanup";
const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup_invariants.rs";
const INVENTORY_HEADER: &str = "id\tchange\tpath\tclassification\towner\taction\trationale";

#[derive(Debug)]
struct ScorecardRow {
    row: String,
    weight: u32,
    status: String,
}

#[derive(Debug, Clone)]
struct InventoryRow {
    id: String,
    change: String,
    path: String,
    classification: String,
    owner: String,
    action: String,
    rationale: String,
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn git_output(args: &[&str]) -> String {
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

fn git_ls_files() -> BTreeSet<String> {
    git_output(&["ls-files"])
        .lines()
        .map(str::to_owned)
        .collect()
}

fn changed_paths_since_baseline() -> BTreeMap<String, String> {
    git_output(&["diff", "--name-status", &format!("{BASELINE_COMMIT}..HEAD")])
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

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
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

fn parse_inventory() -> Vec<InventoryRow> {
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

#[test]
fn saastc_harness_docs_readme_and_ci_are_wired() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");
    let local_ci = read_repo_file("scripts/tron.d/quality.sh");
    let github_ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Scorecard",
        "Status: **phase1_inventory_complete**",
        "Current score: **15/100**",
        "Passing threshold: **100/100**",
        BRANCH_NAME,
        BASELINE_COMMIT,
        INTEGRATION_HEAD,
        INVARIANT_TEST_PATH,
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Evidence Manifest",
        "Status: **phase1_inventory_complete**",
        "| SAASTC-0 | passed_after_fix |",
        "| SAASTC-1 | passed_after_fix |",
        "git diff --name-status b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7..HEAD",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Inventory",
        "`retained`",
        "`simplify`",
        "`remove`",
        "`docs-only`",
        "`predecessor-bookkeeping`",
    ] {
        assert!(inventory.contains(required), "inventory missing {required}");
    }
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
        "self_adapting_agent_successor_teardown_cleanup_invariants",
    ] {
        assert!(readme.contains(required), "README missing {required}");
    }
    for source in [local_ci, github_ci] {
        assert!(
            source.contains("self_adapting_agent_successor_teardown_cleanup_invariants"),
            "closeout CI must include SAASTC invariant target"
        );
    }
}

#[test]
fn saastc_scorecard_weights_statuses_and_current_score_are_consistent() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAASTC scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|row| row.weight).sum::<u32>(),
        100,
        "SAASTC row weights must sum to 100"
    );

    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.weight)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "current score must equal closed SAASTC row weights"
    );

    for required in ["SAASTC-0", "SAASTC-1"] {
        let row = rows
            .iter()
            .find(|row| row.row == required)
            .unwrap_or_else(|| panic!("missing scorecard row {required}"));
        assert_eq!(
            row.status, "passed_after_fix",
            "{required} should be closed by Phase 1"
        );
    }
    for row in rows
        .iter()
        .filter(|row| row.row != "SAASTC-0" && row.row != "SAASTC-1")
    {
        assert_eq!(
            row.status, "pending_source_teardown",
            "{} must remain pending until source teardown proves it",
            row.row
        );
    }
}

#[test]
fn saastc_inventory_covers_every_changed_file_since_oda_baseline() {
    let rows = parse_inventory();
    assert!(
        rows.len() >= 147,
        "Phase 1 inventory should cover the 142 integration files plus cleanup harness files"
    );

    let tracked = git_ls_files();
    let changed = changed_paths_since_baseline();
    let allowed_classifications = BTreeSet::from([
        "retained",
        "simplify",
        "remove",
        "docs-only",
        "predecessor-bookkeeping",
    ]);
    let mut ids = BTreeSet::new();
    let mut by_path = BTreeMap::new();

    for row in rows {
        assert!(
            ids.insert(row.id.clone()),
            "duplicate inventory id {}",
            row.id
        );
        assert!(
            row.id.starts_with("SAASTC-INV-"),
            "inventory id must use SAASTC prefix: {}",
            row.id
        );
        assert!(
            matches!(
                row.change.as_str(),
                "A" | "M" | "D" | "C" | "T" | "U" | "X" | "B"
            ) || row.change.starts_with('R'),
            "{} has unexpected git change marker {}",
            row.id,
            row.change
        );
        assert!(
            allowed_classifications.contains(row.classification.as_str()),
            "{} has invalid classification {}",
            row.id,
            row.classification
        );
        for (field, value) in [
            ("owner", row.owner.as_str()),
            ("action", row.action.as_str()),
            ("rationale", row.rationale.as_str()),
        ] {
            assert!(
                !value.trim().is_empty()
                    && !value.contains("TBD")
                    && !value.contains("TODO")
                    && !value.contains("unclassified"),
                "{} has invalid {} field: {}",
                row.id,
                field,
                value
            );
        }
        assert!(
            changed.contains_key(&row.path)
                || tracked.contains(&row.path)
                || repo_path(&row.path).exists(),
            "{} path must be in the baseline diff, tracked, or present: {}",
            row.id,
            row.path
        );
        assert!(
            by_path.insert(row.path.clone(), row.id.clone()).is_none(),
            "inventory has duplicate path {}",
            row.path
        );
    }

    for path in changed.keys() {
        assert!(
            by_path.contains_key(path),
            "inventory missing changed file from ODA baseline diff: {path}"
        );
    }
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            by_path.contains_key(path),
            "inventory missing cleanup harness file: {path}"
        );
    }
}

#[test]
fn saastc_phase1_records_hard_cleanup_boundaries() {
    let joined = format!(
        "{}\n{}\n{}",
        read_repo_file(SCORECARD_PATH),
        read_repo_file(EVIDENCE_PATH),
        read_repo_file(INVENTORY_PATH)
    );
    for required in [
        "Do not add provider-visible tools",
        "Do not add public `/engine` surfaces",
        "Do not reintroduce repo-managed first-party skills",
        "No source retention decision is final until SAASTC-2 through SAASTC-8",
    ] {
        assert!(
            joined.contains(required),
            "SAASTC docs must record cleanup boundary: {required}"
        );
    }
}
