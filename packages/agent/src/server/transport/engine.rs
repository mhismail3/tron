//! Transport-neutral entry point into the canonical engine capability fabric.
//!
//! Protocol-specific transports translate their wire request into
//! [`EngineTransportRequest`] and then call [`dispatch_engine_transport_request`].
//! The envelope contains engine concepts only: target function, trigger,
//! payload, actor, authority, trace, optional session/workspace scope, and
//! explicit idempotency. JSON-RPC request ids stay outside engine semantics as
//! correlation ids.

use serde_json::{Value, json};

use crate::engine::{
    ActorKind, CausalContext, EngineTriggerRuntime, FunctionId, InvocationId, TraceId,
    TriggerDispatchRequest, TriggerId,
};
use crate::server::capabilities::catalog::{self, TransportIdempotencyMode};
use crate::server::capabilities::error_mapping::engine_error_to_capability_error;
use crate::server::capabilities::errors::CapabilityError;
use crate::server::services::context::ServerCapabilityContext;

/// Public transport that delivered an engine request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineTransportKind {
    /// Five-method JSON-RPC transport.
    JsonRpc,
    /// `/engine` WebSocket protocol.
    EngineWs,
}

impl EngineTransportKind {
    /// Stable transport label stored in causal metadata.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::JsonRpc => "json_rpc",
            Self::EngineWs => "engine_ws",
        }
    }

    fn trigger_id_for_method(self, method: &str) -> Result<TriggerId, CapabilityError> {
        match self {
            Self::JsonRpc => catalog::json_rpc_trigger_id_for_method(method),
            Self::EngineWs => catalog::engine_ws_trigger_id_for_method(method),
        }
        .map_err(engine_error_to_capability_error)
    }
}

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
    /// Additional authority scopes explicitly granted by the transport.
    pub authority_scopes: Vec<String>,
}

/// Input used to build a protocol-neutral engine transport envelope.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineTransportBuildRequest {
    /// Protocol-level correlation id.
    pub correlation_id: String,
    /// Transport kind.
    pub transport: EngineTransportKind,
    /// Public engine method such as `engine.invoke`.
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

/// Build one protocol-neutral envelope for a public engine transport method.
pub fn build_engine_transport_request(
    input: EngineTransportBuildRequest,
) -> Result<Option<EngineTransportRequest>, CapabilityError> {
    let spec = catalog::public_engine_transport_spec_for_method(&input.public_method)
        .map_err(engine_error_to_capability_error)?;
    let Some(spec) = spec else {
        return Ok(None);
    };
    reject_noncanonical_target(spec.method, &input.params_payload)?;
    let domain_authority_scope = spec
        .authority_scope
        .ok_or_else(|| CapabilityError::Internal {
            message: format!(
                "engine transport method {} is missing an authority scope",
                spec.method
            ),
        })?;
    let mut causal_context = transport_causal_context_for_method(
        spec.method,
        domain_authority_scope,
        input.transport,
        &input.context,
    )?;
    if spec.method == "engine.promote" {
        causal_context = causal_context
            .with_scope("engine.promote.workspace")
            .with_scope("engine.promote.system");
    }
    if spec.method == "engine.invoke" {
        for scope in target_authority_scopes_for_engine_invoke(&input.params_payload) {
            causal_context = causal_context.with_scope(scope);
        }
    }
    for scope in &input.context.authority_scopes {
        if !scope.trim().is_empty() {
            causal_context = causal_context.with_scope(scope.clone());
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
                                spec.method
                            ),
                        }
                    })?;
                if key.trim().is_empty() {
                    return Err(CapabilityError::InvalidParams {
                        message: format!(
                            "{} requires non-empty explicit idempotencyKey",
                            spec.method
                        ),
                    });
                }
                causal_context = causal_context.with_idempotency_key(key);
            }
            TransportIdempotencyMode::NotRequired => {}
        }
    }
    let payload = strip_transport_only_fields(spec.method, input.params_payload);

    Ok(Some(EngineTransportRequest {
        correlation_id: input.correlation_id,
        transport: input.transport.as_str().to_owned(),
        public_method: input.public_method,
        function_id: spec.function_id,
        trigger_id: input.transport.trigger_id_for_method(spec.method)?,
        payload,
        causal_context,
    }))
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

fn transport_causal_context_for_method(
    method: &str,
    scope: &str,
    transport: EngineTransportKind,
    context: &EngineTransportContext,
) -> Result<CausalContext, CapabilityError> {
    let actor_kind = if method == "engine.promote" {
        ActorKind::User
    } else {
        ActorKind::Client
    };
    let actor_id = match (transport, method == "engine.promote") {
        (EngineTransportKind::JsonRpc, true) => "engine-user",
        (EngineTransportKind::JsonRpc, false) => "engine-client",
        (EngineTransportKind::EngineWs, true) => "engine-ws-user",
        (EngineTransportKind::EngineWs, false) => "engine-ws-client",
    };
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

fn reject_noncanonical_target(method: &str, payload: &Value) -> Result<(), CapabilityError> {
    if method != "engine.invoke" {
        return Ok(());
    }
    let Some(function_id) = extract_string(payload, "functionId") else {
        return Ok(());
    };
    let Some((namespace, operation)) = function_id.split_once("::") else {
        return Err(CapabilityError::InvalidParams {
            message: "engine.invoke requires a canonical function id".to_owned(),
        });
    };
    if namespace == "rpc"
        || namespace.is_empty()
        || operation.is_empty()
        || function_id.contains('.')
    {
        return Err(CapabilityError::InvalidParams {
            message: "engine.invoke requires a canonical function id".to_owned(),
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
        "approval" => vec!["approval.read".to_owned(), "approval.resolve".to_owned()],
        other => vec![format!("{other}.read"), format!("{other}.write")],
    }
}

fn strip_transport_only_fields(method: &str, mut payload: Value) -> Value {
    if method.starts_with("engine.") && method != "engine.promote" {
        if let Some(object) = payload.as_object_mut() {
            let _ = object.remove("sessionId");
            let _ = object.remove("workspaceId");
            let _ = object.remove("traceId");
            let _ = object.remove("parentInvocationId");
            let _ = object.remove("authorityScopes");
        }
    }
    if method == "engine.promote" {
        if let Some(object) = payload.as_object_mut() {
            let _ = object.remove("idempotencyKey");
            let _ = object.remove("traceId");
            let _ = object.remove("parentInvocationId");
            let _ = object.remove("authorityScopes");
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

/// Build a params object from optional transport payload.
#[must_use]
pub fn params_or_empty(params: Option<Value>) -> Value {
    params.unwrap_or_else(|| json!({}))
}
