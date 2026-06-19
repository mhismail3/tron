use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::compaction_handler::CompactionHandler;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::types::RunContext;
use crate::domains::model::responder::ModelResponder;

/// Parameters for a single turn of the agent loop.
pub struct TurnParams<'a> {
    /// Current turn number (1-indexed).
    pub turn: u32,
    /// Context manager owning messages, agent state summaries, and token tracking.
    pub context_manager: &'a mut ContextManager,
    /// Model responder for streaming.
    pub responder: &'a Arc<dyn ModelResponder>,
    /// Compaction handler for pre-turn context checks.
    pub compaction: &'a CompactionHandler,
    /// Session identifier.
    pub session_id: &'a str,
    /// Event emitter for broadcasting agent lifecycle events.
    pub emitter: &'a Arc<EventEmitter>,
    /// Cancellation token for aborting the turn.
    pub cancel: &'a tokio_util::sync::CancellationToken,
    /// Run-scoped context for reasoning level, trace ids, and agent-owned state.
    pub run_context: &'a RunContext,
    /// Optional event persister for inline event storage.
    pub persister: Option<&'a EventPersister>,
    /// Previous turn's context window token count (for delta tracking).
    pub previous_context_baseline: u64,
    /// Optional retry configuration for provider stream retries.
    pub retry_config: Option<&'a crate::shared::foundation::retry::RetryConfig>,
    /// Workspace ID for scoping capability context (e.g. memory recall).
    pub workspace_id: Option<&'a str>,
    /// Server origin (e.g. `"localhost:9847"`) for system prompt.
    pub server_origin: Option<&'a str>,
    /// Optional per-session sequence counter for monotonic event ordering.
    pub sequence_counter: Option<&'a AtomicI64>,
    /// Optional per-invocation abort registry. Threaded into `CapabilityInvocationExecutionContext`
    /// so each in-flight capability invocation registers a child `CancellationToken` that
    /// `agent.abortCapabilityInvocation` can cancel independently of the turn token.
    pub invocation_abort_registry: Option<&'a Arc<InvocationAbortRegistry>>,
    /// Optional engine host for engine-owned capability invocation.
    pub engine_host: Option<&'a crate::engine::EngineHostHandle>,
}
