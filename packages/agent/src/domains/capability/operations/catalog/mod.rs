use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::ok_result;
use super::{is_supported_operation, supported_operation_names};
use crate::domains::capability::Deps;
use crate::domains::capability::pool::{
    catalog_function_agent_usage_projection, catalog_function_pool_metadata,
    operation_agent_usage_projection, operation_pool_metadata,
};
use crate::domains::catalog_discovery::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn catalog_search(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let mut discovery =
        service::search_catalog_value(&deps.engine_host, invocation, &invocation.payload).await?;
    annotate_model_facing_invocation(&mut discovery, &invocation.payload);
    annotate_execute_operation_matches(&mut discovery, &invocation.payload);
    let content = catalog_search_content(&discovery);
    Ok(ok_result(
        content,
        json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": discovery
        }),
    ))
}

fn catalog_search_content(discovery: &Value) -> String {
    let visible = discovery
        .pointer("/summary/functions/visible")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let operation_matches = discovery
        .get("executeOperationMatches")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    let operation_search_total = discovery
        .get("executeOperationSearch")
        .and_then(|search| search.get("totalMatches"))
        .and_then(Value::as_u64);
    let mut content = if operation_matches > 0 {
        format!(
            "Catalog search returned {operation_matches} provider-visible execute operation match(es) and {visible} diagnostic catalog function match(es)."
        )
    } else if operation_search_total == Some(0) {
        format!(
            "Catalog search found 0 provider-visible execute operation matches and {visible} diagnostic catalog function match(es)."
        )
    } else {
        format!("Catalog search returned {visible} diagnostic catalog function match(es).")
    };
    if let Some(search) = discovery.get("executeOperationSearch") {
        let total = search
            .get("totalMatches")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let omitted = search.get("omitted").and_then(Value::as_u64).unwrap_or(0);
        let truncated = search
            .get("truncated")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let excluded = search
            .get("effectClassExcludedMatches")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if truncated {
            content.push_str(&format!(
                " Search truncated: {omitted} additional execute operation match(es) omitted."
            ));
        } else {
            content.push_str(&format!(
                " Search complete: all {total} matching execute operation(s) returned."
            ));
        }
        if excluded > 0 {
            content.push_str(&format!(
                " {excluded} supported operation(s) were excluded by the requested effect class because they are not safe for that discovery mode."
            ));
        }
    }
    if let Some(candidates) = discovery
        .get("unsupportedOperationCandidates")
        .and_then(Value::as_array)
        .filter(|candidates| !candidates.is_empty())
    {
        let names = candidates
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(", ");
        content.push_str(&format!(
            " Explicit unsupported operation candidate(s): {names}. Do not invoke or inspect those names as supported operations; follow unsupportedOperationRecovery."
        ));
    }
    content
}

pub(super) async fn catalog_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    if let Some((operation, alias)) = execute_operation_inspect_target(&invocation.payload) {
        let include_output_schema = invocation
            .payload
            .get("includeOutputSchema")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let discovery = execute_operation_inspect_projection_with_options(
            &operation,
            &alias,
            include_output_schema,
        );
        let kind = discovery["kind"].as_str().unwrap_or("execute_operation");
        let id = discovery["id"].as_str().unwrap_or("unknown");
        let required_fields = discovery
            .pointer("/schema/requiredPayloadFields")
            .and_then(Value::as_array)
            .map(|fields| {
                fields
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .filter(|fields| !fields.is_empty())
            .unwrap_or_else(|| "operation".to_owned());
        return Ok(ok_result(
            format!(
                "Catalog {kind} inspected: {id}. Required top-level payload fields: {required_fields}.{}{}",
                execute_operation_invocation_guidance(&operation),
                if include_output_schema {
                    " Output schema included."
                } else {
                    " Output schema omitted by default; repeat catalog_inspect with includeOutputSchema=true only when the result contract is needed."
                }
            ),
            json!({
                "primitiveOperation": "catalog_inspect",
                "status": "ok",
                "catalogDiscovery": discovery
            }),
        ));
    }
    if let Some(candidate) = unsupported_execute_operation_inspect_candidate(&invocation.payload) {
        let recovery = unsupported_operation_recovery_projection(&candidate);
        return Ok(ok_result(
            format!(
                "Catalog inspect found no provider-visible operation named {}. Do not invoke this name; follow unsupportedOperationRecovery.",
                candidate.canonical
            ),
            json!({
                "primitiveOperation": "catalog_inspect",
                "status": "ok",
                "catalogDiscovery": {
                    "kind": "execute_operation",
                    "id": format!("execute::{}", candidate.canonical),
                    "found": false,
                    "providerCallable": false,
                    "unsupportedOperationCandidate": true,
                    "unsupportedOperationRecovery": recovery
                }
            }),
        ));
    }

    let (payload, alias) = normalize_catalog_inspect_payload(&invocation.payload);
    let normalized_invocation = Invocation {
        payload,
        ..invocation.clone()
    };
    let mut discovery = service::inspect_catalog_value(
        &deps.engine_host,
        &normalized_invocation,
        &normalized_invocation.payload,
    )
    .await?;
    if let Some(alias) = alias {
        if let Some(object) = discovery.as_object_mut() {
            object.insert("aliasResolvedFrom".to_owned(), Value::String(alias));
        }
    }
    annotate_model_facing_invocation(&mut discovery, &json!({}));
    let kind = discovery["kind"].as_str().unwrap_or("item");
    let id = discovery["id"].as_str().unwrap_or("unknown");
    Ok(ok_result(
        format!("Catalog {kind} inspected: {id}."),
        json!({
            "primitiveOperation": "catalog_inspect",
            "status": "ok",
            "catalogDiscovery": discovery
        }),
    ))
}

fn execute_operation_inspect_target(payload: &Value) -> Option<(String, String)> {
    let kind = payload.get("kind").and_then(Value::as_str)?;
    if kind != "function" {
        return None;
    }
    let id = payload.get("id").and_then(Value::as_str)?;
    let operation = id.strip_prefix("execute::").unwrap_or(id);
    if is_supported_operation(operation) {
        Some((operation.to_owned(), id.to_owned()))
    } else {
        None
    }
}

fn unsupported_execute_operation_inspect_candidate(
    payload: &Value,
) -> Option<OperationSearchQuery> {
    if payload.get("kind").and_then(Value::as_str)? != "function" {
        return None;
    }
    let id = payload.get("id").and_then(Value::as_str)?;
    let candidate = OperationSearchQuery::from_text(id.strip_prefix("execute::").unwrap_or(id))?;
    (!is_supported_operation(&candidate.canonical)
        && looks_like_unsupported_operation_candidate(&candidate))
    .then_some(candidate)
}

#[cfg(test)]
fn execute_operation_inspect_projection(operation: &str, alias: &str) -> Value {
    execute_operation_inspect_projection_with_options(operation, alias, false)
}

fn execute_operation_inspect_projection_with_options(
    operation: &str,
    alias: &str,
    include_output_schema: bool,
) -> Value {
    let id = format!("execute::{operation}");
    let agent_usage = operation_agent_usage_projection(operation)
        .expect("supported execute operation has canonical agent usage");
    let input_schema = execute_operation_input_schema(operation);
    let required_payload_fields = input_schema
        .get("required")
        .and_then(Value::as_array)
        .cloned()
        .expect("canonical input contract declares required payload fields");
    let effect = agent_usage.get("effect").cloned();
    let preflight = agent_usage.get("preflight").cloned();
    let schema_completeness = input_schema
        .get("schemaCompleteness")
        .cloned()
        .expect("canonical input contract declares schema completeness");
    let capability_pool = operation_contextual_pool_projection(
        operation,
        operation_pool_metadata(operation)
            .expect("supported execute operation has canonical pool metadata")
            .provider_projection(),
    );
    let model_facing_invocation = json!({
        "tool": "capability::execute",
        "operation": operation,
        "arguments": {"operation": operation},
        "catalogInspectId": id,
        "capabilityPool": capability_pool.clone(),
        "agentUsage": agent_usage.clone()
    });

    let mut projection = json!({
        "kind": "execute_operation",
        "id": id,
        "operation": operation,
        "summary": format!("Provider-visible capability::execute operation {operation}."),
        "providerCallable": true,
        "providerCallableReason": "Invoke through the single provider-visible capability::execute tool with this operation value.",
        "inputSchema": input_schema.clone(),
        "modelFacingInvocation": model_facing_invocation,
        "capabilityPool": capability_pool,
        "agentUsage": agent_usage,
        "schema": {
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation},
            "requiredPayloadFields": required_payload_fields,
            "payloadPlacement": "Put operation-specific fields at the top level of the capability::execute payload.",
            "schemaCompleteness": schema_completeness,
            "effect": effect,
            "preflight": preflight
        }
    });
    if include_output_schema && let Some(object) = projection.as_object_mut() {
        object.insert(
            "outputSchema".to_owned(),
            super::operation_contract::exact_output_schema(operation)
                .expect("supported execute operation has an output contract"),
        );
    }
    if alias != projection["id"].as_str().unwrap_or_default() {
        if let Some(object) = projection.as_object_mut() {
            object.insert(
                "aliasResolvedFrom".to_owned(),
                Value::String(alias.to_owned()),
            );
        }
    }
    projection
}

fn execute_operation_invocation_guidance(operation: &str) -> &'static str {
    match operation {
        "catalog_conformance" => {
            " This creates an idempotent durable catalog_discovery_report. Pass a stable bounded idempotencyKey and call it only when durable verification evidence is required; use catalog_search or catalog_inspect for read-only discovery."
        }
        "repository_tree_snapshot" => {
            " Copy complete repositoryRef/rootRef/headRef objects, including kind, from git_status details.git.repository.repositoryTreeSnapshotInput; passing only .id values is invalid."
        }
        "trace_list" => {
            " Current-session scope is supplied by trusted runtime context; do not invent selector or scope fields. Optional top-level fields are limit, traceId, recordOperation, and recordStatus. Use exact recordOperation/recordStatus filters when a broad result is truncated and the task needs one operation or failure class. When using trace_list as whole-session evidence, call it after the operations being audited; otherwise say it only covers records visible at its projection time. Final answers must explicitly state that provider transcript tool-call ids may be visible in provider message history for protocol threading, while trace projections do not expose raw trace providerInvocationId fields."
        }
        "trace_get" => {
            " Current-session scope is supplied by trusted runtime context; pass only operation and the traceRecordId returned by trace_list."
        }
        "job_start" => {
            " Durable job writes require command plus a stable bounded idempotencyKey. That caller key is provider-visible in the tool-call payload because you supply it; job_status, job_log, job_list, and trace projections redact raw idempotency keys. Use jobResourceId from job_start for later status/log/cancel calls."
        }
        "job_status" | "job_log" => {
            " Pass only operation and the exact jobResourceId returned by job_start or job_list. job_status/list return provider-safe lifecycle/output refs without raw command text, working directories, authority, idempotency keys, stdout, or stderr; use job_log when the task needs bounded stdout/stderr previews."
        }
        "job_cancel" => {
            " Pass operation, exact jobResourceId, bounded reason, and a stable bounded idempotencyKey. The caller key is provider-visible in the tool-call payload but redacted from status/list/log/trace projections."
        }
        "process_run" => {
            " Use process_run only for short synchronous no-network commands. For inspectable durable execution, prefer job_start followed by job_status/job_log. process_run returns bounded stdout/stderr previews directly and is not a durable job lifecycle."
        }
        "context_control_status" => {
            " Current-session scope is supplied by trusted runtime context; pass only operation. Do not include sessionId or selector fields. The result content summarizes epoch, token budget, composition blocks, and freshness proof without recording a snapshot or action."
        }
        "web_robots_check" => {
            " Pass the explicit target url. On success, pass webRobotsPolicyResourceId unchanged to a robots-gated web_fetch, and copy webRobotsPolicyVersionId into web_fetch.expectedWebRobotsPolicyVersionId."
        }
        "web_fetch" => {
            " Pass the explicit target url. When using robots evidence, pass webRobotsPolicyResourceId unchanged from web_robots_check and copy webRobotsPolicyVersionId into expectedWebRobotsPolicyVersionId; missing or stale versions fail closed before target network I/O."
        }
        _ => "",
    }
}

fn operation_contextual_pool_projection(operation: &str, mut projection: Value) -> Value {
    let usage = operation_agent_usage_projection(operation);
    if let Some(object) = projection.as_object_mut() {
        object.insert(
            "currentInvocation".to_owned(),
            json!({
                "operation": operation,
                "tool": "capability::execute",
                "effect": usage.as_ref().and_then(|usage| usage.get("effect")).cloned(),
                "preflight": usage.as_ref().and_then(|usage| usage.get("preflight")).cloned(),
                "guidance": "For this operation-specific invocation, follow the input schema and preflight fields. Replacement/routing classification is informational unless the user task explicitly asks to replace, shadow, activate, disable, or roll back this operation."
            }),
        );
        if matches!(
            object.get("replacementClass").and_then(Value::as_str),
            Some("runtime_routable")
        ) {
            object.insert(
                "replacementWorkflowBoundary".to_owned(),
                json!({
                    "appliesOnlyWhen": "explicit_replacement_shadow_route_or_rollback_workflow",
                    "notRequiredFor": "normal_read_only_or_session_work_invocation",
                    "safeDefault": "invoke_builtin_operation_with_exact_schema_until_a_governed_route_is_active"
                }),
            );
        }
    }
    projection
}

pub(super) fn execute_operation_input_schema(operation: &str) -> Value {
    super::operation_contract::exact_input_schema(operation).unwrap_or_else(|| {
        panic!(
            "registry invariant violated: supported capability::execute operation `{operation}` has no canonical input contract"
        )
    })
}

fn normalize_catalog_inspect_payload(payload: &Value) -> (Value, Option<String>) {
    let Some(kind) = payload.get("kind").and_then(Value::as_str) else {
        return (payload.clone(), None);
    };
    if kind != "function" {
        return (payload.clone(), None);
    }
    let Some(id) = payload.get("id").and_then(Value::as_str) else {
        return (payload.clone(), None);
    };
    let Some(canonical) = catalog_function_id_for_model_alias(id) else {
        return (payload.clone(), None);
    };
    let mut normalized = payload.clone();
    if let Some(object) = normalized.as_object_mut() {
        object.insert("id".to_owned(), Value::String(canonical.to_owned()));
    }
    (normalized, Some(id.to_owned()))
}

fn annotate_model_facing_invocation(discovery: &mut Value, payload: &Value) {
    let supported_execute_operations = supported_operation_names_for_guidance(payload);
    let supported_execute_operation_filter = supported_operation_guidance_filter(payload);
    if let Some(object) = discovery.as_object_mut() {
        object.insert(
            "modelFacingGuidance".to_owned(),
            json!({
                "catalogInspect": "Use functions[].id exactly as catalog_inspect kind=function id when inspecting engine substrate.",
                "capabilityExecute": "For normal session work, invoke capability::execute operations. Catalog functions are engine substrate unless modelFacingInvocation points at an execute operation.",
                "operationSearch": "If executeOperationMatches is present, use those operation names directly with capability::execute. They are provider-visible operations, not separate catalog functions.",
                "executeSchemaInspection": "Before invoking a provider-visible operation, inspect execute::<operation> with catalog_inspect to get exact top-level payload fields. Backing catalog function ids are secondary diagnostics.",
                "internalDiscovery": "Internal catalog functions are inspect-only by default. Request diagnostics or kernel-evolution context before using them to reason about engine internals.",
                "supportedExecuteOperations": supported_execute_operations,
                "supportedExecuteOperationsFilter": supported_execute_operation_filter
            }),
        );
    }

    if let Some(functions) = discovery.get_mut("functions").and_then(Value::as_array_mut) {
        for function in functions {
            let Some(id) = function.get("id").and_then(Value::as_str) else {
                continue;
            };
            let catalog_id = id.to_owned();
            if let Some(object) = function.as_object_mut() {
                annotate_catalog_function_pool(object, &catalog_id);
                if let Some(operation) = model_execute_operation_for_function_id(&catalog_id) {
                    object.insert(
                        "modelFacingInvocation".to_owned(),
                        json!({
                            "tool": "capability::execute",
                            "operation": operation,
                            "arguments": {"operation": operation},
                            "catalogInspectId": catalog_id,
                            "providerSchemaInspectId": format!("execute::{operation}"),
                            "preferredSchemaInspection": execute_schema_inspection_step(&operation),
                            "schemaInspectionOrder": "Inspect providerSchemaInspectId before invoking the provider-visible operation; inspect catalogInspectId only when engine-substrate diagnostics are explicitly needed.",
                            "capabilityPool": operation_pool_metadata(&operation).map(|metadata| metadata.provider_projection()),
                            "agentUsage": operation_agent_usage_projection(&operation)
                        }),
                    );
                    object.insert(
                        "agentUsage".to_owned(),
                        catalog_function_agent_usage_projection(&catalog_id, Some(&operation)),
                    );
                } else {
                    mark_catalog_target_non_callable(object);
                    object.insert(
                        "agentUsage".to_owned(),
                        catalog_function_agent_usage_projection(&catalog_id, None),
                    );
                }
            }
        }
    }

    if discovery.get("kind").and_then(Value::as_str) == Some("function") {
        let Some(id) = discovery.get("id").and_then(Value::as_str) else {
            return;
        };
        let catalog_id = id.to_owned();
        if let Some(object) = discovery.as_object_mut() {
            annotate_catalog_function_pool(object, &catalog_id);
            if let Some(operation) = model_execute_operation_for_function_id(&catalog_id) {
                object.insert(
                    "modelFacingInvocation".to_owned(),
                    json!({
                        "tool": "capability::execute",
                        "operation": operation,
                        "arguments": {"operation": operation},
                        "catalogInspectId": catalog_id,
                        "providerSchemaInspectId": format!("execute::{operation}"),
                        "preferredSchemaInspection": execute_schema_inspection_step(&operation),
                        "schemaInspectionOrder": "Inspect providerSchemaInspectId before invoking the provider-visible operation; inspect catalogInspectId only when engine-substrate diagnostics are explicitly needed.",
                        "capabilityPool": operation_pool_metadata(&operation).map(|metadata| metadata.provider_projection()),
                        "agentUsage": operation_agent_usage_projection(&operation)
                    }),
                );
                object.insert(
                    "agentUsage".to_owned(),
                    catalog_function_agent_usage_projection(&catalog_id, Some(&operation)),
                );
            } else {
                mark_catalog_target_non_callable(object);
                object.insert(
                    "agentUsage".to_owned(),
                    catalog_function_agent_usage_projection(&catalog_id, None),
                );
            }
        }
    }
}

fn supported_operation_names_for_guidance(payload: &Value) -> Vec<&'static str> {
    if catalog_search_requests_read_only(payload) {
        return supported_operation_names()
            .iter()
            .copied()
            .filter(|operation| operation_is_read_only_inspection_safe(operation))
            .collect();
    }
    supported_operation_names().iter().copied().collect()
}

fn supported_operation_guidance_filter(payload: &Value) -> Value {
    if catalog_search_requests_read_only(payload) {
        return json!({
            "effectClass": "pure_read",
            "mode": "read_only_inspection_safe",
            "reason": "Filtered by the active read-only discovery request so generic default guidance does not suggest mutating operations."
        });
    }
    json!({"effectClass": "all", "mode": "unfiltered"})
}

fn annotate_execute_operation_matches(discovery: &mut Value, payload: &Value) {
    let namespace_prefix = catalog_search_namespace_prefix(payload);
    let query = payload
        .get("text")
        .and_then(Value::as_str)
        .and_then(OperationSearchQuery::from_text)
        .or_else(|| {
            namespace_prefix
                .as_deref()
                .and_then(OperationSearchQuery::from_text)
        });
    let Some(query) = query else {
        return;
    };
    let unsupported_candidates = explicit_unsupported_operation_candidates(&query);
    let focus_on_unsupported_candidate =
        !unsupported_candidates.is_empty() && supported_operations_in_query(&query).is_empty();
    let limit = payload
        .get("limit")
        .and_then(Value::as_u64)
        .map(|limit| limit as usize)
        .unwrap_or(20)
        .clamp(1, 50);
    let mut matches = if focus_on_unsupported_candidate {
        Vec::new()
    } else {
        supported_operation_names()
            .iter()
            .filter_map(|operation| operation_match_projection(operation, &query))
            .collect::<Vec<_>>()
    };
    let plan_operations = (!focus_on_unsupported_candidate)
        .then(|| operation_search_plan_supported_operations(&query))
        .unwrap_or_default();
    let trace_operations = (!focus_on_unsupported_candidate)
        .then(|| trace_evidence_plan_supported_operations(&query))
        .unwrap_or_default();
    let module_governance_operations = (!focus_on_unsupported_candidate)
        .then(|| module_governance_plan_supported_operations(&query))
        .unwrap_or_default();
    for operation in &plan_operations {
        promote_or_insert_planned_operation_match(&mut matches, operation);
    }
    for operation in &trace_operations {
        promote_or_insert_trace_operation_match(&mut matches, operation);
    }
    for operation in &module_governance_operations {
        promote_or_insert_planned_operation_match(&mut matches, operation);
    }
    if let Some(namespace_prefix) = namespace_prefix {
        for operation in supported_operation_names()
            .iter()
            .filter(|operation| operation_matches_namespace_prefix(operation, &namespace_prefix))
        {
            promote_or_insert_namespace_operation_match(&mut matches, operation);
        }
    }
    if !plan_operations.is_empty()
        || !trace_operations.is_empty()
        || !module_governance_operations.is_empty()
    {
        let allowed = plan_operations
            .iter()
            .chain(trace_operations.iter())
            .chain(module_governance_operations.iter())
            .copied()
            .collect::<BTreeSet<_>>();
        matches.retain(|entry| {
            entry
                .get("operation")
                .and_then(Value::as_str)
                .is_some_and(|operation| allowed.contains(operation))
        });
    }
    let mut effect_excluded_matches = Vec::new();
    if catalog_search_requests_read_only(payload) {
        let (included, excluded): (Vec<_>, Vec<_>) = matches.into_iter().partition(|entry| {
            entry
                .get("operation")
                .and_then(Value::as_str)
                .is_some_and(operation_is_read_only_inspection_safe)
        });
        matches = included;
        effect_excluded_matches = excluded
            .into_iter()
            .map(effect_class_exclusion_projection)
            .collect::<Vec<_>>();
    }
    matches.sort_by(|left, right| {
        match_rank(left["matchKind"].as_str().unwrap_or_default())
            .cmp(&match_rank(right["matchKind"].as_str().unwrap_or_default()))
            .then_with(|| {
                right["score"]
                    .as_u64()
                    .unwrap_or(0)
                    .cmp(&left["score"].as_u64().unwrap_or(0))
            })
            .then_with(|| {
                left["operation"]
                    .as_str()
                    .unwrap_or_default()
                    .cmp(right["operation"].as_str().unwrap_or_default())
            })
    });
    let total = matches.len();
    matches.truncate(limit);
    let effect_excluded_total = effect_excluded_matches.len();
    effect_excluded_matches.truncate(20);
    let all_discovered_inspect_targets =
        discovered_inspect_targets_projection(&matches, &effect_excluded_matches);
    if let Some(object) = discovery.as_object_mut() {
        object.insert(
            "executeOperationSearch".to_owned(),
            json!({
                "query": query.display,
                "canonicalQuery": query.canonical,
                "terms": query.terms,
                "totalMatches": total,
                "returnedMatches": matches.len(),
                "truncated": total > matches.len(),
                "omitted": total.saturating_sub(matches.len()),
                "effectClassExcludedMatches": effect_excluded_total,
            }),
        );
        if !all_discovered_inspect_targets.is_empty() {
            object.insert(
                "allDiscoveredInspectTargets".to_owned(),
                Value::Array(all_discovered_inspect_targets),
            );
        }
        if !effect_excluded_matches.is_empty() {
            object.insert(
                "effectClassExcludedOperationMatches".to_owned(),
                Value::Array(effect_excluded_matches),
            );
        }
        if let Some(plan) = operation_search_plan_projection(&query) {
            object.insert("agentNextStep".to_owned(), readiness_plan_next_step(&plan));
            object.insert("agentSearchPlan".to_owned(), plan);
        } else if let Some(plan) = trace_evidence_plan_projection(&query) {
            object.insert("agentSearchPlan".to_owned(), plan);
            if let Some(next_step) = preferred_execute_schema_next_step(&matches) {
                object.insert("agentNextStep".to_owned(), next_step);
            }
        } else if let Some(plan) = module_governance_plan_projection(&query) {
            object.insert(
                "agentNextStep".to_owned(),
                module_governance_plan_next_step(&plan),
            );
            object.insert("agentSearchPlan".to_owned(), plan);
        } else if let Some(next_step) = preferred_execute_schema_next_step(&matches) {
            object.insert("agentNextStep".to_owned(), next_step);
        }
        object.insert("executeOperationMatches".to_owned(), Value::Array(matches));
        if !unsupported_candidates.is_empty() {
            object.insert(
                "unsupportedOperationCandidates".to_owned(),
                Value::Array(
                    unsupported_candidates
                        .iter()
                        .map(|candidate| Value::String(candidate.canonical.clone()))
                        .collect(),
                ),
            );
            object.insert(
                "unsupportedOperationCandidate".to_owned(),
                Value::Bool(true),
            );
            object.insert(
                "unsupportedOperationRecovery".to_owned(),
                unsupported_operation_recovery_projection(&unsupported_candidates[0]),
            );
        } else if total == 0
            && effect_excluded_total == 0
            && looks_like_unsupported_operation_candidate(&query)
        {
            object.insert(
                "unsupportedOperationCandidate".to_owned(),
                Value::Bool(true),
            );
            object.insert(
                "unsupportedOperationRecovery".to_owned(),
                unsupported_operation_recovery_projection(&query),
            );
        }
    }
}

fn discovered_inspect_targets_projection(
    included_matches: &[Value],
    effect_excluded_matches: &[Value],
) -> Vec<Value> {
    included_matches
        .iter()
        .map(|entry| discovered_inspect_target_projection(entry, false))
        .chain(
            effect_excluded_matches
                .iter()
                .map(|entry| discovered_inspect_target_projection(entry, true)),
        )
        .collect()
}

fn discovered_inspect_target_projection(
    entry: &Value,
    excluded_from_immediate_invocation: bool,
) -> Value {
    let operation = entry
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let catalog_inspect_id = entry
        .get("catalogInspectId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("execute::{operation}"));
    let read_only_inspection_safe = entry
        .pointer("/agentUsage/effect/readOnlyInspectionSafe")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut target = json!({
        "operation": operation,
        "tool": "capability::execute",
        "catalogInspectId": catalog_inspect_id.clone(),
        "inspectOperation": "catalog_inspect",
        "inspectArguments": {
            "operation": "catalog_inspect",
            "kind": "function",
            "id": catalog_inspect_id
        },
        "invokeArguments": {"operation": operation},
        "readOnlyInspectionSafe": read_only_inspection_safe,
        "excludedFromImmediateInvocation": excluded_from_immediate_invocation,
        "agentGuidance": if excluded_from_immediate_invocation {
            "Supported operation found but excluded from immediate invocation by the requested effect class. Inspect the schema only; do not invoke unless the task explicitly allows its effect."
        } else {
            "Inspect the schema before invoking the operation."
        }
    });
    if let Some(reason) = entry.get("exclusionReason").and_then(Value::as_str) {
        if let Some(object) = target.as_object_mut() {
            object.insert(
                "exclusionReason".to_owned(),
                Value::String(reason.to_owned()),
            );
        }
    }
    target
}

fn effect_class_exclusion_projection(mut entry: Value) -> Value {
    if let Some(object) = entry.as_object_mut() {
        object.insert(
            "excludedByEffectClass".to_owned(),
            Value::String("pure_read".to_owned()),
        );
        object.insert(
            "exclusionReason".to_owned(),
            Value::String(
                "Supported operation exists but is not read-only inspection safe; inspect its schema only when the task explicitly allows write-like evidence or state changes, and do not invoke it during pure-read discovery.".to_owned(),
            ),
        );
    }
    entry
}

fn catalog_search_namespace_prefix(payload: &Value) -> Option<String> {
    let prefix = payload.get("namespacePrefix")?.as_str()?;
    let prefix = canonical_operation_search_text(prefix);
    if prefix.len() >= 3 {
        Some(prefix)
    } else {
        None
    }
}

fn catalog_search_requests_read_only(payload: &Value) -> bool {
    payload
        .get("effectClass")
        .and_then(Value::as_str)
        .map(|effect_class| {
            matches!(
                effect_class.trim().to_ascii_lowercase().as_str(),
                "pure_read" | "read" | "read_only" | "inspect"
            )
        })
        .unwrap_or(false)
}

fn readiness_plan_next_step(plan: &Value) -> Value {
    json!({
        "priority": "follow_agent_search_plan_primary_inspection",
        "reason": "For replacement or shadow readiness, first inspect the exact targeted cockpit row. It is read-only and tells whether evidence exists; do not infer unsupported shadow list operations.",
        "primaryInspection": plan["primaryInspection"],
        "thenFollow": "agentSearchPlan.readOnlySequence",
        "completionRule": plan["completionRule"]
    })
}

fn module_governance_plan_next_step(plan: &Value) -> Value {
    json!({
        "priority": "follow_module_governance_read_only_plan",
        "reason": "For broad module-governance readiness checks, use the listed read-only overview/list operations directly. Their default payload is complete: operation plus optional limit/includeArchived only. Inspect individual schemas only when you need non-default fields or a concrete resource id from list output.",
        "thenFollow": "agentSearchPlan.readOnlySequence",
        "schemaPolicy": plan["schemaPolicy"],
        "completionRule": plan["completionRule"]
    })
}

fn looks_like_unsupported_operation_candidate(query: &OperationSearchQuery) -> bool {
    let canonical = query.canonical.as_str();
    canonical.contains('_')
        && (canonical.starts_with("capability_")
            || canonical.starts_with("catalog_")
            || canonical.starts_with("context_")
            || canonical.starts_with("git_")
            || canonical.starts_with("module_")
            || canonical.starts_with("trace_")
            || canonical.starts_with("log_")
            || canonical.ends_with("_list")
            || canonical.ends_with("_inspect")
            || canonical.ends_with("_record")
            || canonical.ends_with("_activate")
            || canonical.ends_with("_rollback")
            || canonical.ends_with("_disable"))
}

fn explicit_unsupported_operation_candidates(
    query: &OperationSearchQuery,
) -> Vec<OperationSearchQuery> {
    let mut candidates = query
        .display
        .split_whitespace()
        .filter_map(OperationSearchQuery::from_text)
        .filter(|candidate| looks_like_unsupported_operation_candidate(candidate))
        .filter(|candidate| !is_supported_operation(&candidate.canonical))
        .filter(|candidate| {
            let prefix = format!("{}_", candidate.canonical);
            !supported_operation_names()
                .iter()
                .any(|operation| operation.starts_with(&prefix))
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|left, right| left.canonical.cmp(&right.canonical));
    candidates.dedup_by(|left, right| left.canonical == right.canonical);
    candidates
}

fn unsupported_operation_recovery_projection(query: &OperationSearchQuery) -> Value {
    let mut alternatives = vec![
        recovery_alternative(
            "catalog_search",
            json!({"operation": "catalog_search", "text": query.display}),
            "Search the exact supported provider-visible operation pool before invoking.",
        ),
        recovery_alternative(
            "catalog_inspect",
            json!({"operation": "catalog_inspect", "kind": "function", "id": "execute::<supported_operation>"}),
            "Inspect the exact schema for a supported operation returned by catalog_search.",
        ),
        recovery_alternative(
            "capability_binding_cockpit_overview",
            json!({"operation": "capability_binding_cockpit_overview", "targetOperation": "<supported_operation>"}),
            "Inspect replacement, binding, shadow, route, rollback, role, and preflight readiness for one exact operation.",
        ),
    ];

    let canonical = query.canonical.as_str();
    if canonical.contains("replacement") {
        alternatives.push(recovery_alternative(
            "capability_replacement_candidate_list",
            json!({"operation": "capability_replacement_candidate_list"}),
            "List recorded replacement candidates; this is read-only metadata and may be empty.",
        ));
    }
    if canonical.contains("route") {
        alternatives.extend([
            recovery_alternative(
                "capability_route_binding_list",
                json!({"operation": "capability_route_binding_list"}),
                "List recorded route bindings; this does not activate or change routing.",
            ),
            recovery_alternative(
                "capability_route_event_list",
                json!({"operation": "capability_route_event_list"}),
                "List route events for activation, disable, rollback, and failed-closed history.",
            ),
        ]);
    }
    if canonical.contains("binding") {
        alternatives.extend([
            recovery_alternative(
                "capability_binding_request_list",
                json!({"operation": "capability_binding_request_list"}),
                "List recorded binding requests; this does not create or approve a request.",
            ),
            recovery_alternative(
                "capability_binding_decision_list",
                json!({"operation": "capability_binding_decision_list"}),
                "List recorded binding decisions; this is the read-only decision history.",
            ),
            recovery_alternative(
                "capability_binding_policy_list",
                json!({"operation": "capability_binding_policy_list"}),
                "List recorded binding policies; active policy metadata does not imply runtime routing.",
            ),
        ]);
    }
    if canonical.contains("shadow") {
        alternatives.push(recovery_alternative(
            "capability_shadow_trial_evidence_inspect",
            json!({"operation": "capability_shadow_trial_evidence_inspect", "capabilityShadowTrialEvidenceResourceId": "<exact evidence resource id>"}),
            "Inspect shadow evidence only when an exact evidence resource id is already known; use cockpit overview for availability and counts.",
        ));
    }

    json!({
        "query": query.display,
        "canonicalQuery": query.canonical,
        "supportedOperation": false,
        "guidance": "No supported capability::execute operation matched this operation-like query. Do not call the queried name. Use the listed alternatives or inspect the exact supported operation returned by catalog_search.",
        "closestReadOnlyAlternatives": alternatives,
    })
}

fn recovery_alternative(operation: &str, payload: Value, reason: &str) -> Value {
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": payload,
        "readOnlyInspectionSafe": true,
        "reason": reason,
        "agentUsage": operation_agent_usage_projection(operation)
    })
}

fn preferred_execute_schema_next_step(matches: &[Value]) -> Option<Value> {
    let operation = matches
        .first()
        .and_then(|entry| entry.get("operation"))
        .and_then(Value::as_str)?;
    let mut next_step = json!({
        "priority": "inspect_execute_operation_schema_first",
        "reason": "Before invoking a provider-visible capability::execute operation, inspect the execute::<operation> schema for exact top-level payload fields. Backing catalog function ids are engine substrate and are secondary unless the task is diagnostics or kernel evolution.",
        "schemaInspection": execute_schema_inspection_step(operation)
    });
    if matches
        .first()
        .is_some_and(operation_match_is_read_only_inspection_safe)
    {
        next_step["thenInvoke"] = json!({
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation}
        });
    } else {
        next_step["priority"] = json!("inspect_write_like_operation_before_use");
        next_step["reason"] = json!(
            "This supported operation is not read-only inspection safe. Inspect the execute::<operation> schema and only invoke it when the task explicitly allows the documented state change, resource write, approval, or policy effect."
        );
        next_step["thenInvokeBlocked"] = json!({
            "operation": operation,
            "reason": "Operation metadata is not read-only inspection safe; do not invoke directly from discovery.",
            "requiresSchemaInspection": true
        });
    }
    Some(next_step)
}

fn operation_match_is_read_only_inspection_safe(entry: &Value) -> bool {
    entry
        .pointer("/agentUsage/effect/readOnlyInspectionSafe")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !entry
            .pointer("/agentUsage/effect/mutatesState")
            .and_then(Value::as_bool)
            .unwrap_or(true)
}

#[derive(Clone, Debug)]
struct OperationSearchQuery {
    display: String,
    canonical: String,
    terms: Vec<String>,
}

impl OperationSearchQuery {
    fn from_text(query: &str) -> Option<Self> {
        let display = query.trim().to_owned();
        let canonical = canonical_operation_search_text(&display);
        if canonical.len() < 3 || canonical == "capability_execute" {
            return None;
        }
        let terms = canonical
            .split('_')
            .filter_map(search_term)
            .collect::<Vec<_>>();
        Some(Self {
            display,
            canonical,
            terms,
        })
    }
}

fn canonical_operation_search_text(query: &str) -> String {
    let query = query
        .trim()
        .strip_prefix("execute::")
        .unwrap_or_else(|| query.trim())
        .replace("::", "_")
        .to_ascii_lowercase();
    let mut canonical = String::with_capacity(query.len());
    let mut previous_separator = false;
    for ch in query.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' {
            canonical.push(ch);
            previous_separator = false;
        } else if !previous_separator {
            canonical.push('_');
            previous_separator = true;
        }
    }
    canonical.trim_matches('_').to_owned()
}

fn operation_match_projection(operation: &str, query: &OperationSearchQuery) -> Option<Value> {
    let operation_key = operation.to_ascii_lowercase();
    let catalog_key = direct_catalog_function_id_for_execute_operation(operation)
        .map(str::to_owned)
        .unwrap_or_default()
        .replace("::", "_")
        .to_ascii_lowercase();
    let has_direct_catalog_key = !catalog_key.is_empty();
    let (match_kind, score) = if operation_key == query.canonical
        || (has_direct_catalog_key && catalog_key == query.canonical)
        || query.canonical.contains(&operation_key)
        || (has_direct_catalog_key && query.canonical.contains(&catalog_key))
    {
        ("exact", 400)
    } else if operation_key.starts_with(&query.canonical)
        || (has_direct_catalog_key && catalog_key.starts_with(&query.canonical))
    {
        ("prefix", 300)
    } else if query.canonical.len() >= 5
        && (operation_key.contains(&query.canonical)
            || (has_direct_catalog_key && catalog_key.contains(&query.canonical)))
    {
        ("contains", 200)
    } else if allows_term_matches(query)
        && terms_match_operation(&query.terms, &operation_key, &catalog_key)
    {
        ("terms", 150)
    } else if allows_intent_matches(query) {
        let score = intent_match_score(operation, query)?;
        ("intent", score)
    } else {
        return None;
    };
    Some(json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "catalogInspectId": format!("execute::{operation}"),
        "schemaInspection": execute_schema_inspection_step(operation),
        "matchKind": match_kind,
        "score": score,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    }))
}

fn planned_operation_match_projection(operation: &str) -> Value {
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "catalogInspectId": format!("execute::{operation}"),
        "schemaInspection": execute_schema_inspection_step(operation),
        "matchKind": "plan",
        "score": 260,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    })
}

fn trace_operation_match_projection(operation: &str) -> Value {
    let score = match operation {
        "trace_list" => 285,
        "trace_get" => 275,
        "catalog_inspect" => 265,
        _ => 260,
    };
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "catalogInspectId": format!("execute::{operation}"),
        "schemaInspection": execute_schema_inspection_step(operation),
        "matchKind": "trace_plan",
        "score": score,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    })
}

fn namespace_operation_match_projection(operation: &str) -> Value {
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "catalogInspectId": format!("execute::{operation}"),
        "schemaInspection": execute_schema_inspection_step(operation),
        "matchKind": "namespace",
        "score": 240,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    })
}

fn execute_schema_inspection_step(operation: &str) -> Value {
    json!({
        "operation": "catalog_inspect",
        "tool": "capability::execute",
        "arguments": {
            "operation": "catalog_inspect",
            "kind": "function",
            "id": format!("execute::{operation}")
        },
        "readOnlyInspectionSafe": true,
        "reason": "Inspect the provider-visible execute-operation schema and required top-level payload fields before invoking."
    })
}

fn promote_or_insert_planned_operation_match(matches: &mut Vec<Value>, operation: &str) {
    let planned = planned_operation_match_projection(operation);
    if let Some(existing) = matches
        .iter_mut()
        .find(|entry| entry["operation"] == operation)
    {
        *existing = planned;
    } else {
        matches.push(planned);
    }
}

fn promote_or_insert_trace_operation_match(matches: &mut Vec<Value>, operation: &str) {
    let planned = trace_operation_match_projection(operation);
    if let Some(existing) = matches
        .iter_mut()
        .find(|entry| entry["operation"] == operation)
    {
        if existing["matchKind"] == "exact" {
            return;
        }
        *existing = planned;
    } else {
        matches.push(planned);
    }
}

fn promote_or_insert_namespace_operation_match(matches: &mut Vec<Value>, operation: &str) {
    if matches
        .iter()
        .any(|entry| entry["operation"].as_str() == Some(operation))
    {
        return;
    }
    matches.push(namespace_operation_match_projection(operation));
}

fn match_rank(match_kind: &str) -> usize {
    match match_kind {
        "exact" => 0,
        "prefix" => 1,
        "namespace" => 2,
        "trace_plan" => 3,
        "plan" => 4,
        "contains" => 5,
        "terms" => 6,
        "intent" => 7,
        _ => 5,
    }
}

fn operation_matches_namespace_prefix(operation: &str, namespace_prefix: &str) -> bool {
    let operation_key = operation.to_ascii_lowercase();
    operation_key.starts_with(namespace_prefix)
        || operation_pool_metadata(operation).is_some_and(|metadata| {
            canonical_operation_search_text(metadata.family.as_ref()) == namespace_prefix
                || canonical_operation_search_text(metadata.owner.as_ref()) == namespace_prefix
        })
}

fn terms_match_operation(terms: &[String], operation_key: &str, catalog_key: &str) -> bool {
    if terms.len() < 2 {
        return false;
    }
    terms
        .iter()
        .all(|term| operation_key.split('_').any(|part| part == term) || catalog_key.contains(term))
}

fn allows_term_matches(query: &OperationSearchQuery) -> bool {
    query.display.chars().any(char::is_whitespace)
        || !looks_like_unsupported_operation_candidate(query)
}

fn intent_match_score(operation: &str, query: &OperationSearchQuery) -> Option<u64> {
    if query.terms.len() < 2 {
        return None;
    }
    let query_terms = query_terms(query);
    let (direct_terms, context_terms) = operation_search_terms(operation);
    let direct_hits = query_terms
        .iter()
        .filter(|term| direct_terms.contains(*term))
        .count();
    let context_hits = query_terms
        .iter()
        .filter(|term| context_terms.contains(*term))
        .count();
    if direct_hits == 0 || direct_hits + context_hits < 2 {
        return None;
    }
    Some((direct_hits as u64 * 25) + (context_hits as u64 * 5))
}

fn query_terms(query: &OperationSearchQuery) -> BTreeSet<String> {
    query.terms.iter().cloned().collect()
}

fn allows_intent_matches(query: &OperationSearchQuery) -> bool {
    if !query.display.chars().any(char::is_whitespace) {
        return false;
    }
    supported_operations_in_query(query).len() <= 1
}

fn supported_operations_in_query(query: &OperationSearchQuery) -> Vec<&'static str> {
    supported_operation_names()
        .iter()
        .copied()
        .filter(|operation| query.canonical.contains(operation))
        .collect()
}

fn operation_search_terms(operation: &str) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut direct = token_set(operation);
    if let Some(catalog_key) = direct_catalog_function_id_for_execute_operation(operation) {
        direct.extend(token_set(catalog_key));
    }

    let mut context = BTreeSet::new();
    if let Some(metadata) = operation_pool_metadata(operation) {
        context.extend(token_set(metadata.family.as_ref()));
        context.extend(token_set(metadata.owner.as_ref()));
        context.extend(token_set(metadata.audience.as_str()));
        context.extend(token_set(metadata.replacement_class.as_str()));
        context.extend(token_set(metadata.agent_default_visibility.as_str()));
        context.extend(token_set(metadata.purpose));
        context.extend(token_set(metadata.effect));
        context.extend(token_set(metadata.risk));
        context.extend(token_set(metadata.authority_boundary));
        context.extend(token_set(metadata.evidence_boundary));
        context.extend(token_set(metadata.minimality_decision.as_str()));
        context.extend(token_set(metadata.evolution_path));
        context.extend(token_set(metadata.next_action));
    }
    context.extend(direct.iter().cloned());
    (direct, context)
}

fn token_set(text: &str) -> BTreeSet<String> {
    canonical_operation_search_text(text)
        .split('_')
        .filter_map(search_term)
        .collect()
}

fn search_term(term: &str) -> Option<String> {
    if term.len() < 3 {
        return None;
    }
    if matches!(
        term,
        "capability"
            | "capabilities"
            | "execute"
            | "function"
            | "functions"
            | "operation"
            | "operations"
            | "list"
            | "lists"
            | "inspect"
            | "inspects"
            | "inspection"
            | "record"
            | "records"
            | "read"
            | "only"
            | "safe"
            | "none"
    ) {
        return None;
    }
    Some(term.to_owned())
}

fn operation_search_plan_projection(query: &OperationSearchQuery) -> Option<Value> {
    let (target, query_terms) = operation_search_plan_target(query)?;
    if query_terms.is_empty() {
        return None;
    }

    let mut followups = vec![recovery_alternative(
        "capability_binding_cockpit_overview",
        json!({"operation": "capability_binding_cockpit_overview", "targetOperation": target}),
        "Inspect this operation's role, replacement class, binding, shadow, route, rollback, and scoped evidence counts without invoking the adapter.",
    )];
    if query_terms.contains("replacement") || query_terms.contains("candidate") {
        followups.push(recovery_alternative(
            "capability_replacement_candidate_list",
            json!({"operation": "capability_replacement_candidate_list", "limit": 25}),
            "List recorded replacement candidates; an empty list means no candidate exists in scope.",
        ));
    }
    if query_terms.contains("route") || query_terms.contains("routing") {
        followups.extend([
            recovery_alternative(
                "capability_route_binding_list",
                json!({"operation": "capability_route_binding_list", "limit": 25}),
                "List explicit route bindings without activating, disabling, or rolling back routing.",
            ),
            recovery_alternative(
                "capability_route_event_list",
                json!({"operation": "capability_route_event_list", "limit": 25}),
                "List activation, routed invocation, disable, rollback, and failed-closed route events.",
            ),
        ]);
    }
    if query_terms.contains("binding") {
        followups.extend([
            recovery_alternative(
                "capability_binding_request_list",
                json!({"operation": "capability_binding_request_list", "limit": 25}),
                "List recorded binding requests; this is read-only and may be empty.",
            ),
            recovery_alternative(
                "capability_binding_decision_list",
                json!({"operation": "capability_binding_decision_list", "limit": 25}),
                "List approval or rejection history for binding requests.",
            ),
            recovery_alternative(
                "capability_binding_policy_list",
                json!({"operation": "capability_binding_policy_list", "limit": 25}),
                "List active or historical binding policies; this does not activate routing.",
            ),
        ]);
    }
    let contextual_write_operations = if query_terms.contains("shadow")
        || query_terms.contains("trial")
        || query_terms.contains("evidence")
    {
        vec![
            contextual_write_operation(
                "capability_shadow_trial_request_record",
                "recording a governed metadata-only shadow request after explicit task, approval, and candidate evidence",
            ),
            contextual_write_operation(
                "capability_shadow_trial_decision_record",
                "recording a governance decision for an exact shadow request resource and version",
            ),
            contextual_write_operation(
                "capability_shadow_trial_run_record",
                "recording a metadata-only shadow run for an approved decision with bounded built-in and candidate projections",
            ),
        ]
    } else {
        Vec::new()
    };

    Some(json!({
        "purpose": "Deterministic read-only plan for a capability readiness query with one exact target operation.",
        "targetOperation": target,
        "primaryInspection": {
            "tool": "capability::execute",
            "operation": "capability_binding_cockpit_overview",
            "arguments": {"operation": "capability_binding_cockpit_overview", "targetOperation": target},
            "readOnlyInspectionSafe": true,
            "reason": "Returns one exact operation row with readiness, route, binding, shadow, rollback, and evidence facts."
        },
        "readOnlySequence": followups,
        "adapterInvocationSchemaInspection": {
            "tool": "capability::execute",
            "operation": "catalog_inspect",
            "arguments": {"operation": "catalog_inspect", "kind": "function", "id": format!("execute::{target}")},
            "readOnlyInspectionSafe": true,
            "useOnlyWhen": "Only inspect the target adapter schema when the task explicitly needs to invoke the adapter effect. Do not use this as replacement, shadow, route, or evidence proof.",
            "notPartOfReadinessCompletion": true
        },
        "doNotCall": [
            {"operation": target, "reason": "Do not invoke the adapter just to inspect replacement readiness; call it only when the task needs the adapter effect."},
            {"operation": "capability_shadow_trial_request_list", "reason": "No provider-visible list operation exists for shadow trial requests; use targeted cockpit counts and exact evidence inspect only when an evidence ref exists."},
            {"operation": "capability_shadow_trial_run_list", "reason": "No provider-visible list operation exists for shadow trial runs; use route events and exact evidence refs instead."}
        ],
        "completionRule": "If the targeted cockpit row has zero shadowTrial.evidenceRefs, zero shadowTrial.runs, zero route.bindings, and zero route.routeEvents, stop and report that no current-scope shadow or route evidence is recorded.",
        "finalAnswerWhen": "After the targeted cockpit overview shows no exact shadow evidence refs and the listed read-only operations show no candidates, routes, bindings, or events, stop and answer from those facts.",
        "terminalZeroEvidencePath": {
            "state": "answer_now_no_current_scope_evidence",
            "afterOperation": "capability_binding_cockpit_overview",
            "condition": "targeted cockpit row returns zero shadowTrial.evidenceRefs, shadowTrial.runs, route.bindings, active routes, and route.routeEvents",
            "answerGuidance": "Say no scoped shadow or route evidence is recorded for the target operation. Do not inspect evidence schemas without an exact evidence resource id."
        },
        "contextualWriteOperations": contextual_write_operations,
        "evidenceInspectAvailability": {
            "callableNow": false,
            "becomesCallableWhen": "targeted cockpit, route-event, or resource output returns an exact provider-safe evidence inspect payload",
            "notActionableReason": "No exact capabilityShadowTrialEvidenceResourceId is known from search alone; targeted cockpit returns exact inspect payloads only when evidence exists.",
            "doNotInspectSchemasFromSearch": true
        },
        "doNotInspect": [
            {"operation": "evidence inspection", "reason": "Do not call until evidenceInspectAvailability.callableNow is true because targeted cockpit returned an exact inspect payload."},
            {"operation": "evidence schema inspection", "reason": "Do not inspect evidence schemas in the zero-evidence path; schema inspection does not create evidence."}
        ]
    }))
}

fn contextual_write_operation(operation: &str, use_only_when: &str) -> Value {
    let required_payload_fields = execute_operation_input_schema(operation)
        .get("required")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_else(|| vec![Value::String("operation".to_owned())]);
    let mut agent_usage = operation_agent_usage_projection(operation).unwrap_or_else(|| {
        json!({
            "callable": true,
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation}
        })
    });
    if let Some(preflight) = agent_usage
        .get_mut("preflight")
        .and_then(Value::as_object_mut)
    {
        preflight.insert(
            "requiredPayloadFields".to_owned(),
            Value::Array(required_payload_fields.clone()),
        );
    }
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "schemaInspection": execute_schema_inspection_step(operation),
        "requiredPayloadFields": required_payload_fields,
        "readOnlyInspectionSafe": false,
        "useOnlyWhen": use_only_when,
        "agentUsage": agent_usage
    })
}

fn trace_evidence_plan_projection(query: &OperationSearchQuery) -> Option<Value> {
    let (target, query_terms) = trace_evidence_plan_target(query)?;
    let mut read_only_sequence = vec![recovery_alternative(
        "catalog_inspect",
        json!({"operation": "catalog_inspect", "kind": "function", "id": format!("execute::{target}")}),
        "Inspect the exact provider-visible request schema for the target operation before invoking it.",
    )];

    if target != "trace_list" {
        read_only_sequence.push(recovery_alternative(
            "trace_list",
            json!({"operation": "trace_list", "limit": 25}),
            "After invoking the target operation, list current-session trace evidence through the provider-safe trace projection.",
        ));
    }
    Some(json!({
        "purpose": "Deterministic read-only plan for schema inspection and provider-safe trace evidence.",
        "targetOperation": target,
        "traceIntentTerms": query_terms,
        "primaryInspection": {
            "tool": "capability::execute",
            "operation": "catalog_inspect",
            "arguments": {"operation": "catalog_inspect", "kind": "function", "id": format!("execute::{target}")},
            "readOnlyInspectionSafe": true,
            "reason": "Returns the exact provider-visible schema and top-level payload fields for the target operation."
        },
        "readOnlySequence": read_only_sequence,
        "afterTargetInvocation": {
            "tool": "capability::execute",
            "operation": "trace_list",
            "arguments": {"operation": "trace_list", "limit": 25},
            "readOnlyInspectionSafe": true,
            "reason": "Use trace_list after the target operation to verify provider-safe trace evidence."
        },
        "optionalDetailInspection": {
            "tool": "capability::execute",
            "operation": "trace_get",
            "arguments": {"operation": "trace_get", "traceRecordId": "<trace record id from trace_list>"},
            "readOnlyInspectionSafe": true,
            "reason": "Call trace_get only when the task explicitly needs one focused trace record; trace_list is the default proof path."
        },
        "completionRule": "After schema inspection, one target invocation, and trace_list, answer from provider-safe trace fields only. State that provider-visible trace projections exclude raw internals while internal audit storage may retain raw fields for replay and policy.",
        "doNotInspect": [
            {"field": "raw trace database rows", "reason": "Use provider-safe trace_list/trace_get projections instead of raw internal persistence."}
        ]
    }))
}

fn operation_search_plan_supported_operations(query: &OperationSearchQuery) -> Vec<&'static str> {
    let Some((_target, query_terms)) = operation_search_plan_target(query) else {
        return Vec::new();
    };
    let mut operations = vec!["capability_binding_cockpit_overview"];
    if query_terms.contains("replacement") || query_terms.contains("candidate") {
        operations.push("capability_replacement_candidate_list");
    }
    if query_terms.contains("route") || query_terms.contains("routing") {
        operations.extend([
            "capability_route_binding_list",
            "capability_route_event_list",
        ]);
    }
    if query_terms.contains("binding") {
        operations.extend([
            "capability_binding_request_list",
            "capability_binding_decision_list",
            "capability_binding_policy_list",
        ]);
    }
    operations
}

fn trace_evidence_plan_supported_operations(query: &OperationSearchQuery) -> Vec<&'static str> {
    let Some((target, _)) = trace_evidence_plan_target(query) else {
        return Vec::new();
    };
    vec![target, "catalog_inspect", "trace_list"]
}

fn module_governance_plan_supported_operations(query: &OperationSearchQuery) -> Vec<&'static str> {
    if !module_governance_plan_query(query) {
        return Vec::new();
    }

    let terms = query_terms(query);
    let broad_governance = terms.contains("governance");
    let mut operations = Vec::new();

    if broad_governance || terms.contains("module") || terms.contains("registry") {
        operations.push("module_list");
    }
    if broad_governance || terms.contains("lifecycle") {
        operations.push("module_lifecycle_list");
    }
    if broad_governance || terms.contains("runtime") {
        operations.push("module_runtime_list");
    }
    if broad_governance
        || terms.contains("dependency")
        || terms.contains("request")
        || terms.contains("decision")
        || terms.contains("policy")
    {
        operations.extend([
            "module_dependency_request_list",
            "module_dependency_decision_list",
            "module_dependency_policy_list",
        ]);
    }
    if broad_governance
        || terms.contains("binding")
        || terms.contains("replacement")
        || terms.contains("route")
        || terms.contains("routing")
    {
        operations.extend([
            "capability_binding_cockpit_overview",
            "capability_binding_request_list",
            "capability_binding_decision_list",
            "capability_binding_policy_list",
            "capability_replacement_candidate_list",
            "capability_route_binding_list",
            "capability_route_event_list",
        ]);
    }

    operations.sort_unstable();
    operations.dedup();
    operations
}

fn operation_search_plan_target(
    query: &OperationSearchQuery,
) -> Option<(&'static str, BTreeSet<String>)> {
    let mut supported = supported_operations_in_query(query);
    if supported.len() != 1 {
        return None;
    }
    let target = supported.pop()?;
    let metadata = operation_pool_metadata(target)?;
    if metadata.replacement_class.as_str() != "runtime_routable" {
        return None;
    }
    let query_terms = query_terms(query);
    let asks_binding_or_route_readiness = query_terms.iter().any(|term| {
        matches!(
            term.as_str(),
            "replacement"
                | "replace"
                | "replacing"
                | "route"
                | "routing"
                | "binding"
                | "readiness"
                | "rollback"
                | "candidate"
                | "shadow"
                | "trial"
        )
    }) && !query_terms.contains("trace");
    asks_binding_or_route_readiness.then_some((target, query_terms))
}

fn trace_evidence_plan_target(
    query: &OperationSearchQuery,
) -> Option<(&'static str, BTreeSet<String>)> {
    if operation_search_plan_target(query).is_some() {
        return None;
    }
    let mut supported = supported_operations_in_query(query)
        .into_iter()
        .filter(|operation| !trace_evidence_helper_operation(operation))
        .collect::<Vec<_>>();
    supported.sort_unstable();
    supported.dedup();
    if supported.len() != 1 {
        return None;
    }
    let target = supported.pop()?;
    if !operation_is_read_only_inspection_safe(target) {
        return None;
    }
    let query_terms = query_terms(query);
    let asks_trace_evidence = query_terms
        .iter()
        .any(|term| matches!(term.as_str(), "trace" | "evidence" | "provider" | "safe"));
    let asks_schema_or_trace = query_terms.iter().any(|term| {
        matches!(
            term.as_str(),
            "schema" | "trace" | "evidence" | "projection" | "provider"
        )
    });
    (asks_trace_evidence && asks_schema_or_trace).then_some((target, query_terms))
}

fn module_governance_plan_projection(query: &OperationSearchQuery) -> Option<Value> {
    let operations = module_governance_plan_supported_operations(query);
    if operations.is_empty() {
        return None;
    }

    let read_only_sequence = operations
        .iter()
        .map(|operation| {
            recovery_alternative(
                operation,
                default_list_payload(operation),
                read_only_module_governance_reason(operation),
            )
        })
        .collect::<Vec<_>>();

    Some(json!({
        "purpose": "Deterministic read-only plan for broad module-governance discovery and readiness checks.",
        "query": query.display,
        "readOnlySequence": read_only_sequence,
        "schemaPolicy": {
            "defaultPayloadComplete": true,
            "defaultPayload": "operation-only unless the listed operation documents optional limit/includeArchived filters",
            "inspectWhen": "Inspect execute::<operation> only when you need non-default fields, a concrete resource id from list output, or a focused inspect operation.",
            "doNotInspectEverySibling": true,
            "reason": "The read-only sequence is already constrained to provider-visible overview/list operations whose required payload is operation. Per-operation schema fan-out is unnecessary for a broad governance readiness check."
        },
        "resourceInspectPolicy": {
            "callInspectOperationsOnlyWithExactResourceIds": true,
            "sourceOfResourceIds": "list operation output or cockpit evidence refs",
            "emptyListMeansNoScopedRecords": true
        },
        "doNotCall": [
            {"operationFamily": "module_*_record/request/decision mutators", "reason": "This plan is read-only. Do not create proposals, install requests, lifecycle requests, runtime requests, dependency requests, or decisions."},
            {"operationFamily": "capability_route_activate/disable/rollback", "reason": "Activation, disable, and rollback are governed state changes outside a read-only readiness check."},
            {"operationFamily": "module_program_execution_*", "reason": "Runtime execution is not needed to inspect governance surfaces."}
        ],
        "completionRule": "After the listed overview/list operations, call trace_list last when the task asks for whole-session trace proof, then answer from exact operation results. Empty lists are valid evidence of no current-scope records; do not invent resource ids or call inspect operations without ids. Say no provider-visible mutating capability operation was used; do not claim no internal durability/bookkeeping mutation occurred.",
        "traceEvidenceBoundary": "trace_list is a point-in-time projection. If more operations run after trace_list, do not claim trace_list evidenced those later operations; call trace_list again at the end or qualify the coverage.",
        "finalAnswerGuidance": "Name the surfaces that were discoverable, the read-only operations used, any empty record planes, any confusing or missing guidance, and whether provider-safe trace evidence excludes raw internals. Explicitly say provider transcript tool-call ids may be visible in provider message history for protocol threading, while trace projections exclude raw trace providerInvocationId fields; do not report transcript call ids as absent when only trace projection safety was checked."
    }))
}

fn module_governance_plan_query(query: &OperationSearchQuery) -> bool {
    if operation_search_plan_target(query).is_some() || trace_evidence_plan_target(query).is_some()
    {
        return false;
    }
    if !query.display.chars().any(char::is_whitespace)
        || !supported_operations_in_query(query).is_empty()
    {
        return false;
    }
    let terms = query_terms(query);
    let asks_explicit_plan = terms.contains("governance") || terms.contains("readiness");
    let asks_module_governance = terms.contains("governance")
        || terms.contains("module")
        || terms.contains("registry")
        || terms.contains("lifecycle")
        || terms.contains("runtime")
        || terms.contains("dependency");
    let asks_capability_governance = terms.contains("binding")
        || terms.contains("replacement")
        || terms.contains("route")
        || terms.contains("routing");
    let asks_read_only_overview = query.canonical.contains("read_only")
        || query.canonical.contains("read")
        || query.canonical.contains("inspect")
        || query.canonical.contains("list")
        || query.canonical.contains("readiness")
        || terms.contains("policy")
        || terms.contains("request")
        || terms.contains("decision");
    asks_explicit_plan
        && (asks_module_governance || asks_capability_governance)
        && asks_read_only_overview
}

fn default_list_payload(operation: &str) -> Value {
    if operation == "capability_binding_cockpit_overview" {
        json!({"operation": operation})
    } else {
        json!({
            "operation": operation,
            "limit": 25
        })
    }
}

fn read_only_module_governance_reason(operation: &str) -> &'static str {
    match operation {
        "module_list" => {
            "List module manifest records without installing, enabling, or executing modules."
        }
        "module_lifecycle_list" => {
            "List lifecycle records; empty output means no lifecycle state is currently recorded in scope."
        }
        "module_runtime_list" => {
            "List runtime supervisor envelope records; empty output means no runtime envelope is recorded in scope."
        }
        "module_dependency_request_list" => {
            "List dependency requests; this does not request, approve, restore, or install dependencies."
        }
        "module_dependency_decision_list" => {
            "List dependency decisions; this does not create a decision."
        }
        "module_dependency_policy_list" => {
            "List dependency policy records; this does not activate dependency restoration."
        }
        "capability_binding_cockpit_overview" => {
            "Inspect operation ownership, replacement class, route state, and scoped evidence without changing routing."
        }
        "capability_binding_request_list" => {
            "List binding requests; this does not create a replacement or extension request."
        }
        "capability_binding_decision_list" => {
            "List binding decisions; this does not approve or reject anything."
        }
        "capability_binding_policy_list" => {
            "List binding policies; this does not activate routing."
        }
        "capability_replacement_candidate_list" => {
            "List replacement candidates; empty output means no candidate is recorded in scope."
        }
        "capability_route_binding_list" => {
            "List route bindings; this does not activate, disable, or roll back routing."
        }
        "capability_route_event_list" => {
            "List route events for activation, routed invocation, disable, rollback, and failed-closed history."
        }
        _ => "Read-only governance overview/list operation.",
    }
}

fn trace_evidence_helper_operation(operation: &str) -> bool {
    matches!(operation, "catalog_inspect" | "trace_list" | "trace_get")
}

fn operation_is_read_only_inspection_safe(operation: &str) -> bool {
    operation_agent_usage_projection(operation)
        .and_then(|usage| {
            usage
                .pointer("/effect/readOnlyInspectionSafe")
                .and_then(Value::as_bool)
        })
        .unwrap_or(false)
}

fn annotate_catalog_function_pool(object: &mut serde_json::Map<String, Value>, catalog_id: &str) {
    if let Some(metadata) = catalog_function_pool_metadata(catalog_id) {
        object.insert("capabilityPool".to_owned(), metadata.provider_projection());
    }
}

fn mark_catalog_target_non_callable(object: &mut serde_json::Map<String, Value>) {
    object.insert("providerCallable".to_owned(), Value::Bool(false));
    object.insert(
        "providerCallableReason".to_owned(),
        Value::String(
            "Catalog target is metadata only for model context; invoke capability::execute with a supported operation instead."
                .to_owned(),
        ),
    );
}

fn model_execute_operation_for_function_id(id: &str) -> Option<String> {
    if let Some(operation) = direct_model_execute_operation_for_function_id(id) {
        return Some(operation.to_owned());
    }
    let (namespace, name) = id.split_once("::")?;
    let candidate = format!("{namespace}_{name}");
    if is_supported_operation(&candidate) {
        Some(candidate)
    } else {
        None
    }
}

fn direct_model_execute_operation_for_function_id(id: &str) -> Option<&'static str> {
    match id {
        "logs::recent" => Some("log_recent"),
        "catalog_discovery::search" => Some("catalog_search"),
        "catalog_discovery::inspect" => Some("catalog_inspect"),
        "catalog_discovery::conformance_report" => Some("catalog_conformance"),
        "jobs::log" => Some("job_log"),
        _ => None,
    }
}

fn catalog_function_id_for_model_alias(id: &str) -> Option<String> {
    let alias = id.strip_prefix("execute::").unwrap_or(id);
    match alias {
        "log_recent" => Some("logs::recent".to_owned()),
        "catalog_search" => Some("catalog_discovery::search".to_owned()),
        "catalog_inspect" => Some("catalog_discovery::inspect".to_owned()),
        "catalog_conformance" => Some("catalog_discovery::conformance_report".to_owned()),
        "job_log" => Some("jobs::log".to_owned()),
        operation if is_supported_operation(operation) => {
            Some(catalog_function_id_for_execute_operation(operation))
        }
        _ => None,
    }
}

fn catalog_function_id_for_execute_operation(operation: &str) -> String {
    direct_catalog_function_id_for_execute_operation(operation)
        .unwrap_or("capability::execute")
        .to_owned()
}

fn direct_catalog_function_id_for_execute_operation(operation: &str) -> Option<&'static str> {
    match operation {
        "log_recent" => Some("logs::recent"),
        "catalog_search" => Some("catalog_discovery::search"),
        "catalog_inspect" => Some("catalog_discovery::inspect"),
        "catalog_conformance" => Some("catalog_discovery::conformance_report"),
        "job_log" => Some("jobs::log"),
        "git_status" => Some("git::status"),
        "git_diff" => Some("git::diff"),
        "git_stage" => Some("git::stage"),
        "git_unstage" => Some("git::unstage"),
        "git_commit" => Some("git::commit"),
        "git_branch_start" => Some("git::branch_start"),
        "git_branch_inventory" => Some("git::branch_inventory"),
        "capability_binding_cockpit_overview" => Some("capability_binding::cockpit_overview"),
        _ => None,
    }
}

pub(super) async fn catalog_conformance(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let report =
        service::conformance_report_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    let status = report["status"].as_str().unwrap_or("failed");
    let resource_id = report["reportResourceId"].as_str().unwrap_or("unknown");
    Ok(ok_result(
        format!("Catalog conformance {status}; report resource {resource_id}."),
        json!({
            "primitiveOperation": "catalog_conformance",
            "status": status,
            "catalogDiscovery": report
        }),
    ))
}

#[cfg(test)]
mod tests;
