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
//! any UI-oriented wording. Operation preflight is projected mechanically from
//! the canonical operation contract; this module must not classify operation
//! names or maintain a second authority policy.

use std::borrow::Cow;

use serde::Serialize;
use serde_json::{Value, json};

use super::{
    AuthorityPolicy, ConditionalAuthority, ResourceKindPolicy, SelectorAddition,
    WorkerPackageKindSource, authority_policy, operation_binding_metadata,
    operation_required_payload_fields, operation_risk,
    operations::{OperationEffect, OperationId, operation_effect},
};

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
    let effect = operation_effect(operation)?;
    let risk = operation_risk(operation)?;
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
        effect: effect.as_str(),
        risk,
        authority_boundary,
        evidence_boundary,
        minimality_decision,
        evolution_path,
        next_action,
    })
}

pub(crate) fn operation_agent_usage_projection(operation: &str) -> Option<Value> {
    let binding = operation_binding_metadata(operation)?;
    let audience = operation_pool_metadata(binding.operation)?
        .audience
        .as_str();
    let effect = operation_effect(operation)?;
    let risk = operation_risk(operation)?;
    let authority = authority_policy(operation)?;
    let required_payload_fields = operation_required_payload_fields(operation)?;
    Some(json!({
        "callable": true,
        "tool": "capability::execute",
        "operation": binding.operation,
        "arguments": {"operation": binding.operation},
        "audience": audience,
        "defaultUse": default_use_for_effect(effect, binding.family, binding.ownership_class),
        "effect": operation_effect_projection(binding.operation, binding.family, effect, risk, authority),
        "risk": risk,
        "preflight": preflight_guidance_for_operation(binding.operation, effect, authority, required_payload_fields),
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

fn default_use_for_effect(
    effect: OperationEffect,
    family: &str,
    ownership_class: &str,
) -> &'static str {
    if effect != OperationEffect::ReadOnly {
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

fn operation_effect_projection(
    operation: &str,
    family: &str,
    effect: OperationEffect,
    risk: &str,
    authority: AuthorityPolicy,
) -> Value {
    let read_only = effect == OperationEffect::ReadOnly;
    let starts_work = effect == OperationEffect::StartsWork;
    let writes_resource = authority.base_scope_additions().contains(&"resource.write");
    json!({
        "mode": effect.as_str(),
        "risk": risk,
        "readOnlyInspectionSafe": read_only,
        "mutatesState": !read_only,
        "writesResource": writes_resource,
        "startsWork": starts_work,
        "readOnlyInstruction": if read_only {
            "safe to call during read-only inspection"
        } else {
            "do not call during read-only inspection; inspect schema/catalog/list operations instead"
        },
        "priorEvidence": prior_evidence_projection(operation, authority.conditional_authority()),
        "requiresPriorEvidence": false,
        "family": family
    })
}

fn prior_evidence_projection(
    operation: &str,
    conditional_authority: ConditionalAuthority,
) -> Value {
    match conditional_authority {
        ConditionalAuthority::WebRobotsProof {
            resource_id_field,
            version_id_field,
            ..
        } => json!({
            "mode": "conditional",
            "requiredWhen": "the task requires robots-gated fetch proof or a robots policy was checked for this target",
            "sourceOperation": OperationId::WebRobotsCheck.as_str(),
            "copyFields": {
                "webRobotsPolicyResourceId": format!("{operation}.{resource_id_field}"),
                "webRobotsPolicyVersionId": format!("{operation}.{version_id_field}")
            },
            "failClosed": "missing, mismatched, or stale robots refs are rejected before target network I/O"
        }),
        _ => json!({"mode": "none"}),
    }
}

fn preflight_guidance_for_operation(
    operation: &str,
    effect: OperationEffect,
    authority: AuthorityPolicy,
    required_payload_fields: Vec<String>,
) -> Value {
    let resource_kind_policy = authority.resource_kind_policy();
    let resource_selectors = resource_kind_policy
        .base_kinds()
        .iter()
        .map(|kind| format!("kind:{kind}"))
        .collect::<Vec<_>>();
    let selector_derivations = authority
        .selector_additions()
        .iter()
        .copied()
        .map(selector_addition_projection)
        .collect::<Vec<_>>();
    let read_only = effect == OperationEffect::ReadOnly;
    json!({
        "authorityScopes": authority.base_scope_additions(),
        "capabilitySelectors": authority.capability_additions(),
        "resourceSelectors": resource_selectors,
        "dynamicResourceSelectors": dynamic_resource_selector_projection(resource_kind_policy),
        "exactResourceIdFields": authority.exact_resource_id_fields(),
        "selectorDerivations": selector_derivations,
        "conditionalAuthority": conditional_authority_projection(authority.conditional_authority()),
        "networkPolicy": authority.network_policy().as_str(),
        "agentStateInherited": false,
        "requiredPayloadFields": required_payload_fields,
        "readOnlyInstruction": if read_only {
            "safe to call during read-only inspection"
        } else {
            "do not call during read-only inspection; inspect the exact operation schema or a read-only list/inspect operation first"
        },
        "beforeCalling": format!(
            "Invoke capability::execute with operation={operation}. Put only the canonical top-level payload fields in the request, use exact provider-safe resource refs, and never request wildcard selectors or opaque authority tokens."
        )
    })
}

fn conditional_authority_projection(authority: ConditionalAuthority) -> Value {
    match authority {
        ConditionalAuthority::None => json!({"mode": "none"}),
        ConditionalAuthority::WebRobotsProof {
            resource_id_field,
            version_id_field,
            additional_scopes,
        } => json!({
            "mode": "web_robots_proof",
            "whenFieldsPresent": [resource_id_field, version_id_field],
            "additionalAuthorityScopes": additional_scopes
        }),
        ConditionalAuthority::NotificationPush {
            requested_field,
            additional_scopes,
            additional_resource_kind,
        } => json!({
            "mode": "notification_push",
            "whenFieldTrue": requested_field,
            "additionalAuthorityScopes": additional_scopes,
            "additionalResourceSelector": format!("kind:{additional_resource_kind}")
        }),
    }
}

fn dynamic_resource_selector_projection(policy: ResourceKindPolicy) -> Value {
    match policy {
        ResourceKindPolicy::None
        | ResourceKindPolicy::Static(_)
        | ResourceKindPolicy::CapabilityBinding(_)
        | ResourceKindPolicy::CapabilityRouteUnion
        | ResourceKindPolicy::ModuleRuntime(_)
        | ResourceKindPolicy::ModuleProgramExecution(_)
        | ResourceKindPolicy::Subagent(_) => json!({"mode": "none"}),
        ResourceKindPolicy::OptionalGoal {
            field, linked_kind, ..
        } => json!({
            "mode": "field_present",
            "field": field,
            "additionalResourceSelector": format!("kind:{linked_kind}")
        }),
        ResourceKindPolicy::WebFetchRobotsProof { proof_kind, .. } => json!({
            "mode": "web_robots_proof",
            "additionalResourceSelector": format!("kind:{proof_kind}")
        }),
        ResourceKindPolicy::NotificationPush { push_kind, .. } => json!({
            "mode": "notification_push",
            "additionalResourceSelector": format!("kind:{push_kind}")
        }),
        ResourceKindPolicy::Procedural {
            kind_field,
            resources,
        } => json!({
            "mode": "field_selected",
            "field": kind_field,
            "allowedResourceSelectors": resources
                .resource_kinds()
                .iter()
                .map(|kind| format!("kind:{kind}"))
                .collect::<Vec<_>>()
        }),
        ResourceKindPolicy::WorkerPackage(source) => match source {
            WorkerPackageKindSource::ListArgument { field } => json!({
                "mode": "field_selected",
                "field": field,
                "allowedResourceSelectors": source
                    .allowed_resource_kinds()
                    .iter()
                    .map(|kind| format!("kind:{kind}"))
                    .collect::<Vec<_>>()
            }),
            WorkerPackageKindSource::InspectResourceIdPrefix { field } => json!({
                "mode": "resource_id_prefix",
                "field": field,
                "allowedResourceSelectors": source
                    .allowed_resource_kinds()
                    .iter()
                    .map(|kind| format!("kind:{kind}"))
                    .collect::<Vec<_>>()
            }),
        },
    }
}

fn selector_addition_projection(addition: SelectorAddition) -> Value {
    match addition {
        SelectorAddition::Session => json!({
            "mode": "trusted_current_session"
        }),
        SelectorAddition::WebRobotsProof {
            resource_id_field,
            version_id_field,
        } => json!({
            "mode": "web_robots_proof_fields",
            "resourceIdField": resource_id_field,
            "versionIdField": version_id_field
        }),
        SelectorAddition::ProceduralKind { field } => json!({
            "mode": "procedural_kind_field",
            "field": field
        }),
        SelectorAddition::DerivedModuleLifecycleState {
            install_decision_field,
        } => json!({
            "mode": "derived_module_lifecycle_state",
            "installDecisionField": install_decision_field
        }),
        SelectorAddition::DerivedModuleRuntimeState {
            lifecycle_field,
            request_id_field,
            idempotency_field,
        } => json!({
            "mode": "derived_module_runtime_state",
            "lifecycleField": lifecycle_field,
            "requestIdField": request_id_field,
            "idempotencyField": idempotency_field
        }),
        SelectorAddition::DerivedSubagentTask { task_id_field } => json!({
            "mode": "derived_subagent_task",
            "taskIdField": task_id_field
        }),
        SelectorAddition::DelegatedSubagentResources {
            task_resource_field,
        } => json!({
            "mode": "delegated_subagent_resources",
            "taskResourceField": task_resource_field
        }),
    }
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
    fn every_operation_projects_exact_canonical_effect_risk_and_preflight() {
        assert_eq!(supported_operation_names().len(), 188);
        for operation in supported_operation_names() {
            let effect = operation_effect(operation).expect("canonical effect");
            let risk = operation_risk(operation).expect("canonical risk");
            let authority = authority_policy(operation).expect("canonical authority");
            let required_fields =
                operation_required_payload_fields(operation).expect("canonical required fields");
            let expected_resource_selectors = authority
                .resource_kind_policy()
                .base_kinds()
                .iter()
                .map(|kind| format!("kind:{kind}"))
                .collect::<Vec<_>>();
            let expected_selector_derivations = authority
                .selector_additions()
                .iter()
                .copied()
                .map(selector_addition_projection)
                .collect::<Vec<_>>();
            let usage = operation_agent_usage_projection(operation)
                .unwrap_or_else(|| panic!("missing usage projection for {operation}"));
            let preflight = &usage["preflight"];

            assert_eq!(usage["operation"], **operation, "{operation} operation");
            assert_eq!(usage["risk"], risk, "{operation} risk");
            assert_eq!(
                usage["effect"]["mode"],
                effect.as_str(),
                "{operation} effect"
            );
            assert_eq!(usage["effect"]["risk"], risk, "{operation} effect risk");
            assert_eq!(
                usage["effect"]["readOnlyInspectionSafe"],
                effect == OperationEffect::ReadOnly,
                "{operation} read-only classification"
            );
            assert_eq!(
                usage["effect"]["startsWork"],
                effect == OperationEffect::StartsWork,
                "{operation} starts-work classification"
            );
            assert_eq!(
                usage["effect"]["writesResource"],
                authority.base_scope_additions().contains(&"resource.write"),
                "{operation} resource-write classification"
            );
            assert_eq!(
                preflight["authorityScopes"],
                json!(authority.base_scope_additions()),
                "{operation} authority scopes"
            );
            assert_eq!(
                preflight["capabilitySelectors"],
                json!(authority.capability_additions()),
                "{operation} capability selectors"
            );
            assert_eq!(
                preflight["resourceSelectors"],
                json!(expected_resource_selectors),
                "{operation} resource selectors"
            );
            assert_eq!(
                preflight["exactResourceIdFields"],
                json!(authority.exact_resource_id_fields()),
                "{operation} exact resource-id fields"
            );
            assert_eq!(
                preflight["selectorDerivations"],
                json!(expected_selector_derivations),
                "{operation} selector derivations"
            );
            assert_eq!(
                preflight["dynamicResourceSelectors"],
                dynamic_resource_selector_projection(authority.resource_kind_policy()),
                "{operation} dynamic resource selectors"
            );
            assert_eq!(
                preflight["conditionalAuthority"],
                conditional_authority_projection(authority.conditional_authority()),
                "{operation} conditional authority"
            );
            assert_eq!(
                preflight["networkPolicy"],
                authority.network_policy().as_str(),
                "{operation} network policy"
            );
            assert_eq!(
                preflight["requiredPayloadFields"],
                json!(required_fields),
                "{operation} required fields"
            );
            assert_eq!(preflight["agentStateInherited"], false, "{operation}");
        }
    }

    #[test]
    fn operation_projection_has_no_local_operation_name_policy() {
        let implementation = include_str!("pool.rs")
            .split("#[cfg(test)]")
            .next()
            .expect("implementation section");
        for forbidden in [
            "match operation {",
            "operation ==",
            "operation.starts_with(",
            "operation.ends_with(",
            "none_unless_schema_requires_otherwise",
        ] {
            assert!(
                !implementation.contains(forbidden),
                "capability pool must not duplicate operation policy via {forbidden}"
            );
        }
        for operation in supported_operation_names() {
            let literal = format!("\"{operation}\"");
            assert!(
                !implementation.contains(&literal),
                "capability pool must source operation {operation} from the canonical registry"
            );
        }
    }

    #[test]
    fn canonical_preflight_remains_model_first_and_provider_safe() {
        let usage = operation_agent_usage_projection("git_status").expect("git_status usage");
        assert_eq!(
            usage["preflight"]["authorityScopes"],
            json!(["git.read", "resource.read"])
        );
        assert_eq!(usage["preflight"]["networkPolicy"], "none");
        assert_eq!(
            usage["preflight"]["requiredPayloadFields"],
            json!(["operation"])
        );
        assert!(
            usage["preflight"]["beforeCalling"]
                .as_str()
                .expect("before calling")
                .starts_with("Invoke capability::execute with operation=git_status")
        );
        let preflight = serde_json::to_string(&usage["preflight"]).expect("json");
        assert!(!preflight.contains("route_authority"));
        assert!(!preflight.contains("agent_state"));
        assert!(!preflight.contains("grantId"));
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
