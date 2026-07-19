//! Narrow contracts for real child-agent delegation.

use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel};

pub(crate) const WORKER: &str = "delegation";
pub(crate) const TOPIC: &str = "delegation.lifecycle";
pub(crate) const READ_SCOPE: &str = "delegation.read";
pub(crate) const WRITE_SCOPE: &str = "delegation.write";

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        contract(
            "delegation::start",
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .description(
            "Start one bounded read-only child-agent delegation in a fresh non-fork session",
        )
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(start_schema())
        .response_schema(response_schema())
        .stream_topics(vec![TOPIC])
        .build()?,
        contract(
            "delegation::list",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("List bounded current-session delegation handles")
        .request_schema(json!({"type":"object","additionalProperties":false,"required":["sessionId"],"properties":{"sessionId":{"type":"string","minLength":1}}}))
        .response_schema(json!({"type":"object","additionalProperties":true,"required":["schemaVersion","delegations"]}))
        .build()?,
        contract(
            "delegation::inspect",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("Inspect one delegation using a provider-safe summary projection")
        .request_schema(ref_schema(false))
        .response_schema(response_schema())
        .build()?,
        contract(
            "delegation::cancel",
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .description("Cancel the exact running child run and terminalize its delegation")
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(ref_schema(true))
        .response_schema(response_schema())
        .stream_topics(vec![TOPIC])
        .build()?,
        contract(
            "delegation::accept_result",
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .description("Explicitly accept a ready child result exactly once")
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(ref_schema(true))
        .response_schema(response_schema())
        .stream_topics(vec![TOPIC])
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
        .presentation_hints(json!({"themeColor": "indigo", "surface": "delegation"}))
}

fn start_schema() -> serde_json::Value {
    json!({
        "type": "object", "additionalProperties": false,
        "required": ["sessionId", "objectiveSummary", "successCriteria", "idempotencyKey"],
        "properties": {
            "sessionId": {"type": "string", "minLength": 1},
            "objectiveSummary": {"type": "string", "minLength": 1, "maxLength": 2000},
            "successCriteria": {"type": "array", "minItems": 1, "maxItems": 12, "items": {"type": "string", "minLength": 1, "maxLength": 500}},
            "handoffRefs": {"type": "array", "maxItems": 32, "items": handoff_ref_schema()},
            "idempotencyKey": {"type": "string", "minLength": 1, "maxLength": 256}
        }
    })
}

fn handoff_ref_schema() -> serde_json::Value {
    json!({
        "type": "object", "additionalProperties": false, "required": ["kind", "id"],
        "properties": {
            "kind": {"type": "string", "minLength": 1, "maxLength": 256, "pattern": "^[^*]+$"},
            "id": {"type": "string", "minLength": 1, "maxLength": 256, "pattern": "^[^*]+$"},
            "versionId": {"type": "string", "minLength": 1, "maxLength": 256, "pattern": "^[^*]+$"}
        }
    })
}

fn ref_schema(mutating: bool) -> serde_json::Value {
    let required = if mutating {
        json!([
            "sessionId",
            "delegationResourceId",
            "expectedVersionId",
            "idempotencyKey"
        ])
    } else {
        json!(["sessionId", "delegationResourceId"])
    };
    json!({
        "type": "object", "additionalProperties": false, "required": required,
        "properties": {
            "sessionId": {"type": "string", "minLength": 1},
            "delegationResourceId": {"type": "string", "minLength": 1},
            "expectedVersionId": {"type": "string", "minLength": 1},
            "idempotencyKey": {"type": "string", "minLength": 1, "maxLength": 256},
            "reason": {"type": "string", "minLength": 1, "maxLength": 500}
        }
    })
}

fn response_schema() -> serde_json::Value {
    json!({"type": "object", "additionalProperties": true, "required": ["schemaVersion", "delegation"]})
}
