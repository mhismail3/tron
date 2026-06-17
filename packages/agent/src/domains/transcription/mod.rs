//! Transcription domain worker.
//!
//! This domain owns local speech-to-text for client composer input. It restores
//! the Parakeet MLX sidecar as a narrow worker-owned capability surface:
//! `transcription::audio`, `transcription::list_models`, and
//! `transcription::download_model`. Saved voice notes, media storage, and
//! upload resources are intentionally not part of this domain.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Canonical transcription function contracts and schemas |
//! | `deps` | Narrow dependency bundle for handler setup |
//! | `handlers` | Operation-key bindings to domain functions |
//! | `implementation` | Local sidecar runtime, trait boundary, and worker assets |
//!
//! ## Invariants
//!
//! Transcription is a local server capability gated by
//! `settings.server.transcription.enabled`. The sidecar may create a Python
//! venv and model cache under `~/.tron/internal/transcription/`, but it must
//! not persist user audio beyond temporary files used for one request. Voice
//! notes and media storage remain Phase 2 work.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod implementation;

pub(crate) use deps::Deps;
pub use implementation::*;

use base64::Engine;
use serde_json::{Value, json};
use tracing::{debug, warn};

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_string;

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

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    crate::domains::registration::worker::domain_worker_module(
        "transcription",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}

fn list_models_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let engine_loaded = deps.transcription_engine.get().is_some();
    let status = deps.transcription_engine.status();
    let enabled = deps
        .profile_runtime
        .current()
        .settings
        .server
        .transcription
        .enabled;
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
                "state": status.state.as_str(),
                "message": status.message,
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
        mime_type, "transcription::audio received payload"
    );

    let response = transcribe_audio_full(deps, &audio_bytes, mime_type).await?;
    serde_json::to_value(&response).map_err(|error| CapabilityError::Internal {
        message: format!("serialize transcription response: {error}"),
    })
}

fn download_model_value(deps: &Deps) -> Value {
    let engine_loaded = deps.transcription_engine.get().is_some();
    let status = deps.transcription_engine.status();
    let enabled = deps
        .profile_runtime
        .current()
        .settings
        .server
        .transcription
        .enabled;

    if !enabled {
        return json!({
            "started": false,
            "reason": "transcription_disabled",
            "message": "Enable transcription in settings, then restart Tron Server to load the local model.",
        });
    }

    if engine_loaded {
        return json!({
            "started": false,
            "reason": "already_loaded",
        });
    }

    if status.state == TranscriptionRuntimeState::Loading {
        return json!({
            "started": false,
            "reason": "already_loading",
            "message": status.message.unwrap_or_else(|| "Local transcription model is already loading.".to_string()),
        });
    }

    json!({
        "started": false,
        "reason": "sidecar_manages_model_download",
        "message": status.message.unwrap_or_else(|| "Model downloads automatically when the sidecar starts. Restart Tron Server to retry.".to_string()),
    })
}

fn normalize_base64(input: &str) -> &str {
    match input.find(";base64,") {
        Some(index) => &input[index + 8..],
        None => input,
    }
}

async fn transcribe_audio_full(
    deps: &Deps,
    audio_bytes: &[u8],
    mime_type: &str,
) -> Result<TranscribeResponse, CapabilityError> {
    let start = std::time::Instant::now();

    if !deps
        .profile_runtime
        .current()
        .settings
        .server
        .transcription
        .enabled
    {
        return Err(CapabilityError::NotAvailable {
            message: "Transcription disabled".into(),
        });
    }

    let engine = deps
        .transcription_engine
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_data_url_prefix_is_ignored() {
        assert_eq!(normalize_base64("data:audio/wav;base64,abcd"), "abcd");
        assert_eq!(normalize_base64("abcd"), "abcd");
    }

    #[test]
    fn transcription_cleanup_trims_and_capitalizes() {
        assert_eq!(cleanup_transcription(" ...hello world "), "Hello world");
        assert_eq!(cleanup_transcription(""), "");
        assert_eq!(cleanup_transcription("!!!"), "");
    }
}
