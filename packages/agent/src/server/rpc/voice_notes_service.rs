//! Voice notes service: storage and listing for `~/.tron/user/voice/`.

use serde_json::Value;

use crate::server::rpc::errors::RpcError;

pub(crate) fn notes_dir() -> String {
    let home = crate::core::paths::home_dir();
    format!("{home}/.tron/user/voice")
}

pub(crate) fn ensure_notes_dir(dir: &str) -> Result<(), RpcError> {
    std::fs::create_dir_all(dir).map_err(|error| RpcError::Internal {
        message: format!("Failed to create voice notes directory: {error}"),
    })
}

pub(crate) fn write_note(filepath: &str, content: &str) -> Result<(), RpcError> {
    std::fs::write(filepath, content).map_err(|error| RpcError::Internal {
        message: format!("Failed to write voice note: {error}"),
    })
}

pub(crate) fn list_notes(dir: &str, limit: usize, offset: usize) -> Value {
    let mut notes = Vec::new();

    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.ends_with(".md") || name.starts_with('.') {
                continue;
            }

            let path = entry.path();
            let content = std::fs::read_to_string(&path).unwrap_or_default();
            let note = parse_note(&name, &path.to_string_lossy(), &content);
            notes.push(note);
        }
    }

    notes.sort_by(|left, right| {
        let left_created = left["createdAt"].as_str().unwrap_or("");
        let right_created = right["createdAt"].as_str().unwrap_or("");
        right_created.cmp(left_created)
    });

    let total_count = notes.len();
    let has_more = offset + limit < total_count;
    let notes: Vec<Value> = notes.into_iter().skip(offset).take(limit).collect();

    serde_json::json!({
        "notes": notes,
        "totalCount": total_count,
        "hasMore": has_more,
    })
}

pub(crate) fn delete_note(filepath: &str, filename: &str) -> Value {
    let _ = std::fs::remove_file(filepath);
    serde_json::json!({
        "success": true,
        "filename": filename,
    })
}

fn parse_note(filename: &str, filepath: &str, content: &str) -> Value {
    let mut created_at = String::new();
    let mut duration_seconds: Option<f64> = None;
    let mut language: Option<String> = None;
    let mut transcript = String::new();

    if let Some(stripped) = content.strip_prefix("---\n")
        && let Some(end) = stripped.find("---\n")
    {
        let frontmatter = &stripped[..end];
        for line in frontmatter.lines() {
            if let Some(value) = line.strip_prefix("created: ") {
                created_at = value.trim().to_string();
            } else if let Some(value) = line.strip_prefix("duration: ") {
                duration_seconds = value.trim().parse().ok();
            } else if let Some(value) = line.strip_prefix("language: ") {
                language = Some(value.trim().to_string());
            }
        }
        transcript = content[4 + end + 4..].trim().to_string();
    }

    let preview = if transcript.len() > 100 {
        transcript[..100].to_string()
    } else {
        transcript.clone()
    };

    serde_json::json!({
        "filename": filename,
        "filepath": filepath,
        "createdAt": created_at,
        "durationSeconds": duration_seconds,
        "language": language,
        "preview": preview,
        "transcript": transcript,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_notes_ignores_non_matching_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("ignore.txt"), "x").unwrap();

        let result = list_notes(dir.path().to_str().unwrap(), 10, 0);

        assert!(result["notes"].as_array().unwrap().is_empty());
    }

    #[test]
    fn notes_dir_points_to_voice_notes() {
        let dir = notes_dir();
        assert!(
            dir.ends_with(".tron/user/voice"),
            "expected .tron/user/voice dir, got: {dir}"
        );
    }

    #[test]
    fn list_notes_includes_all_md_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("2026-01-01-000000-000-voice-note.md"),
            "---\ntype: voice-note\ncreated: 2026-01-01\nduration: 1.0\nlanguage: en\n---\n\nHello",
        )
        .unwrap();
        std::fs::write(dir.path().join("another-note.md"), "Also a voice note").unwrap();

        let result = list_notes(dir.path().to_str().unwrap(), 10, 0);
        let notes = result["notes"].as_array().unwrap();
        assert_eq!(notes.len(), 2, "all .md files in voice-notes dir should be listed");
    }

    #[test]
    fn list_notes_skips_hidden_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("visible.md"), "note").unwrap();
        std::fs::write(dir.path().join(".hidden.md"), "hidden").unwrap();

        let result = list_notes(dir.path().to_str().unwrap(), 10, 0);
        let notes = result["notes"].as_array().unwrap();
        assert_eq!(notes.len(), 1);
    }
}
