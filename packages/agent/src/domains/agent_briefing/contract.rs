//! Agent briefing domain contract constants.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};

pub(crate) const WORKER: &str = "agent_briefing";
pub(crate) const READ_SCOPE: &str = "agent_briefing.read";
pub(crate) const SCHEMA_VERSION: &str = "tron.agent_briefing.overview.v1";

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "agent_briefing::overview",
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("Read-only bounded agent briefing projection for native dashboard clients")
        .tags(vec!["agent", "briefing", "dashboard", "read_only"])
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 40
                }
            }
        }))
        .response_schema(json!({
            "type": "object",
            "additionalProperties": true,
            "required": ["schemaVersion", "operation", "summary", "sections", "scope", "projection"],
            "properties": {
                "schemaVersion": {"type": "string"},
                "operation": {"const": "agent_briefing_overview"},
                "summary": {"type": "object"},
                "sections": {"type": "array"},
                "scope": {"type": "object"},
                "projection": {"type": "object"}
            }
        }))
        .build()?,
    ])
}
