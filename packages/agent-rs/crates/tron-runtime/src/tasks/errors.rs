//! Task error types.
//!
//! All errors are structured with typed variants for each failure mode.
//! Unlike memory errors, task errors are **not** fail-silent — callers
//! should handle them (typically returning RPC errors to the client).

use thiserror::Error;

/// Errors from task operations.
#[derive(Debug, Error)]
pub enum TaskError {
    /// Database operation failed.
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    /// Entity not found.
    #[error("{entity} not found: {id}")]
    NotFound {
        /// Entity type (e.g., "Task", "Project", "Area").
        entity: &'static str,
        /// The ID that was looked up.
        id: String,
    },

    /// Validation failure.
    #[error("Validation error: {0}")]
    Validation(String),

    /// Circular dependency detected.
    #[error("Circular dependency: {blocker_id} → {blocked_id}")]
    CircularDependency {
        /// The task that would block.
        blocker_id: String,
        /// The task that would be blocked.
        blocked_id: String,
    },

    /// Hierarchy violation (e.g., subtask of subtask).
    #[error("Hierarchy error: {0}")]
    Hierarchy(String),

    /// Serialization/deserialization error.
    #[error("Serialization error: {0}")]
    Serialization(String),
}

impl TaskError {
    /// Create a not-found error for a task.
    pub fn task_not_found(id: impl Into<String>) -> Self {
        Self::NotFound {
            entity: "Task",
            id: id.into(),
        }
    }

    /// Create a not-found error for a project.
    pub fn project_not_found(id: impl Into<String>) -> Self {
        Self::NotFound {
            entity: "Project",
            id: id.into(),
        }
    }

    /// Create a not-found error for an area.
    pub fn area_not_found(id: impl Into<String>) -> Self {
        Self::NotFound {
            entity: "Area",
            id: id.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_task_not_found_display() {
        let err = TaskError::task_not_found("task-123");
        assert_eq!(err.to_string(), "Task not found: task-123");
    }

    #[test]
    fn test_project_not_found_display() {
        let err = TaskError::project_not_found("proj-456");
        assert_eq!(err.to_string(), "Project not found: proj-456");
    }

    #[test]
    fn test_area_not_found_display() {
        let err = TaskError::area_not_found("area-789");
        assert_eq!(err.to_string(), "Area not found: area-789");
    }

    #[test]
    fn test_validation_display() {
        let err = TaskError::Validation("title is required".to_string());
        assert_eq!(err.to_string(), "Validation error: title is required");
    }

    #[test]
    fn test_circular_dependency_display() {
        let err = TaskError::CircularDependency {
            blocker_id: "a".to_string(),
            blocked_id: "b".to_string(),
        };
        assert_eq!(err.to_string(), "Circular dependency: a → b");
    }

    #[test]
    fn test_hierarchy_display() {
        let err = TaskError::Hierarchy("subtask cannot have children".to_string());
        assert_eq!(
            err.to_string(),
            "Hierarchy error: subtask cannot have children"
        );
    }

    #[test]
    fn test_database_from_rusqlite() {
        let sqlite_err =
            rusqlite::Error::SqliteFailure(rusqlite::ffi::Error::new(1), Some("test".to_string()));
        let err = TaskError::from(sqlite_err);
        assert!(err.to_string().contains("Database error"));
    }
}
