//! Core types for the task management system.
//!
//! All serializable types use `camelCase` for wire compatibility with iOS
//! and the dashboard.

use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────────────────────────────────

/// Task status in the workflow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    /// Ready to work on.
    Pending,
    /// Currently being worked on.
    InProgress,
    /// Done.
    Completed,
    /// Abandoned.
    Cancelled,
    /// Left over from a previous session — needs resolution.
    Stale,
}

impl TaskStatus {
    /// Whether this status represents a terminal (done) state.
    #[must_use]
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Cancelled)
    }

    /// SQL string representation (matches `SQLite` CHECK constraint values).
    #[must_use]
    pub fn as_sql(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::InProgress => "in_progress",
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
            Self::Stale => "stale",
        }
    }

    /// Parse from SQL column value. Unknown values default to `Pending`.
    /// Maps legacy `backlog` to `Pending` for forward compatibility.
    #[must_use]
    pub fn from_sql(s: &str) -> Self {
        match s {
            "in_progress" => Self::InProgress,
            "completed" => Self::Completed,
            "cancelled" => Self::Cancelled,
            "stale" => Self::Stale,
            // "backlog" and "pending" both map to Pending
            _ => Self::Pending,
        }
    }
}

impl std::fmt::Display for TaskStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_sql())
    }
}

/// Type of activity logged for a task.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityAction {
    /// Task was created.
    Created,
    /// Task status changed.
    StatusChanged,
    /// Task fields updated.
    Updated,
    /// Note added to task.
    NoteAdded,
    /// Task was deleted.
    Deleted,
}

impl ActivityAction {
    /// SQL string representation.
    #[must_use]
    pub fn as_sql(self) -> &'static str {
        match self {
            Self::Created => "created",
            Self::StatusChanged => "status_changed",
            Self::Updated => "updated",
            Self::NoteAdded => "note_added",
            Self::Deleted => "deleted",
        }
    }

    /// Parse from SQL column value. Unknown values default to `Updated`.
    #[must_use]
    pub fn from_sql(s: &str) -> Self {
        match s {
            "created" => Self::Created,
            "status_changed" => Self::StatusChanged,
            "note_added" => Self::NoteAdded,
            "deleted" => Self::Deleted,
            _ => Self::Updated,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Domain types
// ─────────────────────────────────────────────────────────────────────────────

/// A task in the system.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    /// Unique ID (prefixed: `task-{uuid}`).
    pub id: String,
    /// Parent task (for subtasks).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_task_id: Option<String>,
    /// Short description.
    pub title: String,
    /// Detailed description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Present continuous form for UI spinner.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_form: Option<String>,
    /// Accumulated notes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    /// Current status.
    pub status: TaskStatus,
    /// When work started.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    /// When task was completed/cancelled.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// Creation timestamp.
    pub created_at: String,
    /// Last update timestamp.
    pub updated_at: String,
    /// Session that created this task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_by_session_id: Option<String>,
    /// Last session to modify this task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_session_id: Option<String>,
    /// When last session modified this task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_session_at: Option<String>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

/// An audit trail entry for task changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskActivity {
    /// Auto-incremented ID.
    pub id: i64,
    /// The task this activity is for.
    pub task_id: String,
    /// Session that caused this activity.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Event that caused this activity.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_id: Option<String>,
    /// What happened.
    pub action: ActivityAction,
    /// Previous value (for changes).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_value: Option<String>,
    /// New value (for changes).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_value: Option<String>,
    /// Human-readable detail.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// When this activity occurred.
    pub timestamp: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Composite types
// ─────────────────────────────────────────────────────────────────────────────

/// Task with all related details.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskWithDetails {
    /// The task itself.
    #[serde(flatten)]
    pub task: Task,
    /// Child tasks (subtasks).
    pub subtasks: Vec<Task>,
    /// Recent activity log.
    pub recent_activity: Vec<TaskActivity>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Mutation params
// ─────────────────────────────────────────────────────────────────────────────

/// Parameters for creating a task.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskCreateParams {
    /// Short description (required).
    pub title: String,
    /// Parent task (makes this a subtask).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_task_id: Option<String>,
    /// Detailed description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Present continuous form for UI.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_form: Option<String>,
    /// Initial status (default: Pending).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskStatus>,
    /// Session creating this task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_by_session_id: Option<String>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

/// Parameters for updating a task.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskUpdateParams {
    /// New title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// New description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// New active form.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_form: Option<String>,
    /// New status.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskStatus>,
    /// Move to different parent task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_task_id: Option<String>,
    /// Note to append.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub add_note: Option<String>,
    /// Session making this update.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_session_id: Option<String>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter types
// ─────────────────────────────────────────────────────────────────────────────

/// Filter parameters for listing tasks.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TaskFilter {
    /// Filter by status.
    pub status: Option<TaskStatus>,
    /// Filter by parent task.
    pub parent_task_id: Option<String>,
    /// Include completed/cancelled tasks.
    pub include_completed: bool,
}

// ─────────────────────────────────────────────────────────────────────────────
// Result types
// ─────────────────────────────────────────────────────────────────────────────

/// Paginated task list result.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskListResult {
    /// Tasks matching the filter.
    pub tasks: Vec<Task>,
    /// Total count (ignoring pagination).
    pub total: u32,
}

/// Summary of active tasks for context injection.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveTaskSummary {
    /// Tasks currently in progress.
    pub in_progress: Vec<Task>,
    /// Count of pending tasks.
    pub pending_count: u32,
    /// Count of stale tasks from previous sessions.
    pub stale_count: u32,
    /// Stale tasks (for context display).
    pub stale_tasks: Vec<Task>,
}

/// Parameters for logging activity.
#[derive(Debug, Clone)]
pub struct LogActivityParams {
    /// Task ID.
    pub task_id: String,
    /// Session that caused this.
    pub session_id: Option<String>,
    /// Event that caused this.
    pub event_id: Option<String>,
    /// What happened.
    pub action: ActivityAction,
    /// Previous value.
    pub old_value: Option<String>,
    /// New value.
    pub new_value: Option<String>,
    /// Human-readable detail.
    pub detail: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_task_status_serde_roundtrip() {
        for status in [
            TaskStatus::Pending,
            TaskStatus::InProgress,
            TaskStatus::Completed,
            TaskStatus::Cancelled,
            TaskStatus::Stale,
        ] {
            let json = serde_json::to_string(&status).unwrap();
            let back: TaskStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(back, status);
        }
    }

    #[test]
    fn test_task_status_serde_values() {
        assert_eq!(
            serde_json::to_string(&TaskStatus::InProgress).unwrap(),
            "\"in_progress\""
        );
        assert_eq!(
            serde_json::to_string(&TaskStatus::Stale).unwrap(),
            "\"stale\""
        );
    }

    #[test]
    fn test_task_status_is_terminal() {
        assert!(TaskStatus::Completed.is_terminal());
        assert!(TaskStatus::Cancelled.is_terminal());
        assert!(!TaskStatus::Pending.is_terminal());
        assert!(!TaskStatus::InProgress.is_terminal());
        assert!(!TaskStatus::Stale.is_terminal());
    }

    #[test]
    fn test_task_status_stale_sql_roundtrip() {
        assert_eq!(TaskStatus::from_sql("stale"), TaskStatus::Stale);
        assert_eq!(TaskStatus::Stale.as_sql(), "stale");
    }

    #[test]
    fn test_task_status_backlog_maps_to_pending() {
        assert_eq!(TaskStatus::from_sql("backlog"), TaskStatus::Pending);
    }

    #[test]
    fn test_task_status_sql_roundtrip() {
        for status in [
            TaskStatus::Pending,
            TaskStatus::InProgress,
            TaskStatus::Completed,
            TaskStatus::Cancelled,
            TaskStatus::Stale,
        ] {
            assert_eq!(TaskStatus::from_sql(status.as_sql()), status);
        }
    }

    #[test]
    fn test_task_status_from_sql_unknown_defaults_to_pending() {
        assert_eq!(TaskStatus::from_sql("garbage"), TaskStatus::Pending);
        assert_eq!(TaskStatus::from_sql(""), TaskStatus::Pending);
        assert_eq!(TaskStatus::from_sql("COMPLETED"), TaskStatus::Pending);
    }

    #[test]
    fn test_activity_action_serde_roundtrip() {
        for action in [
            ActivityAction::Created,
            ActivityAction::StatusChanged,
            ActivityAction::Updated,
            ActivityAction::NoteAdded,
            ActivityAction::Deleted,
        ] {
            let json = serde_json::to_string(&action).unwrap();
            let back: ActivityAction = serde_json::from_str(&json).unwrap();
            assert_eq!(back, action);
        }
    }

    #[test]
    fn test_activity_action_sql_roundtrip() {
        for a in [
            ActivityAction::Created,
            ActivityAction::StatusChanged,
            ActivityAction::Updated,
            ActivityAction::NoteAdded,
            ActivityAction::Deleted,
        ] {
            assert_eq!(ActivityAction::from_sql(a.as_sql()), a);
        }
    }

    #[test]
    fn test_activity_action_from_sql_unknown_defaults_to_updated() {
        assert_eq!(ActivityAction::from_sql("unknown"), ActivityAction::Updated);
        assert_eq!(ActivityAction::from_sql(""), ActivityAction::Updated);
        // Legacy values also map to Updated
        assert_eq!(ActivityAction::from_sql("time_logged"), ActivityAction::Updated);
        assert_eq!(ActivityAction::from_sql("dependency_added"), ActivityAction::Updated);
        assert_eq!(ActivityAction::from_sql("moved"), ActivityAction::Updated);
    }

    #[test]
    fn test_task_create_params_default() {
        let params = TaskCreateParams::default();
        assert!(params.title.is_empty());
        assert!(params.status.is_none());
    }

    #[test]
    fn test_task_update_params_can_set_stale() {
        let params = TaskUpdateParams {
            status: Some(TaskStatus::Stale),
            ..Default::default()
        };
        assert_eq!(params.status, Some(TaskStatus::Stale));
    }

    #[test]
    fn test_task_serde_roundtrip() {
        let task = Task {
            id: "task-123".to_string(),
            parent_task_id: None,
            title: "Fix bug".to_string(),
            description: Some("Details here".to_string()),
            active_form: Some("Fixing bug".to_string()),
            notes: None,
            status: TaskStatus::InProgress,
            started_at: Some("2026-02-10T10:00:00Z".to_string()),
            completed_at: None,
            created_at: "2026-02-10T09:00:00Z".to_string(),
            updated_at: "2026-02-10T10:00:00Z".to_string(),
            created_by_session_id: Some("s-1".to_string()),
            last_session_id: Some("s-2".to_string()),
            last_session_at: Some("2026-02-10T10:00:00Z".to_string()),
            metadata: None,
        };
        let json = serde_json::to_string(&task).unwrap();
        let back: Task = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, task.id);
        assert_eq!(back.status, task.status);
    }

    #[test]
    fn test_task_serde_camel_case() {
        let task = Task {
            id: "t1".to_string(),
            parent_task_id: None,
            title: "Test".to_string(),
            description: None,
            active_form: None,
            notes: None,
            status: TaskStatus::Pending,
            started_at: None,
            completed_at: None,
            created_at: "now".to_string(),
            updated_at: "now".to_string(),
            created_by_session_id: None,
            last_session_id: None,
            last_session_at: None,
            metadata: None,
        };
        let json = serde_json::to_string(&task).unwrap();
        assert!(json.contains("createdAt"));
        assert!(json.contains("updatedAt"));
        // None fields should be skipped
        assert!(!json.contains("parentTaskId"));
    }

    #[test]
    fn test_task_activity_serde() {
        let activity = TaskActivity {
            id: 1,
            task_id: "t1".to_string(),
            session_id: None,
            event_id: None,
            action: ActivityAction::StatusChanged,
            old_value: Some("pending".to_string()),
            new_value: Some("in_progress".to_string()),
            detail: None,
            timestamp: "2026-01-01".to_string(),
        };
        let json = serde_json::to_string(&activity).unwrap();
        assert!(json.contains("statusChanged") || json.contains("status_changed"));
    }

    #[test]
    fn test_active_task_summary_serde() {
        let summary = ActiveTaskSummary {
            in_progress: vec![],
            pending_count: 5,
            stale_count: 1,
            stale_tasks: vec![],
        };
        let json = serde_json::to_string(&summary).unwrap();
        assert!(json.contains("pendingCount"));
        assert!(json.contains("staleCount"));
    }
}
