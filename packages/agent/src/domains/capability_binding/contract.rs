//! Capability binding domain contract constants.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};

pub(crate) const WORKER: &str = "capability_binding";
pub(crate) const CAPABILITY_BINDING_LIFECYCLE_TOPIC: &str = "capability_binding.lifecycle";
pub(crate) const READ_SCOPE: &str = "capability_binding.read";
pub(crate) const WRITE_SCOPE: &str = "capability_binding.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const CAPABILITY_BINDING_REQUEST_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_BINDING_REQUEST_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_BINDING_DECISION_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_BINDING_DECISION_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_BINDING_POLICY_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_BINDING_POLICY_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_SHADOW_TRIAL_REQUEST_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_SHADOW_TRIAL_REQUEST_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_SHADOW_TRIAL_DECISION_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_SHADOW_TRIAL_DECISION_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_SHADOW_TRIAL_RUN_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_SHADOW_TRIAL_RUN_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_SHADOW_TRIAL_EVIDENCE_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_SHADOW_TRIAL_EVIDENCE_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_REPLACEMENT_CANDIDATE_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_REPLACEMENT_CANDIDATE_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_ROUTE_BINDING_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_ROUTE_BINDING_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_ROUTE_ACTIVATION_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_ROUTE_ACTIVATION_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_ROUTE_EVENT_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_ROUTE_EVENT_PAYLOAD_SCHEMA_VERSION;
pub(crate) const CAPABILITY_ROUTE_ROLLBACK_SCHEMA_VERSION: &str =
    crate::engine::CAPABILITY_ROUTE_ROLLBACK_PAYLOAD_SCHEMA_VERSION;
pub(crate) const COCKPIT_VISIBILITY_SCHEMA_VERSION: &str =
    "tron.capability_binding.cockpit_overview.v1";

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "capability_binding::cockpit_overview",
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description(
            "Read-only redacted capability modularity projection for Engine Cockpit clients",
        )
        .tags(vec![
            "capability",
            "binding",
            "cockpit",
            "modularity",
            "read_only",
        ])
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 200
                }
            }
        }))
        .response_schema(json!({
            "type": "object",
            "additionalProperties": true,
            "required": ["schemaVersion", "operation", "summary", "operationList", "resourceScan", "families", "operations", "scope", "projection"],
            "properties": {
                "schemaVersion": {"type": "string"},
                "operation": {"const": "capability_binding_cockpit_overview"},
                "summary": {"type": "object"},
                "operationList": {"type": "object"},
                "resourceScan": {"type": "object"},
                "families": {"type": "array"},
                "operations": {"type": "array"},
                "scope": {"type": "object"},
                "projection": {"type": "object"}
            }
        }))
        .build()?,
    ])
}
