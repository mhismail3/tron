use super::support::*;

use std::collections::BTreeSet;

const PHASE_TWO_INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/phase-2-agent-execution-restoration-inventory.tsv";
const PHASE_TWO_SCORECARD_PATH: &str =
    "packages/agent/docs/phase-2-agent-execution-restoration-scorecard.md";
const PHASE_TWO_EVIDENCE_PATH: &str =
    "packages/agent/docs/phase-2-agent-execution-restoration-evidence-manifest.md";
const PHASE_THREE_INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/phase-3-modular-self-adapting-engine-inventory.tsv";
const PHASE_THREE_SCORECARD_PATH: &str =
    "packages/agent/docs/phase-3-modular-self-adapting-engine-scorecard.md";
const PHASE_THREE_INVENTORY_PATH: &str =
    "packages/agent/docs/phase-3-modular-self-adapting-engine-inventory.md";
const PHASE_THREE_EVIDENCE_PATH: &str =
    "packages/agent/docs/phase-3-modular-self-adapting-engine-evidence-manifest.md";
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
    inventory_tsv_row(&inventory, row_id, "Phase 2")
}

fn phase_three_inventory_row(row_id: &str) -> Vec<String> {
    let inventory = read_repo_file(PHASE_THREE_INVENTORY_TSV_PATH);
    inventory_tsv_row(&inventory, row_id, "Phase 3")
}

fn inventory_tsv_row(inventory: &str, row_id: &str, label: &str) -> Vec<String> {
    let row = inventory
        .lines()
        .find(|line| line.starts_with(&format!("{row_id}\t")))
        .unwrap_or_else(|| panic!("missing {label} inventory row {row_id}"));
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
            "Cargo.toml must not reintroduce removed dependency `{banned}` without an approved Phase 3 module dependency request, owner rationale, policy decision, and P3MSA-INV-019 review evidence"
        );
        assert!(
            !cargo_lock.contains(&format!("name = \"{banned}\"")),
            "Cargo.lock must not retain removed dependency `{banned}` without an approved Phase 3 module dependency request, owner rationale, policy decision, and P3MSA-INV-019 review evidence"
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
fn speculative_dependency_restoration_requires_phase_three_module_policy() {
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
        "feature-index section 24 is the source-backed removed-dependency policy; update this guard plus Phase 2 and Phase 3 evidence together when that catalog intentionally changes"
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
    assert_eq!(inventory_row[11], "Accepted Slice 22A");
    assert_eq!(inventory_row[14], "current_baseline");
    for required in [
        "source-backed dependency policy guard",
        "Cargo.toml/Cargo.lock",
        "without an owning module",
        "BPRC-FEATURE-24",
    ] {
        assert!(
            inventory_row.join("\t").contains(required),
            "P2AER-INV-023 must keep the accepted Slice 22A source policy evidence that Phase 3 builds on: {required}"
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
            "accepted",
            "P2AER-INV-023",
            "BPRC-FEATURE-24",
            "no dependencies are restored",
        ] {
            assert!(
                lower_contents.contains(&required.to_ascii_lowercase()),
                "{path} must record Slice 22A accepted dependency policy evidence: {required}"
            );
        }
    }

    let phase_three_dependency_row = phase_three_inventory_row("P3MSA-INV-007");
    assert_eq!(
        phase_three_dependency_row.len(),
        15,
        "Phase 3 inventory row schema changed: {phase_three_dependency_row:?}"
    );
    assert_eq!(phase_three_dependency_row[0], "P3MSA-INV-007");
    assert_eq!(
        phase_three_dependency_row[2],
        "Modules can request dependencies with owner rationale and review instead of speculative restoration"
    );
    assert_eq!(phase_three_dependency_row[3], "module_plane");
    assert_eq!(phase_three_dependency_row[5], "module_dependencies");
    assert_eq!(phase_three_dependency_row[13], "current_baseline");
    for required in [
        "Accepted Slice 23G",
        "module_dependency_request",
        "module_dependency_decision",
        "module_dependency_policy",
        "Cargo.toml/Cargo.lock parity evidence",
        "Speculative dependency restoration",
        "without selected module",
        "package-manager execution",
        "Cargo.toml/Cargo.lock mutation",
        "Dependency request policy",
        "no package-manager execution or manifest/lockfile mutation",
    ] {
        assert!(
            phase_three_dependency_row.join("\t").contains(required),
            "P3MSA-INV-007 must record accepted module dependency request/policy evidence: {required}"
        );
    }

    let phase_three_rejection_row = phase_three_inventory_row("P3MSA-INV-019");
    assert_eq!(
        phase_three_rejection_row.len(),
        15,
        "Phase 3 inventory row schema changed: {phase_three_rejection_row:?}"
    );
    assert_eq!(
        phase_three_rejection_row[1],
        "Slice 24K Speculative Dependency Restoration"
    );
    assert_eq!(phase_three_rejection_row[3], "reject_candidate");
    assert_eq!(phase_three_rejection_row[5], "none");
    assert_eq!(
        phase_three_rejection_row[8],
        "Implementation-candidate Slice 24K records rejected-shape/static containment for dependency reappearance: removed dependencies stay absent unless a selected module owns a module_dependency_request with rationale risk tests removal path parity evidence and approved module_dependency_policy decision"
    );
    assert_eq!(phase_three_rejection_row[13], "pending_review");
    for required in [
        "P3MSA-INV-007",
        "Accepted Slice 23G",
        "approved module_dependency_request",
        "approved module_dependency_policy",
        "Portable PTY",
        "APNs",
        "package-manager execution",
        "manifest or lockfile mutation",
        "raw dependency artifacts",
        "package-manager output",
        "Dependency guard denies reappearance without approved module rationale",
    ] {
        assert!(
            phase_three_rejection_row.join("\t").contains(required),
            "P3MSA-INV-019 must record Slice 24K rejected-shape dependency containment: {required}"
        );
    }

    for (path, contents) in [
        (
            PHASE_THREE_SCORECARD_PATH,
            read_repo_file(PHASE_THREE_SCORECARD_PATH),
        ),
        (
            PHASE_THREE_INVENTORY_PATH,
            read_repo_file(PHASE_THREE_INVENTORY_PATH),
        ),
        (
            PHASE_THREE_EVIDENCE_PATH,
            read_repo_file(PHASE_THREE_EVIDENCE_PATH),
        ),
    ] {
        for required in [
            "Slice 24K",
            "P3MSA-INV-019",
            "Speculative Dependency Restoration",
            "implementation-candidate",
            "pending_review",
            "P3MSA-INV-007",
            "module_dependency_request",
            "module_dependency_policy",
            "Cargo.toml",
            "Cargo.lock",
            "no package-manager",
            "no dependencies are restored",
        ] {
            assert!(
                contents.contains(required),
                "{path} must record pending-review Slice 24K Phase 3 dependency containment evidence: {required}"
            );
        }
    }
}
