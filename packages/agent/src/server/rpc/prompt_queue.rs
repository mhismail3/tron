//! Prompt queue service — server-side message queue for prompts submitted while agent is busy.
//!
//! Queue state is derived from events: pending items = `message.queued` events without
//! a matching `message.dequeued`. No mutable in-memory state; the event log is the
//! single source of truth.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::events::{AppendOptions, EventStore, EventType};
use crate::server::rpc::errors::RpcError;

/// Maximum number of messages that can be queued per session.
pub const MAX_QUEUE_CAPACITY: usize = 3;

/// A pending queued message derived from the event log.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingQueueItem {
    pub queue_id: String,
    pub text: String,
    pub position: u32,
    pub timestamp: String,
    /// Optional structured metadata that should travel with the prompt
    /// through the queue. Used to preserve `messageKind` +
    /// confirmation/answer fields when interactive-tool responses are
    /// queued while the session is busy, so iOS renders the right chip
    /// once the queued message is eventually drained.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<Value>,
}

/// Prompt queue service — all operations are event-sourced.
pub struct PromptQueueService;

impl PromptQueueService {
    /// Get pending (unprocessed) queued messages for a session.
    ///
    /// Scans `message.queued` and `message.dequeued` events to derive the current queue.
    pub fn get_pending_queue(
        event_store: &EventStore,
        session_id: &str,
    ) -> Result<Vec<PendingQueueItem>, RpcError> {
        let events = event_store
            .get_events_by_type(session_id, &["message.queued", "message.dequeued"], None)
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to query queue events: {e}"),
            })?;

        // Collect dequeued IDs
        let mut dequeued_ids = std::collections::HashSet::new();
        let mut queued_items = Vec::new();

        for event in &events {
            let payload: Value = serde_json::from_str(&event.payload).unwrap_or_default();
            match event.event_type.as_str() {
                "message.dequeued" => {
                    if let Some(queue_id) = payload.get("queueId").and_then(|v| v.as_str()) {
                        let _ = dequeued_ids.insert(queue_id.to_string());
                    }
                }
                "message.queued" => {
                    let queue_id = payload
                        .get("queueId")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string();
                    let text = payload
                        .get("text")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string();
                    let position = payload
                        .get("position")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0) as u32;
                    let metadata = payload.get("metadata").cloned();
                    queued_items.push((queue_id, text, position, event.timestamp.clone(), metadata));
                }
                _ => {}
            }
        }

        // Filter to pending only (no matching dequeue)
        let mut pending: Vec<PendingQueueItem> = queued_items
            .into_iter()
            .filter(|(qid, _, _, _, _)| !dequeued_ids.contains(qid))
            .map(|(queue_id, text, position, timestamp, metadata)| PendingQueueItem {
                queue_id,
                text,
                position,
                timestamp,
                metadata,
            })
            .collect();

        // Re-number positions (0-indexed, ordered by original position)
        pending.sort_by_key(|item| item.position);
        for (i, item) in pending.iter_mut().enumerate() {
            item.position = i as u32;
        }

        Ok(pending)
    }

    /// Queue a prompt message. Returns the queue ID and position.
    ///
    /// Fails if the queue is at capacity.
    pub fn enqueue(
        event_store: &EventStore,
        session_id: &str,
        text: &str,
    ) -> Result<PendingQueueItem, RpcError> {
        Self::enqueue_with_metadata(event_store, session_id, text, None)
    }

    /// Queue a prompt message with optional structured metadata that will
    /// travel with the prompt through the queue lifecycle.
    pub fn enqueue_with_metadata(
        event_store: &EventStore,
        session_id: &str,
        text: &str,
        metadata: Option<Value>,
    ) -> Result<PendingQueueItem, RpcError> {
        let pending = Self::get_pending_queue(event_store, session_id)?;

        if pending.len() >= MAX_QUEUE_CAPACITY {
            return Err(RpcError::Custom {
                code: "QUEUE_FULL".into(),
                message: format!(
                    "Message queue is full ({MAX_QUEUE_CAPACITY} items max)"
                ),
                details: None,
            });
        }

        let queue_id = uuid::Uuid::now_v7().to_string();
        let position = pending.len() as u32;

        let mut payload = json!({
            "text": text,
            "queueId": queue_id,
            "position": position,
        });
        if let Some(ref meta) = metadata {
            payload["metadata"] = meta.clone();
        }

        let event = event_store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::MessageQueued,
                payload,
                parent_id: None,
                sequence: None,
            })
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to persist message.queued event: {e}"),
            })?;

        Ok(PendingQueueItem {
            queue_id,
            text: text.to_string(),
            position,
            timestamp: event.timestamp,
            metadata,
        })
    }

    /// Dequeue (cancel) a specific queued message.
    pub fn dequeue(
        event_store: &EventStore,
        session_id: &str,
        queue_id: &str,
        reason: &str,
    ) -> Result<(), RpcError> {
        let payload = json!({
            "queueId": queue_id,
            "reason": reason,
        });

        let _ = event_store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::MessageDequeued,
                payload,
                parent_id: None,
                sequence: None,
            })
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to persist message.dequeued event: {e}"),
            })?;

        Ok(())
    }

    /// Clear all pending queued messages (emits `message.dequeued` for each).
    pub fn clear_queue(
        event_store: &EventStore,
        session_id: &str,
    ) -> Result<u32, RpcError> {
        let pending = Self::get_pending_queue(event_store, session_id)?;
        let count = pending.len() as u32;

        for item in &pending {
            Self::dequeue(event_store, session_id, &item.queue_id, "cleared")?;
        }

        Ok(count)
    }

}

#[cfg(test)]
impl PromptQueueService {
    /// Peek at the next pending message without dequeuing it.
    pub fn peek_next(
        event_store: &EventStore,
        session_id: &str,
    ) -> Result<Option<PendingQueueItem>, RpcError> {
        let pending = Self::get_pending_queue(event_store, session_id)?;
        Ok(pending.into_iter().next())
    }

    /// Drain the next pending message: dequeue it as "processed" and return its text.
    pub fn drain_next(
        event_store: &std::sync::Arc<EventStore>,
        session_id: &str,
    ) -> Result<Option<String>, RpcError> {
        let first = match Self::peek_next(event_store, session_id)? {
            Some(item) => item,
            None => return Ok(None),
        };

        Self::dequeue(event_store, session_id, &first.queue_id, "processed")?;

        Ok(Some(first.text))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use crate::events::{self, ConnectionConfig, EventStore};

    fn make_store_and_session() -> (Arc<EventStore>, String) {
        let pool = events::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));

        let result = store
            .create_session("claude-opus-4-6", "/tmp", None, None, None, None)
            .unwrap();

        (store, result.session.id)
    }

    #[test]
    fn empty_queue() {
        let (store, sid) = make_store_and_session();
        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert!(pending.is_empty());
    }

    #[test]
    fn enqueue_one() {
        let (store, sid) = make_store_and_session();
        let item = PromptQueueService::enqueue(&store, &sid, "hello").unwrap();
        assert_eq!(item.text, "hello");
        assert_eq!(item.position, 0);

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].queue_id, item.queue_id);
    }

    #[test]
    fn enqueue_multiple() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "first").unwrap();
        PromptQueueService::enqueue(&store, &sid, "second").unwrap();
        PromptQueueService::enqueue(&store, &sid, "third").unwrap();

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 3);
        assert_eq!(pending[0].text, "first");
        assert_eq!(pending[1].text, "second");
        assert_eq!(pending[2].text, "third");
        assert_eq!(pending[0].position, 0);
        assert_eq!(pending[1].position, 1);
        assert_eq!(pending[2].position, 2);
    }

    #[test]
    fn enqueue_at_capacity_fails() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "a").unwrap();
        PromptQueueService::enqueue(&store, &sid, "b").unwrap();
        PromptQueueService::enqueue(&store, &sid, "c").unwrap();

        let err = PromptQueueService::enqueue(&store, &sid, "d").unwrap_err();
        assert_eq!(err.code(), "QUEUE_FULL");
    }

    #[test]
    fn dequeue_removes_from_pending() {
        let (store, sid) = make_store_and_session();
        let item = PromptQueueService::enqueue(&store, &sid, "hello").unwrap();

        PromptQueueService::dequeue(&store, &sid, &item.queue_id, "cancelled").unwrap();

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert!(pending.is_empty());
    }

    #[test]
    fn dequeue_renumbers_positions() {
        let (store, sid) = make_store_and_session();
        let first = PromptQueueService::enqueue(&store, &sid, "first").unwrap();
        PromptQueueService::enqueue(&store, &sid, "second").unwrap();
        PromptQueueService::enqueue(&store, &sid, "third").unwrap();

        // Remove the first item
        PromptQueueService::dequeue(&store, &sid, &first.queue_id, "cancelled").unwrap();

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 2);
        assert_eq!(pending[0].text, "second");
        assert_eq!(pending[0].position, 0);
        assert_eq!(pending[1].text, "third");
        assert_eq!(pending[1].position, 1);
    }

    #[test]
    fn clear_queue_removes_all() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "a").unwrap();
        PromptQueueService::enqueue(&store, &sid, "b").unwrap();

        let cleared = PromptQueueService::clear_queue(&store, &sid).unwrap();
        assert_eq!(cleared, 2);

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert!(pending.is_empty());
    }

    #[test]
    fn clear_empty_queue() {
        let (store, sid) = make_store_and_session();
        let cleared = PromptQueueService::clear_queue(&store, &sid).unwrap();
        assert_eq!(cleared, 0);
    }

    #[test]
    fn peek_next_returns_first_without_removing() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "first").unwrap();
        PromptQueueService::enqueue(&store, &sid, "second").unwrap();

        let item = PromptQueueService::peek_next(&store, &sid).unwrap();
        assert!(item.is_some());
        assert_eq!(item.unwrap().text, "first");

        // Queue unchanged — peek doesn't remove
        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 2);
    }

    #[test]
    fn peek_next_empty_returns_none() {
        let (store, sid) = make_store_and_session();
        let item = PromptQueueService::peek_next(&store, &sid).unwrap();
        assert!(item.is_none());
    }

    #[test]
    fn peek_then_dequeue_safe_drain_pattern() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "hello").unwrap();

        // Peek
        let item = PromptQueueService::peek_next(&store, &sid).unwrap().unwrap();
        assert_eq!(item.text, "hello");

        // Simulate begin_run success, then dequeue
        PromptQueueService::dequeue(&store, &sid, &item.queue_id, "processed").unwrap();

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert!(pending.is_empty());
    }

    #[test]
    fn peek_without_dequeue_preserves_on_failure() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "hello").unwrap();

        // Peek
        let item = PromptQueueService::peek_next(&store, &sid).unwrap().unwrap();
        assert_eq!(item.text, "hello");

        // Simulate begin_run failure — do NOT dequeue
        // Queue should still have the message
        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].text, "hello");
    }

    #[test]
    fn drain_next_returns_first() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "first").unwrap();
        PromptQueueService::enqueue(&store, &sid, "second").unwrap();

        let text = PromptQueueService::drain_next(&store, &sid).unwrap();
        assert_eq!(text, Some("first".to_string()));

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].text, "second");
    }

    #[test]
    fn drain_next_empty_returns_none() {
        let (store, sid) = make_store_and_session();
        let text = PromptQueueService::drain_next(&store, &sid).unwrap();
        assert!(text.is_none());
    }

    #[test]
    fn drain_next_sequential() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "first").unwrap();
        PromptQueueService::enqueue(&store, &sid, "second").unwrap();
        PromptQueueService::enqueue(&store, &sid, "third").unwrap();

        assert_eq!(
            PromptQueueService::drain_next(&store, &sid).unwrap(),
            Some("first".to_string())
        );
        assert_eq!(
            PromptQueueService::drain_next(&store, &sid).unwrap(),
            Some("second".to_string())
        );
        assert_eq!(
            PromptQueueService::drain_next(&store, &sid).unwrap(),
            Some("third".to_string())
        );
        assert_eq!(
            PromptQueueService::drain_next(&store, &sid).unwrap(),
            None
        );
    }

    #[test]
    fn enqueue_after_drain_allows_new_messages() {
        let (store, sid) = make_store_and_session();
        // Fill queue
        PromptQueueService::enqueue(&store, &sid, "a").unwrap();
        PromptQueueService::enqueue(&store, &sid, "b").unwrap();
        PromptQueueService::enqueue(&store, &sid, "c").unwrap();

        // Drain one
        PromptQueueService::drain_next(&store, &sid).unwrap();

        // Can enqueue again
        let item = PromptQueueService::enqueue(&store, &sid, "d").unwrap();
        assert_eq!(item.position, 2); // position 0=b, 1=c, 2=d

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 3);
        assert_eq!(pending[2].text, "d");
    }

    #[test]
    fn idempotent_dequeue() {
        let (store, sid) = make_store_and_session();
        let item = PromptQueueService::enqueue(&store, &sid, "hello").unwrap();

        // Dequeue twice — second should succeed (no-op, still writes event but queue unchanged)
        PromptQueueService::dequeue(&store, &sid, &item.queue_id, "cancelled").unwrap();
        PromptQueueService::dequeue(&store, &sid, &item.queue_id, "cancelled").unwrap();

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert!(pending.is_empty());
    }

    // ── Metadata round-trip (Phase C queue bug fix) ────────────────────

    #[test]
    fn enqueue_with_metadata_roundtrips_through_event_log() {
        let (store, sid) = make_store_and_session();
        let metadata = json!({
            "messageKind": "confirmation_response",
            "confirmationDecision": "Approved",
            "confirmationNote": "looks good",
        });
        let item = PromptQueueService::enqueue_with_metadata(
            &store,
            &sid,
            "[Confirmation response]\n\nDecision: Approved",
            Some(metadata.clone()),
        )
        .unwrap();
        assert_eq!(item.metadata, Some(metadata.clone()));

        // Re-derive the queue from the event log — metadata must survive.
        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].metadata, Some(metadata));
    }

    #[test]
    fn enqueue_without_metadata_leaves_field_none() {
        let (store, sid) = make_store_and_session();
        let item = PromptQueueService::enqueue(&store, &sid, "plain text").unwrap();
        assert!(item.metadata.is_none());

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert!(pending[0].metadata.is_none());
    }

    #[test]
    fn mixed_metadata_queue_preserves_each_item() {
        let (store, sid) = make_store_and_session();
        PromptQueueService::enqueue(&store, &sid, "plain").unwrap();
        PromptQueueService::enqueue_with_metadata(
            &store,
            &sid,
            "[Confirmation response]\n\nDecision: Denied",
            Some(json!({
                "messageKind": "confirmation_response",
                "confirmationDecision": "Denied",
            })),
        )
        .unwrap();

        let pending = PromptQueueService::get_pending_queue(&store, &sid).unwrap();
        assert_eq!(pending.len(), 2);
        assert!(pending[0].metadata.is_none());
        let meta = pending[1].metadata.as_ref().unwrap();
        assert_eq!(meta["messageKind"], "confirmation_response");
        assert_eq!(meta["confirmationDecision"], "Denied");
    }

    #[test]
    fn separate_sessions_independent() {
        let pool = events::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));

        let r1 = store.create_session("claude-opus-4-6", "/tmp", None, None, None, None).unwrap();
        let r2 = store.create_session("claude-opus-4-6", "/tmp", None, None, None, None).unwrap();
        let sid1 = r1.session.id;
        let sid2 = r2.session.id;

        PromptQueueService::enqueue(&store, &sid1, "session1-msg").unwrap();
        PromptQueueService::enqueue(&store, &sid2, "session2-msg").unwrap();

        let q1 = PromptQueueService::get_pending_queue(&store, &sid1).unwrap();
        let q2 = PromptQueueService::get_pending_queue(&store, &sid2).unwrap();
        assert_eq!(q1.len(), 1);
        assert_eq!(q2.len(), 1);
        assert_eq!(q1[0].text, "session1-msg");
        assert_eq!(q2[0].text, "session2-msg");
    }
}
