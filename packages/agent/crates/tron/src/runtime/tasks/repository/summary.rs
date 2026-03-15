use rusqlite::{Connection, params};

use crate::runtime::tasks::errors::TaskError;
use crate::runtime::tasks::types::{ActiveTaskSummary, ProjectProgressEntry};

use super::common::task_from_row;

pub(super) fn get_active_task_summary(
    conn: &Connection,
    workspace_id: Option<&str>,
) -> Result<ActiveTaskSummary, TaskError> {
    let workspace_condition = workspace_id.map_or("", |_| " AND workspace_id = ?1");

    let in_progress_sql = format!(
        "SELECT * FROM tasks WHERE status = 'in_progress'{workspace_condition} \
         ORDER BY CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 \
         WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END, updated_at DESC"
    );
    let in_progress = if let Some(workspace_id) = workspace_id {
        let mut stmt = conn.prepare(&in_progress_sql)?;
        stmt.query_map(params![workspace_id], |row| Ok(task_from_row(row)))?
            .filter_map(Result::ok)
            .collect()
    } else {
        let mut stmt = conn.prepare(&in_progress_sql)?;
        stmt.query_map([], |row| Ok(task_from_row(row)))?
            .filter_map(Result::ok)
            .collect()
    };

    let pending_sql =
        format!("SELECT COUNT(*) FROM tasks WHERE status = 'pending'{workspace_condition}");
    let pending_count = if let Some(workspace_id) = workspace_id {
        conn.query_row(&pending_sql, params![workspace_id], |row| row.get(0))?
    } else {
        conn.query_row(&pending_sql, [], |row| row.get(0))?
    };

    let overdue_sql = format!(
        "SELECT COUNT(*) FROM tasks WHERE due_date IS NOT NULL \
         AND due_date < datetime('now') \
         AND status NOT IN ('completed', 'cancelled'){workspace_condition}"
    );
    let overdue_count = if let Some(workspace_id) = workspace_id {
        conn.query_row(&overdue_sql, params![workspace_id], |row| row.get(0))?
    } else {
        conn.query_row(&overdue_sql, [], |row| row.get(0))?
    };

    let deferred_sql = format!(
        "SELECT COUNT(*) FROM tasks WHERE deferred_until IS NOT NULL \
         AND deferred_until > datetime('now') \
         AND status NOT IN ('completed', 'cancelled'){workspace_condition}"
    );
    let deferred_count = if let Some(workspace_id) = workspace_id {
        conn.query_row(&deferred_sql, params![workspace_id], |row| row.get(0))?
    } else {
        conn.query_row(&deferred_sql, [], |row| row.get(0))?
    };

    Ok(ActiveTaskSummary {
        in_progress,
        pending_count,
        overdue_count,
        deferred_count,
    })
}

pub(super) fn get_active_project_progress(
    conn: &Connection,
    workspace_id: Option<&str>,
) -> Result<Vec<ProjectProgressEntry>, TaskError> {
    let workspace_condition = workspace_id.map_or("", |_| " AND p.workspace_id = ?1");
    let sql = format!(
        "SELECT p.title, \
           (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id \
            AND t.status IN ('completed', 'cancelled')) as completed, \
           (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id) as total \
         FROM projects p \
         WHERE p.status = 'active'{workspace_condition} \
         ORDER BY p.updated_at DESC"
    );

    let entries = if let Some(workspace_id) = workspace_id {
        let mut stmt = conn.prepare(&sql)?;
        stmt.query_map(params![workspace_id], |row| {
            Ok(ProjectProgressEntry {
                title: row.get(0)?,
                completed: row.get(1)?,
                total: row.get(2)?,
            })
        })?
        .filter_map(Result::ok)
        .collect()
    } else {
        let mut stmt = conn.prepare(&sql)?;
        stmt.query_map([], |row| {
            Ok(ProjectProgressEntry {
                title: row.get(0)?,
                completed: row.get(1)?,
                total: row.get(2)?,
            })
        })?
        .filter_map(Result::ok)
        .collect()
    };

    Ok(entries)
}
