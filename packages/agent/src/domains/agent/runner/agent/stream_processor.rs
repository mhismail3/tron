//! Stream processor — consumes `StreamEventStream`, accumulates content blocks.
//!
//! The heavy lifting lives in [`super::stream_state`]: `StreamState` holds the
//! accumulators and `handle_normal_event` / `handle_drain_event` classify each
//! `StreamEvent` into a `StreamAction`. This module provides the public
//! `process_stream` entry point that drives the `tokio::select!` loop.

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use futures::StreamExt;
use tokio_util::sync::CancellationToken;

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::errors::RuntimeError;
use crate::domains::agent::runner::orchestrator::streaming_journal::StreamingJournal;
use crate::domains::agent::runner::types::StreamResult;
use crate::domains::model::providers::provider::{ProviderError, StreamEventStream};
use crate::engine::{InvocationId, TraceId};

use super::stream_state::{StreamAction, StreamState, StreamTraceContext};

/// Process an LLM stream, accumulating content and emitting events.
///
/// When a tool in `turn_stopping_tools` completes (via `ToolCallEnd`), the
/// processor enters **drain mode**: it stops accumulating content (text,
/// thinking, further capability invocations) but keeps reading the stream to capture
/// accurate token usage from the `Done` event. The result is built from
/// accumulators (which contain only pre-drain content), not from the
/// provider's final message.
pub async fn process_stream(
    stream: StreamEventStream,
    session_id: &str,
    emitter: &Arc<EventEmitter>,
    cancel: &CancellationToken,
    turn_stopping_tools: &HashSet<String>,
    sequence_counter: Option<&AtomicI64>,
    journal: Option<&mut StreamingJournal>,
) -> Result<StreamResult, RuntimeError> {
    process_stream_with_trace(
        stream,
        session_id,
        emitter,
        cancel,
        turn_stopping_tools,
        sequence_counter,
        journal,
        None,
        None,
    )
    .await
}

/// Process an LLM stream with inherited engine trace context for every emitted
/// runtime event.
#[allow(clippy::too_many_arguments)]
pub async fn process_stream_with_trace(
    mut stream: StreamEventStream,
    session_id: &str,
    emitter: &Arc<EventEmitter>,
    cancel: &CancellationToken,
    turn_stopping_tools: &HashSet<String>,
    sequence_counter: Option<&AtomicI64>,
    mut journal: Option<&mut StreamingJournal>,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> Result<StreamResult, RuntimeError> {
    let mut state = StreamState::new();
    let (stop_reason, final_message);
    let trace_context = StreamTraceContext {
        trace_id,
        parent_invocation_id,
    };

    loop {
        // biased: prefer cancellation when both a stream event and cancel are ready
        let event = tokio::select! {
            biased;
            () = cancel.cancelled() => {
                return Ok(state.build_interrupted_result());
            }
            event = stream.next() => event,
        };

        match event {
            None => {
                return Err(RuntimeError::Internal(
                    "Stream ended without Done event".into(),
                ));
            }
            Some(Err(ProviderError::Cancelled)) => {
                return Ok(state.build_interrupted_result());
            }
            Some(Err(e)) => {
                return Err(RuntimeError::Provider(e));
            }
            Some(Ok(stream_event)) => {
                let action = if state.draining {
                    state.handle_drain_event(
                        stream_event,
                        session_id,
                        emitter,
                        sequence_counter,
                        trace_context,
                    )
                } else {
                    state.handle_normal_event(
                        stream_event,
                        session_id,
                        emitter,
                        sequence_counter,
                        turn_stopping_tools,
                        &mut journal,
                        trace_context,
                    )
                };
                match action {
                    StreamAction::Continue => continue,
                    StreamAction::Done {
                        stop_reason: sr,
                        final_message: fm,
                    } => {
                        stop_reason = sr;
                        final_message = fm;
                        break;
                    }
                    StreamAction::Err(e) => return Err(e),
                }
            }
        }
    }

    Ok(state.finalize_stream_result(final_message, stop_reason))
}

#[cfg(test)]
#[path = "stream_processor_tests.rs"]
mod tests;
