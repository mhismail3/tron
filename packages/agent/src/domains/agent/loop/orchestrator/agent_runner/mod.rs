//! Agent runner execution — wraps `TronAgent` with orchestrator integration.
//!
//! Handles primitive run execution and the critical
//! `agent.complete` → `agent.ready` ordering. The public [`run_agent`] entry is
//! deliberately small: `TronAgent` owns child context and tool execution, the
//! outer emitter owns reconnect-visible sequencing, and prompt completion owns
//! slot release. High-volume stream and lifecycle scenarios live in `tests`.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

#[cfg(test)]
use crate::shared::protocol::events::TronEvent;
use tracing::{debug, instrument};

use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::tron_agent::TronAgent;
use crate::domains::agent::r#loop::types::{RunContext, RunResult};

/// Run an agent with orchestrator integration.
///
/// This wraps `TronAgent::run` with:
/// 1. Build and inject the primitive `RunContext`
/// 2. Execute `agent.run(content, ctx)`
/// 3. Emit run events directly through the orchestrator's canonical emitter
///
/// Terminal readiness is owned by prompt completion, which publishes the final
/// session projection and synchronizes `agent.ready` with run-slot release.
#[instrument(skip_all, fields(session_id = agent.session_id()))]
pub async fn run_agent(
    agent: &mut TronAgent,
    content: &str,
    ctx: RunContext,
    broadcast: &Arc<EventEmitter>,
    sequence_counter: Option<Arc<AtomicI64>>,
) -> RunResult {
    let session_id = agent.session_id().to_owned();
    debug!(session_id = agent.session_id(), "agent runner starting");

    // Inject sequence counter so the agent can assign monotonic sequences to events.
    if let Some(ref counter) = sequence_counter {
        agent.set_sequence_counter(counter.clone());
    }

    // INVARIANT: there is no intermediate broadcast hop. The outer emitter
    // synchronously updates reconnect state before broadcasting each event.
    agent.set_emitter(broadcast.clone());

    // Run the agent.
    let result = agent.run(content, ctx).await;

    debug!(session_id, stop_reason = ?result.stop_reason, turns = result.turns_executed, "agent run completed");

    result
}

#[cfg(test)]
mod tests;
