//! Voice notes handlers: save, list, delete.

use async_trait::async_trait;
use base64::Engine;
use serde_json::Value;
use tracing::{instrument, warn};

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::handlers::transcription::{normalize_base64, transcribe_audio_via_sidecar};
use crate::registry::MethodHandler;

fn notes_dir() -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    format!("{home}/.tron/notes/Voice Notes")
}

/// Save a voice note (accepts base64 audio, writes markdown with frontmatter).
///
/// Attempts transcription via the sidecar service inline. Falls back to a stub
/// if transcription is disabled or fails.
pub struct SaveHandler;

#[async_trait]
impl MethodHandler for SaveHandler {
    #[instrument(skip(self, ctx), fields(method = "voiceNotes.save"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let audio_base64 = require_string_param(params.as_ref(), "audioBase64")?;

        let mime_type = params
            .as_ref()
            .and_then(|p| p.get("mimeType"))
            .and_then(Value::as_str)
            .unwrap_or("audio/wav");
        let file_name = params
            .as_ref()
            .and_then(|p| p.get("fileName"))
            .and_then(Value::as_str);

        let dir = notes_dir();
        let _ = std::fs::create_dir_all(&dir);

        let now = chrono::Utc::now();
        let filename = format!("{}-voice-note.md", now.format("%Y-%m-%d-%H%M%S"));
        let filepath = format!("{dir}/{filename}");

        // Strip data URI prefix if present (iOS sends "data:audio/m4a;base64,...")
        let audio_base64 = normalize_base64(&audio_base64);

        // Decode audio
        let audio_bytes = base64::engine::general_purpose::STANDARD
            .decode(audio_base64)
            .map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid base64 audio data: {e}"),
            })?;

        // Rough duration estimate: ~16KB/s for compressed audio
        #[allow(clippy::cast_precision_loss)]
        let estimated_duration = (audio_bytes.len() as f64) / 16_000.0;

        // Try transcription via sidecar
        let (transcript_text, language, duration_seconds) =
            match transcribe_audio_via_sidecar(&ctx.settings_path, &audio_bytes, mime_type, file_name).await {
                Ok(result) => {
                    let text = result
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or("(transcription failed)")
                        .to_string();
                    let lang = result
                        .get("language")
                        .and_then(Value::as_str)
                        .unwrap_or("en")
                        .to_string();
                    let dur = result
                        .get("durationSeconds")
                        .and_then(Value::as_f64)
                        .unwrap_or(estimated_duration);
                    (text, lang, dur)
                }
                Err(e) => {
                    warn!(error = %e, "Transcription failed, using stub");
                    (
                        "(transcription not available)".to_string(),
                        "en".to_string(),
                        estimated_duration,
                    )
                }
            };

        // Write markdown with frontmatter
        let content = format!(
            "---\ntype: voice-note\ncreated: {}\nduration: {:.1}\nlanguage: {}\n---\n\n{}\n",
            now.to_rfc3339(),
            duration_seconds,
            language,
            transcript_text,
        );
        std::fs::write(&filepath, &content).map_err(|e| RpcError::Internal {
            message: format!("Failed to write voice note: {e}"),
        })?;

        Ok(serde_json::json!({
            "success": true,
            "filename": filename,
            "filepath": filepath,
            "transcription": {
                "text": transcript_text,
                "language": language,
                "durationSeconds": duration_seconds,
            },
        }))
    }
}

/// List voice notes (reads from ~/.tron/notes/).
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, _ctx), fields(method = "voiceNotes.list"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(Value::as_u64)
            .unwrap_or(50);
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);

        let offset = params
            .as_ref()
            .and_then(|p| p.get("offset"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let offset = usize::try_from(offset).unwrap_or(0);

        let dir = notes_dir();
        let mut notes = Vec::new();

        if let Ok(entries) = std::fs::read_dir(&dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if !name.ends_with("-voice-note.md") {
                    continue;
                }
                let path = entry.path();
                let content = std::fs::read_to_string(&path).unwrap_or_default();

                // Parse frontmatter
                let mut created_at = String::new();
                let mut duration_seconds: Option<f64> = None;
                let mut language: Option<String> = None;
                let mut transcript = String::new();

                if let Some(stripped) = content.strip_prefix("---\n") {
                    if let Some(end) = stripped.find("---\n") {
                        let fm = &stripped[..end];
                        for line in fm.lines() {
                            if let Some(val) = line.strip_prefix("created: ") {
                                created_at = val.trim().to_string();
                            } else if let Some(val) = line.strip_prefix("duration: ") {
                                duration_seconds = val.trim().parse().ok();
                            } else if let Some(val) = line.strip_prefix("language: ") {
                                language = Some(val.trim().to_string());
                            }
                        }
                        transcript = content[4 + end + 4..].trim().to_string();
                    }
                }

                let preview = if transcript.len() > 100 {
                    transcript[..100].to_string()
                } else {
                    transcript.clone()
                };

                notes.push(serde_json::json!({
                    "filename": name,
                    "filepath": path.to_string_lossy(),
                    "createdAt": created_at,
                    "durationSeconds": duration_seconds,
                    "language": language,
                    "preview": preview,
                    "transcript": transcript,
                }));
            }
        }

        // Sort newest first
        notes.sort_by(|a, b| {
            let a_ts = a["createdAt"].as_str().unwrap_or("");
            let b_ts = b["createdAt"].as_str().unwrap_or("");
            b_ts.cmp(a_ts)
        });

        let total_count = notes.len();
        let has_more = offset + limit < total_count;
        let notes: Vec<Value> = notes.into_iter().skip(offset).take(limit).collect();

        Ok(serde_json::json!({
            "notes": notes,
            "totalCount": total_count,
            "hasMore": has_more,
        }))
    }
}

/// Delete a voice note by filename.
pub struct DeleteHandler;

#[async_trait]
impl MethodHandler for DeleteHandler {
    #[instrument(skip(self, _ctx), fields(method = "voiceNotes.delete"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let filename = require_string_param(params.as_ref(), "filename")?;
        let filepath = format!("{}/{filename}", notes_dir());

        let _ = std::fs::remove_file(&filepath);

        Ok(serde_json::json!({
            "success": true,
            "filename": filename,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;
    use std::io::Write;

    #[test]
    fn notes_dir_returns_voice_notes_subdirectory() {
        let dir = notes_dir();
        assert!(
            dir.ends_with("Voice Notes"),
            "Expected 'Voice Notes' subdir, got: {dir}"
        );
    }

    #[tokio::test]
    async fn save_voice_note_with_data_uri_prefix() {
        // iOS sends: "data:audio/m4a;base64,SGVsbG8gV29ybGQ="
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
            .handle(
                Some(json!({"audioBase64": "SGVsbG8gV29ybGQ="})),
                &ctx,
            )
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
            .handle(
                Some(json!({"audioBase64": "SGVsbG8gV29ybGQ="})),
                &ctx,
            )
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
            .handle(
                Some(json!({"audioBase64": "!!!not-valid!!!"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn save_voice_note_missing_audio() {
        let ctx = make_test_context();
        let err = SaveHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
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
        let dir = notes_dir();
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
