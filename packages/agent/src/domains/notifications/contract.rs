//! Capability contracts owned by the notifications domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["notifications.inbox"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("notifications::list", "notifications", EffectClass::PureRead, RiskLevel::Low, Some("notifications.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"limit":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"notifications":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"unreadCount":{"type":"integer"}},"required":["notifications","unreadCount"],"type":"object"}))
            .build()?,
        CapabilityContract::new("notifications::mark_read", "notifications", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("notifications.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"eventId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["eventId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("notifications::mark_all_read", "notifications", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("notifications.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"marked":{"type":"integer"}},"required":["marked"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
