//! Orchestrator — multi-session coordinator.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

/// Hard ceiling on concurrent agent runs. Enforced by a semaphore in
/// `RunRegistry` — exceeding this surfaces as `RuntimeError::ServerBusy`.
pub const MAX_CONCURRENT_SESSIONS: usize = 50;

use crate::shared::events::TronEvent;
use dashmap::DashMap;
use parking_lot::Mutex;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, broadcast};
use tokio_util::sync::CancellationToken;

use metrics::gauge;
use tracing::{debug, info, instrument, trace, warn};

use crate::domains::agent::runner::agent::compaction_handler::CompactionHandler;
use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::errors::RuntimeError;
use crate::domains::agent::runner::orchestrator::capability_invocation_tracker::CapabilityInvocationTracker;
use crate::domains::agent::runner::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::runner::orchestrator::session_manager::{SessionFilter, SessionManager};
use crate::domains::agent::runner::orchestrator::turn_accumulator::TurnAccumulatorMap;

/// Read-only probe for querying active run state.
///
/// Exists to break an Arc cycle between `Orchestrator` and `SubagentManager`:
/// `SubagentManager` needs to know whether a parent session has an active run
/// to decide whether iOS should show a subagent-completion notification, but
/// it cannot hold an `Arc<Orchestrator>` because `Orchestrator` transitively
/// holds `SubagentManager`. Instead, `SubagentManager` stores a
/// `Weak<dyn RunStateProbe>`, obtained from [`Orchestrator::run_state_probe`].
pub trait RunStateProbe: Send + Sync {
    /// Return `true` if the session currently has an active agent run.
    fn has_active_run(&self, session_id: &str) -> bool;
}

impl RunStateProbe for Orchestrator {
    fn has_active_run(&self, session_id: &str) -> bool {
        Orchestrator::has_active_run(self, session_id)
    }
}

/// Tracks an active agent run within a session.
struct ActiveRun {
    run_id: String,
    cancel: CancellationToken,
}

struct RunRegistry {
    run_semaphore: Arc<Semaphore>,
    active_runs: Mutex<HashMap<String, ActiveRun>>,
}

impl RunRegistry {
    fn new() -> Self {
        Self {
            run_semaphore: Arc::new(Semaphore::new(MAX_CONCURRENT_SESSIONS)),
            active_runs: Mutex::new(HashMap::new()),
        }
    }

    fn remove(&self, session_id: &str) {
        let mut runs = self.active_runs.lock();
        let _ = runs.remove(session_id);
        #[allow(clippy::cast_precision_loss)]
        gauge!("agent_runs_active").set(runs.len() as f64);
    }
}

/// Active run registration guard.
///
/// Dropping this guard always clears the session's active-run entry and
/// releases its concurrency permit, even if the owning task exits early.
pub struct StartedRun {
    session_id: String,
    cancel: CancellationToken,
    registry: Arc<RunRegistry>,
    permit: Option<OwnedSemaphorePermit>,
}

impl StartedRun {
    /// Get the cancellation token for this run.
    pub fn cancel_token(&self) -> CancellationToken {
        self.cancel.clone()
    }
}

impl Drop for StartedRun {
    fn drop(&mut self) {
        self.registry.remove(&self.session_id);
        let _ = self.permit.take();
    }
}

/// RAII guard for a session's retain slot.
///
/// Clears the session from `Orchestrator::retain_in_flight` on drop. Obtained
/// via [`Orchestrator::try_begin_retain`]; there is no way to construct one
/// without going through that method, so the set and the guard stay in sync.
pub struct RetainGuard {
    session_id: String,
    set: Arc<DashMap<String, ()>>,
}

impl Drop for RetainGuard {
    fn drop(&mut self) {
        let _ = self.set.remove(&self.session_id);
    }
}

impl std::fmt::Debug for RetainGuard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RetainGuard")
            .field("session_id", &self.session_id)
            .finish()
    }
}

impl std::fmt::Debug for StartedRun {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StartedRun")
            .field("session_id", &self.session_id)
            .finish_non_exhaustive()
    }
}

/// Multi-session orchestrator.
pub struct Orchestrator {
    session_manager: Arc<SessionManager>,
    broadcast: Arc<EventEmitter>,
    run_registry: Arc<RunRegistry>,
    /// Capability invocation tracker shared with capability-result capabilities.
    capability_invocation_tracker: Mutex<CapabilityInvocationTracker>,
    /// Accumulates in-progress turn content for session resume catch-up.
    turn_accumulators: Arc<TurnAccumulatorMap>,
    /// Per-session monotonic sequence counters.
    /// Key: session_id, Value: shared atomic counter (current value = last assigned).
    sequence_counters: Arc<DashMap<String, Arc<AtomicI64>>>,
    /// Per-session compaction handlers for active agent sessions.
    /// Registered when an agent starts, removed when it ends.
    compaction_handlers: Arc<DashMap<String, Arc<CompactionHandler>>>,
    /// Set of session IDs with a retain pipeline currently running.
    ///
    /// Prevents two concurrent retains on the same session (manual + auto,
    /// or double-clicked manual) from running two summarizer subsessions
    /// and producing duplicate `memory.retained` events. Held as `Arc<DashMap>`
    /// so background tasks can hold a reference independent of the orchestrator.
    retain_in_flight: Arc<DashMap<String, ()>>,
    /// Per-invocation cancellation tokens for `agent.abortCapabilityInvocation`. Populated by the
    /// capability executor on each call, consumed (cancelled) by the engine transport.
    invocation_abort_registry: Arc<InvocationAbortRegistry>,
}

impl Orchestrator {
    /// Create a new orchestrator.
    pub fn new(session_manager: Arc<SessionManager>) -> Self {
        Self {
            session_manager,
            broadcast: Arc::new(EventEmitter::new()),
            run_registry: Arc::new(RunRegistry::new()),
            capability_invocation_tracker: Mutex::new(CapabilityInvocationTracker::new()),
            turn_accumulators: Arc::new(TurnAccumulatorMap::new()),
            sequence_counters: Arc::new(DashMap::new()),
            compaction_handlers: Arc::new(DashMap::new()),
            retain_in_flight: Arc::new(DashMap::new()),
            invocation_abort_registry: Arc::new(InvocationAbortRegistry::new()),
        }
    }

    /// Get a shared reference to the per-invocation abort registry.
    pub fn invocation_abort_registry(&self) -> &Arc<InvocationAbortRegistry> {
        &self.invocation_abort_registry
    }

    /// Get the session manager.
    pub fn session_manager(&self) -> &Arc<SessionManager> {
        &self.session_manager
    }

    /// Get the broadcast emitter.
    pub fn broadcast(&self) -> &Arc<EventEmitter> {
        &self.broadcast
    }

    /// Subscribe to all orchestrator events.
    pub fn subscribe(&self) -> broadcast::Receiver<TronEvent> {
        self.broadcast.subscribe()
    }

    /// Get the turn accumulator map (for session resume catch-up).
    pub fn turn_accumulators(&self) -> &Arc<TurnAccumulatorMap> {
        &self.turn_accumulators
    }

    // ── Per-session sequence counters ──

    /// Initialize a sequence counter for a session.
    ///
    /// Called on session create (start=0) or session resume (start=MAX from DB).
    pub fn init_sequence_counter(&self, session_id: &str, start: i64) {
        let _ = self
            .sequence_counters
            .insert(session_id.to_string(), Arc::new(AtomicI64::new(start)));
        trace!(session_id, start, "sequence counter initialized");
    }

    /// Get a session sequence counter and advance it to at least `floor`.
    ///
    /// Prompt runs call this before attaching the shared counter to an agent.
    /// The DB can legitimately have newer persisted events than an in-memory
    /// counter after session resume, external persistence, or an earlier
    /// failed append. Advancing, never resetting, preserves live broadcast
    /// ordering while preventing duplicate persisted `(session_id, sequence)`
    /// rows.
    pub fn ensure_sequence_counter_at_least(&self, session_id: &str, floor: i64) -> Arc<AtomicI64> {
        let counter = match self.sequence_counters.entry(session_id.to_string()) {
            dashmap::mapref::entry::Entry::Occupied(entry) => Arc::clone(entry.get()),
            dashmap::mapref::entry::Entry::Vacant(entry) => {
                let counter = Arc::new(AtomicI64::new(floor));
                entry.insert(Arc::clone(&counter));
                trace!(session_id, floor, "sequence counter initialized");
                return counter;
            }
        };

        let mut current = counter.load(Ordering::SeqCst);
        while current < floor {
            match counter.compare_exchange(current, floor, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => {
                    trace!(
                        session_id,
                        from = current,
                        to = floor,
                        "sequence counter advanced"
                    );
                    break;
                }
                Err(next) => current = next,
            }
        }
        counter
    }

    /// Atomically increment and return the next sequence number for a session.
    ///
    /// Returns 1-based sequences (first call after init(0) returns 1).
    /// Returns `Err` if the counter was not initialized for the given session.
    pub fn next_sequence(&self, session_id: &str) -> Result<i64, RuntimeError> {
        let entry = self.sequence_counters.get(session_id).ok_or_else(|| {
            RuntimeError::Internal(format!(
                "sequence counter not initialized for session {session_id}"
            ))
        })?;
        let seq = entry.value().fetch_add(1, Ordering::SeqCst) + 1;
        trace!(session_id, seq, "sequence assigned");
        Ok(seq)
    }

    /// Read the current sequence value without incrementing.
    ///
    /// Returns `None` if the counter was never initialized for this session.
    pub fn current_sequence(&self, session_id: &str) -> Option<i64> {
        self.sequence_counters
            .get(session_id)
            .map(|entry| entry.value().load(Ordering::SeqCst))
    }

    /// Remove the sequence counter for a session (cleanup on session end).
    pub fn remove_sequence_counter(&self, session_id: &str) {
        if self.sequence_counters.remove(session_id).is_some() {
            trace!(session_id, "sequence counter removed");
        }
    }

    // ── Retain concurrency guard ──

    /// Claim the retain slot for a session. Returns `Some(RetainGuard)` if the
    /// slot was free, or `None` if a retain is already in flight.
    ///
    /// The returned guard removes the session from the in-flight set on drop
    /// (including on panic), so leaks cannot occur even if the caller task
    /// unwinds.
    pub fn try_begin_retain(&self, session_id: &str) -> Option<RetainGuard> {
        // DashMap::entry vacant check gives single-call atomic insertion.
        match self.retain_in_flight.entry(session_id.to_owned()) {
            dashmap::mapref::entry::Entry::Occupied(_) => None,
            dashmap::mapref::entry::Entry::Vacant(v) => {
                let _ = v.insert(());
                Some(RetainGuard {
                    session_id: session_id.to_owned(),
                    set: Arc::clone(&self.retain_in_flight),
                })
            }
        }
    }

    /// True if a retain is currently running for `session_id`. Test-only.
    #[cfg(test)]
    pub fn retain_is_in_flight(&self, session_id: &str) -> bool {
        self.retain_in_flight.contains_key(session_id)
    }

    /// Get a cloned reference to a session's sequence counter.
    ///
    /// Returns `None` if the counter was never initialized for this session.
    /// The returned `Arc<AtomicI64>` can be passed to agents and held across
    /// async boundaries without holding a DashMap lock.
    pub fn get_sequence_counter(&self, session_id: &str) -> Option<Arc<AtomicI64>> {
        self.sequence_counters
            .get(session_id)
            .map(|entry| Arc::clone(entry.value()))
    }

    // ── Per-session compaction handlers ──

    /// Register a compaction handler for a session.
    ///
    /// Called when an agent starts running so that engine compaction
    /// requests can route through the handler (with concurrency guard
    /// and PreCompact hooks).
    pub fn register_compaction_handler(&self, session_id: &str, handler: Arc<CompactionHandler>) {
        let _ = self
            .compaction_handlers
            .insert(session_id.to_string(), handler);
        trace!(session_id, "compaction handler registered");
    }

    /// Get the compaction handler for a session (if an agent is active).
    pub fn get_compaction_handler(&self, session_id: &str) -> Option<Arc<CompactionHandler>> {
        self.compaction_handlers
            .get(session_id)
            .map(|entry| Arc::clone(entry.value()))
    }

    /// Remove the compaction handler for a session (cleanup on session end).
    pub fn remove_compaction_handler(&self, session_id: &str) {
        if self.compaction_handlers.remove(session_id).is_some() {
            trace!(session_id, "compaction handler removed");
        }
    }

    /// Start tracking a run for a session.
    ///
    /// Errors if:
    /// - The session already has an active run (`SessionBusy`)
    /// - The server is at max concurrent runs (`ServerBusy`)
    #[instrument(skip(self), fields(session_id, run_id))]
    pub fn begin_run(&self, session_id: &str, run_id: &str) -> Result<StartedRun, RuntimeError> {
        let mut runs = self.run_registry.active_runs.lock();
        if runs.contains_key(session_id) {
            return Err(RuntimeError::SessionBusy(session_id.to_string()));
        }
        // Acquire a concurrency permit (non-blocking).
        let permit = Arc::clone(&self.run_registry.run_semaphore)
            .try_acquire_owned()
            .map_err(|_| RuntimeError::ServerBusy {
                current: runs.len(),
                max: MAX_CONCURRENT_SESSIONS,
            })?;
        let cancel = CancellationToken::new();
        let _ = runs.insert(
            session_id.to_string(),
            ActiveRun {
                run_id: run_id.to_string(),
                cancel: cancel.clone(),
            },
        );
        #[allow(clippy::cast_precision_loss)]
        gauge!("agent_runs_active").set(runs.len() as f64);
        debug!(session_id, run_id, "run started");
        Ok(StartedRun {
            session_id: session_id.to_string(),
            cancel,
            registry: Arc::clone(&self.run_registry),
            permit: Some(permit),
        })
    }

    /// Get the run ID for an active session (if any).
    pub fn get_run_id(&self, session_id: &str) -> Option<String> {
        self.run_registry
            .active_runs
            .lock()
            .get(session_id)
            .map(|r| r.run_id.clone())
    }

    /// Check if a session has an active run.
    pub fn has_active_run(&self, session_id: &str) -> bool {
        self.run_registry
            .active_runs
            .lock()
            .contains_key(session_id)
    }

    /// Read-only probe for run state.
    ///
    /// Allows `SubagentManager` to query whether a parent session has an active
    /// run without holding a strong `Arc<Orchestrator>` (which would create a
    /// cycle: Orchestrator → SubagentManager → Orchestrator). `SubagentManager`
    /// stores this as `Weak<dyn RunStateProbe>`.
    pub fn run_state_probe(self: &Arc<Self>) -> std::sync::Weak<dyn RunStateProbe> {
        let strong: Arc<dyn RunStateProbe> = self.clone();
        Arc::downgrade(&strong)
    }

    /// Number of active runs.
    pub fn active_run_count(&self) -> usize {
        self.run_registry.active_runs.lock().len()
    }

    /// Abort a running session by cancelling its `CancellationToken`.
    /// Returns true if the session had an active run that was cancelled.
    #[instrument(skip(self), fields(session_id))]
    pub fn abort(&self, session_id: &str) -> Result<bool, RuntimeError> {
        let runs = self.run_registry.active_runs.lock();
        if let Some(run) = runs.get(session_id) {
            warn!(session_id, "abort requested");
            run.cancel.cancel();
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// Check if a session is busy (currently processing).
    ///
    /// This is an **advisory** check — it reads from two independent data stores
    /// (`active_runs` and `session_manager`) without a single atomic transaction.
    /// Callers should tolerate stale results. The authoritative guard is
    /// `begin_run()`, which rejects duplicate runs under its own lock.
    pub fn is_session_busy(&self, session_id: &str) -> bool {
        self.has_active_run(session_id) || self.session_manager.is_active(session_id)
    }

    /// Active session count.
    pub fn active_session_count(&self) -> usize {
        self.session_manager.active_count()
    }

    /// Maximum concurrent session limit.
    pub fn max_concurrent_sessions(&self) -> usize {
        MAX_CONCURRENT_SESSIONS
    }

    /// Whether we can accept another concurrent session.
    pub fn can_accept_session(&self) -> bool {
        self.session_manager.active_count() < MAX_CONCURRENT_SESSIONS
    }

    /// Register a capability invocation, returning a receiver for the result.
    pub fn register_capability_invocation(
        &self,
        invocation_id: &str,
    ) -> tokio::sync::oneshot::Receiver<serde_json::Value> {
        self.capability_invocation_tracker
            .lock()
            .register(invocation_id)
    }

    /// Resolve a pending capability invocation with a result. Returns true if found.
    pub fn resolve_capability_invocation(
        &self,
        invocation_id: &str,
        value: serde_json::Value,
    ) -> bool {
        self.capability_invocation_tracker
            .lock()
            .resolve(invocation_id, value)
    }

    /// Check if a capability invocation is pending.
    pub fn has_pending_capability_invocation(&self, invocation_id: &str) -> bool {
        self.capability_invocation_tracker
            .lock()
            .has_pending(invocation_id)
    }

    /// Graceful shutdown — end all active sessions.
    #[instrument(skip(self))]
    pub async fn shutdown(&self) -> Result<(), RuntimeError> {
        info!("orchestrator shutdown initiated");
        // Cancel and clear all active runs
        {
            let mut runs = self.run_registry.active_runs.lock();
            if !runs.is_empty() {
                warn!(
                    count = runs.len(),
                    "clearing orphaned active runs during shutdown"
                );
                for run in runs.values() {
                    run.cancel.cancel();
                }
                runs.clear();
                #[allow(clippy::cast_precision_loss)]
                gauge!("agent_runs_active").set(0.0);
            }
        }

        // Cancel all pending capability invocations
        self.capability_invocation_tracker.lock().cancel_all();

        // Clear all sequence counters and compaction handlers
        self.sequence_counters.clear();
        self.compaction_handlers.clear();

        // List all active sessions and end them
        let sessions = self
            .session_manager
            .list_sessions(&SessionFilter::default())
            .unwrap_or_default();

        for session in sessions {
            if let Err(e) = self.session_manager.end_session(&session.id).await {
                warn!(session_id = %session.id, error = %e, "failed to end session during shutdown");
            }
        }

        Ok(())
    }
}

#[cfg(test)]
#[path = "orchestrator/tests.rs"]
mod tests;
