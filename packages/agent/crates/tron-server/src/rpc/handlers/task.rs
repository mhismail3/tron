//! Task handlers: create, update, list, delete, get, search.
//! Project handlers: create, list, get, update, delete.
//! Area handlers: create, list, get, update, delete.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

fn get_u32_param(params: Option<&Value>, key: &str, default: u32) -> u32 {
    params
        .and_then(|p| p.get(key))
        .and_then(Value::as_u64)
        .and_then(|v| u32::try_from(v).ok())
        .unwrap_or(default)
}

fn get_task_conn(ctx: &RpcContext) -> Result<tron_events::PooledConnection, RpcError> {
    ctx.task_pool
        .as_ref()
        .ok_or_else(|| RpcError::NotAvailable {
            message: "Task database not configured".into(),
        })?
        .get()
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })
}

fn task_error_to_rpc(e: &tron_runtime::tasks::TaskError, entity: &str, id: &str) -> RpcError {
    match e {
        tron_runtime::tasks::TaskError::NotFound { .. } => RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("{entity} '{id}' not found"),
        },
        _ => RpcError::Internal {
            message: e.to_string(),
        },
    }
}

/// Create a new task.
pub struct CreateTaskHandler;

#[async_trait]
impl MethodHandler for CreateTaskHandler {
    #[instrument(skip(self, ctx), fields(method = "task.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let title = require_string_param(params.as_ref(), "title")?;
        let conn = get_task_conn(ctx)?;

        let project_id = params
            .as_ref()
            .and_then(|p| p.get("projectId"))
            .and_then(Value::as_str)
            .map(String::from);
        let description = params
            .as_ref()
            .and_then(|p| p.get("description"))
            .and_then(Value::as_str)
            .map(String::from);

        let task = tron_runtime::tasks::TaskService::create_task(
            &conn,
            &tron_runtime::tasks::TaskCreateParams {
                title,
                description,
                project_id,
                ..Default::default()
            },
        )
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        Ok(serde_json::to_value(&task).unwrap_or_default())
    }
}

/// Get a task with details.
pub struct GetTaskHandler;

#[async_trait]
impl MethodHandler for GetTaskHandler {
    #[instrument(skip(self, ctx), fields(method = "task.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let task_id = require_string_param(params.as_ref(), "taskId")?;
        let conn = get_task_conn(ctx)?;

        let details = tron_runtime::tasks::TaskService::get_task(&conn, &task_id)
            .map_err(|e| task_error_to_rpc(&e, "Task", &task_id))?;

        Ok(serde_json::to_value(&details).unwrap_or_default())
    }
}

/// Update a task.
pub struct UpdateTaskHandler;

#[async_trait]
impl MethodHandler for UpdateTaskHandler {
    #[instrument(skip(self, ctx), fields(method = "task.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let task_id = require_string_param(params.as_ref(), "taskId")?;
        let conn = get_task_conn(ctx)?;

        let mut updates = tron_runtime::tasks::TaskUpdateParams::default();

        if let Some(title) = params
            .as_ref()
            .and_then(|p| p.get("title"))
            .and_then(Value::as_str)
        {
            updates.title = Some(title.to_string());
        }
        if let Some(status_str) = params
            .as_ref()
            .and_then(|p| p.get("status"))
            .and_then(Value::as_str)
        {
            updates.status = serde_json::from_value(Value::String(status_str.into())).ok();
        }
        if let Some(desc) = params
            .as_ref()
            .and_then(|p| p.get("description"))
            .and_then(Value::as_str)
        {
            updates.description = Some(desc.to_string());
        }

        let task = tron_runtime::tasks::TaskService::update_task(&conn, &task_id, &updates, None)
            .map_err(|e| task_error_to_rpc(&e, "Task", &task_id))?;

        Ok(serde_json::to_value(&task).unwrap_or_default())
    }
}

/// List tasks.
pub struct ListTasksHandler;

#[async_trait]
impl MethodHandler for ListTasksHandler {
    #[instrument(skip(self, ctx), fields(method = "task.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let conn = get_task_conn(ctx)?;

        let status_filter = params
            .as_ref()
            .and_then(|p| p.get("status"))
            .and_then(Value::as_str)
            .and_then(|s| {
                serde_json::from_value::<tron_runtime::tasks::TaskStatus>(Value::String(s.into()))
                    .ok()
            });

        let project_id = params
            .as_ref()
            .and_then(|p| p.get("projectId"))
            .and_then(Value::as_str)
            .map(String::from);

        let filter = tron_runtime::tasks::TaskFilter {
            status: status_filter,
            project_id,
            ..Default::default()
        };

        let limit = get_u32_param(params.as_ref(), "limit", 100);
        let offset = get_u32_param(params.as_ref(), "offset", 0);

        let result = tron_runtime::tasks::TaskRepository::list_tasks(&conn, &filter, limit, offset)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "tasks": result.tasks, "total": result.total }))
    }
}

/// Delete a task.
pub struct DeleteTaskHandler;

#[async_trait]
impl MethodHandler for DeleteTaskHandler {
    #[instrument(skip(self, ctx), fields(method = "task.delete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let task_id = require_string_param(params.as_ref(), "taskId")?;
        let conn = get_task_conn(ctx)?;

        let deleted = tron_runtime::tasks::TaskService::delete_task(&conn, &task_id, None)
            .map_err(|e| task_error_to_rpc(&e, "Task", &task_id))?;

        Ok(serde_json::json!({ "deleted": deleted }))
    }
}

/// Search tasks.
pub struct SearchTasksHandler;

#[async_trait]
impl MethodHandler for SearchTasksHandler {
    #[instrument(skip(self, ctx), fields(method = "task.search"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let query = require_string_param(params.as_ref(), "query")?;
        let conn = get_task_conn(ctx)?;

        let limit = get_u32_param(params.as_ref(), "limit", 50);

        let results = tron_runtime::tasks::TaskRepository::search_tasks(&conn, &query, limit)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "tasks": results }))
    }
}

/// Get task activity log.
pub struct GetTaskActivityHandler;

#[async_trait]
impl MethodHandler for GetTaskActivityHandler {
    #[instrument(skip(self, ctx), fields(method = "task.getActivity"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let task_id = require_string_param(params.as_ref(), "taskId")?;
        let conn = get_task_conn(ctx)?;

        let limit = get_u32_param(params.as_ref(), "limit", 20);

        let activity = tron_runtime::tasks::TaskRepository::get_activity(&conn, &task_id, limit)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "activity": activity }))
    }
}

/// Create a project.
pub struct CreateProjectHandler;

#[async_trait]
impl MethodHandler for CreateProjectHandler {
    #[instrument(skip(self, ctx), fields(method = "project.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let title = require_string_param(params.as_ref(), "title")?;
        let conn = get_task_conn(ctx)?;

        let description = params
            .as_ref()
            .and_then(|p| p.get("description"))
            .and_then(Value::as_str)
            .map(String::from);
        let area_id = params
            .as_ref()
            .and_then(|p| p.get("areaId"))
            .and_then(Value::as_str)
            .map(String::from);

        let project = tron_runtime::tasks::TaskService::create_project(
            &conn,
            &tron_runtime::tasks::ProjectCreateParams {
                title,
                description,
                area_id,
                ..Default::default()
            },
        )
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        Ok(serde_json::to_value(&project).unwrap_or_default())
    }
}

/// List projects.
pub struct ListProjectsHandler;

#[async_trait]
impl MethodHandler for ListProjectsHandler {
    #[instrument(skip(self, ctx), fields(method = "project.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let conn = get_task_conn(ctx)?;

        let result = tron_runtime::tasks::TaskRepository::list_projects(
            &conn,
            &tron_runtime::tasks::ProjectFilter::default(),
            100,
            0,
        )
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        Ok(serde_json::json!({ "projects": result.projects }))
    }
}

/// Get a project.
pub struct GetProjectHandler;

#[async_trait]
impl MethodHandler for GetProjectHandler {
    #[instrument(skip(self, ctx), fields(method = "project.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let project_id = require_string_param(params.as_ref(), "projectId")?;
        let conn = get_task_conn(ctx)?;

        let project = tron_runtime::tasks::TaskRepository::get_project(&conn, &project_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        match project {
            Some(p) => Ok(serde_json::to_value(&p).unwrap_or_default()),
            None => Err(RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Project '{project_id}' not found"),
            }),
        }
    }
}

/// Update a project.
pub struct UpdateProjectHandler;

#[async_trait]
impl MethodHandler for UpdateProjectHandler {
    #[instrument(skip(self, ctx), fields(method = "project.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let project_id = require_string_param(params.as_ref(), "projectId")?;
        let conn = get_task_conn(ctx)?;

        let mut updates = tron_runtime::tasks::ProjectUpdateParams::default();
        if let Some(title) = params
            .as_ref()
            .and_then(|p| p.get("title"))
            .and_then(Value::as_str)
        {
            updates.title = Some(title.to_string());
        }
        if let Some(desc) = params
            .as_ref()
            .and_then(|p| p.get("description"))
            .and_then(Value::as_str)
        {
            updates.description = Some(desc.to_string());
        }

        let project =
            tron_runtime::tasks::TaskService::update_project(&conn, &project_id, &updates)
                .map_err(|e| task_error_to_rpc(&e, "Project", &project_id))?;

        Ok(serde_json::to_value(&project).unwrap_or_default())
    }
}

/// Delete a project.
pub struct DeleteProjectHandler;

#[async_trait]
impl MethodHandler for DeleteProjectHandler {
    #[instrument(skip(self, ctx), fields(method = "project.delete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let project_id = require_string_param(params.as_ref(), "projectId")?;
        let conn = get_task_conn(ctx)?;

        let deleted = tron_runtime::tasks::TaskRepository::delete_project(&conn, &project_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "deleted": deleted }))
    }
}

/// Get project details including tasks.
pub struct GetProjectDetailsHandler;

#[async_trait]
impl MethodHandler for GetProjectDetailsHandler {
    #[instrument(skip(self, ctx), fields(method = "project.getDetails"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let project_id = require_string_param(params.as_ref(), "projectId")?;
        let conn = get_task_conn(ctx)?;

        let project = tron_runtime::tasks::TaskRepository::get_project(&conn, &project_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let project = project.ok_or_else(|| RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("Project '{project_id}' not found"),
        })?;

        // Get tasks for this project
        let filter = tron_runtime::tasks::TaskFilter {
            project_id: Some(project_id),
            ..Default::default()
        };
        let task_result = tron_runtime::tasks::TaskRepository::list_tasks(&conn, &filter, 1000, 0)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let mut project_json = serde_json::to_value(&project).unwrap_or_default();
        if let Some(obj) = project_json.as_object_mut() {
            let _ = obj.insert("tasks".into(), serde_json::json!(task_result.tasks));
        }

        Ok(project_json)
    }
}

/// Create an area.
pub struct CreateAreaHandler;

#[async_trait]
impl MethodHandler for CreateAreaHandler {
    #[instrument(skip(self, ctx), fields(method = "area.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let title = require_string_param(params.as_ref(), "title")?;
        let conn = get_task_conn(ctx)?;

        let description = params
            .as_ref()
            .and_then(|p| p.get("description"))
            .and_then(Value::as_str)
            .map(String::from);

        let area = tron_runtime::tasks::TaskService::create_area(
            &conn,
            &tron_runtime::tasks::AreaCreateParams {
                title,
                description,
                ..Default::default()
            },
        )
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        Ok(serde_json::to_value(&area).unwrap_or_default())
    }
}

/// List areas.
pub struct ListAreasHandler;

#[async_trait]
impl MethodHandler for ListAreasHandler {
    #[instrument(skip(self, ctx), fields(method = "area.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let conn = get_task_conn(ctx)?;

        let result = tron_runtime::tasks::TaskRepository::list_areas(
            &conn,
            &tron_runtime::tasks::AreaFilter::default(),
            100,
            0,
        )
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        Ok(serde_json::json!({ "areas": result.areas }))
    }
}

/// Get an area.
pub struct GetAreaHandler;

#[async_trait]
impl MethodHandler for GetAreaHandler {
    #[instrument(skip(self, ctx), fields(method = "area.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let area_id = require_string_param(params.as_ref(), "areaId")?;
        let conn = get_task_conn(ctx)?;

        let area = tron_runtime::tasks::TaskRepository::get_area(&conn, &area_id).map_err(|e| {
            RpcError::Internal {
                message: e.to_string(),
            }
        })?;

        match area {
            Some(a) => Ok(serde_json::to_value(&a).unwrap_or_default()),
            None => Err(RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Area '{area_id}' not found"),
            }),
        }
    }
}

/// Update an area.
pub struct UpdateAreaHandler;

#[async_trait]
impl MethodHandler for UpdateAreaHandler {
    #[instrument(skip(self, ctx), fields(method = "area.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let area_id = require_string_param(params.as_ref(), "areaId")?;
        let conn = get_task_conn(ctx)?;

        let mut updates = tron_runtime::tasks::AreaUpdateParams::default();
        if let Some(title) = params
            .as_ref()
            .and_then(|p| p.get("title"))
            .and_then(Value::as_str)
        {
            updates.title = Some(title.to_string());
        }
        if let Some(desc) = params
            .as_ref()
            .and_then(|p| p.get("description"))
            .and_then(Value::as_str)
        {
            updates.description = Some(desc.to_string());
        }

        let area = tron_runtime::tasks::TaskRepository::update_area(&conn, &area_id, &updates)
            .map_err(|e| task_error_to_rpc(&e, "Area", &area_id))?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Area '{area_id}' not found"),
            })?;

        Ok(serde_json::to_value(&area).unwrap_or_default())
    }
}

/// Delete an area.
pub struct DeleteAreaHandler;

#[async_trait]
impl MethodHandler for DeleteAreaHandler {
    #[instrument(skip(self, ctx), fields(method = "area.delete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let area_id = require_string_param(params.as_ref(), "areaId")?;
        let conn = get_task_conn(ctx)?;

        let deleted =
            tron_runtime::tasks::TaskRepository::delete_area(&conn, &area_id).map_err(|e| {
                RpcError::Internal {
                    message: e.to_string(),
                }
            })?;

        Ok(serde_json::json!({ "deleted": deleted }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context_with_tasks;
    use serde_json::json;

    #[tokio::test]
    async fn create_task_basic() {
        let ctx = make_test_context_with_tasks();
        let result = CreateTaskHandler
            .handle(Some(json!({"title": "my task"})), &ctx)
            .await
            .unwrap();
        assert!(result["id"].is_string());
        assert_eq!(result["title"], "my task");
    }

    #[tokio::test]
    async fn create_task_missing_title() {
        let ctx = make_test_context_with_tasks();
        let err = CreateTaskHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn get_task_found() {
        let ctx = make_test_context_with_tasks();
        let created = CreateTaskHandler
            .handle(Some(json!({"title": "test"})), &ctx)
            .await
            .unwrap();
        let task_id = created["id"].as_str().unwrap();

        let result = GetTaskHandler
            .handle(Some(json!({"taskId": task_id})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["title"], "test");
    }

    #[tokio::test]
    async fn get_task_not_found() {
        let ctx = make_test_context_with_tasks();
        let err = GetTaskHandler
            .handle(Some(json!({"taskId": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn update_task_status() {
        let ctx = make_test_context_with_tasks();
        let created = CreateTaskHandler
            .handle(Some(json!({"title": "test"})), &ctx)
            .await
            .unwrap();
        let task_id = created["id"].as_str().unwrap();

        let result = UpdateTaskHandler
            .handle(
                Some(json!({"taskId": task_id, "status": "in_progress"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["status"], "in_progress");
    }

    #[tokio::test]
    async fn update_task_not_found() {
        let ctx = make_test_context_with_tasks();
        let err = UpdateTaskHandler
            .handle(
                Some(json!({"taskId": "missing", "status": "completed"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn delete_task_found() {
        let ctx = make_test_context_with_tasks();
        let created = CreateTaskHandler
            .handle(Some(json!({"title": "test"})), &ctx)
            .await
            .unwrap();
        let task_id = created["id"].as_str().unwrap();

        let result = DeleteTaskHandler
            .handle(Some(json!({"taskId": task_id})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["deleted"], true);
    }

    #[tokio::test]
    async fn list_tasks_empty() {
        let ctx = make_test_context_with_tasks();
        let result = ListTasksHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["tasks"].as_array().unwrap().len(), 0);
        assert_eq!(result["total"], 0);
    }

    #[tokio::test]
    async fn list_tasks_with_pagination() {
        let ctx = make_test_context_with_tasks();
        for i in 0..5 {
            let _ = CreateTaskHandler
                .handle(Some(json!({"title": format!("task {i}")})), &ctx)
                .await
                .unwrap();
        }

        let result = ListTasksHandler
            .handle(Some(json!({"limit": 3, "offset": 0})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["tasks"].as_array().unwrap().len(), 3);
        // total reflects all tasks, not just the page
        assert_eq!(result["total"], 5);
    }

    #[tokio::test]
    async fn list_tasks_ios_field_names() {
        let ctx = make_test_context_with_tasks();
        let result = ListTasksHandler.handle(None, &ctx).await.unwrap();
        // iOS TaskListResult expects {tasks: [RpcTask], total: Int}
        assert!(result.get("tasks").is_some());
        assert!(result.get("total").is_some());
        assert!(result["total"].is_number());
    }

    // Project tests
    #[tokio::test]
    async fn create_project() {
        let ctx = make_test_context_with_tasks();
        let result = CreateProjectHandler
            .handle(Some(json!({"title": "my project"})), &ctx)
            .await
            .unwrap();
        assert!(result["id"].is_string());
        assert_eq!(result["title"], "my project");
    }

    #[tokio::test]
    async fn list_projects() {
        let ctx = make_test_context_with_tasks();
        let _ = CreateProjectHandler
            .handle(Some(json!({"title": "proj1"})), &ctx)
            .await
            .unwrap();

        let result = ListProjectsHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["projects"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn get_project() {
        let ctx = make_test_context_with_tasks();
        let created = CreateProjectHandler
            .handle(Some(json!({"title": "proj"})), &ctx)
            .await
            .unwrap();
        let pid = created["id"].as_str().unwrap();

        let result = GetProjectHandler
            .handle(Some(json!({"projectId": pid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["title"], "proj");
    }

    #[tokio::test]
    async fn delete_project() {
        let ctx = make_test_context_with_tasks();
        let created = CreateProjectHandler
            .handle(Some(json!({"title": "proj"})), &ctx)
            .await
            .unwrap();
        let pid = created["id"].as_str().unwrap();

        let result = DeleteProjectHandler
            .handle(Some(json!({"projectId": pid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["deleted"], true);
    }

    // Project details tests
    #[tokio::test]
    async fn get_project_details_includes_tasks() {
        let ctx = make_test_context_with_tasks();
        let project = CreateProjectHandler
            .handle(Some(json!({"title": "proj"})), &ctx)
            .await
            .unwrap();
        let pid = project["id"].as_str().unwrap();

        // Create tasks under the project
        let _ = CreateTaskHandler
            .handle(Some(json!({"title": "t1", "projectId": pid})), &ctx)
            .await
            .unwrap();
        let _ = CreateTaskHandler
            .handle(Some(json!({"title": "t2", "projectId": pid})), &ctx)
            .await
            .unwrap();

        let result = GetProjectDetailsHandler
            .handle(Some(json!({"projectId": pid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["title"], "proj");
        assert_eq!(result["tasks"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn get_project_details_not_found() {
        let ctx = make_test_context_with_tasks();
        let err = GetProjectDetailsHandler
            .handle(Some(json!({"projectId": "missing"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    // Area tests
    #[tokio::test]
    async fn create_area() {
        let ctx = make_test_context_with_tasks();
        let result = CreateAreaHandler
            .handle(Some(json!({"title": "my area"})), &ctx)
            .await
            .unwrap();
        assert!(result["id"].is_string());
        assert_eq!(result["title"], "my area");
    }

    #[tokio::test]
    async fn list_areas() {
        let ctx = make_test_context_with_tasks();
        let _ = CreateAreaHandler
            .handle(Some(json!({"title": "area1"})), &ctx)
            .await
            .unwrap();

        let result = ListAreasHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["areas"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn get_area() {
        let ctx = make_test_context_with_tasks();
        let created = CreateAreaHandler
            .handle(Some(json!({"title": "area"})), &ctx)
            .await
            .unwrap();
        let aid = created["id"].as_str().unwrap();

        let result = GetAreaHandler
            .handle(Some(json!({"areaId": aid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["title"], "area");
    }

    #[tokio::test]
    async fn delete_area() {
        let ctx = make_test_context_with_tasks();
        let created = CreateAreaHandler
            .handle(Some(json!({"title": "area"})), &ctx)
            .await
            .unwrap();
        let aid = created["id"].as_str().unwrap();

        let result = DeleteAreaHandler
            .handle(Some(json!({"areaId": aid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["deleted"], true);
    }
}
