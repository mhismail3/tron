//! SQLite-backed engine stream store.

use std::path::Path;

use chrono::Utc;
use rusqlite::{Connection, params};

use super::{
    EngineStreamEvent, EngineStreamPage, PublishStreamEvent, StreamActorScope, StreamCursor,
    row_to_stream_event, sqlite_err, stream_scope_visible,
};
use crate::engine::kernel::errors::{EngineError, Result};

/// SQLite-backed stream store.
pub struct SqliteEngineStreamStore {
    conn: Connection,
}

impl SqliteEngineStreamStore {
    /// Open a stream store in the engine ledger database.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn =
            Connection::open(path).map_err(|err| sqlite_err("stream.open", err.to_string()))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        crate::shared::storage::apply_runtime_pragmas(&self.conn)
            .map_err(|err| sqlite_err("stream.storage_pragmas", err.to_string()))?;
        crate::shared::storage::ensure_storage_schema(&self.conn)
            .map_err(|err| sqlite_err("stream.storage_schema", err.to_string()))?;
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS engine_stream_events (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT,
  topic TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  visibility TEXT NOT NULL,
  session_id TEXT,
  workspace_id TEXT,
  producer TEXT NOT NULL,
  trace_id TEXT,
  parent_invocation_id TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_engine_stream_events_trace
  ON engine_stream_events(trace_id, cursor);
"#,
            )
            .map_err(|err| sqlite_err("stream.init", err.to_string()))
    }

    /// Borrow the underlying connection for focused tests.
    #[cfg(test)]
    #[must_use]
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    /// Publish one event and return its cursor.
    pub fn publish(&mut self, event: PublishStreamEvent) -> Result<StreamCursor> {
        if event.topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        let owner_id = format!("stream_event_{}", uuid::Uuid::now_v7());
        let payload = crate::shared::storage::store_json_value(
            &self.conn,
            &event.payload,
            &crate::shared::storage::StorePayloadOptions::new(
                "engine_stream_event",
                owner_id,
                "payload",
                "runtime",
            )
            .with_scope(
                event.trace_id.as_ref().map(ToString::to_string),
                event.session_id.clone(),
                event.workspace_id.clone(),
            ),
        )
        .map_err(|err| sqlite_err("stream.event.payload", err.to_string()))?;
        self.conn
            .execute(
                "INSERT INTO engine_stream_events
                 (topic, payload_json, visibility, session_id, workspace_id, producer, trace_id, parent_invocation_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    event.topic,
                    payload,
                    event.visibility.as_str(),
                    event.session_id,
                    event.workspace_id,
                    event.producer,
                    event.trace_id.map(|id| id.to_string()),
                    event.parent_invocation_id.map(|id| id.to_string()),
                    Utc::now().to_rfc3339(),
                ],
            )
            .map_err(|err| sqlite_err("stream.publish", err.to_string()))?;
        Ok(StreamCursor(self.conn.last_insert_rowid() as u64))
    }

    /// Return the latest cursor assigned for a topic.
    pub fn latest_cursor(&self, topic: &str) -> Result<StreamCursor> {
        let cursor = self
            .conn
            .query_row(
                "SELECT COALESCE(MAX(cursor), 0)
                 FROM engine_stream_events
                 WHERE topic = ?1",
                params![topic],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|err| sqlite_err("stream.latest_cursor", err.to_string()))?;
        Ok(StreamCursor(cursor as u64))
    }

    /// Poll a topic directly from an explicit cursor without durable subscriber state.
    pub(crate) fn poll_topic(
        &self,
        topic: &str,
        after: StreamCursor,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        if topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "stream poll limit must be greater than zero".to_owned(),
            ));
        }
        let mut stmt = self
            .conn
            .prepare(
                "SELECT cursor, topic, payload_json, visibility, session_id, workspace_id,
                        producer, trace_id, parent_invocation_id, created_at
                 FROM engine_stream_events
                 WHERE topic = ?1
                   AND cursor > ?2
                   AND (
                     ?4 = 1
                     OR visibility = 'system'
                     OR (visibility = 'session' AND session_id = ?3)
                   )
                 ORDER BY cursor ASC
                 LIMIT ?5",
            )
            .map_err(|err| sqlite_err("stream.poll.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(
                params![
                    topic,
                    after.0 as i64,
                    actor.session_id.as_deref(),
                    if actor.all_sessions { 1_i64 } else { 0_i64 },
                    limit.min(500) as i64 + 1
                ],
                |row| row_to_stream_event(&self.conn, row),
            )
            .map_err(|err| sqlite_err("stream.poll.query", err.to_string()))?;
        let limit = limit.min(500);
        let mut events = Vec::new();
        let mut next_cursor = after;
        let mut has_more = false;
        for (index, row) in rows.enumerate() {
            let event = row.map_err(|err| sqlite_err("stream.poll.row", err.to_string()))?;
            if index >= limit {
                has_more = true;
                break;
            }
            next_cursor = event.cursor;
            if stream_scope_visible(&event.visibility, event.session_id.as_deref(), actor) {
                events.push(event);
            }
        }
        Ok(EngineStreamPage {
            events,
            next_cursor,
            has_more,
        })
    }

    /// List stream records scoped to one session for replay.
    pub fn list_by_session(&self, session_id: &str) -> Result<Vec<EngineStreamEvent>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT cursor, topic, payload_json, visibility, session_id, workspace_id,
                        producer, trace_id, parent_invocation_id, created_at
                 FROM engine_stream_events
                 WHERE session_id = ?1
                 ORDER BY cursor ASC",
            )
            .map_err(|err| sqlite_err("stream.list_by_session.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![session_id], |row| {
                row_to_stream_event(&self.conn, row)
            })
            .map_err(|err| sqlite_err("stream.list_by_session.query", err.to_string()))?;
        let mut events = Vec::new();
        for row in rows {
            events.push(
                row.map_err(|err| sqlite_err("stream.list_by_session.row", err.to_string()))?,
            );
        }
        Ok(events)
    }
}
