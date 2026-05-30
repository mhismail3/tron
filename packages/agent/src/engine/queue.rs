//! Engine queue primitive.
//!
//! Queues provide durable at-least-once handoff for engine invocations. The
//! primitive stores invocation payload plus causality so a later drain can
//! invoke the same function with the original authority and trace context. A
//! retried queue item keeps the original logical idempotency key on the item,
//! but executes retry attempts with attempt-scoped target keys so a stored
//! handler failure does not turn into a permanent replay result. Queue failure
//! lifecycle events are emitted from the post-fail item state, so stream
//! subscribers see the authoritative retry/dead-letter status and attempt count.
//! Cancellation is terminal for an in-flight item: the queue clears the lease,
//! publishes cancellation, and a late target result cannot complete or fail the
//! cancelled receipt.
//! Worker transport loss before a non-mutating queued target returns is treated
//! as delivery failure: the queue publishes retry state, but the target
//! invocation ledger does not record an application-level handler failure.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Duration, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::discovery::ActorKind;
use super::errors::{EngineError, Result};
use super::host::EngineHostHandle;
use super::ids::{ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId};
use super::invocation::{CausalContext, Invocation, InvocationResult};
use super::types::{DeliveryMode, FunctionRevision};

/// Queue item lifecycle.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QueueItemStatus {
    /// Ready to be claimed.
    Ready,
    /// Claimed by a worker until the lease expires.
    Leased,
    /// Completed.
    Completed,
    /// Cancelled before completion.
    Cancelled,
    /// Dead-lettered after retry exhaustion.
    DeadLettered,
}

impl QueueItemStatus {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Leased => "leased",
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
            Self::DeadLettered => "dead_lettered",
        }
    }
}

/// Durable queued engine invocation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineQueueItem {
    /// Receipt id returned to enqueue caller.
    pub receipt_id: String,
    /// Queue name.
    pub queue: String,
    /// Target function id.
    pub function_id: FunctionId,
    /// Target revision captured by the trigger, if any.
    pub target_revision: Option<FunctionRevision>,
    /// Payload to invoke.
    pub payload: Value,
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant.
    pub authority_grant_id: AuthorityGrantId,
    /// Authority scopes.
    pub authority_scopes: Vec<String>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Parent invocation id.
    pub parent_invocation_id: Option<InvocationId>,
    /// Trigger id.
    pub trigger_id: Option<TriggerId>,
    /// Session id.
    pub session_id: Option<String>,
    /// Workspace id.
    pub workspace_id: Option<String>,
    /// Idempotency key for the target invocation.
    pub idempotency_key: Option<String>,
    /// Status.
    pub status: QueueItemStatus,
    /// Number of failed attempts.
    pub attempts: u32,
    /// Current lease owner.
    pub lease_owner: Option<String>,
    /// Current lease expiry.
    pub lease_expires_at: Option<DateTime<Utc>>,
    /// Next time the item may be claimed.
    pub not_before: DateTime<Utc>,
    /// Creation time.
    pub created_at: DateTime<Utc>,
    /// Last update time.
    pub updated_at: DateTime<Utc>,
}

/// Request to enqueue one invocation.
#[derive(Clone, Debug, PartialEq)]
pub struct EnqueueInvocation {
    /// Queue name.
    pub queue: String,
    /// Target function id.
    pub function_id: FunctionId,
    /// Target revision.
    pub target_revision: Option<FunctionRevision>,
    /// Payload.
    pub payload: Value,
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant.
    pub authority_grant_id: AuthorityGrantId,
    /// Authority scopes.
    pub authority_scopes: Vec<String>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Parent invocation id.
    pub parent_invocation_id: Option<InvocationId>,
    /// Trigger id.
    pub trigger_id: Option<TriggerId>,
    /// Session id.
    pub session_id: Option<String>,
    /// Workspace id.
    pub workspace_id: Option<String>,
    /// Idempotency key.
    pub idempotency_key: Option<String>,
}

/// In-memory queue store.
#[derive(Default)]
pub struct InMemoryEngineQueueStore {
    items: BTreeMap<String, EngineQueueItem>,
}

impl InMemoryEngineQueueStore {
    /// Create an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Enqueue one invocation.
    pub fn enqueue(&mut self, request: EnqueueInvocation) -> Result<EngineQueueItem> {
        validate_queue(&request.queue)?;
        let now = Utc::now();
        let item = EngineQueueItem {
            receipt_id: InvocationId::generate().to_string(),
            queue: request.queue,
            function_id: request.function_id,
            target_revision: request.target_revision,
            payload: request.payload,
            actor_id: request.actor_id,
            actor_kind: request.actor_kind,
            authority_grant_id: request.authority_grant_id,
            authority_scopes: request.authority_scopes,
            trace_id: request.trace_id,
            parent_invocation_id: request.parent_invocation_id,
            trigger_id: request.trigger_id,
            session_id: request.session_id,
            workspace_id: request.workspace_id,
            idempotency_key: request.idempotency_key,
            status: QueueItemStatus::Ready,
            attempts: 0,
            lease_owner: None,
            lease_expires_at: None,
            not_before: now,
            created_at: now,
            updated_at: now,
        };
        self.items.insert(item.receipt_id.clone(), item.clone());
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
        let Some((_, item)) = self.items.iter_mut().find(|(_, item)| {
            item.queue == queue
                && matches!(
                    item.status,
                    QueueItemStatus::Ready | QueueItemStatus::Leased
                )
                && item.not_before <= now
                && (item.status == QueueItemStatus::Ready
                    || item
                        .lease_expires_at
                        .map(|expiry| expiry <= now)
                        .unwrap_or(true))
        }) else {
            return Ok(None);
        };
        item.status = QueueItemStatus::Leased;
        item.lease_owner = Some(lease_owner.to_owned());
        item.lease_expires_at = Some(now + Duration::milliseconds(lease_ms.max(1)));
        item.updated_at = now;
        Ok(Some(item.clone()))
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
        let Some(item) = self.items.get_mut(receipt_id) else {
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
        Ok(Some(item.clone()))
    }

    /// Complete one queue item.
    pub fn complete(&mut self, receipt_id: &str) -> Result<bool> {
        let Some(item) = self.items.get_mut(receipt_id) else {
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
        item.updated_at = Utc::now();
        Ok(true)
    }

    /// Fail one queue item, retrying until `max_attempts`.
    pub fn fail(&mut self, receipt_id: &str, max_attempts: u32, backoff_ms: i64) -> Result<bool> {
        let Some(item) = self.items.get_mut(receipt_id) else {
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
        item.not_before = Utc::now() + Duration::milliseconds(backoff_ms.max(0));
        item.updated_at = Utc::now();
        Ok(true)
    }

    /// Cancel one queue item.
    pub fn cancel(&mut self, receipt_id: &str) -> Result<bool> {
        let Some(item) = self.items.get_mut(receipt_id) else {
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
        Ok(true)
    }

    /// Get one item.
    pub fn get(&self, receipt_id: &str) -> Result<Option<EngineQueueItem>> {
        Ok(self.items.get(receipt_id).cloned())
    }

    /// List queue items.
    pub fn list(&self, queue: &str, limit: usize) -> Result<Vec<EngineQueueItem>> {
        validate_queue(queue)?;
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "queue list limit must be greater than zero".to_owned(),
            ));
        }
        Ok(self
            .items
            .values()
            .filter(|item| item.queue == queue)
            .take(limit.min(500))
            .cloned()
            .collect())
    }
}

/// SQLite queue store.
pub struct SqliteEngineQueueStore {
    conn: Connection,
}

/// Queue drain runtime.
pub struct EngineQueueRuntime;

impl EngineQueueRuntime {
    /// Claim and execute one queue item, returning `Ok(None)` when no item is
    /// ready. Failed invocations are retried through the queue store.
    pub async fn drain_once(
        handle: &EngineHostHandle,
        queue: &str,
        lease_owner: &str,
    ) -> Result<Option<InvocationResult>> {
        let Some(item) = handle.claim_queue_item(queue, lease_owner, 30_000).await? else {
            return Ok(None);
        };
        publish_queue_lifecycle_event(handle, "claim", &item, None).await;
        Self::execute_claimed_item(handle, item).await.map(Some)
    }

    /// Claim and execute a specific receipt. Used by transport surfaces
    /// that must synchronously preserve an existing wire contract without
    /// racing unrelated queued work.
    pub async fn drain_receipt(
        handle: &EngineHostHandle,
        receipt_id: &str,
        lease_owner: &str,
    ) -> Result<Option<InvocationResult>> {
        let Some(item) = handle
            .claim_queue_item_by_receipt(receipt_id, lease_owner, 30_000)
            .await?
        else {
            return Ok(None);
        };
        publish_queue_lifecycle_event(handle, "claim", &item, None).await;
        Self::execute_claimed_item(handle, item).await.map(Some)
    }

    async fn execute_claimed_item(
        handle: &EngineHostHandle,
        item: EngineQueueItem,
    ) -> Result<InvocationResult> {
        let mut context = CausalContext::new(
            item.actor_id.clone(),
            item.actor_kind.clone(),
            item.authority_grant_id.clone(),
            item.trace_id.clone(),
        );
        for scope in &item.authority_scopes {
            context = context.with_scope(scope.clone());
        }
        if let Some(parent) = &item.parent_invocation_id {
            context = context.with_parent_invocation(parent.clone());
        }
        if let Some(trigger_id) = &item.trigger_id {
            context = context.with_trigger_id(trigger_id.clone());
        }
        if let Some(session_id) = &item.session_id {
            context = context.with_session_id(session_id.clone());
        }
        if let Some(workspace_id) = &item.workspace_id {
            context = context.with_workspace_id(workspace_id.clone());
        }
        if let Some(key) = &item.idempotency_key {
            let attempt_key = if item.attempts == 0 {
                key.clone()
            } else {
                format!("{key}:queue-retry:{}", item.attempts)
            };
            context = context.with_idempotency_key(attempt_key);
        }
        context.delivery_mode = DeliveryMode::Sync;
        let mut invocation =
            Invocation::new_sync(item.function_id.clone(), item.payload.clone(), context);
        invocation.expected_function_revision = item.target_revision;
        let target = handle.invoke_queue_target(invocation).await;
        let recorded_invocation = target.recorded_invocation;
        let result = target.result;
        if result.error.is_some() {
            if handle.fail_queue_item(&item.receipt_id, 3, 1_000).await? {
                let updated = handle
                    .get_queue_item(&item.receipt_id)
                    .await?
                    .unwrap_or_else(|| item.clone());
                publish_queue_lifecycle_event(
                    handle,
                    queue_failure_event_type(&updated),
                    &updated,
                    Some((&result, recorded_invocation)),
                )
                .await;
            }
        } else {
            if handle.complete_queue_item(&item.receipt_id).await? {
                let updated = handle
                    .get_queue_item(&item.receipt_id)
                    .await?
                    .unwrap_or_else(|| item.clone());
                publish_queue_lifecycle_event(
                    handle,
                    "complete",
                    &updated,
                    Some((&result, recorded_invocation)),
                )
                .await;
            }
        }
        Ok(result)
    }
}

/// Service-shaped queue drainer for production owners that want a named
/// boundary instead of calling the lower-level queue runtime directly.
pub struct EngineQueueDrainer;

impl EngineQueueDrainer {
    /// Claim and execute one queue item.
    pub async fn drain_once(
        handle: &EngineHostHandle,
        queue: &str,
        lease_owner: &str,
    ) -> Result<Option<InvocationResult>> {
        EngineQueueRuntime::drain_once(handle, queue, lease_owner).await
    }

    /// Claim and execute a specific queue receipt.
    pub async fn drain_receipt(
        handle: &EngineHostHandle,
        receipt_id: &str,
        lease_owner: &str,
    ) -> Result<Option<InvocationResult>> {
        EngineQueueRuntime::drain_receipt(handle, receipt_id, lease_owner).await
    }
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
  target_revision INTEGER,
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
  updated_at TEXT NOT NULL
);
"#,
            )
            .map_err(|err| sqlite_err("queue.init", err.to_string()))
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
            target_revision: request.target_revision,
            payload: request.payload,
            actor_id: request.actor_id,
            actor_kind: request.actor_kind,
            authority_grant_id: request.authority_grant_id,
            authority_scopes: request.authority_scopes,
            trace_id: request.trace_id,
            parent_invocation_id: request.parent_invocation_id,
            trigger_id: request.trigger_id,
            session_id: request.session_id,
            workspace_id: request.workspace_id,
            idempotency_key: request.idempotency_key,
            status: QueueItemStatus::Ready,
            attempts: 0,
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
        item.updated_at = Utc::now();
        self.update_item(&item)?;
        Ok(true)
    }

    /// Fail one queue item, retrying until `max_attempts`.
    pub fn fail(&mut self, receipt_id: &str, max_attempts: u32, backoff_ms: i64) -> Result<bool> {
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

    fn insert_item(&mut self, item: &EngineQueueItem) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO engine_queue_items
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                         ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)",
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
                   target_revision = ?4,
                   payload_json = ?5,
                   actor_id = ?6,
                   actor_kind = ?7,
                   authority_grant_id = ?8,
                   authority_scopes_json = ?9,
                   trace_id = ?10,
                   parent_invocation_id = ?11,
                   trigger_id = ?12,
                   session_id = ?13,
                   workspace_id = ?14,
                   idempotency_key = ?15,
                   status = ?16,
                   attempts = ?17,
                   lease_owner = ?18,
                   lease_expires_at = ?19,
                   not_before = ?20,
                   created_at = ?21,
                   updated_at = ?22
                 WHERE receipt_id = ?1",
                item_params(&self.conn, item)?,
            )
            .map_err(|err| sqlite_err("queue.update", err.to_string()))?;
        Ok(())
    }
}

fn item_params(
    conn: &Connection,
    item: &EngineQueueItem,
) -> Result<rusqlite::ParamsFromIter<Vec<rusqlite::types::Value>>> {
    use rusqlite::types::Value as SqlValue;
    let payload = crate::shared::storage::store_json_value(
        conn,
        &item.payload,
        &crate::shared::storage::StorePayloadOptions::new(
            "engine_queue_item",
            item.receipt_id.clone(),
            "payload",
            "runtime",
        )
        .with_scope(
            Some(item.trace_id.to_string()),
            item.session_id.clone(),
            item.workspace_id.clone(),
        ),
    )
    .map_err(|err| EngineError::LedgerFailure {
        operation: "queue.store_payload",
        message: err.to_string(),
    })?;
    let scopes = serde_json::to_string(&item.authority_scopes).unwrap_or_else(|_| "[]".to_owned());
    Ok(params_from_vec(vec![
        SqlValue::Text(item.receipt_id.clone()),
        SqlValue::Text(item.queue.clone()),
        SqlValue::Text(item.function_id.to_string()),
        item.target_revision
            .map(|revision| SqlValue::Integer(revision.0 as i64))
            .unwrap_or(SqlValue::Null),
        SqlValue::Text(payload),
        SqlValue::Text(item.actor_id.to_string()),
        SqlValue::Text(format!("{:?}", item.actor_kind)),
        SqlValue::Text(item.authority_grant_id.to_string()),
        SqlValue::Text(scopes),
        SqlValue::Text(item.trace_id.to_string()),
        item.parent_invocation_id
            .as_ref()
            .map(|id| SqlValue::Text(id.to_string()))
            .unwrap_or(SqlValue::Null),
        item.trigger_id
            .as_ref()
            .map(|id| SqlValue::Text(id.to_string()))
            .unwrap_or(SqlValue::Null),
        item.session_id
            .as_ref()
            .map(|id| SqlValue::Text(id.clone()))
            .unwrap_or(SqlValue::Null),
        item.workspace_id
            .as_ref()
            .map(|id| SqlValue::Text(id.clone()))
            .unwrap_or(SqlValue::Null),
        item.idempotency_key
            .as_ref()
            .map(|key| SqlValue::Text(key.clone()))
            .unwrap_or(SqlValue::Null),
        SqlValue::Text(item.status.as_str().to_owned()),
        SqlValue::Integer(item.attempts as i64),
        item.lease_owner
            .as_ref()
            .map(|owner| SqlValue::Text(owner.clone()))
            .unwrap_or(SqlValue::Null),
        item.lease_expires_at
            .map(|at| SqlValue::Text(at.to_rfc3339()))
            .unwrap_or(SqlValue::Null),
        SqlValue::Text(item.not_before.to_rfc3339()),
        SqlValue::Text(item.created_at.to_rfc3339()),
        SqlValue::Text(item.updated_at.to_rfc3339()),
    ]))
}

fn params_from_vec(
    values: Vec<rusqlite::types::Value>,
) -> rusqlite::ParamsFromIter<Vec<rusqlite::types::Value>> {
    rusqlite::params_from_iter(values)
}

fn row_to_queue_item(
    conn: &Connection,
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<EngineQueueItem> {
    let payload_json: String = row.get(4)?;
    let payload = crate::shared::storage::resolve_stored_json_value(conn, &payload_json)
        .map_err(storage_to_sql_err)?;
    let scopes_json: String = row.get(8)?;
    let target_revision: Option<i64> = row.get(3)?;
    let parent_invocation_id: Option<String> = row.get(10)?;
    let trigger_id: Option<String> = row.get(11)?;
    Ok(EngineQueueItem {
        receipt_id: row.get(0)?,
        queue: row.get(1)?,
        function_id: FunctionId::new(row.get::<_, String>(2)?)
            .expect("stored queue function id should be valid"),
        target_revision: target_revision.map(|value| FunctionRevision(value as u64)),
        payload,
        actor_id: ActorId::new(row.get::<_, String>(5)?)
            .expect("stored queue actor id should be valid"),
        actor_kind: actor_kind_from_str(&row.get::<_, String>(6)?),
        authority_grant_id: AuthorityGrantId::new(row.get::<_, String>(7)?)
            .expect("stored queue authority id should be valid"),
        authority_scopes: serde_json::from_str(&scopes_json).unwrap_or_default(),
        trace_id: TraceId::new(row.get::<_, String>(9)?)
            .expect("stored queue trace id should be valid"),
        parent_invocation_id: parent_invocation_id.and_then(|id| InvocationId::new(id).ok()),
        trigger_id: trigger_id.and_then(|id| TriggerId::new(id).ok()),
        session_id: row.get(12)?,
        workspace_id: row.get(13)?,
        idempotency_key: row.get(14)?,
        status: status_from_str(&row.get::<_, String>(15)?),
        attempts: row.get::<_, i64>(16)? as u32,
        lease_owner: row.get(17)?,
        lease_expires_at: row
            .get::<_, Option<String>>(18)?
            .and_then(|value| parse_time(&value)),
        not_before: parse_time(&row.get::<_, String>(19)?).unwrap_or_else(Utc::now),
        created_at: parse_time(&row.get::<_, String>(20)?).unwrap_or_else(Utc::now),
        updated_at: parse_time(&row.get::<_, String>(21)?).unwrap_or_else(Utc::now),
    })
}

fn validate_queue(queue: &str) -> Result<()> {
    if queue.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "queue name must not be empty".to_owned(),
        ));
    }
    Ok(())
}

fn status_from_str(value: &str) -> QueueItemStatus {
    match value {
        "leased" => QueueItemStatus::Leased,
        "completed" => QueueItemStatus::Completed,
        "cancelled" => QueueItemStatus::Cancelled,
        "dead_lettered" => QueueItemStatus::DeadLettered,
        _ => QueueItemStatus::Ready,
    }
}

fn actor_kind_from_str(value: &str) -> ActorKind {
    match value {
        "Agent" => ActorKind::Agent,
        "Client" => ActorKind::Client,
        "Worker" => ActorKind::Worker,
        "System" => ActorKind::System,
        "Admin" => ActorKind::Admin,
        _ => ActorKind::System,
    }
}

fn storage_to_sql_err(error: anyhow::Error) -> rusqlite::Error {
    rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::other(error.to_string())))
}

fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|dt| dt.with_timezone(&Utc))
        .ok()
}

fn sqlite_err(operation: &'static str, message: impl Into<String>) -> EngineError {
    EngineError::LedgerFailure {
        operation,
        message: message.into(),
    }
}

/// Publish a queue lifecycle event to the engine stream primitive.
pub async fn publish_queue_lifecycle_event(
    handle: &EngineHostHandle,
    event_type: &str,
    item: &EngineQueueItem,
    result: Option<(&InvocationResult, bool)>,
) {
    let _ = handle
        .publish_stream_event(queue_lifecycle_stream_event(event_type, item, result))
        .await;
}

pub(in crate::engine) fn queue_failure_event_type(item: &EngineQueueItem) -> &'static str {
    if item.status == QueueItemStatus::DeadLettered {
        "dead_letter"
    } else {
        "fail"
    }
}

pub(in crate::engine) fn queue_lifecycle_stream_event(
    event_type: &str,
    item: &EngineQueueItem,
    result: Option<(&InvocationResult, bool)>,
) -> super::streams::PublishStreamEvent {
    let status = match event_type {
        "enqueue" => "ready",
        "claim" => "leased",
        "complete" => "completed",
        "fail" => item.status.as_str(),
        "cancel" => "cancelled",
        "dead_letter" => "dead_lettered",
        _ => item.status.as_str(),
    };
    super::streams::PublishStreamEvent {
        topic: "queue.lifecycle".to_owned(),
        payload: json!({
            "type": format!("queue.{event_type}"),
            "receiptId": &item.receipt_id,
            "queue": &item.queue,
            "functionId": &item.function_id,
            "status": status,
            "attempts": item.attempts,
            "deliveryInvocationId": result.map(|(value, _)| value.invocation_id.to_string()),
            "resultInvocationId": result.and_then(|(value, recorded)| {
                recorded.then(|| value.invocation_id.to_string())
            }),
            "error": result
                .and_then(|(value, _)| value.error.as_ref())
                .map(ToString::to_string),
        }),
        visibility: super::types::VisibilityScope::Session,
        session_id: item.session_id.clone(),
        workspace_id: item.workspace_id.clone(),
        producer: "queue".to_owned(),
        trace_id: Some(item.trace_id.clone()),
        parent_invocation_id: item.parent_invocation_id.clone(),
    }
}
