//! Transport-neutral entry point into the canonical engine capability fabric.
//!
//! Protocol-specific transports translate their wire request into
//! [`EngineTransportRequest`] and then call [`dispatch_engine_transport_request`].
//! The envelope contains engine concepts only: target function, trigger,
//! payload, actor, authority, trace, optional session/workspace scope, and
//! explicit idempotency. Protocol message ids stay outside engine semantics as
//! correlation ids.
//!
//! Direct public `capability::execute` calls still use server-owned execution
//! policy. The transport derives policy scopes and metadata from the active
//! profile and rejects client-authored capability policy context.

use serde_json::Value;
use std::collections::BTreeMap;

use crate::domains::capability_support::implementations::primitive_surface::{
    CONTRACT_ALLOW_SCOPE_PREFIX, CONTRACT_DENY_SCOPE_PREFIX, IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
    IMPLEMENTATION_DENY_SCOPE_PREFIX, PLUGIN_ALLOW_SCOPE_PREFIX, PLUGIN_DENY_SCOPE_PREFIX,
    capability_execution_policy_scopes, capability_execution_runtime_metadata,
};
use crate::domains::catalog;
use crate::domains::catalog::TransportIdempotencyMode;
use crate::engine::{
    ActorKind, CausalContext, EngineTriggerRuntime, FunctionId, InvocationId, TraceId,
    TriggerDispatchRequest, TriggerId,
};
use crate::shared::profile::{AgentExecutionSpec, CapabilityExecutionPolicySpec};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;
use crate::transport::contracts;

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
    /// Engine-internal runtime metadata supplied by trusted clients.
    pub runtime_metadata: BTreeMap<String, String>,
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
    reject_client_owned_execute_policy_context(&input)?;
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
        causal_context = causal_context
            .with_scope("engine.promote.workspace")
            .with_scope("engine.promote.system");
    }
    if spec.operation_key.as_str() == "invoke" {
        for scope in target_authority_scopes_for_engine_invoke(&input.params_payload) {
            causal_context = causal_context.with_scope(scope);
        }
    }
    for scope in &input.context.authority_scopes {
        if !scope.trim().is_empty() {
            causal_context = causal_context.with_scope(scope.clone());
        }
    }
    for (key, value) in &input.context.runtime_metadata {
        if !key.trim().is_empty() {
            causal_context = causal_context.with_runtime_metadata(key.clone(), value.clone());
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
    let mut causal_context = envelope.causal_context;
    if is_public_capability_execute_invoke(&envelope.payload) {
        attach_active_profile_execute_context(ctx, &mut causal_context)?;
    }
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
        && extract_string(payload, "functionId").as_deref() == Some("approval::resolve")
    {
        return (ActorKind::User, "engine-user");
    }
    if method == "invoke"
        && extract_string(payload, "functionId").as_deref() == Some("agent::submit_answers")
    {
        return (ActorKind::User, "engine-user");
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

fn reject_client_owned_execute_policy_context(
    input: &EngineTransportBuildRequest,
) -> Result<(), CapabilityError> {
    if input.public_method != "invoke"
        || !is_public_capability_execute_invoke(&input.params_payload)
    {
        return Ok(());
    }
    if let Some(scope) = input
        .context
        .authority_scopes
        .iter()
        .find(|scope| is_capability_execution_policy_scope(scope))
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "capability::execute transport context cannot supply capability execution policy scope '{scope}'; the server derives execute policy from the active profile"
            ),
        });
    }
    if let Some(key) = input
        .context
        .runtime_metadata
        .keys()
        .find(|key| key.starts_with("capability."))
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "capability::execute transport context cannot supply capability runtime metadata '{key}'; the server derives execute policy from the active profile"
            ),
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

fn attach_active_profile_execute_context(
    ctx: &ServerRuntimeContext,
    causal_context: &mut CausalContext,
) -> Result<(), CapabilityError> {
    let current = ctx.profile_runtime.current();
    let (policy_id, policy) = main_capability_execution_policy(current.execution_spec())?;
    for scope in capability_execution_policy_scopes(policy) {
        push_scope_once(causal_context, scope);
    }
    for (key, value) in capability_execution_runtime_metadata(
        current.execution_spec(),
        &policy_id,
        policy,
        Some(current.spec_hash()),
    )
    .map_err(|message| CapabilityError::Internal { message })?
    {
        causal_context.runtime_metadata.entry(key).or_insert(value);
    }
    Ok(())
}

fn main_capability_execution_policy(
    spec: &AgentExecutionSpec,
) -> Result<(String, &CapabilityExecutionPolicySpec), CapabilityError> {
    let entrypoint = spec
        .entrypoints
        .get("main")
        .ok_or_else(|| CapabilityError::Internal {
            message: "active profile is missing entrypoints.main".to_owned(),
        })?;
    let policy_id = spec
        .context_policy(&entrypoint.context_policy)
        .and_then(|policy| policy.capability_execution_policy.clone())
        .unwrap_or_else(|| entrypoint.capability_execution_policy.clone());
    let policy = spec
        .capability_execution_policy(&policy_id)
        .ok_or_else(|| CapabilityError::Internal {
            message: format!("active profile is missing capability execution policy '{policy_id}'"),
        })?;
    Ok((policy_id, policy))
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

fn is_public_capability_execute_invoke(payload: &Value) -> bool {
    extract_string(payload, "functionId").as_deref() == Some("capability::execute")
}

fn is_capability_execution_policy_scope(scope: &str) -> bool {
    [
        CONTRACT_ALLOW_SCOPE_PREFIX,
        CONTRACT_DENY_SCOPE_PREFIX,
        IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
        IMPLEMENTATION_DENY_SCOPE_PREFIX,
        PLUGIN_ALLOW_SCOPE_PREFIX,
        PLUGIN_DENY_SCOPE_PREFIX,
    ]
    .iter()
    .any(|prefix| scope.starts_with(prefix))
}

fn strip_transport_only_fields(method: &str, mut payload: Value) -> Value {
    if matches!(method, "discover" | "inspect" | "watch" | "invoke") {
        if let Some(object) = payload.as_object_mut() {
            let _ = object.remove("sessionId");
            let _ = object.remove("workspaceId");
            let _ = object.remove("traceId");
            let _ = object.remove("parentInvocationId");
            let _ = object.remove("authorityScopes");
        }
    }
    if method == "promote" {
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

#[cfg(test)]
mod tests {
    use serde_json::json;
    use std::collections::BTreeMap;

    use super::*;

    fn build_invoke(function_id: &str) -> EngineTransportRequest {
        build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id: "request-1".to_owned(),
            public_method: "invoke".to_owned(),
            params_payload: json!({
                "functionId": function_id,
                "payload": {"approvalId": "approval-1", "decision": "approve"},
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
    fn approval_resolve_invoke_is_a_user_authorized_engine_action() {
        let envelope = build_invoke("approval::resolve");

        assert_eq!(envelope.causal_context.actor_kind, ActorKind::User);
        assert_eq!(envelope.causal_context.actor_id.as_str(), "engine-user");
        assert!(
            envelope
                .causal_context
                .authority_scopes
                .iter()
                .any(|scope| scope == "approval.resolve")
        );
    }

    #[test]
    fn submit_answers_invoke_is_a_user_authorized_engine_action() {
        let envelope = build_invoke("agent::submit_answers");

        assert_eq!(envelope.causal_context.actor_kind, ActorKind::User);
        assert_eq!(envelope.causal_context.actor_id.as_str(), "engine-user");
        assert!(
            envelope
                .causal_context
                .authority_scopes
                .iter()
                .any(|scope| scope == "agent.write")
        );
    }

    #[test]
    fn ordinary_client_invoke_remains_client_actor() {
        let envelope = build_invoke("system::ping");

        assert_eq!(envelope.causal_context.actor_kind, ActorKind::Client);
        assert_eq!(envelope.causal_context.actor_id.as_str(), "engine-client");
    }

    #[test]
    fn capability_execute_invoke_rejects_client_owned_policy_scopes() {
        let error = build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id: "request-1".to_owned(),
            public_method: "invoke".to_owned(),
            params_payload: json!({
                "functionId": "capability::execute",
                "payload": {"target": {"capabilityId": "process::run"}}
            }),
            context: EngineTransportContext {
                authority_scopes: vec!["contract.allow:*".to_owned()],
                ..EngineTransportContext::default()
            },
        })
        .expect_err("client-authored execute policy scope must be rejected");

        assert!(error.to_string().contains("server derives execute policy"));
    }

    #[test]
    fn capability_execute_invoke_rejects_client_owned_policy_metadata() {
        let mut runtime_metadata = BTreeMap::new();
        let _ = runtime_metadata.insert(
            "capability.searchPolicy".to_owned(),
            r#"{"lexical":false}"#.to_owned(),
        );
        let error = build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id: "request-1".to_owned(),
            public_method: "invoke".to_owned(),
            params_payload: json!({
                "functionId": "capability::execute",
                "payload": {"target": {"capabilityId": "process::run"}}
            }),
            context: EngineTransportContext {
                runtime_metadata,
                ..EngineTransportContext::default()
            },
        })
        .expect_err("client-authored execute runtime metadata must be rejected");

        assert!(error.to_string().contains("server derives execute policy"));
    }

    #[test]
    fn active_profile_execute_context_supplies_policy_scopes_and_metadata() {
        let dir = tempfile::tempdir().expect("tempdir");
        let home = dir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).expect("seed tron home");
        let runtime = crate::domains::agent::runner::profile_runtime::ProfileRuntime::load(&home)
            .expect("profile runtime");
        let current = runtime.current();
        let (policy_id, policy) =
            main_capability_execution_policy(current.execution_spec()).expect("main policy");
        let scopes = capability_execution_policy_scopes(policy);
        let metadata: BTreeMap<_, _> = capability_execution_runtime_metadata(
            current.execution_spec(),
            &policy_id,
            policy,
            Some(current.spec_hash()),
        )
        .expect("runtime metadata")
        .into_iter()
        .collect();

        assert_eq!(policy_id, "default");
        assert!(scopes.iter().any(|scope| scope == "contract.allow:*"));
        assert!(scopes.iter().any(|scope| scope == "implementation.allow:*"));
        assert!(scopes.iter().any(|scope| scope == "plugin.allow:*"));
        assert_eq!(
            metadata.get("capability.executionPolicyId"),
            Some(&"default".to_owned())
        );
        assert_eq!(
            metadata.get("capability.searchPolicyId"),
            Some(&"hybridLocal".to_owned())
        );
        assert!(metadata.contains_key("capability.searchPolicy"));
        assert_eq!(
            metadata.get("capability.profileSpecHash"),
            Some(&current.spec_hash().to_owned())
        );
    }

    #[test]
    fn transport_context_runtime_metadata_reaches_causal_context() {
        let mut runtime_metadata = BTreeMap::new();
        let _ = runtime_metadata.insert(
            "capability.searchPolicyId".to_owned(),
            "operatorConsoleHybridLexical".to_owned(),
        );
        let envelope = build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id: "request-1".to_owned(),
            public_method: "invoke".to_owned(),
            params_payload: json!({
                "functionId": "capability::search",
                "payload": {"query": "read file"}
            }),
            context: EngineTransportContext {
                runtime_metadata,
                ..EngineTransportContext::default()
            },
        })
        .expect("transport envelope builds")
        .expect("invoke maps to engine transport");

        assert_eq!(
            envelope
                .causal_context
                .runtime_metadata("capability.searchPolicyId"),
            Some("operatorConsoleHybridLexical")
        );
    }
}
