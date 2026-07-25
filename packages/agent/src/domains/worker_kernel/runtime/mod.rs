//! Durable worker orchestration.
//!
//! [`WorkerRuntime`] is the single mutable coordinator for activation,
//! invocation, lifecycle, dispatch, direct-tool projection, and resident
//! supervision. The concern modules below extend that one coordinator without
//! duplicating state. `support` owns stateless bounded I/O, artifact integrity,
//! projection, normalization, and redaction. Scenario tests live in `tests`.
//! `run_projection` reconstructs bounded causal trees and structured timelines
//! from durable invocation, attempt, stage, child-session, and model-turn truth;
//! it never stores client-owned progress.
//! `admission` owns schema-checked durable enqueue, idempotent replay,
//! exact-version latency prediction, bounded foreground ownership, atomic
//! detachment, and observational waits plus the transient bridge to an
//! originating model-tool chip. Nested calls retain their ordinary typed-input
//! idempotency and also receive a durable parent/per-tool occurrence slot. A
//! reconstructed parent restarts those occurrences at zero, observes the same
//! child even when provider ids or valid arguments change, and waits for its
//! typed terminal result instead of duplicating it. `invocation` owns
//! claimed delivery, concurrency, progress phases, and terminal completion so
//! detachment never becomes a second execution path.
//! `result` owns generic artifact-style references for large validated worker
//! outputs plus bounded, causally authorized JSON reads. Task-specific result
//! interpretation remains in workers.
//! Agent child-session activity is projected only as bounded, redacted stage
//! labels; raw child content remains in its canonical audit session.
//! `client_actions` selects the current healthy worker for narrow native
//! capture/presentation seams without creating a second execution path.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
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
    MAX_INVOCATION_SECONDS, MAX_WORKER_CONCURRENCY, PreparedWorker, PurgeOutcome, UpsertOutcome,
    WorkerBundle, WorkerClientAction, WorkerCommand, WorkerDependency, WorkerEngineHook,
    WorkerInteractionMode, WorkerRunEvent, WorkerRunStage, WorkerRunner, WorkerTrigger,
};
use support::*;

mod activation;
mod admission;
pub(super) use admission::ModelToolInvocationOutcome;
pub(crate) use admission::WorkerInputContractError;
mod client_actions;
mod dispatch;
mod events;
mod hooks;
mod invocation;
mod lifecycle;
mod resident;
mod result;
mod run_projection;
mod run_projection_format;
mod secrets;
mod session;
mod support;
use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::session::event_store::EventStore;
use crate::domains::settings::SettingsRuntime;
use crate::engine::{
    ActorId, ActorKind, CausalContext, DirectWorkerToolContract, EffectClass, EngineHostHandle,
    FunctionId, FunctionVisibility, IdempotencyContract, Invocation, ModelToolContract,
    PublishStreamEvent, RiskLevel, StreamActorScope, StreamCursor, StreamVisibility, TraceId,
    WorkerId,
};

struct ResidentProcess {
    child: Option<ProcessTree>,
    ready: bool,
    consecutive_health_failures: u8,
    runtime_root: Option<PathBuf>,
}

/// Transient bridge from one durable worker invocation to the exact
/// provider/model tool chip that is awaiting it.
///
/// The bridge is deliberately in memory: durable worker state owns recovery,
/// while a live conversation owns only progress presentation for its current
/// call. Restarted delivery remains correct without reviving a stale chip.
#[derive(Clone, Debug)]
struct ModelToolProgressTarget {
    session_id: String,
    invocation_id: String,
    tool_name: String,
    worker_name: String,
    trace_id: String,
    root_invocation_id: Option<String>,
}

/// Removes a live model-tool bridge even when its awaiting future is cancelled.
///
/// The durable worker run may continue or recover independently; a provider
/// chip that no longer has an awaiting turn must never remain retained by the
/// process-local presentation map.
struct RemoveModelToolProgressOnDrop {
    runtime: Arc<WorkerRuntime>,
    worker_invocation_id: String,
}

impl Drop for RemoveModelToolProgressOnDrop {
    fn drop(&mut self) {
        let _ = self
            .runtime
            .model_tool_progress
            .remove(&self.worker_invocation_id);
    }
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
/// Dropping the worker future because of timeout, disable, stop-all, or server
/// shutdown must also cancel the asynchronously spawned
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
    invocation_stops: DashMap<String, CancellationToken>,
    model_tool_progress: DashMap<String, ModelToolProgressTarget>,
    worker_stops: DashMap<String, CancellationToken>,
    execution_stop: Mutex<CancellationToken>,
    residents: DashMap<String, Arc<Mutex<ResidentProcess>>>,
    resident_users: DashMap<String, Arc<AtomicUsize>>,
    resident_supervisions: DashSet<String>,
    stopped: AtomicBool,
    shutting_down: AtomicBool,
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
            invocation_stops: DashMap::new(),
            model_tool_progress: DashMap::new(),
            worker_stops: DashMap::new(),
            execution_stop: Mutex::new(CancellationToken::new()),
            residents: DashMap::new(),
            resident_users: DashMap::new(),
            resident_supervisions: DashSet::new(),
            stopped: AtomicBool::new(stopped),
            shutting_down: AtomicBool::new(false),
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
            "dispatchStopped": self.store.stop_all()?,
            "activeEngineHooks": self.engine_hook_inventory()?,
            "activeClientActions": self.client_action_inventory()?,
            "fixedTools": fixed_tools,
            "surface": {
                "catalogRevision": surface.catalog_revision,
                "surfaceHash": surface.surface_hash,
                "fixedToolCount": surface.fixed_tool_count,
                "projectedWorkerCount": surface.projected_worker_count,
                "availableWorkerCount": surface.available_worker_count,
                "availableWorkers": surface.available_workers,
            },
            "workers": self.store.list(true)?,
        }))
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
        if let Err(error) = self.register_active_tools().await {
            tracing::error!(%error, "failed to register active worker tools");
        }
        self.run_dispatcher(cancellation).await;
    }

    pub async fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::SeqCst);
        self.execution_stop.lock().await.cancel();
        self.stop_residents(None).await;
    }
}

#[cfg(test)]
mod tests;
