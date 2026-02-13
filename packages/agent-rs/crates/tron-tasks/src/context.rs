//! Task context builder for LLM system prompt injection.
//!
//! Generates a concise summary of active tasks, projects, and areas that
//! gets injected into the system prompt. Returns `None` if there are no
//! open tasks (no point consuming tokens for empty context).

use std::fmt::Write;

use rusqlite::Connection;

use crate::errors::TaskError;
use crate::repository::TaskRepository;
use crate::types::{AreaFilter, AreaStatus, TaskPriority};

/// Build a summary of active tasks for LLM context injection.
///
/// Returns `None` if there are no active tasks, projects, or areas.
///
/// # Output format
///
/// ```text
/// Active: 2 in progress, 5 pending, 1 blocked
/// In Progress:
///   - [task-abc] Fix authentication bug (P:high, 30/60min, due:2026-02-15)
///   - [task-xyz] Add dark mode support
/// Projects: Dashboard v2 (3/8), Mobile App (12/15)
/// Areas:
///   - Engineering — Core product development (8 active tasks, 3 projects)
/// 2 tasks overdue | 3 tasks deferred
/// ```
pub fn build_task_context(
    conn: &Connection,
    workspace_id: Option<&str>,
) -> Result<Option<String>, TaskError> {
    let summary = TaskRepository::get_active_task_summary(conn, workspace_id)?;
    let blocked_count = TaskRepository::get_blocked_task_count(conn, workspace_id)?;
    let project_progress = TaskRepository::get_active_project_progress(conn, workspace_id)?;
    let areas = TaskRepository::list_areas(
        conn,
        &AreaFilter {
            status: Some(AreaStatus::Active),
            workspace_id: workspace_id.map(String::from),
        },
        50,
        0,
    )?;

    // Nothing to report
    if summary.in_progress.is_empty()
        && summary.pending_count == 0
        && blocked_count == 0
        && project_progress.is_empty()
        && areas.areas.is_empty()
    {
        return Ok(None);
    }

    let mut output = String::new();

    // Active counts line
    let _ = write!(
        output,
        "Active: {} in progress, {} pending, {} blocked",
        summary.in_progress.len(),
        summary.pending_count,
        blocked_count,
    );

    // In-progress tasks
    if !summary.in_progress.is_empty() {
        let _ = write!(output, "\nIn Progress:");
        for task in &summary.in_progress {
            let _ = write!(output, "\n  - [{}] {}", task.id, task.title);
            let mut annotations: Vec<String> = Vec::new();
            if task.priority != TaskPriority::Medium {
                annotations.push(format!("P:{}", task.priority));
            }
            if task.estimated_minutes.is_some() || task.actual_minutes > 0 {
                let actual = task.actual_minutes;
                if let Some(est) = task.estimated_minutes {
                    annotations.push(format!("{actual}/{est}min"));
                } else {
                    annotations.push(format!("{actual}min"));
                }
            }
            if let Some(ref due) = task.due_date {
                annotations.push(format!("due:{due}"));
            }
            if !annotations.is_empty() {
                let _ = write!(output, " ({})", annotations.join(", "));
            }
        }
    }

    // Projects
    if !project_progress.is_empty() {
        let _ = write!(output, "\nProjects: ");
        let project_strs: Vec<String> = project_progress
            .iter()
            .map(|p| format!("{} ({}/{})", p.title, p.completed, p.total))
            .collect();
        let _ = write!(output, "{}", project_strs.join(", "));
    }

    // Areas
    if !areas.areas.is_empty() {
        let _ = write!(output, "\nAreas:");
        for area_with_counts in &areas.areas {
            let _ = write!(
                output,
                "\n  - {}",
                area_with_counts.area.title
            );
            if let Some(ref desc) = area_with_counts.area.description {
                let _ = write!(output, " — {desc}");
            }
            let _ = write!(
                output,
                " ({} active tasks, {} projects)",
                area_with_counts.active_task_count, area_with_counts.project_count
            );
        }
    }

    // Warnings
    let mut warnings: Vec<String> = Vec::new();
    if summary.overdue_count > 0 {
        warnings.push(format!("{} tasks overdue", summary.overdue_count));
    }
    if summary.deferred_count > 0 {
        warnings.push(format!("{} tasks deferred", summary.deferred_count));
    }
    if !warnings.is_empty() {
        let _ = write!(output, "\n{}", warnings.join(" | "));
    }

    Ok(Some(output))
}

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::migrations::run_migrations;
    use crate::types::*;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    #[test]
    fn test_empty_returns_none() {
        let conn = setup_db();
        let result = build_task_context(&conn, None).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_single_in_progress_task() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Fix bug".to_string(),
                status: Some(TaskStatus::InProgress),
                priority: Some(TaskPriority::High),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn, None).unwrap().unwrap();
        assert!(result.contains("1 in progress"));
        assert!(result.contains("Fix bug"));
        assert!(result.contains("P:high"));
    }

    #[test]
    fn test_with_projects() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Dashboard v2".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task 1".to_string(),
                project_id: Some(project.id.clone()),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task 2".to_string(),
                project_id: Some(project.id),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn, None).unwrap().unwrap();
        assert!(result.contains("Dashboard v2 (1/2)"));
    }

    #[test]
    fn test_with_areas() {
        let conn = setup_db();
        let area = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Engineering".to_string(),
                description: Some("Core product development".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active task".to_string(),
                area_id: Some(area.id),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn, None).unwrap().unwrap();
        assert!(result.contains("Engineering"));
        assert!(result.contains("Core product development"));
    }

    #[test]
    fn test_time_tracking_display() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Time tracked".to_string(),
                status: Some(TaskStatus::InProgress),
                estimated_minutes: Some(60),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn, None).unwrap().unwrap();
        assert!(result.contains("0/60min"));
    }

    #[test]
    fn test_due_date_display() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Due soon".to_string(),
                status: Some(TaskStatus::InProgress),
                due_date: Some("2026-02-15".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn, None).unwrap().unwrap();
        assert!(result.contains("due:2026-02-15"));
    }

    #[test]
    fn test_medium_priority_not_shown() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Normal task".to_string(),
                status: Some(TaskStatus::InProgress),
                priority: Some(TaskPriority::Medium),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn, None).unwrap().unwrap();
        assert!(!result.contains("P:medium"));
    }

    #[test]
    fn test_blocked_count() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Blocker".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Blocked".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(
            &conn,
            &t1.id,
            &t2.id,
            DependencyRelationship::Blocks,
        )
        .unwrap();
        let result = build_task_context(&conn, None).unwrap().unwrap();
        assert!(result.contains("1 blocked"));
    }
}
