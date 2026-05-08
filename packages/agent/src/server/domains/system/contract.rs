//! Capability contracts owned by the system domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

pub(crate) const STREAM_TOPICS: &[&str] = &["system.status"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("system::ping", "system", EffectClass::PureRead, RiskLevel::Low, Some("system.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"clientVersion":{"type":"string"},"protocolVersion":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["protocolVersion"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"compatible":{"type":"boolean"},"minClientProtocolVersion":{"type":"integer"},"pong":{"type":"boolean"},"serverProtocolVersion":{"type":"integer"},"serverVersion":{"type":"string"},"timestamp":{"type":"string"}},"required":["pong","timestamp","serverVersion","serverProtocolVersion","minClientProtocolVersion","compatible"],"type":"object"}))
            .build()?,
        CapabilityContract::new("system::get_info", "system", EffectClass::PureRead, RiskLevel::Low, Some("system.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"__capabilityContext":{"additionalProperties":false,"properties":{"onboardedMarkerPath":{"type":"string"}},"type":"object"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"activeSessions":{"type":"integer"},"arch":{"type":"string"},"paired":{"type":"boolean"},"platform":{"type":"string"},"port":{"type":"integer"},"runtime":{"type":"string"},"tailscaleIp":{"type":["string","null"]},"uptime":{"type":"integer"},"version":{"type":"string"}},"required":["version","uptime","activeSessions","platform","arch","runtime","port","tailscaleIp","paired"],"type":"object"}))
            .build()?,
        CapabilityContract::new("system::get_diagnostics", "system", EffectClass::PureRead, RiskLevel::Low, Some("system.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("system::shutdown", "system", EffectClass::IrreversibleSideEffect, RiskLevel::Critical, Some("system.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"acknowledged":{"type":"boolean"}},"required":["acknowledged"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("system", "system:shutdown", 60000))
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "shutdown is irreversible for the current process; restart Tron manually"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"system:shutdown","kind":"system","reason":"serializes the graceful server shutdown command","required":true,"ttlMs":60000},"rollbackOrCompensation":"shutdown is irreversible for the current process; restart Tron manually","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("system::check_for_updates", "system", EffectClass::PureRead, RiskLevel::Low, Some("system.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("system::get_update_status", "system", EffectClass::PureRead, RiskLevel::Low, Some("system.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?
    ])
}
