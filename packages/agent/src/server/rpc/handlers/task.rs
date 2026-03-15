//! Task handlers: create, update, list, delete, get, search.
//! Project handlers: create, list, get, update, delete.
//! Area handlers: create, list, get, update, delete.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::handlers::{opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;

fn get_u32_param(params: Option<&Value>, key: &str, default: u32) -> u32 {
    params
        .and_then(|p| p.get(key))
        .and_then(Value::as_u64)
        .and_then(|v| u32::try_from(v).ok())
        .unwrap_or(default)
}

async fn with_task_conn<T, F>(
    ctx: &RpcContext,
    task_name: &'static str,
    f: F,
) -> Result<T, RpcError>
where
    T: Send + 'static,
    F: FnOnce(&crate::events::PooledConnection) -> Result<T, RpcError> + Send + 'static,
{
    let pool = ctx
        .task_pool
        .clone()
        .ok_or_else(|| RpcError::NotAvailable {
            message: "Task database not configured".into(),
        })?;

    ctx.run_blocking(task_name, move || {
        let conn = pool.get().map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;
        f(&conn)
    })
    .await
}

fn task_error_to_rpc(e: &crate::runtime::tasks::TaskError) -> RpcError {
    match e {
        crate::runtime::tasks::TaskError::NotFound { entity, id } => RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("{entity} '{id}' not found"),
        },
        crate::runtime::tasks::TaskError::Busy { .. } => RpcError::NotAvailable {
            message: e.to_string(),
        },
        crate::runtime::tasks::TaskError::Validation(_)
        | crate::runtime::tasks::TaskError::CircularDependency { .. }
        | crate::runtime::tasks::TaskError::Hierarchy(_) => RpcError::InvalidParams {
            message: e.to_string(),
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
        let project_id = opt_string(params.as_ref(), "projectId");
        let description = opt_string(params.as_ref(), "description");

        let task = with_task_conn(ctx, "task.create", move |conn| {
            crate::runtime::tasks::TaskService::create_task(
                conn,
                &crate::runtime::tasks::TaskCreateParams {
                    title,
                    project_id,
                    description,
                    ..Default::default()
                },
            )
            .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let details = with_task_conn(ctx, "task.get", move |conn| {
            crate::runtime::tasks::TaskService::get_task(conn, &task_id)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let mut updates = crate::runtime::tasks::TaskUpdateParams::default();

        if let Some(title) = opt_string(params.as_ref(), "title") {
            updates.title = Some(title);
        }
        if let Some(status_str) = opt_string(params.as_ref(), "status") {
            updates.status = serde_json::from_value(Value::String(status_str)).ok();
        }
        if let Some(desc) = opt_string(params.as_ref(), "description") {
            updates.description = Some(desc);
        }

        let task = with_task_conn(ctx, "task.update", move |conn| {
            crate::runtime::tasks::TaskService::update_task(conn, &task_id, &updates, None)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&task).unwrap_or_default())
    }
}

/// List tasks.
pub struct ListTasksHandler;

#[async_trait]
impl MethodHandler for ListTasksHandler {
    #[instrument(skip(self, ctx), fields(method = "task.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let status_filter = opt_string(params.as_ref(), "status").and_then(|s| {
            serde_json::from_value::<crate::runtime::tasks::TaskStatus>(Value::String(s)).ok()
        });

        let project_id = opt_string(params.as_ref(), "projectId");

        let filter = crate::runtime::tasks::TaskFilter {
            status: status_filter,
            project_id,
            ..Default::default()
        };

        let limit = get_u32_param(params.as_ref(), "limit", 100);
        let offset = get_u32_param(params.as_ref(), "offset", 0);

        let result = with_task_conn(ctx, "task.list", move |conn| {
            crate::runtime::tasks::TaskService::list_tasks(conn, &filter, limit, offset)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let deleted = with_task_conn(ctx, "task.delete", move |conn| {
            crate::runtime::tasks::TaskService::delete_task(conn, &task_id, None)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let limit = get_u32_param(params.as_ref(), "limit", 50);

        let results = with_task_conn(ctx, "task.search", move |conn| {
            crate::runtime::tasks::TaskService::search_tasks(conn, &query, limit)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let limit = get_u32_param(params.as_ref(), "limit", 20);

        let activity = with_task_conn(ctx, "task.get_activity", move |conn| {
            crate::runtime::tasks::TaskService::get_task_activity(conn, &task_id, limit)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let description = opt_string(params.as_ref(), "description");
        let area_id = opt_string(params.as_ref(), "areaId");

        let project = with_task_conn(ctx, "project.create", move |conn| {
            crate::runtime::tasks::TaskService::create_project(
                conn,
                &crate::runtime::tasks::ProjectCreateParams {
                    title,
                    area_id,
                    description,
                    ..Default::default()
                },
            )
            .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&project).unwrap_or_default())
    }
}

/// List projects.
pub struct ListProjectsHandler;

#[async_trait]
impl MethodHandler for ListProjectsHandler {
    #[instrument(skip(self, ctx), fields(method = "project.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let result = with_task_conn(ctx, "project.list", move |conn| {
            crate::runtime::tasks::TaskService::list_projects(
                conn,
                &crate::runtime::tasks::ProjectFilter::default(),
                100,
                0,
            )
            .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let project = with_task_conn(ctx, "project.get", move |conn| {
            crate::runtime::tasks::TaskService::get_project(conn, &project_id)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&project).unwrap_or_default())
    }
}

/// Update a project.
pub struct UpdateProjectHandler;

#[async_trait]
impl MethodHandler for UpdateProjectHandler {
    #[instrument(skip(self, ctx), fields(method = "project.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let project_id = require_string_param(params.as_ref(), "projectId")?;
        let mut updates = crate::runtime::tasks::ProjectUpdateParams::default();
        if let Some(title) = opt_string(params.as_ref(), "title") {
            updates.title = Some(title);
        }
        if let Some(desc) = opt_string(params.as_ref(), "description") {
            updates.description = Some(desc);
        }

        let project = with_task_conn(ctx, "project.update", move |conn| {
            crate::runtime::tasks::TaskService::update_project(conn, &project_id, &updates)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let deleted = with_task_conn(ctx, "project.delete", move |conn| {
            crate::runtime::tasks::TaskService::delete_project(conn, &project_id)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        with_task_conn(ctx, "project.get_details", move |conn| {
            let project =
                crate::runtime::tasks::TaskService::get_project_details(conn, &project_id, 1000, 0)
                    .map_err(|e| task_error_to_rpc(&e))?;

            Ok(serde_json::to_value(&project).unwrap_or_default())
        })
        .await
    }
}

/// Create an area.
pub struct CreateAreaHandler;

#[async_trait]
impl MethodHandler for CreateAreaHandler {
    #[instrument(skip(self, ctx), fields(method = "area.create"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let title = require_string_param(params.as_ref(), "title")?;
        let description = opt_string(params.as_ref(), "description");

        let area = with_task_conn(ctx, "area.create", move |conn| {
            crate::runtime::tasks::TaskService::create_area(
                conn,
                &crate::runtime::tasks::AreaCreateParams {
                    title,
                    description,
                    ..Default::default()
                },
            )
            .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&area).unwrap_or_default())
    }
}

/// List areas.
pub struct ListAreasHandler;

#[async_trait]
impl MethodHandler for ListAreasHandler {
    #[instrument(skip(self, ctx), fields(method = "area.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let result = with_task_conn(ctx, "area.list", move |conn| {
            crate::runtime::tasks::TaskService::list_areas(
                conn,
                &crate::runtime::tasks::AreaFilter::default(),
                100,
                0,
            )
            .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let area = with_task_conn(ctx, "area.get", move |conn| {
            crate::runtime::tasks::TaskService::get_area(conn, &area_id)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&area).unwrap_or_default())
    }
}

/// Update an area.
pub struct UpdateAreaHandler;

#[async_trait]
impl MethodHandler for UpdateAreaHandler {
    #[instrument(skip(self, ctx), fields(method = "area.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let area_id = require_string_param(params.as_ref(), "areaId")?;
        let mut updates = crate::runtime::tasks::AreaUpdateParams::default();
        if let Some(title) = opt_string(params.as_ref(), "title") {
            updates.title = Some(title);
        }
        if let Some(desc) = opt_string(params.as_ref(), "description") {
            updates.description = Some(desc);
        }

        let area = with_task_conn(ctx, "area.update", move |conn| {
            crate::runtime::tasks::TaskService::update_area(conn, &area_id, &updates)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

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
        let deleted = with_task_conn(ctx, "area.delete", move |conn| {
            crate::runtime::tasks::TaskService::delete_area(conn, &area_id)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::json!({ "deleted": deleted }))
    }
}

/// Batch delete tasks by IDs or filter.
pub struct BatchDeleteTasksHandler;

#[async_trait]
impl MethodHandler for BatchDeleteTasksHandler {
    #[instrument(skip(self, ctx), fields(method = "tasks.batchDelete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let dry_run = params
            .as_ref()
            .and_then(|p| p.get("dryRun"))
            .and_then(Value::as_bool)
            .unwrap_or(false);

        let ids: Option<Vec<String>> = params
            .as_ref()
            .and_then(|p| p.get("ids"))
            .and_then(|v| serde_json::from_value(v.clone()).ok());
        let filter: Option<crate::runtime::tasks::TaskFilter> = params
            .as_ref()
            .and_then(|p| p.get("filter"))
            .and_then(|v| serde_json::from_value(v.clone()).ok());

        let target = crate::runtime::tasks::BatchTarget { ids, filter };
        let result = with_task_conn(ctx, "tasks.batch_delete", move |conn| {
            crate::runtime::tasks::TaskService::batch_delete_tasks(conn, &target, dry_run, None)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&result).unwrap_or_default())
    }
}

/// Batch update tasks by IDs or filter.
pub struct BatchUpdateTasksHandler;

#[async_trait]
impl MethodHandler for BatchUpdateTasksHandler {
    #[instrument(skip(self, ctx), fields(method = "tasks.batchUpdate"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let dry_run = params
            .as_ref()
            .and_then(|p| p.get("dryRun"))
            .and_then(Value::as_bool)
            .unwrap_or(false);

        let ids: Option<Vec<String>> = params
            .as_ref()
            .and_then(|p| p.get("ids"))
            .and_then(|v| serde_json::from_value(v.clone()).ok());
        let filter: Option<crate::runtime::tasks::TaskFilter> = params
            .as_ref()
            .and_then(|p| p.get("filter"))
            .and_then(|v| serde_json::from_value(v.clone()).ok());

        let target = crate::runtime::tasks::BatchTarget { ids, filter };

        let mut updates = crate::runtime::tasks::TaskUpdateParams::default();
        if let Some(title) = opt_string(params.as_ref(), "title") {
            updates.title = Some(title);
        }
        if let Some(status_str) = opt_string(params.as_ref(), "status") {
            updates.status = serde_json::from_value(Value::String(status_str)).ok();
        }
        if let Some(priority_str) = opt_string(params.as_ref(), "priority") {
            updates.priority = serde_json::from_value(Value::String(priority_str)).ok();
        }
        if let Some(desc) = opt_string(params.as_ref(), "description") {
            updates.description = Some(desc);
        }
        if let Some(pid) = opt_string(params.as_ref(), "projectId") {
            updates.project_id = Some(pid);
        }
        if let Some(aid) = opt_string(params.as_ref(), "areaId") {
            updates.area_id = Some(aid);
        }

        let result = with_task_conn(ctx, "tasks.batch_update", move |conn| {
            crate::runtime::tasks::TaskService::batch_update_tasks(
                conn, &target, &updates, dry_run, None,
            )
            .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&result).unwrap_or_default())
    }
}

/// Batch create tasks atomically.
pub struct BatchCreateTasksHandler;

#[async_trait]
impl MethodHandler for BatchCreateTasksHandler {
    #[instrument(skip(self, ctx), fields(method = "tasks.batchCreate"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let items: Vec<crate::runtime::tasks::TaskCreateParams> = params
            .as_ref()
            .and_then(|p| p.get("items"))
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or_default();

        let result = with_task_conn(ctx, "tasks.batch_create", move |conn| {
            crate::runtime::tasks::TaskService::batch_create_tasks(conn, &items, None)
                .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context_with_tasks;
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
    async fn list_tasks_wire_format_field_names() {
        let ctx = make_test_context_with_tasks();
        let result = ListTasksHandler.handle(None, &ctx).await.unwrap();
        // Wire format: {tasks: [RpcTask], total: Int}
        assert!(result.get("tasks").is_some());
        assert!(result.get("total").is_some());
        assert!(result["total"].is_number());
    }

    #[tokio::test]
    async fn search_tasks_matches_query() {
        let ctx = make_test_context_with_tasks();
        let _ = CreateTaskHandler
            .handle(Some(json!({"title": "fix login flow"})), &ctx)
            .await
            .unwrap();
        let _ = CreateTaskHandler
            .handle(Some(json!({"title": "write release notes"})), &ctx)
            .await
            .unwrap();

        let result = SearchTasksHandler
            .handle(Some(json!({"query": "login", "limit": 10})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["tasks"].as_array().unwrap().len(), 1);
        assert_eq!(result["tasks"][0]["title"], "fix login flow");
    }

    #[tokio::test]
    async fn get_task_activity_returns_recent_entries() {
        let ctx = make_test_context_with_tasks();
        let created = CreateTaskHandler
            .handle(Some(json!({"title": "track activity"})), &ctx)
            .await
            .unwrap();
        let task_id = created["id"].as_str().unwrap();

        let _ = UpdateTaskHandler
            .handle(
                Some(json!({"taskId": task_id, "status": "in_progress"})),
                &ctx,
            )
            .await
            .unwrap();

        let result = GetTaskActivityHandler
            .handle(Some(json!({"taskId": task_id, "limit": 10})), &ctx)
            .await
            .unwrap();

        let activity = result["activity"].as_array().unwrap();
        assert_eq!(activity.len(), 2);
        assert_eq!(activity[0]["action"], "status_changed");
        assert_eq!(activity[1]["action"], "created");
    }

    #[tokio::test]
    async fn get_task_activity_missing_task_returns_empty() {
        let ctx = make_test_context_with_tasks();
        let result = GetTaskActivityHandler
            .handle(Some(json!({"taskId": "task-missing", "limit": 10})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["activity"].as_array().unwrap().len(), 0);
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
    async fn create_project_empty_title_is_invalid_params() {
        let ctx = make_test_context_with_tasks();
        let err = CreateProjectHandler
            .handle(Some(json!({"title": "   "})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
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
    async fn get_project_not_found() {
        let ctx = make_test_context_with_tasks();
        let err = GetProjectHandler
            .handle(Some(json!({"projectId": "proj-missing"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn update_project_not_found() {
        let ctx = make_test_context_with_tasks();
        let err = UpdateProjectHandler
            .handle(
                Some(json!({"projectId": "proj-missing", "title": "updated"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
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

    // Batch tests
    #[tokio::test]
    async fn batch_delete_by_ids() {
        let ctx = make_test_context_with_tasks();
        let t1 = CreateTaskHandler
            .handle(Some(json!({"title": "a"})), &ctx)
            .await
            .unwrap();
        let t2 = CreateTaskHandler
            .handle(Some(json!({"title": "b"})), &ctx)
            .await
            .unwrap();
        let _t3 = CreateTaskHandler
            .handle(Some(json!({"title": "c"})), &ctx)
            .await
            .unwrap();

        let result = BatchDeleteTasksHandler
            .handle(Some(json!({"ids": [t1["id"], t2["id"]]})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["affected"], 2);
        assert_eq!(result["dryRun"], false);

        let list = ListTasksHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(list["total"], 1);
    }

    #[tokio::test]
    async fn batch_delete_dry_run() {
        let ctx = make_test_context_with_tasks();
        let t1 = CreateTaskHandler
            .handle(Some(json!({"title": "a"})), &ctx)
            .await
            .unwrap();

        let result = BatchDeleteTasksHandler
            .handle(Some(json!({"ids": [t1["id"]], "dryRun": true})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["affected"], 1);
        assert_eq!(result["dryRun"], true);

        // Still there
        let list = ListTasksHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(list["total"], 1);
    }

    #[tokio::test]
    async fn batch_update_by_ids() {
        let ctx = make_test_context_with_tasks();
        let t1 = CreateTaskHandler
            .handle(Some(json!({"title": "a"})), &ctx)
            .await
            .unwrap();
        let t2 = CreateTaskHandler
            .handle(Some(json!({"title": "b"})), &ctx)
            .await
            .unwrap();

        let result = BatchUpdateTasksHandler
            .handle(
                Some(json!({"ids": [t1["id"], t2["id"]], "status": "completed"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["affected"], 2);
    }

    #[tokio::test]
    async fn batch_create_tasks() {
        let ctx = make_test_context_with_tasks();
        let result = BatchCreateTasksHandler
            .handle(
                Some(json!({"items": [{"title": "x"}, {"title": "y"}]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["affected"], 2);
        assert_eq!(result["ids"].as_array().unwrap().len(), 2);

        let list = ListTasksHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(list["total"], 2);
    }

    #[tokio::test]
    async fn batch_delete_no_target() {
        let ctx = make_test_context_with_tasks();
        let result = BatchDeleteTasksHandler.handle(Some(json!({})), &ctx).await;
        assert!(result.is_err());
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
    async fn create_area_empty_title_is_invalid_params() {
        let ctx = make_test_context_with_tasks();
        let err = CreateAreaHandler
            .handle(Some(json!({"title": "   "})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
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
    async fn get_area_not_found() {
        let ctx = make_test_context_with_tasks();
        let err = GetAreaHandler
            .handle(Some(json!({"areaId": "area-missing"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn update_area_not_found() {
        let ctx = make_test_context_with_tasks();
        let err = UpdateAreaHandler
            .handle(
                Some(json!({"areaId": "area-missing", "title": "updated"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
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
