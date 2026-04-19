//! Orchestrator — multi-session coordinator.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

/// Hard ceiling on concurrent agent runs. Enforced by a semaphore in
/// `RunRegistry` — exceeding this surfaces as `RuntimeError::ServerBusy`.
pub const MAX_CONCURRENT_SESSIONS: usize = 50;

use dashmap::DashMap;
use parking_lot::Mutex;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, broadcast};
use tokio_util::sync::CancellationToken;
use crate::core::events::TronEvent;

use metrics::gauge;
use tracing::{debug, info, instrument, trace, warn};

use crate::runtime::agent::compaction_handler::CompactionHandler;
use crate::runtime::agent::event_emitter::EventEmitter;
use crate::runtime::errors::RuntimeError;
use crate::runtime::orchestrator::session_manager::{SessionFilter, SessionManager};
use crate::runtime::orchestrator::tool_call_tracker::ToolCallTracker;
use crate::runtime::orchestrator::turn_accumulator::TurnAccumulatorMap;

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
    /// Tool call tracker shared with RPC handlers.
    tool_tracker: Mutex<ToolCallTracker>,
    /// Accumulates in-progress turn content for session resume catch-up.
    turn_accumulators: Arc<TurnAccumulatorMap>,
    /// Per-session monotonic sequence counters.
    /// Key: session_id, Value: shared atomic counter (current value = last assigned).
    sequence_counters: Arc<DashMap<String, Arc<AtomicI64>>>,
    /// Per-session compaction handlers for active agent sessions.
    /// Registered when an agent starts, removed when it ends.
    compaction_handlers: Arc<DashMap<String, Arc<CompactionHandler>>>,
}

impl Orchestrator {
    /// Create a new orchestrator.
    pub fn new(session_manager: Arc<SessionManager>) -> Self {
        Self {
            session_manager,
            broadcast: Arc::new(EventEmitter::new()),
            run_registry: Arc::new(RunRegistry::new()),
            tool_tracker: Mutex::new(ToolCallTracker::new()),
            turn_accumulators: Arc::new(TurnAccumulatorMap::new()),
            sequence_counters: Arc::new(DashMap::new()),
            compaction_handlers: Arc::new(DashMap::new()),
        }
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
        let _ = self.sequence_counters
            .insert(session_id.to_string(), Arc::new(AtomicI64::new(start)));
        trace!(session_id, start, "sequence counter initialized");
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
    /// Called when an agent starts running so that RPC compaction
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

    /// Register a tool call, returning a receiver for the result.
    pub fn register_tool_call(
        &self,
        tool_call_id: &str,
    ) -> tokio::sync::oneshot::Receiver<serde_json::Value> {
        self.tool_tracker.lock().register(tool_call_id)
    }

    /// Resolve a pending tool call with a result. Returns true if found.
    pub fn resolve_tool_call(&self, tool_call_id: &str, value: serde_json::Value) -> bool {
        self.tool_tracker.lock().resolve(tool_call_id, value)
    }

    /// Check if a tool call is pending.
    pub fn has_pending_tool_call(&self, tool_call_id: &str) -> bool {
        self.tool_tracker.lock().has_pending(tool_call_id)
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

        // Cancel all pending tool calls
        self.tool_tracker.lock().cancel_all();

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
mod tests {
    use super::*;
    use serde_json::json;
    use crate::events::EventStore;

    fn make_orchestrator() -> Orchestrator {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store));
        Orchestrator::new(mgr)
    }

    #[test]
    fn create_orchestrator() {
        let orch = make_orchestrator();
        assert_eq!(orch.max_concurrent_sessions(), MAX_CONCURRENT_SESSIONS);
        assert_eq!(orch.active_session_count(), 0);
        assert!(orch.can_accept_session());
    }

    #[tokio::test]
    async fn create_session_through_orchestrator() {
        let orch = make_orchestrator();
        let sid = orch
            .session_manager()
            .create_session("model", "/tmp", Some("test"), None)
            .unwrap();

        assert_eq!(orch.active_session_count(), 1);
        assert!(orch.is_session_busy(&sid));
    }

    #[tokio::test]
    async fn subscribe_to_events() {
        let orch = make_orchestrator();
        let mut rx = orch.subscribe();

        let _ = orch
            .broadcast()
            .emit(crate::core::events::agent_start_event("s1"));

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "agent_start");
    }

    #[tokio::test]
    async fn max_concurrent_enforced() {
        let orch = make_orchestrator();

        for i in 0..MAX_CONCURRENT_SESSIONS {
            let _ = orch
                .session_manager()
                .create_session("model", &format!("/tmp/{i}"), None, None)
                .unwrap();
        }

        assert_eq!(orch.active_session_count(), MAX_CONCURRENT_SESSIONS);
        assert!(!orch.can_accept_session());
    }

    // --- Run tracking tests ---

    #[test]
    fn begin_run_creates_token() {
        let orch = make_orchestrator();
        let run = orch.begin_run("s1", "run_1").unwrap();
        let token = run.cancel_token();
        assert!(!token.is_cancelled());
        assert!(orch.has_active_run("s1"));
        assert_eq!(orch.active_run_count(), 1);
    }

    #[test]
    fn begin_run_rejects_busy_session() {
        let orch = make_orchestrator();
        let _run = orch.begin_run("s1", "run_1").unwrap();

        let err = orch.begin_run("s1", "run_2").unwrap_err();
        assert!(err.to_string().contains("busy"));
    }

    #[test]
    fn dropping_run_clears_active() {
        let orch = make_orchestrator();
        let run = orch.begin_run("s1", "run_1").unwrap();
        assert!(orch.has_active_run("s1"));

        drop(run);
        assert!(!orch.has_active_run("s1"));
        assert_eq!(orch.active_run_count(), 0);
    }

    #[test]
    fn get_run_id_returns_correct_id() {
        let orch = make_orchestrator();
        let _run = orch.begin_run("s1", "run_abc").unwrap();
        assert_eq!(orch.get_run_id("s1").unwrap(), "run_abc");
    }

    #[test]
    fn get_run_id_unknown_returns_none() {
        let orch = make_orchestrator();
        assert!(orch.get_run_id("unknown").is_none());
    }

    // --- Abort tests ---

    #[test]
    fn abort_active_session_returns_true() {
        let orch = make_orchestrator();
        let run = orch.begin_run("s1", "run_1").unwrap();
        let token = run.cancel_token();

        let result = orch.abort("s1").unwrap();
        assert!(result);
        assert!(token.is_cancelled());
    }

    #[test]
    fn abort_unknown_session_returns_false() {
        let orch = make_orchestrator();
        let result = orch.abort("nonexistent").unwrap();
        assert!(!result);
    }

    #[test]
    fn abort_cancels_token() {
        let orch = make_orchestrator();
        let run = orch.begin_run("s1", "run_1").unwrap();
        let token = run.cancel_token();
        assert!(!token.is_cancelled());

        let _ = orch.abort("s1").unwrap();
        assert!(token.is_cancelled());
    }

    // --- Concurrent runs ---

    #[test]
    fn concurrent_runs_different_sessions() {
        let orch = make_orchestrator();
        let _t1 = orch.begin_run("s1", "run_1").unwrap();
        let _t2 = orch.begin_run("s2", "run_2").unwrap();

        assert_eq!(orch.active_run_count(), 2);
        assert!(orch.has_active_run("s1"));
        assert!(orch.has_active_run("s2"));
    }

    #[test]
    fn abort_one_doesnt_affect_other() {
        let orch = make_orchestrator();
        let t1 = orch.begin_run("s1", "run_1").unwrap();
        let t2 = orch.begin_run("s2", "run_2").unwrap();

        let t1_token = t1.cancel_token();
        let t2_token = t2.cancel_token();

        let _ = orch.abort("s1").unwrap();
        assert!(t1_token.is_cancelled());
        assert!(!t2_token.is_cancelled());
    }

    // --- Tool call tracker tests ---

    #[tokio::test]
    async fn tool_call_register_and_resolve() {
        let orch = make_orchestrator();
        let rx = orch.register_tool_call("tc_1");

        assert!(orch.has_pending_tool_call("tc_1"));
        assert!(orch.resolve_tool_call("tc_1", json!({"result": "ok"})));
        assert!(!orch.has_pending_tool_call("tc_1"));

        let val = rx.await.unwrap();
        assert_eq!(val["result"], "ok");
    }

    #[test]
    fn tool_call_resolve_unknown_returns_false() {
        let orch = make_orchestrator();
        assert!(!orch.resolve_tool_call("unknown", json!(null)));
    }

    // --- Concurrency limit tests ---

    #[test]
    fn begin_run_rejects_at_capacity() {
        let orch = make_orchestrator();

        // Fill to capacity
        let mut runs = Vec::new();
        for i in 0..MAX_CONCURRENT_SESSIONS {
            runs.push(
                orch.begin_run(&format!("s{i}"), &format!("run_{i}"))
                    .unwrap(),
            );
        }
        assert_eq!(orch.active_run_count(), MAX_CONCURRENT_SESSIONS);

        // One past the ceiling should fail with ServerBusy
        let err = orch
            .begin_run(
                &format!("s{MAX_CONCURRENT_SESSIONS}"),
                &format!("run_{MAX_CONCURRENT_SESSIONS}"),
            )
            .unwrap_err();
        assert!(err.to_string().contains("Server busy"));
    }

    #[test]
    fn permit_released_on_drop() {
        let orch = make_orchestrator();

        // Fill to capacity
        let mut runs = Vec::new();
        for i in 0..MAX_CONCURRENT_SESSIONS {
            runs.push(
                orch.begin_run(&format!("s{i}"), &format!("run_{i}"))
                    .unwrap(),
            );
        }

        // At capacity — can't start another
        assert!(
            orch.begin_run(
                &format!("s{MAX_CONCURRENT_SESSIONS}"),
                &format!("run_{MAX_CONCURRENT_SESSIONS}"),
            )
            .is_err()
        );

        // Drop one run — frees a permit
        drop(runs.remove(0));
        assert_eq!(orch.active_run_count(), MAX_CONCURRENT_SESSIONS - 1);

        // Now we can start a new run
        let _t = orch
            .begin_run(
                &format!("s{MAX_CONCURRENT_SESSIONS}"),
                &format!("run_{MAX_CONCURRENT_SESSIONS}"),
            )
            .unwrap();
        assert_eq!(orch.active_run_count(), MAX_CONCURRENT_SESSIONS);
    }

    // --- Shutdown ---

    #[tokio::test]
    async fn shutdown_cancels_all_runs() {
        let orch = make_orchestrator();
        let t1 = orch.begin_run("s1", "run_1").unwrap();
        let t2 = orch.begin_run("s2", "run_2").unwrap();
        let t1_token = t1.cancel_token();
        let t2_token = t2.cancel_token();

        orch.shutdown().await.unwrap();
        assert!(t1_token.is_cancelled());
        assert!(t2_token.is_cancelled());
    }

    #[tokio::test]
    async fn shutdown_clears_tool_calls() {
        let orch = make_orchestrator();
        let rx = orch.register_tool_call("tc_1");

        orch.shutdown().await.unwrap();
        assert!(rx.await.is_err()); // sender was dropped
    }

    // --- is_session_busy advisory tests ---

    #[test]
    fn is_session_busy_reflects_active_run() {
        let orch = make_orchestrator();
        assert!(!orch.is_session_busy("s1"));
        let run = orch.begin_run("s1", "run_1").unwrap();
        assert!(orch.is_session_busy("s1"));
        drop(run);
        assert!(!orch.is_session_busy("s1"));
    }

    #[tokio::test]
    async fn is_session_busy_reflects_active_session() {
        let orch = make_orchestrator();
        let sid = orch
            .session_manager()
            .create_session("model", "/tmp", Some("test"), None)
            .unwrap();
        assert!(orch.is_session_busy(&sid));
    }

    // --- Sequence counter tests ---

    #[test]
    fn next_sequence_monotonic() {
        let orch = make_orchestrator();
        orch.init_sequence_counter("s1", 0);
        let seqs: Vec<i64> = (0..10).map(|_| orch.next_sequence("s1").unwrap()).collect();
        assert_eq!(seqs, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    }

    #[test]
    fn next_sequence_initializes_from_db() {
        let orch = make_orchestrator();
        orch.init_sequence_counter("s1", 5);
        assert_eq!(orch.next_sequence("s1").unwrap(), 6);
        assert_eq!(orch.next_sequence("s1").unwrap(), 7);
    }

    #[test]
    fn next_sequence_concurrent() {
        use std::sync::Arc;
        let orch = Arc::new(make_orchestrator());
        orch.init_sequence_counter("s1", 0);

        let mut handles = Vec::new();
        for _ in 0..10 {
            let orch = Arc::clone(&orch);
            handles.push(std::thread::spawn(move || orch.next_sequence("s1").unwrap()));
        }
        let mut results: Vec<i64> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        results.sort_unstable();
        assert_eq!(results, vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    }

    #[test]
    fn next_sequence_cross_session_independent() {
        let orch = make_orchestrator();
        orch.init_sequence_counter("s1", 0);
        orch.init_sequence_counter("s2", 0);
        assert_eq!(orch.next_sequence("s1").unwrap(), 1);
        assert_eq!(orch.next_sequence("s2").unwrap(), 1);
        assert_eq!(orch.next_sequence("s1").unwrap(), 2);
        assert_eq!(orch.next_sequence("s2").unwrap(), 2);
    }

    #[test]
    fn sequence_counter_cleaned_on_session_end() {
        let orch = make_orchestrator();
        orch.init_sequence_counter("s1", 0);
        assert!(orch.current_sequence("s1").is_some());
        orch.remove_sequence_counter("s1");
        assert!(orch.current_sequence("s1").is_none());
    }

    #[test]
    fn current_sequence_returns_none_for_unknown() {
        let orch = make_orchestrator();
        assert!(orch.current_sequence("unknown").is_none());
    }

    #[test]
    fn current_sequence_reads_without_increment() {
        let orch = make_orchestrator();
        orch.init_sequence_counter("s1", 0);
        let _ = orch.next_sequence("s1").unwrap();
        let _ = orch.next_sequence("s1").unwrap();
        assert_eq!(orch.current_sequence("s1"), Some(2));
        assert_eq!(orch.current_sequence("s1"), Some(2));
    }

    #[test]
    fn init_counter_simulates_server_restart() {
        // Simulates: server restarts, queries MAX(sequence) = 42 from DB, inits counter at 42
        let orch = make_orchestrator();
        orch.init_sequence_counter("s1", 42);
        // Next sequence should be 43, not 1
        assert_eq!(orch.next_sequence("s1").unwrap(), 43);
        assert_eq!(orch.next_sequence("s1").unwrap(), 44);
    }

    #[test]
    fn reinit_counter_resets_to_new_start() {
        // Simulates: counter existed, then session is re-initialized
        let orch = make_orchestrator();
        orch.init_sequence_counter("s1", 0);
        assert_eq!(orch.next_sequence("s1").unwrap(), 1);
        assert_eq!(orch.next_sequence("s1").unwrap(), 2);

        // Re-init to a higher value (e.g., after DB sync)
        orch.init_sequence_counter("s1", 100);
        assert_eq!(orch.next_sequence("s1").unwrap(), 101);
    }

    #[test]
    fn next_sequence_returns_error_when_not_initialized() {
        let orch = make_orchestrator();
        let result = orch.next_sequence("nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn next_sequence_error_contains_session_id() {
        let orch = make_orchestrator();
        let err = orch.next_sequence("sess_abc123").unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("sess_abc123"),
            "error should contain session id: {msg}"
        );
    }

    // --- Orphaned run cleanup ---

    #[tokio::test]
    async fn shutdown_clears_orphaned_runs() {
        let orch = make_orchestrator();
        let t1 = orch.begin_run("s1", "run_1").unwrap();
        let t2 = orch.begin_run("s2", "run_2").unwrap();
        let t1_token = t1.cancel_token();
        let t2_token = t2.cancel_token();
        assert_eq!(orch.active_run_count(), 2);

        orch.shutdown().await.unwrap();
        assert!(t1_token.is_cancelled());
        assert!(t2_token.is_cancelled());
        assert_eq!(
            orch.active_run_count(),
            0,
            "active_runs must be cleared after shutdown"
        );
    }
}
