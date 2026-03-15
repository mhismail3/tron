use rusqlite::{Connection, OptionalExtension, params};

use crate::runtime::tasks::errors::TaskError;
use crate::runtime::tasks::types::{
    Project, ProjectCreateParams, ProjectFilter, ProjectListResult, ProjectStatus,
    ProjectUpdateParams, ProjectWithProgress,
};

use super::common::{SqlValue, generate_id, now_iso, parse_tags, project_from_row, tags_to_json};

pub(super) fn create_project(
    conn: &Connection,
    params: &ProjectCreateParams,
) -> Result<Project, TaskError> {
    let id = generate_id("proj");
    let now = now_iso();
    let status = params.status.unwrap_or(ProjectStatus::Active);
    let tags_json = tags_to_json(params.tags.as_deref().unwrap_or(&[]));
    let metadata_json = params.metadata.as_ref().map_or_else(
        || "{}".to_string(),
        |metadata| serde_json::to_string(metadata).unwrap_or_else(|_| "{}".to_string()),
    );

    let _ = conn.execute(
        "INSERT INTO projects (id, workspace_id, area_id, title, description, status,
         tags, created_at, updated_at, metadata)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9)",
        params![
            id,
            params.workspace_id,
            params.area_id,
            params.title,
            params.description,
            status.as_sql(),
            tags_json,
            now,
            metadata_json,
        ],
    )?;

    get_project(conn, &id)?.ok_or_else(|| TaskError::project_not_found(&id))
}

pub(super) fn get_project(conn: &Connection, id: &str) -> Result<Option<Project>, TaskError> {
    conn.query_row("SELECT * FROM projects WHERE id = ?1", params![id], |row| {
        Ok(project_from_row(row))
    })
    .optional()
    .map_err(Into::into)
}

pub(super) fn update_project(
    conn: &Connection,
    id: &str,
    updates: &ProjectUpdateParams,
) -> Result<Option<Project>, TaskError> {
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
    if let Some(ref area_id) = updates.area_id {
        sets.push("area_id = ?".to_string());
        values.push(Box::new(area_id.clone()) as SqlValue);
    }
    if let Some(ref metadata) = updates.metadata {
        sets.push("metadata = ?".to_string());
        values.push(
            Box::new(serde_json::to_string(metadata).unwrap_or_else(|_| "{}".to_string()))
                as SqlValue,
        );
    }

    if updates.add_tags.is_some() || updates.remove_tags.is_some() {
        let current: Option<String> = conn
            .query_row(
                "SELECT tags FROM projects WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
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

    if sets.is_empty() {
        return get_project(conn, id);
    }

    sets.push("updated_at = ?".to_string());
    values.push(Box::new(now_iso()) as SqlValue);
    values.push(Box::new(id.to_string()) as SqlValue);

    let sql = format!("UPDATE projects SET {} WHERE id = ?", sets.join(", "));
    let params_refs: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    let changed = conn.execute(&sql, params_refs.as_slice())?;

    if changed == 0 {
        return Ok(None);
    }

    get_project(conn, id)
}

pub(super) fn delete_project(conn: &Connection, id: &str) -> Result<bool, TaskError> {
    Ok(conn.execute("DELETE FROM projects WHERE id = ?1", params![id])? > 0)
}

pub(super) fn list_projects(
    conn: &Connection,
    filter: &ProjectFilter,
    limit: u32,
    offset: u32,
) -> Result<ProjectListResult, TaskError> {
    let mut conditions = Vec::new();
    let mut values = Vec::new();

    if let Some(status) = filter.status {
        conditions.push("p.status = ?".to_string());
        values.push(Box::new(status.as_sql().to_string()) as SqlValue);
    }
    if let Some(ref workspace_id) = filter.workspace_id {
        conditions.push("p.workspace_id = ?".to_string());
        values.push(Box::new(workspace_id.clone()) as SqlValue);
    }
    if let Some(ref area_id) = filter.area_id {
        conditions.push("p.area_id = ?".to_string());
        values.push(Box::new(area_id.clone()) as SqlValue);
    }

    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", conditions.join(" AND "))
    };

    let count_sql = format!("SELECT COUNT(*) FROM projects p {where_clause}");
    let count_params: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
    let total: u32 = conn.query_row(&count_sql, count_params.as_slice(), |row| row.get(0))?;

    let data_sql = format!(
        "SELECT p.*, \
           (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id) as task_count, \
           (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id \
            AND t.status IN ('completed', 'cancelled')) as completed_task_count \
         FROM projects p {where_clause} \
         ORDER BY p.status, p.updated_at DESC \
         LIMIT ? OFFSET ?"
    );

    let mut data_values = values;
    data_values.push(Box::new(limit) as SqlValue);
    data_values.push(Box::new(offset) as SqlValue);
    let data_params: Vec<&dyn rusqlite::types::ToSql> =
        data_values.iter().map(AsRef::as_ref).collect();

    let mut stmt = conn.prepare(&data_sql)?;
    let projects = stmt
        .query_map(data_params.as_slice(), |row| {
            Ok(ProjectWithProgress {
                project: project_from_row(row),
                task_count: row.get("task_count")?,
                completed_task_count: row.get("completed_task_count")?,
            })
        })?
        .filter_map(Result::ok)
        .collect();

    Ok(ProjectListResult { projects, total })
}
