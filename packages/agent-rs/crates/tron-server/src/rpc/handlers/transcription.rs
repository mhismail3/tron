//! Transcription handlers: transcribe.audio, transcribe.listModels, transcribe.downloadModel.

use std::path::Path;

use async_trait::async_trait;
use base64::Engine;
use serde_json::Value;
use tracing::{info, instrument, warn};

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::registry::MethodHandler;

/// Maximum audio size in bytes (50 MB).
const MAX_AUDIO_SIZE: usize = 50 * 1024 * 1024;

/// Map a MIME type to a sensible default filename with the correct extension.
///
/// The sidecar (and many audio libraries) uses the file extension to determine
/// the container format. Sending m4a audio with a `.wav` extension causes
/// "file does not start with RIFF id" errors.
fn filename_for_mime(mime_type: &str) -> String {
    let ext = match mime_type {
        "audio/mp4" | "audio/m4a" | "audio/x-m4a" | "audio/aac" => "m4a",
        "audio/mpeg" | "audio/mp3" => "mp3",
        "audio/ogg" | "audio/vorbis" => "ogg",
        "audio/webm" => "webm",
        "audio/flac" | "audio/x-flac" => "flac",
        "audio/x-caf" | "audio/x-aiff" => "caf",
        _ => "wav",
    };
    format!("audio.{ext}")
}

/// Strip data URI prefix from base64-encoded audio.
///
/// iOS sends `data:audio/m4a;base64,AAAA...` — this extracts the raw base64
/// portion after the `;base64,` marker. Plain base64 passes through unchanged.
pub fn normalize_base64(input: &str) -> &str {
    match input.find(";base64,") {
        Some(idx) => &input[idx + 8..],
        None => input,
    }
}

/// Transcribe audio bytes via the sidecar service.
///
/// Loads settings from `settings_path`, verifies transcription is enabled,
/// and POSTs the audio as multipart to the sidecar `/transcribe` endpoint.
///
/// Returns the sidecar JSON response on success or an `RpcError` on failure.
pub async fn transcribe_audio_via_sidecar(
    settings_path: &Path,
    audio_bytes: &[u8],
    mime_type: &str,
    file_name: Option<&str>,
) -> Result<Value, RpcError> {
    if !settings_path.exists() {
        return Err(RpcError::NotAvailable {
            message: "Transcription is not configured (no settings file)".into(),
        });
    }

    let settings =
        tron_settings::load_settings_from_path(settings_path).map_err(|e| RpcError::Internal {
            message: format!("Failed to load settings: {e}"),
        })?;
    let transcription = &settings.server.transcription;

    if !transcription.enabled {
        return Err(RpcError::NotAvailable {
            message: "Transcription is not enabled in settings".into(),
        });
    }

    if audio_bytes.len() > MAX_AUDIO_SIZE {
        return Err(RpcError::InvalidParams {
            message: format!(
                "Audio data too large: {} bytes (max {})",
                audio_bytes.len(),
                MAX_AUDIO_SIZE
            ),
        });
    }

    let base_url = &transcription.base_url;
    let client = reqwest::Client::new();
    let default_name = filename_for_mime(mime_type);
    let part = reqwest::multipart::Part::bytes(audio_bytes.to_vec())
        .file_name(file_name.unwrap_or(&default_name).to_string())
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

    response.json().await.map_err(|e| RpcError::Internal {
        message: format!("Failed to parse transcription response: {e}"),
    })
}

/// Shared transcription helper: tries native engine first, falls back to sidecar.
///
/// Returns `(text, language, duration_seconds)` on success, or a stub fallback
/// if both native and sidecar fail.
pub async fn transcribe_audio(
    ctx: &RpcContext,
    audio_bytes: &[u8],
    mime_type: &str,
    file_name: Option<&str>,
) -> (String, String, f64) {
    let result = transcribe_audio_full(ctx, audio_bytes, mime_type, file_name).await;
    (
        result["text"].as_str().unwrap_or("").to_string(),
        result["language"].as_str().unwrap_or("en").to_string(),
        result["durationSeconds"].as_f64().unwrap_or(0.0),
    )
}

/// Full transcription helper returning the complete response expected by iOS.
///
/// Returns a JSON object with all fields: text, rawText, language, durationSeconds,
/// processingTimeMs, model, device, computeType, cleanupMode.
async fn transcribe_audio_full(
    ctx: &RpcContext,
    audio_bytes: &[u8],
    mime_type: &str,
    file_name: Option<&str>,
) -> Value {
    // Rough duration estimate for fallback: ~16KB/s for compressed audio
    #[allow(clippy::cast_precision_loss)]
    let estimated_duration = (audio_bytes.len() as f64) / 16_000.0;

    let start = std::time::Instant::now();

    // Try native engine first
    if let Some(ref engine) = ctx.transcription_engine {
        match engine.transcribe(audio_bytes, mime_type).await {
            Ok(result) => {
                let elapsed_ms = start.elapsed().as_millis() as u64;
                info!(
                    "native transcription succeeded ({:.1}s audio)",
                    result.duration_seconds
                );
                return serde_json::json!({
                    "text": result.text,
                    "rawText": result.text,
                    "language": result.language,
                    "durationSeconds": result.duration_seconds,
                    "processingTimeMs": elapsed_ms,
                    "model": "parakeet-tdt-0.6b-v3",
                    "device": "cpu",
                    "computeType": "onnx",
                    "cleanupMode": "none",
                });
            }
            Err(e) => {
                warn!(error = %e, "native transcription failed, trying sidecar");
            }
        }
    }

    // Try sidecar
    match transcribe_audio_via_sidecar(&ctx.settings_path, audio_bytes, mime_type, file_name).await
    {
        Ok(result) => {
            let elapsed_ms = start.elapsed().as_millis() as u64;
            // Sidecar returns snake_case — map to camelCase for iOS
            let text = result.get("text").and_then(Value::as_str).unwrap_or("");
            serde_json::json!({
                "text": text,
                "rawText": result.get("raw_text").or_else(|| result.get("rawText"))
                    .and_then(Value::as_str).unwrap_or(text),
                "language": result.get("language").and_then(Value::as_str).unwrap_or("en"),
                "durationSeconds": result.get("duration_s").or_else(|| result.get("durationSeconds"))
                    .and_then(Value::as_f64).unwrap_or(estimated_duration),
                "processingTimeMs": result.get("processing_time_ms").or_else(|| result.get("processingTimeMs"))
                    .and_then(Value::as_u64).unwrap_or(elapsed_ms),
                "model": result.get("model").and_then(Value::as_str).unwrap_or(""),
                "device": result.get("device").and_then(Value::as_str).unwrap_or(""),
                "computeType": result.get("compute_type").or_else(|| result.get("computeType"))
                    .and_then(Value::as_str).unwrap_or(""),
                "cleanupMode": result.get("cleanup_mode").or_else(|| result.get("cleanupMode"))
                    .and_then(Value::as_str).unwrap_or("basic"),
            })
        }
        Err(e) => {
            warn!(error = %e, "sidecar transcription failed, using stub");
            serde_json::json!({
                "text": "(transcription not available)",
                "rawText": "",
                "language": "en",
                "durationSeconds": estimated_duration,
                "processingTimeMs": 0,
                "model": "",
                "device": "",
                "computeType": "",
                "cleanupMode": "none",
            })
        }
    }
}

/// Transcribe an audio file. Tries native engine first, falls back to sidecar.
pub struct TranscribeAudioHandler;

#[async_trait]
impl MethodHandler for TranscribeAudioHandler {
    #[instrument(skip(self, ctx), fields(method = "transcribe.audio"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let audio_base64 = params
            .as_ref()
            .and_then(|p| p.get("audioBase64"))
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::InvalidParams {
                message: "Missing required parameter: audioBase64".into(),
            })?;

        // Strip data URI prefix if present (iOS sends "data:audio/m4a;base64,...")
        let audio_base64 = normalize_base64(audio_base64);

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

        Ok(transcribe_audio_full(ctx, &audio_bytes, mime_type, None).await)
    }
}

/// List available transcription models with cached/engine status.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    #[instrument(skip(self, ctx), fields(method = "transcribe.listModels"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let model_dir = tron_transcription::model::default_model_dir();
        let cached = tron_transcription::model::is_model_cached(&model_dir);
        let engine_loaded = ctx.transcription_engine.is_some();

        Ok(serde_json::json!({
            "models": [
                {
                    "id": "parakeet-tdt-0.6b-v3",
                    "name": "Parakeet TDT 0.6B v3",
                    "size": "600M",
                    "language": "en",
                    "default": true,
                    "cached": cached,
                    "engineLoaded": engine_loaded,
                }
            ]
        }))
    }
}

/// Trigger background download of the transcription model.
pub struct DownloadModelHandler;

#[async_trait]
impl MethodHandler for DownloadModelHandler {
    #[instrument(skip(self, _ctx), fields(method = "transcribe.downloadModel"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let model_dir = tron_transcription::model::default_model_dir();

        if tron_transcription::model::is_model_cached(&model_dir) {
            return Ok(serde_json::json!({
                "started": false,
                "reason": "already_cached",
            }));
        }

        // Spawn background download — don't block the RPC response
        let dir = model_dir.clone();
        let _ = tokio::spawn(async move {
            match tron_transcription::model::ensure_model(&dir).await {
                Ok(()) => info!("transcription model download complete"),
                Err(e) => warn!(error = %e, "transcription model download failed"),
            }
        });

        Ok(serde_json::json!({
            "started": true,
            "modelDir": model_dir.to_string_lossy(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    // ── TranscribeAudioHandler tests ──

    #[tokio::test]
    async fn transcribe_falls_back_to_sidecar_when_no_engine() {
        // With no engine and no sidecar, handler returns stub via transcribe_audio
        let ctx = make_test_context();
        let result = TranscribeAudioHandler
            .handle(Some(json!({"audioBase64": "SGVsbG8="})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["text"], "(transcription not available)");
        assert_eq!(result["language"], "en");
        assert!(result["durationSeconds"].is_number());
    }

    #[tokio::test]
    async fn transcribe_handler_returns_full_ios_response() {
        let ctx = make_test_context();
        let result = TranscribeAudioHandler
            .handle(Some(json!({"audioBase64": "SGVsbG8="})), &ctx)
            .await
            .unwrap();
        // Must have all fields expected by iOS TranscribeAudioResult
        assert!(result.get("text").is_some());
        assert!(result.get("rawText").is_some());
        assert!(result.get("language").is_some());
        assert!(result.get("durationSeconds").is_some());
        assert!(result.get("processingTimeMs").is_some());
        assert!(result.get("model").is_some());
        assert!(result.get("device").is_some());
        assert!(result.get("computeType").is_some());
        assert!(result.get("cleanupMode").is_some());
    }

    #[tokio::test]
    async fn transcribe_audio_missing_base64() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(
            tmp.path(),
            r#"{"server":{"transcription":{"enabled":true,"baseUrl":"http://localhost:9876"}}}"#,
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
            r#"{"server":{"transcription":{"enabled":true,"baseUrl":"http://localhost:9876"}}}"#,
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
        // cached field must be present (value depends on filesystem state)
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
    async fn download_model_handler_returns_started() {
        let ctx = make_test_context();
        let result = DownloadModelHandler.handle(None, &ctx).await.unwrap();
        // Will return either started:true or started:false with reason:already_cached
        assert!(result.get("started").is_some());
        assert!(result["started"].is_boolean());
    }

    // ── transcribe_audio shared helper tests ──

    #[tokio::test]
    async fn transcribe_audio_helper_no_engine_no_sidecar() {
        let ctx = make_test_context();
        let (text, lang, dur) = transcribe_audio(&ctx, b"fake-audio", "audio/wav", None).await;
        assert_eq!(text, "(transcription not available)");
        assert_eq!(lang, "en");
        assert!(dur > 0.0);
    }

    #[tokio::test]
    async fn transcribe_audio_full_returns_all_fields() {
        let ctx = make_test_context();
        let result = transcribe_audio_full(&ctx, b"fake-audio", "audio/wav", None).await;
        assert_eq!(result["text"], "(transcription not available)");
        assert_eq!(result["rawText"], "");
        assert_eq!(result["language"], "en");
        assert!(result["durationSeconds"].is_number());
        assert!(result["processingTimeMs"].is_number());
        assert!(result["model"].is_string());
        assert!(result["device"].is_string());
        assert!(result["computeType"].is_string());
        assert!(result["cleanupMode"].is_string());
    }

    #[tokio::test]
    async fn transcribe_audio_helper_duration_estimate() {
        let ctx = make_test_context();
        let audio = vec![0u8; 16_000]; // 16KB = ~1s at 16KB/s estimate
        let (_, _, dur) = transcribe_audio(&ctx, &audio, "audio/wav", None).await;
        assert!((dur - 1.0).abs() < 0.01, "expected ~1.0s, got {dur}");
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

    // ── Sidecar helper tests ──

    #[tokio::test]
    async fn helper_no_settings_file() {
        let path = std::path::Path::new("/tmp/nonexistent-settings-2349847.json");
        let err = transcribe_audio_via_sidecar(path, b"audio", "audio/wav", None)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn helper_disabled_in_settings() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(
            tmp.path(),
            r#"{"server":{"transcription":{"enabled":false,"baseUrl":"http://localhost:9876"}}}"#,
        )
        .unwrap();

        let err = transcribe_audio_via_sidecar(tmp.path(), b"audio", "audio/wav", None)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn helper_audio_too_large() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(
            tmp.path(),
            r#"{"server":{"transcription":{"enabled":true,"baseUrl":"http://localhost:9876"}}}"#,
        )
        .unwrap();

        // Create a 51MB "audio" file (exceeds MAX_AUDIO_SIZE)
        let big = vec![0u8; 51 * 1024 * 1024];
        let err = transcribe_audio_via_sidecar(tmp.path(), &big, "audio/wav", None)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("too large"));
    }

    // ── filename_for_mime tests ──

    #[test]
    fn filename_for_mime_m4a_variants() {
        assert_eq!(filename_for_mime("audio/m4a"), "audio.m4a");
        assert_eq!(filename_for_mime("audio/mp4"), "audio.m4a");
        assert_eq!(filename_for_mime("audio/x-m4a"), "audio.m4a");
        assert_eq!(filename_for_mime("audio/aac"), "audio.m4a");
    }

    #[test]
    fn filename_for_mime_common_formats() {
        assert_eq!(filename_for_mime("audio/mpeg"), "audio.mp3");
        assert_eq!(filename_for_mime("audio/mp3"), "audio.mp3");
        assert_eq!(filename_for_mime("audio/ogg"), "audio.ogg");
        assert_eq!(filename_for_mime("audio/webm"), "audio.webm");
        assert_eq!(filename_for_mime("audio/flac"), "audio.flac");
        assert_eq!(filename_for_mime("audio/x-caf"), "audio.caf");
    }

    #[test]
    fn filename_for_mime_wav_default() {
        assert_eq!(filename_for_mime("audio/wav"), "audio.wav");
        assert_eq!(filename_for_mime("audio/x-wav"), "audio.wav");
        assert_eq!(filename_for_mime("unknown/type"), "audio.wav");
    }
}
