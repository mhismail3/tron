//! Transactional DB writer with dedup.
//!
//! Orchestrates the full import pipeline: parse → linearize → assemble →
//! transform → write. Detects duplicate imports via a tag on the session.
//!
//! # M28 — dry-run validation
//!
//! The write path runs the pipeline via [`crate::domains::import::validator::validate_and_prepare`],
//! which produces BOTH the events the writer needs AND a validation
//! report. The report is attached to the returned [`ImportResult`] so a
//! caller sees the same warnings the dry-run surfaces (unparseable lines,
//! orphan capability invocations/results, missing model). No separate second pass —
//! the validator is the single source of pipeline output.

use std::path::Path;

use crate::domains::import::errors::ImportError;
use crate::domains::import::validator::{self, ImportWarning};
use crate::domains::session::event_store::{
    EventStore, EventStoreError, ImportAtomicOptions, ImportEventSpec,
};

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
    /// Sum of available server-priced token-record costs (USD).
    pub total_cost: f64,
    /// Primary model.
    pub model: String,
    /// Working directory.
    pub working_directory: String,
    /// Non-fatal warnings surfaced by the pipeline (M28).
    ///
    /// Empty on a clean import. On a source file with issues, each entry
    /// has a category ([`crate::domains::import::ImportWarningKind`]) and a
    /// human-readable message the caller can render to the user.
    pub warnings: Vec<ImportWarning>,
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
///
/// Non-fatal issues (unparseable lines, orphan capability invocations/results,
/// missing model) are attached to the returned [`ImportResult::warnings`]
/// via the shared validator. The same report is available before the
/// write via [`crate::domains::import::validate_session`].
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

    let prepared = validator::validate_and_prepare(session_path)?;
    let validator::ValidatedImport {
        validation,
        events,
        model,
    } = prepared;

    let event_specs: Vec<ImportEventSpec<'_>> = events
        .iter()
        .map(|spec| ImportEventSpec {
            event_type: spec.event_type,
            payload: &spec.payload,
        })
        .collect();

    let atomic = event_store
        .import_atomic(&ImportAtomicOptions {
            model: &model,
            workspace_path: working_directory,
            title: validation.preview.title.as_deref(),
            origin,
            source: Some("import"),
            events: &event_specs,
            dedup_tag: &dedup_tag,
            extra_tags,
        })
        .map_err(|e| match e {
            EventStoreError::DuplicateImport {
                existing_session_id,
            } => ImportError::AlreadyImported {
                tron_session_id: existing_session_id,
            },
            other => ImportError::Database(other),
        })?;

    Ok(ImportResult {
        tron_session_id: atomic.session.id,
        // The event_count on the public API reports events ADDED during import,
        // excluding the synthetic session.start event (preserves prior semantics:
        // caller sees `transformed_events + 1 dedup_tag + extra_tags`).
        event_count: events.len() as i64 + 1 + extra_tags.len() as i64,
        turn_count: validation.preview.turn_count,
        message_count: validation.preview.message_count,
        total_cost: validation.preview.total_cost,
        model,
        working_directory: working_directory.to_string(),
        warnings: validation.warnings,
    })
}

#[cfg(test)]
#[path = "writer_tests.rs"]
mod tests;
