use serde_json::{Value, json};

use super::ok_result;
use super::registry::{is_supported_operation, supported_operation_names};
use crate::domains::capability::Deps;
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
    let visible = discovery
        .pointer("/summary/functions/visible")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    Ok(ok_result(
        format!("Catalog search returned {visible} visible functions."),
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
                "catalogInspect": "Use functions[].id exactly as catalog_inspect kind=function id.",
                "capabilityExecute": "When a function includes modelFacingInvocation, invoke that operation through capability::execute instead of using the catalog function id as the primitive operation.",
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
                if let Some(operation) = model_execute_operation_for_function_id(&catalog_id) {
                    object.insert(
                        "modelFacingInvocation".to_owned(),
                        json!({
                            "tool": "capability::execute",
                            "operation": operation,
                            "arguments": {"operation": operation},
                            "catalogInspectId": catalog_id
                        }),
                    );
                } else {
                    mark_catalog_target_non_callable(object);
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
            if let Some(operation) = model_execute_operation_for_function_id(&catalog_id) {
                object.insert(
                    "modelFacingInvocation".to_owned(),
                    json!({
                        "tool": "capability::execute",
                        "operation": operation,
                        "arguments": {"operation": operation},
                        "catalogInspectId": catalog_id
                    }),
                );
            } else {
                mark_catalog_target_non_callable(object);
            }
        }
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

fn model_execute_operation_for_function_id(id: &str) -> Option<&'static str> {
    match id {
        "logs::recent" => Some("log_recent"),
        "catalog_discovery::search" => Some("catalog_search"),
        "catalog_discovery::inspect" => Some("catalog_inspect"),
        "catalog_discovery::conformance_report" => Some("catalog_conformance"),
        "jobs::log" => Some("job_log"),
        _ => None,
    }
}

fn catalog_function_id_for_model_alias(id: &str) -> Option<&'static str> {
    let alias = id.strip_prefix("execute::").unwrap_or(id);
    match alias {
        "log_recent" => Some("logs::recent"),
        "catalog_search" => Some("catalog_discovery::search"),
        "catalog_inspect" => Some("catalog_discovery::inspect"),
        "catalog_conformance" => Some("catalog_discovery::conformance_report"),
        "job_log" => Some("jobs::log"),
        operation if is_supported_operation(operation) => Some("capability::execute"),
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
                {"id": "capability::execute"}
            ]
        });

        annotate_model_facing_invocation(&mut discovery);

        assert_eq!(
            discovery["functions"][0]["modelFacingInvocation"]["operation"],
            "log_recent"
        );
        assert!(
            discovery["functions"][1]
                .get("modelFacingInvocation")
                .is_none()
        );
        assert_eq!(discovery["functions"][1]["providerCallable"], false);
        assert!(
            discovery["functions"][1]["providerCallableReason"]
                .as_str()
                .unwrap_or_default()
                .contains("capability::execute")
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
}
