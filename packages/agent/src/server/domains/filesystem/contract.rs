//! Capability contracts owned by the filesystem domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

pub(crate) const STREAM_TOPICS: &[&str] = &["filesystem.changes"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("filesystem::list_dir", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"path":{"type":"string"},"sessionId":{"type":"string"},"showHidden":{"type":"boolean"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"entries":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"parent":{"type":["string","null"]},"path":{"type":"string"}},"required":["path","parent","entries"],"type":"object"}))
            .build()?,
        CapabilityContract::new("filesystem::get_home", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"homePath":{"type":"string"},"suggestedPaths":{"items":{"additionalProperties":false,"properties":{"exists":{"type":"boolean"},"name":{"type":"string"},"path":{"type":"string"}},"required":["name","path","exists"],"type":"object"},"type":"array"}},"required":["homePath","suggestedPaths"],"type":"object"}))
            .build()?,
        CapabilityContract::new("filesystem::create_dir", "filesystem", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("filesystem.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"path":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"created":{"type":"boolean"},"path":{"type":"string"}},"required":["created","path"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("filesystem::read_file", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"path":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"content":{"type":"string"},"path":{"type":"string"}},"required":["content","path"],"type":"object"}))
            .build()?
    ])
}
