//! Transactional DB writer with dedup.
//!
//! Orchestrates the full import pipeline: parse → linearize → assemble →
//! transform → write. Detects duplicate imports via a tag on the session.

use std::path::Path;

use crate::events::{EventStore, EventStoreError, ImportAtomicOptions, ImportEventSpec};
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
///
/// The DB write phase runs entirely through [`EventStore::import_atomic`],
/// which performs the dedup check and every event append inside a single
/// SQLite transaction. A failed import therefore never leaves a partial
/// session in the store, and concurrent imports of the same source file
/// race to a single winner.
pub fn import_session(
    event_store: &EventStore,
    session_path: &Path,
    working_directory: &str,
    extra_tags: &[String],
    origin: Option<&str>,
) -> Result<ImportResult, ImportError> {
    let session_uuid = session_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown");
    let dedup_tag = format!("claude_code_import:{session_uuid}");

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

    // Fallback when no assistant message carried a model ID
    let model: &str = if result.model.is_empty() {
        "claude-sonnet-4-20250514"
    } else {
        &result.model
    };

    let event_specs: Vec<ImportEventSpec<'_>> = result
        .events
        .iter()
        .map(|spec| ImportEventSpec {
            event_type: spec.event_type,
            payload: &spec.payload,
        })
        .collect();

    let atomic = event_store
        .import_atomic(&ImportAtomicOptions {
            model,
            workspace_path: working_directory,
            title: result.title.as_deref(),
            origin,
            source: Some("import"),
            events: &event_specs,
            dedup_tag: &dedup_tag,
            extra_tags,
        })
        .map_err(|e| match e {
            EventStoreError::DuplicateImport { existing_session_id } => {
                ImportError::AlreadyImported {
                    tron_session_id: existing_session_id,
                }
            }
            other => ImportError::Database(other),
        })?;

    Ok(ImportResult {
        tron_session_id: atomic.session.id,
        // The event_count on the public API reports events ADDED during import,
        // excluding the synthetic session.start event (preserves prior semantics:
        // caller sees `transformed_events + 1 dedup_tag + extra_tags`).
        event_count: result.events.len() as i64 + 1 + extra_tags.len() as i64,
        turn_count: result.turn_count,
        message_count: result.message_count,
        total_cost: result.total_cost,
        model: model.to_string(),
        working_directory: working_directory.to_string(),
    })
}

#[cfg(test)]
#[path = "writer_tests.rs"]
mod tests;
