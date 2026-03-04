//! Transcription handlers: transcribe.audio, transcribe.listModels, transcribe.downloadModel.

use async_trait::async_trait;
use base64::Engine;
use serde_json::Value;
use tracing::{info, instrument, warn};
use tron_transcription::TranscriptionResult;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::opt_string;
use crate::rpc::registry::MethodHandler;

/// Maximum audio size in bytes (50 MB).
const MAX_AUDIO_SIZE: usize = 50 * 1024 * 1024;

/// Typed response for the transcribe.audio RPC method.
///
/// Serializes to camelCase JSON matching the `TranscribeAudioResult` wire format.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct TranscribeResponse {
    text: String,
    raw_text: String,
    language: String,
    duration_seconds: f64,
    processing_time_ms: u64,
    model: String,
    device: String,
    compute_type: String,
    cleanup_mode: String,
}

/// Strip data URI prefix from base64-encoded audio.
///
/// Clients may send `data:audio/m4a;base64,AAAA...` — this extracts the raw
/// base64 portion after the `;base64,` marker. Plain base64 passes through unchanged.
pub fn normalize_base64(input: &str) -> &str {
    match input.find(";base64,") {
        Some(idx) => &input[idx + 8..],
        None => input,
    }
}

/// Shared transcription helper using the MLX sidecar.
///
/// Returns a [`TranscriptionResult`] with text, language, and duration.
pub async fn transcribe_audio(
    ctx: &RpcContext,
    audio_bytes: &[u8],
    mime_type: &str,
) -> TranscriptionResult {
    match transcribe_audio_full(ctx, audio_bytes, mime_type).await {
        Ok(resp) => TranscriptionResult {
            text: resp.text,
            language: resp.language,
            duration_seconds: resp.duration_seconds,
        },
        Err(_) => {
            #[allow(clippy::cast_precision_loss)]
            let estimated_duration = (audio_bytes.len() as f64) / 16_000.0;
            TranscriptionResult {
                text: "(transcription not available)".into(),
                language: "en".into(),
                duration_seconds: estimated_duration,
            }
        }
    }
}

/// Full transcription via the MLX sidecar.
async fn transcribe_audio_full(
    ctx: &RpcContext,
    audio_bytes: &[u8],
    mime_type: &str,
) -> Result<TranscribeResponse, RpcError> {
    let start = std::time::Instant::now();

    let engine = ctx.transcription_engine.get().ok_or(RpcError::NotAvailable {
        message: "Transcription engine not loaded".into(),
    })?;

    match engine.transcribe(audio_bytes, mime_type).await {
        Ok(result) => {
            #[allow(clippy::cast_possible_truncation)]
            let elapsed_ms = start.elapsed().as_millis() as u64;
            let cleaned = cleanup_transcription(&result.text);
            info!(
                "transcription succeeded ({:.1}s audio)",
                result.duration_seconds
            );
            Ok(TranscribeResponse {
                text: cleaned,
                raw_text: result.text,
                language: result.language,
                duration_seconds: result.duration_seconds,
                processing_time_ms: elapsed_ms,
                model: "parakeet-tdt-0.6b-v3".into(),
                device: "apple_silicon".into(),
                compute_type: "mlx".into(),
                cleanup_mode: "basic".into(),
            })
        }
        Err(e) => {
            warn!(error = %e, "transcription failed");
            Err(RpcError::NotAvailable {
                message: "Transcription not available (engine failed)".into(),
            })
        }
    }
}

/// Clean up raw transcription text for presentation.
///
/// ASR models like Parakeet sometimes produce artifacts:
/// - Leading punctuation (`, I want to...` or `. And then...`)
/// - Leading/trailing whitespace
///
/// This function strips those artifacts while preserving the semantic content.
/// The raw model output is always available in `raw_text`.
fn cleanup_transcription(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    // Strip leading punctuation and whitespace
    let cleaned = trimmed.trim_start_matches(|c: char| c.is_ascii_punctuation() || c == ' ');
    if cleaned.is_empty() {
        return String::new();
    }

    // Capitalize first letter
    let mut chars = cleaned.chars();
    match chars.next() {
        Some(first) => {
            let upper: String = first.to_uppercase().collect();
            upper + chars.as_str()
        }
        None => String::new(),
    }
}

/// Transcribe an audio file via the MLX sidecar.
pub struct TranscribeAudioHandler;

#[async_trait]
impl MethodHandler for TranscribeAudioHandler {
    #[instrument(skip(self, ctx), fields(method = "transcribe.audio"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let audio_base64 = opt_string(params.as_ref(), "audioBase64").ok_or_else(|| {
            RpcError::InvalidParams {
                message: "Missing required parameter: audioBase64".into(),
            }
        })?;

        // Strip data URI prefix if present (clients may send "data:audio/m4a;base64,...")
        let audio_base64 = normalize_base64(&audio_base64);

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

        let mime_type = opt_string(params.as_ref(), "mimeType");
        let mime_type = mime_type.as_deref().unwrap_or("audio/wav");

        info!(
            audio_bytes = audio_bytes.len(),
            mime_type,
            "transcribe.audio: received {} bytes, mime={}",
            audio_bytes.len(),
            mime_type
        );

        let resp = transcribe_audio_full(ctx, &audio_bytes, mime_type).await?;

        info!(
            text_len = resp.text.len(),
            duration = resp.duration_seconds,
            processing_ms = resp.processing_time_ms,
            text_preview = %if resp.text.len() > 100 { &resp.text[..100] } else { &resp.text },
            "transcribe.audio: result text_len={}, duration={:.1}s, processing={}ms, text=\"{}\"",
            resp.text.len(),
            resp.duration_seconds,
            resp.processing_time_ms,
            if resp.text.len() > 100 { &resp.text[..100] } else { &resp.text }
        );

        serde_json::to_value(&resp).map_err(|e| RpcError::Internal {
            message: format!("serialize response: {e}"),
        })
    }
}

/// List available transcription models with sidecar status.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    #[instrument(skip(self, ctx), fields(method = "transcribe.listModels"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let engine_loaded = ctx.transcription_engine.get().is_some();

        Ok(serde_json::json!({
            "models": [
                {
                    "id": "parakeet-tdt-0.6b-v3",
                    "name": "Parakeet TDT 0.6B v3",
                    "size": "600M",
                    "language": "en",
                    "default": true,
                    "cached": engine_loaded,
                    "engineLoaded": engine_loaded,
                }
            ]
        }))
    }
}

/// Report sidecar status. Model download happens automatically on first worker start.
pub struct DownloadModelHandler;

#[async_trait]
impl MethodHandler for DownloadModelHandler {
    #[instrument(skip(self, _ctx), fields(method = "transcribe.downloadModel"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let engine_loaded = _ctx.transcription_engine.get().is_some();

        if engine_loaded {
            return Ok(serde_json::json!({
                "started": false,
                "reason": "already_loaded",
            }));
        }

        Ok(serde_json::json!({
            "started": false,
            "reason": "sidecar_manages_model_download",
            "message": "Model downloads automatically when the sidecar starts. Restart the server to retry.",
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    // ── TranscribeResponse tests ──

    #[test]
    fn transcribe_response_serializes_camel_case() {
        let resp = TranscribeResponse {
            text: "hello".into(),
            raw_text: "hello".into(),
            language: "en".into(),
            duration_seconds: 2.5,
            processing_time_ms: 100,
            model: "parakeet".into(),
            device: "apple_silicon".into(),
            compute_type: "mlx".into(),
            cleanup_mode: "none".into(),
        };
        let val = serde_json::to_value(&resp).unwrap();
        assert_eq!(val["text"], "hello");
        assert_eq!(val["rawText"], "hello");
        assert_eq!(val["durationSeconds"], 2.5);
        assert_eq!(val["processingTimeMs"], 100);
        assert_eq!(val["computeType"], "mlx");
        assert_eq!(val["cleanupMode"], "none");
        // Verify NO snake_case keys leak through
        assert!(val.get("raw_text").is_none());
        assert!(val.get("duration_seconds").is_none());
        assert!(val.get("processing_time_ms").is_none());
        assert!(val.get("compute_type").is_none());
        assert!(val.get("cleanup_mode").is_none());
    }

    // ── TranscribeAudioHandler tests ──

    #[tokio::test]
    async fn transcribe_handler_returns_not_available_without_engine() {
        let ctx = make_test_context();
        let err = TranscribeAudioHandler
            .handle(Some(json!({"audioBase64": "SGVsbG8="})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn transcribe_audio_missing_base64() {
        let ctx = make_test_context();
        let err = TranscribeAudioHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn transcribe_audio_invalid_base64() {
        let ctx = make_test_context();
        let err = TranscribeAudioHandler
            .handle(Some(json!({"audioBase64": "!!!not-valid-base64!!!"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    // ── ListModelsHandler tests ──

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
    async fn list_models_shows_cached_status() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let model = &result["models"][0];
        assert!(model.get("cached").is_some());
        assert!(model["cached"].is_boolean());
    }

    #[tokio::test]
    async fn list_models_shows_engine_loaded() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let model = &result["models"][0];
        assert_eq!(model["engineLoaded"], false, "no engine in test context");
    }

    // ── DownloadModelHandler tests ──

    #[tokio::test]
    async fn download_model_handler_reports_status() {
        let ctx = make_test_context();
        let result = DownloadModelHandler.handle(None, &ctx).await.unwrap();
        assert!(result.get("started").is_some());
        assert!(result["started"].is_boolean());
    }

    // ── transcribe_audio shared helper tests ──

    #[tokio::test]
    async fn transcribe_audio_helper_no_engine() {
        let ctx = make_test_context();
        let result = transcribe_audio(&ctx, b"fake-audio", "audio/wav").await;
        assert_eq!(result.text, "(transcription not available)");
        assert_eq!(result.language, "en");
        assert!(result.duration_seconds > 0.0);
    }

    #[tokio::test]
    async fn transcribe_audio_full_returns_error_when_unavailable() {
        let ctx = make_test_context();
        let err = transcribe_audio_full(&ctx, b"fake-audio", "audio/wav")
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn transcribe_audio_helper_duration_estimate() {
        let ctx = make_test_context();
        let audio = vec![0u8; 16_000]; // 16KB = ~1s at 16KB/s estimate
        let result = transcribe_audio(&ctx, &audio, "audio/wav").await;
        assert!(
            (result.duration_seconds - 1.0).abs() < 0.01,
            "expected ~1.0s, got {}",
            result.duration_seconds
        );
    }

    // ── normalize_base64 tests ──

    #[test]
    fn normalize_base64_strips_data_uri() {
        assert_eq!(normalize_base64("data:audio/m4a;base64,AAAA"), "AAAA");
        assert_eq!(normalize_base64("data:audio/wav;base64,BBBB"), "BBBB");
    }

    #[test]
    fn normalize_base64_passthrough_plain() {
        assert_eq!(normalize_base64("SGVsbG8="), "SGVsbG8=");
    }

    #[test]
    fn normalize_base64_empty() {
        assert_eq!(normalize_base64(""), "");
    }

    // ── cleanup_transcription tests ──

    #[test]
    fn cleanup_strips_leading_comma() {
        assert_eq!(cleanup_transcription(", I want to test"), "I want to test");
    }

    #[test]
    fn cleanup_strips_leading_period() {
        assert_eq!(cleanup_transcription(". And then"), "And then");
    }

    #[test]
    fn cleanup_strips_leading_semicolon() {
        assert_eq!(
            cleanup_transcription("; something else"),
            "Something else"
        );
    }

    #[test]
    fn cleanup_capitalizes_first_letter() {
        assert_eq!(
            cleanup_transcription("hello world"),
            "Hello world"
        );
    }

    #[test]
    fn cleanup_preserves_already_capitalized() {
        assert_eq!(
            cleanup_transcription("Hello world"),
            "Hello world"
        );
    }

    #[test]
    fn cleanup_preserves_interior_punctuation() {
        assert_eq!(
            cleanup_transcription("Hello, world. How are you?"),
            "Hello, world. How are you?"
        );
    }

    #[test]
    fn cleanup_trims_whitespace() {
        assert_eq!(
            cleanup_transcription("  hello world  "),
            "Hello world"
        );
    }

    #[test]
    fn cleanup_empty_string() {
        assert_eq!(cleanup_transcription(""), "");
    }

    #[test]
    fn cleanup_only_punctuation() {
        assert_eq!(cleanup_transcription(",. ;"), "");
    }

    #[test]
    fn cleanup_preserves_numbers() {
        assert_eq!(cleanup_transcription(", 42 things"), "42 things");
    }

    #[test]
    fn cleanup_multiple_leading_punctuation() {
        assert_eq!(
            cleanup_transcription(",,, well then"),
            "Well then"
        );
    }
}
