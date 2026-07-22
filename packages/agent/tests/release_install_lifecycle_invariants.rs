//! Source-backed contributor service lifecycle and hosted release invariants.

use std::path::{Path, PathBuf};
use std::process::Command;

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
        .filter(|path| repo_path(path).is_file())
        .map(str::to_owned)
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

fn probe_dev_command(args: &[&str]) -> (i32, String, String) {
    let output = Command::new("bash")
        .arg("-c")
        .arg(
            r#"
source "$DEV_SCRIPT"
require_project_dir() { :; }
load_dev_relay_environment() { :; }
print_error() { printf '%s\n' "$1" >&2; }
build_rust_dev() { printf '%s\n' build; }
run_tests() { printf '%s\n' test; }
dev_start_foreground() { printf '%s\n' start-foreground; }
dev_start_background() { printf '%s\n' start-background; }
cmd_dev "$@"
"#,
        )
        .arg("bash")
        .args(args)
        .env("DEV_SCRIPT", repo_path("scripts/tron.d/dev.sh"))
        .output()
        .expect("dev build sequence probe should start");
    let stdout = String::from_utf8(output.stdout)
        .expect("dev build sequence probe output should be UTF-8")
        .lines()
        .collect::<Vec<_>>()
        .join(",");
    let stderr = String::from_utf8(output.stderr)
        .expect("dev build sequence probe error should be UTF-8")
        .trim()
        .to_owned();
    (output.status.code().unwrap_or(-1), stdout, stderr)
}

fn probe_install_command(args: &[&str]) -> std::process::Output {
    Command::new("bash")
        .arg("-c")
        .arg(
            r#"
source "$INSTALL_SCRIPT"
print_error() { printf '%s\n' "$1" >&2; }
require_project_dir() { printf '%s\n' require-project; }
build_rust() { printf '%s\n' build; }
cmd_install "$@"
"#,
        )
        .arg("bash")
        .args(args)
        .env(
            "INSTALL_SCRIPT",
            repo_path("scripts/tron.d/manual-deploy.sh"),
        )
        .output()
        .expect("install parser probe should start")
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
        "listener_pid_for_port \"$PROD_PORT\"",
    ] {
        assert!(dev.contains(required), "dev.sh missing {required}");
    }
    assert_eq!(
        dev.matches("service_start").count(),
        11,
        "every dev exit, stop, and takeover failure must use the shared service start owner"
    );
    assert!(
        !dev.contains("restart_installed_service_after_dev"),
        "dev workflow must not recreate a separate installed-service restore owner"
    );
    assert!(
        !dev.contains("cmd_manual_deploy") && !dev.contains("manual-deploy"),
        "dev workflow must not invoke manual deploy"
    );
    assert!(
        !dev.contains("cargo build --profile dev-server"),
        "cmd_dev must delegate its one build to the workspace build owner"
    );
    let build_sequences: [(&[&str], &str); 4] = [
        (&[], "build,start-foreground"),
        (&["-t"], "test,build,start-foreground"),
        (&["-b"], "build,start-foreground"),
        (&["-bdt"], "build,test,start-background"),
    ];
    for (args, expected) in build_sequences {
        let (status, actual, stderr) = probe_dev_command(args);
        assert_eq!(status, 0, "cmd_dev failed for {args:?}: {stderr}");
        assert_eq!(
            actual, expected,
            "cmd_dev must build exactly once before takeover for {args:?}"
        );
    }
    let invalid_waits: [&[&str]; 2] = [&["-d", "--wait", "0"], &["-bdt", "--wait", "soon"]];
    for args in invalid_waits {
        let (status, output, error) = probe_dev_command(args);
        assert_eq!(status, 2, "invalid --wait must exit 2 for {args:?}");
        assert!(output.is_empty(), "invalid --wait must not start work");
        assert_eq!(error, "--wait must be a positive integer number of seconds");
    }
    let failed_background_sign = Command::new("bash")
        .args([
            "-c",
            "source \"$1\"; print_status() { :; }; print_error() { last_error=\"$1\"; }; launchd_stop() { :; }; launchctl() { return 1; }; service_is_running() { return 0; }; wait_for_port_free() { return 0; }; create_app_bundle() { return 0; }; service_start() { restored=true; }; DEV_PLIST_NAME=test.dev; PLIST_NAME=test.prod; PROD_PORT=9847; TRON_HOME=/nonexistent; RUST_WORKSPACE=/nonexistent; DEV_SERVER_BINARY=/nonexistent/source-tron; DEV_BUNDLE=/nonexistent/Tron-Dev.app; DEV_BINARY=/nonexistent/tron; DEV_PLIST_PATH=/nonexistent/dev.plist; RUN_DIR=/nonexistent; DEV_BACKGROUND_PID_FILE=/nonexistent/pid; if create_dev_launchd_plist; then exit 11; fi; run_failure() { restored=false; last_error=; case \"$1\" in sign) codesign_bundle() { return 1; }; mkdir() { return 0; }; DEV_BACKGROUND_LOG=/dev/null; create_dev_launchd_plist() { return 0; }; expected='Failed to prepare signed dev takeover bundle' ;; mkdir) codesign_bundle() { return 0; }; mkdir() { return 1; }; DEV_BACKGROUND_LOG=/dev/null; create_dev_launchd_plist() { return 0; }; expected='Failed to create dev takeover runtime directory' ;; log) codesign_bundle() { return 0; }; mkdir() { return 0; }; DEV_BACKGROUND_LOG=/nonexistent/log; create_dev_launchd_plist() { return 0; }; expected='Failed to initialize dev takeover log' ;; plist) codesign_bundle() { return 0; }; mkdir() { return 0; }; DEV_BACKGROUND_LOG=/dev/null; create_dev_launchd_plist() { return 1; }; expected='Failed to create dev takeover LaunchAgent' ;; esac; if dev_start_background false 1; then return 10; fi; test \"$restored\" = true && test \"$last_error\" = \"$expected\"; }; run_failure sign && run_failure mkdir && run_failure log && run_failure plist",
            "bash",
            repo_path("scripts/tron.d/dev.sh")
                .to_str()
                .expect("dev helper path should be utf8"),
        ])
        .stderr(std::process::Stdio::null())
        .status()
        .expect("background dev signing failure smoke should run");
    assert!(
        failed_background_sign.success(),
        "background dev must restore the installed helper when takeover preparation fails"
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
fn contributor_binary_recovery_has_one_service_owner() {
    let service = read_repo_file("scripts/tron-lib.d/service.sh");
    let definitions: Vec<_> = git_ls_files("scripts/tron-lib.d")
        .into_iter()
        .chain(git_ls_files("scripts/tron.d"))
        .filter(|path| path.ends_with(".sh"))
        .filter(|path| read_repo_file(path).contains("ensure_prod_binary() {"))
        .collect();

    assert_eq!(
        definitions,
        ["scripts/tron-lib.d/service.sh"],
        "workspace modules must not override shared service recovery by source order"
    );
    let tron_lib = read_repo_file("scripts/tron-lib.sh");
    let workspace_cli = read_repo_file("scripts/tron");
    for (path, source) in [
        ("scripts/tron-lib.sh", tron_lib.as_str()),
        ("scripts/tron", workspace_cli.as_str()),
        ("scripts/tron-lib.d/service.sh", service.as_str()),
    ] {
        assert!(
            !source.contains("SERVICE_RECOVERY_RELEASE_BINARY"),
            "{path} must not recover an installed helper from an unverifiable workspace build"
        );
    }
    let recovery = service
        .split_once("ensure_prod_binary() {")
        .expect("service recovery command missing")
        .1
        .split_once("service_start() {")
        .expect("service recovery owner has no boundary")
        .0;
    for required in [
        "local pair_backup=\"$CONTRIBUTOR_DIR/contributor-pair.bak\"",
        "local backup_binary=\"$pair_backup/Tron-Deploy.app/Contents/MacOS/tron\"",
        "begin_contributor_pair_update rollback || return 1",
        "restore_contributor_pair_plan || return 1",
        "CONTRIBUTOR_PAIR_RECOVERY_PENDING=1",
        "No valid contributor service binary found. Run: tron manual-deploy",
    ] {
        assert!(
            recovery.contains(required),
            "service recovery missing {required}"
        );
    }
    for single_owner in [
        "launchctl kickstart -k \"$target\"",
        "launchctl bootstrap \"gui/$(id -u)\" \"$plist\"",
        "RELEASE_LAUNCH_AGENT_PLIST",
        "--tron-start-server-and-quit",
    ] {
        assert_eq!(service.matches(single_owner).count(), 1, "{single_owner}");
    }
    let service_start = service
        .split_once("service_start() {")
        .expect("service start command missing")
        .1
        .split_once("service_stop() {")
        .expect("service start owner has no boundary")
        .0;
    assert_order(
        service_start,
        "\"$RELEASE_APP_BINARY\" --tron-start-server-and-quit",
        "wait_for_service_health 5",
        "installed wrapper starts must stay wrapper-owned and health-gated",
    );
    assert_order(
        service_start,
        "ensure_prod_binary",
        "launchd_restart \"$PLIST_NAME\"",
        "the contributor start path must remain owned by the shared service owner",
    );
    assert_order(
        service_start,
        "if service_is_running && wait_for_service_health 12; then",
        "finish_contributor_pair_recovery || return 1",
        "recovery must pass health before retiring its rollback plan",
    );
    for retired in [
        "ensure_restartable_prod_server() {",
        "release_wrapper_available() {",
        "restart_installed_service_after_dev() {",
    ] {
        assert!(
            !service.contains(retired),
            "service module must not retain duplicate start indirection {retired}"
        );
    }
}

#[test]
fn manual_deploy_and_rollback_fail_closed_on_unhealthy_helpers() {
    let manual = read_repo_file("scripts/tron.d/manual-deploy.sh");
    let deploy = manual
        .split_once("cmd_manual_deploy() {")
        .expect("manual deploy command missing")
        .1;
    assert_order(
        deploy,
        "backup_contributor_pair",
        "install_runtime_cli_payload",
        "manual deploy must publish the prior pair before replacing its CLI",
    );
    assert_order(
        deploy,
        "if service_is_running && wait_for_service_health 12; then",
        "printf '%s\\n' \"$new_commit\" > \"$DEPLOYED_COMMIT_FILE\"",
        "manual deploy must health-check before advancing deployed commit",
    );
    assert_order(
        &manual,
        "if service_is_running && wait_for_service_health 12; then",
        "\"deploy\" \"$new_commit\" \"$previous_commit\" \"completed\"",
        "manual deploy must complete sentinel only after health passes",
    );
    let failure_tail = deploy
        .split_once("Service started but did not pass /health; failing deploy closed.")
        .map(|(_, tail)| tail)
        .expect("manual deploy missing unhealthy-helper failure marker");
    assert!(
        failure_tail.contains("record_failed_contributor_deploy"),
        "manual deploy unhealthy helper must enter paired rollback handling"
    );
    for required in [
        "record_failed_contributor_deploy()",
        "\"deploy\" \"$new_commit\" \"$previous_commit\" \"rolled_back\"",
        "\"deploy\" \"$new_commit\" \"$previous_commit\" \"failed\"",
        "restore_contributor_pair_plan || return 1",
        "discard_contributor_pair_backup rollback",
        "begin_contributor_pair_update manual-deploy || return 1",
        "end_contributor_pair_update || return 1",
        "contributor-pair.bak",
    ] {
        assert!(
            manual.contains(required),
            "manual deploy missing {required}"
        );
    }
    assert_order(
        &manual,
        "launchd_stop \"$PLIST_NAME\"",
        "restore_contributor_pair_plan || return 1",
        "rollback helper must stop an unhealthy candidate before restoring backup bundle",
    );
    assert_order(
        &manual,
        "wait_for_port_free \"$PROD_PORT\" 10 || return 1",
        "restore_contributor_pair_plan || return 1",
        "rollback helper must wait for port 9847 to clear before restoring backup bundle",
    );
    for forbidden in [
        "tron.bak",
        "runtime-cli.bak",
        "Health check failed — server may still be starting",
        "Monitor with: tron status",
    ] {
        assert!(
            !manual.contains(forbidden),
            "manual deploy must not soft-pass unhealthy helper: {forbidden}"
        );
    }

    let service = read_repo_file("scripts/tron-lib.d/service.sh");
    for required in [
        "begin_contributor_pair_update()",
        "backup_contributor_pair()",
        "contributor_pair_backup_kind()",
        "validate_contributor_bundle()",
        "restore_contributor_bundle()",
        "restore_contributor_entrypoints()",
        "restore_runtime_cli_payload()",
        "restore_contributor_pair_plan()",
        "end_contributor_pair_update()",
        "begin_contributor_pair_read()",
        "end_contributor_pair_read()",
        "contributor-pair.bak",
        ".contributor-pair.bak.staging",
        ".contributor-pair.bak.committed",
        ".contributor-pair.bak.restored",
        "no-prior-pair",
        "mv \"$staging_dir\" \"$backup_dir\"",
        "mv \"$backup_dir\" \"$discard_dir\"",
        "/usr/bin/lockf -s -t 0 9",
        "/usr/bin/lockf -s -t 0 8",
        "deployed-commit",
    ] {
        assert!(
            service.contains(required),
            "paired runtime rollback missing {required}"
        );
    }
    assert_order(
        &service,
        "ditto \"$INSTALLED_BUNDLE\" \"$staging_dir/Tron-Deploy.app\"",
        "mv \"$staging_dir\" \"$backup_dir\"",
        "the complete signed bundle must be validated before atomic plan publication",
    );
    assert_order(
        &service,
        "restore_contributor_bundle || return 1",
        "restore_runtime_cli_payload || return 1",
        "rollback must restore the signed bundle before exposing its matching CLI",
    );
    let rollback_failure_tail = service
        .split_once("Rollback restored the backup, but the service did not become healthy")
        .map(|(_, tail)| tail)
        .expect("manual rollback missing unhealthy-backup failure marker");
    assert!(
        rollback_failure_tail.contains("exit 1"),
        "manual rollback health failure must exit nonzero"
    );
    assert_order(
        &service,
        "if ! service_is_running || ! wait_for_service_health 12; then",
        "Service restarted from healthy backup",
        "manual rollback success must be health-gated",
    );
    let rollback_success = service
        .split_once("Service restarted from healthy backup")
        .map(|(_, tail)| tail)
        .expect("manual rollback missing healthy-backup success path");
    assert!(
        rollback_success.contains("discard_contributor_pair_backup rollback || exit 1"),
        "manual rollback must atomically retire its pair backup after health passes"
    );

    let logs = read_repo_file("scripts/tron-lib.d/logs.sh");
    assert!(
        !manual.contains("last-deployment.json") && !logs.contains("last-deployment.json"),
        "restart-sentinel.json must remain the sole manual-deploy outcome projection"
    );
    assert!(
        service.contains("\"$CONTRIBUTOR_DIR/last-deployment.json\""),
        "uninstall must remove the retired result file left by older installations"
    );
}

#[test]
fn setup_install_uninstall_and_clean_machine_boundaries_are_narrow() {
    let tron_lib = read_repo_file("scripts/tron-lib.sh");
    for required in [
        "Shared contributor-shell paths and functions",
        "Rust foundation owners define the complete runtime home layout",
        "RUN_DIR=\"$TRON_HOME/internal/run\"",
        "AUTH_FILE=\"$TRON_HOME/auth.json\"",
        "DEPLOY_UPDATE_FILE=\"$RUN_DIR/deploy.in-progress\"",
    ] {
        assert!(tron_lib.contains(required), "tron-lib missing {required}");
    }

    let manual = read_repo_file("scripts/tron.d/manual-deploy.sh");
    for required in [
        "cmd_setup()",
        "cmd_install()",
        "print_status \"Starting service...\"",
        "service_is_running && wait_for_service_health 12",
        "completed on first server start",
    ] {
        assert!(
            manual.contains(required),
            "setup/install path missing {required}"
        );
    }
    let invalid_install = probe_install_command(&["--unknown"]);
    assert_eq!(
        invalid_install.status.code(),
        Some(2),
        "unknown install options must exit 2"
    );
    assert!(
        invalid_install.stdout.is_empty(),
        "invalid options must fail before work"
    );
    assert_eq!(
        String::from_utf8_lossy(&invalid_install.stderr).trim(),
        "Unknown install option: --unknown"
    );
    let tron = read_repo_file("scripts/tron");
    let installed_cli = read_repo_file("scripts/tron-cli");
    assert!(
        tron.contains("TRON_BUNDLE_ID=\"com.tron.agent\""),
        "the workspace entrypoint must own its contributor helper bundle identifier"
    );
    assert!(
        !tron_lib.contains("TRON_BUNDLE_ID") && !tron_lib.contains("require_installed"),
        "the installed shared CLI library must not retain workspace-only bundle or install helpers"
    );
    assert!(
        manual.contains("if [ ! -f \"$PLIST_PATH\" ]; then")
            && manual.contains("Contributor service is not installed. Run: tron install"),
        "manual deploy must own its contributor-install prerequisite"
    );
    for (path, source) in [
        ("scripts/tron-lib.sh", tron_lib.as_str()),
        ("scripts/tron", tron.as_str()),
        ("scripts/tron-cli", installed_cli.as_str()),
        ("scripts/tron.d/manual-deploy.sh", manual.as_str()),
    ] {
        for forbidden in ["ensure_tron_home", "ensure_default_configs"] {
            assert!(
                !source.contains(forbidden),
                "{path} must not duplicate Rust startup ownership with {forbidden}"
            );
        }
    }
    for retired in [
        "memory/{rules,sessions}",
        "projects,plans,reports",
        "prompts,providers,context,tools",
    ] {
        assert!(
            !tron_lib.contains(retired),
            "shell layout must not restore retired path set {retired}"
        );
    }

    let auth = read_repo_file("scripts/tron-lib.d/auth.sh");
    assert!(
        installed_cli.contains("unset RUST_WORKSPACE"),
        "installed OAuth must ignore mutable workspace input and use its paired helper"
    );
    assert!(
        !installed_cli.contains("RUST_WORKSPACE=\"${_WORKSPACE_PATH}/packages/agent\""),
        "installed OAuth must not execute mutable checkout source"
    );
    for required in [
        "_auth_storage_is_initialized",
        "Start the Tron server once, then retry login",
        "_run_tron_auth_owner",
        "_run_with_contributor_pair_read",
        "printf '%s\\0'",
        "_run_tron_auth_owner begin-oauth anthropic",
        "_run_tron_auth_owner begin-oauth openai-codex",
        "| _run_tron_auth_owner complete-oauth",
        "expected_state",
        "completion_kind",
        "begin_contributor_pair_read",
        "end_contributor_pair_read",
        "\" 8>&- 9>&- &",
    ] {
        assert!(auth.contains(required), "auth helper missing {required}");
    }
    for forbidden in [
        "mktemp \"${AUTH_FILE}",
        "mv -f \"$tmp_file\" \"$AUTH_FILE\"",
        "--arg accessToken",
        "--arg refreshToken",
        "openssl rand",
        "curl -s -w",
        "ANTHROPIC_OAUTH_",
        "OPENAI_OAUTH_",
        "store-oauth",
    ] {
        assert!(
            !auth.contains(forbidden) && !tron_lib.contains(forbidden),
            "shell auth surface must defer provider protocol and storage: {forbidden}"
        );
    }
    assert!(
        !auth.contains("elif [[ -x \"$DEV_BINARY\" ]]")
            && auth.contains("installed Tron CLI has no paired helper binary"),
        "installed auth must use only its paired helper binary"
    );
    assert!(
        auth.contains("        rotate)\n            shift\n            # The Rust owner serializes rotation with every other auth writer.\n            _run_with_contributor_pair_read _run_tron_auth_owner rotate \"$@\"\n            ;;"),
        "auth rotate arm must shift the action and hold the pair reader mutex around the exact Rust owner invocation"
    );
    assert!(
        !auth.contains("cmd_auth_rotate"),
        "auth rotate must not regain a single-caller forwarding wrapper"
    );
    assert_eq!(manual.matches("install_runtime_cli_payload").count(), 3);
    assert_eq!(manual.matches("tron-cli,tron-lib.sh,tron-agent").count(), 1);
    assert_eq!(manual.matches("workspace-path").count(), 1);
    assert!(manual.contains("cp \"$PROJECT_DIR/packages/mac-app/Sources/Resources/AppIcon.icns\""));
    assert!(manual.contains("\"$CONTRIBUTOR_DIR/AppIcon.icns\""));
    let install = manual
        .split_once("cmd_install() {")
        .expect("install command missing")
        .1;
    assert!(
        !install.contains("prebuilt: $RELEASE_BINARY"),
        "install must not pair current shell sources with an unverified prebuilt helper"
    );
    assert_order(
        install,
        "build_rust",
        "begin_contributor_pair_update",
        "install must build the helper from current source before acquiring its pair lock",
    );
    assert_order(
        install,
        "begin_contributor_pair_update",
        "backup_contributor_pair",
        "install must acquire the pair lock before publishing its rollback plan",
    );
    assert_order(
        install,
        "backup_contributor_pair",
        "install_runtime_cli_payload",
        "install must publish a rollback plan before replacing its runtime payload",
    );
    assert_order(
        install,
        "install_runtime_cli_payload",
        "create_app_bundle \"$INSTALLED_BUNDLE\" \"$RELEASE_BINARY\"",
        "clean installs must stage the required helper icon before bundle construction",
    );
    assert_order(
        install,
        "wait_for_service_health 12",
        "printf '%s\\n' \"$current_commit\" > \"$DEPLOYED_COMMIT_FILE\"",
        "install must health-gate its deployed commit marker",
    );
    let committed_install = install
        .split_once("printf '%s\\n' \"$current_commit\" > \"$DEPLOYED_COMMIT_FILE\"")
        .map(|(_, tail)| tail)
        .expect("install must record its durable commit marker");
    assert!(
        committed_install.contains("end_contributor_pair_update || return 1"),
        "install must release the pair lock only after its durable commit marker"
    );
    assert_order(
        install,
        "discard_contributor_pair_backup || return 1",
        "end_contributor_pair_update || return 1",
        "install must retire its validated rollback plan before releasing readers",
    );
    let setup = manual
        .split_once("cmd_setup() {")
        .expect("setup command missing")
        .1;
    for required in [
        "begin_contributor_pair_update setup",
        "if contributor_pair_is_complete; then",
        "Preserved installed CLI",
        "ln -sf \"$SCRIPT_DIR/tron\" \"$BIN_DIR/tron\"",
        "end_contributor_pair_update",
    ] {
        assert!(setup.contains(required), "setup path missing {required}");
    }
    assert_order(
        setup,
        "begin_contributor_pair_update setup",
        "ln -sf \"$SCRIPT_DIR/tron\" \"$BIN_DIR/tron\"",
        "setup must lock the shared entrypoint before linking workspace source",
    );
    assert!(
        !setup.contains("install_runtime_cli_payload"),
        "workspace setup must not replace the installed helper/CLI pair"
    );
    let installer = manual
        .split_once("install_runtime_cli_payload() {")
        .expect("runtime CLI installer missing")
        .1;
    assert_order(
        installer,
        "contributor_pair_update_is_owned",
        "cp \"$SCRIPT_DIR\"/{tron-cli,tron-lib.sh,tron-agent.entitlements}",
        "the runtime CLI installer must reject unlocked callers",
    );
    assert!(
        !repo_path("scripts/AppIcon.icns").exists(),
        "the Mac resource must remain the sole helper icon owner"
    );

    let bundle = read_repo_file("scripts/tron.d/bundle.sh");
    assert!(bundle.contains("$PROJECT_DIR/packages/mac-app/Sources/Resources/AppIcon.icns"));
    assert!(!bundle.contains("$CONTRIBUTOR_DIR/AppIcon.icns"));
    assert!(bundle.contains("\"$SCRIPT_DIR/tron-version\" print"));
    assert!(bundle.contains("TRON_APPLE_MARKETING_VERSION)"));
    assert!(bundle.contains("TRON_APPLE_BUILD)"));
    assert!(!bundle.contains("bundle_version_env_value"));
    assert!(!bundle.contains("\"$PROJECT_DIR/VERSION.env\""));
    assert!(!bundle.contains("${3:-}"));
    assert!(!bundle.contains("%%-*"));
    assert!(!bundle.contains("workspace-path"));
    assert!(bundle.contains("print_error \"Code signing failed\""));
    assert!(!repo_path("scripts/tron-lib.d/bundle.sh").exists());
    for retired in [
        "tron_version_env_file",
        "tron_version_env_value",
        "tron_marketing_version",
    ] {
        assert!(
            !tron_lib.contains(retired),
            "installed shared CLI library must not retain workspace bundle helper {retired}"
        );
    }
    for path in git_ls_files("scripts") {
        let source = read_repo_file(&path);
        for forbidden in [
            "sign_and_notarize",
            "notarize_bundle",
            "notarytool",
            "NOTARIZE_PROFILE",
            "stapler",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must leave notarization to the hosted release owner: {forbidden}"
            );
        }
    }
    assert_eq!(
        manual
            .matches("codesign_bundle \"$INSTALLED_BUNDLE\"")
            .count(),
        2
    );
    let failed_sign = Command::new("bash")
        .args([
            "-c",
            "print_error() { :; }; source \"$1\"; TRON_BUNDLE_ID=com.tron.test; CONTRIBUTOR_DIR=/nonexistent; codesign_bundle /nonexistent",
            "bash",
            repo_path("scripts/tron.d/bundle.sh")
                .to_str()
                .expect("bundle helper path should be utf8"),
        ])
        .status()
        .expect("codesign failure smoke should run");
    assert!(
        !failed_sign.success(),
        "contributor signing must fail when no valid signature can be produced"
    );

    let service = read_repo_file("scripts/tron-lib.d/service.sh");
    for required in [
        "cmd_uninstall()",
        "--reset-settings",
        "--reset-credentials",
        "Database and workspace data preserved",
        "clear_user_settings",
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
    assert!(uninstaller.contains("ServerSettingsWriter.deleteSettings"));
    assert!(uninstaller.contains("setup.settingsPath"));
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
        "-project TronMobile.xcodeproj",
        "working-directory: packages/mac-app",
        "-project TronMac.xcodeproj",
        "Dry-run DMG assembly",
        "ENABLE_DEBUG_DYLIB=NO",
    ] {
        assert!(ci.contains(required), "CI missing {required}");
    }
    let mac_filter = ci
        .split_once("            mac:\n")
        .expect("CI must define a Mac path filter")
        .1
        .split_once("\n\n  personal-info-guard:")
        .expect("Mac path filter must end before the first validation job")
        .0;
    assert!(
        mac_filter.contains("- '.github/workflows/release-mac.yml'"),
        "Mac release workflow changes must schedule Mac CI"
    );

    let release_mac = read_repo_file(".github/workflows/release-mac.yml");
    for required in [
        "scripts/tron version github-output",
        "./scripts/bundle-agent.sh --skip-build",
        "xcodegen generate",
        "xcodebuild archive",
        "-project TronMac.xcodeproj",
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
    for required in [
        "xcrun notarytool submit \"$ZIP_PATH\"",
        "run: xcrun stapler staple \"$APP_PATH\"",
        "xcrun notarytool submit \"${{ steps.dmg.outputs.dmg_path }}\"",
        "run: xcrun stapler staple \"${{ steps.dmg.outputs.dmg_path }}\"",
    ] {
        assert!(
            release_mac.contains(required),
            "hosted Mac release must retain distribution notarization step {required}"
        );
    }

    let release_ios = read_repo_file(".github/workflows/release-ios.yml");
    for required in [
        "xcodegen generate",
        "xcodebuild archive",
        "-project TronMobile.xcodeproj",
        "dry_run",
        "asc builds upload",
    ] {
        assert!(
            release_ios.contains(required),
            "iOS release workflow missing {required}"
        );
    }
}

#[test]
fn mac_dmg_packaging_has_one_fail_closed_owner() {
    let script = read_repo_file("packages/mac-app/scripts/package-dmg.sh");
    for required in [
        "--app|--output|--volume-name|--layout",
        "structural|release",
        "mktemp -d",
        "ditto \"$app\" \"$source/$bundle\"",
        "--skip-jenkins",
        "--window-size 540 340 --icon \"$bundle\" 135 170",
        "--app-drop-link 405 170",
        "--hide-extension \"$bundle\"",
        "create-dmg \"${args[@]}\"",
        "hdiutil attach -readonly -nobrowse -mountpoint",
        "mounted DMG is missing executable helper",
        "mounted DMG is missing Applications link",
        "readlink \"$mount_point/Applications\"",
    ] {
        assert!(script.contains(required), "DMG owner missing {required}");
    }
    let create_calls = script
        .lines()
        .filter(|line| line.trim_start().starts_with("create-dmg "))
        .count();
    assert_eq!(create_calls, 1, "create-dmg must have one owner");
    for forbidden in ["retrying minimal", "create-dmg ||"] {
        assert!(!script.contains(forbidden), "{forbidden}");
    }

    let assert_call = |source: &str, label: &str, required: &[&str]| {
        for value in required {
            assert!(source.contains(value), "{label} missing {value}");
        }
        for duplicate in ["create-dmg ", "hdiutil attach", "ditto \"$APP_PATH\""] {
            assert!(!source.contains(duplicate), "{label}: {duplicate}");
        }
    };
    let ci = read_repo_file(".github/workflows/ci.yml");
    let ci_dmg = ci.split_once("- name: Dry-run DMG assembly").unwrap().1;
    assert_call(
        ci_dmg.split_once("  # Aggregate gate").unwrap().0,
        "CI DMG call",
        &[
            "./scripts/package-dmg.sh",
            "--layout structural",
            "--app \"$APP_PATH\"",
        ],
    );
    let release = read_repo_file(".github/workflows/release-mac.yml");
    let release_dmg = release.split_once("- name: Build DMG").unwrap().1;
    assert_call(
        release_dmg.split_once("- name: Sign DMG").unwrap().0,
        "release DMG call",
        &[
            "./packages/mac-app/scripts/package-dmg.sh",
            "--layout release",
            "echo \"dmg_path=$DMG_PATH\" >> \"$GITHUB_OUTPUT\"",
        ],
    );
}

#[test]
fn dev_quality_environment_and_app_wrapper_do_not_hide_production_deploys() {
    for path in [
        concat!("scripts/auto", "-deploy"),
        "scripts/tron.d/automation.sh",
    ] {
        assert!(
            !repo_path(path).exists(),
            "automatic deployment helper must stay absent: {path}"
        );
    }

    for path in [
        "README.md",
        "scripts/tron",
        "scripts/tron-cli",
        "scripts/tron-lib.sh",
        "packages/mac-app/Sources/Server/Paths/TronPaths.swift",
    ] {
        let source = read_repo_file(path);
        for forbidden in [
            concat!("auto", "-deploy"),
            "AUTO_DEPLOY",
            concat!("cmd_", "auto", "_deploy"),
            "com.tron.auto-deploy",
        ] {
            assert!(
                !source.contains(forbidden),
                "manual production surface must not retain {forbidden} in {path}"
            );
        }
    }

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
    assert!(workspace_cli.contains("*) dispatch_runtime_command \"$@\" ;;"));
    assert!(
        !workspace_cli
            .lines()
            .any(|line| line.trim_start().starts_with("deploy)")),
        "old tron deploy dispatcher alias must not return"
    );
    let installed_cli = read_repo_file("scripts/tron-cli");
    assert!(installed_cli.contains("dev|manual-deploy|ci|bench|version|preflight|setup|install"));
    assert!(installed_cli.contains("*) dispatch_runtime_command \"$@\" ;;"));
    assert!(
        !installed_cli
            .lines()
            .any(|line| line.trim_start().starts_with("deploy)")),
        "installed CLI must not expose old deploy alias"
    );
}

#[test]
fn runtime_command_help_has_one_shared_owner() {
    let workspace_cli = read_repo_file("scripts/tron");
    let installed_cli = read_repo_file("scripts/tron-cli");
    let runtime_cli = read_repo_file("scripts/tron-lib.sh");
    let shared_help = runtime_cli
        .split_once("show_runtime_command_help() {")
        .expect("shared runtime help owner missing")
        .1
        .split_once("\n}")
        .expect("shared runtime help owner must be a shell function")
        .0;
    let runtime_dispatcher = runtime_cli
        .split_once("dispatch_runtime_command() {")
        .expect("shared runtime dispatcher missing")
        .1;
    let dispatcher_case = runtime_dispatcher
        .split_once("case \"$command\" in")
        .expect("runtime dispatcher case missing")
        .1
        .split_once("*)")
        .expect("runtime dispatcher default arm missing")
        .0;

    let dispatcher_commands = dispatcher_case
        .lines()
        .filter_map(|line| {
            line.trim_start()
                .split_once(')')
                .map(|(command, _)| command)
        })
        .collect::<Vec<_>>()
        .join(" ");
    assert_eq!(
        dispatcher_commands, "status start stop restart uninstall logs errors rollback login auth",
        "runtime dispatcher inventory drifted"
    );
    let expected_help_commands =
        "status|start|stop|restart|uninstall|logs|errors|rollback|login|auth rotate"
            .split('|')
            .collect::<Vec<_>>();
    assert_eq!(
        shared_help
            .lines()
            .filter(|line| line.trim_start().starts_with("echo \"  "))
            .count(),
        expected_help_commands.len(),
        "shared runtime help inventory drifted"
    );

    for entrypoint in [&workspace_cli, &installed_cli] {
        assert_eq!(entrypoint.matches("show_runtime_command_help").count(), 1);
    }
    for help_command in expected_help_commands {
        let help_row = format!("echo \"  {help_command}");
        assert_eq!(
            shared_help.matches(&help_row).count(),
            1,
            "shared runtime help must contain one {help_command} row"
        );
        assert!(
            !workspace_cli.contains(&help_row) && !installed_cli.contains(&help_row),
            "entrypoints must not duplicate shared runtime help row {help_command}"
        );
    }
}
