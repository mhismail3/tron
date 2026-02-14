//! Transcription handlers: transcribe.audio, transcribe.listModels.

use async_trait::async_trait;
use base64::Engine;
use serde_json::Value;
use tracing::instrument;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::registry::MethodHandler;

/// Maximum audio size in bytes (50 MB).
const MAX_AUDIO_SIZE: usize = 50 * 1024 * 1024;

/// Transcribe an audio file via the sidecar service.
pub struct TranscribeAudioHandler;

#[async_trait]
impl MethodHandler for TranscribeAudioHandler {
    #[instrument(skip(self, ctx), fields(method = "transcribe.audio"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        // Transcription requires an explicit settings file with transcription enabled.
        // Default settings have enabled=true, so we must check the file exists to
        // avoid trying to connect to a sidecar that hasn't been configured.
        if !ctx.settings_path.exists() {
            return Err(RpcError::NotAvailable {
                message: "Transcription is not configured (no settings file)".into(),
            });
        }

        let settings = tron_settings::load_settings_from_path(&ctx.settings_path)
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to load settings: {e}"),
            })?;
        let transcription = &settings.server.transcription;

        if !transcription.enabled {
            return Err(RpcError::NotAvailable {
                message: "Transcription is not enabled in settings".into(),
            });
        }

        let audio_base64 = params
            .as_ref()
            .and_then(|p| p.get("audioBase64"))
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::InvalidParams {
                message: "Missing required parameter: audioBase64".into(),
            })?;

        // Decode and validate size
        let audio_bytes = base64::engine::general_purpose::STANDARD
            .decode(audio_base64)
            .map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid base64 audio data: {e}"),
            })?;

        if audio_bytes.len() > MAX_AUDIO_SIZE {
            return Err(RpcError::InvalidParams {
                message: format!(
                    "Audio data too large: {} bytes (max {})",
                    audio_bytes.len(),
                    MAX_AUDIO_SIZE
                ),
            });
        }

        let mime_type = params
            .as_ref()
            .and_then(|p| p.get("mimeType"))
            .and_then(Value::as_str)
            .unwrap_or("audio/wav");

        // POST to sidecar
        let base_url = &transcription.base_url;
        let client = reqwest::Client::new();
        let part = reqwest::multipart::Part::bytes(audio_bytes)
            .file_name("audio.wav")
            .mime_str(mime_type)
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to create multipart: {e}"),
            })?;

        let form = reqwest::multipart::Form::new().part("audio", part);

        let response = client
            .post(format!("{base_url}/transcribe"))
            .multipart(form)
            .send()
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Transcription sidecar request failed: {e}"),
            })?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(RpcError::Internal {
                message: format!("Transcription sidecar returned {status}: {body}"),
            });
        }

        let result: Value = response.json().await.map_err(|e| RpcError::Internal {
            message: format!("Failed to parse transcription response: {e}"),
        })?;

        Ok(result)
    }
}

/// List available transcription models.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    #[instrument(skip(self, _ctx), fields(method = "transcribe.listModels"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({
            "models": [
                {
                    "id": "parakeet-tdt-0.6b-v3",
                    "name": "Parakeet TDT 0.6B v3",
                    "size": "600M",
                    "language": "en",
                    "default": true,
                }
            ]
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn list_models_returns_models() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(!models.is_empty());
        assert_eq!(models[0]["id"], "parakeet-tdt-0.6b-v3");
        assert_eq!(models[0]["default"], true);
    }

    #[tokio::test]
    async fn list_models_model_has_required_fields() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let model = &result["models"][0];
        assert!(model["id"].is_string());
        assert!(model["name"].is_string());
        assert!(model["size"].is_string());
        assert!(model["language"].is_string());
    }

    #[tokio::test]
    async fn transcribe_audio_disabled_settings() {
        let ctx = make_test_context();
        // Default settings have transcription disabled
        let err = TranscribeAudioHandler
            .handle(Some(json!({"audioBase64": "SGVsbG8="})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn transcribe_audio_missing_base64() {
        // Write temp settings with transcription enabled
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(
            tmp.path(),
            r#"{"transcription":{"enabled":true,"baseUrl":"http://localhost:9876"}}"#,
        )
        .unwrap();

        let mut ctx = make_test_context();
        ctx.settings_path = tmp.path().to_path_buf();

        let err = TranscribeAudioHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn transcribe_audio_invalid_base64() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(
            tmp.path(),
            r#"{"transcription":{"enabled":true,"baseUrl":"http://localhost:9876"}}"#,
        )
        .unwrap();

        let mut ctx = make_test_context();
        ctx.settings_path = tmp.path().to_path_buf();

        let err = TranscribeAudioHandler
            .handle(Some(json!({"audioBase64": "!!!not-valid-base64!!!"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
