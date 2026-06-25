//! Static and source-backed invariants for the Self-Updating Worker Runtime
//! Foundation goal.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-updating-worker-runtime-foundation-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-updating-worker-runtime-foundation-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-updating-worker-runtime-foundation-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-updating-worker-runtime-foundation-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/self_updating_worker_runtime_foundation_invariants.rs";
const TARGET_NAME: &str = "self_updating_worker_runtime_foundation_invariants";
const BASELINE_COMMIT: &str = "4cb2387f1a872f9fabaf58bdd88330065113b914";

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

fn read_repo_files(paths: &[&str]) -> String {
    paths
        .iter()
        .map(|path| read_repo_file(path))
        .collect::<Vec<_>>()
        .join("\n")
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

fn assert_current_lineage_base() {
    let status = Command::new("git")
        .args(["merge-base", "--is-ancestor", BASELINE_COMMIT, "HEAD"])
        .current_dir(repo_root())
        .status()
        .expect("git merge-base should run");
    assert!(
        status.success(),
        "HEAD must descend from SUWRF baseline {BASELINE_COMMIT}"
    );
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SUWRF-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "SUWRF scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid SUWRF weight in {line}: {error}")),
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
            "id\trecord_type\tpath_or_surface\towner\tclassification\tcurrent_state\tproof\tregression_gate\tscorecard_rows"
        ),
        "SUWRF inventory TSV header changed"
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

#[test]
fn scorecard_artifacts_and_lineage_are_current() {
    assert_current_lineage_base();
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing SUWRF artifact: {path}");
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "Total weight: **100**",
        "codex/self-updating-worker-runtime-foundation-current",
        BASELINE_COMMIT,
        "BPRC-FEATURE-06",
        "Scope quarantine",
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
}

#[test]
fn scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        ("SUWRF-0", ("Baseline and scope", 5_u32)),
        ("SUWRF-1", ("Lifecycle ownership", 10)),
        ("SUWRF-2", ("Manifest contract", 10)),
        ("SUWRF-3", ("Authority and grants", 10)),
        ("SUWRF-4", ("Launch isolation", 10)),
        ("SUWRF-5", ("Conformance gate", 10)),
        ("SUWRF-6", ("Resource/event evidence", 10)),
        ("SUWRF-7", ("Rollback/failure semantics", 8)),
        ("SUWRF-8", ("Generic iOS visibility", 7)),
        ("SUWRF-9", ("Static gates", 10)),
        ("SUWRF-10", ("Docs/evidence/closeout", 10)),
    ]);
    assert_eq!(rows.len(), expected.len(), "SUWRF must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected SUWRF row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "SUWRF weights must sum to 100");
}

#[test]
fn inventory_covers_sources_resources_boundaries_and_validation() {
    let rows = parse_inventory_rows();
    let ids = rows
        .iter()
        .map(|row| row[0].as_str())
        .collect::<BTreeSet<_>>();
    for required in [
        "SUWRF-ARTIFACT-01",
        "SUWRF-ARTIFACT-02",
        "SUWRF-ARTIFACT-03",
        "SUWRF-ARTIFACT-04",
        "SUWRF-SOURCE-01",
        "SUWRF-SOURCE-02",
        "SUWRF-SOURCE-03",
        "SUWRF-SOURCE-04",
        "SUWRF-RESOURCE-01",
        "SUWRF-RESOURCE-02",
        "SUWRF-RESOURCE-03",
        "SUWRF-RESOURCE-04",
        "SUWRF-RESOURCE-05",
        "SUWRF-BOUNDARY-01",
        "SUWRF-BOUNDARY-02",
        "SUWRF-BOUNDARY-03",
        "SUWRF-BOUNDARY-04",
        "SUWRF-VALIDATION-01",
        "SUWRF-VALIDATION-02",
    ] {
        assert!(ids.contains(required), "inventory missing {required}");
    }
    for row in &rows {
        assert_eq!(row.len(), 9, "inventory row must have 9 columns: {row:?}");
        for cell in row {
            assert!(!cell.trim().is_empty(), "inventory cells must not be empty");
        }
    }
}

#[test]
fn worker_lifecycle_owns_package_launch_separate_from_worker_protocol() {
    let lifecycle = read_repo_files(&[
        "packages/agent/src/domains/worker_lifecycle/mod.rs",
        "packages/agent/src/domains/worker_lifecycle/authority.rs",
        "packages/agent/src/domains/worker_lifecycle/contract.rs",
        "packages/agent/src/domains/worker_lifecycle/handlers.rs",
        "packages/agent/src/domains/worker_lifecycle/launcher.rs",
        "packages/agent/src/domains/worker_lifecycle/manifest.rs",
        "packages/agent/src/domains/worker_lifecycle/resources.rs",
    ]);
    for required in [
        "tron.worker_package.v1",
        "propose_package_change",
        "install_package",
        "enable_package",
        "disable_package",
        "launch_worker",
        "stop_worker",
        "retire_package",
        "env_clear",
        "TRON_WORKER_ENDPOINT",
        "TRON_WORKER_TOKEN_JSON",
        "worker_package_conformance_report",
        "worker lifecycle changes require a derived non-bootstrap grant",
        "rollbackPolicy.onFailure",
    ] {
        assert!(
            lifecycle.contains(required),
            "worker_lifecycle source missing required lifecycle surface: {required}"
        );
    }

    let external_workers =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/mod.rs");
    for forbidden in [
        "worker_package",
        "launchCommand",
        "TRON_WORKER_TOKEN_JSON",
        "Command::new",
        "tokio::process",
    ] {
        assert!(
            !external_workers.contains(forbidden),
            "/engine/workers protocol host must not own package lifecycle or launch policy: {forbidden}"
        );
    }
}

#[test]
fn resource_kinds_and_package_root_are_declared_once() {
    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    for kind in [
        "worker_package",
        "worker_package_installation",
        "worker_package_proposal",
        "worker_package_conformance_report",
        "worker_launch_attempt",
    ] {
        assert!(
            definitions.contains(kind),
            "built-in resource definitions missing {kind}"
        );
    }
    let paths = read_repo_file("packages/agent/src/shared/foundation/paths/mod.rs");
    assert!(
        paths.contains("pub const WORKERS: &str = \"workers\"")
            && paths.contains("pub fn worker_packages_dir()"),
        "paths must define the approved worker package root"
    );
}

#[test]
fn no_provider_tool_sprawl_fixed_panels_or_removed_feature_buckets() {
    assert!(
        !repo_path("packages/agent/skills").exists(),
        "repo-managed first-party skills must remain absent"
    );
    for forbidden in [
        "packages/ios-app/Sources/UI/Skills",
        "packages/ios-app/Sources/UI/MCP",
        "packages/ios-app/Sources/UI/Workers",
        "packages/ios-app/Sources/UI/Scheduler",
        "packages/ios-app/Sources/UI/Memory",
        "packages/agent/src/domains/mcp",
        "packages/agent/src/domains/skills",
        "packages/agent/src/domains/program_execution",
    ] {
        assert!(
            !repo_path(forbidden).exists(),
            "SUWRF must not restore fixed/product surface {forbidden}"
        );
    }
    let scheduler_root = repo_path("packages/agent/src/domains/scheduler");
    if scheduler_root.exists() {
        let phase_two_inventory =
            read_repo_file("packages/agent/docs/phase-2-agent-execution-restoration-inventory.tsv");
        assert!(
            phase_two_inventory
                .contains("P2AER-INV-028\tscheduling reminders automations background work")
                && phase_two_inventory.contains("Accepted Slice 12")
                && phase_two_inventory.contains("current_baseline\tBPRC-FEATURE-17"),
            "domains/scheduler is allowed only as the narrow accepted Slice 12 foundation"
        );
    }
    let memory_root = repo_path("packages/agent/src/domains/memory");
    if memory_root.exists() {
        let phase_two_inventory =
            read_repo_file("packages/agent/docs/phase-2-agent-execution-restoration-inventory.tsv");
        assert!(
            phase_two_inventory.contains("P2AER-INV-014\tmemory core contract")
                && phase_two_inventory
                    .contains("current_baseline\tBPRC-FEATURE-10\tIARM-SURFACE-034"),
            "domains/memory is allowed only as the P2AER-tracked Slice 3 foundation"
        );
        for forbidden in [
            "semantic",
            "vector",
            "embedding",
            "embeddings",
            "hooks",
            "procedural",
            "rules",
            "skills",
        ] {
            assert!(
                !memory_root.join(forbidden).exists()
                    && !memory_root.join(format!("{forbidden}.rs")).exists(),
                "SUWRF must not restore old memory engine/runtime surface: {forbidden}"
            );
        }
    }
    let readme = read_repo_file("README.md");
    assert!(
        readme.contains("provider-visible model tool remains `execute`"),
        "README must state provider-visible execute minimality after SUWRF"
    );
}

#[test]
fn readme_and_evidence_record_current_behavior_and_commands() {
    let readme = read_repo_file("README.md");
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        TARGET_NAME,
        "worker_lifecycle",
        "worker_package",
        "workspace/workers",
        "Self-Updating Worker Runtime Foundation",
    ] {
        assert!(readme.contains(required), "README missing {required}");
    }
    let evidence = read_repo_file(EVIDENCE_PATH);
    for required in [
        "SUWRF-0",
        "SUWRF-1",
        "SUWRF-2",
        "SUWRF-3",
        "SUWRF-4",
        "SUWRF-5",
        "SUWRF-6",
        "SUWRF-7",
        "SUWRF-8",
        "SUWRF-9",
        "SUWRF-10",
        "cargo test --manifest-path packages/agent/Cargo.toml worker_lifecycle -- --quiet",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
}

#[test]
fn static_gate_wiring_matches_local_and_github_closeout_order() {
    let local_targets = parse_quality_closeout_targets();
    let github_targets = parse_github_static_gate_targets();
    assert_eq!(
        local_targets, github_targets,
        "scripts/tron ci test and GitHub rust-static-gates must run the same closeout target set in the same order"
    );
    assert!(
        local_targets.contains(&TARGET_NAME.to_owned()),
        "SUWRF target must be in the closeout set"
    );
    let unique: BTreeSet<_> = local_targets.iter().collect();
    assert_eq!(
        unique.len(),
        local_targets.len(),
        "closeout target set must not contain duplicates"
    );
    assert_eq!(
        local_targets.last().map(String::as_str),
        Some("integration"),
        "serial integration target must remain last"
    );
    let bprc_index = local_targets
        .iter()
        .position(|target| target == "baseline_pre_restoration_closure_invariants")
        .expect("BPRC target should be present");
    let suwrf_index = local_targets
        .iter()
        .position(|target| target == TARGET_NAME)
        .expect("SUWRF target should be present");
    let primitive_trace_index = local_targets
        .iter()
        .position(|target| target == "primitive_trace_execution")
        .expect("primitive trace target should be present");
    assert!(
        bprc_index < suwrf_index && suwrf_index < primitive_trace_index,
        "SUWRF must run after BPRC and before primitive trace/integration closeout targets"
    );
}

#[test]
fn tracked_artifact_paths_exist() {
    let tracked = git_output(&["ls-files"])
        .lines()
        .map(str::to_owned)
        .collect::<BTreeSet<_>>();
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        "packages/agent/src/domains/worker_lifecycle/mod.rs",
    ] {
        assert!(
            repo_path(path).exists() || tracked.contains(path),
            "tracked SUWRF path missing: {path}"
        );
    }
}
