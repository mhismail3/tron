//! Authenticated webhook credential rotation and typed-input ingress.

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::types::InvokeRequest;
use super::Deps;
use super::support::required_string;

pub(super) async fn rotate_webhook(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    serde_json::to_value(deps.runtime.store().rotate_webhook(
        &required_string(&invocation.payload, "workerId")?,
        &required_string(&invocation.payload, "triggerId")?,
    )?)
    .map_err(|error| error.to_string())
}

pub(super) async fn webhook(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let worker_id = required_string(&invocation.payload, "workerId")?;
    let trigger_id = required_string(&invocation.payload, "triggerId")?;
    let token = required_string(&invocation.payload, "token")?;
    let configured = deps
        .runtime
        .store()
        .verify_webhook(&worker_id, &trigger_id, &token)?;
    let body = invocation
        .payload
        .get("input")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let input = materialize_webhook_input(configured, body);
    serde_json::to_value(deps.runtime.enqueue(InvokeRequest {
        worker_id,
        input,
        model: None,
        reasoning_level: None,
        idempotency_key: format!(
            "webhook:{trigger_id}:{}",
            required_string(&invocation.payload, "idempotencyKey")?
        ),
        trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
        causal_depth: 0,
        trigger_kind: "webhook".to_owned(),
        origin_session_id: None,
    })?)
    .map_err(|error| error.to_string())
}

/// Treat a webhook body as the worker's typed input. Object-valued trigger
/// configuration provides defaults and request fields override them. This
/// keeps HTTP invocation identical to manual/direct invocation instead of
/// forcing every worker schema to declare an engine-specific `webhook` wrapper.
fn materialize_webhook_input(configured: Value, body: Value) -> Value {
    match (configured, body) {
        (Value::Object(mut defaults), Value::Object(request)) => {
            defaults.extend(request);
            Value::Object(defaults)
        }
        (_, body) => body,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn webhook_body_is_direct_typed_input_with_configured_defaults() {
        let input = materialize_webhook_input(
            json!({"mode":"research","days":30}),
            json!({"topic":"persistent agents","days":7}),
        );

        assert_eq!(
            input,
            json!({"mode":"research","days":7,"topic":"persistent agents"})
        );
        assert!(input.get("webhook").is_none());
    }
}
