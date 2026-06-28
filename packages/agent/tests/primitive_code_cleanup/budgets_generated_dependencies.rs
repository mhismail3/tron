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

fn production_rust_files() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| path.starts_with("packages/agent/src/") && path.ends_with(".rs"))
        .filter(|path| {
            !path.ends_with("_tests.rs")
                && !path.ends_with("/tests.rs")
                && !path.ends_with("/static_tests.rs")
        })
        .collect()
}

const FORBIDDEN_SKILL_BOOTSTRAP_IDENTIFIER_FRAGMENTS: &[&str] = &[
    "bootstrapmanagedskill",
    "bootstrapmanagedskills",
    "bootstrapskill",
    "bootstrapskills",
    "builtinskill",
    "builtinskills",
    "copyskill",
    "copyskills",
    "firstpartyskill",
    "firstpartyskills",
    "injectskill",
    "injectskills",
    "loadskill",
    "loadskills",
    "managedskillbootstrap",
    "managedskillsbootstrap",
    "promptskillcontext",
    "promptskillscontext",
    "promptskillinjection",
    "promptskillsinjection",
    "repomanagedskillbootstrap",
    "repomanagedskillsbootstrap",
    "skillasset",
    "skillassets",
    "skillbootstrap",
    "skillbundle",
    "skillbundles",
    "skillcopy",
    "skillinject",
    "skillloader",
    "skillpromptcontext",
    "skillpromptinjection",
    "skillregistry",
    "skillsasset",
    "skillsassets",
    "skillsbootstrap",
    "skillsbundle",
    "skillsbundles",
    "skillscopy",
    "skillsinject",
    "skillsloader",
    "skillspromptcontext",
    "skillspromptinjection",
    "skillsregistry",
    "skillsync",
    "syncskill",
    "syncskills",
];

fn compact_identifier_token(token: &str) -> String {
    token
        .bytes()
        .filter_map(|byte| match byte {
            b'A'..=b'Z' => Some((byte + 32) as char),
            b'a'..=b'z' | b'0'..=b'9' => Some(byte as char),
            _ => None,
        })
        .collect()
}

fn push_identifier_compact(compacts: &mut Vec<String>, token: &str) {
    if token.bytes().any(|byte| byte.is_ascii_alphabetic()) {
        let compact = compact_identifier_token(token);
        if !compact.is_empty() {
            compacts.push(compact);
        }
    }
}

fn code_like_identifier_compacts(contents: &str) -> Vec<String> {
    let mut compacts = Vec::new();
    let mut token = String::new();
    for ch in contents.chars() {
        if ch == '_' || ch.is_ascii_alphanumeric() {
            token.push(ch);
        } else if !token.is_empty() {
            push_identifier_compact(&mut compacts, &token);
            token.clear();
        }
    }
    if !token.is_empty() {
        push_identifier_compact(&mut compacts, &token);
    }
    compacts
}

fn forbidden_skill_bootstrap_identifier_hits(path: &str, contents: &str) -> Vec<String> {
    let identifiers = code_like_identifier_compacts(contents);
    let mut hits = Vec::new();
    for forbidden in FORBIDDEN_SKILL_BOOTSTRAP_IDENTIFIER_FRAGMENTS {
        if identifiers
            .iter()
            .any(|identifier| identifier.contains(forbidden))
        {
            hits.push(format!("{path}: {forbidden}"));
        }
    }
    hits
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
        "Accepted Slice 24K records rejected-shape/static containment for dependency reappearance: removed dependencies stay absent unless a selected module owns a module_dependency_request with rationale risk tests removal path parity evidence and approved module_dependency_policy decision"
    );
    assert_eq!(phase_three_rejection_row[13], "current_baseline");
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
            "Accepted",
            "current_baseline",
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
                "{path} must record accepted Slice 24K Phase 3 dependency containment evidence: {required}"
            );
        }
    }
}

#[test]
fn repo_managed_skills_bootstrap_behavior_requires_phase_three_rejection_containment() {
    assert!(
        !repo_path("packages/agent/skills").exists(),
        "repo-managed first-party skills directory must remain absent"
    );

    for path in git_ls_files() {
        assert!(
            path != "packages/agent/skills" && !path.starts_with("packages/agent/skills/"),
            "repo-managed first-party skill assets must not be tracked: {path}"
        );
        assert!(
            !(path.starts_with("packages/agent/") && path.ends_with("/SKILL.md")),
            "package SKILL.md assets must not be tracked under packages/agent: {path}"
        );
    }

    let mut hits = Vec::new();
    for path in production_rust_files() {
        let contents = read_repo_file(&path);
        hits.extend(forbidden_skill_bootstrap_identifier_hits(&path, &contents));
    }
    assert!(
        hits.is_empty(),
        "bootstrap skill registries, skill-copy wiring, and hidden prompt-context skill injection must stay absent: {hits:#?}"
    );

    let phase_three_repo_skills_row = phase_three_inventory_row("P3MSA-INV-020");
    assert_eq!(
        phase_three_repo_skills_row.len(),
        15,
        "Phase 3 inventory row schema changed: {phase_three_repo_skills_row:?}"
    );
    assert_eq!(
        phase_three_repo_skills_row[1],
        "Slice 24L Repo-Managed Skills And Bootstrap Behavior"
    );
    assert_eq!(phase_three_repo_skills_row[3], "reject_candidate");
    assert_eq!(phase_three_repo_skills_row[5], "procedural_module");
    assert_eq!(phase_three_repo_skills_row[13], "current_baseline");
    for required in [
        "Slice 24L",
        "packages/agent/skills",
        "SKILL.md",
        "repo-managed first-party skill assets",
        "skill-copy wiring",
        "bootstrap prompt context",
        "hidden prompt-context skill injection",
        "bootstrap skill registries",
        "module_registry_procedural_manifest",
        "procedural_module",
        "metadata-only",
        "P3MSA-INV-013",
    ] {
        assert!(
            phase_three_repo_skills_row.join("\t").contains(required),
            "P3MSA-INV-020 must record Slice 24L repo-managed-skill/bootstrap containment: {required}"
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
            "Slice 24L",
            "P3MSA-INV-020",
            "Repo-Managed Skills And Bootstrap Behavior",
            "current_baseline",
            "packages/agent/skills",
            "SKILL.md",
            "repo-managed first-party skill assets",
            "skill-copy wiring",
            "bootstrap prompt context",
            "hidden prompt-context skill injection",
            "module_registry_procedural_manifest",
            "procedural_module",
            "metadata-only",
        ] {
            assert!(
                contents.contains(required),
                "{path} must record Slice 24L repo-managed-skill/bootstrap containment evidence: {required}"
            );
        }
    }
}

#[test]
fn repo_managed_skills_bootstrap_guard_rejects_realistic_identifier_variants() {
    for (contents, expected_fragment) in [
        ("struct SkillsRegistry;", "skillsregistry"),
        ("struct BootstrapSkillsRegistry;", "bootstrapskills"),
        ("struct ManagedSkillsRegistry;", "skillsregistry"),
        ("struct SkillLoader;", "skillloader"),
        ("struct SkillsLoader;", "skillsloader"),
        ("struct SkillBootstrapRegistry;", "skillbootstrap"),
        ("struct SkillsPromptContext;", "skillspromptcontext"),
        ("fn bootstrap_skills_registry() {}", "bootstrapskills"),
        ("fn managed_skill_bootstrap() {}", "managedskillbootstrap"),
        ("fn skill_prompt_context() {}", "skillpromptcontext"),
        ("fn prompt_skills_context() {}", "promptskillscontext"),
        (
            "fn repo_managed_skills_bootstrap() {}",
            "repomanagedskillsbootstrap",
        ),
    ] {
        let hits = forbidden_skill_bootstrap_identifier_hits("candidate.rs", contents);
        assert!(
            hits.iter().any(|hit| hit.ends_with(expected_fragment)),
            "expected {contents:?} to be rejected by {expected_fragment}; hits: {hits:?}"
        );
    }
}

#[test]
fn repo_managed_skills_bootstrap_guard_allows_metadata_only_proof_fields() {
    for contents in [
        r#"const MODULE_REGISTRY: &str = "module_registry_procedural_manifest";"#,
        r#"const MODULE_ID: &str = "procedural_module";"#,
        r#"json!({"sideEffectProof": {"repoManagedSkillsTouched": false}})"#,
        "no skill-copy/bootstrap registries or hidden skill prompt-context injection may return",
    ] {
        let hits = forbidden_skill_bootstrap_identifier_hits("allowed.rs", contents);
        assert!(
            hits.is_empty(),
            "metadata-only proof text must remain allowed: {hits:?}"
        );
    }
}
