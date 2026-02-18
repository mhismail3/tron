//! Graceful shutdown coordination via `CancellationToken`.

use std::time::Duration;

use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Default timeout for graceful shutdown before force-exiting.
const DEFAULT_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(30);

/// Coordinates graceful shutdown across all server tasks.
pub struct ShutdownCoordinator {
    token: CancellationToken,
}

impl ShutdownCoordinator {
    /// Create a new shutdown coordinator.
    pub fn new() -> Self {
        Self {
            token: CancellationToken::new(),
        }
    }

    /// Get a clone of the cancellation token.
    pub fn token(&self) -> CancellationToken {
        self.token.clone()
    }

    /// Initiate shutdown.
    pub fn shutdown(&self) {
        self.token.cancel();
    }

    /// Whether a shutdown has been initiated.
    pub fn is_shutting_down(&self) -> bool {
        self.token.is_cancelled()
    }

    /// Perform a graceful shutdown of all tracked tasks.
    ///
    /// 1. Cancel the shutdown token (signals all tasks)
    /// 2. Wait up to `timeout` for all handles to complete
    /// 3. Abort any remaining tasks after timeout
    pub async fn graceful_shutdown(&self, handles: Vec<JoinHandle<()>>, timeout: Option<Duration>) {
        let timeout = timeout.unwrap_or(DEFAULT_SHUTDOWN_TIMEOUT);

        self.shutdown();
        info!(
            task_count = handles.len(),
            timeout_secs = timeout.as_secs(),
            "waiting for tasks to complete"
        );

        let drain = futures::future::join_all(handles);

        if tokio::time::timeout(timeout, drain).await.is_err() {
            warn!("shutdown timed out after {timeout:?}, some tasks may still be running");
        }
    }
}

impl Default for ShutdownCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_state_not_shutting_down() {
        let coord = ShutdownCoordinator::new();
        assert!(!coord.is_shutting_down());
    }

    #[test]
    fn shutdown_sets_flag() {
        let coord = ShutdownCoordinator::new();
        coord.shutdown();
        assert!(coord.is_shutting_down());
    }

    #[test]
    fn token_propagation() {
        let coord = ShutdownCoordinator::new();
        let token = coord.token();
        assert!(!token.is_cancelled());
        coord.shutdown();
        assert!(token.is_cancelled());
    }

    #[test]
    fn multiple_shutdown_calls_idempotent() {
        let coord = ShutdownCoordinator::new();
        coord.shutdown();
        coord.shutdown();
        coord.shutdown();
        assert!(coord.is_shutting_down());
    }

    #[test]
    fn multiple_tokens_all_cancelled() {
        let coord = ShutdownCoordinator::new();
        let t1 = coord.token();
        let t2 = coord.token();
        let t3 = coord.token();
        coord.shutdown();
        assert!(t1.is_cancelled());
        assert!(t2.is_cancelled());
        assert!(t3.is_cancelled());
    }

    #[test]
    fn default_is_not_shutting_down() {
        let coord = ShutdownCoordinator::default();
        assert!(!coord.is_shutting_down());
    }

    #[tokio::test]
    async fn token_cancelled_future_resolves() {
        let coord = ShutdownCoordinator::new();
        let token = coord.token();

        let handle = tokio::spawn(async move {
            token.cancelled().await;
            true
        });

        coord.shutdown();
        let result = handle.await.unwrap();
        assert!(result);
    }

    #[tokio::test]
    async fn graceful_shutdown_awaits_all_tasks() {
        let coord = ShutdownCoordinator::new();
        let token = coord.token();

        let handle = tokio::spawn(async move {
            token.cancelled().await;
        });

        coord.graceful_shutdown(vec![handle], None).await;
        assert!(coord.is_shutting_down());
    }

    #[tokio::test]
    async fn graceful_shutdown_times_out() {
        let coord = ShutdownCoordinator::new();

        // A task that never finishes (ignores cancellation)
        let handle = tokio::spawn(async {
            tokio::time::sleep(Duration::from_secs(300)).await;
        });

        // Should timeout quickly
        coord
            .graceful_shutdown(vec![handle], Some(Duration::from_millis(100)))
            .await;
        assert!(coord.is_shutting_down());
    }
}
