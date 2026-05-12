//! Capability contracts owned by the web domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};

pub(crate) const STREAM_TOPICS: &[&str] = &["web.requests"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "web::fetch",
            "web",
            EffectClass::PureRead,
            RiskLevel::Medium,
            Some("web.read"),
        )
        .request_schema(json!({
            "additionalProperties": false,
            "properties": {
                "url": {"type": "string"},
                "headers": {"additionalProperties": true, "type": "object"},
                "maxBytes": {"type": "integer", "minimum": 1, "maximum": 1048576},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            },
            "required": ["url"],
            "type": "object"
        }))
        .response_schema(json!({
            "additionalProperties": false,
            "properties": {
                "url": {"type": "string"},
                "status": {"type": "integer"},
                "contentType": {"type": ["string", "null"]},
                "body": {"type": "string"},
                "truncated": {"type": "boolean"}
            },
            "required": ["url", "status", "contentType", "body", "truncated"],
            "type": "object"
        }))
        .build()?,
        CapabilityContract::new(
            "web::search",
            "web",
            EffectClass::PureRead,
            RiskLevel::Medium,
            Some("web.read"),
        )
        .request_schema(json!({
            "additionalProperties": false,
            "properties": {
                "query": {"type": "string"},
                "count": {"type": "integer", "minimum": 1, "maximum": 20},
                "freshness": {"type": "string"},
                "country": {"type": "string"},
                "safesearch": {"type": "string", "enum": ["off", "moderate", "strict"]},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            },
            "required": ["query"],
            "type": "object"
        }))
        .response_schema(json!({
            "additionalProperties": false,
            "properties": {
                "query": {"type": "string"},
                "results": {"items": {"additionalProperties": true, "type": "object"}, "type": "array"}
            },
            "required": ["query", "results"],
            "type": "object"
        }))
        .build()?,
    ])
}
