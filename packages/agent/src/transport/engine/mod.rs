//! Transport-neutral entry point into the canonical engine capability fabric.
//!
//! Protocol-specific transports translate their wire request into
//! [`EngineTransportRequest`] and then call [`dispatch_engine_transport_request`].
//! The envelope contains engine concepts only: target function, payload,
//! actor, trace, optional session/workspace scope, and
//! explicit idempotency. Protocol message ids stay outside engine semantics as
//! correlation ids.
//!
//! Public transports do not accept caller-provided runtime metadata; it remains
//! reserved for trusted engine and agent-owned execution paths.

pub mod socket;

use serde_json::Value;

use crate::domains::registration::catalog;
use crate::engine::{ActorKind, CausalContext, FunctionId, Invocation, InvocationId, TraceId};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;

/// Optional context supplied by a transport message.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EngineTransportContext {
    /// Session scope.
    pub session_id: Option<String>,
    /// Workspace scope.
    pub workspace_id: Option<String>,
    /// Caller-supplied trace id.
    pub trace_id: Option<String>,
    /// Parent invocation id.
    pub parent_invocation_id: Option<String>,
}

/// Input used to build a protocol-neutral engine transport envelope.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineTransportBuildRequest {
    /// Protocol-level correlation id.
    pub correlation_id: String,
    /// Invoke parameters containing the canonical function id and target payload.
    pub params_payload: Value,
    /// Transport context.
    pub context: EngineTransportContext,
}

/// Protocol-neutral invocation envelope for public engine transports.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineTransportRequest {
    /// Protocol-level correlation id, never an idempotency key.
    pub correlation_id: String,
    /// Transport name, currently always `engine_ws`.
    pub transport: String,
    /// Canonical target function id supplied by the authenticated client.
    pub function_id: FunctionId,
    /// Payload delivered to the engine function.
    pub payload: Value,
    /// Causal actor and trace metadata for the engine invocation.
    pub causal_context: crate::engine::CausalContext,
}

/// Build one protocol-neutral envelope for a public engine transport method.
pub fn build_engine_transport_request(
    input: EngineTransportBuildRequest,
) -> Result<EngineTransportRequest, CapabilityError> {
    let function_id = extract_string(&input.params_payload, "functionId").ok_or_else(|| {
        CapabilityError::InvalidParams {
            message: "invoke requires functionId".to_owned(),
        }
    })?;
    validate_canonical_target(&function_id)?;
    let function_id = FunctionId::new(function_id).map_err(engine_error_to_capability_error)?;
    let payload = input
        .params_payload
        .get("payload")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));
    let mut causal_context = transport_causal_context(&input.context)?;
    if let Some(key) = extract_string(&input.params_payload, "idempotencyKey") {
        if key.trim().is_empty() {
            return Err(CapabilityError::InvalidParams {
                message: "idempotencyKey must not be empty".to_owned(),
            });
        }
        causal_context = causal_context.with_idempotency_key(key);
    }

    Ok(EngineTransportRequest {
        correlation_id: input.correlation_id,
        transport: "engine_ws".to_owned(),
        function_id,
        payload,
        causal_context,
    })
}

/// Dispatch one protocol-neutral transport envelope directly to its canonical
/// engine function.
pub async fn dispatch_engine_transport_request(
    ctx: &ServerRuntimeContext,
    envelope: EngineTransportRequest,
) -> Result<Value, CapabilityError> {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            envelope.function_id,
            envelope.payload,
            envelope.causal_context,
        ))
        .await;
    crate::shared::server::error_mapping::result_to_capability_value(result)
}

fn transport_causal_context(
    context: &EngineTransportContext,
) -> Result<CausalContext, CapabilityError> {
    let trace_id = match context.trace_id.as_deref() {
        Some(id) if !id.trim().is_empty() => {
            TraceId::new(id).map_err(engine_error_to_capability_error)?
        }
        _ => TraceId::generate(),
    };
    let mut causal_context = CausalContext::new(
        catalog::actor_id("engine-client").map_err(engine_error_to_capability_error)?,
        ActorKind::Client,
        trace_id,
    );
    if let Some(session_id) = context
        .session_id
        .clone()
        .filter(|value| !value.trim().is_empty())
    {
        causal_context = causal_context.with_session_id(session_id);
    }
    if let Some(workspace_id) = context
        .workspace_id
        .clone()
        .filter(|value| !value.trim().is_empty())
    {
        causal_context = causal_context.with_workspace_id(workspace_id);
    }
    if let Some(parent_id) = context
        .parent_invocation_id
        .clone()
        .filter(|value| !value.trim().is_empty())
    {
        causal_context = causal_context.with_parent_invocation(
            InvocationId::new(parent_id).map_err(engine_error_to_capability_error)?,
        );
    }
    Ok(causal_context)
}

fn validate_canonical_target(function_id: &str) -> Result<(), CapabilityError> {
    let Some((namespace, operation)) = function_id.split_once("::") else {
        return Err(CapabilityError::InvalidParams {
            message: "invoke requires a canonical function id".to_owned(),
        });
    };
    if namespace == "rpc"
        || namespace.is_empty()
        || operation.is_empty()
        || function_id.contains('.')
    {
        return Err(CapabilityError::InvalidParams {
            message: "invoke requires a canonical function id".to_owned(),
        });
    }
    Ok(())
}

fn extract_string(payload: &Value, key: &str) -> Option<String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn build_invoke(function_id: &str) -> EngineTransportRequest {
        build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id: "request-1".to_owned(),
            params_payload: json!({
                "functionId": function_id,
                "payload": {"targetId": "target-1"},
                "idempotencyKey": "idem-1",
                "context": {"sessionId": "session-1"}
            }),
            context: EngineTransportContext {
                session_id: Some("session-1".to_owned()),
                ..EngineTransportContext::default()
            },
        })
        .expect("transport envelope builds")
    }

    #[test]
    fn ordinary_client_invoke_remains_client_actor() {
        let envelope = build_invoke("system::ping");

        assert_eq!(envelope.causal_context.actor_kind, ActorKind::Client);
        assert_eq!(envelope.causal_context.actor_id.as_str(), "engine-client");
    }

    #[test]
    fn worker_kernel_invoke_remains_public_client_actor() {
        let envelope = build_invoke("worker_kernel::invoke");

        assert_eq!(envelope.causal_context.actor_kind, ActorKind::Client);
        assert_eq!(envelope.causal_context.actor_id.as_str(), "engine-client");
    }

    #[test]
    fn public_transport_context_cannot_inject_runtime_metadata() {
        let envelope = build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id: "request-1".to_owned(),
            params_payload: json!({
                "functionId": "worker_kernel::invoke",
                "payload": {"operation": "observe", "input": {"text": "read file"}}
            }),
            context: EngineTransportContext::default(),
        })
        .expect("transport envelope builds");

        assert!(envelope.causal_context.runtime_metadata.is_empty());
    }

    #[test]
    fn public_engine_invoke_keeps_authenticated_client_identity_and_no_runtime_metadata() {
        let envelope = build_invoke("agent::prompt_apply");

        assert_eq!(envelope.causal_context.actor_kind, ActorKind::Client);
        assert_eq!(envelope.causal_context.actor_id.as_str(), "engine-client");
        assert!(envelope.causal_context.runtime_metadata.is_empty());
    }
}
