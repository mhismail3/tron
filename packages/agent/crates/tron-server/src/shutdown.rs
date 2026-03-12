//! Graceful shutdown coordination via `CancellationToken`.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use parking_lot::Mutex;
use tokio::sync::Notify;
use tokio::task::{AbortHandle, JoinHandle};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Default timeout for graceful shutdown before force-exiting.
const DEFAULT_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(30);

struct TaskRegistry {
    closed: AtomicBool,
    next_task_id: AtomicU64,
    task_count: AtomicUsize,
    abort_handles: Mutex<HashMap<u64, AbortHandle>>,
    drained: Notify,
}

impl TaskRegistry {
    fn new() -> Self {
        Self {
            closed: AtomicBool::new(false),
            next_task_id: AtomicU64::new(1),
            task_count: AtomicUsize::new(0),
            abort_handles: Mutex::new(HashMap::new()),
            drained: Notify::new(),
        }
    }

    fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
    }

    fn tracked_count(&self) -> usize {
        self.task_count.load(Ordering::SeqCst)
    }

    fn finish(&self, task_id: u64) {
        let removed = self.abort_handles.lock().remove(&task_id).is_some();
        if removed {
            let remaining = self.task_count.fetch_sub(1, Ordering::SeqCst) - 1;
            if remaining == 0 {
                self.drained.notify_waiters();
            }
        }
    }

    fn abort_all(&self) {
        let handles: Vec<_> = self.abort_handles.lock().values().cloned().collect();
        for handle in handles {
            handle.abort();
        }
    }

    async fn wait_for_empty(&self) {
        while self.tracked_count() > 0 {
            self.drained.notified().await;
        }
    }
}

/// Coordinates graceful shutdown across all server tasks.
pub struct ShutdownCoordinator {
    token: CancellationToken,
    registry: Arc<TaskRegistry>,
}

impl ShutdownCoordinator {
    /// Create a new shutdown coordinator.
    pub fn new() -> Self {
        Self {
            token: CancellationToken::new(),
            registry: Arc::new(TaskRegistry::new()),
        }
    }

    /// Register a background task handle for graceful shutdown.
    ///
    /// Completed tasks self-prune automatically. If shutdown has already begun,
    /// the task is aborted immediately instead of being retained.
    pub fn register_task(&self, handle: JoinHandle<()>) {
        if self.registry.is_closed() {
            handle.abort();
            return;
        }

        let task_id = self.registry.next_task_id.fetch_add(1, Ordering::Relaxed);
        let abort_handle = handle.abort_handle();
        let _ = self.registry.task_count.fetch_add(1, Ordering::SeqCst);
        let _ = self
            .registry
            .abort_handles
            .lock()
            .insert(task_id, abort_handle);

        let registry = Arc::clone(&self.registry);
        drop(tokio::spawn(async move {
            let _ = handle.await;
            registry.finish(task_id);
        }));
    }

    /// Get a clone of the cancellation token.
    pub fn token(&self) -> CancellationToken {
        self.token.clone()
    }

    /// Stop accepting new tasks and signal shutdown to listeners.
    pub fn close(&self) {
        self.registry.close();
        self.token.cancel();
    }

    /// Initiate shutdown.
    pub fn shutdown(&self) {
        self.close();
    }

    /// Whether a shutdown has been initiated.
    pub fn is_shutting_down(&self) -> bool {
        self.token.is_cancelled()
    }

    /// Number of still-running tracked background tasks.
    pub fn tracked_task_count(&self) -> usize {
        self.registry.tracked_count()
    }

    /// Perform a graceful shutdown of all tracked tasks.
    ///
    /// 1. Cancel the shutdown token (signals all tasks)
    /// 2. Register any explicit handles with the tracker
    /// 3. Wait up to `timeout` for all handles to complete
    /// 3. Abort any remaining tasks after timeout
    pub async fn graceful_shutdown(&self, handles: Vec<JoinHandle<()>>, timeout: Option<Duration>) {
        let timeout = timeout.unwrap_or(DEFAULT_SHUTDOWN_TIMEOUT);

        for handle in handles {
            self.register_task(handle);
        }

        self.close();

        info!(
            task_count = self.tracked_task_count(),
            timeout_secs = timeout.as_secs(),
            "waiting for tasks to complete"
        );

        if tokio::time::timeout(timeout, self.registry.wait_for_empty())
            .await
            .is_ok()
        {
            info!("all shutdown tasks completed");
        } else {
            warn!(
                timeout_secs = timeout.as_secs(),
                "shutdown timed out, aborting remaining tasks"
            );
            self.registry.abort_all();
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
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

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
        assert!(
            !completed.load(Ordering::SeqCst),
            "task should have been aborted, not completed"
        );
    }

    #[tokio::test]
    async fn shutdown_completes_fast_tasks_normally() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

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

        assert!(
            completed.load(Ordering::SeqCst),
            "fast task should complete normally"
        );
    }

    #[tokio::test]
    async fn registered_tasks_included_in_shutdown() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

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

        assert!(
            completed.load(Ordering::SeqCst),
            "registered task should complete during shutdown"
        );
    }

    #[tokio::test]
    async fn completed_tasks_self_prune() {
        let coord = ShutdownCoordinator::new();
        coord.register_task(tokio::spawn(async {}));
        coord.register_task(tokio::spawn(async {}));

        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(coord.tracked_task_count(), 0);
    }

    #[tokio::test]
    async fn register_after_close_aborts_task() {
        let coord = ShutdownCoordinator::new();
        coord.close();

        let handle = tokio::spawn(async {
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        let abort = handle.abort_handle();
        coord.register_task(handle);

        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(abort.is_finished());
    }
}
