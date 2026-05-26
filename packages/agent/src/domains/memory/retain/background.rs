//! Background retain task orchestration.

use std::sync::Arc;

use chrono::Utc;
use serde_json::json;
use tracing::{debug, warn};

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::session::event_store::AppendOptions;
use crate::domains::session::event_store::types::EventType;
use crate::engine::Invocation;

use super::RetainDeps;
use super::RetainSource;
use super::events::emit_auto_retain_failed;
use super::parsing::{parse_retain_output, slugify};
use super::resources::{RetainedMemoryPayload, persist_retained_memory_outputs};
use super::summarizer::{SummarizerOutcome, keyword_summary, run_summarizer};
use super::writer::split_title_and_body;

/// Background task that runs the summarizer and persists retained outputs.
#[allow(clippy::too_many_arguments)]
pub(super) async fn retain_background_task(
    deps: RetainDeps,
    parent_invocation: Option<Invocation>,
    session_id: String,
    broadcast: Arc<EventEmitter>,
    working_directory: String,
    model: String,
    transcript: String,
    start_ts: String,
    end_ts: String,
    source: RetainSource,
) {
    let outcome = match deps.subagent_manager.clone() {
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
            &deps.event_store,
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

    let mut entry_type_parts = vec!["journal"];
    if let Some(ref cm) = parsed.core_memory {
        debug!(session_id = %session_id, file = %cm.file, "parsed core memory update");
        entry_type_parts.push("memory");
    }
    if let Some(ref arg) = parsed.argument {
        let slug = slugify(&arg.title);
        debug!(session_id = %session_id, slug = %slug, "parsed argument memory");
        entry_type_parts.push("argument");
    }

    let entry_type = entry_type_parts.join("+");
    let source_label = match source {
        RetainSource::Manual => "manual",
        RetainSource::Auto { .. } => "auto",
    };
    let retained_outputs = match persist_retained_memory_outputs(
        &deps,
        parent_invocation.as_ref(),
        RetainedMemoryPayload {
            session_id: &session_id,
            created_ts: &created_ts,
            model: &model,
            start_ts: &start_ts,
            end_ts: &end_ts,
            title: &title,
            body: &body,
            source: source_label,
            summarizer_failure: summarizer_failure.as_deref(),
            core_memory: parsed.core_memory.as_ref(),
            argument: parsed.argument.as_ref(),
        },
    )
    .await
    {
        Ok(outputs) => outputs,
        Err(error) => {
            warn!(session_id = %session_id, error = %error, "failed to persist resource-backed memory retain output");
            if let RetainSource::Auto { interval_fired } = source {
                emit_auto_retain_failed(
                    &deps.event_store,
                    &broadcast,
                    &session_id,
                    interval_fired,
                    &error.to_string(),
                )
                .await;
            }
            let _ = broadcast.emit(crate::shared::events::TronEvent::MemoryUpdated {
                base: crate::shared::events::BaseEvent::now(&session_id),
                title: None,
                summary: Some(
                    "Memory retain failed before resource-backed persistence completed".to_owned(),
                ),
                entry_type: Some("failed".to_owned()),
                event_id: None,
                resource_refs: Some(Vec::new()),
            });
            return;
        }
    };
    let resource_refs = retained_outputs.resource_refs;
    let evidence_refs = retained_outputs.evidence_refs;

    let retained_event_id = deps
        .event_store
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
                "resourceRefs": &resource_refs,
                "evidenceRefs": &evidence_refs,
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
        resource_refs: Some(resource_refs),
    });
}
