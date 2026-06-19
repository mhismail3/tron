use chrono::Utc;
use serde_json::{Value, json};

use crate::engine::{CreateResource, EngineHostHandle, Invocation, WorkerId};
use crate::shared::protocol::memory::{
    MEMORY_SCHEMA_VERSION, MemoryMigrationEnvelope, MemoryRecord, RESOURCE_BACKED_MEMORY_ENGINE_ID,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::service::{list_memory_value, require_writable_policy, resolve_policy};
use super::support::*;
use super::{
    MEMORY_MIGRATION_ENVELOPE_KIND, MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID, MEMORY_RECORD_KIND,
    MEMORY_RECORD_SCHEMA_ID, WORKER,
};

/// Export redacted portable memory records into a migration envelope resource.
pub(crate) async fn migrate_export_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let list = list_memory_value(engine_host, invocation, &json!({"limit": 500})).await?;
    let records = list["records"].as_array().cloned().unwrap_or_default();
    let policy = resolve_policy(engine_host, &resource_scope(invocation), false).await?;
    let envelope = MemoryMigrationEnvelope {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        operation: "export".to_owned(),
        source_engine_id: policy
            .record
            .active_engine_id
            .unwrap_or_else(|| RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned()),
        target_engine_id: optional_string(payload, "targetEngineId")?,
        records,
        index_metadata: json!({"kind": "none", "algorithm": "not_exported"}),
        lineage: optional_object(payload, "lineage")?.unwrap_or_else(|| {
            json!({
                "source": "memory.migrate_export",
                "traceId": invocation.causal_context.trace_id.as_str()
            })
        }),
        validation: json!({
            "redacted": true,
            "inlinePrivateContent": false,
            "recordCount": list["records"].as_array().map_or(0, Vec::len)
        }),
        created_at: Utc::now(),
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!(
                "memory_migration_envelope:export:{}",
                invocation.id.as_str()
            )),
            kind: MEMORY_MIGRATION_ENVELOPE_KIND.to_owned(),
            schema_id: Some(MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("exported".to_owned()),
            policy: memory_policy("migration_export"),
            initial_payload: Some(to_value(&envelope, "memory migration export")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.migration_exported",
        json!({"envelopeResourceId": resource.resource_id.clone(), "recordCount": envelope.records.len()}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "exported",
        "envelopeResourceId": resource.resource_id.clone(),
        "envelopeVersionId": resource.current_version_id.clone(),
        "recordCount": envelope.records.len(),
        "resourceRefs": [resource_ref(&resource, "memory_migration_envelope")]
    }))
}

/// Import portable records from a migration envelope payload.
pub(crate) async fn migrate_import_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let _policy = require_writable_policy(engine_host, invocation).await?;
    let envelope_payload = required_object(payload, "envelope")?;
    let records = envelope_payload
        .get("records")
        .and_then(Value::as_array)
        .cloned()
        .ok_or_else(|| invalid_params("envelope.records is required"))?;
    let mut imported = Vec::new();
    for (index, record_value) in records.iter().enumerate() {
        let record_payload = record_value
            .get("record")
            .cloned()
            .unwrap_or_else(|| record_value.clone());
        let mut record: MemoryRecord = serde_json::from_value(record_payload)
            .map_err(|err| invalid_params(format!("malformed imported memory record: {err}")))?;
        ensure_body_ref_is_pointer(&record.body_ref)?;
        record.revision = 1;
        record.lifecycle = json!({
            "state": "retained",
            "importedAt": Utc::now(),
            "sourceEnvelope": "inline"
        });
        record.migration = json!({
            "imported": true,
            "sourceEngineId": envelope_payload.get("sourceEngineId").cloned().unwrap_or(Value::Null)
        });
        let resource = engine_host
            .create_resource(CreateResource {
                resource_id: Some(format!(
                    "memory_record:import:{}:{index}",
                    invocation.id.as_str()
                )),
                kind: MEMORY_RECORD_KIND.to_owned(),
                schema_id: Some(MEMORY_RECORD_SCHEMA_ID.to_owned()),
                scope: resource_scope(invocation),
                owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
                owner_actor_id: invocation.causal_context.actor_id.clone(),
                lifecycle: Some("retained".to_owned()),
                policy: memory_policy("record_import"),
                initial_payload: Some(to_value(&record, "imported memory record")?),
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
        imported.push(resource_ref(&resource, "imported_memory_record"));
    }
    let import_envelope = MemoryMigrationEnvelope {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        operation: "import".to_owned(),
        source_engine_id: envelope_payload
            .get("sourceEngineId")
            .and_then(Value::as_str)
            .unwrap_or(RESOURCE_BACKED_MEMORY_ENGINE_ID)
            .to_owned(),
        target_engine_id: Some(RESOURCE_BACKED_MEMORY_ENGINE_ID.to_owned()),
        records: envelope_payload["records"]
            .as_array()
            .cloned()
            .unwrap_or_default(),
        index_metadata: envelope_payload
            .get("indexMetadata")
            .cloned()
            .unwrap_or_else(|| json!({"kind": "none"})),
        lineage: envelope_payload
            .get("lineage")
            .cloned()
            .unwrap_or_else(|| json!({"source": "memory.migrate_import"})),
        validation: json!({"importedRecords": imported.len(), "accepted": true}),
        created_at: Utc::now(),
    };
    let envelope_resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!(
                "memory_migration_envelope:import:{}",
                invocation.id.as_str()
            )),
            kind: MEMORY_MIGRATION_ENVELOPE_KIND.to_owned(),
            schema_id: Some(MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("imported".to_owned()),
            policy: memory_policy("migration_import"),
            initial_payload: Some(to_value(&import_envelope, "memory migration import")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.migration_imported",
        json!({"envelopeResourceId": envelope_resource.resource_id.clone(), "recordCount": imported.len()}),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "imported",
        "envelopeResourceId": envelope_resource.resource_id.clone(),
        "envelopeVersionId": envelope_resource.current_version_id.clone(),
        "recordCount": imported.len(),
        "resourceRefs": imported
    }))
}
