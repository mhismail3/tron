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

fn read_repo_file(path: &str) -> String {
    fs::read_to_string(repo_path(path)).unwrap_or_else(|error| panic!("read {path}: {error}"))
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
