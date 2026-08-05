//! Living contracts for repository-owned validation and documentation entry points.

use std::collections::BTreeSet;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

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

fn run_git(root: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(args)
        .current_dir(root)
        .output()
        .unwrap_or_else(|error| panic!("git {args:?} failed to start: {error}"));
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn run_staged_personal_info_guard(root: &Path) -> Output {
    Command::new("bash")
        .args(["scripts/personal-info-guard.sh", "--staged"])
        .current_dir(root)
        .output()
        .expect("staged guard probe should start")
}

#[test]
fn staged_personal_info_guard_preserves_multiple_paths() {
    let repo = tempfile::tempdir().expect("guard probe repository should exist");
    let scripts = repo.path().join("scripts");
    std::fs::create_dir(&scripts).expect("guard probe scripts directory should exist");
    std::fs::copy(
        repo_path("scripts/personal-info-guard.sh"),
        scripts.join("personal-info-guard.sh"),
    )
    .expect("guard script should copy into probe repository");
    std::fs::write(repo.path().join("a clean.txt"), "generic content\n")
        .expect("clean staged file should be writable");

    run_git(repo.path(), &["init", "-q"]);
    run_git(repo.path(), &["add", "-A"]);
    let clean = run_staged_personal_info_guard(repo.path());
    assert!(
        clean.status.success(),
        "clean staged files should pass: {}{}",
        String::from_utf8_lossy(&clean.stdout),
        String::from_utf8_lossy(&clean.stderr)
    );

    let developer = ["m", "oo", "se"].concat();
    std::fs::write(
        repo.path().join(":(exclude) z leak.txt"),
        format!("/Users/{developer}/private\n"),
    )
    .expect("leaking staged file should be writable");
    run_git(repo.path(), &["add", "-A"]);
    let leaking = run_staged_personal_info_guard(repo.path());
    assert!(
        !leaking.status.success(),
        "later staged paths must not disappear from the scan"
    );
    assert!(
        String::from_utf8_lossy(&leaking.stdout).contains("raw home path"),
        "guard should identify the staged personal-path violation"
    );

    let invalid_index = repo.path().join("invalid-index");
    std::fs::write(&invalid_index, "not a Git index\n")
        .expect("invalid index fixture should be writable");
    let failed_git = Command::new("bash")
        .args(["scripts/personal-info-guard.sh", "--staged"])
        .env("GIT_INDEX_FILE", invalid_index)
        .current_dir(repo.path())
        .output()
        .expect("broken-index guard probe should start");
    assert_eq!(
        failed_git.status.code(),
        Some(2),
        "staged index errors must fail closed"
    );
    assert!(
        String::from_utf8_lossy(&failed_git.stderr).contains("failed to read the staged index"),
        "setup failure should identify the staged-index owner"
    );
}

#[test]
fn logs_cli_owns_bounded_quoted_filters() {
    let logs_script = read_repo_file("scripts/tron-lib.d/logs.sh");
    for required in [
        "-w|--workspace",
        "-t|--trace",
        "local value=${1//\\'/\\'\\'}",
        "join_conditions()",
        "joined=\"$joined AND $condition\"",
        "where_clause=\"WHERE $(join_conditions \"${conditions[@]}\")\"",
        r#"'workspaceId', workspace_id"#,
        r#"'traceId', trace_id"#,
        r#"session_id = $(sql_quote_literal "$session")"#,
        r#"workspace_id = $(sql_quote_literal "$workspace")"#,
        r#"trace_id = $(sql_quote_literal "$trace")"#,
        "search_literal=$(sql_quote_literal \"$search\")",
        "if ! [[ \"$limit\" =~ ^[0-9]+$ ]] || [ \"$limit\" -lt 1 ]; then",
    ] {
        assert!(
            logs_script.contains(required),
            "tron logs lost bounded SQL guard `{required}`"
        );
    }
    assert!(!logs_script.contains("session_id LIKE '%$session%'"));
    assert!(!logs_script.contains("IFS=' AND '; echo"));

    let service_script = read_repo_file("scripts/tron-lib.d/service.sh");
    let runtime_cli = read_repo_file("scripts/tron-lib.sh");
    assert!(runtime_cli.contains("errors)    query_logs --level error --limit 20"));
    assert!(!service_script.contains("cmd_errors()") && !service_script.contains("FROM logs"));
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

fn cargo_discovered_integration_targets() -> BTreeSet<String> {
    let manifest: toml::Value = read_repo_file("packages/agent/Cargo.toml")
        .parse()
        .expect("agent Cargo.toml should parse");
    let package = manifest["package"]
        .as_table()
        .expect("agent Cargo.toml should define [package]");
    assert!(
        package
            .get("autotests")
            .and_then(toml::Value::as_bool)
            .unwrap_or(true),
        "Cargo integration-test auto-discovery must remain enabled"
    );
    assert!(
        manifest.get("test").is_none(),
        "explicit [[test]] targets would duplicate the top-level source contract"
    );

    std::fs::read_dir(repo_path("packages/agent/tests"))
        .expect("integration-test directory should be readable")
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let path = entry.path();
            if !path.is_file() || path.extension().and_then(|value| value.to_str()) != Some("rs") {
                return None;
            }
            path.file_stem()
                .and_then(|value| value.to_str())
                .map(str::to_owned)
        })
        .collect()
}

fn quality_discovered_integration_targets() -> Vec<String> {
    let output = Command::new("bash")
        .args([
            "-c",
            "source scripts/tron.d/quality.sh && discover_cargo_integration_test_targets",
        ])
        .env("RUST_WORKSPACE", repo_path("packages/agent"))
        .current_dir(repo_root())
        .output()
        .expect("quality target discovery should start");
    assert!(
        output.status.success(),
        "quality target discovery failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("quality target discovery should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn probe_quality_run_tests(
    targets: &[&str],
    failing_target: Option<&str>,
) -> (bool, Vec<String>, String) {
    let workspace = tempfile::tempdir().expect("quality probe workspace should exist");
    let tests_dir = workspace.path().join("tests");
    std::fs::create_dir(&tests_dir).expect("quality probe tests directory should exist");
    for target in targets {
        std::fs::write(tests_dir.join(format!("{target}.rs")), "")
            .expect("quality probe target should be writable");
    }
    let call_log = workspace.path().join("cargo-calls.log");
    let output = Command::new("bash")
        .args([
            "-c",
            r#"
source "$QUALITY_SCRIPT"
print_status() { :; }
print_success() { :; }
cargo() {
    printf '%s\n' "$*" >> "$CALL_LOG"
    if [ -n "$FAIL_TARGET" ] && [[ " $* " == *" --test $FAIL_TARGET "* ]]; then
        return 1
    fi
    return 0
}
run_tests
"#,
        ])
        .env("QUALITY_SCRIPT", repo_path("scripts/tron.d/quality.sh"))
        .env("RUST_WORKSPACE", workspace.path())
        .env("CALL_LOG", &call_log)
        .env("FAIL_TARGET", failing_target.unwrap_or(""))
        .current_dir(workspace.path())
        .output()
        .expect("quality run_tests probe should start");
    let calls = std::fs::read_to_string(call_log)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect();
    (
        output.status.success(),
        calls,
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

fn ci_summary_script(workflow: &str) -> String {
    let (_, script) = workflow
        .split_once("      - name: Verify all required jobs passed\n        run: |\n")
        .expect("CI summary must own a result-check script");
    script
        .lines()
        .map(|line| {
            line.strip_prefix("          ")
                .unwrap_or_else(|| panic!("unexpected CI summary indentation: {line}"))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn probe_ci_summary(
    script: &str,
    changes: &str,
    ios: &str,
    mac: &str,
    require_ios: &str,
    require_mac: &str,
) -> Output {
    Command::new("bash")
        .args(["-c", script])
        .env("RESULT_CHANGES", changes)
        .env("RESULT_GUARD", "success")
        .env("RESULT_VERSION", "success")
        .env("RESULT_WORKFLOW_LINT", "success")
        .env("RESULT_RUST", "success")
        .env("RESULT_IOS", ios)
        .env("RESULT_MAC", mac)
        .env("REQUIRE_IOS", require_ios)
        .env("REQUIRE_MAC", require_mac)
        .output()
        .expect("CI summary probe should start")
}

#[test]
fn agent_investigation_guidance_is_self_contained() {
    let retired_skill = ["self", "inspect"].join("-");
    let stale_references = Command::new("git")
        .args(["grep", "-n", "-i", "-F", "-e"])
        .arg(&retired_skill)
        .arg("--")
        .current_dir(repo_root())
        .output()
        .expect("retired-skill scan should start");
    assert_eq!(
        stale_references.status.code(),
        Some(1),
        "tracked files still reference the retired investigation skill, or git grep failed:\n{}{}",
        String::from_utf8_lossy(&stale_references.stdout),
        String::from_utf8_lossy(&stale_references.stderr)
    );

    assert!(
        git_output(&["ls-files", "packages/agent/skills"])
            .trim()
            .is_empty(),
        "repo-managed first-party skills must remain absent"
    );

    let guidance = read_repo_file("AGENTS.md");
    for required in [
        "## Live-state investigations",
        "TRON_DATA_DIR",
        "TRON_HOME_NAME",
        "tron.sqlite",
        "workers.sqlite",
        "PRAGMA query_only = ON",
        "sqlite_schema",
        "PRAGMA table_info",
        "current WAL state",
        "nearest Rust `mod.rs`",
        "Swift state",
    ] {
        assert!(
            guidance.contains(required),
            "root agent guidance lost live-investigation requirement {required:?}"
        );
    }
}

fn workflow_step_script(workflow: &str, step_name: &str) -> String {
    let marker = format!("      - name: {step_name}\n");
    let (_, step) = workflow
        .split_once(&marker)
        .unwrap_or_else(|| panic!("workflow must define step {step_name:?}"));
    let (_, script) = step
        .split_once("        run: |\n")
        .unwrap_or_else(|| panic!("workflow step {step_name:?} must own a run block"));
    script
        .lines()
        .take_while(|line| line.is_empty() || line.starts_with("          "))
        .map(|line| line.strip_prefix("          ").unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n")
}

fn assert_release_mode(
    script: &str,
    required_secrets: &[&str],
    event: &str,
    requested_dry_run: &str,
    configured_secrets: &[&str],
    expected_mode: Option<&str>,
    expected_message: &str,
) {
    let workspace = tempfile::tempdir().expect("release-mode probe should have a workspace");
    let output_path = workspace.path().join("github-output");
    let mut command = Command::new("/bin/bash");
    command
        .args(["-c", script])
        .env_clear()
        .env("GITHUB_EVENT_NAME", event)
        .env("DRY_RUN_INPUT", requested_dry_run)
        .env("GITHUB_OUTPUT", &output_path);
    for secret in required_secrets {
        command.env(
            secret,
            if configured_secrets.contains(secret) {
                "configured"
            } else {
                ""
            },
        );
    }
    let output = command.output().expect("release-mode probe should start");
    let messages = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let emitted = std::fs::read_to_string(output_path).unwrap_or_default();

    match expected_mode {
        Some(mode) => {
            assert!(
                output.status.success(),
                "release-mode probe failed: {messages}"
            );
            assert_eq!(emitted.trim(), format!("dry_run={mode}"));
        }
        None => {
            assert!(
                !output.status.success(),
                "release-mode probe unexpectedly succeeded: {messages}"
            );
            assert!(
                emitted.is_empty(),
                "failed gate must not emit a release mode"
            );
        }
    }
    assert!(
        messages.contains(expected_message),
        "release-mode probe omitted {expected_message:?}: {messages}"
    );
}

#[test]
fn root_readme_stays_a_concise_progressive_disclosure_front_door() {
    let readme = read_repo_file("README.md");
    assert!(
        readme.lines().count() <= 250,
        "root README must stay under 250 lines; move details to their owner"
    );
    for required in [
        "# Tron",
        "## Why Tron",
        "## System Shape",
        "## Install",
        "## Develop",
        "## Validate",
        "## Documentation",
        "packages/agent/docs/project-reference.md",
        "CONTRIBUTING.md",
        "packages/agent/src/lib.rs",
        "packages/ios-app/docs/architecture.md",
        "packages/mac-app/docs/architecture.md",
        "rust-toolchain.toml",
    ] {
        assert!(
            readme.contains(required),
            "root README front door is missing {required}"
        );
    }
}

#[test]
fn dependabot_tracks_only_repository_owned_ecosystems() {
    let config = read_repo_file(".github/dependabot.yml");
    let ecosystems = config
        .lines()
        .filter_map(|line| line.trim().strip_prefix("- package-ecosystem: "))
        .collect::<BTreeSet<_>>();
    assert_eq!(ecosystems, BTreeSet::from(["cargo", "github-actions"]));
}

#[test]
fn shell_entrypoints_leave_runtime_initialization_to_source_owners() {
    let probe = tempfile::tempdir().expect("shell ownership probe should have a home");
    for (name, script, args) in [
        (
            "workspace-version",
            "scripts/tron",
            &["version", "print"][..],
        ),
        (
            "installed-auth-help",
            "scripts/tron-cli",
            &["auth", "--help"][..],
        ),
    ] {
        let data_dir = probe.path().join(name);
        let output = Command::new("/bin/bash")
            .arg(repo_path(script))
            .args(args)
            .env("HOME", probe.path())
            .env("TRON_DATA_DIR", &data_dir)
            .current_dir(repo_root())
            .output()
            .expect("read-only shell probe should start");
        assert!(
            output.status.success(),
            "{script} {args:?} failed: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            !data_dir.exists(),
            "read-only shell command must not create {}",
            data_dir.display()
        );
    }

    let cold_home = probe.path().join("cold-login");
    let output = Command::new("/bin/bash")
        .arg(repo_path("scripts/tron"))
        .args(["login", "--provider", "anthropic", "--label", "probe"])
        .env("HOME", probe.path())
        .env("TRON_DATA_DIR", &cold_home)
        .current_dir(repo_root())
        .output()
        .expect("cold login probe should start");
    assert!(
        !output.status.success(),
        "cold login must fail before OAuth"
    );
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Start the Tron server once"),
        "cold login must explain its initialization owner"
    );
    assert!(
        !cold_home.exists(),
        "failed cold login must not create partial auth state"
    );
}

#[test]
fn local_and_github_ci_share_one_fail_fast_test_schedule() {
    let local_targets = quality_discovered_integration_targets();
    let discovered_targets = cargo_discovered_integration_targets();
    let workflow = read_repo_file(".github/workflows/ci.yml");
    let toolchain: toml::Value = read_repo_file("rust-toolchain.toml")
        .parse()
        .expect("root Rust toolchain should parse");

    assert!(
        toolchain["toolchain"]["channel"]
            .as_str()
            .is_some_and(|channel| !channel.is_empty()),
        "root toolchain must own a concrete Rust channel"
    );
    assert_eq!(
        git_output(&["ls-files", "*rust-toolchain.toml"])
            .lines()
            .collect::<Vec<_>>(),
        ["rust-toolchain.toml"],
        "the repository must have one tracked Rust toolchain owner"
    );
    for path in [
        ".github/workflows/ci.yml",
        ".github/workflows/release-mac.yml",
    ] {
        assert!(
            !read_repo_file(path).contains("\n          toolchain:"),
            "{path} must inherit the root rust-toolchain.toml"
        );
    }

    assert!(
        workflow.contains("run: scripts/tron ci test"),
        "GitHub Rust quality must delegate to the local test owner"
    );
    assert!(
        !workflow.contains("Run Rust-owned closeout target set")
            && !workflow.contains("cargo test --test "),
        "GitHub CI must not duplicate the local integration-target list"
    );
    assert!(
        workflow.contains("workflow_dispatch:") && !workflow.contains("continue-on-error:"),
        "manual validation must remain available and required jobs must fail closed"
    );
    for required in [
        "./scripts/tron version check",
        "./scripts/tron version test",
        "./scripts/tron-release-notes --test",
    ] {
        assert!(
            workflow.contains(required),
            "version-drift CI is missing {required}"
        );
    }

    let mut expected_targets = discovered_targets
        .iter()
        .filter(|target| target.as_str() != "integration")
        .cloned()
        .collect::<Vec<_>>();
    assert!(
        discovered_targets.contains("integration"),
        "Cargo's process-global integration target must remain present"
    );
    expected_targets.push("integration".to_owned());
    assert_eq!(local_targets, expected_targets);

    let (succeeded, calls, stderr) =
        probe_quality_run_tests(&["zeta", "integration", "alpha"], None);
    assert!(succeeded, "quality run_tests probe failed: {stderr}");
    assert_eq!(
        calls,
        vec![
            "test --workspace --lib --bins -- --quiet --test-threads=1".to_owned(),
            "test --test alpha -- --quiet".to_owned(),
            "test --test zeta -- --quiet".to_owned(),
            "test --test integration -- --test-threads=1 --quiet".to_owned(),
        ]
    );

    let (succeeded, calls, _) =
        probe_quality_run_tests(&["integration", "beta", "alpha"], Some("alpha"));
    assert!(
        !succeeded,
        "quality run_tests must fail with its first target"
    );
    assert_eq!(
        calls,
        vec![
            "test --workspace --lib --bins -- --quiet --test-threads=1".to_owned(),
            "test --test alpha -- --quiet".to_owned(),
        ]
    );

    let (succeeded, calls, stderr) = probe_quality_run_tests(&["alpha"], None);
    assert!(!succeeded, "quality run_tests must require integration");
    assert!(
        calls.is_empty(),
        "missing integration must fail before Cargo"
    );
    assert!(stderr.contains("serial integration test target is missing"));
}

#[test]
fn release_workflows_fail_closed_before_live_builds() {
    let workflows: [(&str, &[&str]); 2] = [
        (
            ".github/workflows/release-mac.yml",
            &[
                "MACOS_CERT_P12_BASE64",
                "MACOS_CERT_PASSWORD",
                "NOTARIZE_APPLE_ID",
                "NOTARIZE_TEAM_ID",
                "NOTARIZE_APP_PASSWORD",
            ],
        ),
        (
            ".github/workflows/release-ios.yml",
            &["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8_BASE64"],
        ),
    ];

    for (path, required_secrets) in workflows {
        let workflow = read_repo_file(path);
        assert_eq!(
            workflow_step_script(&workflow, "Resolve version").trim(),
            "./scripts/tron version github-output",
            "{path} must delegate version resolution to its script owner"
        );
        assert!(
            workflow.contains("default: true") && workflow.contains("type: boolean"),
            "{path} must expose a typed, safe dry-run default"
        );
        let (_, gate) = workflow
            .split_once("      - name: Resolve dry-run flag\n")
            .expect("workflow must own the release-mode gate");
        let (gate_environment, _) = gate
            .split_once("        run: |\n")
            .expect("release-mode gate must own a run block");
        assert!(gate_environment.contains("DRY_RUN_INPUT: ${{ inputs.dry_run }}"));
        for secret in required_secrets {
            let binding = format!("{secret}: ${{{{ secrets.{secret} }}}}");
            assert!(
                gate_environment.contains(&binding),
                "{path} release-mode gate is missing {binding}"
            );
        }
        let script = workflow_step_script(&workflow, "Resolve dry-run flag");
        assert!(
            !script.contains("${{ secrets.") && !script.contains("${{ inputs."),
            "{path} must pass inputs and secrets through the step environment"
        );

        let probe = |event, input, configured, mode, message| {
            assert_release_mode(
                &script,
                required_secrets,
                event,
                input,
                configured,
                mode,
                message,
            );
        };
        probe(
            "workflow_dispatch",
            "true",
            &[],
            Some("true"),
            "Dry-run=true",
        );
        probe("workflow_dispatch", "", &[], Some("true"), "Dry-run=true");
        probe(
            "workflow_dispatch",
            "invalid",
            required_secrets,
            None,
            "dry_run must be true or false",
        );
        probe(
            "push",
            "true",
            required_secrets,
            Some("false"),
            "Dry-run=false",
        );
        probe(
            "workflow_dispatch",
            "false",
            required_secrets,
            Some("false"),
            "Dry-run=false",
        );
        probe("workflow_dispatch", "false", &[], None, "requires secrets");

        for missing_secret in required_secrets {
            let configured = required_secrets
                .iter()
                .copied()
                .filter(|secret| secret != missing_secret)
                .collect::<Vec<_>>();
            assert_release_mode(
                &script,
                required_secrets,
                "push",
                "",
                &configured,
                None,
                missing_secret,
            );
        }
    }
}

#[test]
fn ios_release_credentials_are_ephemeral_and_restored() {
    let workflow = read_repo_file(".github/workflows/release-ios.yml");
    for forbidden in [
        "asc auth login",
        "ASC_PROFILE=ci",
        "security list-keychains -d user -s \"$keychain_path\"\n",
    ] {
        assert!(
            !workflow.contains(forbidden),
            "iOS release must not retain persistent credential behavior {forbidden:?}"
        );
    }
    for required in [
        "export ASC_PRIVATE_KEY_PATH=\"$key_path\"",
        "ASC_PRIVATE_KEY_PATH=$key_path",
        "ios-keychain-snapshot-ready",
        "security list-keychains -d user -s \"$keychain_path\" \"${original_keychains[@]}\"",
        "security default-keychain -d user -s \"$keychain_path\"",
        "ios-installed-profile-uuids",
        "cmp -s \"$profile_path\" \"$destination\"",
        "printf '%s\\n' \"$uuid\" >> \"$installed_profile_uuids\"",
    ] {
        assert!(
            workflow.contains(required),
            "iOS release missing {required}"
        );
    }
    let snapshot = workflow
        .find(": > \"$snapshot_ready\"")
        .expect("manual signing must mark a complete snapshot");
    let mutation = workflow
        .find("security list-keychains -d user -s \"$keychain_path\"")
        .expect("manual signing must prepend its keychain");
    assert!(
        snapshot < mutation,
        "keychain snapshot must precede mutation"
    );

    let summary = workflow
        .rfind("      - name: Summary\n")
        .expect("iOS release must end with a summary");
    let cleanup_start = workflow
        .find("      - name: Tear down iOS release credentials\n")
        .expect("iOS release must own credential teardown");
    assert!(summary < cleanup_start, "credential teardown must be final");
    assert_eq!(workflow.matches("        if: always()\n").count(), 1);
    let cleanup = workflow_step_script(&workflow, "Tear down iOS release credentials");
    for required in [
        "security list-keychains -d user -s \"${original_keychains[@]}\"",
        "security default-keychain -d user -s \"$original_default\"",
        "security delete-keychain \"$keychain_path\"",
        "tron-asc-api-key.p8",
        "ios-distribution.p12",
        "installed_profile_uuids",
        "exit \"$cleanup_failed\"",
    ] {
        assert!(
            cleanup.contains(required),
            "iOS teardown missing {required}"
        );
    }

    let state = tempfile::tempdir().expect("cleanup probe state should exist");
    let runner_temp = state.path().join("runner temp");
    let home = state.path().join("home");
    let bin = state.path().join("bin");
    let profiles = home.join("Library/MobileDevice/Provisioning Profiles");
    std::fs::create_dir_all(&runner_temp).unwrap();
    std::fs::create_dir_all(&profiles).unwrap();
    std::fs::create_dir_all(&bin).unwrap();
    let security_log = state.path().join("security.log");
    let security = bin.join("security");
    std::fs::write(
        &security,
        r#"#!/bin/bash
printf '%s\n' "$*" >> "$SECURITY_LOG"
if [[ "$1" == "list-keychains" && "${FAIL_SECURITY_RESTORE:-0}" == "1" ]]; then
  exit 1
fi
if [[ "$1" == "delete-keychain" ]]; then
  /bin/rm -f "$2"
fi
"#,
    )
    .unwrap();
    let mut permissions = std::fs::metadata(&security).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&security, permissions).unwrap();

    let uuid = "12345678-1234-1234-1234-123456789ABC";
    let keychain = runner_temp.join("ios-signing.keychain-db");
    let profile = profiles.join(format!("{uuid}.mobileprovision"));
    let transient_names = [
        "tron-asc-api-key.p8",
        "ios-distribution.p12",
        "app.mobileprovision",
        "share-extension.mobileprovision",
        "app-profile.plist",
        "share-extension-profile.plist",
    ];
    let seed = || {
        std::fs::write(&keychain, "keychain").unwrap();
        std::fs::write(&profile, "profile").unwrap();
        std::fs::write(
            runner_temp.join("ios-installed-profile-uuids"),
            format!("{uuid}\n"),
        )
        .unwrap();
        std::fs::write(
            runner_temp.join("ios-original-keychains"),
            "/Users/runner/Library/Keychains/login keychain-db\n/other.keychain-db\n",
        )
        .unwrap();
        std::fs::write(
            runner_temp.join("ios-original-default-keychain"),
            "/Users/runner/Library/Keychains/login keychain-db\n",
        )
        .unwrap();
        std::fs::write(runner_temp.join("ios-keychain-snapshot-ready"), "").unwrap();
        for name in transient_names {
            std::fs::write(runner_temp.join(name), "credential").unwrap();
        }
    };
    let run_cleanup = |fail_restore: bool| {
        Command::new("/bin/bash")
            .args(["-c", &cleanup])
            .env_clear()
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("RUNNER_TEMP", &runner_temp)
            .env("HOME", &home)
            .env("SECURITY_LOG", &security_log)
            .env(
                "FAIL_SECURITY_RESTORE",
                if fail_restore { "1" } else { "0" },
            )
            .output()
            .expect("credential teardown probe should start")
    };

    seed();
    let output = run_cleanup(false);
    assert!(output.status.success(), "teardown failed: {output:?}");
    assert!(!keychain.exists() && !profile.exists());
    for name in transient_names {
        assert!(!runner_temp.join(name).exists(), "teardown left {name}");
    }
    let calls = std::fs::read_to_string(&security_log).unwrap();
    let list = calls.find("list-keychains -d user -s").unwrap();
    let default = calls.find("default-keychain -d user -s").unwrap();
    let delete = calls.find("delete-keychain").unwrap();
    assert!(list < default && default < delete);
    assert!(calls.contains("login keychain-db"));
    assert!(
        run_cleanup(false).status.success(),
        "teardown must be idempotent"
    );

    seed();
    let failed = run_cleanup(true);
    assert!(
        !failed.status.success(),
        "restore failure must fail teardown"
    );
    assert!(
        !keychain.exists() && !profile.exists(),
        "failed restore must still clean material"
    );
}

#[test]
fn github_ci_schedules_clients_and_aggregates_fail_closed() {
    let workflow = read_repo_file(".github/workflows/ci.yml");
    let classifier = read_repo_file("scripts/ci-change-flags.sh");
    assert!(
        classifier.contains("packages/ios-app/*")
            && classifier.contains(".github/workflows/release-ios.yml"),
        "iOS source and release changes must schedule iOS validation"
    );
    for required in [
        "rust-toolchain.toml",
        "packages/agent/*",
        "packages/mac-app/*",
        ".github/workflows/release-mac.yml",
    ] {
        assert!(
            classifier.contains(required),
            "Mac validation filter is missing {required}"
        );
    }
    assert!(
        workflow.contains("run: scripts/ci-change-flags.sh")
            && !workflow.contains("dorny/paths-filter"),
        "CI must use the repository-owned deterministic change classifier"
    );
    let classifier_test = Command::new("bash")
        .args(["scripts/ci-change-flags.sh", "--self-test"])
        .current_dir(repo_root())
        .output()
        .expect("change classifier self-test should start");
    assert!(classifier_test.status.success());

    let ci_summary = workflow
        .split_once("\n  ci:\n")
        .map(|(_, summary)| summary)
        .expect("CI must define its aggregate summary job");
    for required in [
        "needs: [changes, personal-info-guard, version-drift, workflow-lint, rust, ios, mac]",
        "RESULT_CHANGES: ${{ needs.changes.result }}",
        "REQUIRE_IOS: ${{ needs.changes.outputs.ios_required }}",
        "REQUIRE_MAC: ${{ needs.changes.outputs.mac_required }}",
    ] {
        assert!(
            ci_summary.contains(required),
            "CI aggregate is missing {required}"
        );
    }
    for required in [
        "ios_required: ${{ github.event_name != 'pull_request' || steps.filter.outputs.ios == 'true' || contains(github.event.pull_request.labels.*.name, 'ios') }}",
        "mac_required: ${{ github.event_name != 'pull_request' || steps.filter.outputs.mac == 'true' || contains(github.event.pull_request.labels.*.name, 'mac') }}",
        "if: needs.changes.outputs.ios_required == 'true'",
        "if: needs.changes.outputs.mac_required == 'true'",
    ] {
        assert!(
            workflow.contains(required),
            "client scheduling must share its required decision: missing {required}"
        );
    }

    let script = ci_summary_script(ci_summary);
    assert!(
        probe_ci_summary(&script, "success", "skipped", "skipped", "false", "false")
            .status
            .success(),
        "a successfully path-filtered PR may skip both clients"
    );
    assert!(
        probe_ci_summary(&script, "success", "success", "success", "true", "true")
            .status
            .success(),
        "a full push succeeds when both clients pass"
    );
    assert!(
        !probe_ci_summary(&script, "failure", "skipped", "skipped", "false", "false")
            .status
            .success(),
        "change-detector failure must fail the aggregate"
    );
    assert!(
        !probe_ci_summary(&script, "success", "skipped", "success", "true", "true")
            .status
            .success(),
        "a required client skip must fail the aggregate"
    );
    assert!(
        !probe_ci_summary(&script, "success", "failure", "skipped", "true", "false")
            .status
            .success(),
        "client failures must fail the aggregate"
    );
}

#[test]
fn github_workflow_dependencies_are_immutable() {
    for path in [
        ".github/workflows/ci.yml",
        ".github/workflows/performance.yml",
        ".github/workflows/release-ios.yml",
        ".github/workflows/release-mac.yml",
    ] {
        let workflow = read_repo_file(path);
        for (index, line) in workflow.lines().enumerate() {
            let Some((_, declaration)) = line.split_once("uses:") else {
                continue;
            };
            let dependency = declaration
                .split_whitespace()
                .next()
                .expect("uses declaration must name a dependency");
            if dependency.starts_with("./") {
                continue;
            }
            if dependency.starts_with("docker://") {
                assert!(
                    dependency.contains("@sha256:")
                        && dependency
                            .rsplit_once("@sha256:")
                            .is_some_and(|(_, digest)| {
                                digest.len() == 64
                                    && digest
                                        .chars()
                                        .all(|character| character.is_ascii_hexdigit())
                            }),
                    "{path}:{} must pin its container action by digest: {dependency}",
                    index + 1
                );
                continue;
            }
            let revision = dependency
                .rsplit_once('@')
                .map(|(_, revision)| revision)
                .unwrap_or_default();
            assert!(
                revision.len() == 40
                    && revision
                        .chars()
                        .all(|character| character.is_ascii_hexdigit()),
                "{path}:{} must pin its action to a full commit SHA: {dependency}",
                index + 1
            );
        }
    }
}

#[test]
fn apple_ci_uses_one_checksum_pinned_toolchain_manifest() {
    let manifest = read_repo_file("config/ci-toolchain.env");
    for required in [
        "TRON_CI_XCODE_VERSION=26.3",
        "TRON_CI_IOS_RUNTIME_VERSION=26.2",
        "TRON_CI_XCODEGEN_VERSION=2.45.3",
        "TRON_CI_CREATE_DMG_VERSION=1.3.0",
        "TRON_CI_ASC_VERSION=3.5.0",
    ] {
        assert!(
            manifest.contains(required),
            "toolchain manifest lost {required}"
        );
    }
    assert_eq!(manifest.matches("_SHA256=").count(), 4);

    let installer = read_repo_file("scripts/install-ci-tools.sh");
    assert!(installer.contains("verify_sha256"));
    assert!(installer.contains("shasum -a 256"));

    for path in [
        ".github/workflows/ci.yml",
        ".github/workflows/release-ios.yml",
        ".github/workflows/release-mac.yml",
    ] {
        let workflow = read_repo_file(path);
        assert!(!workflow.contains("latest-stable"), "{path} must pin Xcode");
        assert!(
            !workflow.contains("OS=latest"),
            "{path} must pin iOS runtime"
        );
        assert!(
            !workflow.contains("brew install xcodegen")
                && !workflow.contains("brew install create-dmg")
                && !workflow.contains("brew install xcodegen asc"),
            "{path} must use checksum-pinned release tools"
        );
    }
}

#[test]
fn tracked_ignored_files_stay_absent() {
    let tracked = git_output(&["ls-files"]);
    for generated_prefix in [
        "packages/ios-app/TronMobile.xcodeproj/",
        "packages/mac-app/TronMac.xcodeproj/",
    ] {
        assert!(
            !tracked
                .lines()
                .any(|path| path.starts_with(generated_prefix)),
            "generated project must stay untracked: {generated_prefix}"
        );
    }

    for ignored_output in [
        "packages/agent/target/debug/tron",
        "packages/ios-app/TronMobile.xcodeproj/project.pbxproj",
        "packages/mac-app/TronMac.xcodeproj/project.pbxproj",
        "packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron",
        "packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron",
    ] {
        let status = Command::new("git")
            .args([
                "check-ignore",
                "--no-index",
                "--quiet",
                "--",
                ignored_output,
            ])
            .current_dir(repo_root())
            .status()
            .expect("git check-ignore should start");
        assert!(
            status.success(),
            "generated output is not ignored: {ignored_output}"
        );
    }

    let ignored_tracked = git_output(&["ls-files", "-ci", "--exclude-standard"]);
    assert!(
        ignored_tracked.trim().is_empty(),
        "tracked ignored files must stay absent:\n{ignored_tracked}"
    );
}

#[test]
fn executable_surfaces_do_not_hide_a_production_deploy_route() {
    let output = Command::new("git")
        .args([
            "grep",
            "-n",
            "-E",
            r"tron deploy|cmd_deploy|^[[:space:]]*deploy\)",
            "--",
            "scripts",
            ".github",
            ".codex/environments",
            "packages/mac-app/Sources",
        ])
        .current_dir(repo_root())
        .output()
        .expect("git grep should start");
    assert_eq!(
        output.status.code(),
        Some(1),
        "hidden production deploy route or git grep failure:\n{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
