//! Static and source-backed invariants for the Baseline Pre-Restoration Closure
//! goal.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str = "packages/agent/docs/baseline-pre-restoration-closure-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/baseline-pre-restoration-closure-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/baseline-pre-restoration-closure-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/baseline-pre-restoration-closure-inventory.tsv";
const FEATURE_INDEX_PATH: &str =
    "packages/agent/docs/primitive-baseline-vs-modular-capability-engine-feature-index.md";
const TARGET_PATH: &str = "packages/agent/tests/baseline_pre_restoration_closure_invariants.rs";
const TARGET_NAME: &str = "baseline_pre_restoration_closure_invariants";
const BASE_COMMIT: &str = "1545da37d3c6186fbc6613789bae3d4a5481f976";

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

fn tracked_present_or_reference(path: &str) -> bool {
    path == BASE_COMMIT
        || path.starts_with("https://")
        || repo_path(path).exists()
        || git_ls_files().contains(path)
}

fn assert_current_lineage_base() {
    let status = Command::new("git")
        .args(["merge-base", "--is-ancestor", BASE_COMMIT, "HEAD"])
        .current_dir(repo_root())
        .status()
        .expect("git merge-base should run");
    assert!(
        status.success(),
        "HEAD must descend from BPRC baseline {BASE_COMMIT}"
    );
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| BPRC-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "BPRC scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid BPRC weight in {line}: {error}")),
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
            "id\trecord_type\tpath_or_feature\tsurface_kind\towner\tclassification\tcurrent_state\trequired_before_restoration\tserver_impact\tios_impact\tproof\tregression_gate\tscorecard_rows"
        ),
        "BPRC inventory TSV header changed"
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
fn bprc_artifacts_lineage_and_readme_wiring_exist() {
    assert_current_lineage_base();
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        FEATURE_INDEX_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing BPRC artifact: {path}");
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "Total weight: **100**",
        "codex/baseline-pre-restoration-closure-current",
        BASE_COMMIT,
        "iii-hq/iii",
        "worker/function/trigger",
        "Scope quarantine",
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }

    let readme = read_repo_file("README.md");
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        TARGET_NAME,
        "Worker / Function / Trigger",
        "pre-restoration entry contract",
    ] {
        assert!(
            readme.contains(required),
            "README must mention BPRC artifact, target, or contract: {required}"
        );
    }
}

#[test]
fn bprc_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        (
            "BPRC-0",
            ("Baseline lineage, branch, and scope quarantine", 5_u32),
        ),
        ("BPRC-1", ("Active-doc truth cleanup", 10)),
        (
            "BPRC-2",
            ("Feature-index conversion into restoration backlog", 10),
        ),
        ("BPRC-3", ("Successor-feature absence guards", 10)),
        ("BPRC-4", ("Baseline residue and dead-surface audit", 10)),
        ("BPRC-5", ("Engine substrate readiness statement", 8)),
        ("BPRC-6", ("iOS baseline parity and UX readiness audit", 10)),
        ("BPRC-7", ("Static-gate and CI parity", 8)),
        ("BPRC-8", ("Artifact inventory and provenance integrity", 8)),
        ("BPRC-9", ("Pre-restoration entry contract", 9)),
        ("BPRC-10", ("Broad validation and frozen handoff", 12)),
    ]);
    assert_eq!(rows.len(), expected.len(), "BPRC must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected BPRC row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "BPRC scorecard weights must sum to 100");
}

#[test]
fn bprc_inventory_is_structured_and_covers_backlog_and_artifacts() {
    let rows = parse_inventory_rows();
    assert!(rows.len() >= 42, "BPRC inventory row count regressed");
    let allowed_record_types = BTreeSet::from([
        "artifact",
        "baseline_reference",
        "substrate",
        "restoration_backlog",
        "entry_contract",
    ]);
    let allowed_classifications = BTreeSet::from([
        "active_current",
        "source_truth",
        "external_reference",
        "future_restoration",
        "static_gate",
        "scope_boundary",
    ]);
    let mut ids = BTreeSet::new();
    let mut by_id = BTreeMap::new();
    let mut covered_scorecard_rows = BTreeSet::new();
    for row in &rows {
        assert_eq!(row.len(), 13, "BPRC row must have 13 fields: {row:?}");
        assert!(ids.insert(row[0].clone()), "duplicate BPRC id {}", row[0]);
        assert!(
            allowed_record_types.contains(row[1].as_str()),
            "{} has unknown record_type {}",
            row[0],
            row[1]
        );
        assert!(
            allowed_classifications.contains(row[5].as_str()),
            "{} has unknown classification {}",
            row[0],
            row[5]
        );
        assert!(
            tracked_present_or_reference(&row[2]) || row[1] == "restoration_backlog",
            "BPRC inventory path/reference must be tracked, present, URL, commit, or backlog: {}",
            row[2]
        );
        for field in row {
            let lower = field.to_ascii_lowercase();
            assert!(
                !field.trim().is_empty()
                    && !field.contains("TODO")
                    && !field.contains("TBD")
                    && !lower.contains("placeholder")
                    && !lower.contains("pending")
                    && !lower.contains("unclassified")
                    && !lower.contains("recorded later")
                    && !lower.contains("to be recorded")
                    && !lower.contains("will be recorded"),
                "invalid BPRC inventory field in row {:?}",
                row
            );
        }
        for scorecard_row in row[12].split(',') {
            covered_scorecard_rows.insert(scorecard_row.to_owned());
        }
        by_id.insert(row[0].clone(), row.clone());
    }

    for row_id in 0..=10 {
        assert!(
            covered_scorecard_rows.contains(&format!("BPRC-{row_id}")),
            "BPRC inventory does not cover BPRC-{row_id}"
        );
    }
    for feature_id in 1..=24 {
        let id = format!("BPRC-FEATURE-{feature_id:02}");
        let row = by_id
            .get(&id)
            .unwrap_or_else(|| panic!("missing restoration backlog row {id}"));
        assert_eq!(row[1], "restoration_backlog");
        assert_eq!(row[5], "future_restoration");
        assert_eq!(row[6], "not_in_baseline");
        assert!(
            row[7].contains("policy")
                || row[7].contains("contract")
                || row[7].contains("worker")
                || row[7].contains("schema")
                || row[7].contains("authority")
                || row[7].contains("resource")
                || row[7].contains("evidence")
                || row[7].contains("protocol")
                || row[7].contains("migration"),
            "{id} must state concrete pre-restoration requirements"
        );
    }
    for required_id in [
        "BPRC-INV-001",
        "BPRC-INV-002",
        "BPRC-INV-003",
        "BPRC-INV-004",
        "BPRC-INV-005",
        "BPRC-INV-006",
        "BPRC-INV-007",
        "BPRC-INV-008",
        "BPRC-INV-009",
        "BPRC-INV-010",
        "BPRC-INV-011",
        "BPRC-INV-012",
        "BPRC-INV-016",
        "BPRC-INV-017",
        "BPRC-INV-018",
    ] {
        assert!(by_id.contains_key(required_id), "missing {required_id}");
    }
}

#[test]
fn old_product_surfaces_and_fixed_ios_panels_remain_absent() {
    let domain_root = repo_path("packages/agent/src/domains");
    for forbidden in [
        "browser",
        "context",
        "cron",
        "device",
        "display",
        "events",
        "filesystem",
        "git",
        "import",
        "job",
        "mcp",
        "memory",
        "notifications",
        "plan",
        "process",
        "program",
        "prompt_library",
        "repo",
        "sandbox",
        "self_extension",
        "skills",
        "transcription",
        "tree",
        "voice_notes",
        "web",
        "worktree",
    ] {
        assert!(
            !domain_root.join(forbidden).exists(),
            "old product domain was restored in baseline: {forbidden}"
        );
    }
    assert!(
        !repo_path("packages/agent/skills").exists(),
        "repo-managed first-party skills must remain absent"
    );
    let retired_panel_roots: Vec<String> = [
        ("Agent", "Control"),
        ("Audit", "Details"),
        ("Engine", "Approval"),
        ("Prompt", "Library"),
        ("Session", "Tree"),
        ("Source", "Changes"),
        ("User", "Interaction"),
        ("Voice", "Notes"),
    ]
    .into_iter()
    .map(|(prefix, suffix)| format!("{prefix}{suffix}"))
    .chain(
        ["Notifications", "Process", "Skills", "Subagents", "Work"]
            .into_iter()
            .map(str::to_owned),
    )
    .collect();
    for forbidden in retired_panel_roots {
        assert!(
            !repo_path("packages/ios-app/Sources/UI")
                .join(&forbidden)
                .exists()
                && !repo_path("packages/ios-app/Sources/Views")
                    .join(&forbidden)
                    .exists(),
            "fixed iOS product panel root was restored in baseline: {forbidden}"
        );
    }
}

#[test]
fn worker_function_trigger_alignment_and_provider_minimality_hold() {
    let engine_mod = read_repo_file("packages/agent/src/engine/mod.rs");
    for required in [
        "workers own the functions and triggers they register",
        "canonical engine function",
        "EngineExternalWorkerRuntime",
        "TriggerDispatchRequest",
        "WorkerProtocolMessage",
    ] {
        assert!(
            engine_mod.contains(required),
            "engine docs/exports must retain worker/function/trigger substrate: {required}"
        );
    }

    let capability_contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    assert_eq!(
        capability_contract
            .matches("CapabilityContract::new(")
            .count(),
        1,
        "provider-visible capability contract count must remain one"
    );
    assert!(
        capability_contract.contains("\"capability::execute\""),
        "single provider-visible contract must remain capability::execute"
    );
    for forbidden in ["capability::search", "capability::inspect", "\"intent\""] {
        assert!(
            !capability_contract.contains(forbidden),
            "provider-facing execute contract widened before restoration: {forbidden}"
        );
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    for required in [
        "worker/function/trigger",
        "everything is a worker",
        "not as a hardcoded harness feature",
    ] {
        assert!(
            scorecard.contains(required) || inventory.contains(required),
            "BPRC artifacts must record iii-style alignment: {required}"
        );
    }
}

#[test]
fn active_docs_state_current_baseline_not_in_progress_teardown() {
    let readme = read_repo_file("README.md");
    assert!(
        readme.contains("current primitive baseline"),
        "README must describe current primitive baseline"
    );
    assert!(
        !readme.contains("On the primitive teardown branch"),
        "README intro must not present teardown as the active branch state"
    );
    let ios_arch = read_repo_file("packages/ios-app/docs/architecture.md");
    assert!(
        ios_arch.contains("current primitive baseline"),
        "iOS architecture docs must describe current primitive baseline"
    );
    assert!(
        !ios_arch.contains("On the primitive teardown branch"),
        "iOS architecture docs must not present teardown as active branch state"
    );
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
        "BPRC target must be in the closeout set"
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
    let pmc_index = local_targets
        .iter()
        .position(|target| target == "primitive_minimality_closure_invariants")
        .expect("PMC target should be present");
    let bprc_index = local_targets
        .iter()
        .position(|target| target == TARGET_NAME)
        .expect("BPRC target should be present");
    let primitive_trace_index = local_targets
        .iter()
        .position(|target| target == "primitive_trace_execution")
        .expect("primitive trace target should be present");
    assert!(
        pmc_index < bprc_index && bprc_index < primitive_trace_index,
        "BPRC must run after PMC and before primitive trace/integration closeout targets"
    );
}

#[test]
fn evidence_manifest_records_required_commands_without_placeholders() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row_id in 0..=10 {
        assert!(
            evidence.contains(&format!("BPRC-{row_id}")),
            "BPRC evidence manifest must cover BPRC-{row_id}"
        );
    }
    for command in [
        "cargo test --manifest-path packages/agent/Cargo.toml --test baseline_pre_restoration_closure_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_minimality_closure_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "BPRC evidence manifest missing command: {command}"
        );
    }
    for forbidden in [
        "TODO",
        "TBD",
        "placeholder",
        "pending",
        "current_gap",
        "recorded later",
        "to be recorded",
        "will be recorded",
        "not run",
    ] {
        assert!(
            !evidence.contains(forbidden),
            "BPRC evidence must not contain placeholder language: {forbidden}"
        );
    }
}
