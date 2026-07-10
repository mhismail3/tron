//! Capstone invariants for the minimal-kernel self-adaptation foundation.
//!
//! The goal of these tests is not to add another runtime layer. They make sure
//! the existing modularity, context-policy, dynamic-route, and cockpit
//! scorecards are tied to source files that actually enforce the contract.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

const SCORECARD_PATH: &str =
    "packages/agent/docs/minimal-kernel-self-adaptation-hardening-scorecard.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/minimal-kernel-self-adaptation-hardening-inventory.tsv";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/minimal-kernel-self-adaptation-hardening-evidence-manifest.md";
const MODULARITY_SCORECARD_PATH: &str = "packages/agent/docs/capability-modularity-scorecard.md";
const MODULARITY_INVENTORY_PATH: &str = "packages/agent/docs/capability-modularity-inventory.tsv";
const DYNAMIC_SCORECARD_PATH: &str =
    "packages/agent/docs/capability-dynamic-replacement-scorecard.md";
const REGISTRY_PATH: &str =
    "packages/agent/src/domains/capability/operations/operation_contract.rs";
const ROUTE_PATH: &str = "packages/agent/src/domains/capability_binding/route.rs";
const CONTEXT_CONTROL_PATH: &str = "packages/agent/src/domains/context_control/mod.rs";
const CONTEXT_CONTROL_TESTS_PATH: &str = "packages/agent/src/domains/context_control/tests.rs";
const CAPABILITY_BINDING_TESTS_PATH: &str =
    "packages/agent/src/domains/capability_binding/tests.rs";
const COCKPIT_VISIBILITY_PATH: &str =
    "packages/agent/src/domains/capability_binding/cockpit_visibility.rs";
const README_PATH: &str = "README.md";

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
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

fn registry_operations() -> Vec<String> {
    let registry = read_repo_file(REGISTRY_PATH);
    let mut in_registry = false;
    let mut operations = Vec::new();
    for line in registry.lines() {
        if line.trim() == "define_operation_ids! {" {
            in_registry = true;
            continue;
        }
        if in_registry && line.trim() == "}" {
            break;
        }
        if !in_registry {
            continue;
        }
        let trimmed = line.trim();
        if trimmed.contains("=> \"") {
            let operation = trimmed
                .split('"')
                .nth(1)
                .unwrap_or_else(|| panic!("registry operation row is malformed: {line}"));
            operations.push(operation.to_owned());
        }
    }
    operations
}

fn tsv_rows(path: &str) -> Vec<HashMap<String, String>> {
    let text = read_repo_file(path);
    let mut lines = text.lines();
    let header = lines
        .next()
        .unwrap_or_else(|| panic!("{path} must have a TSV header"))
        .split('\t')
        .map(str::to_owned)
        .collect::<Vec<_>>();
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let values = line.split('\t').map(str::to_owned).collect::<Vec<_>>();
            assert_eq!(
                values.len(),
                header.len(),
                "{path} has malformed TSV row: {line}"
            );
            header.iter().cloned().zip(values).collect()
        })
        .collect()
}

fn locked_family_capstone_area(family: &str, ownership_class: &str) -> Option<&'static str> {
    match (family, ownership_class) {
        ("core", "kernel_locked") => Some("minimal_kernel_authority"),
        ("state", "kernel_locked") => Some("minimal_kernel_event_log"),
        ("trace" | "logs" | "catalog_discovery", "kernel_locked") => {
            Some("minimal_kernel_trace_replay_catalog")
        }
        ("device" | "notifications", "governance_locked") => {
            Some("minimal_kernel_resource_custody")
        }
        ("capability_binding", "governance_locked") => Some("capability_route_contract"),
        (
            "module_registry"
            | "module_authoring"
            | "module_validation"
            | "module_install"
            | "module_dependencies"
            | "module_lifecycle"
            | "module_runtime"
            | "procedural"
            | "tool_sources"
            | "worker_packages",
            "governance_locked",
        ) => Some("module_governance_pipeline"),
        _ => None,
    }
}

#[test]
fn minimal_kernel_capstone_artifacts_are_present_and_honest() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let readme = read_repo_file(README_PATH);
    let modularity = read_repo_file(MODULARITY_SCORECARD_PATH);
    let dynamic = read_repo_file(DYNAMIC_SCORECARD_PATH);

    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Provider-visible surface remains one tool: `capability::execute`",
        "new provider operation",
        "safely replace every adapter today",
        "first scoped read-only `git_status` route",
        "context_policy_snapshot",
        "route events",
        "rollback/disable controls",
    ] {
        assert!(
            scorecard.contains(required)
                || evidence.contains(required)
                || readme.contains(required),
            "capstone artifacts missing required marker: {required}"
        );
    }

    assert!(
        inventory.starts_with("area\towner\tclass\tevidence\tstatus\tnextAction\n"),
        "minimal-kernel inventory header drifted"
    );
    for area in [
        "minimal_kernel_authority",
        "minimal_kernel_transport",
        "minimal_kernel_event_log",
        "minimal_kernel_resource_custody",
        "minimal_kernel_redaction",
        "minimal_kernel_trace_replay_catalog",
        "module_governance_pipeline",
        "capability_route_contract",
        "context_policy_contract",
        "cockpit_visibility_contract",
        "honest_boundary",
    ] {
        assert!(inventory.contains(area), "inventory missing area {area}");
        let row = inventory
            .lines()
            .find(|line| line.starts_with(area))
            .unwrap_or_else(|| panic!("inventory missing row for {area}"));
        assert!(row.contains("\tpassed\t"), "{area} must be passed");
        assert!(
            row.ends_with("\tnone"),
            "{area} must not leave a dangling action"
        );
    }

    for source_scorecard in [&modularity, &dynamic] {
        assert!(
            source_scorecard.contains("Current score: **100/100**")
                || source_scorecard.contains("Current foundation score: **100/100**"),
            "capstone can only close over complete source scorecards"
        );
    }
}

#[test]
fn minimal_kernel_capstone_adds_no_runtime_plane_or_provider_tool() {
    let operations = registry_operations();
    for forbidden_prefix in [
        "minimal_kernel_",
        "self_adaptation_",
        "self_update_",
        "runtime_replacement_",
    ] {
        let unexpected: Vec<_> = operations
            .iter()
            .filter(|operation| operation.starts_with(forbidden_prefix))
            .collect();
        assert!(
            unexpected.is_empty(),
            "capstone must not add provider-visible operations: {unexpected:?}"
        );
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    for forbidden in [
        "package manager is invoked by the capstone",
        "production deploy",
        "arbitrary hot swapping",
    ] {
        assert!(
            !scorecard.contains(forbidden),
            "capstone must not describe forbidden runtime behavior: {forbidden}"
        );
    }
}

#[test]
fn minimal_kernel_capstone_closes_over_locked_operation_inventory() {
    let capstone_rows = tsv_rows(INVENTORY_PATH);
    let capstone_areas = capstone_rows
        .iter()
        .map(|row| row["area"].as_str())
        .collect::<HashSet<_>>();
    let modularity_rows = tsv_rows(MODULARITY_INVENTORY_PATH);
    let mut locked_rows = 0usize;

    for row in modularity_rows {
        let operation = row["operation"].as_str();
        let family = row["family"].as_str();
        let ownership_class = row["ownershipClass"].as_str();
        if !matches!(ownership_class, "kernel_locked" | "governance_locked") {
            continue;
        }
        locked_rows += 1;
        let area = locked_family_capstone_area(family, ownership_class).unwrap_or_else(|| {
            panic!(
                "{operation} is {ownership_class} in family {family}, but the minimal-kernel capstone has no substrate mapping for that locked family"
            )
        });
        assert!(
            capstone_areas.contains(area),
            "{operation} maps to capstone area {area}, but the capstone inventory does not contain it"
        );
    }

    assert!(
        locked_rows > 0,
        "capstone closure test must cover at least one kernel/governance operation"
    );
}

#[test]
fn replacement_contract_is_verifiable_not_best_effort() {
    let route = read_repo_file(ROUTE_PATH);
    let binding_tests = read_repo_file(CAPABILITY_BINDING_TESTS_PATH);
    let module_runtime = read_repo_file("packages/agent/src/domains/module_runtime/service.rs");
    let dynamic = read_repo_file(DYNAMIC_SCORECARD_PATH);

    for required in [
        "validated_shadow_evidence_from_payload",
        "validated_shadow_evidence_from_candidate",
        "validate_candidate_runtime_contract",
        "expectedCapabilityReplacementCandidateVersionId",
        "expectedCapabilityRouteBindingVersionId",
        "route_has_terminal_event",
        "emit_route_lookup_failed_event",
        "emit_routed_invocation_event",
        "capability route requires accepted shadow trial evidence",
        "capability route authority requires resource-scoped exact selectors",
        "stale capability replacement candidate version",
        "active route binding is missing candidate version ref",
        "active_route_failed_closed",
        "builtInProjectionUsed",
        "rollbackAvailable",
        "disableAvailable",
        "\"networkPolicy\": \"none\"",
    ] {
        assert!(
            route.contains(required),
            "route contract missing source marker: {required}"
        );
    }

    for required in [
        "project_provider_safe_adapter_output",
        "accepted_shadow_trial_evidence",
        "supervisorEnvelopeOnly",
        "liveModuleCodeExecuted",
        "module runtime adapter projection rejected stale lifecycle ref",
        "module runtime adapter projection rejected stale runtime ref",
        "git_status adapter projection requires concrete evidenceRef",
    ] {
        assert!(
            module_runtime.contains(required),
            "module-runtime projection boundary missing marker: {required}"
        );
    }

    for required_test in [
        "capability_execute_dispatch_routes_git_status_through_active_replacement",
        "active_route_rejects_unsafe_adapter_projection_without_builtin_success_substitution",
        "route_lookup_rejects_stale_binding_or_candidate_current_versions",
        "route_candidate_rejects_stale_or_unauthorized_runtime_contract_refs",
        "active_route_lookup_rejects_multiple_active_routes_in_scope",
        "shadow_trial_rejects_completed_projection_without_concrete_evidence",
    ] {
        assert!(
            binding_tests.contains(required_test),
            "route contract must have regression coverage: {required_test}"
        );
    }

    assert!(
        dynamic.contains("not arbitrary live module-code execution"),
        "dynamic scorecard must keep the first route boundary honest"
    );
}

#[test]
fn context_policy_contract_is_server_owned_and_summarizer_only() {
    let context_mod = read_repo_file(CONTEXT_CONTROL_PATH);
    let context_tests = read_repo_file(CONTEXT_CONTROL_TESTS_PATH);
    let context_records = read_repo_file("packages/agent/src/domains/context_control/records.rs");
    let context_service = read_repo_file("packages/agent/src/domains/context_control/service.rs");
    let resource_defs = read_repo_file(
        "packages/agent/src/engine/durability/resources/context_control_definitions.rs",
    );
    let modularity = read_repo_file(MODULARITY_SCORECARD_PATH);

    for required in [
        "context_survivor",
        "context_exclusion",
        "context_policy_snapshot",
        "future context summarizers",
        "summarizer strategy only",
        "server-owned",
        "consumed the current policy snapshot",
    ] {
        assert!(
            context_mod.contains(required),
            "context-control docs missing policy marker: {required}"
        );
    }

    for required in [
        "summarizerMustConsume",
        "futureProviderContextBinding",
        "\"targetRef\"",
        "providerSafeRefOnly",
        "hiddenPromptBodiesExcluded",
    ] {
        assert!(
            context_records.contains(required) || context_service.contains(required),
            "context policy records missing proof marker: {required}"
        );
    }

    for required in [
        "context_policy_records_list_disable_and_snapshot_with_exact_authority",
        "context_policy_snapshot_rejects_overflow_instead_of_truncating",
        "context_policy_list_rejects_limit_truncation",
        "context_policy_record_rejects_raw_local_paths",
        "context_policy_records_require_safe_refs_and_reason",
    ] {
        assert!(
            context_tests.contains(required),
            "context policy must have regression coverage: {required}"
        );
    }

    for kind in [
        "CONTEXT_SURVIVOR_PAYLOAD_SCHEMA_VERSION",
        "CONTEXT_EXCLUSION_PAYLOAD_SCHEMA_VERSION",
        "CONTEXT_POLICY_SNAPSHOT_PAYLOAD_SCHEMA_VERSION",
        "context_policy_snapshot_provider_safe",
    ] {
        assert!(
            resource_defs.contains(kind),
            "context policy resource definitions missing {kind}"
        );
    }

    assert!(
        modularity.contains("context_control_compact")
            && modularity.contains("summarizer strategy"),
        "capability modularity scorecard must classify compaction as a summarizer seam only"
    );
}

#[test]
fn cockpit_visibility_is_server_truth_not_local_storytelling() {
    let cockpit = read_repo_file(COCKPIT_VISIBILITY_PATH);
    let ios_dto = read_repo_file(
        "packages/ios-app/Sources/Engine/Protocol/WorkerLifecycle/EngineProtocolTypes+CapabilityCockpit.swift",
    );
    let ios_state =
        read_repo_file("packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift");
    let ios_views =
        read_repo_file("packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitViews.swift");
    let evidence = read_repo_file(EVIDENCE_PATH);

    for required in [
        "collect_facts",
        "route_stories",
        "CAPABILITY_ROUTE_ACTIVATION_KIND",
        "CAPABILITY_ROUTE_EVENT_KIND",
        "CAPABILITY_ROUTE_ROLLBACK_KIND",
        "resource_scan_complete",
        "resourceScanComplete",
        "activeRoutes",
        "failedClosed",
        "rolledBack",
    ] {
        assert!(
            cockpit.contains(required)
                || ios_dto.contains(required)
                || ios_state.contains(required)
                || ios_views.contains(required),
            "cockpit visibility missing server-truth marker: {required}"
        );
    }

    for required in [
        "routeStories",
        "What Changed",
        "CapabilityOperationDetailSheet",
    ] {
        assert!(
            ios_state.contains(required) || ios_views.contains(required),
            "iOS cockpit must render server-owned adaptation facts: {required}"
        );
    }

    assert!(
        evidence.contains("without raw IDs") || evidence.contains("no raw IDs"),
        "capstone evidence must keep top-level visibility redacted"
    );
}
