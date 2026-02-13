//! Tree handlers: getVisualization, getBranches, getSubtree, getAncestors, compareBranches.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get tree visualization for a session.
pub struct GetVisualizationHandler;

#[async_trait]
impl MethodHandler for GetVisualizationHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "stub": true, "tree": {} }))
    }
}

/// Get branches for a session.
pub struct GetBranchesHandler;

#[async_trait]
impl MethodHandler for GetBranchesHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "branches": [] }))
    }
}

/// Get a subtree rooted at a specific event.
pub struct GetSubtreeHandler;

#[async_trait]
impl MethodHandler for GetSubtreeHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _event_id = require_string_param(params.as_ref(), "eventId")?;
        Ok(serde_json::json!({ "stub": true, "subtree": {} }))
    }
}

/// Get ancestor chain for an event.
pub struct GetAncestorsHandler;

#[async_trait]
impl MethodHandler for GetAncestorsHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _event_id = require_string_param(params.as_ref(), "eventId")?;
        Ok(serde_json::json!({ "ancestors": [] }))
    }
}

/// Compare two branches.
pub struct CompareBranchesHandler;

#[async_trait]
impl MethodHandler for CompareBranchesHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _branch_a = require_string_param(params.as_ref(), "branchA")?;
        let _branch_b = require_string_param(params.as_ref(), "branchB")?;
        Ok(serde_json::json!({ "stub": true, "comparison": {} }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_visualization_success() {
        let ctx = make_test_context();
        let result = GetVisualizationHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(result.is_object());
    }

    #[tokio::test]
    async fn get_visualization_missing_param() {
        let ctx = make_test_context();
        let err = GetVisualizationHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn get_branches_success() {
        let ctx = make_test_context();
        let result = GetBranchesHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(result["branches"].is_array());
    }

    #[tokio::test]
    async fn get_subtree_missing_param() {
        let ctx = make_test_context();
        let err = GetSubtreeHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn compare_branches_missing_param() {
        let ctx = make_test_context();
        let err = CompareBranchesHandler
            .handle(Some(json!({"branchA": "a"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
