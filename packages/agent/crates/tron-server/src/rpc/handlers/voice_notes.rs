//! Voice notes handlers: save, list, delete.

use async_trait::async_trait;
use base64::Engine;
use serde_json::Value;
use tracing::instrument;
use uuid::Uuid;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::transcription::{normalize_base64, transcribe_audio};
use crate::rpc::handlers::{opt_string, opt_u64, require_string_param};
use crate::rpc::registry::MethodHandler;
use crate::rpc::voice_notes_service;

/// Save a voice note (accepts base64 audio, writes markdown with frontmatter).
///
/// Attempts transcription via the sidecar service inline. Falls back to a stub
/// if transcription is disabled or fails.
pub struct SaveHandler;

fn build_voice_note_filename(now: chrono::DateTime<chrono::Utc>) -> String {
    format!(
        "{}-{}-voice-note.md",
        now.format("%Y-%m-%d-%H%M%S-%3f"),
        Uuid::now_v7()
    )
}

#[async_trait]
impl MethodHandler for SaveHandler {
    #[instrument(skip(self, ctx), fields(method = "voiceNotes.save"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let audio_base64 = require_string_param(params.as_ref(), "audioBase64")?;

        let mime_type_owned = opt_string(params.as_ref(), "mimeType");
        let mime_type = mime_type_owned.as_deref().unwrap_or("audio/wav");
        let dir = voice_notes_service::notes_dir();
        let create_dir = dir.clone();
        ctx.run_blocking("voiceNotes.mkdir", move || {
            voice_notes_service::ensure_notes_dir(&create_dir)
        })
        .await?;

        let now = chrono::Utc::now();
        let filename = build_voice_note_filename(now);
        let filepath = format!("{dir}/{filename}");

        // Strip data URI prefix if present (clients may send "data:audio/m4a;base64,...")
        let audio_base64 = normalize_base64(&audio_base64);

        // Decode audio
        let audio_bytes = base64::engine::general_purpose::STANDARD
            .decode(audio_base64)
            .map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid base64 audio data: {e}"),
            })?;

        // Transcribe via native ONNX engine (stub fallback if unavailable)
        let result = transcribe_audio(ctx, &audio_bytes, mime_type).await;

        // Write markdown with frontmatter
        let content = format!(
            "---\ntype: voice-note\ncreated: {}\nduration: {:.1}\nlanguage: {}\n---\n\n{}\n",
            now.to_rfc3339(),
            result.duration_seconds,
            result.language,
            result.text,
        );
        let write_path = filepath.clone();
        ctx.run_blocking("voiceNotes.write", move || {
            voice_notes_service::write_note(&write_path, &content)
        })
        .await?;

        Ok(serde_json::json!({
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
}

/// List voice notes (reads from ~/.tron/notes/).
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, ctx), fields(method = "voiceNotes.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let limit = usize::try_from(opt_u64(params.as_ref(), "limit", 50)).unwrap_or(usize::MAX);
        let offset = usize::try_from(opt_u64(params.as_ref(), "offset", 0)).unwrap_or(0);

        let dir = voice_notes_service::notes_dir();
        ctx.run_blocking("voiceNotes.list", move || {
            Ok(voice_notes_service::list_notes(&dir, limit, offset))
        })
        .await
    }
}

/// Delete a voice note by filename.
pub struct DeleteHandler;

#[async_trait]
impl MethodHandler for DeleteHandler {
    #[instrument(skip(self, ctx), fields(method = "voiceNotes.delete"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let filename = require_string_param(params.as_ref(), "filename")?;
        let filepath = format!("{}/{filename}", voice_notes_service::notes_dir());
        let filename_for_response = filename.clone();

        ctx.run_blocking("voiceNotes.delete", move || {
            Ok(voice_notes_service::delete_note(
                &filepath,
                &filename_for_response,
            ))
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;
    use std::io::Write;

    #[test]
    fn notes_dir_returns_voice_notes_subdirectory() {
        let dir = voice_notes_service::notes_dir();
        assert!(
            dir.ends_with("Voice Notes"),
            "Expected 'Voice Notes' subdir, got: {dir}"
        );
    }

    #[test]
    fn voice_note_filenames_are_unique_with_same_timestamp() {
        let now = chrono::Utc::now();
        let first = build_voice_note_filename(now);
        let second = build_voice_note_filename(now);

        assert_ne!(first, second);
        assert!(first.ends_with("-voice-note.md"));
        assert!(second.ends_with("-voice-note.md"));
    }

    #[tokio::test]
    async fn save_voice_note_with_data_uri_prefix() {
        // Handles data URI prefix: "data:audio/m4a;base64,SGVsbG8gV29ybGQ="
        let ctx = make_test_context();
        let result = SaveHandler
            .handle(
                Some(json!({"audioBase64": "data:audio/m4a;base64,SGVsbG8gV29ybGQ="})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        if let Some(fp) = result["filepath"].as_str() {
            let _ = std::fs::remove_file(fp);
        }
    }

    #[tokio::test]
    async fn save_voice_note_success() {
        let ctx = make_test_context();
        let result = SaveHandler
            .handle(Some(json!({"audioBase64": "SGVsbG8gV29ybGQ="})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert!(result["filename"].is_string());
        assert!(result["filepath"].is_string());
        assert!(result["transcription"]["text"].is_string());
        assert!(result["transcription"]["durationSeconds"].is_number());
        // Without sidecar configured, falls back to stub
        assert_eq!(
            result["transcription"]["text"].as_str().unwrap(),
            "(transcription not available)"
        );
        // Cleanup
        if let Some(fp) = result["filepath"].as_str() {
            let _ = std::fs::remove_file(fp);
        }
    }

    #[tokio::test]
    async fn save_voice_note_writes_transcript_to_file() {
        let ctx = make_test_context();
        let result = SaveHandler
            .handle(Some(json!({"audioBase64": "SGVsbG8gV29ybGQ="})), &ctx)
            .await
            .unwrap();
        let fp = result["filepath"].as_str().unwrap();
        let content = std::fs::read_to_string(fp).unwrap();
        assert!(content.contains("(transcription not available)"));
        assert!(content.contains("type: voice-note"));
        assert!(content.contains("language: en"));
        let _ = std::fs::remove_file(fp);
    }

    #[tokio::test]
    async fn save_voice_note_invalid_base64() {
        let ctx = make_test_context();
        let err = SaveHandler
            .handle(Some(json!({"audioBase64": "!!!not-valid!!!"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn save_voice_note_missing_audio() {
        let ctx = make_test_context();
        let err = SaveHandler.handle(Some(json!({})), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn list_voice_notes_empty() {
        let ctx = make_test_context();
        let result = ListHandler.handle(None, &ctx).await.unwrap();
        assert!(result["notes"].is_array());
        assert!(result["totalCount"].is_number());
        assert!(result.get("hasMore").is_some());
    }

    #[tokio::test]
    async fn list_voice_notes_with_pagination() {
        let ctx = make_test_context();
        let result = ListHandler
            .handle(Some(json!({"limit": 10, "offset": 0})), &ctx)
            .await
            .unwrap();
        assert!(result["notes"].is_array());
    }

    #[tokio::test]
    async fn delete_voice_note_by_filename() {
        let ctx = make_test_context();
        // Create a temp note
        let dir = voice_notes_service::notes_dir();
        let _ = std::fs::create_dir_all(&dir);
        let filename = "test-delete-voice-note.md";
        let path = format!("{dir}/{filename}");
        {
            let mut f = std::fs::File::create(&path).unwrap();
            f.write_all(b"test").unwrap();
        }

        let result = DeleteHandler
            .handle(Some(json!({"filename": filename})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["filename"], filename);
        assert!(!std::path::Path::new(&path).exists());
    }

    #[tokio::test]
    async fn delete_voice_note_missing_filename() {
        let ctx = make_test_context();
        let err = DeleteHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
