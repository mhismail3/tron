//! Trace record repository.

use rusqlite::{Connection, OptionalExtension, params};

use crate::domains::session::event_store::errors::Result;
use crate::domains::session::event_store::trace::{AgentTraceListOptions, AgentTraceRecord};

/// Stateless repository for the `trace_records` table.
pub struct TraceRepo;

impl TraceRepo {
    /// Insert a newly-started trace record.
    pub fn insert(conn: &Connection, record: &AgentTraceRecord) -> Result<()> {
        let record_json = serde_json::to_string(&record.record_json)?;
        let _ = conn.execute(
            "INSERT INTO trace_records (
                id, trace_id, invocation_id, parent_invocation_id,
                provider_invocation_id, session_id, workspace_id, turn,
                model_primitive_name, operation, status, timestamp,
                completed_at, duration_ms, record_json
             )
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
            params![
                record.id,
                record.trace_id,
                record.invocation_id,
                record.parent_invocation_id,
                record.provider_invocation_id,
                record.session_id,
                record.workspace_id,
                record.turn,
                record.model_primitive_name,
                record.operation,
                record.status,
                record.timestamp,
                record.completed_at,
                record.duration_ms,
                record_json,
            ],
        )?;
        Ok(())
    }

    /// Replace the persisted record after completion.
    pub fn update(conn: &Connection, record: &AgentTraceRecord) -> Result<bool> {
        let record_json = serde_json::to_string(&record.record_json)?;
        let changed = conn.execute(
            "UPDATE trace_records
             SET status = ?2,
                 completed_at = ?3,
                 duration_ms = ?4,
                 record_json = ?5
             WHERE id = ?1",
            params![
                record.id,
                record.status,
                record.completed_at,
                record.duration_ms,
                record_json,
            ],
        )?;
        Ok(changed > 0)
    }

    /// Get one record by id.
    pub fn get(conn: &Connection, id: &str) -> Result<Option<AgentTraceRecord>> {
        conn.query_row(
            "SELECT id, trace_id, invocation_id, parent_invocation_id,
                    provider_invocation_id, session_id, workspace_id, turn,
                    model_primitive_name, operation, status, timestamp,
                    completed_at, duration_ms, record_json
             FROM trace_records
             WHERE id = ?1",
            params![id],
            Self::map_row,
        )
        .optional()
        .map_err(Into::into)
    }

    /// List records by session and/or trace, newest first.
    pub fn list(
        conn: &Connection,
        options: &AgentTraceListOptions<'_>,
    ) -> Result<Vec<AgentTraceRecord>> {
        let limit = options.limit.unwrap_or(50).clamp(1, 500);
        match (options.session_id, options.trace_id) {
            (Some(session_id), Some(trace_id)) => {
                let mut stmt = conn.prepare(
                    "SELECT id, trace_id, invocation_id, parent_invocation_id,
                            provider_invocation_id, session_id, workspace_id, turn,
                            model_primitive_name, operation, status, timestamp,
                            completed_at, duration_ms, record_json
                     FROM trace_records
                     WHERE session_id = ?1 AND trace_id = ?2
                     ORDER BY timestamp DESC
                     LIMIT ?3",
                )?;
                let rows = stmt
                    .query_map(params![session_id, trace_id, limit], Self::map_row)?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                Ok(rows)
            }
            (Some(session_id), None) => {
                let mut stmt = conn.prepare(
                    "SELECT id, trace_id, invocation_id, parent_invocation_id,
                            provider_invocation_id, session_id, workspace_id, turn,
                            model_primitive_name, operation, status, timestamp,
                            completed_at, duration_ms, record_json
                     FROM trace_records
                     WHERE session_id = ?1
                     ORDER BY timestamp DESC
                     LIMIT ?2",
                )?;
                let rows = stmt
                    .query_map(params![session_id, limit], Self::map_row)?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                Ok(rows)
            }
            (None, Some(trace_id)) => {
                let mut stmt = conn.prepare(
                    "SELECT id, trace_id, invocation_id, parent_invocation_id,
                            provider_invocation_id, session_id, workspace_id, turn,
                            model_primitive_name, operation, status, timestamp,
                            completed_at, duration_ms, record_json
                     FROM trace_records
                     WHERE trace_id = ?1
                     ORDER BY timestamp DESC
                     LIMIT ?2",
                )?;
                let rows = stmt
                    .query_map(params![trace_id, limit], Self::map_row)?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                Ok(rows)
            }
            (None, None) => {
                let mut stmt = conn.prepare(
                    "SELECT id, trace_id, invocation_id, parent_invocation_id,
                            provider_invocation_id, session_id, workspace_id, turn,
                            model_primitive_name, operation, status, timestamp,
                            completed_at, duration_ms, record_json
                     FROM trace_records
                     ORDER BY timestamp DESC
                     LIMIT ?1",
                )?;
                let rows = stmt
                    .query_map(params![limit], Self::map_row)?
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                Ok(rows)
            }
        }
    }

    fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentTraceRecord> {
        let record_json: String = row.get(14)?;
        let record_json = serde_json::from_str(&record_json).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                14,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?;
        Ok(AgentTraceRecord {
            id: row.get(0)?,
            trace_id: row.get(1)?,
            invocation_id: row.get(2)?,
            parent_invocation_id: row.get(3)?,
            provider_invocation_id: row.get(4)?,
            session_id: row.get(5)?,
            workspace_id: row.get(6)?,
            turn: row.get(7)?,
            model_primitive_name: row.get(8)?,
            operation: row.get(9)?,
            status: row.get(10)?,
            timestamp: row.get(11)?,
            completed_at: row.get(12)?,
            duration_ms: row.get(13)?,
            record_json,
        })
    }
}
