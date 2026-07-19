//! Prompt run cleanup and cancellation guards.

use std::sync::Arc;

use crate::domains::agent::r#loop::orchestrator::core::StartedRun;

pub(super) struct PromptRunCleanup {
    session_manager:
        Arc<crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager>,
    session_id: String,
    started_run: Option<StartedRun>,
}

impl PromptRunCleanup {
    pub(super) fn new(
        started_run: StartedRun,
        session_manager: Arc<
            crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager,
        >,
        session_id: String,
    ) -> Self {
        Self {
            session_manager,
            session_id,
            started_run: Some(started_run),
        }
    }

    pub(super) fn cancel_token(&self) -> tokio_util::sync::CancellationToken {
        self.started_run
            .as_ref()
            .expect("started run must exist while prompt is active")
            .cancel_token()
    }

    pub(super) fn release(&mut self) {
        let _ = self.release_with_terminal(|| {});
    }

    /// Publish terminal lifecycle while the matching run still serializes
    /// same-session admission, then release the run and its cache ownership.
    pub(super) fn release_with_terminal(&mut self, terminal: impl FnOnce()) -> bool {
        // INVARIANT: invalidation and run release happen exactly once. Completion
        // calls this explicitly before publishing slow result resources, and
        // `Drop` calls it again. A second invalidation could erase a cache entry
        // already rebuilt and pinned by the next run for this session.
        if let Some(mut started_run) = self.started_run.take() {
            self.session_manager.invalidate_session(&self.session_id);
            started_run.finish_with(terminal)
        } else {
            false
        }
    }
}

impl Drop for PromptRunCleanup {
    fn drop(&mut self) {
        self.release();
    }
}

pub(super) struct ShutdownCancelForwarder(Option<tokio::task::JoinHandle<()>>);

impl ShutdownCancelForwarder {
    pub(super) fn new(
        shutdown_token: Option<tokio_util::sync::CancellationToken>,
        run_cancel: tokio_util::sync::CancellationToken,
    ) -> Self {
        let handle = shutdown_token.map(|shutdown_token| {
            tokio::spawn(async move {
                shutdown_token.cancelled().await;
                run_cancel.cancel();
            })
        });
        Self(handle)
    }
}

impl Drop for ShutdownCancelForwarder {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::agent::Orchestrator;
    use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
    use crate::domains::session::event_store::{
        ConnectionConfig, EventStore, new_in_memory, run_migrations,
    };

    fn make_session_manager() -> Arc<SessionManager> {
        let pool = new_in_memory(&ConnectionConfig::default()).expect("in-memory event store");
        {
            let connection = pool.get().expect("event-store connection");
            run_migrations(&connection).expect("event-store migrations");
        }
        Arc::new(SessionManager::new(Arc::new(EventStore::new(pool))))
    }

    #[test]
    fn explicit_release_does_not_invalidate_a_rebuilt_cache_on_drop() {
        let session_manager = make_session_manager();
        let session_id = session_manager
            .create_session("test-model", "/tmp", Some("test"))
            .expect("session");
        let orchestrator = Orchestrator::new(session_manager.clone());
        let started_run = orchestrator
            .begin_run(&session_id, "run-1")
            .expect("started run");
        let mut cleanup =
            PromptRunCleanup::new(started_run, session_manager.clone(), session_id.clone());

        cleanup.release();
        assert!(!session_manager.is_cached(&session_id));

        let _ = session_manager
            .resume_session_for_prompt(&session_id)
            .expect("rebuilt projection");
        assert!(session_manager.is_cached(&session_id));

        drop(cleanup);
        assert!(
            session_manager.is_cached(&session_id),
            "dropping an already released cleanup must preserve the next run's cache"
        );
    }
}
