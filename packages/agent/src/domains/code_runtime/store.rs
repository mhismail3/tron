use std::fs;
use std::path::{Path, PathBuf};

use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

use crate::shared::storage::apply_runtime_pragmas;

use super::compiler::digest;
use super::types::{CellStatus, CodeInspect, CodeRunResult, RuntimeLimits};

const RUNTIME_ABI: &str = "tron.code.v1";

#[derive(Debug, Error)]
pub(crate) enum StoreError {
    #[error("code runtime storage failed: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("code runtime storage path failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("runtime is busy with unresolved cell {0}")]
    Busy(String),
    #[error("idempotency key was reused with different source")]
    IdempotencyConflict,
    #[error("runtime journal limit reached; explicitly reset or consolidate it")]
    JournalLimit,
    #[error("durable code row is corrupt: {0}")]
    Corrupt(String),
    #[error("broker replay diverged at call {ordinal}: expected {expected}, received {actual}")]
    ReplayDiverged {
        ordinal: u64,
        expected: String,
        actual: String,
    },
}

#[derive(Debug, Clone)]
pub(crate) struct RuntimeRow {
    pub runtime_id: String,
    pub agent_id: String,
    pub epoch: u64,
}

#[derive(Debug, Clone)]
pub(crate) struct CellRow {
    pub cell_id: String,
    pub runtime_id: String,
    pub sequence: u64,
    pub source_digest: String,
    pub compiled: String,
    pub status: CellStatus,
    pub result: Option<Value>,
    pub output: Vec<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct CallRow {
    pub call_id: String,
    pub ordinal: u64,
    pub operation: String,
    pub request_json: String,
    pub request_digest: String,
    pub status: String,
    pub result: Option<Value>,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct CodeRuntimeStore {
    path: PathBuf,
}

impl CodeRuntimeStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StoreError> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let store = Self { path };
        let conn = store.connect()?;
        verify_schema(&conn)?;
        Ok(store)
    }

    fn connect(&self) -> Result<Connection, StoreError> {
        let conn = Connection::open(&self.path)?;
        apply_runtime_pragmas(&conn).map_err(|error| {
            StoreError::Corrupt(format!("could not apply SQLite runtime pragmas: {error:#}"))
        })?;
        Ok(conn)
    }

    pub fn admit_cell(
        &self,
        agent_id: &str,
        invocation_key: &str,
        assignment_id: Option<&str>,
        source: &str,
        source_digest: &str,
        compiled: &str,
        compiled_digest: &str,
        limits: &RuntimeLimits,
    ) -> Result<(RuntimeRow, CellRow, bool), StoreError> {
        let mut conn = self.connect()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let runtime = current_or_create_runtime(&tx, agent_id)?;

        if let Some(existing) = load_cell_by_invocation(&tx, &runtime.runtime_id, invocation_key)? {
            if existing.source_digest != source_digest {
                return Err(StoreError::IdempotencyConflict);
            }
            tx.commit()?;
            return Ok((runtime, existing, true));
        }

        let unresolved: Option<String> = tx
            .query_row(
                "SELECT cell_id FROM code_cells
                 WHERE runtime_id = ?1 AND status = 'running'
                 ORDER BY sequence LIMIT 1",
                [&runtime.runtime_id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(cell_id) = unresolved {
            return Err(StoreError::Busy(cell_id));
        }

        let (committed_count, journal_bytes): (i64, i64) = tx.query_row(
            "SELECT COUNT(*), COALESCE(SUM(LENGTH(compiled_text)), 0)
             FROM code_cells WHERE runtime_id = ?1 AND status = 'committed'",
            [&runtime.runtime_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if usize::try_from(committed_count).unwrap_or(usize::MAX) >= limits.max_committed_cells
            || usize::try_from(journal_bytes)
                .unwrap_or(usize::MAX)
                .saturating_add(compiled.len())
                > limits.max_journal_bytes
        {
            return Err(StoreError::JournalLimit);
        }

        let sequence: i64 = tx.query_row(
            "SELECT next_cell_sequence FROM code_runtimes WHERE runtime_id = ?1",
            [&runtime.runtime_id],
            |row| row.get(0),
        )?;
        let cell_id = Uuid::now_v7().to_string();
        let now = now();
        tx.execute(
            "INSERT INTO code_cells (
                cell_id, runtime_id, sequence, invocation_key, assignment_id,
                source_text, source_digest, compiled_text, compiled_digest,
                status, created_at, started_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'running', ?10, ?10)",
            params![
                cell_id,
                runtime.runtime_id,
                sequence,
                invocation_key,
                assignment_id,
                source,
                source_digest,
                compiled,
                compiled_digest,
                now,
            ],
        )?;
        tx.execute(
            "UPDATE code_runtimes
             SET next_cell_sequence = next_cell_sequence + 1,
                 active_cell_id = ?2, updated_at = ?3
             WHERE runtime_id = ?1",
            params![runtime.runtime_id, cell_id, now],
        )?;
        tx.execute(
            "INSERT INTO code_runtime_events (
                event_id, runtime_id, cell_id, kind, payload_json, created_at
             ) VALUES (?1, ?2, ?3, 'cell.admitted', '{}', ?4)",
            params![Uuid::now_v7().to_string(), runtime.runtime_id, cell_id, now],
        )?;
        let cell = load_cell(&tx, &cell_id)?.ok_or_else(|| {
            StoreError::Corrupt("admitted cell disappeared before commit".to_owned())
        })?;
        tx.commit()?;
        Ok((runtime, cell, false))
    }

    pub fn committed_cells(&self, runtime_id: &str) -> Result<Vec<CellRow>, StoreError> {
        let conn = self.connect()?;
        let mut statement = conn.prepare(
            "SELECT cell_id, runtime_id, sequence, source_digest,
                    compiled_text, status, result_json, output_json, error_text
             FROM code_cells
             WHERE runtime_id = ?1 AND status = 'committed'
             ORDER BY sequence",
        )?;
        let rows = statement
            .query_map([runtime_id], cell_from_row)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn finish_cell(
        &self,
        cell_id: &str,
        status: CellStatus,
        result: Option<&Value>,
        output: &[String],
        error: Option<&str>,
    ) -> Result<CellRow, StoreError> {
        debug_assert!(status != CellStatus::Running);
        let mut conn = self.connect()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let runtime_id: String = tx.query_row(
            "SELECT runtime_id FROM code_cells WHERE cell_id = ?1",
            [cell_id],
            |row| row.get(0),
        )?;
        let result_json = result.map(canonical_json).transpose()?;
        let output_json = canonical_json(&serde_json::to_value(output).map_err(|error| {
            StoreError::Corrupt(format!("could not serialize output: {error}"))
        })?)?;
        let now = now();
        tx.execute(
            "UPDATE code_cells
             SET status = ?2, result_json = ?3, output_json = ?4,
                 error_text = ?5, completed_at = ?6
             WHERE cell_id = ?1 AND status = 'running'",
            params![
                cell_id,
                status.as_str(),
                result_json,
                output_json,
                error,
                now,
            ],
        )?;
        tx.execute(
            "UPDATE code_runtimes
             SET active_cell_id = CASE WHEN active_cell_id = ?2 THEN NULL ELSE active_cell_id END,
                 updated_at = ?3
             WHERE runtime_id = ?1",
            params![runtime_id, cell_id, now],
        )?;
        tx.execute(
            "INSERT INTO code_runtime_events (
                event_id, runtime_id, cell_id, kind, payload_json, created_at
             ) VALUES (?1, ?2, ?3, ?4, '{}', ?5)",
            params![
                Uuid::now_v7().to_string(),
                runtime_id,
                cell_id,
                format!("cell.{}", status.as_str()),
                now,
            ],
        )?;
        let row = load_cell(&tx, cell_id)?
            .ok_or_else(|| StoreError::Corrupt("terminalized cell disappeared".to_owned()))?;
        tx.commit()?;
        Ok(row)
    }

    pub fn load_call(&self, cell_id: &str, ordinal: u64) -> Result<Option<CallRow>, StoreError> {
        let conn = self.connect()?;
        conn.query_row(
            "SELECT call_id, call_ordinal, operation, request_json, request_digest,
                    status, result_json, error_text
             FROM code_calls WHERE cell_id = ?1 AND call_ordinal = ?2",
            params![cell_id, i64::try_from(ordinal).unwrap_or(i64::MAX)],
            call_from_row,
        )
        .optional()
        .map_err(StoreError::from)
    }

    pub fn calls_for_cell(&self, cell_id: &str) -> Result<Vec<CallRow>, StoreError> {
        let conn = self.connect()?;
        let mut statement = conn.prepare(
            "SELECT call_id, call_ordinal, operation, request_json, request_digest,
                    status, result_json, error_text
             FROM code_calls WHERE cell_id = ?1 ORDER BY call_ordinal",
        )?;
        statement
            .query_map([cell_id], call_from_row)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }

    pub fn admit_call(
        &self,
        cell_id: &str,
        ordinal: u64,
        operation: &str,
        request: &Value,
    ) -> Result<CallRow, StoreError> {
        let request_json = canonical_json(request)?;
        let request_digest = digest(request_json.as_bytes());
        let call_id = Uuid::now_v7().to_string();
        let conn = self.connect()?;
        conn.execute(
            "INSERT OR IGNORE INTO code_calls (
                call_id, cell_id, call_ordinal, operation, request_json,
                request_digest, status, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'admitted', ?7)",
            params![
                call_id,
                cell_id,
                i64::try_from(ordinal).unwrap_or(i64::MAX),
                operation,
                request_json,
                request_digest,
                now(),
            ],
        )?;
        self.load_call(cell_id, ordinal)?
            .ok_or_else(|| StoreError::Corrupt("admitted broker call disappeared".to_owned()))
    }

    pub fn finish_call(
        &self,
        call_id: &str,
        result: Result<&Value, &str>,
    ) -> Result<CallRow, StoreError> {
        let conn = self.connect()?;
        let (status, result_json, error_text) = match result {
            Ok(value) => ("completed", Some(canonical_json(value)?), None),
            Err(error) => ("failed", None, Some(error)),
        };
        conn.execute(
            "UPDATE code_calls
             SET status = ?2, result_json = ?3, error_text = ?4, completed_at = ?5
             WHERE call_id = ?1",
            params![call_id, status, result_json, error_text, now()],
        )?;
        conn.query_row(
            "SELECT call_id, call_ordinal, operation, request_json, request_digest,
                    status, result_json, error_text
             FROM code_calls WHERE call_id = ?1",
            [call_id],
            call_from_row,
        )
        .map_err(StoreError::from)
    }

    pub fn verify_call(
        &self,
        row: &CallRow,
        operation: &str,
        request: &Value,
    ) -> Result<(), StoreError> {
        let request_json = canonical_json(request)?;
        let actual = format!("{}:{}", operation, digest(request_json.as_bytes()));
        let expected = format!("{}:{}", row.operation, row.request_digest);
        if operation != row.operation || request_json != row.request_json {
            return Err(StoreError::ReplayDiverged {
                ordinal: row.ordinal,
                expected,
                actual,
            });
        }
        Ok(())
    }

    pub fn inspect(
        &self,
        agent_id: &str,
        limits: &RuntimeLimits,
    ) -> Result<CodeInspect, StoreError> {
        let conn = self.connect()?;
        let runtime: Option<(String, i64, Option<String>)> = conn
            .query_row(
                "SELECT runtime_id, epoch, active_cell_id FROM code_runtimes
                 WHERE agent_id = ?1 AND is_current = 1",
                [agent_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        let Some((runtime_id, epoch, unresolved)) = runtime else {
            return Ok(CodeInspect {
                agent_id: agent_id.to_owned(),
                runtime_id: None,
                epoch: 0,
                committed_cells: 0,
                journal_bytes: 0,
                unresolved_cell_id: None,
                journal_limit_reached: false,
            });
        };
        let (count, bytes): (i64, i64) = conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(LENGTH(compiled_text)), 0)
             FROM code_cells WHERE runtime_id = ?1 AND status = 'committed'",
            [&runtime_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let committed_cells = usize::try_from(count).unwrap_or(usize::MAX);
        let journal_bytes = usize::try_from(bytes).unwrap_or(usize::MAX);
        Ok(CodeInspect {
            agent_id: agent_id.to_owned(),
            runtime_id: Some(runtime_id),
            epoch: u64::try_from(epoch).unwrap_or_default(),
            committed_cells,
            journal_bytes,
            unresolved_cell_id: unresolved,
            journal_limit_reached: committed_cells >= limits.max_committed_cells
                || journal_bytes >= limits.max_journal_bytes,
        })
    }

    pub fn reset(&self, agent_id: &str) -> Result<RuntimeRow, StoreError> {
        let mut conn = self.connect()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let active: Option<String> = tx
            .query_row(
                "SELECT active_cell_id FROM code_runtimes
                 WHERE agent_id = ?1 AND is_current = 1",
                [agent_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        if let Some(cell_id) = active {
            return Err(StoreError::Busy(cell_id));
        }
        tx.execute(
            "UPDATE code_runtimes SET is_current = 0, state = 'retired', updated_at = ?2
             WHERE agent_id = ?1 AND is_current = 1",
            params![agent_id, now()],
        )?;
        let epoch: i64 = tx.query_row(
            "SELECT COALESCE(MAX(epoch), -1) + 1 FROM code_runtimes WHERE agent_id = ?1",
            [agent_id],
            |row| row.get(0),
        )?;
        let runtime = insert_runtime(&tx, agent_id, epoch)?;
        tx.commit()?;
        Ok(runtime)
    }
}

impl CellRow {
    pub fn as_result(&self, runtime: &RuntimeRow, replayed: bool) -> CodeRunResult {
        CodeRunResult {
            runtime_id: runtime.runtime_id.clone(),
            epoch: runtime.epoch,
            cell_id: self.cell_id.clone(),
            sequence: self.sequence,
            status: self.status,
            value: self.result.clone(),
            output: self.output.clone(),
            error: self.error.clone(),
            replayed,
        }
    }
}

fn verify_schema(conn: &Connection) -> Result<(), StoreError> {
    // INVARIANT: the EventStore current schema is the only schema author. The
    // code runtime may share `tron.sqlite`, but must never install a private
    // competing table shape when opened independently.
    for object in [
        "code_runtimes",
        "code_cells",
        "code_calls",
        "code_runtime_events",
        "idx_code_runtime_current",
        "idx_code_cells_runtime_status",
        "idx_code_runtime_events_runtime",
    ] {
        let present: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name=?1)",
            [object],
            |row| row.get(0),
        )?;
        if !present {
            return Err(StoreError::Corrupt(format!(
                "canonical EventStore schema is missing {object}"
            )));
        }
    }
    Ok(())
}

fn current_or_create_runtime(
    tx: &rusqlite::Transaction<'_>,
    agent_id: &str,
) -> Result<RuntimeRow, StoreError> {
    if let Some(runtime) = tx
        .query_row(
            "SELECT runtime_id, agent_id, epoch FROM code_runtimes
             WHERE agent_id = ?1 AND is_current = 1",
            [agent_id],
            |row| {
                Ok(RuntimeRow {
                    runtime_id: row.get(0)?,
                    agent_id: row.get(1)?,
                    epoch: u64::try_from(row.get::<_, i64>(2)?).unwrap_or_default(),
                })
            },
        )
        .optional()?
    {
        return Ok(runtime);
    }
    let epoch: i64 = tx.query_row(
        "SELECT COALESCE(MAX(epoch), -1) + 1 FROM code_runtimes WHERE agent_id = ?1",
        [agent_id],
        |row| row.get(0),
    )?;
    insert_runtime(tx, agent_id, epoch)
}

fn insert_runtime(
    tx: &rusqlite::Transaction<'_>,
    agent_id: &str,
    epoch: i64,
) -> Result<RuntimeRow, StoreError> {
    let runtime_id = Uuid::now_v7().to_string();
    let now = now();
    tx.execute(
        "INSERT INTO code_runtimes (
            runtime_id, agent_id, epoch, is_current, state, runtime_abi, created_at, updated_at
         ) VALUES (?1, ?2, ?3, 1, 'ready', ?4, ?5, ?5)",
        params![runtime_id, agent_id, epoch, RUNTIME_ABI, now],
    )?;
    Ok(RuntimeRow {
        runtime_id,
        agent_id: agent_id.to_owned(),
        epoch: u64::try_from(epoch).unwrap_or_default(),
    })
}

fn load_cell_by_invocation(
    conn: &Connection,
    runtime_id: &str,
    invocation_key: &str,
) -> Result<Option<CellRow>, StoreError> {
    conn.query_row(
        "SELECT cell_id, runtime_id, sequence, source_digest,
                compiled_text, status, result_json, output_json, error_text
         FROM code_cells WHERE runtime_id = ?1 AND invocation_key = ?2",
        params![runtime_id, invocation_key],
        cell_from_row,
    )
    .optional()
    .map_err(StoreError::from)
}

fn load_cell(conn: &Connection, cell_id: &str) -> Result<Option<CellRow>, StoreError> {
    conn.query_row(
        "SELECT cell_id, runtime_id, sequence, source_digest,
                compiled_text, status, result_json, output_json, error_text
         FROM code_cells WHERE cell_id = ?1",
        [cell_id],
        cell_from_row,
    )
    .optional()
    .map_err(StoreError::from)
}

fn cell_from_row(row: &rusqlite::Row<'_>) -> Result<CellRow, rusqlite::Error> {
    let status_text: String = row.get(5)?;
    let status = CellStatus::parse(&status_text).ok_or_else(|| {
        rusqlite::Error::InvalidColumnType(5, "status".to_owned(), rusqlite::types::Type::Text)
    })?;
    let result_json: Option<String> = row.get(6)?;
    let output_json: String = row.get(7)?;
    Ok(CellRow {
        cell_id: row.get(0)?,
        runtime_id: row.get(1)?,
        sequence: u64::try_from(row.get::<_, i64>(2)?).unwrap_or_default(),
        source_digest: row.get(3)?,
        compiled: row.get(4)?,
        status,
        result: result_json
            .map(|value| serde_json::from_str(&value))
            .transpose()
            .map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    6,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })?,
        output: serde_json::from_str(&output_json).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                7,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?,
        error: row.get(8)?,
    })
}

fn call_from_row(row: &rusqlite::Row<'_>) -> Result<CallRow, rusqlite::Error> {
    let result_json: Option<String> = row.get(6)?;
    Ok(CallRow {
        call_id: row.get(0)?,
        ordinal: u64::try_from(row.get::<_, i64>(1)?).unwrap_or_default(),
        operation: row.get(2)?,
        request_json: row.get(3)?,
        request_digest: row.get(4)?,
        status: row.get(5)?,
        result: result_json
            .map(|value| serde_json::from_str(&value))
            .transpose()
            .map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    6,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })?,
        error: row.get(7)?,
    })
}

fn canonical_json(value: &Value) -> Result<String, StoreError> {
    serde_json::to_string(value)
        .map_err(|error| StoreError::Corrupt(format!("JSON serialization failed: {error}")))
}

fn now() -> String {
    Utc::now().to_rfc3339()
}
