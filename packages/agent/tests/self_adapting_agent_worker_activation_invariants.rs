//! Static gates for the Self-Adapting Agent Worker Activation scorecard.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-activation-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-activation-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-activation-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-activation-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_worker_activation_invariants.rs";
const INVENTORY_HEADER: &str =
    "id\tpath\tlanguage\tsurface\tcurrent_role\tsaawa_rows\tproof\tresidual_risk";

#[derive(Debug, Clone, PartialEq, Eq)]
struct ScorecardRow {
    row: String,
    points: u32,
    status: String,
}

#[derive(Debug, Clone)]
struct InventoryRow {
    id: String,
    path: String,
    language: String,
    surface: String,
    current_role: String,
    saawa_rows: String,
    proof: String,
    residual_risk: String,
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
        .filter(|line| line.starts_with("| SAAWA-"))
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
                    .unwrap_or_else(|error| panic!("invalid SAAWA score in {line}: {error}")),
                status: columns[4].to_owned(),
            }
        })
        .collect()
}

fn parse_inventory() -> Vec<InventoryRow> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    let header = lines.next().expect("inventory TSV must have a header");
    assert_eq!(
        header, INVENTORY_HEADER,
        "SAAWA inventory TSV header changed"
    );

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                8,
                "inventory row {} must have 8 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                id: columns[0].to_owned(),
                path: columns[1].to_owned(),
                language: columns[2].to_owned(),
                surface: columns[3].to_owned(),
                current_role: columns[4].to_owned(),
                saawa_rows: columns[5].to_owned(),
                proof: columns[6].to_owned(),
                residual_risk: columns[7].to_owned(),
            }
        })
        .collect()
}

#[test]
fn saawa_harness_docs_inventory_and_ci_are_linked() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Self-Adapting Agent Worker Activation Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "Baseline commit: `4b530e014 Harden promotion governance`",
        "| SAAWA-0 | Harness and Baseline | 6 | passed_after_fix |",
        "| SAAWA-10 | Closeout | 6 | passed_after_fix |",
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            scorecard.contains(required),
            "SAAWA scorecard missing required text: {required}"
        );
    }
    for required in [
        "# Self-Adapting Agent Worker Activation Evidence Manifest",
        "Status: **complete**",
        "## Baseline Evidence",
        "## Verification Log",
        "| SAAWA-0 | passed_after_fix |",
        "| SAAWA-10 | passed_after_fix |",
    ] {
        assert!(
            evidence.contains(required),
            "SAAWA evidence manifest missing required text: {required}"
        );
    }
    for required in [
        "# Self-Adapting Agent Worker Activation Inventory",
        "Status: SAAWA campaign `complete`;",
        "`activation_contract`",
        "`governance_chain`",
        "`resource_contract`",
        "`grant_token`",
        "`external_runtime`",
        "`lifecycle_audit`",
        "`transport_boundary`",
        "`closeout_gate`",
    ] {
        assert!(
            inventory.contains(required),
            "SAAWA inventory missing required text: {required}"
        );
    }
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            readme.contains(required),
            "README living-doc map must link {required}"
        );
    }
    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains("self_adapting_agent_worker_activation_invariants"),
            "{path} must list the SAAWA invariant target"
        );
    }
}

#[test]
fn saawa_scorecard_weights_sum_to_100_and_every_row_has_evidence() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 11, "SAAWA scorecard must contain SAAWA-0..10");
    let total: u32 = rows.iter().map(|row| row.points).sum();
    assert_eq!(total, 100, "SAAWA scorecard row weights must sum to 100");
    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.points)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "SAAWA current score must equal closed row weights"
    );
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row in rows {
        let required = format!("| {} | passed_after_fix |", row.row);
        assert!(
            evidence.contains(&required),
            "SAAWA evidence manifest missing row for closed checkpoint: {required}"
        );
    }
}

#[test]
fn saawa_inventory_rows_are_structured_and_cover_required_surfaces() {
    let rows = parse_inventory();
    assert!(
        rows.len() >= 40,
        "SAAWA inventory must cover code, tests, docs, and boundaries"
    );
    let tracked: BTreeSet<_> = git_ls_files().into_iter().collect();
    let mut ids = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    let mut paths = BTreeSet::new();
    for row in &rows {
        assert!(
            ids.insert(row.id.clone()),
            "duplicate SAAWA row id: {}",
            row.id
        );
        let intentionally_absent = row.language == "missing";
        assert!(
            intentionally_absent || tracked.contains(&row.path) || repo_path(&row.path).exists(),
            "SAAWA row path must be tracked, staged, or intentionally absent: {}",
            row.path
        );
        for (field, value) in [
            ("language", &row.language),
            ("surface", &row.surface),
            ("current_role", &row.current_role),
            ("saawa_rows", &row.saawa_rows),
            ("proof", &row.proof),
            ("residual_risk", &row.residual_risk),
        ] {
            assert!(
                !value.trim().is_empty() && !value.contains("unclassified"),
                "{} has invalid {} field: `{}`",
                row.id,
                field,
                value
            );
        }
        assert!(
            row.saawa_rows.contains("SAAWA-"),
            "{} must reference SAAWA rows",
            row.id
        );
        surfaces.insert(row.surface.as_str());
        paths.insert(row.path.as_str());
    }
    for required in [
        "activation_contract",
        "governance_chain",
        "resource_contract",
        "grant_token",
        "external_runtime",
        "lifecycle_audit",
        "transport_boundary",
        "closeout_gate",
    ] {
        assert!(
            surfaces.contains(required),
            "inventory missing surface {required}"
        );
    }
    for required in [
        "packages/agent/src/engine/primitives/worker.rs",
        "packages/agent/src/engine/primitives/worker_activation.rs",
        "packages/agent/src/engine/primitives/worker_activation_governance.rs",
        "packages/agent/src/engine/runtime/external_workers/activation.rs",
        "packages/agent/src/engine/runtime/worker_protocol.rs",
        "packages/agent/src/engine/durability/resources/definitions.rs",
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/agent/src/domains/capability/contract.rs",
    ] {
        assert!(
            paths.contains(required),
            "inventory missing required path {required}"
        );
    }
}

#[test]
fn saawa_activation_contract_resource_and_governance_are_strict() {
    let worker = read_repo_file("packages/agent/src/engine/primitives/worker.rs");
    for required in [
        "ISSUE_ACTIVATION_FUNCTION",
        "worker::issue_activation",
        "EffectClass::IdempotentWrite",
        "worker.activate",
        "RiskLevel::High",
        "IdempotencyContract::caller_system_engine_ledger()",
        "issue_activation.visibility = VisibilityScope::Admin",
    ] {
        assert!(
            worker.contains(required),
            "worker activation contract missing marker: {required}"
        );
    }

    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    for required in [
        "\"worker_activation\"",
        "\"tron.resource.worker_activation.v1\"",
        "\"issued\"",
        "\"connected\"",
        "\"registered\"",
        "\"disconnected\"",
        "\"expired\"",
        "\"revoked\"",
        "\"failed\"",
        "\"archived\"",
        "\"tokenFingerprint\"",
        "\"governanceFingerprint\"",
        "\"expectedFunctionDefinition\"",
        "\"registrationMode\"",
        "\"networkPolicy\"",
        "\"tokenStorage\"",
        "\"workspaceId\": {\"type\": [\"string\", \"null\"]}",
    ] {
        assert!(
            definitions.contains(required),
            "worker_activation resource definition missing marker: {required}"
        );
    }

    let activation = read_repo_file("packages/agent/src/engine/primitives/worker_activation.rs");
    for required in [
        "ensure_activation_idempotency",
        "ACTIVATION_MAX_TTL_HOURS",
        "worker-runtime",
        "subject_actor_id: Some(worker_actor.clone())",
        "subject_worker_id: Some(worker_id.clone())",
        "file_roots: Vec::new()",
        "\"stream::publish\"",
        "network_policy: \"loopback\".to_owned()",
        "can_delegate: false",
        "token.activation_resource_id = Some(activation_resource_id.clone())",
        "\"redacted_fingerprint_only\"",
        "\"registrationMode\": \"volatile\"",
        "\"networkPolicy\": \"loopback\"",
    ] {
        assert!(
            activation.contains(required),
            "activation issuance missing marker: {required}"
        );
    }

    let governance =
        read_repo_file("packages/agent/src/engine/primitives/worker_activation_governance.rs");
    for required in [
        "candidate.resource.kind != \"capability_definition\"",
        "candidate.resource.lifecycle != \"reviewed\"",
        "decision.resource.lifecycle != \"final\"",
        "must be accepted",
        "ensure_evidence_verified",
        "ensure_activation_chain",
        "ensure_resource_scope_compatible",
        "EngineResourceScope::System => actor.actor_kind.is_admin_like()",
        "expected_function.visibility != request.target_visibility",
        "governance_fingerprint",
    ] {
        assert!(
            governance.contains(required),
            "activation governance missing marker: {required}"
        );
    }
}

#[test]
fn saawa_runtime_binds_hello_registration_lifecycle_and_proxy() {
    let token = read_repo_file("packages/agent/src/engine/runtime/worker_protocol.rs");
    for required in [
        "activation_resource_id: Option<String>",
        "governance_fingerprint: Option<String>",
        "#[serde(default, skip_serializing_if = \"Option::is_none\")]",
    ] {
        assert!(
            token.contains(required),
            "ScopedWorkerToken activation metadata missing marker: {required}"
        );
    }

    let activation =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/activation.rs");
    for required in [
        "validate_activation_hello",
        "validate_activation_function_registration",
        "validate_activation_trigger_registration",
        "activation token fingerprint does not match",
        "activation grant hash does not match worker token",
        "activation workers must use volatile registration",
        "activation workers cannot request system visibility",
        "activation worker namespace claims must exactly match scoped token",
        "activation workers may register only the expected function",
        "activation function metadata {key} does not match expected definition",
        "activation function trustTier does not match worker token",
        "activation function signatureStatus does not match worker token",
        "activation workers cannot register triggers",
        "mark_activation_connected",
        "mark_activation_registered",
        "mark_activation_disconnected",
    ] {
        assert!(
            activation.contains(required),
            "external worker activation binding missing marker: {required}"
        );
    }

    let lifecycle =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/lifecycle.rs");
    for required in [
        "self.validate_activation_hello(&hello).await?",
        "self.mark_activation_connected(&connection).await?",
        "self.mark_activation_disconnected(&connection, Some(disconnect.reason.as_str()))",
        "\"worker.connected\"",
        "\"worker.disconnected\"",
        "\"worker.unregistered\"",
        "WORKER_LIFECYCLE_TOPIC",
    ] {
        assert!(
            lifecycle.contains(required),
            "worker lifecycle activation wiring missing marker: {required}"
        );
    }

    let registration =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/registration.rs");
    for required in [
        "self.validate_activation_function_registration(&connection, &definition)",
        "self.mark_activation_registered(&connection).await?",
        "self.validate_activation_trigger_registration(&connection)?",
        "ExternalFunctionProxyHandler",
    ] {
        assert!(
            registration.contains(required),
            "worker registration activation wiring missing marker: {required}"
        );
    }

    let proxy = read_repo_file("packages/agent/src/engine/runtime/external_workers/proxy.rs");
    assert!(
        proxy.contains("ExternalFunctionProxyHandler") && proxy.contains("WorkerInvoke"),
        "activation functions must continue routing through existing external proxy"
    );
}

#[test]
fn saawa_agent_provider_and_public_engine_surfaces_do_not_expose_activation() {
    let grant = read_repo_file(
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs",
    );
    for forbidden in [
        "worker.activate",
        "worker.write",
        "engine::promote",
        "worker::issue_activation",
        "worker::disconnect",
        "trigger::create",
        "trigger::register",
    ] {
        assert!(
            !grant.contains(forbidden),
            "agent runtime grant must not include {forbidden}"
        );
    }

    let capability = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    assert!(
        capability.contains("assert_eq!(ids, [EXECUTE_FUNCTION_ID]);"),
        "capability contract must keep provider surface to execute"
    );
    assert!(
        !capability.contains("issue_activation") && !capability.contains("worker_activate"),
        "provider-visible execute contract must not expose worker activation"
    );
    let primitive_surface =
        read_repo_file("packages/agent/src/domains/agent/loop/primitive_surface.rs");
    for required in [
        "function.id.as_str() == EXECUTE_FUNCTION_ID",
        "model_capability_id",
        "capability.execute",
    ] {
        assert!(
            primitive_surface.contains(required),
            "provider primitive surface missing execute-only marker: {required}"
        );
    }

    let contracts = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    assert!(
        contracts.contains(
            "const PUBLIC_ENGINE_TRANSPORT_METHODS: &[&str] =\n    &[\"discover\", \"inspect\", \"watch\", \"invoke\", \"promote\"];"
        ),
        "public engine transport method set must remain discover/inspect/watch/invoke/promote"
    );
    for source_path in [
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/agent/src/transport/engine/socket/mod.rs",
        "packages/agent/src/transport/engine/socket/wire.rs",
    ] {
        let source = read_repo_file(source_path);
        for forbidden in ["activation", "issue_activation", "worker.activate"] {
            assert!(
                !source.contains(forbidden),
                "{source_path} must not expose public activation marker {forbidden}"
            );
        }
    }
}

#[test]
fn saawa_activation_code_has_no_launch_scheduler_deploy_or_skill_path() {
    let activation_sources = [
        "packages/agent/src/engine/primitives/worker_activation.rs",
        "packages/agent/src/engine/primitives/worker_activation_governance.rs",
        "packages/agent/src/engine/runtime/external_workers/activation.rs",
    ];
    for path in activation_sources {
        let source = read_repo_file(path);
        for forbidden in [
            "Command::new",
            ".spawn(",
            "tokio::spawn",
            "cron",
            "schedule",
            "scheduler",
            "autolaunch",
            "auto_launch",
            "deploy",
            "tron deploy",
            "packages/agent/skills",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not contain launch/scheduler/deploy marker {forbidden}"
            );
        }
    }

    assert!(
        !repo_path("packages/agent/skills").exists(),
        "repo-managed first-party skills must remain absent"
    );

    let server = read_repo_file("packages/agent/src/app/bootstrap/server.rs");
    assert!(
        server.contains("ensure_worker_peer_is_loopback(addr)?;")
            && server.contains("\"/engine/workers\""),
        "worker protocol route must remain loopback-only infrastructure"
    );
}
