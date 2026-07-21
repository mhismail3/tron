//! Stream processor — consumes `ModelResponseStream`, accumulates content blocks.
//!
//! The heavy lifting lives in [`super::stream_state`]: `StreamState` holds the
//! accumulators and `handle_event` classifies each `StreamEvent` into a
//! `StreamAction`. This module provides the public
//! `process_stream` entry point that drives the `tokio::select!` loop.
//! Final results normalize provider terminal metadata against accumulated
//! content so persisted replay cannot claim `end_turn` while carrying a
//! finalized capability invocation. Provider and journal failures return a
//! [`StreamFailure`] containing the content accumulated before the error; the
//! turn runner owns atomic partial-message plus failure persistence.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use futures::StreamExt;
use tokio_util::sync::CancellationToken;

use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
use crate::domains::agent::r#loop::types::StreamResult;
use crate::domains::model::responder::ModelResponseStream;
use crate::engine::{InvocationId, TraceId};

use super::stream_state::{StreamAction, StreamState, StreamTraceContext};

/// A stream error paired with the assistant content accumulated before the
/// failure. The turn owner persists that partial message and its terminal
/// failure atomically so live text does not disappear after reconstruction.
#[derive(Debug)]
pub(crate) struct StreamFailure {
    pub(crate) error: RuntimeError,
    pub(crate) partial: StreamResult,
}

impl std::fmt::Display for StreamFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.error.fmt(formatter)
    }
}

impl std::error::Error for StreamFailure {}

fn failed(state: StreamState, error: RuntimeError) -> StreamFailure {
    StreamFailure {
        error,
        partial: state.build_failed_result(),
    }
}

/// Process an LLM stream, accumulating content and emitting events.
///
/// After real streamed content has been observed, the result is built from
/// accumulators rather than the provider's final message. Final-only responses
/// still use the provider `Done` message because some providers synthesize
/// block close events from that same terminal payload.
#[cfg(test)]
pub async fn process_stream(
    stream: ModelResponseStream,
    session_id: &str,
    emitter: &Arc<EventEmitter>,
    cancel: &CancellationToken,
    sequence_counter: Option<&AtomicI64>,
    journal: Option<&mut StreamingJournal>,
) -> Result<StreamResult, StreamFailure> {
    process_stream_with_trace(
        stream,
        session_id,
        emitter,
        cancel,
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
    mut stream: ModelResponseStream,
    session_id: &str,
    emitter: &Arc<EventEmitter>,
    cancel: &CancellationToken,
    sequence_counter: Option<&AtomicI64>,
    mut journal: Option<&mut StreamingJournal>,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> Result<StreamResult, StreamFailure> {
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
                return Err(failed(
                    state,
                    RuntimeError::Internal("Stream ended without Done event".into()),
                ));
            }
            Some(Err(error)) if error.is_cancelled() => {
                return Ok(state.build_interrupted_result());
            }
            Some(Err(e)) => {
                return Err(failed(state, RuntimeError::ModelResponse(e)));
            }
            Some(Ok(stream_event)) => {
                let action = state.handle_event(
                    stream_event,
                    session_id,
                    emitter,
                    sequence_counter,
                    &mut journal,
                    trace_context,
                );
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
                    StreamAction::Err(e) => return Err(failed(state, e)),
                }
            }
        }
    }

    Ok(state.finalize_stream_result(final_message, stop_reason))
}

#[cfg(test)]
mod tests;
