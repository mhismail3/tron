//! Capability contracts owned by the skills domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

pub(crate) const STREAM_TOPICS: &[&str] = &["skills.catalog"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("skills::list", "skills", EffectClass::PureRead, RiskLevel::Low, Some("skills.read"))
            .domain_module("unknown")
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workingDirectory":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"skills":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["skills"],"type":"object"}))
            .build()?,
        CapabilityContract::new("skills::get", "skills", EffectClass::PureRead, RiskLevel::Low, Some("skills.read"))
            .domain_module("unknown")
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workingDirectory":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"found":{"type":"boolean"},"skill":{"additionalProperties":true,"type":"object"}},"required":["skill","found"],"type":"object"}))
            .build()?,
        CapabilityContract::new("skills::refresh", "skills", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("skills.write"))
            .domain_module("unknown")
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workingDirectory":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"skillCount":{"type":"integer"},"success":{"type":"boolean"}},"required":["success","skillCount"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("skills::activate", "skills", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("skills.write"))
            .domain_module("unknown")
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"skillName":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","skillName"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"alreadyActive":{"type":"boolean"},"skill":{"additionalProperties":true,"type":"object"},"success":{"type":"boolean"}},"required":["success","skill"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("skills::deactivate", "skills", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("skills.write"))
            .domain_module("unknown")
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"skillName":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","skillName"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"deactivatedSkill":{"type":"string"},"success":{"type":"boolean"},"wasActive":{"type":"boolean"}},"required":["success","wasActive","deactivatedSkill"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("skills::active", "skills", EffectClass::PureRead, RiskLevel::Low, Some("skills.read"))
            .domain_module("unknown")
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"skills":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["skills"],"type":"object"}))
            .build()?
    ])
}
