use rusqlite::{Connection, OptionalExtension, params};

use crate::tasks::errors::TaskError;
use crate::tasks::types::{
    Area, AreaCreateParams, AreaFilter, AreaListResult, AreaStatus, AreaUpdateParams,
    AreaWithCounts,
};

use super::common::{SqlValue, area_from_row, generate_id, now_iso, parse_tags, tags_to_json};

pub(super) fn create_area(conn: &Connection, params: &AreaCreateParams) -> Result<Area, TaskError> {
    let id = generate_id("area");
    let now = now_iso();
    let status = params.status.unwrap_or(AreaStatus::Active);
    let workspace_id = params.workspace_id.as_deref().unwrap_or("default");
    let tags_json = tags_to_json(params.tags.as_deref().unwrap_or(&[]));
    let metadata_json = params.metadata.as_ref().map_or_else(
        || "{}".to_string(),
        |metadata| serde_json::to_string(metadata).unwrap_or_else(|_| "{}".to_string()),
    );

    let _ = conn.execute(
        "INSERT INTO areas (id, workspace_id, title, description, status,
         tags, sort_order, created_at, updated_at, metadata)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9)",
        params![
            id,
            workspace_id,
            params.title,
            params.description,
            status.as_sql(),
            tags_json,
            params.sort_order.unwrap_or(0.0),
            now,
            metadata_json,
        ],
    )?;

    get_area(conn, &id)?.ok_or_else(|| TaskError::area_not_found(&id))
}

pub(super) fn get_area(conn: &Connection, id: &str) -> Result<Option<Area>, TaskError> {
    conn.query_row("SELECT * FROM areas WHERE id = ?1", params![id], |row| {
        Ok(area_from_row(row))
    })
    .optional()
    .map_err(Into::into)
}

pub(super) fn update_area(
    conn: &Connection,
    id: &str,
    updates: &AreaUpdateParams,
) -> Result<Option<Area>, TaskError> {
    let mut sets = Vec::new();
    let mut values = Vec::new();

    if let Some(ref title) = updates.title {
        sets.push("title = ?".to_string());
        values.push(Box::new(title.clone()) as SqlValue);
    }
    if let Some(ref description) = updates.description {
        sets.push("description = ?".to_string());
        values.push(Box::new(description.clone()) as SqlValue);
    }
    if let Some(status) = updates.status {
        sets.push("status = ?".to_string());
        values.push(Box::new(status.as_sql().to_string()) as SqlValue);
    }
    if let Some(sort_order) = updates.sort_order {
        sets.push("sort_order = ?".to_string());
        values.push(Box::new(sort_order) as SqlValue);
    }

    if updates.add_tags.is_some() || updates.remove_tags.is_some() {
        let current: Option<String> = conn
            .query_row("SELECT tags FROM areas WHERE id = ?1", params![id], |row| {
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

    if let Some(ref metadata) = updates.metadata {
        sets.push("metadata = ?".to_string());
        values.push(
            Box::new(serde_json::to_string(metadata).unwrap_or_else(|_| "{}".to_string()))
                as SqlValue,
        );
    }

    if sets.is_empty() {
        return get_area(conn, id);
    }

    sets.push("updated_at = ?".to_string());
    values.push(Box::new(now_iso()) as SqlValue);
    values.push(Box::new(id.to_string()) as SqlValue);

    let sql = format!("UPDATE areas SET {} WHERE id = ?", sets.join(", "));
    let params_refs: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    let changed = conn.execute(&sql, params_refs.as_slice())?;

    if changed == 0 {
        return Ok(None);
    }

    get_area(conn, id)
}

pub(super) fn delete_area(conn: &Connection, id: &str) -> Result<bool, TaskError> {
    let _ = conn.execute(
        "UPDATE projects SET area_id = NULL WHERE area_id = ?1",
        params![id],
    )?;
    let _ = conn.execute(
        "UPDATE tasks SET area_id = NULL WHERE area_id = ?1",
        params![id],
    )?;
    Ok(conn.execute("DELETE FROM areas WHERE id = ?1", params![id])? > 0)
}

pub(super) fn list_areas(
    conn: &Connection,
    filter: &AreaFilter,
    limit: u32,
    offset: u32,
) -> Result<AreaListResult, TaskError> {
    let mut conditions = Vec::new();
    let mut values = Vec::new();

    if let Some(status) = filter.status {
        conditions.push("a.status = ?".to_string());
        values.push(Box::new(status.as_sql().to_string()) as SqlValue);
    }
    if let Some(ref workspace_id) = filter.workspace_id {
        conditions.push("a.workspace_id = ?".to_string());
        values.push(Box::new(workspace_id.clone()) as SqlValue);
    }

    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", conditions.join(" AND "))
    };

    let count_sql = format!("SELECT COUNT(*) FROM areas a {where_clause}");
    let count_params: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    let total: u32 = conn.query_row(&count_sql, count_params.as_slice(), |row| row.get(0))?;

    let data_sql = format!(
        "SELECT a.*, \
           (SELECT COUNT(*) FROM projects p WHERE p.area_id = a.id) as project_count, \
           (SELECT COUNT(*) FROM tasks t WHERE t.area_id = a.id) as task_count, \
           (SELECT COUNT(*) FROM tasks t WHERE t.area_id = a.id \
            AND t.status NOT IN ('completed', 'cancelled')) as active_task_count \
         FROM areas a {where_clause} \
         ORDER BY a.sort_order, a.updated_at DESC \
         LIMIT ? OFFSET ?"
    );

    let mut data_values = values;
    data_values.push(Box::new(limit) as SqlValue);
    data_values.push(Box::new(offset) as SqlValue);
    let data_params: Vec<&dyn rusqlite::types::ToSql> =
        data_values.iter().map(AsRef::as_ref).collect();

    let mut stmt = conn.prepare(&data_sql)?;
    let areas = stmt
        .query_map(data_params.as_slice(), |row| {
            Ok(AreaWithCounts {
                area: area_from_row(row),
                project_count: row.get("project_count")?,
                task_count: row.get("task_count")?,
                active_task_count: row.get("active_task_count")?,
            })
        })?
        .filter_map(Result::ok)
        .collect();

    Ok(AreaListResult { areas, total })
}
