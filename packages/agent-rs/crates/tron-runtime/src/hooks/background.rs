//! Background hook task tracker.
//!
//! Tracks fire-and-forget hook executions spawned via `tokio::spawn`.
//! Provides [`drain_all`](BackgroundTracker::drain_all) to wait for all
//! pending background tasks to complete (used at session boundaries).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use tokio::sync::Mutex;
use tokio::task::JoinSet;
use tracing::warn;

/// Tracks background hook task handles for eventual draining.
///
/// Background hooks are spawned as fire-and-forget tasks but tracked so they
/// can be awaited at session boundaries (e.g., before session end or before
/// a new user prompt).
pub struct BackgroundTracker {
    /// Tracked tasks.
    tasks: Arc<Mutex<JoinSet<()>>>,
    /// Approximate count of pending tasks (atomic for lock-free reads).
    pending: Arc<AtomicUsize>,
}

impl BackgroundTracker {
    /// Create a new empty background tracker.
    #[must_use]
    pub fn new() -> Self {
        Self {
            tasks: Arc::new(Mutex::new(JoinSet::new())),
            pending: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Spawn a future as a tracked background task.
    pub fn spawn<F>(&self, future: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        let pending = Arc::clone(&self.pending);
        let _ = pending.fetch_add(1, Ordering::Relaxed);

        let tasks = Arc::clone(&self.tasks);
        drop(tokio::spawn(async move {
            let mut guard = tasks.lock().await;
            let _ = guard.spawn(async move {
                future.await;
                let _ = pending.fetch_sub(1, Ordering::Relaxed);
            });
        }));
    }

    /// Wait for all tracked background tasks to complete.
    ///
    /// Errors in individual tasks are logged and swallowed (fail-open).
    pub async fn drain_all(&self) {
        let mut tasks = self.tasks.lock().await;
        while let Some(result) = tasks.join_next().await {
            if let Err(e) = result {
                warn!(error = %e, "Background hook task panicked");
            }
        }
    }

    /// Wait for all tracked background tasks to complete, with a timeout.
    ///
    /// Returns `true` if all tasks completed, `false` if the timeout was reached.
    pub async fn drain_with_timeout(&self, timeout: std::time::Duration) -> bool {
        tokio::time::timeout(timeout, self.drain_all())
            .await
            .is_ok()
    }

    /// Get the approximate number of pending background tasks.
    #[must_use]
    pub fn pending_count(&self) -> usize {
        self.pending.load(Ordering::Relaxed)
    }
}

impl Default for BackgroundTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for BackgroundTracker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BackgroundTracker")
            .field("pending_count", &self.pending_count())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;
    use tokio::time::Duration;

    #[tokio::test]
    async fn test_new_tracker_empty() {
        let tracker = BackgroundTracker::new();
        assert_eq!(tracker.pending_count(), 0);
    }

    #[tokio::test]
    async fn test_spawn_and_drain() {
        let tracker = BackgroundTracker::new();
        let completed = Arc::new(AtomicBool::new(false));
        let completed_clone = Arc::clone(&completed);

        tracker.spawn(async move {
            completed_clone.store(true, Ordering::SeqCst);
        });

        // Give the spawn a moment to register
        tokio::time::sleep(Duration::from_millis(50)).await;

        tracker.drain_all().await;
        assert!(completed.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn test_spawn_multiple_and_drain() {
        let tracker = BackgroundTracker::new();
        let counter = Arc::new(AtomicUsize::new(0));

        for _ in 0..5 {
            let counter_clone = Arc::clone(&counter);
            tracker.spawn(async move {
                let _ = counter_clone.fetch_add(1, Ordering::SeqCst);
            });
        }

        // Give spawns a moment
        tokio::time::sleep(Duration::from_millis(100)).await;

        tracker.drain_all().await;
        assert_eq!(counter.load(Ordering::SeqCst), 5);
    }

    #[tokio::test]
    async fn test_drain_empty_immediate() {
        let tracker = BackgroundTracker::new();
        // Should return immediately
        tracker.drain_all().await;
    }

    #[tokio::test]
    async fn test_pending_count_decrements() {
        let tracker = BackgroundTracker::new();
        let barrier = Arc::new(tokio::sync::Notify::new());
        let barrier_clone = Arc::clone(&barrier);

        tracker.spawn(async move {
            barrier_clone.notified().await;
        });

        // Let it register
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Should be pending
        assert!(tracker.pending_count() >= 1);

        // Release the task
        barrier.notify_one();

        // Wait for completion
        tokio::time::sleep(Duration::from_millis(50)).await;
        tracker.drain_all().await;

        assert_eq!(tracker.pending_count(), 0);
    }

    #[tokio::test]
    async fn test_drain_with_timeout_success() {
        let tracker = BackgroundTracker::new();
        tracker.spawn(async {
            tokio::time::sleep(Duration::from_millis(10)).await;
        });

        // Give spawn time to register
        tokio::time::sleep(Duration::from_millis(50)).await;

        let completed = tracker.drain_with_timeout(Duration::from_secs(1)).await;
        assert!(completed);
    }

    #[tokio::test]
    async fn test_drain_with_timeout_expired() {
        let tracker = BackgroundTracker::new();
        tracker.spawn(async {
            tokio::time::sleep(Duration::from_secs(10)).await;
        });

        // Give spawn time to register
        tokio::time::sleep(Duration::from_millis(50)).await;

        let completed = tracker.drain_with_timeout(Duration::from_millis(10)).await;
        assert!(!completed);
    }

    #[tokio::test]
    async fn test_debug_impl() {
        let tracker = BackgroundTracker::new();
        let debug = format!("{tracker:?}");
        assert!(debug.contains("BackgroundTracker"));
        assert!(debug.contains("pending_count"));
    }
}
