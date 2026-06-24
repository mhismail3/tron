//! SQLite schema, row codecs, and stored JSON helpers for the engine ledger.

use chrono::{DateTime, Utc};
use rusqlite::Connection;
use serde::{Serialize, de::DeserializeOwned};

use super::{IdempotencyEntry, IdempotencyKey, StoredEngineError, StoredInvocationOutcome};
use crate::engine::catalog::discovery::ActorKind;
use crate::engine::invocation::model::InvocationRecord;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, WorkerId,
};
use crate::engine::kernel::types::{
    CatalogChange, CatalogChangeClass, CatalogRevision, CatalogSubjectKind, DeliveryMode,
    FunctionRevision, IdempotencyScope, VisibilityScope,
};

pub(super) const SQLITE_SCHEMA: &str = r#"
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS engine_catalog_changes (
  id              TEXT PRIMARY KEY,
  before_revision INTEGER NOT NULL,
  after_revision  INTEGER NOT NULL,
  kind_json       TEXT NOT NULL,
  subject_id      TEXT NOT NULL,
  subject_kind_json TEXT NOT NULL,
  class_json      TEXT NOT NULL,
  visibility_json TEXT NOT NULL,
  session_id      TEXT,
  workspace_id    TEXT,
  owner_worker_id TEXT,
  timestamp       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS engine_catalog_workers (
  worker_id       TEXT PRIMARY KEY,
  definition_json TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS engine_catalog_functions (
  function_id     TEXT PRIMARY KEY,
  owner_worker_id TEXT NOT NULL,
  definition_json TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS engine_invocations (
  invocation_id            TEXT PRIMARY KEY,
  function_id              TEXT NOT NULL,
  worker_id                TEXT NOT NULL,
  function_revision        INTEGER NOT NULL,
  catalog_revision         INTEGER NOT NULL,
  actor_id                 TEXT NOT NULL,
  actor_kind_json          TEXT NOT NULL,
  authority_grant_id       TEXT NOT NULL,
  authority_scopes_json    TEXT NOT NULL,
  trace_id                 TEXT NOT NULL,
  parent_invocation_id     TEXT,
  trigger_id               TEXT,
  session_id               TEXT,
  workspace_id             TEXT,
  delivery_mode_json       TEXT NOT NULL,
  idempotency_scope_kind   TEXT,
  idempotency_scope_value  TEXT,
  resource_lease_ids_json  TEXT NOT NULL DEFAULT '[]',
  compensation_status      TEXT,
  produced_resource_refs_json TEXT NOT NULL DEFAULT '[]',
  idempotency_key          TEXT,
  replayed_from            TEXT,
  succeeded                INTEGER NOT NULL CHECK (succeeded IN (0, 1)),
  result_json              TEXT,
  error_json               TEXT,
  timestamp                TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS engine_idempotency_entries (
  function_id           TEXT NOT NULL,
  scope_kind            TEXT NOT NULL,
  scope_value           TEXT NOT NULL,
  idempotency_key       TEXT NOT NULL,
  payload_fingerprint   TEXT NOT NULL,
  function_revision     INTEGER NOT NULL,
  replay_behavior_json  TEXT NOT NULL,
  status_json           TEXT NOT NULL,
  first_invocation_id   TEXT NOT NULL,
  latest_invocation_id  TEXT NOT NULL,
  outcome_value_json    TEXT,
  outcome_error_json    TEXT,
  created_at            TEXT NOT NULL,
  updated_at            TEXT NOT NULL,
  PRIMARY KEY (function_id, scope_kind, scope_value, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_engine_invocations_trace
  ON engine_invocations(trace_id);

CREATE INDEX IF NOT EXISTS idx_engine_catalog_changes_after
  ON engine_catalog_changes(after_revision);

CREATE INDEX IF NOT EXISTS idx_engine_catalog_functions_owner
  ON engine_catalog_functions(owner_worker_id);
"#;

pub(super) struct RawCatalogChangeRow {
    pub(super) id: String,
    pub(super) before_revision: u64,
    pub(super) after_revision: u64,
    pub(super) kind_json: String,
    pub(super) subject_id: String,
    pub(super) subject_kind_json: String,
    pub(super) class_json: String,
    pub(super) visibility_json: String,
    pub(super) session_id: Option<String>,
    pub(super) workspace_id: Option<String>,
    pub(super) owner_worker_id: Option<String>,
    pub(super) timestamp: String,
}

pub(super) struct RawInvocationRow {
    pub(super) invocation_id: String,
    pub(super) function_id: String,
    pub(super) worker_id: String,
    pub(super) function_revision: u64,
    pub(super) catalog_revision: u64,
    pub(super) actor_id: String,
    pub(super) actor_kind_json: String,
    pub(super) authority_grant_id: String,
    pub(super) authority_scopes_json: String,
    pub(super) trace_id: String,
    pub(super) parent_invocation_id: Option<String>,
    pub(super) trigger_id: Option<String>,
    pub(super) session_id: Option<String>,
    pub(super) workspace_id: Option<String>,
    pub(super) delivery_mode_json: String,
    pub(super) idempotency_scope_kind: Option<String>,
    pub(super) idempotency_scope_value: Option<String>,
    pub(super) resource_lease_ids_json: String,
    pub(super) compensation_status: Option<String>,
    pub(super) produced_resource_refs_json: String,
    pub(super) idempotency_key: Option<String>,
    pub(super) replayed_from: Option<String>,
    pub(super) succeeded: i64,
    pub(super) result_json: Option<String>,
    pub(super) error_json: Option<String>,
    pub(super) timestamp: String,
}

pub(super) struct RawIdempotencyRow {
    pub(super) function_id: String,
    pub(super) scope_kind: String,
    pub(super) scope_value: String,
    pub(super) idempotency_key: String,
    pub(super) payload_fingerprint: String,
    pub(super) function_revision: u64,
    pub(super) replay_behavior_json: String,
    pub(super) status_json: String,
    pub(super) first_invocation_id: String,
    pub(super) latest_invocation_id: String,
    pub(super) outcome_value_json: Option<String>,
    pub(super) outcome_error_json: Option<String>,
    pub(super) created_at: String,
    pub(super) updated_at: String,
}

pub(super) fn raw_catalog_change(row: RawCatalogChangeRow) -> Result<CatalogChange> {
    Ok(CatalogChange {
        id: row.id,
        before: CatalogRevision(row.before_revision),
        after: CatalogRevision(row.after_revision),
        kind: from_json_string("catalog_change.kind", &row.kind_json)?,
        subject_id: row.subject_id,
        subject_kind: from_json_string::<CatalogSubjectKind>(
            "catalog_change.subject_kind",
            &row.subject_kind_json,
        )?,
        class: from_json_string::<CatalogChangeClass>("catalog_change.class", &row.class_json)?,
        visibility: from_json_string::<VisibilityScope>(
            "catalog_change.visibility",
            &row.visibility_json,
        )?,
        session_id: row.session_id,
        workspace_id: row.workspace_id,
        owner_worker: row.owner_worker_id.map(WorkerId::new).transpose()?,
        timestamp: parse_time("catalog_change.timestamp", &row.timestamp)?,
    })
}

pub(super) fn raw_invocation_record(row: RawInvocationRow) -> Result<InvocationRecord> {
    let error: Option<StoredEngineError> =
        optional_from_json_string("invocation.error", &row.error_json)?;
    Ok(InvocationRecord {
        invocation_id: InvocationId::new(row.invocation_id)?,
        function_id: FunctionId::new(row.function_id)?,
        worker_id: WorkerId::new(row.worker_id)?,
        function_revision: FunctionRevision(row.function_revision),
        catalog_revision: CatalogRevision(row.catalog_revision),
        actor_id: ActorId::new(row.actor_id)?,
        actor_kind: from_json_string::<ActorKind>("invocation.actor_kind", &row.actor_kind_json)?,
        authority_grant_id: AuthorityGrantId::new(row.authority_grant_id)?,
        authority_scopes: from_json_string(
            "invocation.authority_scopes",
            &row.authority_scopes_json,
        )?,
        trace_id: TraceId::new(row.trace_id)?,
        parent_invocation_id: row
            .parent_invocation_id
            .map(InvocationId::new)
            .transpose()?,
        trigger_id: row.trigger_id.map(TriggerId::new).transpose()?,
        session_id: row.session_id,
        workspace_id: row.workspace_id,
        delivery_mode: from_json_string::<DeliveryMode>(
            "invocation.delivery_mode",
            &row.delivery_mode_json,
        )?,
        idempotency_key: row.idempotency_key,
        idempotency_scope: match (row.idempotency_scope_kind, row.idempotency_scope_value) {
            (Some(kind), Some(value)) => Some(IdempotencyScope::new(kind, value)),
            _ => None,
        },
        resource_lease_ids: from_json_string(
            "invocation.resource_lease_ids",
            &row.resource_lease_ids_json,
        )?,
        compensation_status: row.compensation_status,
        produced_resource_refs: from_json_string(
            "invocation.produced_resource_refs",
            &row.produced_resource_refs_json,
        )?,
        replayed_from: row.replayed_from.map(InvocationId::new).transpose()?,
        succeeded: row.succeeded == 1,
        result_value: optional_from_json_string("invocation.result", &row.result_json)?,
        error: error.map(|stored| stored.to_replay_error()),
        timestamp: parse_time("invocation.timestamp", &row.timestamp)?,
    })
}

pub(super) fn raw_idempotency_entry(row: RawIdempotencyRow) -> Result<IdempotencyEntry> {
    Ok(IdempotencyEntry {
        key: IdempotencyKey {
            function_id: FunctionId::new(row.function_id)?,
            scope: IdempotencyScope::new(row.scope_kind, row.scope_value),
            key: row.idempotency_key,
        },
        payload_fingerprint: row.payload_fingerprint,
        function_revision: FunctionRevision(row.function_revision),
        replay_behavior: from_json_string(
            "idempotency.replay_behavior",
            &row.replay_behavior_json,
        )?,
        status: from_json_string("idempotency.status", &row.status_json)?,
        first_invocation_id: InvocationId::new(row.first_invocation_id)?,
        latest_invocation_id: InvocationId::new(row.latest_invocation_id)?,
        outcome: match (row.outcome_value_json, row.outcome_error_json) {
            (value, error) if value.is_some() || error.is_some() => Some(StoredInvocationOutcome {
                value: optional_from_json_string("idempotency.outcome_value", &value)?,
                error: optional_from_json_string("idempotency.outcome_error", &error)?,
            }),
            _ => None,
        },
        created_at: parse_time("idempotency.created_at", &row.created_at)?,
        updated_at: parse_time("idempotency.updated_at", &row.updated_at)?,
    })
}

pub(super) fn optional_stored_error_json(
    conn: &rusqlite::Connection,
    owner_kind: &str,
    owner_id: &str,
    error: Option<&EngineError>,
    trace_id: Option<String>,
    session_id: Option<String>,
    workspace_id: Option<String>,
) -> Result<Option<String>> {
    let stored = error.map(StoredEngineError::from_engine_error);
    optional_stored_json_string(
        conn,
        owner_kind,
        owner_id,
        "error",
        &stored,
        trace_id,
        session_id,
        workspace_id,
    )
}

pub(super) fn optional_stored_json_string<T: Serialize>(
    conn: &rusqlite::Connection,
    owner_kind: &str,
    owner_id: &str,
    field_name: &str,
    value: &Option<T>,
    trace_id: Option<String>,
    session_id: Option<String>,
    workspace_id: Option<String>,
) -> Result<Option<String>> {
    let Some(value) = value.as_ref() else {
        return Ok(None);
    };
    let json = serde_json::to_value(value).map_err(|err| EngineError::LedgerFailure {
        operation: "stored_json_value",
        message: err.to_string(),
    })?;
    crate::shared::storage::store_json_value(
        conn,
        &json,
        &crate::shared::storage::StorePayloadOptions::new(
            owner_kind.to_owned(),
            owner_id.to_owned(),
            field_name.to_owned(),
            "audit",
        )
        .with_scope(trace_id, session_id, workspace_id),
    )
    .map(Some)
    .map_err(|err| EngineError::LedgerFailure {
        operation: "stored_json_value",
        message: err.to_string(),
    })
}

pub(super) fn resolve_optional_stored_json_string(
    conn: &rusqlite::Connection,
    value: Option<String>,
) -> Result<Option<String>> {
    value
        .as_deref()
        .map(|value| {
            crate::shared::storage::resolve_stored_json_string(conn, value).map_err(|err| {
                EngineError::LedgerFailure {
                    operation: "resolve_stored_json",
                    message: err.to_string(),
                }
            })
        })
        .transpose()
}

fn optional_from_json_string<T: DeserializeOwned>(
    operation: &'static str,
    value: &Option<String>,
) -> Result<Option<T>> {
    value
        .as_ref()
        .map(|value| from_json_string(operation, value))
        .transpose()
}

pub(super) fn to_json_string<T: Serialize>(operation: &'static str, value: &T) -> Result<String> {
    serde_json::to_string(value).map_err(|err| EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    })
}

pub(super) fn from_json_string<T: DeserializeOwned>(
    operation: &'static str,
    value: &str,
) -> Result<T> {
    serde_json::from_str(value).map_err(|err| EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    })
}

pub(super) fn ensure_column(
    conn: &Connection,
    table: &'static str,
    column: &'static str,
    declaration: &'static str,
) -> Result<()> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|err| sqlite_err("ensure_column.prepare", err))?;
    let mut rows = stmt
        .query([])
        .map_err(|err| sqlite_err("ensure_column.query", err))?;
    while let Some(row) = rows
        .next()
        .map_err(|err| sqlite_err("ensure_column.next", err))?
    {
        let name: String = row
            .get(1)
            .map_err(|err| sqlite_err("ensure_column.name", err))?;
        if name == column {
            return Ok(());
        }
    }
    conn.execute(
        &format!("ALTER TABLE {table} ADD COLUMN {column} {declaration}"),
        [],
    )
    .map_err(|err| sqlite_err("ensure_column.alter", err))?;
    Ok(())
}

fn parse_time(operation: &'static str, value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|err| EngineError::LedgerFailure {
            operation,
            message: err.to_string(),
        })
}

pub(super) fn sqlite_err(operation: &'static str, err: rusqlite::Error) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    }
}

pub(super) fn ledger_failure(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}
