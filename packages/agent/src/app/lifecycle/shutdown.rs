//! Graceful shutdown coordination via `CancellationToken`.
//!
//! Subsystems register two ways:
//!
//! 1. [`ShutdownCoordinator::register_task`] — for background tasks whose
//!    completion shutdown must own. Long-lived tasks observe
//!    [`ShutdownCoordinator::token`] to cooperatively stop; finite tasks may
//!    simply complete. All are drained at the end of
//!    [`ShutdownCoordinator::graceful_shutdown`].
//! 2. [`ShutdownCoordinator::register_phase_callback`] — for subsystems
//!    that need a specific async "please drain now" callback. Callbacks run
//!    in [`ShutdownPhase`] order BEFORE the task drain so that, e.g.,
//!    tool blocking work can drain before the database pool closes.
//!
//! The order is intentional: the orchestrator cancels accepted agent runs ->
//! tools drain -> DB pool closes. See [`ShutdownPhase`].
//!
//! INVARIANT: task registration and registry closure are one atomic decision.
//! Once closure wins, new handles are aborted; once registration wins, shutdown
//! observes and drains that handle. Drain waiters register before inspecting
//! the count, so fast final-task completion cannot strand any shutdown caller.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use futures::future::BoxFuture;
use metrics::{counter, gauge, histogram};
use parking_lot::Mutex;
use tokio::sync::Notify;
use tokio::task::{AbortHandle, JoinHandle};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Default timeout for graceful shutdown before force-exiting.
const DEFAULT_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(30);
const ABORT_DRAIN_TIMEOUT: Duration = Duration::from_secs(1);
/// Per-callback budget so one slow subsystem can't starve the rest.
/// Shorter than `DEFAULT_SHUTDOWN_TIMEOUT`/N so the full drain still
/// finishes within the overall budget.
const PER_CALLBACK_TIMEOUT: Duration = Duration::from_secs(5);

/// Subsystem categories that run as async shutdown callbacks, in strict
/// declaration order (lower variant runs first).
///
/// The order matters:
/// - [`Agent`](ShutdownPhase::Agent) cancels in-flight turns and closes their
///   durable session projections before lower-level drains begin.
/// - [`Tools`](ShutdownPhase::Tools) then cancels anything still running
///   (e.g. long process tools that ignored turn cancel).
/// - [`Database`](ShutdownPhase::Database) flushes pending writes last.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ShutdownPhase {
    /// Agent turn loops — drain in-flight turns before tool workers stop.
    Agent = 0,
    /// Tool executors that outlive their turn.
    Tools = 1,
    /// Database pool — flushed last so all preceding phases can still write.
    Database = 2,
}

impl ShutdownPhase {
    fn as_str(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::Tools => "tools",
            Self::Database => "database",
        }
    }
}

/// One registered shutdown callback. The factory produces the future lazily so
/// side effects do not start until `graceful_shutdown` calls it.
struct PhaseCallback {
    phase: ShutdownPhase,
    name: &'static str,
    factory: Box<dyn FnOnce() -> BoxFuture<'static, ()> + Send>,
}

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

    fn close(&self) {
        // Registration and closure share the task-map lock so shutdown cannot
        // observe an empty registry while a pre-close registration slips in.
        let _registration_gate = self.abort_handles.lock();
        self.closed.store(true, Ordering::SeqCst);
    }

    fn register(&self, abort_handle: AbortHandle) -> Option<(u64, usize)> {
        let mut abort_handles = self.abort_handles.lock();
        if self.closed.load(Ordering::SeqCst) {
            return None;
        }
        let task_id = self.next_task_id.fetch_add(1, Ordering::Relaxed);
        let count = self.task_count.fetch_add(1, Ordering::SeqCst) + 1;
        let _ = abort_handles.insert(task_id, abort_handle);
        Some((task_id, count))
    }

    fn tracked_count(&self) -> usize {
        self.task_count.load(Ordering::SeqCst)
    }

    fn finish(&self, task_id: u64) {
        let removed = self.abort_handles.lock().remove(&task_id).is_some();
        if removed {
            let remaining = self.task_count.fetch_sub(1, Ordering::SeqCst) - 1;
            gauge!("shutdown_tracked_tasks").set(remaining as f64);
            if remaining == 0 {
                self.drained.notify_waiters();
            }
        }
    }

    fn abort_all(&self) {
        let handles: Vec<_> = self.abort_handles.lock().values().cloned().collect();
        counter!("shutdown_tasks_aborted_total").increment(handles.len() as u64);
        for handle in handles {
            handle.abort();
        }
    }

    async fn wait_for_empty(&self) {
        loop {
            let notified = self.drained.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.tracked_count() == 0 {
                return;
            }
            notified.await;
        }
    }
}

/// Coordinates graceful shutdown across all server tasks.
pub struct ShutdownCoordinator {
    token: CancellationToken,
    registry: Arc<TaskRegistry>,
    callbacks: Mutex<Vec<PhaseCallback>>,
}

impl ShutdownCoordinator {
    /// Create a new shutdown coordinator.
    pub fn new() -> Self {
        Self {
            token: CancellationToken::new(),
            registry: Arc::new(TaskRegistry::new()),
            callbacks: Mutex::new(Vec::new()),
        }
    }

    /// Register an async callback that runs during graceful shutdown.
    ///
    /// Callbacks run in [`ShutdownPhase`] order (lower variant first) BEFORE
    /// the task-drain step, each with a `PER_CALLBACK_TIMEOUT` budget. Use
    /// this for subsystems that need an explicit "stop" call — e.g.
    /// draining blocking tool work — rather than the generic
    /// token-observation pattern of [`register_task`](Self::register_task).
    ///
    /// The factory runs lazily (on `graceful_shutdown`), so side-effects
    /// don't begin at registration time.
    pub fn register_phase_callback<F, Fut>(
        &self,
        phase: ShutdownPhase,
        name: &'static str,
        factory: F,
    ) where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send + 'static,
    {
        self.callbacks.lock().push(PhaseCallback {
            phase,
            name,
            factory: Box::new(move || Box::pin(factory())),
        });
    }

    /// Register a background task handle for graceful shutdown.
    ///
    /// Completed tasks self-prune automatically. If shutdown has already begun,
    /// the task is aborted immediately instead of being retained.
    pub fn register_task(&self, handle: JoinHandle<()>) {
        let abort_handle = handle.abort_handle();
        let Some((task_id, count)) = self.registry.register(abort_handle) else {
            counter!("shutdown_tasks_rejected_total").increment(1);
            handle.abort();
            return;
        };
        gauge!("shutdown_tracked_tasks").set(count as f64);
        counter!("shutdown_tasks_registered_total").increment(1);

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

    /// Perform a graceful shutdown of all tracked tasks and registered callbacks.
    ///
    /// 1. Cancel the shutdown token (signals all tasks)
    /// 2. Register any explicit handles with the tracker
    /// 3. Run phase callbacks in [`ShutdownPhase`] order, each with `PER_CALLBACK_TIMEOUT`
    /// 4. Wait up to `timeout` for all handles to complete
    /// 5. Abort any remaining tasks after timeout
    pub async fn graceful_shutdown(&self, handles: Vec<JoinHandle<()>>, timeout: Option<Duration>) {
        let timeout = timeout.unwrap_or(DEFAULT_SHUTDOWN_TIMEOUT);
        let start = std::time::Instant::now();

        for handle in handles {
            self.register_task(handle);
        }

        self.close();

        self.run_phase_callbacks().await;

        info!(
            task_count = self.tracked_task_count(),
            timeout_secs = timeout.as_secs(),
            "waiting for tasks to complete"
        );

        if tokio::time::timeout(timeout, self.registry.wait_for_empty())
            .await
            .is_ok()
        {
            histogram!("shutdown_drain_seconds", "outcome" => "completed")
                .record(start.elapsed().as_secs_f64());
            info!("all shutdown tasks completed");
        } else {
            counter!("shutdown_timeouts_total").increment(1);
            histogram!("shutdown_drain_seconds", "outcome" => "timed_out")
                .record(start.elapsed().as_secs_f64());
            warn!(
                timeout_secs = timeout.as_secs(),
                "shutdown timed out, aborting remaining tasks"
            );
            self.registry.abort_all();
            if tokio::time::timeout(ABORT_DRAIN_TIMEOUT, self.registry.wait_for_empty())
                .await
                .is_err()
            {
                warn!(
                    timeout_ms = ABORT_DRAIN_TIMEOUT.as_millis(),
                    remaining = self.tracked_task_count(),
                    "aborted tasks did not drain within the post-abort window"
                );
            }
        }
    }

    /// Drain registered phase callbacks in phase order, isolating failures.
    ///
    /// Each callback is:
    /// - bounded by `PER_CALLBACK_TIMEOUT` so one slow subsystem can't block the rest
    /// - spawned on its own task so a panic terminates that task, not the coordinator
    /// - logged with outcome (`completed` / `timed_out` / `panicked`)
    async fn run_phase_callbacks(&self) {
        let mut callbacks: Vec<PhaseCallback> = std::mem::take(&mut self.callbacks.lock());
        if callbacks.is_empty() {
            return;
        }

        callbacks.sort_by_key(|callback| callback.phase);

        for callback in callbacks {
            let PhaseCallback {
                phase,
                name,
                factory,
            } = callback;
            let phase_str = phase.as_str();
            let start = std::time::Instant::now();

            let join = tokio::spawn(async move {
                factory().await;
            });

            match tokio::time::timeout(PER_CALLBACK_TIMEOUT, join).await {
                Ok(Ok(())) => {
                    histogram!("shutdown_callback_seconds", "phase" => phase_str, "name" => name, "outcome" => "completed")
                        .record(start.elapsed().as_secs_f64());
                    info!(
                        phase = phase_str,
                        name = name,
                        "shutdown callback completed"
                    );
                }
                Ok(Err(join_err)) => {
                    counter!("shutdown_callback_panics_total", "phase" => phase_str, "name" => name)
                        .increment(1);
                    warn!(
                        phase = phase_str,
                        name = name,
                        error = %join_err,
                        "shutdown callback panicked or was cancelled"
                    );
                }
                Err(_) => {
                    counter!("shutdown_callback_timeouts_total", "phase" => phase_str, "name" => name)
                        .increment(1);
                    warn!(
                        phase = phase_str,
                        name = name,
                        timeout_secs = PER_CALLBACK_TIMEOUT.as_secs(),
                        "shutdown callback timed out"
                    );
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
        assert_eq!(coord.tracked_task_count(), 0);
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
    async fn concurrent_shutdown_waiters_observe_final_task_completion() {
        let coord = Arc::new(ShutdownCoordinator::new());
        let token = coord.token();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        coord.register_task(tokio::spawn(async move {
            token.cancelled().await;
            let _ = release_rx.await;
        }));

        let first_coord = Arc::clone(&coord);
        let first = tokio::spawn(async move {
            first_coord
                .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
                .await;
        });
        let second_coord = Arc::clone(&coord);
        let second = tokio::spawn(async move {
            second_coord
                .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
                .await;
        });

        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(!first.is_finished());
        assert!(!second.is_finished());
        release_tx.send(()).unwrap();

        tokio::time::timeout(Duration::from_secs(1), async {
            first.await.unwrap();
            second.await.unwrap();
        })
        .await
        .expect("every shutdown waiter must observe the final task completion");
        assert_eq!(coord.tracked_task_count(), 0);
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
    async fn register_task_updates_tracked_count_while_running() {
        let coord = ShutdownCoordinator::new();
        let notify = Arc::new(Notify::new());
        let notify_for_task = notify.clone();

        coord.register_task(tokio::spawn(async move {
            notify_for_task.notified().await;
        }));

        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(coord.tracked_task_count(), 1);

        notify.notify_waiters();
        tokio::time::sleep(Duration::from_millis(20)).await;
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

    #[tokio::test]
    async fn phase_callbacks_run_in_declared_order() {
        let coord = ShutdownCoordinator::new();
        let order: Arc<Mutex<Vec<&'static str>>> = Arc::new(Mutex::new(Vec::new()));

        // Register out-of-order to prove sorting, not registration order, wins.
        for (phase, name) in [
            (ShutdownPhase::Database, "database"),
            (ShutdownPhase::Agent, "agent"),
            (ShutdownPhase::Tools, "tools"),
        ] {
            let order = Arc::clone(&order);
            coord.register_phase_callback(phase, name, move || async move {
                order.lock().push(name);
            });
        }

        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        let observed = order.lock().clone();
        assert_eq!(observed, vec!["agent", "tools", "database"]);
    }

    #[tokio::test]
    async fn phase_callback_panic_isolated_others_continue() {
        let coord = ShutdownCoordinator::new();
        let ran_after: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let ran_after_clone = Arc::clone(&ran_after);

        coord.register_phase_callback(ShutdownPhase::Agent, "bad", move || async move {
            panic!("intentional test panic");
        });
        coord.register_phase_callback(ShutdownPhase::Tools, "good", move || async move {
            ran_after_clone.store(true, Ordering::SeqCst);
        });

        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        assert!(
            ran_after.load(Ordering::SeqCst),
            "later callback must run even when earlier callback panics"
        );
    }

    #[tokio::test]
    async fn phase_callback_timeout_does_not_block_others() {
        let coord = ShutdownCoordinator::new();
        let ran_after: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let ran_after_clone = Arc::clone(&ran_after);

        // Hangs past PER_CALLBACK_TIMEOUT (5s) and must be force-completed.
        coord.register_phase_callback(ShutdownPhase::Agent, "slow", move || async move {
            tokio::time::sleep(Duration::from_secs(60)).await;
        });
        coord.register_phase_callback(ShutdownPhase::Tools, "fast", move || async move {
            ran_after_clone.store(true, Ordering::SeqCst);
        });

        let start = std::time::Instant::now();
        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(30)))
            .await;
        let elapsed = start.elapsed();

        assert!(
            ran_after.load(Ordering::SeqCst),
            "callback after the hanging one must still run"
        );
        assert!(
            elapsed < Duration::from_secs(10),
            "timed-out callback must not block further than its own budget; elapsed={:?}",
            elapsed
        );
    }

    #[tokio::test]
    async fn graceful_shutdown_waits_for_slow_callback_to_finish() {
        // INVARIANT: graceful_shutdown must not return until every registered
        // phase callback has either completed or been cut by PER_CALLBACK_TIMEOUT.
        // This is the load-bearing guarantee callers rely on.
        let coord = ShutdownCoordinator::new();
        let callback_ran = Arc::new(AtomicBool::new(false));
        let callback_ran_clone = Arc::clone(&callback_ran);

        coord.register_phase_callback(ShutdownPhase::Agent, "slow", move || async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            callback_ran_clone.store(true, Ordering::SeqCst);
        });

        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        assert!(
            callback_ran.load(Ordering::SeqCst),
            "graceful_shutdown must await callback completion before returning"
        );
    }

    #[tokio::test]
    async fn graceful_shutdown_runs_every_registered_phase_callback() {
        let coord = ShutdownCoordinator::new();
        let count = Arc::new(std::sync::atomic::AtomicUsize::new(0));

        for phase in [
            ShutdownPhase::Agent,
            ShutdownPhase::Tools,
            ShutdownPhase::Database,
        ] {
            let count = Arc::clone(&count);
            coord.register_phase_callback(phase, "sub", move || async move {
                let _ = count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            });
        }

        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 3);
    }

    #[test]
    fn phase_ordering_is_total() {
        // Lock in the declared phase order; any reordering requires an
        // explicit change to this test + the module docs.
        assert!(ShutdownPhase::Agent < ShutdownPhase::Tools);
        assert!(ShutdownPhase::Tools < ShutdownPhase::Database);
    }
}
