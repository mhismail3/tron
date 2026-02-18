//! Graceful shutdown coordination via `CancellationToken`.

use std::time::Duration;

use parking_lot::Mutex;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Default timeout for graceful shutdown before force-exiting.
const DEFAULT_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(30);

/// Coordinates graceful shutdown across all server tasks.
pub struct ShutdownCoordinator {
    token: CancellationToken,
    /// Dynamically registered background task handles (e.g. agent runs).
    task_handles: Mutex<Vec<JoinHandle<()>>>,
}

impl ShutdownCoordinator {
    /// Create a new shutdown coordinator.
    pub fn new() -> Self {
        Self {
            token: CancellationToken::new(),
            task_handles: Mutex::new(Vec::new()),
        }
    }

    /// Register a background task handle for graceful shutdown.
    pub fn register_task(&self, handle: JoinHandle<()>) {
        self.task_handles.lock().push(handle);
    }

    /// Take all registered task handles (drains the list).
    pub fn take_tasks(&self) -> Vec<JoinHandle<()>> {
        std::mem::take(&mut *self.task_handles.lock())
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

        // Merge explicitly passed handles with dynamically registered ones
        let mut all_handles = handles;
        all_handles.extend(self.take_tasks());

        info!(
            task_count = all_handles.len(),
            timeout_secs = timeout.as_secs(),
            "waiting for tasks to complete"
        );

        // Collect abort handles before consuming into join_all
        let abort_handles: Vec<_> = all_handles.iter().map(|h| h.abort_handle()).collect();

        match tokio::time::timeout(timeout, futures::future::join_all(all_handles)).await {
            Ok(_) => {
                info!("all shutdown tasks completed");
            }
            Err(_) => {
                warn!(
                    timeout_secs = timeout.as_secs(),
                    "shutdown timed out, aborting remaining tasks"
                );
                for handle in &abort_handles {
                    handle.abort();
                }
            }
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

    #[tokio::test]
    async fn shutdown_aborts_slow_tasks() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let coord = ShutdownCoordinator::new();
        let completed = Arc::new(AtomicBool::new(false));
        let completed_clone = Arc::clone(&completed);

        // Task that ignores cancellation and sleeps 60s
        let handle = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(60)).await;
            completed_clone.store(true, Ordering::SeqCst);
        });

        coord
            .graceful_shutdown(vec![handle], Some(Duration::from_millis(100)))
            .await;

        // Give a small window for any post-abort activity
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!completed.load(Ordering::SeqCst), "task should have been aborted, not completed");
    }

    #[tokio::test]
    async fn shutdown_completes_fast_tasks_normally() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let coord = ShutdownCoordinator::new();
        let completed = Arc::new(AtomicBool::new(false));
        let completed_clone = Arc::clone(&completed);
        let token = coord.token();

        let handle = tokio::spawn(async move {
            token.cancelled().await;
            tokio::time::sleep(Duration::from_millis(10)).await;
            completed_clone.store(true, Ordering::SeqCst);
        });

        coord
            .graceful_shutdown(vec![handle], Some(Duration::from_secs(5)))
            .await;

        assert!(completed.load(Ordering::SeqCst), "fast task should complete normally");
    }

    #[tokio::test]
    async fn registered_tasks_included_in_shutdown() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let coord = ShutdownCoordinator::new();
        let completed = Arc::new(AtomicBool::new(false));
        let completed_clone = Arc::clone(&completed);
        let token = coord.token();

        // Register a task dynamically (like agent.prompt does)
        let handle = tokio::spawn(async move {
            token.cancelled().await;
            completed_clone.store(true, Ordering::SeqCst);
        });
        coord.register_task(handle);

        // Pass no explicit handles — registered tasks should still be awaited
        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        assert!(completed.load(Ordering::SeqCst), "registered task should complete during shutdown");
    }

    #[tokio::test]
    async fn take_tasks_drains_registry() {
        let coord = ShutdownCoordinator::new();
        let h1 = tokio::spawn(async {});
        let h2 = tokio::spawn(async {});
        coord.register_task(h1);
        coord.register_task(h2);

        let taken = coord.take_tasks();
        assert_eq!(taken.len(), 2);
        assert!(coord.take_tasks().is_empty(), "second take should be empty");
    }
}
