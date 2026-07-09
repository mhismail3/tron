//! Capability-pool classification shared by discovery, cockpit projections, and
//! scorecard drift tests.
//!
//! `capability::execute` operations and engine catalog functions are different
//! surfaces over the same engine fabric. This module keeps that distinction
//! explicit so agents can find session-useful operations by default, inspect
//! internal substrate when needed, and understand which parts can evolve by
//! runtime routing, producer extension, or source-level kernel evolution.
//! The model-facing projection is agent-first: it advertises exact invocation
//! payloads, authority selectors, and read-only-vs-write effect contracts before
//! any UI-oriented wording.

use std::borrow::Cow;

use serde::Serialize;
use serde_json::{Value, json};

use super::operation_binding_metadata;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CapabilityPoolSurface {
    AgentOperation,
    CatalogFunction,
}

impl CapabilityPoolSurface {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::AgentOperation => "agent_operation",
            Self::CatalogFunction => "catalog_function",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CapabilityPoolAudience {
    SessionWork,
    AgentDiagnostics,
    Governance,
    EngineInternal,
    KernelEvolution,
}

impl CapabilityPoolAudience {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::SessionWork => "session_work",
            Self::AgentDiagnostics => "agent_diagnostics",
            Self::Governance => "governance",
            Self::EngineInternal => "engine_internal",
            Self::KernelEvolution => "kernel_evolution",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CapabilityPoolReplacementClass {
    RuntimeRoutable,
    ProducerExtensible,
    KernelEvolutionOnly,
}

impl CapabilityPoolReplacementClass {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::RuntimeRoutable => "runtime_routable",
            Self::ProducerExtensible => "producer_extensible",
            Self::KernelEvolutionOnly => "kernel_evolution_only",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CapabilityPoolVisibility {
    DefaultVisible,
    SearchVisible,
    InspectOnly,
    HiddenUnlessEvolutionMode,
}

impl CapabilityPoolVisibility {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::DefaultVisible => "default_visible",
            Self::SearchVisible => "search_visible",
            Self::InspectOnly => "inspect_only",
            Self::HiddenUnlessEvolutionMode => "hidden_unless_evolution_mode",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CapabilityPoolMinimalityDecision {
    KeepCore,
    KeepGovernance,
    ModuleCandidate,
}

impl CapabilityPoolMinimalityDecision {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::KeepCore => "keep_core",
            Self::KeepGovernance => "keep_governance",
            Self::ModuleCandidate => "module_candidate",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CapabilityPoolMetadata<'a> {
    pub(crate) id: Cow<'a, str>,
    pub(crate) surface: CapabilityPoolSurface,
    pub(crate) family: Cow<'a, str>,
    pub(crate) owner: Cow<'a, str>,
    pub(crate) audience: CapabilityPoolAudience,
    pub(crate) replacement_class: CapabilityPoolReplacementClass,
    pub(crate) agent_default_visibility: CapabilityPoolVisibility,
    pub(crate) purpose: &'static str,
    pub(crate) effect: &'static str,
    pub(crate) risk: &'static str,
    pub(crate) authority_boundary: &'static str,
    pub(crate) evidence_boundary: &'static str,
    pub(crate) minimality_decision: CapabilityPoolMinimalityDecision,
    pub(crate) evolution_path: &'static str,
    pub(crate) next_action: &'static str,
}

impl<'a> CapabilityPoolMetadata<'a> {
    pub(crate) fn provider_projection(&self) -> CapabilityPoolProjection<'a> {
        CapabilityPoolProjection {
            id: self.id.clone(),
            surface: self.surface.as_str(),
            family: self.family.clone(),
            owner: self.owner.clone(),
            audience: self.audience.as_str(),
            replacement_class: self.replacement_class.as_str(),
            agent_default_visibility: self.agent_default_visibility.as_str(),
            purpose: self.purpose,
            effect: self.effect,
            risk: self.risk,
            authority_boundary: self.authority_boundary,
            evidence_boundary: self.evidence_boundary,
            minimality_decision: self.minimality_decision.as_str(),
            evolution_path: self.evolution_path,
            next_action: self.next_action,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CapabilityPoolProjection<'a> {
    id: Cow<'a, str>,
    surface: &'static str,
    family: Cow<'a, str>,
    owner: Cow<'a, str>,
    audience: &'static str,
    replacement_class: &'static str,
    agent_default_visibility: &'static str,
    purpose: &'static str,
    effect: &'static str,
    risk: &'static str,
    authority_boundary: &'static str,
    evidence_boundary: &'static str,
    minimality_decision: &'static str,
    evolution_path: &'static str,
    next_action: &'static str,
}

pub(crate) fn operation_pool_metadata(operation: &str) -> Option<CapabilityPoolMetadata<'static>> {
    let binding = operation_binding_metadata(operation)?;
    let (audience, visibility) =
        operation_audience_and_visibility(binding.family, binding.ownership_class);
    let replacement_class = replacement_class_for_ownership(binding.ownership_class);
    let minimality_decision = minimality_for_operation(binding.ownership_class);
    let purpose = purpose_for_operation_family(binding.family);
    let authority_boundary = authority_boundary_for_ownership(binding.ownership_class);
    let evidence_boundary = evidence_boundary_for_ownership(binding.ownership_class);
    let evolution_path = evolution_path_for_class(replacement_class);
    let next_action = next_action_for_ownership(binding.ownership_class);
    Some(CapabilityPoolMetadata {
        id: Cow::Borrowed(binding.operation),
        surface: CapabilityPoolSurface::AgentOperation,
        family: Cow::Borrowed(binding.family),
        owner: Cow::Borrowed(binding.current_owner),
        audience,
        replacement_class,
        agent_default_visibility: visibility,
        purpose,
        effect: "execute_contract",
        risk: "execute_contract",
        authority_boundary,
        evidence_boundary,
        minimality_decision,
        evolution_path,
        next_action,
    })
}

pub(crate) fn operation_agent_usage_projection(operation: &str) -> Option<Value> {
    let binding = operation_binding_metadata(operation)?;
    Some(json!({
        "callable": true,
        "tool": "capability::execute",
        "operation": binding.operation,
        "arguments": {"operation": binding.operation},
        "audience": operation_pool_metadata(binding.operation)
            .map(|metadata| metadata.audience.as_str())
            .unwrap_or("session_work"),
        "defaultUse": default_use_for_operation(binding.operation, binding.family, binding.ownership_class),
        "effect": operation_effect_projection(binding.operation, binding.family, binding.ownership_class),
        "preflight": preflight_guidance_for_operation(binding.operation, binding.family, binding.ownership_class),
        "failureRecovery": failure_recovery_for_operation(binding.family, binding.ownership_class),
    }))
}

pub(crate) fn catalog_function_agent_usage_projection(
    id: &str,
    callable_operation: Option<&str>,
) -> Value {
    match callable_operation {
        Some(operation) => operation_agent_usage_projection(operation).unwrap_or_else(|| {
            json!({
                "callable": false,
                "defaultUse": "inspect_only",
                "catalogInspectId": id,
                "reason": "No supported capability::execute operation is registered for this catalog function."
            })
        }),
        None => json!({
            "callable": false,
            "defaultUse": "inspect_only",
            "catalogInspectId": id,
            "reason": "This is engine catalog substrate. Inspect it for diagnostics or kernel-evolution context, then use a supported capability::execute operation for session work."
        }),
    }
}

pub(crate) fn catalog_function_pool_metadata(id: &str) -> Option<CapabilityPoolMetadata<'_>> {
    let namespace = id.split_once("::")?.0;
    let family = catalog_family(namespace);
    let owner = catalog_owner(namespace);
    let audience = catalog_audience(namespace);
    let replacement_class = catalog_replacement_class(namespace);
    let visibility = catalog_visibility(namespace, id);
    let minimality_decision = catalog_minimality(namespace);
    let purpose = catalog_purpose(namespace);
    let authority_boundary = catalog_authority_boundary(namespace);
    let evidence_boundary = catalog_evidence_boundary(namespace);
    let evolution_path = evolution_path_for_class(replacement_class);
    Some(CapabilityPoolMetadata {
        id: Cow::Borrowed(id),
        surface: CapabilityPoolSurface::CatalogFunction,
        family,
        owner,
        audience,
        replacement_class,
        agent_default_visibility: visibility,
        purpose,
        effect: "catalog_function_contract",
        risk: "catalog_function_contract",
        authority_boundary,
        evidence_boundary,
        minimality_decision,
        evolution_path,
        next_action: "none",
    })
}

fn operation_audience_and_visibility(
    family: &str,
    ownership_class: &str,
) -> (CapabilityPoolAudience, CapabilityPoolVisibility) {
    match ownership_class {
        "adapter_replaceable" | "record_plane" | "module_owned" => (
            CapabilityPoolAudience::SessionWork,
            CapabilityPoolVisibility::DefaultVisible,
        ),
        "governance_locked" => (
            CapabilityPoolAudience::Governance,
            CapabilityPoolVisibility::SearchVisible,
        ),
        "kernel_locked" if matches!(family, "trace" | "logs" | "catalog_discovery" | "core") => (
            CapabilityPoolAudience::AgentDiagnostics,
            CapabilityPoolVisibility::SearchVisible,
        ),
        "kernel_locked" => (
            CapabilityPoolAudience::KernelEvolution,
            CapabilityPoolVisibility::InspectOnly,
        ),
        _ => (
            CapabilityPoolAudience::KernelEvolution,
            CapabilityPoolVisibility::InspectOnly,
        ),
    }
}

fn replacement_class_for_ownership(class: &str) -> CapabilityPoolReplacementClass {
    match class {
        "adapter_replaceable" | "module_owned" => CapabilityPoolReplacementClass::RuntimeRoutable,
        "record_plane" => CapabilityPoolReplacementClass::ProducerExtensible,
        _ => CapabilityPoolReplacementClass::KernelEvolutionOnly,
    }
}

fn minimality_for_operation(class: &str) -> CapabilityPoolMinimalityDecision {
    match class {
        "adapter_replaceable" | "module_owned" => CapabilityPoolMinimalityDecision::ModuleCandidate,
        "record_plane" => CapabilityPoolMinimalityDecision::KeepCore,
        "governance_locked" => CapabilityPoolMinimalityDecision::KeepGovernance,
        _ => CapabilityPoolMinimalityDecision::KeepCore,
    }
}

fn purpose_for_operation_family(family: &str) -> &'static str {
    match family {
        "catalog_discovery" => "agent_inspects_capability_catalog",
        "capability_binding" => "agent_governs_future_capability_replacement",
        "context_control" => "agent_and_user_manage_provider_context_boundaries",
        "git" => "agent_inspects_or_changes_scoped_git_state_by_operation_effect",
        "filesystem" => "agent_reads_and_updates_scoped_filesystem_state",
        "jobs" => "agent_runs_and_observes_bounded_local_work",
        "module_runtime" | "module_lifecycle" | "module_program_execution" => {
            "agent_supervises_governed_module_work"
        }
        "web" | "web_research" => "agent_collects_web_source_evidence",
        _ => "agent_invokes_named_capability_operation",
    }
}

fn authority_boundary_for_ownership(class: &str) -> &'static str {
    match class {
        "adapter_replaceable" => "exact_operation_selectors_plus_route_authority",
        "module_owned" => "module_lifecycle_runtime_and_exact_resource_selectors",
        "record_plane" => "server_owned_resource_custody_and_exact_selectors",
        "governance_locked" => "server_owned_governance_policy_and_exact_selectors",
        _ => "engine_owned_kernel_authority",
    }
}

fn evidence_boundary_for_ownership(class: &str) -> &'static str {
    match class {
        "adapter_replaceable" => "shadow_activation_route_event_and_rollback_evidence_required",
        "module_owned" => "module_runtime_lifecycle_trace_and_rollback_evidence_required",
        "record_plane" => "durable_resource_trace_and_provider_safe_projection_required",
        "governance_locked" => "durable_governance_records_and_audit_refs_required",
        _ => "engine_trace_replay_catalog_or_source_review_evidence_required",
    }
}

fn evolution_path_for_class(class: CapabilityPoolReplacementClass) -> &'static str {
    match class {
        CapabilityPoolReplacementClass::RuntimeRoutable => {
            "candidate_validation_shadow_approval_activation_route_event_rollback"
        }
        CapabilityPoolReplacementClass::ProducerExtensible => {
            "module_producer_may_extend_records_without_bypassing_custody"
        }
        CapabilityPoolReplacementClass::KernelEvolutionOnly => {
            "source_candidate_validation_adversarial_review_user_approved_integration"
        }
    }
}

fn next_action_for_ownership(class: &str) -> &'static str {
    match class {
        "adapter_replaceable" => "prove_next_runtime_route_before_expanding_targets",
        "record_plane" => "keep_producer_extensions_inside_resource_custody",
        "module_owned" => "use_as_template_for_governed_module_version_replacement",
        "governance_locked" => "preserve_as_replacement_trust_pipeline",
        _ => "source_level_evolution_only",
    }
}

fn default_use_for_operation(operation: &str, family: &str, ownership_class: &str) -> &'static str {
    if !operation_is_read_only_safe(operation) {
        return match ownership_class {
            "governance_locked" => "governed_write_after_evidence_and_approval",
            "record_plane" => "record_after_evidence_and_idempotency",
            "adapter_replaceable" | "module_owned" => {
                "perform_work_only_when_user_task_requires_effect"
            }
            _ => "effectful_operation_not_for_read_only_inspection",
        };
    }
    match ownership_class {
        "kernel_locked" if matches!(family, "catalog_discovery" | "trace" | "logs" | "core") => {
            "diagnose_or_verify"
        }
        "kernel_locked" => "kernel_evolution_inspection",
        "governance_locked" => "governed_record_or_inspection",
        "record_plane" => "record_or_inspect_custody",
        "adapter_replaceable" => "perform_session_work",
        "module_owned" => "perform_governed_module_work",
        _ => "inspect_before_use",
    }
}

fn operation_effect_projection(operation: &str, family: &str, ownership_class: &str) -> Value {
    let read_only = operation_is_read_only_safe(operation);
    let mode = if read_only {
        "read_only"
    } else if operation_starts_work(operation) {
        "starts_work"
    } else if operation_writes_metadata(operation) {
        "metadata_write"
    } else {
        "state_change"
    };
    json!({
        "mode": mode,
        "readOnlyInspectionSafe": read_only,
        "mutatesState": !read_only,
        "writesResource": !read_only && (operation_writes_metadata(operation) || matches!(ownership_class, "record_plane" | "governance_locked")),
        "startsWork": operation_starts_work(operation),
        "readOnlyInstruction": if read_only {
            "safe to call during read-only inspection"
        } else {
            "do not call during read-only inspection; inspect schema/catalog/list operations instead"
        },
        "requiresPriorEvidence": !read_only && matches!(ownership_class, "record_plane" | "governance_locked"),
        "family": family
    })
}

fn operation_is_read_only_safe(operation: &str) -> bool {
    matches!(
        operation,
        "observe"
            | "state_get"
            | "state_list"
            | "filesystem_read"
            | "filesystem_list"
            | "filesystem_find"
            | "filesystem_glob"
            | "filesystem_search_text"
            | "filesystem_diff"
            | "git_status"
            | "git_diff"
            | "git_branch_inventory"
            | "job_status"
            | "job_list"
            | "job_log"
            | "trace_list"
            | "trace_get"
            | "log_recent"
            | "replay_manifest"
            | "catalog_search"
            | "catalog_inspect"
            | "memory_status"
            | "memory_list"
            | "memory_inspect"
            | "memory_query_list"
            | "memory_query_inspect"
            | "memory_decision_list"
            | "memory_decision_inspect"
            | "context_control_action_list"
            | "context_control_action_inspect"
            | "context_survivor_list"
            | "context_exclusion_list"
            | "subagent_status"
            | "subagent_result"
            | "subagent_task_list"
            | "subagent_task_inspect"
            | "capability_binding_cockpit_overview"
    ) || operation.ends_with("_list")
        || operation.ends_with("_inspect")
        || operation.ends_with("_status")
}

fn operation_writes_metadata(operation: &str) -> bool {
    operation.ends_with("_record")
        || matches!(
            operation,
            "state_set"
                | "catalog_conformance"
                | "context_control_snapshot"
                | "context_control_compact"
                | "context_control_clear"
                | "context_policy_snapshot"
                | "context_survivor_disable"
                | "context_exclusion_disable"
                | "media_create"
                | "media_archive"
                | "module_lifecycle_request"
                | "module_lifecycle_decision"
                | "module_runtime_cancel"
                | "module_dependency_policy_activate"
                | "capability_binding_policy_activate"
                | "capability_route_activate"
                | "capability_route_disable"
                | "capability_route_rollback"
                | "procedural_definition_record"
                | "procedural_activation_request_record"
                | "procedural_activation_decision_record"
        )
}

fn operation_starts_work(operation: &str) -> bool {
    matches!(
        operation,
        "process_run"
            | "job_start"
            | "subagent_launch"
            | "module_runtime_request"
            | "module_program_execution_start"
            | "schedule_fire_due"
    )
}

fn preflight_guidance_for_operation(operation: &str, family: &str, ownership_class: &str) -> Value {
    if operation == "capability_shadow_trial_request_record" {
        return json!({
            "authorityScopes": [
                "capability_binding.read",
                "capability_binding.write",
                "resource.read",
                "resource.write"
            ],
            "resourceSelectors": [
                "kind:capability_shadow_trial_request",
                "kind:capability_shadow_trial_decision",
                "kind:capability_shadow_trial_run",
                "kind:capability_shadow_trial_evidence"
            ],
            "networkPolicy": "none",
            "agentStateInherited": false,
            "requiredPayloadFields": [
                "operation",
                "title",
                "targetOperation",
                "ownershipClass",
                "bindingMode",
                "candidateAdapter",
                "authorityConstraints",
                "contractEvidenceRefs",
                "evidenceRefs",
                "staleVersionGuard",
                "rollbackRef",
                "disableRef",
                "abortRef",
                "rationale",
                "idempotencyKey"
            ],
            "example": {
                "operation": "capability_shadow_trial_request_record",
                "targetOperation": "git_status",
                "bindingMode": "shadow",
                "candidateAdapter": {
                    "adapterId": "candidate_git_status_adapter",
                    "adapterVersion": "metadata-v1",
                    "executionMode": "metadata_only",
                    "networkPolicy": "none"
                }
            },
            "readOnlyInstruction": "Do not call during read-only inspection; this records durable shadow-trial request metadata.",
            "beforeCalling": "Inspect capability_binding_cockpit_overview or catalog_inspect for git_status, copy the server-owned owner/class metadata exactly, inspect the operation schema for exact field names, and provide bounded evidence refs only."
        });
    }

    if operation.starts_with("capability_binding_")
        || operation.starts_with("capability_shadow_trial_")
        || operation.starts_with("capability_replacement_")
        || operation.starts_with("capability_route_")
    {
        let write = operation.ends_with("_record")
            || operation.ends_with("_activate")
            || operation.ends_with("_disable")
            || operation.ends_with("_rollback");
        let mut scopes = vec!["capability_binding.read", "resource.read"];
        if write {
            scopes.extend(["capability_binding.write", "resource.write"]);
        }
        return json!({
            "authorityScopes": scopes,
            "resourceSelectors": capability_binding_kind_selectors_for_operation(operation),
            "networkPolicy": "none",
            "agentStateInherited": false,
            "readOnlyInstruction": if operation_is_read_only_safe(operation) {
                "safe to call during read-only inspection"
            } else {
                "do not call during read-only inspection; use list/inspect/search/overview operations instead"
            },
            "beforeCalling": "Use exact kind/resource selectors. Do not use wildcard selectors, opaque authority tokens, local paths, commands, logs, or code bodies."
        });
    }

    if family == "context_control" {
        let write = !operation_is_read_only_safe(operation);
        let mut scopes = vec!["context_control.read", "resource.read"];
        if write {
            scopes.extend(["context_control.write", "resource.write"]);
        }
        return json!({
            "authorityScopes": scopes,
            "resourceSelectors": [
                "kind:context_control_snapshot",
                "kind:context_control_action",
                "kind:context_control_epoch",
                "kind:context_survivor",
                "kind:context_exclusion",
                "kind:context_policy_snapshot"
            ],
            "networkPolicy": "none",
            "agentStateInherited": false,
            "readOnlyInstruction": if write {
                "do not call during read-only inspection; use context_control_status, list, or inspect operations instead"
            } else {
                "safe to call during read-only current-session context inspection"
            },
            "beforeCalling": "Use the trusted current session, exact sessionId when supplied, and provider-safe refs only. Do not use wildcard selectors, raw prompt bodies, hidden system/soul prompt text, local paths, commands, logs, grants, authority ids, or hidden chain-of-thought."
        });
    }

    if operation_is_read_only_safe(operation) && ownership_class == "adapter_replaceable" {
        return json!({
            "authority": "derived_read_only_adapter_authority_for_exact_operation",
            "networkPolicy": if matches!(family, "web") { "declared_by_operation" } else { "none" },
            "agentStateInherited": false,
            "requiredPayloadFields": ["operation"],
            "readOnlyInstruction": "safe to call during read-only session work after inspecting the execute::<operation> schema when field names are unclear",
            "beforeCalling": "Use the exact operation selector and operation-specific top-level fields only. Do not request replacement, route, shadow, binding, or rollback authority unless the user task is explicitly about replacing this operation."
        });
    }

    json!({
        "authority": authority_boundary_for_ownership(ownership_class),
        "evidence": evidence_boundary_for_ownership(ownership_class),
        "networkPolicy": if matches!(family, "web") { "declared_by_operation" } else { "none_unless_schema_requires_otherwise" },
        "beforeCalling": "Put operation-specific fields at the top level of the capability::execute payload and inspect the operation schema when required fields are unclear."
    })
}

fn capability_binding_kind_selectors_for_operation(operation: &str) -> Vec<&'static str> {
    if operation.starts_with("capability_shadow_trial_") {
        return vec![
            "kind:capability_shadow_trial_request",
            "kind:capability_shadow_trial_decision",
            "kind:capability_shadow_trial_run",
            "kind:capability_shadow_trial_evidence",
        ];
    }
    if operation.starts_with("capability_route_")
        || operation.starts_with("capability_replacement_")
    {
        return vec![
            "kind:capability_replacement_candidate",
            "kind:capability_route_binding",
            "kind:capability_route_activation",
            "kind:capability_route_event",
            "kind:capability_route_rollback",
        ];
    }
    match operation {
        "capability_binding_request_record"
        | "capability_binding_request_list"
        | "capability_binding_request_inspect" => return vec!["kind:capability_binding_request"],
        "capability_binding_decision_record" => {
            return vec![
                "kind:capability_binding_request",
                "kind:capability_binding_decision",
            ];
        }
        "capability_binding_decision_list" | "capability_binding_decision_inspect" => {
            return vec!["kind:capability_binding_decision"];
        }
        "capability_binding_policy_activate" => {
            return vec![
                "kind:capability_binding_decision",
                "kind:capability_binding_policy",
            ];
        }
        "capability_binding_policy_list" | "capability_binding_policy_inspect" => {
            return vec!["kind:capability_binding_policy"];
        }
        _ => {}
    }
    vec![
        "kind:capability_binding_request",
        "kind:capability_binding_decision",
        "kind:capability_binding_policy",
    ]
}

fn failure_recovery_for_operation(family: &str, ownership_class: &str) -> &'static str {
    match (family, ownership_class) {
        ("capability_binding", _) => {
            "Inspect cockpit overview and the relevant binding/shadow/route list before retrying with exact selectors and expected versions."
        }
        (_, "governance_locked") => {
            "List or inspect the governing records first, then retry with exact resource selectors and stale-version guards."
        }
        (_, "record_plane") => {
            "List or inspect durable records first, then retry with exact refs, stable idempotency keys, and bounded evidence."
        }
        (_, "adapter_replaceable") => {
            "Inspect schema, authority requirements, and recent trace evidence before retrying the adapter operation."
        }
        _ => "Use catalog_inspect or trace/log operations to diagnose before retrying.",
    }
}

fn catalog_family(namespace: &str) -> Cow<'_, str> {
    match namespace {
        "capability" => Cow::Borrowed("capability_execute"),
        "agent" => Cow::Borrowed("agent_runtime"),
        "engine" => Cow::Borrowed("engine_transport"),
        "catalog" | "catalog_discovery" => Cow::Borrowed("catalog_discovery"),
        "resource" | "artifact" | "goal" | "claim" | "evidence" | "decision"
        | "materialized_file" | "patch" => Cow::Borrowed("resource_kernel"),
        "grant" => Cow::Borrowed("authority_kernel"),
        "queue" => Cow::Borrowed("queue_kernel"),
        "stream" => Cow::Borrowed("stream_kernel"),
        "state" => Cow::Borrowed("state_kernel"),
        "trigger" => Cow::Borrowed("trigger_kernel"),
        "worker" | "worker_lifecycle" => Cow::Borrowed("worker_governance"),
        "storage" => Cow::Borrowed("storage_kernel"),
        "system" => Cow::Borrowed("system_kernel"),
        "logs" => Cow::Borrowed("logs"),
        "transcription" => Cow::Borrowed("transcription"),
        "ui" => Cow::Borrowed("generated_ui_kernel"),
        other => Cow::Borrowed(other),
    }
}

fn catalog_owner(namespace: &str) -> Cow<'_, str> {
    match namespace {
        "resource" | "artifact" | "goal" | "claim" | "evidence" | "decision"
        | "materialized_file" | "patch" => Cow::Borrowed("engine::primitives::resource"),
        "grant" => Cow::Borrowed("engine::primitives::grant"),
        "catalog" => Cow::Borrowed("engine::primitives::catalog"),
        "queue" => Cow::Borrowed("engine::primitives::queue"),
        "stream" => Cow::Borrowed("engine::primitives::stream"),
        "state" => Cow::Borrowed("engine::primitives::state"),
        "trigger" => Cow::Borrowed("engine::primitives::trigger"),
        "worker" => Cow::Borrowed("engine::primitives::worker"),
        "storage" => Cow::Borrowed("engine::primitives::storage"),
        "ui" => Cow::Borrowed("engine::primitives::ui"),
        "engine" => Cow::Borrowed("engine::invocation::host"),
        "system" => Cow::Borrowed("domains::system"),
        other => Cow::Owned(format!("domains::{other}")),
    }
}

fn catalog_audience(namespace: &str) -> CapabilityPoolAudience {
    match namespace {
        "capability" => CapabilityPoolAudience::SessionWork,
        "catalog" | "catalog_discovery" | "logs" | "trace" | "worker" | "storage" | "system" => {
            CapabilityPoolAudience::AgentDiagnostics
        }
        "approval"
        | "auth"
        | "module_registry"
        | "module_authoring"
        | "module_validation"
        | "module_install"
        | "module_dependencies"
        | "capability_binding"
        | "module_lifecycle"
        | "module_runtime"
        | "worker_lifecycle"
        | "tool_sources"
        | "procedural" => CapabilityPoolAudience::Governance,
        "resource" | "artifact" | "goal" | "claim" | "evidence" | "decision"
        | "materialized_file" | "patch" | "grant" | "queue" | "stream" | "state" | "trigger"
        | "ui" | "engine" | "agent" => CapabilityPoolAudience::EngineInternal,
        _ => CapabilityPoolAudience::EngineInternal,
    }
}

fn catalog_replacement_class(namespace: &str) -> CapabilityPoolReplacementClass {
    match namespace {
        "filesystem" | "git" | "jobs" | "web" | "subagents" => {
            CapabilityPoolReplacementClass::RuntimeRoutable
        }
        "context_control" | "memory" | "media" | "import_history" | "repository_tree"
        | "import_preview" | "program_execution" | "prompt_artifacts" | "update_diagnostics"
        | "device" | "notifications" | "scheduler" | "agent_briefing" | "module_activity"
        | "web_research" | "message" | "session" | "model" | "settings" | "blob"
        | "transcription" => CapabilityPoolReplacementClass::ProducerExtensible,
        _ => CapabilityPoolReplacementClass::KernelEvolutionOnly,
    }
}

fn catalog_visibility(namespace: &str, id: &str) -> CapabilityPoolVisibility {
    if id == "capability::execute" {
        return CapabilityPoolVisibility::SearchVisible;
    }
    match namespace {
        "catalog_discovery" | "logs" => CapabilityPoolVisibility::SearchVisible,
        "catalog" | "worker" | "storage" | "system" => CapabilityPoolVisibility::InspectOnly,
        "resource" | "artifact" | "goal" | "claim" | "evidence" | "decision"
        | "materialized_file" | "patch" | "grant" | "queue" | "stream" | "state" | "trigger"
        | "ui" | "engine" | "agent" => CapabilityPoolVisibility::HiddenUnlessEvolutionMode,
        _ => CapabilityPoolVisibility::InspectOnly,
    }
}

fn catalog_minimality(namespace: &str) -> CapabilityPoolMinimalityDecision {
    match catalog_replacement_class(namespace) {
        CapabilityPoolReplacementClass::RuntimeRoutable => {
            CapabilityPoolMinimalityDecision::ModuleCandidate
        }
        CapabilityPoolReplacementClass::ProducerExtensible => {
            CapabilityPoolMinimalityDecision::KeepCore
        }
        CapabilityPoolReplacementClass::KernelEvolutionOnly => match catalog_audience(namespace) {
            CapabilityPoolAudience::Governance => CapabilityPoolMinimalityDecision::KeepGovernance,
            _ => CapabilityPoolMinimalityDecision::KeepCore,
        },
    }
}

fn catalog_purpose(namespace: &str) -> &'static str {
    match namespace {
        "capability" => "single_model_facing_execute_bridge",
        "catalog" | "catalog_discovery" => "engine_catalog_inspection_and_freshness",
        "worker" | "worker_lifecycle" => "worker_registration_lifecycle_and_health",
        "resource" | "artifact" | "goal" | "claim" | "evidence" | "decision"
        | "materialized_file" | "patch" => "typed_resource_custody_substrate",
        "grant" => "engine_authority_grant_substrate",
        "queue" => "durable_queue_delivery_substrate",
        "stream" => "engine_stream_delivery_substrate",
        "state" => "scoped_engine_state_substrate",
        "trigger" => "trigger_dispatch_substrate",
        "storage" => "engine_storage_maintenance_substrate",
        "system" => "system_info_and_shutdown_substrate",
        "engine" => "authenticated_engine_transport_substrate",
        "agent" => "server_owned_agent_loop_runtime",
        "logs" => "filtered_log_ingest_and_recent_log_substrate",
        "transcription" => "local_transcription_input_substrate",
        "ui" => "generated_ui_resource_substrate",
        _ => "domain_catalog_function_backing_engine_or_client_workflow",
    }
}

fn catalog_authority_boundary(namespace: &str) -> &'static str {
    match namespace {
        "resource" | "artifact" | "goal" | "claim" | "evidence" | "decision"
        | "materialized_file" | "patch" => "resource_kernel_scopes_only",
        "grant" => "engine_owned_authority_scopes_only",
        "catalog" | "catalog_discovery" => "catalog_read_or_catalog_report_scopes_only",
        "worker" | "worker_lifecycle" => "worker_lifecycle_governance_scopes_only",
        "engine" => "authenticated_engine_transport_scopes_only",
        "agent" => "server_owned_agent_runtime_scopes_only",
        "capability" => "derived_execute_child_grants_only",
        _ => "domain_contract_authority_scopes_only",
    }
}

fn catalog_evidence_boundary(namespace: &str) -> &'static str {
    match catalog_replacement_class(namespace) {
        CapabilityPoolReplacementClass::RuntimeRoutable => {
            "operation_route_shadow_and_trace_evidence_required"
        }
        CapabilityPoolReplacementClass::ProducerExtensible => {
            "resource_trace_projection_and_custody_evidence_required"
        }
        CapabilityPoolReplacementClass::KernelEvolutionOnly => {
            "source_review_catalog_trace_or_kernel_audit_evidence_required"
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};

    use crate::domains::capability::supported_operation_names;
    use crate::engine::{ActorContext, ActorId, ActorKind, AuthorityGrantId, FunctionQuery};
    use crate::shared::server::test_support::make_test_context;

    use super::*;

    #[derive(Debug)]
    struct InventoryRow<'a> {
        id: &'a str,
        surface: &'a str,
        audience: &'a str,
        replacement_class: &'a str,
        visibility: &'a str,
        minimality: &'a str,
        evolution_path: &'a str,
        next_action: &'a str,
    }

    fn inventory_rows() -> Vec<InventoryRow<'static>> {
        include_str!("../../../docs/engine-capability-pool-inventory.tsv")
            .lines()
            .skip(1)
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                let columns: Vec<_> = line.split('\t').collect();
                assert_eq!(columns.len(), 16, "inventory row shape changed: {line}");
                InventoryRow {
                    id: columns[0],
                    surface: columns[1],
                    audience: columns[4],
                    replacement_class: columns[5],
                    visibility: columns[6],
                    minimality: columns[12],
                    evolution_path: columns[13],
                    next_action: columns[14],
                }
            })
            .collect()
    }

    #[test]
    fn operation_pool_metadata_covers_supported_operations() {
        for operation in supported_operation_names() {
            let metadata = operation_pool_metadata(operation)
                .unwrap_or_else(|| panic!("missing operation pool metadata for {operation}"));
            assert_eq!(metadata.id.as_ref(), *operation);
            assert_eq!(metadata.surface, CapabilityPoolSurface::AgentOperation);
            assert_ne!(
                metadata.agent_default_visibility,
                CapabilityPoolVisibility::HiddenUnlessEvolutionMode
            );
        }
    }

    #[test]
    fn catalog_function_pool_metadata_classifies_known_kernel_and_domain_functions() {
        for id in [
            "capability::execute",
            "catalog::watch_snapshot",
            "resource::create",
            "grant::derive",
            "git::status",
            "module_runtime::request",
            "catalog_discovery::search",
        ] {
            let metadata = catalog_function_pool_metadata(id)
                .unwrap_or_else(|| panic!("missing catalog function pool metadata for {id}"));
            assert_eq!(metadata.id.as_ref(), id);
            assert_eq!(metadata.surface, CapabilityPoolSurface::CatalogFunction);
        }
    }

    #[test]
    fn inventory_rows_are_unique_and_use_allowed_classes() {
        let rows = inventory_rows();
        let mut seen = BTreeSet::new();
        for row in rows {
            assert!(
                seen.insert((row.surface, row.id)),
                "duplicate capability-pool row for {} {}",
                row.surface,
                row.id
            );
            assert!(
                matches!(
                    row.replacement_class,
                    "runtime_routable" | "producer_extensible" | "kernel_evolution_only"
                ),
                "unsupported replacement class in {row:?}"
            );
            assert!(
                matches!(
                    row.visibility,
                    "default_visible"
                        | "search_visible"
                        | "inspect_only"
                        | "hidden_unless_evolution_mode"
                ),
                "unsupported visibility in {row:?}"
            );
        }
    }

    #[test]
    fn inventory_covers_every_supported_operation_once() {
        let rows = inventory_rows();
        let operation_rows = rows
            .iter()
            .filter(|row| row.surface == CapabilityPoolSurface::AgentOperation.as_str())
            .collect::<Vec<_>>();
        assert_eq!(operation_rows.len(), supported_operation_names().len());
        let row_ids = operation_rows
            .into_iter()
            .map(|row| row.id)
            .collect::<BTreeSet<_>>();
        for operation in supported_operation_names() {
            assert!(
                row_ids.contains(operation),
                "engine capability pool inventory missing agent operation {operation}"
            );
            let metadata = operation_pool_metadata(operation).expect("metadata");
            let row = rows
                .iter()
                .find(|row| {
                    row.surface == CapabilityPoolSurface::AgentOperation.as_str()
                        && row.id == *operation
                })
                .expect("operation row");
            assert_eq!(
                row.audience,
                metadata.audience.as_str(),
                "{operation} audience drifted"
            );
            assert_eq!(
                row.replacement_class,
                metadata.replacement_class.as_str(),
                "{operation} replacement class drifted"
            );
            assert_eq!(
                row.visibility,
                metadata.agent_default_visibility.as_str(),
                "{operation} visibility drifted"
            );
            assert_eq!(
                row.minimality,
                metadata.minimality_decision.as_str(),
                "{operation} minimality drifted"
            );
        }
    }

    #[tokio::test]
    async fn inventory_covers_startup_registered_catalog_functions_once() {
        let ctx = make_test_context();
        let mut query = FunctionQuery::default();
        query.include_internal = true;
        query.actor = Some(ActorContext::new(
            ActorId::new("capability-pool-audit").expect("actor id"),
            ActorKind::Admin,
            AuthorityGrantId::new("engine-transport").expect("grant id"),
        ));
        let functions = ctx.engine_host.discover(&query).await;
        let function_ids = functions
            .iter()
            .map(|function| function.id.as_str().to_owned())
            .collect::<BTreeSet<_>>();
        assert!(
            !function_ids.is_empty(),
            "test context must register catalog functions"
        );

        let rows = inventory_rows();
        let row_ids = rows
            .iter()
            .filter(|row| row.surface == CapabilityPoolSurface::CatalogFunction.as_str())
            .map(|row| row.id.to_owned())
            .collect::<BTreeSet<_>>();
        let missing = function_ids
            .difference(&row_ids)
            .cloned()
            .collect::<Vec<_>>();
        assert!(
            missing.is_empty(),
            "engine capability pool inventory missing catalog functions: {missing:?}"
        );
        let extras = row_ids
            .difference(&function_ids)
            .cloned()
            .collect::<Vec<_>>();
        assert!(
            extras.is_empty(),
            "engine capability pool inventory has stale catalog functions: {extras:?}"
        );

        let catalog_rows_by_id = rows
            .iter()
            .filter(|row| row.surface == CapabilityPoolSurface::CatalogFunction.as_str())
            .map(|row| (row.id, row))
            .collect::<BTreeMap<_, _>>();
        for id in function_ids {
            let metadata =
                catalog_function_pool_metadata(&id).expect("catalog function classification");
            let row = catalog_rows_by_id
                .get(id.as_str())
                .unwrap_or_else(|| panic!("missing row for catalog function {id}"));
            assert_eq!(
                row.audience,
                metadata.audience.as_str(),
                "{id} audience drifted"
            );
            assert_eq!(
                row.replacement_class,
                metadata.replacement_class.as_str(),
                "{id} replacement class drifted"
            );
            assert_eq!(
                row.visibility,
                metadata.agent_default_visibility.as_str(),
                "{id} visibility drifted"
            );
            assert_eq!(
                row.minimality,
                metadata.minimality_decision.as_str(),
                "{id} minimality drifted"
            );
        }
    }

    #[test]
    fn internal_catalog_functions_are_not_default_visible_session_actions() {
        for row in inventory_rows()
            .into_iter()
            .filter(|row| row.surface == CapabilityPoolSurface::CatalogFunction.as_str())
        {
            if row.id != "capability::execute" {
                assert_ne!(
                    row.visibility, "default_visible",
                    "catalog function {} must not masquerade as a normal session action",
                    row.id
                );
            }
        }
    }

    #[test]
    fn capability_binding_agent_usage_advertises_operation_specific_selectors() {
        for (operation, expected_selectors) in [
            (
                "capability_binding_request_list",
                vec!["kind:capability_binding_request"],
            ),
            (
                "capability_binding_decision_list",
                vec!["kind:capability_binding_decision"],
            ),
            (
                "capability_binding_policy_list",
                vec!["kind:capability_binding_policy"],
            ),
        ] {
            let usage = operation_agent_usage_projection(operation)
                .unwrap_or_else(|| panic!("missing usage projection for {operation}"));
            let selectors = usage["preflight"]["resourceSelectors"]
                .as_array()
                .expect("resource selectors")
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>();
            assert_eq!(
                selectors, expected_selectors,
                "{operation} selectors drifted"
            );
            assert_eq!(usage["preflight"]["networkPolicy"], "none");
            assert_eq!(usage["preflight"]["agentStateInherited"], false);
            let scopes = usage["preflight"]["authorityScopes"]
                .as_array()
                .expect("authority scopes")
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>();
            assert!(scopes.contains(&"capability_binding.read"));
            assert!(scopes.contains(&"resource.read"));
            assert!(!scopes.contains(&"capability_binding.write"));
            assert_eq!(usage["effect"]["readOnlyInspectionSafe"], true);
            assert_eq!(usage["effect"]["mutatesState"], false);
        }
    }

    #[test]
    fn read_only_adapter_preflight_does_not_require_replacement_route_authority() {
        let usage = operation_agent_usage_projection("git_status").expect("git_status usage");
        assert_eq!(usage["effect"]["readOnlyInspectionSafe"], true);
        assert_eq!(
            usage["preflight"]["authority"],
            "derived_read_only_adapter_authority_for_exact_operation"
        );
        assert_eq!(usage["preflight"]["networkPolicy"], "none");
        assert_eq!(usage["preflight"]["agentStateInherited"], false);
        assert_eq!(
            usage["preflight"]["requiredPayloadFields"],
            json!(["operation"])
        );
        let preflight = serde_json::to_string(&usage["preflight"]).expect("json");
        assert!(
            !preflight.contains("route_authority"),
            "plain read-only adapter preflight must not imply replacement route authority: {preflight}"
        );
        assert!(
            usage["preflight"]["beforeCalling"]
                .as_str()
                .expect("before calling")
                .contains("unless the user task is explicitly about replacing this operation")
        );
    }

    #[test]
    fn write_operations_advertise_not_safe_for_read_only_inspection() {
        for operation in [
            "capability_shadow_trial_request_record",
            "capability_replacement_candidate_record",
            "capability_route_activate",
            "catalog_conformance",
            "context_policy_snapshot",
            "git_commit",
            "process_run",
        ] {
            let usage = operation_agent_usage_projection(operation)
                .unwrap_or_else(|| panic!("missing usage projection for {operation}"));
            assert_eq!(
                usage["effect"]["readOnlyInspectionSafe"], false,
                "{operation} must not look read-only safe"
            );
            assert_eq!(usage["effect"]["mutatesState"], true);
            assert!(
                usage["effect"]["readOnlyInstruction"]
                    .as_str()
                    .expect("read-only instruction")
                    .contains("do not call during read-only inspection")
            );
            assert!(
                usage["defaultUse"]
                    .as_str()
                    .expect("default use")
                    .contains("inspection")
                    || usage["defaultUse"]
                        .as_str()
                        .expect("default use")
                        .contains("approval")
                    || usage["defaultUse"]
                        .as_str()
                        .expect("default use")
                        .contains("requires_effect")
                    || usage["defaultUse"]
                        .as_str()
                        .expect("default use")
                        .contains("evidence")
            );
        }
    }

    #[test]
    fn kernel_evolution_only_rows_are_not_default_visible_runtime_replacements() {
        for row in inventory_rows() {
            if row.replacement_class == "kernel_evolution_only" {
                assert_ne!(
                    row.visibility, "default_visible",
                    "kernel-evolution-only row {} {} must not be default-visible",
                    row.surface, row.id
                );
                assert_ne!(
                    row.minimality, "module_candidate",
                    "kernel-evolution-only row {} {} must not be a module candidate",
                    row.surface, row.id
                );
                assert_eq!(
                    row.evolution_path,
                    "source_candidate_validation_adversarial_review_user_approved_integration",
                    "kernel-evolution-only row {} {} must use the source-level evolution path",
                    row.surface,
                    row.id
                );
                assert!(
                    !row.next_action.contains("runtime_route")
                        && !row.next_action.contains("module_version"),
                    "kernel-evolution-only row {} {} must not imply runtime routing",
                    row.surface,
                    row.id
                );
            }
        }
    }
}
