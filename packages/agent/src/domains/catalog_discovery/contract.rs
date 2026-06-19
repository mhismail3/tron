use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, DurableOutputContract, EffectClass,
    IdempotencyContract, ResourceLeaseRequirement, RiskLevel,
};

use super::{
    CATALOG_DISCOVERY_TOPIC, CONFORMANCE_REPORT_FUNCTION, INSPECT_FUNCTION, READ_SCOPE,
    SEARCH_FUNCTION, WORKER, WRITE_SCOPE,
};

/// Canonical catalog discovery capability contracts.
pub(super) fn capabilities() -> crate::engine::Result<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            SEARCH_FUNCTION,
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("Search visible workers and functions with schema, health, and conformance summaries.")
        .tags(vec!["catalog", "discovery", "self-inspection", "schema", "health"])
        .examples(vec![json!({
            "text": "files",
            "includeProtectedCounts": true
        })])
        .lifecycle(json!({
            "stopsTurn": false,
            "executionPolicy": "inspect_only",
            "sideEffects": []
        }))
        .request_schema(search_schema())
        .response_schema(search_response_schema())
        .presentation_hints(json!({"systemImage": "sparkle.magnifyingglass"}))
        .build()?,
        CapabilityContract::new(
            INSPECT_FUNCTION,
            WORKER,
            EffectClass::PureRead,
            RiskLevel::Low,
            Some(READ_SCOPE),
        )
        .description("Inspect one visible catalog item without invoking it.")
        .tags(vec!["catalog", "inspect", "schema", "metadata"])
        .examples(vec![json!({
            "kind": "function",
            "id": "capability::execute"
        })])
        .lifecycle(json!({
            "stopsTurn": false,
            "executionPolicy": "inspect_only",
            "sideEffects": []
        }))
        .request_schema(inspect_schema())
        .response_schema(inspect_response_schema())
        .presentation_hints(json!({"systemImage": "doc.text.magnifyingglass"}))
        .build()?,
        CapabilityContract::new(
            CONFORMANCE_REPORT_FUNCTION,
            WORKER,
            EffectClass::AppendOnlyEvent,
            RiskLevel::Low,
            Some(WRITE_SCOPE),
        )
        .description("Create a durable conformance report for visible catalog discovery and protected omission evidence.")
        .tags(vec!["catalog", "conformance", "evidence", "resource", "audit"])
        .examples(vec![json!({
            "reason": "runtime cockpit verification",
            "includeProtectedCounts": true
        })])
        .lifecycle(json!({
            "stopsTurn": false,
            "executionPolicy": "evidence_write_only",
            "sideEffects": ["resource:create", "stream:publish"]
        }))
        .request_schema(report_schema())
        .response_schema(report_response_schema())
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .resource_lease(ResourceLeaseRequirement::exclusive_template(
            WORKER,
            "catalog_discovery:report",
            60_000,
        ))
        .compensation(CompensationContract::new(
            CompensationKind::EventSourced,
            "catalog discovery reports are append-only resource and stream evidence; later reports supersede rather than rewrite history",
        ))
        .output_contract(DurableOutputContract::resource_backed([
            crate::engine::CATALOG_DISCOVERY_REPORT_KIND,
        ]))
        .stream_topics(vec![CATALOG_DISCOVERY_TOPIC])
        .presentation_hints(json!({"systemImage": "checkmark.shield"}))
        .build()?,
    ])
}

fn search_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "text": {"type": "string"},
            "namespacePrefix": {"type": "string"},
            "visibility": {"type": "string"},
            "effectClass": {"type": "string"},
            "maxRisk": {"type": "string"},
            "health": {"type": "string"},
            "includeProtectedCounts": {"type": "boolean"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 500},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn inspect_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["kind", "id"],
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string", "enum": ["function", "worker", "trigger_type", "trigger"]},
            "id": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn report_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "text": {"type": "string"},
            "namespacePrefix": {"type": "string"},
            "reason": {"type": "string"},
            "includeProtectedCounts": {"type": "boolean"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn search_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "catalogRevision", "summary", "functions", "workers"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "catalogRevision": {"type": "integer"},
            "summary": {"type": "object"},
            "functions": {"type": "array"},
            "workers": {"type": "array"},
            "triggers": {"type": "array"},
            "triggerTypes": {"type": "array"},
            "resourceEvidence": {"type": "object"}
        }
    })
}

fn inspect_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "catalogRevision", "kind", "id", "definition"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "catalogRevision": {"type": "integer"},
            "kind": {"type": "string"},
            "id": {"type": "string"},
            "definition": {},
            "summary": {"type": "object"},
            "schemaHints": {"type": "object"},
            "conformance": {"type": "object"}
        }
    })
}

fn report_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["status", "reportResourceId", "streamCursor", "resourceRefs", "summary"],
        "additionalProperties": true,
        "properties": {
            "status": {"type": "string"},
            "reportResourceId": {"type": "string"},
            "streamCursor": {"type": "integer"},
            "summary": {"type": "object"},
            "resourceRefs": {"type": "array"}
        }
    })
}
