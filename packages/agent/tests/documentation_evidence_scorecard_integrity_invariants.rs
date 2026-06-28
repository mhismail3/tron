//! Static and source-backed invariants for the Documentation / Evidence /
//! Scorecard Integrity slice.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/documentation-evidence-scorecard-integrity-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/documentation-evidence-scorecard-integrity-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.tsv";
const PHASE_THREE_INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/phase-3-modular-self-adapting-engine-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/documentation_evidence_scorecard_integrity_invariants.rs";
const TARGET_NAME: &str = "documentation_evidence_scorecard_integrity_invariants";
const BASE_COMMIT: &str = "687dc1e1f4b51701452f2ba25c92f34bc018a950";
const STALE_BRANCH_HEAD: &str = "f931c3126a2ee62940f42512278715c9c65c2079";

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

fn tracked_or_present(path: &str) -> bool {
    repo_path(path).exists() || git_ls_files().contains(path)
}

fn parse_desi_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| DESI-"))
        .map(parse_scorecard_row)
        .collect()
}

fn parse_scorecard_row(line: &str) -> ScorecardRow {
    let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
    assert_eq!(
        columns.len(),
        5,
        "scorecard row must have five columns: {line}"
    );
    ScorecardRow {
        id: columns[0].to_owned(),
        name: columns[1].to_owned(),
        weight: columns[2]
            .parse()
            .unwrap_or_else(|error| panic!("invalid scorecard weight in {line}: {error}")),
        status: columns[3].to_owned(),
    }
}

fn parse_inventory_rows() -> Vec<Vec<String>> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tclassification\tproof\tevidence_policy\tscorecard_rows"
        ),
        "DESI inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

fn parse_phase_three_inventory_rows() -> Vec<BTreeMap<String, String>> {
    let tsv = read_repo_file(PHASE_THREE_INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    let header: Vec<_> = lines
        .next()
        .expect("Phase 3 inventory TSV must have a header")
        .split('\t')
        .map(str::to_owned)
        .collect();
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let fields: Vec<_> = line.split('\t').map(str::to_owned).collect();
            assert_eq!(
                fields.len(),
                header.len(),
                "Phase 3 inventory row must match the header: {line}"
            );
            header.iter().cloned().zip(fields).collect()
        })
        .collect()
}

fn phase_three_slice_label(slice: &str) -> String {
    let mut parts = slice.split_whitespace();
    let prefix = parts
        .next()
        .unwrap_or_else(|| panic!("Phase 3 slice field is empty: {slice}"));
    let number = parts
        .next()
        .unwrap_or_else(|| panic!("Phase 3 slice field has no number: {slice}"));
    format!("{prefix} {number}")
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

fn all_scorecard_paths() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| path.starts_with("packages/agent/docs/") && path.ends_with("-scorecard.md"))
        .collect()
}

fn numeric_scorecard_rows(path: &str) -> Vec<ScorecardRow> {
    read_repo_file(path)
        .lines()
        .filter(|line| line.starts_with("| "))
        .filter_map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            if columns.len() >= 4 && columns[2].parse::<u32>().is_ok() {
                Some(ScorecardRow {
                    id: columns[0].to_owned(),
                    name: columns[1].to_owned(),
                    weight: columns[2].parse().unwrap_or_else(|error| {
                        panic!("invalid scorecard weight in {line}: {error}")
                    }),
                    status: columns[3].to_owned(),
                })
            } else {
                None
            }
        })
        .collect()
}

fn evidence_path_for_scorecard(scorecard_path: &str) -> String {
    scorecard_path.replace("-scorecard.md", "-evidence-manifest.md")
}

fn assert_current_lineage_base() {
    let status = Command::new("git")
        .args(["merge-base", "--is-ancestor", BASE_COMMIT, "HEAD"])
        .current_dir(repo_root())
        .status()
        .expect("git merge-base should run");
    assert!(
        status.success(),
        "HEAD must be based on the current DXRHA baseline {BASE_COMMIT}"
    );
}

#[test]
fn desi_artifacts_branch_lineage_and_readme_wiring_exist() {
    assert_current_lineage_base();

    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing DESI artifact: {path}");
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "codex/documentation-evidence-scorecard-integrity-current",
        BASE_COMMIT,
        "codex/documentation-evidence-scorecard-integrity",
        STALE_BRANCH_HEAD,
        "quarry-only",
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
    ] {
        assert!(
            readme.contains(required),
            "README must mention DESI artifact or target: {required}"
        );
    }
}

#[test]
fn desi_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_desi_scorecard_rows();
    let expected = BTreeMap::from([
        (
            "DESI-0",
            ("Baseline, lineage, and stale-branch quarantine", 5_u32),
        ),
        (
            "DESI-1",
            ("Whole documentation/evidence artifact inventory", 10),
        ),
        (
            "DESI-2",
            ("Active docs truthfulness and present-tense closure", 10),
        ),
        (
            "DESI-3",
            ("Evidence command provenance and result integrity", 12),
        ),
        ("DESI-4", ("Scorecard arithmetic and status integrity", 10)),
        (
            "DESI-5",
            (
                "Inventory coverage and predecessor cross-index integrity",
                10,
            ),
        ),
        ("DESI-6", ("README and progressive-disclosure docs sync", 8)),
        (
            "DESI-7",
            (
                "Static-gate/local-GitHub wiring and closeout target parity",
                8,
            ),
        ),
        (
            "DESI-8",
            ("Stale/open-loop/future-tense residue guards", 10),
        ),
        ("DESI-9", ("Branch, handoff, and remote pickup hygiene", 7)),
        ("DESI-10", ("Broad verification and final closeout", 10)),
    ]);
    assert_eq!(rows.len(), expected.len(), "DESI must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected DESI row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "DESI scorecard weights must sum to 100");

    let evidence = read_repo_file(EVIDENCE_PATH);
    for row_id in 0..=10 {
        assert!(
            evidence.contains(&format!("DESI-{row_id}")),
            "DESI evidence manifest must cover DESI-{row_id}"
        );
    }
}

#[test]
fn all_retained_scorecards_have_complete_arithmetic_and_companion_evidence() {
    for scorecard_path in all_scorecard_paths() {
        let rows = numeric_scorecard_rows(&scorecard_path);
        assert!(
            !rows.is_empty(),
            "{scorecard_path} must contain weighted scorecard rows"
        );
        let total: u32 = rows.iter().map(|row| row.weight).sum();
        assert_eq!(total, 100, "{scorecard_path} weights must sum to 100");
        for row in &rows {
            assert!(
                matches!(row.status.as_str(), "passed" | "passed_after_fix"),
                "{} in {scorecard_path} must be closed, got {}",
                row.id,
                row.status
            );
        }

        let mut row_numbers = BTreeSet::new();
        for row in &rows {
            let suffix = row
                .id
                .rsplit_once('-')
                .and_then(|(_, suffix)| suffix.parse::<u32>().ok())
                .unwrap_or_else(|| panic!("{} has non-numeric row id {}", scorecard_path, row.id));
            row_numbers.insert(suffix);
        }
        let max = *row_numbers
            .iter()
            .last()
            .expect("scorecard row numbers should be present");
        for expected in 0..=max {
            assert!(
                row_numbers.contains(&expected),
                "{scorecard_path} missing row number {expected}"
            );
        }

        let scorecard = read_repo_file(&scorecard_path);
        assert!(
            scorecard.contains("100/100") && scorecard.to_lowercase().contains("status:"),
            "{scorecard_path} must state closed 100/100 status"
        );

        let evidence_path = evidence_path_for_scorecard(&scorecard_path);
        assert!(
            tracked_or_present(&evidence_path),
            "{scorecard_path} missing companion evidence manifest {evidence_path}"
        );
        let evidence = read_repo_file(&evidence_path);
        assert!(
            evidence.contains("exit 0")
                || evidence.contains("passed")
                || evidence.contains("passed_after_fix")
                || evidence.contains("Source Audit"),
            "{evidence_path} must contain concrete command results or source-grounded rationale"
        );
        for forbidden in [
            "recorded later",
            "to be recorded",
            "will be recorded",
            "recorded in final closeout",
        ] {
            assert!(
                !evidence.contains(forbidden),
                "{evidence_path} contains generic evidence placeholder language: {forbidden}"
            );
        }
    }
}

#[test]
fn desi_inventory_is_structured_and_covers_required_surfaces() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 95,
        "DESI inventory row count regressed: {}",
        rows.len()
    );

    let allowed_surfaces = BTreeSet::from([
        "root_doc",
        "scorecard",
        "evidence_manifest",
        "inventory",
        "invariant_test",
        "local_gate",
        "github_gate",
        "review_template",
        "platform_docs",
        "predecessor_inventory",
        "branch_handoff",
    ]);
    let allowed_classifications = BTreeSet::from([
        "active_current",
        "historical_evidence",
        "source_truth",
        "predecessor_index",
        "quarry_only",
    ]);
    let mut ids = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    let mut covered_rows = BTreeSet::new();
    let mut by_path = BTreeMap::new();
    for row in &rows {
        assert_eq!(row.len(), 8, "DESI row must have 8 fields: {row:?}");
        assert!(ids.insert(row[0].clone()), "duplicate DESI id {}", row[0]);
        assert!(row[0].starts_with("DESI-INV-"));
        assert!(
            tracked_or_present(&row[1]) || row[4] == "quarry_only",
            "DESI inventory path must be tracked/present unless quarry-only: {}",
            row[1]
        );
        assert!(
            allowed_surfaces.contains(row[2].as_str()),
            "{} has unknown surface {}",
            row[0],
            row[2]
        );
        assert!(
            allowed_classifications.contains(row[4].as_str()),
            "{} has unknown classification {}",
            row[0],
            row[4]
        );
        for field in row {
            assert!(
                !field.trim().is_empty()
                    && !field.contains("TODO")
                    && !field.contains("TBD")
                    && !field.contains("current_gap")
                    && !field.contains("unclassified"),
                "invalid DESI inventory field in row {:?}",
                row
            );
        }
        surfaces.insert(row[2].clone());
        by_path.insert(row[1].clone(), row.clone());
        for id in row[7].split(',') {
            covered_rows.insert(id.to_owned());
        }
    }
    for surface in allowed_surfaces {
        assert!(surfaces.contains(surface), "missing DESI surface {surface}");
    }
    for row_id in 0..=10 {
        assert!(
            covered_rows.contains(&format!("DESI-{row_id}")),
            "DESI inventory does not cover DESI-{row_id}"
        );
    }
    for required_path in [
        "README.md",
        "AGENTS.md",
        ".github/workflows/ci.yml",
        ".github/pull_request_template.md",
        "scripts/tron.d/quality.sh",
        "packages/ios-app/docs/architecture.md",
        "packages/ios-app/docs/development.md",
        "packages/ios-app/docs/events.md",
        "packages/mac-app/docs/architecture.md",
        "packages/mac-app/docs/development.md",
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            by_path.contains_key(required_path),
            "DESI inventory missing required path {required_path}"
        );
    }
}

#[test]
fn accepted_phase_three_desi_rows_use_current_baseline_closeout_wording() {
    let accepted_phase_three_slices: BTreeSet<_> = parse_phase_three_inventory_rows()
        .into_iter()
        .filter(|row| row.get("status").map(String::as_str) == Some("current_baseline"))
        .map(|row| {
            phase_three_slice_label(
                row.get("slice")
                    .expect("Phase 3 inventory row must include slice"),
            )
        })
        .collect();
    assert!(
        !accepted_phase_three_slices.is_empty(),
        "Phase 3 inventory must contain accepted current_baseline rows"
    );

    let forbidden = [
        ["implementation", "candidate"].join("-"),
        ["review-pending", "status"].join(" "),
        [
            "tsv must preserve pending_review status",
            "until acceptance",
        ]
        .join(" "),
    ];
    let mut checked_rows = 0_u32;
    for row in parse_inventory_rows() {
        if row[4] != "active_current" {
            continue;
        }
        let joined = row.join("\t");
        if !accepted_phase_three_slices
            .iter()
            .any(|slice| joined.contains(slice))
        {
            continue;
        }
        checked_rows += 1;
        let normalized = joined.to_lowercase();
        for phrase in &forbidden {
            assert!(
                !normalized.contains(phrase.as_str()),
                "{} describes an accepted Phase 3 current_baseline row with stale closeout wording: {phrase}",
                row[0]
            );
        }
    }

    assert!(
        checked_rows > 0,
        "DESI inventory must contain active/current rows for accepted Phase 3 slices"
    );
}

#[test]
fn active_docs_use_present_tense_and_reject_open_loop_residue() {
    let active_docs = [
        "README.md",
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
    ];
    for path in active_docs {
        let source = read_repo_file(path);
        for forbidden in [
            "is being reduced",
            "while PET-10 finishes",
            "PET-10 owns deleting",
            "recorded later",
            "recorded in final response",
            "recorded in final closeout",
            "to be recorded",
            "will be recorded",
            "will add",
            "will run",
            "current_gap",
            "TODO",
            "TBD",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} contains stale active wording: {forbidden}"
            );
        }
    }

    let readme = read_repo_file("README.md");
    let normalized_readme = readme.split_whitespace().collect::<Vec<_>>().join(" ");
    assert!(
        readme.contains("The iOS app is a thin chat and generic runtime shell"),
        "README intro must state current iOS shell truth"
    );
    assert!(
        normalized_readme.contains("retained ledger/log records.")
            && readme.contains("Engine substrate primitives provide host infrastructure"),
        "README must describe retained substrate surfaces in present tense"
    );

    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let ci = read_repo_file(".github/workflows/ci.yml");
    for source in [quality.as_str(), ci.as_str()] {
        assert!(
            !source.contains("tron deploy")
                && !source.contains("auto-deploy")
                && !source.contains("cmd_auto_deploy"),
            "active local/GitHub quality gates must not contain deploy automation"
        );
    }
}

#[test]
fn local_and_github_static_gate_targets_match_exactly_with_desi() {
    let local_targets = parse_quality_closeout_targets();
    let github_targets = parse_github_static_gate_targets();
    assert_eq!(
        local_targets, github_targets,
        "scripts/tron ci test and GitHub rust-static-gates must run the same closeout target set in the same order"
    );
    assert!(
        local_targets.contains(&TARGET_NAME.to_owned()),
        "DESI target must be in the closeout set"
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
    let desi_index = local_targets
        .iter()
        .position(|target| target == TARGET_NAME)
        .expect("DESI target should be present");
    let dxrha_index = local_targets
        .iter()
        .position(|target| target == "developer_experience_repo_hygiene_automation_invariants")
        .expect("DXRHA target should be present");
    let primitive_trace_index = local_targets
        .iter()
        .position(|target| target == "primitive_trace_execution")
        .expect("primitive trace target should be present");
    assert!(
        dxrha_index < desi_index && desi_index < primitive_trace_index,
        "DESI must run after DXRHA and before primitive trace/integration closeout targets"
    );
}

#[test]
fn predecessor_inventories_classify_desi_artifacts() {
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
        "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv",
        "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "packages/agent/docs/observability-diagnostics-auditability-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv",
        "packages/agent/docs/state-ownership-lifecycle-inventory.tsv",
        "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
        "packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.tsv",
    ] {
        let source = read_repo_file(predecessor);
        for required_path in required_paths {
            assert!(
                source.contains(required_path),
                "{predecessor} missing DESI artifact {required_path}"
            );
        }
    }
}

#[test]
fn closeout_evidence_records_required_commands_without_placeholders() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "DESI evidence manifest missing command: {command}"
        );
    }
    for forbidden in [
        "TODO",
        "TBD",
        "current_gap",
        "recorded later",
        "to be recorded",
        "will be recorded",
        "recorded in final response",
    ] {
        assert!(
            !evidence.contains(forbidden),
            "DESI evidence must not contain placeholder language: {forbidden}"
        );
    }
}

#[test]
fn branch_handoff_and_remote_pickup_rules_are_recorded() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    for required in [
        "codex/documentation-evidence-scorecard-integrity-current",
        "codex/documentation-evidence-scorecard-integrity",
        "quarry-only",
        BASE_COMMIT,
        STALE_BRANCH_HEAD,
        "git status --short",
        "another thread can continue without chat history",
    ] {
        assert!(
            scorecard.contains(required)
                || evidence.contains(required)
                || inventory.contains(required),
            "DESI branch/handoff docs missing {required}"
        );
    }
    assert!(
        scorecard.find(BASE_COMMIT).expect("base commit marker")
            < scorecard.find("quarry-only").expect("quarry-only marker"),
        "scorecard must establish current lineage before stale-branch quarantine"
    );
}
