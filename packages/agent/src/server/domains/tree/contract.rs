//! Capability contracts owned by the tree domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

pub(crate) const STREAM_TOPICS: &[&str] = &[];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("tree::get_visualization", "tree", EffectClass::PureRead, RiskLevel::Low, Some("tree.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("tree::get_branches", "tree", EffectClass::PureRead, RiskLevel::Low, Some("tree.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("tree::get_subtree", "tree", EffectClass::PureRead, RiskLevel::Low, Some("tree.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"eventId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["eventId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("tree::get_ancestors", "tree", EffectClass::PureRead, RiskLevel::Low, Some("tree.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"eventId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["eventId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("tree::compare_branches", "tree", EffectClass::PureRead, RiskLevel::Low, Some("tree.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"branchA":{"type":"string"},"branchB":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["branchA","branchB"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?
    ])
}
