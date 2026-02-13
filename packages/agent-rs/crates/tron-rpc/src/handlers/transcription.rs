//! Transcription handlers: transcribe.audio, transcribe.listModels.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Transcribe an audio file.
pub struct TranscribeAudioHandler;

#[async_trait]
impl MethodHandler for TranscribeAudioHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _path = require_string_param(params.as_ref(), "path")?;
        Ok(serde_json::json!({ "stub": true, "text": "" }))
    }
}

/// List available transcription models.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "models": [] }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn transcribe_audio_success() {
        let ctx = make_test_context();
        let result = TranscribeAudioHandler
            .handle(Some(json!({"path": "/tmp/audio.wav"})), &ctx)
            .await
            .unwrap();
        assert!(result.is_object());
    }

    #[tokio::test]
    async fn transcribe_audio_missing_path() {
        let ctx = make_test_context();
        let err = TranscribeAudioHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn list_models() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["models"].is_array());
    }
}
