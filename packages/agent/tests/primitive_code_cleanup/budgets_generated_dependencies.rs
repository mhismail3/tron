use super::support::*;

use std::collections::BTreeSet;

const PHASE_TWO_INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/phase-2-agent-execution-restoration-inventory.tsv";
const PHASE_TWO_SCORECARD_PATH: &str =
    "packages/agent/docs/phase-2-agent-execution-restoration-scorecard.md";
const PHASE_TWO_EVIDENCE_PATH: &str =
    "packages/agent/docs/phase-2-agent-execution-restoration-evidence-manifest.md";
const FEATURE_INDEX_PATH: &str =
    "packages/agent/docs/primitive-baseline-vs-modular-capability-engine-feature-index.md";

fn removed_dependency_names_from_feature_index() -> BTreeSet<String> {
    let feature_index = read_repo_file(FEATURE_INDEX_PATH);
    let start = feature_index
        .find("### 24. Dependencies That Indicate Removed Behavior")
        .expect("feature index must retain dependency restoration section 24");
    let section_and_tail = &feature_index[start..];
    let end = section_and_tail
        .find("\n## ")
        .expect("feature index dependency section must end before next heading");
    let section = &section_and_tail[..end];
    section
        .lines()
        .filter(|line| line.trim_start().starts_with("- `"))
        .flat_map(|line| {
            line.split('`')
                .enumerate()
                .filter_map(|(index, part)| (index % 2 == 1).then_some(part.to_owned()))
                .collect::<Vec<_>>()
        })
        .collect()
}

fn direct_dependency_declared(cargo_toml: &str, dependency: &str) -> bool {
    cargo_toml.lines().any(|line| {
        let trimmed = line.trim_start();
        trimmed.starts_with(&format!("{dependency} ="))
            || trimmed.starts_with(&format!("\"{dependency}\" ="))
            || trimmed.contains(&format!("package = \"{dependency}\""))
    })
}

fn phase_two_inventory_row(row_id: &str) -> Vec<String> {
    let inventory = read_repo_file(PHASE_TWO_INVENTORY_TSV_PATH);
    let row = inventory
        .lines()
        .find(|line| line.starts_with(&format!("{row_id}\t")))
        .unwrap_or_else(|| panic!("missing Phase 2 inventory row {row_id}"));
    row.split('\t').map(str::to_owned).collect()
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

    for banned in removed_dependency_names_from_feature_index() {
        assert!(
            !direct_dependency_declared(&cargo_toml, &banned),
            "Cargo.toml must not reintroduce removed dependency `{banned}` without an owning module and Phase 2 dependency-restoration rationale"
        );
        assert!(
            !cargo_lock.contains(&format!("name = \"{banned}\"")),
            "Cargo.lock must not retain removed dependency `{banned}` without an owning module and Phase 2 dependency-restoration rationale"
        );
    }

    for banned in [
        "indexmap",
        "pin-project-lite",
        "assert_matches",
        "insta",
        "mockall",
        "proptest",
    ] {
        assert!(
            !direct_dependency_declared(&cargo_toml, banned),
            "Cargo.toml must not retain unused direct dependency `{banned}`"
        );
    }

    let retired_asset = repo_path("packages/agent/assets/capability-search");
    assert!(
        !retired_asset.exists(),
        "retired capability-search asset bundle must stay deleted"
    );
}

#[test]
fn dependency_restoration_review_is_source_backed_by_phase_two_policy() {
    let expected_removed_dependencies: BTreeSet<String> = [
        "apns",
        "bytemuck",
        "image",
        "resvg",
        "chrono-tz",
        "ed25519-dalek",
        "hmac",
        "enigo",
        "eventsource-stream",
        "fastembed",
        "sqlite-vec",
        "globset",
        "html2text",
        "scraper",
        "portable-pty",
        "rquickjs",
        "rquickjs-serde",
        "unicode-normalization",
        "urlencoding",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    let removed_dependencies = removed_dependency_names_from_feature_index();
    assert_eq!(
        removed_dependencies, expected_removed_dependencies,
        "feature-index section 24 is the source-backed removed-dependency policy; update this guard and Phase 2 evidence together when that catalog intentionally changes"
    );

    let feature_index = read_repo_file(FEATURE_INDEX_PATH);
    assert!(
        feature_index.contains("Do not add dependencies speculatively")
            && feature_index.contains("Each dependency should enter with the")
            && feature_index.contains("module that owns it"),
        "feature-index dependency policy must retain owner-first restoration guidance"
    );

    let inventory_row = phase_two_inventory_row("P2AER-INV-023");
    assert_eq!(
        inventory_row.len(),
        18,
        "Phase 2 dependency inventory row schema changed: {inventory_row:?}"
    );
    assert_eq!(inventory_row[1], "dependency restoration review");
    assert_eq!(inventory_row[4], "deferred");
    assert_eq!(inventory_row[10], "module_contract");
    assert_eq!(inventory_row[11], "Slice 22A");
    assert_eq!(inventory_row[14], "pending_review");
    for required in [
        "source-backed dependency policy guard",
        "Cargo.toml/Cargo.lock",
        "without an owning module",
        "BPRC-FEATURE-24",
    ] {
        assert!(
            inventory_row.join("\t").contains(required),
            "P2AER-INV-023 must record Slice 22A dependency policy evidence: {required}"
        );
    }

    let scorecard = read_repo_file(PHASE_TWO_SCORECARD_PATH);
    let evidence = read_repo_file(PHASE_TWO_EVIDENCE_PATH);
    for (path, contents) in [
        (PHASE_TWO_SCORECARD_PATH, scorecard),
        (PHASE_TWO_EVIDENCE_PATH, evidence),
    ] {
        let lower_contents = contents.to_ascii_lowercase();
        for required in [
            "Slice 22A",
            "Dependency Restoration Review Foundation",
            "pending_review",
            "P2AER-INV-023",
            "BPRC-FEATURE-24",
            "no dependencies are restored",
        ] {
            assert!(
                lower_contents.contains(&required.to_ascii_lowercase()),
                "{path} must record Slice 22A implementation-candidate dependency policy evidence: {required}"
            );
        }
    }
}
