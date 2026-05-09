//! Capability contracts owned by the events domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["events.session"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("events::get_history", "events", EffectClass::PureRead, RiskLevel::Low, Some("events.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"beforeEventId":{"type":"string"},"limit":{"type":"integer"},"sessionId":{"type":"string"},"types":{"items":{"type":"string"},"type":"array"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"events":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"hasMore":{"type":"boolean"},"oldestEventId":{"type":["string","null"]},"sessionId":{"type":"string"}},"required":["sessionId","events","hasMore","oldestEventId"],"type":"object"}))
            .build()?,
        CapabilityContract::new("events::get_since", "events", EffectClass::PureRead, RiskLevel::Low, Some("events.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"afterEventId":{"type":"string"},"afterSequence":{"type":"integer"},"limit":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"events":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"hasMore":{"type":"boolean"},"nextCursor":{"type":["string","null"]}},"required":["events","hasMore","nextCursor"],"type":"object"}))
            .build()?,
        CapabilityContract::new("events::subscribe", "events", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("events.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"subscribed":{"type":"boolean"}},"required":["subscribed"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("events::unsubscribe", "events", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("events.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"unsubscribed":{"type":"boolean"}},"required":["unsubscribed"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("events::append", "events", EffectClass::AppendOnlyEvent, RiskLevel::Medium, Some("events.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"parentId":{"type":"string"},"payload":{},"sessionId":{"type":"string"},"type":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","type","payload"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"event":{"additionalProperties":true,"type":"object"},"newHeadEventId":{"type":["string","null"]}},"required":["event","newHeadEventId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::EventSourced, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
