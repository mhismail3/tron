//! Task RPC handlers: create, update, list, delete, get, search, done, addNote, batchCreate.

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
        let description = opt_string(params.as_ref(), "description");
        let parent_task_id = opt_string(params.as_ref(), "parentTaskId");

        let task = with_task_conn(ctx, "task.create", move |conn| {
            crate::runtime::tasks::TaskService::create_task(
                conn,
                &crate::runtime::tasks::TaskCreateParams {
                    title,
                    description,
                    parent_task_id,
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

        let filter = crate::runtime::tasks::TaskFilter {
            status: status_filter,
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

/// Mark a task as completed.
pub struct DoneTaskHandler;

#[async_trait]
impl MethodHandler for DoneTaskHandler {
    #[instrument(skip(self, ctx), fields(method = "task.done"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let task_id = require_string_param(params.as_ref(), "taskId")?;
        let task = with_task_conn(ctx, "task.done", move |conn| {
            crate::runtime::tasks::TaskService::update_task(
                conn,
                &task_id,
                &crate::runtime::tasks::TaskUpdateParams {
                    status: Some(crate::runtime::tasks::TaskStatus::Completed),
                    ..Default::default()
                },
                None,
            )
            .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&task).unwrap_or_default())
    }
}

/// Append a note to a task.
pub struct AddNoteHandler;

#[async_trait]
impl MethodHandler for AddNoteHandler {
    #[instrument(skip(self, ctx), fields(method = "task.addNote"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let task_id = require_string_param(params.as_ref(), "taskId")?;
        let note = require_string_param(params.as_ref(), "note")?;

        let task = with_task_conn(ctx, "task.add_note", move |conn| {
            crate::runtime::tasks::TaskService::update_task(
                conn,
                &task_id,
                &crate::runtime::tasks::TaskUpdateParams {
                    add_note: Some(note),
                    ..Default::default()
                },
                None,
            )
            .map_err(|e| task_error_to_rpc(&e))
        })
        .await?;

        Ok(serde_json::to_value(&task).unwrap_or_default())
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
        assert_eq!(result["total"], 5);
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
    async fn done_task() {
        let ctx = make_test_context_with_tasks();
        let created = CreateTaskHandler
            .handle(Some(json!({"title": "to complete"})), &ctx)
            .await
            .unwrap();
        let task_id = created["id"].as_str().unwrap();

        let result = DoneTaskHandler
            .handle(Some(json!({"taskId": task_id})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["status"], "completed");
    }

    #[tokio::test]
    async fn add_note_to_task() {
        let ctx = make_test_context_with_tasks();
        let created = CreateTaskHandler
            .handle(Some(json!({"title": "note test"})), &ctx)
            .await
            .unwrap();
        let task_id = created["id"].as_str().unwrap();

        let result = AddNoteHandler
            .handle(Some(json!({"taskId": task_id, "note": "my note"})), &ctx)
            .await
            .unwrap();
        assert!(result["notes"].as_str().unwrap().contains("my note"));
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
    }
}
