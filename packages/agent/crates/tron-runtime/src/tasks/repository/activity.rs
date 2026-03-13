use rusqlite::{Connection, params};

use crate::tasks::errors::TaskError;
use crate::tasks::types::{ActivityAction, LogActivityParams, TaskActivity};

use super::common::now_iso;

pub(super) fn log_activity(conn: &Connection, params: &LogActivityParams) -> Result<(), TaskError> {
    let _ = conn.execute(
        "INSERT INTO task_activity \
         (task_id, session_id, event_id, action, old_value, new_value, detail, \
          minutes_logged, timestamp) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![
            params.task_id,
            params.session_id,
            params.event_id,
            params.action.as_sql(),
            params.old_value,
            params.new_value,
            params.detail,
            params.minutes_logged,
            now_iso(),
        ],
    )?;
    Ok(())
}

pub(super) fn get_activity(
    conn: &Connection,
    task_id: &str,
    limit: u32,
) -> Result<Vec<TaskActivity>, TaskError> {
    let mut stmt = conn.prepare(
        "SELECT id, task_id, session_id, event_id, action, old_value, new_value, \
         detail, minutes_logged, timestamp \
         FROM task_activity WHERE task_id = ?1 ORDER BY id DESC LIMIT ?2",
    )?;
    let activities = stmt
        .query_map(params![task_id, limit], |row| {
            Ok(TaskActivity {
                id: row.get(0)?,
                task_id: row.get(1)?,
                session_id: row.get(2)?,
                event_id: row.get(3)?,
                action: ActivityAction::from_sql(&row.get::<_, String>(4)?),
                old_value: row.get(5)?,
                new_value: row.get(6)?,
                detail: row.get(7)?,
                minutes_logged: row.get(8)?,
                timestamp: row.get(9)?,
            })
        })?
        .filter_map(Result::ok)
        .collect();
    Ok(activities)
}
