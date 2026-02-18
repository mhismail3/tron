//! Orchestrator — multi-session coordinator.

use std::collections::HashMap;
use std::sync::Arc;

use parking_lot::Mutex;
use tokio::sync::{OwnedSemaphorePermit, Semaphore, broadcast};
use tokio_util::sync::CancellationToken;
use tron_core::events::TronEvent;

use metrics::gauge;
use tracing::{debug, info, instrument, warn};

use crate::agent::event_emitter::EventEmitter;
use crate::errors::RuntimeError;
use crate::orchestrator::session_manager::{SessionFilter, SessionManager};
use crate::orchestrator::tool_call_tracker::ToolCallTracker;

/// Tracks an active agent run within a session.
struct ActiveRun {
    run_id: String,
    cancel: CancellationToken,
    /// RAII guard — released when the run is removed from `active_runs`.
    _permit: OwnedSemaphorePermit,
}

/// Multi-session orchestrator.
pub struct Orchestrator {
    session_manager: Arc<SessionManager>,
    broadcast: Arc<EventEmitter>,
    max_concurrent_sessions: usize,
    /// Semaphore limiting total concurrent agent runs.
    run_semaphore: Arc<Semaphore>,
    /// Active runs keyed by `session_id`.
    active_runs: Mutex<HashMap<String, ActiveRun>>,
    /// Tool call tracker shared with RPC handlers.
    tool_tracker: Mutex<ToolCallTracker>,
}

impl Orchestrator {
    /// Create a new orchestrator.
    pub fn new(session_manager: Arc<SessionManager>, max_concurrent: usize) -> Self {
        Self {
            session_manager,
            broadcast: Arc::new(EventEmitter::new()),
            max_concurrent_sessions: max_concurrent,
            run_semaphore: Arc::new(Semaphore::new(max_concurrent)),
            active_runs: Mutex::new(HashMap::new()),
            tool_tracker: Mutex::new(ToolCallTracker::new()),
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

    /// Start tracking a run for a session. Returns the `CancellationToken`.
    ///
    /// Errors if:
    /// - The session already has an active run (`SessionBusy`)
    /// - The server is at max concurrent runs (`ServerBusy`)
    #[instrument(skip(self), fields(session_id, run_id))]
    pub fn start_run(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> Result<CancellationToken, RuntimeError> {
        let mut runs = self.active_runs.lock();
        if runs.contains_key(session_id) {
            return Err(RuntimeError::SessionBusy(session_id.to_string()));
        }
        // Acquire a concurrency permit (non-blocking).
        let permit = Arc::clone(&self.run_semaphore)
            .try_acquire_owned()
            .map_err(|_| RuntimeError::ServerBusy {
                current: runs.len(),
                max: self.max_concurrent_sessions,
            })?;
        let cancel = CancellationToken::new();
        let _ = runs.insert(
            session_id.to_string(),
            ActiveRun {
                run_id: run_id.to_string(),
                cancel: cancel.clone(),
                _permit: permit,
            },
        );
        #[allow(clippy::cast_precision_loss)]
        gauge!("agent_runs_active").set(runs.len() as f64);
        info!(session_id, run_id, "run started");
        Ok(cancel)
    }

    /// Complete a run for a session (removes from active tracking).
    #[instrument(skip(self), fields(session_id))]
    pub fn complete_run(&self, session_id: &str) {
        debug!(session_id, "run completed");
        let mut runs = self.active_runs.lock();
        let _ = runs.remove(session_id);
        #[allow(clippy::cast_precision_loss)]
        gauge!("agent_runs_active").set(runs.len() as f64);
    }

    /// Get the run ID for an active session (if any).
    pub fn get_run_id(&self, session_id: &str) -> Option<String> {
        self.active_runs
            .lock()
            .get(session_id)
            .map(|r| r.run_id.clone())
    }

    /// Check if a session has an active run.
    pub fn has_active_run(&self, session_id: &str) -> bool {
        self.active_runs.lock().contains_key(session_id)
    }

    /// Number of active runs.
    pub fn active_run_count(&self) -> usize {
        self.active_runs.lock().len()
    }

    /// Abort a running session by cancelling its `CancellationToken`.
    /// Returns true if the session had an active run that was cancelled.
    #[instrument(skip(self), fields(session_id))]
    pub fn abort(&self, session_id: &str) -> Result<bool, RuntimeError> {
        let runs = self.active_runs.lock();
        if let Some(run) = runs.get(session_id) {
            warn!(session_id, "abort requested");
            run.cancel.cancel();
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// Check if a session is busy (currently processing).
    pub fn is_session_busy(&self, session_id: &str) -> bool {
        self.has_active_run(session_id) || self.session_manager.is_active(session_id)
    }

    /// Active session count.
    pub fn active_session_count(&self) -> usize {
        self.session_manager.active_count()
    }

    /// Maximum concurrent session limit.
    pub fn max_concurrent_sessions(&self) -> usize {
        self.max_concurrent_sessions
    }

    /// Whether we can accept another concurrent session.
    pub fn can_accept_session(&self) -> bool {
        self.session_manager.active_count() < self.max_concurrent_sessions
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
        // Cancel all active runs
        {
            let runs = self.active_runs.lock();
            for run in runs.values() {
                run.cancel.cancel();
            }
        }

        // Cancel all pending tool calls
        self.tool_tracker.lock().cancel_all();

        // List all active sessions and end them
        let sessions = self
            .session_manager
            .list_sessions(&SessionFilter::default())
            .unwrap_or_default();

        for session in sessions {
            let _ = self.session_manager.end_session(&session.id).await;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tron_events::EventStore;

    fn make_orchestrator() -> Orchestrator {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store));
        Orchestrator::new(mgr, 10)
    }

    #[test]
    fn create_orchestrator() {
        let orch = make_orchestrator();
        assert_eq!(orch.max_concurrent_sessions(), 10);
        assert_eq!(orch.active_session_count(), 0);
        assert!(orch.can_accept_session());
    }

    #[tokio::test]
    async fn create_session_through_orchestrator() {
        let orch = make_orchestrator();
        let sid = orch
            .session_manager()
            .create_session("model", "/tmp", Some("test"))
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
            .emit(tron_core::events::agent_start_event("s1"));

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "agent_start");
    }

    #[tokio::test]
    async fn max_concurrent_enforced() {
        let orch = make_orchestrator();

        for i in 0..10 {
            let _ = orch
                .session_manager()
                .create_session("model", &format!("/tmp/{i}"), None)
                .unwrap();
        }

        assert_eq!(orch.active_session_count(), 10);
        assert!(!orch.can_accept_session());
    }

    // --- Run tracking tests ---

    #[test]
    fn start_run_creates_token() {
        let orch = make_orchestrator();
        let token = orch.start_run("s1", "run_1").unwrap();
        assert!(!token.is_cancelled());
        assert!(orch.has_active_run("s1"));
        assert_eq!(orch.active_run_count(), 1);
    }

    #[test]
    fn start_run_rejects_busy_session() {
        let orch = make_orchestrator();
        let _token = orch.start_run("s1", "run_1").unwrap();

        let err = orch.start_run("s1", "run_2").unwrap_err();
        assert!(err.to_string().contains("busy"));
    }

    #[test]
    fn complete_run_clears_active() {
        let orch = make_orchestrator();
        let _token = orch.start_run("s1", "run_1").unwrap();
        assert!(orch.has_active_run("s1"));

        orch.complete_run("s1");
        assert!(!orch.has_active_run("s1"));
        assert_eq!(orch.active_run_count(), 0);
    }

    #[test]
    fn get_run_id_returns_correct_id() {
        let orch = make_orchestrator();
        let _token = orch.start_run("s1", "run_abc").unwrap();
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
        let token = orch.start_run("s1", "run_1").unwrap();

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
        let token = orch.start_run("s1", "run_1").unwrap();
        assert!(!token.is_cancelled());

        let _ = orch.abort("s1").unwrap();
        assert!(token.is_cancelled());
    }

    // --- Concurrent runs ---

    #[test]
    fn concurrent_runs_different_sessions() {
        let orch = make_orchestrator();
        let _t1 = orch.start_run("s1", "run_1").unwrap();
        let _t2 = orch.start_run("s2", "run_2").unwrap();

        assert_eq!(orch.active_run_count(), 2);
        assert!(orch.has_active_run("s1"));
        assert!(orch.has_active_run("s2"));
    }

    #[test]
    fn abort_one_doesnt_affect_other() {
        let orch = make_orchestrator();
        let t1 = orch.start_run("s1", "run_1").unwrap();
        let t2 = orch.start_run("s2", "run_2").unwrap();

        let _ = orch.abort("s1").unwrap();
        assert!(t1.is_cancelled());
        assert!(!t2.is_cancelled());
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
    fn start_run_rejects_at_capacity() {
        let orch = make_orchestrator(); // max_concurrent = 10

        // Fill to capacity
        for i in 0..10 {
            let _t = orch
                .start_run(&format!("s{i}"), &format!("run_{i}"))
                .unwrap();
        }
        assert_eq!(orch.active_run_count(), 10);

        // 11th run should fail with ServerBusy
        let err = orch.start_run("s10", "run_10").unwrap_err();
        assert!(err.to_string().contains("Server busy"));
    }

    #[test]
    fn permit_released_on_complete() {
        let orch = make_orchestrator(); // max_concurrent = 10

        // Fill to capacity
        for i in 0..10 {
            let _t = orch
                .start_run(&format!("s{i}"), &format!("run_{i}"))
                .unwrap();
        }

        // At capacity — can't start another
        assert!(orch.start_run("s10", "run_10").is_err());

        // Complete one run — frees a permit
        orch.complete_run("s0");
        assert_eq!(orch.active_run_count(), 9);

        // Now we can start a new run
        let _t = orch.start_run("s10", "run_10").unwrap();
        assert_eq!(orch.active_run_count(), 10);
    }

    // --- Shutdown ---

    #[tokio::test]
    async fn shutdown_cancels_all_runs() {
        let orch = make_orchestrator();
        let t1 = orch.start_run("s1", "run_1").unwrap();
        let t2 = orch.start_run("s2", "run_2").unwrap();

        orch.shutdown().await.unwrap();
        assert!(t1.is_cancelled());
        assert!(t2.is_cancelled());
    }

    #[tokio::test]
    async fn shutdown_clears_tool_calls() {
        let orch = make_orchestrator();
        let rx = orch.register_tool_call("tc_1");

        orch.shutdown().await.unwrap();
        assert!(rx.await.is_err()); // sender was dropped
    }
}
