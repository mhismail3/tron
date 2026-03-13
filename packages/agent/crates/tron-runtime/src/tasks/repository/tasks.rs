use rusqlite::{Connection, OptionalExtension, params};

use crate::tasks::errors::TaskError;
use crate::tasks::types::{
    Task, TaskCreateParams, TaskFilter, TaskListResult, TaskPriority, TaskSource, TaskStatus,
    TaskUpdateParams,
};

use super::common::{
    SqlValue, build_task_where_clause, build_update_sets, generate_id, now_iso, parse_tags,
    tags_to_json, task_from_row,
};

pub(super) fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
    let id = generate_id("task");
    let now = now_iso();
    let status = params.status.unwrap_or(TaskStatus::Pending);
    let priority = params.priority.unwrap_or(TaskPriority::Medium);
    let source = params.source.unwrap_or(TaskSource::Agent);
    let tags_json = tags_to_json(params.tags.as_deref().unwrap_or(&[]));
    let metadata_json = params.metadata.as_ref().map_or_else(
        || "{}".to_string(),
        |metadata| serde_json::to_string(metadata).unwrap_or_else(|_| "{}".to_string()),
    );

    let started_at = (status == TaskStatus::InProgress).then(|| now.clone());

    let project_id = params
        .project_id
        .as_deref()
        .filter(|value| !value.is_empty());
    let parent_task_id = params
        .parent_task_id
        .as_deref()
        .filter(|value| !value.is_empty());
    let area_id = params.area_id.as_deref().filter(|value| !value.is_empty());

    let _ = conn.execute(
        "INSERT INTO tasks (id, project_id, parent_task_id, workspace_id, area_id,
         title, description, active_form, status, priority, source, tags,
         due_date, deferred_until, started_at, estimated_minutes,
         created_by_session_id, last_session_id, last_session_at,
         created_at, updated_at, metadata)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                 ?13, ?14, ?15, ?16, ?17, ?17, ?18, ?18, ?18, ?19)",
        params![
            id,
            project_id,
            parent_task_id,
            params.workspace_id,
            area_id,
            params.title,
            params.description,
            params.active_form,
            status.as_sql(),
            priority.as_sql(),
            source.as_sql(),
            tags_json,
            params.due_date,
            params.deferred_until,
            started_at,
            params.estimated_minutes,
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

    if updates.add_tags.is_some() || updates.remove_tags.is_some() {
        let current: Option<String> = conn
            .query_row("SELECT tags FROM tasks WHERE id = ?1", params![id], |row| {
                row.get(0)
            })
            .optional()?;

        if let Some(current_json) = current {
            let mut tags = parse_tags(&current_json);
            if let Some(ref add_tags) = updates.add_tags {
                for tag in add_tags {
                    if !tags.contains(tag) {
                        tags.push(tag.clone());
                    }
                }
            }
            if let Some(ref remove_tags) = updates.remove_tags {
                tags.retain(|tag| !remove_tags.contains(tag));
            }
            sets.push("tags = ?".to_string());
            values.push(Box::new(tags_to_json(&tags)) as SqlValue);
        }
    }

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

pub(super) fn increment_actual_minutes(
    conn: &Connection,
    id: &str,
    minutes: i32,
) -> Result<(), TaskError> {
    let _ = conn.execute(
        "UPDATE tasks SET actual_minutes = actual_minutes + ?1, updated_at = ?2 WHERE id = ?3",
        params![minutes, now_iso(), id],
    )?;
    Ok(())
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
         ORDER BY \
           CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 \
           WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END, \
           updated_at DESC \
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
    let mut stmt = conn
        .prepare("SELECT * FROM tasks WHERE parent_task_id = ?1 ORDER BY sort_order, created_at")?;
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
