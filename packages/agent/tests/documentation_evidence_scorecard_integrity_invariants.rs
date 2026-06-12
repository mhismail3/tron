//! Static gates for Documentation / Evidence / Scorecard Integrity.

use std::collections::BTreeSet;
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
const TARGET_PATH: &str =
    "packages/agent/tests/documentation_evidence_scorecard_integrity_invariants.rs";
const TARGET_NAME: &str = "documentation_evidence_scorecard_integrity_invariants";

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

fn command_stdout(program: &str, args: &[&str]) -> String {
    let output = Command::new(program)
        .args(args)
        .current_dir(repo_root())
        .output()
        .unwrap_or_else(|error| panic!("failed to run {program} {args:?}: {error}"));
    assert!(
        output.status.success(),
        "{program} {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("command stdout should be utf8")
}

fn hardening_targets_from_quality_script(source: &str) -> BTreeSet<String> {
    let mut in_array = false;
    let mut targets = BTreeSet::new();
    for line in source.lines() {
        let trimmed = line.trim();
        if trimmed == "local closeout_test_targets=(" {
            in_array = true;
            continue;
        }
        if in_array && trimmed == ")" {
            break;
        }
        if in_array && !trimmed.is_empty() {
            targets.insert(trimmed.to_owned());
        }
    }
    targets
}

fn hardening_targets_from_github_ci(source: &str) -> BTreeSet<String> {
    source
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            let rest = trimmed.strip_prefix("cargo test --test ")?;
            Some(
                rest.split_whitespace()
                    .next()
                    .expect("cargo test line should name a target")
                    .to_owned(),
            )
        })
        .collect()
}

fn docs_artifacts() -> Vec<String> {
    std::fs::read_dir(repo_path("packages/agent/docs"))
        .expect("packages/agent/docs should exist")
        .map(|entry| entry.expect("docs entry should be readable").path())
        .filter(|path| path.is_file())
        .filter_map(|path| {
            let file_name = path.file_name()?.to_str()?;
            let is_artifact = file_name.ends_with("-scorecard.md")
                || file_name.ends_with("-evidence-manifest.md")
                || file_name.ends_with("-inventory.md")
                || file_name.ends_with("-inventory.tsv")
                || file_name.ends_with("-file-inventory.tsv")
                || file_name.ends_with("-retention-inventory.tsv");
            is_artifact.then(|| {
                path.strip_prefix(repo_root())
                    .expect("docs artifact should be under repo root")
                    .to_string_lossy()
                    .into_owned()
            })
        })
        .collect()
}

fn parse_scorecard_row(row: &str) -> Vec<&str> {
    row.trim_matches('|').split('|').map(str::trim).collect()
}

#[test]
fn desi_artifacts_readme_and_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            repo_path(path).exists(),
            "required DESI artifact missing: {path}"
        );
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

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(source.contains(TARGET_NAME), "{path} must run DESI");
    }
}

#[test]
fn desi_scorecard_rows_have_required_weights_and_close_cleanly() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Passing threshold: **100/100**"));
    assert!(
        scorecard.contains("Base commit: `9ef779cf56c7a498921dec0782dea41cfbe17104`"),
        "DESI scorecard must record the required base commit"
    );

    let expected = [
        ("DESI-0", "Harness, Base, and Scope Control", 5),
        (
            "DESI-1",
            "Documentation and Evidence Inventory Completeness",
            10,
        ),
        ("DESI-2", "Closed Artifact State Integrity", 12),
        ("DESI-3", "Evidence Claim Traceability", 12),
        ("DESI-4", "Scorecard Math and Row Closure Discipline", 10),
        (
            "DESI-5",
            "Inventory Coverage and Predecessor Synchronization",
            10,
        ),
        (
            "DESI-6",
            "README and Progressive Disclosure Truthfulness",
            10,
        ),
        (
            "DESI-7",
            "Future-Tense and Aspirational Cleanup Rejection",
            8,
        ),
        ("DESI-8", "Command Matrix Reproducibility", 8),
        ("DESI-9", "Personal Info, Path, and Provenance Hygiene", 7),
        ("DESI-10", "Adversarial Audit, Clean State, and Commit", 8),
    ];

    let mut total = 0u32;
    let mut pending_rows = 0usize;
    for (id, name, weight) in expected {
        let row = scorecard
            .lines()
            .find(|line| line.starts_with(&format!("| {id} |")))
            .unwrap_or_else(|| panic!("missing DESI scorecard row {id}"));
        let columns = parse_scorecard_row(row);
        assert_eq!(
            columns.get(1),
            Some(&name),
            "unexpected DESI row name: {row}"
        );
        assert_eq!(
            columns
                .get(2)
                .unwrap_or_else(|| panic!("missing weight in {row}"))
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid DESI weight in {row}: {error}")),
            weight,
            "unexpected DESI weight: {row}"
        );
        let status = columns
            .get(3)
            .unwrap_or_else(|| panic!("missing status in {row}"));
        assert!(
            !status.is_empty() && *status != "TODO" && *status != "TBD",
            "DESI row status must be explicit: {row}"
        );
        if status.contains("pending") {
            pending_rows += 1;
        }
        total += weight;
    }
    assert_eq!(total, 100, "DESI scorecard weights must sum to 100");

    if scorecard.contains("Status: **closed**") {
        assert!(scorecard.contains("Current score: **100/100**"));
        assert_eq!(
            pending_rows, 0,
            "closed DESI scorecard cannot retain pending rows"
        );
        for forbidden in ["pending_validation", "not_run_yet", "TODO", "TBD"] {
            assert!(
                !scorecard.contains(forbidden),
                "closed DESI scorecard contains stale marker {forbidden}"
            );
        }
    } else {
        assert!(
            !scorecard.contains("Current score: **100/100**"),
            "active DESI scorecard must stay below 100 until validation is real"
        );
        assert!(
            pending_rows > 0,
            "active DESI scorecard must show pending rows"
        );
    }
}

#[test]
fn desi_inventory_covers_all_documentation_artifacts_and_control_surfaces() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: **inventory_built_pre_edit**"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));
    assert!(
        inventory.contains("This inventory was built before DESI source edits"),
        "DESI inventory must preserve pre-edit provenance"
    );

    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tcurrent_contract\tsource_evidence\trisk\taction_rationale\tproof_target"
        ),
        "DESI TSV header changed"
    );
    let rows: Vec<_> = lines.collect();
    assert!(rows.len() >= 126, "DESI inventory row count regressed");

    for artifact in docs_artifacts() {
        assert!(
            tsv.contains(&artifact),
            "DESI inventory must cover docs artifact: {artifact}"
        );
    }

    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        "README.md#living-architecture-docs",
        "README.md#testing",
        "scripts/tron.d/quality.sh",
        ".github/workflows/ci.yml",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "closed-artifact stale markers",
        "passed claim traceability",
        "future-tense cleanup language",
        "provenance and path hygiene",
        "command matrix reproducibility",
    ] {
        assert!(tsv.contains(required), "DESI inventory missing {required}");
    }

    let mut ids = BTreeSet::new();
    for row in rows {
        let columns: Vec<_> = row.split('\t').collect();
        assert_eq!(
            columns.len(),
            9,
            "DESI inventory row must have 9 columns: {row}"
        );
        assert!(
            ids.insert(columns[0].to_owned()),
            "duplicate DESI row id {}",
            columns[0]
        );
        assert!(
            columns[0].starts_with("DESI-INV-"),
            "bad DESI row id: {}",
            columns[0]
        );
        for value in columns {
            assert!(
                !value.trim().is_empty() && !value.contains("TODO") && !value.contains("TBD"),
                "DESI inventory field must be complete: {row}"
            );
        }
    }
}

#[test]
fn desi_evidence_manifest_lists_required_closeout_commands() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(
        evidence.contains("Status: **active_validation_pending**")
            || evidence.contains("Status: **closed**"),
        "DESI evidence must record status"
    );

    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "DESI evidence must record command: {command}"
        );
    }

    for row in [
        "DESI-0", "DESI-1", "DESI-2", "DESI-3", "DESI-4", "DESI-5", "DESI-6", "DESI-7", "DESI-8",
        "DESI-9", "DESI-10",
    ] {
        assert!(
            evidence.contains(&format!("| {row} |")),
            "DESI evidence missing row evidence for {row}"
        );
    }

    if evidence.contains("Status: **closed**") {
        assert!(evidence.contains("Current score: **100/100**"));
        for forbidden in ["pending_validation", "not_run_yet", "TODO", "TBD"] {
            assert!(
                !evidence.contains(forbidden),
                "closed DESI evidence contains stale marker {forbidden}"
            );
        }
    }
}

#[test]
fn local_and_github_static_gate_target_lists_stay_in_parity() {
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let ci = read_repo_file(".github/workflows/ci.yml");
    let local_targets = hardening_targets_from_quality_script(&quality);
    let github_targets = hardening_targets_from_github_ci(&ci);

    assert!(
        local_targets.contains(TARGET_NAME),
        "local target list must include DESI"
    );
    assert!(
        github_targets.contains(TARGET_NAME),
        "GitHub static gates must include DESI"
    );
    assert_eq!(
        local_targets, github_targets,
        "local scripts/tron ci test and GitHub rust-static-gates target lists must match"
    );
    assert!(
        quality.contains("cargo test --test integration -- --test-threads=1 --quiet"),
        "local integration target must remain serial"
    );
    assert!(
        ci.contains("cargo test --test integration -- --test-threads=1 --quiet"),
        "GitHub integration target must remain serial"
    );
}

#[test]
fn readme_and_corrected_inventories_do_not_reopen_closed_artifacts() {
    let readme = read_repo_file("README.md");
    for forbidden in [
        "active Public Protocol API Contract Discipline scorecard",
        "local iOS build/test is currently blocked by host Xcode destination state",
        "active Configuration / Profile / Environment Discipline artifacts",
        "active Release / Install / Upgrade / Rollback Discipline artifacts",
        "active iOS Thin Client / Generic Runtime Shell artifacts",
        "active Developer Experience / Repo Hygiene / Automation artifacts",
        "active Documentation / Evidence / Scorecard Integrity artifacts",
    ] {
        assert!(
            !readme.contains(forbidden),
            "README retains stale living-doc status: {forbidden}"
        );
    }
    for required in [
        "completed Public Protocol API Contract Discipline scorecard",
        "completed Configuration / Profile / Environment Discipline artifacts",
        "completed Release / Install / Upgrade / Rollback Discipline artifacts",
        "completed iOS Thin Client / Generic Runtime Shell artifacts",
        "completed Developer Experience / Repo Hygiene / Automation artifacts",
        "completed Documentation / Evidence / Scorecard Integrity artifacts",
    ] {
        assert!(
            readme.contains(required),
            "README missing truthful status: {required}"
        );
    }

    let itc_inventory =
        read_repo_file("packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.md");
    assert!(itc_inventory.contains("Status: **closed**"));
    assert!(
        !itc_inventory.contains("active_validation_pending"),
        "closed ITC inventory cannot retain active validation status"
    );

    let ppacd_inventory =
        read_repo_file("packages/agent/docs/public-protocol-api-contract-discipline-inventory.md");
    assert!(ppacd_inventory.contains("Status: **closed**"));
    for forbidden in [
        "blocked_pending_ios_runtime_validation",
        "Final PPACD closeout still requires",
        "blocked locally by Xcode/CoreSimulator state",
    ] {
        assert!(
            !ppacd_inventory.contains(forbidden),
            "closed PPACD inventory retains stale blocker wording: {forbidden}"
        );
    }
}

#[test]
fn predecessor_inventories_cover_new_desi_artifacts() {
    let required_paths = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ];

    for path in [
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
    ] {
        let source = read_repo_file(path);
        for required in required_paths {
            assert!(
                source.contains(required),
                "{path} must contain predecessor inventory row for {required}"
            );
        }
    }
}

#[test]
fn desi_artifacts_keep_path_and_provenance_hygiene() {
    let user_path_prefix = ["/", "Users", "/"].join("");
    let forbidden = [
        user_path_prefix.as_str(),
        ".codex/worktrees",
        "chat history as proof",
    ];
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
    ] {
        let source = read_repo_file(path);
        for forbidden in forbidden {
            assert!(
                !source.contains(forbidden),
                "{path} contains non-durable path/provenance marker {forbidden}"
            );
        }
    }

    let ignored = command_stdout("git", &["ls-files", "-ci", "--exclude-standard"]);
    assert!(
        ignored.trim().is_empty(),
        "tracked ignored files must stay absent: {ignored}"
    );
}
