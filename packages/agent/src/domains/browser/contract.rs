//! Capability contracts owned by the browser domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};

pub(crate) const STREAM_TOPICS: &[&str] = &[];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("browser::get_status", "browser", EffectClass::PureRead, RiskLevel::Low, Some("browser.read"))
            .description("Return whether browser/computer-use streaming is currently available.")
            .tags(vec!["browser", "computer use", "status", "streaming", "screen"])
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"hasBrowser":{"type":"boolean"},"isStreaming":{"type":"boolean"}},"required":["hasBrowser","isStreaming"],"type":"object"}))
            .examples(vec![json!({"mode":"invoke","contractId":"browser::get_status","payload":{},"reason":"Check browser/computer-use status."})])
            .build()?
    ])
}
