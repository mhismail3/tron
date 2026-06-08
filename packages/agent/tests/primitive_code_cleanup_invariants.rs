//! Static gates for the whole-repo primitive code cleanup campaign.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
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

fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run in repository tests");
    assert!(
        output.status.success(),
        "git ls-files failed with status {:?}",
        output.status.code()
    );
    String::from_utf8(output.stdout)
        .expect("git ls-files output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn line_count(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
        .lines()
        .count()
}

fn is_static_or_evidence_path(path: &str) -> bool {
    path.contains("scorecard")
        || path.contains("evidence")
        || path.contains("inventory")
        || path.ends_with("primitive_engine_teardown_plan_invariants.rs")
        || path.ends_with("primitive_code_cleanup_invariants.rs")
        || path.ends_with("SourceGuardTests.swift")
}

#[test]
fn primitive_code_cleanup_scorecard_stays_formalized() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-code-cleanup-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/primitive-code-cleanup-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# Primitive Code Cleanup Scorecard",
        "Current score: **22/100**",
        "Status: **active**",
        "Branch: `codex/primitive-engine-teardown`",
        "Primitive And Plane Budget",
        "Folder Justification Table",
        "Large File Budgets",
        "Static Gates",
        "| PCC-0 | Scorecard, evidence, and static-gate setup | 5 | passed_after_fix |",
        "| PCC-10 | Final adversarial pass | 8 | pending |",
        "Total weight: **100**",
        "| PCC-1 | Inventory and folder justification | 12 | passed_after_fix |",
        "| PCC-2 | Root and generated artifact hygiene | 5 | passed_after_fix |",
        "| PCC-3 | Rust agent consolidation | 18 | running |",
        "Continue PCC-3 with the small-domain collapse audit:",
        "primitive-code-cleanup-inventory.md",
        "primitive-code-cleanup-file-inventory.tsv",
    ] {
        assert!(
            scorecard.contains(required),
            "cleanup scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Primitive Code Cleanup Evidence Manifest",
        "Current score: **22/100**",
        "Status: **active**",
        "| PCC-0 | passed_after_fix |",
        "| PCC-1 | passed_after_fix |",
        "| PCC-2 | passed_after_fix |",
        "| PCC-3 | running |",
    ] {
        assert!(
            manifest.contains(required),
            "cleanup evidence manifest missing required text: {required}"
        );
    }

    assert!(
        readme.contains("packages/agent/docs/primitive-code-cleanup-scorecard.md")
            && readme.contains("packages/agent/docs/primitive-code-cleanup-evidence-manifest.md"),
        "README living-doc map must link the active cleanup scorecard and evidence manifest"
    );
}

#[test]
fn primitive_code_cleanup_inventory_covers_tracked_files() {
    let inventory = read_repo_file("packages/agent/docs/primitive-code-cleanup-inventory.md");
    let file_inventory =
        read_repo_file("packages/agent/docs/primitive-code-cleanup-file-inventory.tsv");
    let readme = read_repo_file("README.md");

    for required in [
        "# Primitive Code Cleanup Inventory",
        "Status: `passed_after_fix`",
        "Machine-readable inventory",
        "Classification Vocabulary",
        "Canonical Target Tree",
        "Delete Candidates",
        "Collapse-Audit Hotspots",
        "Open Loops",
    ] {
        assert!(
            inventory.contains(required),
            "cleanup inventory missing required text: {required}"
        );
    }

    assert!(
        readme.contains("packages/agent/docs/primitive-code-cleanup-inventory.md")
            && readme.contains("packages/agent/docs/primitive-code-cleanup-file-inventory.tsv"),
        "README living-doc map must link cleanup inventory artifacts"
    );

    let mut seen_paths = HashSet::new();
    let mut counts = HashMap::<&str, usize>::new();
    let mut lines = file_inventory.lines();
    assert_eq!(
        lines.next(),
        Some("path\tclassification\towner\tcleanup_row\treason"),
        "file inventory must keep a stable TSV header"
    );
    for line in lines {
        let columns: Vec<_> = line.split('\t').collect();
        assert_eq!(
            columns.len(),
            5,
            "inventory row must have five TSV columns: {line}"
        );
        assert!(
            matches!(
                columns[1],
                "retain" | "collapse" | "delete" | "generated" | "asset"
            ),
            "invalid inventory classification `{}` for {}",
            columns[1],
            columns[0]
        );
        assert!(
            !columns[2].is_empty() && !columns[3].is_empty() && !columns[4].is_empty(),
            "inventory row must name owner, cleanup row, and reason: {line}"
        );
        *counts.entry(columns[1]).or_insert(0) += 1;
        assert!(
            seen_paths.insert(columns[0].to_owned()),
            "duplicate file inventory row for {}",
            columns[0]
        );
    }

    for path in git_ls_files().into_iter().chain([
        "packages/agent/docs/primitive-code-cleanup-inventory.md".to_owned(),
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv".to_owned(),
    ]) {
        assert!(
            seen_paths.contains(&path),
            "tracked file missing cleanup inventory classification: {path}"
        );
    }

    for classification in ["retain", "collapse", "delete", "generated", "asset"] {
        assert!(
            counts.get(classification).copied().unwrap_or_default() > 0,
            "inventory must contain at least one `{classification}` row"
        );
    }
}

#[test]
fn retained_top_level_source_directories_are_justified() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-code-cleanup-scorecard.md");
    for path in [
        ".claude",
        ".codex",
        ".github",
        "packages",
        "scripts",
        "packages/agent",
        "packages/ios-app",
        "packages/mac-app",
        "packages/agent/src/app",
        "packages/agent/src/transport",
        "packages/agent/src/engine",
        "packages/agent/src/domains",
        "packages/agent/src/shared",
        "packages/agent/src/platform",
        "packages/ios-app/Sources/App",
        "packages/ios-app/Sources/Core",
        "packages/ios-app/Sources/Database",
        "packages/ios-app/Sources/Extensions",
        "packages/ios-app/Sources/IconLayers",
        "packages/ios-app/Sources/Models",
        "packages/ios-app/Sources/Protocols",
        "packages/ios-app/Sources/Resources",
        "packages/ios-app/Sources/Services",
        "packages/ios-app/Sources/Theme",
        "packages/ios-app/Sources/Utilities",
        "packages/ios-app/Sources/ViewModels",
        "packages/ios-app/Sources/Views",
        "packages/ios-app/Sources/Assets.xcassets",
        "packages/mac-app/Sources/Assets.xcassets",
        "packages/mac-app/Sources/MenuBar",
        "packages/mac-app/Sources/Resources",
        "packages/mac-app/Sources/Services",
        "packages/mac-app/Sources/Theme",
        "packages/mac-app/Sources/Wizard",
    ] {
        assert!(
            scorecard.contains(&format!("| `{path}` |")),
            "folder justification table missing retained directory `{path}`"
        );
    }
}

#[test]
fn deleted_product_terms_stay_outside_scorecards_evidence_and_static_gates() {
    let banned_terms = [
        "AgentControl",
        "Agent Control",
        "PromptLibrary",
        "Prompt Library",
        "VoiceNotes",
        "Voice Notes",
        "SourceControl",
        "Source Control",
        "AuditDetails",
        "Audit Details",
        "Plugin Sources",
        "SessionTree",
        "postProcessing",
    ];

    for path in git_ls_files() {
        if is_static_or_evidence_path(&path) {
            continue;
        }
        if !matches!(
            Path::new(&path)
                .extension()
                .and_then(|extension| extension.to_str()),
            Some("md" | "rs" | "swift")
        ) {
            continue;
        }
        let text = read_repo_file(&path);
        for term in banned_terms {
            assert!(
                !text.contains(term),
                "deleted product term `{term}` must stay out of {path}"
            );
        }
    }
}

#[test]
fn large_source_files_have_explicit_cleanup_budget_rows() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-code-cleanup-scorecard.md");
    for path in git_ls_files() {
        let extension = Path::new(&path)
            .extension()
            .and_then(|extension| extension.to_str());
        let budget = match extension {
            Some("rs") => 1_000,
            Some("swift") => 800,
            _ => continue,
        };
        if path.contains(".xcodeproj/") || path.contains("Assets.xcassets/") {
            continue;
        }
        let lines = line_count(&repo_path(&path));
        if lines > budget {
            assert!(
                scorecard.contains(&format!("| `{path}` |")),
                "large source file {path} has {lines} LOC but no cleanup budget row"
            );
        }
    }
}

#[test]
fn tracked_generated_and_cache_junk_stays_absent() {
    for path in git_ls_files() {
        assert!(
            !path.contains("/__pycache__/")
                && !path.ends_with(".pyc")
                && !path.contains("/node_modules/")
                && !path.contains("/target/")
                && !path.contains(".xcresult/"),
            "tracked generated/cache artifact must not be committed: {path}"
        );
    }
}

#[test]
fn project_gitignore_covers_recurring_local_artifacts() {
    let gitignore = read_repo_file(".gitignore");
    for pattern in [
        "**/target/",
        "packages/ios-app/.build/",
        "packages/ios-app/build/",
        "DerivedData/",
        "*.xcresult",
        "*.dSYM/",
        "node_modules/",
        "__pycache__/",
        "*.pyc",
        ".pytest_cache/",
        "scripts/artifacts/",
        "tmp/",
        "*.log",
        ".worktrees/",
    ] {
        assert!(
            gitignore.contains(pattern),
            "root .gitignore must cover recurring local artifact pattern `{pattern}`"
        );
    }
}

#[test]
fn rust_dead_dependency_artifacts_stay_removed() {
    let cargo_toml = read_repo_file("packages/agent/Cargo.toml");
    let cargo_lock = read_repo_file("packages/agent/Cargo.lock");

    for banned in [
        "fastembed",
        "sqlite-vec",
        "rquickjs",
        "rquickjs-serde",
        "resvg",
    ] {
        assert!(
            !cargo_toml.contains(banned),
            "Cargo.toml must not reintroduce dead dependency `{banned}`"
        );
        assert!(
            !cargo_lock.contains(banned),
            "Cargo.lock must not retain dead dependency `{banned}`"
        );
    }

    assert!(
        !cargo_toml.contains("\nimage = ") && !cargo_lock.contains("name = \"image\""),
        "standalone image conversion dependency must stay removed"
    );

    let retired_asset = repo_path("packages/agent/assets/capability-search");
    assert!(
        !retired_asset.exists(),
        "retired capability-search asset bundle must stay deleted"
    );
}
