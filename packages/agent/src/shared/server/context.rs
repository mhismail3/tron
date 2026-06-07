//! Server runtime setup context and shared domain support.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU16, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::model::providers::ProviderHealthTracker;
use crate::domains::model::providers::provider::ProviderFactory;
use crate::domains::session::event_store::EventStore;
use crate::engine::EngineHostHandle;
use metrics::{counter, histogram};

use crate::app::shutdown::{ShutdownCoordinator, ShutdownPhase};
use crate::shared::server::errors::CapabilityError;

const DEFAULT_BLOCKING_CONCURRENCY: usize = 16;
const BLOCKING_SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(5);

static GLOBAL_BLOCKING_SUPERVISOR: OnceLock<Arc<BlockingTaskSupervisor>> = OnceLock::new();

/// Bounded owner for capability blocking work.
///
/// Blocking closures cannot be force-aborted once the OS thread is running, so
/// the production contract is: limit concurrency before side effects begin,
/// track active work independently of the awaiting request future, and drain
/// with a fixed budget during shutdown.
pub struct BlockingTaskSupervisor {
    semaphore: Arc<tokio::sync::Semaphore>,
    active: Arc<AtomicUsize>,
    drained: Arc<tokio::sync::Notify>,
}

impl BlockingTaskSupervisor {
    /// Build a supervisor with a fixed maximum number of concurrent blocking
    /// closures.
    pub fn new(max_concurrency: usize) -> Self {
        assert!(
            max_concurrency > 0,
            "blocking task concurrency limit must be positive"
        );
        Self {
            semaphore: Arc::new(tokio::sync::Semaphore::new(max_concurrency)),
            active: Arc::new(AtomicUsize::new(0)),
            drained: Arc::new(tokio::sync::Notify::new()),
        }
    }

    /// Number of closures currently executing on blocking threads.
    pub fn active_count(&self) -> usize {
        self.active.load(Ordering::SeqCst)
    }

    /// Run one blocking closure after acquiring a supervisor permit.
    pub async fn run<T, F>(&self, task_name: &'static str, f: F) -> Result<T, CapabilityError>
    where
        T: Send + 'static,
        F: FnOnce() -> Result<T, CapabilityError> + Send + 'static,
    {
        let start = Instant::now();
        counter!("capability_blocking_tasks_started_total", "task" => task_name.to_owned())
            .increment(1);

        let permit = self.semaphore.clone().acquire_owned().await.map_err(|_| {
            CapabilityError::Internal {
                message: format!("Blocking task supervisor closed before '{task_name}' started"),
            }
        })?;

        let active = Arc::clone(&self.active);
        let drained = Arc::clone(&self.drained);
        let running = active.fetch_add(1, Ordering::SeqCst) + 1;
        metrics::gauge!("capability_blocking_tasks_active").set(running as f64);

        match tokio::task::spawn_blocking(move || {
            let _guard = BlockingTaskGuard {
                _permit: permit,
                active,
                drained,
            };
            f()
        })
        .await
        {
            Ok(Ok(value)) => {
                record_blocking_outcome(task_name, start.elapsed(), "success");
                Ok(value)
            }
            Ok(Err(error)) => {
                record_blocking_outcome(task_name, start.elapsed(), "error");
                Err(error)
            }
            Err(error) => {
                counter!("capability_blocking_failures_total", "task" => task_name.to_owned())
                    .increment(1);
                record_blocking_outcome(task_name, start.elapsed(), "panic");
                Err(CapabilityError::Internal {
                    message: format!("Blocking task '{task_name}' failed: {error}"),
                })
            }
        }
    }

    /// Wait for active blocking closures to finish within `timeout`.
    pub async fn drain(&self, timeout: Duration) -> bool {
        tokio::time::timeout(timeout, async {
            while self.active_count() > 0 {
                self.drained.notified().await;
            }
        })
        .await
        .is_ok()
    }
}

impl Default for BlockingTaskSupervisor {
    fn default() -> Self {
        Self::new(DEFAULT_BLOCKING_CONCURRENCY)
    }
}

struct BlockingTaskGuard {
    _permit: tokio::sync::OwnedSemaphorePermit,
    active: Arc<AtomicUsize>,
    drained: Arc<tokio::sync::Notify>,
}

impl Drop for BlockingTaskGuard {
    fn drop(&mut self) {
        let remaining = self.active.fetch_sub(1, Ordering::SeqCst) - 1;
        metrics::gauge!("capability_blocking_tasks_active").set(remaining as f64);
        if remaining == 0 {
            self.drained.notify_waiters();
        }
    }
}

fn global_blocking_supervisor() -> Arc<BlockingTaskSupervisor> {
    GLOBAL_BLOCKING_SUPERVISOR
        .get_or_init(|| Arc::new(BlockingTaskSupervisor::default()))
        .clone()
}

/// Register a bounded drain for capability blocking work during server shutdown.
pub fn register_blocking_supervisor_shutdown(shutdown: &Arc<ShutdownCoordinator>) {
    let supervisor = global_blocking_supervisor();
    shutdown.register_phase_callback(
        ShutdownPhase::Capabilities,
        "capability-blocking",
        move || async move {
            if !supervisor.drain(BLOCKING_SHUTDOWN_DRAIN_TIMEOUT).await {
                tracing::warn!(
                    active = supervisor.active_count(),
                    timeout_ms = BLOCKING_SHUTDOWN_DRAIN_TIMEOUT.as_millis(),
                    "timed out draining capability blocking tasks"
                );
            }
        },
    );
}

/// Dependencies needed to create and run agents.
#[derive(Clone)]
pub struct AgentDeps {
    /// Factory that creates a fresh LLM provider per request (reads current model + auth).
    pub provider_factory: Arc<dyn ProviderFactory>,
}

/// Broad server runtime context used at app setup and domain registration.
///
/// Runtime domain handlers should not store this type directly. Each domain
/// narrows it into a local `Deps` bundle while building its worker module, then
/// operation handlers keep only those domain-specific handles.
#[derive(Clone)]
pub struct ServerRuntimeContext {
    /// Multi-session orchestrator.
    pub orchestrator: Arc<Orchestrator>,
    /// Session lifecycle manager.
    pub session_manager: Arc<SessionManager>,
    /// Event store for direct event queries.
    pub event_store: Arc<EventStore>,
    /// Shared live capability engine host.
    pub engine_host: EngineHostHandle,
    /// Path to the sparse user profile settings overlay.
    pub settings_path: PathBuf,
    /// Compiled active profile runtime.
    pub profile_runtime: Arc<crate::domains::agent::runner::profile_runtime::ProfileRuntime>,
    /// Agent execution dependencies (None = prompt handler returns error).
    pub agent_deps: Option<AgentDeps>,
    /// When the server started (for uptime calculation).
    pub server_start_time: Instant,
    /// Provider health tracker for rolling-window error rate monitoring.
    pub health_tracker: Arc<ProviderHealthTracker>,
    /// Shutdown coordinator for registering background task handles.
    pub shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
    /// Server origin (e.g. `"localhost:9847"`).
    pub origin: String,
    /// Path to auth JSON file (`~/.tron/profiles/auth.json`).
    pub auth_path: PathBuf,
    /// Pending OAuth flows keyed by flow ID (in-memory, TTL 10 min).
    pub oauth_flows: Arc<
        tokio::sync::Mutex<
            std::collections::HashMap<String, crate::domains::auth::flows::PendingOAuthFlow>,
        >,
    >,
    /// WebSocket listening port. Surfaced via `system.getInfo` so iOS clients
    /// can render the connection display ("Tailscale 100.x:9847") without
    /// re-parsing user input. Initialized from config and updated after bind.
    pub ws_port: Arc<AtomicU16>,
    /// Path to the first-run sentinel (`~/.tron/internal/run/.onboarded`). Stored on
    /// the context so tests can inject a temp path; production sets it to
    /// [`crate::app::onboarding::onboarded_marker_path`]. Drives the `paired`
    /// field returned by `system.getInfo`.
    pub onboarded_marker_path: PathBuf,
}

impl ServerRuntimeContext {
    /// Run blocking work on the dedicated blocking pool used by async capabilities.
    pub async fn run_blocking<T, F>(
        &self,
        task_name: &'static str,
        f: F,
    ) -> Result<T, CapabilityError>
    where
        T: Send + 'static,
        F: FnOnce() -> Result<T, CapabilityError> + Send + 'static,
    {
        run_blocking_task(task_name, f).await
    }

    /// Spawn blocking work whose result is intentionally not part of the capability
    /// response, while still registering the async owner with shutdown.
    pub fn spawn_blocking_detached<F>(&self, task_name: &'static str, f: F)
    where
        F: FnOnce() -> Result<(), CapabilityError> + Send + 'static,
    {
        let handle = tokio::spawn(async move {
            if let Err(error) = run_blocking_task(task_name, f).await {
                tracing::warn!(task = task_name, error = %error, "detached blocking capability task failed");
            }
        });

        if let Some(shutdown) = &self.shutdown_coordinator {
            shutdown.register_task(handle);
        } else {
            drop(handle);
        }
    }

    /// Current WebSocket listening port.
    pub fn ws_port(&self) -> u16 {
        self.ws_port.load(Ordering::SeqCst)
    }

    /// Update the current WebSocket listening port after bind.
    pub fn set_ws_port(&self, port: u16) {
        self.ws_port.store(port, Ordering::SeqCst);
    }
}

pub(crate) async fn run_blocking_task<T, F>(
    task_name: &'static str,
    f: F,
) -> Result<T, CapabilityError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, CapabilityError> + Send + 'static,
{
    global_blocking_supervisor().run(task_name, f).await
}

fn record_blocking_outcome(
    task_name: &'static str,
    duration: std::time::Duration,
    outcome: &'static str,
) {
    counter!(
        "capability_blocking_tasks_completed_total",
        "task" => task_name.to_owned(),
        "outcome" => outcome.to_owned()
    )
    .increment(1);
    histogram!(
        "capability_blocking_task_duration_seconds",
        "task" => task_name.to_owned(),
        "outcome" => outcome.to_owned()
    )
    .record(duration.as_secs_f64());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::server::test_support::{
        ModelAwareMockFactory, StrictMockFactory, make_test_agent_deps, make_test_context,
    };

    #[test]
    fn context_has_server_start_time() {
        let ctx = make_test_context();
        let elapsed = ctx.server_start_time.elapsed();
        assert!(elapsed.as_secs() < 5);
    }

    #[test]
    fn server_start_time_allows_uptime_calc() {
        let ctx = make_test_context();
        let uptime = ctx.server_start_time.elapsed();
        assert!(uptime.as_secs() < 5);
    }

    #[test]
    fn context_has_orchestrator() {
        let ctx = make_test_context();
        assert!(ctx.orchestrator.can_accept_session());
    }

    #[test]
    fn context_has_session_manager() {
        let ctx = make_test_context();
        assert_eq!(ctx.session_manager.active_count(), 0);
    }

    #[tokio::test]
    async fn context_session_manager_matches_orchestrator() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();
        assert_eq!(ctx.orchestrator.active_session_count(), 1);
    }

    #[test]
    fn context_has_event_store() {
        let ctx = make_test_context();
        let result = ctx.event_store.list_workspaces();
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn context_has_engine_host() {
        let ctx = make_test_context();
        let host = ctx.engine_host.lock().await;
        assert!(
            host.catalog()
                .function(&crate::engine::FunctionId::new("engine::discover").unwrap())
                .is_some()
        );
    }

    #[tokio::test]
    async fn context_event_store_matches_session_manager() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();
        let session = ctx.event_store.get_session(&sid).unwrap();
        assert!(session.is_some());
    }

    #[test]
    fn context_has_settings_path() {
        let ctx = make_test_context();
        assert!(!ctx.settings_path.as_os_str().is_empty());
    }

    #[tokio::test]
    async fn context_event_store_operations_work() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();

        let event = ctx
            .event_store
            .append(&crate::domains::session::event_store::AppendOptions {
                session_id: &sid,
                event_type: crate::domains::session::event_store::EventType::MessageUser,
                payload: serde_json::json!({"text": "hello"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        assert_eq!(event.session_id, sid);
    }

    #[tokio::test]
    async fn run_blocking_executes_closure() {
        let ctx = make_test_context();
        let value = ctx
            .run_blocking("test.run_blocking", || Ok::<_, CapabilityError>(41))
            .await;
        assert_eq!(value.unwrap(), 41);
    }

    #[tokio::test]
    async fn run_blocking_propagates_closure_error() {
        let ctx = make_test_context();
        let err = ctx
            .run_blocking("test.run_blocking_error", || {
                Err::<(), _>(CapabilityError::InvalidParams {
                    message: "bad input".into(),
                })
            })
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert_eq!(err.to_string(), "bad input");
    }

    #[tokio::test]
    async fn run_blocking_maps_panics_to_internal_error() {
        let ctx = make_test_context();
        let err = ctx
            .run_blocking(
                "test.run_blocking_panic",
                || -> Result<(), CapabilityError> {
                    panic!("boom");
                },
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INTERNAL_ERROR");
        assert!(
            err.to_string().contains("test.run_blocking_panic"),
            "panic error should include task name: {err}"
        );
    }

    #[tokio::test]
    async fn blocking_supervisor_limits_concurrency() {
        use std::sync::atomic::AtomicUsize;

        let supervisor = Arc::new(BlockingTaskSupervisor::new(1));
        let active = Arc::new(AtomicUsize::new(0));
        let max_seen = Arc::new(AtomicUsize::new(0));

        let mut handles = Vec::new();
        for _ in 0..2 {
            let supervisor = Arc::clone(&supervisor);
            let active = Arc::clone(&active);
            let max_seen = Arc::clone(&max_seen);
            handles.push(tokio::spawn(async move {
                supervisor
                    .run("test.blocking_limit", move || {
                        let now = active.fetch_add(1, Ordering::SeqCst) + 1;
                        max_seen.fetch_max(now, Ordering::SeqCst);
                        std::thread::sleep(Duration::from_millis(30));
                        active.fetch_sub(1, Ordering::SeqCst);
                        Ok::<_, CapabilityError>(())
                    })
                    .await
                    .unwrap();
            }));
        }

        for handle in handles {
            handle.await.unwrap();
        }
        assert_eq!(max_seen.load(Ordering::SeqCst), 1);
        assert_eq!(supervisor.active_count(), 0);
    }

    #[tokio::test]
    async fn blocking_supervisor_drain_waits_for_active_work() {
        let supervisor = Arc::new(BlockingTaskSupervisor::new(1));
        let running = Arc::clone(&supervisor);
        let handle = tokio::spawn(async move {
            running
                .run("test.blocking_drain", || {
                    std::thread::sleep(Duration::from_millis(30));
                    Ok::<_, CapabilityError>(())
                })
                .await
                .unwrap();
        });

        while supervisor.active_count() == 0 {
            tokio::task::yield_now().await;
        }
        assert!(supervisor.drain(Duration::from_secs(1)).await);
        handle.await.unwrap();
    }

    #[tokio::test]
    async fn blocking_supervisor_drain_times_out_without_losing_tracking() {
        let supervisor = Arc::new(BlockingTaskSupervisor::new(1));
        let running = Arc::clone(&supervisor);
        let handle = tokio::spawn(async move {
            running
                .run("test.blocking_drain_timeout", || {
                    std::thread::sleep(Duration::from_millis(120));
                    Ok::<_, CapabilityError>(())
                })
                .await
                .unwrap();
        });

        while supervisor.active_count() == 0 {
            tokio::task::yield_now().await;
        }
        assert!(!supervisor.drain(Duration::from_millis(5)).await);
        assert_eq!(supervisor.active_count(), 1);
        handle.await.unwrap();
        assert_eq!(supervisor.active_count(), 0);
    }

    #[test]
    fn make_test_context_populates_all_fields() {
        let ctx = make_test_context();
        assert!(ctx.orchestrator.can_accept_session());
        assert_eq!(ctx.session_manager.active_count(), 0);
        assert!(ctx.event_store.list_workspaces().is_ok());
        assert!(!ctx.settings_path.as_os_str().is_empty());
    }

    // ── AgentDeps tests ──

    #[test]
    fn context_without_agent_deps_returns_not_available_in_handlers() {
        let ctx = make_test_context();
        assert!(ctx.agent_deps.is_none());
    }

    #[test]
    fn context_with_agent_deps() {
        let mut ctx = make_test_context();
        ctx.agent_deps = Some(make_test_agent_deps());
        assert!(ctx.agent_deps.is_some());
    }

    #[test]
    fn agent_deps_provider_factory_accessible() {
        let deps = make_test_agent_deps();
        assert!(Arc::strong_count(&deps.provider_factory) >= 1);
    }

    #[tokio::test]
    async fn agent_deps_factory_creates_provider() {
        let deps = make_test_agent_deps();
        let provider = deps
            .provider_factory
            .create_for_model("claude-opus-4-6")
            .await
            .unwrap();
        assert_eq!(provider.model(), "mock");
    }

    #[tokio::test]
    async fn model_aware_factory_returns_correct_model() {
        let factory = ModelAwareMockFactory;
        let p1 = factory.create_for_model("claude-opus-4-6").await.unwrap();
        let p2 = factory.create_for_model("gpt-5.3-codex").await.unwrap();
        assert_eq!(p1.model(), "claude-opus-4-6");
        assert_eq!(p2.model(), "gpt-5.3-codex");
    }

    #[tokio::test]
    async fn strict_factory_rejects_unknown_model() {
        let factory = StrictMockFactory;
        let result = factory.create_for_model("unknown-model").await;
        match result {
            Err(e) => assert_eq!(e.category(), "auth"),
            Ok(_) => panic!("expected auth error"),
        }
    }

    #[test]
    fn agent_deps_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AgentDeps>();
    }
}
