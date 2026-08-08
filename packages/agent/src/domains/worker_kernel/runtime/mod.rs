//! Durable worker orchestration.
//!
//! [`WorkerRuntime`] is the single mutable coordinator for activation,
//! invocation, lifecycle, dispatch, public/internal worker-tool projection, and resident
//! supervision. The concern modules below extend that one coordinator without
//! duplicating state. `support` owns stateless bounded I/O, artifact integrity,
//! projection, normalization, and redaction. Scenario tests live in `tests`.
//! `run_projection` reconstructs bounded causal trees and structured timelines
//! from durable invocation, attempt, stage, child-session, and model-turn truth;
//! it never stores client-owned progress. Exact lookups include a closed
//! `requestedInvocation` projection whose timing and descendant-inclusive
//! usage belong to the requested worker rather than the causal root. Its request preview prefers
//! conventional user-authored question/query/task fields so clients never need
//! to present a serialized worker input object as the run summary. Equal-time
//! durable timeline facts retain lifecycle order (queued before detached)
//! rather than falling back to display-text ordering.
//! `run_metrics` projects the same requested-invocation timing and usage as a
//! compact envelope without materializing graph nodes or timeline content.
//! `admission` owns schema-checked durable enqueue, idempotent replay,
//! exact-version latency prediction, bounded foreground ownership, atomic
//! detachment, and observational waits plus the transient bridge to an
//! originating model-tool chip. Nested calls retain their ordinary typed-input
//! idempotency and also receive a durable parent/per-tool occurrence slot.
//! Resolved agent-runner model/reasoning pairs are validated before enqueue
//! whether they came from an override, bundle default, fallback, or retry pin;
//! requested and effective values remain provenance, not routing policy. A
//! reconstructed parent restarts those occurrences at zero, observes the same
//! child even when provider ids or valid arguments change, and waits for its
//! typed terminal result instead of duplicating it. `invocation` owns
//! claimed delivery, concurrency, progress phases, and terminal completion so
//! detachment never becomes a second execution path. A claimed delivery cannot
//! release its process-local owner while its durable status is still running;
//! shutdown and orphan recovery interrupt and requeue the same invocation.
//! `result` owns generic artifact-style references for large validated worker
//! outputs plus bounded JSON reads. Authenticated operator clients and
//! engine-owned recovery may inspect profile-local results. An agent worker
//! may read only a direct child it durably admitted; other agent and worker
//! callers require the originating session or an explicit Agent Delivery grant.
//! Task-specific result interpretation remains in workers.
//! Agent child-session activity is projected only as bounded, redacted stage
//! labels; raw child content remains in its canonical audit session.
//! `client_actions` selects the current healthy worker for narrow native
//! capture/presentation seams without creating a second execution path.
//! `hooks` selects one immutable healthy owner and joins the ordinary durable
//! invocation. Pure relevance derives short-lived exact-input idempotency from
//! canonical JSON; session- and trace-bound hooks preserve their causal key. It
//! owns neither a result cache nor a second execution path. Request-scoped
//! failures from optional semantic hooks and runtime failures from agent
//! runners remain terminal evidence on that invocation without globally
//! disabling their worker. Provider HTTP/auth/API failures, tool failures,
//! execution timeouts, and result-loading failures do not prove that an
//! immutable worker is broken;
//! structural activation, integrity, and invalid-output failures still
//! quarantine broken versions.
//! `agent_deliveries`
//! owns coordination tools, import ordering, waits, and safe delivery-only
//! wakeups; `agent_delivery_import` projects closed terminal/effect envelopes
//! without holding both databases. Terminal completion
//! notifies that same dispatcher for low-latency import while its one-second
//! tick remains the lost-signal and restart reconciliation fallback. Every
//! background invocation receipt uses one model-facing contract: the invocation
//! stays nonblocking and passive unless the model immediately registers
//! `agent_wait_for_workers`; polling and `worker_await` are explicitly
//! prohibited. Wait reconciliation suppresses or supersedes an unprepared
//! default passive result and creates one wake delivery, while a result already
//! prepared for provider context is reused rather than duplicated.
//! `events` publishes invocation invalidations with the invocation ledger's
//! durable `origin_session_id`; lifecycle changes remain global and scheduled
//! or otherwise sessionless work remains unscoped. These lossy stream facts
//! only accelerate client rereads of authoritative projections and never own
//! completion, delivery, or wait state.
//! `notifications` drains the durable worker-to-client outbox through APNs;
//! provider acceptance is evidence, never a human-delivery receipt.
//! Closed self-wakeup output queues only the same immutable worker version at
//! its worker-selected future time, reusing this dispatcher and invocation
//! ledger instead of introducing another timer or job subsystem.

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
use tokio::sync::{Mutex, Notify, Semaphore};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

use super::persistence::{AgentDeliveryOutboxRecord, WorkerStore};
use super::process::{MAX_PROCESS_CAPTURE_BYTES, ProcessTree};
use super::types::{
    ActiveWorker, InvocationRecord, InvokeRequest, MAX_CAUSAL_DEPTH, MAX_ENGINE_CONCURRENCY,
    MAX_INVOCATION_SECONDS, MAX_WORKER_CONCURRENCY, PreparedWorker, PurgeOutcome, UpsertOutcome,
    WorkerBundle, WorkerClientAction, WorkerCommand, WorkerDependency, WorkerEngineHook,
    WorkerInteractionMode, WorkerModelExposure, WorkerRunEvent, WorkerRunStage, WorkerRunner,
    WorkerTrigger,
};
use support::*;

mod activation;
mod admission;
mod agent_deliveries;
mod agent_delivery_import;
mod artifacts;
pub(super) use admission::ModelToolInvocationOutcome;
pub(crate) use admission::WorkerInputContractError;
mod client_actions;
mod dispatch;
mod events;
mod hooks;
mod invocation;
mod lifecycle;
mod notifications;
mod resident;
mod result;
mod run_metrics;
mod run_projection;
mod run_projection_format;
mod secrets;
mod session;
mod session_organization;
mod support;
mod worker_dispatches;
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
    notification_maintenance_ticks: AtomicUsize,
    session_organization_maintenance_ticks: AtomicUsize,
    delivery_maintenance: Arc<Notify>,
    notification_configuration_revision: Mutex<Option<String>>,
    http: reqwest::Client,
    notification_transport: super::notifications::transport::NotificationTransport,
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
        let _ = event_store
            .expire_agent_deliveries()
            .map_err(|error| format!("reconcile expired agent deliveries: {error}"))?;
        let recovered_leases = event_store
            .clear_agent_delivery_leases()
            .map_err(|error| format!("clear stale agent-delivery leases: {error}"))?;
        if recovered_leases > 0 {
            metrics::counter!("agent_delivery_lease_recoveries_total")
                .increment(recovered_leases as u64);
        }
        let notification_transport =
            super::notifications::transport::NotificationTransport::new(store.home())?;
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
            notification_maintenance_ticks: AtomicUsize::new(0),
            session_organization_maintenance_ticks: AtomicUsize::new(0),
            delivery_maintenance: Arc::new(Notify::new()),
            notification_configuration_revision: Mutex::new(None),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(MAX_INVOCATION_SECONDS))
                .build()
                .map_err(|error| format!("build worker HTTP client: {error}"))?,
            notification_transport,
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
        let surface = super::surface::resolve_tool_surface(
            &self.host,
            session_id,
            relevance_query,
            None,
            None,
        )
        .await?
        .snapshot;
        let fixed_tools = super::surface::fixed_tool_inventory(&surface);
        let workers = self.store.list(true)?;
        let tool_owner_by_name = workers
            .iter()
            .map(|worker| (worker.tool_name.clone(), worker.worker_id.clone()))
            .collect::<std::collections::BTreeMap<_, _>>();
        let worker_architecture = workers
            .iter()
            .filter(|summary| summary.enabled && !summary.retired)
            .map(|summary| {
                let active = self.store.load_indexed_active(&summary.worker_id)?;
                let bundle = active.bundle;
                let runner_model = match &bundle.runner {
                    WorkerRunner::Agent { model, .. } => model.clone(),
                    WorkerRunner::Command { .. } | WorkerRunner::Service { .. } => None,
                };
                let calls = bundle
                    .worker_dispatch_routes
                    .iter()
                    .map(|route| json!({
                        "kind":"worker_dispatch",
                        "label":route.route,
                        "targetWorkerId":route.target_worker_id,
                        "responseOwner":route.client_response_owner.as_str(),
                    }))
                    .chain(
                        bundle
                            .agent_tools
                            .as_deref()
                            .unwrap_or_default()
                            .iter()
                            .map(|tool| {
                                json!({
                                    "kind":"agent_tool",
                                    "label":tool,
                                    "targetWorkerId":tool_owner_by_name.get(tool),
                                })
                            }),
                    )
                    .collect::<Vec<_>>();
                Ok(json!({
                    "workerId":summary.worker_id,
                    "name":summary.name,
                    "description":summary.description,
                    "activeVersion":summary.active_version,
                    "health":summary.health,
                    "modelExposure":match bundle.model_exposure {
                        WorkerModelExposure::Direct => "direct",
                        WorkerModelExposure::Internal => "internal",
                    },
                    "runnerKind":bundle.runner.kind(),
                    "runnerModel":runner_model,
                    "engineHooks":bundle.engine_hooks.iter().map(|hook| hook.as_str()).collect::<Vec<_>>(),
                    "clientActions":bundle.client_actions.iter().map(|action| action.as_str()).collect::<Vec<_>>(),
                    "clientDeliveries":bundle.client_deliveries.iter().map(|delivery| delivery.as_str()).collect::<Vec<_>>(),
                    "triggerKinds":bundle.triggers.iter().map(WorkerTrigger::kind).collect::<Vec<_>>(),
                    "calls":calls,
                    "presentation":{
                        "suiteId":bundle.presentation.as_ref().and_then(|presentation| presentation.suite_id.as_deref()),
                        "componentRole":bundle.presentation.as_ref().and_then(|presentation| presentation.component_role.as_deref()),
                        "primary":bundle.presentation.as_ref().is_some_and(|presentation| presentation.primary),
                    },
                    "provenance":bundle.provenance.iter().take(8).map(|source| json!({
                        "source":crate::shared::foundation::redaction::redact_sensitive_content(&source.source),
                        "revision":source.revision,
                        "checksum":source.checksum,
                    })).collect::<Vec<_>>(),
                }))
            })
            .collect::<Result<Vec<_>, String>>()?;
        Ok(json!({
            "dispatchStopped": self.store.stop_all()?,
            "activeEngineHooks": self.engine_hook_inventory()?,
            "activeClientActions": self.client_action_inventory()?,
            "activeClientDeliveries": self.client_delivery_inventory()?,
            "fixedTools": fixed_tools,
            "surface": {
                "catalogRevision": surface.catalog_revision,
                "surfaceHash": surface.surface_hash,
                "fixedToolCount": surface.fixed_tool_count,
                "ordinaryFixedToolCount": surface.ordinary_fixed_tool_count,
                "specialistFixedToolCount": surface.specialist_fixed_tool_count,
                "conditionalFixedToolCount": surface.conditional_fixed_tool_count,
                "projectedWorkerCount": surface.projected_worker_count,
                "availableWorkerCount": surface.available_worker_count,
                "availableWorkers": surface.available_workers,
            },
            "workers": workers,
            "workerArchitecture": worker_architecture,
        }))
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
