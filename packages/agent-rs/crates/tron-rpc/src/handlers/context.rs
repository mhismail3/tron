//! Context handlers: getSnapshot, getDetailedSnapshot, shouldCompact,
//! previewCompaction, confirmCompaction, canAcceptTurn, clear, compact.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get context snapshot for a session.
pub struct GetSnapshotHandler;

#[async_trait]
impl MethodHandler for GetSnapshotHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "stub": true, "snapshot": {} }))
    }
}

/// Get detailed context snapshot.
pub struct GetDetailedSnapshotHandler;

#[async_trait]
impl MethodHandler for GetDetailedSnapshotHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "stub": true, "snapshot": {} }))
    }
}

/// Check if compaction is recommended.
pub struct ShouldCompactHandler;

#[async_trait]
impl MethodHandler for ShouldCompactHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "shouldCompact": false }))
    }
}

/// Preview what compaction would produce.
pub struct PreviewCompactionHandler;

#[async_trait]
impl MethodHandler for PreviewCompactionHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "stub": true, "preview": {} }))
    }
}

/// Confirm and execute compaction.
pub struct ConfirmCompactionHandler;

#[async_trait]
impl MethodHandler for ConfirmCompactionHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "confirmed": true }))
    }
}

/// Check if the context can accept another turn.
pub struct CanAcceptTurnHandler;

#[async_trait]
impl MethodHandler for CanAcceptTurnHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "canAcceptTurn": true }))
    }
}

/// Clear context for a session.
pub struct ClearHandler;

#[async_trait]
impl MethodHandler for ClearHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "cleared": true }))
    }
}

/// Trigger compaction for a session.
pub struct CompactHandler;

#[async_trait]
impl MethodHandler for CompactHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "compacted": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_snapshot() {
        let ctx = make_test_context();
        let result = GetSnapshotHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(result.is_object());
    }

    #[tokio::test]
    async fn get_detailed_snapshot() {
        let ctx = make_test_context();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(result.is_object());
    }

    #[tokio::test]
    async fn should_compact() {
        let ctx = make_test_context();
        let result = ShouldCompactHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["shouldCompact"], false);
    }

    #[tokio::test]
    async fn preview_compaction() {
        let ctx = make_test_context();
        let result = PreviewCompactionHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(result.is_object());
    }

    #[tokio::test]
    async fn confirm_compaction() {
        let ctx = make_test_context();
        let result = ConfirmCompactionHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["confirmed"], true);
    }

    #[tokio::test]
    async fn can_accept_turn() {
        let ctx = make_test_context();
        let result = CanAcceptTurnHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["canAcceptTurn"], true);
    }

    #[tokio::test]
    async fn clear_context() {
        let ctx = make_test_context();
        let result = ClearHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["cleared"], true);
    }

    #[tokio::test]
    async fn compact_context() {
        let ctx = make_test_context();
        let result = CompactHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["compacted"], true);
    }
}
