//! Memory retain runtime: manual + auto.
//!
//! The retain system connects ephemeral conversations to persistent memory.
//! It runs as an async background task and acts as a smart
//! router:
//!
//! - **Always** writes a journal entry to `~/.tron/memory/sessions/`
//! - **Conditionally** updates core memories in `~/.tron/memory/rules/`
//! - **Conditionally** creates argument docs in `~/.tron/workspace/knowledge/arguments/`
//!
//! The summarizer uses Sonnet 4.6 and produces structured output with `<journal>`,
//! `<core_memory>`, and `<argument>` sections that the retain runtime routes
//! to the right files. The `memory.retainModel` setting is plumbed through iOS
//! for future configurability.
//!
//! ## Entry points
//!
//! - `memory::retain` engine function — manual retain arrives through
//!   `/engine` `invoke`, acquires a session resource lease, builds a
//!   narrow memory deps into [`RetainDeps`], and calls [`trigger_retain`] with
//!   [`RetainSource::Manual`].
//! - `memory::auto_retain_fire` hidden engine function — invoked after a
//!   successful agent run. It evaluates the auto-retain policy against the
//!   session's turn history and fires [`trigger_retain`] with
//!   [`RetainSource::Auto`] when the `memory.autoRetainInterval` threshold is
//!   crossed. See the [`auto_retain`] submodule for the policy details.
//!
//! ## Local layout
//!
//! `trigger_retain` owns only lifecycle orchestration. The retained work is
//! split beside it: `slice` reads the event-store window, `transcript`
//! serializes messages for the summarizer, `background` runs the async retain
//! task, `summarizer` owns subagent execution, `parsing` decodes structured
//! summarizer output, `writer` owns filesystem writes, and `events` owns the
//! retain lifecycle event records.
//!
//! ## Concurrency
//!
//! The entire pipeline holds a session-keyed [`RetainGuard`] (owned by
//! [`Orchestrator::try_begin_retain`]) for the full summarizer duration. A
//! concurrent retain (double-click, or manual-while-auto-in-flight) returns
//! `{ retained: false, reason: "in_flight" }` immediately with no side effects.
//!
//! [`RetainGuard`]: crate::domains::agent::runner::orchestrator::orchestrator::RetainGuard
//! [`Orchestrator::try_begin_retain`]: crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator::try_begin_retain

use serde_json::{Value, json};
use tracing::debug;

use crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager;
use crate::domains::memory::Deps as MemoryDeps;
use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::map_event_store_error;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;

use std::sync::Arc;

pub(crate) mod auto_retain;
mod background;
mod events;
mod parsing;
mod slice;
mod summarizer;
mod transcript;
mod writer;

use background::retain_background_task;
use events::emit_auto_retain_triggered;
use slice::{find_boundary_sequence, get_retain_slice};
use transcript::serialize_for_memory;

// =============================================================================
// Retain source discriminator + dependencies
// =============================================================================

/// Whether a retain was initiated by the user or by the auto-retain policy.
///
/// Controls whether a `MemoryAutoRetainTriggered` event is emitted at the
/// start of the pipeline. The summarizer behaviour itself is identical.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RetainSource {
    /// User invoked the manual memory retain capability.
    Manual,
    /// Auto-retain policy crossed its threshold at end of an agent run.
    Auto {
        /// The interval value that caused the fire (from settings).
        interval_fired: u32,
    },
}

/// The narrow set of dependencies the retain pipeline needs.
///
/// Exists so the pipeline can be driven from engine functions without requiring
/// the full server context. Manual retain and hidden auto-retain both construct
/// it via [`RetainDeps::from_memory_deps`].
#[derive(Clone)]
pub(crate) struct RetainDeps {
    pub orchestrator: Arc<crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator>,
    pub event_store: Arc<EventStore>,
    pub subagent_manager: Option<Arc<SubagentManager>>,
}

impl RetainDeps {
    pub(crate) fn from_memory_deps(deps: &MemoryDeps) -> Self {
        Self {
            orchestrator: Arc::clone(&deps.orchestrator),
            event_store: Arc::clone(&deps.event_store),
            subagent_manager: deps.subagent_manager.clone(),
        }
    }

    #[cfg(test)]
    fn from_test_context(ctx: &crate::shared::server::context::ServerRuntimeContext) -> Self {
        Self {
            orchestrator: Arc::clone(&ctx.orchestrator),
            event_store: Arc::clone(&ctx.event_store),
            subagent_manager: ctx.subagent_manager.clone(),
        }
    }
}

// =============================================================================
// Manual entry point
// =============================================================================

/// Trigger a memory retain: summarize session history since the last boundary
/// and write to `~/.tron/memory/sessions/{session_id}.md`.
///
/// This operation is non-blocking — it emits `MemoryUpdating` immediately,
/// spawns the summarizer as a background task, and returns. The background
/// task emits `MemoryUpdated` when done.
pub(crate) async fn trigger_manual_retain(
    params: Option<&Value>,
    memory_deps: &MemoryDeps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let deps = RetainDeps::from_memory_deps(memory_deps);
    trigger_retain(&deps, session_id, RetainSource::Manual).await
}

// =============================================================================
// Core logic
// =============================================================================

/// Entry point for both manual (`trigger_manual_retain`) and automatic
/// (`auto_retain::maybe_fire`) retentions. Async-spawns the summarizer and
/// returns immediately with `{ retained, status }`.
///
/// Concurrency: holds a session-level `RetainGuard` for the entire duration of
/// the background summarizer. A second concurrent retain (manual double-click,
/// or manual-while-auto-in-flight) returns `{ retained: false, reason: "in_flight" }`
/// immediately with no side effects.
pub(crate) async fn trigger_retain(
    deps: &RetainDeps,
    session_id: String,
    source: RetainSource,
) -> Result<Value, CapabilityError> {
    // Acquire the retain slot. If another retain is already running for this
    // session, return the sentinel response and emit nothing — no events, no
    // writes, no LLM calls.
    let guard = match deps.orchestrator.try_begin_retain(&session_id) {
        Some(g) => g,
        None => {
            debug!(session_id = %session_id, "retain already in-flight; skipping");
            return Ok(json!({ "retained": false, "reason": "in_flight" }));
        }
    };

    // For auto-retain: emit (and persist) the distinct trigger event first so
    // iOS can render "auto-retain starting" before the generic spinner.
    if let RetainSource::Auto { interval_fired } = source {
        emit_auto_retain_triggered(deps, &session_id, interval_fired).await;
    }

    // Emit MemoryUpdating so the iOS spinner appears immediately.
    let _ = deps
        .orchestrator
        .broadcast()
        .emit(crate::shared::events::TronEvent::MemoryUpdating {
            base: crate::shared::events::BaseEvent::now(&session_id),
        });

    // ── Find summarization boundary ────────────────────────────────────────
    let event_store = deps.event_store.clone();
    let session_id_q = session_id.clone();
    let boundary_sequence = run_blocking_task("memory.retain.find_boundary", move || {
        find_boundary_sequence(&event_store, &session_id_q)
    })
    .await?;

    // ── Get events since boundary ─────────────────────────────────────────
    let event_store2 = deps.event_store.clone();
    let session_id_q2 = session_id.clone();
    let slice = run_blocking_task("memory.retain.get_events", move || {
        get_retain_slice(&event_store2, &session_id_q2, boundary_sequence)
    })
    .await?;

    let Some(slice) = slice else {
        // Nothing new to summarize.
        let _ =
            deps.orchestrator
                .broadcast()
                .emit(crate::shared::events::TronEvent::MemoryUpdated {
                    base: crate::shared::events::BaseEvent::now(&session_id),
                    title: None,
                    summary: None,
                    entry_type: Some("journal".to_owned()),
                    event_id: None,
                });
        return Ok(json!({ "retained": false, "reason": "nothing_new" }));
    };

    // ── Get session metadata ───────────────────────────────────────────────
    let event_store3 = deps.event_store.clone();
    let session_id_q3 = session_id.clone();
    let session_meta = run_blocking_task("memory.retain.get_session", move || {
        event_store3
            .get_session(&session_id_q3)
            .map_err(map_event_store_error)
    })
    .await?;

    let working_directory = session_meta
        .as_ref()
        .map(|s| s.working_directory.clone())
        .unwrap_or_else(|| "/tmp".to_owned());

    let model = session_meta
        .as_ref()
        .map(|s| s.latest_model.as_str())
        .unwrap_or("claude-sonnet-4-6")
        .to_owned();

    // ── Serialize transcript ───────────────────────────────────────────────
    let transcript = serialize_for_memory(&slice.messages);

    if transcript.is_empty() {
        let _ =
            deps.orchestrator
                .broadcast()
                .emit(crate::shared::events::TronEvent::MemoryUpdated {
                    base: crate::shared::events::BaseEvent::now(&session_id),
                    title: None,
                    summary: None,
                    entry_type: Some("journal".to_owned()),
                    event_id: None,
                });
        return Ok(json!({ "retained": false, "reason": "empty_transcript" }));
    }

    // ── Spawn background retain task ────────────────────────────────────────
    // The handler returns immediately. The background task runs the summarizer,
    // parses the output, writes files, and emits MemoryUpdated when done.
    //
    // The RetainGuard moves into the spawn so the in-flight slot is held for
    // the full summarizer duration, then released on drop — whether the task
    // completes, errors, or panics.
    let bg_session_id = session_id.clone();
    let bg_event_store = deps.event_store.clone();
    let bg_broadcast = Arc::clone(deps.orchestrator.broadcast());
    let bg_subagent_manager = deps.subagent_manager.clone();
    let bg_start_ts = slice.start_ts;
    let bg_end_ts = slice.end_ts;

    let bg_source = source;
    drop(tokio::spawn(async move {
        retain_background_task(
            bg_session_id,
            bg_event_store,
            bg_broadcast,
            bg_subagent_manager,
            working_directory,
            model,
            transcript,
            bg_start_ts,
            bg_end_ts,
            bg_source,
        )
        .await;
        drop(guard);
    }));

    Ok(json!({
        "retained": true,
        "status": "retaining",
    }))
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests;
