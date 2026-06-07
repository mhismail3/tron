//! Session reconstruction service — single capability call returns complete session state.
//!
//! Replaces ad hoc client-side reconstruction from separate session/event
//! calls. The server is the single source of truth: persisted history
//! events + in-flight state are returned in one response. Non-forked sessions
//! use session-local sequence order; forked sessions use the ordered ancestor
//! chain, not just events physically owned by the child session, so clients
//! render inherited history at the fork point.
//!
//! ## In-flight reconciliation
//!
//! When capabilities are executing, `message.assistant` has already been persisted (containing
//! thinking, text, and capability_invocation blocks), but the turn accumulator still holds the same
//! content. [`reconcile_in_flight`] strips text/thinking from in-flight state when capabilities
//! are past "generating" status, preventing duplicate content on iOS reconstruction.
//!
//! ## Response shape
//!
//! ```text
//! {
//!   events: [...],           // persisted events in server-authored chain order
//!   hasMoreEvents: bool,     // true if older events exist (pagination)
//!   oldestEventId: string?,  // event-id cursor for cross-session pagination
//!   inFlight: {...}?,        // non-null only when agent is running
//!   lastSequence: i64,       // highest sequence (includes non-persisted events)
//!   isRunning: bool,
//!   runId: string?,          // active run id, null when idle
//!   metadata: {...},
//! }
//! ```

use serde_json::{Value, json};
use tracing::{debug, instrument};

use crate::domains::session::Deps;
use crate::domains::session::event_store::sqlite::row_types::EventRow;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{self, CapabilityError};
use crate::shared::server::events::event_row_to_wire_with_payload;

/// Hard ceiling on the number of events returned by a single
/// `session.reconstruct` call, regardless of what the client asks for.
///
/// The capability is a single synchronous load into memory followed by a single
/// JSON serialization; letting a client request an unbounded window is a
/// trivial self-DoS. 10k events is roughly 25–50 turns of history for a
/// typical Tron session, which more than covers any UX that needs the full
/// state up front. Clients that want older events paginate via
/// `beforeEventId`.
pub const MAX_RECONSTRUCT_EVENTS: i64 = 10_000;

pub(crate) struct SessionReconstructService;

fn paginate_ordered_chain(
    mut events: Vec<EventRow>,
    before_event_id: Option<&str>,
    limit: i64,
) -> Result<(Vec<EventRow>, bool), CapabilityError> {
    if let Some(cursor) = before_event_id {
        let cursor_index = events
            .iter()
            .position(|event| event.id == cursor)
            .ok_or_else(|| CapabilityError::NotFound {
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

impl SessionReconstructService {
    /// Reconstruct the full session state for a reconnecting client.
    #[instrument(skip(deps), fields(session_id = %session_id))]
    pub(crate) async fn reconstruct(
        deps: &Deps,
        session_id: String,
        limit: Option<i64>,
        before_event_id: Option<String>,
    ) -> Result<Value, CapabilityError> {
        // INVARIANT: client-supplied `limit` is always clamped to
        // [0, MAX_RECONSTRUCT_EVENTS]. `None` means "give me the default
        // window" — the default IS the cap, not "unbounded". A negative
        // value is coerced to 0 (returns empty).
        let effective_limit: i64 = limit
            .unwrap_or(MAX_RECONSTRUCT_EVENTS)
            .clamp(0, MAX_RECONSTRUCT_EVENTS);
        let limit = Some(effective_limit);

        let event_store = deps.event_store.clone();
        let session_manager = deps.session_manager.clone();
        let orchestrator = deps.orchestrator.clone();
        let sid = session_id.clone();
        let cursor_event_id = before_event_id.clone();

        // 1. Load events from DB (blocking — SQLite)
        let (events, has_more, session_metadata) =
            run_blocking_task("session.reconstruct.load", move || {
                // Verify session exists
                let session = session_manager
                    .get_session(&sid)
                    .map_err(|e| CapabilityError::Internal {
                        message: e.to_string(),
                    })?
                    .ok_or_else(|| CapabilityError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: format!("Session '{sid}' not found"),
                    })?;

                // Load events with pagination (limit clamped above). Forked
                // sessions need the ancestor chain ending at the child head:
                // session-local sequence pagination cannot describe parent
                // rows whose sequence counters belong to another session.
                let (events, has_more) = if session.parent_session_id.is_some() {
                    let head_id = session.head_event_id.as_deref().ok_or_else(|| {
                        CapabilityError::Internal {
                            message: "Forked session has no head event".into(),
                        }
                    })?;
                    let ancestors = event_store.get_ancestors(head_id).map_err(|e| {
                        CapabilityError::Internal {
                            message: format!("Failed to load fork ancestors: {e}"),
                        }
                    })?;
                    paginate_ordered_chain(ancestors, cursor_event_id.as_deref(), effective_limit)?
                } else if let Some(before_id) = cursor_event_id.as_deref() {
                    let cursor = event_store
                        .get_event(before_id)
                        .map_err(|e| CapabilityError::Internal {
                            message: format!("Failed to load cursor event: {e}"),
                        })?
                        .ok_or_else(|| CapabilityError::NotFound {
                            code: errors::EVENT_NOT_FOUND.into(),
                            message: format!("Event '{before_id}' not found"),
                        })?;
                    if cursor.session_id != sid {
                        return Err(CapabilityError::NotFound {
                            code: errors::EVENT_NOT_FOUND.into(),
                            message: format!("Event '{before_id}' is not in session '{sid}'"),
                        });
                    }
                    let events = event_store
                        .get_events_before(&sid, cursor.sequence, limit)
                        .map_err(|e| CapabilityError::Internal {
                            message: format!("Failed to load events: {e}"),
                        })?;
                    let has_more = if let Some(first) = events.first() {
                        event_store
                            .has_events_before(&sid, first.sequence)
                            .unwrap_or(false)
                    } else {
                        false
                    };
                    (events, has_more)
                } else {
                    let events = event_store.get_latest_events(&sid, limit).map_err(|e| {
                        CapabilityError::Internal {
                            message: format!("Failed to load events: {e}"),
                        }
                    })?;
                    let has_more = if let Some(first) = events.first() {
                        event_store
                            .has_events_before(&sid, first.sequence)
                            .unwrap_or(false)
                    } else {
                        false
                    };
                    (events, has_more)
                };

                // Build metadata from session row (already has aggregated counters)
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
            .await?;

        // 2. Check agent status + get in-flight state (non-blocking)
        let run_id = orchestrator.get_run_id(&session_id);
        let is_running = run_id.is_some();
        let in_flight = if is_running {
            let state = Self::build_in_flight_state(&orchestrator, &session_id);
            if let Some(ref s) = state {
                debug!(
                    session_id,
                    capability_count = s
                        .get("capabilityInvocations")
                        .and_then(|v| v.as_array())
                        .map(|a| a.len())
                        .unwrap_or(0),
                    seq_count = s
                        .get("contentSequence")
                        .and_then(|v| v.as_array())
                        .map(|a| a.len())
                        .unwrap_or(0),
                    has_streaming = s.get("streaming").map(|v| !v.is_null()).unwrap_or(false),
                    "in-flight state built for running agent"
                );
            }
            state
        } else {
            None
        };

        // 3. Get lastSequence from the session's sequence counter
        // Falls back to the last event's sequence if counter not initialized
        let last_sequence = orchestrator
            .current_sequence(&session_id)
            .unwrap_or_else(|| events.last().map(|e| e.sequence).unwrap_or(0));

        let oldest_event_id = events.first().map(|e| e.id.clone());

        // 4. Convert events to wire format
        let resolved_payloads =
            deps.event_store
                .resolve_event_payloads(&events)
                .map_err(|error| CapabilityError::Internal {
                    message: format!("Failed to resolve event payloads: {error}"),
                })?;
        let wire_events: Vec<Value> = events
            .iter()
            .zip(resolved_payloads)
            .map(|(event, payload)| event_row_to_wire_with_payload(event, Some(payload)))
            .collect();

        debug!(
            session_id,
            event_count = wire_events.len(),
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
            "runId": run_id,
            // Reconnect state is intentionally two-valued: active turn work is
            // "processing"; every terminal or between-turn window is "idle".
            "agentPhase": if is_running { "processing" } else { "idle" },
            "metadata": session_metadata,
        }))
    }

    /// Build the in-flight state from the turn accumulator.
    fn build_in_flight_state(
        orchestrator: &crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator,
        session_id: &str,
    ) -> Option<Value> {
        let (text, capability_invocations, content_sequence) =
            orchestrator.turn_accumulators().get_state(session_id)?;

        Some(Self::reconcile_in_flight(
            text,
            capability_invocations,
            content_sequence,
        ))
    }

    /// Reconcile in-flight accumulator state against persisted events.
    ///
    /// When any capability has progressed past "generating" status, capability invocation has
    /// started, which means `message.assistant` was persisted (capabilities only execute
    /// after persist). In that case, text and thinking in the accumulator duplicate
    /// the persisted event — strip them from the response to prevent iOS duplication.
    ///
    /// Capability invocations and capability_ref items are always preserved since they carry live
    /// status (running/completed, streamingOutput, startedAt) not in persisted events.
    fn reconcile_in_flight(
        text: String,
        capability_invocations: Value,
        content_sequence: Value,
    ) -> Value {
        // Detect if message.assistant has been persisted for this turn.
        // Any capability past "generating" means capability invocation started → message.assistant persisted.
        let capabilities_executing = capability_invocations
            .as_array()
            .map(|calls| {
                calls.iter().any(|tc| {
                    tc.get("status")
                        .and_then(|s| s.as_str())
                        .is_some_and(|s| s != "generating")
                })
            })
            .unwrap_or(false);

        if capabilities_executing {
            // Strip text/thinking from content sequence — already in persisted message.assistant.
            // Keep only capability_ref items (they carry live status not in persisted events).
            let filtered: Vec<Value> = content_sequence
                .as_array()
                .unwrap_or(&vec![])
                .iter()
                .filter(|item| item.get("type").and_then(|t| t.as_str()) == Some("capability_ref"))
                .cloned()
                .collect();

            json!({
                "capabilityInvocations": capability_invocations,
                "contentSequence": filtered,
                "streaming": null,
            })
        } else {
            // LLM still streaming — keep everything (no persisted message.assistant yet).
            let streaming = if !text.is_empty() {
                Some(json!({ "type": "text", "content": text }))
            } else {
                None
            };

            json!({
                "capabilityInvocations": capability_invocations,
                "contentSequence": content_sequence,
                "streaming": streaming,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── reconcile_in_flight tests ──

    #[test]
    fn strips_text_thinking_when_capabilities_executing() {
        let result = SessionReconstructService::reconcile_in_flight(
            "I'll run sleep 10.".into(),
            json!([{
                "invocationId": "tc_1",
                "modelPrimitiveName": "execute",
                "status": "running",
                "startedAt": "2026-04-07T12:00:00Z",
                "streamingOutput": "running...",
            }]),
            json!([
                { "type": "thinking", "thinking": "The user wants sleep 10." },
                { "type": "text", "text": "I'll run sleep 10." },
                { "type": "capability_ref", "invocationId": "tc_1" },
            ]),
        );

        // Text/thinking stripped — already in persisted message.assistant
        let seq = result["contentSequence"].as_array().unwrap();
        assert_eq!(seq.len(), 1);
        assert_eq!(seq[0]["type"], "capability_ref");
        assert_eq!(seq[0]["invocationId"], "tc_1");

        // Streaming cleared
        assert!(result["streaming"].is_null());

        // Capability invocations preserved with full detail
        let capabilities = result["capabilityInvocations"].as_array().unwrap();
        assert_eq!(capabilities.len(), 1);
        assert_eq!(capabilities[0]["status"], "running");
        assert_eq!(capabilities[0]["startedAt"], "2026-04-07T12:00:00Z");
        assert_eq!(capabilities[0]["streamingOutput"], "running...");
    }

    #[test]
    fn keeps_text_thinking_when_still_generating() {
        let result = SessionReconstructService::reconcile_in_flight(
            "Let me think...".into(),
            json!([{
                "invocationId": "tc_1",
                "modelPrimitiveName": "execute",
                "status": "generating",
            }]),
            json!([
                { "type": "thinking", "thinking": "Planning..." },
                { "type": "text", "text": "Let me think..." },
                { "type": "capability_ref", "invocationId": "tc_1" },
            ]),
        );

        // Everything kept — LLM still streaming, no persisted message.assistant yet
        let seq = result["contentSequence"].as_array().unwrap();
        assert_eq!(seq.len(), 3);
        assert_eq!(seq[0]["type"], "thinking");
        assert_eq!(seq[1]["type"], "text");
        assert_eq!(seq[2]["type"], "capability_ref");

        // Streaming active
        assert_eq!(result["streaming"]["type"], "text");
        assert_eq!(result["streaming"]["content"], "Let me think...");
    }

    #[test]
    fn keeps_everything_when_no_capabilities() {
        let result = SessionReconstructService::reconcile_in_flight(
            "Here is my response...".into(),
            json!([]),
            json!([
                { "type": "thinking", "thinking": "I'll explain." },
                { "type": "text", "text": "Here is my response..." },
            ]),
        );

        // Everything kept — text-only response still streaming
        let seq = result["contentSequence"].as_array().unwrap();
        assert_eq!(seq.len(), 2);
        assert_eq!(seq[0]["type"], "thinking");
        assert_eq!(seq[1]["type"], "text");

        // Streaming active
        assert_eq!(result["streaming"]["type"], "text");
    }

    #[test]
    fn strips_when_mixed_capability_statuses() {
        // One capability running, one still generating — strip because at least one is executing
        let result = SessionReconstructService::reconcile_in_flight(
            "Running capabilities...".into(),
            json!([
                { "invocationId": "tc_1", "modelPrimitiveName": "execute", "status": "running" },
                { "invocationId": "tc_2", "modelPrimitiveName": "inspect", "status": "generating" },
            ]),
            json!([
                { "type": "thinking", "thinking": "Let me run both." },
                { "type": "text", "text": "Running capabilities..." },
                { "type": "capability_ref", "invocationId": "tc_1" },
                { "type": "capability_ref", "invocationId": "tc_2" },
            ]),
        );

        let seq = result["contentSequence"].as_array().unwrap();
        assert_eq!(seq.len(), 2); // Only capability_refs
        assert_eq!(seq[0]["invocationId"], "tc_1");
        assert_eq!(seq[1]["invocationId"], "tc_2");
        assert!(result["streaming"].is_null());

        // Both capability invocations preserved
        assert_eq!(result["capabilityInvocations"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn strips_when_capability_completed() {
        let result = SessionReconstructService::reconcile_in_flight(
            "Done.".into(),
            json!([{
                "invocationId": "tc_1",
                "modelPrimitiveName": "inspect",
                "status": "completed",
                "result": "file contents...",
                "completedAt": "2026-04-07T12:00:01Z",
            }]),
            json!([
                { "type": "text", "text": "Done." },
                { "type": "capability_ref", "invocationId": "tc_1" },
            ]),
        );

        let seq = result["contentSequence"].as_array().unwrap();
        assert_eq!(seq.len(), 1);
        assert_eq!(seq[0]["type"], "capability_ref");
        assert!(result["streaming"].is_null());
    }

    #[test]
    fn strips_when_capability_errored() {
        let result = SessionReconstructService::reconcile_in_flight(
            "Trying...".into(),
            json!([{
                "invocationId": "tc_1",
                "modelPrimitiveName": "execute",
                "status": "error",
                "isError": true,
                "result": "command not found",
            }]),
            json!([
                { "type": "text", "text": "Trying..." },
                { "type": "capability_ref", "invocationId": "tc_1" },
            ]),
        );

        let seq = result["contentSequence"].as_array().unwrap();
        assert_eq!(seq.len(), 1);
        assert_eq!(seq[0]["type"], "capability_ref");
    }

    #[test]
    fn preserves_streaming_output_and_timestamps() {
        let result = SessionReconstructService::reconcile_in_flight(
            "text".into(),
            json!([{
                "invocationId": "tc_1",
                "modelPrimitiveName": "execute",
                "status": "running",
                "arguments": { "command": "sleep 10" },
                "startedAt": "2026-04-07T12:00:00Z",
                "streamingOutput": "partial output line 1\nline 2\n",
                "isError": false,
            }]),
            json!([
                { "type": "capability_ref", "invocationId": "tc_1" },
            ]),
        );

        let capability = &result["capabilityInvocations"][0];
        assert_eq!(capability["startedAt"], "2026-04-07T12:00:00Z");
        assert_eq!(
            capability["streamingOutput"],
            "partial output line 1\nline 2\n"
        );
        assert_eq!(capability["arguments"]["command"], "sleep 10");
        assert_eq!(capability["isError"], false);
    }

    #[test]
    fn no_streaming_when_text_empty_and_no_capabilities() {
        let result = SessionReconstructService::reconcile_in_flight(
            String::new(),
            json!([]),
            json!([
                { "type": "thinking", "thinking": "hmm" },
            ]),
        );

        assert!(result["streaming"].is_null());
        assert_eq!(result["contentSequence"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn strips_multiple_text_and_thinking_blocks() {
        // Interleaved: thinking, text, capability, text, capability
        let result = SessionReconstructService::reconcile_in_flight(
            "second text".into(),
            json!([
                { "invocationId": "tc_1", "modelPrimitiveName": "execute", "status": "running" },
                { "invocationId": "tc_2", "modelPrimitiveName": "inspect", "status": "running" },
            ]),
            json!([
                { "type": "thinking", "thinking": "plan A" },
                { "type": "text", "text": "first text" },
                { "type": "capability_ref", "invocationId": "tc_1" },
                { "type": "thinking", "thinking": "plan B" },
                { "type": "text", "text": "second text" },
                { "type": "capability_ref", "invocationId": "tc_2" },
            ]),
        );

        let seq = result["contentSequence"].as_array().unwrap();
        assert_eq!(seq.len(), 2);
        assert!(seq.iter().all(|item| item["type"] == "capability_ref"));
    }
}
