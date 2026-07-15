use super::support::*;
use std::process::Command;

#[test]
fn full_repo_personal_info_guard_passes() {
    let mut command = Command::new(repo_path("scripts/personal-info-guard.sh"));
    command.current_dir(repo_root());
    let (ok, output) = command_output(&mut command);
    assert!(ok, "full personal-info guard must pass:\n{output}");
}

#[test]
fn live_docs_templates_and_scorecards_have_no_deleted_doc_residue() {
    let scan_files: Vec<_> = git_ls_files()
        .into_iter()
        .filter(|path| {
            path == "README.md"
                || path == "CONTRIBUTING.md"
                || path == "AGENTS.md"
                || path.starts_with(".github/")
                || path.starts_with("packages/agent/docs/")
                || path.starts_with("packages/ios-app/docs/")
                || path.starts_with("packages/mac-app/docs/")
                || path == "packages/ios-app/README.md"
        })
        .filter(|path| path.ends_with(".md") || path.ends_with(".yml"))
        .collect();

    let banned_needles = [
        ".claude",
        "CLAUDE",
        "managed skill sync",
        "managed-skill sync",
        "Deleted product campaign scorecards and guides are absent",
    ];

    let mut hits = Vec::new();
    for file in scan_files {
        let text = read_repo_file(&file);
        for needle in banned_needles {
            if needle == ".claude" && iarm_old_tree_census_allows_claude_rule_paths(&file, &text) {
                continue;
            }
            if text.contains(needle) {
                hits.push(format!("{file}: {needle}"));
            }
        }
    }

    assert_no_hits(
        "live docs/templates/scorecards must not retain deleted-doc residue",
        hits,
    );
}

fn iarm_old_tree_census_allows_claude_rule_paths(file: &str, text: &str) -> bool {
    matches!(
        file,
        "packages/agent/docs/ios-affordance-restoration-map-inventory.md"
            | "packages/agent/docs/ios-affordance-restoration-map-evidence-manifest.md"
    ) && (text.contains("old-path census") || text.contains("The old reference contributes"))
        && (text.contains("old `.claude/rules` paths") || text.contains("`.claude/rules/` paths"))
}

#[test]
fn github_ci_runs_rust_quality_for_docs_templates_ios_and_mac_changes() {
    let ci = read_repo_file(".github/workflows/ci.yml");
    assert!(
        ci.contains("run: scripts/tron ci test"),
        "GitHub CI must delegate Rust tests to scripts/tron ci test"
    );
    let rust_job = ci
        .split_once("\n  rust:\n")
        .and_then(|(_, rest)| rest.split_once("\n  ios:\n"))
        .map(|(job, _)| job)
        .expect("GitHub CI must define rust before ios");
    assert!(
        !rust_job
            .lines()
            .any(|line| line.trim_start().starts_with("if:")),
        "GitHub Rust CI must be unconditional so docs, templates, iOS, and Mac changes run static gates"
    );
}

#[test]
fn tron_ci_clippy_contract_matches_cargo_lint_policy() {
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let cargo_toml = read_repo_file("packages/agent/Cargo.toml");
    assert!(
        quality.contains("cargo clippy --workspace --all-targets")
            && cargo_toml.contains("[lints.clippy]"),
        "`tron ci clippy` must enforce the Cargo.toml lint policy"
    );

    let mut hits = Vec::new();
    for file in [
        "README.md",
        "CONTRIBUTING.md",
        "scripts/tron",
        "scripts/tron-cli",
        "scripts/tron.d/quality.sh",
    ] {
        let text = read_repo_file(file);
        for (index, line) in text.lines().enumerate() {
            if line.contains("clippy") && line.contains("-D warnings") {
                hits.push(format!("{file}:{}: {line}", index + 1));
            }
        }
    }
    assert_no_hits(
        "`tron ci clippy` docs/help must not claim a blanket -D warnings policy",
        hits,
    );
}

#[test]
fn xcodegen_workflows_keep_generated_projects_untracked() {
    let ci = read_repo_file(".github/workflows/ci.yml");
    let release_ios = read_repo_file(".github/workflows/release-ios.yml");
    let release_mac = read_repo_file(".github/workflows/release-mac.yml");

    for (name, text, project) in [
        (
            "ci.yml",
            ci.as_str(),
            "packages/ios-app/TronMobile.xcodeproj",
        ),
        (
            "release-ios.yml",
            release_ios.as_str(),
            "packages/ios-app/TronMobile.xcodeproj",
        ),
        ("ci.yml", ci.as_str(), "packages/mac-app/TronMac.xcodeproj"),
        (
            "release-mac.yml",
            release_mac.as_str(),
            "packages/mac-app/TronMac.xcodeproj",
        ),
    ] {
        let ignore_guard = format!("git check-ignore -q {project}");
        let tracked_guard = format!("git diff --exit-code {project}");
        assert!(
            text.contains("xcodegen generate")
                && text.contains(project)
                && text.contains(&ignore_guard)
                && !text.contains(&tracked_guard),
            "{name} must generate `{project}` and keep it ignored"
        );
    }
}

#[test]
fn mac_ci_runs_focused_wrapper_tests() {
    let ci = read_repo_file(".github/workflows/ci.yml");
    for required in [
        "TronPathsTests",
        "ServerStatusPollerTests",
        "TailscaleProbeTests",
    ] {
        assert!(
            ci.contains(required),
            "Mac CI must run focused wrapper suite `{required}`"
        );
    }
    assert!(
        ci.contains("build-for-testing"),
        "Mac CI should keep build-for-testing compile coverage"
    );
}

#[test]
fn rust_production_modules_have_no_path_aliases_or_module_inception() {
    let mut hits = Vec::new();
    for file in list_tracked_files_with_extension("rs") {
        if !file.starts_with("packages/agent/src/") {
            continue;
        }
        let text = read_repo_file(&file);
        if text.contains("#[path =") {
            hits.push(format!("{file}: #[path ="));
        }
        if text.contains("module_inception") {
            hits.push(format!("{file}: module_inception"));
        }
    }
    assert_no_hits(
        "production Rust modules must not use path aliases or module inception allowances",
        hits,
    );
}

#[test]
fn rust_provider_shared_and_settings_loader_use_physical_owners() {
    let providers_mod = read_repo_file("packages/agent/src/domains/model/providers/mod.rs");
    let settings_mod = read_repo_file("packages/agent/src/domains/settings/profile/mod.rs");

    assert!(
        providers_mod.contains("pub mod shared;") && !providers_mod.contains("#[path = \"shared/"),
        "provider shared helpers must live under providers::shared with physical module declarations"
    );
    assert!(
        settings_mod.contains("pub mod storage;") && !settings_mod.contains("pub mod loader"),
        "settings loader must live under profile::storage::loader without duplicate exports"
    );
}

#[test]
fn rust_ownership_roots_have_progressive_docs() {
    let required_docs = [
        "packages/agent/src/domains/agent/loop/orchestrator/mod.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/core/mod.rs",
        "packages/agent/src/domains/model/providers/mod.rs",
        "packages/agent/src/domains/model/providers/shared/mod.rs",
        "packages/agent/src/domains/settings/profile/mod.rs",
        "packages/agent/src/domains/settings/profile/storage/mod.rs",
    ];

    let mut missing_sections = Vec::new();
    for file in required_docs {
        let source = read_repo_file(file);
        for section in [
            "## Submodules",
            "## Entry Points",
            "## Dependency Direction",
            "## Invariants",
            "## Test Ownership",
        ] {
            if !source.contains(section) {
                missing_sections.push(format!("{file} missing {section}"));
            }
        }
    }

    assert_no_hits(
        "ownership-critical Rust roots must carry progressive docs",
        missing_sections,
    );
}

#[test]
fn ios_engine_clients_have_no_misc_facade() {
    let mut hits = Vec::new();
    for file in list_tracked_files_with_extension("swift") {
        if !file.starts_with("packages/ios-app/Sources/")
            && !file.starts_with("packages/ios-app/Tests/")
        {
            continue;
        }
        let text = read_repo_file(&file);
        for needle in ["MiscClient", ".misc", " misc:", "let misc", "var misc"] {
            if text.contains(needle) {
                hits.push(format!("{file}: {needle}"));
            }
        }
    }
    assert_no_hits("iOS engine clients must not retain a misc facade", hits);
}

#[test]
fn ios_transport_domain_residue_is_removed() {
    let mut hits = Vec::new();
    for file in list_tracked_files_with_extension("swift") {
        if !file.starts_with("packages/ios-app/Sources/")
            && !file.starts_with("packages/ios-app/Tests/")
        {
            continue;
        }
        let text = read_repo_file(&file);
        for line in text.lines() {
            if line.trim() == "@available(iOS 26.0, *)" {
                hits.push(format!("{file}: redundant iOS 26 availability annotation"));
            }
        }
        for needle in [
            "Sub-Managers",
            "git workflow sub-sheets",
            "PROTECTED_BRANCH",
            "NO_REMOTE",
            "NON_FAST_FORWARD",
            "GIT_AUTH_FAILED",
            "GIT_NETWORK_ERROR",
            "DIRTY_WORKING_TREE",
            "MISSING_BASE_BRANCH",
            "REF_NOT_FOUND",
            "BRANCH_EXISTS",
            "BRANCH_ACTIVE",
            "NOT_GIT_REPO",
            "GIT_ERROR",
            "friendlyGitError",
        ] {
            if text.contains(needle) {
                hits.push(format!("{file}: {needle}"));
            }
        }
    }
    assert_no_hits(
        "iOS transport/domain cleanup must remove stale Git, availability, and manager residue",
        hits,
    );
}

#[test]
fn ios_sourceguard_has_deep_hierarchy_and_budget_gates() {
    let sourceguard = list_tracked_files_with_extension("swift")
        .into_iter()
        .filter(|path| {
            path.starts_with("packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests")
        })
        .map(|path| read_repo_file(&path))
        .collect::<Vec<_>>()
        .join("\n");

    for required in [
        "Engine/Transport/Clients",
        "UI/Capabilities/Shared",
        "UI/Settings/Shell",
        "UI/Components",
        "Tests/Session/Chat",
        "testIOSDeepHierarchyRootsHaveExplicitCountAndBudgetGates",
        "testIOSDeploymentTargetAvailabilityAnnotationsAreNotDuplicated",
        "hardLineLimit = 700",
        "maximumLineCount: hardLineLimit",
    ] {
        assert!(
            sourceguard.contains(required),
            "SourceGuard must cover deep hierarchy/budget requirement `{required}`"
        );
    }
}
