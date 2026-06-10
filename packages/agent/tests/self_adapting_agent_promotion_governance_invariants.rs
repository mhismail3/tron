//! Static gates for the Self-Adapting Agent Promotion Governance scorecard.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-promotion-governance-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-promotion-governance-evidence-manifest.md";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_promotion_governance_invariants.rs";

#[derive(Debug, Clone, PartialEq, Eq)]
struct ScorecardRow {
    row: String,
    points: u32,
    status: String,
}

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
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SAPG-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            assert!(
                columns.len() >= 5,
                "scorecard row must have at least 5 columns: {line}"
            );
            ScorecardRow {
                row: columns[1].to_owned(),
                points: columns[3]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid SAPG score in {line}: {error}")),
                status: columns[4].to_owned(),
            }
        })
        .collect()
}

#[test]
fn sapg_harness_docs_and_ci_are_complete() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let readme = read_repo_file("README.md");
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let github = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Self-Adapting Agent Promotion Governance Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "Baseline commit: `e781a6aef263327d82f666611cb975a71e67e2ee`",
        "| SAPG-0 | Harness and Baseline | 7 | passed_after_fix |",
        "| SAPG-11 | Closeout | 4 | passed_after_fix |",
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            scorecard.contains(required),
            "SAPG scorecard missing required text: {required}"
        );
    }
    for required in [
        "# Self-Adapting Agent Promotion Governance Evidence Manifest",
        "Status: **complete**",
        "## Verification Log",
        "| SAPG-0 | passed_after_fix |",
        "| SAPG-11 | passed_after_fix |",
    ] {
        assert!(
            evidence.contains(required),
            "SAPG evidence manifest missing required text: {required}"
        );
    }
    for required in [SCORECARD_PATH, EVIDENCE_PATH, INVARIANT_TEST_PATH] {
        assert!(
            readme.contains(required),
            "README living-doc map must link {required}"
        );
    }
    for source in [quality, github] {
        assert!(
            source.contains("self_adapting_agent_promotion_governance_invariants"),
            "SAPG invariant target must be in local and GitHub closeout target lists"
        );
    }
}

#[test]
fn sapg_scorecard_weights_sum_to_100_and_every_row_has_evidence() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAPG scorecard must contain SAPG-0..11");
    let total: u32 = rows.iter().map(|row| row.points).sum();
    assert_eq!(total, 100, "SAPG scorecard row weights must sum to 100");
    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.points)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "SAPG current score must equal closed row weights"
    );
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row in rows {
        let required = format!("| {} | passed_after_fix |", row.row);
        assert!(
            evidence.contains(&required),
            "SAPG evidence manifest missing row for closed checkpoint: {required}"
        );
    }
}

#[test]
fn sapg_promote_contract_requires_governance_fields_on_every_public_path() {
    let meta = read_repo_file("packages/agent/src/engine/invocation/host/meta.rs");
    let contracts = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    let transport = read_repo_file("packages/agent/src/transport/engine/mod.rs");
    let wire = read_repo_file("packages/agent/src/transport/engine/socket/wire.rs");
    let socket = read_repo_file("packages/agent/src/transport/engine/socket/mod.rs");

    for source in [&meta, &contracts, &socket] {
        for required in [
            "decisionResourceId",
            "evidenceResourceIds",
            "candidateResourceIds",
            "promotionReason",
            "idempotencyKey",
        ] {
            assert!(
                source.contains(required),
                "promote public/internal contract missing {required}"
            );
        }
    }
    assert!(
        meta.contains("\"minItems\": 1") && contracts.contains("\"minItems\":1"),
        "promote schemas must require non-empty evidence/candidate arrays"
    );
    for required in [
        "decision_resource_id",
        "evidence_resource_ids",
        "candidate_resource_ids",
        "promotion_reason",
        "idempotency_key",
    ] {
        assert!(
            wire.contains(required),
            "promote socket DTO missing serde-renamed field {required}"
        );
    }
    assert!(
        !transport.contains("object.remove(\"idempotencyKey\")"),
        "public promote must pass idempotencyKey through for schema/governance validation"
    );
    assert!(
        contracts.contains("\"required\":[\"functionId\",\"targetVisibility\",\"idempotencyKey\",\"decisionResourceId\",\"evidenceResourceIds\",\"candidateResourceIds\",\"promotionReason\"]")
            || contracts.contains("\"required\": [\"functionId\", \"targetVisibility\", \"idempotencyKey\", \"decisionResourceId\", \"evidenceResourceIds\", \"candidateResourceIds\", \"promotionReason\"]"),
        "public promote request schema must require all governance fields"
    );
}

#[test]
fn sapg_engine_promote_validates_before_catalog_visibility_mutation() {
    let promote = read_repo_file("packages/agent/src/engine/invocation/host/meta_invocation.rs");
    let gate = read_repo_file("packages/agent/src/engine/invocation/host/promotion_governance.rs");
    let registry = read_repo_file("packages/agent/src/engine/catalog/registry/registration.rs");

    let validate_position = promote
        .find("self.validate_promotion_governance")
        .expect("engine::promote must call governance validation");
    let mutation_position = promote
        .find("self.catalog.promote_function_visibility")
        .expect("engine::promote must call catalog visibility mutation");
    assert!(
        validate_position < mutation_position,
        "governance validation must run before catalog visibility mutation"
    );

    for required in [
        "ensure_decision_approves",
        "ensure_evidence_verified",
        "ensure_candidate_kind",
        "ensure_candidates_are_chained",
        "ensure_resource_scope_compatible",
        "ensure_target_authority",
        "engine.promote.workspace",
        "engine.promote.system",
        "admin authority",
    ] {
        assert!(
            gate.contains(required),
            "promotion governance gate missing enforcement marker: {required}"
        );
    }
    assert!(
        registry.contains("\"promotionGovernance\""),
        "catalog promotion must stamp redacted governance refs onto the function definition"
    );
}

#[test]
fn sapg_candidates_are_resource_backed_and_generated_workers_remain_non_live() {
    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    let gate = read_repo_file("packages/agent/src/engine/invocation/host/promotion_governance.rs");
    let grant = read_repo_file(
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs",
    );
    let transport_contract = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    let external_worker_validation =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/validation.rs");

    for required in [
        ("\"artifact\"", "\"artifact\""),
        ("\"capability_definition\"", "\"capability_definition\""),
        ("\"materialized_file\"", "\"materialized_file\""),
        ("\"patch_proposal\"", "\"patch_proposal\""),
        ("UI_SURFACE_KIND", "\"ui_surface\""),
    ] {
        assert!(
            definitions.contains(required.0) && gate.contains(required.1),
            "candidate kind must be both resource-defined and promotion-eligible: {:?}",
            required
        );
    }
    for forbidden in [
        "\"engine::promote\".to_owned()",
        "\"worker::register\".to_owned()",
        "\"trigger::create\".to_owned()",
        "\"engine.promote\".to_owned()",
        "\"worker.write\".to_owned()",
    ] {
        assert!(
            !grant.contains(forbidden),
            "agent runtime grant must not include live promotion/worker authority: {forbidden}"
        );
    }
    assert!(
        transport_contract.contains("engine::promote")
            && transport_contract.contains("engine.promote.workspace"),
        "promotion remains an explicit public engine boundary"
    );
    assert!(
        external_worker_validation.contains("workerToken.resourceSelectors must be scoped"),
        "external workers must still require scoped tokens before any live registration"
    );
    assert!(
        !repo_path("packages/agent/skills").exists(),
        "SAPG must not reintroduce repo-managed first-party skills"
    );
}

#[test]
fn sapg_static_source_inventory_covers_changed_roots() {
    let tracked: BTreeSet<_> = git_ls_files().into_iter().collect();
    for required in [
        "packages/agent/src/engine/invocation/host/promotion_governance.rs",
        "packages/agent/src/engine/invocation/host/meta_invocation.rs",
        "packages/agent/src/engine/catalog/registry/registration.rs",
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/agent/src/transport/engine/socket/wire.rs",
        "packages/agent/docs/self-adapting-agent-promotion-governance-scorecard.md",
        "packages/agent/docs/self-adapting-agent-promotion-governance-evidence-manifest.md",
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            tracked.contains(required) || repo_path(required).exists(),
            "SAPG changed root must be tracked or staged: {required}"
        );
    }
}
