use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{DurableOutputContract, EffectClass, IdempotencyContract, RiskLevel};

use super::{
    CONFIGURE_FUNCTION, EDIT_FUNCTION, EXPORT_FUNCTION, IMPORT_FUNCTION, INSPECT_FUNCTION,
    LIST_FUNCTION, MEMORY_ENGINE_KIND, MEMORY_LIFECYCLE_TOPIC, MEMORY_MIGRATION_ENVELOPE_KIND,
    MEMORY_POLICY_KIND, MEMORY_PROMPT_TRACE_KIND, MEMORY_RECORD_KIND, PROMPT_TRACE_FUNCTION,
    READ_SCOPE, RETAIN_FUNCTION, STATUS_FUNCTION, TOMBSTONE_FUNCTION, WORKER, WRITE_SCOPE,
};

/// Canonical memory capability contracts.
pub(crate) fn capabilities() -> crate::engine::Result<Vec<CapabilitySpec>> {
    Ok(vec![
        read_contract(
            STATUS_FUNCTION,
            "Inspect memory policy, mode, active engine identity, and prompt-inclusion boundary.",
        )
        .request_schema(json_schema())
        .response_schema(status_response_schema())
        .build()?,
        write_contract(
            CONFIGURE_FUNCTION,
            "Create or update the memory policy resource for the current scope.",
        )
        .request_schema(configure_schema())
        .response_schema(policy_response_schema())
        .output_contract(DurableOutputContract::resource_backed([
            MEMORY_POLICY_KIND,
            MEMORY_ENGINE_KIND,
        ]))
        .build()?,
        write_contract(
            RETAIN_FUNCTION,
            "Retain a canonical memory record through the resource-backed contract.",
        )
        .request_schema(retain_schema())
        .response_schema(record_response_schema("retained"))
        .output_contract(DurableOutputContract::resource_backed([MEMORY_RECORD_KIND]))
        .build()?,
        write_contract(
            EDIT_FUNCTION,
            "Create a versioned replacement for an existing memory record.",
        )
        .request_schema(edit_schema())
        .response_schema(record_response_schema("edited"))
        .output_contract(DurableOutputContract::resource_backed([MEMORY_RECORD_KIND]))
        .build()?,
        write_contract(
            TOMBSTONE_FUNCTION,
            "Tombstone a memory record while preserving audit history.",
        )
        .request_schema(tombstone_schema())
        .response_schema(record_response_schema("tombstoned"))
        .output_contract(DurableOutputContract::resource_backed([MEMORY_RECORD_KIND]))
        .build()?,
        read_contract(
            LIST_FUNCTION,
            "List redacted memory records in the current scope.",
        )
        .request_schema(list_schema())
        .response_schema(list_response_schema())
        .build()?,
        read_contract(
            INSPECT_FUNCTION,
            "Inspect one redacted memory record and its version history.",
        )
        .request_schema(inspect_schema())
        .response_schema(json_schema())
        .build()?,
        write_contract(
            EXPORT_FUNCTION,
            "Export redacted portable memory records into a migration envelope resource.",
        )
        .request_schema(export_schema())
        .response_schema(migration_response_schema("exported"))
        .output_contract(DurableOutputContract::resource_backed([
            MEMORY_MIGRATION_ENVELOPE_KIND,
        ]))
        .build()?,
        write_contract(
            IMPORT_FUNCTION,
            "Import portable memory records from a migration envelope payload.",
        )
        .request_schema(import_schema())
        .response_schema(migration_response_schema("imported"))
        .output_contract(DurableOutputContract::resource_backed([
            MEMORY_MIGRATION_ENVELOPE_KIND,
            MEMORY_RECORD_KIND,
        ]))
        .build()?,
        write_contract(
            PROMPT_TRACE_FUNCTION,
            "Record a prompt inclusion trace without injecting private memory content.",
        )
        .request_schema(prompt_trace_schema())
        .response_schema(prompt_trace_response_schema())
        .output_contract(DurableOutputContract::resource_backed([
            MEMORY_PROMPT_TRACE_KIND,
        ]))
        .build()?,
    ])
}

fn read_contract(function_id: &'static str, description: &'static str) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::PureRead,
        RiskLevel::Low,
        Some(READ_SCOPE),
    )
    .description(description)
    .tags(vec!["memory", "audit", "resource"])
    .domain_module("memory")
    .presentation_hints(json!({"systemImage": "brain.head.profile"}))
}

fn write_contract(function_id: &'static str, description: &'static str) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::AppendOnlyEvent,
        RiskLevel::Medium,
        Some(WRITE_SCOPE),
    )
    .description(description)
    .tags(vec!["memory", "resource", "audit", "migration"])
    .domain_module("memory")
    .idempotency(IdempotencyContract::caller_system_engine_ledger())
    .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
    .stream_topics(vec![MEMORY_LIFECYCLE_TOPIC])
    .presentation_hints(json!({"systemImage": "brain"}))
}

fn json_schema() -> serde_json::Value {
    json!({"type": "object", "additionalProperties": true})
}

fn configure_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["mode"],
        "additionalProperties": false,
        "properties": {
            "mode": {"type": "string", "enum": ["disabled", "active", "shadow", "compare"]},
            "activeEngineId": {"type": "string"},
            "compareEngineIds": {"type": "array", "items": {"type": "string"}},
            "inclusion": {"type": "object"},
            "retention": {"type": "object"},
            "privacy": {"type": "object"},
            "migration": {"type": "object"},
            "provenance": {"type": "object"}
        }
    })
}

fn retain_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["subject", "scope", "preview", "bodyRef", "provenance", "confidence", "sensitivity", "retention"],
        "additionalProperties": false,
        "properties": {
            "recordId": {"type": "string"},
            "subject": {"type": "string"},
            "scope": {"type": "object"},
            "preview": {"type": "string"},
            "bodyRef": {"type": "object"},
            "provenance": {"type": "object"},
            "confidence": {"type": "object"},
            "sensitivity": {"type": "string"},
            "retention": {"type": "object"},
            "expiresAt": {"type": "string"},
            "sourceRefs": {"type": "array"},
            "traceRefs": {"type": "array"},
            "replayRefs": {"type": "array"},
            "migration": {"type": "object"}
        }
    })
}

fn edit_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["recordResourceId", "expectedCurrentVersionId"],
        "additionalProperties": false,
        "properties": {
            "recordResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "subject": {"type": "string"},
            "scope": {"type": "object"},
            "preview": {"type": "string"},
            "bodyRef": {"type": "object"},
            "confidence": {"type": "object"},
            "sensitivity": {"type": "string"},
            "retention": {"type": "object"},
            "expiresAt": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}

fn tombstone_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["recordResourceId", "expectedCurrentVersionId"],
        "additionalProperties": false,
        "properties": {
            "recordResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}

fn list_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "lifecycle": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 500}
        }
    })
}

fn inspect_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["recordResourceId"],
        "additionalProperties": false,
        "properties": {
            "recordResourceId": {"type": "string"}
        }
    })
}

fn export_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "targetEngineId": {"type": "string"},
            "lineage": {"type": "object"}
        }
    })
}

fn import_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["envelope"],
        "additionalProperties": false,
        "properties": {
            "envelope": {"type": "object"}
        }
    })
}

fn prompt_trace_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "source": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 500}
        }
    })
}

fn status_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "mode", "promptInclusion", "contract"],
        "additionalProperties": true
    })
}

fn policy_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "policyResourceId", "policyVersionId", "mode", "resourceRefs"],
        "additionalProperties": true
    })
}

fn record_response_schema(status: &'static str) -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "recordResourceId", "recordVersionId", "resourceRefs"],
        "additionalProperties": true,
        "properties": {"status": {"const": status}}
    })
}

fn list_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "records", "redacted"],
        "additionalProperties": true
    })
}

fn migration_response_schema(status: &'static str) -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "envelopeResourceId", "envelopeVersionId", "recordCount", "resourceRefs"],
        "additionalProperties": true,
        "properties": {"status": {"const": status}}
    })
}

fn prompt_trace_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "traceResourceId", "traceVersionId", "context", "trace", "resourceRefs"],
        "additionalProperties": true
    })
}
