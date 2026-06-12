//! Static and source-backed invariants for the Release / Install /
//! Upgrade / Rollback Discipline slice.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

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

fn git_ls_files(prefix: &str) -> Vec<String> {
    let output = Command::new("git")
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

fn tracked_or_present(path: &str) -> bool {
    repo_path(path).exists() || git_ls_files(path).iter().any(|tracked| tracked == path)
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| RIURD-"))
        .map(|line| {
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
        })
        .collect()
}

fn parse_inventory_rows() -> Vec<Vec<String>> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\trelease_risk\tcurrent_discipline\tproof\tscorecard_rows"
        ),
        "RIURD inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

fn assert_order(source: &str, before: &str, after: &str, context: &str) {
    let before_index = source
        .find(before)
        .unwrap_or_else(|| panic!("{context}: missing before marker {before:?}"));
    let after_index = source
        .find(after)
        .unwrap_or_else(|| panic!("{context}: missing after marker {after:?}"));
    assert!(
        before_index < after_index,
        "{context}: expected {before:?} to appear before {after:?}"
    );
}

fn is_text_mac_source(path: &str) -> bool {
    [
        ".swift",
        ".plist",
        ".entitlements",
        ".json",
        ".strings",
        ".md",
        ".yml",
        ".yaml",
    ]
    .iter()
    .any(|suffix| path.ends_with(suffix))
}

#[test]
fn riurd_artifacts_and_static_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing RIURD artifact: {path}");
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
            "README must mention RIURD artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(TARGET_NAME),
            "{path} must run RIURD invariant target"
        );
    }
}

#[test]
fn riurd_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        (
            "RIURD-0",
            ("Baseline, lineage, and stale-branch quarantine", 5_u32),
        ),
        ("RIURD-1", ("Whole release/install lifecycle inventory", 8)),
        (
            "RIURD-2",
            ("Port 9847 and process ownership discipline", 12),
        ),
        ("RIURD-3", ("Safe dev/manual deploy separation", 10)),
        (
            "RIURD-4",
            (
                "Setup, install, uninstall, restart, and clean-machine bootstrap",
                12,
            ),
        ),
        (
            "RIURD-5",
            ("Upgrade finalization and rollback semantics", 12),
        ),
        ("RIURD-6", ("Mac wrapper and SMAppService boundaries", 10)),
        (
            "RIURD-7",
            ("Generated project and packaging drift discipline", 8),
        ),
        (
            "RIURD-8",
            ("Docs, README, predecessor inventories, and CI wiring", 9),
        ),
        (
            "RIURD-9",
            ("Targeted static gates and verification harness", 8),
        ),
        ("RIURD-10", ("Broad closeout and clean handoff", 6)),
    ]);
    assert_eq!(rows.len(), expected.len(), "RIURD must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected RIURD row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "RIURD scorecard weights must sum to 100");

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "codex/release-install-upgrade-rollback-discipline-current",
        "0ed28e7fb309ff7db355e4c8cc2ad0062e3c699a",
        "codex/release-install-upgrade-rollback-discipline",
        "quarry-only",
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for forbidden in ["TODO", "TBD", "placeholder"] {
        assert!(
            !scorecard.contains(forbidden),
            "closed RIURD scorecard must not contain {forbidden}"
        );
    }
}

#[test]
fn riurd_inventory_is_structured_and_covers_required_surfaces() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 60,
        "RIURD inventory row count regressed: {}",
        rows.len()
    );

    let allowed_surfaces = BTreeSet::from([
        "cli",
        "dev_server",
        "manual_deploy",
        "setup_install",
        "service_manager",
        "mac_wrapper",
        "update_rollback",
        "generated_project",
        "release_workflow",
        "rust_startup",
        "environment",
        "docs_ci",
        "predecessor_inventory",
    ]);
    let mut ids = BTreeSet::new();
    let mut covered_rows = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    for row in &rows {
        assert_eq!(row.len(), 8, "RIURD row must have 8 fields: {row:?}");
        assert!(ids.insert(row[0].clone()), "duplicate RIURD id {}", row[0]);
        assert!(row[0].starts_with("RIURD-INV-"));
        assert!(
            tracked_or_present(&row[1]),
            "RIURD inventory path must be tracked or present: {}",
            row[1]
        );
        assert!(
            allowed_surfaces.contains(row[2].as_str()),
            "{} has unknown surface {}",
            row[0],
            row[2]
        );
        for field in row {
            assert!(
                !field.trim().is_empty()
                    && !field.contains("TODO")
                    && !field.contains("TBD")
                    && !field.contains("unclassified"),
                "invalid RIURD inventory field in row {:?}",
                row
            );
        }
        surfaces.insert(row[2].clone());
        for id in row[7].split(',') {
            covered_rows.insert(id.to_owned());
        }
    }
    for surface in allowed_surfaces {
        assert!(surfaces.contains(surface), "missing surface {surface}");
    }
    for row_id in 0..=10 {
        assert!(
            covered_rows.contains(&format!("RIURD-{row_id}")),
            "RIURD inventory does not cover RIURD-{row_id}"
        );
    }
    for required_path in [
        "scripts/tron",
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/manual-deploy.sh",
        "scripts/tron-lib.d/service.sh",
        "scripts/tron-lib.d/logs.sh",
        ".github/workflows/ci.yml",
        ".github/workflows/release-mac.yml",
        ".codex/environments/environment.toml",
        "packages/agent/src/shared/foundation/paths/mod.rs",
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/app/bootstrap/server.rs",
        "packages/mac-app/project.yml",
        "packages/mac-app/Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift",
        "packages/mac-app/Sources/Server/ProcessControl/DevServerStopper.swift",
        "packages/mac-app/Sources/App/Lifecycle/MacAppStartupMaintenance.swift",
        "packages/ios-app/project.yml",
        "README.md",
    ] {
        assert!(
            rows.iter().any(|row| row[1] == required_path),
            "RIURD inventory missing required path {required_path}"
        );
    }
}

#[test]
fn port_9847_and_process_ownership_are_source_guarded() {
    let tron_lib = read_repo_file("scripts/tron-lib.sh");
    assert!(tron_lib.contains("PROD_PORT=9847"));
    assert!(tron_lib.contains("DEV_PLIST_NAME=\"com.tron.server.dev-takeover\""));
    assert!(tron_lib.contains("RELEASE_APP=\"/Applications/Tron.app\""));

    let dev = read_repo_file("scripts/tron.d/dev.sh");
    for required in [
        "launchd_stop \"$DEV_PLIST_NAME\"",
        "launchd_stop \"$PLIST_NAME\"",
        "wait_for_port_free \"$PROD_PORT\" 10",
        "create_app_bundle \"$DEV_BUNDLE\"",
        "create_dev_launchd_plist",
        "restart_installed_service_after_dev 12",
        "listener_pid_for_port \"$PROD_PORT\"",
    ] {
        assert!(dev.contains(required), "dev.sh missing {required}");
    }
    assert!(
        !dev.contains("cmd_manual_deploy") && !dev.contains("manual-deploy"),
        "dev workflow must not invoke manual deploy"
    );

    let manual = read_repo_file("scripts/tron.d/manual-deploy.sh");
    for required in [
        "Dev server is running on port $PROD_PORT",
        "Stop dev first with Ctrl+C or: tron dev --stop",
        "service_is_running && wait_for_service_health 12",
        "restore_contributor_backup",
    ] {
        assert!(
            manual.contains(required),
            "manual-deploy missing {required}"
        );
    }

    let live_manager =
        read_repo_file("packages/mac-app/Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift");
    for required in [
        "shouldRefuseExternalServer",
        "portBound || databaseLockHeld",
        "isPortBound(TronPaths.defaultServerPort)",
        "isDatabaseLockHeld()",
        "runtimeRequiresReplacement",
        "shouldRefreshRegistrationForCurrentBundle",
        "shouldRefreshRegistrationForLaunchConstraints",
    ] {
        assert!(
            live_manager.contains(required),
            "LiveLaunchAgentManager missing {required}"
        );
    }

    let stopper =
        read_repo_file("packages/mac-app/Sources/Server/ProcessControl/DevServerStopper.swift");
    assert_order(
        &stopper,
        "guard let process = await probe(port), process.isDevServer else",
        "signal(process.pid, sigterm)",
        "DevServerStopper must verify dev ownership before signaling",
    );

    let prod_plist = read_repo_file(
        "packages/mac-app/Sources/Resources/Library/LaunchAgents/com.tron.server.plist",
    );
    assert!(prod_plist.contains("<string>com.tron.server</string>"));
    assert!(prod_plist.contains("<string>9847</string>"));
    assert!(prod_plist.contains("Tron Server.app/Contents/MacOS/tron"));
    let isolated_plist = read_repo_file(
        "packages/mac-app/Sources/Resources/Library/LaunchAgents/com.tron.server.dev.plist",
    );
    assert!(isolated_plist.contains("<string>com.tron.server.dev</string>"));
    assert!(isolated_plist.contains("<string>9848</string>"));
    assert!(isolated_plist.contains("<key>TRON_HOME_NAME</key>"));
}

#[test]
fn manual_deploy_and_rollback_fail_closed_on_unhealthy_helpers() {
    let manual = read_repo_file("scripts/tron.d/manual-deploy.sh");
    assert_order(
        &manual,
        "if service_is_running && wait_for_service_health 12; then",
        "echo \"$new_commit\" > \"$DEPLOYED_COMMIT_FILE\"",
        "manual deploy must health-check before advancing deployed commit",
    );
    assert_order(
        &manual,
        "if service_is_running && wait_for_service_health 12; then",
        "write_restart_sentinel \"deploy\" \"$new_commit\" \"$previous_commit\" \"completed\"",
        "manual deploy must complete sentinel only after health passes",
    );
    let failure_tail = manual
        .split_once("Service started but did not pass /health; failing deploy closed.")
        .map(|(_, tail)| tail)
        .expect("manual deploy missing unhealthy-helper failure marker");
    assert_order(
        failure_tail,
        "write_deployment_result \"failed\" \"$failure_reason\"",
        "return 1",
        "manual deploy unhealthy helper must return failure after recording failure evidence",
    );
    for required in [
        "write_restart_sentinel \"deploy\" \"$new_commit\" \"$previous_commit\" \"rolled_back\"",
        "write_restart_sentinel \"deploy\" \"$new_commit\" \"$previous_commit\" \"failed\"",
        "TRON_DEPLOYMENT_COMMIT=\"$new_commit\"",
        "TRON_DEPLOYMENT_PREVIOUS_COMMIT=\"$previous_commit\"",
    ] {
        assert!(
            manual.contains(required),
            "manual deploy missing {required}"
        );
    }
    assert_order(
        &manual,
        "launchd_stop \"$PLIST_NAME\"",
        "create_app_bundle \"$INSTALLED_BUNDLE\" \"$CONTRIBUTOR_DIR/tron.bak\"",
        "rollback helper must stop an unhealthy candidate before restoring backup bundle",
    );
    assert_order(
        &manual,
        "wait_for_port_free \"$PROD_PORT\" 10 || return 1",
        "create_app_bundle \"$INSTALLED_BUNDLE\" \"$CONTRIBUTOR_DIR/tron.bak\"",
        "rollback helper must wait for port 9847 to clear before restoring backup bundle",
    );
    for forbidden in [
        "Health check failed — server may still be starting",
        "Monitor with: tron status",
    ] {
        assert!(
            !manual.contains(forbidden),
            "manual deploy must not soft-pass unhealthy helper: {forbidden}"
        );
    }

    let service = read_repo_file("scripts/tron-lib.d/service.sh");
    assert_order(
        &service,
        "if service_is_running && wait_for_service_health 12; then",
        "write_deployment_result \"rolled_back\" \"Manual rollback\"",
        "manual rollback success must be health-gated",
    );
    let rollback_failure_tail = service
        .split_once("write_deployment_result \"failed\" \"Manual rollback did not pass health\"")
        .map(|(_, tail)| tail)
        .expect("manual rollback missing failed deployment evidence marker");
    assert!(
        rollback_failure_tail.contains("exit 1"),
        "manual rollback health failure must exit nonzero after recording evidence"
    );
}

#[test]
fn setup_install_uninstall_and_clean_machine_boundaries_are_narrow() {
    let tron_lib = read_repo_file("scripts/tron-lib.sh");
    for required in [
        "ensure_tron_home()",
        "$TRON_HOME\"/internal/{database,run}",
        "$DEFAULT_PROFILE_DIR\" \"$NORMAL_PROFILE_DIR\" \"$CHAT_PROFILE_DIR\" \"$LOCAL_PROFILE_DIR\" \"$USER_PROFILE_DIR",
        "$WORKSPACE_DIR\"/{projects,plans,reports,renders,screenshots,scratch,labs,archive}",
        "Standalone settings JSON is intentionally not created here",
        "chmod 600 \"$AUTH_FILE\"",
    ] {
        assert!(tron_lib.contains(required), "tron-lib missing {required}");
    }

    let manual = read_repo_file("scripts/tron.d/manual-deploy.sh");
    for required in [
        "cmd_setup()",
        "ensure_tron_home",
        "ensure_default_configs",
        "cmd_install()",
        "--gui-helper",
        "--skip-service-start",
        "Machine-readable contributor runs skip launchctl",
    ] {
        assert!(
            manual.contains(required),
            "setup/install path missing {required}"
        );
    }

    let service = read_repo_file("scripts/tron-lib.d/service.sh");
    for required in [
        "cmd_uninstall()",
        "--reset-settings",
        "--reset-credentials",
        "Database and workspace data preserved",
        "clear_user_profile_settings",
        "rm -f \"$AUTH_FILE\"",
    ] {
        assert!(
            service.contains(required),
            "uninstall path missing {required}"
        );
    }

    let paths = read_repo_file("packages/mac-app/Sources/Server/Paths/TronPaths.swift");
    for required in [
        "productionServerPort = 9847",
        "isolatedServerPort = 9848",
        "releaseApplicationURL = URL(fileURLWithPath: \"/Applications/Tron.app\"",
        "TRON_MAC_INSTALL_MODE",
        "TRON_HOME_NAME",
    ] {
        assert!(paths.contains(required), "TronPaths missing {required}");
    }

    let uninstaller =
        read_repo_file("packages/mac-app/Sources/Server/ProcessControl/TronUninstaller.swift");
    assert!(uninstaller.contains("preserveUserData"));
    assert!(uninstaller.contains("removeSettingsOverlay"));
    assert!(uninstaller.contains("setup.bearerTokenPath"));
    assert!(
        !uninstaller.contains("database") && !uninstaller.contains("workspace"),
        "Mac uninstall must not delete durable database/workspace data"
    );
}

#[test]
fn generated_project_and_release_packaging_policy_is_guarded() {
    assert!(
        !repo_path("packages/mac-app/Project.swift").exists(),
        "Mac app uses XcodeGen project.yml in this checkout, not Project.swift"
    );
    assert!(repo_path("packages/mac-app/project.yml").exists());
    assert!(repo_path("packages/ios-app/project.yml").exists());

    let ci = read_repo_file(".github/workflows/ci.yml");
    for required in [
        "working-directory: packages/ios-app",
        "run: xcodegen generate",
        "git diff --exit-code packages/ios-app/TronMobile.xcodeproj",
        "working-directory: packages/mac-app",
        "git check-ignore -q packages/mac-app/TronMac.xcodeproj",
        "Dry-run DMG assembly",
    ] {
        assert!(ci.contains(required), "CI missing {required}");
    }

    let release_mac = read_repo_file(".github/workflows/release-mac.yml");
    for required in [
        "scripts/tron version check",
        "./scripts/bundle-agent.sh --skip-build",
        "xcodegen generate",
        "git check-ignore -q packages/mac-app/TronMac.xcodeproj",
        "Sign embedded Tron Server helper",
        "Notarize DMG",
        "Staple DMG",
        "gh release",
    ] {
        assert!(
            release_mac.contains(required),
            "Mac release workflow missing {required}"
        );
    }

    let release_ios = read_repo_file(".github/workflows/release-ios.yml");
    for required in [
        "xcodegen generate",
        "git diff --exit-code packages/ios-app/TronMobile.xcodeproj",
        "dry_run",
        "asc builds upload",
    ] {
        assert!(
            release_ios.contains(required),
            "iOS release workflow missing {required}"
        );
    }

    let mac_gitignore = read_repo_file("packages/mac-app/.gitignore");
    assert!(mac_gitignore.contains("TronMac.xcodeproj/"));
}

#[test]
fn dev_quality_environment_and_app_wrapper_do_not_hide_production_deploys() {
    for path in [
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/quality.sh",
        ".codex/environments/environment.toml",
    ] {
        let source = read_repo_file(path);
        for forbidden in [
            "manual-deploy",
            "cmd_manual_deploy",
            " tron deploy",
            "cmd_deploy",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not hide production deploy path {forbidden}"
            );
        }
    }

    let mac_sources = git_ls_files("packages/mac-app/Sources");
    for path in mac_sources {
        if !is_text_mac_source(&path) {
            continue;
        }
        let source = read_repo_file(&path);
        for forbidden in [
            "manual-deploy",
            "cmd_manual_deploy",
            "tron deploy",
            "scripts/tron deploy",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not invoke production deploy path {forbidden}"
            );
        }
    }

    let workspace_cli = read_repo_file("scripts/tron");
    assert!(workspace_cli.contains("manual-deploy) shift; cmd_manual_deploy"));
    assert!(
        !workspace_cli
            .lines()
            .any(|line| line.trim_start().starts_with("deploy)")),
        "old tron deploy dispatcher alias must not return"
    );
    let installed_cli = read_repo_file("scripts/tron-cli");
    assert!(installed_cli.contains("dev|manual-deploy|ci|bench|version|preflight|setup|install"));
    assert!(
        !installed_cli
            .lines()
            .any(|line| line.trim_start().starts_with("deploy)")),
        "installed CLI must not expose old deploy alias"
    );
}

#[test]
fn predecessor_inventory_wiring_is_recorded() {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    for predecessor in [
        "configuration-profile-environment-discipline-inventory.tsv",
        "performance-resource-governance-inventory.tsv",
        "provider-model-boundary-discipline-inventory.tsv",
        "public-protocol-api-contract-discipline-inventory.tsv",
        "off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
        "data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "observability-diagnostics-auditability-inventory.tsv",
        "security-authority-capability-boundaries-inventory.tsv",
        "concurrency-scheduling-discipline-inventory.tsv",
        "state-ownership-lifecycle-inventory.tsv",
        "failure-semantics-inventory.tsv",
        "determinism-replayability-inventory.tsv",
        "true-primitive-cleanup-retention-inventory.tsv",
        "hierarchical-rearchitecture-file-inventory.tsv",
        "hierarchical-rearchitecture-current-ownership-map.tsv",
        "primitive-code-cleanup-file-inventory.tsv",
    ] {
        assert!(
            inventory.contains(predecessor),
            "RIURD inventory missing predecessor audit path {predecessor}"
        );
    }

    for path in [
        "packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv",
        "packages/agent/docs/performance-resource-governance-inventory.tsv",
        "packages/agent/docs/provider-model-boundary-discipline-inventory.tsv",
        "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv",
        "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
        "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "packages/agent/docs/observability-diagnostics-auditability-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv",
        "packages/agent/docs/state-ownership-lifecycle-inventory.tsv",
        "packages/agent/docs/failure-semantics-inventory.tsv",
        "packages/agent/docs/determinism-replayability-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
    ] {
        let predecessor = read_repo_file(path);
        assert!(
            predecessor.contains("Release / Install / Upgrade / Rollback Discipline")
                || predecessor.contains("release-install-upgrade-rollback-discipline")
                || predecessor.contains(TARGET_NAME),
            "{path} missing RIURD predecessor inventory marker"
        );
    }
}
