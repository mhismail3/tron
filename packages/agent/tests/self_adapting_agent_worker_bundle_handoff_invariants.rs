//! Static gates for the Self-Adapting Agent Worker Bundle Handoff scorecard.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-bundle-handoff-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-bundle-handoff-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-bundle-handoff-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-worker-bundle-handoff-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_worker_bundle_handoff_invariants.rs";
const INVENTORY_HEADER: &str =
    "id\tpath\tlanguage\tsurface\tcurrent_role\tsaawbh_rows\tproof\tresidual_risk";

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
        .filter(|line| line.starts_with("| SAAWBH-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            (
                columns[1].to_owned(),
                columns[3].parse().expect("SAAWBH weight must be numeric"),
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
fn saawbh_docs_readme_and_ci_are_linked() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");
    let local_ci = read_repo_file("scripts/tron.d/quality.sh");
    let github_ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Self-Adapting Agent Worker Bundle Handoff Scorecard",
        "Current score: **100/100**",
        "Status: **complete**",
        "Baseline commit: `2d3cf28eb130bcf6ba22b59b55556ba22abea650`",
        "| SAAWBH-0 | Harness and Baseline | 5 | passed_after_fix |",
        "| SAAWBH-11 | Regression and Closeout | 6 | passed_after_fix |",
        INVARIANT_TEST_PATH,
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Worker Bundle Handoff Evidence Manifest",
        "Status: **complete**",
        "| SAAWBH-0 | passed_after_fix |",
        "| SAAWBH-11 | passed_after_fix |",
        "stdin_activation_bundle_v1",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Worker Bundle Handoff Inventory",
        "Status: SAAWBH campaign `complete`;",
        "`activation_issue`",
        "`durable_redaction`",
        "`vault`",
        "`supervisor_stdin`",
        "`transport_boundary`",
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
            source.contains("self_adapting_agent_worker_bundle_handoff_invariants"),
            "CI must include SAAWBH invariant target"
        );
    }
}

#[test]
fn saawbh_scorecard_and_inventory_are_complete() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAAWBH scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|(_, weight, _)| *weight).sum::<u32>(),
        100,
        "SAAWBH weights must sum to 100"
    );
    assert!(
        rows.iter()
            .all(|(_, _, status)| status == "passed_after_fix"),
        "all SAAWBH rows must be closed"
    );

    let tracked = git_ls_files();
    let inventory = parse_inventory();
    assert!(
        inventory.len() >= 28,
        "SAAWBH inventory must cover major surfaces"
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
        assert!(row[5].contains("SAAWBH-"), "{} must reference rows", row[0]);
        surfaces.insert(row[3].clone());
    }
    for surface in [
        "activation_issue",
        "durable_redaction",
        "vault",
        "launch_plan",
        "supervisor_stdin",
        "process_resource",
        "transport_boundary",
    ] {
        assert!(surfaces.contains(surface), "missing surface {surface}");
    }
}

#[test]
fn saawbh_source_enforces_secret_custody_and_stdin_boundary() {
    let vault =
        read_repo_file("packages/agent/src/engine/runtime/worker_activation_bundle_vault.rs");
    for required in [
        "pub struct WorkerActivationBundleVault",
        "BTreeMap<String, VaultEntry>",
        "pub fn consume(",
        "pub fn purge_expired(",
        "bundle_fingerprint",
        "stdin_bytes",
    ] {
        assert!(vault.contains(required), "vault missing {required}");
    }
    for forbidden in [
        "Sqlite",
        "CreateResource",
        "PublishStreamEvent",
        "EnqueueInvocation",
        "std::fs",
        "tokio::fs",
        "File::",
        "OpenOptions",
        "Command::",
    ] {
        assert!(
            !vault.contains(forbidden),
            "vault must not use durable backing: {forbidden}"
        );
    }

    let issue = read_repo_file("packages/agent/src/engine/primitives/worker_activation.rs");
    assert!(issue.contains("store_worker_activation_bundle"));
    assert!(issue.contains("\"tokenStorage\": \"redacted_fingerprint_only\""));

    let registry = read_repo_file("packages/agent/src/engine/catalog/registry/mod.rs");
    assert!(registry.contains("durable_result_for_invocation"));
    assert!(registry.contains("activation_bundle_not_persisted"));
    assert!(registry.contains("ISSUE_ACTIVATION_FUNCTION"));

    let invocation = read_repo_file("packages/agent/src/engine/catalog/registry/invocation.rs");
    let idempotency = read_repo_file("packages/agent/src/engine/catalog/registry/idempotency.rs");
    assert!(invocation.contains("durable_result_for_invocation"));
    assert!(idempotency.contains("durable_result_for_invocation"));

    let supervisor =
        read_repo_file("packages/agent/src/engine/runtime/worker_orchestration/supervisor.rs");
    for required in [
        "WorkerProcessSecretStdin",
        "Stdio::piped()",
        "write_all(&secret_stdin.bytes)",
        "drop(stdin)",
        "Command::new(&request.executable_path)",
    ] {
        assert!(
            supervisor.contains(required),
            "supervisor missing {required}"
        );
    }
    for forbidden in ["shell", "tempfile", "launchctl", "SMAppService"] {
        assert!(
            !supervisor
                .to_ascii_lowercase()
                .contains(&forbidden.to_ascii_lowercase()),
            "supervisor must not introduce {forbidden}"
        );
    }
}

#[test]
fn saawbh_launch_and_transport_boundaries_remain_closed() {
    let contracts =
        read_repo_file("packages/agent/src/engine/runtime/worker_orchestration/contracts.rs");
    assert!(contracts.contains("reject_secret_material(\"argv\""));
    assert!(contracts.contains("reject_secret_material(\"cwd\""));

    let orchestration =
        read_repo_file("packages/agent/src/engine/runtime/worker_orchestration/mod.rs");
    assert!(orchestration.contains("stdin_activation_bundle_v1"));
    assert!(orchestration.contains("preissued_bundle"));
    assert!(orchestration.contains("consume_worker_activation_bundle"));
    assert!(orchestration.contains("validate_vault_metadata_matches_activation"));
    assert!(orchestration.contains("metadata.token_fingerprint != activation_fingerprint"));
    assert!(orchestration.contains("WorkerProcessSecretStdin"));
    assert!(!orchestration.contains("restartPolicy\": \"always\""));

    let public_engine = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    for forbidden in [
        "launch_activation",
        "activation_handoff",
        "handoff_activation_bundle",
    ] {
        assert!(
            !public_engine.contains(forbidden),
            "public /engine contract must not expose {forbidden}"
        );
    }
    let provider = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
    );
    for forbidden in [
        "launch_activation",
        "stdin_activation_bundle_v1",
        "activation handoff",
    ] {
        assert!(
            !provider.contains(forbidden),
            "provider converter must not expose {forbidden}"
        );
    }
    let triggers = read_repo_file("packages/agent/src/engine/runtime/triggers.rs");
    assert!(
        !triggers.contains("worker::launch_activation"),
        "trigger runtime must not schedule worker launch"
    );
}
