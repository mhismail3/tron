//! Durable compensation audit records.
//!
//! Compensation is intentionally recorded before Tron attempts any automated
//! rollback. High-risk functions describe their recovery semantics in
//! [`CompensationContract`], and the host writes one durable record for each
//! executed invocation so operators and future approval/rollback workers can
//! inspect the exact resource leases and outcome.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::errors::{EngineError, Result};
use super::ids::{ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId};
use super::ledger::StoredEngineError;
use super::types::{CompensationContract, FunctionRevision};

/// Current durable state of a compensation record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EngineCompensationStatus {
    /// The compensation contract was recorded for audit.
    Recorded,
}

impl EngineCompensationStatus {
    /// Static storage value.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Recorded => "recorded",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "recorded" => Ok(Self::Recorded),
            other => Err(EngineError::LedgerFailure {
                operation: "compensation.status",
                message: format!("unknown compensation status {other}"),
            }),
        }
    }
}

/// Durable compensation audit record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineCompensationRecord {
    /// Stable record id.
    pub compensation_id: String,
    /// Invocation this record describes.
    pub invocation_id: InvocationId,
    /// Function id.
    pub function_id: FunctionId,
    /// Function revision.
    pub function_revision: FunctionRevision,
    /// Actor that caused the invocation.
    pub actor_id: ActorId,
    /// Authority grant used for the invocation.
    pub authority_grant_id: AuthorityGrantId,
    /// Trace propagated through the invocation.
    pub trace_id: TraceId,
    /// Parent invocation if present.
    pub parent_invocation_id: Option<InvocationId>,
    /// Leases acquired by the host for the invocation.
    pub resource_lease_ids: Vec<String>,
    /// Function-declared compensation contract.
    pub contract: CompensationContract,
    /// Current compensation status.
    pub status: EngineCompensationStatus,
    /// Whether the original invocation succeeded.
    pub succeeded: bool,
    /// Successful result value, if any.
    pub result: Option<Value>,
    /// Stable error projection, if any.
    pub error: Option<StoredEngineError>,
    /// Creation timestamp.
    pub created_at: DateTime<Utc>,
}

/// In-memory compensation store.
#[derive(Default)]
pub struct InMemoryEngineCompensationStore {
    records: BTreeMap<String, EngineCompensationRecord>,
    by_invocation: BTreeMap<InvocationId, String>,
}

impl InMemoryEngineCompensationStore {
    /// Create an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Append or return the compensation record for an invocation.
    pub fn record(
        &mut self,
        mut record: EngineCompensationRecord,
    ) -> Result<EngineCompensationRecord> {
        if let Some(existing_id) = self.by_invocation.get(&record.invocation_id)
            && let Some(existing) = self.records.get(existing_id)
        {
            return Ok(existing.clone());
        }
        record.compensation_id = InvocationId::generate().to_string();
        self.by_invocation
            .insert(record.invocation_id.clone(), record.compensation_id.clone());
        self.records
            .insert(record.compensation_id.clone(), record.clone());
        Ok(record)
    }

    /// Get one record.
    pub fn get(&self, compensation_id: &str) -> Result<Option<EngineCompensationRecord>> {
        Ok(self.records.get(compensation_id).cloned())
    }

    /// List all records in insertion order by timestamp.
    pub fn list(&self) -> Result<Vec<EngineCompensationRecord>> {
        let mut records = self.records.values().cloned().collect::<Vec<_>>();
        records.sort_by_key(|record| record.created_at);
        Ok(records)
    }
}

/// SQLite-backed compensation store.
pub struct SqliteEngineCompensationStore {
    conn: Connection,
}

impl SqliteEngineCompensationStore {
    /// Open a compensation store in the isolated engine ledger DB.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path).map_err(|err| sqlite_err("compensation.open", err))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS engine_compensation_records (
  compensation_id       TEXT PRIMARY KEY,
  invocation_id         TEXT NOT NULL UNIQUE,
  function_id           TEXT NOT NULL,
  function_revision     INTEGER NOT NULL,
  actor_id              TEXT NOT NULL,
  authority_grant_id    TEXT NOT NULL,
  trace_id              TEXT NOT NULL,
  parent_invocation_id  TEXT,
  resource_lease_ids    TEXT NOT NULL,
  contract_json         TEXT NOT NULL,
  status                TEXT NOT NULL,
  succeeded             INTEGER NOT NULL CHECK (succeeded IN (0, 1)),
  result_json           TEXT,
  error_json            TEXT,
  created_at            TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_engine_compensation_invocation
  ON engine_compensation_records(invocation_id);
"#,
            )
            .map_err(|err| sqlite_err("compensation.init", err))
    }

    /// Append or return the compensation record for an invocation.
    pub fn record(
        &mut self,
        mut record: EngineCompensationRecord,
    ) -> Result<EngineCompensationRecord> {
        if let Some(existing) = self.by_invocation(&record.invocation_id)? {
            return Ok(existing);
        }
        record.compensation_id = InvocationId::generate().to_string();
        self.conn
            .execute(
                "INSERT INTO engine_compensation_records (
                    compensation_id, invocation_id, function_id, function_revision,
                    actor_id, authority_grant_id, trace_id, parent_invocation_id,
                    resource_lease_ids, contract_json, status, succeeded, result_json,
                    error_json, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
                params![
                    record.compensation_id.as_str(),
                    record.invocation_id.as_str(),
                    record.function_id.as_str(),
                    record.function_revision.0,
                    record.actor_id.as_str(),
                    record.authority_grant_id.as_str(),
                    record.trace_id.as_str(),
                    record
                        .parent_invocation_id
                        .as_ref()
                        .map(InvocationId::as_str),
                    to_json("compensation.resource_leases", &record.resource_lease_ids)?,
                    to_json("compensation.contract", &record.contract)?,
                    record.status.as_str(),
                    i64::from(record.succeeded),
                    optional_json("compensation.result", &record.result)?,
                    optional_json("compensation.error", &record.error)?,
                    record.created_at.to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("compensation.insert", err))?;
        Ok(record)
    }

    /// Get one record.
    pub fn get(&self, compensation_id: &str) -> Result<Option<EngineCompensationRecord>> {
        self.conn
            .query_row(
                "SELECT * FROM engine_compensation_records WHERE compensation_id = ?1",
                params![compensation_id],
                row_to_record,
            )
            .optional()
            .map_err(|err| sqlite_err("compensation.get", err))
    }

    /// List all records in insertion order.
    pub fn list(&self) -> Result<Vec<EngineCompensationRecord>> {
        let mut stmt = self
            .conn
            .prepare("SELECT * FROM engine_compensation_records ORDER BY rowid ASC")
            .map_err(|err| sqlite_err("compensation.list.prepare", err))?;
        let records = stmt
            .query_map([], row_to_record)
            .map_err(|err| sqlite_err("compensation.list.query", err))?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|err| sqlite_err("compensation.list.rows", err))?;
        Ok(records)
    }

    fn by_invocation(
        &self,
        invocation_id: &InvocationId,
    ) -> Result<Option<EngineCompensationRecord>> {
        self.conn
            .query_row(
                "SELECT * FROM engine_compensation_records WHERE invocation_id = ?1",
                params![invocation_id.as_str()],
                row_to_record,
            )
            .optional()
            .map_err(|err| sqlite_err("compensation.by_invocation", err))
    }
}

/// Build a compensation record.
#[must_use]
pub fn compensation_record(
    invocation: &super::invocation::Invocation,
    result: &super::invocation::InvocationResult,
    contract: CompensationContract,
    resource_lease_ids: Vec<String>,
) -> EngineCompensationRecord {
    EngineCompensationRecord {
        compensation_id: String::new(),
        invocation_id: invocation.id.clone(),
        function_id: invocation.function_id.clone(),
        function_revision: result.function_revision,
        actor_id: invocation.causal_context.actor_id.clone(),
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        trace_id: invocation.causal_context.trace_id.clone(),
        parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
        resource_lease_ids,
        contract,
        status: EngineCompensationStatus::Recorded,
        succeeded: result.error.is_none(),
        result: result.value.clone(),
        error: result
            .error
            .as_ref()
            .map(StoredEngineError::from_engine_error),
        created_at: Utc::now(),
    }
}

fn row_to_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<EngineCompensationRecord> {
    let parent: Option<String> = row.get("parent_invocation_id")?;
    let resource_lease_ids_json: String = row.get("resource_lease_ids")?;
    let contract_json: String = row.get("contract_json")?;
    let result_json: Option<String> = row.get("result_json")?;
    let error_json: Option<String> = row.get("error_json")?;
    let created_at: String = row.get("created_at")?;
    Ok(EngineCompensationRecord {
        compensation_id: row.get("compensation_id")?,
        invocation_id: InvocationId::new(row.get::<_, String>("invocation_id")?)
            .map_err(to_sql_err)?,
        function_id: FunctionId::new(row.get::<_, String>("function_id")?).map_err(to_sql_err)?,
        function_revision: FunctionRevision(row.get::<_, u64>("function_revision")?),
        actor_id: ActorId::new(row.get::<_, String>("actor_id")?).map_err(to_sql_err)?,
        authority_grant_id: AuthorityGrantId::new(row.get::<_, String>("authority_grant_id")?)
            .map_err(to_sql_err)?,
        trace_id: TraceId::new(row.get::<_, String>("trace_id")?).map_err(to_sql_err)?,
        parent_invocation_id: parent
            .map(InvocationId::new)
            .transpose()
            .map_err(to_sql_err)?,
        resource_lease_ids: from_json("compensation.resource_leases", &resource_lease_ids_json)
            .map_err(to_sql_err)?,
        contract: from_json("compensation.contract", &contract_json).map_err(to_sql_err)?,
        status: EngineCompensationStatus::parse(&row.get::<_, String>("status")?)
            .map_err(to_sql_err)?,
        succeeded: row.get::<_, i64>("succeeded")? == 1,
        result: optional_from_json("compensation.result", &result_json).map_err(to_sql_err)?,
        error: optional_from_json("compensation.error", &error_json).map_err(to_sql_err)?,
        created_at: parse_time(&created_at).map_err(to_sql_err)?,
    })
}

fn optional_json<T: Serialize>(
    operation: &'static str,
    value: &Option<T>,
) -> Result<Option<String>> {
    value
        .as_ref()
        .map(|value| to_json(operation, value))
        .transpose()
}

fn optional_from_json<T: for<'de> Deserialize<'de>>(
    operation: &'static str,
    value: &Option<String>,
) -> Result<Option<T>> {
    value
        .as_ref()
        .map(|value| from_json(operation, value))
        .transpose()
}

fn to_json<T: Serialize>(operation: &'static str, value: &T) -> Result<String> {
    serde_json::to_string(value).map_err(|err| EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    })
}

fn from_json<T: for<'de> Deserialize<'de>>(operation: &'static str, value: &str) -> Result<T> {
    serde_json::from_str(value).map_err(|err| EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    })
}

fn parse_time(value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|err| EngineError::LedgerFailure {
            operation: "compensation.parse_time",
            message: err.to_string(),
        })
}

fn sqlite_err(operation: &'static str, err: rusqlite::Error) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: err.to_string(),
    }
}

fn to_sql_err(error: EngineError) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(error))
}
