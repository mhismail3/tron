//! Capability contracts owned by the filesystem domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

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
            .build()?,
        CapabilityContract::new("filesystem::write_file", "filesystem", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("filesystem.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"content":{"type":"string"},"path":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path","content"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"bytesWritten":{"type":"integer"},"created":{"type":"boolean"},"path":{"type":"string"}},"required":["path","bytesWritten","created"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "writes are audited with byte counts; callers should inspect/diff before replacing important content"))
            .build()?,
        CapabilityContract::new("filesystem::edit_file", "filesystem", EffectClass::ReversibleSideEffect, RiskLevel::Medium, Some("filesystem.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"newString":{"type":"string"},"oldString":{"type":"string"},"path":{"type":"string"},"replaceAll":{"type":"boolean"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path","oldString","newString"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"diff":{"type":"string"},"path":{"type":"string"},"replacements":{"type":"integer"}},"required":["path","replacements","diff"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "the returned diff contains enough context for manual reversal when the edited file still exists"))
            .build()?,
        CapabilityContract::new("filesystem::find", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"exclude":{"items":{"type":"string"},"type":"array"},"maxDepth":{"type":"integer"},"maxResults":{"type":"integer"},"path":{"type":"string"},"pattern":{"type":"string"},"sessionId":{"type":"string"},"type":{"enum":["file","directory","all"],"type":"string"},"workspaceId":{"type":"string"}},"required":["pattern"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"matches":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"path":{"type":"string"},"truncated":{"type":"boolean"}},"required":["path","matches","truncated"],"type":"object"}))
            .build()?,
        CapabilityContract::new("filesystem::glob", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"exclude":{"items":{"type":"string"},"type":"array"},"maxDepth":{"type":"integer"},"maxResults":{"type":"integer"},"path":{"type":"string"},"pattern":{"type":"string"},"sessionId":{"type":"string"},"type":{"enum":["file","directory","all"],"type":"string"},"workspaceId":{"type":"string"}},"required":["pattern"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"matches":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"path":{"type":"string"},"truncated":{"type":"boolean"}},"required":["path","matches","truncated"],"type":"object"}))
            .build()?,
        CapabilityContract::new("filesystem::search_text", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"context":{"type":"integer"},"filePattern":{"type":"string"},"maxResults":{"type":"integer"},"path":{"type":"string"},"pattern":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["pattern"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"matches":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"path":{"type":"string"},"truncated":{"type":"boolean"}},"required":["path","matches","truncated"],"type":"object"}))
            .build()?,
        CapabilityContract::new("filesystem::diff", "filesystem", EffectClass::PureRead, RiskLevel::Low, Some("filesystem.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"newContent":{"type":"string"},"path":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path","newContent"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"diff":{"type":"string"},"path":{"type":"string"}},"required":["path","diff"],"type":"object"}))
            .build()?,
        CapabilityContract::new("filesystem::apply_patch", "filesystem", EffectClass::ReversibleSideEffect, RiskLevel::Medium, Some("filesystem.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"newString":{"type":"string"},"oldString":{"type":"string"},"path":{"type":"string"},"replaceAll":{"type":"boolean"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["path","oldString","newString"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"diff":{"type":"string"},"path":{"type":"string"},"replacements":{"type":"integer"}},"required":["path","replacements","diff"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "patch edits return a diff for manual reversal when the edited file still exists"))
            .build()?
    ])
}
