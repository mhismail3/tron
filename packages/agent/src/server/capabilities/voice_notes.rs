use super::*;

use base64::Engine;
use uuid::Uuid;

use crate::server::services::voice_notes_service;
use crate::server::transport::json_rpc::params::{opt_string, require_string_param};

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, RpcError> {
    match method {
        "voice_notes::save" => save(&invocation.payload, deps).await,
        "voice_notes::delete" => delete(&invocation.payload, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("voice notes method {method} is not engine-owned"),
        }),
    }
}

async fn save(payload: &Value, deps: &EngineCapabilityDeps) -> Result<Value, RpcError> {
    let audio_base64 = require_string_param(Some(payload), "audioBase64")?;
    let mime_type_owned = opt_string(Some(payload), "mimeType");
    let mime_type = mime_type_owned.as_deref().unwrap_or("audio/wav");
    let dir = voice_notes_service::notes_dir();
    let create_dir = dir.clone();
    deps.capability_context
        .run_blocking("voiceNotes.mkdir", move || {
            voice_notes_service::ensure_notes_dir(&create_dir)
        })
        .await?;

    let now = chrono::Utc::now();
    let filename = build_voice_note_filename(now);
    let filepath = format!("{dir}/{filename}");
    let audio_base64 = super::transcription::normalize_base64(&audio_base64);
    let audio_bytes = base64::engine::general_purpose::STANDARD
        .decode(audio_base64)
        .map_err(|error| RpcError::InvalidParams {
            message: format!("Invalid base64 audio data: {error}"),
        })?;
    let result =
        super::transcription::transcribe_audio(&deps.capability_context, &audio_bytes, mime_type)
            .await;

    let content = format!(
        "---\ntype: voice-note\ncreated: {}\nduration: {:.1}\nlanguage: {}\n---\n\n{}\n",
        now.to_rfc3339(),
        result.duration_seconds,
        result.language,
        result.text,
    );
    let write_path = filepath.clone();
    deps.capability_context
        .run_blocking("voiceNotes.write", move || {
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

async fn delete(payload: &Value, deps: &EngineCapabilityDeps) -> Result<Value, RpcError> {
    let filename = require_string_param(Some(payload), "filename")?;
    let filepath = format!("{}/{filename}", voice_notes_service::notes_dir());
    let filename_for_response = filename.clone();
    deps.capability_context
        .run_blocking("voice_notes::delete", move || {
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
