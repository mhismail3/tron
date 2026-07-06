//! Static invariants for governed dynamic capability replacement.
//!
//! These tests intentionally verify documentation and source contracts rather
//! than executing arbitrary module code. The first route slice is scoped to
//! `git_status` and proves the governed dispatcher can route to a supervised
//! module-runtime provider-safe adapter projection while failing closed when
//! the projection boundary is unsafe.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

const SCORECARD_PATH: &str = "packages/agent/docs/capability-dynamic-replacement-scorecard.md";
const INVENTORY_PATH: &str = "packages/agent/docs/capability-dynamic-replacement-inventory.tsv";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/capability-dynamic-replacement-evidence-manifest.md";
const REGISTRY_PATH: &str = "packages/agent/src/domains/capability/operations/registry.rs";
const DISPATCH_PATH: &str = "packages/agent/src/domains/capability/operations/dispatch.rs";
const GIT_OPERATION_PATH: &str = "packages/agent/src/domains/capability/operations/git.rs";
const ROUTE_PATH: &str = "packages/agent/src/domains/capability_binding/route.rs";
const VALIDATION_PATH: &str = "packages/agent/src/domains/capability_binding/validation.rs";
const RESOURCE_DEFINITIONS_PATH: &str =
    "packages/agent/src/engine/durability/resources/capability_binding_definitions.rs";
const README_PATH: &str = "README.md";

const ROUTE_OPERATIONS: [&str; 11] = [
    "capability_replacement_candidate_record",
    "capability_replacement_candidate_list",
    "capability_replacement_candidate_inspect",
    "capability_route_binding_record",
    "capability_route_binding_list",
    "capability_route_binding_inspect",
    "capability_route_activate",
    "capability_route_disable",
    "capability_route_rollback",
    "capability_route_event_list",
    "capability_route_event_inspect",
];

const ROUTE_RESOURCE_KINDS: [&str; 5] = [
    "capability_replacement_candidate",
    "capability_route_binding",
    "capability_route_activation",
    "capability_route_event",
    "capability_route_rollback",
];

const SCORECARD_AREAS: [&str; 9] = [
    "Runtime route model",
    "Candidate module contract",
    "Shadow execution",
    "Activation and routing",
    "Rollback and disable",
    "Agent workflow",
    "Cockpit/session visibility",
    "Tests/stress harness",
    "Minimal-engine guardrails",
];

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

fn registry_operations() -> BTreeSet<String> {
    let registry = read_repo_file(REGISTRY_PATH);
    let mut in_registry = false;
    let mut operations = BTreeSet::new();
    for line in registry.lines() {
        if line.contains("SUPPORTED_OPERATION_NAMES") {
            in_registry = true;
            continue;
        }
        if in_registry && line.trim() == "];" {
            break;
        }
        if !in_registry {
            continue;
        }
        let trimmed = line.trim();
        if trimmed.starts_with('"') {
            let operation = trimmed
                .split('"')
                .nth(1)
                .unwrap_or_else(|| panic!("registry operation row is malformed: {line}"));
            operations.insert(operation.to_owned());
        }
    }
    operations
}

#[test]
fn dynamic_replacement_scorecard_artifacts_are_present_and_weighted() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let readme = read_repo_file(README_PATH);

    for area in SCORECARD_AREAS {
        assert!(
            scorecard.contains(area),
            "dynamic replacement scorecard missing weighted area {area}"
        );
        assert!(
            inventory.contains(&area.to_lowercase().replace([' ', '/', '-'], "_")),
            "dynamic replacement inventory missing row for {area}"
        );
    }

    for required in [
        "Current foundation score: **92/100**",
        "Provider-visible surface remains one tool: `capability::execute`",
        "supervised module-runtime provider-safe adapter projection",
        "active_route_module_adapter_projection",
        "packages/agent/docs/capability-dynamic-replacement-inventory.tsv",
        "packages/agent/docs/capability-dynamic-replacement-evidence-manifest.md",
    ] {
        assert!(
            scorecard.contains(required)
                || evidence.contains(required)
                || readme.contains(required),
            "dynamic replacement artifacts missing required text: {required}"
        );
    }
}

#[test]
fn dynamic_replacement_registry_and_dispatch_expose_route_operations_once() {
    let registry = registry_operations();
    let dispatch = read_repo_file(DISPATCH_PATH);

    assert!(
        registry.contains("git_status"),
        "first dynamic replacement target git_status must remain registered"
    );
    for operation in ROUTE_OPERATIONS {
        assert!(
            registry.contains(operation),
            "registry missing dynamic route operation {operation}"
        );
        assert!(
            dispatch.contains(&format!("\"{operation}\"")),
            "dispatch missing dynamic route operation {operation}"
        );
    }
}

#[test]
fn dynamic_replacement_resources_are_durable_route_records() {
    let route = read_repo_file(ROUTE_PATH);
    let definitions = read_repo_file(RESOURCE_DEFINITIONS_PATH);

    for kind in ROUTE_RESOURCE_KINDS {
        assert!(
            route.contains(kind) || definitions.contains(kind),
            "route resource kind missing from route implementation or definitions: {kind}"
        );
        assert!(
            definitions.contains(&format!("tron.{kind}.v1")),
            "route resource schema id missing for {kind}"
        );
    }
}

#[test]
fn dynamic_replacement_git_status_seam_is_scoped_and_honest() {
    let git = read_repo_file(GIT_OPERATION_PATH);
    let route = read_repo_file(ROUTE_PATH);
    let validation = read_repo_file(VALIDATION_PATH);

    for required in ["active_route_for_git_status", "execute_routed_git_status"] {
        assert!(
            git.contains(required),
            "git_status operation must call route seam marker {required}"
        );
    }

    for required in [
        "const TARGET_OPERATION: &str = \"git_status\"",
        "moduleAdapterInvoked\": true",
        "supervised_runtime_projection",
        "builtInProjectionUsed",
        "active_route_module_adapter_projection",
        "active_route_failed_closed",
        "rollbackAvailable",
        "route_has_terminal_event",
        "ensure_capability_shadow_trial_evidence",
        "shadowEvidenceRef requires versionId",
        "capability route requires accepted shadow trial evidence",
        "capability route requires equivalent shadow trial evidence",
        "capability route authority requires resource-scoped exact selectors",
        "active route is missing route binding version ref",
        "stale capability route binding version",
        "active route binding is missing candidate version ref",
        "stale capability replacement candidate version",
    ] {
        assert!(
            route.contains(required),
            "route implementation missing fail-closed/honesty marker {required}"
        );
    }

    for required in [
        "replacementTarget mismatch for",
        "capability binding policy rejects agent_state inheritance",
        "capability binding policy rejects agent_state resourceKinds",
        "capability binding policy rejects wildcard resource selectors",
    ] {
        assert!(
            validation.contains(required),
            "binding validation missing route-safety marker {required}"
        );
    }

    let module_runtime = read_repo_file("packages/agent/src/domains/module_runtime/service.rs");
    for required in [
        "project_provider_safe_adapter_output",
        "module runtime adapter projection rejected stale lifecycle ref",
        "module runtime adapter projection rejected stale runtime ref",
        "module runtime adapter projection rejected mismatched lifecycle authorization",
        "supervisorEnvelopeOnly",
        "networkPolicy",
    ] {
        assert!(
            module_runtime.contains(required),
            "module runtime adapter projection missing safety marker {required}"
        );
    }
}

#[test]
fn dynamic_replacement_governance_operations_are_not_themselves_replaceable() {
    let registry = read_repo_file(REGISTRY_PATH);
    let modularity_inventory =
        read_repo_file("packages/agent/docs/capability-modularity-inventory.tsv");

    for operation in ROUTE_OPERATIONS {
        let row = modularity_inventory
            .lines()
            .find(|line| line.starts_with(operation))
            .unwrap_or_else(|| panic!("modularity inventory missing {operation}"));
        assert!(
            row.contains("\tcapability_binding\t"),
            "{operation} must stay in capability_binding family"
        );
        assert!(
            row.contains("\tgovernance_locked\t"),
            "{operation} must stay governance_locked"
        );
    }
    assert!(
        registry.contains("\"governance_locked\""),
        "operation metadata must continue to expose governance_locked class"
    );
}
