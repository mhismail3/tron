//! SQL data access layer for tasks, projects, and areas.
//!
//! All methods take a `&Connection` parameter and are stateless — pure functions
//! that translate between Rust types and SQL. Uses `uuid::Uuid::now_v7()` for
//! time-ordered ID generation with entity-specific prefixes.

use std::collections::VecDeque;

use rusqlite::{params, Connection, OptionalExtension};
use uuid::Uuid;

use crate::errors::TaskError;
use crate::types::{
    ActiveTaskSummary, ActivityAction, Area, AreaCreateParams, AreaFilter, AreaListResult,
    AreaStatus, AreaUpdateParams, AreaWithCounts, DependencyRelationship, LogActivityParams,
    Project, ProjectCreateParams, ProjectFilter, ProjectListResult, ProjectProgressEntry,
    ProjectStatus, ProjectUpdateParams, ProjectWithProgress, Task, TaskActivity, TaskCreateParams,
    TaskDependency, TaskFilter, TaskListResult, TaskPriority, TaskSource, TaskStatus,
    TaskUpdateParams,
};

/// Generate a prefixed UUID v7 ID.
fn generate_id(prefix: &str) -> String {
    format!("{prefix}-{}", Uuid::now_v7())
}

/// Get current UTC timestamp as ISO 8601 string.
fn now_iso() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// Parse a JSON array string into a `Vec<String>`.
fn parse_tags(json: &str) -> Vec<String> {
    serde_json::from_str(json).unwrap_or_default()
}

/// Serialize tags to a JSON array string.
fn tags_to_json(tags: &[String]) -> String {
    serde_json::to_string(tags).unwrap_or_else(|_| "[]".to_string())
}

/// Parse optional JSON metadata.
fn parse_metadata(json: Option<String>) -> Option<serde_json::Value> {
    json.and_then(|s| serde_json::from_str(&s).ok())
}

/// Task repository for SQL CRUD operations.
pub struct TaskRepository;

impl TaskRepository {
    // ─────────────────────────────────────────────────────────────────────
    // Task CRUD
    // ─────────────────────────────────────────────────────────────────────

    /// Create a new task.
    pub fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
        let id = generate_id("task");
        let now = now_iso();
        let status = params.status.unwrap_or(TaskStatus::Pending);
        let priority = params.priority.unwrap_or(TaskPriority::Medium);
        let source = params.source.unwrap_or(TaskSource::Agent);
        let tags_json = tags_to_json(params.tags.as_deref().unwrap_or(&[]));
        let metadata_json = params
            .metadata
            .as_ref()
            .map_or_else(|| "{}".to_string(), |m| serde_json::to_string(m).unwrap_or_else(|_| "{}".to_string()));

        let started_at = if status == TaskStatus::InProgress {
            Some(now.clone())
        } else {
            None
        };

        // Normalize empty strings to None for FK columns — some providers
        // (e.g. OpenAI) send "" instead of null for optional ID fields.
        let project_id = params.project_id.as_deref().filter(|s| !s.is_empty());
        let parent_task_id = params.parent_task_id.as_deref().filter(|s| !s.is_empty());
        let area_id = params.area_id.as_deref().filter(|s| !s.is_empty());

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

        Self::get_task(conn, &id)?.ok_or_else(|| TaskError::task_not_found(&id))
    }

    /// Get a task by ID.
    pub fn get_task(conn: &Connection, id: &str) -> Result<Option<Task>, TaskError> {
        let task = conn
            .query_row("SELECT * FROM tasks WHERE id = ?1", params![id], |row| {
                Ok(task_from_row(row))
            })
            .optional()?;
        Ok(task)
    }

    /// Update a task. Returns the updated task, or `None` if not found.
    #[allow(clippy::too_many_lines)]
    pub fn update_task(
        conn: &Connection,
        id: &str,
        updates: &TaskUpdateParams,
    ) -> Result<Option<Task>, TaskError> {
        // Build dynamic SET clause
        let mut sets: Vec<String> = Vec::new();
        let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ref title) = updates.title {
            sets.push("title = ?".to_string());
            values.push(Box::new(title.clone()));
        }
        if let Some(ref desc) = updates.description {
            sets.push("description = ?".to_string());
            values.push(Box::new(desc.clone()));
        }
        if let Some(ref af) = updates.active_form {
            sets.push("active_form = ?".to_string());
            values.push(Box::new(af.clone()));
        }
        if let Some(status) = updates.status {
            sets.push("status = ?".to_string());
            values.push(Box::new(status.as_sql().to_string()));
        }
        if let Some(priority) = updates.priority {
            sets.push("priority = ?".to_string());
            values.push(Box::new(priority.as_sql().to_string()));
        }
        if let Some(ref pid) = updates.project_id {
            sets.push("project_id = ?".to_string());
            // Normalize empty strings to NULL for FK columns
            let normalized: Option<String> = if pid.is_empty() { None } else { Some(pid.clone()) };
            values.push(Box::new(normalized));
        }
        if let Some(ref ptid) = updates.parent_task_id {
            sets.push("parent_task_id = ?".to_string());
            let normalized: Option<String> = if ptid.is_empty() { None } else { Some(ptid.clone()) };
            values.push(Box::new(normalized));
        }
        if let Some(ref aid) = updates.area_id {
            sets.push("area_id = ?".to_string());
            let normalized: Option<String> = if aid.is_empty() { None } else { Some(aid.clone()) };
            values.push(Box::new(normalized));
        }
        if let Some(ref dd) = updates.due_date {
            sets.push("due_date = ?".to_string());
            values.push(Box::new(dd.clone()));
        }
        if let Some(ref du) = updates.deferred_until {
            sets.push("deferred_until = ?".to_string());
            values.push(Box::new(du.clone()));
        }
        if let Some(em) = updates.estimated_minutes {
            sets.push("estimated_minutes = ?".to_string());
            values.push(Box::new(em));
        }
        if let Some(ref sid) = updates.last_session_id {
            sets.push("last_session_id = ?".to_string());
            values.push(Box::new(sid.clone()));
            sets.push("last_session_at = ?".to_string());
            values.push(Box::new(now_iso()));
        }
        if let Some(ref meta) = updates.metadata {
            sets.push("metadata = ?".to_string());
            values.push(Box::new(
                serde_json::to_string(meta).unwrap_or_else(|_| "{}".to_string()),
            ));
        }

        // Handle tags: add_tags and remove_tags
        if updates.add_tags.is_some() || updates.remove_tags.is_some() {
            // Read current tags
            let current: Option<String> = conn
                .query_row(
                    "SELECT tags FROM tasks WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .optional()?;

            if let Some(current_json) = current {
                let mut tags = parse_tags(&current_json);
                if let Some(ref add) = updates.add_tags {
                    for t in add {
                        if !tags.contains(t) {
                            tags.push(t.clone());
                        }
                    }
                }
                if let Some(ref remove) = updates.remove_tags {
                    tags.retain(|t| !remove.contains(t));
                }
                sets.push("tags = ?".to_string());
                values.push(Box::new(tags_to_json(&tags)));
            }
        }

        // Handle note appending
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
            values.push(Box::new(new_notes));
        }

        if sets.is_empty() {
            return Self::get_task(conn, id);
        }

        sets.push("updated_at = ?".to_string());
        values.push(Box::new(now_iso()));
        values.push(Box::new(id.to_string()));

        let sql = format!(
            "UPDATE tasks SET {} WHERE id = ?",
            sets.join(", ")
        );

        let params_refs: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
        let changed = conn.execute(&sql, params_refs.as_slice())?;

        if changed == 0 {
            return Ok(None);
        }

        Self::get_task(conn, id)
    }

    /// Delete a task by ID. Returns true if a row was deleted.
    pub fn delete_task(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        let changed = conn.execute("DELETE FROM tasks WHERE id = ?1", params![id])?;
        Ok(changed > 0)
    }

    /// Increment actual minutes on a task.
    pub fn increment_actual_minutes(
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

    /// List tasks with filtering and pagination.
    #[allow(clippy::too_many_lines)]
    pub fn list_tasks(
        conn: &Connection,
        filter: &TaskFilter,
        limit: u32,
        offset: u32,
    ) -> Result<TaskListResult, TaskError> {
        let mut conditions: Vec<String> = Vec::new();
        let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(status) = filter.status {
            conditions.push("status = ?".to_string());
            values.push(Box::new(status.as_sql().to_string()));
        }
        if let Some(priority) = filter.priority {
            conditions.push("priority = ?".to_string());
            values.push(Box::new(priority.as_sql().to_string()));
        }
        if let Some(ref pid) = filter.project_id {
            conditions.push("project_id = ?".to_string());
            values.push(Box::new(pid.clone()));
        }
        if let Some(ref wid) = filter.workspace_id {
            conditions.push("workspace_id = ?".to_string());
            values.push(Box::new(wid.clone()));
        }
        if let Some(ref aid) = filter.area_id {
            conditions.push("area_id = ?".to_string());
            values.push(Box::new(aid.clone()));
        }
        if let Some(ref ptid) = filter.parent_task_id {
            conditions.push("parent_task_id = ?".to_string());
            values.push(Box::new(ptid.clone()));
        }
        if let Some(ref due) = filter.due_before {
            conditions.push("due_date IS NOT NULL AND due_date <= ?".to_string());
            values.push(Box::new(due.clone()));
        }

        // Default exclusions
        if !filter.include_completed {
            conditions.push("status NOT IN ('completed', 'cancelled')".to_string());
        }
        if !filter.include_deferred {
            conditions.push(
                "(deferred_until IS NULL OR deferred_until <= datetime('now'))".to_string(),
            );
        }
        if !filter.include_backlog {
            conditions.push("status != 'backlog'".to_string());
        }

        // Tag filtering
        if let Some(ref tags) = filter.tags {
            for tag in tags {
                conditions.push(
                    "EXISTS (SELECT 1 FROM json_each(tags) WHERE json_each.value = ?)".to_string(),
                );
                values.push(Box::new(tag.clone()));
            }
        }

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        // Count query
        let count_sql = format!("SELECT COUNT(*) FROM tasks {where_clause}");
        let count_params: Vec<&dyn rusqlite::types::ToSql> =
            values.iter().map(AsRef::as_ref).collect();
        let total: u32 = conn.query_row(&count_sql, count_params.as_slice(), |row| row.get(0))?;

        // Data query with ordering
        let data_sql = format!(
            "SELECT * FROM tasks {where_clause} \
             ORDER BY \
               CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 \
               WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END, \
               updated_at DESC \
             LIMIT ? OFFSET ?",
        );

        let mut data_values = values;
        data_values.push(Box::new(limit));
        data_values.push(Box::new(offset));
        let data_params: Vec<&dyn rusqlite::types::ToSql> =
            data_values.iter().map(AsRef::as_ref).collect();

        let mut stmt = conn.prepare(&data_sql)?;
        let tasks = stmt
            .query_map(data_params.as_slice(), |row| Ok(task_from_row(row)))?
            .filter_map(Result::ok)
            .collect();

        Ok(TaskListResult { tasks, total })
    }

    /// Get subtasks of a parent task.
    pub fn get_subtasks(conn: &Connection, parent_task_id: &str) -> Result<Vec<Task>, TaskError> {
        let mut stmt = conn.prepare(
            "SELECT * FROM tasks WHERE parent_task_id = ?1 ORDER BY sort_order, created_at",
        )?;
        let tasks = stmt
            .query_map(params![parent_task_id], |row| Ok(task_from_row(row)))?
            .filter_map(Result::ok)
            .collect();
        Ok(tasks)
    }

    /// Search tasks using FTS5.
    pub fn search_tasks(
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

    // ─────────────────────────────────────────────────────────────────────
    // Project CRUD
    // ─────────────────────────────────────────────────────────────────────

    /// Create a new project.
    pub fn create_project(
        conn: &Connection,
        params: &ProjectCreateParams,
    ) -> Result<Project, TaskError> {
        let id = generate_id("proj");
        let now = now_iso();
        let status = params.status.unwrap_or(ProjectStatus::Active);
        let tags_json = tags_to_json(params.tags.as_deref().unwrap_or(&[]));
        let metadata_json = params
            .metadata
            .as_ref()
            .map_or_else(|| "{}".to_string(), |m| serde_json::to_string(m).unwrap_or_else(|_| "{}".to_string()));

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

        Self::get_project(conn, &id)?.ok_or_else(|| TaskError::project_not_found(&id))
    }

    /// Get a project by ID.
    pub fn get_project(conn: &Connection, id: &str) -> Result<Option<Project>, TaskError> {
        let project = conn
            .query_row(
                "SELECT * FROM projects WHERE id = ?1",
                params![id],
                |row| Ok(project_from_row(row)),
            )
            .optional()?;
        Ok(project)
    }

    /// Update a project. Returns the updated project, or `None` if not found.
    pub fn update_project(
        conn: &Connection,
        id: &str,
        updates: &ProjectUpdateParams,
    ) -> Result<Option<Project>, TaskError> {
        let mut sets: Vec<String> = Vec::new();
        let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ref title) = updates.title {
            sets.push("title = ?".to_string());
            values.push(Box::new(title.clone()));
        }
        if let Some(ref desc) = updates.description {
            sets.push("description = ?".to_string());
            values.push(Box::new(desc.clone()));
        }
        if let Some(status) = updates.status {
            sets.push("status = ?".to_string());
            values.push(Box::new(status.as_sql().to_string()));
        }
        if let Some(ref aid) = updates.area_id {
            sets.push("area_id = ?".to_string());
            values.push(Box::new(aid.clone()));
        }
        if let Some(ref meta) = updates.metadata {
            sets.push("metadata = ?".to_string());
            values.push(Box::new(
                serde_json::to_string(meta).unwrap_or_else(|_| "{}".to_string()),
            ));
        }

        // Handle tags
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
                if let Some(ref add) = updates.add_tags {
                    for t in add {
                        if !tags.contains(t) {
                            tags.push(t.clone());
                        }
                    }
                }
                if let Some(ref remove) = updates.remove_tags {
                    tags.retain(|t| !remove.contains(t));
                }
                sets.push("tags = ?".to_string());
                values.push(Box::new(tags_to_json(&tags)));
            }
        }

        if sets.is_empty() {
            return Self::get_project(conn, id);
        }

        sets.push("updated_at = ?".to_string());
        values.push(Box::new(now_iso()));
        values.push(Box::new(id.to_string()));

        let sql = format!(
            "UPDATE projects SET {} WHERE id = ?",
            sets.join(", ")
        );
        let params_refs: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
        let changed = conn.execute(&sql, params_refs.as_slice())?;

        if changed == 0 {
            return Ok(None);
        }

        Self::get_project(conn, id)
    }

    /// Delete a project. Returns true if a row was deleted.
    pub fn delete_project(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        // Tasks get project_id set to NULL via ON DELETE SET NULL
        let changed = conn.execute("DELETE FROM projects WHERE id = ?1", params![id])?;
        Ok(changed > 0)
    }

    /// List projects with progress counts.
    pub fn list_projects(
        conn: &Connection,
        filter: &ProjectFilter,
        limit: u32,
        offset: u32,
    ) -> Result<ProjectListResult, TaskError> {
        let mut conditions: Vec<String> = Vec::new();
        let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(status) = filter.status {
            conditions.push("p.status = ?".to_string());
            values.push(Box::new(status.as_sql().to_string()));
        }
        if let Some(ref wid) = filter.workspace_id {
            conditions.push("p.workspace_id = ?".to_string());
            values.push(Box::new(wid.clone()));
        }
        if let Some(ref aid) = filter.area_id {
            conditions.push("p.area_id = ?".to_string());
            values.push(Box::new(aid.clone()));
        }

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        // Count
        let count_sql = format!("SELECT COUNT(*) FROM projects p {where_clause}");
        let count_params: Vec<&dyn rusqlite::types::ToSql> =
            values.iter().map(AsRef::as_ref).collect();
        let total: u32 = conn.query_row(&count_sql, count_params.as_slice(), |row| row.get(0))?;

        // Data with aggregated counts
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
        data_values.push(Box::new(limit));
        data_values.push(Box::new(offset));
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

    // ─────────────────────────────────────────────────────────────────────
    // Area CRUD
    // ─────────────────────────────────────────────────────────────────────

    /// Create a new area.
    pub fn create_area(conn: &Connection, params: &AreaCreateParams) -> Result<Area, TaskError> {
        let id = generate_id("area");
        let now = now_iso();
        let status = params.status.unwrap_or(AreaStatus::Active);
        let workspace_id = params
            .workspace_id
            .as_deref()
            .unwrap_or("default");
        let tags_json = tags_to_json(params.tags.as_deref().unwrap_or(&[]));
        let metadata_json = params
            .metadata
            .as_ref()
            .map_or_else(|| "{}".to_string(), |m| serde_json::to_string(m).unwrap_or_else(|_| "{}".to_string()));

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

        Self::get_area(conn, &id)?.ok_or_else(|| TaskError::area_not_found(&id))
    }

    /// Get an area by ID.
    pub fn get_area(conn: &Connection, id: &str) -> Result<Option<Area>, TaskError> {
        let area = conn
            .query_row("SELECT * FROM areas WHERE id = ?1", params![id], |row| {
                Ok(area_from_row(row))
            })
            .optional()?;
        Ok(area)
    }

    /// Update an area. Returns the updated area, or `None` if not found.
    pub fn update_area(
        conn: &Connection,
        id: &str,
        updates: &AreaUpdateParams,
    ) -> Result<Option<Area>, TaskError> {
        let mut sets: Vec<String> = Vec::new();
        let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ref title) = updates.title {
            sets.push("title = ?".to_string());
            values.push(Box::new(title.clone()));
        }
        if let Some(ref desc) = updates.description {
            sets.push("description = ?".to_string());
            values.push(Box::new(desc.clone()));
        }
        if let Some(status) = updates.status {
            sets.push("status = ?".to_string());
            values.push(Box::new(status.as_sql().to_string()));
        }
        if let Some(order) = updates.sort_order {
            sets.push("sort_order = ?".to_string());
            values.push(Box::new(order));
        }

        // Handle tags
        if updates.add_tags.is_some() || updates.remove_tags.is_some() {
            let current: Option<String> = conn
                .query_row(
                    "SELECT tags FROM areas WHERE id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .optional()?;

            if let Some(current_json) = current {
                let mut tags = parse_tags(&current_json);
                if let Some(ref add) = updates.add_tags {
                    for t in add {
                        if !tags.contains(t) {
                            tags.push(t.clone());
                        }
                    }
                }
                if let Some(ref remove) = updates.remove_tags {
                    tags.retain(|t| !remove.contains(t));
                }
                sets.push("tags = ?".to_string());
                values.push(Box::new(tags_to_json(&tags)));
            }
        }

        if let Some(ref meta) = updates.metadata {
            sets.push("metadata = ?".to_string());
            values.push(Box::new(
                serde_json::to_string(meta).unwrap_or_else(|_| "{}".to_string()),
            ));
        }

        if sets.is_empty() {
            return Self::get_area(conn, id);
        }

        sets.push("updated_at = ?".to_string());
        values.push(Box::new(now_iso()));
        values.push(Box::new(id.to_string()));

        let sql = format!(
            "UPDATE areas SET {} WHERE id = ?",
            sets.join(", ")
        );
        let params_refs: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(AsRef::as_ref).collect();
        let changed = conn.execute(&sql, params_refs.as_slice())?;

        if changed == 0 {
            return Ok(None);
        }

        Self::get_area(conn, id)
    }

    /// Delete an area. Returns true if a row was deleted.
    pub fn delete_area(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        // Cascade: projects/tasks with this area_id get SET NULL
        let _ = conn.execute(
            "UPDATE projects SET area_id = NULL WHERE area_id = ?1",
            params![id],
        )?;
        let _ = conn.execute(
            "UPDATE tasks SET area_id = NULL WHERE area_id = ?1",
            params![id],
        )?;
        let changed = conn.execute("DELETE FROM areas WHERE id = ?1", params![id])?;
        Ok(changed > 0)
    }

    /// List areas with counts.
    pub fn list_areas(
        conn: &Connection,
        filter: &AreaFilter,
        limit: u32,
        offset: u32,
    ) -> Result<AreaListResult, TaskError> {
        let mut conditions: Vec<String> = Vec::new();
        let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(status) = filter.status {
            conditions.push("a.status = ?".to_string());
            values.push(Box::new(status.as_sql().to_string()));
        }
        if let Some(ref wid) = filter.workspace_id {
            conditions.push("a.workspace_id = ?".to_string());
            values.push(Box::new(wid.clone()));
        }

        let where_clause = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        let count_sql = format!("SELECT COUNT(*) FROM areas a {where_clause}");
        let count_params: Vec<&dyn rusqlite::types::ToSql> =
            values.iter().map(AsRef::as_ref).collect();
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
        data_values.push(Box::new(limit));
        data_values.push(Box::new(offset));
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

    /// Search areas using FTS5.
    pub fn search_areas(
        conn: &Connection,
        query: &str,
        limit: u32,
    ) -> Result<Vec<Area>, TaskError> {
        let mut stmt = conn.prepare(
            "SELECT a.* FROM areas a \
             JOIN areas_fts f ON f.area_id = a.id \
             WHERE areas_fts MATCH ?1 \
             ORDER BY rank LIMIT ?2",
        )?;
        let areas = stmt
            .query_map(params![query, limit], |row| Ok(area_from_row(row)))?
            .filter_map(Result::ok)
            .collect();
        Ok(areas)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────────────────────

    /// Add a dependency between two tasks.
    #[allow(clippy::similar_names)]
    pub fn add_dependency(
        conn: &Connection,
        blocker_id: &str,
        blocked_id: &str,
        relationship: DependencyRelationship,
    ) -> Result<(), TaskError> {
        let _ = conn.execute(
            "INSERT OR IGNORE INTO task_dependencies \
             (blocker_task_id, blocked_task_id, relationship) \
             VALUES (?1, ?2, ?3)",
            params![blocker_id, blocked_id, relationship.as_sql()],
        )?;
        Ok(())
    }

    /// Remove a dependency. Returns true if a row was deleted.
    #[allow(clippy::similar_names)]
    pub fn remove_dependency(
        conn: &Connection,
        blocker_id: &str,
        blocked_id: &str,
    ) -> Result<bool, TaskError> {
        let changed = conn.execute(
            "DELETE FROM task_dependencies \
             WHERE blocker_task_id = ?1 AND blocked_task_id = ?2",
            params![blocker_id, blocked_id],
        )?;
        Ok(changed > 0)
    }

    /// Get dependencies where this task is blocked BY others.
    pub fn get_blocked_by(
        conn: &Connection,
        task_id: &str,
    ) -> Result<Vec<TaskDependency>, TaskError> {
        let mut stmt = conn.prepare(
            "SELECT blocker_task_id, blocked_task_id, relationship, created_at \
             FROM task_dependencies WHERE blocked_task_id = ?1",
        )?;
        let deps = stmt
            .query_map(params![task_id], |row| {
                Ok(TaskDependency {
                    blocker_task_id: row.get(0)?,
                    blocked_task_id: row.get(1)?,
                    relationship: match row.get::<_, String>(2)?.as_str() {
                        "related" => DependencyRelationship::Related,
                        _ => DependencyRelationship::Blocks,
                    },
                    created_at: row.get(3)?,
                })
            })?
            .filter_map(Result::ok)
            .collect();
        Ok(deps)
    }

    /// Get tasks that this task blocks.
    pub fn get_blocks(conn: &Connection, task_id: &str) -> Result<Vec<TaskDependency>, TaskError> {
        let mut stmt = conn.prepare(
            "SELECT blocker_task_id, blocked_task_id, relationship, created_at \
             FROM task_dependencies WHERE blocker_task_id = ?1",
        )?;
        let deps = stmt
            .query_map(params![task_id], |row| {
                Ok(TaskDependency {
                    blocker_task_id: row.get(0)?,
                    blocked_task_id: row.get(1)?,
                    relationship: match row.get::<_, String>(2)?.as_str() {
                        "related" => DependencyRelationship::Related,
                        _ => DependencyRelationship::Blocks,
                    },
                    created_at: row.get(3)?,
                })
            })?
            .filter_map(Result::ok)
            .collect();
        Ok(deps)
    }

    /// Check if adding a dependency would create a circular reference.
    ///
    /// Uses BFS starting from `blocked_id`, following `blocks` edges.
    /// If we can reach `blocker_id`, then adding the edge would create a cycle.
    #[allow(clippy::similar_names)]
    pub fn has_circular_dependency(
        conn: &Connection,
        blocker_id: &str,
        blocked_id: &str,
    ) -> Result<bool, TaskError> {
        let mut visited = std::collections::HashSet::new();
        let mut queue = VecDeque::new();
        queue.push_back(blocked_id.to_string());

        while let Some(current) = queue.pop_front() {
            if current == blocker_id {
                return Ok(true);
            }
            if !visited.insert(current.clone()) {
                continue;
            }

            // Follow "blocks" edges outward from current
            let mut stmt = conn.prepare(
                "SELECT blocked_task_id FROM task_dependencies \
                 WHERE blocker_task_id = ?1 AND relationship = 'blocks'",
            )?;
            let children: Vec<String> = stmt
                .query_map(params![current], |row| row.get(0))?
                .filter_map(Result::ok)
                .collect();
            queue.extend(children);
        }

        Ok(false)
    }

    /// Count tasks that are blocked (have unresolved `blocks` dependencies).
    pub fn get_blocked_task_count(
        conn: &Connection,
        workspace_id: Option<&str>,
    ) -> Result<u32, TaskError> {
        let count = if let Some(wid) = workspace_id {
            conn.query_row(
                "SELECT COUNT(DISTINCT td.blocked_task_id) \
                 FROM task_dependencies td \
                 JOIN tasks t ON t.id = td.blocked_task_id \
                 WHERE td.relationship = 'blocks' \
                 AND t.status NOT IN ('completed', 'cancelled') \
                 AND t.workspace_id = ?1",
                params![wid],
                |row| row.get(0),
            )?
        } else {
            conn.query_row(
                "SELECT COUNT(DISTINCT td.blocked_task_id) \
                 FROM task_dependencies td \
                 JOIN tasks t ON t.id = td.blocked_task_id \
                 WHERE td.relationship = 'blocks' \
                 AND t.status NOT IN ('completed', 'cancelled')",
                [],
                |row| row.get(0),
            )?
        };
        Ok(count)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Activity
    // ─────────────────────────────────────────────────────────────────────

    /// Log an activity entry for a task.
    pub fn log_activity(conn: &Connection, params: &LogActivityParams) -> Result<(), TaskError> {
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

    /// Get activity log for a task.
    pub fn get_activity(
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
                    action: match row.get::<_, String>(4)?.as_str() {
                        "created" => ActivityAction::Created,
                        "status_changed" => ActivityAction::StatusChanged,
                        "note_added" => ActivityAction::NoteAdded,
                        "time_logged" => ActivityAction::TimeLogged,
                        "dependency_added" => ActivityAction::DependencyAdded,
                        "dependency_removed" => ActivityAction::DependencyRemoved,
                        "moved" => ActivityAction::Moved,
                        "deleted" => ActivityAction::Deleted,
                        // "updated" and unknown values
                        _ => ActivityAction::Updated,
                    },
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

    // ─────────────────────────────────────────────────────────────────────
    // Context summaries
    // ─────────────────────────────────────────────────────────────────────

    /// Get a summary of active tasks for LLM context injection.
    pub fn get_active_task_summary(
        conn: &Connection,
        workspace_id: Option<&str>,
    ) -> Result<ActiveTaskSummary, TaskError> {
        let ws_condition = workspace_id.map_or("", |_| " AND workspace_id = ?1");

        // In-progress tasks
        let ip_sql = format!(
            "SELECT * FROM tasks WHERE status = 'in_progress'{ws_condition} \
             ORDER BY CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 \
             WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END, updated_at DESC"
        );
        let in_progress = if let Some(wid) = workspace_id {
            let mut stmt = conn.prepare(&ip_sql)?;
            stmt.query_map(params![wid], |row| Ok(task_from_row(row)))?
                .filter_map(Result::ok)
                .collect()
        } else {
            let mut stmt = conn.prepare(&ip_sql)?;
            stmt.query_map([], |row| Ok(task_from_row(row)))?
                .filter_map(Result::ok)
                .collect()
        };

        // Pending count
        let pending_sql = format!(
            "SELECT COUNT(*) FROM tasks WHERE status = 'pending'{ws_condition}"
        );
        let pending_count: u32 = if let Some(wid) = workspace_id {
            conn.query_row(&pending_sql, params![wid], |row| row.get(0))?
        } else {
            conn.query_row(&pending_sql, [], |row| row.get(0))?
        };

        // Overdue count
        let overdue_sql = format!(
            "SELECT COUNT(*) FROM tasks WHERE due_date IS NOT NULL \
             AND due_date < datetime('now') \
             AND status NOT IN ('completed', 'cancelled'){ws_condition}"
        );
        let overdue_count: u32 = if let Some(wid) = workspace_id {
            conn.query_row(&overdue_sql, params![wid], |row| row.get(0))?
        } else {
            conn.query_row(&overdue_sql, [], |row| row.get(0))?
        };

        // Deferred count
        let deferred_sql = format!(
            "SELECT COUNT(*) FROM tasks WHERE deferred_until IS NOT NULL \
             AND deferred_until > datetime('now') \
             AND status NOT IN ('completed', 'cancelled'){ws_condition}"
        );
        let deferred_count: u32 = if let Some(wid) = workspace_id {
            conn.query_row(&deferred_sql, params![wid], |row| row.get(0))?
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

    /// Get project progress for LLM context.
    pub fn get_active_project_progress(
        conn: &Connection,
        workspace_id: Option<&str>,
    ) -> Result<Vec<ProjectProgressEntry>, TaskError> {
        let ws_condition = workspace_id.map_or("", |_| " AND p.workspace_id = ?1");
        let sql = format!(
            "SELECT p.title, \
               (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id \
                AND t.status IN ('completed', 'cancelled')) as completed, \
               (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id) as total \
             FROM projects p \
             WHERE p.status = 'active'{ws_condition} \
             ORDER BY p.updated_at DESC"
        );

        let entries = if let Some(wid) = workspace_id {
            let mut stmt = conn.prepare(&sql)?;
            stmt.query_map(params![wid], |row| {
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
}

// ─────────────────────────────────────────────────────────────────────────────
// Row converters
// ─────────────────────────────────────────────────────────────────────────────

fn task_from_row(row: &rusqlite::Row<'_>) -> Task {
    let status_str: String = row.get_unwrap("status");
    let priority_str: String = row.get_unwrap("priority");
    let source_str: String = row.get_unwrap("source");
    let tags_json: String = row.get_unwrap("tags");
    let metadata_json: Option<String> = row.get_unwrap("metadata");

    Task {
        id: row.get_unwrap("id"),
        project_id: row.get_unwrap("project_id"),
        parent_task_id: row.get_unwrap("parent_task_id"),
        workspace_id: row.get_unwrap("workspace_id"),
        area_id: row.get_unwrap("area_id"),
        title: row.get_unwrap("title"),
        description: row.get_unwrap("description"),
        active_form: row.get_unwrap("active_form"),
        notes: row.get_unwrap("notes"),
        status: match status_str.as_str() {
            "backlog" => TaskStatus::Backlog,
            "in_progress" => TaskStatus::InProgress,
            "completed" => TaskStatus::Completed,
            "cancelled" => TaskStatus::Cancelled,
            _ => TaskStatus::Pending,
        },
        priority: match priority_str.as_str() {
            "low" => TaskPriority::Low,
            "high" => TaskPriority::High,
            "critical" => TaskPriority::Critical,
            _ => TaskPriority::Medium,
        },
        source: match source_str.as_str() {
            "user" => TaskSource::User,
            "skill" => TaskSource::Skill,
            "system" => TaskSource::System,
            _ => TaskSource::Agent,
        },
        tags: parse_tags(&tags_json),
        due_date: row.get_unwrap("due_date"),
        deferred_until: row.get_unwrap("deferred_until"),
        started_at: row.get_unwrap("started_at"),
        completed_at: row.get_unwrap("completed_at"),
        created_at: row.get_unwrap("created_at"),
        updated_at: row.get_unwrap("updated_at"),
        estimated_minutes: row.get_unwrap("estimated_minutes"),
        actual_minutes: row.get_unwrap("actual_minutes"),
        created_by_session_id: row.get_unwrap("created_by_session_id"),
        last_session_id: row.get_unwrap("last_session_id"),
        last_session_at: row.get_unwrap("last_session_at"),
        sort_order: row.get_unwrap("sort_order"),
        metadata: parse_metadata(metadata_json),
    }
}

fn project_from_row(row: &rusqlite::Row<'_>) -> Project {
    let status_str: String = row.get_unwrap("status");
    let tags_json: String = row.get_unwrap("tags");
    let metadata_json: Option<String> = row.get_unwrap("metadata");

    Project {
        id: row.get_unwrap("id"),
        workspace_id: row.get_unwrap("workspace_id"),
        area_id: row.get_unwrap("area_id"),
        title: row.get_unwrap("title"),
        description: row.get_unwrap("description"),
        status: match status_str.as_str() {
            "paused" => ProjectStatus::Paused,
            "completed" => ProjectStatus::Completed,
            "archived" => ProjectStatus::Archived,
            _ => ProjectStatus::Active,
        },
        tags: parse_tags(&tags_json),
        created_at: row.get_unwrap("created_at"),
        updated_at: row.get_unwrap("updated_at"),
        completed_at: row.get_unwrap("completed_at"),
        metadata: parse_metadata(metadata_json),
    }
}

fn area_from_row(row: &rusqlite::Row<'_>) -> Area {
    let status_str: String = row.get_unwrap("status");
    let tags_json: String = row.get_unwrap("tags");
    let metadata_json: Option<String> = row.get_unwrap("metadata");

    Area {
        id: row.get_unwrap("id"),
        workspace_id: row.get_unwrap("workspace_id"),
        title: row.get_unwrap("title"),
        description: row.get_unwrap("description"),
        status: match status_str.as_str() {
            "archived" => AreaStatus::Archived,
            _ => AreaStatus::Active,
        },
        tags: parse_tags(&tags_json),
        sort_order: row.get_unwrap("sort_order"),
        created_at: row.get_unwrap("created_at"),
        updated_at: row.get_unwrap("updated_at"),
        metadata: parse_metadata(metadata_json),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

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

    // --- Task CRUD ---

    #[test]
    fn test_create_task_minimal() {
        let conn = setup_db();
        let params = TaskCreateParams {
            title: "Fix bug".to_string(),
            ..Default::default()
        };
        let task = TaskRepository::create_task(&conn, &params).unwrap();
        assert!(task.id.starts_with("task-"));
        assert_eq!(task.title, "Fix bug");
        assert_eq!(task.status, TaskStatus::Pending);
        assert_eq!(task.priority, TaskPriority::Medium);
        assert_eq!(task.source, TaskSource::Agent);
        assert_eq!(task.actual_minutes, 0);
    }

    #[test]
    fn test_create_task_all_fields() {
        let conn = setup_db();
        let params = TaskCreateParams {
            title: "Full task".to_string(),
            description: Some("Description".to_string()),
            active_form: Some("Working".to_string()),
            status: Some(TaskStatus::InProgress),
            priority: Some(TaskPriority::High),
            source: Some(TaskSource::User),
            tags: Some(vec!["tag1".to_string(), "tag2".to_string()]),
            due_date: Some("2026-03-01".to_string()),
            estimated_minutes: Some(120),
            workspace_id: Some("ws-1".to_string()),
            ..Default::default()
        };
        let task = TaskRepository::create_task(&conn, &params).unwrap();
        assert_eq!(task.status, TaskStatus::InProgress);
        assert_eq!(task.priority, TaskPriority::High);
        assert_eq!(task.source, TaskSource::User);
        assert_eq!(task.tags, vec!["tag1", "tag2"]);
        assert!(task.started_at.is_some()); // Auto-set for InProgress
        assert_eq!(task.estimated_minutes, Some(120));
    }

    #[test]
    fn test_get_task_exists() {
        let conn = setup_db();
        let params = TaskCreateParams {
            title: "Test".to_string(),
            ..Default::default()
        };
        let created = TaskRepository::create_task(&conn, &params).unwrap();
        let fetched = TaskRepository::get_task(&conn, &created.id).unwrap();
        assert!(fetched.is_some());
        assert_eq!(fetched.unwrap().id, created.id);
    }

    #[test]
    fn test_get_task_not_found() {
        let conn = setup_db();
        let result = TaskRepository::get_task(&conn, "task-nonexistent").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_update_task_title() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Old".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                title: Some("New".to_string()),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated.title, "New");
    }

    #[test]
    fn test_update_task_status() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated.status, TaskStatus::InProgress);
    }

    #[test]
    fn test_update_task_not_found() {
        let conn = setup_db();
        let result = TaskRepository::update_task(
            &conn,
            "task-missing",
            &TaskUpdateParams {
                title: Some("X".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_update_task_add_tags() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Tags".to_string(),
                tags: Some(vec!["a".to_string()]),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                add_tags: Some(vec!["b".to_string()]),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert!(updated.tags.contains(&"a".to_string()));
        assert!(updated.tags.contains(&"b".to_string()));
    }

    #[test]
    fn test_update_task_add_tags_dedup() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Tags".to_string(),
                tags: Some(vec!["a".to_string()]),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                add_tags: Some(vec!["a".to_string()]),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated.tags.len(), 1);
    }

    #[test]
    fn test_update_task_remove_tags() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Tags".to_string(),
                tags: Some(vec!["a".to_string(), "b".to_string()]),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                remove_tags: Some(vec!["a".to_string()]),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated.tags, vec!["b".to_string()]);
    }

    #[test]
    fn test_update_task_add_note() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Notes".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                add_note: Some("First note".to_string()),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert!(updated.notes.as_ref().unwrap().contains("First note"));
        assert!(updated.notes.as_ref().unwrap().starts_with('['));
    }

    #[test]
    fn test_delete_task() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Delete me".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(TaskRepository::delete_task(&conn, &task.id).unwrap());
        assert!(TaskRepository::get_task(&conn, &task.id).unwrap().is_none());
    }

    #[test]
    fn test_delete_task_not_found() {
        let conn = setup_db();
        assert!(!TaskRepository::delete_task(&conn, "task-missing").unwrap());
    }

    #[test]
    fn test_increment_actual_minutes() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Time".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(task.actual_minutes, 0);
        TaskRepository::increment_actual_minutes(&conn, &task.id, 30).unwrap();
        let updated = TaskRepository::get_task(&conn, &task.id).unwrap().unwrap();
        assert_eq!(updated.actual_minutes, 30);
        TaskRepository::increment_actual_minutes(&conn, &task.id, 15).unwrap();
        let updated = TaskRepository::get_task(&conn, &task.id).unwrap().unwrap();
        assert_eq!(updated.actual_minutes, 45);
    }

    // --- List and search ---

    #[test]
    fn test_list_tasks_empty() {
        let conn = setup_db();
        let result = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 50, 0).unwrap();
        assert_eq!(result.total, 0);
        assert!(result.tasks.is_empty());
    }

    #[test]
    fn test_list_tasks_excludes_completed_by_default() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".to_string(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 50, 0).unwrap();
        assert_eq!(result.total, 1);
        assert_eq!(result.tasks[0].title, "Active");
    }

    #[test]
    fn test_list_tasks_include_completed() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".to_string(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_tasks(
            &conn,
            &TaskFilter {
                include_completed: true,
                include_backlog: true,
                ..Default::default()
            },
            50,
            0,
        )
        .unwrap();
        assert_eq!(result.total, 2);
    }

    #[test]
    fn test_list_tasks_filter_by_status() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "IP".to_string(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Pending".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_tasks(
            &conn,
            &TaskFilter {
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
            50,
            0,
        )
        .unwrap();
        assert_eq!(result.total, 1);
        assert_eq!(result.tasks[0].title, "IP");
    }

    #[test]
    fn test_list_tasks_priority_ordering() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Low".to_string(),
                priority: Some(TaskPriority::Low),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Critical".to_string(),
                priority: Some(TaskPriority::Critical),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 50, 0).unwrap();
        assert_eq!(result.tasks[0].title, "Critical");
        assert_eq!(result.tasks[1].title, "Low");
    }

    #[test]
    fn test_list_tasks_pagination() {
        let conn = setup_db();
        for i in 0..5 {
            TaskRepository::create_task(
                &conn,
                &TaskCreateParams {
                    title: format!("Task {i}"),
                    ..Default::default()
                },
            )
            .unwrap();
        }
        let result = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 2, 0).unwrap();
        assert_eq!(result.total, 5);
        assert_eq!(result.tasks.len(), 2);

        let result2 = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 2, 2).unwrap();
        assert_eq!(result2.tasks.len(), 2);
    }

    #[test]
    fn test_get_subtasks() {
        let conn = setup_db();
        let parent = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Parent".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Child 1".to_string(),
                parent_task_id: Some(parent.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Child 2".to_string(),
                parent_task_id: Some(parent.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        let subtasks = TaskRepository::get_subtasks(&conn, &parent.id).unwrap();
        assert_eq!(subtasks.len(), 2);
    }

    #[test]
    fn test_search_tasks() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Fix authentication bug".to_string(),
                description: Some("Login fails with OAuth".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Add dark mode".to_string(),
                ..Default::default()
            },
        )
        .unwrap();

        let results = TaskRepository::search_tasks(&conn, "authentication", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].title.contains("authentication"));
    }

    // --- Project CRUD ---

    #[test]
    fn test_create_project() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Dashboard v2".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(project.id.starts_with("proj-"));
        assert_eq!(project.title, "Dashboard v2");
        assert_eq!(project.status, ProjectStatus::Active);
    }

    #[test]
    fn test_delete_project_orphans_tasks() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task".to_string(),
                project_id: Some(project.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::delete_project(&conn, &project.id).unwrap();
        let updated_task = TaskRepository::get_task(&conn, &task.id).unwrap().unwrap();
        assert!(updated_task.project_id.is_none());
    }

    #[test]
    fn test_list_projects_with_progress() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".to_string(),
                project_id: Some(project.id.clone()),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".to_string(),
                project_id: Some(project.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        let result =
            TaskRepository::list_projects(&conn, &ProjectFilter::default(), 50, 0).unwrap();
        assert_eq!(result.projects[0].task_count, 2);
        assert_eq!(result.projects[0].completed_task_count, 1);
    }

    // --- Area CRUD ---

    #[test]
    fn test_create_area() {
        let conn = setup_db();
        let area = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Engineering".to_string(),
                description: Some("Core development".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(area.id.starts_with("area-"));
        assert_eq!(area.title, "Engineering");
        assert_eq!(area.workspace_id, "default");
        assert_eq!(area.status, AreaStatus::Active);
    }

    #[test]
    fn test_delete_area_cascades() {
        let conn = setup_db();
        let area = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Area".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                area_id: Some(area.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::delete_area(&conn, &area.id).unwrap();
        let updated = TaskRepository::get_project(&conn, &project.id).unwrap().unwrap();
        assert!(updated.area_id.is_none());
    }

    #[test]
    fn test_list_areas_with_counts() {
        let conn = setup_db();
        let area = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Engineering".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                area_id: Some(area.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active task".to_string(),
                area_id: Some(area.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done task".to_string(),
                area_id: Some(area.id.clone()),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_areas(&conn, &AreaFilter::default(), 50, 0).unwrap();
        assert_eq!(result.areas[0].project_count, 1);
        assert_eq!(result.areas[0].task_count, 2);
        assert_eq!(result.areas[0].active_task_count, 1);
    }

    #[test]
    fn test_search_areas() {
        let conn = setup_db();
        TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Engineering".to_string(),
                description: Some("Core product development".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Marketing".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let results = TaskRepository::search_areas(&conn, "engineering", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "Engineering");
    }

    // --- Dependencies ---

    #[test]
    fn test_add_dependency() {
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
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();

        let blocked_by = TaskRepository::get_blocked_by(&conn, &t2.id).unwrap();
        assert_eq!(blocked_by.len(), 1);
        assert_eq!(blocked_by[0].blocker_task_id, t1.id);

        let blocks = TaskRepository::get_blocks(&conn, &t1.id).unwrap();
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].blocked_task_id, t2.id);
    }

    #[test]
    fn test_add_dependency_duplicate_ignored() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        // Duplicate — should not error
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();

        let deps = TaskRepository::get_blocked_by(&conn, &t2.id).unwrap();
        assert_eq!(deps.len(), 1);
    }

    #[test]
    fn test_remove_dependency() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        assert!(TaskRepository::remove_dependency(&conn, &t1.id, &t2.id).unwrap());
        assert!(!TaskRepository::remove_dependency(&conn, &t1.id, &t2.id).unwrap());
    }

    #[test]
    fn test_circular_dependency_simple() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        // Would t2 → t1 create cycle? Yes: t1 → t2 → t1
        assert!(TaskRepository::has_circular_dependency(&conn, &t2.id, &t1.id).unwrap());
    }

    #[test]
    fn test_circular_dependency_transitive() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t3 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        TaskRepository::add_dependency(&conn, &t2.id, &t3.id, DependencyRelationship::Blocks)
            .unwrap();
        // Would t3 → t1 create cycle? Yes: t1 → t2 → t3 → t1
        assert!(TaskRepository::has_circular_dependency(&conn, &t3.id, &t1.id).unwrap());
    }

    #[test]
    fn test_no_circular_dependency() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t3 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        // Would t1 → t3 create cycle? No.
        assert!(!TaskRepository::has_circular_dependency(&conn, &t1.id, &t3.id).unwrap());
    }

    #[test]
    fn test_blocked_task_count() {
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
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        let count = TaskRepository::get_blocked_task_count(&conn, None).unwrap();
        assert_eq!(count, 1);
    }

    // --- Activity ---

    #[test]
    fn test_log_and_get_activity() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::log_activity(
            &conn,
            &LogActivityParams {
                task_id: task.id.clone(),
                session_id: None,
                event_id: None,
                action: ActivityAction::Created,
                old_value: None,
                new_value: None,
                detail: Some("Task created".to_string()),
                minutes_logged: None,
            },
        )
        .unwrap();
        let activity = TaskRepository::get_activity(&conn, &task.id, 10).unwrap();
        assert_eq!(activity.len(), 1);
        assert_eq!(activity[0].action, ActivityAction::Created);
        assert_eq!(activity[0].detail.as_deref(), Some("Task created"));
    }

    #[test]
    fn test_activity_ordered_desc() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        for action in [ActivityAction::Created, ActivityAction::Updated] {
            TaskRepository::log_activity(
                &conn,
                &LogActivityParams {
                    task_id: task.id.clone(),
                    session_id: None,
                    event_id: None,
                    action,
                    old_value: None,
                    new_value: None,
                    detail: None,
                    minutes_logged: None,
                },
            )
            .unwrap();
        }
        let activity = TaskRepository::get_activity(&conn, &task.id, 10).unwrap();
        assert!(activity[0].id > activity[1].id); // Most recent first
    }

    // --- Context summaries ---

    #[test]
    fn test_active_task_summary() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "In progress".to_string(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Pending".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let summary = TaskRepository::get_active_task_summary(&conn, None).unwrap();
        assert_eq!(summary.in_progress.len(), 1);
        assert_eq!(summary.pending_count, 1);
    }

    #[test]
    fn test_active_project_progress() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "My Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".to_string(),
                project_id: Some(project.id.clone()),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".to_string(),
                project_id: Some(project.id),
                ..Default::default()
            },
        )
        .unwrap();
        let progress = TaskRepository::get_active_project_progress(&conn, None).unwrap();
        assert_eq!(progress.len(), 1);
        assert_eq!(progress[0].title, "My Project");
        assert_eq!(progress[0].completed, 1);
        assert_eq!(progress[0].total, 2);
    }

    // --- FK empty string normalization ---

    #[test]
    fn create_task_normalizes_empty_project_id() {
        let conn = setup_db();
        // Empty string project_id should be normalized to NULL, not trigger FK failure
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task with empty project".to_string(),
                project_id: Some(String::new()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(task.project_id.is_none());
    }

    #[test]
    fn create_task_normalizes_empty_area_id() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task with empty area".to_string(),
                area_id: Some(String::new()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(task.area_id.is_none());
    }

    #[test]
    fn update_task_normalizes_empty_project_id() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Proj".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task".to_string(),
                project_id: Some(project.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(task.project_id.as_deref(), Some(project.id.as_str()));

        // Update with empty string should set to NULL
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                project_id: Some(String::new()),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert!(updated.project_id.is_none());
    }
}
