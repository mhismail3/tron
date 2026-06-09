//! In-memory engine queue store.

use std::collections::BTreeMap;

use chrono::{Duration, Utc};

use super::sqlite_codec::validate_queue;
use super::{
    EngineQueueAttemptRecord, EngineQueueItem, EnqueueInvocation, QueueAttemptOutcome,
    QueueItemStatus,
};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::InvocationId;

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
        self.complete_with_attempt(receipt_id, None)
    }

    /// Complete one queue item and append an attempt record.
    pub fn complete_with_attempt(
        &mut self,
        receipt_id: &str,
        attempt: Option<EngineQueueAttemptRecord>,
    ) -> Result<bool> {
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
        if let Some(attempt) = attempt {
            item.attempt_records.push(attempt);
        }
        item.updated_at = Utc::now();
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
        if let Some(mut attempt) = attempt {
            attempt.attempt = item.attempts;
            if item.status == QueueItemStatus::DeadLettered {
                attempt.outcome = QueueAttemptOutcome::DeadLettered;
            }
            item.attempt_records.push(attempt);
        }
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

    /// List queue items that belong to one trace.
    pub fn list_by_trace(&self, trace_id: &str, limit: usize) -> Result<Vec<EngineQueueItem>> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "queue list limit must be greater than zero".to_owned(),
            ));
        }
        let mut items = self
            .items
            .values()
            .filter(|item| item.trace_id.as_str() == trace_id)
            .cloned()
            .collect::<Vec<_>>();
        items.sort_by_key(|item| item.created_at);
        items.truncate(limit.min(500));
        Ok(items)
    }
}
