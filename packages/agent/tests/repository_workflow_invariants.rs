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
        .take_while(|line| line.starts_with("          "))
        .map(|line| {
            line.strip_prefix("          ")
                .unwrap_or_else(|| panic!("unexpected CI summary indentation: {line}"))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn probe_ci_summary(
    script: &str,
    provenance: &str,
    ios: &str,
    mac: &str,
    full_required: &str,
) -> Output {
    let common_result = if full_required == "true" {
        "success"
    } else {
        "skipped"
    };
    Command::new("bash")
        .args(["-c", script])
        .env("RESULT_PROVENANCE", provenance)
        .env("RESULT_GUARD", common_result)
        .env("RESULT_VERSION", common_result)
        .env("RESULT_WORKFLOW_LINT", common_result)
        .env("RESULT_RUST", common_result)
        .env("RESULT_IOS", ios)
        .env("RESULT_MAC", mac)
        .env("FULL_REQUIRED", full_required)
        .env(
            "VALIDATION_MODE",
            if full_required == "true" {
                "full"
            } else {
                "reused"
            },
        )
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
            "test --locked --workspace --lib --bins -- --quiet --test-threads=1".to_owned(),
            "test --locked --test alpha -- --quiet".to_owned(),
            "test --locked --test zeta -- --quiet".to_owned(),
            "test --locked --test integration -- --test-threads=1 --quiet".to_owned(),
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
            "test --locked --workspace --lib --bins -- --quiet --test-threads=1".to_owned(),
            "test --locked --test alpha -- --quiet".to_owned(),
        ]
    );

    let quality = read_repo_file("scripts/tron.d/quality.sh");
    for required in [
        "cargo check --locked --workspace --all-targets",
        "cargo clippy --locked --workspace --all-targets",
        "cargo test --locked --workspace --lib --bins",
        "cargo doc --locked --workspace --no-deps",
    ] {
        assert!(
            quality.contains(required),
            "repository-owned CI must refuse dependency resolution drift: missing {required}"
        );
    }

    let (succeeded, calls, stderr) = probe_quality_run_tests(&["alpha"], None);
    assert!(!succeeded, "quality run_tests must require integration");
    assert!(
        calls.is_empty(),
        "missing integration must fail before Cargo"
    );
    assert!(stderr.contains("serial integration test target is missing"));
}

#[test]
fn workflow_ordering_preserves_main_history_and_rejects_stale_ios_delivery() {
    let ci = read_repo_file(".github/workflows/ci.yml");
    for required in [
        "format('ci-{0}-pr-{1}', github.workflow, github.event.pull_request.number)",
        "format('ci-{0}-{1}-{2}-{3}', github.workflow, github.event_name, github.run_id, github.run_attempt)",
        "cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
    ] {
        assert!(
            ci.contains(required),
            "authoritative CI ordering contract is missing {required}"
        );
    }
    assert!(
        !ci.contains("group: ci-${{ github.workflow }}-${{ github.ref }}"),
        "main and manual CI runs must not share a pending-replacement group"
    );

    let ios = read_repo_file(".github/workflows/release-ios.yml");
    let eligibility_job = ios
        .split_once("  eligibility:\n")
        .expect("iOS delivery must define a hosted eligibility job")
        .1
        .split_once("\n  testflight:\n")
        .expect("eligibility must run before the protected release job")
        .0;
    for required in [
        "runs-on: ubuntu-latest",
        "eligible: ${{ steps.resolve.outputs.eligible }}",
        "source_sha: ${{ steps.resolve.outputs.source_sha }}",
        "latest_main_sha: ${{ steps.resolve.outputs.latest_main_sha }}",
        "evidence_sha256: ${{ steps.resolve.outputs.evidence_sha256 }}",
        "delivery_required: ${{ steps.resolve.outputs.delivery_required }}",
        "apple_build_owner_run_number: ${{ steps.resolve.outputs.apple_build_owner_run_number }}",
        "expected_asc_build_id: ${{ steps.resolve.outputs.expected_asc_build_id }}",
        "actions: read",
        "if: github.event_name == 'workflow_run'",
        "ref: main",
    ] {
        assert!(
            eligibility_job.contains(required),
            "iOS eligibility job is missing {required}"
        );
    }
    assert!(
        !eligibility_job.contains("environment:") && !eligibility_job.contains("${{ secrets."),
        "source eligibility must stay outside the protected environment and release secrets"
    );

    let eligibility_script = workflow_step_script(&ios, "Resolve delivery eligibility");
    for required in [
        "source_sha=\"$UPSTREAM_SHA\"",
        "eligible=false",
        "\"$UPSTREAM_CONCLUSION\" == \"success\"",
        "\"$UPSTREAM_EVENT\" == \"push\"",
        "\"$UPSTREAM_BRANCH\" == \"main\"",
        "refs/heads/main:refs/remotes/origin/main",
        "current_main_sha=\"$(git rev-parse refs/remotes/origin/main)\"",
        "\"$source_sha\" == \"$current_main_sha\"",
        "scripts/ios-release-verify.py eligibility",
        "--observed-main-sha \"$current_main_sha\"",
        "--ci-workflow-run-id \"$UPSTREAM_RUN_ID\"",
        "evidence_sha256=sha256:$evidence_sha256",
        "scripts/ios-release-verify.py github-release-state",
        "scripts/ios-release-verify.py intent",
        "TRON_IOS_APPLE_BUILD_OWNER_RUN_NUMBER=\"$owner_run_number\"",
        "delivery_required=$delivery_required",
        "intent_artifact=\"tron-ios-release-intent-",
    ] {
        assert!(
            eligibility_script.contains(required),
            "automatic iOS delivery eligibility is missing {required}"
        );
    }
    let intent_evidence = ios
        .split_once("      - name: Preserve automatic release intent\n")
        .expect("automatic release must persist intent before side effects")
        .1
        .split_once("\n  testflight:\n")
        .expect("release intent must be retained outside the protected job")
        .0;
    for required in [
        "name: ${{ steps.resolve.outputs.intent_artifact }}",
        "path: ${{ steps.resolve.outputs.intent_path }}",
        "retention-days: 90",
        "if-no-files-found: error",
    ] {
        assert!(
            intent_evidence.contains(required),
            "automatic release intent retention is missing {required}"
        );
    }
    for required in [
        "permissions:\n      contents: read\n      actions: read",
        "scripts/ios-release-verify.py github-provenance",
        "scripts/ios-release-verify.py reuse-provenance",
        "scripts/ios-release-verify.py admission",
        "scripts/ios-release-verify.py receipt",
        "scripts/ios-release-verify.py direct-intent",
        "scripts/ios-release-verify.py github-direct-release-state",
        "scripts/ios-release-verify.py github-direct-provenance",
        "scripts/ios-release-verify.py direct-reuse-provenance",
        "scripts/ios-release-verify.py direct-source-check",
        "scripts/ios-release-verify.py direct-admission",
        "scripts/ios-release-verify.py direct-receipt",
        "--platform IOS",
        "asc builds wait --build-id \"$build_id\"",
        "expected_build_id=\"$EXISTING_ASC_BUILD_ID\"",
        "existing live build lacks a trusted admission receipt",
        "fresh release allocation from current main",
    ] {
        assert!(
            ios.contains(required),
            "rerun-safe iOS release workflow is missing {required}"
        );
    }
    for artifact_name in [
        "ios-dsyms-${{ steps.ver.outputs.version }}-${{ steps.ver.outputs.apple_build }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "ios-release-provenance-${{ steps.ver.outputs.apple_build }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "ios-release-reuse-provenance-${{ steps.ver.outputs.apple_build }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "ios-dry-run-ipa-${{ steps.ver.outputs.version }}-${{ steps.ver.outputs.apple_build }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "ios-release-admission-${{ steps.ver.outputs.apple_build }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "ios-asc-diagnostics-${{ steps.ver.outputs.apple_build }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "tron-ios-release-receipt-${{ github.event.workflow_run.id }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "tron-ios-direct-release-intent-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}",
        "ios-release-direct-source-check-${{ steps.ver.outputs.apple_build }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "ios-release-direct-admission-${{ steps.ver.outputs.apple_build }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "tron-ios-direct-release-receipt-${{ github.run_id }}-${{ github.run_attempt }}",
    ] {
        assert!(
            ios.contains(artifact_name),
            "attempt-produced artifact is not v4-safe: {artifact_name}"
        );
    }
    let upload_head = ios
        .find("      - name: Upload to App Store Connect\n")
        .expect("ASC upload must exist");
    let durable_head = ios
        .find("      - name: Preserve automatic delivery head evidence\n")
        .expect("head evidence upload must exist");
    let durable_admission = ios
        .find("      - name: Preserve automatic ASC admission receipt\n")
        .expect("ASC admission evidence must exist");
    let receipt_write = ios
        .find("      - name: Write automatic TestFlight delivery receipt\n")
        .expect("delivery receipt writer must exist");
    let teardown = ios
        .find("      - name: Tear down iOS release credentials\n")
        .expect("credential teardown must exist");
    let receipt_upload = ios
        .find("      - name: Preserve automatic TestFlight delivery receipt\n")
        .expect("delivery receipt upload must exist");
    assert!(
        upload_head < durable_head
            && durable_head < durable_admission
            && durable_admission < receipt_write
            && receipt_write < teardown
            && teardown < receipt_upload,
        "iOS release evidence must preserve upload/head/admission/delivery/cleanup order"
    );
    let eligibility_evidence = ios
        .split_once("      - name: Preserve automatic delivery eligibility\n")
        .expect("automatic eligibility must be retained as structured evidence")
        .1
        .split_once("\n  testflight:\n")
        .expect("eligibility evidence must remain outside the protected release job")
        .0;
    for required in [
        "if: github.event_name == 'workflow_run'",
        "tron-ios-release-eligibility-${{ github.event.workflow_run.id }}-${{ github.event.workflow_run.run_attempt }}-${{ github.run_id }}-${{ github.run_attempt }}",
        "path: ${{ steps.resolve.outputs.evidence_path }}",
        "retention-days: 90",
        "if-no-files-found: error",
    ] {
        assert!(
            eligibility_evidence.contains(required),
            "automatic eligibility evidence is missing {required}"
        );
    }

    for required in [
        "needs: eligibility",
        "if: needs.eligibility.outputs.eligible == 'true'",
        "ref: ${{ needs.eligibility.outputs.source_sha }}",
        "EXPECTED_SOURCE_SHA: ${{ needs.eligibility.outputs.source_sha }}",
    ] {
        assert!(
            ios.contains(required),
            "protected iOS delivery is not bound to eligibility output {required}"
        );
    }
    let checkout_script = workflow_step_script(&ios, "Verify trusted checkout");
    for required in [
        "current_main_sha=\"$(git rev-parse origin/main)\"",
        "test \"$resolved_sha\" = \"$current_main_sha\"",
        "\"$GITHUB_EVENT_NAME\" == \"workflow_dispatch\" && \"$REQUESTED_CHANNEL\" != \"dry-run\"",
        "git merge-base --is-ancestor \"$resolved_sha\" \"$current_main_sha\"",
    ] {
        assert!(
            checkout_script.contains(required),
            "release-job checkout guard is missing {required}"
        );
    }
    let delivery_guard = workflow_step_script(&ios, "Reconfirm automatic delivery head");
    for required in [
        "refs/heads/main:refs/remotes/origin/main",
        "test \"$EXPECTED_SOURCE_SHA\" = \"$current_main_sha\"",
        "checked_at=\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"",
        "scripts/ios-release-verify.py head-check",
        "--ci-workflow-run-id \"$CI_WORKFLOW_RUN_ID\"",
        "--release-workflow-run-id \"$GITHUB_RUN_ID\"",
        "sha256=sha256:$head_check_sha256",
        "IOS_RELEASE_HEAD_CHECK=$head_check_path",
    ] {
        assert!(
            delivery_guard.contains(required),
            "automatic iOS delivery lost its just-in-time main-head guard: {required}"
        );
    }
    assert!(
        ios.contains("EXPECTED_SOURCE_SHA: ${{ needs.eligibility.outputs.source_sha }}"),
        "automatic delivery guard must bind eligibility's exact source"
    );
    assert!(
        ios.contains("id: pre_upload_guard")
            && ios.contains("CI_WORKFLOW_RUN_ID: ${{ github.event.workflow_run.id }}")
            && ios.contains("CI_COMPLETED_AT: ${{ github.event.workflow_run.updated_at }}"),
        "automatic delivery evidence must bind the authoritative and release runs"
    );
    let guard_offset = ios
        .find("- name: Reconfirm automatic delivery head")
        .expect("delivery head guard should exist");
    let upload_offset = ios
        .find("- name: Upload to App Store Connect")
        .expect("App Store Connect upload should exist");
    assert!(
        guard_offset < upload_offset,
        "automatic iOS source must be rechecked before its first App Store Connect delivery"
    );
    let evidence_offset = ios
        .find("- name: Preserve automatic delivery head evidence")
        .expect("automatic delivery should preserve its just-in-time head check");
    assert!(
        upload_offset < evidence_offset,
        "head-check artifact upload must not widen the check-to-App-Store upload race"
    );
    let evidence_step = &ios[evidence_offset..];
    for required in [
        "if: always() && github.event_name == 'workflow_run'",
        "steps.pre_upload_guard.outcome == 'success'",
        "path: ${{ steps.pre_upload_guard.outputs.path }}",
        "retention-days: 90",
        "if-no-files-found: error",
    ] {
        assert!(
            evidence_step.contains(required),
            "automatic delivery evidence retention is missing {required}"
        );
    }

    let direct_guard = workflow_step_script(&ios, "Reconfirm direct live release source");
    for required in [
        "test \"$EXPECTED_SOURCE_SHA\" = \"$current_main_sha\"",
        "source_mode=\"current-main\"",
        "git merge-base --is-ancestor \"$EXPECTED_SOURCE_SHA\" \"$current_main_sha\"",
        "source_mode=\"main-ancestor\"",
        "scripts/ios-release-verify.py direct-source-check",
        "IOS_RELEASE_DIRECT_SOURCE_CHECK=$source_check_path",
    ] {
        assert!(
            direct_guard.contains(required),
            "direct live source guard is missing {required}"
        );
    }
    let direct_guard_offset = ios
        .find("- name: Reconfirm direct live release source")
        .expect("direct live source guard must exist");
    let direct_source_evidence = ios
        .find("- name: Preserve direct live source evidence")
        .expect("direct source evidence must exist");
    let direct_admission = ios
        .find("- name: Preserve direct ASC admission")
        .expect("direct admission evidence must exist");
    let direct_receipt_write = ios
        .find("- name: Write direct TestFlight delivery receipt")
        .expect("direct receipt writer must exist");
    let direct_receipt_upload = ios
        .find("- name: Preserve direct TestFlight delivery receipt")
        .expect("direct receipt artifact must exist");
    assert!(
        direct_guard_offset < upload_offset
            && upload_offset < direct_source_evidence
            && direct_source_evidence < direct_admission
            && direct_admission < direct_receipt_write
            && direct_receipt_write < teardown
            && teardown < direct_receipt_upload,
        "direct intent/effect/admission/receipt custody is out of order"
    );
}

#[test]
fn release_workflows_fail_closed_before_live_builds() {
    let workflows: [(&str, &[&str]); 1] = [(
        ".github/workflows/release-mac.yml",
        &[
            "MACOS_CERT_P12_BASE64",
            "MACOS_CERT_PASSWORD",
            "NOTARIZE_APPLE_ID",
            "NOTARIZE_TEAM_ID",
            "NOTARIZE_APP_PASSWORD",
        ],
    )];

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

    let ios = read_repo_file(".github/workflows/release-ios.yml");
    assert_eq!(
        workflow_step_script(&ios, "Resolve iOS delivery").trim(),
        "./scripts/tron version github-ios-output",
        "iOS delivery must delegate event, SHA, channel, and build resolution"
    );
    for required in [
        "workflow_run:",
        "workflows: [\"CI\"]",
        "branches: [main]",
        "channel:",
        "- dry-run",
        "- internal",
        "- external",
        "github.event.workflow_run.head_sha",
        "CURRENT_PROJECT_VERSION=\"${{ steps.ver.outputs.apple_build }}\"",
        "if: steps.ver.outputs.channel == 'internal'",
        "if: steps.ver.outputs.channel == 'external'",
    ] {
        assert!(
            ios.contains(required),
            "iOS delivery workflow missing {required}"
        );
    }
    for required in [
        "group: ${{ github.event_name == 'workflow_run' && format('ios-release-intent-{0}-{1}', github.event.workflow_run.id, github.event.workflow_run.conclusion)",
        "cancel-in-progress: false",
        "TRON_IOS_APPLE_BUILD_OWNER_RUN_NUMBER: ${{ needs.eligibility.outputs.apple_build_owner_run_number }}",
        "if: needs.eligibility.outputs.eligible == 'true' && needs.eligibility.outputs.delivery_required == 'true'",
    ] {
        assert!(
            ios.contains(required),
            "automatic iOS delivery is missing rerun-safe ownership contract {required}"
        );
    }
    assert!(ios.contains("if: needs.eligibility.outputs.eligible == 'true'"));
    let credential_environment = ios
        .split_once("      - name: Require live iOS credentials\n")
        .expect("iOS delivery must own a live credential gate")
        .1
        .split_once("        run: |\n")
        .expect("iOS live credential gate must own a run block")
        .0;
    for secret in ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8_BASE64"] {
        let binding = format!("{secret}: ${{{{ secrets.{secret} }}}}");
        assert!(
            credential_environment.contains(&binding),
            "iOS live credential gate is missing {binding}"
        );
    }
    let credential_script = workflow_step_script(&ios, "Require live iOS credentials");
    assert!(
        credential_script.contains("required_secrets=(ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64)")
    );
    assert!(credential_script.contains("live iOS delivery requires secrets"));

    let archive_script = workflow_step_script(&ios, "xcodebuild archive");
    for required in [
        "CODE_SIGN_STYLE=Manual",
        "CODE_SIGN_IDENTITY=\"$IOS_DISTRIBUTION_IDENTITY_HASH\"",
        "\"OTHER_CODE_SIGN_FLAGS=--keychain $IOS_SIGNING_KEYCHAIN_PATH\"",
        "\"PROVISIONING_PROFILE_SPECIFIER=\\$(TRON_APPSTORE_PROFILE_SPECIFIER)\"",
        "IOS_APP_PROFILE_SPECIFIER=\"$IOS_APP_PROFILE_SPECIFIER\"",
        "IOS_SHARE_PROFILE_SPECIFIER=\"$IOS_SHARE_PROFILE_SPECIFIER\"",
    ] {
        assert!(
            archive_script.contains(required),
            "iOS archive must consume resolved signing assets through {required}"
        );
    }
    assert!(
        !archive_script.contains("CODE_SIGN_STYLE=Automatic"),
        "installed App Store profiles must not archive through development-oriented automatic signing"
    );
    assert_eq!(
        archive_script.matches("-allowProvisioningUpdates").count(),
        1,
        "only cloud signing may ask Apple to create or update signing assets"
    );

    let project = read_repo_file("packages/ios-app/project.yml");
    for required in [
        "TRON_APPSTORE_PROFILE_SPECIFIER: \"$(IOS_APP_PROFILE_SPECIFIER)\"",
        "TRON_APPSTORE_PROFILE_SPECIFIER: \"$(IOS_SHARE_PROFILE_SPECIFIER)\"",
    ] {
        assert!(
            project.contains(required),
            "iOS targets must resolve distinct App Store profiles through {required}"
        );
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
        "original_keychains=()",
        "security list-keychains -d user | sed",
        "security default-keychain -d user | sed",
        "hosted runner default keychain is unavailable",
        "keychain_path=\"$HOME/Library/Keychains/tron-ios-signing-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.keychain-db\"",
        "system_keychain=\"/Library/Keychains/System.keychain\"",
        "system_root_keychain=\"/System/Library/Keychains/SystemRootCertificates.keychain\"",
        "security default-keychain -d user -s \"$keychain_path\"",
        "apple_root_path=\"$RUNNER_TEMP/AppleIncRootCertificate.cer\"",
        "wwdr_path=\"$RUNNER_TEMP/AppleWWDRCAG3.cer\"",
        "signing_probe=\"$RUNNER_TEMP/tron-signing-probe\"",
        "signing_probe_error=\"$RUNNER_TEMP/tron-signing-probe.stderr\"",
        "-T /usr/bin/xcodebuild >/dev/null",
        "\"$keychain_path\" >/dev/null",
        "ios-installed-profile-uuids",
        "cmp -s \"$profile_path\" \"$destination\"",
        "printf '%s\\n' \"$uuid\" >> \"$installed_profile_uuids\"",
        "hosted provisioning-profile directory is unsafe",
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
        .find("security list-keychains -d user -s \\\n            \"$keychain_path\"")
        .expect("manual signing must prepend its keychain");
    assert!(
        snapshot < mutation,
        "keychain snapshot must precede mutation"
    );
    let signing = workflow_step_script(&workflow, "Prepare manual iOS signing assets");
    for required in [
        "TRON_RELEASE_APPLE_ROOT_URL",
        "TRON_RELEASE_APPLE_ROOT_SHA256",
        "TRON_RELEASE_APPLE_WWDR_G3_URL",
        "TRON_RELEASE_APPLE_WWDR_G3_SHA256",
        "download_public_certificate()",
        "openssl pkcs12 \\",
        "-legacy \\",
        "-N \\",
        "-p codeSign \\",
        "-c \"$leaf_path\" \\",
        "-c \"$wwdr_path\" \\",
        "-r \"$apple_root_path\" \\",
        "security import \"$wwdr_path\" -k \"$keychain_path\" >/dev/null",
        "-S apple-tool:,apple:",
        "--sign \"$identity_hash\"",
        "--keychain \"$keychain_path\"",
        "codesign-diagnostic --log \"$signing_probe_error\"",
        "--extract-certificates=\"$signing_probe_cert_prefix\"",
        "embedded_wwdr_sha",
        "embedded_root_sha",
        "IOS_DISTRIBUTION_IDENTITY_HASH=$identity_hash",
        "uuid=\"$(/usr/libexec/PlistBuddy -c 'Print :UUID' \"$decoded_plist\" | tr '[:upper:]' '[:lower:]')\"",
        "profile-certificate \\",
        "--leaf-certificate \"$leaf_der_path\"",
    ] {
        assert!(
            signing.contains(required),
            "manual signing must validate its isolated certificate chain through {required}"
        );
    }
    let root_download = signing
        .find("\"$TRON_RELEASE_APPLE_ROOT_URL\"")
        .expect("manual signing must download Apple's root");
    let wwdr_download = signing
        .find("\"$TRON_RELEASE_APPLE_WWDR_G3_URL\"")
        .expect("manual signing must download Apple's intermediate");
    let exact_chain = signing
        .find("-N \\")
        .expect("manual signing must verify the exact pinned chain");
    let signing_probe = signing
        .find("--sign \"$identity_hash\"")
        .expect("manual signing must prove non-interactive key access");
    let keychain_create = signing
        .find("security create-keychain")
        .expect("manual signing must create a job-owned keychain");
    let profile_install = signing
        .find("/bin/cp \"$profile_path\" \"$destination\"")
        .expect("manual signing must install a validated profile");
    assert!(
        root_download < wwdr_download && wwdr_download < exact_chain && exact_chain < signing_probe,
        "the exact pinned chain must validate before non-interactive signing is tested"
    );
    assert!(keychain_create < profile_install);
    assert!(
        !signing.contains("security import \"$apple_root_path\""),
        "the system-trusted Apple root must not be duplicated in a temporary user keychain"
    );
    assert!(
        signing.contains("-T /usr/bin/xcodebuild >/dev/null")
            && signing.contains("\"$keychain_path\" >/dev/null"),
        "manual signing must avoid certificate-subject log leakage"
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
        "ios-distribution-leaf.pem",
        "ios-distribution-leaf.cer",
        "AppleIncRootCertificate.cer",
        "AppleWWDRCAG3.cer",
        "tron-signing-probe",
        "tron-signing-probe.stderr",
        "tron-signing-probe-cert-0",
        "installed_profile_uuids",
        "The hosted VM is discarded after this step",
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
    let profiles = home.join("Library/Developer/Xcode/UserData/Provisioning Profiles");
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

    let uuid = "12345678-1234-1234-1234-123456789abc";
    let keychains = home.join("Library/Keychains");
    std::fs::create_dir_all(&keychains).unwrap();
    let keychain = keychains.join("tron-ios-signing-12345-1.keychain-db");
    let profile = profiles.join(format!("{uuid}.mobileprovision"));
    let transient_names = [
        "tron-asc-api-key.p8",
        "ios-distribution.p12",
        "ios-distribution-leaf.pem",
        "ios-distribution-leaf.cer",
        "AppleIncRootCertificate.cer",
        "AppleWWDRCAG3.cer",
        "tron-signing-probe",
        "tron-signing-probe.stderr",
        "tron-signing-probe-cert-0",
        "tron-signing-probe-cert-1",
        "tron-signing-probe-cert-2",
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
            .current_dir(repo_root())
            .env_clear()
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("RUNNER_TEMP", &runner_temp)
            .env("HOME", &home)
            .env("GITHUB_RUN_ID", "12345")
            .env("GITHUB_RUN_ATTEMPT", "1")
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
fn ios_release_uses_an_exact_ephemeral_host_before_credentials_are_admitted() {
    let workflow = read_repo_file(".github/workflows/release-ios.yml");
    let ci = read_repo_file(".github/workflows/ci.yml");
    let shadow = read_repo_file("scripts/ci-shadow-run.sh");
    let doctor = read_repo_file("scripts/ios-release-toolchain-doctor.sh");

    let checkout = workflow
        .find("      - name: Checkout\n")
        .expect("iOS release must check out its admitted source");
    let xcode = workflow
        .find("      - name: Select exact release Xcode\n")
        .expect("iOS release must select its exact Xcode");
    let toolchain = workflow
        .find("      - name: Verify hosted release toolchain\n")
        .expect("iOS release must verify its hosted toolchain");
    let credential_gate = workflow
        .find("      - name: Require live iOS credentials\n")
        .expect("iOS release must own a live credential gate");
    assert!(
        checkout < xcode && xcode < toolchain && toolchain < credential_gate,
        "trusted checkout and hosted toolchain verification must precede release secrets"
    );
    assert!(
        workflow.contains("runs-on: macos-26")
            && workflow.contains("xcode-version: \"26.6\"")
            && workflow.contains("environment: ios-testflight"),
        "TestFlight must use the exact protected GitHub-hosted macOS image"
    );
    for required in [
        "RUNNER_ENVIRONMENT",
        "github-hosted",
        "ImageOS",
        "macos26",
        "uname -m",
        "arm64",
        "TRON_RELEASE_IOS_XCODE_VERSION",
        "TRON_RELEASE_IOS_XCODE_BUILD",
        "TRON_RELEASE_IOS_SDK_VERSION",
        "TestFlight delivery must not use a beta Xcode bundle",
        "xcodebuild -checkFirstLaunchStatus",
        "component=ios-release-toolchain-doctor",
    ] {
        assert!(
            doctor.contains(required),
            "hosted release toolchain doctor is missing {required}"
        );
    }
    assert!(
        workflow.contains("The hosted VM is discarded after this step")
            && !workflow.contains("self-hosted")
            && !workflow.contains("ios-release-user-context")
            && !workflow.contains("credential-ledger")
            && !workflow.contains("tron-runner-baseline")
            && !workflow.contains("Recover stale iOS release credentials"),
        "ephemeral TestFlight delivery must not retain persistent-runner recovery machinery"
    );
    for retired_path in [
        "scripts/bootstrap-ios-release-runner.sh",
        "scripts/ios-release-credential-ledger.py",
        "scripts/ios-release-runner-diagnostics.sh",
        "scripts/ios-release-runner-launchd-bootstrap",
        "scripts/ios-release-runner-session-entrypoint",
        "scripts/ios-release-user-context",
        ".github/actionlint.yaml",
    ] {
        assert!(
            !repo_path(retired_path).exists(),
            "retired self-hosted release surface remains: {retired_path}"
        );
    }
    for owner in [ci.as_str(), shadow.as_str()] {
        assert!(
            !owner.contains("bootstrap-ios-release-runner")
                && !owner.contains("ios-release-user-context"),
            "hosted validation retained a deleted runner primitive"
        );
    }
}

#[test]
fn github_ci_stages_feedback_and_reuses_exact_evidence_fail_closed() {
    let workflow = read_repo_file(".github/workflows/ci.yml");
    let feedback = read_repo_file(".github/workflows/fast-feedback.yml");
    let classifier = read_repo_file("scripts/ci-change-flags.sh");
    let evidence = read_repo_file("scripts/ci-validation-evidence.py");
    assert!(
        evidence.contains("class NoRedirect")
            && evidence.contains("urllib.request.urlopen(location, timeout=60)"),
        "artifact evidence must not forward GitHub authorization to signed blob storage"
    );
    assert!(
        classifier.contains("packages/ios-app/*")
            && classifier.contains(".github/workflows/release-ios.yml")
            && classifier.contains("scripts/ios-*"),
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
        feedback.contains("run: scripts/ci-change-flags.sh")
            && !feedback.contains("dorny/paths-filter"),
        "fast feedback must use the repository-owned deterministic change classifier"
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
    assert!(
        ci_summary.contains("fetch-depth: 1")
            && evidence.contains("\"cat-file\", \"commit\"")
            && !evidence.contains("git(\"show\", \"-s\", \"--format=%P\", \"HEAD\")"),
        "depth-one evidence must read ordered parents from the raw commit object"
    );
    for required in [
        "needs: [provenance, personal-info-guard, version-drift, workflow-lint, rust, ios, mac]",
        "RESULT_PROVENANCE: ${{ needs.provenance.result }}",
        "FULL_REQUIRED: ${{ needs.provenance.outputs.full_required }}",
        "VALIDATION_MODE: ${{ needs.provenance.outputs.mode }}",
        "Create merge validation evidence",
        "name: tron-merge-validation",
    ] {
        assert!(
            ci_summary.contains(required),
            "CI aggregate is missing {required}"
        );
    }
    for required in [
        "python3 scripts/ci-validation-evidence.py verify",
        "full_required=true",
        "mode=fallback",
        "if: needs.provenance.outputs.full_required == 'true'",
        "Draft validation",
    ] {
        assert!(
            workflow.contains(required),
            "client scheduling must share its required decision: missing {required}"
        );
    }

    let script = ci_summary_script(ci_summary);
    assert!(
        probe_ci_summary(&script, "success", "skipped", "skipped", "false")
            .status
            .success(),
        "verified evidence may skip the complete matrix"
    );
    assert!(
        probe_ci_summary(&script, "success", "success", "success", "true")
            .status
            .success(),
        "full validation succeeds when every workload passes"
    );
    assert!(
        !probe_ci_summary(&script, "failure", "skipped", "skipped", "false")
            .status
            .success(),
        "provenance failure must fail the aggregate"
    );
    assert!(
        !probe_ci_summary(&script, "success", "skipped", "success", "true")
            .status
            .success(),
        "a required client skip must fail the aggregate"
    );
    assert!(
        !probe_ci_summary(&script, "success", "failure", "success", "true")
            .status
            .success(),
        "client failures must fail the aggregate"
    );
}

#[test]
fn provider_neutral_ci_shadow_is_pinned_advisory_and_release_free() {
    let policy: serde_json::Value = serde_json::from_str(&read_repo_file("config/ci-policy.json"))
        .expect("CI policy should be valid JSON");
    assert_eq!(policy["schema"], "tron.ci-policy.v1");
    assert_eq!(
        policy["providers"]["github-actions"]["role"],
        "authoritative"
    );
    assert_eq!(
        policy["providers"]["github-actions"]["required_check_authority"],
        true
    );
    assert_eq!(
        policy["providers"]["github-actions"]["release_authority"],
        true
    );
    assert_eq!(policy["providers"]["buildkite"]["role"], "shadow");
    assert_eq!(policy["providers"]["buildkite"]["shadow"], true);
    assert_eq!(
        policy["providers"]["buildkite"]["required_check_authority"],
        false
    );
    assert_eq!(policy["providers"]["buildkite"]["release_authority"], false);
    assert_eq!(policy["release"]["provider"], "github-actions");
    assert_eq!(policy["release"]["ios"]["identity"]["app_id"], "6761511764");
    assert_eq!(
        policy["release"]["ios"]["identity"]["bundle_ids"],
        serde_json::json!(["com.tron.mobile", "com.tron.mobile.ShareExtension"])
    );
    assert_eq!(policy["release"]["ios"]["identity"]["scheme"], "Tron");
    assert_eq!(
        policy["release"]["ios"]["identity"]["configuration"],
        "Prod"
    );
    assert_eq!(
        policy["release"]["ios"]["channels"],
        serde_json::json!({"internal": "internal", "external": "external"})
    );
    assert_eq!(
        policy["release"]["ios"]["triggers"],
        serde_json::json!({"internal": "latest-green-main", "external": "server-v*"})
    );
    assert_eq!(
        policy["release"]["mac"],
        serde_json::json!({
            "configuration_path": ".github/workflows/release-mac.yml",
            "channels": {"public": "public"},
            "triggers": {"public": "server-v*"}
        })
    );
    let workflow_inventory = policy["workflow_inventory"]
        .as_object()
        .expect("CI policy should inventory every authoritative workflow");
    let expected_workflows: [(&str, &str, &str, &str, &[&str]); 6] = [
        (
            "merge-validation",
            ".github/workflows/ci.yml",
            "required-validation",
            "secretless-shadow-observation",
            &["pull_request:main", "push:main", "workflow_dispatch"],
        ),
        (
            "fast-feedback",
            ".github/workflows/fast-feedback.yml",
            "advisory-validation",
            "unimplemented",
            &["pull_request:main"],
        ),
        (
            "ios-performance",
            ".github/workflows/ios-performance.yml",
            "advisory-measurement",
            "unimplemented",
            &["schedule", "workflow_dispatch"],
        ),
        (
            "server-performance",
            ".github/workflows/performance.yml",
            "advisory-measurement",
            "unimplemented",
            &["schedule", "workflow_dispatch"],
        ),
        (
            "ios-release",
            ".github/workflows/release-ios.yml",
            "release",
            "unimplemented",
            &[
                "workflow_run:CI:main:completed",
                "push:server-v*",
                "workflow_dispatch",
            ],
        ),
        (
            "mac-release",
            ".github/workflows/release-mac.yml",
            "release",
            "unimplemented",
            &["push:server-v*", "workflow_dispatch"],
        ),
    ];
    assert_eq!(workflow_inventory.len(), expected_workflows.len());
    for (id, path, role, coverage, triggers) in expected_workflows {
        let workflow = workflow_inventory
            .get(id)
            .unwrap_or_else(|| panic!("CI policy is missing workflow {id}"));
        assert_eq!(workflow["configuration_path"], path);
        assert_eq!(workflow["provider"], "github-actions");
        assert_eq!(workflow["role"], role);
        assert_eq!(workflow["candidate_coverage"], coverage);
        assert_eq!(workflow["triggers"], serde_json::json!(triggers));
        assert!(
            repo_root().join(path).is_file(),
            "inventoried workflow is missing: {path}"
        );
    }
    let inventoried_paths: std::collections::BTreeSet<&str> = workflow_inventory
        .values()
        .map(|workflow| {
            workflow["configuration_path"]
                .as_str()
                .expect("workflow path should be a string")
        })
        .collect();
    let checked_in_paths: std::collections::BTreeSet<String> =
        std::fs::read_dir(repo_root().join(".github/workflows"))
            .expect("workflow directory should exist")
            .map(|entry| {
                let name = entry
                    .expect("workflow entry should be readable")
                    .file_name()
                    .into_string()
                    .expect("workflow filename should be UTF-8");
                format!(".github/workflows/{name}")
            })
            .collect();
    assert_eq!(
        inventoried_paths
            .into_iter()
            .map(str::to_owned)
            .collect::<std::collections::BTreeSet<_>>(),
        checked_in_paths,
        "replacement policy must inventory every checked-in GitHub workflow"
    );
    assert_eq!(
        policy["replacement_gate"]["scope"],
        "all-workflow-inventory-entries"
    );
    let required_blockers: Vec<&str> = policy["replacement_gate"]["required_blockers"]
        .as_array()
        .expect("replacement gate should have policy-owned blockers")
        .iter()
        .map(|value| {
            value
                .as_str()
                .expect("replacement blocker should be a string")
        })
        .collect();
    for blocker in [
        "artifact-custody-verification",
        "fork-pull-request-parity",
        "skip-token-trigger-continuity",
        "workflow-dispatch-parity",
        "fast-feedback-parity",
        "performance-workflow-parity",
        "ios-performance-workflow-parity",
        "candidate-main-release-handoff-parity",
        "ios-testflight-release-parity",
        "release-tag-parity",
        "mac-release-parity",
    ] {
        assert!(
            required_blockers.contains(&blocker),
            "replacement policy lost blocker {blocker}"
        );
    }
    assert_eq!(policy["cutover_gate"]["minimum_representative_runs"], 30);
    assert_eq!(policy["cutover_gate"]["minimum_observation_days"], 30);
    assert_eq!(
        policy["cutover_gate"]["maximum_candidate_main_p95_seconds"],
        480
    );
    assert_eq!(
        policy["cutover_gate"]["maximum_candidate_provider_failure_rate"],
        0.01
    );
    assert_eq!(
        policy["cutover_gate"]["minimum_provider_failure_rate_improvement"],
        0.02
    );
    assert_eq!(
        policy["cutover_gate"]["maximum_paired_reliability_p_value"],
        0.05
    );
    assert_eq!(
        policy["cutover_gate"]["authority_change_policy"],
        "prohibited-until-explicit-external-review"
    );

    let required_jobs: Vec<&str> = policy["required_jobs"]
        .as_array()
        .expect("CI policy should list required jobs")
        .iter()
        .map(|value| value.as_str().expect("required job should be a string"))
        .collect();
    assert_eq!(
        required_jobs,
        [
            "personal-info-guard",
            "version-drift",
            "workflow-lint",
            "rust",
            "ios",
            "mac",
        ]
    );

    let bootstrap = read_repo_file(".buildkite/pipeline.yml");
    let shadow = read_repo_file(".buildkite/shadow-steps.yml");
    let adapter = read_repo_file("scripts/ci-shadow-run.sh");
    let context = read_repo_file("scripts/ci-provider-context.py");
    let evidence = read_repo_file("scripts/ci-validation-evidence.py");
    let parity = read_repo_file("scripts/ci-parity-report.py");
    let cutover = read_repo_file("scripts/ci-cutover-evaluation.py");
    let ios_release_verifier = read_repo_file("scripts/ios-release-verify.py");
    let ios_release_docs = read_repo_file("packages/ios-app/docs/development.md");
    let definition_validator = read_repo_file("scripts/validate-ci-definitions.sh");
    let rust_image = read_repo_file(".buildkite/rust-shadow.Dockerfile");

    assert!(bootstrap.contains("key: \"source-context\""));
    assert!(bootstrap.contains("scripts/ci-shadow-run.sh source-context"));
    assert!(bootstrap.contains("build/ci-shadow/source-context/**/*"));
    assert!(bootstrap.contains("retry:\n      manual:\n        allowed: false"));
    assert!(adapter.contains("buildkite-agent pipeline upload"));
    assert!(adapter.contains("--reject-parse-warnings"));
    assert!(adapter.contains("--expected-context"));
    assert!(adapter.contains("--bundle"));
    assert!(adapter.contains("meta-data get buildkite:webhook"));
    assert!(adapter.contains("--webhook-payload"));
    assert!(context.contains("Buildkite webhook.pull_request.base.sha"));
    assert!(context.contains("Buildkite webhook.before"));
    assert!(context.contains("Buildkite webhook.pull_request.merge_commit_sha"));
    assert!(!context.contains("BUILDKITE_PULL_REQUEST_BASE_SHA"));
    for job in &required_jobs {
        assert!(
            shadow.contains(&format!("scripts/ci-shadow-run.sh {job}")),
            "Buildkite shadow is missing required job {job}"
        );
    }
    assert!(shadow.contains("key: \"shadow-evidence\""));
    assert!(shadow.contains("key: \"operational-observation\""));
    assert!(shadow.contains("allow_dependency_failure: true"));
    assert!(shadow.contains("soft_fail: true"));
    assert!(shadow.contains("depends_on:\n      - \"personal-info-guard\""));
    assert!(
        !shadow.contains("    cache:"),
        "untrusted pull requests must not seed cross-build writable caches"
    );
    assert!(adapter.contains("ci-validation-evidence.py"));
    assert!(context.contains("pinned context"));
    assert!(evidence.contains("tron.validation.v2"));
    assert!(evidence.contains("validate_archive_manifest"));
    assert!(parity.contains("tron.ci-parity.v1"));
    assert!(adapter.contains("tron.ci-shadow-bootstrap-execution.v1"));
    assert!(adapter.contains("executed-bootstrap.yml"));
    assert!(adapter.contains("tron.ci-shadow-operational-observation.v1"));
    for schema in [
        "tron.ci-cutover-observations.v2",
        "tron.ci-cutover-evaluation.v2",
        "tron.ci-testflight-export.v2",
    ] {
        assert!(
            cutover.contains(schema),
            "cutover evaluator is missing current schema {schema}"
        );
    }
    for schema in [
        "tron.ios-release-eligibility.v1",
        "tron.ios-release-intent.v1",
        "tron.ios-release-head-check.v1",
        "tron.ios-release-provenance.v1",
        "tron.ios-release-admission.v1",
        "tron.ios-release-reuse-provenance.v1",
        "tron.ios-release-receipt.v1",
    ] {
        assert!(
            cutover.contains(schema) && ios_release_verifier.contains(schema),
            "cutover and release validation must share evidence schema {schema}"
        );
    }
    for schema in [
        "tron.ios-release-direct-intent.v1",
        "tron.ios-release-direct-source-check.v1",
        "tron.ios-release-direct-admission.v1",
        "tron.ios-release-direct-reuse-provenance.v1",
        "tron.ios-release-direct-receipt.v1",
    ] {
        assert!(
            ios_release_verifier.contains(schema) && ios_release_docs.contains(schema),
            "direct live release custody is missing schema {schema}"
        );
    }
    assert!(cutover.contains("tron.ci-trigger-export.v1"));
    assert!(cutover.contains("one_sided_exact_mcnemar"));
    assert!(cutover.contains("observation-thresholds-satisfied-provenance-unverified"));
    assert!(cutover.contains("eligible_for_external_review\": False"));
    assert!(cutover.contains("candidate-main-release-handoff-parity"));
    assert!(cutover.contains("\"context\": \"CI summary\", \"integration_id\": 15368"));
    assert!(cutover.contains("\"build_pull_request_merge_commits\": False"));
    assert!(cutover.contains("candidate_attestation[\"build_pull_request_merge\"]"));
    assert!(cutover.contains("\"trigger_mode\": \"code\""));
    assert!(cutover.contains("candidate_attestation[\"code_trigger_mode\"]"));
    assert!(parity.contains("--reference-artifacts"));
    assert!(parity.contains("--candidate-artifacts"));
    assert!(parity.contains("\"verified\": False"));
    assert!(definition_validator.contains("--reject-secrets"));
    assert!(definition_validator.contains("--reject-parse-warnings"));
    assert!(definition_validator.contains(".buildkite/shadow-steps.yml"));
    assert!(definition_validator.contains("component=ci-definition-validator"));
    assert!(definition_validator.contains("github_workflows_verified"));
    assert!(definition_validator.contains("buildkite_definition_verified"));
    assert!(rust_image.contains("rustup component add --toolchain"));
    assert!(rust_image.contains("rustfmt clippy"));

    for forbidden in [
        "tron-ios-release",
        "ios-testflight",
        "release-ios",
        "release-mac",
        "ASC_KEY",
        "IOS_DISTRIBUTION",
        "MACOS_CERT",
        "notarytool",
    ] {
        assert!(
            !bootstrap.contains(forbidden) && !shadow.contains(forbidden),
            "Buildkite execution pipeline must not contain release surface {forbidden}"
        );
    }

    let github_ci = read_repo_file(".github/workflows/ci.yml");
    let ios_release = read_repo_file(".github/workflows/release-ios.yml");
    let mac_release = read_repo_file(".github/workflows/release-mac.yml");
    assert!(github_ci.contains("'CI summary'"));
    assert!(ios_release.contains("workflows: [\"CI\"]"));
    assert!(ios_release.contains("runs-on: macos-26"));
    assert!(ios_release.contains("environment: ios-testflight"));
    assert!(mac_release.contains("tags:\n      - \"server-v*\""));
    assert!(github_ci.contains("ci-cutover-evaluation.py --self-test"));
    assert!(github_ci.contains("scripts/validate-ci-definitions.sh"));
    assert!(github_ci.contains("ready_for_review"));
    assert!(github_ci.contains("converted_to_draft"));
    assert!(github_ci.contains("retention-days: 90"));
    assert!(adapter.contains("ci-cutover-evaluation.py\" --self-test"));

    for (program, arguments) in [
        (
            "python3",
            vec!["scripts/ci-provider-context.py", "--self-test"],
        ),
        (
            "python3",
            vec!["scripts/ci-validation-evidence.py", "--self-test"],
        ),
        (
            "python3",
            vec!["scripts/ci-parity-report.py", "--self-test"],
        ),
        (
            "python3",
            vec!["scripts/ci-cutover-evaluation.py", "--self-test"],
        ),
        ("bash", vec!["scripts/ci-shadow-run.sh", "--self-test"]),
        (
            "bash",
            vec!["scripts/validate-ci-definitions.sh", "--self-test"],
        ),
    ] {
        let output = Command::new(program)
            .args(arguments)
            .current_dir(repo_root())
            .output()
            .unwrap_or_else(|error| panic!("{program} CI self-test failed to start: {error}"));
        assert!(
            output.status.success(),
            "{program} CI self-test failed:\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn github_workflow_dependencies_are_immutable() {
    for path in [
        ".github/workflows/ci.yml",
        ".github/workflows/fast-feedback.yml",
        ".github/workflows/ios-performance.yml",
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
        "TRON_CI_RUST_IMAGE='rust:1.94.1-bookworm@sha256:6ae102bdbf528294bc79ad6e1fae682f6f7c2a6e6621506ba959f9685b308a55'",
        "TRON_CI_ACTIONLINT_IMAGE='rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667'",
        "TRON_CI_BUILDKITE_AGENT_VERSION=3.136.2",
        "TRON_CI_BUILDKITE_AGENT_LINUX_AMD64_SHA256=3a10ff051d7ea08dfcf16e29f7cbe96370e1929f26eec36621ca3802fecf94e9",
        "TRON_CI_BUILDKITE_AGENT_DARWIN_ARM64_SHA256=5e0160bdf509c422bbe78e0f5836acc6e9404196c33bf42a9434470ad2fb935a",
        "TRON_RELEASE_IOS_XCODE_VERSION=26.6",
        "TRON_RELEASE_IOS_XCODE_BUILD=17F113",
        "TRON_RELEASE_IOS_SDK_VERSION=26.5",
        "TRON_RELEASE_IOS_DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer",
        "TRON_RELEASE_IOS_DEPLOYMENT_TARGET=26.0",
        "TRON_RELEASE_APPLE_ROOT_URL=https://www.apple.com/appleca/AppleIncRootCertificate.cer",
        "TRON_RELEASE_APPLE_ROOT_SHA256=b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
        "TRON_RELEASE_APPLE_WWDR_G3_URL=https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer",
        "TRON_RELEASE_APPLE_WWDR_G3_SHA256=dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f",
    ] {
        assert!(
            manifest.contains(required),
            "toolchain manifest lost {required}"
        );
    }
    assert!(
        !manifest.contains("TRON_RELEASE_IOS_DEVELOPER_DIR=/Applications/Xcode-beta"),
        "TestFlight delivery must not select a beta Xcode bundle"
    );
    let doctor = read_repo_file("scripts/ios-release-toolchain-doctor.sh");
    assert!(
        doctor.contains("TRON_RELEASE_IOS_DEVELOPER_DIR\" != *[Bb]eta*")
            && doctor.contains("TestFlight delivery must not use a beta Xcode bundle"),
        "the release doctor must reject a beta Xcode path before archive work"
    );
    assert_eq!(manifest.matches("_SHA256=").count(), 8);

    let installer = read_repo_file("scripts/install-ci-tools.sh");
    assert!(installer.contains("verify_sha256"));
    assert!(installer.contains("shasum -a 256"));
    assert!(installer.contains("--retry-all-errors"));
    assert!(installer.contains("--retry 5"));
    assert!(installer.contains("${destination}.partial.XXXXXX"));
    assert!(installer.contains("mv -f \"$partial\" \"$destination\""));
    assert!(installer.contains("share/xcodegen"));
    assert!(installer.contains("install_buildkite_agent"));
    assert!(installer.contains("component=ci-tool-installer"));
    assert!(installer.contains("download_cache_hit"));
    assert!(installer.contains("download_completed"));
    assert!(installer.contains("tool_prefix_rebuild_completed"));
    for required in [
        "tron.ci-tool-prefix.v1",
        "write_prefix_manifest",
        "verify_prefix_manifest",
        "publish_staged_prefix",
        "${prefix}.staging.XXXXXX",
        "os.replace(temporary, manifest)",
        "write_prefix_manifest \"$staging\" \"$tool\" \"$version\"",
        "\"$validator\" \"$staging\"",
        "publish_staged_prefix \"$staging\" \"$prefix\"",
        "--self-test",
        "incomplete tool prefix was accepted",
        "corrupt tool prefix was accepted",
        "share/create-dmg/support",
    ] {
        assert!(
            installer.contains(required),
            "atomic manifest-sealed CI tool installation is missing {required}"
        );
    }

    let verifier = read_repo_file("scripts/verify-ci-toolchain.sh");
    assert!(verifier.contains("SettingPresets"));
    assert!(verifier.contains("Platforms/iOS.yml"));
    assert!(verifier.contains("Platforms/macOS.yml"));
    assert!(verifier.contains("verify_buildkite_agent"));
    assert!(verifier.contains("verify_owned_prefix create-dmg \"$prefix\""));
    assert!(verifier.contains("template.applescript eula-resources-template.xml"));
    assert!(verifier.contains("share/create-dmg/support/$required"));
    assert!(verifier.contains("component=ci-toolchain-verifier"));
    assert!(verifier.contains("manifest_sha256="));
    assert!(verifier.contains("target_verified"));

    let ios_test = read_repo_file("scripts/ios-ci-test.sh");
    for required in [
        "component=ios-ci-test",
        "build_started",
        "build_completed",
        "test_started",
        "test_completed",
        "metrics_written",
        "ci_completed",
    ] {
        assert!(
            ios_test.contains(required),
            "measured iOS CI execution is missing structured event {required}"
        );
    }

    let installer_self_test = Command::new("bash")
        .args(["scripts/install-ci-tools.sh", "--self-test"])
        .current_dir(repo_root())
        .output()
        .expect("CI tool installer self-test should start");
    assert!(
        installer_self_test.status.success(),
        "CI tool installer self-test failed:\n{}{}",
        String::from_utf8_lossy(&installer_self_test.stdout),
        String::from_utf8_lossy(&installer_self_test.stderr)
    );

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
fn local_ios_test_selection_supports_unfiltered_full_validation_on_macos_bash() {
    let helper = read_repo_file("scripts/tron-ios-simulator");
    for required in [
        "# macOS still ships Bash 3.2",
        "set --\n    selection=",
        "set -- \"$@\" \"-only-testing:$line\"",
        "-derivedDataPath \"$TEST_DERIVED_DATA\" \\\n            \"$@\"",
    ] {
        assert!(
            helper.contains(required),
            "local iOS selection lost its empty-filter-safe argument contract: {required}"
        );
    }
    assert!(
        !helper.contains("test_args"),
        "Bash 3.2 nounset must not expand an empty test-filter array"
    );
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
