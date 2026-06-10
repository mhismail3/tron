//! Transport-neutral entry point into the canonical engine capability fabric.
//!
//! Protocol-specific transports translate their wire request into
//! [`EngineTransportRequest`] and then call [`dispatch_engine_transport_request`].
//! The envelope contains engine concepts only: target function, trigger,
//! payload, actor, authority, trace, optional session/workspace scope, and
//! explicit idempotency. Protocol message ids stay outside engine semantics as
//! correlation ids.
//!
//! Public transports do not accept caller-provided authority scopes or runtime
//! metadata. Authority scopes are derived from registered transport contracts
//! and canonical targets; runtime metadata is reserved for trusted engine and
//! agent-owned execution paths.

pub mod contracts;
pub mod socket;

use serde_json::Value;

use crate::domains::registration::catalog;
use crate::domains::registration::catalog::TransportIdempotencyMode;
use crate::engine::{
    ActorKind, CausalContext, EngineTriggerRuntime, FunctionId, InvocationId, TraceId,
    TriggerDispatchRequest, TriggerId,
};
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
    /// Public engine message type such as `invoke`.
    pub public_method: String,
    /// Method params/payload before transport-only fields are stripped.
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
    /// Public transport message type, for example `invoke`.
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

/// Build one protocol-neutral envelope for a public engine transport method.
pub fn build_engine_transport_request(
    input: EngineTransportBuildRequest,
) -> Result<Option<EngineTransportRequest>, CapabilityError> {
    let spec = contracts::public_engine_transport_spec_for_method(&input.public_method)
        .map_err(engine_error_to_capability_error)?;
    let Some(spec) = spec else {
        return Ok(None);
    };
    reject_noncanonical_target(spec.operation_key.as_str(), &input.params_payload)?;
    let domain_authority_scope = spec
        .authority_scope
        .ok_or_else(|| CapabilityError::Internal {
            message: format!(
                "engine transport method {} is missing an authority scope",
                spec.operation_key.as_str()
            ),
        })?;
    let mut causal_context = transport_causal_context_for_method(
        spec.operation_key.as_str(),
        domain_authority_scope,
        &input.params_payload,
        &input.context,
    )?;
    if spec.operation_key.as_str() == "promote" {
        push_scope_once(&mut causal_context, "engine.promote.workspace".to_owned());
        push_scope_once(&mut causal_context, "engine.promote.system".to_owned());
    }
    if spec.operation_key.as_str() == "invoke" {
        for scope in target_authority_scopes_for_engine_invoke(&input.params_payload) {
            push_scope_once(&mut causal_context, scope);
        }
    }
    if spec.effect_class.is_mutating() {
        match spec.idempotency_mode {
            TransportIdempotencyMode::ExplicitRequired => {
                let key =
                    extract_string(&input.params_payload, "idempotencyKey").ok_or_else(|| {
                        CapabilityError::InvalidParams {
                            message: format!(
                                "{} requires non-empty explicit idempotencyKey",
                                spec.operation_key.as_str()
                            ),
                        }
                    })?;
                if key.trim().is_empty() {
                    return Err(CapabilityError::InvalidParams {
                        message: format!(
                            "{} requires non-empty explicit idempotencyKey",
                            spec.operation_key.as_str()
                        ),
                    });
                }
                causal_context = causal_context.with_idempotency_key(key);
            }
            TransportIdempotencyMode::NotRequired => {}
        }
    }
    let payload = strip_transport_only_fields(spec.operation_key.as_str(), input.params_payload);

    Ok(Some(EngineTransportRequest {
        correlation_id: input.correlation_id,
        transport: "engine_ws".to_owned(),
        public_method: input.public_method,
        function_id: spec.function_id,
        trigger_id: contracts::engine_ws_trigger_id_for_method(spec.operation_key.as_str())
            .map_err(engine_error_to_capability_error)?,
        payload,
        causal_context,
    }))
}

/// Dispatch one protocol-neutral transport envelope through the trigger runtime.
pub async fn dispatch_engine_transport_request(
    ctx: &ServerRuntimeContext,
    envelope: EngineTransportRequest,
) -> Result<Value, CapabilityError> {
    let causal_context = envelope.causal_context;
    let actor_id = causal_context.actor_id.clone();
    let actor_kind = causal_context.actor_kind;
    let authority_scopes = causal_context.authority_scopes.clone();
    let trace_id = Some(causal_context.trace_id.clone());
    let session_id = causal_context.session_id.clone();
    let workspace_id = causal_context.workspace_id.clone();
    let idempotency_key = causal_context.idempotency_key.clone();
    let mut dispatch =
        TriggerDispatchRequest::new(envelope.trigger_id, envelope.payload, actor_id, actor_kind);
    dispatch.authority_scopes = authority_scopes;
    dispatch.runtime_metadata = causal_context.runtime_metadata.clone();
    dispatch.trace_id = trace_id;
    dispatch.session_id = session_id;
    dispatch.workspace_id = workspace_id;
    dispatch.idempotency_key = idempotency_key;

    let result = EngineTriggerRuntime::dispatch(&ctx.engine_host, dispatch).await;
    crate::shared::server::error_mapping::result_to_capability_value(result)
}

fn transport_causal_context_for_method(
    method: &str,
    scope: &str,
    payload: &Value,
    context: &EngineTransportContext,
) -> Result<CausalContext, CapabilityError> {
    let (actor_kind, actor_id) = transport_actor_for_method(method, payload);
    let trace_id = match context.trace_id.as_deref() {
        Some(id) if !id.trim().is_empty() => {
            TraceId::new(id).map_err(engine_error_to_capability_error)?
        }
        _ => TraceId::generate(),
    };
    let mut causal_context = CausalContext::new(
        catalog::actor_id(actor_id).map_err(engine_error_to_capability_error)?,
        actor_kind,
        catalog::grant_id(catalog::SYSTEM_AUTHORITY_GRANT)
            .map_err(engine_error_to_capability_error)?,
        trace_id,
    )
    .with_scope(scope);
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

fn transport_actor_for_method(method: &str, payload: &Value) -> (ActorKind, &'static str) {
    if method == "promote" {
        return (ActorKind::User, "engine-user");
    }
    if method == "invoke"
        && extract_string(payload, "functionId").as_deref() == Some("capability::execute")
    {
        return (ActorKind::Agent, "engine-agent");
    }
    (ActorKind::Client, "engine-client")
}

fn reject_noncanonical_target(method: &str, payload: &Value) -> Result<(), CapabilityError> {
    if method != "invoke" {
        return Ok(());
    }
    let Some(function_id) = extract_string(payload, "functionId") else {
        return Ok(());
    };
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

fn target_authority_scopes_for_engine_invoke(payload: &Value) -> Vec<String> {
    let Some(function_id) = extract_string(payload, "functionId") else {
        return Vec::new();
    };
    let Some((namespace, _operation)) = function_id.split_once("::") else {
        return Vec::new();
    };
    match namespace {
        "engine" => vec![
            "engine.read".to_owned(),
            "engine.promote.workspace".to_owned(),
            "engine.promote.system".to_owned(),
        ],
        other => vec![format!("{other}.read"), format!("{other}.write")],
    }
}

fn push_scope_once(causal_context: &mut CausalContext, scope: String) {
    if !causal_context
        .authority_scopes
        .iter()
        .any(|item| item == &scope)
    {
        causal_context.authority_scopes.push(scope);
    }
}

fn strip_transport_only_fields(method: &str, mut payload: Value) -> Value {
    if matches!(method, "discover" | "inspect" | "watch" | "invoke") {
        if let Some(object) = payload.as_object_mut() {
            let _ = object.remove("sessionId");
            let _ = object.remove("workspaceId");
            let _ = object.remove("traceId");
            let _ = object.remove("parentInvocationId");
        }
    }
    if method == "promote" {
        if let Some(object) = payload.as_object_mut() {
            let _ = object.remove("idempotencyKey");
            let _ = object.remove("traceId");
            let _ = object.remove("parentInvocationId");
        }
    }
    payload
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
            public_method: "invoke".to_owned(),
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
        .expect("invoke maps to engine transport")
    }

    #[test]
    fn ordinary_client_invoke_remains_client_actor() {
        let envelope = build_invoke("system::ping");

        assert_eq!(envelope.causal_context.actor_kind, ActorKind::Client);
        assert_eq!(envelope.causal_context.actor_id.as_str(), "engine-client");
    }

    #[test]
    fn capability_execute_invoke_uses_agent_actor() {
        let envelope = build_invoke("capability::execute");

        assert_eq!(envelope.causal_context.actor_kind, ActorKind::Agent);
        assert_eq!(envelope.causal_context.actor_id.as_str(), "engine-agent");
    }

    #[test]
    fn public_transport_context_cannot_inject_runtime_metadata() {
        let envelope = build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id: "request-1".to_owned(),
            public_method: "invoke".to_owned(),
            params_payload: json!({
                "functionId": "capability::execute",
                "payload": {"operation": "observe", "input": {"text": "read file"}}
            }),
            context: EngineTransportContext::default(),
        })
        .expect("transport envelope builds")
        .expect("invoke maps to engine transport");

        assert!(envelope.causal_context.runtime_metadata.is_empty());
    }
}
