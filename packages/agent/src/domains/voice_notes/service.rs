//! Voice notes projection helpers.
//!
//! Voice-note durability lives in typed resources. Filesystem paths are only
//! materialized locations attached to `materialized_file` resource versions.

use serde_json::{Value, json};

pub(crate) fn notes_dir() -> String {
    crate::shared::paths::voice_notes_dir()
        .to_string_lossy()
        .into_owned()
}

pub(crate) fn note_projection_from_payload(payload: &Value) -> Option<Value> {
    let filename = payload.get("filename")?.as_str()?;
    let filepath = payload.get("filepath")?.as_str()?;
    let transcript = payload
        .get("body")
        .or_else(|| payload.get("transcript"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let preview = transcript
        .char_indices()
        .nth(100)
        .map(|(idx, _)| transcript[..idx].to_owned())
        .unwrap_or_else(|| transcript.to_owned());
    Some(json!({
        "filename": filename,
        "filepath": filepath,
        "createdAt": payload.get("createdAt").and_then(Value::as_str).unwrap_or_default(),
        "durationSeconds": payload.get("durationSeconds").cloned().unwrap_or(Value::Null),
        "language": payload.get("language").cloned().unwrap_or(Value::Null),
        "preview": preview,
        "transcript": transcript,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notes_dir_points_to_voice_notes() {
        let dir = notes_dir();
        assert!(
            dir.ends_with(".tron/workspace/inbox/voice-notes"),
            "expected .tron/workspace/inbox/voice-notes dir, got: {dir}"
        );
    }

    #[test]
    fn projection_truncates_preview_on_character_boundary() {
        let payload = json!({
            "filename": "note.md",
            "filepath": "/tmp/note.md",
            "createdAt": "2026-01-01T00:00:00Z",
            "durationSeconds": 1.0,
            "language": "en",
            "body": "é".repeat(120),
        });

        let note = note_projection_from_payload(&payload).unwrap();
        assert_eq!(note["preview"].as_str().unwrap().chars().count(), 100);
    }
}
