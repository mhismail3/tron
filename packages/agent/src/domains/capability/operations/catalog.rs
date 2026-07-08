use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::ok_result;
use super::registry::{is_supported_operation, supported_operation_names};
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
    annotate_model_facing_invocation(&mut discovery);
    annotate_execute_operation_matches(&mut discovery, &invocation.payload);
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
    let content = if operation_matches == 0 && operation_search_total == Some(0) {
        format!(
            "Catalog search returned {visible} visible functions and 0 execute operation matches."
        )
    } else if operation_matches == 0 {
        format!("Catalog search returned {visible} visible functions.")
    } else {
        format!(
            "Catalog search returned {visible} visible functions and {operation_matches} execute operation match(es)."
        )
    };
    Ok(ok_result(
        content,
        json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": discovery
        }),
    ))
}

pub(super) async fn catalog_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    if let Some((operation, alias)) = execute_operation_inspect_target(&invocation.payload) {
        let discovery = execute_operation_inspect_projection(&operation, &alias);
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
                "Catalog {kind} inspected: {id}. Required top-level payload fields: {required_fields}."
            ),
            json!({
                "primitiveOperation": "catalog_inspect",
                "status": "ok",
                "catalogDiscovery": discovery
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
    annotate_model_facing_invocation(&mut discovery);
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

fn execute_operation_inspect_projection(operation: &str, alias: &str) -> Value {
    let id = format!("execute::{operation}");
    let agent_usage = operation_agent_usage_projection(operation).unwrap_or_else(|| {
        json!({
            "callable": true,
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation}
        })
    });
    let required_payload_fields = agent_usage
        .pointer("/preflight/requiredPayloadFields")
        .and_then(Value::as_array)
        .filter(|fields| !fields.is_empty())
        .cloned()
        .unwrap_or_else(|| operation_required_payload_fields(operation));
    let required_payload_field_names = required_payload_fields
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    let effect = agent_usage.get("effect").cloned();
    let preflight = agent_usage.get("preflight").cloned();
    let input_schema = execute_operation_input_schema(operation, &required_payload_field_names);
    let output_schema = execute_operation_output_schema(operation);
    let model_facing_invocation = json!({
        "tool": "capability::execute",
        "operation": operation,
        "arguments": {"operation": operation},
        "catalogInspectId": id,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
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
        "outputSchema": output_schema.clone(),
        "modelFacingInvocation": model_facing_invocation,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": agent_usage,
        "schema": {
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation},
            "requiredPayloadFields": required_payload_fields,
            "inputSchema": input_schema,
            "outputSchema": output_schema,
            "payloadPlacement": "Put operation-specific fields at the top level of the capability::execute payload.",
            "schemaCompleteness": "operation_specific_contract",
            "effect": effect,
            "preflight": preflight
        }
    });
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

fn execute_operation_input_schema(operation: &str, required_fields: &[&str]) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "operation".to_owned(),
        json!({
            "type": "string",
            "const": operation,
            "description": "Exact capability::execute operation selector."
        }),
    );
    for field in required_fields {
        if *field == "operation" {
            continue;
        }
        properties.insert(
            (*field).to_owned(),
            json!({
                "type": "string",
                "description": "Operation-specific top-level payload field required before invoking this capability."
            }),
        );
    }

    json!({
        "type": "object",
        "required": required_fields,
        "properties": properties,
        "additionalProperties": true,
        "payloadPlacement": "top_level_capability_execute_payload",
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn execute_operation_output_schema(operation: &str) -> Value {
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe text summary of the operation result."
            },
            "details": {
                "type": "object",
                "description": "Bounded provider-safe evidence for the operation result.",
                "properties": {
                    "primitiveOperation": {"const": operation},
                    "status": {"type": "string"}
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
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

fn operation_required_payload_fields(operation: &str) -> Vec<Value> {
    let fields = match operation {
        "capability_binding_request_inspect" => {
            vec!["operation", "capabilityBindingRequestResourceId"]
        }
        "capability_binding_decision_inspect" => {
            vec!["operation", "capabilityBindingDecisionResourceId"]
        }
        "capability_binding_policy_inspect" => {
            vec!["operation", "capabilityBindingPolicyResourceId"]
        }
        "capability_shadow_trial_evidence_inspect" => {
            vec!["operation", "capabilityShadowTrialEvidenceResourceId"]
        }
        "capability_replacement_candidate_inspect" => {
            vec!["operation", "capabilityReplacementCandidateResourceId"]
        }
        "capability_route_binding_inspect" => {
            vec!["operation", "capabilityRouteBindingResourceId"]
        }
        "capability_route_event_inspect" => vec!["operation", "capabilityRouteEventResourceId"],
        operation if operation.ends_with("_inspect") => vec!["operation", "<exactResourceIdField>"],
        _ => vec!["operation"],
    };
    fields
        .iter()
        .map(|field| Value::String((*field).to_owned()))
        .collect()
}

fn annotate_model_facing_invocation(discovery: &mut Value) {
    if let Some(object) = discovery.as_object_mut() {
        object.insert(
            "modelFacingGuidance".to_owned(),
            json!({
                "catalogInspect": "Use functions[].id exactly as catalog_inspect kind=function id when inspecting engine substrate.",
                "capabilityExecute": "For normal session work, invoke capability::execute operations. Catalog functions are engine substrate unless modelFacingInvocation points at an execute operation.",
                "operationSearch": "If executeOperationMatches is present, use those operation names directly with capability::execute. They are provider-visible operations, not separate catalog functions.",
                "executeSchemaInspection": "Before invoking a provider-visible operation, inspect execute::<operation> with catalog_inspect to get exact top-level payload fields. Backing catalog function ids are secondary diagnostics.",
                "internalDiscovery": "Internal catalog functions are inspect-only by default. Request diagnostics or kernel-evolution context before using them to reason about engine internals.",
                "supportedExecuteOperations": supported_operation_names()
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

fn annotate_execute_operation_matches(discovery: &mut Value, payload: &Value) {
    let Some(query) = payload.get("text").and_then(Value::as_str) else {
        return;
    };
    let Some(query) = OperationSearchQuery::from_text(query) else {
        return;
    };
    let limit = payload
        .get("limit")
        .and_then(Value::as_u64)
        .map(|limit| limit as usize)
        .unwrap_or(20)
        .clamp(1, 50);
    let mut matches = supported_operation_names()
        .iter()
        .filter_map(|operation| operation_match_projection(operation, &query))
        .collect::<Vec<_>>();
    let plan_operations = operation_search_plan_supported_operations(&query);
    for operation in &plan_operations {
        promote_or_insert_planned_operation_match(&mut matches, operation);
    }
    if !plan_operations.is_empty() {
        let allowed = plan_operations.iter().copied().collect::<BTreeSet<_>>();
        matches.retain(|entry| {
            entry
                .get("operation")
                .and_then(Value::as_str)
                .is_some_and(|operation| allowed.contains(operation))
        });
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
            }),
        );
        if let Some(plan) = operation_search_plan_projection(&query) {
            object.insert("agentSearchPlan".to_owned(), plan);
        }
        if let Some(next_step) = preferred_execute_schema_next_step(&matches) {
            object.insert("agentNextStep".to_owned(), next_step);
        }
        object.insert("executeOperationMatches".to_owned(), Value::Array(matches));
        if total == 0 && looks_like_unsupported_operation_candidate(&query) {
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
    Some(json!({
        "priority": "inspect_execute_operation_schema_first",
        "reason": "Before invoking a provider-visible capability::execute operation, inspect the execute::<operation> schema for exact top-level payload fields. Backing catalog function ids are engine substrate and are secondary unless the task is diagnostics or kernel evolution.",
        "schemaInspection": execute_schema_inspection_step(operation),
        "thenInvoke": {
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation}
        }
    }))
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

fn execute_schema_inspection_step(operation: &str) -> Value {
    json!({
        "operation": "catalog_inspect",
        "tool": "capability::execute",
        "arguments": {
            "operation": "catalog_inspect",
            "kind": "function",
            "id": format!("execute::{operation}"),
            "maxSchemaBytes": 8000
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

fn match_rank(match_kind: &str) -> usize {
    match match_kind {
        "exact" => 0,
        "prefix" => 1,
        "plan" => 2,
        "contains" => 3,
        "terms" => 4,
        "intent" => 5,
        _ => 5,
    }
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

    let mut followups = vec![
        recovery_alternative(
            "catalog_inspect",
            json!({"operation": "catalog_inspect", "kind": "function", "id": format!("execute::{target}"), "maxSchemaBytes": 8000}),
            "Inspect the exact request schema before invoking the target operation.",
        ),
        recovery_alternative(
            "capability_binding_cockpit_overview",
            json!({"operation": "capability_binding_cockpit_overview", "targetOperation": target}),
            "Inspect this operation's role, replacement class, binding, shadow, route, rollback, and scoped evidence counts without invoking the adapter.",
        ),
    ];
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
        "doNotCall": [
            {"operation": target, "reason": "Do not invoke the adapter just to inspect replacement readiness; call it only when the task needs the adapter effect."},
            {"operation": "capability_shadow_trial_request_list", "reason": "No provider-visible list operation exists for shadow trial requests; use targeted cockpit counts and exact evidence inspect only when an evidence ref exists."},
            {"operation": "capability_shadow_trial_run_list", "reason": "No provider-visible list operation exists for shadow trial runs; use route events and exact evidence refs instead."}
        ],
        "completionRule": "If targeted cockpit counts and scoped list operations are empty, report that no current-scope evidence is recorded instead of searching for unsupported list operations.",
        "finalAnswerWhen": "After the targeted cockpit overview and listed read-only sequence show zero candidates, routes, bindings, events, or exact shadow evidence refs, stop and answer from those facts.",
        "doNotInspect": [
            {"operation": "capability_shadow_trial_evidence_inspect", "reason": "Only inspect shadow evidence when an exact capabilityShadowTrialEvidenceResourceId is already present in cockpit, route-event, or resource output."}
        ]
    }))
}

fn operation_search_plan_supported_operations(query: &OperationSearchQuery) -> Vec<&'static str> {
    let Some((target, query_terms)) = operation_search_plan_target(query) else {
        return Vec::new();
    };
    let mut operations = vec![
        target,
        "catalog_inspect",
        "capability_binding_cockpit_overview",
    ];
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
    if query_terms.contains("shadow")
        || query_terms.contains("trial")
        || query_terms.contains("evidence")
    {
        operations.push("capability_shadow_trial_evidence_inspect");
    }
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
    let asks_readiness = query_terms.iter().any(|term| {
        matches!(
            term.as_str(),
            "replacement"
                | "replace"
                | "replacing"
                | "route"
                | "routing"
                | "binding"
                | "shadow"
                | "trial"
                | "evidence"
                | "readiness"
                | "rollback"
                | "candidate"
        )
    });
    asks_readiness.then_some((target, query_terms))
}

fn annotate_catalog_function_pool(object: &mut serde_json::Map<String, Value>, catalog_id: &str) {
    if let Some(metadata) = catalog_function_pool_metadata(catalog_id) {
        object.insert(
            "capabilityPool".to_owned(),
            serde_json::to_value(metadata.provider_projection())
                .expect("capability pool projection serializes"),
        );
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
mod tests {
    use super::*;

    #[test]
    fn catalog_inspect_normalizes_model_facing_log_alias() {
        let (payload, alias) = normalize_catalog_inspect_payload(&json!({
            "kind": "function",
            "id": "execute::log_recent"
        }));

        assert_eq!(payload["id"], "logs::recent");
        assert_eq!(alias.as_deref(), Some("execute::log_recent"));
    }

    #[test]
    fn catalog_inspect_normalizes_direct_catalog_operation_aliases() {
        let (payload, alias) = normalize_catalog_inspect_payload(&json!({
            "kind": "function",
            "id": "git_status"
        }));

        assert_eq!(payload["id"], "git::status");
        assert_eq!(alias.as_deref(), Some("git_status"));
    }

    #[test]
    fn catalog_inspect_detects_execute_operation_aliases_before_generic_schema() {
        let (operation, alias) = execute_operation_inspect_target(&json!({
            "kind": "function",
            "id": "execute::capability_shadow_trial_evidence_inspect"
        }))
        .expect("execute operation alias");

        assert_eq!(operation, "capability_shadow_trial_evidence_inspect");
        assert_eq!(alias, "execute::capability_shadow_trial_evidence_inspect");

        let discovery = execute_operation_inspect_projection(&operation, &alias);
        assert_eq!(discovery["kind"], "execute_operation");
        assert_eq!(
            discovery["id"],
            "execute::capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(
            discovery["operation"],
            "capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(discovery["providerCallable"], true);
        assert_eq!(
            discovery["modelFacingInvocation"]["arguments"]["operation"],
            "capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(
            discovery["schema"]["requiredPayloadFields"],
            json!(["operation", "capabilityShadowTrialEvidenceResourceId"])
        );
        assert_eq!(
            discovery["inputSchema"]["required"],
            json!(["operation", "capabilityShadowTrialEvidenceResourceId"])
        );
        assert_eq!(
            discovery["inputSchema"]["properties"]["operation"]["const"],
            "capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(
            discovery["inputSchema"]["properties"]["capabilityShadowTrialEvidenceResourceId"]["type"],
            "string"
        );
        assert_eq!(
            discovery["schema"]["inputSchema"]["required"],
            json!(["operation", "capabilityShadowTrialEvidenceResourceId"])
        );
        assert_eq!(
            discovery["outputSchema"]["properties"]["details"]["properties"]["primitiveOperation"]
                ["const"],
            "capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(
            discovery["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            true
        );
    }

    #[test]
    fn catalog_search_annotations_bridge_catalog_ids_to_execute_operations() {
        let mut discovery = json!({
            "functions": [
                {"id": "logs::recent"},
                {"id": "git::status"},
                {"id": "capability_binding::cockpit_overview"},
                {"id": "capability::execute"}
            ]
        });

        annotate_model_facing_invocation(&mut discovery);

        assert_eq!(
            discovery["functions"][0]["modelFacingInvocation"]["operation"],
            "log_recent"
        );
        assert_eq!(
            discovery["functions"][1]["modelFacingInvocation"]["operation"],
            "git_status"
        );
        assert_eq!(
            discovery["functions"][1]["modelFacingInvocation"]["providerSchemaInspectId"],
            "execute::git_status"
        );
        assert_eq!(
            discovery["functions"][1]["modelFacingInvocation"]["preferredSchemaInspection"]["arguments"]
                ["id"],
            "execute::git_status"
        );
        assert_eq!(discovery["functions"][1]["agentUsage"]["callable"], true);
        assert_eq!(
            discovery["functions"][2]["modelFacingInvocation"]["operation"],
            "capability_binding_cockpit_overview"
        );
        assert_eq!(
            discovery["functions"][2]["agentUsage"]["preflight"]["resourceSelectors"][0],
            "kind:capability_binding_request"
        );
        assert_eq!(
            discovery["functions"][0]["capabilityPool"]["surface"],
            "catalog_function"
        );
        assert_eq!(
            discovery["functions"][0]["modelFacingInvocation"]["capabilityPool"]["surface"],
            "agent_operation"
        );
        assert_eq!(
            discovery["functions"][0]["modelFacingInvocation"]["capabilityPool"]["audience"],
            "agent_diagnostics"
        );
        assert!(
            discovery["functions"][3]
                .get("modelFacingInvocation")
                .is_none()
        );
        assert_eq!(
            discovery["functions"][3]["capabilityPool"]["audience"],
            "session_work"
        );
        assert_eq!(
            discovery["functions"][3]["capabilityPool"]["agentDefaultVisibility"],
            "search_visible"
        );
        assert_eq!(discovery["functions"][3]["providerCallable"], false);
        assert!(
            discovery["functions"][3]["providerCallableReason"]
                .as_str()
                .unwrap_or_default()
                .contains("capability::execute")
        );
        assert_eq!(
            discovery["functions"][3]["agentUsage"]["defaultUse"],
            "inspect_only"
        );
        assert_eq!(
            discovery["modelFacingGuidance"]["supportedExecuteOperations"]
                .as_array()
                .expect("operations")
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>(),
            supported_operation_names().to_vec()
        );
    }

    #[test]
    fn catalog_search_adds_exact_execute_operation_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "trace_list", "limit": 10}),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(matches[0]["operation"], "trace_list");
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["tool"], "capability::execute");
        assert_eq!(matches[0]["arguments"]["operation"], "trace_list");
        assert_eq!(matches[0]["catalogInspectId"], "execute::trace_list");
        assert_eq!(
            matches[0]["schemaInspection"]["arguments"]["id"],
            "execute::trace_list"
        );
        assert_eq!(
            discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
            "execute::trace_list"
        );
        assert_eq!(
            discovery["agentNextStep"]["priority"],
            "inspect_execute_operation_schema_first"
        );
        assert_eq!(
            matches[0]["capabilityPool"]["audience"],
            "agent_diagnostics"
        );
        assert_eq!(
            matches[0]["capabilityPool"]["replacementClass"],
            "kernel_evolution_only"
        );
        assert_eq!(matches[0]["agentUsage"]["callable"], true);
        assert_eq!(
            discovery["executeOperationSearch"]["totalMatches"],
            matches.len()
        );
    }

    #[test]
    fn catalog_search_adds_multiple_exact_execute_operation_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_binding_request_list capability_binding_decision_list capability_binding_policy_list", "limit": 10}),
        );

        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            operations,
            vec![
                "capability_binding_decision_list",
                "capability_binding_policy_list",
                "capability_binding_request_list",
            ]
        );
        assert!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("operation matches")
                .iter()
                .all(|value| value["matchKind"] == "exact")
        );
        assert_eq!(
            discovery["executeOperationSearch"]["canonicalQuery"]
                .as_str()
                .expect("canonical query"),
            "capability_binding_request_list_capability_binding_decision_list_capability_binding_policy_list"
        );
        assert!(
            discovery["executeOperationSearch"]["terms"]
                .as_array()
                .expect("terms")
                .iter()
                .any(|term| term == "request")
        );
    }

    #[test]
    fn catalog_search_advertises_write_operations_as_not_read_only_safe() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_shadow_trial_request_record", "limit": 10}),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(
            matches[0]["operation"],
            "capability_shadow_trial_request_record"
        );
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["agentUsage"]["effect"]["mode"], "metadata_write");
        assert_eq!(
            matches[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            false
        );
        assert_eq!(matches[0]["agentUsage"]["effect"]["mutatesState"], true);
        assert!(
            matches[0]["agentUsage"]["effect"]["readOnlyInstruction"]
                .as_str()
                .expect("effect instruction")
                .contains("do not call during read-only inspection")
        );
        assert!(
            matches[0]["agentUsage"]["preflight"]["readOnlyInstruction"]
                .as_str()
                .expect("preflight instruction")
                .contains("Do not call during read-only inspection")
        );
    }

    #[test]
    fn catalog_search_advertises_conformance_as_report_write() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "catalog_conformance", "limit": 10}),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(matches[0]["operation"], "catalog_conformance");
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["agentUsage"]["effect"]["mode"], "metadata_write");
        assert_eq!(
            matches[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            false
        );
        assert_eq!(matches[0]["agentUsage"]["effect"]["writesResource"], true);
        assert!(
            matches[0]["agentUsage"]["effect"]["readOnlyInstruction"]
                .as_str()
                .expect("effect instruction")
                .contains("do not call during read-only inspection")
        );
    }

    #[test]
    fn catalog_search_adds_prefix_execute_operation_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_binding_request", "limit": 20}),
        );

        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert!(operations.contains(&"capability_binding_request_record"));
        assert!(operations.contains(&"capability_binding_request_list"));
        assert!(operations.contains(&"capability_binding_request_inspect"));
        assert!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("operation matches")
                .iter()
                .all(|value| value["matchKind"] == "prefix")
        );
    }

    #[test]
    fn catalog_search_explicitly_recovers_unsupported_operation_like_queries() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_shadow_trial_request_list", "limit": 10}),
        );

        assert_eq!(
            discovery["executeOperationSearch"]["canonicalQuery"],
            "capability_shadow_trial_request_list"
        );
        assert_eq!(
            discovery["executeOperationSearch"]["totalMatches"],
            json!(0)
        );
        assert_eq!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("empty operation matches")
                .len(),
            0
        );
        assert_eq!(discovery["unsupportedOperationCandidate"], json!(true));
        assert!(
            discovery["unsupportedOperationRecovery"]["guidance"]
                .as_str()
                .expect("guidance")
                .contains("Do not call the queried name")
        );
        let alternatives = discovery["unsupportedOperationRecovery"]["closestReadOnlyAlternatives"]
            .as_array()
            .expect("alternatives");
        assert!(alternatives.iter().any(|alternative| {
            alternative["operation"] == "capability_binding_cockpit_overview"
                && alternative["arguments"]["targetOperation"] == "<supported_operation>"
        }));
        assert!(alternatives.iter().any(|alternative| {
            alternative["operation"] == "capability_shadow_trial_evidence_inspect"
        }));
    }

    #[test]
    fn catalog_search_maps_catalog_style_text_to_execute_operation_match() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(&mut discovery, &json!({"text": "git::status"}));

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(matches[0]["operation"], "git_status");
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["catalogInspectId"], "execute::git_status");
        assert_eq!(
            matches[0]["schemaInspection"]["arguments"]["id"],
            "execute::git_status"
        );
        assert_eq!(matches[0]["capabilityPool"]["audience"], "session_work");
        assert_eq!(
            matches[0]["capabilityPool"]["replacementClass"],
            "runtime_routable"
        );
        assert_eq!(
            discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
            "execute::git_status"
        );
    }

    #[test]
    fn catalog_search_returns_agent_readiness_plan_for_multi_intent_queries() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "text": "git_status replacement readiness shadow trial route binding evidence",
                "limit": 25
            }),
        );

        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        for expected in [
            "git_status",
            "capability_binding_cockpit_overview",
            "capability_replacement_candidate_list",
            "capability_route_binding_list",
            "capability_route_event_list",
            "capability_shadow_trial_evidence_inspect",
        ] {
            assert!(
                operations.contains(&expected),
                "multi-intent search should include {expected}: {operations:?}"
            );
        }
        assert!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("operation matches")
                .iter()
                .all(|value| value["matchKind"] == "plan")
        );
        assert!(!operations.contains(&"git_commit"));
        assert!(!operations.contains(&"capability_shadow_trial_request_record"));
        assert_eq!(
            discovery["agentSearchPlan"]["targetOperation"],
            json!("git_status")
        );
        assert_eq!(
            discovery["agentSearchPlan"]["primaryInspection"]["arguments"]["targetOperation"],
            json!("git_status")
        );
        assert!(
            discovery["agentSearchPlan"]["completionRule"]
                .as_str()
                .expect("completion rule")
                .contains("no current-scope evidence is recorded")
        );
        assert!(
            discovery["agentSearchPlan"]["finalAnswerWhen"]
                .as_str()
                .expect("final answer")
                .contains("stop and answer")
        );
        assert_eq!(
            discovery["agentSearchPlan"]["doNotInspect"][0]["operation"],
            "capability_shadow_trial_evidence_inspect"
        );
        let do_not_call = discovery["agentSearchPlan"]["doNotCall"]
            .as_array()
            .expect("do not call");
        assert!(
            do_not_call
                .iter()
                .any(|entry| entry["operation"] == "git_status")
        );
        assert!(
            do_not_call
                .iter()
                .any(|entry| entry["operation"] == "capability_shadow_trial_request_list")
        );
    }

    #[test]
    fn catalog_search_does_not_expand_generic_execute_catalog_function() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability::execute", "limit": 50}),
        );

        assert!(
            discovery.get("executeOperationMatches").is_none(),
            "generic capability::execute schema must not become operation matches"
        );
        assert!(discovery.get("executeOperationSearch").is_none());
    }

    #[test]
    fn catalog_search_does_not_expand_normalized_generic_execute_query() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_execute", "limit": 50}),
        );

        assert!(
            discovery.get("executeOperationMatches").is_none(),
            "normalized generic execute query must not become operation matches"
        );
        assert!(discovery.get("executeOperationSearch").is_none());
    }
}
