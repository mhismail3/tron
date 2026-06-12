//! Static invariants for the Developer Experience / Repo Hygiene / Automation slice.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/developer-experience-repo-hygiene-automation-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/developer-experience-repo-hygiene-automation-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/developer_experience_repo_hygiene_automation_invariants.rs";
const TARGET_NAME: &str = "developer_experience_repo_hygiene_automation_invariants";

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

fn git_ls_files() -> BTreeSet<String> {
    command_stdout("git", &["ls-files"])
        .lines()
        .map(str::to_owned)
        .collect()
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

#[test]
fn dxrha_artifacts_readme_and_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            repo_path(path).exists(),
            "required DXRHA artifact missing: {path}"
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
            "README must mention DXRHA artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(source.contains(TARGET_NAME), "{path} must run DXRHA");
    }
}

#[test]
fn dxrha_scorecard_rows_have_required_weights_and_close_cleanly() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Passing threshold: **100/100**"));
    assert!(
        scorecard.contains("Base commit: `3cec727e19505aa4c58a18bcc4e54560c6829cce`"),
        "DXRHA scorecard must record the required base commit"
    );

    let expected = [
        ("DXRHA-0", "Harness, Base, and Scope Control", 5),
        ("DXRHA-1", "Contributor Workflow Inventory", 8),
        ("DXRHA-2", "Setup and Dev Server UX Discipline", 10),
        (
            "DXRHA-3",
            "Script Dispatch, Help, and Error Consistency",
            10,
        ),
        ("DXRHA-4", "Generated Artifact Determinism", 10),
        ("DXRHA-5", "Local and CI Target Parity", 12),
        ("DXRHA-6", "Tracked Ignored and Stale Artifact Hygiene", 10),
        (
            "DXRHA-7",
            "Branch, Push, and Worktree Handoff Cleanliness",
            8,
        ),
        ("DXRHA-8", "README and Progressive Disclosure Accuracy", 10),
        ("DXRHA-9", "Automation Safety Boundaries", 9),
        (
            "DXRHA-10",
            "Evidence, Adversarial Audit, Clean State, and Commit",
            8,
        ),
    ];

    let mut total = 0u32;
    let mut pending_rows = 0usize;
    for (id, name, weight) in expected {
        let row = scorecard
            .lines()
            .find(|line| line.starts_with(&format!("| {id} |")))
            .unwrap_or_else(|| panic!("missing DXRHA scorecard row {id}"));
        let columns: Vec<_> = row.trim_matches('|').split('|').map(str::trim).collect();
        assert_eq!(columns.get(1), Some(&name), "unexpected row name: {row}");
        assert_eq!(
            columns
                .get(2)
                .unwrap_or_else(|| panic!("missing weight in {row}"))
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid DXRHA weight in {row}: {error}")),
            weight,
            "unexpected DXRHA weight: {row}"
        );
        let status = columns
            .get(3)
            .unwrap_or_else(|| panic!("missing status in {row}"));
        assert!(
            !status.is_empty() && *status != "TODO" && *status != "TBD",
            "DXRHA row status must be explicit: {row}"
        );
        if status.contains("pending") {
            pending_rows += 1;
        }
        total += weight;
    }
    assert_eq!(total, 100, "DXRHA scorecard weights must sum to 100");

    if scorecard.contains("Status: **closed**") || scorecard.contains("Status: **complete**") {
        assert!(scorecard.contains("Current score: **100/100**"));
        assert_eq!(
            pending_rows, 0,
            "closed DXRHA scorecard cannot retain pending rows"
        );
        assert!(
            !scorecard.contains("not_run_yet") && !scorecard.contains("pending_validation"),
            "closed DXRHA scorecard cannot retain unrun markers"
        );
    } else {
        assert!(
            !scorecard.contains("Current score: **100/100**"),
            "active DXRHA scorecard must stay below 100 until validation is real"
        );
        assert!(
            pending_rows > 0,
            "active DXRHA scorecard must show pending rows"
        );
    }
}

#[test]
fn dxrha_inventory_shape_and_required_surfaces_are_complete() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: Complete"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));
    assert!(
        inventory.contains("This inventory was built before DXRHA source edits"),
        "DXRHA inventory must preserve pre-edit provenance"
    );

    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tcurrent_contract\tsource_evidence\trisk\taction_rationale\tproof_target"
        ),
        "DXRHA TSV header changed"
    );
    let rows: Vec<_> = lines.collect();
    assert!(
        rows.len() >= 60,
        "DXRHA inventory must keep the audited contributor workflow row set"
    );

    for required in [
        "DXRHA-INV-001\tscripts/tron\tcli_dispatch",
        "DXRHA-INV-002\tscripts/tron.d/dev.sh\tcli_dispatch",
        "DXRHA-INV-003\tscripts/tron.d/quality.sh\tlocal_gate",
        "DXRHA-INV-020\t.github/workflows/ci.yml\tgithub_gate",
        "DXRHA-INV-027\t.gitignore\trepo_hygiene",
        "DXRHA-INV-028\tpackages/ios-app/project.yml\tgenerated_artifact",
        "DXRHA-INV-029\tpackages/ios-app/TronMobile.xcodeproj\tgenerated_artifact",
        "DXRHA-INV-030\tpackages/mac-app/project.yml\tgenerated_artifact",
        "DXRHA-INV-031\tpackages/mac-app/TronMac.xcodeproj\tgenerated_artifact",
        "DXRHA-INV-036\tREADME.md\tdocs_workflow",
        "DXRHA-INV-037\tCONTRIBUTING.md\tdocs_workflow",
        "DXRHA-INV-043\t.codex/environments/environment.toml\thandoff",
        "DXRHA-INV-044\tbranch:codex/developer-experience-repo-hygiene-automation\thandoff",
        "DXRHA-INV-046\t~/.tron/\tsafety_boundary",
        "DXRHA-INV-049\tpackages/agent/skills/\tsafety_boundary",
        "DXRHA-INV-055\tpackages/agent/docs/developer-experience-repo-hygiene-automation-scorecard.md\tdxrha_artifact",
        "DXRHA-INV-059\tpackages/agent/tests/developer_experience_repo_hygiene_automation_invariants.rs\tdxrha_artifact",
    ] {
        assert!(tsv.contains(required), "DXRHA inventory missing {required}");
    }

    let mut ids = BTreeSet::new();
    for row in rows {
        let columns: Vec<_> = row.split('\t').collect();
        assert_eq!(
            columns.len(),
            9,
            "DXRHA inventory row must have 9 columns: {row}"
        );
        assert!(
            ids.insert(columns[0].to_owned()),
            "duplicate DXRHA inventory id {}",
            columns[0]
        );
        assert!(
            columns[0].starts_with("DXRHA-INV-"),
            "DXRHA id must use prefix: {}",
            columns[0]
        );
        for value in columns {
            assert!(
                !value.trim().is_empty() && !value.contains("TODO") && !value.contains("TBD"),
                "DXRHA inventory field must be complete: {row}"
            );
        }
    }
}

#[test]
fn dxrha_evidence_manifest_lists_required_closeout_commands() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(
        evidence.contains("Status: **active_validation_pending**")
            || evidence.contains("Status: **closed**"),
        "DXRHA evidence must record status"
    );

    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "cd packages/mac-app && xcodegen generate && cd ../.. && test -d packages/mac-app/TronMac.xcodeproj && git check-ignore -q packages/mac-app/TronMac.xcodeproj",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "DXRHA evidence must record command: {command}"
        );
    }

    if evidence.contains("Status: **closed**") {
        assert!(evidence.contains("Current score: **100/100**"));
        for forbidden in ["pending_validation", "not_run_yet", "TODO", "TBD"] {
            assert!(
                !evidence.contains(forbidden),
                "closed DXRHA evidence cannot retain {forbidden}"
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
        "local closeout target list must include DXRHA"
    );
    assert!(
        github_targets.contains(TARGET_NAME),
        "GitHub static-gates target list must include DXRHA"
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
fn generated_project_policy_and_tracked_ignored_hygiene_are_guarded() {
    let gitignore = read_repo_file(".gitignore");
    for required in [
        "**/target/",
        "packages/ios-app/.build/",
        "packages/ios-app/build/",
        "scripts/artifacts/",
        ".worktrees/",
        "!packages/ios-app/TronMobile.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
    ] {
        assert!(
            gitignore.contains(required),
            ".gitignore missing required DXRHA pattern: {required}"
        );
    }

    let ignored = command_stdout("git", &["ls-files", "-ci", "--exclude-standard"]);
    assert!(
        ignored.trim().is_empty(),
        "tracked ignored files must stay absent: {ignored}"
    );

    let ci = read_repo_file(".github/workflows/ci.yml");
    for required in [
        "xcodegen generate",
        "git diff --exit-code packages/ios-app/TronMobile.xcodeproj",
        "test -d packages/mac-app/TronMac.xcodeproj",
        "git check-ignore -q packages/mac-app/TronMac.xcodeproj",
    ] {
        assert!(
            ci.contains(required),
            "CI missing generated project policy marker: {required}"
        );
    }

    let readme = read_repo_file("README.md");
    assert!(readme.contains(
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj"
    ));
    assert!(readme.contains("git check-ignore -q packages/mac-app/TronMac.xcodeproj"));
}

#[test]
fn contributor_docs_match_live_script_ux() {
    let contributing = read_repo_file("CONTRIBUTING.md");
    assert!(
        contributing.contains("scripts/tron dev --stop"),
        "CONTRIBUTING must document the implemented dev stop spelling"
    );
    for forbidden in ["scripts/tron dev stop", "lands in Phase 5"] {
        assert!(
            !contributing.contains(forbidden),
            "CONTRIBUTING retains stale workflow wording: {forbidden}"
        );
    }

    let dev = read_repo_file("scripts/tron.d/dev.sh");
    for required in ["--stop)       dev_stop; return ;;", "tron dev --stop"] {
        assert!(dev.contains(required), "dev.sh missing marker: {required}");
    }
}

#[test]
fn production_automation_and_runtime_cleanup_boundaries_stay_safe() {
    let tracked = git_ls_files();
    assert!(
        !tracked
            .iter()
            .any(|path| path.starts_with("packages/agent/skills/")),
        "repo-managed packages/agent/skills must stay absent"
    );

    for path in tracked.iter().filter(|path| {
        path.starts_with(".github/workflows/")
            || path == &"scripts/tron"
            || path == &"scripts/tron-cli"
            || path.ends_with(".sh")
    }) {
        let source = read_repo_file(path);
        for forbidden in [
            "cmd_deploy",
            "auto-deploy",
            "cmd_auto_deploy",
            "tron deploy",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not contain production deploy automation marker {forbidden}"
            );
        }
        assert!(
            !source.contains("\n    deploy)"),
            "{path} must not dispatch a shorter deploy alias"
        );
    }

    let ci = read_repo_file(".github/workflows/ci.yml");
    for forbidden in ["manual-deploy", "tron install", "launchctl bootstrap"] {
        assert!(
            !ci.contains(forbidden),
            "CI must not run contributor install/deploy/LaunchAgent mutation: {forbidden}"
        );
    }

    for path in [
        "README.md",
        "CONTRIBUTING.md",
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
    ] {
        let source = read_repo_file(path);
        assert!(
            !source.contains("rm -rf ~/.tron"),
            "{path} must not recommend broad runtime state deletion"
        );
    }
}

#[test]
fn closed_artifacts_reject_stale_pending_markers() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        "packages/agent/docs/release-install-upgrade-rollback-discipline-scorecard.md",
        "packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md",
        "packages/agent/docs/off-plan-successor-teardown-cleanup-scorecard.md",
    ] {
        let source = read_repo_file(path);
        let closed = source.contains("Status: **closed**")
            || source.contains("Status: **complete**")
            || source.contains("Status: **completed**");
        if !closed {
            continue;
        }
        for forbidden in [
            "pending_validation",
            "not_run_yet",
            "Status: **active_validation_pending**",
            "TODO",
            "TBD",
        ] {
            assert!(
                !source.contains(forbidden),
                "closed artifact {path} contains stale marker {forbidden}"
            );
        }
    }
}

#[test]
fn predecessor_inventories_cover_new_dxrha_artifacts() {
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
fn touched_shell_scripts_remain_syntax_valid() {
    for path in [
        "scripts/tron",
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/quality.sh",
        "scripts/tron.d/manual-deploy.sh",
        "scripts/tron.d/workspace.sh",
    ] {
        let output = Command::new("bash")
            .args(["-n", path])
            .current_dir(repo_root())
            .output()
            .unwrap_or_else(|error| panic!("failed to run bash -n {path}: {error}"));
        assert!(
            output.status.success(),
            "bash -n {path} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
