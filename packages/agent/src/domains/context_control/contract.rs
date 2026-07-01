//! Context-control domain contracts.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::catalog::TransportIdempotencyMode;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const WORKER: &str = "context_control";
pub(crate) const CONTEXT_CONTROL_TOPIC: &str = "context_control.lifecycle";
pub(crate) const READ_SCOPE: &str = "context_control.read";
pub(crate) const WRITE_SCOPE: &str = "context_control.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const SNAPSHOT_SCHEMA_VERSION: &str =
    crate::engine::CONTEXT_CONTROL_SNAPSHOT_PAYLOAD_SCHEMA_VERSION;
pub(crate) const ACTION_SCHEMA_VERSION: &str =
    crate::engine::CONTEXT_CONTROL_ACTION_PAYLOAD_SCHEMA_VERSION;
pub(crate) const EPOCH_SCHEMA_VERSION: &str =
    crate::engine::CONTEXT_CONTROL_EPOCH_PAYLOAD_SCHEMA_VERSION;

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        contract(
            "context_control::snapshot",
            EffectClass::AppendOnlyEvent,
            RiskLevel::Low,
            Some(WRITE_SCOPE),
        )
        .description("Record and return a provider-safe snapshot of one session context")
        .tags(vec!["context", "snapshot", "tokens", "audit"])
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(session_request_schema())
        .response_schema(common_response_schema("context_control_snapshot"))
        .build()?,
        contract(
            "context_control::compact",
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .description("Compact the current session context into a durable safe summary boundary")
        .tags(vec!["context", "compact", "epoch", "audit"])
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(action_request_schema())
        .response_schema(common_response_schema("context_control_compact"))
        .stream_topics(vec![CONTEXT_CONTROL_TOPIC])
        .build()?,
        contract(
            "context_control::clear",
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            Some(WRITE_SCOPE),
        )
        .description("Clear provider context into a new durable session epoch")
        .tags(vec!["context", "clear", "epoch", "audit"])
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "context clear creates an epoch boundary but does not delete history, resources, or traces; recovery uses durable audit refs and explicit user/agent follow-up context actions",
        ))
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(action_request_schema())
        .response_schema(common_response_schema("context_control_clear"))
        .stream_topics(vec![CONTEXT_CONTROL_TOPIC])
        .build()?,
        contract(
            "context_control::action_list",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("List recent provider-safe context-control actions for a session")
        .tags(vec!["context", "actions", "audit"])
        .request_schema(list_request_schema())
        .response_schema(common_response_schema("context_control_action_list"))
        .build()?,
        contract(
            "context_control::action_inspect",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("Inspect one provider-safe context-control action record")
        .tags(vec!["context", "action", "audit"])
        .request_schema(inspect_request_schema())
        .response_schema(common_response_schema("context_control_action_inspect"))
        .build()?,
        contract(
            "context_control::ui_snapshot",
            EffectClass::AppendOnlyEvent,
            RiskLevel::Low,
            Some(WRITE_SCOPE),
        )
        .description(
            "First-party Session Briefing UI wrapper for recording a provider-safe context snapshot",
        )
        .tags(vec!["context", "snapshot", "ios", "session-briefing"])
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(session_request_schema())
        .response_schema(common_response_schema("context_control_snapshot"))
        .build()?,
        contract(
            "context_control::ui_compact",
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .description("First-party Session Briefing UI wrapper for compacting context")
        .tags(vec!["context", "compact", "ios", "session-briefing"])
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(action_request_schema())
        .response_schema(common_response_schema("context_control_compact"))
        .stream_topics(vec![CONTEXT_CONTROL_TOPIC])
        .build()?,
        contract(
            "context_control::ui_clear",
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            Some(WRITE_SCOPE),
        )
        .description("First-party Session Briefing UI wrapper for clearing context into a new epoch")
        .tags(vec!["context", "clear", "ios", "session-briefing"])
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "context clear creates an epoch boundary but does not delete history, resources, or traces; recovery uses durable audit refs and explicit user/agent follow-up context actions",
        ))
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(action_request_schema())
        .response_schema(common_response_schema("context_control_clear"))
        .stream_topics(vec![CONTEXT_CONTROL_TOPIC])
        .build()?,
        contract(
            "context_control::ui_action_list",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("First-party Session Briefing UI wrapper for listing context actions")
        .tags(vec!["context", "actions", "ios", "session-briefing"])
        .request_schema(list_request_schema())
        .response_schema(common_response_schema("context_control_action_list"))
        .build()?,
        contract(
            "context_control::ui_action_inspect",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("First-party Session Briefing UI wrapper for inspecting one context action")
        .tags(vec!["context", "action", "ios", "session-briefing"])
        .request_schema(inspect_request_schema())
        .response_schema(common_response_schema("context_control_action_inspect"))
        .build()?,
    ])
}

fn contract(
    method: &'static str,
    effect: EffectClass,
    risk: RiskLevel,
    scope: Option<&'static str>,
) -> CapabilityContract {
    CapabilityContract::new(method, WORKER, effect, risk, scope)
        .domain_module(WORKER)
        .presentation_hints(json!({
            "themeColor": "teal",
            "surface": "context_control"
        }))
}

fn session_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["sessionId", "idempotencyKey"],
        "properties": {
            "sessionId": {"type": "string", "minLength": 1},
            "reason": {"type": "string", "minLength": 1, "maxLength": 200},
            "idempotencyKey": {"type": "string", "minLength": 1, "maxLength": 256}
        }
    })
}

fn action_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["sessionId", "reason", "idempotencyKey"],
        "properties": {
            "sessionId": {"type": "string", "minLength": 1},
            "reason": {"type": "string", "minLength": 1, "maxLength": 500},
            "idempotencyKey": {"type": "string", "minLength": 1, "maxLength": 256},
            "actorNote": {"type": "string", "maxLength": 500}
        }
    })
}

fn list_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["sessionId"],
        "properties": {
            "sessionId": {"type": "string", "minLength": 1},
            "limit": {"type": "integer", "minimum": 1, "maximum": 50}
        }
    })
}

fn inspect_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["sessionId", "contextControlActionResourceId"],
        "properties": {
            "sessionId": {"type": "string", "minLength": 1},
            "contextControlActionResourceId": {"type": "string", "minLength": 1}
        }
    })
}

fn common_response_schema(operation: &'static str) -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": true,
        "required": ["schemaVersion", "operation", "status", "projection"],
        "properties": {
            "schemaVersion": {"type": "string"},
            "operation": {"const": operation},
            "status": {"type": "string"},
            "projection": {"type": "object"}
        }
    })
}
