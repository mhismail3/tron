//! transcription domain worker.
//!
//! This module owns canonical function execution for the transcription namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        super::domain_worker_module(
            "transcription",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

use base64::Engine;
use tracing::{debug, warn};

use crate::server::shared::params::opt_string;
use crate::transcription::TranscriptionResult;

const MAX_AUDIO_SIZE: usize = 150 * 1024 * 1024;

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

fn list_models_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let engine_loaded = deps.transcription_engine.get().is_some();
    let enabled = crate::settings::get_settings().server.transcription.enabled;
    Ok(json!({
        "models": [
            {
                "id": "parakeet-tdt-0.6b-v3",
                "name": "Parakeet TDT 0.6B v3",
                "size": "600M",
                "language": "en",
                "default": true,
                "enabled": enabled,
                "cached": engine_loaded,
                "engineLoaded": engine_loaded,
            }
        ]
    }))
}

async fn transcribe_audio_value(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let audio_base64 =
        opt_string(Some(payload), "audioBase64").ok_or_else(|| CapabilityError::InvalidParams {
            message: "Missing required parameter: audioBase64".into(),
        })?;
    let audio_base64 = normalize_base64(&audio_base64);
    let audio_bytes = base64::engine::general_purpose::STANDARD
        .decode(audio_base64)
        .map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid base64 audio data: {error}"),
        })?;

    if audio_bytes.len() > MAX_AUDIO_SIZE {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Audio data too large: {} bytes (max {})",
                audio_bytes.len(),
                MAX_AUDIO_SIZE
            ),
        });
    }

    let mime_type = opt_string(Some(payload), "mimeType");
    let mime_type = mime_type.as_deref().unwrap_or("audio/wav");
    debug!(
        audio_bytes = audio_bytes.len(),
        mime_type, "transcribe.audio received payload"
    );

    let response =
        transcribe_audio_full(&deps.transcription_engine, &audio_bytes, mime_type).await?;
    serde_json::to_value(&response).map_err(|error| CapabilityError::Internal {
        message: format!("serialize response: {error}"),
    })
}

fn download_model_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let engine_loaded = deps.transcription_engine.get().is_some();
    let enabled = crate::settings::get_settings().server.transcription.enabled;

    if !enabled {
        return Ok(json!({
            "started": false,
            "reason": "transcription_disabled",
            "message": "Enable transcription in settings, then restart Tron Server to load the local model.",
        }));
    }

    if engine_loaded {
        return Ok(json!({
            "started": false,
            "reason": "already_loaded",
        }));
    }

    Ok(json!({
        "started": false,
        "reason": "sidecar_manages_model_download",
        "message": "Model downloads automatically when the sidecar starts. Restart Tron Server to retry.",
    }))
}

pub(super) fn normalize_base64(input: &str) -> &str {
    match input.find(";base64,") {
        Some(index) => &input[index + 8..],
        None => input,
    }
}

pub(super) async fn transcribe_audio(
    transcription_engine: &Arc<std::sync::OnceLock<Arc<crate::transcription::MlxEngine>>>,
    audio_bytes: &[u8],
    mime_type: &str,
) -> TranscriptionResult {
    if let Ok(response) = transcribe_audio_full(transcription_engine, audio_bytes, mime_type).await
    {
        TranscriptionResult {
            text: response.text,
            language: response.language,
            duration_seconds: response.duration_seconds,
        }
    } else {
        #[allow(clippy::cast_precision_loss)]
        let estimated_duration = (audio_bytes.len() as f64) / 16_000.0;
        TranscriptionResult {
            text: "(transcription not available)".into(),
            language: "en".into(),
            duration_seconds: estimated_duration,
        }
    }
}

async fn transcribe_audio_full(
    transcription_engine: &Arc<std::sync::OnceLock<Arc<crate::transcription::MlxEngine>>>,
    audio_bytes: &[u8],
    mime_type: &str,
) -> Result<TranscribeResponse, CapabilityError> {
    let start = std::time::Instant::now();

    if !crate::settings::get_settings().server.transcription.enabled {
        return Err(CapabilityError::NotAvailable {
            message: "Transcription disabled".into(),
        });
    }

    let engine = transcription_engine
        .get()
        .ok_or(CapabilityError::NotAvailable {
            message: "Transcription engine not loaded".into(),
        })?;

    match engine.transcribe(audio_bytes, mime_type).await {
        Ok(result) => {
            #[allow(clippy::cast_possible_truncation)]
            let elapsed_ms = start.elapsed().as_millis() as u64;
            let cleaned = cleanup_transcription(&result.text);
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
        Err(error) => {
            warn!(error = %error, "transcription failed");
            Err(CapabilityError::NotAvailable {
                message: "Transcription not available (engine failed)".into(),
            })
        }
    }
}

fn cleanup_transcription(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let cleaned = trimmed.trim_start_matches(|c: char| c.is_ascii_punctuation() || c == ' ');
    if cleaned.is_empty() {
        return String::new();
    }
    let mut chars = cleaned.chars();
    match chars.next() {
        Some(first) => {
            let upper: String = first.to_uppercase().collect();
            upper + chars.as_str()
        }
        None => String::new(),
    }
}
