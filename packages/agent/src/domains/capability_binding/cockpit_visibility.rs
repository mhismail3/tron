use std::collections::BTreeMap;

#[cfg(test)]
use std::collections::BTreeSet;

use serde::Serialize;
use serde_json::Value;

use crate::domains::capability::{operation_binding_metadata, supported_operation_names};
use crate::engine::{
    EngineResource, EngineResourceInspection, EngineResourceScope, EngineResourceVersion,
    Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::contract;
use super::resource_store::{current_payload, engine_error};
use super::validation::invalid;
use super::{
    CAPABILITY_BINDING_DECISION_KIND, CAPABILITY_BINDING_POLICY_KIND,
    CAPABILITY_BINDING_REQUEST_KIND, CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND, CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
    CAPABILITY_SHADOW_TRIAL_RUN_KIND, Deps,
};

const DEFAULT_LIMIT: usize = 170;
const MAX_LIMIT: usize = 200;
const MAX_RESOURCES_PER_KIND_SCOPE: usize = 100;

const BINDING_KINDS: &[&str] = &[
    CAPABILITY_BINDING_REQUEST_KIND,
    CAPABILITY_BINDING_DECISION_KIND,
    CAPABILITY_BINDING_POLICY_KIND,
];

const SHADOW_TRIAL_KINDS: &[&str] = &[
    CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
    CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
    CAPABILITY_SHADOW_TRIAL_RUN_KIND,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND,
];

#[derive(Clone, Debug, Default)]
struct OperationFacts {
    binding: BindingFacts,
    shadow: ShadowFacts,
}

#[derive(Clone, Debug, Default)]
struct BindingFacts {
    requested: usize,
    approved: usize,
    rejected: usize,
    active_policies: usize,
    failed_replacement_attempts: usize,
    rollback_available: bool,
    disable_available: bool,
    latest_state: Option<String>,
    last_updated_at: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct ShadowFacts {
    requested: usize,
    approved: usize,
    rejected: usize,
    runs: usize,
    passed: usize,
    failed: usize,
    aborted: usize,
    disabled: usize,
    rollback_available: bool,
    disable_available: bool,
    abort_available: bool,
    latest_state: Option<String>,
    last_updated_at: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CockpitProjection {
    schema_version: &'static str,
    operation: &'static str,
    summary: CockpitSummary,
    families: Vec<FamilySummary>,
    operations: Vec<OperationVisibility>,
    scope: ScopeProjection,
    projection: ProjectionPolicy,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct CockpitSummary {
    total_operations: usize,
    kernel_locked: usize,
    governance_locked: usize,
    record_plane: usize,
    adapter_replaceable: usize,
    module_owned: usize,
    deferred: usize,
    binding_requests: usize,
    binding_approved: usize,
    binding_rejected: usize,
    active_policies: usize,
    shadow_requests: usize,
    shadow_runs: usize,
    rollback_available: usize,
    title: String,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FamilySummary {
    family: String,
    label: String,
    operations: usize,
    kernel_locked: usize,
    governance_locked: usize,
    record_plane: usize,
    adapter_replaceable: usize,
    module_owned: usize,
    binding_activity: usize,
    shadow_activity: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OperationVisibility {
    name: String,
    family: String,
    family_label: String,
    owner: OwnerProjection,
    status: StatusProjection,
    replacement: ReplacementProjection,
    binding: BindingProjection,
    shadow_trial: ShadowTrialProjection,
    rollback: RollbackProjection,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OwnerProjection {
    label: String,
    detail: String,
    backend_owner: &'static str,
    source: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusProjection {
    kind: String,
    label: String,
    detail: String,
    built_in: bool,
    module_owned: bool,
    locked: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplacementProjection {
    can_shadow: bool,
    can_replace: bool,
    can_extend: bool,
    label: String,
    detail: String,
    governance_boundary: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct BindingProjection {
    requested: usize,
    approved: usize,
    rejected: usize,
    active_policies: usize,
    failed_replacement_attempts: usize,
    latest_state: Option<String>,
    last_updated_at: Option<String>,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ShadowTrialProjection {
    requested: usize,
    approved: usize,
    rejected: usize,
    runs: usize,
    passed: usize,
    failed: usize,
    aborted: usize,
    disabled: usize,
    latest_state: Option<String>,
    last_updated_at: Option<String>,
    available_for_this_operation: bool,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RollbackProjection {
    available: bool,
    disable_available: bool,
    abort_available: bool,
    boundary: &'static str,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ScopeProjection {
    session_scoped: bool,
    workspace_scoped: bool,
    exact_scope_required: bool,
    source: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectionPolicy {
    allowlist: &'static str,
    server_owned_truth: bool,
    projection_only: bool,
    metadata_only: bool,
    autonomy_behavior_created: bool,
    runtime_routing_changed: bool,
    dispatch_table_mutated: bool,
    hot_swap_performed: bool,
    module_activated: bool,
    module_executed: bool,
    raw_resource_ids_returned: bool,
    raw_local_paths_returned: bool,
    raw_env_values_returned: bool,
    raw_secrets_returned: bool,
    raw_commands_returned: bool,
    raw_logs_returned: bool,
    raw_code_returned: bool,
    raw_file_contents_returned: bool,
    raw_grant_ids_returned: bool,
    raw_authority_ids_returned: bool,
    trace_ids_returned: bool,
    invocation_ids_returned: bool,
    token_like_material_returned: bool,
    hidden_chain_of_thought_returned: bool,
    bounded_items: bool,
}

pub(crate) async fn cockpit_overview_value(
    deps: &Deps,
    invocation: &Invocation,
) -> Result<Value, CapabilityError> {
    let scopes = readable_scopes(invocation);
    if scopes.is_empty() {
        return Err(invalid(
            "capability_binding_cockpit_overview requires trusted session or workspace context",
        ));
    }
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .map(|value| value as usize)
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, MAX_LIMIT);
    let facts = collect_facts(deps, &scopes).await?;
    let mut operations = supported_operation_names()
        .iter()
        .filter_map(|operation| {
            operation_binding_metadata(operation).map(|metadata| {
                let facts = facts.get::<str>(*operation).cloned().unwrap_or_default();
                operation_visibility(
                    metadata.operation,
                    metadata.family,
                    metadata.ownership_class,
                    facts,
                )
            })
        })
        .take(limit)
        .collect::<Vec<_>>();
    operations.sort_by(|left, right| {
        left.family
            .cmp(&right.family)
            .then_with(|| left.name.cmp(&right.name))
    });
    let projection = CockpitProjection {
        schema_version: contract::COCKPIT_VISIBILITY_SCHEMA_VERSION,
        operation: "capability_binding_cockpit_overview",
        summary: summary(&operations),
        families: family_summaries(&operations),
        operations,
        scope: ScopeProjection {
            session_scoped: invocation.causal_context.session_id.is_some(),
            workspace_scoped: invocation.causal_context.workspace_id.is_some(),
            exact_scope_required: true,
            source: "trusted invocation causal context",
        },
        projection: ProjectionPolicy {
            allowlist: "capability_binding_cockpit_visibility_redacted_v1",
            server_owned_truth: true,
            projection_only: true,
            metadata_only: true,
            autonomy_behavior_created: false,
            runtime_routing_changed: false,
            dispatch_table_mutated: false,
            hot_swap_performed: false,
            module_activated: false,
            module_executed: false,
            raw_resource_ids_returned: false,
            raw_local_paths_returned: false,
            raw_env_values_returned: false,
            raw_secrets_returned: false,
            raw_commands_returned: false,
            raw_logs_returned: false,
            raw_code_returned: false,
            raw_file_contents_returned: false,
            raw_grant_ids_returned: false,
            raw_authority_ids_returned: false,
            trace_ids_returned: false,
            invocation_ids_returned: false,
            token_like_material_returned: false,
            hidden_chain_of_thought_returned: false,
            bounded_items: true,
        },
    };
    serde_json::to_value(projection).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}

async fn collect_facts(
    deps: &Deps,
    scopes: &[EngineResourceScope],
) -> Result<BTreeMap<String, OperationFacts>, CapabilityError> {
    let mut facts = BTreeMap::<String, OperationFacts>::new();
    for kind in BINDING_KINDS {
        collect_kind_facts(deps, scopes, kind, &mut facts, apply_binding_resource).await?;
    }
    for kind in SHADOW_TRIAL_KINDS {
        collect_kind_facts(deps, scopes, kind, &mut facts, apply_shadow_resource).await?;
    }
    Ok(facts)
}

async fn collect_kind_facts(
    deps: &Deps,
    scopes: &[EngineResourceScope],
    kind: &str,
    facts: &mut BTreeMap<String, OperationFacts>,
    apply: fn(&EngineResource, &EngineResourceVersion, &Value, &mut OperationFacts),
) -> Result<(), CapabilityError> {
    for scope in scopes {
        let resources = deps
            .engine_host
            .list_resources(ListResources {
                kind: Some(kind.to_owned()),
                scope: Some(scope.clone()),
                lifecycle: None,
                limit: MAX_RESOURCES_PER_KIND_SCOPE,
            })
            .await
            .map_err(engine_error)?;
        for resource in resources {
            if let Some((inspection, version, payload)) =
                inspect_current_payload(deps, &resource).await?
                && let Some(operation) = operation_name(&payload)
            {
                let entry = facts.entry(operation).or_default();
                apply(&inspection.resource, &version, &payload, entry);
            }
        }
    }
    Ok(())
}

async fn inspect_current_payload(
    deps: &Deps,
    resource: &EngineResource,
) -> Result<Option<(EngineResourceInspection, EngineResourceVersion, Value)>, CapabilityError> {
    let Some(inspection) = deps
        .engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)?
    else {
        return Ok(None);
    };
    let (version, payload) = current_payload(&inspection, "capability_binding_cockpit_overview")?;
    Ok(Some((inspection.clone(), version.clone(), payload.clone())))
}

fn apply_binding_resource(
    resource: &EngineResource,
    _version: &EngineResourceVersion,
    payload: &Value,
    facts: &mut OperationFacts,
) {
    let state = state(resource, payload);
    let updated_at = timestamp(resource, payload);
    let binding_mode = payload.pointer("/binding/mode").and_then(Value::as_str);
    match resource.kind.as_str() {
        CAPABILITY_BINDING_REQUEST_KIND => {
            facts.binding.requested += 1;
        }
        CAPABILITY_BINDING_DECISION_KIND => match normalize(&state).as_str() {
            "approvedpolicy" => facts.binding.approved += 1,
            "rejected" => {
                facts.binding.rejected += 1;
                if binding_mode == Some("replace") {
                    facts.binding.failed_replacement_attempts += 1;
                }
            }
            _ => {}
        },
        CAPABILITY_BINDING_POLICY_KIND => {
            if normalize(&state) == "active" {
                facts.binding.active_policies += 1;
            }
            if has_truthy(payload, "/activation/rollbackRef") {
                facts.binding.rollback_available = true;
            }
            if has_truthy(payload, "/activation/disableRef") {
                facts.binding.disable_available = true;
            }
        }
        _ => {}
    }
    update_latest(
        &mut facts.binding.latest_state,
        &mut facts.binding.last_updated_at,
        state,
        updated_at,
    );
}

fn apply_shadow_resource(
    resource: &EngineResource,
    _version: &EngineResourceVersion,
    payload: &Value,
    facts: &mut OperationFacts,
) {
    let state = state(resource, payload);
    let updated_at = timestamp(resource, payload);
    match resource.kind.as_str() {
        CAPABILITY_SHADOW_TRIAL_REQUEST_KIND => {
            facts.shadow.requested += 1;
        }
        CAPABILITY_SHADOW_TRIAL_DECISION_KIND => match normalize(&state).as_str() {
            "approvedtrial" => facts.shadow.approved += 1,
            "rejected" => facts.shadow.rejected += 1,
            "aborted" => facts.shadow.aborted += 1,
            "disabled" => facts.shadow.disabled += 1,
            _ => {}
        },
        CAPABILITY_SHADOW_TRIAL_RUN_KIND => {
            facts.shadow.runs += 1;
            match normalize(&state).as_str() {
                "passed" => facts.shadow.passed += 1,
                "failed" => facts.shadow.failed += 1,
                "aborted" => facts.shadow.aborted += 1,
                "disabled" => facts.shadow.disabled += 1,
                _ => {}
            }
            if bool_at(payload, "/resultControls/rollbackAvailable") {
                facts.shadow.rollback_available = true;
            }
            if bool_at(payload, "/resultControls/disableAvailable") {
                facts.shadow.disable_available = true;
            }
            if bool_at(payload, "/resultControls/abortAvailable") {
                facts.shadow.abort_available = true;
            }
        }
        CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND => {
            if bool_at(payload, "/resultControls/rollbackAvailable") {
                facts.shadow.rollback_available = true;
            }
            if bool_at(payload, "/resultControls/disableAvailable") {
                facts.shadow.disable_available = true;
            }
            if bool_at(payload, "/resultControls/abortAvailable") {
                facts.shadow.abort_available = true;
            }
        }
        _ => {}
    }
    update_latest(
        &mut facts.shadow.latest_state,
        &mut facts.shadow.last_updated_at,
        state,
        updated_at,
    );
}

fn operation_visibility(
    operation: &str,
    family: &str,
    ownership_class: &str,
    facts: OperationFacts,
) -> OperationVisibility {
    let replacement = replacement_projection(family, ownership_class);
    let rollback = rollback_projection(ownership_class, &facts);
    OperationVisibility {
        name: operation.to_owned(),
        family: family.to_owned(),
        family_label: family_label(family),
        owner: owner_projection(family, ownership_class),
        status: status_projection(family, ownership_class),
        replacement,
        binding: binding_projection(&facts.binding),
        shadow_trial: shadow_projection(operation, &facts.shadow),
        rollback,
    }
}

fn owner_projection(family: &str, ownership_class: &str) -> OwnerProjection {
    OwnerProjection {
        label: owner_label(family, ownership_class),
        detail: match ownership_class {
            "kernel_locked" => "The engine kernel owns this operation and modules cannot take it over.",
            "governance_locked" => "The governance pipeline owns this operation because it controls module trust.",
            "record_plane" => "The server record plane owns durable custody; modules may only add governed producers.",
            "adapter_replaceable" => "A built-in adapter owns execution today and can be proposed for governed replacement later.",
            "module_owned" => "A governed module/runtime pack owns this operation today.",
            _ => "Ownership has not been resolved for module binding.",
        }
        .to_owned(),
        backend_owner: contract::WORKER,
        source: "capability execute registry plus capability binding resources",
    }
}

fn status_projection(family: &str, ownership_class: &str) -> StatusProjection {
    let (label, detail, built_in, module_owned, locked) = match ownership_class {
        "kernel_locked" => (
            "Kernel locked",
            "Engine substrate; replacement is not available.",
            true,
            false,
            true,
        ),
        "governance_locked" => (
            "Governance locked",
            "Trust pipeline; replacement is not available.",
            true,
            false,
            true,
        ),
        "record_plane" => (
            "Record-plane custody",
            "Durable records stay server-owned; module producers may be added through policy.",
            true,
            false,
            false,
        ),
        "adapter_replaceable" => (
            "Built-in adapter",
            "Built-in execution can be shadowed or replaced only after governed evidence.",
            true,
            false,
            false,
        ),
        "module_owned" => (
            "Module-owned",
            "Already owned by a governed module/runtime pack.",
            false,
            true,
            false,
        ),
        _ => (
            "Deferred",
            "Ownership is intentionally unresolved until a future scorecard slice.",
            true,
            false,
            false,
        ),
    };
    StatusProjection {
        kind: if ownership_class == "adapter_replaceable" {
            "built_in_adapter".to_owned()
        } else {
            ownership_class.to_owned()
        },
        label: label.to_owned(),
        detail: format!("{detail} Family: {}.", family_label(family)),
        built_in,
        module_owned,
        locked,
    }
}

fn replacement_projection(family: &str, ownership_class: &str) -> ReplacementProjection {
    let can_replace = matches!(ownership_class, "adapter_replaceable" | "module_owned");
    let can_shadow = can_replace;
    let can_extend = matches!(
        ownership_class,
        "record_plane" | "adapter_replaceable" | "module_owned"
    );
    let (label, detail) = match ownership_class {
        "kernel_locked" => (
            "No replacement",
            "A future module may read safe projections, but it cannot replace this kernel responsibility.",
        ),
        "governance_locked" => (
            "No replacement",
            "This operation governs module trust, so future modules cannot replace it.",
        ),
        "record_plane" => (
            "Extension only",
            "Future modules may add producers or workflows but cannot bypass server-owned records.",
        ),
        "adapter_replaceable" => (
            "Shadow or replace after review",
            "Future modules can request shadow or replacement with exact authority, parity evidence, and rollback/disable metadata.",
        ),
        "module_owned" => (
            "Governed module path",
            "Already module-owned; replacement remains behind lifecycle, runtime, and rollback governance.",
        ),
        _ => (
            "Deferred",
            "Replacement policy waits for a resolved ownership class.",
        ),
    };
    ReplacementProjection {
        can_shadow,
        can_replace,
        can_extend,
        label: label.to_owned(),
        detail: format!("{detail} Area: {}.", family_label(family)),
        governance_boundary: "capability binding policy",
    }
}

fn binding_projection(facts: &BindingFacts) -> BindingProjection {
    let detail = if facts.active_policies > 0 {
        format!(
            "{} active metadata policy record{}; runtime routing remains disabled.",
            facts.active_policies,
            plural(facts.active_policies)
        )
    } else if facts.rejected > 0 {
        format!(
            "{} binding decision{} rejected; no runtime routing changed.",
            facts.rejected,
            plural(facts.rejected)
        )
    } else if facts.requested > 0 {
        format!(
            "{} binding request{} recorded and awaiting governance.",
            facts.requested,
            plural(facts.requested)
        )
    } else {
        "No binding requests have been recorded in this scope.".to_owned()
    };
    BindingProjection {
        requested: facts.requested,
        approved: facts.approved,
        rejected: facts.rejected,
        active_policies: facts.active_policies,
        failed_replacement_attempts: facts.failed_replacement_attempts,
        latest_state: facts.latest_state.clone(),
        last_updated_at: facts.last_updated_at.clone(),
        detail,
    }
}

fn shadow_projection(operation: &str, facts: &ShadowFacts) -> ShadowTrialProjection {
    let detail = if facts.runs > 0 {
        format!(
            "{} metadata-only shadow run{} recorded; candidate execution and routing stayed disabled.",
            facts.runs,
            plural(facts.runs)
        )
    } else if facts.approved > 0 {
        format!(
            "{} shadow trial approval{} recorded; no live replacement was made.",
            facts.approved,
            plural(facts.approved)
        )
    } else if facts.requested > 0 {
        format!(
            "{} shadow trial request{} recorded and awaiting governance.",
            facts.requested,
            plural(facts.requested)
        )
    } else if operation == "git_status" {
        "Eligible for the current metadata-only shadow-trial path; no trial is active in this scope."
            .to_owned()
    } else {
        "No shadow trial is available for this operation in the current slice.".to_owned()
    };
    ShadowTrialProjection {
        requested: facts.requested,
        approved: facts.approved,
        rejected: facts.rejected,
        runs: facts.runs,
        passed: facts.passed,
        failed: facts.failed,
        aborted: facts.aborted,
        disabled: facts.disabled,
        latest_state: facts.latest_state.clone(),
        last_updated_at: facts.last_updated_at.clone(),
        available_for_this_operation: operation == "git_status",
        detail,
    }
}

fn rollback_projection(ownership_class: &str, facts: &OperationFacts) -> RollbackProjection {
    let available = facts.binding.rollback_available || facts.shadow.rollback_available;
    let disable_available = facts.binding.disable_available || facts.shadow.disable_available;
    let abort_available = facts.shadow.abort_available;
    let detail = if available {
        "Rollback metadata is available for the recorded policy or shadow trial; live routing still has not changed."
            .to_owned()
    } else {
        match ownership_class {
            "adapter_replaceable" | "module_owned" => {
                "No active replacement rollback is available yet; any future replacement must record rollback and disable controls first."
                    .to_owned()
            }
            "record_plane" => {
                "Replacement rollback is not applicable because server-owned records remain the custody boundary."
                    .to_owned()
            }
            "kernel_locked" | "governance_locked" => {
                "Rollback is not applicable because replacement is not allowed for this locked operation."
                    .to_owned()
            }
            _ => "Rollback waits for a resolved ownership and binding policy.".to_owned(),
        }
    };
    RollbackProjection {
        available,
        disable_available,
        abort_available,
        boundary: "capability binding governance",
        detail,
    }
}

fn summary(operations: &[OperationVisibility]) -> CockpitSummary {
    let mut summary = CockpitSummary {
        total_operations: operations.len(),
        title: "Capability ownership visible".to_owned(),
        detail: format!(
            "{} capability::execute operations have server-owned modularity metadata.",
            operations.len()
        ),
        ..CockpitSummary::default()
    };
    for operation in operations {
        match operation.status.kind.as_str() {
            "kernel_locked" => summary.kernel_locked += 1,
            "governance_locked" => summary.governance_locked += 1,
            "record_plane" => summary.record_plane += 1,
            "built_in_adapter" => summary.adapter_replaceable += 1,
            "module_owned" => summary.module_owned += 1,
            _ => summary.deferred += 1,
        }
        summary.binding_requests += operation.binding.requested;
        summary.binding_approved += operation.binding.approved;
        summary.binding_rejected += operation.binding.rejected;
        summary.active_policies += operation.binding.active_policies;
        summary.shadow_requests += operation.shadow_trial.requested;
        summary.shadow_runs += operation.shadow_trial.runs;
        if operation.rollback.available {
            summary.rollback_available += 1;
        }
    }
    if summary.binding_requests > 0 || summary.shadow_requests > 0 {
        summary.detail = format!(
            "{} operations, {} binding request{}, {} shadow request{} in this scope.",
            summary.total_operations,
            summary.binding_requests,
            plural(summary.binding_requests),
            summary.shadow_requests,
            plural(summary.shadow_requests)
        );
    }
    summary
}

fn family_summaries(operations: &[OperationVisibility]) -> Vec<FamilySummary> {
    let mut families = BTreeMap::<String, FamilySummary>::new();
    for operation in operations {
        let entry = families
            .entry(operation.family.clone())
            .or_insert_with(|| FamilySummary {
                family: operation.family.clone(),
                label: operation.family_label.clone(),
                operations: 0,
                kernel_locked: 0,
                governance_locked: 0,
                record_plane: 0,
                adapter_replaceable: 0,
                module_owned: 0,
                binding_activity: 0,
                shadow_activity: 0,
            });
        entry.operations += 1;
        match operation.status.kind.as_str() {
            "kernel_locked" => entry.kernel_locked += 1,
            "governance_locked" => entry.governance_locked += 1,
            "record_plane" => entry.record_plane += 1,
            "built_in_adapter" => entry.adapter_replaceable += 1,
            "module_owned" => entry.module_owned += 1,
            _ => {}
        }
        entry.binding_activity += operation.binding.requested
            + operation.binding.approved
            + operation.binding.rejected
            + operation.binding.active_policies;
        entry.shadow_activity += operation.shadow_trial.requested + operation.shadow_trial.runs;
    }
    families.into_values().collect()
}

fn readable_scopes(invocation: &Invocation) -> Vec<EngineResourceScope> {
    let mut scopes = Vec::new();
    if let Some(session) = &invocation.causal_context.session_id {
        scopes.push(EngineResourceScope::Session(session.clone()));
    }
    if let Some(workspace) = &invocation.causal_context.workspace_id {
        scopes.push(EngineResourceScope::Workspace(workspace.clone()));
    }
    scopes
}

fn operation_name(payload: &Value) -> Option<String> {
    payload
        .pointer("/operation/name")
        .and_then(Value::as_str)
        .filter(|operation| supported_operation_names().contains(operation))
        .map(str::to_owned)
}

fn state(resource: &EngineResource, payload: &Value) -> String {
    payload
        .get("state")
        .and_then(Value::as_str)
        .unwrap_or(&resource.lifecycle)
        .to_owned()
}

fn timestamp(resource: &EngineResource, payload: &Value) -> String {
    payload
        .get("updatedAt")
        .and_then(Value::as_str)
        .or_else(|| payload.get("createdAt").and_then(Value::as_str))
        .map(str::to_owned)
        .unwrap_or_else(|| {
            resource
                .updated_at
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
        })
}

fn update_latest(
    state_slot: &mut Option<String>,
    timestamp_slot: &mut Option<String>,
    state: String,
    updated_at: String,
) {
    if timestamp_slot
        .as_deref()
        .is_none_or(|current| updated_at.as_str() >= current)
    {
        *state_slot = Some(state);
        *timestamp_slot = Some(updated_at);
    }
}

fn has_truthy(payload: &Value, pointer: &str) -> bool {
    payload
        .pointer(pointer)
        .is_some_and(|value| !value.is_null())
}

fn bool_at(payload: &Value, pointer: &str) -> bool {
    payload.pointer(pointer).and_then(Value::as_bool) == Some(true)
}

fn owner_label(family: &str, ownership_class: &str) -> String {
    match ownership_class {
        "kernel_locked" => "Engine kernel".to_owned(),
        "governance_locked" => format!("{} governance", family_label(family)),
        "record_plane" => format!("{} record plane", family_label(family)),
        "adapter_replaceable" => format!("Built-in {} adapter", family_label(family)),
        "module_owned" => format!("{} module pack", family_label(family)),
        _ => "Deferred owner".to_owned(),
    }
}

fn family_label(family: &str) -> String {
    family
        .split('_')
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => format!("{}{}", first.to_ascii_uppercase(), chars.as_str()),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn normalize(value: &str) -> String {
    value
        .trim()
        .replace(['_', '-', ' '], "")
        .to_ascii_lowercase()
}

fn plural(count: usize) -> &'static str {
    if count == 1 { "" } else { "s" }
}

#[cfg(test)]
pub(crate) fn test_serialized_has_no_raw_cockpit_material(value: &Value) -> bool {
    let serialized = serde_json::to_string(value).expect("projection serializes");
    let forbidden = [
        "domains::",
        "capability_binding_request:",
        "capability_binding_decision:",
        "capability_binding_policy:",
        "capability_shadow_trial_request:",
        "capability_shadow_trial_decision:",
        "capability_shadow_trial_run:",
        "capability_shadow_trial_evidence:",
        "engine-system",
        "engine-transport",
        "/Users/",
        "/tmp/",
        "Authorization:",
        "Bearer ",
    ];
    forbidden.iter().all(|needle| !serialized.contains(needle))
}

#[cfg(test)]
pub(crate) fn test_operation_names(value: &Value) -> BTreeSet<String> {
    value["operations"]
        .as_array()
        .expect("operations array")
        .iter()
        .filter_map(|operation| operation["name"].as_str().map(str::to_owned))
        .collect()
}
