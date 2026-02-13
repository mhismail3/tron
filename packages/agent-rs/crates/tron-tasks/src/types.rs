//! Core types for the task management system.
//!
//! All serializable types use `camelCase` for wire compatibility with iOS
//! and the dashboard. The type system mirrors the TypeScript implementation
//! exactly to ensure protocol compatibility.

use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────────────────────────────────

/// Task status in the workflow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    /// Not yet prioritized.
    Backlog,
    /// Ready to work on.
    Pending,
    /// Currently being worked on.
    InProgress,
    /// Done.
    Completed,
    /// Abandoned.
    Cancelled,
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
            Self::Backlog => "backlog",
            Self::Pending => "pending",
            Self::InProgress => "in_progress",
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
        }
    }
}

impl std::fmt::Display for TaskStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_sql())
    }
}

/// Task priority level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskPriority {
    /// Low priority.
    Low,
    /// Default priority.
    Medium,
    /// Elevated priority.
    High,
    /// Urgent.
    Critical,
}

impl TaskPriority {
    /// SQL string representation.
    #[must_use]
    pub fn as_sql(self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Critical => "critical",
        }
    }
}

impl std::fmt::Display for TaskPriority {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_sql())
    }
}

/// Source of task creation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskSource {
    /// Created by the agent.
    Agent,
    /// Created by the user.
    User,
    /// Created by a skill.
    Skill,
    /// System-generated.
    System,
}

impl TaskSource {
    /// SQL string representation.
    #[must_use]
    pub fn as_sql(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::User => "user",
            Self::Skill => "skill",
            Self::System => "system",
        }
    }
}

/// Project status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProjectStatus {
    /// Actively being worked on.
    Active,
    /// Temporarily paused.
    Paused,
    /// All tasks done.
    Completed,
    /// No longer relevant.
    Archived,
}

impl ProjectStatus {
    /// SQL string representation.
    #[must_use]
    pub fn as_sql(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Completed => "completed",
            Self::Archived => "archived",
        }
    }
}

/// Area status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AreaStatus {
    /// Active area of responsibility.
    Active,
    /// No longer tracked.
    Archived,
}

impl AreaStatus {
    /// SQL string representation.
    #[must_use]
    pub fn as_sql(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Archived => "archived",
        }
    }
}

/// Type of dependency relationship between tasks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DependencyRelationship {
    /// Blocker must be completed before blocked can start.
    Blocks,
    /// Tasks are related but not blocking.
    Related,
}

impl DependencyRelationship {
    /// SQL string representation.
    #[must_use]
    pub fn as_sql(self) -> &'static str {
        match self {
            Self::Blocks => "blocks",
            Self::Related => "related",
        }
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
    /// Time logged on task.
    TimeLogged,
    /// Dependency added.
    DependencyAdded,
    /// Dependency removed.
    DependencyRemoved,
    /// Task moved to different project/parent.
    Moved,
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
            Self::TimeLogged => "time_logged",
            Self::DependencyAdded => "dependency_added",
            Self::DependencyRemoved => "dependency_removed",
            Self::Moved => "moved",
            Self::Deleted => "deleted",
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
    /// Project this task belongs to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    /// Parent task (for subtasks).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_task_id: Option<String>,
    /// Workspace scope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// Area of responsibility.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub area_id: Option<String>,
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
    /// Priority level.
    pub priority: TaskPriority,
    /// Who/what created this task.
    pub source: TaskSource,
    /// Categorization tags.
    pub tags: Vec<String>,
    /// When this task is due.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    /// Deferred until this date.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deferred_until: Option<String>,
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
    /// Estimated effort in minutes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_minutes: Option<i32>,
    /// Actual effort in minutes.
    pub actual_minutes: i32,
    /// Session that created this task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_by_session_id: Option<String>,
    /// Last session to modify this task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_session_id: Option<String>,
    /// When last session modified this task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_session_at: Option<String>,
    /// Display ordering.
    pub sort_order: i32,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

/// A project grouping tasks.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    /// Unique ID (prefixed: `proj-{uuid}`).
    pub id: String,
    /// Workspace scope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// Area of responsibility.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub area_id: Option<String>,
    /// Project title.
    pub title: String,
    /// Detailed description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Current status.
    pub status: ProjectStatus,
    /// Categorization tags.
    pub tags: Vec<String>,
    /// Creation timestamp.
    pub created_at: String,
    /// Last update timestamp.
    pub updated_at: String,
    /// When project was completed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

/// An area of ongoing responsibility (PARA model).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Area {
    /// Unique ID (prefixed: `area-{uuid}`).
    pub id: String,
    /// Workspace scope.
    pub workspace_id: String,
    /// Area title.
    pub title: String,
    /// Detailed description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Current status.
    pub status: AreaStatus,
    /// Categorization tags.
    pub tags: Vec<String>,
    /// Display ordering (REAL in `SQLite` for fractional ordering).
    pub sort_order: f64,
    /// Creation timestamp.
    pub created_at: String,
    /// Last update timestamp.
    pub updated_at: String,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

/// A dependency relationship between two tasks.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskDependency {
    /// The task that blocks.
    pub blocker_task_id: String,
    /// The task being blocked.
    pub blocked_task_id: String,
    /// Type of relationship.
    pub relationship: DependencyRelationship,
    /// When the dependency was created.
    pub created_at: String,
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
    /// Minutes logged (for `TimeLogged` action).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minutes_logged: Option<i32>,
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
    /// Dependencies blocking this task.
    pub blocked_by: Vec<TaskDependency>,
    /// Tasks this task blocks.
    pub blocks: Vec<TaskDependency>,
    /// Recent activity log.
    pub recent_activity: Vec<TaskActivity>,
}

/// Project with progress counts.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectWithProgress {
    /// The project itself.
    #[serde(flatten)]
    pub project: Project,
    /// Total number of tasks in this project.
    pub task_count: u32,
    /// Number of completed tasks.
    pub completed_task_count: u32,
}

/// Area with related counts.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AreaWithCounts {
    /// The area itself.
    #[serde(flatten)]
    pub area: Area,
    /// Number of projects in this area.
    pub project_count: u32,
    /// Total tasks in this area.
    pub task_count: u32,
    /// Non-terminal tasks in this area.
    pub active_task_count: u32,
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
    /// Project to assign to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    /// Parent task (makes this a subtask).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_task_id: Option<String>,
    /// Workspace scope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// Area of responsibility.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub area_id: Option<String>,
    /// Detailed description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Present continuous form for UI.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_form: Option<String>,
    /// Initial status (default: Pending).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskStatus>,
    /// Initial priority (default: Medium).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<TaskPriority>,
    /// Source of creation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<TaskSource>,
    /// Initial tags.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    /// Due date.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    /// Deferred until date.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deferred_until: Option<String>,
    /// Estimated effort in minutes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_minutes: Option<i32>,
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
    /// New priority.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<TaskPriority>,
    /// Move to different project.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    /// Move to different parent task.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_task_id: Option<String>,
    /// Move to different area.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub area_id: Option<String>,
    /// New due date.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    /// New deferred-until date.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deferred_until: Option<String>,
    /// New estimated minutes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_minutes: Option<i32>,
    /// Tags to add.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub add_tags: Option<Vec<String>>,
    /// Tags to remove.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remove_tags: Option<Vec<String>>,
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

/// Parameters for creating a project.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCreateParams {
    /// Project title (required).
    pub title: String,
    /// Workspace scope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// Area of responsibility.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub area_id: Option<String>,
    /// Detailed description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Initial status (default: Active).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<ProjectStatus>,
    /// Initial tags.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

/// Parameters for updating a project.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectUpdateParams {
    /// New title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// New description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// New status.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<ProjectStatus>,
    /// New area.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub area_id: Option<String>,
    /// Tags to add.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub add_tags: Option<Vec<String>>,
    /// Tags to remove.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remove_tags: Option<Vec<String>>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

/// Parameters for creating an area.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AreaCreateParams {
    /// Area title (required).
    pub title: String,
    /// Workspace scope (default: "default").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// Detailed description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Initial status (default: Active).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<AreaStatus>,
    /// Initial tags.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    /// Display order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort_order: Option<f64>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

/// Parameters for updating an area.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AreaUpdateParams {
    /// New title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// New description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// New status.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<AreaStatus>,
    /// New sort order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort_order: Option<f64>,
    /// Tags to add.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub add_tags: Option<Vec<String>>,
    /// Tags to remove.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remove_tags: Option<Vec<String>>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter types
// ─────────────────────────────────────────────────────────────────────────────

/// Filter parameters for listing tasks.
#[derive(Debug, Clone, Default)]
pub struct TaskFilter {
    /// Filter by status.
    pub status: Option<TaskStatus>,
    /// Filter by priority.
    pub priority: Option<TaskPriority>,
    /// Filter by tags (any match).
    pub tags: Option<Vec<String>>,
    /// Filter by project.
    pub project_id: Option<String>,
    /// Filter by workspace.
    pub workspace_id: Option<String>,
    /// Filter by area.
    pub area_id: Option<String>,
    /// Filter by parent task.
    pub parent_task_id: Option<String>,
    /// Only tasks due before this date.
    pub due_before: Option<String>,
    /// Include completed/cancelled tasks.
    pub include_completed: bool,
    /// Include deferred tasks.
    pub include_deferred: bool,
    /// Include backlog tasks.
    pub include_backlog: bool,
}

/// Filter parameters for listing projects.
#[derive(Debug, Clone, Default)]
pub struct ProjectFilter {
    /// Filter by status.
    pub status: Option<ProjectStatus>,
    /// Filter by workspace.
    pub workspace_id: Option<String>,
    /// Filter by area.
    pub area_id: Option<String>,
}

/// Filter parameters for listing areas.
#[derive(Debug, Clone, Default)]
pub struct AreaFilter {
    /// Filter by status.
    pub status: Option<AreaStatus>,
    /// Filter by workspace.
    pub workspace_id: Option<String>,
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

/// Paginated project list result.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectListResult {
    /// Projects matching the filter.
    pub projects: Vec<ProjectWithProgress>,
    /// Total count (ignoring pagination).
    pub total: u32,
}

/// Paginated area list result.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AreaListResult {
    /// Areas matching the filter.
    pub areas: Vec<AreaWithCounts>,
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
    /// Count of overdue tasks.
    pub overdue_count: u32,
    /// Count of deferred tasks.
    pub deferred_count: u32,
}

/// Progress entry for a project (used in context builder).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectProgressEntry {
    /// Project title.
    pub title: String,
    /// Completed task count.
    pub completed: u32,
    /// Total task count.
    pub total: u32,
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
    /// Minutes logged.
    pub minutes_logged: Option<i32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_task_status_serde_roundtrip() {
        for status in [
            TaskStatus::Backlog,
            TaskStatus::Pending,
            TaskStatus::InProgress,
            TaskStatus::Completed,
            TaskStatus::Cancelled,
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
            serde_json::to_string(&TaskStatus::Backlog).unwrap(),
            "\"backlog\""
        );
    }

    #[test]
    fn test_task_status_is_terminal() {
        assert!(TaskStatus::Completed.is_terminal());
        assert!(TaskStatus::Cancelled.is_terminal());
        assert!(!TaskStatus::Pending.is_terminal());
        assert!(!TaskStatus::InProgress.is_terminal());
        assert!(!TaskStatus::Backlog.is_terminal());
    }

    #[test]
    fn test_task_priority_serde_roundtrip() {
        for priority in [
            TaskPriority::Low,
            TaskPriority::Medium,
            TaskPriority::High,
            TaskPriority::Critical,
        ] {
            let json = serde_json::to_string(&priority).unwrap();
            let back: TaskPriority = serde_json::from_str(&json).unwrap();
            assert_eq!(back, priority);
        }
    }

    #[test]
    fn test_project_status_serde_roundtrip() {
        for status in [
            ProjectStatus::Active,
            ProjectStatus::Paused,
            ProjectStatus::Completed,
            ProjectStatus::Archived,
        ] {
            let json = serde_json::to_string(&status).unwrap();
            let back: ProjectStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(back, status);
        }
    }

    #[test]
    fn test_area_status_serde_roundtrip() {
        for status in [AreaStatus::Active, AreaStatus::Archived] {
            let json = serde_json::to_string(&status).unwrap();
            let back: AreaStatus = serde_json::from_str(&json).unwrap();
            assert_eq!(back, status);
        }
    }

    #[test]
    fn test_dependency_relationship_serde() {
        assert_eq!(
            serde_json::to_string(&DependencyRelationship::Blocks).unwrap(),
            "\"blocks\""
        );
        assert_eq!(
            serde_json::to_string(&DependencyRelationship::Related).unwrap(),
            "\"related\""
        );
    }

    #[test]
    fn test_activity_action_serde_roundtrip() {
        for action in [
            ActivityAction::Created,
            ActivityAction::StatusChanged,
            ActivityAction::Updated,
            ActivityAction::NoteAdded,
            ActivityAction::TimeLogged,
            ActivityAction::DependencyAdded,
            ActivityAction::DependencyRemoved,
            ActivityAction::Moved,
            ActivityAction::Deleted,
        ] {
            let json = serde_json::to_string(&action).unwrap();
            let back: ActivityAction = serde_json::from_str(&json).unwrap();
            assert_eq!(back, action);
        }
    }

    #[test]
    fn test_task_serde_roundtrip() {
        let task = Task {
            id: "task-123".to_string(),
            project_id: Some("proj-1".to_string()),
            parent_task_id: None,
            workspace_id: Some("ws-1".to_string()),
            area_id: None,
            title: "Fix bug".to_string(),
            description: Some("Details here".to_string()),
            active_form: Some("Fixing bug".to_string()),
            notes: None,
            status: TaskStatus::InProgress,
            priority: TaskPriority::High,
            source: TaskSource::Agent,
            tags: vec!["bug".to_string(), "urgent".to_string()],
            due_date: Some("2026-02-15".to_string()),
            deferred_until: None,
            started_at: Some("2026-02-10T10:00:00Z".to_string()),
            completed_at: None,
            created_at: "2026-02-10T09:00:00Z".to_string(),
            updated_at: "2026-02-10T10:00:00Z".to_string(),
            estimated_minutes: Some(60),
            actual_minutes: 30,
            created_by_session_id: Some("s-1".to_string()),
            last_session_id: Some("s-2".to_string()),
            last_session_at: Some("2026-02-10T10:00:00Z".to_string()),
            sort_order: 0,
            metadata: None,
        };
        let json = serde_json::to_string(&task).unwrap();
        let back: Task = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, task.id);
        assert_eq!(back.status, task.status);
        assert_eq!(back.priority, task.priority);
    }

    #[test]
    fn test_task_serde_camel_case() {
        let task = Task {
            id: "t1".to_string(),
            project_id: None,
            parent_task_id: None,
            workspace_id: None,
            area_id: None,
            title: "Test".to_string(),
            description: None,
            active_form: None,
            notes: None,
            status: TaskStatus::Pending,
            priority: TaskPriority::Medium,
            source: TaskSource::Agent,
            tags: vec![],
            due_date: None,
            deferred_until: None,
            started_at: None,
            completed_at: None,
            created_at: "now".to_string(),
            updated_at: "now".to_string(),
            estimated_minutes: None,
            actual_minutes: 0,
            created_by_session_id: None,
            last_session_id: None,
            last_session_at: None,
            sort_order: 0,
            metadata: None,
        };
        let json = serde_json::to_string(&task).unwrap();
        assert!(json.contains("createdAt"));
        assert!(json.contains("updatedAt"));
        assert!(json.contains("sortOrder"));
        assert!(json.contains("actualMinutes"));
        // None fields should be skipped
        assert!(!json.contains("projectId"));
        assert!(!json.contains("parentTaskId"));
    }

    #[test]
    fn test_project_serde_roundtrip() {
        let project = Project {
            id: "proj-1".to_string(),
            workspace_id: Some("ws-1".to_string()),
            area_id: None,
            title: "Dashboard v2".to_string(),
            description: Some("Redesign".to_string()),
            status: ProjectStatus::Active,
            tags: vec!["frontend".to_string()],
            created_at: "2026-01-01".to_string(),
            updated_at: "2026-02-01".to_string(),
            completed_at: None,
            metadata: None,
        };
        let json = serde_json::to_string(&project).unwrap();
        let back: Project = serde_json::from_str(&json).unwrap();
        assert_eq!(back.title, project.title);
    }

    #[test]
    fn test_area_serde_roundtrip() {
        let area = Area {
            id: "area-1".to_string(),
            workspace_id: "default".to_string(),
            title: "Engineering".to_string(),
            description: Some("Core development".to_string()),
            status: AreaStatus::Active,
            tags: vec![],
            sort_order: 1.5,
            created_at: "2026-01-01".to_string(),
            updated_at: "2026-01-01".to_string(),
            metadata: None,
        };
        let json = serde_json::to_string(&area).unwrap();
        let back: Area = serde_json::from_str(&json).unwrap();
        assert_eq!(back.title, area.title);
        assert!((back.sort_order - 1.5).abs() < f64::EPSILON);
    }

    #[test]
    fn test_task_dependency_serde() {
        let dep = TaskDependency {
            blocker_task_id: "t1".to_string(),
            blocked_task_id: "t2".to_string(),
            relationship: DependencyRelationship::Blocks,
            created_at: "2026-01-01".to_string(),
        };
        let json = serde_json::to_string(&dep).unwrap();
        assert!(json.contains("blockerTaskId"));
        assert!(json.contains("blockedTaskId"));
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
            minutes_logged: None,
            timestamp: "2026-01-01".to_string(),
        };
        let json = serde_json::to_string(&activity).unwrap();
        assert!(json.contains("statusChanged") || json.contains("status_changed"));
    }

    #[test]
    fn test_task_create_params_default() {
        let params = TaskCreateParams::default();
        assert!(params.title.is_empty());
        assert!(params.status.is_none());
        assert!(params.priority.is_none());
    }

    #[test]
    fn test_active_task_summary_serde() {
        let summary = ActiveTaskSummary {
            in_progress: vec![],
            pending_count: 5,
            overdue_count: 1,
            deferred_count: 2,
        };
        let json = serde_json::to_string(&summary).unwrap();
        assert!(json.contains("pendingCount"));
        assert!(json.contains("overdueCount"));
        assert!(json.contains("deferredCount"));
    }
}
