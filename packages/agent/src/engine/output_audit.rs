//! Audit observations for durable outputs that are not yet resource-backed.
//!
//! This phase records non-resource durable outputs instead of globally blocking
//! them. The observations make the later enforcement cut measurable.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, Row, params, types::Type};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::errors::{EngineError, Result};
use super::ids::{FunctionId, InvocationId, TraceId};

/// One output-resource audit observation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineOutputAuditObservation {
    /// Stable observation id.
    pub observation_id: String,
    /// Trace id.
    pub trace_id: TraceId,
    /// Invocation id.
    pub invocation_id: InvocationId,
    /// Function that produced the output.
    pub function_id: FunctionId,
    /// Output kind, for example `filesystem_write`.
    pub output_kind: String,
    /// Optional path or logical ref.
    pub output_ref: Option<String>,
    /// Severity.
    pub severity: String,
    /// Human-readable message.
    pub message: String,
    /// Extra details.
    pub details: Value,
    /// Timestamp.
    pub created_at: DateTime<Utc>,
}

/// In-memory output audit store.
#[derive(Clone, Debug, Default)]
pub struct InMemoryEngineOutputAuditStore {
    observations: BTreeMap<String, EngineOutputAuditObservation>,
}

impl InMemoryEngineOutputAuditStore {
    /// Create an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Record an observation.
    pub fn record(
        &mut self,
        request: EngineOutputAuditObservation,
    ) -> Result<EngineOutputAuditObservation> {
        self.observations
            .insert(request.observation_id.clone(), request.clone());
        Ok(request)
    }

    /// List observations for one trace.
    pub fn list_by_trace(
        &self,
        trace_id: &str,
        limit: usize,
    ) -> Result<Vec<EngineOutputAuditObservation>> {
        validate_limit(limit)?;
        Ok(self
            .observations
            .values()
            .filter(|observation| observation.trace_id.as_str() == trace_id)
            .take(limit)
            .cloned()
            .collect())
    }
}

/// SQLite output audit store.
pub struct SqliteEngineOutputAuditStore {
    conn: Connection,
}

impl SqliteEngineOutputAuditStore {
    /// Open output audit tables in the unified engine DB.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)
            .map_err(|err| sqlite_err("output_audit.open", err.to_string()))?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS engine_output_audit_observations (
                observation_id TEXT PRIMARY KEY,
                trace_id TEXT NOT NULL,
                invocation_id TEXT NOT NULL,
                function_id TEXT NOT NULL,
                output_kind TEXT NOT NULL,
                output_ref TEXT,
                severity TEXT NOT NULL,
                message TEXT NOT NULL,
                details_json TEXT NOT NULL,
                created_at TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_engine_output_audit_trace
               ON engine_output_audit_observations(trace_id, created_at);",
        )
        .map_err(|err| sqlite_err("output_audit.init", err.to_string()))?;
        Ok(Self { conn })
    }

    /// Record an observation.
    pub fn record(
        &mut self,
        request: EngineOutputAuditObservation,
    ) -> Result<EngineOutputAuditObservation> {
        self.conn
            .execute(
                "INSERT INTO engine_output_audit_observations
                 (observation_id, trace_id, invocation_id, function_id, output_kind,
                  output_ref, severity, message, details_json, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    request.observation_id,
                    request.trace_id.as_str(),
                    request.invocation_id.as_str(),
                    request.function_id.as_str(),
                    request.output_kind,
                    request.output_ref,
                    request.severity,
                    request.message,
                    serde_json::to_string(&request.details).map_err(|error| {
                        EngineError::LedgerFailure {
                            operation: "output_audit.details",
                            message: error.to_string(),
                        }
                    })?,
                    request.created_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("output_audit.record", err.to_string()))?;
        Ok(request)
    }

    /// List observations for one trace.
    pub fn list_by_trace(
        &self,
        trace_id: &str,
        limit: usize,
    ) -> Result<Vec<EngineOutputAuditObservation>> {
        validate_limit(limit)?;
        let mut stmt = self
            .conn
            .prepare(
                "SELECT * FROM engine_output_audit_observations
                 WHERE trace_id = ?1 ORDER BY created_at ASC LIMIT ?2",
            )
            .map_err(|err| sqlite_err("output_audit.list.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![trace_id, limit as i64], row_to_observation)
            .map_err(|err| sqlite_err("output_audit.list", err.to_string()))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|err| sqlite_err("output_audit.list.row", err.to_string()))
    }
}

/// Shared output audit backend.
pub enum EngineOutputAuditStoreBackend {
    /// In-memory.
    InMemory(InMemoryEngineOutputAuditStore),
    /// SQLite.
    Sqlite(SqliteEngineOutputAuditStore),
}

impl EngineOutputAuditStoreBackend {
    /// Record an observation.
    pub fn record(
        &mut self,
        request: EngineOutputAuditObservation,
    ) -> Result<EngineOutputAuditObservation> {
        match self {
            Self::InMemory(store) => store.record(request),
            Self::Sqlite(store) => store.record(request),
        }
    }

    /// List by trace.
    pub fn list_by_trace(
        &self,
        trace_id: &str,
        limit: usize,
    ) -> Result<Vec<EngineOutputAuditObservation>> {
        match self {
            Self::InMemory(store) => store.list_by_trace(trace_id, limit),
            Self::Sqlite(store) => store.list_by_trace(trace_id, limit),
        }
    }
}

/// Build a new audit observation.
pub fn output_audit_observation(
    trace_id: TraceId,
    invocation_id: InvocationId,
    function_id: FunctionId,
    output_kind: impl Into<String>,
    output_ref: Option<String>,
    message: impl Into<String>,
    details: Value,
) -> EngineOutputAuditObservation {
    EngineOutputAuditObservation {
        observation_id: format!("out_audit_{}", Uuid::now_v7()),
        trace_id,
        invocation_id,
        function_id,
        output_kind: output_kind.into(),
        output_ref,
        severity: "warn".to_owned(),
        message: message.into(),
        details,
        created_at: Utc::now(),
    }
}

fn validate_limit(limit: usize) -> Result<()> {
    if limit == 0 {
        return Err(EngineError::PolicyViolation(
            "output audit list limit must be greater than zero".to_owned(),
        ));
    }
    Ok(())
}

fn row_to_observation(row: &Row<'_>) -> rusqlite::Result<EngineOutputAuditObservation> {
    let details_raw: String = row.get("details_json")?;
    let created_at: String = row.get("created_at")?;
    Ok(EngineOutputAuditObservation {
        observation_id: row.get("observation_id")?,
        trace_id: TraceId::new(row.get::<_, String>("trace_id")?).map_err(sql_from_engine)?,
        invocation_id: InvocationId::new(row.get::<_, String>("invocation_id")?)
            .map_err(sql_from_engine)?,
        function_id: FunctionId::new(row.get::<_, String>("function_id")?)
            .map_err(sql_from_engine)?,
        output_kind: row.get("output_kind")?,
        output_ref: row.get("output_ref")?,
        severity: row.get("severity")?,
        message: row.get("message")?,
        details: serde_json::from_str(&details_raw).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error))
        })?,
        created_at: DateTime::parse_from_rfc3339(&created_at)
            .map(|value| value.with_timezone(&Utc))
            .map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error))
            })?,
    })
}

fn sql_from_engine(error: EngineError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, Type::Text, Box::new(error))
}

fn sqlite_err(operation: &'static str, message: String) -> EngineError {
    EngineError::LedgerFailure { operation, message }
}
