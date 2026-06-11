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
