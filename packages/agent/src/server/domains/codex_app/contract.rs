//! Capability contracts owned by the codex_app domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("codex_app::status", "codex_app", EffectClass::PureRead, RiskLevel::Low, Some("codex_app.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?
    ])
}
