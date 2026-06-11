//! Static invariants for the Release / Install / Upgrade / Rollback Discipline slice.

use std::path::{Path, PathBuf};

const SCORECARD_PATH: &str =
    "packages/agent/docs/release-install-upgrade-rollback-discipline-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/release-install-upgrade-rollback-discipline-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/release-install-upgrade-rollback-discipline-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/release-install-upgrade-rollback-discipline-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/release_install_upgrade_rollback_discipline_invariants.rs";
const TARGET_NAME: &str = "release_install_upgrade_rollback_discipline_invariants";

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

fn tracked_files_under(prefix: &str) -> Vec<String> {
    let output = std::process::Command::new("git")
        .args(["ls-files", prefix])
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(
        output.status.success(),
        "git ls-files failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("git output should be utf8")
        .lines()
        .map(str::to_owned)
        .collect()
}

#[test]
fn rur_artifacts_and_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            repo_path(path).exists(),
            "required RUR artifact missing: {path}"
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
            "README must mention RUR artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(source.contains(TARGET_NAME), "{path} must run RUR");
    }
}

#[test]
fn rur_scorecard_shape_is_weighted_and_not_prematurely_closed() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Passing threshold: **100/100**"));
    assert!(
        !scorecard.contains("TODO") && !scorecard.contains("TBD"),
        "RUR scorecard must not retain placeholders"
    );

    let expected = [
        ("RUR-0", "Harness, Baseline, and Scope Control", 5),
        ("RUR-1", "Release/Install/Runtime Ownership Inventory", 10),
        ("RUR-2", "Port 9847 Ownership and Conflict Discipline", 12),
        (
            "RUR-3",
            "Mac App Wrapper, SMAppService, and LaunchAgent Semantics",
            12,
        ),
        ("RUR-4", "CLI Setup/Dev/Manual Deploy Safety", 10),
        (
            "RUR-5",
            "Install, Uninstall, Restart, Update Finalization, and Rollback Paths",
            12,
        ),
        (
            "RUR-6",
            "Upgrade/Rollback State Safety for Profiles, DBs, Generated Projects, and Runtime Dirs",
            10,
        ),
        ("RUR-7", "Generated Project and Package Drift", 8),
        ("RUR-8", "Clean-Machine and Stale-Install Proof", 8),
        (
            "RUR-9",
            "Docs, README, Inventories, Static Guards, and CI Wiring",
            8,
        ),
        (
            "RUR-10",
            "Evidence, Adversarial Audit, Clean State, and Commit",
            5,
        ),
    ];

    let mut total = 0u32;
    let mut pending_rows = 0usize;
    for (id, name, weight) in expected {
        let row = scorecard
            .lines()
            .find(|line| line.starts_with(&format!("| {id} |")))
            .unwrap_or_else(|| panic!("missing RUR scorecard row {id}"));
        let columns: Vec<_> = row.trim_matches('|').split('|').map(str::trim).collect();
        assert_eq!(columns.get(1), Some(&name), "unexpected row name: {row}");
        assert_eq!(
            columns
                .get(2)
                .unwrap_or_else(|| panic!("missing weight in {row}"))
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid RUR weight in {row}: {error}")),
            weight,
            "unexpected weight: {row}"
        );
        let status = columns
            .get(3)
            .unwrap_or_else(|| panic!("missing status in {row}"));
        assert!(
            *status != "TODO" && *status != "TBD" && !status.is_empty(),
            "RUR row status must be explicit: {row}"
        );
        if status.contains("pending") {
            pending_rows += 1;
        }
        total += weight;
    }
    assert_eq!(total, 100, "RUR scorecard weights must sum to 100");

    if scorecard.contains("Status: **closed**") {
        assert!(scorecard.contains("Current score: **100/100**"));
        assert_eq!(
            pending_rows, 0,
            "closed scorecard cannot retain pending rows"
        );
    } else {
        assert!(
            !scorecard.contains("Current score: **100/100**"),
            "active RUR scorecard must stay below 100 until validation is real"
        );
        assert!(pending_rows > 0, "active RUR scorecard must show open rows");
    }
}

#[test]
fn rur_inventory_shape_and_required_surfaces_are_complete() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: Complete"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));

    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\truntime_owner\tport_or_state\tcurrent_proof\trisk\tproof_target\taction_rationale"
        ),
        "RUR TSV header changed"
    );
    let rows: Vec<_> = lines.collect();
    assert!(
        rows.len() >= 38,
        "RUR inventory must keep the audited surface set"
    );

    for required in [
        "RUR-INV-001\tscripts/tron\tworkspace_cli_dispatcher",
        "RUR-INV-004\tscripts/tron-lib.d/service.sh\tservice_helper",
        "RUR-INV-005\tscripts/tron.d/dev.sh\tdev_takeover_cli",
        "RUR-INV-006\tscripts/tron.d/manual-deploy.sh\tcontributor_manual_deploy",
        "RUR-INV-012\tpackages/mac-app/Sources/Server/Paths/TronPaths.swift",
        "RUR-INV-013\tpackages/mac-app/Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift",
        "RUR-INV-018\tpackages/mac-app/Sources/Server/ProcessControl/DevServerStopper.swift",
        "RUR-INV-026\tpackages/mac-app/project.yml\tmac_xcodegen_source",
        "RUR-INV-028\tpackages/ios-app/project.yml\tios_xcodegen_source",
        "RUR-INV-030\t~/.tron/internal/run\truntime_run_dir",
        "RUR-INV-038\tpackages/agent/tests/release_install_upgrade_rollback_discipline_invariants.rs",
    ] {
        assert!(tsv.contains(required), "RUR inventory missing {required}");
    }

    for row in rows {
        let columns: Vec<_> = row.split('\t').collect();
        assert_eq!(columns.len(), 10, "RUR row must have 10 columns: {row}");
        assert!(columns[0].starts_with("RUR-INV-"));
        for value in columns {
            assert!(
                !value.trim().is_empty() && !value.contains("TODO") && !value.contains("TBD"),
                "RUR inventory field must be complete: {row}"
            );
        }
    }
}

#[test]
fn rur_evidence_lists_required_closeout_matrix() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(
        !evidence.contains("TODO") && !evidence.contains("TBD"),
        "RUR evidence must not retain placeholders"
    );

    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "RUR evidence must record command: {command}"
        );
    }
    assert!(evidence.contains("git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj"));
    assert!(evidence.contains("git diff --exit-code -- packages/mac-app/TronMac.xcodeproj"));
    assert!(
        evidence.contains("No iOS runtime source has been touched"),
        "RUR evidence must record iOS source-touch scope"
    );

    let scorecard = read_repo_file(SCORECARD_PATH);
    if scorecard.contains("Status: **closed**") {
        assert!(
            !evidence.contains("pending") && !evidence.contains("not_run"),
            "closed RUR evidence cannot retain pending/not_run results"
        );
        assert!(evidence.contains("Status: **closed**"));
        assert!(evidence.contains("Current score: **100/100**"));
    }
}

#[test]
fn scripts_fail_closed_on_unknown_port_owners() {
    let dev = read_repo_file("scripts/tron.d/dev.sh");
    for forbidden in [
        "kill -9 \"$existing_pid\"",
        "kill \"$existing_pid\"",
        "kill -9 \"$pid\"",
        "kill \"$pid\"",
    ] {
        assert!(
            !dev.contains(forbidden),
            "dev takeover must not signal unverified port owners: {forbidden}"
        );
    }
    for required in [
        "is_dev_server_pid \"$existing_pid\"",
        "stop_known_dev_server_pid \"$existing_pid\"",
        "refuse_unknown_port_owner \"$PROD_PORT\" \"$existing_pid\"",
        "if ! is_dev_server_pid \"$pid\"; then",
        "stop_known_dev_server_pid \"$pid\" || return 1",
    ] {
        assert!(dev.contains(required), "dev.sh missing guard {required}");
    }

    let service = read_repo_file("scripts/tron-lib.d/service.sh");
    for required in [
        "is_dev_server_pid()",
        "is_prod_server_pid()",
        "process_command_for_pid()",
        "/Tron-Dev.app/Contents/MacOS/tron",
        "/Applications/Tron.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron",
        "refuse_unknown_port_owner()",
        "stop_known_dev_server_pid()",
        "mode=\"external_listener\"",
        "mode=\"prod_loaded_no_listener\"",
        "no listener is active on port $PROD_PORT",
        "\"listenerIsDevServer\"",
        "rm -f \"$PLIST_PATH\" \"$DEV_PLIST_PATH\"",
        "\"$DEV_BACKGROUND_PID_FILE\"",
        "\"$DEV_BACKGROUND_LOG\"",
    ] {
        assert!(
            service.contains(required),
            "service helper missing RUR guard marker: {required}"
        );
    }

    let manual_deploy = read_repo_file("scripts/tron.d/manual-deploy.sh");
    for required in [
        "is_dev_server_pid \"$listener_pid\"",
        "Port $PROD_PORT is occupied by an unknown process",
        "describe_port_owner \"$PROD_PORT\" \"$listener_pid\"",
    ] {
        assert!(
            manual_deploy.contains(required),
            "manual deploy missing port-owner guard: {required}"
        );
    }
}

#[test]
fn production_deploy_automation_did_not_expand() {
    let workspace_cli = read_repo_file("scripts/tron");
    let installed_cli = read_repo_file("scripts/tron-cli");
    assert!(workspace_cli.contains("manual-deploy"));
    assert!(!workspace_cli.contains("\n    deploy)"));
    assert!(!workspace_cli.contains("cmd_deploy"));
    assert!(installed_cli.contains("manual-deploy"));
    assert!(!installed_cli.contains("dev|deploy|ci"));
    assert!(!installed_cli.contains("\n    deploy)"));

    for path in tracked_files_under(".github/workflows") {
        let source = read_repo_file(&path);
        assert!(
            !source.contains("tron deploy")
                && !source.contains("./scripts/tron deploy")
                && !source.contains("scripts/tron deploy"),
            "{path} must not call production deploy automation"
        );
        if path.ends_with("ci.yml") {
            assert!(
                !source.contains("manual-deploy") && !source.contains("tron install"),
                "CI quality gates must not install LaunchAgents or run manual deploy"
            );
        }
    }
}

#[test]
fn generated_project_drift_and_runtime_state_boundaries_are_documented() {
    let readme = read_repo_file("README.md");
    for required in [
        "tron dev",
        "port `9847`",
        "external listener",
        "SMAppService",
        "git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "git diff --exit-code -- packages/mac-app/TronMac.xcodeproj",
        "profiles/",
        "workspace/",
        "internal/database/",
    ] {
        assert!(
            readme.contains(required),
            "README missing RUR text {required}"
        );
    }

    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(evidence.contains("cd packages/ios-app && xcodegen generate"));
    assert!(evidence.contains("cd packages/mac-app && xcodegen generate"));
}

#[test]
fn hra_current_ownership_rows_cover_new_rur_artifacts() {
    let required_paths = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ];
    for hra_path in [
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
    ] {
        let hra = read_repo_file(hra_path);
        for required in required_paths {
            assert!(
                hra.contains(required),
                "{hra_path} must contain current ownership row for {required}"
            );
        }
    }
}

#[test]
fn touched_shell_scripts_remain_syntax_valid() {
    for path in [
        "scripts/tron-lib.d/service.sh",
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/manual-deploy.sh",
    ] {
        let output = std::process::Command::new("bash")
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
