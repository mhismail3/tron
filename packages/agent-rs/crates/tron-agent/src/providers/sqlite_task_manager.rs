//! Real `TaskManagerDelegate` backed by `tron_runtime::tasks::TaskService`.
//!
//! Provides the `TaskManager` tool with actual database access for CRUD
//! operations on tasks, projects, and areas.

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_events::ConnectionPool;
use tron_runtime::tasks::service::TaskService;
use tron_runtime::tasks::types::{
    AreaCreateParams, ProjectCreateParams, ProjectStatus, ProjectUpdateParams, TaskCreateParams,
    TaskPriority, TaskStatus, TaskUpdateParams,
};
use tron_tools::errors::ToolError;
use tron_tools::traits::TaskManagerDelegate;

/// Real task manager backed by `SQLite` via `TaskService`.
pub struct SqliteTaskManagerDelegate {
    pool: ConnectionPool,
}

impl SqliteTaskManagerDelegate {
    pub fn new(pool: ConnectionPool) -> Self {
        Self { pool }
    }
}

fn tool_err(msg: impl std::fmt::Display) -> ToolError {
    ToolError::Internal {
        message: msg.to_string(),
    }
}

fn get_str(params: &Value, key: &str) -> Option<String> {
    params.get(key).and_then(Value::as_str).map(String::from)
}

fn get_i64(params: &Value, key: &str) -> Option<i64> {
    params.get(key).and_then(Value::as_i64)
}

/// Parse an enum from a JSON string value using serde deserialization.
/// These types implement `Deserialize` with `rename_all = "lowercase"` but
/// not `FromStr`, so we round-trip through a JSON string literal.
fn parse_status(s: &str) -> Option<TaskStatus> {
    serde_json::from_value(Value::String(s.to_string())).ok()
}

fn parse_priority(s: &str) -> Option<TaskPriority> {
    serde_json::from_value(Value::String(s.to_string())).ok()
}

fn parse_project_status(s: &str) -> Option<ProjectStatus> {
    serde_json::from_value(Value::String(s.to_string())).ok()
}

#[async_trait]
#[allow(clippy::too_many_lines)]
impl TaskManagerDelegate for SqliteTaskManagerDelegate {
    async fn execute_action(&self, action: &str, params: Value) -> Result<Value, ToolError> {
        let conn = self.pool.get().map_err(tool_err)?;

        match action {
            "create" => {
                let title = get_str(&params, "title")
                    .ok_or_else(|| tool_err("title is required for create"))?;
                let create_params = TaskCreateParams {
                    title,
                    description: get_str(&params, "description"),
                    status: get_str(&params, "status").and_then(|s| parse_status(&s)),
                    priority: get_str(&params, "priority").and_then(|s| parse_priority(&s)),
                    project_id: get_str(&params, "projectId"),
                    area_id: get_str(&params, "areaId"),
                    parent_task_id: get_str(&params, "parentTaskId"),
                    ..Default::default()
                };
                let task = TaskService::create_task(&conn, &create_params).map_err(tool_err)?;
                Ok(serde_json::to_value(&task).map_err(tool_err)?)
            }
            "update" => {
                let id = get_str(&params, "taskId")
                    .ok_or_else(|| tool_err("taskId is required for update"))?;
                let updates = TaskUpdateParams {
                    title: get_str(&params, "title"),
                    description: get_str(&params, "description"),
                    status: get_str(&params, "status").and_then(|s| parse_status(&s)),
                    priority: get_str(&params, "priority").and_then(|s| parse_priority(&s)),
                    project_id: get_str(&params, "projectId"),
                    area_id: get_str(&params, "areaId"),
                    add_note: get_str(&params, "note"),
                    ..Default::default()
                };
                let task =
                    TaskService::update_task(&conn, &id, &updates, None).map_err(tool_err)?;
                Ok(serde_json::to_value(&task).map_err(tool_err)?)
            }
            "get" => {
                let id = get_str(&params, "taskId")
                    .ok_or_else(|| tool_err("taskId is required for get"))?;
                let details = TaskService::get_task(&conn, &id).map_err(tool_err)?;
                Ok(serde_json::to_value(&details).map_err(tool_err)?)
            }
            "list" => {
                let limit = get_i64(&params, "limit").unwrap_or(20);
                let offset = get_i64(&params, "offset").unwrap_or(0);
                let status_filter = get_str(&params, "status");
                let project_filter = get_str(&params, "projectId");

                let mut sql = String::from(
                    "SELECT id, title, status, priority, project_id, area_id, \
                     created_at, started_at, completed_at \
                     FROM tasks WHERE 1=1",
                );
                let mut sql_params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

                if let Some(ref s) = status_filter {
                    sql.push_str(" AND status = ?");
                    sql_params.push(Box::new(s.clone()));
                }
                if let Some(ref p) = project_filter {
                    sql.push_str(" AND project_id = ?");
                    sql_params.push(Box::new(p.clone()));
                }
                sql.push_str(" ORDER BY created_at DESC LIMIT ? OFFSET ?");
                sql_params.push(Box::new(limit));
                sql_params.push(Box::new(offset));

                let param_refs: Vec<&dyn rusqlite::types::ToSql> =
                    sql_params.iter().map(AsRef::as_ref).collect();
                let mut stmt = conn.prepare(&sql).map_err(tool_err)?;
                let rows: Vec<Value> = stmt
                    .query_map(param_refs.as_slice(), |row| {
                        Ok(json!({
                            "id": row.get::<_, String>(0)?,
                            "title": row.get::<_, String>(1)?,
                            "status": row.get::<_, String>(2)?,
                            "priority": row.get::<_, String>(3)?,
                            "projectId": row.get::<_, Option<String>>(4)?,
                            "areaId": row.get::<_, Option<String>>(5)?,
                            "createdAt": row.get::<_, String>(6)?,
                            "startedAt": row.get::<_, Option<String>>(7)?,
                            "completedAt": row.get::<_, Option<String>>(8)?,
                        }))
                    })
                    .map_err(tool_err)?
                    .filter_map(Result::ok)
                    .collect();

                Ok(json!({ "tasks": rows, "count": rows.len() }))
            }
            "search" => {
                let query = get_str(&params, "query").unwrap_or_default();
                let limit = get_i64(&params, "limit").unwrap_or(20);

                let mut stmt = conn
                    .prepare(
                        "SELECT id, title, status, priority \
                         FROM tasks \
                         WHERE title LIKE '%' || ?1 || '%' \
                            OR description LIKE '%' || ?1 || '%' \
                         ORDER BY created_at DESC LIMIT ?2",
                    )
                    .map_err(tool_err)?;
                let rows: Vec<Value> = stmt
                    .query_map(rusqlite::params![query, limit], |row| {
                        Ok(json!({
                            "id": row.get::<_, String>(0)?,
                            "title": row.get::<_, String>(1)?,
                            "status": row.get::<_, String>(2)?,
                            "priority": row.get::<_, String>(3)?,
                        }))
                    })
                    .map_err(tool_err)?
                    .filter_map(Result::ok)
                    .collect();

                Ok(json!({ "tasks": rows, "count": rows.len() }))
            }
            "log_time" => {
                let id = get_str(&params, "taskId")
                    .ok_or_else(|| tool_err("taskId is required for log_time"))?;
                #[allow(clippy::cast_possible_truncation)]
                let minutes = get_i64(&params, "minutes")
                    .ok_or_else(|| tool_err("minutes is required for log_time"))? as i32;
                TaskService::log_time(&conn, &id, minutes, None).map_err(tool_err)?;
                Ok(json!({ "success": true, "taskId": id, "minutesLogged": minutes }))
            }
            "delete" => {
                let id = get_str(&params, "taskId")
                    .ok_or_else(|| tool_err("taskId is required for delete"))?;
                let deleted = TaskService::delete_task(&conn, &id, None).map_err(tool_err)?;
                Ok(json!({ "success": deleted, "taskId": id }))
            }
            "create_project" => {
                let title = get_str(&params, "projectTitle")
                    .or_else(|| get_str(&params, "title"))
                    .ok_or_else(|| tool_err("projectTitle is required"))?;
                let create_params = ProjectCreateParams {
                    title,
                    description: get_str(&params, "description"),
                    ..Default::default()
                };
                let project =
                    TaskService::create_project(&conn, &create_params).map_err(tool_err)?;
                Ok(serde_json::to_value(&project).map_err(tool_err)?)
            }
            "update_project" => {
                let id = get_str(&params, "projectId")
                    .ok_or_else(|| tool_err("projectId is required"))?;
                let updates = ProjectUpdateParams {
                    title: get_str(&params, "title")
                        .or_else(|| get_str(&params, "projectTitle")),
                    description: get_str(&params, "description"),
                    status: get_str(&params, "status")
                        .and_then(|s| parse_project_status(&s)),
                    ..Default::default()
                };
                let project =
                    TaskService::update_project(&conn, &id, &updates).map_err(tool_err)?;
                Ok(serde_json::to_value(&project).map_err(tool_err)?)
            }
            "get_project" | "delete_project" | "list_projects" => {
                // Direct SQL for these since TaskService doesn't expose them all
                match action {
                    "get_project" => {
                        let id = get_str(&params, "projectId")
                            .ok_or_else(|| tool_err("projectId is required"))?;
                        let mut stmt = conn
                            .prepare(
                                "SELECT id, title, description, status, created_at, completed_at \
                                 FROM projects WHERE id = ?1",
                            )
                            .map_err(tool_err)?;
                        let project: Option<Value> = stmt
                            .query_row(rusqlite::params![id], |row| {
                                Ok(json!({
                                    "id": row.get::<_, String>(0)?,
                                    "title": row.get::<_, String>(1)?,
                                    "description": row.get::<_, Option<String>>(2)?,
                                    "status": row.get::<_, String>(3)?,
                                    "createdAt": row.get::<_, String>(4)?,
                                    "completedAt": row.get::<_, Option<String>>(5)?,
                                }))
                            })
                            .ok();
                        Ok(project.unwrap_or(json!({ "error": "Project not found" })))
                    }
                    "delete_project" => {
                        let id = get_str(&params, "projectId")
                            .ok_or_else(|| tool_err("projectId is required"))?;
                        let deleted = conn
                            .execute("DELETE FROM projects WHERE id = ?1", rusqlite::params![id])
                            .map_err(tool_err)?;
                        Ok(json!({ "success": deleted > 0, "projectId": id }))
                    }
                    "list_projects" => {
                        let limit = get_i64(&params, "limit").unwrap_or(20);
                        let mut stmt = conn
                            .prepare(
                                "SELECT id, title, status, created_at \
                                 FROM projects ORDER BY created_at DESC LIMIT ?1",
                            )
                            .map_err(tool_err)?;
                        let rows: Vec<Value> = stmt
                            .query_map(rusqlite::params![limit], |row| {
                                Ok(json!({
                                    "id": row.get::<_, String>(0)?,
                                    "title": row.get::<_, String>(1)?,
                                    "status": row.get::<_, String>(2)?,
                                    "createdAt": row.get::<_, String>(3)?,
                                }))
                            })
                            .map_err(tool_err)?
                            .filter_map(Result::ok)
                            .collect();
                        Ok(json!({ "projects": rows, "count": rows.len() }))
                    }
                    _ => unreachable!(),
                }
            }
            "create_area" => {
                let title = get_str(&params, "areaTitle")
                    .or_else(|| get_str(&params, "title"))
                    .ok_or_else(|| tool_err("areaTitle is required"))?;
                let create_params = AreaCreateParams {
                    title,
                    description: get_str(&params, "description"),
                    ..Default::default()
                };
                let area = TaskService::create_area(&conn, &create_params).map_err(tool_err)?;
                Ok(serde_json::to_value(&area).map_err(tool_err)?)
            }
            "update_area" | "get_area" | "delete_area" | "list_areas" => {
                // Direct SQL for area operations
                match action {
                    "get_area" => {
                        let id = get_str(&params, "areaId")
                            .ok_or_else(|| tool_err("areaId is required"))?;
                        let mut stmt = conn
                            .prepare(
                                "SELECT id, title, description, created_at \
                                 FROM areas WHERE id = ?1",
                            )
                            .map_err(tool_err)?;
                        let area: Option<Value> = stmt
                            .query_row(rusqlite::params![id], |row| {
                                Ok(json!({
                                    "id": row.get::<_, String>(0)?,
                                    "title": row.get::<_, String>(1)?,
                                    "description": row.get::<_, Option<String>>(2)?,
                                    "createdAt": row.get::<_, String>(3)?,
                                }))
                            })
                            .ok();
                        Ok(area.unwrap_or(json!({ "error": "Area not found" })))
                    }
                    "update_area" => {
                        let id = get_str(&params, "areaId")
                            .ok_or_else(|| tool_err("areaId is required"))?;
                        let title = get_str(&params, "title")
                            .or_else(|| get_str(&params, "areaTitle"));
                        let desc = get_str(&params, "description");
                        if let Some(t) = &title {
                            let _ = conn.execute(
                                "UPDATE areas SET title = ?1 WHERE id = ?2",
                                rusqlite::params![t, id],
                            )
                            .map_err(tool_err)?;
                        }
                        if let Some(d) = &desc {
                            let _ = conn.execute(
                                "UPDATE areas SET description = ?1 WHERE id = ?2",
                                rusqlite::params![d, id],
                            )
                            .map_err(tool_err)?;
                        }
                        Ok(json!({ "success": true, "areaId": id }))
                    }
                    "delete_area" => {
                        let id = get_str(&params, "areaId")
                            .ok_or_else(|| tool_err("areaId is required"))?;
                        let deleted = conn
                            .execute("DELETE FROM areas WHERE id = ?1", rusqlite::params![id])
                            .map_err(tool_err)?;
                        Ok(json!({ "success": deleted > 0, "areaId": id }))
                    }
                    "list_areas" => {
                        let limit = get_i64(&params, "limit").unwrap_or(20);
                        let mut stmt = conn
                            .prepare(
                                "SELECT id, title, description, created_at \
                                 FROM areas ORDER BY created_at DESC LIMIT ?1",
                            )
                            .map_err(tool_err)?;
                        let rows: Vec<Value> = stmt
                            .query_map(rusqlite::params![limit], |row| {
                                Ok(json!({
                                    "id": row.get::<_, String>(0)?,
                                    "title": row.get::<_, String>(1)?,
                                    "description": row.get::<_, Option<String>>(2)?,
                                    "createdAt": row.get::<_, String>(3)?,
                                }))
                            })
                            .map_err(tool_err)?
                            .filter_map(Result::ok)
                            .collect();
                        Ok(json!({ "areas": rows, "count": rows.len() }))
                    }
                    _ => unreachable!(),
                }
            }
            other => Err(ToolError::Internal {
                message: format!("Unknown action: {other}"),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_events::ConnectionConfig;

    fn setup_pool() -> ConnectionPool {
        let pool = tron_events::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
            let _ = tron_runtime::tasks::migrations::run_migrations(&conn).unwrap();
        }
        pool
    }

    #[tokio::test]
    async fn create_and_get_task() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("create", json!({"title": "Test Task"}))
            .await
            .unwrap();
        assert!(result.get("id").is_some());
        assert_eq!(result["title"], "Test Task");

        let id = result["id"].as_str().unwrap();
        let detail = delegate
            .execute_action("get", json!({"taskId": id}))
            .await
            .unwrap();
        // TaskWithDetails uses #[serde(flatten)] — task fields are at top level
        assert_eq!(detail["id"].as_str(), Some(id));
        assert_eq!(detail["title"], "Test Task");
    }

    #[tokio::test]
    async fn list_tasks_empty() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("list", json!({}))
            .await
            .unwrap();
        assert_eq!(result["count"], 0);
    }

    #[tokio::test]
    async fn create_and_list_project() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("create_project", json!({"projectTitle": "My Project"}))
            .await
            .unwrap();
        assert!(result.get("id").is_some());

        let list = delegate
            .execute_action("list_projects", json!({}))
            .await
            .unwrap();
        assert_eq!(list["count"], 1);
    }

    #[tokio::test]
    async fn create_and_list_area() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("create_area", json!({"areaTitle": "My Area"}))
            .await
            .unwrap();
        assert!(result.get("id").is_some());

        let list = delegate
            .execute_action("list_areas", json!({}))
            .await
            .unwrap();
        assert_eq!(list["count"], 1);
    }

    #[tokio::test]
    async fn delete_task() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("create", json!({"title": "To Delete"}))
            .await
            .unwrap();
        let id = result["id"].as_str().unwrap().to_string();

        let deleted = delegate
            .execute_action("delete", json!({"taskId": id}))
            .await
            .unwrap();
        assert_eq!(deleted["success"], true);
    }

    #[tokio::test]
    async fn unknown_action_returns_error() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("unknown", json!({}))
            .await;
        assert!(result.is_err());
    }
}
