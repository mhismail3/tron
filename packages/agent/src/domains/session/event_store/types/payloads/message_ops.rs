//! Message operation payloads.

use serde::{Deserialize, Serialize};

/// Payload for `message.deleted` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageDeletedPayload {
    /// Event ID of the message being deleted.
    pub target_event_id: String,
    /// Type of the target message.
    pub target_type: String,
    /// Turn number of the deleted message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_turn: Option<i64>,
    /// Reason for deletion.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Payload for `message.queued` events.
///
/// Persisted when a user queues a message while the agent is busy.
/// The server is the source of truth for the queue — iOS displays pills
/// based on these events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageQueuedPayload {
    /// The queued message text.
    pub text: String,
    /// Unique queue item ID (UUID v7).
    pub queue_id: String,
    /// Position in the queue (0-indexed).
    pub position: u32,
}

/// Payload for `message.dequeued` events.
///
/// Persisted when a queued message is consumed (auto-sent by the server
/// after `agent.ready`) or cancelled by the user.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageDequeuedPayload {
    /// Queue item ID being consumed/cancelled (matches `MessageQueuedPayload.queue_id`).
    pub queue_id: String,
    /// Why the message was dequeued: `"processed"`, `"cancelled"`, or `"cleared"`.
    pub reason: String,
}
