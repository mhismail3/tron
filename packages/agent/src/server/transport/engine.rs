//! Transport-neutral entry point into the canonical engine capability fabric.
//!
//! Protocol-specific transports translate their wire request into
//! [`EngineTransportRequest`] and then call [`dispatch_engine_transport_request`].
//! The envelope contains engine concepts only: target function, trigger,
//! payload, actor, authority, trace, optional session/workspace scope, and
//! explicit idempotency. JSON-RPC request ids stay outside engine semantics as
//! correlation ids.

use serde_json::Value;

use crate::engine::{EngineTriggerRuntime, FunctionId, TriggerDispatchRequest, TriggerId};
use crate::server::capabilities::errors::CapabilityError;
use crate::server::services::context::ServerCapabilityContext;

/// Protocol-neutral invocation envelope for public engine transports.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineTransportRequest {
    /// Protocol-level correlation id, never an idempotency key.
    pub correlation_id: String,
    /// Transport name, for example `json_rpc`.
    pub transport: String,
    /// Public transport method, for example `engine.invoke`.
    pub public_method: String,
    /// Canonical target function id selected by the transport binding.
    pub function_id: FunctionId,
    /// Trigger id responsible for this invocation.
    pub trigger_id: TriggerId,
    /// Payload delivered to the engine function.
    pub payload: Value,
    /// Causal authority and trace metadata for the engine invocation.
    pub causal_context: crate::engine::CausalContext,
}

/// Dispatch one protocol-neutral transport envelope through the trigger runtime.
pub async fn dispatch_engine_transport_request(
    ctx: &ServerCapabilityContext,
    envelope: EngineTransportRequest,
) -> Result<Value, CapabilityError> {
    let actor_id = envelope.causal_context.actor_id.clone();
    let actor_kind = envelope.causal_context.actor_kind;
    let authority_scopes = envelope.causal_context.authority_scopes.clone();
    let trace_id = Some(envelope.causal_context.trace_id.clone());
    let session_id = envelope.causal_context.session_id.clone();
    let workspace_id = envelope.causal_context.workspace_id.clone();
    let idempotency_key = envelope.causal_context.idempotency_key.clone();
    let mut dispatch =
        TriggerDispatchRequest::new(envelope.trigger_id, envelope.payload, actor_id, actor_kind);
    dispatch.authority_scopes = authority_scopes;
    dispatch.trace_id = trace_id;
    dispatch.session_id = session_id;
    dispatch.workspace_id = workspace_id;
    dispatch.idempotency_key = idempotency_key;

    let result = EngineTriggerRuntime::dispatch(&ctx.engine_host, dispatch).await;
    crate::server::capabilities::error_mapping::result_to_capability_value(result)
}
