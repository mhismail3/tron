use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::types::RunContext;
use crate::shared::protocol::events::{BaseEvent, turn_failed_event};
use crate::shared::server::failure::FailureEnvelope;

fn run_base(session_id: &str, run_context: &RunContext) -> BaseEvent {
    BaseEvent::now(session_id).with_trace_context(
        run_context
            .engine_trace_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
        run_context
            .parent_invocation_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
    )
}

pub(super) fn emit_turn_failure(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    turn: u32,
    run_context: &RunContext,
    sequence_counter: Option<&AtomicI64>,
    failure: &FailureEnvelope,
    partial_content: Option<String>,
) {
    let event = turn_failed_event(
        run_base(session_id, run_context),
        turn,
        failure,
        partial_content,
    );
    if let Some(counter) = sequence_counter {
        let _ = emitter.emit_sequenced(event, counter);
    } else {
        let _ = emitter.emit(event);
    }
}
