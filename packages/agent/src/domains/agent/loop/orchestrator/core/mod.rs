//! Orchestrator core — multi-session coordinator.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `tests` | Coordinator capacity, sequencing, cancellation, and broadcast tests |
//!
//! ## Entry Points
//!
//! - [`Orchestrator::new`] wires the coordinator to `SessionManager`.
//! - [`Orchestrator::run_agent`] starts a primitive agent turn for a session.
//! - [`Orchestrator::try_begin_retain`] guards active-run retention and
//!   concurrency permits.
//!
//! ## Dependency Direction
//!
//! Depends on sibling orchestrator helpers, agent loop event emission, session
//! management, and shared protocol events. Depended on by bootstrap, prompt
//! runtime services, and session reconstruction through the public
//! `domains::agent::Orchestrator` export.
//!
//! ## Invariants
//!
//! - The active-run registry enforces [`MAX_CONCURRENT_SESSIONS`].
//! - Dropping [`StartedRun`] releases both cancellation state and the semaphore
//!   permit, and removes only its matching reconstruction projection.
//! - Runtime sequence assignment stays synchronized with durable event-store
//!   sequence truth; one active run owns sequenced completion through the final
//!   session metadata event.
//!
//! ## Test Ownership
//!
//! Coordinator tests live in `tests`. Cross-module behavior is covered by
//! prompt runtime, session reconstruction, and integration tests.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

/// Hard ceiling on concurrent agent runs. Enforced by a semaphore in
/// `RunRegistry` — exceeding this surfaces as `RuntimeError::ServerBusy`.
pub const MAX_CONCURRENT_SESSIONS: usize = 50;

use crate::shared::protocol::events::TronEvent;
use dashmap::DashMap;
use parking_lot::Mutex;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, broadcast};
use tokio_util::sync::CancellationToken;

use metrics::gauge;
use tracing::{debug, info, instrument, trace, warn};

use crate::domains::agent::r#loop::compaction_handler::CompactionHandler;
use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::agent::r#loop::orchestrator::tool_invocation_tracker::ToolInvocationTracker;
use crate::domains::agent::r#loop::orchestrator::turn_accumulator::{
    TurnAccumulatorMap, TurnReconstructionSnapshot,
};

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
}

/// Active run registration guard.
///
/// Dropping this guard always clears the session's active-run entry and
/// releases its concurrency permit, even if the owning task exits early.
pub struct StartedRun {
    session_id: String,
    run_id: String,
    cancel: CancellationToken,
    registry: Arc<RunRegistry>,
    turn_accumulators: Arc<TurnAccumulatorMap>,
    permit: Option<OwnedSemaphorePermit>,
}

impl StartedRun {
    /// Get the cancellation token for this run.
    pub fn cancel_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    /// Finish the matching run while serializing its terminal publication with
    /// admission of the next run for this session.
    ///
    /// `before_release` runs while the active-run registry is locked. A client
    /// awakened by those terminal events can begin admission on another thread,
    /// but that admission cannot observe `SessionBusy`: it waits for this method
    /// to remove the old run and release its concurrency permit first.
    pub(in crate::domains::agent) fn finish_with(&mut self, before_release: impl FnOnce()) -> bool {
        let removed = {
            let mut runs = self.registry.active_runs.lock();
            let matches = runs
                .get(&self.session_id)
                .is_some_and(|run| run.run_id == self.run_id);
            if matches {
                before_release();
                let _ = runs.remove(&self.session_id);
                // Release the global capacity slot before another same-session
                // admission can acquire the registry lock.
                let _ = self.permit.take();
            }
            #[allow(clippy::cast_precision_loss)]
            gauge!("agent_runs_active").set(runs.len() as f64);
            matches
        };

        if removed {
            self.turn_accumulators
                .finish_run(&self.session_id, &self.run_id);
        } else {
            // Shutdown may have cleared the registry first. The guard still
            // owns its semaphore permit and must release it exactly once.
            let _ = self.permit.take();
        }
        removed
    }
}

impl Drop for StartedRun {
    fn drop(&mut self) {
        let _ = self.finish_with(|| {});
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
    /// Tool invocation tracker shared with tool-result tools.
    tool_invocation_tracker: Mutex<ToolInvocationTracker>,
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
    /// Per-invocation cancellation tokens for `agent.abortToolInvocation`. Populated by the
    /// tool executor on each call, consumed (cancelled) by the engine transport.
    invocation_abort_registry: Arc<InvocationAbortRegistry>,
}

impl Orchestrator {
    /// Create a new orchestrator.
    pub fn new(session_manager: Arc<SessionManager>) -> Self {
        let turn_accumulators = Arc::new(TurnAccumulatorMap::new());
        Self {
            session_manager,
            broadcast: Arc::new(EventEmitter::with_observer(turn_accumulators.clone())),
            run_registry: Arc::new(RunRegistry::new()),
            tool_invocation_tracker: Mutex::new(ToolInvocationTracker::new()),
            turn_accumulators,
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
        let counter = entry.value();
        let mut current = counter.load(Ordering::SeqCst);
        let seq = loop {
            let next = current.checked_add(1).ok_or_else(|| {
                RuntimeError::Persistence(format!(
                    "event sequence exhausted for session {session_id}"
                ))
            })?;
            match counter.compare_exchange_weak(current, next, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => break next,
                Err(observed) => current = observed,
            }
        };
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

    /// Remove the sequence counter after permanent session deletion.
    ///
    /// Reversible archive preserves this live ordering projection so an
    /// unarchived session cannot reuse a provider-visible sequence.
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

    // ── Per-session compaction handlers ──

    /// Register a compaction handler for a session.
    ///
    /// Called when an agent starts running so engine compaction requests can
    /// route through the active handler with the session run guard.
    pub fn register_compaction_handler(&self, session_id: &str, handler: Arc<CompactionHandler>) {
        let _ = self
            .compaction_handlers
            .insert(session_id.to_string(), handler);
        trace!(session_id, "compaction handler registered");
    }

    /// Get the compaction handler for a session (if an agent is active).
    #[cfg(test)]
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
        self.turn_accumulators.begin_run(session_id, run_id);
        #[allow(clippy::cast_precision_loss)]
        gauge!("agent_runs_active").set(runs.len() as f64);
        debug!(session_id, run_id, "run started");
        Ok(StartedRun {
            session_id: session_id.to_string(),
            run_id: run_id.to_string(),
            cancel,
            registry: Arc::clone(&self.run_registry),
            turn_accumulators: Arc::clone(&self.turn_accumulators),
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

    /// Atomically pair the active run identity with its reconstruction
    /// projection. `begin_run` takes these locks in the same order.
    pub(crate) fn active_reconstruction_snapshot(
        &self,
        session_id: &str,
    ) -> Option<(String, Option<TurnReconstructionSnapshot>)> {
        let runs = self.run_registry.active_runs.lock();
        let run_id = runs.get(session_id)?.run_id.clone();
        let snapshot = self
            .turn_accumulators
            .reconstruction_snapshot(session_id, &run_id);
        Some((run_id, snapshot))
    }

    /// Atomically pair status run identity with its current tool.
    pub(crate) fn agent_status_snapshot(
        &self,
        session_id: &str,
    ) -> (
        Option<String>,
        Option<crate::domains::agent::r#loop::orchestrator::turn_accumulator::CurrentToolSnapshot>,
    ) {
        let runs = self.run_registry.active_runs.lock();
        let Some(run_id) = runs.get(session_id).map(|run| run.run_id.clone()) else {
            return (None, None);
        };
        let tool = self
            .turn_accumulators
            .current_running_tool(session_id, &run_id);
        (Some(run_id), tool)
    }

    /// Commit the durable prompt-admission row into the matching run's
    /// reconstruction cut.
    pub(crate) fn commit_run_admission(
        &self,
        session_id: &str,
        run_id: &str,
        sequence: i64,
    ) -> bool {
        self.turn_accumulators
            .commit_admission(session_id, run_id, sequence)
    }

    /// Observe when the matching run's durable prompt-admission row commits.
    pub(crate) fn run_admission_receiver(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> Option<tokio::sync::watch::Receiver<bool>> {
        self.turn_accumulators
            .admission_receiver(session_id, run_id)
    }

    /// Check if a session has an active run.
    pub fn has_active_run(&self, session_id: &str) -> bool {
        self.run_registry
            .active_runs
            .lock()
            .contains_key(session_id)
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

    /// Number of reconstructed session projections currently cached.
    ///
    /// Health and `system.info` expose this cache-residency value as
    /// `active_sessions` / `activeSessions`. Active run truth lives in
    /// `RunRegistry` and is exposed separately.
    pub(crate) fn cached_session_count(&self) -> usize {
        self.session_manager.cached_count()
    }

    /// Register a tool invocation, returning a receiver for the result.
    pub fn register_tool_invocation(
        &self,
        invocation_id: &str,
    ) -> tokio::sync::oneshot::Receiver<serde_json::Value> {
        self.tool_invocation_tracker.lock().register(invocation_id)
    }

    /// Resolve a pending tool invocation with a result. Returns true if found.
    pub fn resolve_tool_invocation(&self, invocation_id: &str, value: serde_json::Value) -> bool {
        self.tool_invocation_tracker
            .lock()
            .resolve(invocation_id, value)
    }

    /// Check if a tool invocation is pending.
    pub fn has_pending_tool_invocation(&self, invocation_id: &str) -> bool {
        self.tool_invocation_tracker
            .lock()
            .has_pending(invocation_id)
    }

    /// Graceful shutdown — cancel runtime work and end all unarchived durable sessions.
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
            // Keep the established registry -> projection lock order. Late run
            // events cannot recreate entries because `begin_run` is the
            // projection's sole creator.
            self.turn_accumulators.clear();
        }

        // Cancel all pending tool invocations
        self.tool_invocation_tracker.lock().cancel_all();

        // Clear all sequence counters and compaction handlers
        self.sequence_counters.clear();
        self.compaction_handlers.clear();

        self.session_manager.end_unarchived_sessions_for_shutdown();

        Ok(())
    }
}

#[cfg(test)]
mod tests;
