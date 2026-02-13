//! Voice notes handlers: save, list, delete.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Save a voice note.
pub struct SaveHandler;

#[async_trait]
impl MethodHandler for SaveHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "saved": true, "noteId": uuid::Uuid::now_v7().to_string() }))
    }
}

/// List voice notes.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "notes": [] }))
    }
}

/// Delete a voice note.
pub struct DeleteHandler;

#[async_trait]
impl MethodHandler for DeleteHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _note_id = require_string_param(params.as_ref(), "noteId")?;
        Ok(serde_json::json!({ "deleted": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn save_voice_note_success() {
        let ctx = make_test_context();
        let result = SaveHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["saved"], true);
        assert!(result["noteId"].is_string());
    }

    #[tokio::test]
    async fn save_voice_note_missing_session() {
        let ctx = make_test_context();
        let err = SaveHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn list_voice_notes() {
        let ctx = make_test_context();
        let result = ListHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert!(result["notes"].is_array());
    }

    #[tokio::test]
    async fn delete_voice_note_missing_id() {
        let ctx = make_test_context();
        let err = DeleteHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
