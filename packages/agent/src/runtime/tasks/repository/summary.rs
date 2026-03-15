use rusqlite::Connection;

use crate::runtime::tasks::errors::TaskError;
use crate::runtime::tasks::types::ActiveTaskSummary;

use super::common::task_from_row;

pub(super) fn get_active_task_summary(
    conn: &Connection,
) -> Result<ActiveTaskSummary, TaskError> {
    let mut stmt = conn.prepare(
        "SELECT * FROM tasks WHERE status = 'in_progress' ORDER BY updated_at DESC",
    )?;
    let in_progress = stmt
        .query_map([], |row| Ok(task_from_row(row)))?
        .filter_map(Result::ok)
        .collect();

    let pending_count: u32 =
        conn.query_row("SELECT COUNT(*) FROM tasks WHERE status = 'pending'", [], |row| {
            row.get(0)
        })?;

    let mut stale_stmt =
        conn.prepare("SELECT * FROM tasks WHERE status = 'stale' ORDER BY updated_at DESC")?;
    let stale_tasks: Vec<_> = stale_stmt
        .query_map([], |row| Ok(task_from_row(row)))?
        .filter_map(Result::ok)
        .collect();
    let stale_count = stale_tasks.len() as u32;

    Ok(ActiveTaskSummary {
        in_progress,
        pending_count,
        stale_count,
        stale_tasks,
    })
}
