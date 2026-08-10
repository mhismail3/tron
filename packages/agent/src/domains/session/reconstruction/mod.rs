//! Session reconstruction service — single tool call returns complete session state.
//!
//! Replaces ad hoc client-side reconstruction from separate session/event
//! calls. The server is the single source of truth: persisted history
//! events + in-flight state are returned in one response. Non-forked sessions
//! use session-local sequence order; forked sessions use the ordered ancestor
//! chain, not just events physically owned by the child session, so clients
//! render inherited history at the fork point. Durable rows and events are read
//! from `EventStore` directly; the agent cache contributes no query truth.
//! The active-turn projection is snapshotted before the durable read at the
//! sequence synchronously observed by the event emitter. Initial durable rows
//! are capped to that exact cut before limiting; a run/turn transition retries
//! the read. Raw allocator state and ancestor-session sequences never advance
//! the client deduplication cursor.
//!
//! ## In-flight reconciliation
//!
//! When tools are executing, `message.assistant` has already been persisted (containing
//! thinking, text, and tool_invocation blocks), but the turn accumulator still holds the same
//! content. [`reconcile_in_flight`] strips text/thinking from in-flight state when tools
//! are past "generating" status, preventing duplicate content on iOS reconstruction.
//! Before tool execution starts, `streaming.type` is derived from the last
//! active content-sequence item, so reconnects distinguish active thinking from
//! active assistant text. Reconstruction snapshots the turn accumulator directly
//! only while the run registry reports an active run. Prompt admission remains
//! pending until its durable `message.user` row joins this same cut; reconnects
//! wait for that commit (or run release) rather than returning a snapshot that
//! can never receive the missing row. An active run without turn content returns
//! `inFlight: null`; `isRunning`, `runId`, and `agentPhase` share the atomic
//! active-run snapshot and transition to idle only at terminal run release.
//!
//! ## Response shape
//!
//! ```text
//! {
//!   events: [...],           // persisted events in server-authored chain order
//!   hasMoreEvents: bool,     // true if older events exist (pagination)
//!   oldestEventId: string?,  // event-id cursor for cross-session pagination
//!   inFlight: {...}?,        // non-null only when agent is running
//!   lastSequence: i64,       // highest sequence represented by this snapshot
//!   isRunning: bool,
//!   runId: string?,          // active run id, null when idle
//!   metadata: {...},         // chat/session metadata only
//! }
//! ```
//!
//! `model.provider_request` rows remain in the event chain so parent links and
//! pagination cursors stay exact, but their audit bodies are replaced with a
//! tiny deferred marker in `events`. Provider-context inventory and full
//! manifests are separate, lazy reads through `session::context_requests` and
//! `session::context_request_detail`; they never delay chat reconstruction.
//!
//! `operations` exposes the authenticated function adapter; this module owns
//! loading, generation validation, pagination, and projection through the
//! single [`SessionReconstructionService`] entry. Concern-focused scenarios
//! live in `tests`. Reconstruction never writes session state or consults a
//! shadow client cache.

use std::sync::Arc;

use serde_json::{Value, json};
use tracing::{debug, instrument};

use crate::domains::agent::r#loop::orchestrator::turn_accumulator::TurnReconstructionSnapshot;
use crate::domains::session::Deps;
use crate::domains::session::event_store::{EventRow, EventStore, EventType};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{self, ToolError};
use crate::shared::server::events::event_row_to_wire_with_payload;

/// Hard ceiling on the number of events returned by a single
/// `session.reconstruct` call, regardless of what the client asks for.
///
/// The tool is a single synchronous load into memory followed by a single
/// JSON serialization; letting a client request an unbounded window is a
/// trivial self-DoS. 10k events is roughly 25–50 turns of history for a
/// typical Tron session, which more than covers any UX that needs the full
/// state up front. Clients that want older events paginate via
/// `beforeEventId`.
pub const MAX_RECONSTRUCT_EVENTS: i64 = 10_000;

pub(crate) struct SessionReconstructionService;

mod operations;

pub(crate) use operations::session_reconstruct_value;

fn paginate_ordered_chain(
    mut events: Vec<EventRow>,
    before_event_id: Option<&str>,
    limit: i64,
) -> Result<(Vec<EventRow>, bool), ToolError> {
    if let Some(cursor) = before_event_id {
        let cursor_index = events
            .iter()
            .position(|event| event.id == cursor)
            .ok_or_else(|| ToolError::NotFound {
                code: errors::EVENT_NOT_FOUND.into(),
                message: format!("Event '{cursor}' not found in reconstruction chain"),
            })?;
        events.truncate(cursor_index);
    }

    let limit = usize::try_from(limit).unwrap_or(0);
    if limit == 0 {
        return Ok((Vec::new(), !events.is_empty()));
    }

    let has_more = events.len() > limit;
    if has_more {
        let keep_from = events.len() - limit;
        events = events.split_off(keep_from);
    }

    Ok((events, has_more))
}

type ActiveSnapshot = Option<(String, Option<TurnReconstructionSnapshot>)>;

fn same_reconstruction_generation(before: &ActiveSnapshot, after: &ActiveSnapshot) -> bool {
    match (before, after) {
        (None, None) => true,
        (Some((before_run, before_snapshot)), Some((after_run, after_snapshot)))
            if before_run == after_run =>
        {
            match (before_snapshot, after_snapshot) {
                (Some(before), Some(after)) => {
                    before.generation == after.generation
                        && before.sequence_consistent == after.sequence_consistent
                }
                (None, None) => true,
                _ => false,
            }
        }
        _ => false,
    }
}

fn reconstruction_wire_events(
    event_store: &EventStore,
    events: &[EventRow],
) -> Result<(Vec<Value>, usize), ToolError> {
    let ordinary_events = events
        .iter()
        .filter(|event| event.event_type != EventType::ModelProviderRequest.as_str())
        .cloned()
        .collect::<Vec<_>>();
    let resolved_payloads = event_store
        .resolve_event_payloads(&ordinary_events)
        .map_err(|error| ToolError::Internal {
            message: format!("Failed to resolve event payloads: {error}"),
        })?;
    let mut resolved_payloads = resolved_payloads.into_iter();
    let mut deferred_provider_audits = 0;
    let wire_events = events
        .iter()
        .map(|event| {
            let payload = if event.event_type == EventType::ModelProviderRequest.as_str() {
                deferred_provider_audits += 1;
                json!({
                    "projection": "deferred",
                    "turn": event.turn,
                    "model": event.model,
                    "providerType": event.provider_type,
                })
            } else {
                resolved_payloads
                    .next()
                    .expect("ordinary event payload count matches event rows")
            };
            event_row_to_wire_with_payload(event, Some(payload))
        })
        .collect();
    debug_assert!(resolved_payloads.next().is_none());
    Ok((wire_events, deferred_provider_audits))
}

async fn load_durable_reconstruction(
    event_store: Arc<EventStore>,
    session_id: String,
    cursor_event_id: Option<String>,
    effective_limit: i64,
    top_level_sequence_cut: Option<i64>,
) -> Result<(Vec<EventRow>, bool, Value), ToolError> {
    run_blocking_task("session.reconstruct.load", move || {
        let session = event_store
            .get_session(&session_id)
            .map_err(|e| ToolError::Internal {
                message: format!("Persistence error: {e}"),
            })?
            .ok_or_else(|| ToolError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let limit = Some(effective_limit);
        let (events, has_more) = if session.parent_session_id.is_some() {
            let head_id = session
                .head_event_id
                .as_deref()
                .ok_or_else(|| ToolError::Internal {
                    message: "Forked session has no head event".into(),
                })?;
            let mut ancestors =
                event_store
                    .get_ancestors(head_id)
                    .map_err(|e| ToolError::Internal {
                        message: format!("Failed to load fork ancestors: {e}"),
                    })?;
            if cursor_event_id.is_none()
                && let Some(cut) = top_level_sequence_cut
            {
                ancestors.retain(|event| event.session_id != session_id || event.sequence <= cut);
            }
            paginate_ordered_chain(ancestors, cursor_event_id.as_deref(), effective_limit)?
        } else if let Some(before_id) = cursor_event_id.as_deref() {
            let cursor = event_store
                .get_event(before_id)
                .map_err(|e| ToolError::Internal {
                    message: format!("Failed to load cursor event: {e}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::EVENT_NOT_FOUND.into(),
                    message: format!("Event '{before_id}' not found"),
                })?;
            if cursor.session_id != session_id {
                return Err(ToolError::NotFound {
                    code: errors::EVENT_NOT_FOUND.into(),
                    message: format!("Event '{before_id}' is not in session '{session_id}'"),
                });
            }
            let events = event_store
                .get_events_before(&session_id, cursor.sequence, limit)
                .map_err(|e| ToolError::Internal {
                    message: format!("Failed to load events: {e}"),
                })?;
            let has_more = events.first().is_some_and(|first| {
                event_store
                    .has_events_before(&session_id, first.sequence)
                    .unwrap_or(false)
            });
            (events, has_more)
        } else {
            let events = if let Some(cut) = top_level_sequence_cut {
                if let Some(before) = cut.checked_add(1) {
                    event_store
                        .get_events_before(&session_id, before, limit)
                        .map_err(|e| ToolError::Internal {
                            message: format!(
                                "Failed to load events through reconstruction cut: {e}"
                            ),
                        })?
                } else {
                    event_store
                        .get_latest_events(&session_id, limit)
                        .map_err(|e| ToolError::Internal {
                            message: format!("Failed to load events: {e}"),
                        })?
                }
            } else {
                event_store
                    .get_latest_events(&session_id, limit)
                    .map_err(|e| ToolError::Internal {
                        message: format!("Failed to load events: {e}"),
                    })?
            };
            let has_more = events.first().is_some_and(|first| {
                event_store
                    .has_events_before(&session_id, first.sequence)
                    .unwrap_or(false)
            });
            (events, has_more)
        };

        let metadata = json!({
            "model": session.latest_model,
            "turnCount": session.turn_count,
            "workingDirectory": session.working_directory,
            "title": session.title,
            "tokenUsage": {
                "input": session.total_input_tokens,
                "output": session.total_output_tokens,
                "cacheRead": session.total_cache_read_tokens,
                "cacheCreation": session.total_cache_creation_tokens,
            },
            "totalCost": session.total_cost,
        });

        Ok((events, has_more, metadata))
    })
    .await
}

impl SessionReconstructionService {
    /// Reconstruct the full session state for a reconnecting client.
    #[instrument(skip(deps), fields(session_id = %session_id))]
    pub(crate) async fn reconstruct(
        deps: &Deps,
        session_id: String,
        limit: Option<i64>,
        before_event_id: Option<String>,
    ) -> Result<Value, ToolError> {
        // INVARIANT: client-supplied `limit` is always clamped to
        // [0, MAX_RECONSTRUCT_EVENTS]. `None` means "give me the default
        // window" — the default IS the cap, not "unbounded". A negative
        // value is coerced to 0 (returns empty).
        let effective_limit: i64 = limit
            .unwrap_or(MAX_RECONSTRUCT_EVENTS)
            .clamp(0, MAX_RECONSTRUCT_EVENTS);
        let is_top_level = before_event_id.is_none();

        // Initial reconstruction is a linearizable cut. The emitter updates
        // state and its source sequence synchronously before broadcast; the DB
        // read is then bounded to that exact sequence before applying `limit`.
        // Later events are already buffered by iOS and replay above the cut.
        // Turn/run transitions retry, while same-turn deltas do not invalidate
        // the earlier coherent snapshot.
        let (events, has_more, session_metadata, captured_snapshot, run_id) = if is_top_level {
            loop {
                let captured = deps
                    .orchestrator
                    .active_reconstruction_snapshot(&session_id);
                if let Some((run_id, Some(snapshot))) = captured.as_ref()
                    && !snapshot.admission_committed
                {
                    if let Some(mut admission) = deps
                        .orchestrator
                        .run_admission_receiver(&session_id, run_id)
                    {
                        let committed = *admission.borrow_and_update();
                        if !committed {
                            let _ = admission.changed().await;
                        }
                    }
                    continue;
                }
                let sequence_cut = captured
                    .as_ref()
                    .and_then(|(_, snapshot)| snapshot.as_ref())
                    .and_then(|snapshot| snapshot.last_sequence);
                let loaded = load_durable_reconstruction(
                    deps.event_store.clone(),
                    session_id.clone(),
                    None,
                    effective_limit,
                    sequence_cut,
                )
                .await?;
                let after = deps
                    .orchestrator
                    .active_reconstruction_snapshot(&session_id);
                if same_reconstruction_generation(&captured, &after) {
                    let run_id = after.as_ref().map(|(run_id, _)| run_id.clone());
                    break (loaded.0, loaded.1, loaded.2, captured, run_id);
                }
                debug!(
                    session_id,
                    "run or turn changed during reconstruction; retrying coherent cut"
                );
            }
        } else {
            let loaded = load_durable_reconstruction(
                deps.event_store.clone(),
                session_id.clone(),
                before_event_id.clone(),
                effective_limit,
                None,
            )
            .await?;
            let active = deps
                .orchestrator
                .active_reconstruction_snapshot(&session_id);
            let run_id = active.as_ref().map(|(run_id, _)| run_id.clone());
            (loaded.0, loaded.1, loaded.2, active, run_id)
        };

        let snapshot = captured_snapshot
            .as_ref()
            .and_then(|(_, snapshot)| snapshot.as_ref());
        let represented_sequence = is_top_level
            .then(|| snapshot.and_then(|snapshot| snapshot.last_sequence))
            .flatten();
        let is_running = run_id.is_some();
        let compaction_reason = snapshot.and_then(|snapshot| snapshot.compaction_reason.clone());
        let is_compacting = compaction_reason.is_some();
        let in_flight = is_running
            .then_some(represented_sequence)
            .flatten()
            .and_then(|_| {
                snapshot
                    .and_then(|snapshot| snapshot.state.clone())
                    .map(Self::reconcile_turn_snapshot)
            });
        if let Some(state) = in_flight.as_ref() {
            debug!(
                session_id,
                tool_count = state
                    .get("toolInvocations")
                    .and_then(|value| value.as_array())
                    .map_or(0, Vec::len),
                seq_count = state
                    .get("contentSequence")
                    .and_then(|value| value.as_array())
                    .map_or(0, Vec::len),
                has_streaming = state.get("streaming").is_some_and(|v| !v.is_null()),
                represented_sequence,
                "in-flight state built from coherent reconstruction cut"
            );
        }

        // Parent and child sequences are independent. Only the target-session
        // component can seed its live dedup watermark; older pages never
        // replace the top-level watermark on iOS.
        let durable_sequence = events
            .iter()
            .rev()
            .find(|event| event.session_id == session_id)
            .map(|event| event.sequence)
            .unwrap_or(0);
        let last_sequence = represented_sequence.unwrap_or(durable_sequence);
        let oldest_event_id = events.first().map(|e| e.id.clone());

        // 4. Convert events to the client reconstruction projection. Exact
        // provider-request manifests are audit data, not transcript data.
        let (wire_events, deferred_provider_audits) =
            reconstruction_wire_events(&deps.event_store, &events)?;

        debug!(
            session_id,
            event_count = wire_events.len(),
            deferred_provider_audits,
            has_more,
            is_running,
            last_sequence,
            "session reconstruction complete"
        );

        Ok(json!({
            "events": wire_events,
            "hasMoreEvents": has_more,
            "oldestEventId": oldest_event_id,
            "inFlight": in_flight,
            "lastSequence": last_sequence,
            "isRunning": is_running,
            "isCompacting": is_compacting,
            "compactionReason": compaction_reason,
            "runId": run_id,
            // Reconnect state is intentionally two-valued: active turn work is
            // "processing"; every terminal or between-turn window is "idle".
            "agentPhase": if is_running { "processing" } else { "idle" },
            "metadata": session_metadata,
        }))
    }

    fn reconcile_turn_snapshot(snapshot: (String, Value, Value, bool)) -> Value {
        let (text, tool_invocations, content_sequence, response_complete) = snapshot;
        let mut state = Self::reconcile_in_flight(text, tool_invocations, content_sequence);
        if response_complete {
            let tool_refs = state["contentSequence"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|item| item["type"] == "tool_ref")
                .cloned()
                .collect();
            state["contentSequence"] = Value::Array(tool_refs);
            state["streaming"] = Value::Null;
        }
        state
    }

    /// Reconcile in-flight accumulator state against persisted events.
    ///
    /// When any tool has progressed past "generating" status, tool invocation has
    /// started, which means `message.assistant` was persisted (tools only execute
    /// after persist). In that case, text and thinking in the accumulator duplicate
    /// the persisted event — strip them from the response to prevent iOS duplication.
    ///
    /// Tool invocations and tool_ref items are always preserved since they carry live
    /// status (running/completed, streamingOutput, startedAt) not in persisted events.
    fn reconcile_in_flight(
        text: String,
        tool_invocations: Value,
        content_sequence: Value,
    ) -> Value {
        // Detect if message.assistant has been persisted for this turn.
        // Any tool past "generating" means tool invocation started → message.assistant persisted.
        let tools_executing = tool_invocations
            .as_array()
            .map(|calls| {
                calls.iter().any(|tc| {
                    tc.get("status")
                        .and_then(|s| s.as_str())
                        .is_some_and(|s| s != "generating")
                })
            })
            .unwrap_or(false);

        if tools_executing {
            // Strip text/thinking from content sequence — already in persisted message.assistant.
            // Keep only tool_ref items (they carry live status not in persisted events).
            let filtered: Vec<Value> = content_sequence
                .as_array()
                .unwrap_or(&vec![])
                .iter()
                .filter(|item| item.get("type").and_then(|t| t.as_str()) == Some("tool_ref"))
                .cloned()
                .collect();

            json!({
                "toolInvocations": tool_invocations,
                "contentSequence": filtered,
                "streaming": null,
            })
        } else {
            // LLM still streaming — keep everything (no persisted message.assistant yet).
            let streaming = Self::streaming_from_sequence(&content_sequence, &text);

            json!({
                "toolInvocations": tool_invocations,
                "contentSequence": content_sequence,
                "streaming": streaming,
            })
        }
    }

    fn streaming_from_sequence(content_sequence: &Value, text: &str) -> Option<Value> {
        let last = content_sequence.as_array()?.last()?;
        match last.get("type").and_then(Value::as_str) {
            Some("thinking") => last
                .get("thinking")
                .and_then(Value::as_str)
                .filter(|thinking| !thinking.is_empty())
                .map(|thinking| json!({ "type": "thinking", "content": thinking })),
            Some("text") => last
                .get("text")
                .and_then(Value::as_str)
                .filter(|current_text| !current_text.is_empty())
                .map(|current_text| json!({ "type": "text", "content": current_text })),
            _ if !text.is_empty() => Some(json!({ "type": "text", "content": text })),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests;
