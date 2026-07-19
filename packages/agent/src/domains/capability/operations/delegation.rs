//! Provider-facing adapters for the minimal delegation workflow.

use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn delegation_start(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value = invoke("delegation::start", invocation, deps).await?;
    let content = handle_content("Started", &value);
    Ok(result("delegation_start", &content, value))
}

pub(super) async fn delegation_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value = invoke("delegation::inspect", invocation, deps).await?;
    let content = handle_content("Inspected", &value);
    Ok(result("delegation_inspect", &content, value))
}

pub(super) async fn delegation_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value = invoke("delegation::list", invocation, deps).await?;
    let rows = value["delegations"].as_array().cloned().unwrap_or_default();
    let count = rows.len();
    let handles = rows
        .iter()
        .map(|delegation| {
            format!(
                "{} [{}] version {}",
                delegation
                    .pointer("/workflowRef/id")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown"),
                delegation
                    .get("state")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown"),
                delegation
                    .pointer("/versionRef/versionId")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    Ok(result(
        "delegation_list",
        &format!("Found {count} current-session delegation handles.\n{handles}"),
        value,
    ))
}

pub(super) async fn delegation_cancel(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value = invoke("delegation::cancel", invocation, deps).await?;
    let content = handle_content("Cancelled", &value);
    Ok(result("delegation_cancel", &content, value))
}

fn handle_content(action: &str, value: &Value) -> String {
    let delegation = &value["delegation"];
    format!(
        "{action} delegation {} in state {} at version {}.",
        delegation
            .pointer("/workflowRef/id")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        delegation
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
        delegation
            .pointer("/versionRef/versionId")
            .and_then(Value::as_str)
            .unwrap_or("unknown"),
    )
}

pub(super) async fn delegation_accept_result(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value = invoke("delegation::accept_result", invocation, deps).await?;
    let summary = value
        .pointer("/delegation/resultSummary")
        .and_then(Value::as_str)
        .unwrap_or("Accepted delegated child result without a text summary.");
    let handle = handle_content("Accepted", &value);
    Ok(result(
        "delegation_accept_result",
        &format!("{handle}\nAccepted delegated child result:\n{summary}"),
        value,
    ))
}

fn result(operation: &str, content: &str, value: serde_json::Value) -> CapabilityResult {
    ok_result(
        content.to_owned(),
        json!({"primitiveOperation": operation, "status": "ok", "delegation": value}),
    )
}

async fn invoke(
    function: &str,
    parent: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = delegation_payload(parent)?;
    let mut context = parent.causal_context.clone();
    context.actor_id =
        crate::engine::ActorId::new("system:delegation-adapter").map_err(engine_error)?;
    context.actor_kind = crate::engine::ActorKind::System;
    context.authority_grant_id =
        crate::engine::AuthorityGrantId::new("engine-system").map_err(engine_error)?;
    context.parent_invocation_id = Some(parent.id.clone());
    context.idempotency_key = Some(format!("{function}:{}", parent.id));
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            crate::engine::FunctionId::new(function).map_err(engine_error)?,
            payload,
            context,
        ))
        .await;
    crate::shared::server::error_mapping::result_to_capability_value(result)
}

fn delegation_payload(parent: &Invocation) -> Result<Value, CapabilityError> {
    let mut payload = parent.payload.clone();
    if let Some(object) = payload.as_object_mut() {
        object.remove("operation");
        if !object.contains_key("sessionId") {
            let session_id = parent.causal_context.session_id.as_deref().ok_or_else(|| {
                CapabilityError::InvalidParams {
                    message: "delegation operations require session causality".into(),
                }
            })?;
            object.insert("sessionId".to_owned(), Value::String(session_id.to_owned()));
        }
    }
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_adapter_injects_causal_session_and_removes_outer_operation() {
        let parent = Invocation::new_sync(
            crate::engine::FunctionId::new("capability::execute").unwrap(),
            json!({"operation": "delegation_start", "objectiveSummary": "inspect", "successCriteria": ["report"], "idempotencyKey": "key"}),
            crate::engine::CausalContext::new(
                crate::engine::ActorId::new("agent:parent").unwrap(),
                crate::engine::ActorKind::Agent,
                crate::engine::AuthorityGrantId::new("grant").unwrap(),
                crate::engine::TraceId::generate(),
            )
            .with_session_id("parent-session"),
        );
        let payload = delegation_payload(&parent).unwrap();
        assert_eq!(payload["sessionId"], "parent-session");
        assert!(payload.get("operation").is_none());
    }

    #[test]
    fn accepted_result_content_carries_the_bounded_projection_summary() {
        let result = result(
            "delegation_accept_result",
            "Accepted delegation delegation:1 in state accepted at version version:1.\nAccepted delegated child result:\nbounded child finding",
            json!({"delegation": {"state": "accepted", "resultSummary": "bounded child finding"}}),
        );
        let crate::shared::protocol::model_capabilities::CapabilityResultBody::Blocks(blocks) =
            result.content
        else {
            panic!("expected text blocks");
        };
        assert!(matches!(
            &blocks[0],
            crate::shared::protocol::content::CapabilityResultContent::Text { text }
                if text == "Accepted delegated child result:\nbounded child finding"
                    || text.ends_with("Accepted delegated child result:\nbounded child finding")
        ));
    }
}

fn engine_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}
