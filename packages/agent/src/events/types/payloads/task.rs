//! Task/project/area CRUD event payloads (broadcast-only).

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
    /// Parent project ID.
    pub project_id: Option<String>,
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

/// Payload for `project.created` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCreatedPayload {
    /// Project ID.
    pub project_id: String,
    /// Project title.
    pub title: String,
    /// Project status.
    pub status: String,
    /// Area ID.
    pub area_id: Option<String>,
}

/// Payload for `project.updated` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectUpdatedPayload {
    /// Project ID.
    pub project_id: String,
    /// Project title.
    pub title: String,
    /// Project status.
    pub status: String,
}

/// Payload for `project.deleted` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectDeletedPayload {
    /// Project ID.
    pub project_id: String,
    /// Project title.
    pub title: String,
}

/// Payload for `area.created` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AreaCreatedPayload {
    /// Area ID.
    pub area_id: String,
    /// Area title.
    pub title: String,
    /// Area status.
    pub status: String,
}

/// Payload for `area.updated` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AreaUpdatedPayload {
    /// Area ID.
    pub area_id: String,
    /// Area title.
    pub title: String,
    /// Area status.
    pub status: String,
    /// Which fields changed.
    pub changed_fields: Vec<String>,
}

/// Payload for `area.deleted` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AreaDeletedPayload {
    /// Area ID.
    pub area_id: String,
    /// Area title.
    pub title: String,
}
