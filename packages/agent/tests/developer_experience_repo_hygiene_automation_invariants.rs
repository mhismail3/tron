//! Static and source-backed invariants for the Developer Experience / Repo
//! Hygiene / Automation slice.

use std::collections::{BTreeMap, BTreeSet};
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

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| DXRHA-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "DXRHA scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid DXRHA weight in {line}: {error}")),
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
            "id\tpath\tsurface_kind\towner\tworkflow_rule\tlocal_proof\tgithub_or_remote_proof\tscorecard_rows"
        ),
        "DXRHA inventory TSV header changed"
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

fn assert_order(source: &str, before: &str, after: &str, context: &str) {
    let before_index = source
        .find(before)
        .unwrap_or_else(|| panic!("{context}: missing before marker {before:?}"));
    let after_index = source
        .find(after)
        .unwrap_or_else(|| panic!("{context}: missing after marker {after:?}"));
    assert!(
        before_index < after_index,
        "{context}: expected {before:?} before {after:?}"
    );
}

#[test]
fn dxrha_artifacts_and_static_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing DXRHA artifact: {path}");
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
        assert!(
            source.contains(TARGET_NAME),
            "{path} must run the DXRHA invariant target"
        );
    }
}

#[test]
fn dxrha_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        (
            "DXRHA-0",
            ("Baseline, lineage, and stale-branch quarantine", 5_u32),
        ),
        ("DXRHA-1", ("Whole contributor workflow inventory", 10)),
        (
            "DXRHA-2",
            ("scripts/tron UX and command dispatch discipline", 10),
        ),
        ("DXRHA-3", ("Local CI and GitHub CI target parity", 12)),
        ("DXRHA-4", ("Generated artifact discipline", 10)),
        (
            "DXRHA-5",
            ("Stale tracked ignored/build artifact hygiene", 8),
        ),
        (
            "DXRHA-6",
            ("Setup/dev server path and runtime-state clarity", 10),
        ),
        ("DXRHA-7", ("Version and release-helper sanity", 8)),
        ("DXRHA-8", ("Docs/inventory/README upkeep workflow", 8)),
        ("DXRHA-9", ("Branch, handoff, and remote pickup hygiene", 7)),
        ("DXRHA-10", ("Broad verification and final closeout", 12)),
    ]);
    assert_eq!(rows.len(), expected.len(), "DXRHA must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected DXRHA row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "DXRHA scorecard weights must sum to 100");

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "codex/developer-experience-repo-hygiene-automation-current",
        "485819810382db7f763196b8305426e1f3f8a839",
        "codex/developer-experience-repo-hygiene-automation",
        "9ef779cf5",
        "quarry-only",
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for forbidden in ["TODO", "TBD", "placeholder", "pending"] {
        assert!(
            !scorecard.contains(forbidden),
            "closed DXRHA scorecard must not contain {forbidden}"
        );
    }
}

#[test]
fn dxrha_inventory_is_structured_and_covers_required_workflow_surfaces() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 45,
        "DXRHA inventory row count regressed: {}",
        rows.len()
    );

    let allowed_surfaces = BTreeSet::from([
        "setup",
        "dev_server",
        "local_ci",
        "github_ci",
        "static_gate",
        "generated_project",
        "version_release",
        "personal_info_guard",
        "docs_upkeep",
        "predecessor_inventory",
        "branch_handoff",
        "ignored_artifact",
        "tests",
        "release_boundary",
    ]);
    let mut ids = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    let mut covered_rows = BTreeSet::new();
    let mut by_path = BTreeMap::new();
    for row in &rows {
        assert_eq!(row.len(), 8, "DXRHA row must have 8 fields: {row:?}");
        assert!(ids.insert(row[0].clone()), "duplicate DXRHA id {}", row[0]);
        assert!(row[0].starts_with("DXRHA-INV-"));
        assert!(
            tracked_or_present(&row[1]),
            "DXRHA inventory path must be tracked or present: {}",
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
                    && !field.contains("pending")
                    && !field.contains("unclassified"),
                "invalid DXRHA inventory field in row {:?}",
                row
            );
        }
        surfaces.insert(row[2].clone());
        by_path.insert(row[1].clone(), row.clone());
        for row_id in row[7].split(',') {
            covered_rows.insert(row_id.to_owned());
        }
    }
    for surface in allowed_surfaces {
        assert!(
            surfaces.contains(surface),
            "missing DXRHA surface {surface}"
        );
    }
    for row_id in 0..=10 {
        assert!(
            covered_rows.contains(&format!("DXRHA-{row_id}")),
            "DXRHA inventory does not cover DXRHA-{row_id}"
        );
    }
    for required_path in [
        "scripts/tron",
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/quality.sh",
        "scripts/tron-version",
        "scripts/tron-release-notes",
        "scripts/personal-info-guard.sh",
        "scripts/install-hooks.sh",
        ".github/workflows/ci.yml",
        ".github/pull_request_template.md",
        ".gitignore",
        "packages/mac-app/.gitignore",
        "packages/ios-app/project.yml",
        "packages/ios-app/TronMobile.xcodeproj/project.pbxproj",
        "packages/mac-app/project.yml",
        "packages/mac-app/docs/development.md",
        "packages/ios-app/docs/development.md",
        "CONTRIBUTING.md",
        "README.md",
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            by_path.contains_key(required_path),
            "DXRHA inventory missing required path {required_path}"
        );
    }
}

#[test]
fn local_and_github_static_gate_targets_match_exactly() {
    let local_targets = parse_quality_closeout_targets();
    let github_targets = parse_github_static_gate_targets();
    assert_eq!(
        local_targets, github_targets,
        "scripts/tron ci test and GitHub rust-static-gates must run the same closeout target set in the same order"
    );
    assert!(
        local_targets.contains(&TARGET_NAME.to_owned()),
        "DXRHA target must be in the closeout set"
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
}

#[test]
fn scripts_tron_dispatch_help_and_docs_stay_in_sync_without_hidden_deploy() {
    let script = read_repo_file("scripts/tron");
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let readme = read_repo_file("README.md");
    let contributing = read_repo_file("CONTRIBUTING.md");
    let pr_template = read_repo_file(".github/pull_request_template.md");

    for command in [
        "dev",
        "ci",
        "bench",
        "version",
        "setup",
        "preflight",
        "manual-deploy",
        "install",
        "rollback",
        "uninstall",
        "status",
        "start",
        "stop",
        "restart",
        "login",
        "auth",
        "logs",
        "errors",
    ] {
        assert!(
            script.contains(command),
            "scripts/tron help/dispatch missing {command}"
        );
        assert!(
            readme.contains(&format!("`tron {command}`"))
                || readme.contains(&format!(" {command} ")),
            "README CLI reference missing {command}"
        );
    }

    assert!(script.contains("*) print_error \"Unknown command: $1\"; cmd_help; exit 1 ;;"));
    assert!(
        !script
            .lines()
            .any(|line| line.trim_start().starts_with("deploy)")),
        "scripts/tron must not add tron deploy"
    );
    assert!(
        !quality.contains("manual-deploy") && !quality.contains("cmd_manual_deploy"),
        "local CI must not hide a manual deploy path"
    );
    assert!(
        readme.contains("The command has no shorter deploy alias")
            && readme.contains("Production releases are the notarized DMG pipeline"),
        "README must keep deployment manual-only and explicit"
    );
    assert!(
        contributing.contains("scripts/tron dev --stop"),
        "CONTRIBUTING must document the actual dev stop option"
    );
    assert!(
        pr_template.contains("scripts/tron ci fmt check clippy test")
            && pr_template.contains("git diff --check")
            && pr_template.contains("git ls-files -ci --exclude-standard"),
        "PR template must keep local closeout hygiene visible"
    );
}

#[test]
fn generated_and_ignored_artifact_policy_is_source_guarded() {
    let tracked = git_ls_files();
    assert!(
        tracked.contains("packages/ios-app/TronMobile.xcodeproj/project.pbxproj"),
        "iOS generated project is intentionally tracked and must stay visible to drift checks"
    );
    assert!(
        !tracked
            .iter()
            .any(|path| path.starts_with("packages/mac-app/TronMac.xcodeproj/")),
        "Mac generated project must stay ignored, not tracked"
    );

    let root_gitignore = read_repo_file(".gitignore");
    for required in [
        "**/target/",
        "packages/ios-app/.build/",
        "packages/ios-app/build/",
        "*.xcresult",
        "DerivedData/",
        "scripts/artifacts/",
        "node_modules/",
    ] {
        assert!(
            root_gitignore.contains(required),
            ".gitignore missing {required}"
        );
    }
    let mac_gitignore = read_repo_file("packages/mac-app/.gitignore");
    for required in [
        "TronMac.xcodeproj/",
        "build/",
        "DerivedData/",
        "Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron",
        "Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron",
    ] {
        assert!(
            mac_gitignore.contains(required),
            "Mac .gitignore missing {required}"
        );
    }

    let ignored_tracked = git_output(&["ls-files", "-ci", "--exclude-standard"]);
    assert!(
        ignored_tracked.trim().is_empty(),
        "tracked ignored files must stay absent:\n{ignored_tracked}"
    );

    let ci = read_repo_file(".github/workflows/ci.yml");
    for required in [
        "git diff --exit-code packages/ios-app/TronMobile.xcodeproj",
        "git check-ignore -q packages/mac-app/TronMac.xcodeproj",
        "Verify generated Xcode project is committed",
        "Verify generated Xcode project stays ignored",
    ] {
        assert!(
            ci.contains(required),
            "CI missing generated-project guard {required}"
        );
    }
}

#[test]
fn setup_dev_runtime_state_and_version_helpers_are_documented_and_guarded() {
    let readme = read_repo_file("README.md");
    let tron_lib = read_repo_file("scripts/tron-lib.sh");
    let dev = read_repo_file("scripts/tron.d/dev.sh");
    let version = read_repo_file("scripts/tron-version");
    let release_notes = read_repo_file("scripts/tron-release-notes");
    let ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "$TRON_HOME\"/internal/{database,run}",
        "$TRON_HOME\"/memory/{rules,sessions}",
        "$WORKSPACE_DIR\"/{projects,plans,reports,renders,screenshots,scratch,labs,archive}",
        "Standalone settings JSON is intentionally not created here",
    ] {
        assert!(tron_lib.contains(required), "tron-lib missing {required}");
    }
    for required in [
        "tron dev -bd --json --wait",
        "~/.tron/",
        "+-- memory/",
        "move `~/.tron` aside",
        "port `9847`",
    ] {
        assert!(
            readme.contains(required),
            "README missing runtime-state marker {required}"
        );
    }
    assert!(
        !readme.contains("startup no longer creates a top-level `memory` directory"),
        "README must not contradict scripts/tron-lib.sh memory directory seeding"
    );

    for required in [
        "launchd_stop \"$DEV_PLIST_NAME\"",
        "launchd_stop \"$PLIST_NAME\"",
        "wait_for_port_free \"$PROD_PORT\" 10",
        "restart_installed_service_after_dev 12",
        "--json",
        "--wait",
        "--stop",
    ] {
        assert!(dev.contains(required), "dev.sh missing {required}");
    }

    for required in [
        "VERSION.env is the only hand-edited release identity file",
        "self_test()",
        "asset_version 0.1.0-beta.3",
        "scripts/tron\" version check",
    ] {
        assert!(
            version.contains(required),
            "tron-version missing {required}"
        );
    }
    for required in [
        "deterministic GitHub Release changelog generator",
        "--test",
        "Release notes helper tests passed",
        "Changelog truncated in the GitHub release body",
    ] {
        assert!(
            release_notes.contains(required),
            "tron-release-notes missing {required}"
        );
    }
    for required in [
        "./scripts/tron version check",
        "./scripts/tron version test",
        "./scripts/tron-release-notes --test",
    ] {
        assert!(
            ci.contains(required),
            "CI missing version/release guard {required}"
        );
    }
}

#[test]
fn closeout_evidence_records_required_commands_without_open_placeholders() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "scripts/tron version check",
        "scripts/tron version test",
        "scripts/tron-release-notes --test",
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "DXRHA evidence manifest missing command: {command}"
        );
    }
    for forbidden in ["TODO", "TBD", "placeholder", "pending"] {
        assert!(
            !evidence.contains(forbidden),
            "closed DXRHA evidence must not contain {forbidden}"
        );
    }
}

#[test]
fn predecessor_inventories_classify_dxrha_artifacts() {
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
    ] {
        let source = read_repo_file(predecessor);
        for required_path in required_paths {
            assert!(
                source.contains(required_path),
                "{predecessor} missing DXRHA artifact {required_path}"
            );
        }
    }
}

#[test]
fn branch_handoff_and_remote_pickup_rules_are_recorded() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    for required in [
        "codex/developer-experience-repo-hygiene-automation-current",
        "codex/developer-experience-repo-hygiene-automation",
        "quarry-only",
        "git status --short",
        "stale branch",
        "another thread can continue without chat history",
    ] {
        assert!(
            scorecard.contains(required)
                || evidence.contains(required)
                || inventory.contains(required),
            "DXRHA branch/handoff docs missing {required}"
        );
    }
    assert_order(
        &scorecard,
        "485819810382db7f763196b8305426e1f3f8a839",
        "`codex/developer-experience-repo-hygiene-automation` branch is stale",
        "scorecard must establish current lineage before stale-branch quarantine",
    );
}
