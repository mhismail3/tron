use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;
use serde_json::Value;

use crate::domains::capability::{
    OperationBindingMetadata, operation_binding_metadata,
    pool::{CapabilityPoolMetadata, operation_agent_usage_projection, operation_pool_metadata},
    supported_operation_names,
};
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
    CAPABILITY_BINDING_REQUEST_KIND, CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
    CAPABILITY_ROUTE_ACTIVATION_KIND, CAPABILITY_ROUTE_BINDING_KIND, CAPABILITY_ROUTE_EVENT_KIND,
    CAPABILITY_ROUTE_ROLLBACK_KIND, CAPABILITY_SHADOW_TRIAL_DECISION_KIND,
    CAPABILITY_SHADOW_TRIAL_EVIDENCE_KIND, CAPABILITY_SHADOW_TRIAL_REQUEST_KIND,
    CAPABILITY_SHADOW_TRIAL_RUN_KIND, Deps,
};

const MAX_RESOURCES_PER_KIND_SCOPE: usize = 100;
const MAX_SHADOW_EVIDENCE_REFS: usize = 5;

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

const ROUTE_KINDS: &[&str] = &[
    CAPABILITY_REPLACEMENT_CANDIDATE_KIND,
    CAPABILITY_ROUTE_BINDING_KIND,
    CAPABILITY_ROUTE_ACTIVATION_KIND,
    CAPABILITY_ROUTE_EVENT_KIND,
    CAPABILITY_ROUTE_ROLLBACK_KIND,
];

#[derive(Clone, Debug, Default)]
struct OperationFacts {
    binding: BindingFacts,
    shadow: ShadowFacts,
    route: RouteFacts,
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
    evidence_refs: Vec<ShadowEvidenceRef>,
}

#[derive(Clone, Debug)]
struct ShadowEvidenceRef {
    resource_id: String,
    version_id: Option<String>,
    state: String,
    updated_at: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct RouteFacts {
    candidates: usize,
    bindings: usize,
    route_events: usize,
    routed_invocations: usize,
    failed_closed: usize,
    disabled: usize,
    rolled_back: usize,
    rollback_records: usize,
    rollback_available: bool,
    disable_available: bool,
    latest_state: Option<String>,
    last_updated_at: Option<String>,
    active_activation_ids: BTreeSet<String>,
    terminal_activation_ids: BTreeSet<String>,
}

impl RouteFacts {
    fn active_route_count(&self) -> usize {
        self.active_activation_ids
            .difference(&self.terminal_activation_ids)
            .count()
    }

    fn has_active_route(&self) -> bool {
        self.active_route_count() > 0
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CockpitProjection {
    schema_version: &'static str,
    operation: &'static str,
    summary: CockpitSummary,
    operation_list: OperationListProjection,
    resource_scan: ResourceScanProjection,
    families: Vec<FamilySummary>,
    route_stories: Vec<RouteStoryProjection>,
    operations: Vec<OperationVisibility>,
    scope: ScopeProjection,
    projection: ProjectionPolicy,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct CockpitSummary {
    total_operations: usize,
    returned_operations: usize,
    operation_list_complete: bool,
    operation_list_truncated: bool,
    resource_scan_complete: bool,
    resource_scan_truncated: bool,
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
    route_candidates: usize,
    active_routes: usize,
    route_events: usize,
    routed_invocations: usize,
    failed_closed_routes: usize,
    route_rollbacks: usize,
    rollback_available: usize,
    title: String,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OperationListProjection {
    total_operations: usize,
    returned_operations: usize,
    requested_limit: usize,
    target_operation: Option<String>,
    filter_applied: bool,
    complete: bool,
    truncated: bool,
    state: &'static str,
    label: String,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ResourceScanProjection {
    queries: usize,
    scanned_resources: usize,
    applied_resources: usize,
    limit_per_kind_scope: usize,
    complete: bool,
    truncated: bool,
    truncated_queries: usize,
    state: &'static str,
    label: String,
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
    route_activity: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RouteStoryProjection {
    kind: &'static str,
    operation: String,
    title: String,
    detail: String,
    status: String,
    evidence_count: usize,
    last_updated_at: Option<String>,
    drill_down_label: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OperationVisibility {
    name: String,
    family: String,
    family_label: String,
    capability_pool: CapabilityPoolRoleProjection,
    agent_usage: Value,
    owner: OwnerProjection,
    status: StatusProjection,
    replacement: ReplacementProjection,
    readiness: ReadinessProjection,
    binding: BindingProjection,
    shadow_trial: ShadowTrialProjection,
    route: RouteProjection,
    rollback: RollbackProjection,
    agent_path: AgentPathProjection,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentPathProjection {
    purpose: String,
    primary_inspection: AgentPathStep,
    read_only_sequence: Vec<AgentPathStep>,
    unavailable_surfaces: Vec<UnavailableSurfaceProjection>,
    completion: AgentPathCompletionProjection,
    adapter_execution_guidance: String,
    evidence_guidance: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentPathStep {
    label: String,
    operation: String,
    payload: Value,
    read_only_inspection_safe: bool,
    reason: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct UnavailableSurfaceProjection {
    operation: String,
    reason: String,
    alternative: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentPathCompletionProjection {
    state: String,
    action: String,
    reason: String,
    stop_when: String,
    final_answer_guidance: String,
    readiness_verdict: AgentPathReadinessVerdictProjection,
    read_only_boundary: AgentPathReadOnlyBoundaryProjection,
    governed_next_steps: Vec<AgentPathNextStepProjection>,
    do_not_inspect: Vec<AgentPathDoNotInspectProjection>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentPathReadinessVerdictProjection {
    ready_for_routing: bool,
    final_answer_ready: bool,
    stop_now: bool,
    current_scope_state: String,
    current_scope_evidence: AgentPathEvidenceCountsProjection,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentPathEvidenceCountsProjection {
    shadow_evidence_refs: usize,
    shadow_runs: usize,
    route_bindings: usize,
    active_routes: usize,
    route_events: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentPathReadOnlyBoundaryProjection {
    capability_requested_mutation: bool,
    engine_audit_persistence: bool,
    required_final_answer_suffix: &'static str,
    detail: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentPathNextStepProjection {
    order: usize,
    operation: &'static str,
    effect: &'static str,
    requires_approval: bool,
    reason: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AgentPathDoNotInspectProjection {
    operation: String,
    reason: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct CapabilityPoolRoleProjection {
    surface: &'static str,
    audience: &'static str,
    replacement_class: &'static str,
    agent_default_visibility: &'static str,
    minimality_decision: &'static str,
    evolution_path: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OwnerProjection {
    label: String,
    detail: String,
    source: &'static str,
    metadata_source_label: &'static str,
    projection_source_label: &'static str,
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
    target: ReplacementTargetProjection,
    governance_boundary: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplacementTargetProjection {
    label: String,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReadinessProjection {
    state: String,
    label: String,
    detail: String,
    next_action_label: String,
    next_action_detail: String,
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
    evidence_refs: Vec<ShadowEvidenceRefProjection>,
    evidence_inspect_ready: bool,
    available_for_this_operation: bool,
    detail: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ShadowEvidenceRefProjection {
    label: String,
    resource_id: String,
    version_id: Option<String>,
    state: String,
    updated_at: Option<String>,
    inspect_operation: &'static str,
    inspect_payload: Value,
    reason: &'static str,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RouteProjection {
    candidates: usize,
    bindings: usize,
    active_routes: usize,
    route_events: usize,
    routed_invocations: usize,
    failed_closed: usize,
    disabled: usize,
    rolled_back: usize,
    rollback_records: usize,
    rollback_available: bool,
    disable_available: bool,
    latest_state: Option<String>,
    last_updated_at: Option<String>,
    state: String,
    label: String,
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

#[derive(Clone, Debug, Default)]
struct FactCollection {
    facts: BTreeMap<String, OperationFacts>,
    scan: ResourceScanFacts,
}

#[derive(Clone, Debug)]
struct ResourceScanFacts {
    queries: usize,
    scanned_resources: usize,
    applied_resources: usize,
    truncated_queries: usize,
    limit_per_kind_scope: usize,
}

impl Default for ResourceScanFacts {
    fn default() -> Self {
        Self {
            queries: 0,
            scanned_resources: 0,
            applied_resources: 0,
            truncated_queries: 0,
            limit_per_kind_scope: MAX_RESOURCES_PER_KIND_SCOPE,
        }
    }
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
        .unwrap_or_else(|| supported_operation_names().len())
        .clamp(1, contract::COCKPIT_OVERVIEW_MAX_LIMIT);
    let target_operation = invocation
        .payload
        .get("targetOperation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    if let Some(target_operation) = target_operation.as_deref()
        && !supported_operation_names().contains(&target_operation)
    {
        return Err(invalid(format!(
            "unknown targetOperation {target_operation}"
        )));
    }
    let facts = collect_facts(deps, &scopes).await?;
    let mut all_operations = Vec::new();
    for operation in supported_operation_names() {
        let metadata =
            operation_binding_metadata(operation).ok_or_else(|| CapabilityError::Internal {
                message: format!("missing capability binding metadata for operation {operation}"),
            })?;
        let pool = operation_pool_metadata(operation).ok_or_else(|| CapabilityError::Internal {
            message: format!("missing capability pool metadata for operation {operation}"),
        })?;
        let operation_facts = facts
            .facts
            .get::<str>(*operation)
            .cloned()
            .unwrap_or_default();
        let include_shadow_evidence_refs = target_operation
            .as_deref()
            .is_some_and(|target| target == *operation);
        all_operations.push(operation_visibility(
            metadata,
            capability_pool_role_projection(&pool),
            operation_facts,
            include_shadow_evidence_refs,
        ));
    }
    all_operations.sort_by(|left, right| {
        left.family
            .cmp(&right.family)
            .then_with(|| left.name.cmp(&right.name))
    });
    let visible_operations = if let Some(target_operation) = target_operation.as_deref() {
        all_operations
            .iter()
            .filter(|operation| operation.name == target_operation)
            .cloned()
            .collect::<Vec<_>>()
    } else {
        all_operations
            .iter()
            .take(limit)
            .cloned()
            .collect::<Vec<_>>()
    };
    let operation_list = operation_list_projection(
        all_operations.len(),
        visible_operations.len(),
        limit,
        target_operation.clone(),
    );
    let resource_scan = resource_scan_projection(facts.scan);
    let operations = visible_operations;
    let raw_resource_ids_returned = operations
        .iter()
        .any(|operation| !operation.shadow_trial.evidence_refs.is_empty());
    let route_stories = route_stories(&all_operations);
    let projection = CockpitProjection {
        schema_version: contract::COCKPIT_VISIBILITY_SCHEMA_VERSION,
        operation: "capability_binding_cockpit_overview",
        summary: summary(
            &all_operations,
            operations.len(),
            &operation_list,
            &resource_scan,
        ),
        operation_list,
        resource_scan,
        families: family_summaries(&all_operations),
        route_stories,
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
            raw_resource_ids_returned,
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
) -> Result<FactCollection, CapabilityError> {
    let mut collection = FactCollection::default();
    for kind in BINDING_KINDS {
        collect_kind_facts(deps, scopes, kind, &mut collection, apply_binding_resource).await?;
    }
    for kind in SHADOW_TRIAL_KINDS {
        collect_kind_facts(deps, scopes, kind, &mut collection, apply_shadow_resource).await?;
    }
    for kind in ROUTE_KINDS {
        collect_kind_facts(deps, scopes, kind, &mut collection, apply_route_resource).await?;
    }
    Ok(collection)
}

async fn collect_kind_facts(
    deps: &Deps,
    scopes: &[EngineResourceScope],
    kind: &str,
    collection: &mut FactCollection,
    apply: fn(&EngineResource, &EngineResourceVersion, &Value, &mut OperationFacts),
) -> Result<(), CapabilityError> {
    for scope in scopes {
        let resources = deps
            .engine_host
            .list_resources(ListResources {
                kind: Some(kind.to_owned()),
                scope: Some(scope.clone()),
                lifecycle: None,
                limit: MAX_RESOURCES_PER_KIND_SCOPE + 1,
            })
            .await
            .map_err(engine_error)?;
        collection.scan.queries += 1;
        if resources.len() > MAX_RESOURCES_PER_KIND_SCOPE {
            collection.scan.truncated_queries += 1;
        }
        for resource in resources.into_iter().take(MAX_RESOURCES_PER_KIND_SCOPE) {
            collection.scan.scanned_resources += 1;
            if let Some((inspection, version, payload)) =
                inspect_current_payload(deps, &resource).await?
                && let Some(operation) = operation_name(&payload)
            {
                collection.scan.applied_resources += 1;
                let entry = collection.facts.entry(operation).or_default();
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
            if facts.shadow.evidence_refs.len() < MAX_SHADOW_EVIDENCE_REFS {
                facts.shadow.evidence_refs.push(ShadowEvidenceRef {
                    resource_id: resource.resource_id.clone(),
                    version_id: Some(_version.version_id.clone()),
                    state: state.clone(),
                    updated_at: Some(updated_at.clone()),
                });
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
        _ => {}
    }
    update_latest(
        &mut facts.shadow.latest_state,
        &mut facts.shadow.last_updated_at,
        state,
        updated_at,
    );
}

fn apply_route_resource(
    resource: &EngineResource,
    _version: &EngineResourceVersion,
    payload: &Value,
    facts: &mut OperationFacts,
) {
    let state = state(resource, payload);
    let updated_at = timestamp(resource, payload);
    match resource.kind.as_str() {
        CAPABILITY_REPLACEMENT_CANDIDATE_KIND => {
            facts.route.candidates += 1;
        }
        CAPABILITY_ROUTE_BINDING_KIND => {
            facts.route.bindings += 1;
        }
        CAPABILITY_ROUTE_ACTIVATION_KIND => {
            if normalize(&state) == "active" {
                facts
                    .route
                    .active_activation_ids
                    .insert(resource.resource_id.clone());
            }
            if bool_at(payload, "/activation/rollbackAvailable") {
                facts.route.rollback_available = true;
            }
            if bool_at(payload, "/activation/disableAvailable") {
                facts.route.disable_available = true;
            }
        }
        CAPABILITY_ROUTE_EVENT_KIND => {
            facts.route.route_events += 1;
            let event_kind = payload
                .pointer("/event/kind")
                .and_then(Value::as_str)
                .unwrap_or(state.as_str());
            match normalize(event_kind).as_str() {
                "routedinvocation" => facts.route.routed_invocations += 1,
                "disabled" => {
                    facts.route.disabled += 1;
                    if let Some(activation_id) = route_event_activation_id(payload) {
                        facts.route.terminal_activation_ids.insert(activation_id);
                    }
                }
                "rolledback" => {
                    facts.route.rolled_back += 1;
                    if let Some(activation_id) = route_event_activation_id(payload) {
                        facts.route.terminal_activation_ids.insert(activation_id);
                    }
                }
                _ => {}
            }
            if normalize(&state) == "failedclosed" || bool_at(payload, "/event/failClosed") {
                facts.route.failed_closed += 1;
            }
        }
        CAPABILITY_ROUTE_ROLLBACK_KIND => {
            facts.route.rollback_records += 1;
            if bool_at(payload, "/rollback/builtInRestored") {
                facts.route.rollback_available = true;
            }
        }
        _ => {}
    }
    update_latest(
        &mut facts.route.latest_state,
        &mut facts.route.last_updated_at,
        state,
        updated_at,
    );
}

fn operation_visibility(
    metadata: OperationBindingMetadata,
    capability_pool: CapabilityPoolRoleProjection,
    facts: OperationFacts,
    include_shadow_evidence_refs: bool,
) -> OperationVisibility {
    let replacement = replacement_projection(
        metadata.family,
        metadata.ownership_class,
        metadata.replacement_target,
    );
    let rollback = rollback_projection(metadata.ownership_class, &facts);
    let readiness = readiness_projection(metadata.ownership_class, &facts, &replacement);
    let binding = binding_projection(&facts.binding);
    let shadow_trial = shadow_projection(
        metadata.operation,
        &facts.shadow,
        include_shadow_evidence_refs,
    );
    let route = route_projection(&facts.route);
    let agent_path = agent_path_projection(
        metadata.operation,
        &replacement,
        &readiness,
        &binding,
        &shadow_trial,
        &route,
    );
    OperationVisibility {
        name: metadata.operation.to_owned(),
        family: metadata.family.to_owned(),
        family_label: family_label(metadata.family),
        capability_pool,
        agent_usage: operation_agent_usage_projection(metadata.operation)
            .expect("supported operation has canonical agent usage metadata"),
        owner: owner_projection(
            metadata.family,
            metadata.current_owner,
            metadata.ownership_class,
        ),
        status: status_projection(metadata.family, metadata.ownership_class),
        replacement,
        readiness,
        binding,
        shadow_trial,
        route,
        rollback,
        agent_path,
    }
}

fn agent_path_projection(
    operation: &str,
    replacement: &ReplacementProjection,
    readiness: &ReadinessProjection,
    binding: &BindingProjection,
    shadow_trial: &ShadowTrialProjection,
    route: &RouteProjection,
) -> AgentPathProjection {
    let primary = AgentPathStep {
        label: "Inspect this operation's readiness".to_owned(),
        operation: "capability_binding_cockpit_overview".to_owned(),
        payload: serde_json::json!({
            "operation": "capability_binding_cockpit_overview",
            "targetOperation": operation
        }),
        read_only_inspection_safe: true,
        reason: "Returns one exact operation row with role, preflight, binding, shadow, route, rollback, and evidence availability without invoking the adapter.".to_owned(),
    };
    let mut read_only_sequence = vec![
        AgentPathStep {
            label: "Find the exact operation name".to_owned(),
            operation: "catalog_search".to_owned(),
            payload: serde_json::json!({
                "operation": "catalog_search",
                "text": operation,
                "limit": 10
            }),
            read_only_inspection_safe: true,
            reason: "Use executeOperationMatches directly; do not invent operation names from natural language.".to_owned(),
        },
        AgentPathStep {
            label: "Inspect the request schema".to_owned(),
            operation: "catalog_inspect".to_owned(),
            payload: serde_json::json!({
                "operation": "catalog_inspect",
                "kind": "function",
                "id": format!("execute::{operation}"),
                "maxSchemaBytes": 8000
            }),
            read_only_inspection_safe: true,
            reason: "Use exact schema field names before calling the operation.".to_owned(),
        },
        primary.clone(),
    ];
    if replacement.can_replace || replacement.can_shadow || replacement.can_extend {
        read_only_sequence.extend([
            AgentPathStep {
                label: "List replacement candidates".to_owned(),
                operation: "capability_replacement_candidate_list".to_owned(),
                payload: serde_json::json!({
                    "operation": "capability_replacement_candidate_list",
                    "limit": 25
                }),
                read_only_inspection_safe: true,
                reason: "Shows whether a governed candidate exists; an empty list means no candidate has been recorded in scope.".to_owned(),
            },
            AgentPathStep {
                label: "List route bindings".to_owned(),
                operation: "capability_route_binding_list".to_owned(),
                payload: serde_json::json!({
                    "operation": "capability_route_binding_list",
                    "limit": 25
                }),
                read_only_inspection_safe: true,
                reason: "Shows explicit route bindings without activating, disabling, or rolling back routing.".to_owned(),
            },
            AgentPathStep {
                label: "List route events".to_owned(),
                operation: "capability_route_event_list".to_owned(),
                payload: serde_json::json!({
                    "operation": "capability_route_event_list",
                    "limit": 25
                }),
                read_only_inspection_safe: true,
                reason: "Shows routed invocation, activation, disable, rollback, and failed-closed history.".to_owned(),
            },
        ]);
    }
    if binding.requested > 0 || binding.approved > 0 || binding.rejected > 0 {
        read_only_sequence.extend([
            AgentPathStep {
                label: "List binding requests".to_owned(),
                operation: "capability_binding_request_list".to_owned(),
                payload: serde_json::json!({
                    "operation": "capability_binding_request_list",
                    "limit": 25
                }),
                read_only_inspection_safe: true,
                reason: "Shows recorded governance requests; this is read-only and does not create a proposal.".to_owned(),
            },
            AgentPathStep {
                label: "List binding decisions".to_owned(),
                operation: "capability_binding_decision_list".to_owned(),
                payload: serde_json::json!({
                    "operation": "capability_binding_decision_list",
                    "limit": 25
                }),
                read_only_inspection_safe: true,
                reason: "Shows approval or rejection history; this is the safe source for governance outcomes.".to_owned(),
            },
        ]);
    }

    let mut unavailable_surfaces = Vec::new();
    if shadow_trial.available_for_this_operation {
        unavailable_surfaces.extend([
            UnavailableSurfaceProjection {
                operation: "capability_shadow_trial_request_list".to_owned(),
                reason: "No provider-visible list operation exists for shadow trial requests in this slice.".to_owned(),
                alternative: "Use capability_binding_cockpit_overview with targetOperation. When scoped shadow evidence exists, the targeted cockpit row returns exact capability_shadow_trial_evidence_inspect payloads.".to_owned(),
            },
            UnavailableSurfaceProjection {
                operation: "capability_shadow_trial_run_list".to_owned(),
                reason: "No provider-visible list operation exists for shadow trial runs in this slice.".to_owned(),
                alternative: "Use cockpit shadowTrial counts and route events; inspect exact evidence refs from the targeted cockpit row only when present.".to_owned(),
            },
        ]);
    }

    if !shadow_trial.evidence_refs.is_empty() {
        for reference in &shadow_trial.evidence_refs {
            read_only_sequence.push(AgentPathStep {
                label: reference.label.clone(),
                operation: reference.inspect_operation.to_owned(),
                payload: reference.inspect_payload.clone(),
                read_only_inspection_safe: true,
                reason: reference.reason.to_owned(),
            });
        }
    }

    let adapter_execution_guidance = if operation == "git_status" {
        "Do not call git_status just to prove replacement readiness. Use the targeted cockpit overview. Call git_status only when repository status is the task and the workspace is a Git worktree."
            .to_owned()
    } else {
        format!(
            "Do not invoke {operation} just to inspect its replacement readiness. Use the targeted cockpit overview and schema first, then call the operation only if the user task needs its effect."
        )
    };
    let evidence_guidance = if route.route_events > 0 || shadow_trial.runs > 0 {
        "Use route events, shadow evidence, and trace/resource refs returned by the read-only list/inspect operations; do not infer evidence from class labels alone."
            .to_owned()
    } else {
        format!(
            "Current readiness is {}. If counts are zero, say no scoped evidence is recorded instead of searching for unsupported list operations or inspecting evidence schemas.",
            readiness.label
        )
    };
    let completion = agent_path_completion_projection(readiness, shadow_trial, route);

    AgentPathProjection {
        purpose: "Agent-native read-only path from operation discovery to readiness evidence."
            .to_owned(),
        primary_inspection: primary,
        read_only_sequence,
        unavailable_surfaces,
        completion,
        adapter_execution_guidance,
        evidence_guidance,
    }
}

fn agent_path_completion_projection(
    readiness: &ReadinessProjection,
    shadow_trial: &ShadowTrialProjection,
    route: &RouteProjection,
) -> AgentPathCompletionProjection {
    let has_shadow_evidence = !shadow_trial.evidence_refs.is_empty() || shadow_trial.runs > 0;
    let has_route_evidence =
        route.route_events > 0 || route.active_routes > 0 || route.bindings > 0;
    let readiness_verdict = readiness_verdict_projection(
        readiness,
        shadow_trial,
        route,
        has_shadow_evidence,
        has_route_evidence,
    );
    let read_only_boundary = read_only_boundary_projection();
    let governed_next_steps = governed_next_steps_projection(readiness, route);
    if has_shadow_evidence || has_route_evidence {
        AgentPathCompletionProjection {
            state: "continue_with_returned_evidence_refs".to_owned(),
            action: "inspect_returned_refs_only".to_owned(),
            reason: "The targeted cockpit row returned scoped evidence or route activity.".to_owned(),
            stop_when: "After inspecting the exact refs returned by this row and any listed read-only route operations."
                .to_owned(),
            final_answer_guidance: "Answer from targeted cockpit facts, exact evidence refs, route events, and provider-safe trace/resource projections."
                .to_owned(),
            readiness_verdict,
            read_only_boundary,
            governed_next_steps,
            do_not_inspect: vec![AgentPathDoNotInspectProjection {
                operation: "unsupported_shadow_trial_list_operations".to_owned(),
                reason:
                    "Use exact refs returned by the targeted cockpit row; do not invent list operations."
                        .to_owned(),
            }],
        }
    } else {
        AgentPathCompletionProjection {
            state: "answer_now_no_current_scope_evidence".to_owned(),
            action: "stop_after_targeted_cockpit".to_owned(),
            reason: format!(
                "The targeted cockpit row is {} and returned zero shadow evidence refs, zero shadow runs, zero route bindings, and zero route events.",
                readiness.label
            ),
            stop_when: "When the targeted cockpit row has zero shadowTrial.evidenceRefs, shadowTrial.runs, route.bindings, active routes, and route.routeEvents."
                .to_owned(),
            final_answer_guidance: "State that no current-scope shadow or route evidence is recorded for this operation, and do not inspect evidence schemas without an exact evidence resource id."
                .to_owned(),
            readiness_verdict,
            read_only_boundary,
            governed_next_steps,
            do_not_inspect: vec![
                AgentPathDoNotInspectProjection {
                    operation: "capability_shadow_trial_evidence_inspect".to_owned(),
                    reason: "No exact capabilityShadowTrialEvidenceResourceId was returned, so schema inspection cannot produce evidence."
                        .to_owned(),
                },
                AgentPathDoNotInspectProjection {
                    operation:
                        "catalog_inspect execute::capability_shadow_trial_evidence_inspect"
                            .to_owned(),
                    reason: "Inspecting the evidence operation schema is unnecessary when the targeted cockpit row already proves that no scoped evidence refs exist."
                        .to_owned(),
                },
            ],
        }
    }
}

fn readiness_verdict_projection(
    readiness: &ReadinessProjection,
    shadow_trial: &ShadowTrialProjection,
    route: &RouteProjection,
    has_shadow_evidence: bool,
    has_route_evidence: bool,
) -> AgentPathReadinessVerdictProjection {
    let ready_for_routing = readiness.state == "runtime_route_active";
    let stop_now = !has_shadow_evidence && !has_route_evidence;
    let current_scope_state = if ready_for_routing {
        "active_runtime_route_recorded"
    } else if has_shadow_evidence || has_route_evidence {
        "current_scope_evidence_available"
    } else {
        "no_current_scope_shadow_or_route_evidence"
    };
    AgentPathReadinessVerdictProjection {
        ready_for_routing,
        final_answer_ready: stop_now,
        stop_now,
        current_scope_state: current_scope_state.to_owned(),
        current_scope_evidence: AgentPathEvidenceCountsProjection {
            shadow_evidence_refs: shadow_trial.evidence_refs.len(),
            shadow_runs: shadow_trial.runs,
            route_bindings: route.bindings,
            active_routes: route.active_routes,
            route_events: route.route_events,
        },
    }
}

fn read_only_boundary_projection() -> AgentPathReadOnlyBoundaryProjection {
    AgentPathReadOnlyBoundaryProjection {
        capability_requested_mutation: false,
        engine_audit_persistence: true,
        required_final_answer_suffix: "capabilityRequestedMutation=false; engineAuditPersistence=true",
        detail: "Read-only capability inspection must not request target effects or governance writes, but the engine still records session, trace, resource, and audit evidence so the run can be replayed. The final answer must end with requiredFinalAnswerSuffix as one unchanged line.",
    }
}

fn governed_next_steps_projection(
    readiness: &ReadinessProjection,
    route: &RouteProjection,
) -> Vec<AgentPathNextStepProjection> {
    if route.active_routes > 0 {
        return vec![
            AgentPathNextStepProjection {
                order: 1,
                operation: "capability_route_event_list",
                effect: "read_route_history",
                requires_approval: false,
                reason: "Inspect routed invocation and activation history before changing an active route.",
            },
            AgentPathNextStepProjection {
                order: 2,
                operation: "capability_route_disable",
                effect: "metadata_write",
                requires_approval: true,
                reason: "Disable the active scoped route only when the user or policy asks to stop using it.",
            },
            AgentPathNextStepProjection {
                order: 3,
                operation: "capability_route_rollback",
                effect: "metadata_write",
                requires_approval: true,
                reason: "Roll back when verification fails or built-in ownership must be restored.",
            },
        ];
    }
    if !matches!(
        readiness.state.as_str(),
        "proposal_possible"
            | "route_candidate_recorded"
            | "metadata_policy_active"
            | "needs_governance_review"
            | "shadow_evidence_recorded"
            | "awaiting_governance"
            | "route_failed_closed"
            | "route_disabled"
            | "route_rolled_back"
    ) {
        return Vec::new();
    }
    vec![
        AgentPathNextStepProjection {
            order: 1,
            operation: "capability_replacement_candidate_record",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Record the candidate module, contract, authority, rollback, and safety rationale.",
        },
        AgentPathNextStepProjection {
            order: 2,
            operation: "capability_shadow_trial_request_record",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Request a shadow comparison without routing live user calls.",
        },
        AgentPathNextStepProjection {
            order: 3,
            operation: "capability_shadow_trial_decision_record",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Record governance approval or denial before any shadow run.",
        },
        AgentPathNextStepProjection {
            order: 4,
            operation: "capability_shadow_trial_run_record",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Persist bounded built-in versus candidate comparison evidence.",
        },
        AgentPathNextStepProjection {
            order: 5,
            operation: "capability_shadow_trial_evidence_inspect",
            effect: "read_evidence",
            requires_approval: false,
            reason: "Inspect only the exact evidence resource id returned by the shadow run.",
        },
        AgentPathNextStepProjection {
            order: 6,
            operation: "capability_binding_request_record",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Request binding only after candidate and shadow evidence prove contract compatibility.",
        },
        AgentPathNextStepProjection {
            order: 7,
            operation: "capability_binding_decision_record",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Record approval or denial for the proposed binding.",
        },
        AgentPathNextStepProjection {
            order: 8,
            operation: "capability_binding_policy_activate",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Activate governance policy metadata before runtime routing.",
        },
        AgentPathNextStepProjection {
            order: 9,
            operation: "capability_route_binding_record",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Create the exact scoped route binding with rollback proof.",
        },
        AgentPathNextStepProjection {
            order: 10,
            operation: "capability_route_activate",
            effect: "metadata_write",
            requires_approval: true,
            reason: "Activate the route only after all prior governed evidence exists.",
        },
        AgentPathNextStepProjection {
            order: 11,
            operation: "capability_route_event_list",
            effect: "read_route_history",
            requires_approval: false,
            reason: "Verify activation, routed invocations, failed-closed events, and rollback history.",
        },
    ]
}

fn capability_pool_role_projection(
    metadata: &CapabilityPoolMetadata<'_>,
) -> CapabilityPoolRoleProjection {
    CapabilityPoolRoleProjection {
        surface: metadata.surface.as_str(),
        audience: metadata.audience.as_str(),
        replacement_class: metadata.replacement_class.as_str(),
        agent_default_visibility: metadata.agent_default_visibility.as_str(),
        minimality_decision: metadata.minimality_decision.as_str(),
        evolution_path: metadata.evolution_path,
    }
}

fn owner_projection(family: &str, current_owner: &str, ownership_class: &str) -> OwnerProjection {
    OwnerProjection {
        label: owner_label(family, current_owner, ownership_class),
        detail: match ownership_class {
            "kernel_locked" => "The engine kernel owns this operation and modules cannot take it over.",
            "governance_locked" => "The governance pipeline owns this operation because it controls module trust.",
            "record_plane" => "The server record plane owns durable custody; modules may only add governed producers.",
            "adapter_replaceable" => "A built-in adapter owns execution today and can be proposed for governed replacement later.",
            "module_owned" => "A governed module/runtime pack owns this operation today.",
            _ => "Ownership has not been resolved for module binding.",
        }
        .to_owned(),
        source: "capability execute registry redacted ownership metadata plus scoped capability binding resources",
        metadata_source_label: "Capability execute registry",
        projection_source_label: "Capability binding cockpit projection",
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

fn replacement_projection(
    family: &str,
    ownership_class: &str,
    replacement_target: &str,
) -> ReplacementProjection {
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
        target: replacement_target_projection(family, ownership_class, replacement_target),
        governance_boundary: "capability binding policy",
    }
}

fn replacement_target_projection(
    family: &str,
    ownership_class: &str,
    replacement_target: &str,
) -> ReplacementTargetProjection {
    let family_label = family_label(family);
    let label = match ownership_class {
        "kernel_locked" => "Engine-owned kernel responsibility".to_owned(),
        "governance_locked" => format!("{family_label} governance responsibility"),
        "record_plane" => format!("{family_label} extension producer"),
        "adapter_replaceable" => format!("Governed {family_label} adapter"),
        "module_owned" => format!("Governed {family_label} module pack"),
        _ => "Unresolved target".to_owned(),
    };
    let detail = if replacement_target.contains("requires_exact")
        || replacement_target.contains("requires_supervised")
    {
        "Any future target must satisfy exact authority, parity evidence, bounded provider-safe refs, replay/idempotency proof, and rollback/disable metadata."
    } else if replacement_target.contains("stays_engine_owned") {
        "The target remains engine-owned; cockpit clients must treat this as observe-only metadata."
    } else if replacement_target.contains("modules_may_extend") {
        "Future modules may add governed producers or workflows without bypassing server-owned custody."
    } else if replacement_target.contains("governance_pipeline") {
        "The target is part of the module governance pipeline and is not a runtime replacement route."
    } else if replacement_target.contains("already_module_owned") {
        "The target is already module-owned and remains behind lifecycle, runtime, rollback, and disable governance."
    } else {
        "The replacement target is intentionally summarized; raw registry target strings are not returned."
    };
    ReplacementTargetProjection {
        label,
        detail: detail.to_owned(),
    }
}

fn readiness_projection(
    ownership_class: &str,
    facts: &OperationFacts,
    replacement: &ReplacementProjection,
) -> ReadinessProjection {
    let (state, label, detail, next_action_label, next_action_detail) = if facts
        .route
        .has_active_route()
    {
        (
            "runtime_route_active",
            "Runtime route active",
            "A governed scoped route is active for this operation. Invocations use the supervised module-runtime adapter projection boundary.",
            "Monitor route events",
            "Use route events and rollback controls to verify or restore built-in ownership.",
        )
    } else if facts.route.failed_closed > 0 {
        (
            "route_failed_closed",
            "Route failed closed",
            "A routed replacement attempt failed closed; the server did not report built-in success as the replacement result.",
            "Inspect route event",
            "Review route events, runtime refs, and rollback evidence before another activation attempt.",
        )
    } else if facts.route.rolled_back > 0 || facts.route.rollback_records > 0 {
        (
            "route_rolled_back",
            "Route rolled back",
            "A previous active route was rolled back and built-in ownership is restored for future lookups.",
            "Review rollback",
            "Use route rollback evidence before proposing another replacement.",
        )
    } else if facts.route.disabled > 0 {
        (
            "route_disabled",
            "Route disabled",
            "A previous active route was disabled and no active route is currently selected.",
            "Review route history",
            "Inspect route events before deciding whether to reactivate or roll back.",
        )
    } else if facts.route.bindings > 0 || facts.route.candidates > 0 {
        (
            "route_candidate_recorded",
            "Route candidate recorded",
            "A governed route candidate or binding exists, but no active route is currently selected.",
            "Review route candidate",
            "Confirm candidate, shadow evidence, approval refs, and rollback controls before activation.",
        )
    } else if facts.binding.active_policies > 0 {
        (
            "metadata_policy_active",
            "Policy metadata active",
            "A capability binding policy record is active, but this projection confirms runtime routing still has not changed.",
            "Review before routing",
            "Treat this as governance metadata only until a later runtime slice supplies routing proof.",
        )
    } else if facts.binding.failed_replacement_attempts > 0
        || facts.binding.rejected > 0
        || facts.shadow.failed > 0
    {
        (
            "needs_governance_review",
            "Review needed",
            "At least one binding or shadow outcome in this scope needs governance review before any replacement conclusion is safe.",
            "Inspect decisions",
            "Use the recorded governance evidence; do not infer readiness from the operation class alone.",
        )
    } else if facts.shadow.runs > 0 {
        (
            "shadow_evidence_recorded",
            "Shadow evidence recorded",
            "A metadata-only shadow trial exists for this scope; candidate execution and live routing remain disabled.",
            "Review evidence",
            "Review the shadow evidence before considering any future replacement path.",
        )
    } else if facts.binding.requested > 0 || facts.shadow.requested > 0 {
        (
            "awaiting_governance",
            "Awaiting governance",
            "A request exists in this scope, but no server-owned decision makes it ready for replacement.",
            "Wait for decision",
            "Display the recorded request as pending metadata only.",
        )
    } else if matches!(ownership_class, "kernel_locked" | "governance_locked") {
        (
            "locked",
            "Engine-owned",
            "The server registry marks this operation as locked; replacement readiness is not available.",
            "Observe only",
            "Show current ownership and do not offer replacement affordances.",
        )
    } else if replacement.can_replace {
        (
            "proposal_possible",
            "Governed proposal possible",
            "The server registry allows a future shadow or replacement proposal, but no current-scope request makes it ready.",
            "Record governed proposal",
            "Any proposal must come through capability binding metadata with exact authority and rollback evidence.",
        )
    } else if replacement.can_extend {
        (
            "extension_possible",
            "Extension possible",
            "The server registry allows future governed extension without bypassing server-owned records.",
            "Record extension proposal",
            "Treat this as an extension path only, not as replacement readiness.",
        )
    } else {
        (
            "unknown",
            "Readiness unknown",
            "The server cannot truthfully derive replacement readiness for this operation yet.",
            "Do not infer",
            "Display the degraded state until ownership metadata becomes more precise.",
        )
    };
    ReadinessProjection {
        state: state.to_owned(),
        label: label.to_owned(),
        detail: detail.to_owned(),
        next_action_label: next_action_label.to_owned(),
        next_action_detail: next_action_detail.to_owned(),
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

fn shadow_projection(
    operation: &str,
    facts: &ShadowFacts,
    include_evidence_refs: bool,
) -> ShadowTrialProjection {
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
    let evidence_refs = if include_evidence_refs {
        facts
            .evidence_refs
            .iter()
            .enumerate()
            .map(|(index, reference)| shadow_evidence_ref_projection(index, reference))
            .collect()
    } else {
        Vec::new()
    };
    let evidence_inspect_ready = !evidence_refs.is_empty();
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
        evidence_refs,
        evidence_inspect_ready,
        available_for_this_operation: operation == "git_status",
        detail,
    }
}

fn shadow_evidence_ref_projection(
    index: usize,
    reference: &ShadowEvidenceRef,
) -> ShadowEvidenceRefProjection {
    let mut inspect_payload = serde_json::json!({
        "operation": "capability_shadow_trial_evidence_inspect",
        "capabilityShadowTrialEvidenceResourceId": reference.resource_id
    });
    if let Some(version_id) = reference.version_id.as_deref() {
        inspect_payload["expectedCapabilityShadowTrialEvidenceVersionId"] =
            Value::String(version_id.to_owned());
    }
    ShadowEvidenceRefProjection {
        label: format!("Inspect shadow evidence {}", index + 1),
        resource_id: reference.resource_id.clone(),
        version_id: reference.version_id.clone(),
        state: reference.state.clone(),
        updated_at: reference.updated_at.clone(),
        inspect_operation: "capability_shadow_trial_evidence_inspect",
        inspect_payload,
        reason: "Exact provider-safe shadow evidence ref from the targeted cockpit row; inspect it instead of guessing unsupported shadow-trial list operations.",
    }
}

fn route_projection(facts: &RouteFacts) -> RouteProjection {
    let active_routes = facts.active_route_count();
    let (state, label, detail) = if active_routes > 0 {
        (
            "active",
            "Active route",
            format!(
                "{} governed route{} active; {} routed invocation{} recorded.",
                active_routes,
                plural(active_routes),
                facts.routed_invocations,
                plural(facts.routed_invocations)
            ),
        )
    } else if facts.failed_closed > 0 {
        (
            "failed_closed",
            "Failed closed",
            format!(
                "{} route event{} failed closed; no built-in success was projected as the replacement result.",
                facts.failed_closed,
                plural(facts.failed_closed)
            ),
        )
    } else if facts.rolled_back > 0 || facts.rollback_records > 0 {
        let rollback_count = facts.rolled_back.max(facts.rollback_records);
        (
            "rolled_back",
            "Rolled back",
            format!(
                "{} rollback event{} recorded; built-in ownership is restored.",
                rollback_count,
                plural(rollback_count)
            ),
        )
    } else if facts.disabled > 0 {
        (
            "disabled",
            "Disabled",
            format!(
                "{} disable event{} recorded; no active route is selected.",
                facts.disabled,
                plural(facts.disabled)
            ),
        )
    } else if facts.bindings > 0 || facts.candidates > 0 {
        (
            "candidate",
            "Candidate recorded",
            format!(
                "{} candidate{} and {} binding{} recorded; activation has not changed runtime routing.",
                facts.candidates,
                plural(facts.candidates),
                facts.bindings,
                plural(facts.bindings)
            ),
        )
    } else {
        (
            "none",
            "No runtime route",
            "No dynamic replacement route records exist for this operation in the current scope."
                .to_owned(),
        )
    };
    RouteProjection {
        candidates: facts.candidates,
        bindings: facts.bindings,
        active_routes,
        route_events: facts.route_events,
        routed_invocations: facts.routed_invocations,
        failed_closed: facts.failed_closed,
        disabled: facts.disabled,
        rolled_back: facts.rolled_back,
        rollback_records: facts.rollback_records,
        rollback_available: facts.rollback_available,
        disable_available: facts.disable_available,
        latest_state: facts.latest_state.clone(),
        last_updated_at: facts.last_updated_at.clone(),
        state: state.to_owned(),
        label: label.to_owned(),
        detail,
    }
}

fn rollback_projection(ownership_class: &str, facts: &OperationFacts) -> RollbackProjection {
    let available = facts.binding.rollback_available
        || facts.shadow.rollback_available
        || facts.route.rollback_available
        || facts.route.rolled_back > 0
        || facts.route.has_active_route();
    let disable_available = facts.binding.disable_available
        || facts.shadow.disable_available
        || facts.route.disable_available
        || facts.route.has_active_route();
    let abort_available = facts.shadow.abort_available;
    let detail = if facts.route.has_active_route() {
        "An active runtime replacement route has rollback and disable controls recorded; built-in ownership can be restored through route governance."
            .to_owned()
    } else if facts.route.rolled_back > 0 || facts.route.rollback_records > 0 {
        "A runtime replacement route was rolled back; built-in ownership has been restored through route governance."
            .to_owned()
    } else if facts.route.disabled > 0 {
        "A runtime replacement route was disabled; no active replacement route is selected."
            .to_owned()
    } else if available {
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
        boundary: "capability binding and route governance",
        detail,
    }
}

fn operation_list_projection(
    total_operations: usize,
    returned_operations: usize,
    requested_limit: usize,
    target_operation: Option<String>,
) -> OperationListProjection {
    let filter_applied = target_operation.is_some();
    let truncated = !filter_applied && returned_operations < total_operations;
    let label = if filter_applied {
        "Operation filter applied"
    } else if truncated {
        "Operation list truncated"
    } else {
        "Operation list complete"
    };
    let detail = if let Some(target_operation) = target_operation.as_deref() {
        format!(
            "1 of {total_operations} operations is returned for exact targetOperation {target_operation}."
        )
    } else if truncated {
        format!(
            "{returned_operations} of {total_operations} operations are returned because the client requested limit {requested_limit}."
        )
    } else {
        format!("{returned_operations} of {total_operations} operations are returned.")
    };
    OperationListProjection {
        total_operations,
        returned_operations,
        requested_limit,
        target_operation,
        filter_applied,
        complete: !truncated,
        truncated,
        state: if filter_applied {
            "filtered"
        } else if truncated {
            "truncated"
        } else {
            "complete"
        },
        label: label.to_owned(),
        detail,
    }
}

fn resource_scan_projection(scan: ResourceScanFacts) -> ResourceScanProjection {
    let truncated = scan.truncated_queries > 0;
    let label = if truncated {
        "Resource scan bounded"
    } else {
        "Resource scan complete"
    };
    let detail = if truncated {
        format!(
            "{} of {} kind/scope scan{} reached the per-scan limit of {}; binding, shadow, and route counts are lower-bound facts.",
            scan.truncated_queries,
            scan.queries,
            plural(scan.queries),
            scan.limit_per_kind_scope
        )
    } else {
        format!(
            "{} resources scanned across {} kind/scope scan{}; all bounded scans completed.",
            scan.scanned_resources,
            scan.queries,
            plural(scan.queries)
        )
    };
    ResourceScanProjection {
        queries: scan.queries,
        scanned_resources: scan.scanned_resources,
        applied_resources: scan.applied_resources,
        limit_per_kind_scope: scan.limit_per_kind_scope,
        complete: !truncated,
        truncated,
        truncated_queries: scan.truncated_queries,
        state: if truncated {
            "bounded_degraded"
        } else {
            "complete"
        },
        label: label.to_owned(),
        detail,
    }
}

fn summary(
    operations: &[OperationVisibility],
    returned_operations: usize,
    operation_list: &OperationListProjection,
    resource_scan: &ResourceScanProjection,
) -> CockpitSummary {
    let mut summary = CockpitSummary {
        total_operations: operations.len(),
        returned_operations,
        operation_list_complete: operation_list.complete,
        operation_list_truncated: operation_list.truncated,
        resource_scan_complete: resource_scan.complete,
        resource_scan_truncated: resource_scan.truncated,
        title: "Capability ownership visible".to_owned(),
        detail: format!(
            "{} capability::execute operations have server-owned modularity metadata; {} are returned.",
            operations.len(),
            returned_operations
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
        summary.route_candidates += operation.route.candidates;
        summary.active_routes += operation.route.active_routes;
        summary.route_events += operation.route.route_events;
        summary.routed_invocations += operation.route.routed_invocations;
        summary.failed_closed_routes += operation.route.failed_closed;
        summary.route_rollbacks += operation
            .route
            .rolled_back
            .max(operation.route.rollback_records);
        if operation.rollback.available {
            summary.rollback_available += 1;
        }
    }
    if operation_list.truncated || resource_scan.truncated {
        summary.detail = format!(
            "{} of {} operations returned; {}",
            returned_operations,
            summary.total_operations,
            if resource_scan.truncated {
                "resource counts are bounded lower-bound facts"
            } else {
                "resource scan is complete"
            }
        );
    } else if summary.active_routes > 0 || summary.route_events > 0 {
        summary.detail = format!(
            "{} operations returned from {} total, {} active route{}, {} route event{} in this scope.",
            summary.returned_operations,
            summary.total_operations,
            summary.active_routes,
            plural(summary.active_routes),
            summary.route_events,
            plural(summary.route_events)
        );
    } else if summary.binding_requests > 0 || summary.shadow_requests > 0 {
        summary.detail = format!(
            "{} operations returned from {} total, {} binding request{}, {} shadow request{} in this scope.",
            summary.returned_operations,
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
                route_activity: 0,
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
        entry.route_activity += operation.route.candidates
            + operation.route.bindings
            + operation.route.route_events
            + operation.route.rollback_records;
    }
    families.into_values().collect()
}

fn route_stories(operations: &[OperationVisibility]) -> Vec<RouteStoryProjection> {
    let mut stories = operations
        .iter()
        .filter_map(route_story)
        .collect::<Vec<_>>();
    stories.sort_by(|left, right| {
        route_story_rank(left.kind)
            .cmp(&route_story_rank(right.kind))
            .then_with(|| {
                right
                    .last_updated_at
                    .as_deref()
                    .unwrap_or_default()
                    .cmp(left.last_updated_at.as_deref().unwrap_or_default())
            })
            .then_with(|| left.operation.cmp(&right.operation))
    });
    stories.truncate(8);
    stories
}

fn route_story(operation: &OperationVisibility) -> Option<RouteStoryProjection> {
    let route = &operation.route;
    let operation_name = operation.name.clone();
    let evidence_count =
        route.route_events + route.candidates + route.bindings + route.rollback_records;
    if route.active_routes > 0 {
        return Some(RouteStoryProjection {
            kind: "active_route",
            operation: operation_name.clone(),
            title: format!("{operation_name} is using a governed replacement route"),
            detail: format!(
                "{} routed invocation{} recorded. Rollback {} and disable {}.",
                route.routed_invocations,
                plural(route.routed_invocations),
                availability_label(route.rollback_available),
                availability_label(route.disable_available)
            ),
            status: "active".to_owned(),
            evidence_count,
            last_updated_at: route.last_updated_at.clone(),
            drill_down_label: "Inspect route evidence",
        });
    }
    if route.failed_closed > 0 {
        return Some(RouteStoryProjection {
            kind: "failed_closed",
            operation: operation_name.clone(),
            title: format!("{operation_name} replacement failed closed"),
            detail: format!(
                "{} failed-closed route event{} recorded; the engine did not project a built-in success result as replacement output.",
                route.failed_closed,
                plural(route.failed_closed)
            ),
            status: "needs_review".to_owned(),
            evidence_count,
            last_updated_at: route.last_updated_at.clone(),
            drill_down_label: "Inspect failure evidence",
        });
    }
    if route.rolled_back > 0 || route.rollback_records > 0 {
        return Some(RouteStoryProjection {
            kind: "rolled_back",
            operation: operation_name.clone(),
            title: format!("{operation_name} returned to built-in ownership"),
            detail: format!(
                "{} rollback record{} or event{} prove built-in ownership was restored.",
                route.rollback_records.max(route.rolled_back),
                plural(route.rollback_records.max(route.rolled_back)),
                plural(route.rollback_records.max(route.rolled_back))
            ),
            status: "restored".to_owned(),
            evidence_count,
            last_updated_at: route.last_updated_at.clone(),
            drill_down_label: "Inspect rollback evidence",
        });
    }
    if route.disabled > 0 {
        return Some(RouteStoryProjection {
            kind: "disabled",
            operation: operation_name.clone(),
            title: format!("{operation_name} replacement route was disabled"),
            detail: format!(
                "{} disable event{} recorded; no active replacement route is selected.",
                route.disabled,
                plural(route.disabled)
            ),
            status: "disabled".to_owned(),
            evidence_count,
            last_updated_at: route.last_updated_at.clone(),
            drill_down_label: "Inspect route history",
        });
    }
    if route.candidates > 0 || route.bindings > 0 {
        return Some(RouteStoryProjection {
            kind: "candidate",
            operation: operation_name.clone(),
            title: format!("{operation_name} has a replacement candidate"),
            detail: format!(
                "{} candidate{} and {} binding{} exist; runtime routing has not changed.",
                route.candidates,
                plural(route.candidates),
                route.bindings,
                plural(route.bindings)
            ),
            status: "candidate".to_owned(),
            evidence_count,
            last_updated_at: route.last_updated_at.clone(),
            drill_down_label: "Inspect candidate evidence",
        });
    }
    None
}

fn route_story_rank(kind: &str) -> usize {
    match kind {
        "failed_closed" => 0,
        "active_route" => 1,
        "candidate" => 2,
        "disabled" => 3,
        "rolled_back" => 4,
        _ => 5,
    }
}

fn availability_label(available: bool) -> &'static str {
    if available {
        "available"
    } else {
        "not published"
    }
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

fn route_event_activation_id(payload: &Value) -> Option<String> {
    payload
        .pointer("/activation/resourceId")
        .and_then(Value::as_str)
        .or_else(|| {
            payload
                .pointer("/activation/resource/resourceId")
                .and_then(Value::as_str)
        })
        .map(str::to_owned)
}

fn owner_label(family: &str, current_owner: &str, ownership_class: &str) -> String {
    let family_label = family_label(family);
    match ownership_class {
        "kernel_locked" => "Engine kernel".to_owned(),
        "governance_locked" => format!("{family_label} governance"),
        "record_plane" => format!("{family_label} record plane"),
        "adapter_replaceable" if current_owner.contains(" + ") => {
            format!("Built-in {family_label} adapter")
        }
        "adapter_replaceable" => format!("Built-in {family_label} adapter"),
        "module_owned" => format!("{family_label} module pack"),
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
        "future_git_adapter_requires",
        "resource:git_status_shadow_projection",
    ];
    let found = forbidden
        .into_iter()
        .filter(|needle| serialized.contains(needle))
        .collect::<Vec<_>>();
    if !found.is_empty() {
        eprintln!("cockpit projection contains forbidden material: {found:?}");
    }
    found.is_empty()
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
