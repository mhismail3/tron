//! Static gates for the Self-Adapting Agent Worker Orchestration scorecard.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-orchestration-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-orchestration-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-orchestration-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-orchestration-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_worker_orchestration_invariants.rs";
const INVENTORY_HEADER: &str =
    "id\tpath\tlanguage\tsurface\tcurrent_role\tsaawo_rows\tproof\tresidual_risk";

#[derive(Debug)]
struct ScorecardRow {
    row: String,
    points: u32,
    status: String,
}

#[derive(Debug)]
struct InventoryRow {
    id: String,
    path: String,
    language: String,
    surface: String,
    current_role: String,
    saawo_rows: String,
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
        .filter(|line| line.starts_with("| SAAWO-"))
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
                    .unwrap_or_else(|error| panic!("invalid SAAWO score in {line}: {error}")),
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
        "SAAWO inventory TSV header changed"
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
                saawo_rows: columns[5].to_owned(),
                proof: columns[6].to_owned(),
                residual_risk: columns[7].to_owned(),
            }
        })
        .collect()
}

#[test]
fn saawo_harness_docs_inventory_and_ci_are_linked() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Self-Adapting Agent Worker Orchestration Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "Baseline commit: `125d58efd7baafb86b2a339d64a6f145b10cc1e2`",
        "| SAAWO-0 | Harness and Baseline | 5 | passed_after_fix |",
        "| SAAWO-11 | Regression and Closeout | 8 | passed_after_fix |",
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            scorecard.contains(required),
            "SAAWO scorecard missing required text: {required}"
        );
    }
    for required in [
        "# Self-Adapting Agent Worker Orchestration Evidence Manifest",
        "Status: **complete**",
        "## Baseline Evidence",
        "## Verification Log",
        "| SAAWO-0 | passed_after_fix |",
        "| SAAWO-11 | passed_after_fix |",
        "preissued_bundle",
    ] {
        assert!(
            evidence.contains(required),
            "SAAWO evidence missing required text: {required}"
        );
    }
    for required in [
        "# Self-Adapting Agent Worker Orchestration Inventory",
        "Status: SAAWO campaign `complete`;",
        "`launch_plan`",
        "`process_resource`",
        "`supervisor`",
        "`readiness_binding`",
        "`transport_boundary`",
        "`regression_gate`",
    ] {
        assert!(
            inventory.contains(required),
            "SAAWO inventory missing required text: {required}"
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
            source.contains("self_adapting_agent_worker_orchestration_invariants"),
            "{path} must list the SAAWO invariant target"
        );
    }
}

#[test]
fn saawo_scorecard_weights_sum_to_100_and_every_row_has_evidence() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAAWO scorecard must contain SAAWO-0..11");
    let total: u32 = rows.iter().map(|row| row.points).sum();
    assert_eq!(total, 100, "SAAWO scorecard row weights must sum to 100");
    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.points)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "SAAWO current score must equal closed row weights"
    );
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row in rows {
        let required = format!("| {} | passed_after_fix |", row.row);
        assert!(
            evidence.contains(&required),
            "SAAWO evidence manifest missing row for closed checkpoint: {required}"
        );
    }
}

#[test]
fn saawo_inventory_rows_are_structured_and_cover_required_surfaces() {
    let rows = parse_inventory();
    assert!(
        rows.len() >= 35,
        "SAAWO inventory must cover code, tests, docs, and boundaries"
    );
    let tracked: BTreeSet<_> = git_ls_files().into_iter().collect();
    let mut ids = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    for row in &rows {
        assert!(
            ids.insert(row.id.clone()),
            "duplicate SAAWO row id: {}",
            row.id
        );
        assert!(
            tracked.contains(&row.path) || repo_path(&row.path).exists(),
            "SAAWO row path must be tracked, staged, or present: {}",
            row.path
        );
        for (field, value) in [
            ("language", &row.language),
            ("surface", &row.surface),
            ("current_role", &row.current_role),
            ("saawo_rows", &row.saawo_rows),
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
        surfaces.insert(row.surface.clone());
    }
    for surface in [
        "closeout_gate",
        "activation_binding",
        "launch_plan",
        "process_resource",
        "supervisor",
        "readiness_binding",
        "transport_boundary",
        "regression_gate",
    ] {
        assert!(
            surfaces.contains(surface),
            "missing SAAWO surface {surface}"
        );
    }
}

#[test]
fn saawo_resource_contracts_and_worker_primitives_are_governed() {
    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    for required in [
        "\"worker_launch_plan\"",
        "\"tron.resource.worker_launch_plan.v1\"",
        "\"worker_process\"",
        "\"tron.resource.worker_process.v1\"",
        "\"requested\"",
        "\"starting\"",
        "\"hello_seen\"",
        "\"ready\"",
        "\"unhealthy\"",
        "\"stopping\"",
        "\"stopped\"",
        "\"failed\"",
        "\"killed\"",
        "\"expired\"",
        "\"revoked\"",
        "\"archived\"",
        "\"activationDeliveryMode\"",
        "\"executable\"",
        "\"argvAllowlist\"",
        "\"envAllowlist\"",
        "\"maxLogCaptureBytes\"",
    ] {
        assert!(
            definitions.contains(required),
            "resource definitions missing {required}"
        );
    }

    let worker = read_repo_file("packages/agent/src/engine/primitives/worker.rs");
    for required in [
        "LAUNCH_ACTIVATION_FUNCTION",
        "\"worker::launch_activation\"",
        "STOP_PROCESS_FUNCTION",
        "\"worker::stop_process\"",
        "VisibilityScope::Admin",
        "EffectClass::IdempotentWrite",
        "IdempotencyContract::caller_system_engine_ledger()",
        "AuthorityRequirement::scope(\"worker.launch\")",
        "RiskLevel::High",
    ] {
        assert!(
            worker.contains(required),
            "worker primitive missing {required}"
        );
    }
}

#[test]
fn saawo_supervisor_and_readiness_binding_are_direct_exec_and_redacted() {
    let orchestration = [
        "packages/agent/src/engine/runtime/worker_orchestration/mod.rs",
        "packages/agent/src/engine/runtime/worker_orchestration/contracts.rs",
        "packages/agent/src/engine/runtime/worker_orchestration/process_resource.rs",
        "packages/agent/src/engine/runtime/worker_orchestration/supervisor.rs",
    ]
    .into_iter()
    .map(read_repo_file)
    .collect::<Vec<_>>()
    .join("\n");
    for required in [
        "pub trait WorkerProcessSupervisor",
        "TokioWorkerProcessSupervisor",
        "Command::new",
        "command.args",
        "command.env_clear",
        "start_kill",
        "redact_text",
        "preissued_bundle",
        "validate_direct_path",
        "ensure_file_digest",
        "max_log_capture_bytes",
        "let remaining = max - bytes.len()",
        "join_capture(",
        "Duration::from_millis(250)",
        "WorkerProcessSupervisorRegistry",
    ] {
        assert!(
            orchestration.contains(required),
            "orchestration runtime missing {required}"
        );
    }
    for forbidden in [
        "sh -c",
        "bash -c",
        "osascript",
        "SMAppService",
        "launchd",
        "LaunchAgent",
        "tron deploy",
        "restart_loop",
        "auto_restart",
    ] {
        assert!(
            !orchestration.contains(forbidden),
            "orchestration runtime must not contain forbidden surface {forbidden}"
        );
    }

    let activation =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/activation.rs");
    for required in [
        "mark_hello_seen",
        "mark_ready",
        "mark_failed_for_activation",
    ] {
        assert!(
            activation.contains(required),
            "activation runtime missing process readiness hook {required}"
        );
    }
    let registration =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/registration.rs");
    assert!(
        registration.contains("activation registration rejected")
            && registration.contains("mark_failed_for_activation"),
        "registration mismatch must disconnect and mark process failed"
    );
}

#[test]
fn saawo_has_no_scheduler_provider_public_engine_or_service_manager_surface() {
    let public_engine = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    assert!(
        !public_engine.contains("launch_activation")
            && !public_engine.contains("stop_process")
            && !public_engine.contains("worker.launch"),
        "public /engine transport must not expose worker launch"
    );
    assert!(
        public_engine.contains("&[\"discover\", \"inspect\", \"watch\", \"invoke\", \"promote\"]"),
        "public /engine method set must stay explicit"
    );

    for path in [
        "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
        "packages/agent/src/domains/model/providers/anthropic/message_converter/mod.rs",
        "packages/agent/src/domains/model/providers/google/message_converter.rs",
        "packages/agent/src/domains/model/providers/kimi/message_converter.rs",
    ] {
        let source = read_repo_file(path);
        for forbidden in [
            "worker::launch_activation",
            "worker.launch",
            "launch_activation",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not expose worker launch to providers"
            );
        }
    }

    let triggers = read_repo_file("packages/agent/src/engine/runtime/triggers.rs");
    assert!(
        !triggers.contains("worker::launch_activation")
            && !triggers.contains("worker_launch_plan")
            && !triggers.contains("worker_process"),
        "trigger runtime must not schedule worker launch in SAAWO"
    );

    assert!(
        !repo_path("packages/agent/skills").exists(),
        "primitive branch must not reintroduce repo-managed first-party skills"
    );

    for path in [
        "packages/agent/src/engine/runtime/worker_orchestration/mod.rs",
        "packages/agent/src/engine/runtime/worker_orchestration/contracts.rs",
        "packages/agent/src/engine/runtime/worker_orchestration/process_resource.rs",
        "packages/agent/src/engine/runtime/worker_orchestration/supervisor.rs",
        "packages/agent/src/engine/primitives/worker.rs",
        "packages/agent/src/transport/runtime/external_workers.rs",
    ] {
        let source = read_repo_file(path);
        for forbidden in ["SMAppService", "launchd", "LaunchAgent", "tron deploy"] {
            assert!(
                !source.contains(forbidden),
                "{path} must not introduce service/deploy surface {forbidden}"
            );
        }
    }
}
