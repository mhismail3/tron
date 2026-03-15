//! Task CRUD event payloads (broadcast-only).

use serde::{Deserialize, Serialize};

/// Payload for `task.created` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskCreatedPayload {
    /// Task ID.
    pub task_id: String,
    /// Task title.
    pub title: String,
    /// Task status.
    pub status: String,
}

/// Payload for `task.updated` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskUpdatedPayload {
    /// Task ID.
    pub task_id: String,
    /// Task title.
    pub title: String,
    /// Task status.
    pub status: String,
    /// Which fields changed.
    pub changed_fields: Vec<String>,
}

/// Payload for `task.deleted` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskDeletedPayload {
    /// Task ID.
    pub task_id: String,
    /// Task title.
    pub title: String,
}
