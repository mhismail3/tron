//! Task handlers: create, update, list, delete.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Create a new task.
pub struct CreateTaskHandler;

#[async_trait]
impl MethodHandler for CreateTaskHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _title = require_string_param(params.as_ref(), "title")?;
        Ok(serde_json::json!({ "stub": true, "taskId": uuid::Uuid::now_v7().to_string() }))
    }
}

/// Update a task.
pub struct UpdateTaskHandler;

#[async_trait]
impl MethodHandler for UpdateTaskHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _task_id = require_string_param(params.as_ref(), "taskId")?;
        Ok(serde_json::json!({ "updated": true }))
    }
}

/// List tasks.
pub struct ListTasksHandler;

#[async_trait]
impl MethodHandler for ListTasksHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "tasks": [] }))
    }
}

/// Delete a task.
pub struct DeleteTaskHandler;

#[async_trait]
impl MethodHandler for DeleteTaskHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _task_id = require_string_param(params.as_ref(), "taskId")?;
        Ok(serde_json::json!({ "deleted": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn create_task_success() {
        let ctx = make_test_context();
        let result = CreateTaskHandler
            .handle(Some(json!({"title": "my task"})), &ctx)
            .await
            .unwrap();
        assert!(result["taskId"].is_string());
    }

    #[tokio::test]
    async fn create_task_missing_title() {
        let ctx = make_test_context();
        let err = CreateTaskHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn update_task_success() {
        let ctx = make_test_context();
        let result = UpdateTaskHandler
            .handle(Some(json!({"taskId": "t1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["updated"], true);
    }

    #[tokio::test]
    async fn delete_task_missing_id() {
        let ctx = make_test_context();
        let err = DeleteTaskHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
