use rusqlite::{Connection, params};

use crate::tasks::errors::TaskError;
use crate::tasks::types::{Task, TaskFilter, TaskUpdateParams};

use super::common::{SqlValue, build_simple_set_clause, build_task_where_clause, task_from_row};

pub(super) fn delete_tasks_by_ids(conn: &Connection, ids: &[String]) -> Result<u32, TaskError> {
    if ids.is_empty() {
        return Ok(0);
    }

    let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!("DELETE FROM tasks WHERE id IN ({placeholders})");
    let params: Vec<&dyn rusqlite::types::ToSql> = ids
        .iter()
        .map(|id| id as &dyn rusqlite::types::ToSql)
        .collect();
    Ok(conn.execute(&sql, params.as_slice())? as u32)
}

pub(super) fn delete_tasks_by_filter(
    conn: &Connection,
    filter: &TaskFilter,
) -> Result<u32, TaskError> {
    let (where_clause, values) = build_task_where_clause(filter);
    let sql = format!("DELETE FROM tasks {where_clause}");
    let params: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    Ok(conn.execute(&sql, params.as_slice())? as u32)
}

pub(super) fn count_tasks_by_ids(conn: &Connection, ids: &[String]) -> Result<u32, TaskError> {
    if ids.is_empty() {
        return Ok(0);
    }

    let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!("SELECT COUNT(*) FROM tasks WHERE id IN ({placeholders})");
    let params: Vec<&dyn rusqlite::types::ToSql> = ids
        .iter()
        .map(|id| id as &dyn rusqlite::types::ToSql)
        .collect();
    conn.query_row(&sql, params.as_slice(), |row| row.get(0))
        .map_err(Into::into)
}

pub(super) fn count_tasks_by_filter(
    conn: &Connection,
    filter: &TaskFilter,
) -> Result<u32, TaskError> {
    let (where_clause, values) = build_task_where_clause(filter);
    let sql = format!("SELECT COUNT(*) FROM tasks {where_clause}");
    let params: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    conn.query_row(&sql, params.as_slice(), |row| row.get(0))
        .map_err(Into::into)
}

pub(super) fn get_tasks_by_ids(conn: &Connection, ids: &[String]) -> Result<Vec<Task>, TaskError> {
    if ids.is_empty() {
        return Ok(vec![]);
    }

    let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!("SELECT * FROM tasks WHERE id IN ({placeholders})");
    let params: Vec<&dyn rusqlite::types::ToSql> = ids
        .iter()
        .map(|id| id as &dyn rusqlite::types::ToSql)
        .collect();
    let mut stmt = conn.prepare(&sql)?;
    let tasks = stmt
        .query_map(params.as_slice(), |row| Ok(task_from_row(row)))?
        .filter_map(Result::ok)
        .collect();
    Ok(tasks)
}

pub(super) fn get_tasks_by_filter(
    conn: &Connection,
    filter: &TaskFilter,
) -> Result<Vec<Task>, TaskError> {
    let (where_clause, values) = build_task_where_clause(filter);
    let sql = format!("SELECT * FROM tasks {where_clause}");
    let params: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    let mut stmt = conn.prepare(&sql)?;
    let tasks = stmt
        .query_map(params.as_slice(), |row| Ok(task_from_row(row)))?
        .filter_map(Result::ok)
        .collect();
    Ok(tasks)
}

pub(super) fn update_tasks_by_ids(
    conn: &Connection,
    ids: &[String],
    updates: &TaskUpdateParams,
) -> Result<u32, TaskError> {
    if ids.is_empty() {
        return Ok(0);
    }

    let (sets, mut values) = build_simple_set_clause(updates)?;
    let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    for id in ids {
        values.push(Box::new(id.clone()) as SqlValue);
    }
    let sql = format!(
        "UPDATE tasks SET {} WHERE id IN ({placeholders})",
        sets.join(", ")
    );
    let params: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    Ok(conn.execute(&sql, params.as_slice())? as u32)
}

pub(super) fn update_tasks_by_filter(
    conn: &Connection,
    filter: &TaskFilter,
    updates: &TaskUpdateParams,
) -> Result<u32, TaskError> {
    let (sets, mut set_values) = build_simple_set_clause(updates)?;
    let (where_clause, where_values) = build_task_where_clause(filter);
    set_values.extend(where_values);
    let sql = format!("UPDATE tasks SET {} {}", sets.join(", "), where_clause);
    let params: Vec<&dyn rusqlite::types::ToSql> = set_values.iter().map(AsRef::as_ref).collect();
    Ok(conn.execute(&sql, params.as_slice())? as u32)
}

pub(super) fn delete_projects_by_ids(conn: &Connection, ids: &[String]) -> Result<u32, TaskError> {
    if ids.is_empty() {
        return Ok(0);
    }

    let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!("DELETE FROM projects WHERE id IN ({placeholders})");
    let params: Vec<&dyn rusqlite::types::ToSql> = ids
        .iter()
        .map(|id| id as &dyn rusqlite::types::ToSql)
        .collect();
    Ok(conn.execute(&sql, params.as_slice())? as u32)
}

pub(super) fn delete_areas_by_ids(conn: &Connection, ids: &[String]) -> Result<u32, TaskError> {
    if ids.is_empty() {
        return Ok(0);
    }

    for id in ids {
        let _ = conn.execute(
            "UPDATE projects SET area_id = NULL WHERE area_id = ?1",
            params![id],
        )?;
        let _ = conn.execute(
            "UPDATE tasks SET area_id = NULL WHERE area_id = ?1",
            params![id],
        )?;
    }

    let placeholders = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
    let sql = format!("DELETE FROM areas WHERE id IN ({placeholders})");
    let params: Vec<&dyn rusqlite::types::ToSql> = ids
        .iter()
        .map(|id| id as &dyn rusqlite::types::ToSql)
        .collect();
    Ok(conn.execute(&sql, params.as_slice())? as u32)
}
