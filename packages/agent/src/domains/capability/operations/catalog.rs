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
    let content = if operation_matches == 0 {
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

fn annotate_model_facing_invocation(discovery: &mut Value) {
    if let Some(object) = discovery.as_object_mut() {
        object.insert(
            "modelFacingGuidance".to_owned(),
            json!({
                "catalogInspect": "Use functions[].id exactly as catalog_inspect kind=function id when inspecting engine substrate.",
                "capabilityExecute": "For normal session work, invoke capability::execute operations. Catalog functions are engine substrate unless modelFacingInvocation points at an execute operation.",
                "operationSearch": "If executeOperationMatches is present, use those operation names directly with capability::execute. They are provider-visible operations, not separate catalog functions.",
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
    let query = normalize_operation_query(query);
    if query.len() < 3 {
        return;
    }
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
    matches.sort_by(|left, right| {
        match_rank(left["matchKind"].as_str().unwrap_or_default())
            .cmp(&match_rank(right["matchKind"].as_str().unwrap_or_default()))
            .then_with(|| {
                left["operation"]
                    .as_str()
                    .unwrap_or_default()
                    .cmp(right["operation"].as_str().unwrap_or_default())
            })
    });
    let total = matches.len();
    if total == 0 {
        return;
    }
    matches.truncate(limit);
    if let Some(object) = discovery.as_object_mut() {
        object.insert(
            "executeOperationSearch".to_owned(),
            json!({
                "query": query,
                "totalMatches": total,
                "returnedMatches": matches.len(),
                "truncated": total > matches.len(),
                "omitted": total.saturating_sub(matches.len()),
            }),
        );
        object.insert("executeOperationMatches".to_owned(), Value::Array(matches));
    }
}

fn normalize_operation_query(query: &str) -> String {
    query
        .trim()
        .strip_prefix("execute::")
        .unwrap_or_else(|| query.trim())
        .replace("::", "_")
        .to_ascii_lowercase()
}

fn operation_match_projection(operation: &str, query: &str) -> Option<Value> {
    let operation_key = operation.to_ascii_lowercase();
    let catalog_key = direct_catalog_function_id_for_execute_operation(operation)
        .map(str::to_owned)
        .unwrap_or_default()
        .replace("::", "_")
        .to_ascii_lowercase();
    let has_direct_catalog_key = !catalog_key.is_empty();
    let match_kind = if operation_key == query || (has_direct_catalog_key && catalog_key == query) {
        "exact"
    } else if operation_key.starts_with(query)
        || (has_direct_catalog_key && catalog_key.starts_with(query))
    {
        "prefix"
    } else if query.len() >= 5
        && (operation_key.contains(query)
            || (has_direct_catalog_key && catalog_key.contains(query)))
    {
        "contains"
    } else {
        return None;
    };
    Some(json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "matchKind": match_kind,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    }))
}

fn match_rank(match_kind: &str) -> usize {
    match match_kind {
        "exact" => 0,
        "prefix" => 1,
        "contains" => 2,
        _ => 3,
    }
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
    fn catalog_inspect_normalizes_other_execute_operation_aliases_to_execute_schema() {
        let (payload, alias) = normalize_catalog_inspect_payload(&json!({
            "kind": "function",
            "id": "module_runtime_request"
        }));

        assert_eq!(payload["id"], "capability::execute");
        assert_eq!(alias.as_deref(), Some("module_runtime_request"));
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
    fn catalog_search_maps_catalog_style_text_to_execute_operation_match() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(&mut discovery, &json!({"text": "git::status"}));

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(matches[0]["operation"], "git_status");
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["capabilityPool"]["audience"], "session_work");
        assert_eq!(
            matches[0]["capabilityPool"]["replacementClass"],
            "runtime_routable"
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
