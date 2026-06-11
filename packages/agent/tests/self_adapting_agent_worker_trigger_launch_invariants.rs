//! Static gates for the Self-Adapting Agent Worker Trigger Launch scorecard.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-trigger-launch-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-trigger-launch-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-trigger-launch-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-trigger-launch-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_worker_trigger_launch_invariants.rs";
const INVENTORY_HEADER: &str =
    "id\tpath\tlanguage\tsurface\tcurrent_role\tsaawtl_rows\tproof\tresidual_risk";

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

fn git_ls_files() -> BTreeSet<String> {
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

fn parse_scorecard_rows() -> Vec<(String, u32, String)> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SAAWTL-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            (
                columns[1].to_owned(),
                columns[3].parse().expect("SAAWTL weight must be numeric"),
                columns[4].to_owned(),
            )
        })
        .collect()
}

fn parse_inventory() -> Vec<Vec<String>> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next().expect("inventory TSV must have a header"),
        INVENTORY_HEADER
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

#[test]
fn saawtl_docs_readme_and_ci_are_linked() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");
    let local_ci = read_repo_file("scripts/tron.d/quality.sh");
    let github_ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Self-Adapting Agent Worker Trigger Launch Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "Baseline commit: `899910502ec894e1ba8b0c6a5bb0795549383d88`",
        "| SAAWTL-0 | Harness and Baseline | 5 | passed_after_fix |",
        "| SAAWTL-11 | Regression and Closeout | 12 | passed_after_fix |",
        INVARIANT_TEST_PATH,
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Worker Trigger Launch Evidence Manifest",
        "Status: **complete**",
        "| SAAWTL-0 | passed_after_fix |",
        "| SAAWTL-11 | passed_after_fix |",
        "stdin_activation_bundle_v1",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Worker Trigger Launch Inventory",
        "Status: SAAWTL campaign `complete`;",
        "`trigger_dispatch`",
        "`autostart_plan`",
        "`trigger_launch_runtime`",
        "`attempt_audit`",
        "`forbidden_surface`",
    ] {
        assert!(inventory.contains(required), "inventory missing {required}");
    }
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(readme.contains(required), "README missing {required}");
    }
    for source in [local_ci, github_ci] {
        assert!(
            source.contains("self_adapting_agent_worker_trigger_launch_invariants"),
            "CI must include SAAWTL invariant target"
        );
    }
}

#[test]
fn saawtl_scorecard_and_inventory_are_complete() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAAWTL scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|(_, weight, _)| *weight).sum::<u32>(),
        100,
        "SAAWTL weights must sum to 100"
    );
    assert!(
        rows.iter()
            .all(|(_, _, status)| status == "passed_after_fix"),
        "all SAAWTL rows must be closed"
    );

    let tracked = git_ls_files();
    let inventory = parse_inventory();
    assert!(
        inventory.len() >= 24,
        "SAAWTL inventory must cover major surfaces"
    );
    let mut ids = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    for row in inventory {
        assert_eq!(row.len(), 8, "inventory rows must have 8 columns");
        assert!(
            ids.insert(row[0].clone()),
            "duplicate inventory id {}",
            row[0]
        );
        assert!(
            tracked.contains(&row[1]) || repo_path(&row[1]).exists(),
            "inventory path must be tracked, staged, or present: {}",
            row[1]
        );
        assert!(row[5].contains("SAAWTL-"), "{} must reference rows", row[0]);
        surfaces.insert(row[3].clone());
    }
    for surface in [
        "trigger_dispatch",
        "autostart_plan",
        "trigger_launch_runtime",
        "activation_issue",
        "stdin_launch",
        "attempt_audit",
        "forbidden_surface",
    ] {
        assert!(surfaces.contains(surface), "missing surface {surface}");
    }
}

#[test]
fn saawtl_source_enforces_trigger_only_stdin_launch() {
    let worker = read_repo_file("packages/agent/src/engine/primitives/worker.rs");
    for required in [
        "worker::launch_from_trigger",
        "AuthorityRequirement {\n        scopes: vec![\"worker.activate\".to_owned(), \"worker.launch\".to_owned()],",
        "IdempotencyContract::caller_system_engine_ledger()",
        "launch_from_trigger.visibility = VisibilityScope::Admin",
    ] {
        assert!(
            worker.contains(required),
            "worker primitive missing {required}"
        );
    }

    let trigger_launch =
        read_repo_file("packages/agent/src/engine/runtime/worker_orchestration/trigger_launch.rs");
    for required in [
        "requires trigger causal context",
        "requires target idempotency key",
        "worker::issue_activation",
        "worker::launch_activation",
        "saawtl:issue:",
        "saawtl:launch:",
        "worker_trigger_launch_attempt",
        "stdin_activation_bundle_v1",
        "restartPolicy\": \"none",
        "activation_bundle_vault_only",
        "validate_launch_plan_matches_activation",
    ] {
        assert!(
            trigger_launch.contains(required),
            "trigger launch runtime missing {required}"
        );
    }
    for forbidden in [
        "tokio::time::interval",
        "spawn(",
        "launchd",
        "SMAppService",
        "tron deploy",
        "set_var(",
        "activationBundle",
    ] {
        assert!(
            !trigger_launch.contains(forbidden),
            "trigger launch runtime must not contain {forbidden}"
        );
    }

    let contracts =
        read_repo_file("packages/agent/src/engine/runtime/worker_orchestration/contracts.rs");
    for required in [
        "pub(in crate::engine::runtime) struct AutostartPlan",
        "require_policy(policy, \"deliveryMode\", \"stdin_activation_bundle_v1\")",
        "require_policy(policy, \"restartPolicy\", \"none\")",
        "require_policy(policy, \"duplicatePolicy\", \"idempotency_key_replay_v1\")",
        "reject_secret_material_in_value",
    ] {
        assert!(contracts.contains(required), "contracts missing {required}");
    }
}

#[test]
fn saawtl_resource_contracts_and_boundaries_are_registered() {
    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    for required in [
        "\"worker_autostart_plan\"",
        "\"tron.resource.worker_autostart_plan.v1\"",
        "\"worker_trigger_launch_attempt\"",
        "\"tron.resource.worker_trigger_launch_attempt.v1\"",
        "\"deliveryMode\": {\"type\": \"string\", \"enum\": [\"stdin_activation_bundle_v1\"]}",
        "\"restartPolicy\": {\"type\": \"string\", \"enum\": [\"none\"]}",
        "\"duplicatePolicy\": {\"type\": \"string\", \"enum\": [\"idempotency_key_replay_v1\"]}",
        "\"ready_pending\"",
    ] {
        assert!(
            definitions.contains(required),
            "resource definitions missing {required}"
        );
    }

    let meta = read_repo_file("packages/agent/src/engine/invocation/host/meta.rs");
    assert!(meta.contains("\"worker::launch_from_trigger\""));

    let transport = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    let provider = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
    );
    for source in [transport, provider] {
        assert!(
            !source.contains("launch_from_trigger")
                && !source.contains("worker_autostart_plan")
                && !source.contains("worker_trigger_launch_attempt"),
            "trigger launch must not be public/provider-visible"
        );
    }
}

#[test]
fn saawtl_tests_cover_runtime_and_forbidden_surface() {
    let runtime_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/worker_trigger_launch.rs");
    for required in [
        "worker_trigger_launch_dispatch_issues_stdin_launch_once_and_replays_attempt",
        "worker_trigger_launch_rejects_direct_calls_and_unreviewed_context",
        "worker_trigger_launch_rejects_wrong_policy_before_issue_or_start",
        "fake.starts.load(Ordering::SeqCst),\n        1",
        "had_secret_stdin",
        "workerHello",
    ] {
        assert!(
            runtime_tests.contains(required),
            "runtime tests missing {required}"
        );
    }

    let external_registration =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/registration.rs");
    assert!(external_registration.contains("validate_activation_trigger_registration"));
    assert!(!external_registration.contains("launch_from_trigger"));

    let repo_files = git_ls_files();
    for forbidden_path in [
        "packages/agent/skills",
        "packages/agent/src/service_manager",
        "packages/agent/src/launchd",
    ] {
        assert!(
            !repo_files
                .iter()
                .any(|path| path.starts_with(forbidden_path)),
            "forbidden path introduced: {forbidden_path}"
        );
    }
}
