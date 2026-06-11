//! Static gates for the Self-Adapting Agent Successor Teardown Cleanup scorecard.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::Command;

const BASELINE_COMMIT: &str = "b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7";
const INTEGRATION_HEAD: &str = "9e8ccb1cf129ba8ef1dc14d9050e84da5ee7e3b3";
const BRANCH_NAME: &str = "codex/self-adapting-agent-successor-teardown-cleanup";
const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-successor-teardown-cleanup-inventory.tsv";
const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup_invariants.rs";
const INVENTORY_HEADER: &str = "id\tchange\tpath\tclassification\towner\taction\trationale";

#[derive(Debug)]
struct ScorecardRow {
    row: String,
    weight: u32,
    status: String,
}

#[derive(Debug, Clone)]
struct InventoryRow {
    id: String,
    change: String,
    path: String,
    classification: String,
    owner: String,
    action: String,
    rationale: String,
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

fn git_output(args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo_root())
        .output()
        .unwrap_or_else(|error| panic!("git command failed to start: {args:?}: {error}"));
    assert!(
        output.status.success(),
        "git command failed: {:?}\nstdout:\n{}\nstderr:\n{}",
        args,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("git output should be UTF-8")
}

fn git_ls_files() -> BTreeSet<String> {
    git_output(&["ls-files"])
        .lines()
        .map(str::to_owned)
        .collect()
}

fn changed_paths_since_baseline() -> BTreeMap<String, String> {
    git_output(&["diff", "--name-status", BASELINE_COMMIT])
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let columns: Vec<_> = line.split('\t').collect();
            let change = columns
                .first()
                .expect("git diff --name-status must emit a status")
                .to_string();
            let path = columns
                .last()
                .expect("git diff --name-status must emit a path")
                .to_string();
            (path, change)
        })
        .collect()
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SAASTC-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            assert!(
                columns.len() >= 5,
                "scorecard row must have at least 5 columns: {line}"
            );
            ScorecardRow {
                row: columns[1].to_owned(),
                weight: columns[3]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid score in {line}: {error}")),
                status: columns[4].to_owned(),
            }
        })
        .collect()
}

fn parse_inventory() -> Vec<InventoryRow> {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = inventory.lines();
    assert_eq!(
        lines.next().expect("inventory TSV must have a header"),
        INVENTORY_HEADER
    );

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                7,
                "inventory row {} must have 7 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                id: columns[0].to_owned(),
                change: columns[1].to_owned(),
                path: columns[2].to_owned(),
                classification: columns[3].to_owned(),
                owner: columns[4].to_owned(),
                action: columns[5].to_owned(),
                rationale: columns[6].to_owned(),
            }
        })
        .collect()
}

#[test]
fn saastc_harness_docs_readme_and_ci_are_wired() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");
    let local_ci = read_repo_file("scripts/tron.d/quality.sh");
    let github_ci = read_repo_file(".github/workflows/ci.yml");

    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Scorecard",
        "Status: **source_teardown_in_progress**",
        "Current score: **15/100**",
        "Passing threshold: **100/100**",
        BRANCH_NAME,
        BASELINE_COMMIT,
        INTEGRATION_HEAD,
        INVARIANT_TEST_PATH,
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Evidence Manifest",
        "Status: **source_teardown_in_progress**",
        "| SAASTC-0 | passed_after_fix |",
        "| SAASTC-1 | passed_after_fix |",
        "git diff --name-status b331f2b1d58f14aa3392a866e8f008e6fd8a0fb7..HEAD",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
    for required in [
        "# Self-Adapting Agent Successor Teardown Cleanup Inventory",
        "Source teardown in progress",
        "`retained`",
        "`simplify`",
        "`remove`",
        "`docs-only`",
        "`predecessor-bookkeeping`",
    ] {
        assert!(inventory.contains(required), "inventory missing {required}");
    }
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
        "self_adapting_agent_successor_teardown_cleanup_invariants",
    ] {
        assert!(readme.contains(required), "README missing {required}");
    }
    for source in [local_ci, github_ci] {
        assert!(
            source.contains("self_adapting_agent_successor_teardown_cleanup_invariants"),
            "closeout CI must include SAASTC invariant target"
        );
    }
}

#[test]
fn saastc_scorecard_weights_statuses_and_current_score_are_consistent() {
    let rows = parse_scorecard_rows();
    assert_eq!(rows.len(), 12, "SAASTC scorecard must contain rows 0..11");
    assert_eq!(
        rows.iter().map(|row| row.weight).sum::<u32>(),
        100,
        "SAASTC row weights must sum to 100"
    );

    let closed: u32 = rows
        .iter()
        .filter(|row| row.status == "passed_after_fix")
        .map(|row| row.weight)
        .sum();
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(
        scorecard.contains(&format!("Current score: **{closed}/100**")),
        "current score must equal closed SAASTC row weights"
    );

    for required in ["SAASTC-0", "SAASTC-1"] {
        let row = rows
            .iter()
            .find(|row| row.row == required)
            .unwrap_or_else(|| panic!("missing scorecard row {required}"));
        assert_eq!(
            row.status, "passed_after_fix",
            "{required} should be closed by Phase 1"
        );
    }
    for row in rows
        .iter()
        .filter(|row| row.row != "SAASTC-0" && row.row != "SAASTC-1")
    {
        assert_eq!(
            row.status, "pending_source_teardown",
            "{} must remain pending until source teardown proves it",
            row.row
        );
    }
}

#[test]
fn saastc_inventory_covers_every_changed_file_since_oda_baseline() {
    let rows = parse_inventory();
    let changed = changed_paths_since_baseline();
    assert!(
        rows.len() >= changed.len(),
        "cleanup inventory must cover at least the current baseline diff"
    );

    let tracked = git_ls_files();
    let allowed_classifications = BTreeSet::from([
        "retained",
        "simplify",
        "remove",
        "docs-only",
        "predecessor-bookkeeping",
    ]);
    let mut ids = BTreeSet::new();
    let mut by_path = BTreeMap::new();

    for row in rows {
        assert!(
            ids.insert(row.id.clone()),
            "duplicate inventory id {}",
            row.id
        );
        assert!(
            row.id.starts_with("SAASTC-INV-"),
            "inventory id must use SAASTC prefix: {}",
            row.id
        );
        assert!(
            matches!(
                row.change.as_str(),
                "A" | "M" | "D" | "C" | "T" | "U" | "X" | "B"
            ) || row.change.starts_with('R'),
            "{} has unexpected git change marker {}",
            row.id,
            row.change
        );
        assert!(
            allowed_classifications.contains(row.classification.as_str()),
            "{} has invalid classification {}",
            row.id,
            row.classification
        );
        for (field, value) in [
            ("owner", row.owner.as_str()),
            ("action", row.action.as_str()),
            ("rationale", row.rationale.as_str()),
        ] {
            assert!(
                !value.trim().is_empty()
                    && !value.contains("TBD")
                    && !value.contains("TODO")
                    && !value.contains("unclassified"),
                "{} has invalid {} field: {}",
                row.id,
                field,
                value
            );
        }
        assert!(
            changed.contains_key(&row.path)
                || tracked.contains(&row.path)
                || repo_path(&row.path).exists(),
            "{} path must be in the baseline diff, tracked, or present: {}",
            row.id,
            row.path
        );
        assert!(
            by_path.insert(row.path.clone(), row.id.clone()).is_none(),
            "inventory has duplicate path {}",
            row.path
        );
    }

    for path in changed.keys() {
        assert!(
            by_path.contains_key(path),
            "inventory missing changed file from ODA baseline diff: {path}"
        );
    }
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            by_path.contains_key(path),
            "inventory missing cleanup harness file: {path}"
        );
    }
}

#[test]
fn saastc_transport_boundary_has_no_successor_worker_public_surface() {
    let contracts = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    assert!(
        contracts.contains("&[\"discover\", \"inspect\", \"watch\", \"invoke\", \"promote\"]"),
        "public engine transport method set must stay narrow"
    );
    for forbidden in [
        "\"launch\"",
        "\"launch_activation\"",
        "\"launch_from_trigger\"",
        "\"issue_activation\"",
        "\"schedule\"",
        "\"worker_schedule\"",
        "\"worker_activation\"",
        "\"worker_process\"",
        "startupTimeoutMs",
    ] {
        assert!(
            !contracts.contains(forbidden),
            "public engine contracts must not expose successor worker surface: {forbidden}"
        );
    }

    let socket = read_repo_file("packages/agent/src/transport/engine/socket/mod.rs");
    for required in [
        "\"hello\" =>",
        "\"discover\" =>",
        "\"inspect\" =>",
        "\"watch\" =>",
        "\"invoke\" =>",
        "\"promote\" =>",
        "\"subscribe\" =>",
        "\"poll\" =>",
        "\"ack\" =>",
        "\"heartbeat\" =>",
        "\"goodbye\" =>",
    ] {
        assert!(
            socket.contains(required),
            "engine socket dispatch missing retained public/protocol branch {required}"
        );
    }

    let transport_files = [
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/agent/src/transport/engine/mod.rs",
        "packages/agent/src/transport/engine/socket/mod.rs",
        "packages/agent/src/transport/engine/socket/tests.rs",
        "packages/agent/src/transport/engine/socket/wire.rs",
        "packages/agent/src/transport/runtime/mod.rs",
    ];
    for path in transport_files {
        let source = read_repo_file(path);
        for forbidden in [
            "domains::model::providers",
            "openai",
            "worker::launch_activation",
            "worker::launch_from_trigger",
            "worker::issue_activation",
            "worker_schedule_plan",
            "worker_schedule_tick",
            "worker_schedule_scan_state",
            "activationBundle",
            "postReadyPayload",
            "EngineWorkerScheduleService",
            "scheduler.run()",
            "worker_schedule::",
            "SMAppService",
            "launchd",
            "tron deploy",
            "packages/agent/skills",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not expose or start successor worker/provider/deploy surface: {forbidden}"
            );
        }
    }

    let wire = read_repo_file("packages/agent/src/transport/engine/socket/wire.rs");
    for forbidden in [
        "LaunchMessage",
        "ScheduleMessage",
        "ActivationMessage",
        "WorkerActivation",
        "WorkerSchedule",
    ] {
        assert!(
            !wire.contains(forbidden),
            "engine wire DTOs must not define successor worker messages: {forbidden}"
        );
    }
}

#[test]
fn saastc_provider_execute_boundary_is_execute_only_and_fail_closed() {
    let capability_mod = read_repo_file("packages/agent/src/domains/capability/mod.rs");
    let capability_contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    let operations = read_repo_file("packages/agent/src/domains/capability/operations/mod.rs");
    let openai_converter = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/mod.rs",
    );
    let openai_converter_tests = read_repo_file(
        "packages/agent/src/domains/model/providers/openai/message_converter/tests.rs",
    );

    for required in [
        "if spec.operation_key != \"execute\"",
        "unexpected capability operation",
        "`capability::execute`",
        "Provider integrations must expose exactly this one tool",
    ] {
        assert!(
            capability_mod.contains(required),
            "capability module missing execute-only registration guard {required}"
        );
    }
    for required in [
        "pub(crate) const EXECUTE_FUNCTION_ID: &str = \"capability::execute\";",
        "Ok(vec![",
        "CapabilityContract::new(",
        "\"modelPrimitiveName\": \"execute\"",
        "\"additionalProperties\": false",
        "only_execute_is_registered_and_model_facing",
        "execute_schema_exposes_primitive_operations_not_catalog_targets",
        "schema[\"properties\"].get(\"target\").is_none()",
        "schema[\"properties\"].get(\"contractId\").is_none()",
        "schema[\"properties\"].get(\"functionId\").is_none()",
        "schema[\"properties\"].get(\"constraints\").is_none()",
    ] {
        assert!(
            capability_contract.contains(required),
            "capability contract missing execute-only provider marker {required}"
        );
    }
    for forbidden in [
        "worker::launch_activation",
        "worker::launch_from_trigger",
        "worker::issue_activation",
        "worker_schedule_plan",
        "worker_schedule_tick",
        "worker_schedule_scan_state",
    ] {
        assert!(
            !capability_contract.contains(forbidden),
            "provider execute contract must not expose forbidden field or worker surface {forbidden}"
        );
    }

    for required in [
        "validate_execute_context",
        "ActorKind::Agent",
        "ActorKind::System",
        "is_bootstrap_authority_grant_id",
        "execute_operation",
        "\"resource_create\"",
        "\"resource_list\"",
        "\"replay_manifest\"",
        "capability::execute cannot read or write system-scoped resources",
        "capability::execute requires a derived least-privilege authority grant",
    ] {
        assert!(
            operations.contains(required),
            "execute operations missing retained authority/direct-operation guard {required}"
        );
    }
    for forbidden in [
        "catalog_search",
        "catalog::inspect",
        "targetFunction",
        "launch_activation",
        "launch_from_trigger",
        "worker_schedule",
        "activationBundle",
        "providerMetadata",
    ] {
        assert!(
            !operations.contains(forbidden),
            "execute operations must not route through successor/provider surface {forbidden}"
        );
    }

    for required in [
        "primitive_execute_capabilities(capabilities)",
        "capability.name == \"execute\"",
        "Use ONLY this model-facing tool",
    ] {
        assert!(
            openai_converter.contains(required),
            "OpenAI converter missing execute-only provider guard {required}"
        );
    }
    for forbidden in [
        "hosted",
        "tool_search",
        "computer_use",
        "worker_schedule",
        "activationBundle",
        "providerMetadata",
        "runtimeMetadata",
    ] {
        assert!(
            !openai_converter.contains(forbidden),
            "OpenAI converter must not expose hidden/provider worker surface {forbidden}"
        );
    }
    for required in [
        "convert_tools_v2_ignores_non_execute_capabilities",
        "make_tool(\"inspect\"",
        "make_tool(\"launch_activation\"",
        "assert_eq!(result.len(), 1)",
        "assert_eq!(name, \"execute\")",
        "assert!(!result.contains(\"- **inspect**\"))",
        "assert!(result.contains(\"Do not send `target`\"))",
    ] {
        assert!(
            openai_converter_tests.contains(required),
            "OpenAI converter tests missing execute-only regression {required}"
        );
    }
}

#[test]
fn saastc_invocation_host_keeps_single_governed_promotion_path() {
    let catalog_handle =
        read_repo_file("packages/agent/src/engine/invocation/host/catalog_handle.rs");
    let meta = read_repo_file("packages/agent/src/engine/invocation/host/meta.rs");
    let meta_invocation =
        read_repo_file("packages/agent/src/engine/invocation/host/meta_invocation.rs");
    let promotion_governance =
        read_repo_file("packages/agent/src/engine/invocation/host/promotion_governance.rs");
    let runtime_host = read_repo_file("packages/agent/src/engine/invocation/host/runtime_host.rs");
    let trigger_tests = read_repo_file("packages/agent/src/engine/tests/runtime/triggers.rs");

    assert!(
        !catalog_handle.contains("pub async fn promote_function_visibility"),
        "EngineHostHandle must not expose a direct promotion shortcut around engine::promote"
    );
    assert!(
        trigger_tests.contains("host.catalog_mut()")
            && trigger_tests.contains(".promote_function_visibility(")
            && trigger_tests.contains("None,"),
        "legacy direct promotion usage should be isolated to local test setup only"
    );

    for required in [
        "pub(super) const PROMOTE_FUNCTION: &str = \"engine::promote\";",
        ".with_required_authority(AuthorityRequirement::scope(\"engine.promote\"))",
        "\"decisionResourceId\"",
        "\"evidenceResourceIds\"",
        "\"candidateResourceIds\"",
        "\"promotionReason\"",
        "\"additionalProperties\": false",
    ] {
        assert!(
            meta.contains(required),
            "engine::promote contract missing governance requirement {required}"
        );
    }

    let validate_position = meta_invocation
        .find("self.validate_promotion_governance(")
        .expect("engine::promote must validate governance refs");
    let mutate_position = meta_invocation
        .find("self.catalog.promote_function_visibility(")
        .expect("engine::promote must perform the catalog visibility mutation");
    assert!(
        validate_position < mutate_position,
        "engine::promote must validate decision/evidence/candidate resources before mutation"
    );
    for required in [
        "if function.visibility != VisibilityScope::Session",
        "\"cannot promote function from a different session\"",
        "VisibilityScope::Workspace | VisibilityScope::System",
        "Some(governance_refs.redacted_catalog_metadata(&target))",
    ] {
        assert!(
            meta_invocation.contains(required),
            "engine::promote missing fail-closed host guard {required}"
        );
    }

    for required in [
        "ensure_payload_idempotency_matches_context(invocation)?",
        "ensure_target_authority(&actor, target, workspace_id)?",
        "require_resource(&resources, &refs.decision_resource_id)?",
        "ensure_decision_approves(&decision, function, target, workspace_id)?",
        "ensure_evidence_verified(&inspection)?",
        "ensure_candidate_kind(&inspection)?",
        "ensure_candidates_are_chained(&decision, &evidence, &candidates)?",
        "\"workspace promotion requires engine.promote.workspace authority\"",
        "\"system promotion requires admin authority\"",
    ] {
        assert!(
            promotion_governance.contains(required),
            "promotion governance missing retained authority/resource proof {required}"
        );
    }

    for required in [
        "fn derive_authority_grant(",
        ".grants",
        ".derive(request)",
        "fn store_worker_activation_bundle(",
        ".worker_activation_bundles",
        ".store(",
    ] {
        assert!(
            runtime_host.contains(required),
            "primitive runtime host missing retained store boundary {required}"
        );
    }
    for forbidden in [
        "tokio::spawn",
        "launchd",
        "SMAppService",
        "tron deploy",
        "providerMetadata",
        "postReadyPayload",
    ] {
        assert!(
            !runtime_host.contains(forbidden),
            "primitive runtime host must not start autonomous/public/deploy surface {forbidden}"
        );
    }
}

#[test]
fn saastc_primitive_surface_keeps_internal_source_proven_contracts() {
    let primitives = read_repo_file("packages/agent/src/engine/primitives/mod.rs");
    let runtime = read_repo_file("packages/agent/src/engine/primitives/runtime.rs");
    let stores = read_repo_file("packages/agent/src/engine/primitives/stores.rs");
    let activation_governance =
        read_repo_file("packages/agent/src/engine/primitives/worker_activation_governance.rs");
    let workers = read_repo_file("packages/agent/src/engine/primitives/workers.rs");
    let activation_fixture =
        read_repo_file("packages/agent/src/engine/tests/fixtures/worker_activation.rs");
    let activation_tests =
        read_repo_file("packages/agent/src/engine/tests/invocation/worker_activation.rs");

    for required in [
        "pub(in crate::engine) mod runtime;",
        "mod stores;",
        "mod worker_activation_governance;",
        "pub(in crate::engine) use stores::{",
        "pub(in crate::engine) use workers::{primitive_function_definitions, primitive_workers};",
        "worker::issue_activation",
        "`storage::*` is the",
    ] {
        assert!(
            primitives.contains(required),
            "primitive module root missing retained internal contract marker {required}"
        );
    }

    for required in [
        "pub(in crate::engine) trait PrimitiveRuntimeHost",
        "fn discover_functions(",
        "fn inspect_resource(",
        "fn derive_authority_grant(",
        "fn store_worker_activation_bundle(",
        "match invocation.function_id.as_str()",
        "worker::ISSUE_ACTIVATION_FUNCTION => worker_issue_activation(host, invocation)",
        "storage::RETENTION_RUN_FUNCTION => storage_retention_run(host, invocation)",
    ] {
        assert!(
            runtime.contains(required),
            "primitive runtime missing retained dispatch/store boundary {required}"
        );
    }
    for forbidden in [
        "tokio::spawn",
        "launchd",
        "SMAppService",
        "tron deploy",
        "providerMetadata",
        "postReadyPayload",
        "retryLoop",
        "restartLoop",
    ] {
        assert!(
            !runtime.contains(forbidden),
            "primitive runtime must not expose autonomous/provider/deploy surface {forbidden}"
        );
    }

    for required in [
        "pub(in crate::engine) enum ResourceStoreBackend",
        "fn register_type(",
        "fn create(",
        "fn update(",
        "fn link(",
        "fn inspect(",
        "fn list_page(",
        "builtin_resource_type_definitions()",
        "WorkerActivationBundleVault::new()",
        "WorkerProcessSupervisorRegistry::production()",
        "OnceLock<Weak<AsyncMutex<EngineHost>>>",
    ] {
        assert!(
            stores.contains(required),
            "primitive stores missing retained backend/host marker {required}"
        );
    }

    for required in [
        "candidate.resource.kind != \"capability_definition\"",
        "candidate.resource.lifecycle != \"reviewed\"",
        "ensure_candidate_scope_matches_request",
        "ensure_decision_approves_activation",
        "ensure_evidence_verified",
        "ensure_activation_chain",
        "EngineResourceScope::System => actor.actor_kind.is_admin_like()",
        "governance_fingerprint",
    ] {
        assert!(
            activation_governance.contains(required),
            "worker activation governance missing retained primitive guard {required}"
        );
    }

    for required in [
        ".with_namespace_claim(\"worker_activation\")",
        ".with_namespace_claim(\"worker_launch_plan\")",
        ".with_namespace_claim(\"worker_autostart_plan\")",
        ".with_namespace_claim(\"worker_trigger_launch_attempt\")",
        ".with_namespace_claim(\"worker_schedule_plan\")",
        ".with_namespace_claim(\"worker_schedule_tick\")",
        ".with_namespace_claim(\"worker_schedule_scan_state\")",
        ".with_namespace_claim(\"worker_process\")",
        "registrations.extend(worker::registrations(stores)?);",
        "registrations.extend(storage::registrations()?);",
    ] {
        assert!(
            workers.contains(required),
            "primitive worker assembly missing retained namespace/registration {required}"
        );
    }

    for required in [
        "pub resource_scope: Option<VisibilityScope>",
        "unwrap_or(&config.target_visibility)",
        "\"scope\": resource_scope.as_str()",
    ] {
        assert!(
            activation_fixture.contains(required),
            "worker activation fixture missing scoped governance regression support {required}"
        );
    }
    for required in [
        "system_scoped.resource_scope = Some(VisibilityScope::System)",
        "mutating_causal(\"saawa-system-governance\").with_scope(\"worker.activate\")",
        "scope is incompatible with activation target",
    ] {
        assert!(
            activation_tests.contains(required),
            "worker activation tests missing system-governance authority regression {required}"
        );
    }
}

#[test]
fn saastc_resource_substrate_keeps_only_retained_safe_resource_contracts() {
    let sqlite_store =
        read_repo_file("packages/agent/src/engine/durability/resources/store/mod.rs");
    let memory_store =
        read_repo_file("packages/agent/src/engine/durability/resources/store/memory.rs");
    for source in [&sqlite_store, &memory_store] {
        assert!(
            !source.contains("pub fn list_types"),
            "resource stores must not expose the removed type-catalog listing API"
        );
    }

    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    let agent_records = read_repo_file(
        "packages/agent/src/engine/durability/resources/agent_record_definitions.rs",
    );
    let schedule_records = read_repo_file(
        "packages/agent/src/engine/durability/resources/worker_schedule_definitions.rs",
    );
    let validation = read_repo_file("packages/agent/src/engine/durability/resources/validation.rs");
    let types = read_repo_file("packages/agent/src/engine/durability/resources/types.rs");
    let primitive_stores = read_repo_file("packages/agent/src/engine/primitives/stores.rs");
    let store_tests =
        read_repo_file("packages/agent/src/engine/durability/resources/store/tests.rs");

    for required in [
        "agent_record_resource_type_definitions()",
        "worker_schedule_resource_type_definitions()",
        "\"worker_activation\"",
        "\"tron.resource.worker_activation.v1\"",
        "\"worker_process\"",
        "\"tron.resource.worker_process.v1\"",
        "\"additionalProperties\": false",
        "\"tokenFingerprint\"",
        "\"tokenStorage\"",
        "\"registrationMode\"",
        "\"volatile\"",
        "\"networkPolicy\"",
        "\"loopback\"",
        "\"restartPolicy\"",
        "\"none\"",
        "\"duplicatePolicy\"",
        "\"idempotency_key_replay_v1\"",
    ] {
        assert!(
            definitions.contains(required),
            "resource definitions missing retained safe worker contract marker {required}"
        );
    }
    for forbidden in [
        "scopedWorkerToken",
        "activationBundle",
        "postReadyPayload",
        "restartLoop",
        "retryLoop",
        "launchd",
        "SMAppService",
        "apiKey",
        "accessToken",
        "refreshToken",
        "clientSecret",
        "password",
        "credential",
    ] {
        assert!(
            !definitions.contains(forbidden),
            "resource definitions must not persist forbidden worker/secret surface {forbidden}"
        );
    }

    for required in [
        "\"agent_memory\"",
        "\"tron.resource.agent_memory.v1\"",
        "\"agent_rule\"",
        "\"tron.resource.agent_rule.v1\"",
        "\"required\": [\"statement\", \"status\", \"scope\", \"provenance\", \"evidenceRefs\"]",
        "\"additionalProperties\": false",
        "\"supersededByResourceId\"",
        "\"revokedByResourceId\"",
    ] {
        assert!(
            agent_records.contains(required),
            "agent record definitions missing retained authorship marker {required}"
        );
    }

    for required in [
        "\"worker_schedule_plan\"",
        "\"worker_schedule_tick\"",
        "\"worker_schedule_scan_state\"",
        "\"additionalProperties\": false",
        "\"pageSize\": {\"type\": \"integer\", \"minimum\": 1, \"maximum\": 500}",
        "\"maxPerPoll\": {\"type\": \"integer\", \"minimum\": 1, \"maximum\": 500}",
    ] {
        assert!(
            schedule_records.contains(required),
            "schedule resource definitions missing retained bounded-state marker {required}"
        );
    }

    for required in [
        "validate_create_request",
        "validate_update_request",
        "validate_link_request",
        "validate_list_page_request",
        "validate_resource_payload",
        "schema::validate_payload",
        "validate_ui_surface_payload",
    ] {
        assert!(
            validation.contains(required),
            "resource validation missing retained gate {required}"
        );
    }
    for required in [
        "expected_current_version_id",
        "ResourceListCursor",
        "next_cursor",
        "has_more",
        "EngineResourceVersionState",
        "may_be_current",
    ] {
        assert!(
            types.contains(required),
            "resource types missing retained determinism/CAS/page marker {required}"
        );
    }
    for required in [
        "pub(in crate::engine) enum ResourceStoreBackend",
        "fn register_type(",
        "fn create(",
        "fn update(",
        "fn link(",
        "fn inspect(",
        "fn list(",
        "fn list_page(",
        "builtin_resource_type_definitions()",
    ] {
        assert!(
            primitive_stores.contains(required),
            "PrimitiveStores resource backend missing retained access marker {required}"
        );
    }
    assert!(
        !primitive_stores.contains("list_types("),
        "PrimitiveStores must not reintroduce resource type catalog listing"
    );

    for required in [
        "resource_payloads_must_match_registered_schema_before_persisting",
        "sqlite_resource_store_round_trips_full_substrate",
        "sqlite_resource_pages_match_in_memory_cursor_semantics",
        "resource_list_is_filtered_by_kind_scope_and_lifecycle",
    ] {
        assert!(
            store_tests.contains(required),
            "resource store tests missing retained regression {required}"
        );
    }
}

#[test]
fn saastc_external_worker_runtime_lifecycle_is_loopback_bounded() {
    let runtime_root = read_repo_file("packages/agent/src/engine/runtime/mod.rs");
    let external_mod = read_repo_file("packages/agent/src/engine/runtime/external_workers/mod.rs");
    let lifecycle =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/lifecycle.rs");
    let activation =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/activation.rs");
    let registration =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/registration.rs");

    for required in [
        "pub mod external_workers;",
        "`EngineExternalWorkerRuntime` manages connected local workers.",
        "Activation tokens bind reviewed capability-definition governance",
        "volatile worker connection",
        "does not depend on HTTP handlers, domains, app\n//! bootstrap, or provider-specific model clients",
    ] {
        assert!(
            runtime_root.contains(required),
            "runtime module docs missing retained external-worker boundary {required}"
        );
    }

    for required in [
        "pub trait ExternalWorkerInvoker",
        "pub struct ExternalWorkerConnection",
        "pub struct EngineExternalWorkerRuntime",
        "connections: BTreeMap<WorkerId, ExternalWorkerConnection>",
        "invokers: BTreeMap<WorkerId, Arc<dyn ExternalWorkerInvoker>>",
        "WorkerProtocolMessage::Hello(hello)",
        "WorkerProtocolMessage::RegisterFunction(message)",
        "WorkerProtocolMessage::RegisterTrigger(message)",
        "WorkerProtocolMessage::PublishStream(message)",
        "WorkerProtocolMessage::Heartbeat(message)",
        "WorkerProtocolMessage::Disconnect(message)",
        "Ok(None)",
    ] {
        assert!(
            external_mod.contains(required),
            "external worker runtime root missing bounded protocol marker {required}"
        );
    }

    for required in [
        "if !hello.loopback_only",
        "WorkerAuthPolicy::LoopbackBearer",
        "hello.worker.kind != WorkerKind::External",
        "hello.identity.worker_id != worker_id",
        "validate_worker_token(&hello)?",
        "self.validate_activation_hello(&hello).await?",
        "self.validate_worker_grant(&hello).await?",
        "let volatile = hello.registration_mode == WorkerRegistrationMode::Volatile;",
        "self.host.register_worker(hello.worker, volatile).await?",
        "heartbeat.sequence <= connection.heartbeat_sequence",
        "pub async fn disconnect_timed_out(&mut self, timeout: Duration)",
        "reason: \"heartbeat timeout\".to_owned()",
        "self.invokers.remove(&disconnect.worker_id)",
        ".unregister_worker(&connection.worker_id, connection.owner_actor.as_str())",
        "self.mark_durable_worker_disconnected(&connection).await?",
        "CatalogSnapshot {\n            functions,\n            triggers: Vec::new(),\n        }",
        "grant.lifecycle != EngineGrantLifecycle::Active",
        "grant_policy_hash(&grant)",
        "connection.worker_token.authority_grant_id.clone()",
    ] {
        assert!(
            lifecycle.contains(required),
            "external worker lifecycle missing retained boundedness marker {required}"
        );
    }

    for required in [
        "validate_activation_hello",
        "validate_activation_function_registration",
        "validate_activation_trigger_registration",
        "activation workers must use volatile registration",
        "activation workers cannot request system visibility",
        "activation workers may register only the expected function",
        "activation workers cannot register triggers",
        "mark_activation_connected",
        "mark_activation_registered",
        "mark_activation_disconnected",
        "expected_current_version_id",
        "mark_failed_for_activation",
    ] {
        assert!(
            activation.contains(required),
            "external worker activation binding missing retained marker {required}"
        );
    }

    for required in [
        "pub fn attach_invoker(",
        "if !self.connections.contains_key(&worker_id)",
        "validate_activation_function_registration(&connection, &definition)",
        "validate_external_capability_metadata(",
        "stamp_external_capability_metadata(&mut definition, &connection.worker_token)",
        "connection.registration_mode == WorkerRegistrationMode::Volatile",
        "self.validate_activation_trigger_registration(&connection)?",
        "validate_worker_trigger(&self.host, &connection, &message.definition).await?",
        "publish_stream",
        "stream_topic_allowed_by_token(&connection.worker_token, &message.topic)",
        "external worker trigger authority grant must match the scoped token",
        "external worker trigger target",
        "external worker stream sessionId must match the scoped worker session",
    ] {
        assert!(
            registration.contains(required),
            "external worker registration missing retained scoped marker {required}"
        );
    }

    for (path, source) in [
        (
            "packages/agent/src/engine/runtime/external_workers/mod.rs",
            external_mod.as_str(),
        ),
        (
            "packages/agent/src/engine/runtime/external_workers/lifecycle.rs",
            lifecycle.as_str(),
        ),
        (
            "packages/agent/src/engine/runtime/external_workers/activation.rs",
            activation.as_str(),
        ),
        (
            "packages/agent/src/engine/runtime/external_workers/registration.rs",
            registration.as_str(),
        ),
    ] {
        for forbidden in [
            "tokio::spawn",
            "std::process::Command",
            "launchd",
            "SMAppService",
            "tron deploy",
            "packages/agent/skills",
            "providerMetadata",
            "postReadyPayload",
            "restartLoop",
            "retryLoop",
            "worker_schedule",
            "scheduler.run",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not own autonomous launch/deploy/provider/schedule surface: {forbidden}"
            );
        }
    }

    let external_worker_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/external_worker.rs");
    let delivery_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/external_worker_delivery.rs");
    let activation_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/worker_activation.rs");
    for required in [
        "local_external_worker_runtime_registers_session_functions_and_disconnects_cleanly",
        "local_external_worker_hello_requires_session_scoped_token_binding",
        "local_external_worker_hello_rejects_stale_grant_revision",
        "local_external_worker_hello_rejects_tampered_grant_hash",
        "local_external_worker_lifecycle_events_publish_through_streams_and_traces",
    ] {
        assert!(
            external_worker_tests.contains(required),
            "external worker runtime tests missing retained lifecycle regression {required}"
        );
    }
    for required in [
        "local_external_worker_durable_disconnect_marks_functions_unhealthy",
        "local_external_worker_heartbeat_timeout_unregisters_volatile_capabilities",
        ".disconnect_timed_out(std::time::Duration::from_secs(30))",
    ] {
        assert!(
            delivery_tests.contains(required),
            "external worker delivery tests missing retained boundedness regression {required}"
        );
    }
    for required in [
        "worker_activation_runtime_connects_registers_invokes_and_disconnects_volatile_function",
        "worker_activation_hello_rejects_token_scope_expansion_durable_and_revoked_grant",
        "worker_activation_registration_rejects_function_metadata_and_trigger_expansion",
    ] {
        assert!(
            activation_tests.contains(required),
            "worker activation runtime tests missing retained activation regression {required}"
        );
    }
}

#[test]
fn saastc_engine_catalog_module_exports_are_retained_fabric_only() {
    let engine_mod = read_repo_file("packages/agent/src/engine/mod.rs");
    let registry_mod = read_repo_file("packages/agent/src/engine/catalog/registry/mod.rs");
    let idempotency = read_repo_file("packages/agent/src/engine/catalog/registry/idempotency.rs");
    let invocation = read_repo_file("packages/agent/src/engine/catalog/registry/invocation.rs");
    let registration = read_repo_file("packages/agent/src/engine/catalog/registry/registration.rs");

    for required in [
        "Model providers do not see that transport surface\n//! directly; agents receive one model-facing capability, `execute`",
        "engine submodules are crate-private implementation",
        "must use the narrow facade re-exports in this module",
        "pub(crate) mod authority;",
        "pub(crate) mod catalog;",
        "pub(crate) mod durability;",
        "pub(crate) mod invocation;",
        "pub(crate) mod kernel;",
        "pub(crate) mod primitives;",
        "pub(crate) mod runtime;",
        "pub use catalog::registry::LiveCatalog;",
        "pub use invocation::host::{",
        "CatalogWatchRequest, CatalogWatchResponse, EngineHost, EngineHostHandle",
        "pub use runtime::external_workers::{",
        "EngineExternalWorkerRuntime, ExternalWorkerConnection, ExternalWorkerInvoker",
        "pub use runtime::triggers::{EngineTriggerRuntime, TriggerDispatchRequest};",
        "pub use runtime::worker_protocol::{",
        "pub use runtime::worker_schedule::{",
        "pub(crate) fn is_bootstrap_authority_grant_id",
    ] {
        assert!(
            engine_mod.contains(required),
            "engine module facade missing retained export/boundary marker {required}"
        );
    }
    for forbidden in [
        "pub mod authority;",
        "pub mod catalog;",
        "pub mod durability;",
        "pub mod invocation;",
        "pub mod kernel;",
        "pub mod primitives;",
        "pub mod runtime;",
        "domains::model::providers",
        "transport::engine",
        "std::process::Command",
        "tokio::spawn",
        "launchd",
        "SMAppService",
        "tron deploy",
        "packages/agent/skills",
    ] {
        assert!(
            !engine_mod.contains(forbidden),
            "engine facade must not widen module/provider/deploy surface: {forbidden}"
        );
    }

    for required in [
        "mod authorization;",
        "mod catalog_changes;",
        "mod cleanup;",
        "mod idempotency;",
        "mod invocation;",
        "mod output_contract;",
        "mod registration;",
        "mod search;",
        "pub(in crate::engine) use idempotency::InvocationIdempotencyDecision;",
        "pub(in crate::engine) use invocation::{PreparedSyncInvocation, PreparedSyncInvocationDecision};",
        "pub(super) fn durable_result_for_invocation",
        "activation_bundle_not_persisted",
        "\"scopedWorkerToken\": {\"redacted\": true}",
        "ledger: Box<dyn EngineLedgerStore>",
        "grants: Arc<StdMutex<EngineGrantStoreBackend>>",
        "pub(in crate::engine) fn set_grant_store",
    ] {
        assert!(
            registry_mod.contains(required),
            "catalog registry module missing retained private/export marker {required}"
        );
    }

    for required in [
        "pub(in crate::engine) enum InvocationIdempotencyDecision",
        "ReplayBehavior::ReturnPrevious",
        "ReplayBehavior::NoOp",
        "ReplayBehavior::Reject",
        "ReplayBehavior::Compensate",
        "compensation replay is not executable in phase 1",
        "pub(in crate::engine) fn begin_invocation_idempotency",
        "pub(in crate::engine) fn complete_invocation_idempotency",
        "LedgerKind::InMemory | LedgerKind::EngineLedger",
        "payload_fingerprint(&invocation.payload)",
        "write_canonical_json",
    ] {
        assert!(
            idempotency.contains(required),
            "catalog idempotency missing retained reservation/replay marker {required}"
        );
    }

    for required in [
        "pub(in crate::engine) struct PreparedSyncInvocation",
        "pub(in crate::engine) enum PreparedSyncInvocationDecision",
        "policy::validate_invocation",
        "policy::validate_trigger_target_invocation",
        "self.validate_invocation_grant(&function, &invocation)",
        "self.ledger.reserve_idempotency(reservation.clone())",
        "schema::validate_payload(&function.id, \"request\"",
        "self.consume_invocation_budget(&function, &invocation)",
        "PreparedSyncInvocationDecision::Execute",
        "pub(in crate::engine) fn finish_prepared_sync_invocation",
        "pub(in crate::engine) fn finish_prepared_sync_invocation_with_contracts",
        "validate_output_contract(&function, &invocation, &value)",
        "StoredInvocationOutcome::from_result(&durable_result)",
        "append_invocation",
    ] {
        assert!(
            invocation.contains(required),
            "catalog invocation missing retained prepare/finish marker {required}"
        );
    }

    for required in [
        "pub(in crate::engine) fn hydrate_durable_catalog_from_ledger",
        "worker.lifecycle = WorkerLifecycleState::Stopped",
        "function.health = FunctionHealth::Unhealthy",
        "validate_worker_namespace_claims(&definition)?",
        "self.validate_worker_grant(&definition)?",
        "validate_reserved_function_namespace(&definition)?",
        "self.validate_function_worker_grant(&definition, owner)?",
        "policy::validate_function_registration(&definition)?",
        "let persist_durable_external = !volatile && owner.kind == WorkerKind::External;",
        "self.cleanup_owned_volatile(id)?",
        "pub fn promote_function_visibility",
        "policy::validate_trigger_registration(",
        "fn validate_worker_namespace_claims",
        "fn validate_reserved_function_namespace",
    ] {
        assert!(
            registration.contains(required),
            "catalog registration missing retained owner/durability marker {required}"
        );
    }

    for (path, source) in [
        (
            "packages/agent/src/engine/catalog/registry/idempotency.rs",
            idempotency.as_str(),
        ),
        (
            "packages/agent/src/engine/catalog/registry/invocation.rs",
            invocation.as_str(),
        ),
        (
            "packages/agent/src/engine/catalog/registry/mod.rs",
            registry_mod.as_str(),
        ),
        (
            "packages/agent/src/engine/catalog/registry/registration.rs",
            registration.as_str(),
        ),
    ] {
        for forbidden in [
            "tokio::spawn",
            "std::process::Command",
            "launchd",
            "SMAppService",
            "tron deploy",
            "packages/agent/skills",
            "domains::model::providers",
            "postReadyPayload",
            "restartLoop",
            "retryLoop",
            "worker_schedule",
            "scheduler.run",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not own autonomous/provider/deploy/schedule surface: {forbidden}"
            );
        }
    }
}

#[test]
fn saastc_phase1_records_hard_cleanup_boundaries() {
    let joined = format!(
        "{}\n{}\n{}",
        read_repo_file(SCORECARD_PATH),
        read_repo_file(EVIDENCE_PATH),
        read_repo_file(INVENTORY_PATH)
    );
    for required in [
        "Do not add provider-visible tools",
        "Do not add public `/engine` surfaces",
        "Do not reintroduce repo-managed first-party skills",
        "No source retention decision is final until SAASTC-2 through SAASTC-8",
    ] {
        assert!(
            joined.contains(required),
            "SAASTC docs must record cleanup boundary: {required}"
        );
    }
}
