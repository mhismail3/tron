//! Static and source-backed invariants for the Self-Sufficient Agent Runtime
//! Readiness slice.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-sufficient-agent-runtime-readiness-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-sufficient-agent-runtime-readiness-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/self_sufficient_agent_runtime_readiness_invariants.rs";
const TARGET_NAME: &str = "self_sufficient_agent_runtime_readiness_invariants";
const BASE_COMMIT: &str = "98b9a7eeb62afb9a844ffd7dd6cd8f591aab6de6";
const STALE_BRANCH: &str = "codex/self-sufficient-agent-runtime-readiness";
const STALE_BRANCH_HEAD: &str = "e62804694fa6578758d4f7e7c6cf12f334a13853";

#[path = "self_sufficient_agent_runtime_readiness_invariants/successor_guards.rs"]
mod successor_guards;

#[derive(Debug)]
struct ScorecardRow {
    id: String,
    name: String,
    weight: u32,
    status: String,
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
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

fn read_repo_file_if_utf8(path: &str) -> Option<String> {
    let full_path = repo_path(path);
    let bytes = std::fs::read(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()));
    String::from_utf8(bytes).ok()
}

fn git_output(args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo_root())
        .output()
        .unwrap_or_else(|error| panic!("git {args:?} failed to start: {error}"));
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
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

fn tracked_or_present(path: &str) -> bool {
    repo_path(path).exists() || git_ls_files().contains(path)
}

fn assert_current_lineage_base() {
    let status = Command::new("git")
        .args(["merge-base", "--is-ancestor", BASE_COMMIT, "HEAD"])
        .current_dir(repo_root())
        .status()
        .expect("git merge-base should run");
    assert!(
        status.success(),
        "HEAD must descend from DESI baseline {BASE_COMMIT}"
    );
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SSARR-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "SSARR scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid SSARR weight in {line}: {error}")),
                status: columns[3].to_owned(),
            }
        })
        .collect()
}

fn parse_inventory_rows() -> Vec<Vec<String>> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\treadiness_dimension\tcurrent_extension_point\tfuture_scope\timplementation_state\trisk_or_blocker\tproof\tevidence_policy\tscorecard_rows"
        ),
        "SSARR inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

fn parse_quality_closeout_targets() -> Vec<String> {
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let mut targets = Vec::new();
    let mut in_array = false;
    for line in quality.lines() {
        if line.contains("local closeout_test_targets=(") {
            in_array = true;
            continue;
        }
        if in_array {
            let trimmed = line.trim();
            if trimmed == ")" {
                break;
            }
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            targets.push(trimmed.to_owned());
        }
    }
    assert!(
        !targets.is_empty(),
        "local closeout_test_targets array not found"
    );
    targets
}

fn parse_github_static_gate_targets() -> Vec<String> {
    let ci = read_repo_file(".github/workflows/ci.yml");
    let mut targets = Vec::new();
    let mut in_block = false;
    for line in ci.lines() {
        if line.contains("Run Rust-owned closeout target set") {
            in_block = true;
            continue;
        }
        if in_block && line.trim_start().starts_with("- name:") && !targets.is_empty() {
            break;
        }
        if !in_block {
            continue;
        }
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("cargo test --test ") {
            let target = rest
                .split_whitespace()
                .next()
                .expect("cargo test target should have a name");
            targets.push(target.to_owned());
        }
    }
    assert!(
        !targets.is_empty(),
        "GitHub static-gates target block not found"
    );
    targets
}

fn active_text_files() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| {
            path == "README.md"
                || path == "AGENTS.md"
                || path.starts_with(".github/")
                || path.starts_with("scripts/")
                || path.starts_with("packages/agent/src/")
                || path.starts_with("packages/agent/tests/")
                || path.starts_with("packages/agent/docs/")
                || path.starts_with("packages/ios-app/Sources/")
                || path.starts_with("packages/ios-app/Tests/")
                || path.starts_with("packages/ios-app/docs/")
                || path.starts_with("packages/mac-app/Sources/")
                || path.starts_with("packages/mac-app/Tests/")
                || path.starts_with("packages/mac-app/docs/")
        })
        .filter(|path| {
            matches!(
                Path::new(path).extension().and_then(|ext| ext.to_str()),
                Some("rs" | "swift" | "md" | "tsv" | "sh" | "yml" | "yaml" | "toml")
            ) || matches!(path.as_str(), "README.md" | "AGENTS.md")
        })
        .collect()
}

#[test]
fn predecessor_inventories_classify_ssarr_artifacts() {
    let required_paths = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ];
    for predecessor in [
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/release-install-upgrade-rollback-discipline-inventory.tsv",
        "packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.tsv",
        "packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv",
        "packages/agent/docs/performance-resource-governance-inventory.tsv",
        "packages/agent/docs/provider-model-boundary-discipline-inventory.tsv",
        "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv",
        "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "packages/agent/docs/observability-diagnostics-auditability-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv",
        "packages/agent/docs/state-ownership-lifecycle-inventory.tsv",
        "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
        "packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.tsv",
        "packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.tsv",
    ] {
        let source = read_repo_file(predecessor);
        for required_path in required_paths {
            assert!(
                source.contains(required_path),
                "{predecessor} missing SSARR artifact {required_path}"
            );
        }
    }
}
