//! Background retain task orchestration.

use std::sync::Arc;

use chrono::Utc;
use serde_json::json;
use tracing::{debug, warn};

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::{AppendOptions, EventStore};

use super::RetainSource;
use super::events::emit_auto_retain_failed;
use super::parsing::{parse_retain_output, slugify};
use super::summarizer::{SummarizerOutcome, keyword_summary, run_summarizer};
use super::writer::{
    argument_file_path, core_memory_file_path, split_title_and_body, write_argument_entry,
    write_core_memory_update, write_session_entry,
};

/// Background task that runs the summarizer and writes results.
#[allow(clippy::too_many_arguments)]
pub(super) async fn retain_background_task(
    session_id: String,
    event_store: Arc<EventStore>,
    broadcast: Arc<EventEmitter>,
    subagent_manager: Option<Arc<SubagentManager>>,
    working_directory: String,
    model: String,
    transcript: String,
    start_ts: String,
    end_ts: String,
    source: RetainSource,
) {
    let outcome = match subagent_manager {
        Some(manager) => run_summarizer(manager, &session_id, &working_directory, transcript).await,
        None => {
            warn!(session_id = %session_id, "no subagent manager for memory retain, using keyword recovery");
            SummarizerOutcome::Err {
                recovery: keyword_summary(&session_id),
                reason: "no subagent manager configured".to_string(),
            }
        }
    };

    let (raw_output, summarizer_failure) = match outcome {
        SummarizerOutcome::Ok(text) => (text, None),
        SummarizerOutcome::Err { recovery, reason } => (recovery, Some(reason)),
    };

    if let (RetainSource::Auto { interval_fired }, Some(reason)) =
        (source, summarizer_failure.as_ref())
    {
        emit_auto_retain_failed(
            &event_store,
            &broadcast,
            &session_id,
            interval_fired,
            reason,
        )
        .await;
    }

    let parsed = parse_retain_output(&raw_output);
    let journal_text = parsed.journal.as_deref().unwrap_or(&raw_output);
    let (title, body) = split_title_and_body(journal_text);
    let created_ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    if let Err(e) = write_session_entry(
        &session_id,
        &created_ts,
        &model,
        &start_ts,
        &end_ts,
        &title,
        &body,
    ) {
        warn!(session_id = %session_id, error = %e, "failed to write session journal file");
    }

    let mut entry_type_parts = vec!["journal"];

    if let Some(ref cm) = parsed.core_memory {
        let path = core_memory_file_path(&cm.file);
        if let Err(e) = write_core_memory_update(&path, &cm.update) {
            warn!(session_id = %session_id, error = %e, "failed to write core memory update");
        } else {
            debug!(session_id = %session_id, file = %cm.file, "updated core memory");
            entry_type_parts.push("memory");
        }
    }

    if let Some(ref arg) = parsed.argument {
        let slug = slugify(&arg.title);
        let path = argument_file_path(&slug);
        if let Err(e) = write_argument_entry(&path, arg) {
            warn!(session_id = %session_id, error = %e, "failed to write argument");
        } else {
            debug!(session_id = %session_id, slug = %slug, "created argument");
            entry_type_parts.push("argument");
        }
    }

    let entry_type = entry_type_parts.join("+");

    let retained_event_id = event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MemoryRetained,
            payload: json!({
                "sessionId": session_id,
                "title": title,
                "summary": body,
                "timestamp": created_ts,
                "rangeStart": start_ts,
                "rangeEnd": end_ts,
                "entryType": entry_type,
            }),
            parent_id: None,
            sequence: None,
        })
        .map(|row| row.id)
        .unwrap_or_default();

    let _ = broadcast.emit(crate::shared::events::TronEvent::MemoryUpdated {
        base: crate::shared::events::BaseEvent::now(&session_id),
        title: Some(title),
        summary: Some(body),
        entry_type: Some(entry_type),
        event_id: if retained_event_id.is_empty() {
            None
        } else {
            Some(retained_event_id)
        },
    });
}
