//! SQLite-backed engine queue store.

use std::path::Path;

use chrono::{Duration, Utc};
use rusqlite::{Connection, OptionalExtension, params};

use super::sqlite_codec::{item_params, row_to_queue_item, sqlite_err, validate_queue};
use super::{
    EngineQueueAttemptRecord, EngineQueueItem, EnqueueInvocation, QueueAttemptOutcome,
    QueueItemStatus,
};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::InvocationId;

/// SQLite queue store.
pub struct SqliteEngineQueueStore {
    conn: Connection,
}

impl SqliteEngineQueueStore {
    /// Open a queue store in the engine ledger database.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn =
            Connection::open(path).map_err(|err| sqlite_err("queue.open", err.to_string()))?;
        let store = Self { conn };
        store.init()?;
        Ok(store)
    }

    fn init(&self) -> Result<()> {
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS engine_queue_items (
  receipt_id TEXT PRIMARY KEY,
  queue TEXT NOT NULL,
  function_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_kind TEXT NOT NULL,
  authority_grant_id TEXT NOT NULL,
  authority_scopes_json TEXT NOT NULL,
  trace_id TEXT NOT NULL,
  parent_invocation_id TEXT,
  trigger_id TEXT,
  session_id TEXT,
  workspace_id TEXT,
  idempotency_key TEXT,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  lease_owner TEXT,
  lease_expires_at TEXT,
  not_before TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  runtime_metadata_json TEXT NOT NULL DEFAULT '{}',
  attempt_records_json TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX IF NOT EXISTS idx_engine_queue_items_trace
  ON engine_queue_items(trace_id, created_at);
"#,
            )
            .map_err(|err| sqlite_err("queue.init", err.to_string()))
            .and_then(|_| self.ensure_runtime_metadata_column())
            .and_then(|_| self.ensure_attempt_records_column())
    }

    fn ensure_runtime_metadata_column(&self) -> Result<()> {
        let mut stmt = self
            .conn
            .prepare("PRAGMA table_info(engine_queue_items)")
            .map_err(|err| sqlite_err("queue.schema.prepare", err.to_string()))?;
        let columns = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|err| sqlite_err("queue.schema.query", err.to_string()))?;
        for column in columns {
            if column.map_err(|err| sqlite_err("queue.schema.row", err.to_string()))?
                == "runtime_metadata_json"
            {
                return Ok(());
            }
        }
        self.conn
            .execute(
                "ALTER TABLE engine_queue_items ADD COLUMN runtime_metadata_json TEXT NOT NULL DEFAULT '{}'",
                [],
            )
            .map_err(|err| sqlite_err("queue.schema.alter_runtime_metadata", err.to_string()))?;
        Ok(())
    }

    fn ensure_attempt_records_column(&self) -> Result<()> {
        let mut stmt = self
            .conn
            .prepare("PRAGMA table_info(engine_queue_items)")
            .map_err(|err| sqlite_err("queue.schema.prepare", err.to_string()))?;
        let columns = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|err| sqlite_err("queue.schema.query", err.to_string()))?;
        for column in columns {
            if column.map_err(|err| sqlite_err("queue.schema.row", err.to_string()))?
                == "attempt_records_json"
            {
                return Ok(());
            }
        }
        self.conn
            .execute(
                "ALTER TABLE engine_queue_items ADD COLUMN attempt_records_json TEXT NOT NULL DEFAULT '[]'",
                [],
            )
            .map_err(|err| sqlite_err("queue.schema.alter_attempt_records", err.to_string()))?;
        Ok(())
    }

    /// Borrow the underlying connection for focused tests.
    #[cfg(test)]
    #[must_use]
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    /// Enqueue one invocation.
    pub fn enqueue(&mut self, request: EnqueueInvocation) -> Result<EngineQueueItem> {
        validate_queue(&request.queue)?;
        let now = Utc::now();
        let item = EngineQueueItem {
            receipt_id: InvocationId::generate().to_string(),
            queue: request.queue,
            function_id: request.function_id,
            payload: request.payload,
            actor_id: request.actor_id,
            actor_kind: request.actor_kind,
            authority_grant_id: request.authority_grant_id,
            authority_scopes: request.authority_scopes,
            runtime_metadata: request.runtime_metadata,
            trace_id: request.trace_id,
            parent_invocation_id: request.parent_invocation_id,
            trigger_id: request.trigger_id,
            session_id: request.session_id,
            workspace_id: request.workspace_id,
            idempotency_key: request.idempotency_key,
            status: QueueItemStatus::Ready,
            attempts: 0,
            attempt_records: Vec::new(),
            lease_owner: None,
            lease_expires_at: None,
            not_before: now,
            created_at: now,
            updated_at: now,
        };
        self.insert_item(&item)?;
        Ok(item)
    }

    /// Claim the next ready item.
    pub fn claim(
        &mut self,
        queue: &str,
        lease_owner: &str,
        lease_ms: i64,
    ) -> Result<Option<EngineQueueItem>> {
        validate_queue(queue)?;
        if lease_owner.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "queue lease owner must not be empty".to_owned(),
            ));
        }
        let now = Utc::now();
        let item = self
            .conn
            .query_row(
                "SELECT * FROM engine_queue_items
                 WHERE queue = ?1
                   AND status IN ('ready', 'leased')
                   AND not_before <= ?2
                   AND (status = 'ready' OR lease_expires_at IS NULL OR lease_expires_at <= ?2)
                 ORDER BY created_at ASC
                 LIMIT 1",
                params![queue, now.to_rfc3339()],
                |row| row_to_queue_item(&self.conn, row),
            )
            .optional()
            .map_err(|err| sqlite_err("queue.claim.select", err.to_string()))?;
        let Some(mut item) = item else {
            return Ok(None);
        };
        item.status = QueueItemStatus::Leased;
        item.lease_owner = Some(lease_owner.to_owned());
        item.lease_expires_at = Some(now + Duration::milliseconds(lease_ms.max(1)));
        item.updated_at = now;
        self.update_item(&item)?;
        Ok(Some(item))
    }

    /// Claim a specific ready or expired-leased item by receipt.
    pub fn claim_by_receipt(
        &mut self,
        receipt_id: &str,
        lease_owner: &str,
        lease_ms: i64,
    ) -> Result<Option<EngineQueueItem>> {
        if lease_owner.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "queue lease owner must not be empty".to_owned(),
            ));
        }
        let now = Utc::now();
        let Some(mut item) = self.get(receipt_id)? else {
            return Ok(None);
        };
        if !matches!(
            item.status,
            QueueItemStatus::Ready | QueueItemStatus::Leased
        ) || item.not_before > now
            || (item.status == QueueItemStatus::Leased
                && item
                    .lease_expires_at
                    .map(|expiry| expiry > now)
                    .unwrap_or(false))
        {
            return Ok(None);
        }
        item.status = QueueItemStatus::Leased;
        item.lease_owner = Some(lease_owner.to_owned());
        item.lease_expires_at = Some(now + Duration::milliseconds(lease_ms.max(1)));
        item.updated_at = now;
        self.update_item(&item)?;
        Ok(Some(item))
    }

    /// Complete one queue item.
    pub fn complete(&mut self, receipt_id: &str) -> Result<bool> {
        self.complete_with_attempt(receipt_id, None)
    }

    /// Complete one queue item and append an attempt record.
    pub fn complete_with_attempt(
        &mut self,
        receipt_id: &str,
        attempt: Option<EngineQueueAttemptRecord>,
    ) -> Result<bool> {
        let Some(mut item) = self.get(receipt_id)? else {
            return Ok(false);
        };
        if matches!(
            item.status,
            QueueItemStatus::Cancelled | QueueItemStatus::DeadLettered
        ) {
            return Ok(false);
        }
        item.status = QueueItemStatus::Completed;
        item.lease_owner = None;
        item.lease_expires_at = None;
        if let Some(attempt) = attempt {
            item.attempt_records.push(attempt);
        }
        item.updated_at = Utc::now();
        self.update_item(&item)?;
        Ok(true)
    }

    /// Fail one queue item, retrying until `max_attempts`.
    pub fn fail(&mut self, receipt_id: &str, max_attempts: u32, backoff_ms: i64) -> Result<bool> {
        self.fail_with_attempt(receipt_id, max_attempts, backoff_ms, None)
    }

    /// Fail one queue item and append an attempt record.
    pub fn fail_with_attempt(
        &mut self,
        receipt_id: &str,
        max_attempts: u32,
        backoff_ms: i64,
        attempt: Option<EngineQueueAttemptRecord>,
    ) -> Result<bool> {
        let Some(mut item) = self.get(receipt_id)? else {
            return Ok(false);
        };
        if matches!(
            item.status,
            QueueItemStatus::Completed | QueueItemStatus::Cancelled | QueueItemStatus::DeadLettered
        ) {
            return Ok(false);
        }
        item.attempts = item.attempts.saturating_add(1);
        item.lease_owner = None;
        item.lease_expires_at = None;
        item.status = if item.attempts >= max_attempts {
            QueueItemStatus::DeadLettered
        } else {
            QueueItemStatus::Ready
        };
        if let Some(mut attempt) = attempt {
            attempt.attempt = item.attempts;
            if item.status == QueueItemStatus::DeadLettered {
                attempt.outcome = QueueAttemptOutcome::DeadLettered;
            }
            item.attempt_records.push(attempt);
        }
        item.not_before = Utc::now() + Duration::milliseconds(backoff_ms.max(0));
        item.updated_at = Utc::now();
        self.update_item(&item)?;
        Ok(true)
    }

    /// Cancel one queue item.
    pub fn cancel(&mut self, receipt_id: &str) -> Result<bool> {
        let Some(mut item) = self.get(receipt_id)? else {
            return Ok(false);
        };
        if matches!(
            item.status,
            QueueItemStatus::Completed | QueueItemStatus::DeadLettered
        ) {
            return Ok(false);
        }
        item.status = QueueItemStatus::Cancelled;
        item.lease_owner = None;
        item.lease_expires_at = None;
        item.updated_at = Utc::now();
        self.update_item(&item)?;
        Ok(true)
    }

    /// Get one item.
    pub fn get(&self, receipt_id: &str) -> Result<Option<EngineQueueItem>> {
        self.conn
            .query_row(
                "SELECT * FROM engine_queue_items WHERE receipt_id = ?1",
                params![receipt_id],
                |row| row_to_queue_item(&self.conn, row),
            )
            .optional()
            .map_err(|err| sqlite_err("queue.get", err.to_string()))
    }

    /// List queue items.
    pub fn list(&self, queue: &str, limit: usize) -> Result<Vec<EngineQueueItem>> {
        validate_queue(queue)?;
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "queue list limit must be greater than zero".to_owned(),
            ));
        }
        let mut stmt = self
            .conn
            .prepare("SELECT * FROM engine_queue_items WHERE queue = ?1 ORDER BY created_at ASC LIMIT ?2")
            .map_err(|err| sqlite_err("queue.list.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![queue, limit.min(500) as i64], |row| {
                row_to_queue_item(&self.conn, row)
            })
            .map_err(|err| sqlite_err("queue.list.query", err.to_string()))?;
        rows.map(|row| row.map_err(|err| sqlite_err("queue.list.row", err.to_string())))
            .collect()
    }

    /// List queue items that belong to one trace.
    pub fn list_by_trace(&self, trace_id: &str, limit: usize) -> Result<Vec<EngineQueueItem>> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "queue list limit must be greater than zero".to_owned(),
            ));
        }
        let mut stmt = self
            .conn
            .prepare(
                "SELECT * FROM engine_queue_items
                 WHERE trace_id = ?1
                 ORDER BY created_at ASC
                 LIMIT ?2",
            )
            .map_err(|err| sqlite_err("queue.list_by_trace.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![trace_id, limit.min(500) as i64], |row| {
                row_to_queue_item(&self.conn, row)
            })
            .map_err(|err| sqlite_err("queue.list_by_trace.query", err.to_string()))?;
        rows.map(|row| row.map_err(|err| sqlite_err("queue.list_by_trace.row", err.to_string())))
            .collect()
    }

    /// List queue items scoped to one session for replay.
    pub fn list_by_session(&self, session_id: &str) -> Result<Vec<EngineQueueItem>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT * FROM engine_queue_items
                 WHERE session_id = ?1
                 ORDER BY queue ASC, created_at ASC, receipt_id ASC",
            )
            .map_err(|err| sqlite_err("queue.list_by_session.prepare", err.to_string()))?;
        let rows = stmt
            .query_map(params![session_id], |row| {
                row_to_queue_item(&self.conn, row)
            })
            .map_err(|err| sqlite_err("queue.list_by_session.query", err.to_string()))?;
        rows.map(|row| row.map_err(|err| sqlite_err("queue.list_by_session.row", err.to_string())))
            .collect()
    }

    fn insert_item(&mut self, item: &EngineQueueItem) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_queue_items (
                   receipt_id, queue, function_id, payload_json,
                   actor_id, actor_kind, authority_grant_id, authority_scopes_json,
                   trace_id, parent_invocation_id, trigger_id, session_id, workspace_id,
                   idempotency_key, status, attempts, lease_owner, lease_expires_at,
                   not_before, created_at, updated_at, runtime_metadata_json,
                   attempt_records_json
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                           ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23)",
                item_params(&self.conn, item)?,
            )
            .map_err(|err| sqlite_err("queue.insert", err.to_string()))?;
        Ok(())
    }

    fn update_item(&mut self, item: &EngineQueueItem) -> Result<()> {
        self.conn
            .execute(
                "UPDATE engine_queue_items SET
                   queue = ?2,
                   function_id = ?3,
                   payload_json = ?4,
                   actor_id = ?5,
                   actor_kind = ?6,
                   authority_grant_id = ?7,
                   authority_scopes_json = ?8,
                   trace_id = ?9,
                   parent_invocation_id = ?10,
                   trigger_id = ?11,
                   session_id = ?12,
                   workspace_id = ?13,
                   idempotency_key = ?14,
                   status = ?15,
                   attempts = ?16,
                   lease_owner = ?17,
                   lease_expires_at = ?18,
                   not_before = ?19,
                   created_at = ?20,
                   updated_at = ?21,
                   runtime_metadata_json = ?22,
                   attempt_records_json = ?23
                 WHERE receipt_id = ?1",
                item_params(&self.conn, item)?,
            )
            .map_err(|err| sqlite_err("queue.update", err.to_string()))?;
        Ok(())
    }
}
