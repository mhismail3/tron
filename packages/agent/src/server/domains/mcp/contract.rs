//! Capability contracts owned by the mcp domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

pub(crate) const STREAM_TOPICS: &[&str] = &["mcp.health", "mcp.catalog"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("mcp::status", "mcp", EffectClass::PureRead, RiskLevel::Low, Some("mcp.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"items":{"additionalProperties":true,"type":"object"},"type":"array"}))
            .build()?,
        CapabilityContract::new("mcp::add_server", "mcp", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("mcp.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"args":{"items":{"type":"string"},"type":"array"},"command":{"type":"string"},"enabled":{"type":"boolean"},"env":{"additionalProperties":true,"type":"object"},"name":{"type":"string"},"sessionId":{"type":"string"},"url":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"},"toolCount":{"type":"integer"}},"required":["success","toolCount"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("mcp::remove_server", "mcp", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("mcp.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("mcp::enable_server", "mcp", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("mcp.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("mcp::disable_server", "mcp", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("mcp.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("mcp::restart_server", "mcp", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("mcp.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"},"toolCount":{"type":"integer"}},"required":["success","toolCount"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("mcp::reload", "mcp", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("mcp.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"serverCount":{"type":"integer"},"success":{"type":"boolean"}},"required":["success","serverCount"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("mcp::list_tools", "mcp", EffectClass::PureRead, RiskLevel::Low, Some("mcp.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"server":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"items":{"additionalProperties":true,"type":"object"},"type":"array"}))
            .build()?
    ])
}
