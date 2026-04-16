//! Transactional DB writer with dedup.
//!
//! Orchestrates the full import pipeline: parse → linearize → assemble →
//! transform → write. Detects duplicate imports via a tag on the session.

use std::path::Path;

use serde_json::json;

use crate::events::{AppendOptions, EventStore, EventType};
use crate::import::assembler::assemble;
use crate::import::errors::ImportError;
use crate::import::parser::parse_session;
use crate::import::transformer::transform;
use crate::import::tree::linearize;

/// Result of a successful import.
#[derive(Debug)]
pub struct ImportResult {
    /// Created Tron session ID.
    pub tron_session_id: String,
    /// Number of events written.
    pub event_count: i64,
    /// Number of turns.
    pub turn_count: i64,
    /// Number of messages (user + assistant).
    pub message_count: i64,
    /// Estimated total cost (USD).
    pub total_cost: f64,
    /// Primary model.
    pub model: String,
    /// Working directory.
    pub working_directory: String,
}

/// Import a Claude Code session into Tron.
///
/// Full pipeline: parse → linearize → assemble → transform → write.
/// Returns `ImportError::AlreadyImported` if the session was previously imported.
pub fn import_session(
    event_store: &EventStore,
    session_path: &Path,
    working_directory: &str,
    extra_tags: &[String],
    origin: Option<&str>,
) -> Result<ImportResult, ImportError> {
    // Extract session UUID from filename.
    let session_uuid = session_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown");
    let dedup_tag = format!("claude_code_import:{session_uuid}");

    // Check for duplicate import.
    if let Some(existing_id) = find_session_with_tag(event_store, &dedup_tag)? {
        return Err(ImportError::AlreadyImported {
            tron_session_id: existing_id,
        });
    }

    let records = parse_session(session_path)?;
    let linear = linearize(records);
    let assembled = assemble(linear);

    if assembled.is_empty() {
        return Err(ImportError::EmptySession);
    }

    let result = transform(assembled);

    if result.events.is_empty() {
        return Err(ImportError::EmptySession);
    }

    let model = if result.model.is_empty() {
        "claude-sonnet-4-20250514"
    } else {
        &result.model
    };

    let session = event_store.create_session(
        model,
        working_directory,
        result.title.as_deref(),
        None,
        origin,
        Some("import"),
    )?;

    let session_id = &session.session.id;

    for spec in &result.events {
        let _ = event_store.append(&AppendOptions {
            session_id,
            event_type: spec.event_type,
            payload: spec.payload.clone(),
            parent_id: None,
            sequence: None,
        })?;
    }

    let _ = event_store.append(&AppendOptions {
        session_id,
        event_type: EventType::MetadataTag,
        payload: json!({ "action": "add", "tag": dedup_tag }),
        parent_id: None,
        sequence: None,
    })?;

    for tag in extra_tags {
        let _ = event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::MetadataTag,
            payload: json!({ "action": "add", "tag": tag }),
            parent_id: None,
            sequence: None,
        })?;
    }

    if let Some(title) = &result.title {
        let _ = event_store.update_session_title(session_id, Some(title));
    }

    Ok(ImportResult {
        tron_session_id: session_id.clone(),
        event_count: result.events.len() as i64 + 1 + extra_tags.len() as i64,
        turn_count: result.turn_count,
        message_count: result.message_count,
        total_cost: result.total_cost,
        model: model.to_string(),
        working_directory: working_directory.to_string(),
    })
}

/// Find a session that has the given tag in its metadata.tag events.
pub(crate) fn find_session_with_tag(
    event_store: &EventStore,
    tag: &str,
) -> Result<Option<String>, ImportError> {
    use crate::events::sqlite::repositories::event::ListEventsOptions;
    use crate::events::sqlite::repositories::session::ListSessionsOptions;

    let sessions = event_store
        .list_sessions(&ListSessionsOptions::default())
        .map_err(ImportError::Database)?;

    let opts = ListEventsOptions::default();
    for session in sessions {
        let events = event_store
            .get_events_by_session(&session.id, &opts)
            .map_err(ImportError::Database)?;

        for event in &events {
            if event.event_type == "metadata.tag"
                && let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload)
                && payload.get("tag").and_then(|t| t.as_str()) == Some(tag)
                && payload.get("action").and_then(|a| a.as_str()) == Some("add")
            {
                return Ok(Some(session.id));
            }
        }
    }

    Ok(None)
}

#[cfg(test)]
#[path = "writer_tests.rs"]
mod tests;
