//! Static gates for the off-plan SAA authorship teardown cleanup.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv";
const INVARIANT_TARGET: &str = "off_plan_saa_authorship_teardown_cleanup_invariants";
const RETIRED_SAA_TARGET: &str = "self_adapting_agent_authorship_invariants";

const FORBIDDEN_EXECUTE_RESOURCE_OPS: &[&str] = &[
    "resource_create",
    "resource_update",
    "resource_link",
    "resource_inspect",
    "resource_list",
];

const RETAINED_EXECUTE_OPS: &[&str] = &[
    "observe",
    "state_get",
    "state_set",
    "state_list",
    "file_read",
    "file_write",
    "process_run",
    "trace_list",
    "trace_get",
    "log_recent",
    "replay_manifest",
];

const POST_PPACD_STALE_BRANCHES: &[&str] = &[
    "codex/provider-model-boundary-discipline",
    "codex/performance-resource-governance-recovery",
    "codex/configuration-profile-environment-discipline-recovery",
    "codex/release-install-upgrade-rollback-discipline",
    "codex/ios-thin-client-generic-runtime-shell",
    "codex/developer-experience-repo-hygiene-automation",
    "codex/documentation-evidence-scorecard-integrity",
    "codex/self-sufficient-agent-runtime-readiness",
];

const POST_PPACD_RESIDUE_TERMS: &[&str] = &[
    "self-adapting",
    "Self-Adapting",
    "SAA",
    "generated worker",
    "generated-worker",
    "worker schedule",
    "worker activation",
    "self_adapting_agent_authorship",
    "self-adapting-agent-authorship",
];

const CURRENT_ARCHITECTURE_COMPLETION_CLAIMS: &[&str] = &[
    "Complete SAA authorship scorecard",
    "completed SAA scorecard",
    "completed Self-Adapting Agent Authorship",
    "approved SAA",
    "SAA as completed current architecture",
    "SAA current architecture",
    "current SAA architecture",
    "self-adapting-agent-authorship-scorecard.md",
    "self_adapting_agent_authorship_invariants",
    "generated worker execution is implemented",
    "generated-worker systems are implemented",
    "generated workers are complete",
    "worker schedule dispatch is implemented",
    "worker schedule scanning is complete",
    "worker activation is implemented",
    "worker activation is complete",
];

#[test]
fn opsaa_scorecard_rows_total_100_and_close_cleanly() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("# Off-Plan SAA Authorship Teardown Cleanup Scorecard"));
    assert!(scorecard.contains("Status: **complete**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    assert!(scorecard.contains("Total weight: **100**"));
    assert!(scorecard.contains(INVARIANT_TARGET));

    let rows = parse_scorecard_rows(&scorecard);
    assert_eq!(rows.len(), 10, "OPSAA scorecard must contain OPSAA-0..9");
    let expected = BTreeMap::from([
        ("OPSAA-0", ("Harness, Baseline, and Scope Control", 5_u32)),
        ("OPSAA-1", ("SAA Surface Inventory and Classification", 12)),
        (
            "OPSAA-2",
            ("Provider-Facing Execute Contract Re-narrowed", 12),
        ),
        (
            "OPSAA-3",
            ("SAA Resource Operations Removed or Proven Generic", 12),
        ),
        (
            "OPSAA-4",
            (
                "Agent Memory/Rule Runtime Substrate Removed or Reclassified Future-Only",
                10,
            ),
        ),
        ("OPSAA-5", ("Static Gates, README, and CI Cleaned", 10)),
        (
            "OPSAA-6",
            ("Predecessor Inventories and Counts Reconciled", 10),
        ),
        ("OPSAA-7", ("Negative Guards Against SAA Resurrection", 12)),
        (
            "OPSAA-8",
            ("Regression Coverage for Retained Primitive Behavior", 10),
        ),
        (
            "OPSAA-9",
            ("Evidence, Broad Verification, and Clean Commit", 7),
        ),
    ]);
    let mut total = 0;
    for row in &rows {
        let (expected_title, expected_points) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected OPSAA row {}", row.id));
        assert_eq!(&row.title, expected_title);
        assert_eq!(row.points, *expected_points);
        assert_eq!(row.status, "passed_after_fix", "{} must be closed", row.id);
        total += row.points;
    }
    assert_eq!(total, 100, "OPSAA scorecard row weights must sum to 100");
}

#[test]
fn opsaa_evidence_manifest_records_closeout_without_placeholders() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(evidence.contains("# Off-Plan SAA Authorship Teardown Cleanup Evidence Manifest"));
    assert!(evidence.contains("Status: **complete**"));
    assert!(evidence.contains("Current score: **100/100**"));
    for row in 0..=9 {
        assert!(
            evidence.contains(&format!("| OPSAA-{row} | passed_after_fix |")),
            "evidence missing closed row OPSAA-{row}"
        );
    }
    for forbidden in ["TODO", "TBD", "placeholder", "pending", "not run"] {
        assert!(
            !evidence.contains(forbidden),
            "closed OPSAA evidence must not contain placeholder marker `{forbidden}`"
        );
    }

    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml domains::capability --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml engine::tests::durability --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "OPSAA evidence manifest missing command: {command}"
        );
    }
}

#[test]
fn post_ppacd_reconciliation_evidence_records_lineage_quarantine_and_residue_audit() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(evidence.contains("## Post-PPACD Current-Lineage Reconciliation"));
    for required in [
        "codex/opsaa-post-ppacd-reconciliation",
        "codex/public-protocol-api-contract-discipline-current",
        "30dbf4b6bfd45edbee00ed7e55be2fb1ed964b19",
        "fccdbbd54161e82bc4c837d68b7c4d0ca62be0cf",
        "05d0a5872d6426afa1bda076706a362835410748",
        "e781a6aef263327d82f666611cb975a71e67e2ee",
        "Stale branch quarantine",
        "not current-lineage completion evidence",
        "must not be merged, cherry-picked, or copied wholesale",
        "Active residue audit",
        "retained historical cleanup/evidence",
        "retained generic primitive wording",
        "retained future/readiness wording",
        "No removable stale current-architecture claim was found",
        "no runtime removal was required",
        "git worktree list",
        "git log --graph --oneline --decorate --boundary --all --ancestry-path e781a6aef..30dbf4b6b",
        "git branch --list",
        "git grep -n -I -E",
    ] {
        assert!(
            evidence.contains(required),
            "post-PPACD reconciliation evidence missing `{required}`"
        );
    }

    for branch in POST_PPACD_STALE_BRANCHES {
        assert!(
            evidence.contains(branch),
            "post-PPACD evidence missing stale branch quarantine entry for {branch}"
        );
    }
    for term in POST_PPACD_RESIDUE_TERMS {
        assert!(
            evidence.contains(term),
            "post-PPACD residue audit missing searched term {term}"
        );
    }
}

#[test]
fn opsaa_inventory_classifies_deleted_reverted_and_retained_surfaces() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: `complete`"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));
    for classification in [
        "`delete`",
        "`revert_to_pre_saa`",
        "`retain_generic_preexisting`",
        "`retain_with_rewording`",
    ] {
        assert!(
            inventory.contains(classification),
            "inventory missing classification {classification}"
        );
    }

    let rows = parse_inventory_rows();
    assert!(rows.len() >= 40, "OPSAA inventory row count regressed");
    let classifications: BTreeSet<_> = rows.iter().map(|row| row.classification.as_str()).collect();
    for expected in [
        "delete",
        "revert_to_pre_saa",
        "retain_generic_preexisting",
        "retain_with_rewording",
    ] {
        assert!(
            classifications.contains(expected),
            "OPSAA inventory missing classification rows for {expected}"
        );
    }

    let by_path: BTreeMap<_, _> = rows.iter().map(|row| (&row.path, row)).collect();
    for (path, classification) in [
        (
            "packages/agent/src/domains/capability/operations/resource.rs",
            "delete",
        ),
        (
            "packages/agent/src/domains/capability/operations/mod.rs",
            "revert_to_pre_saa",
        ),
        (
            "packages/agent/src/domains/capability/contract.rs",
            "revert_to_pre_saa",
        ),
        (
            "packages/agent/src/engine/durability/resources/definitions.rs",
            "revert_to_pre_saa",
        ),
        (
            "packages/agent/src/engine/primitives/resource/mod.rs",
            "retain_generic_preexisting",
        ),
        ("README.md", "retain_with_rewording"),
    ] {
        let row = by_path
            .get(&path.to_owned())
            .unwrap_or_else(|| panic!("OPSAA inventory missing path {path}"));
        assert_eq!(row.classification, classification);
    }
}

#[test]
fn active_saa_docs_tests_and_static_targets_are_absent() {
    let tracked = git_ls_files();
    for path in &tracked {
        assert!(
            !path.contains("self-adapting-agent-authorship"),
            "active tracked SAA doc remains: {path}"
        );
        assert!(
            !path.contains("self_adapting_agent_authorship"),
            "active tracked SAA test remains: {path}"
        );
    }

    for path in [
        "scripts/tron.d/quality.sh",
        ".github/workflows/ci.yml",
        "README.md",
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains(INVARIANT_TARGET),
            "{path} must list the OPSAA invariant target"
        );
        assert!(
            !source.contains(RETIRED_SAA_TARGET),
            "{path} must not list retired SAA invariant target"
        );
    }
}

#[test]
fn post_ppacd_active_residue_hits_stay_in_classified_buckets() {
    for path in git_ls_files()
        .into_iter()
        .filter(|path| is_post_ppacd_audited_text_surface(path))
    {
        let Some(source) = read_repo_file_if_utf8(&path) else {
            continue;
        };
        let matched_terms = POST_PPACD_RESIDUE_TERMS
            .iter()
            .filter(|term| source.contains(**term))
            .copied()
            .collect::<Vec<_>>();
        if matched_terms.is_empty() {
            continue;
        }

        let classification = post_ppacd_residue_classification(&path).unwrap_or_else(|| {
            panic!("{path} has unclassified OPSAA/SAA residue: {matched_terms:?}")
        });
        match classification {
            ResidueClass::HistoricalCleanupEvidence => assert!(
                source.contains("OPSAA")
                    || source.contains("off-plan")
                    || source.contains("teardown cleanup")
                    || source.contains("SAA")
                    || source.contains("not SAA resurrection"),
                "{path} is classified as historical cleanup/evidence but lacks cleanup context"
            ),
            ResidueClass::FutureReadinessWording => assert!(
                source.contains("successor")
                    || source.contains("readiness")
                    || source.contains("does not add")
                    || source.contains("not implemented here")
                    || source.contains("After PET-11 passes"),
                "{path} is classified as future/readiness wording but lacks future-scope context"
            ),
        }
    }
}

#[test]
fn post_ppacd_active_surfaces_do_not_reclaim_saa_or_generated_worker_completion() {
    for path in git_ls_files()
        .into_iter()
        .filter(|path| is_post_ppacd_audited_text_surface(path))
    {
        if matches!(
            post_ppacd_residue_classification(&path),
            Some(ResidueClass::HistoricalCleanupEvidence)
        ) {
            continue;
        }
        let Some(source) = read_repo_file_if_utf8(&path) else {
            continue;
        };
        for forbidden in CURRENT_ARCHITECTURE_COMPLETION_CLAIMS {
            assert!(
                !source.contains(forbidden),
                "{path} reclaims stale current-architecture SAA/generated-worker completion through `{forbidden}`"
            );
        }
    }
}

#[test]
fn provider_visible_execute_surface_is_renarrowed() {
    let contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    let openai = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
    );
    let operations = read_repo_file("packages/agent/src/domains/capability/operations/mod.rs");

    for retained in RETAINED_EXECUTE_OPS {
        assert!(
            contract.contains(retained),
            "execute schema missing retained operation {retained}"
        );
        assert!(
            openai.contains(retained),
            "OpenAI clarification missing retained operation {retained}"
        );
    }

    for forbidden in FORBIDDEN_EXECUTE_RESOURCE_OPS {
        assert!(
            !contract.contains(forbidden),
            "provider execute schema still exposes {forbidden}"
        );
        assert!(
            !openai.contains(forbidden),
            "OpenAI clarification still exposes {forbidden}"
        );
        assert!(
            !operations.contains(&format!("\"{forbidden}\"")),
            "execute dispatcher still branches on {forbidden}"
        );
    }

    for forbidden_field in [
        "resourcePayload",
        "expectedCurrentVersionId",
        "sourceResourceId",
        "targetResourceId",
    ] {
        assert!(
            !contract.contains(forbidden_field),
            "provider schema still exposes SAA resource field {forbidden_field}"
        );
    }
    assert!(!operations.contains("mod resource;"));
}

#[test]
fn memory_rule_runtime_substrate_is_removed_from_active_sources() {
    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    let workers = read_repo_file("packages/agent/src/engine/primitives/workers.rs");
    let grants = read_repo_file(
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs",
    );
    let contracts =
        read_repo_file("packages/agent/src/engine/tests/durability/resource_contracts.rs");

    for forbidden in [
        "agent_memory",
        "agent_rule",
        "tron.resource.agent_memory.v1",
        "tron.resource.agent_rule.v1",
    ] {
        assert!(
            !definitions.contains(forbidden),
            "built-in resource definitions still contain {forbidden}"
        );
        assert!(
            !workers.contains(forbidden),
            "resource worker namespace claims still contain {forbidden}"
        );
        assert!(
            !grants.contains(forbidden),
            "runtime grant still contains {forbidden}"
        );
        assert!(
            !contracts.contains(forbidden),
            "durability contract tests still require {forbidden}"
        );
    }
    assert!(!grants.contains("self_adapting_resource_kinds"));
    assert!(!grants.contains("\"resource::create\""));
    assert!(!grants.contains("\"resource.read\""));
    assert!(!grants.contains("\"*\""));
}

#[test]
fn active_readme_and_predecessor_inventories_do_not_claim_saa_complete_current_architecture() {
    for path in [
        "README.md",
        "packages/agent/docs/hierarchical-rearchitecture-inventory.md",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/primitive-code-cleanup-inventory.md",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.md",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
    ] {
        let source = read_repo_file(path);
        for forbidden in [
            "self-adapting-agent-authorship",
            "self_adapting_agent_authorship",
            "SAA-10",
            "completed SAA",
            "completed Self-Adapting Agent Authorship",
            "approved SAA",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} still claims or links active SAA current architecture through `{forbidden}`"
            );
        }
    }
}

#[test]
fn generic_preexisting_resource_substrate_still_has_contract_coverage() {
    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    let contracts =
        read_repo_file("packages/agent/src/engine/tests/durability/resource_contracts.rs");
    for kind in [
        "artifact",
        "goal",
        "decision",
        "claim",
        "evidence",
        "materialized_file",
        "patch_proposal",
        "execution_output",
        "agent_result",
    ] {
        assert!(
            definitions.contains(&format!("\"{kind}\"")),
            "retained generic resource definition missing {kind}"
        );
        assert!(
            contracts.contains(&format!("\"{kind}\"")),
            "durability resource contract test missing retained kind {kind}"
        );
    }
    assert!(
        definitions.contains("UI_SURFACE_KIND"),
        "retained generic ui_surface definition must remain registered through UI_SURFACE_KIND"
    );
    assert!(
        contracts.contains("\"ui_surface\""),
        "durability resource contract test missing retained kind ui_surface"
    );
    let engine_resource = repo_path("packages/agent/src/engine/primitives/resource/mod.rs");
    assert!(
        engine_resource.exists(),
        "generic engine resource primitive must remain"
    );
}

fn parse_scorecard_rows(scorecard: &str) -> Vec<ScorecardRow> {
    scorecard
        .lines()
        .filter_map(|line| {
            let columns = line.split('|').map(str::trim).collect::<Vec<_>>();
            if !columns
                .get(1)
                .is_some_and(|cell| cell.starts_with("OPSAA-"))
            {
                return None;
            }
            Some(ScorecardRow {
                id: columns[1].to_owned(),
                title: columns[2].to_owned(),
                points: columns[3]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid OPSAA points in {line}: {error}")),
                status: columns[4].to_owned(),
            })
        })
        .collect()
}

fn parse_inventory_rows() -> Vec<InventoryRow> {
    let source = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = source.lines();
    let header = lines.next().expect("inventory header");
    assert_eq!(
        header,
        "row_id\tpath\tsurface\tclassification\tsource_proof\taction\tproof_notes"
    );
    lines
        .map(|line| {
            let columns = line.split('\t').collect::<Vec<_>>();
            assert_eq!(columns.len(), 7, "invalid OPSAA inventory row: {line}");
            InventoryRow {
                path: columns[1].to_owned(),
                classification: columns[3].to_owned(),
            }
        })
        .collect()
}

fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files");
    assert!(
        output.status.success(),
        "git ls-files failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("utf8 git ls-files")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn is_post_ppacd_audited_text_surface(path: &str) -> bool {
    path == "README.md"
        || path == ".github/workflows/ci.yml"
        || path.starts_with("scripts/")
        || path.ends_with(".rs")
        || path.ends_with(".swift")
        || (path.starts_with("packages/agent/docs/")
            && (path.ends_with(".md") || path.ends_with(".tsv")))
}

fn post_ppacd_residue_classification(path: &str) -> Option<ResidueClass> {
    match path {
        "README.md"
        | "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv"
        | "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv"
        | "packages/agent/docs/hierarchical-rearchitecture-inventory.md"
        | "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv"
        | "packages/agent/docs/release-install-upgrade-rollback-discipline-scorecard.md"
        | "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv"
        | "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv"
        | "packages/agent/tests/hierarchical_rearchitecture/scorecard_inventory.rs" => {
            Some(ResidueClass::HistoricalCleanupEvidence)
        }
        "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.md"
        | "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv"
        | "packages/agent/docs/provider-model-boundary-discipline-evidence-manifest.md"
        | "packages/agent/docs/provider-model-boundary-discipline-inventory.md"
        | "packages/agent/docs/provider-model-boundary-discipline-scorecard.md"
        | "packages/agent/tests/provider_model_boundary_discipline_invariants.rs"
        | "packages/agent/docs/public-protocol-api-contract-discipline-inventory.md"
        | "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv" => {
            Some(ResidueClass::HistoricalCleanupEvidence)
        }
        "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-scorecard.md"
        | "packages/agent/docs/ios-thin-client-generic-runtime-shell-evidence-manifest.md"
        | "packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.md"
        | "packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md"
        | "packages/agent/docs/primitive-code-cleanup-scorecard.md"
        | "packages/agent/docs/public-protocol-api-contract-discipline-scorecard.md"
        | "packages/agent/tests/primitive_engine_teardown/scorecard_inventory.rs" => {
            Some(ResidueClass::FutureReadinessWording)
        }
        _ if path.starts_with("packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-") => {
            Some(ResidueClass::HistoricalCleanupEvidence)
        }
        _ if path
            == "packages/agent/tests/off_plan_saa_authorship_teardown_cleanup_invariants.rs" =>
        {
            Some(ResidueClass::HistoricalCleanupEvidence)
        }
        _ if path.starts_with("packages/agent/docs/primitive-engine-teardown-") => {
            Some(ResidueClass::FutureReadinessWording)
        }
        _ if path.contains("self-sufficient-agent-runtime-readiness")
            || path
                == "packages/agent/tests/self_sufficient_agent_runtime_readiness_invariants.rs" =>
        {
            Some(ResidueClass::FutureReadinessWording)
        }
        _ if path.contains("ios-self-adapting-agent-cockpit-baseline")
            || path
                == "packages/agent/tests/ios_self_adapting_agent_cockpit_baseline_invariants.rs" =>
        {
            Some(ResidueClass::FutureReadinessWording)
        }
        _ => None,
    }
}

fn read_repo_file(path: &str) -> String {
    fs::read_to_string(repo_path(path)).unwrap_or_else(|error| panic!("read {path}: {error}"))
}

fn read_repo_file_if_utf8(path: &str) -> Option<String> {
    let bytes = fs::read(repo_path(path)).unwrap_or_else(|error| panic!("read {path}: {error}"));
    String::from_utf8(bytes).ok()
}

fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

fn repo_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("repo root")
}

struct ScorecardRow {
    id: String,
    title: String,
    points: u32,
    status: String,
}

struct InventoryRow {
    path: String,
    classification: String,
}

enum ResidueClass {
    HistoricalCleanupEvidence,
    FutureReadinessWording,
}
