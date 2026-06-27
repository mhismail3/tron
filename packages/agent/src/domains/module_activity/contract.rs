//! Module activity domain contract constants.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};

pub(crate) const WORKER: &str = "module_activity";
pub(crate) const READ_SCOPE: &str = "module_activity.read";
pub(crate) const SCHEMA_VERSION: &str = "tron.module_activity.overview.v1";

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "module_activity::overview",
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("Read-only bounded module activity projection for runtime cockpit clients")
        .tags(vec!["module", "activity", "cockpit", "read_only"])
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "additionalProperties": true,
            "required": ["schemaVersion", "operation", "summary", "timeline", "blocked", "waiting", "resources", "projection"],
            "properties": {
                "schemaVersion": {"type": "string"},
                "operation": {"const": "module_activity_overview"},
                "summary": {"type": "object"},
                "timeline": {"type": "array"},
                "blocked": {"type": "array"},
                "waiting": {"type": "array"},
                "resources": {"type": "array"},
                "projection": {"type": "object"}
            }
        }))
        .build()?,
    ])
}
