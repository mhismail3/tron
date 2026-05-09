//! Capability contracts owned by the blob domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};

pub(crate) const STREAM_TOPICS: &[&str] = &[];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("blob::get", "blob", EffectClass::PureRead, RiskLevel::Low, Some("blob.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"blobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["blobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"blobId":{"type":"string"},"data":{"type":"string"},"mimeType":{"type":"string"},"sizeBytes":{"type":"integer"}},"required":["blobId","mimeType","data","sizeBytes"],"type":"object"}))
            .build()?
    ])
}
