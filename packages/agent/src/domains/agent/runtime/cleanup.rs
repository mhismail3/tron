//! Prompt run cleanup and cancellation guards.

use std::sync::Arc;

use crate::domains::agent::runner::orchestrator::orchestrator::StartedRun;

pub(super) struct PromptRunCleanup {
    session_manager:
        Arc<crate::domains::agent::runner::orchestrator::session_manager::SessionManager>,
    session_id: String,
    started_run: Option<StartedRun>,
}

impl PromptRunCleanup {
    pub(super) fn new(
        started_run: StartedRun,
        session_manager: Arc<
            crate::domains::agent::runner::orchestrator::session_manager::SessionManager,
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
        self.session_manager.clear_processing(&self.session_id);
        self.session_manager.invalidate_session(&self.session_id);
        let _ = self.started_run.take();
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
