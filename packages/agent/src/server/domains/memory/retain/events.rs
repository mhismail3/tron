//! Retain lifecycle event persistence and publication.

use chrono::Utc;
use serde_json::json;
use std::sync::Arc;
use tracing::warn;

use crate::events::types::EventType;
use crate::events::{AppendOptions, EventStore};
use crate::runtime::agent::event_emitter::EventEmitter;
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::errors::CapabilityError;

use super::RetainDeps;

/// Persist and broadcast `memory.auto_retain_failed`. Paired with a prior
/// `MemoryAutoRetainTriggered` to signal that the auto-retain pipeline for
/// this session did not complete successfully.
pub(super) async fn emit_auto_retain_failed(
    event_store: &Arc<EventStore>,
    broadcast: &Arc<EventEmitter>,
    session_id: &str,
    interval_fired: u32,
    reason: &str,
) {
    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let event_store_p = event_store.clone();
    let session_id_p = session_id.to_owned();
    let reason_p = reason.to_owned();
    let timestamp_p = timestamp.clone();
    let _ = run_blocking_task("memory.auto_retain_failed.persist", move || {
        if let Err(e) = event_store_p.append(&AppendOptions {
            session_id: &session_id_p,
            event_type: EventType::MemoryAutoRetainFailed,
            payload: json!({
                "sessionId": session_id_p,
                "intervalFired": interval_fired,
                "reason": reason_p,
                "timestamp": timestamp_p,
            }),
            parent_id: None,
            sequence: None,
        }) {
            warn!(
                session_id = %session_id_p,
                error = %e,
                "failed to persist memory.auto_retain_failed event"
            );
        }
        Ok::<(), CapabilityError>(())
    })
    .await;

    let _ = broadcast.emit(crate::core::events::TronEvent::MemoryAutoRetainFailed {
        base: crate::core::events::BaseEvent::now(session_id),
        interval_fired,
        reason: reason.to_owned(),
    });
}

/// Persist and broadcast `memory.auto_retain_triggered` so clients can
/// distinguish automatic retentions from manual ones in the transcript and
/// history.
pub(super) async fn emit_auto_retain_triggered(
    deps: &RetainDeps,
    session_id: &str,
    interval_fired: u32,
) {
    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let event_store_p = deps.event_store.clone();
    let session_id_p = session_id.to_owned();
    let timestamp_p = timestamp.clone();
    let _ = run_blocking_task("memory.auto_retain_triggered.persist", move || {
        if let Err(e) = event_store_p.append(&AppendOptions {
            session_id: &session_id_p,
            event_type: EventType::MemoryAutoRetainTriggered,
            payload: json!({
                "sessionId": session_id_p,
                "intervalFired": interval_fired,
                "timestamp": timestamp_p,
            }),
            parent_id: None,
            sequence: None,
        }) {
            warn!(
                session_id = %session_id_p,
                error = %e,
                "failed to persist memory.auto_retain_triggered event"
            );
        }
        Ok::<(), CapabilityError>(())
    })
    .await;

    let _ = deps.orchestrator.broadcast().emit(
        crate::core::events::TronEvent::MemoryAutoRetainTriggered {
            base: crate::core::events::BaseEvent::now(session_id),
            interval_fired,
        },
    );
}
