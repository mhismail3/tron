//! Engine client protocol contracts.
//!
//! Public `/engine` message types are worker/client transport bindings over
//! engine-owned functions. They are not model-facing primitives; domain workers do
//! not own these message contracts.

use serde_json::json;

use crate::domains::catalog::{
    CapabilitySpec, SYSTEM_AUTHORITY_GRANT, TransportIdempotencyMode, grant_id, worker_id,
};
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    DeliveryMode, EffectClass, EngineError, IdempotencyContract, IdempotencyKeySource,
    Result as EngineResult, RiskLevel, TriggerDefinition, TriggerId, TriggerTypeDefinition,
    TriggerTypeId, VisibilityScope,
};
use crate::shared::server::context::ServerRuntimeContext;

const PUBLIC_ENGINE_TRANSPORT_METHODS: &[&str] =
    &["discover", "inspect", "watch", "invoke", "promote"];

/// Public `/engine` client protocol methods.
pub fn public_engine_transport_methods() -> impl Iterator<Item = &'static str> {
    PUBLIC_ENGINE_TRANSPORT_METHODS.iter().copied()
}

/// Build and validate the public `/engine` client protocol method set.
pub fn public_engine_transport_specs() -> EngineResult<Vec<CapabilitySpec>> {
    let specs = vec![
        public_spec("discover", "engine::discover", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"effectClass":{"type":"string"},"health":{"type":"string"},"maxRisk":{"type":"string"},"namespacePrefix":{"type":"string"},"text":{"type":"string"},"visibility":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"catalogRevision":{"type":"integer"},"functions":{"items":{"type":"object"},"type":"array"}},"required":["functions","catalogRevision"],"type":"object"}))
            .build()?,
        public_spec("inspect", "engine::inspect", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"kind":{"enum":["function","worker","trigger_type","trigger"],"type":"string"}},"required":["kind","id"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"catalogRevision":{"type":"integer"},"definition":{"type":"object"},"kind":{"type":"string"}},"required":["catalogRevision","kind","definition"],"type":"object"}))
            .build()?,
        public_spec("watch", "engine::watch", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"cursor":{"type":"integer"},"topic":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"events":{"items":{"type":"object"},"type":"array"},"nextCursor":{"type":"integer"}},"required":["events","nextCursor"],"type":"object"}))
            .build()?,
        public_spec(
            "invoke",
            "engine::invoke",
            EffectClass::DelegatedInvocation,
            RiskLevel::Low,
        )
        .request_schema(json!({"additionalProperties":true,"properties":{"context":{"additionalProperties":true,"type":"object"},"expectedRevision":{"type":"integer"},"functionId":{"type":"string"},"idempotencyKey":{"type":"string"},"payload":{"type":"object"}},"required":["functionId"],"type":"object"}))
        .response_schema(json!({"additionalProperties":true,"properties":{"invocationId":{"type":"string"},"result":{},"status":{"type":"string"}},"required":["status"],"type":"object"}))
        .build()?,
        public_spec(
            "promote",
            "engine::promote",
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
        )
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(json!({"additionalProperties":false,"properties":{"expectedFunctionRevision":{"type":"integer"},"functionId":{"type":"string"},"idempotencyKey":{"type":"string"},"targetVisibility":{"type":"string"},"workspaceId":{"type":"string"}},"required":["functionId","targetVisibility","expectedFunctionRevision","idempotencyKey"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"functionId":{"type":"string"},"newVisibility":{"type":"string"},"promoted":{"type":"boolean"}},"required":["promoted","functionId","newVisibility"],"type":"object"}))
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .compensation(crate::engine::CompensationContract::new(
            crate::engine::CompensationKind::InverseCommandAvailable,
            "domain-specific tests preserve current rollback, no-op, or replay behavior",
        ))
        .build()?,
    ];
    for spec in &specs {
        if spec.visibility.is_agent_visible()
            && spec.effect_class.is_mutating()
            && spec.idempotency_mode == TransportIdempotencyMode::NotRequired
        {
            return Err(EngineError::PolicyViolation(format!(
                "agent-visible public engine transport method {} lacks idempotency",
                spec.operation_key.as_str()
            )));
        }
        if spec.request_schema.is_none() || spec.response_schema.is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "public engine transport method {} must declare strict request/response schemas",
                spec.operation_key.as_str()
            )));
        }
        if spec.effect_class.is_mutating() && spec.authority_scope.is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "mutating public engine transport method {} must require an authority scope",
                spec.operation_key.as_str()
            )));
        }
    }
    Ok(specs)
}

/// Find a public engine transport contract by message type.
pub(crate) fn public_engine_transport_spec_for_method(
    method: &str,
) -> EngineResult<Option<CapabilitySpec>> {
    public_engine_transport_specs().map(|specs| {
        specs
            .into_iter()
            .find(|candidate| candidate.operation_key.as_str() == method)
    })
}

/// Engine client protocol trigger type.
pub(crate) fn engine_ws_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("engine_ws")?,
        worker_id("engine")?,
        "Engine WebSocket transport dispatch into a canonical function",
    );
    definition.allowed_delivery_modes = vec![DeliveryMode::Sync];
    definition.visibility = VisibilityScope::Internal;
    definition.config_schema = Some(json!({
        "type": "object",
        "required": ["messageType"],
        "additionalProperties": false,
        "properties": {
            "messageType": {"type": "string"}
        }
    }));
    Ok(definition)
}

/// Manual in-process trigger type used by tests and internal capabilities.
pub(crate) fn manual_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("manual")?,
        worker_id("engine")?,
        "Manual in-process dispatch for tests and future agent capabilities",
    );
    definition.allowed_delivery_modes = vec![DeliveryMode::Sync];
    definition.visibility = VisibilityScope::Internal;
    Ok(definition)
}

/// Build one engine client protocol trigger for a public message contract.
pub(crate) fn engine_ws_trigger_for_spec(
    spec: &CapabilitySpec,
) -> EngineResult<Option<TriggerDefinition>> {
    let mut trigger = TriggerDefinition::new(
        engine_ws_trigger_id_for_method(spec.operation_key.as_str())?,
        worker_id("engine")?,
        TriggerTypeId::new("engine_ws")?,
        spec.function_id.clone(),
        grant_id(SYSTEM_AUTHORITY_GRANT)?,
    )
    .with_delivery_mode(DeliveryMode::Sync);
    trigger.config = json!({ "messageType": spec.operation_key.as_str() });
    trigger.idempotency_key_strategy = if spec.effect_class.is_mutating() {
        Some(IdempotencyKeySource::TriggerDerived)
    } else {
        None
    };
    trigger.visibility = VisibilityScope::Internal;
    Ok(Some(trigger))
}

/// Trigger id for one public engine client protocol message.
pub(crate) fn engine_ws_trigger_id_for_method(method: &str) -> EngineResult<TriggerId> {
    TriggerId::new(format!("engine_ws:{method}"))
}

/// Register engine client protocol trigger types and message triggers.
pub(crate) fn register_engine_transport_triggers_for_context(
    ctx: &ServerRuntimeContext,
) -> EngineResult<()> {
    let handle = &ctx.engine_host;
    handle.register_trigger_type_for_setup(engine_ws_trigger_type()?, false)?;
    handle.register_trigger_type_for_setup(manual_trigger_type()?, false)?;
    for spec in &public_engine_transport_specs()? {
        if let Some(trigger) = engine_ws_trigger_for_spec(spec)? {
            handle.register_trigger_for_setup(trigger, false)?;
        }
    }
    Ok(())
}

fn public_spec(
    method: &'static str,
    function_id: &'static str,
    effect: EffectClass,
    risk: RiskLevel,
) -> CapabilityContract {
    CapabilityContract::new(method, "engine", effect, risk, Some(authority_for(effect)))
        .function_id(function_id)
        .domain_worker("engine")
        .domain_module("transport::engine_ws")
}

fn authority_for(effect: EffectClass) -> &'static str {
    if effect.is_mutating() {
        "engine.promote.workspace"
    } else {
        "engine.read"
    }
}
