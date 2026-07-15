//! Living contracts for repository-owned validation and documentation entry points.

use std::collections::BTreeSet;
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
    ] {
        assert!(
            readme.contains(required),
            "root README front door is missing {required}"
        );
    }
}

#[test]
fn local_and_github_ci_share_one_fail_fast_test_schedule() {
    let local_targets = quality_discovered_integration_targets();
    let discovered_targets = cargo_discovered_integration_targets();
    let workflow = read_repo_file(".github/workflows/ci.yml");

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
fn github_ci_schedules_clients_and_aggregates_fail_closed() {
    let workflow = read_repo_file(".github/workflows/ci.yml");
    let ios_filter = workflow
        .split_once("            ios:\n")
        .and_then(|(_, rest)| rest.split_once("            mac:\n"))
        .map(|(filter, _)| filter)
        .expect("CI must define the iOS path filter before the Mac filter");
    assert!(
        ios_filter.contains("packages/ios-app/**")
            && ios_filter.contains(".github/workflows/release-ios.yml"),
        "iOS source and release changes must schedule iOS validation"
    );
    let mac_filter = workflow
        .split_once("            mac:\n")
        .and_then(|(_, rest)| rest.split_once("\n\n  personal-info-guard:\n"))
        .map(|(filter, _)| filter)
        .expect("CI must define the Mac path filter before validation jobs");
    for required in [
        "packages/agent/**",
        "packages/mac-app/**",
        ".github/workflows/release-mac.yml",
    ] {
        assert!(
            mac_filter.contains(required),
            "Mac validation filter is missing {required}"
        );
    }

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
