//! Durable worker orchestration.
//!
//! [`WorkerRuntime`] is the single mutable coordinator for activation,
//! invocation, lifecycle, dispatch, direct-tool projection, and resident
//! supervision. The concern modules below extend that one coordinator without
//! duplicating state. `support` owns stateless bounded I/O, artifact integrity,
//! projection, normalization, and redaction. Scenario tests live in `tests`.
//! `admission` owns schema-checked durable enqueue, idempotent replay, and
//! observational waits; `invocation` owns claimed delivery, concurrency, and
//! terminal completion so admission never becomes an execution side channel.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, RwLock as StdRwLock, Weak};
use std::time::Duration;

use dashmap::{DashMap, DashSet};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tokio::sync::{Mutex, Semaphore};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

use super::core_proposals::{CoreProposal, CoreProposalService};
use super::persistence::WorkerStore;
use super::process::{MAX_PROCESS_CAPTURE_BYTES, ProcessTree};
use super::types::{
    ActiveWorker, InvocationRecord, InvokeRequest, MAX_CAUSAL_DEPTH, MAX_ENGINE_CONCURRENCY,
    MAX_INVOCATION_SECONDS, MAX_WORKER_CONCURRENCY, PreparedWorker, UpsertOutcome, WorkerBundle,
    WorkerCommand, WorkerDependency, WorkerEngineHook, WorkerRunner, WorkerTrigger,
};
use support::*;

mod activation;
mod admission;
mod dispatch;
mod events;
mod hooks;
mod invocation;
mod lifecycle;
mod resident;
mod secrets;
mod session;
mod support;
use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::session::event_store::EventStore;
use crate::domains::settings::SettingsRuntime;
use crate::engine::{
    ActorId, ActorKind, CausalContext, DirectWorkerToolContract, EffectClass, EngineHostHandle,
    FunctionDefinition, FunctionId, FunctionVisibility, IdempotencyContract,
    InProcessFunctionHandler, Invocation, ModelToolContract, PublishStreamEvent, RiskLevel,
    StreamActorScope, StreamCursor, StreamVisibility, TraceId, WorkerId,
};

struct ResidentProcess {
    child: Option<ProcessTree>,
    consecutive_health_failures: u8,
    runtime_root: Option<PathBuf>,
}

const RESIDENT_HEALTH_FAILURE_LIMIT: u8 = 3;
const RESIDENT_HEALTH_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_DEPENDENCY_DOWNLOAD_BYTES: usize = 128 * 1_048_576;

struct RemoveDirectoryOnDrop(PathBuf);

impl Drop for RemoveDirectoryOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Couples an agent-runner child session to its durable worker invocation.
/// Dropping the worker future because of timeout, disable, stop-all, autonomy
/// shutdown, or server shutdown must also cancel the asynchronously spawned
/// child agent; otherwise consequential work can outlive its terminal record.
struct AbortAgentRunOnDrop {
    orchestrator: Arc<Orchestrator>,
    session_id: String,
    armed: bool,
}

impl AbortAgentRunOnDrop {
    fn new(orchestrator: Arc<Orchestrator>, session_id: String) -> Self {
        Self {
            orchestrator,
            session_id,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for AbortAgentRunOnDrop {
    fn drop(&mut self) {
        if self.armed {
            let _ = self.orchestrator.abort(&self.session_id);
        }
    }
}

#[derive(Clone)]
struct KernelPrimitiveRegistration {
    definition: FunctionDefinition,
    handler: Weak<dyn InProcessFunctionHandler>,
}

pub struct WorkerRuntime {
    store: WorkerStore,
    host: EngineHostHandle,
    orchestrator: Arc<Orchestrator>,
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    settings_runtime: Arc<SettingsRuntime>,
    engine_limit: Arc<Semaphore>,
    worker_limits: DashMap<String, Arc<Semaphore>>,
    inflight: DashSet<String>,
    worker_stops: DashMap<String, CancellationToken>,
    execution_stop: Mutex<CancellationToken>,
    residents: DashMap<String, Arc<Mutex<ResidentProcess>>>,
    resident_users: DashMap<String, Arc<AtomicUsize>>,
    resident_supervisions: DashSet<String>,
    stopped: AtomicBool,
    shutting_down: AtomicBool,
    kernel_primitives: StdRwLock<Vec<KernelPrimitiveRegistration>>,
    kernel_visibility: AtomicBool,
    http: reqwest::Client,
    core_proposals: CoreProposalService,
}

impl WorkerRuntime {
    pub fn new(
        store: WorkerStore,
        host: EngineHostHandle,
        orchestrator: Arc<Orchestrator>,
        session_manager: Arc<SessionManager>,
        event_store: Arc<EventStore>,
        settings_runtime: Arc<SettingsRuntime>,
    ) -> Result<Arc<Self>, String> {
        for runtime_directory in ["worker-invocations", "worker-services"] {
            let path = store
                .home()
                .join(crate::shared::foundation::paths::dirs::INTERNAL)
                .join(crate::shared::foundation::paths::dirs::RUN)
                .join(runtime_directory);
            if path.exists() {
                std::fs::remove_dir_all(&path).map_err(|error| {
                    format!("remove stale {runtime_directory} runtime state: {error}")
                })?;
            }
        }
        let stopped = store.stop_all()?;
        let kernel_visibility = settings_runtime.current().settings.autonomous_workers;
        let core_proposals = CoreProposalService::new(store.home(), Arc::clone(&event_store))?;
        Ok(Arc::new(Self {
            store,
            host,
            orchestrator,
            session_manager,
            event_store,
            settings_runtime,
            engine_limit: Arc::new(Semaphore::new(MAX_ENGINE_CONCURRENCY)),
            worker_limits: DashMap::new(),
            inflight: DashSet::new(),
            worker_stops: DashMap::new(),
            execution_stop: Mutex::new(CancellationToken::new()),
            residents: DashMap::new(),
            resident_users: DashMap::new(),
            resident_supervisions: DashSet::new(),
            stopped: AtomicBool::new(stopped),
            shutting_down: AtomicBool::new(false),
            kernel_primitives: StdRwLock::new(Vec::new()),
            kernel_visibility: AtomicBool::new(kernel_visibility),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(MAX_INVOCATION_SECONDS))
                .build()
                .map_err(|error| format!("build worker HTTP client: {error}"))?,
            core_proposals,
        }))
    }

    pub fn store(&self) -> &WorkerStore {
        &self.store
    }

    pub(crate) fn host(&self) -> &EngineHostHandle {
        &self.host
    }

    /// Return one coherent, authenticated-client projection of the live model
    /// surface and canonical engine worker inventory.
    pub(crate) async fn engine_surface_snapshot(
        &self,
        session_id: Option<&str>,
        relevance_query: Option<&str>,
    ) -> Result<Value, String> {
        let session_id = session_id.unwrap_or("engine-dashboard");
        let surface =
            super::surface::resolve_tool_surface(&self.host, session_id, relevance_query, None)
                .await?
                .snapshot;
        let fixed_tools = super::surface::fixed_tool_inventory(&self.host, &surface).await?;
        Ok(json!({
            "autonomousWorkers": self.autonomous_enabled(),
            "dispatchStopped": self.store.stop_all()?,
            "activeEngineHooks": self.engine_hook_inventory()?,
            "fixedTools": fixed_tools,
            "surface": surface,
            "workers": self.store.list(true)?,
        }))
    }

    pub fn autonomous_enabled(&self) -> bool {
        self.settings_runtime.current().settings.autonomous_workers
    }

    pub(crate) fn configure_kernel_primitives(
        &self,
        primitives: Vec<(FunctionDefinition, Weak<dyn InProcessFunctionHandler>)>,
    ) -> Result<(), String> {
        let mut registrations = self
            .kernel_primitives
            .write()
            .map_err(|_| "worker kernel primitive registry is poisoned".to_owned())?;
        *registrations = primitives
            .into_iter()
            .map(|(definition, handler)| KernelPrimitiveRegistration {
                definition,
                handler,
            })
            .collect();
        Ok(())
    }

    pub async fn create_core_proposal(
        &self,
        title: String,
        intent: String,
        repository_path: String,
        patch: String,
        test_command: Vec<String>,
    ) -> Result<CoreProposal, String> {
        self.core_proposals
            .create(title, intent, repository_path, patch, test_command)
            .await
    }

    pub fn list_core_proposals(&self) -> Result<Vec<CoreProposal>, String> {
        self.core_proposals.list()
    }

    pub fn inspect_core_proposal(&self, proposal_id: &str) -> Result<CoreProposal, String> {
        self.core_proposals.inspect(proposal_id)
    }

    pub async fn apply_core_proposal(
        &self,
        proposal_id: &str,
        approval_session_id: &str,
        approval_message_id: &str,
    ) -> Result<CoreProposal, String> {
        self.core_proposals
            .apply(proposal_id, approval_session_id, approval_message_id)
            .await
    }

    pub async fn activate(self: &Arc<Self>, cancellation: CancellationToken) {
        let autonomous = self.autonomous_enabled();
        let applied = match self.apply_autonomy_state(autonomous).await {
            Ok(()) => Some(autonomous),
            Err(error) => {
                tracing::error!(%error, autonomous, "failed to apply initial worker autonomy state");
                None
            }
        };
        self.run_dispatcher(cancellation, applied).await;
    }

    pub async fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::SeqCst);
        self.execution_stop.lock().await.cancel();
        self.stop_residents(None).await;
    }
}

#[cfg(test)]
mod tests;
