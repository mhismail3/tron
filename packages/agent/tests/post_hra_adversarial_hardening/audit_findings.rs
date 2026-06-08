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
        "packages/agent/docs/primitive-code-cleanup-scorecard.md`: active",
        "packages/agent/docs/hierarchical-rearchitecture-scorecard.md`: active",
        "managed skill sync",
        "managed-skill sync",
        "Deleted product campaign scorecards and guides are absent",
    ];

    let mut hits = Vec::new();
    for file in scan_files {
        let text = read_repo_file(&file);
        for needle in banned_needles {
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

#[test]
fn github_ci_runs_rust_static_gates_for_docs_templates_ios_and_mac_changes() {
    let ci = read_repo_file(".github/workflows/ci.yml");
    let required_static_gates = [
        "primitive_engine_teardown_plan_invariants",
        "primitive_code_cleanup_invariants",
        "hierarchical_rearchitecture_invariants",
        "post_hra_adversarial_hardening_invariants",
    ];
    let required_paths = [
        ".github/pull_request_template.md",
        ".github/ISSUE_TEMPLATE/",
        "README.md",
        "AGENTS.md",
        "packages/agent/docs/",
        "packages/ios-app/",
        "packages/mac-app/",
    ];

    for required in required_static_gates {
        assert!(
            ci.contains(required),
            "GitHub CI must run Rust-owned static gate `{required}`"
        );
    }
    for required in required_paths {
        assert!(
            ci.contains(required),
            "GitHub CI path filters must include `{required}`"
        );
    }
}

#[test]
fn github_rust_ci_matches_tron_ci_test_harness_shape() {
    let ci = read_repo_file(".github/workflows/ci.yml");
    for required in [
        "scripts/tron ci test",
        "serial integration",
        "--test integration",
        "--test primitive_trace_execution",
    ] {
        assert!(
            ci.contains(required),
            "GitHub Rust CI must match scripts/tron ci test harness shape: missing `{required}`"
        );
    }
}

#[test]
fn xcodegen_workflows_fail_on_tracked_project_drift() {
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
        (
            "release-mac.yml",
            release_mac.as_str(),
            "packages/mac-app/TronMac.xcodeproj",
        ),
    ] {
        assert!(
            text.contains("xcodegen generate")
                && text.contains("git diff --exit-code")
                && text.contains(project),
            "{name} must fail when xcodegen changes tracked project `{project}`"
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
        "settings loader must live under profile::storage::loader without compatibility exports"
    );
}

#[test]
fn rust_near_budget_files_have_explicit_warning_rows() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let mut hits = Vec::new();
    for file in list_tracked_files_with_extension("rs") {
        if !file.starts_with("packages/agent/src/") {
            continue;
        }
        let loc = source_line_count(&file);
        if loc >= 850 && !scorecard.contains(&file) {
            hits.push(format!("{file}: {loc} LOC"));
        }
    }
    assert_no_hits(
        "Rust files at or above 850 LOC must have explicit near-budget rows",
        hits,
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
fn ios_sourceguard_has_deep_hierarchy_and_budget_gates() {
    let sourceguard = [
        "packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests.swift",
        "packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+Hierarchy.swift",
    ]
    .into_iter()
    .map(read_repo_file)
    .collect::<Vec<_>>()
    .join("\n");

    for required in [
        "Engine/Transport/Clients",
        "UI/Capabilities/Shared",
        "UI/Settings/Shell",
        "UI/Components",
        "Tests/Session/Chat",
        "590",
        "near-budget",
    ] {
        assert!(
            sourceguard.contains(required),
            "SourceGuard must cover deep hierarchy/budget requirement `{required}`"
        );
    }
}

#[test]
fn inventory_and_provenance_have_no_open_or_external_closeout_state() {
    let mut hits = Vec::new();
    for file in [
        "packages/agent/docs/hierarchical-rearchitecture-scorecard.md",
        "packages/agent/docs/hierarchical-rearchitecture-evidence-manifest.md",
        "packages/agent/docs/hierarchical-rearchitecture-inventory.md",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-move-map.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-ios-move-map.tsv",
    ] {
        let text = read_repo_file(file);
        if text.contains("TRON_REARCHITECTURE_PLAN.md") {
            hits.push(format!("{file}: external HRA plan dependency"));
        }
    }

    for file in [
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-move-map.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-ios-move-map.tsv",
    ] {
        let text = read_repo_file(file);
        for line in text.lines().skip(1) {
            let columns: Vec<_> = line.split('\t').collect();
            if let Some(status) = columns.get(8) {
                if matches!(
                    *status,
                    "pending" | "running" | "blocked" | "failed_unfixed" | "deferred_to_successor"
                ) {
                    hits.push(format!(
                        "{file}: open inventory status `{status}` in {line}"
                    ));
                }
            }
        }
    }

    assert_no_hits(
        "completed HRA inventory/provenance must not depend on external plans or open statuses",
        hits,
    );
}
