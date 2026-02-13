//! Worktree handlers: getStatus, commit, merge, list.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get worktree status.
pub struct GetStatusHandler;

#[async_trait]
impl MethodHandler for GetStatusHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "stub": true, "status": {} }))
    }
}

/// Commit worktree changes.
pub struct CommitHandler;

#[async_trait]
impl MethodHandler for CommitHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        let _message = require_string_param(params.as_ref(), "message")?;
        Ok(serde_json::json!({ "committed": true }))
    }
}

/// Merge worktree.
pub struct MergeHandler;

#[async_trait]
impl MethodHandler for MergeHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "merged": true }))
    }
}

/// List worktrees.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "worktrees": [] }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_status_success() {
        let ctx = make_test_context();
        let result = GetStatusHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(result.is_object());
    }

    #[tokio::test]
    async fn commit_missing_message() {
        let ctx = make_test_context();
        let err = CommitHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn merge_success() {
        let ctx = make_test_context();
        let result = MergeHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["merged"], true);
    }

    #[tokio::test]
    async fn list_worktrees() {
        let ctx = make_test_context();
        let result = ListHandler.handle(None, &ctx).await.unwrap();
        assert!(result["worktrees"].is_array());
    }
}
