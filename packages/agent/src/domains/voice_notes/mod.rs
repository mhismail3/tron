//! voice notes domain worker.
//!
//! This module owns canonical function execution for the voice notes namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "voice_notes",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod service;

use base64::Engine;
use uuid::Uuid;

use crate::domains::voice_notes::service as voice_notes_service;
use crate::shared::server::params::{opt_string, opt_u64, require_string_param};

async fn list(payload: &Value, _deps: &Deps) -> Result<Value, CapabilityError> {
    let limit = usize::try_from(opt_u64(Some(payload), "limit", 50)).unwrap_or(usize::MAX);
    let offset = usize::try_from(opt_u64(Some(payload), "offset", 0)).unwrap_or(0);
    let dir = voice_notes_service::notes_dir();
    run_blocking_task("voice_notes::list", move || {
        Ok(voice_notes_service::list_notes(&dir, limit, offset))
    })
    .await
}

async fn save(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let audio_base64 = require_string_param(Some(payload), "audioBase64")?;
    let mime_type_owned = opt_string(Some(payload), "mimeType");
    let mime_type = mime_type_owned.as_deref().unwrap_or("audio/wav");
    let dir = voice_notes_service::notes_dir();
    let create_dir = dir.clone();
    run_blocking_task("voiceNotes.mkdir", move || {
        voice_notes_service::ensure_notes_dir(&create_dir)
    })
    .await?;

    let now = chrono::Utc::now();
    let filename = build_voice_note_filename(now);
    let filepath = format!("{dir}/{filename}");
    let audio_base64 = super::transcription::normalize_base64(&audio_base64);
    let audio_bytes = base64::engine::general_purpose::STANDARD
        .decode(audio_base64)
        .map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid base64 audio data: {error}"),
        })?;
    let result =
        super::transcription::transcribe_audio(&deps.transcription_engine, &audio_bytes, mime_type)
            .await;

    let content = format!(
        "---\ntype: voice-note\ncreated: {}\nduration: {:.1}\nlanguage: {}\n---\n\n{}\n",
        now.to_rfc3339(),
        result.duration_seconds,
        result.language,
        result.text,
    );
    let write_path = filepath.clone();
    run_blocking_task("voiceNotes.write", move || {
        voice_notes_service::write_note(&write_path, &content)
    })
    .await?;

    Ok(json!({
        "success": true,
        "filename": filename,
        "filepath": filepath,
        "transcription": {
            "text": result.text,
            "language": result.language,
            "durationSeconds": result.duration_seconds,
        },
    }))
}

async fn delete(payload: &Value, _deps: &Deps) -> Result<Value, CapabilityError> {
    let filename = require_string_param(Some(payload), "filename")?;
    let filepath = format!("{}/{filename}", voice_notes_service::notes_dir());
    let filename_for_response = filename.clone();
    run_blocking_task("voice_notes::delete", move || {
        Ok(voice_notes_service::delete_note(
            &filepath,
            &filename_for_response,
        ))
    })
    .await
}

fn build_voice_note_filename(now: chrono::DateTime<chrono::Utc>) -> String {
    format!(
        "{}-{}-voice-note.md",
        now.format("%Y-%m-%d-%H%M%S-%3f"),
        Uuid::now_v7()
    )
}
