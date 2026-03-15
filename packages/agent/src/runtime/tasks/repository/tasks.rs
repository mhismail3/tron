use rusqlite::{Connection, OptionalExtension, params};

use crate::runtime::tasks::errors::TaskError;
use crate::runtime::tasks::types::{
    Task, TaskCreateParams, TaskFilter, TaskListResult, TaskStatus, TaskUpdateParams,
};

use super::common::{
    SqlValue, build_task_where_clause, build_update_sets, generate_id, now_iso, task_from_row,
};

pub(super) fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
    let id = generate_id("task");
    let now = now_iso();
    let status = params.status.unwrap_or(TaskStatus::Pending);
    let metadata_json = params.metadata.as_ref().map_or_else(
        || "{}".to_string(),
        |metadata| serde_json::to_string(metadata).unwrap_or_else(|_| "{}".to_string()),
    );

    let started_at = (status == TaskStatus::InProgress).then(|| now.clone());

    let parent_task_id = params
        .parent_task_id
        .as_deref()
        .filter(|value| !value.is_empty());

    let _ = conn.execute(
        "INSERT INTO tasks (id, parent_task_id,
         title, description, active_form, status,
         started_at,
         created_by_session_id, last_session_id, last_session_at,
         created_at, updated_at, metadata)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9, ?9, ?9, ?10)",
        params![
            id,
            parent_task_id,
            params.title,
            params.description,
            params.active_form,
            status.as_sql(),
            started_at,
            params.created_by_session_id,
            now,
            metadata_json,
        ],
    )?;

    get_task(conn, &id)?.ok_or_else(|| TaskError::task_not_found(&id))
}

pub(super) fn get_task(conn: &Connection, id: &str) -> Result<Option<Task>, TaskError> {
    conn.query_row("SELECT * FROM tasks WHERE id = ?1", params![id], |row| {
        Ok(task_from_row(row))
    })
    .optional()
    .map_err(Into::into)
}

pub(super) fn update_task(
    conn: &Connection,
    id: &str,
    updates: &TaskUpdateParams,
) -> Result<Option<Task>, TaskError> {
    let (mut sets, mut values) = build_update_sets(updates);

    if let Some(ref note) = updates.add_note {
        let current_notes: Option<String> = conn
            .query_row(
                "SELECT notes FROM tasks WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();

        let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
        let timestamped = format!("[{today}] {note}");
        let new_notes = match current_notes {
            Some(existing) if !existing.is_empty() => format!("{existing}\n{timestamped}"),
            _ => timestamped,
        };
        sets.push("notes = ?".to_string());
        values.push(Box::new(new_notes) as SqlValue);
    }

    if sets.is_empty() {
        return get_task(conn, id);
    }

    sets.push("updated_at = ?".to_string());
    values.push(Box::new(now_iso()) as SqlValue);
    values.push(Box::new(id.to_string()) as SqlValue);

    let sql = format!("UPDATE tasks SET {} WHERE id = ?", sets.join(", "));
    let params_refs: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    let changed = conn.execute(&sql, params_refs.as_slice())?;

    if changed == 0 {
        return Ok(None);
    }

    get_task(conn, id)
}

pub(super) fn delete_task(conn: &Connection, id: &str) -> Result<bool, TaskError> {
    Ok(conn.execute("DELETE FROM tasks WHERE id = ?1", params![id])? > 0)
}

pub(super) fn list_tasks(
    conn: &Connection,
    filter: &TaskFilter,
    limit: u32,
    offset: u32,
) -> Result<TaskListResult, TaskError> {
    let (where_clause, values) = build_task_where_clause(filter);

    let count_sql = format!("SELECT COUNT(*) FROM tasks {where_clause}");
    let count_params: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    let total: u32 = conn.query_row(&count_sql, count_params.as_slice(), |row| row.get(0))?;

    let data_sql = format!(
        "SELECT * FROM tasks {where_clause} \
         ORDER BY updated_at DESC \
         LIMIT ? OFFSET ?",
    );

    let mut data_values = values;
    data_values.push(Box::new(limit) as SqlValue);
    data_values.push(Box::new(offset) as SqlValue);
    let data_params: Vec<&dyn rusqlite::types::ToSql> =
        data_values.iter().map(AsRef::as_ref).collect();

    let mut stmt = conn.prepare(&data_sql)?;
    let tasks = stmt
        .query_map(data_params.as_slice(), |row| Ok(task_from_row(row)))?
        .filter_map(Result::ok)
        .collect();

    Ok(TaskListResult { tasks, total })
}

pub(super) fn get_subtasks(
    conn: &Connection,
    parent_task_id: &str,
) -> Result<Vec<Task>, TaskError> {
    let mut stmt =
        conn.prepare("SELECT * FROM tasks WHERE parent_task_id = ?1 ORDER BY created_at")?;
    let tasks = stmt
        .query_map(params![parent_task_id], |row| Ok(task_from_row(row)))?
        .filter_map(Result::ok)
        .collect();
    Ok(tasks)
}

pub(super) fn search_tasks(
    conn: &Connection,
    query: &str,
    limit: u32,
) -> Result<Vec<Task>, TaskError> {
    let mut stmt = conn.prepare(
        "SELECT t.* FROM tasks t \
         JOIN tasks_fts f ON f.task_id = t.id \
         WHERE tasks_fts MATCH ?1 \
         ORDER BY rank LIMIT ?2",
    )?;
    let tasks = stmt
        .query_map(params![query, limit], |row| Ok(task_from_row(row)))?
        .filter_map(Result::ok)
        .collect();
    Ok(tasks)
}

pub(super) fn mark_stale_tasks(
    conn: &Connection,
    session_id: &str,
) -> Result<usize, TaskError> {
    let count = conn.execute(
        "UPDATE tasks SET status = 'stale', updated_at = ?1 \
         WHERE last_session_id = ?2 AND status = 'in_progress'",
        params![now_iso(), session_id],
    )?;
    Ok(count)
}
