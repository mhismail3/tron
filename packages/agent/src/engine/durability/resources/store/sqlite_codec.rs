//! SQLite schema, row codecs, and scalar serialization helpers for resources.

use chrono::{DateTime, Utc};
use rusqlite::{Connection, Row, types::Type};
use serde::{Deserialize, Serialize};

use crate::engine::durability::resources::types::*;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{ActorId, InvocationId, TraceId, WorkerId};

pub(super) const RESOURCE_SQLITE_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS engine_resource_type_definitions (
  kind TEXT PRIMARY KEY,
  schema_id TEXT NOT NULL,
  schema_json TEXT NOT NULL,
  lifecycle_states_json TEXT NOT NULL,
  versioning_mode TEXT NOT NULL,
  allowed_link_relations_json TEXT NOT NULL,
  default_retention_json TEXT NOT NULL,
  redaction_rules_json TEXT NOT NULL,
  materialization_rules_json TEXT NOT NULL,
  required_capabilities_json TEXT NOT NULL,
  owner_worker_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS engine_resources (
  resource_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  schema_id TEXT NOT NULL,
  scope_kind TEXT NOT NULL,
  scope_value TEXT NOT NULL,
  owner_worker_id TEXT NOT NULL,
  owner_actor_id TEXT NOT NULL,
  lifecycle TEXT NOT NULL,
  policy_json TEXT NOT NULL,
  current_version_id TEXT,
  trace_id TEXT NOT NULL,
  created_by_invocation_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY(kind) REFERENCES engine_resource_type_definitions(kind)
);
CREATE INDEX IF NOT EXISTS idx_engine_resources_kind_scope
  ON engine_resources(kind, scope_kind, scope_value, lifecycle, updated_at);
CREATE TABLE IF NOT EXISTS engine_resource_versions (
  version_id TEXT PRIMARY KEY,
  resource_id TEXT NOT NULL REFERENCES engine_resources(resource_id),
  parent_version_id TEXT,
  content_hash TEXT NOT NULL,
  version_state TEXT NOT NULL DEFAULT 'available',
  payload_json TEXT NOT NULL,
  locations_json TEXT NOT NULL,
  created_by_invocation_id TEXT,
  trace_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_engine_resource_versions_resource
  ON engine_resource_versions(resource_id, created_at);
CREATE TABLE IF NOT EXISTS engine_resource_links (
  link_id TEXT PRIMARY KEY,
  source_resource_id TEXT NOT NULL REFERENCES engine_resources(resource_id),
  target_resource_id TEXT NOT NULL REFERENCES engine_resources(resource_id),
  relation TEXT NOT NULL,
  metadata_json TEXT NOT NULL,
  created_by_invocation_id TEXT,
  trace_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_engine_resource_links_source
  ON engine_resource_links(source_resource_id, relation);
CREATE INDEX IF NOT EXISTS idx_engine_resource_links_target
  ON engine_resource_links(target_resource_id, relation);
CREATE TABLE IF NOT EXISTS engine_resource_events (
  event_id TEXT PRIMARY KEY,
  resource_id TEXT NOT NULL REFERENCES engine_resources(resource_id),
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  invocation_id TEXT,
  trace_id TEXT NOT NULL,
  occurred_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_engine_resource_events_resource
  ON engine_resource_events(resource_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_engine_resource_events_trace
  ON engine_resource_events(trace_id, occurred_at);
"#;

pub(super) fn json_string<T: Serialize>(value: &T, operation: &'static str) -> Result<String> {
    serde_json::to_string(value).map_err(|error| EngineError::LedgerFailure {
        operation,
        message: error.to_string(),
    })
}

pub(super) fn sqlite_err(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}

pub(super) fn collect_rows<T>(
    rows: rusqlite::MappedRows<'_, impl FnMut(&Row<'_>) -> rusqlite::Result<T>>,
    operation: &'static str,
) -> Result<Vec<T>> {
    let mut values = Vec::new();
    for row in rows {
        values.push(row.map_err(|err| sqlite_err(operation, err.to_string()))?);
    }
    Ok(values)
}

pub(super) fn resource_scope_workspace(scope: &EngineResourceScope) -> Option<&str> {
    match scope {
        EngineResourceScope::Workspace(value) => Some(value.as_str()),
        EngineResourceScope::System | EngineResourceScope::Session(_) => None,
    }
}

pub(super) fn row_to_type_definition(
    row: &Row<'_>,
) -> rusqlite::Result<EngineResourceTypeDefinition> {
    let versioning_mode_raw: String = row.get(4)?;
    Ok(EngineResourceTypeDefinition {
        kind: row.get(0)?,
        schema_id: row.get(1)?,
        schema: row_json(row, 2, "resource_type.schema")?,
        lifecycle_states: row_json(row, 3, "resource_type.lifecycle_states")?,
        versioning_mode: EngineResourceVersioningMode::parse(&versioning_mode_raw)
            .map_err(|err| row_engine_err(4, err))?,
        allowed_link_relations: row_json(row, 5, "resource_type.allowed_link_relations")?,
        default_retention: row_json(row, 6, "resource_type.default_retention")?,
        redaction_rules: row_json(row, 7, "resource_type.redaction_rules")?,
        materialization_rules: row_json(row, 8, "resource_type.materialization_rules")?,
        required_capabilities: row_json(row, 9, "resource_type.required_capabilities")?,
        owner_worker_id: WorkerId::new(row.get::<_, String>(10)?)
            .map_err(|err| row_engine_err(10, err))?,
        revision: row.get(11)?,
        created_at: row_time(row, 12, "resource_type.created_at")?,
        updated_at: row_time(row, 13, "resource_type.updated_at")?,
    })
}

pub(super) fn row_to_resource(row: &Row<'_>) -> rusqlite::Result<EngineResource> {
    let scope_kind: String = row.get(3)?;
    let scope_value: String = row.get(4)?;
    Ok(EngineResource {
        resource_id: row.get(0)?,
        kind: row.get(1)?,
        schema_id: row.get(2)?,
        scope: EngineResourceScope::parse(&scope_kind, scope_value)
            .map_err(|err| row_engine_err(3, err))?,
        owner_worker_id: WorkerId::new(row.get::<_, String>(5)?)
            .map_err(|err| row_engine_err(5, err))?,
        owner_actor_id: ActorId::new(row.get::<_, String>(6)?)
            .map_err(|err| row_engine_err(6, err))?,
        lifecycle: row.get(7)?,
        policy: row_json(row, 8, "resource.policy")?,
        current_version_id: row.get(9)?,
        trace_id: TraceId::new(row.get::<_, String>(10)?).map_err(|err| row_engine_err(10, err))?,
        created_by_invocation_id: row_invocation_id(row, 11)?,
        created_at: row_time(row, 12, "resource.created_at")?,
        updated_at: row_time(row, 13, "resource.updated_at")?,
    })
}

pub(super) fn row_to_resource_version(
    conn: &Connection,
    row: &Row<'_>,
) -> rusqlite::Result<EngineResourceVersion> {
    let payload_json: String = row.get(5)?;
    let payload = crate::shared::storage::resolve_stored_json_value(conn, &payload_json).map_err(
        |error| row_engine_err(5, sqlite_err("resource_version.payload", error.to_string())),
    )?;
    Ok(EngineResourceVersion {
        version_id: row.get(0)?,
        resource_id: row.get(1)?,
        parent_version_id: row.get(2)?,
        content_hash: row.get(3)?,
        state: EngineResourceVersionState::parse(&row.get::<_, String>(4)?)
            .map_err(|err| row_engine_err(4, err))?,
        payload,
        locations: row_json(row, 6, "resource_version.locations")?,
        created_by_invocation_id: row_invocation_id(row, 7)?,
        trace_id: TraceId::new(row.get::<_, String>(8)?).map_err(|err| row_engine_err(8, err))?,
        created_at: row_time(row, 9, "resource_version.created_at")?,
    })
}

pub(super) fn row_to_resource_link(row: &Row<'_>) -> rusqlite::Result<EngineResourceLink> {
    Ok(EngineResourceLink {
        link_id: row.get(0)?,
        source_resource_id: row.get(1)?,
        target_resource_id: row.get(2)?,
        relation: row.get(3)?,
        metadata: row_json(row, 4, "resource_link.metadata")?,
        created_by_invocation_id: row_invocation_id(row, 5)?,
        trace_id: TraceId::new(row.get::<_, String>(6)?).map_err(|err| row_engine_err(6, err))?,
        created_at: row_time(row, 7, "resource_link.created_at")?,
    })
}

pub(super) fn row_to_resource_event(row: &Row<'_>) -> rusqlite::Result<EngineResourceEvent> {
    Ok(EngineResourceEvent {
        event_id: row.get(0)?,
        resource_id: row.get(1)?,
        event_type: row.get(2)?,
        payload: row_json(row, 3, "resource_event.payload")?,
        invocation_id: row_invocation_id(row, 4)?,
        trace_id: TraceId::new(row.get::<_, String>(5)?).map_err(|err| row_engine_err(5, err))?,
        occurred_at: row_time(row, 6, "resource_event.occurred_at")?,
    })
}

fn row_json<T: for<'de> Deserialize<'de>>(
    row: &Row<'_>,
    idx: usize,
    operation: &'static str,
) -> rusqlite::Result<T> {
    let value: String = row.get(idx)?;
    serde_json::from_str(&value).map_err(|error| {
        row_engine_err(
            idx,
            EngineError::LedgerFailure {
                operation,
                message: error.to_string(),
            },
        )
    })
}

fn row_time(row: &Row<'_>, idx: usize, operation: &'static str) -> rusqlite::Result<DateTime<Utc>> {
    let value: String = row.get(idx)?;
    DateTime::parse_from_rfc3339(&value)
        .map(|time| time.with_timezone(&Utc))
        .map_err(|error| {
            row_engine_err(
                idx,
                EngineError::LedgerFailure {
                    operation,
                    message: error.to_string(),
                },
            )
        })
}

fn row_invocation_id(row: &Row<'_>, idx: usize) -> rusqlite::Result<Option<InvocationId>> {
    let value: Option<String> = row.get(idx)?;
    value
        .map(InvocationId::new)
        .transpose()
        .map_err(|err| row_engine_err(idx, err))
}

fn row_engine_err(idx: usize, error: EngineError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(idx, Type::Text, Box::new(error))
}
