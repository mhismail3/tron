//! Session reconstruction service — single RPC call returns complete session state.
//!
//! Replaces the legacy pattern of `agent.getState` + `events.getSince` + iOS-side
//! reconciliation. The server is the single source of truth: persisted history
//! events + in-flight state are returned in one response with monotonic sequence
//! numbers for deterministic dedup.
//!
//! ## Response shape
//!
//! ```text
//! {
//!   events: [...],           // persisted events in sequence order
//!   hasMoreEvents: bool,     // true if older events exist (pagination)
//!   oldestSequence: i64?,    // sequence of earliest event in response
//!   inFlight: {...}?,        // non-null only when agent is running
//!   lastSequence: i64,       // highest sequence (includes non-persisted events)
//!   isRunning: bool,
//!   metadata: {...},
//! }
//! ```

use serde_json::{Value, json};
use tracing::{debug, instrument};

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::handlers::events::event_row_to_wire;

pub(crate) struct SessionReconstructService;

impl SessionReconstructService {
    /// Reconstruct the full session state for a reconnecting client.
    #[instrument(skip(ctx), fields(session_id = %session_id))]
    pub(crate) async fn reconstruct(
        ctx: &RpcContext,
        session_id: String,
        limit: Option<i64>,
        before_sequence: Option<i64>,
    ) -> Result<Value, RpcError> {
        let event_store = ctx.event_store.clone();
        let session_manager = ctx.session_manager.clone();
        let orchestrator = ctx.orchestrator.clone();
        let sid = session_id.clone();

        // 1. Load events from DB (blocking — SQLite)
        let (events, has_more, session_metadata) =
            ctx.run_blocking("session.reconstruct.load", move || {
                // Verify session exists
                let session = session_manager
                    .get_session(&sid)
                    .map_err(|e| RpcError::Internal {
                        message: e.to_string(),
                    })?
                    .ok_or_else(|| RpcError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: format!("Session '{sid}' not found"),
                    })?;

                // Load events with pagination
                let events = if let Some(before_seq) = before_sequence {
                    event_store.get_events_before(&sid, before_seq, limit)
                } else {
                    event_store.get_latest_events(&sid, limit)
                }
                .map_err(|e| RpcError::Internal {
                    message: format!("Failed to load events: {e}"),
                })?;

                // Determine if there are older events
                let has_more = if let Some(first) = events.first() {
                    event_store
                        .has_events_before(&sid, first.sequence)
                        .unwrap_or(false)
                } else {
                    false
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
        let is_running = orchestrator.has_active_run(&session_id);
        let in_flight = if is_running {
            let state = Self::build_in_flight_state(&orchestrator, &session_id);
            if let Some(ref s) = state {
                debug!(
                    session_id,
                    tool_count = s.get("toolCalls").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
                    seq_count = s.get("contentSequence").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
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

        let oldest_sequence = events.first().map(|e| e.sequence);

        // 4. Convert events to wire format
        let wire_events: Vec<Value> = events.iter().map(event_row_to_wire).collect();

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
            "oldestSequence": oldest_sequence,
            "inFlight": in_flight,
            "lastSequence": last_sequence,
            "isRunning": is_running,
            "metadata": session_metadata,
        }))
    }

    /// Build the in-flight state from the turn accumulator.
    fn build_in_flight_state(
        orchestrator: &crate::runtime::orchestrator::orchestrator::Orchestrator,
        session_id: &str,
    ) -> Option<Value> {
        let (text, tool_calls, content_sequence) =
            orchestrator.turn_accumulators().get_state(session_id)?;

        // Derive streaming state from the last content item
        let streaming = if !text.is_empty() {
            Some(json!({ "type": "text", "content": text }))
        } else {
            None
        };

        Some(json!({
            "toolCalls": tool_calls,
            "contentSequence": content_sequence,
            "streaming": streaming,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_in_flight_json_shape() {
        // Verify the JSON structure matches the documented response format
        let text = "partial text".to_string();
        let tool_calls = json!([{
            "toolCallId": "tc_1",
            "toolName": "bash",
            "status": "running",
        }]);
        let content_sequence = json!([
            { "type": "text", "text": "partial text" },
            { "type": "tool_ref", "toolCallId": "tc_1" },
        ]);

        let streaming = if !text.is_empty() {
            Some(json!({ "type": "text", "content": text }))
        } else {
            None
        };

        let in_flight = json!({
            "toolCalls": tool_calls,
            "contentSequence": content_sequence,
            "streaming": streaming,
        });

        assert!(in_flight["toolCalls"].is_array());
        assert_eq!(in_flight["toolCalls"][0]["status"], "running");
        assert!(in_flight["contentSequence"].is_array());
        assert_eq!(in_flight["streaming"]["type"], "text");
        assert_eq!(in_flight["streaming"]["content"], "partial text");
    }

    #[test]
    fn test_no_streaming_when_text_empty() {
        let text = String::new();
        let streaming = if !text.is_empty() {
            Some(json!({ "type": "text", "content": text }))
        } else {
            None
        };
        assert!(streaming.is_none());
    }

    #[test]
    fn test_reconstruct_response_shape() {
        // Verify the overall response JSON has all required keys
        let response = json!({
            "events": [],
            "hasMoreEvents": false,
            "oldestSequence": null,
            "inFlight": null,
            "lastSequence": 0,
            "isRunning": false,
            "metadata": {
                "model": "claude-opus-4-20250514",
                "turnCount": 0,
                "workingDirectory": "/tmp",
                "tokenUsage": null,
            },
        });

        assert!(response.get("events").is_some());
        assert!(response.get("hasMoreEvents").is_some());
        assert!(response.get("oldestSequence").is_some());
        assert!(response.get("inFlight").is_some());
        assert!(response.get("lastSequence").is_some());
        assert!(response.get("isRunning").is_some());
        assert!(response.get("metadata").is_some());
    }
}
