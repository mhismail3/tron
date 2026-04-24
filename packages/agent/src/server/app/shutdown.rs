//! Graceful shutdown coordination via `CancellationToken`.
//!
//! Subsystems register two ways:
//!
//! 1. [`ShutdownCoordinator::register_task`] — for fire-and-forget
//!    background tasks that observe [`ShutdownCoordinator::token`] to
//!    cooperatively stop. These are drained at the end of
//!    [`ShutdownCoordinator::graceful_shutdown`].
//! 2. [`ShutdownCoordinator::register_phase_hook`] — for subsystems
//!    that need a specific async "please drain now" callback. Hooks run
//!    in [`ShutdownPhase`] order BEFORE the task drain so that, e.g.,
//!    MCP servers can send `shutdown` messages before the WebSocket
//!    server is torn down.
//!
//! The order is intentional: agent loops finish turns → tools drain →
//! MCP disconnects cleanly → cron stops scheduling → transcription
//! workers drop → DB pool closes. See [`ShutdownPhase`].

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
/// Per-hook budget so one slow subsystem can't starve the rest.
/// Shorter than `DEFAULT_SHUTDOWN_TIMEOUT`/N so the full drain still
/// finishes within the overall budget.
const PER_HOOK_TIMEOUT: Duration = Duration::from_secs(5);

/// Subsystem categories that run as async shutdown hooks, in strict
/// declaration order (lower variant runs first).
///
/// The order matters:
/// - [`Agent`](ShutdownPhase::Agent) drains in-flight turns first so
///   tools they own finish naturally.
/// - [`Tools`](ShutdownPhase::Tools) then cancels anything still running
///   (e.g. long bash commands that ignored turn cancel).
/// - [`Mcp`](ShutdownPhase::Mcp) disconnects external MCP servers BEFORE
///   we stop accepting RPCs that would call them.
/// - [`Cron`](ShutdownPhase::Cron) stops scheduling new runs.
/// - [`Transcription`](ShutdownPhase::Transcription) reaps sidecar
///   processes last, after any tool that might produce audio has drained.
/// - [`Database`](ShutdownPhase::Database) flushes pending writes last.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ShutdownPhase {
    /// Agent turn loops — drain in-flight turns before any tool dies.
    Agent = 0,
    /// Tool executors (bash, webfetch, subagents) that outlive their turn.
    Tools = 1,
    /// MCP stdio/SSE clients — disconnect cleanly before the transport stops.
    Mcp = 2,
    /// Cron scheduler — stop enqueuing new runs; in-flight runs drain via tasks.
    Cron = 3,
    /// Transcription sidecar workers (MLX, etc.).
    Transcription = 4,
    /// Database pool — flushed last so all preceding phases can still write.
    Database = 5,
}

impl ShutdownPhase {
    fn as_str(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::Tools => "tools",
            Self::Mcp => "mcp",
            Self::Cron => "cron",
            Self::Transcription => "transcription",
            Self::Database => "database",
        }
    }
}

/// One registered shutdown hook. The factory produces the future lazily
/// so the hook's side-effects don't start until `graceful_shutdown` calls it.
struct PhaseHook {
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
        while self.tracked_count() > 0 {
            self.drained.notified().await;
        }
    }
}

/// Coordinates graceful shutdown across all server tasks.
pub struct ShutdownCoordinator {
    token: CancellationToken,
    registry: Arc<TaskRegistry>,
    hooks: Mutex<Vec<PhaseHook>>,
}

impl ShutdownCoordinator {
    /// Create a new shutdown coordinator.
    pub fn new() -> Self {
        Self {
            token: CancellationToken::new(),
            registry: Arc::new(TaskRegistry::new()),
            hooks: Mutex::new(Vec::new()),
        }
    }

    /// Register an async hook that runs during graceful shutdown.
    ///
    /// Hooks run in [`ShutdownPhase`] order (lower variant first) BEFORE
    /// the task-drain step, each with a `PER_HOOK_TIMEOUT` budget. Use
    /// this for subsystems that need an explicit "stop" call — e.g.
    /// MCP's `router.shutdown_all()` — rather than the generic
    /// token-observation pattern of [`register_task`](Self::register_task).
    ///
    /// The factory runs lazily (on `graceful_shutdown`), so side-effects
    /// don't begin at registration time.
    pub fn register_phase_hook<F, Fut>(&self, phase: ShutdownPhase, name: &'static str, factory: F)
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send + 'static,
    {
        self.hooks.lock().push(PhaseHook {
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
        if self.registry.is_closed() {
            counter!("shutdown_tasks_rejected_total").increment(1);
            handle.abort();
            return;
        }

        let task_id = self.registry.next_task_id.fetch_add(1, Ordering::Relaxed);
        let abort_handle = handle.abort_handle();
        let count = self.registry.task_count.fetch_add(1, Ordering::SeqCst) + 1;
        gauge!("shutdown_tracked_tasks").set(count as f64);
        counter!("shutdown_tasks_registered_total").increment(1);
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

    /// Perform a graceful shutdown of all tracked tasks and registered hooks.
    ///
    /// 1. Cancel the shutdown token (signals all tasks)
    /// 2. Register any explicit handles with the tracker
    /// 3. Run phase hooks in [`ShutdownPhase`] order, each with `PER_HOOK_TIMEOUT`
    /// 4. Wait up to `timeout` for all handles to complete
    /// 5. Abort any remaining tasks after timeout
    pub async fn graceful_shutdown(&self, handles: Vec<JoinHandle<()>>, timeout: Option<Duration>) {
        let timeout = timeout.unwrap_or(DEFAULT_SHUTDOWN_TIMEOUT);
        let start = std::time::Instant::now();

        for handle in handles {
            self.register_task(handle);
        }

        self.close();

        self.run_phase_hooks().await;

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

    /// Drain registered phase hooks in phase order, isolating failures.
    ///
    /// Each hook is:
    /// - bounded by `PER_HOOK_TIMEOUT` so one slow subsystem can't block the rest
    /// - spawned on its own task so a panic terminates that task, not the coordinator
    /// - logged with outcome (`completed` / `timed_out` / `panicked`)
    async fn run_phase_hooks(&self) {
        let mut hooks: Vec<PhaseHook> = std::mem::take(&mut self.hooks.lock());
        if hooks.is_empty() {
            return;
        }

        hooks.sort_by_key(|h| h.phase);

        for hook in hooks {
            let PhaseHook {
                phase,
                name,
                factory,
            } = hook;
            let phase_str = phase.as_str();
            let start = std::time::Instant::now();

            let join = tokio::spawn(async move {
                factory().await;
            });

            match tokio::time::timeout(PER_HOOK_TIMEOUT, join).await {
                Ok(Ok(())) => {
                    histogram!("shutdown_hook_seconds", "phase" => phase_str, "name" => name, "outcome" => "completed")
                        .record(start.elapsed().as_secs_f64());
                    info!(phase = phase_str, name = name, "shutdown hook completed");
                }
                Ok(Err(join_err)) => {
                    counter!("shutdown_hook_panics_total", "phase" => phase_str, "name" => name)
                        .increment(1);
                    warn!(
                        phase = phase_str,
                        name = name,
                        error = %join_err,
                        "shutdown hook panicked or was cancelled"
                    );
                }
                Err(_) => {
                    counter!("shutdown_hook_timeouts_total", "phase" => phase_str, "name" => name)
                        .increment(1);
                    warn!(
                        phase = phase_str,
                        name = name,
                        timeout_secs = PER_HOOK_TIMEOUT.as_secs(),
                        "shutdown hook timed out"
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
    async fn phase_hooks_run_in_declared_order() {
        let coord = ShutdownCoordinator::new();
        let order: Arc<Mutex<Vec<&'static str>>> = Arc::new(Mutex::new(Vec::new()));

        // Register out-of-order to prove sorting, not registration order, wins.
        for (phase, name) in [
            (ShutdownPhase::Database, "database"),
            (ShutdownPhase::Agent, "agent"),
            (ShutdownPhase::Mcp, "mcp"),
            (ShutdownPhase::Cron, "cron"),
            (ShutdownPhase::Transcription, "transcription"),
            (ShutdownPhase::Tools, "tools"),
        ] {
            let order = Arc::clone(&order);
            coord.register_phase_hook(phase, name, move || async move {
                order.lock().push(name);
            });
        }

        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        let observed = order.lock().clone();
        assert_eq!(
            observed,
            vec!["agent", "tools", "mcp", "cron", "transcription", "database"]
        );
    }

    #[tokio::test]
    async fn phase_hook_panic_isolated_others_continue() {
        let coord = ShutdownCoordinator::new();
        let ran_after: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let ran_after_clone = Arc::clone(&ran_after);

        coord.register_phase_hook(ShutdownPhase::Agent, "bad", move || async move {
            panic!("intentional test panic");
        });
        coord.register_phase_hook(ShutdownPhase::Tools, "good", move || async move {
            ran_after_clone.store(true, Ordering::SeqCst);
        });

        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        assert!(
            ran_after.load(Ordering::SeqCst),
            "later hook must run even when earlier hook panics"
        );
    }

    #[tokio::test]
    async fn phase_hook_timeout_does_not_block_others() {
        let coord = ShutdownCoordinator::new();
        let ran_after: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let ran_after_clone = Arc::clone(&ran_after);

        // Hangs past PER_HOOK_TIMEOUT (5s) — must be force-completed.
        coord.register_phase_hook(ShutdownPhase::Agent, "slow", move || async move {
            tokio::time::sleep(Duration::from_secs(60)).await;
        });
        coord.register_phase_hook(ShutdownPhase::Tools, "fast", move || async move {
            ran_after_clone.store(true, Ordering::SeqCst);
        });

        let start = std::time::Instant::now();
        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(30)))
            .await;
        let elapsed = start.elapsed();

        assert!(
            ran_after.load(Ordering::SeqCst),
            "hook after the hanging one must still run"
        );
        assert!(
            elapsed < Duration::from_secs(10),
            "timed-out hook must not block further than its own budget; elapsed={:?}",
            elapsed
        );
    }

    #[tokio::test]
    async fn graceful_shutdown_waits_for_slow_hook_to_finish() {
        // INVARIANT: graceful_shutdown must not return until every registered
        // phase hook has either completed or been cut by PER_HOOK_TIMEOUT.
        // This is the load-bearing guarantee callers rely on.
        let coord = ShutdownCoordinator::new();
        let hook_ran = Arc::new(AtomicBool::new(false));
        let hook_ran_clone = Arc::clone(&hook_ran);

        coord.register_phase_hook(ShutdownPhase::Agent, "slow", move || async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            hook_ran_clone.store(true, Ordering::SeqCst);
        });

        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        assert!(
            hook_ran.load(Ordering::SeqCst),
            "graceful_shutdown must await hook completion before returning"
        );
    }

    #[tokio::test]
    async fn graceful_shutdown_runs_every_registered_phase_hook() {
        let coord = ShutdownCoordinator::new();
        let count = Arc::new(std::sync::atomic::AtomicUsize::new(0));

        for phase in [
            ShutdownPhase::Agent,
            ShutdownPhase::Tools,
            ShutdownPhase::Mcp,
            ShutdownPhase::Cron,
            ShutdownPhase::Transcription,
            ShutdownPhase::Database,
        ] {
            let count = Arc::clone(&count);
            coord.register_phase_hook(phase, "sub", move || async move {
                let _ = count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            });
        }

        coord
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 6);
    }

    #[test]
    fn phase_ordering_is_total() {
        // Lock in the declared phase order; any reordering requires an
        // explicit change to this test + the module docs.
        assert!(ShutdownPhase::Agent < ShutdownPhase::Tools);
        assert!(ShutdownPhase::Tools < ShutdownPhase::Mcp);
        assert!(ShutdownPhase::Mcp < ShutdownPhase::Cron);
        assert!(ShutdownPhase::Cron < ShutdownPhase::Transcription);
        assert!(ShutdownPhase::Transcription < ShutdownPhase::Database);
    }
}
