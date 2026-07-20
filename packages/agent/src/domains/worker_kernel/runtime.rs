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
use tokio::process::Command;
use tokio::sync::{Mutex, Semaphore};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::agent::r#loop::profile_runtime::ProfileRuntime;
use crate::domains::session::event_store::EventStore;
use crate::engine::{
    ActorId, ActorKind, CausalContext, EffectClass, EngineHostHandle, FunctionDefinition,
    FunctionHealth, FunctionId, IdempotencyContract, InProcessFunctionHandler, Invocation,
    PublishStreamEvent, RUNTIME_METADATA_TRIGGER_DEPTH, RiskLevel, StreamActorScope, StreamCursor,
    TraceId, VisibilityScope, WorkerId,
};

use super::core_proposals::{CoreProposal, CoreProposalService};
use super::persistence::WorkerStore;
use super::process::{MAX_PROCESS_CAPTURE_BYTES, ProcessTree, wait_with_bounded_output};
use super::types::{
    ActiveWorker, InvocationRecord, InvokeRequest, MAX_CAUSAL_DEPTH, MAX_INVOCATION_SECONDS,
    MAX_PROFILE_CONCURRENCY, MAX_WORKER_CONCURRENCY, PreparedWorker, UpsertOutcome, WorkerBundle,
    WorkerCommand, WorkerDependency, WorkerRunner, WorkerTrigger,
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
    profile_runtime: Arc<ProfileRuntime>,
    profile_limit: Arc<Semaphore>,
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
        profile_runtime: Arc<ProfileRuntime>,
    ) -> Result<Arc<Self>, String> {
        for runtime_directory in ["worker-invocations", "worker-services"] {
            let path = store
                .home()
                .join("internal")
                .join("run")
                .join(runtime_directory);
            if path.exists() {
                std::fs::remove_dir_all(&path).map_err(|error| {
                    format!("remove stale {runtime_directory} runtime state: {error}")
                })?;
            }
        }
        let stopped = store.stop_all()?;
        let kernel_visibility = profile_runtime.current().settings.autonomous_workers;
        let core_proposals = CoreProposalService::new(store.home(), Arc::clone(&event_store))?;
        Ok(Arc::new(Self {
            store,
            host,
            orchestrator,
            session_manager,
            event_store,
            profile_runtime,
            profile_limit: Arc::new(Semaphore::new(MAX_PROFILE_CONCURRENCY)),
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

    pub fn autonomous_enabled(&self) -> bool {
        self.profile_runtime.current().settings.autonomous_workers
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

    pub async fn upsert(
        self: &Arc<Self>,
        bundle: WorkerBundle,
        predecessor: Option<&str>,
    ) -> Result<UpsertOutcome, String> {
        self.reject_secret_material_in_bundle(&bundle)?;
        let mut prepared = self.store.prepare(bundle, predecessor)?;
        if let Err(error) = self.prepare_dependencies_and_test(&mut prepared).await {
            self.store.abandon(&prepared);
            return Err(error);
        }
        self.store.finalize(&mut prepared)?;
        let outcome = self.store.publish(prepared)?;
        self.stop_obsolete_residents(&outcome.worker.worker_id, &outcome.version)
            .await;
        self.reset_worker_stop(&outcome.worker.worker_id);
        if let Err(error) = self.register_dynamic_tool(&outcome.worker.worker_id).await {
            let reason = self
                .handle_tool_activation_failure(
                    &outcome.worker.worker_id,
                    &outcome.version,
                    "activation",
                    &error,
                )
                .await;
            return Err(reason);
        }
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action": "activated",
                "worker": outcome.worker,
                "version": outcome.version,
            }),
            None,
        )
        .await;
        Ok(outcome)
    }

    async fn handle_tool_activation_failure(
        &self,
        worker_id: &str,
        version: &str,
        phase: &str,
        error: &str,
    ) -> String {
        self.handle_worker_runtime_failure(
            worker_id,
            version,
            phase,
            &format!("dynamic tool {phase} failed: {error}"),
        )
        .await
    }

    async fn handle_worker_runtime_failure(
        &self,
        worker_id: &str,
        version: &str,
        phase: &str,
        error: &str,
    ) -> String {
        let secrets = self.load_all_vault_secrets().unwrap_or_default();
        let reason = redact_known_secrets(error, &secrets);
        let mut recording_failures = Vec::new();
        if let Err(recording_error) = self.store.mark_failed(worker_id, phase, &reason) {
            recording_failures.push(format!("disable failed worker: {recording_error}"));
        }
        if let Err(recording_error) = self.store.record_system_inbox(
            worker_id,
            phase,
            &json!({
                "status":"failed",
                "phase":phase,
                "workerId":worker_id,
                "version":version,
                "error":reason,
                "disabled":true,
            }),
        ) {
            recording_failures.push(format!("record failure inbox: {recording_error}"));
        }
        self.cancel_worker(worker_id);
        self.unregister_dynamic_tool(worker_id).await;
        self.stop_residents(Some(worker_id)).await;
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action":"failed",
                "phase":phase,
                "workerId":worker_id,
                "version":version,
                "reason":reason,
                "disabled":true,
            }),
            None,
        )
        .await;
        if recording_failures.is_empty() {
            reason
        } else {
            format!("{reason}; {}", recording_failures.join("; "))
        }
    }

    async fn prepare_dependencies_and_test(
        &self,
        prepared: &mut PreparedWorker,
    ) -> Result<(), String> {
        let workdir = prepared.staging_dir.join("files");
        let dependencies = prepared.staging_dir.join("dependencies");
        let runtime = prepared.staging_dir.join("dependency-runtime");
        let secrets = self.load_secrets(&prepared.bundle)?;
        let redactions = self.load_all_vault_secrets()?;
        let mut install_evidence = Vec::new();
        let mut smoke_evidence = Vec::new();
        let mut health_evidence = Vec::new();
        std::fs::create_dir_all(&dependencies).map_err(|error| error.to_string())?;
        std::fs::create_dir_all(&runtime).map_err(|error| error.to_string())?;
        for index in 0..prepared.bundle.dependencies.len() {
            let dependency = prepared.bundle.dependencies[index].clone();
            let dependency_dir = dependencies.join(&dependency.name);
            let actual_checksum = self
                .fetch_dependency(&dependency, &dependency_dir)
                .await
                .map_err(|error| redact_known_secrets(&error, &redactions))?;
            prepared.bundle.dependencies[index].checksum = Some(actual_checksum);
            if let Some(install) = &dependency.install {
                let output = run_worker_command(install, &dependency_dir, None, &secrets, None)
                    .await
                    .map_err(|error| redact_known_secrets(&error, &redactions))?;
                install_evidence.push(json!({
                    "dependency":dependency.name,
                    "command":install.command,
                    "output":redact_json_known_secrets(output, &redactions),
                }));
            }
        }
        self.store.seal_resolved_dependencies(prepared)?;
        for test in &prepared.bundle.smoke_tests {
            let output = run_worker_command(test, &workdir, None, &secrets, None)
                .await
                .map_err(|error| redact_known_secrets(&error, &redactions))?;
            smoke_evidence.push(json!({
                "command":test.command,
                "output":redact_json_known_secrets(output, &redactions),
            }));
        }
        for check in &prepared.bundle.health_checks {
            let output = run_worker_command(check, &workdir, None, &secrets, None)
                .await
                .map_err(|error| redact_known_secrets(&error, &redactions))?;
            health_evidence.push(json!({
                "command":check.command,
                "output":redact_json_known_secrets(output, &redactions),
            }));
        }
        let verification = json!({
            "format":"tron.worker_verification.v1",
            "verifiedAt":chrono::Utc::now().to_rfc3339(),
            "dependencies":prepared.bundle.dependencies,
            "dependencyInstalls":install_evidence,
            "smokeTests":smoke_evidence,
            "healthChecks":health_evidence,
            "status":"passed",
        });
        std::fs::write(
            prepared.staging_dir.join("verification.json"),
            serde_json::to_vec_pretty(&verification).map_err(|error| error.to_string())?,
        )
        .map_err(|error| format!("write worker verification evidence: {error}"))?;
        Ok(())
    }

    async fn fetch_dependency(
        &self,
        dependency: &WorkerDependency,
        destination: &Path,
    ) -> Result<String, String> {
        if destination.exists() {
            std::fs::remove_dir_all(destination).map_err(|error| error.to_string())?;
        }
        std::fs::create_dir_all(destination).map_err(|error| error.to_string())?;
        if let Some(source) = dependency.source.strip_prefix("file://") {
            let source = PathBuf::from(source);
            if source.is_dir() {
                copy_tree(&source, destination)?;
            } else {
                std::fs::copy(&source, destination.join("source"))
                    .map_err(|error| format!("copy dependency '{}': {error}", dependency.name))?;
            }
        } else if let Some(source) = dependency.source.strip_prefix("git+") {
            let clone = WorkerCommand {
                command: vec![
                    "git".to_owned(),
                    "clone".to_owned(),
                    "--quiet".to_owned(),
                    "--no-checkout".to_owned(),
                    source.to_owned(),
                    ".".to_owned(),
                ],
                timeout_seconds: 1_800,
            };
            run_worker_command(&clone, destination, None, &HashMap::new(), None).await?;
            let checkout = WorkerCommand {
                command: vec![
                    "git".to_owned(),
                    "checkout".to_owned(),
                    "--quiet".to_owned(),
                    "--detach".to_owned(),
                    dependency.version.clone(),
                ],
                timeout_seconds: 300,
            };
            run_worker_command(&checkout, destination, None, &HashMap::new(), None).await?;
            let _ = std::fs::remove_dir_all(destination.join(".git"));
        } else {
            let url = url::Url::parse(&dependency.source)
                .map_err(|error| format!("dependency '{}' source URL: {error}", dependency.name))?;
            if !matches!(url.scheme(), "http" | "https") {
                return Err(format!(
                    "dependency '{}' source must use file://, git+https://, http://, or https://",
                    dependency.name
                ));
            }
            let response = self
                .http
                .get(url)
                .send()
                .await
                .map_err(|error| format!("fetch dependency '{}': {error}", dependency.name))?
                .error_for_status()
                .map_err(|error| format!("fetch dependency '{}': {error}", dependency.name))?;
            if response
                .content_length()
                .is_some_and(|length| length > MAX_DEPENDENCY_DOWNLOAD_BYTES as u64)
            {
                return Err(format!("dependency '{}' exceeds 128 MiB", dependency.name));
            }
            let destination_file = destination.join("source");
            let mut file = tokio::fs::File::create(&destination_file)
                .await
                .map_err(|error| format!("store dependency '{}': {error}", dependency.name))?;
            let mut response = response;
            let mut downloaded = 0_usize;
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|error| format!("read dependency '{}': {error}", dependency.name))?
            {
                downloaded = downloaded.saturating_add(chunk.len());
                if downloaded > MAX_DEPENDENCY_DOWNLOAD_BYTES {
                    return Err(format!("dependency '{}' exceeds 128 MiB", dependency.name));
                }
                file.write_all(&chunk)
                    .await
                    .map_err(|error| format!("store dependency '{}': {error}", dependency.name))?;
            }
            file.flush()
                .await
                .map_err(|error| format!("store dependency '{}': {error}", dependency.name))?;
        }
        let actual = format!("sha256:{}", digest_tree(destination)?);
        if let Some(expected) = dependency.checksum.as_deref()
            && !actual.eq_ignore_ascii_case(expected)
        {
            return Err(format!(
                "dependency '{}' checksum mismatch: expected {expected}, got {actual}",
                dependency.name
            ));
        }
        Ok(actual)
    }

    pub async fn invoke(
        self: &Arc<Self>,
        request: InvokeRequest,
    ) -> Result<InvocationRecord, String> {
        let (queued, replayed) = self.enqueue_request(request)?;
        if replayed && queued.status != "queued" {
            return Ok(queued);
        }
        self.execute_queued(queued).await
    }

    pub fn enqueue(&self, request: InvokeRequest) -> Result<InvocationRecord, String> {
        self.enqueue_request(request).map(|(record, _)| record)
    }

    fn enqueue_request(&self, request: InvokeRequest) -> Result<(InvocationRecord, bool), String> {
        if !self.autonomous_enabled() {
            return Err(
                "autonomous workers are disabled for this profile; set autonomousWorkers=true"
                    .to_owned(),
            );
        }
        if self.stopped.load(Ordering::SeqCst) || self.store.stop_all()? {
            return Err("worker dispatch is stopped for this profile".to_owned());
        }
        if request.causal_depth > MAX_CAUSAL_DEPTH {
            return Err(format!(
                "worker causal depth {} exceeds the profile limit {MAX_CAUSAL_DEPTH}",
                request.causal_depth
            ));
        }
        let worker = self.store.load_indexed_active(&request.worker_id)?;
        if !worker.summary.enabled || worker.summary.retired {
            return Err(format!("worker '{}' is not enabled", request.worker_id));
        }
        let worker_function =
            FunctionId::new(format!("worker_kernel::dynamic_{}", request.worker_id))
                .map_err(|error| error.to_string())?;
        crate::engine::validate_engine_schema_payload(
            &worker_function,
            "request",
            &worker.bundle.input_schema,
            &request.input,
        )
        .map_err(|error| format!("worker input does not match its schema: {error}"))?;
        self.reject_secret_material_in_value(&request.input, "worker input")?;
        let (queued, replayed) = self.store.begin_invocation(
            &request.worker_id,
            &worker.summary.active_version,
            &request.input,
            &request.idempotency_key,
            &request.trace_id,
            request.causal_depth,
            &request.trigger_kind,
        )?;
        Ok((queued, replayed))
    }

    async fn execute_queued(
        self: &Arc<Self>,
        queued: InvocationRecord,
    ) -> Result<InvocationRecord, String> {
        let invocation_id = queued.invocation_id.clone();
        if !self.inflight.insert(invocation_id.clone()) {
            return self
                .store
                .invocation(&invocation_id)?
                .ok_or_else(|| "worker invocation disappeared".to_owned());
        }
        let result = self.execute_queued_inner(queued).await;
        let _ = self.inflight.remove(&invocation_id);
        result
    }

    async fn execute_queued_inner(
        self: &Arc<Self>,
        queued: InvocationRecord,
    ) -> Result<InvocationRecord, String> {
        if !self.autonomous_enabled() {
            return Err("worker autonomy was disabled while the invocation was queued".to_owned());
        }
        let summary = self
            .store
            .summary(&queued.worker_id)?
            .ok_or_else(|| format!("worker '{}' was not found", queued.worker_id))?;
        if !summary.enabled || summary.retired {
            return Ok(queued);
        }
        let worker = match self
            .store
            .load_version(&queued.worker_id, &queued.worker_version)
        {
            Ok(worker) => worker,
            Err(error) => {
                return self.fail_queued_integrity_check(queued, &error).await;
            }
        };
        let global_stop = self.execution_stop.lock().await.clone();
        let worker_stop = self.worker_stop(&queued.worker_id);
        let profile_permit = self.profile_limit.clone().acquire_owned();
        let profile_permit = tokio::select! {
            permit = profile_permit => permit,
            () = global_stop.cancelled() => return Err("worker dispatch stopped while queued".to_owned()),
            () = worker_stop.cancelled() => return Err(self.worker_cancelled_error(&queued.worker_id, true)),
        }
            .map_err(|_| "worker profile concurrency gate is closed".to_owned())?;
        let worker_limit = self
            .worker_limits
            .entry(queued.worker_id.clone())
            .or_insert_with(|| Arc::new(Semaphore::new(MAX_WORKER_CONCURRENCY)))
            .clone();
        let worker_permit = tokio::select! {
            permit = worker_limit.acquire_owned() => permit,
            () = global_stop.cancelled() => return Err("worker dispatch stopped while queued".to_owned()),
            () = worker_stop.cancelled() => return Err(self.worker_cancelled_error(&queued.worker_id, true)),
        }
            .map_err(|_| "worker concurrency gate is closed".to_owned())?;
        let _permits = (profile_permit, worker_permit);
        if !self.store.claim_running(&queued.invocation_id)? {
            return self
                .store
                .invocation(&queued.invocation_id)?
                .ok_or_else(|| "claimed worker invocation disappeared".to_owned());
        }

        self.publish_event(
            "worker.invocations",
            json!({
                "action": "started",
                "invocationId": queued.invocation_id,
                "workerId": queued.worker_id,
                "version": queued.worker_version,
                "triggerKind": queued.trigger_kind,
                "causalDepth": queued.causal_depth,
            }),
            TraceId::new(queued.trace_id.clone()).ok(),
        )
        .await;

        let timed = tokio::time::timeout(
            Duration::from_secs(MAX_INVOCATION_SECONDS),
            self.execute_worker(&worker, &queued),
        );
        let execution = tokio::select! {
            result = timed => result
                .map_err(|_| format!("worker invocation exceeded {MAX_INVOCATION_SECONDS} seconds"))
                .and_then(|result| result),
            () = global_stop.cancelled() => Err("worker invocation stopped by profile stop-all".to_owned()),
            () = worker_stop.cancelled() => Err(self.worker_cancelled_error(&queued.worker_id, false)),
        };
        if self.shutting_down.load(Ordering::SeqCst) && global_stop.is_cancelled() {
            return Err("worker invocation interrupted by runtime shutdown".to_owned());
        }
        let was_stopped = global_stop.is_cancelled() || worker_stop.is_cancelled();

        let worker_function =
            FunctionId::new(format!("worker_kernel::dynamic_{}", queued.worker_id))
                .map_err(|error| error.to_string())?;
        let execution = execution.and_then(|output| {
            let secrets = self.load_all_vault_secrets()?;
            let output = redact_json_known_secrets(output, &secrets);
            crate::engine::validate_engine_schema_payload(
                &worker_function,
                "response",
                &worker.bundle.output_schema,
                &output,
            )
            .map_err(|error| format!("worker output does not match its schema: {error}"))?;
            Ok(output)
        });
        let completed = match execution {
            Ok(output) => self.store.complete_invocation(
                &queued.invocation_id,
                &queued.worker_id,
                Ok(&output),
            )?,
            Err(error) => {
                let secrets = self.load_all_vault_secrets().unwrap_or_default();
                let redacted = redact_known_secrets(&error, &secrets);
                if !was_stopped {
                    self.store
                        .mark_failed(&queued.worker_id, "execution", &redacted)?;
                    self.unregister_dynamic_tool(&queued.worker_id).await;
                    self.stop_residents(Some(&queued.worker_id)).await;
                    self.publish_event(
                        "worker.lifecycle",
                        json!({
                            "action":"failed",
                            "phase":"execution",
                            "workerId":queued.worker_id,
                            "version":queued.worker_version,
                            "reason":redacted,
                            "disabled":true,
                        }),
                        TraceId::new(queued.trace_id.clone()).ok(),
                    )
                    .await;
                }
                self.store.complete_invocation(
                    &queued.invocation_id,
                    &queued.worker_id,
                    Err(&redacted),
                )?
            }
        };
        self.publish_event(
            "worker.invocations",
            json!({
                "action": completed.status,
                "invocationId": completed.invocation_id,
                "workerId": completed.worker_id,
                "error": completed.error,
                "causalDepth": completed.causal_depth,
            }),
            TraceId::new(completed.trace_id.clone()).ok(),
        )
        .await;
        if completed.status == "completed" {
            let _ = self.register_dynamic_tool(&completed.worker_id).await;
        }
        Ok(completed)
    }

    async fn fail_queued_integrity_check(
        &self,
        queued: InvocationRecord,
        error: &str,
    ) -> Result<InvocationRecord, String> {
        if !self.store.claim_running(&queued.invocation_id)? {
            return self
                .store
                .invocation(&queued.invocation_id)?
                .ok_or_else(|| {
                    "worker invocation disappeared during integrity failure".to_owned()
                });
        }
        let secrets = self.load_all_vault_secrets().unwrap_or_default();
        let reason = redact_known_secrets(
            &format!("worker immutable-version integrity check failed: {error}"),
            &secrets,
        );
        self.store
            .mark_failed(&queued.worker_id, "integrity", &reason)?;
        self.cancel_worker(&queued.worker_id);
        self.unregister_dynamic_tool(&queued.worker_id).await;
        self.stop_residents(Some(&queued.worker_id)).await;
        let completed = self.store.complete_invocation(
            &queued.invocation_id,
            &queued.worker_id,
            Err(&reason),
        )?;
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action":"failed",
                "phase":"integrity",
                "workerId":queued.worker_id,
                "version":queued.worker_version,
                "reason":reason,
                "disabled":true,
            }),
            TraceId::new(queued.trace_id.clone()).ok(),
        )
        .await;
        self.publish_event(
            "worker.invocations",
            json!({
                "action":completed.status,
                "invocationId":completed.invocation_id,
                "workerId":completed.worker_id,
                "error":completed.error,
                "causalDepth":completed.causal_depth,
            }),
            TraceId::new(completed.trace_id.clone()).ok(),
        )
        .await;
        Ok(completed)
    }

    async fn execute_worker(
        self: &Arc<Self>,
        worker: &ActiveWorker,
        invocation: &InvocationRecord,
    ) -> Result<Value, String> {
        let secrets = self.load_secrets(&worker.bundle)?;
        match &worker.bundle.runner {
            WorkerRunner::Agent {
                instructions,
                model,
            } => {
                self.execute_agent(worker, invocation, instructions, model.as_deref(), &secrets)
                    .await
            }
            WorkerRunner::Command { command } => {
                let (runtime_root, workdir) = self.materialize_runtime_artifact(
                    worker,
                    "worker-invocations",
                    &invocation.invocation_id,
                )?;
                let _runtime_cleanup = RemoveDirectoryOnDrop(runtime_root);
                let command = WorkerCommand {
                    command: command.clone(),
                    timeout_seconds: MAX_INVOCATION_SECONDS,
                };
                run_worker_command(
                    &command,
                    &workdir,
                    Some(&invocation.input),
                    &secrets,
                    Some(invocation),
                )
                .await
            }
            WorkerRunner::Service {
                command,
                invoke_url,
                health_url,
            } => {
                let key = resident_key(worker);
                let users = self
                    .resident_users
                    .entry(key.clone())
                    .or_insert_with(|| Arc::new(AtomicUsize::new(0)))
                    .clone();
                users.fetch_add(1, Ordering::SeqCst);
                let result = async {
                    self.ensure_resident(worker, command, health_url.as_deref(), &secrets)
                        .await?;
                    let mut response = self
                        .http
                        .post(invoke_url)
                        .header("x-tron-invocation-id", &invocation.invocation_id)
                        .header("x-tron-idempotency-key", &invocation.idempotency_key)
                        .header("x-tron-trace-id", &invocation.trace_id)
                        .header("x-tron-causal-depth", invocation.causal_depth.to_string())
                        .header("x-tron-trigger-kind", &invocation.trigger_kind)
                        .json(&invocation.input)
                        .send()
                        .await
                        .map_err(|error| format!("invoke resident worker: {error}"))?;
                    let status = response.status();
                    let bytes = read_http_body_limited(
                        &mut response,
                        MAX_PROCESS_CAPTURE_BYTES,
                        "resident worker response",
                    )
                    .await?;
                    if !status.is_success() {
                        return Err(format!(
                            "resident worker returned {status}: {}",
                            String::from_utf8_lossy(&bytes)
                        ));
                    }
                    serde_json::from_slice(&bytes)
                        .map_err(|error| format!("decode resident worker response: {error}"))
                }
                .await;
                let remaining = users.fetch_sub(1, Ordering::SeqCst).saturating_sub(1);
                let is_current = self
                    .store
                    .summary(&worker.summary.worker_id)
                    .ok()
                    .flatten()
                    .is_some_and(|summary| {
                        summary.enabled && summary.active_version == worker.summary.active_version
                    });
                if remaining == 0 && !is_current {
                    self.stop_resident_key(&key).await;
                }
                result
            }
        }
    }

    fn materialize_runtime_artifact(
        &self,
        worker: &ActiveWorker,
        category: &str,
        identity: &str,
    ) -> Result<(PathBuf, PathBuf), String> {
        let runtime_root = self
            .store
            .home()
            .join("internal")
            .join("run")
            .join(category)
            .join(identity);
        if runtime_root.exists() {
            std::fs::remove_dir_all(&runtime_root)
                .map_err(|error| format!("reset worker runtime artifact: {error}"))?;
        }
        let artifact = runtime_root.join("artifact");
        copy_tree(&worker.version_dir, &artifact)?;
        Ok((runtime_root, artifact.join("files")))
    }

    async fn execute_agent(
        &self,
        worker: &ActiveWorker,
        invocation: &InvocationRecord,
        instructions: &str,
        model: Option<&str>,
        secrets: &HashMap<String, String>,
    ) -> Result<Value, String> {
        let (ephemeral, workdir) = self.materialize_runtime_artifact(
            worker,
            "worker-invocations",
            &invocation.invocation_id,
        )?;
        let _ephemeral_cleanup = RemoveDirectoryOnDrop(ephemeral.clone());
        let secret_dir = ephemeral.join("secrets");
        if !secrets.is_empty() {
            std::fs::create_dir_all(&secret_dir)
                .map_err(|error| format!("create worker secret directory: {error}"))?;
            for (name, value) in secrets {
                let path = secret_dir.join(name);
                std::fs::write(&path, value)
                    .map_err(|error| format!("materialize worker secret binding: {error}"))?;
                set_owner_only(&path)?;
            }
        }
        let default_model = self
            .profile_runtime
            .current()
            .settings
            .server
            .default_model
            .clone();
        let session_id = self
            .session_manager
            .create_session(
                model.unwrap_or(&default_model),
                &workdir.display().to_string(),
                Some(&format!("Worker: {}", worker.summary.name)),
            )
            .map_err(|error| format!("create agent worker session: {error}"))?;
        let prompt = format!(
            "You are executing persistent worker '{}'. Follow its durable contract exactly.\n\n{}\n\nInvocation metadata (preserve the idempotency key when deduplicating side effects):\n{}\n\nInput JSON:\n{}\n\nNamed secrets, when configured, are available as files under {}. Never reveal their values. Return only the result required by the output schema.",
            worker.summary.name,
            instructions,
            serde_json::to_string_pretty(&json!({
                "invocationId":invocation.invocation_id,
                "idempotencyKey":invocation.idempotency_key,
                "traceId":invocation.trace_id,
                "causalDepth":invocation.causal_depth,
                "triggerKind":invocation.trigger_kind,
            }))
            .map_err(|error| error.to_string())?,
            serde_json::to_string_pretty(&invocation.input).map_err(|error| error.to_string())?,
            secret_dir.display(),
        );
        let context = CausalContext::trusted_local(
            ActorId::new(format!("worker:{}", worker.summary.worker_id))
                .map_err(|error| error.to_string())?,
            ActorKind::Worker,
            TraceId::new(invocation.trace_id.clone()).unwrap_or_else(|_| TraceId::generate()),
        )
        .with_scope("agent.write")
        .with_session_id(session_id.clone())
        .with_idempotency_key(format!(
            "worker-agent:{}",
            hex::encode(Sha256::digest(invocation.idempotency_key.as_bytes()))
        ))
        .with_runtime_metadata(
            RUNTIME_METADATA_TRIGGER_DEPTH,
            invocation.causal_depth.saturating_add(1).to_string(),
        );
        let mut agent_run_guard =
            AbortAgentRunOnDrop::new(Arc::clone(&self.orchestrator), session_id.clone());
        let outcome = self
            .host
            .invoke(Invocation::new_sync(
                FunctionId::new("agent::prompt").map_err(|error| error.to_string())?,
                json!({"sessionId":session_id,"prompt":prompt,"source":"worker"}),
                context,
            ))
            .await;
        if let Some(error) = outcome.error {
            return Err(format!("start agent worker: {error}"));
        }
        loop {
            if self.orchestrator.get_run_id(&session_id).is_none() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        agent_run_guard.disarm();
        let rows = self
            .event_store
            .get_latest_events(&session_id, Some(100))
            .map_err(|error| format!("load agent worker result: {error}"))?;
        let payloads = self
            .event_store
            .resolve_event_payloads(&rows)
            .map_err(|error| format!("resolve agent worker result: {error}"))?;
        rows.iter()
            .zip(payloads)
            .rev()
            .find(|(row, _)| row.event_type == "message.assistant")
            .map(|(_, payload)| {
                normalize_agent_output(payload.get("content").cloned().unwrap_or(payload))
            })
            .ok_or_else(|| "agent worker completed without an assistant result".to_owned())
    }

    async fn ensure_resident(
        &self,
        worker: &ActiveWorker,
        command: &[String],
        health_url: Option<&str>,
        secrets: &HashMap<String, String>,
    ) -> Result<(), String> {
        let process = self
            .residents
            .entry(resident_key(worker))
            .or_insert_with(|| {
                Arc::new(Mutex::new(ResidentProcess {
                    child: None,
                    consecutive_health_failures: 0,
                    runtime_root: None,
                }))
            })
            .clone();
        let mut process = process.lock().await;
        let still_running = match process.child.as_mut() {
            Some(child) => child
                .try_wait()
                .map_err(|error| error.to_string())?
                .is_none(),
            None => false,
        };
        if !still_running {
            if let Some(child) = process.child.as_mut() {
                child.terminate().await;
            }
            if let Some(runtime_root) = process.runtime_root.take() {
                let _ = std::fs::remove_dir_all(runtime_root);
            }
            let (runtime_root, workdir) = self.materialize_runtime_artifact(
                worker,
                "worker-services",
                &format!("{}-{}", worker.summary.worker_id, uuid::Uuid::now_v7()),
            )?;
            let child = spawn_process(
                command,
                &workdir,
                secrets,
                Stdio::null(),
                // Resident output is not part of an invocation result. Leaving
                // stderr piped without a reader eventually blocks a normally
                // logging service once the OS pipe fills.
                Stdio::null(),
                None,
            );
            let child = match child {
                Ok(child) => child,
                Err(error) => {
                    let _ = std::fs::remove_dir_all(&runtime_root);
                    return Err(error);
                }
            };
            process.child = Some(child);
            process.runtime_root = Some(runtime_root);
            process.consecutive_health_failures = 0;
            if let Some(url) = health_url {
                let mut healthy = false;
                for _ in 0..50 {
                    if self
                        .http
                        .get(url)
                        .send()
                        .await
                        .is_ok_and(|response| response.status().is_success())
                    {
                        healthy = true;
                        break;
                    }
                    if process
                        .child
                        .as_mut()
                        .expect("resident was just spawned")
                        .try_wait()
                        .map_err(|error| error.to_string())?
                        .is_some()
                    {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                if !healthy {
                    if let Some(child) = process.child.as_mut() {
                        child.terminate().await;
                    }
                    if let Some(runtime_root) = process.runtime_root.take() {
                        let _ = std::fs::remove_dir_all(runtime_root);
                    }
                    return Err("resident worker failed its startup health check".to_owned());
                }
            }
        }
        Ok(())
    }

    pub async fn set_enabled(
        self: &Arc<Self>,
        worker_id: &str,
        enabled: bool,
    ) -> Result<Value, String> {
        let worker = self.store.set_enabled(worker_id, enabled)?;
        if enabled {
            self.reset_worker_stop(worker_id);
            if self.autonomous_enabled()
                && let Err(error) = self.register_dynamic_tool(worker_id).await
            {
                return Err(self
                    .handle_tool_activation_failure(
                        worker_id,
                        &worker.active_version,
                        "enable",
                        &error,
                    )
                    .await);
            }
        } else {
            self.cancel_worker(worker_id);
            self.unregister_dynamic_tool(worker_id).await;
            self.stop_residents(Some(worker_id)).await;
        }
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action":if enabled { "enabled" } else { "disabled" },
                "worker":&worker,
                "version":&worker.active_version,
            }),
            None,
        )
        .await;
        serde_json::to_value(worker).map_err(|error| error.to_string())
    }

    /// Cancel this worker's current execution generation without changing its
    /// durable enabled state, route, or triggers. Active invocations retain a
    /// clone of the cancelled token; resetting the map entry after resident
    /// shutdown lets later work dispatch immediately.
    pub async fn stop_worker(self: &Arc<Self>, worker_id: &str) -> Result<Value, String> {
        let worker = self
            .store
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        self.store
            .record_stopped(worker_id, &worker.active_version)?;
        self.cancel_worker(worker_id);
        self.stop_residents(Some(worker_id)).await;
        if worker.enabled && !worker.retired {
            self.reset_worker_stop(worker_id);
        }
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action":"stopped",
                "workerId":worker_id,
                "version":worker.active_version,
                "enabled":worker.enabled,
                "retired":worker.retired,
            }),
            None,
        )
        .await;
        serde_json::to_value(worker).map_err(|error| error.to_string())
    }

    pub async fn rollback(
        self: &Arc<Self>,
        worker_id: &str,
        version: &str,
    ) -> Result<Value, String> {
        let (worker, webhooks) = self.store.rollback(worker_id, version)?;
        self.stop_obsolete_residents(worker_id, version).await;
        self.reset_worker_stop(worker_id);
        if self.autonomous_enabled()
            && let Err(error) = self.register_dynamic_tool(worker_id).await
        {
            return Err(self
                .handle_tool_activation_failure(worker_id, version, "rollback", &error)
                .await);
        }
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action":"rolled_back",
                "worker":&worker,
                "version":version,
            }),
            None,
        )
        .await;
        Ok(json!({"worker":worker,"webhooks":webhooks}))
    }

    pub async fn retire(self: &Arc<Self>, worker_id: &str) -> Result<Value, String> {
        let worker = self.store.retire(worker_id)?;
        self.cancel_worker(worker_id);
        self.stop_residents(Some(worker_id)).await;
        self.unregister_dynamic_tool(worker_id).await;
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action":"retired",
                "worker":&worker,
                "version":&worker.active_version,
            }),
            None,
        )
        .await;
        serde_json::to_value(worker).map_err(|error| error.to_string())
    }

    pub async fn purge(self: &Arc<Self>, worker_id: &str) -> Result<bool, String> {
        self.cancel_worker(worker_id);
        self.stop_residents(Some(worker_id)).await;
        self.unregister_dynamic_tool(worker_id).await;
        let purged = self.store.purge(worker_id)?;
        if purged {
            self.publish_event(
                "worker.lifecycle",
                json!({"action":"purged","workerId":worker_id}),
                None,
            )
            .await;
        }
        Ok(purged)
    }

    pub async fn set_stop_all(&self, stopped: bool) -> Result<(), String> {
        self.store.set_stop_all(stopped)?;
        self.stopped.store(stopped, Ordering::SeqCst);
        if stopped {
            self.execution_stop.lock().await.cancel();
            self.stop_residents(None).await;
        } else if self.autonomous_enabled() {
            *self.execution_stop.lock().await = CancellationToken::new();
        }
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action":if stopped { "stop_all" } else { "resumed_all" },
                "stopped":stopped,
            }),
            None,
        )
        .await;
        Ok(())
    }

    fn worker_stop(&self, worker_id: &str) -> CancellationToken {
        self.worker_stops
            .entry(worker_id.to_owned())
            .or_insert_with(CancellationToken::new)
            .clone()
    }

    fn cancel_worker(&self, worker_id: &str) {
        self.worker_stop(worker_id).cancel();
    }

    fn reset_worker_stop(&self, worker_id: &str) {
        let _ = self
            .worker_stops
            .insert(worker_id.to_owned(), CancellationToken::new());
    }

    fn worker_cancelled_error(&self, worker_id: &str, queued: bool) -> String {
        let remains_enabled = self
            .store
            .summary(worker_id)
            .ok()
            .flatten()
            .is_some_and(|worker| worker.enabled && !worker.retired);
        match (remains_enabled, queued) {
            (true, true) => "worker was stopped while queued".to_owned(),
            (true, false) => "worker invocation stopped by per-worker stop".to_owned(),
            (false, true) => "worker was disabled while queued".to_owned(),
            (false, false) => {
                "worker invocation stopped because the worker was disabled".to_owned()
            }
        }
    }

    async fn apply_autonomy_state(self: &Arc<Self>, enabled: bool) -> Result<(), String> {
        let visibility = self.sync_kernel_primitive_visibility(enabled).await;
        if enabled {
            visibility?;
            if !self.stopped.load(Ordering::SeqCst) {
                *self.execution_stop.lock().await = CancellationToken::new();
            }
            self.register_active_tools().await?;
        } else {
            self.execution_stop.lock().await.cancel();
            self.stop_residents(None).await;
            let unregistration = self.unregister_all_dynamic_tools().await;
            visibility?;
            unregistration?;
        }
        self.publish_event(
            "worker.lifecycle",
            json!({
                "action": if enabled { "autonomy_enabled" } else { "autonomy_disabled" },
                "autonomousWorkers": enabled,
            }),
            None,
        )
        .await;
        Ok(())
    }

    async fn sync_kernel_primitive_visibility(&self, enabled: bool) -> Result<(), String> {
        let previous = self.kernel_visibility.load(Ordering::SeqCst);
        if previous == enabled {
            return Ok(());
        }
        let registrations = self
            .kernel_primitives
            .read()
            .map_err(|_| "worker kernel primitive registry is poisoned".to_owned())?
            .clone();
        let mut prepared = Vec::with_capacity(registrations.len());
        for registration in registrations {
            let handler = registration.handler.upgrade().ok_or_else(|| {
                format!(
                    "worker kernel handler for {} is no longer registered",
                    registration.definition.id.as_str()
                )
            })?;
            let mut next = registration.definition.clone();
            let metadata = next.metadata.as_object_mut().ok_or_else(|| {
                format!(
                    "worker kernel metadata for {} is not an object",
                    next.id.as_str()
                )
            })?;
            let _ = metadata.insert("modelPrimitive".to_owned(), Value::Bool(enabled));
            let mut rollback = registration.definition;
            let rollback_metadata = rollback.metadata.as_object_mut().ok_or_else(|| {
                format!(
                    "worker kernel metadata for {} is not an object",
                    rollback.id.as_str()
                )
            })?;
            let _ = rollback_metadata.insert("modelPrimitive".to_owned(), Value::Bool(previous));
            prepared.push((next, rollback, handler));
        }

        let mut updated = 0;
        for (next, _, handler) in &prepared {
            if let Err(error) = self
                .host
                .register_function(next.clone(), Some(Arc::clone(handler)), false)
                .await
            {
                let mut rollback_failures = Vec::new();
                for (_, rollback, rollback_handler) in prepared.iter().take(updated).rev() {
                    if let Err(rollback_error) = self
                        .host
                        .register_function(
                            rollback.clone(),
                            Some(Arc::clone(rollback_handler)),
                            false,
                        )
                        .await
                    {
                        rollback_failures.push(rollback_error.to_string());
                    }
                }
                let rollback_evidence = if rollback_failures.is_empty() {
                    String::new()
                } else {
                    format!(
                        "; visibility rollback failures: {}",
                        rollback_failures.join(" | ")
                    )
                };
                return Err(format!(
                    "update worker kernel tool visibility for {}: {error}{rollback_evidence}",
                    next.id.as_str()
                ));
            }
            updated += 1;
        }
        self.kernel_visibility.store(enabled, Ordering::SeqCst);
        Ok(())
    }

    async fn unregister_all_dynamic_tools(&self) -> Result<(), String> {
        for worker in self.store.list(true)? {
            self.unregister_dynamic_tool(&worker.worker_id).await;
        }
        Ok(())
    }

    async fn register_active_tools(self: &Arc<Self>) -> Result<(), String> {
        let mut failures = Vec::new();
        for worker in self.store.list(false)? {
            if !worker.enabled || worker.retired {
                continue;
            }
            if let Err(error) = self.register_dynamic_tool(&worker.worker_id).await {
                failures.push(
                    self.handle_tool_activation_failure(
                        &worker.worker_id,
                        &worker.active_version,
                        "startup",
                        &error,
                    )
                    .await,
                );
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(failures.join(" | "))
        }
    }

    async fn register_dynamic_tool(self: &Arc<Self>, worker_id: &str) -> Result<(), String> {
        if !self.autonomous_enabled() {
            self.unregister_dynamic_tool(worker_id).await;
            return Ok(());
        }
        let active = self.store.load_active(worker_id)?;
        let success_evidence = self.store.success_evidence(worker_id)?;
        let provenance = active
            .bundle
            .provenance
            .iter()
            .take(3)
            .map(|source| {
                source.revision.as_ref().map_or_else(
                    || source.source.clone(),
                    |revision| format!("{}@{revision}", source.source),
                )
            })
            .collect::<Vec<_>>()
            .join(", ");
        let model_description = format!(
            "{}\nPersistent worker evidence: health={}; activeVersion={}; completedRuns={}; lastCompletedAt={}; provenance={}",
            active.summary.description,
            active.summary.health,
            active.summary.active_version,
            success_evidence["completedRuns"].as_u64().unwrap_or(0),
            success_evidence["lastCompletedAt"]
                .as_str()
                .unwrap_or("none"),
            provenance,
        );
        let function_id = FunctionId::new(format!("worker_kernel::dynamic_{worker_id}"))
            .map_err(|error| error.to_string())?;
        let mut definition = FunctionDefinition::new(
            function_id,
            WorkerId::new("worker_kernel").map_err(|error| error.to_string())?,
            model_description,
            VisibilityScope::System,
            EffectClass::ExternalSideEffect,
        )
        .with_risk(RiskLevel::High)
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_request_schema(active.bundle.input_schema.clone())
        .with_response_schema(active.bundle.output_schema.clone())
        .with_health(FunctionHealth::Healthy);
        definition.metadata = json!({
            "modelPrimitive": true,
            "modelPrimitiveName": active.summary.tool_name,
            "workerId": active.summary.worker_id,
            "workerVersion": active.summary.active_version,
            "workerDynamic": true,
            "workerRouting": active.bundle.routing,
            "workerProvenance": active.bundle.provenance,
            "workerHealth": active.summary.health,
            "workerSuccessEvidence": success_evidence,
            "trustedLocalKernel": true,
            "contextPrimerLevel": "relevant",
        });
        self.host
            .register_function(
                definition,
                Some(Arc::new(DynamicWorkerHandler {
                    runtime: Arc::clone(self),
                    worker_id: worker_id.to_owned(),
                })),
                false,
            )
            .await
            .map_err(|error| format!("register dynamic worker tool: {error}"))?;
        if !self.autonomous_enabled() {
            self.unregister_dynamic_tool(worker_id).await;
        }
        Ok(())
    }

    async fn unregister_dynamic_tool(&self, worker_id: &str) {
        let Ok(function_id) = FunctionId::new(format!("worker_kernel::dynamic_{worker_id}")) else {
            return;
        };
        let Ok(owner) = WorkerId::new("worker_kernel") else {
            return;
        };
        let _ = self.host.unregister_function(&function_id, &owner).await;
    }

    async fn run_dispatcher(
        self: &Arc<Self>,
        cancellation: CancellationToken,
        mut applied_autonomy: Option<bool>,
    ) {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut runs = JoinSet::new();
        loop {
            tokio::select! {
                () = cancellation.cancelled() => break,
                _ = ticker.tick() => {
                    let autonomous = self.autonomous_enabled();
                    if applied_autonomy != Some(autonomous) {
                        match self.apply_autonomy_state(autonomous).await {
                            Ok(()) => applied_autonomy = Some(autonomous),
                            Err(error) => {
                                tracing::error!(%error, autonomous, "failed to apply live worker autonomy state");
                                applied_autonomy = None;
                                continue;
                            }
                        }
                    }
                    if autonomous && !self.stopped.load(Ordering::SeqCst) {
                        if self.execution_stop.lock().await.is_cancelled() {
                            *self.execution_stop.lock().await = CancellationToken::new();
                        }
                        self.dispatch_resident_supervision(&mut runs);
                        self.dispatch_queued(&mut runs).await;
                        self.dispatch_schedules(&mut runs).await;
                        self.dispatch_events(&mut runs).await;
                    }
                }
                Some(_) = runs.join_next(), if !runs.is_empty() => {}
            }
        }
        runs.abort_all();
        self.shutdown().await;
    }

    async fn dispatch_queued(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let Ok(queued) = self.store.queued_invocations(128) else {
            return;
        };
        for invocation in queued {
            if self.inflight.contains(&invocation.invocation_id) {
                continue;
            }
            let runtime = Arc::clone(self);
            runs.spawn(async move {
                let _ = runtime.execute_queued(invocation).await;
            });
        }
    }

    async fn dispatch_schedules(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let Ok(due) = self.store.due_schedules() else {
            return;
        };
        for (worker_id, trigger, due_at) in due {
            let WorkerTrigger::Schedule {
                id,
                every_seconds,
                input,
            } = trigger
            else {
                continue;
            };
            let queued = self.enqueue_request(InvokeRequest {
                worker_id: worker_id.clone(),
                input,
                idempotency_key: format!("schedule:{id}:{due_at}"),
                trace_id: format!("worker-schedule-{}", uuid::Uuid::now_v7()),
                causal_depth: 0,
                trigger_kind: "schedule".to_owned(),
            });
            let Ok((queued, _)) = queued else {
                continue;
            };
            if self
                .store
                .advance_schedule(&worker_id, &id, every_seconds)
                .is_err()
            {
                continue;
            }
            let runtime = Arc::clone(self);
            runs.spawn(async move {
                let _ = runtime.execute_queued(queued).await;
            });
        }
    }

    async fn dispatch_events(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let Ok(triggers) = self.store.event_triggers() else {
            return;
        };
        for (worker_id, trigger, cursor) in triggers {
            let WorkerTrigger::EngineEvent {
                id,
                topic,
                filter,
                input,
            } = trigger
            else {
                continue;
            };
            let page = self
                .host
                .poll_stream_topic(
                    &topic,
                    StreamCursor(u64::try_from(cursor).unwrap_or_default()),
                    100,
                    &StreamActorScope::admin(),
                )
                .await;
            let Ok(page) = page else {
                continue;
            };
            let active = match self.store.load_active(&worker_id) {
                Ok(active) => active,
                Err(_) => continue,
            };
            let worker_function =
                match FunctionId::new(format!("worker_kernel::dynamic_{worker_id}")) {
                    Ok(function) => function,
                    Err(_) => continue,
                };
            let next_cursor = page.next_cursor.0;
            let mut durable = Vec::new();
            let mut persistence_failed = false;
            for event in page.events {
                if !json_subset_matches(&filter, &event.payload) {
                    continue;
                }
                let merged = materialize_engine_event_input(
                    &input,
                    &event.payload,
                    &active.bundle.input_schema,
                );
                let event_cursor = event.cursor.0;
                let event_worker = worker_id.clone();
                let event_trigger = id.clone();
                let causal_depth = event
                    .payload
                    .get("causalDepth")
                    .and_then(Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
                    .unwrap_or(0)
                    .saturating_add(1);
                let idempotency_key = format!("event:{event_trigger}:{event_cursor}");
                let trace_id = event.trace_id.as_ref().map_or_else(
                    || format!("worker-event-{}", uuid::Uuid::now_v7()),
                    |id| id.as_str().to_owned(),
                );
                if causal_depth > MAX_CAUSAL_DEPTH {
                    if self
                        .store
                        .record_trigger_suppression(
                            &trace_id,
                            &event_worker,
                            "engine_event",
                            &idempotency_key,
                            causal_depth,
                            "causal_depth_limit",
                        )
                        .is_err()
                    {
                        persistence_failed = true;
                        break;
                    }
                    continue;
                }
                let input_validation = crate::engine::validate_engine_schema_payload(
                    &worker_function,
                    "request",
                    &active.bundle.input_schema,
                    &merged,
                )
                .map_err(|error| format!(
                    "engine-event trigger '{event_trigger}' produced input outside inputSchema: {error}"
                ))
                .and_then(|()| {
                    self.reject_secret_material_in_value(&merged, "engine-event worker input")
                });
                if let Err(error) = input_validation {
                    let _ = self
                        .handle_worker_runtime_failure(
                            &worker_id,
                            &active.summary.active_version,
                            "trigger_dispatch",
                            &error,
                        )
                        .await;
                    if self
                        .store
                        .summary(&worker_id)
                        .ok()
                        .flatten()
                        .is_none_or(|summary| summary.enabled)
                    {
                        persistence_failed = true;
                    }
                    break;
                }
                match self.enqueue_request(InvokeRequest {
                    worker_id: event_worker,
                    input: merged,
                    idempotency_key,
                    trace_id,
                    causal_depth,
                    trigger_kind: "engine_event".to_owned(),
                }) {
                    Ok((queued, _)) => durable.push(queued),
                    Err(_) => {
                        persistence_failed = true;
                        break;
                    }
                }
            }
            if !persistence_failed {
                let _ = self.store.update_stream_cursor(
                    &worker_id,
                    &id,
                    i64::try_from(next_cursor).unwrap_or(i64::MAX),
                );
            }
            for queued in durable {
                let runtime = Arc::clone(self);
                runs.spawn(async move {
                    let _ = runtime.execute_queued(queued).await;
                });
            }
        }
    }

    fn dispatch_resident_supervision(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let residents = self
            .residents
            .iter()
            .map(|entry| (entry.key().clone(), Arc::clone(entry.value())))
            .collect::<Vec<_>>();
        for (key, process) in residents {
            if !self.resident_supervisions.insert(key.clone()) {
                continue;
            }
            let runtime = Arc::clone(self);
            runs.spawn(async move {
                runtime.supervise_resident(&key, process).await;
                let _ = runtime.resident_supervisions.remove(&key);
            });
        }
    }

    #[cfg(test)]
    async fn supervise_residents(self: &Arc<Self>) {
        let mut runs = JoinSet::new();
        self.dispatch_resident_supervision(&mut runs);
        while runs.join_next().await.is_some() {}
    }

    async fn supervise_resident(&self, key: &str, process: Arc<Mutex<ResidentProcess>>) {
        let Some((worker_id, version)) = key.rsplit_once('@') else {
            return;
        };
        if !self.resident_is_current(worker_id, version)
            || !self.resident_process_is_registered(key, &process)
        {
            return;
        }

        let exited = {
            let mut process = process.lock().await;
            match process.child.as_mut() {
                Some(child) => match child.try_wait() {
                    Ok(Some(status)) => {
                        process.child = None;
                        Some(format!("resident service exited with {status}"))
                    }
                    Ok(None) => None,
                    Err(error) => Some(format!(
                        "resident service process supervision failed: {error}"
                    )),
                },
                None => Some("resident service process disappeared".to_owned()),
            }
        };
        if let Some(error) = exited {
            if self.resident_is_current(worker_id, version)
                && self.resident_process_is_registered(key, &process)
            {
                let _ = self
                    .handle_worker_runtime_failure(
                        worker_id,
                        version,
                        "resident_supervision",
                        &error,
                    )
                    .await;
            }
            return;
        }

        let worker = match self.store.load_version(worker_id, version) {
            Ok(worker) => worker,
            Err(error) => {
                if self.resident_is_current(worker_id, version)
                    && self.resident_process_is_registered(key, &process)
                {
                    let _ = self
                        .handle_worker_runtime_failure(
                            worker_id,
                            version,
                            "resident_supervision",
                            &format!("load resident worker version for supervision: {error}"),
                        )
                        .await;
                }
                return;
            }
        };
        let WorkerRunner::Service { health_url, .. } = worker.bundle.runner else {
            return;
        };
        let Some(health_url) = health_url else {
            return;
        };
        let health = self
            .http
            .get(&health_url)
            .timeout(RESIDENT_HEALTH_TIMEOUT)
            .send()
            .await;
        if !self.resident_is_current(worker_id, version)
            || !self.resident_process_is_registered(key, &process)
        {
            return;
        }
        let healthy = health
            .as_ref()
            .is_ok_and(|response| response.status().is_success());
        let failure = {
            let mut process = process.lock().await;
            if healthy {
                process.consecutive_health_failures = 0;
                None
            } else {
                process.consecutive_health_failures =
                    process.consecutive_health_failures.saturating_add(1);
                (process.consecutive_health_failures >= RESIDENT_HEALTH_FAILURE_LIMIT).then(
                    || match health {
                        Ok(response) => format!(
                            "resident health endpoint {health_url} returned {} {} consecutive times",
                            response.status(),
                            process.consecutive_health_failures
                        ),
                        Err(error) => format!(
                            "resident health endpoint {health_url} failed {} consecutive times: {error}",
                            process.consecutive_health_failures
                        ),
                    },
                )
            }
        };
        if let Some(error) = failure
            && self.resident_is_current(worker_id, version)
            && self.resident_process_is_registered(key, &process)
        {
            let _ = self
                .handle_worker_runtime_failure(worker_id, version, "resident_supervision", &error)
                .await;
        }
    }

    fn resident_is_current(&self, worker_id: &str, version: &str) -> bool {
        self.store
            .summary(worker_id)
            .ok()
            .flatten()
            .is_some_and(|summary| {
                summary.enabled && !summary.retired && summary.active_version == version
            })
    }

    fn resident_process_is_registered(
        &self,
        key: &str,
        process: &Arc<Mutex<ResidentProcess>>,
    ) -> bool {
        self.residents
            .get(key)
            .is_some_and(|registered| Arc::ptr_eq(registered.value(), process))
    }

    async fn stop_residents(&self, worker_id: Option<&str>) {
        let ids = self
            .residents
            .iter()
            .filter(|entry| {
                worker_id.is_none_or(|id| {
                    entry.key() == id || entry.key().starts_with(&format!("{id}@"))
                })
            })
            .map(|entry| entry.key().clone())
            .collect::<Vec<_>>();
        for id in ids {
            self.stop_resident_key(&id).await;
        }
    }

    async fn stop_resident_key(&self, key: &str) {
        if let Some((_, process)) = self.residents.remove(key) {
            let mut process = process.lock().await;
            if let Some(mut child) = process.child.take() {
                child.terminate().await;
            }
            if let Some(runtime_root) = process.runtime_root.take() {
                let _ = std::fs::remove_dir_all(runtime_root);
            }
        }
        let _ = self.resident_users.remove(key);
    }

    async fn stop_obsolete_residents(&self, worker_id: &str, active_version: &str) {
        let active_key = format!("{worker_id}@{active_version}");
        let keys = self
            .residents
            .iter()
            .filter(|entry| {
                entry.key().starts_with(&format!("{worker_id}@"))
                    && entry.key() != &active_key
                    && self
                        .resident_users
                        .get(entry.key())
                        .is_none_or(|users| users.load(Ordering::SeqCst) == 0)
            })
            .map(|entry| entry.key().clone())
            .collect::<Vec<_>>();
        for key in keys {
            self.stop_resident_key(&key).await;
        }
    }

    fn load_secrets(&self, bundle: &WorkerBundle) -> Result<HashMap<String, String>, String> {
        let vault = self.store.home().join("workspace").join("vault");
        let mut secrets = HashMap::new();
        for binding in &bundle.secret_bindings {
            let name = binding.name();
            let direct = vault.join(name);
            let json_path = vault.join(format!("{name}.json"));
            let path = if direct.is_file() {
                direct
            } else if json_path.is_file() {
                json_path
            } else {
                if binding.required() {
                    return Err(format!(
                        "required named secret binding '{name}' was not found"
                    ));
                }
                continue;
            };
            let value = std::fs::read_to_string(&path)
                .map_err(|error| format!("read named secret binding '{name}': {error}"))?;
            let _ = secrets.insert(name.to_owned(), value.trim_end().to_owned());
        }
        Ok(secrets)
    }

    fn reject_secret_material_in_bundle(&self, bundle: &WorkerBundle) -> Result<(), String> {
        let secrets = self.load_all_vault_secrets()?;
        if secrets.is_empty() {
            return Ok(());
        }
        let encoded = serde_json::to_string(bundle)
            .map_err(|error| format!("encode worker bundle for secret scan: {error}"))?;
        for (name, secret) in secrets {
            if secret.len() >= 4 && encoded.contains(&secret) {
                return Err(format!(
                    "worker bundle contains the value of named secret '{name}'; keep only the logical binding name"
                ));
            }
        }
        Ok(())
    }

    fn reject_secret_material_in_value(&self, value: &Value, surface: &str) -> Result<(), String> {
        let secrets = self.load_all_vault_secrets()?;
        if secrets.is_empty() {
            return Ok(());
        }
        let encoded = serde_json::to_string(value)
            .map_err(|error| format!("encode {surface} for secret scan: {error}"))?;
        for (name, secret) in secrets {
            if secret.len() >= 4 && encoded.contains(&secret) {
                return Err(format!(
                    "{surface} contains the value of vault secret '{name}'; workers receive secrets only through declared logical bindings"
                ));
            }
        }
        Ok(())
    }

    fn load_all_vault_secrets(&self) -> Result<HashMap<String, String>, String> {
        let vault = self.store.home().join("workspace").join("vault");
        if !vault.is_dir() {
            return Ok(HashMap::new());
        }
        let mut secrets = HashMap::new();
        for entry in walkdir::WalkDir::new(&vault).follow_links(false) {
            let entry = entry.map_err(|error| format!("scan named-secret vault: {error}"))?;
            if !entry.file_type().is_file() {
                continue;
            }
            let relative = entry
                .path()
                .strip_prefix(&vault)
                .map_err(|error| error.to_string())?
                .display()
                .to_string();
            let value = std::fs::read_to_string(entry.path())
                .map_err(|error| format!("read named-secret vault entry '{relative}': {error}"))?;
            let value = value.trim_end().to_owned();
            if !value.is_empty() {
                let _ = secrets.insert(relative, value);
            }
        }
        Ok(secrets)
    }

    async fn publish_event(&self, topic: &str, payload: Value, trace_id: Option<TraceId>) {
        let _ = self
            .host
            .publish_stream_event(PublishStreamEvent {
                topic: topic.to_owned(),
                payload,
                visibility: VisibilityScope::System,
                session_id: None,
                workspace_id: None,
                producer: "worker_kernel".to_owned(),
                trace_id,
                parent_invocation_id: None,
            })
            .await;
    }
}

struct DynamicWorkerHandler {
    runtime: Arc<WorkerRuntime>,
    worker_id: String,
}

#[async_trait::async_trait]
impl InProcessFunctionHandler for DynamicWorkerHandler {
    async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
        if !self.runtime.autonomous_enabled() {
            return Err(crate::engine::EngineError::HandlerFailed(
                "autonomous workers are disabled for this profile; set autonomousWorkers=true"
                    .to_owned(),
            ));
        }
        let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
        let depth = invocation
            .causal_context
            .runtime_metadata
            .get(RUNTIME_METADATA_TRIGGER_DEPTH)
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(0);
        let idempotency_key = invocation
            .causal_context
            .idempotency_key
            .clone()
            .unwrap_or_else(|| format!("manual:{}", invocation.id));
        let record = self
            .runtime
            .invoke(InvokeRequest {
                worker_id: self.worker_id.clone(),
                input: invocation.payload,
                idempotency_key,
                trace_id,
                causal_depth: depth,
                trigger_kind: "manual".to_owned(),
            })
            .await
            .map_err(crate::engine::EngineError::HandlerFailed)?;
        if record.status != "completed" {
            return Err(crate::engine::EngineError::HandlerFailed(
                record
                    .error
                    .unwrap_or_else(|| format!("worker '{}' failed", self.worker_id)),
            ));
        }
        Ok(record.output.unwrap_or_else(|| json!({})))
    }
}

async fn read_http_body_limited(
    response: &mut reqwest::Response,
    max_bytes: usize,
    label: &str,
) -> Result<Vec<u8>, String> {
    if response
        .content_length()
        .is_some_and(|length| length > max_bytes as u64)
    {
        return Err(format!("{label} exceeds the {max_bytes}-byte ceiling"));
    }
    let mut body = Vec::with_capacity(
        response
            .content_length()
            .unwrap_or_default()
            .min(max_bytes as u64) as usize,
    );
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| format!("read {label}: {error}"))?
    {
        if body.len().saturating_add(chunk.len()) > max_bytes {
            return Err(format!("{label} exceeds the {max_bytes}-byte ceiling"));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

async fn run_worker_command(
    spec: &WorkerCommand,
    workdir: &Path,
    input: Option<&Value>,
    secrets: &HashMap<String, String>,
    invocation: Option<&InvocationRecord>,
) -> Result<Value, String> {
    let child = spawn_process(
        &spec.command,
        workdir,
        secrets,
        Stdio::piped(),
        Stdio::piped(),
        invocation,
    )?;
    let input = input
        .map(serde_json::to_vec)
        .transpose()
        .map_err(|error| format!("encode worker input: {error}"))?;
    let output = wait_with_bounded_output(
        child,
        input,
        Duration::from_secs(spec.timeout_seconds),
        format!(
            "worker command timed out after {} seconds",
            spec.timeout_seconds
        ),
        MAX_PROCESS_CAPTURE_BYTES,
    )
    .await
    .map_err(|error| format!("wait for worker command: {error}"))?;
    if !output.status.success() {
        let truncation = if output.stderr_truncated {
            "\n[stderr truncated at 4194304 bytes]"
        } else {
            ""
        };
        return Err(redact_known_secrets(
            &format!(
                "worker command exited {}: {}{}",
                output.status,
                String::from_utf8_lossy(&output.stderr),
                truncation,
            ),
            secrets,
        ));
    }
    if let Some((kind, error)) = output.input_error
        && kind != std::io::ErrorKind::BrokenPipe
    {
        return Err(format!("write worker input: {error}"));
    }
    if output.stdout_truncated {
        return Err(format!(
            "worker command stdout exceeded the {}-byte capture ceiling",
            MAX_PROCESS_CAPTURE_BYTES
        ));
    }
    if output.stdout.is_empty() {
        return Ok(json!({}));
    }
    Ok(serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        json!({
            "stdout": String::from_utf8_lossy(&output.stdout).trim_end()
        })
    }))
}

fn spawn_process(
    command: &[String],
    workdir: &Path,
    secrets: &HashMap<String, String>,
    stdout: Stdio,
    stderr: Stdio,
    invocation: Option<&InvocationRecord>,
) -> Result<ProcessTree, String> {
    let (program, arguments) = command
        .split_first()
        .ok_or_else(|| "worker command has no program".to_owned())?;
    let program_path = if program.starts_with("./") {
        workdir.join(program.trim_start_matches("./"))
    } else {
        PathBuf::from(program)
    };
    let mut process = Command::new(program_path);
    process
        .args(arguments)
        .current_dir(workdir)
        .stdin(Stdio::piped())
        .stdout(stdout)
        .stderr(stderr)
        .kill_on_drop(true);
    if let Some(root) = worker_artifact_root(workdir) {
        let dependency_runtime = root.join("dependency-runtime");
        let bin = dependency_runtime.join("bin");
        let inherited_path = std::env::var_os("PATH").unwrap_or_default();
        let path = std::env::join_paths(
            std::iter::once(bin.clone()).chain(std::env::split_paths(&inherited_path)),
        )
        .map_err(|error| format!("construct worker dependency PATH: {error}"))?;
        process
            .env("TRON_WORKER_DEPENDENCY_ROOT", &dependency_runtime)
            .env("PIP_TARGET", dependency_runtime.join("python"))
            .env("PYTHONPATH", dependency_runtime.join("python"))
            .env("PYTHONUSERBASE", dependency_runtime.join("python-user"))
            .env("NPM_CONFIG_PREFIX", &dependency_runtime)
            .env("CARGO_HOME", dependency_runtime.join("cargo"))
            .env("GEM_HOME", dependency_runtime.join("gems"))
            .env("BUNDLE_PATH", dependency_runtime.join("gems"))
            .env("PATH", path);
    }
    for (name, value) in secrets {
        let env_name = format!(
            "TRON_SECRET_{}",
            name.chars()
                .map(|character| if character.is_ascii_alphanumeric() {
                    character.to_ascii_uppercase()
                } else {
                    '_'
                })
                .collect::<String>()
        );
        process.env(env_name, value);
    }
    if let Some(invocation) = invocation {
        process
            .env("TRON_WORKER_INVOCATION_ID", &invocation.invocation_id)
            .env("TRON_WORKER_IDEMPOTENCY_KEY", &invocation.idempotency_key)
            .env("TRON_WORKER_TRACE_ID", &invocation.trace_id)
            .env(
                "TRON_WORKER_CAUSAL_DEPTH",
                invocation.causal_depth.to_string(),
            )
            .env("TRON_WORKER_TRIGGER_KIND", &invocation.trigger_kind);
    }
    ProcessTree::spawn(&mut process).map_err(|error| format!("start worker command: {error}"))
}

fn worker_artifact_root(workdir: &Path) -> Option<PathBuf> {
    workdir
        .ancestors()
        .find(|candidate| candidate.join("dependency-runtime").is_dir())
        .map(Path::to_path_buf)
}

fn digest_tree(root: &Path) -> Result<String, String> {
    let mut entries = walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?;
    entries.retain(|entry| entry.file_type().is_file() || entry.file_type().is_symlink());
    entries.sort_by(|left, right| left.path().cmp(right.path()));
    let mut digest = Sha256::new();
    for entry in entries {
        let relative = entry
            .path()
            .strip_prefix(root)
            .map_err(|error| error.to_string())?;
        digest.update(relative.to_string_lossy().as_bytes());
        digest.update([0]);
        if entry.file_type().is_symlink() {
            digest.update(
                std::fs::read_link(entry.path())
                    .map_err(|error| error.to_string())?
                    .to_string_lossy()
                    .as_bytes(),
            );
            digest.update([0xfe]);
        } else {
            digest.update(std::fs::read(entry.path()).map_err(|error| error.to_string())?);
            digest.update([0xff]);
        }
    }
    Ok(hex::encode(digest.finalize()))
}

fn resident_key(worker: &ActiveWorker) -> String {
    format!(
        "{}@{}",
        worker.summary.worker_id, worker.summary.active_version
    )
}

fn redact_known_secrets(value: &str, secrets: &HashMap<String, String>) -> String {
    let mut redacted = crate::shared::foundation::redaction::redact_sensitive_content(value);
    for secret in secrets.values().filter(|secret| !secret.is_empty()) {
        redacted = redacted.replace(secret, "[REDACTED]");
    }
    redacted
}

fn redact_json_known_secrets(value: Value, secrets: &HashMap<String, String>) -> Value {
    match value {
        Value::String(value) => Value::String(redact_known_secrets(&value, secrets)),
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(|value| redact_json_known_secrets(value, secrets))
                .collect(),
        ),
        Value::Object(values) => Value::Object(
            values
                .into_iter()
                .map(|(key, value)| (key, redact_json_known_secrets(value, secrets)))
                .collect(),
        ),
        value => value,
    }
}

fn normalize_agent_output(value: Value) -> Value {
    let text = match value {
        Value::String(text) => text,
        Value::Array(blocks) => {
            let text = blocks
                .iter()
                .filter_map(|block| block.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n");
            if text.is_empty() {
                return Value::Array(blocks);
            }
            text
        }
        value => return value,
    };
    let trimmed = text.trim();
    if let Ok(value) = serde_json::from_str(trimmed) {
        return value;
    }
    let unfenced = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```"))
        .and_then(|body| body.strip_suffix("```"))
        .map(str::trim);
    if let Some(unfenced) = unfenced
        && let Ok(value) = serde_json::from_str(unfenced)
    {
        return value;
    }
    json!({"text": text})
}

fn json_subset_matches(filter: &Value, candidate: &Value) -> bool {
    match filter {
        Value::Object(expected) => {
            let Some(actual) = candidate.as_object() else {
                return false;
            };
            expected.iter().all(|(key, expected)| {
                actual
                    .get(key)
                    .is_some_and(|actual| json_subset_matches(expected, actual))
            })
        }
        Value::Array(expected) => candidate.as_array().is_some_and(|actual| {
            expected.len() == actual.len()
                && expected
                    .iter()
                    .zip(actual)
                    .all(|(expected, actual)| json_subset_matches(expected, actual))
        }),
        _ => filter == candidate,
    }
}

/// Project an engine event into the worker's ordinary typed input without a
/// framework envelope. Configured input provides defaults; only event payload
/// keys explicitly declared by the top-level input schema may override them.
fn materialize_engine_event_input(configured: &Value, payload: &Value, schema: &Value) -> Value {
    let mut materialized = configured.clone();
    let (Some(materialized), Some(payload), Some(properties)) = (
        materialized.as_object_mut(),
        payload.as_object(),
        schema.get("properties").and_then(Value::as_object),
    ) else {
        return materialized;
    };
    for key in properties.keys() {
        if let Some(value) = payload.get(key) {
            let _ = materialized.insert(key.clone(), value.clone());
        }
    }
    Value::Object(materialized.clone())
}

fn copy_tree(source: &Path, destination: &Path) -> Result<(), String> {
    if !source.exists() {
        return Ok(());
    }
    for entry in walkdir::WalkDir::new(source).follow_links(false) {
        let entry = entry.map_err(|error| error.to_string())?;
        let relative = entry
            .path()
            .strip_prefix(source)
            .map_err(|error| error.to_string())?;
        let target = destination.join(relative);
        if entry.file_type().is_dir() {
            std::fs::create_dir_all(&target).map_err(|error| error.to_string())?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            }
            std::fs::copy(entry.path(), target).map_err(|error| error.to_string())?;
        } else if entry.file_type().is_symlink() {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            }
            copy_symlink(entry.path(), &target)?;
        } else {
            return Err(format!(
                "worker artifact contains unsupported special file {}",
                entry.path().display()
            ));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn copy_symlink(source: &Path, destination: &Path) -> Result<(), String> {
    let target = std::fs::read_link(source)
        .map_err(|error| format!("read worker symlink {}: {error}", source.display()))?;
    std::os::unix::fs::symlink(&target, destination).map_err(|error| {
        format!(
            "copy worker symlink {} -> {}: {error}",
            destination.display(),
            target.display()
        )
    })
}

#[cfg(not(unix))]
fn copy_symlink(source: &Path, _destination: &Path) -> Result<(), String> {
    Err(format!(
        "worker symlink copies are not supported on this platform: {}",
        source.display()
    ))
}

#[cfg(unix)]
fn set_owner_only(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| error.to_string())
}

#[cfg(not(unix))]
fn set_owner_only(_path: &Path) -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use futures::stream;
    use std::collections::{BTreeMap, BTreeSet};
    use std::sync::Arc;

    use crate::domains::model::responder::{
        ModelResponder, ModelResponderFactory, ModelResponderInfo, ModelResponse,
        ModelResponseError, ModelResponseRequest, ModelResponseStream,
    };
    use crate::shared::protocol::content::AssistantContent;
    use crate::shared::protocol::events::{AssistantMessage, StreamEvent};

    fn command_bundle(command: Vec<String>) -> WorkerBundle {
        WorkerBundle {
            schema_version: super::super::types::BUNDLE_SCHEMA.to_owned(),
            worker_id: None,
            name: "Echo Worker".to_owned(),
            description: "Returns typed JSON input for durable runner tests".to_owned(),
            tool_name: Some("worker_echo".to_owned()),
            input_schema: json!({"type":"object"}),
            output_schema: json!({"type":"object"}),
            runner: WorkerRunner::Command { command },
            files: Default::default(),
            dependencies: Vec::new(),
            triggers: Vec::new(),
            secret_bindings: Vec::new(),
            smoke_tests: Vec::new(),
            health_checks: Vec::new(),
            provenance: vec![super::super::types::SourceProvenance {
                source: "test:deterministic".to_owned(),
                revision: Some("1".to_owned()),
                checksum: None,
            }],
            routing: Default::default(),
        }
    }

    fn test_runtime(
        responder: Option<Arc<dyn ModelResponderFactory>>,
    ) -> (Arc<WorkerRuntime>, tempfile::TempDir) {
        let home = tempfile::tempdir().unwrap();
        let runtime = test_runtime_at(home.path(), responder);
        (runtime, home)
    }

    fn test_runtime_at(
        home: &Path,
        responder: Option<Arc<dyn ModelResponderFactory>>,
    ) -> Arc<WorkerRuntime> {
        let context =
            crate::shared::server::test_support::make_test_context_with_responder(responder);
        crate::domains::settings::profile::SettingsStore::new(&context.settings_path)
            .update(json!({"autonomousWorkers": true}))
            .unwrap();
        context
            .profile_runtime
            .reload_now("worker kernel test")
            .unwrap();
        let store = WorkerStore::open_without_snapshot(home.to_path_buf()).unwrap();
        WorkerRuntime::new(
            store,
            context.engine_host.clone(),
            context.orchestrator.clone(),
            context.session_manager.clone(),
            context.event_store.clone(),
            context.profile_runtime.clone(),
        )
        .unwrap()
    }

    fn last30days_bundle(source_url: &str) -> WorkerBundle {
        let script = r#"import datetime,json,os,sys
request=json.loads(sys.stdin.read() or '{}')
topic=request.get('topic','worker autonomy')
as_of=datetime.date.fromisoformat(request.get('asOf','2026-07-19'))
cutoff=as_of-datetime.timedelta(days=30)
with open('sources.json',encoding='utf-8') as handle:
    sources=json.load(handle)
recent=[source for source in sources if cutoff <= datetime.date.fromisoformat(source['publishedAt']) <= as_of]
print(json.dumps({
    'topic':topic,
    'windowDays':30,
    'asOf':as_of.isoformat(),
    'summary':f'Found {len(recent)} deterministic sources about {topic} from the last 30 days.',
    'sources':recent,
    'credentialMode':'optional_credentials_present' if os.getenv('TRON_SECRET_SEARCH_API_KEY') else 'optional_credentials_absent',
    'upstreamAvailable':os.path.isdir('../dependencies/upstream')
},separators=(',',':')))
"#;
        WorkerBundle {
            schema_version: super::super::types::BUNDLE_SCHEMA.to_owned(),
            worker_id: Some("last30days-research".to_owned()),
            name: "Last 30 Days Research".to_owned(),
            description: "Research a topic across sources published in the last 30 days with citations and graceful credential fallback".to_owned(),
            tool_name: Some("worker_last30days_research".to_owned()),
            input_schema: json!({
                "type":"object",
                "additionalProperties":false,
                "required":["topic"],
                "properties":{
                    "topic":{"type":"string","minLength":1},
                    "asOf":{"type":"string"}
                }
            }),
            output_schema: json!({
                "type":"object",
                "additionalProperties":false,
                "required":["topic","windowDays","asOf","summary","sources","credentialMode","upstreamAvailable"],
                "properties":{
                    "topic":{"type":"string"},
                    "windowDays":{"const":30},
                    "asOf":{"type":"string"},
                    "summary":{"type":"string"},
                    "sources":{"type":"array","items":{"type":"object"}},
                    "credentialMode":{"enum":["optional_credentials_present","optional_credentials_absent"]},
                    "upstreamAvailable":{"type":"boolean"}
                }
            }),
            runner: WorkerRunner::Command {
                command: vec!["python3".to_owned(), "recent_research.py".to_owned()],
            },
            files: BTreeMap::from([
                ("recent_research.py".to_owned(), script.to_owned()),
                (
                    "sources.json".to_owned(),
                    include_str!("../../../tests/fixtures/last30days_recent_sources.json").to_owned(),
                ),
            ]),
            dependencies: Vec::new(),
            triggers: vec![
                WorkerTrigger::Manual { id: "manual".to_owned() },
                WorkerTrigger::Schedule {
                    id: "daily".to_owned(),
                    every_seconds: 86_400,
                    input: json!({"topic":"worker autonomy"}),
                },
                WorkerTrigger::EngineEvent {
                    id: "research-requested".to_owned(),
                    topic: "research.requested".to_owned(),
                    filter: json!({"windowDays":30}),
                    input: json!({"topic":"worker autonomy"}),
                },
                WorkerTrigger::Webhook {
                    id: "local-research".to_owned(),
                    input: json!({"topic":"worker autonomy"}),
                },
            ],
            secret_bindings: vec![super::super::types::WorkerSecretBinding::Optional(
                "search-api-key".to_owned(),
            )],
            smoke_tests: vec![WorkerCommand {
                command: vec!["python3".to_owned(), "recent_research.py".to_owned()],
                timeout_seconds: 10,
            }],
            health_checks: vec![WorkerCommand {
                command: vec![
                    "python3".to_owned(),
                    "-m".to_owned(),
                    "py_compile".to_owned(),
                    "recent_research.py".to_owned(),
                ],
                timeout_seconds: 10,
            }],
            provenance: vec![super::super::types::SourceProvenance {
                source: source_url.to_owned(),
                revision: Some("fixture-adaptation-v1".to_owned()),
                checksum: None,
            }],
            routing: super::super::types::WorkerRouting {
                intents: vec!["recent research".to_owned(), "last 30 days".to_owned()],
                examples: vec!["What changed in autonomous workers in the last month?".to_owned()],
            },
        }
    }

    fn request(worker_id: &str, input: Value, key: &str) -> InvokeRequest {
        InvokeRequest {
            worker_id: worker_id.to_owned(),
            input,
            idempotency_key: key.to_owned(),
            trace_id: format!("trace-{key}"),
            causal_depth: 0,
            trigger_kind: "manual".to_owned(),
        }
    }

    #[tokio::test]
    async fn last30days_replay_activates_one_typed_worker_and_survives_restart() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/last30days_worker_gap.json"
        ))
        .unwrap();
        let source_url = fixture["sourceUrl"].as_str().unwrap();
        let home = tempfile::tempdir().unwrap();
        let runtime = test_runtime_at(home.path(), None);
        let mut bundle = last30days_bundle(source_url);
        for trigger in &mut bundle.triggers {
            if let WorkerTrigger::Schedule { every_seconds, .. } = trigger {
                *every_seconds = 1;
            }
        }

        let outcome = runtime.upsert(bundle, None).await.unwrap();
        assert!(outcome.created);
        assert_eq!(outcome.worker.worker_id, "last30days-research");
        assert_eq!(outcome.worker.tool_name, "worker_last30days_research");
        assert_eq!(outcome.webhooks.len(), 1);
        let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
        let trigger_kinds = inspection["triggers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|trigger| trigger["kind"].as_str().unwrap())
            .collect::<BTreeSet<_>>();
        assert_eq!(
            trigger_kinds,
            BTreeSet::from(["manual", "schedule", "engine_event", "webhook"])
        );

        let direct = runtime
            .host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::dynamic_last30days-research").unwrap(),
                json!({"topic":"worker autonomy","asOf":"2026-07-19"}),
                CausalContext::trusted_local(
                    ActorId::new("agent:last30days-replay").unwrap(),
                    ActorKind::Agent,
                    TraceId::new("trace-last30days-direct").unwrap(),
                )
                .with_session_id("session-last30days-replay")
                .with_idempotency_key("last30days-direct"),
            ))
            .await;
        assert!(
            direct.error.is_none(),
            "direct worker error: {:?}",
            direct.error
        );
        let value = direct.value.unwrap();
        assert_eq!(value["windowDays"], 30);
        assert_eq!(value["credentialMode"], "optional_credentials_absent");
        assert_eq!(value["sources"].as_array().unwrap().len(), 3);
        assert!(
            value["summary"]
                .as_str()
                .unwrap()
                .contains("worker autonomy")
        );

        let webhook_credential = &outcome.webhooks[0];
        let webhook_input = runtime
            .store()
            .verify_webhook(
                &outcome.worker.worker_id,
                &webhook_credential.trigger_id,
                &webhook_credential.token,
            )
            .unwrap();
        let webhook = runtime
            .invoke(InvokeRequest {
                worker_id: outcome.worker.worker_id.clone(),
                input: webhook_input,
                idempotency_key: "webhook:local-research:last30days-replay".to_owned(),
                trace_id: "trace-last30days-webhook".to_owned(),
                causal_depth: 0,
                trigger_kind: "webhook".to_owned(),
            })
            .await
            .unwrap();
        assert_eq!(webhook.status, "completed");

        runtime
            .publish_event(
                "research.requested",
                json!({"windowDays":30,"requestId":"same-worker-proof"}),
                Some(TraceId::new("trace-last30days-event").unwrap()),
            )
            .await;
        let mut event_runs = JoinSet::new();
        runtime.dispatch_events(&mut event_runs).await;
        while event_runs.join_next().await.is_some() {}

        tokio::time::sleep(Duration::from_millis(1_100)).await;
        let mut schedule_runs = JoinSet::new();
        runtime.dispatch_schedules(&mut schedule_runs).await;
        while schedule_runs.join_next().await.is_some() {}
        let trigger_kinds = runtime
            .store()
            .runs(Some(&outcome.worker.worker_id), 10)
            .unwrap()
            .into_iter()
            .map(|run| run.trigger_kind)
            .collect::<BTreeSet<_>>();
        assert_eq!(
            trigger_kinds,
            BTreeSet::from([
                "engine_event".to_owned(),
                "manual".to_owned(),
                "schedule".to_owned(),
                "webhook".to_owned(),
            ])
        );

        let version_dir = home
            .path()
            .join("workspace/workers/last30days-research/versions")
            .join(&outcome.version);
        assert!(version_dir.join("manifest.json").is_file());
        assert!(
            home.path()
                .join("workspace/workers/last30days-research/worker.json")
                .is_file()
        );

        let restarted = test_runtime_at(home.path(), None);
        restarted.register_active_tools().await.unwrap();
        let after_restart = restarted
            .host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::dynamic_last30days-research").unwrap(),
                json!({"topic":"persistent workers","asOf":"2026-07-19"}),
                CausalContext::trusted_local(
                    ActorId::new("agent:last30days-restart").unwrap(),
                    ActorKind::Agent,
                    TraceId::new("trace-last30days-restart").unwrap(),
                )
                .with_session_id("session-last30days-restart")
                .with_idempotency_key("last30days-restart"),
            ))
            .await;
        assert!(
            after_restart.error.is_none(),
            "restarted worker error: {:?}",
            after_restart.error
        );
        assert_eq!(after_restart.value.unwrap()["topic"], "persistent workers");
        assert_eq!(
            restarted
                .store()
                .runs(Some("last30days-research"), 10)
                .unwrap()
                .len(),
            5
        );
    }

    #[tokio::test]
    #[ignore = "opt-in live network: set TRON_WORKER_LIVE_NETWORK=1"]
    async fn last30days_upstream_live_network_dependency_is_locked_and_activates() {
        assert_eq!(
            std::env::var("TRON_WORKER_LIVE_NETWORK").ok().as_deref(),
            Some("1"),
            "set TRON_WORKER_LIVE_NETWORK=1 to run the upstream proof"
        );
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/last30days_worker_gap.json"
        ))
        .unwrap();
        let source_url = fixture["sourceUrl"].as_str().unwrap();
        let revision_output = std::process::Command::new("git")
            .args(["ls-remote", source_url, "HEAD"])
            .output()
            .unwrap();
        assert!(revision_output.status.success());
        let revision = String::from_utf8(revision_output.stdout)
            .unwrap()
            .split_whitespace()
            .next()
            .unwrap()
            .to_owned();
        let mut bundle = last30days_bundle(source_url);
        bundle
            .description
            .push_str(" using a locked upstream checkout");
        bundle.dependencies.push(WorkerDependency {
            name: "upstream".to_owned(),
            source: format!("git+{source_url}"),
            version: revision.clone(),
            checksum: None,
            install: None,
        });
        bundle.smoke_tests.push(WorkerCommand {
            command: vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "test -d ../dependencies/upstream".to_owned(),
            ],
            timeout_seconds: 10,
        });
        bundle.provenance[0].revision = Some(revision);

        let (runtime, _home) = test_runtime(None);
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let active = runtime
            .store()
            .load_active(&outcome.worker.worker_id)
            .unwrap();
        let locked = active.bundle.dependencies[0]
            .checksum
            .as_deref()
            .expect("upsert seals fetched dependency checksum");
        assert_eq!(
            locked,
            format!(
                "sha256:{}",
                digest_tree(&active.version_dir.join("dependencies/upstream")).unwrap()
            )
        );
        let result = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"topic":"recent research","asOf":"2026-07-19"}),
                "upstream-live-network",
            ))
            .await
            .unwrap();
        assert_eq!(result.status, "completed");
        assert_eq!(result.output.unwrap()["upstreamAvailable"], true);
    }

    #[tokio::test]
    async fn upsert_fetches_and_seals_an_omitted_dependency_checksum() {
        let (runtime, home) = test_runtime(None);
        let source = home.path().join("dependency-source");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("source.txt"), "locked content").unwrap();
        let expected = format!("sha256:{}", digest_tree(&source).unwrap());
        let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        bundle.dependencies.push(WorkerDependency {
            name: "upstream".to_owned(),
            source: format!("file://{}", source.display()),
            version: "fixture-1".to_owned(),
            checksum: None,
            install: None,
        });
        bundle.smoke_tests.push(WorkerCommand {
            command: vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "test -f ../dependencies/upstream/source.txt".to_owned(),
            ],
            timeout_seconds: 5,
        });

        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let active = runtime
            .store()
            .load_active(&outcome.worker.worker_id)
            .unwrap();
        assert_eq!(
            active.bundle.dependencies[0].checksum.as_deref(),
            Some(expected.as_str())
        );
        let manifest: Value = serde_json::from_slice(
            &std::fs::read(active.version_dir.join("manifest.json")).unwrap(),
        )
        .unwrap();
        let lock: Value = serde_json::from_slice(
            &std::fs::read(active.version_dir.join("dependencies.lock.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(manifest["dependencies"][0]["checksum"], expected);
        assert_eq!(lock[0]["checksum"], expected);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn dependency_hash_and_runtime_copy_preserve_symlink_targets() {
        let (runtime, home) = test_runtime(None);
        let source = home.path().join("symlink-dependency-source");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("target.txt"), "linked content").unwrap();
        std::os::unix::fs::symlink("target.txt", source.join("current.txt")).unwrap();
        let expected = format!("sha256:{}", digest_tree(&source).unwrap());
        let mut bundle = command_bundle(vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "test \"$(cat ../dependencies/upstream/current.txt)\" = 'linked content'; printf '{\"linked\":true}'".to_owned(),
        ]);
        bundle.dependencies.push(WorkerDependency {
            name: "upstream".to_owned(),
            source: format!("file://{}", source.display()),
            version: "fixture-1".to_owned(),
            checksum: None,
            install: None,
        });
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let active = runtime
            .store()
            .load_active(&outcome.worker.worker_id)
            .unwrap();

        assert_eq!(
            active.bundle.dependencies[0].checksum.as_deref(),
            Some(expected.as_str())
        );
        assert!(
            std::fs::symlink_metadata(active.version_dir.join("dependencies/upstream/current.txt"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let record = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({}),
                "symlink-runtime-copy",
            ))
            .await
            .unwrap();
        assert_eq!(record.output, Some(json!({"linked":true})));
    }

    #[tokio::test]
    async fn command_runner_upserts_invokes_and_replays_idempotently() {
        let (runtime, home) = test_runtime(None);
        let command = vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import json,os,sys; value=json.load(sys.stdin); value['idempotencyKey']=os.environ['TRON_WORKER_IDEMPOTENCY_KEY']; value['traceId']=os.environ['TRON_WORKER_TRACE_ID']; print(json.dumps(value))".to_owned(),
        ];
        let outcome = runtime.upsert(command_bundle(command), None).await.unwrap();
        let first = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"topic":"workers"}),
                "same-key",
            ))
            .await
            .unwrap();
        let replay = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"topic":"different"}),
                "same-key",
            ))
            .await
            .unwrap();

        assert_eq!(first.status, "completed");
        assert_eq!(first.attempt_count, 1);
        assert_eq!(
            first.output,
            Some(json!({
                "topic":"workers",
                "idempotencyKey":"same-key",
                "traceId":"trace-same-key",
            }))
        );
        assert_eq!(replay.invocation_id, first.invocation_id);
        assert_eq!(runtime.store().runs(None, 10).unwrap().len(), 1);
        assert_eq!(
            runtime
                .store()
                .attempts(&first.invocation_id)
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            runtime.store().trace("trace-same-key").unwrap().unwrap()["suppressedCount"],
            1
        );
        assert!(
            home.path()
                .join("workspace/workers")
                .join(&outcome.worker.worker_id)
                .join("versions")
                .join(&outcome.version)
                .join("verification.json")
                .is_file()
        );

        let direct = runtime
            .host
            .invoke(Invocation::new_sync(
                FunctionId::new(format!(
                    "worker_kernel::dynamic_{}",
                    outcome.worker.worker_id
                ))
                .unwrap(),
                json!({"topic":"direct typed tool"}),
                CausalContext::trusted_local(
                    ActorId::new("agent:worker-direct-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::new("worker-direct-trace").unwrap(),
                )
                .with_session_id("worker-direct-session")
                .with_idempotency_key("worker-direct-call"),
            ))
            .await;
        assert!(
            direct.error.is_none(),
            "direct worker error: {:?}",
            direct.error
        );
        assert_eq!(
            direct.value,
            Some(json!({
                "topic":"direct typed tool",
                "idempotencyKey":"worker-direct-call",
                "traceId":"worker-direct-trace",
            }))
        );
        let inspection_actor = crate::engine::ActorContext::new(
            ActorId::new("system:worker-tool-evidence-test").unwrap(),
            ActorKind::System,
            crate::engine::AuthorityGrantId::new("worker-tool-evidence-test").unwrap(),
        );
        let definition = runtime
            .host
            .inspect_function(
                &FunctionId::new(format!(
                    "worker_kernel::dynamic_{}",
                    outcome.worker.worker_id
                ))
                .unwrap(),
                Some(&inspection_actor),
            )
            .await
            .unwrap();
        assert!(definition.description.contains("health=healthy"));
        assert!(definition.description.contains("completedRuns=2"));
        assert!(definition.description.contains("test:deterministic@1"));
    }

    #[tokio::test]
    async fn command_runner_writes_only_to_its_disposable_runtime_copy() {
        let (runtime, home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec![
                    "sh".to_owned(),
                    "-c".to_owned(),
                    "printf runtime > runtime-only.txt; printf '{\"isolated\":true}'".to_owned(),
                ]),
                None,
            )
            .await
            .unwrap();

        let record = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({}),
                "runtime-copy",
            ))
            .await
            .unwrap();

        assert_eq!(record.output, Some(json!({"isolated":true})));
        assert!(
            !home
                .path()
                .join("workspace/workers")
                .join(&outcome.worker.worker_id)
                .join("versions")
                .join(&outcome.version)
                .join("files/runtime-only.txt")
                .exists(),
            "worker execution mutated its immutable canonical version"
        );
        assert!(
            !home
                .path()
                .join("internal/run/worker-invocations")
                .join(&record.invocation_id)
                .exists(),
            "terminal command runtime copy was not removed"
        );
    }

    #[tokio::test]
    async fn update_routes_new_work_immediately_while_old_version_drains() {
        let (runtime, home) = test_runtime(None);
        let started = home.path().join("old-started");
        let release = home.path().join("release-old");
        let old_command = format!(
            "touch '{}'; while [ ! -f '{}' ]; do sleep 0.02; done; printf '{{\"version\":\"old\"}}'",
            started.display(),
            release.display()
        );
        let first = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), old_command]),
                None,
            )
            .await
            .unwrap();
        let worker_id = first.worker.worker_id.clone();
        let old_version = first.version.clone();
        let old_runtime = Arc::clone(&runtime);
        let old_worker = worker_id.clone();
        let old_run = tokio::spawn(async move {
            old_runtime
                .invoke(request(&old_worker, json!({}), "draining-old"))
                .await
                .unwrap()
        });
        tokio::time::timeout(Duration::from_secs(5), async {
            while !started.is_file() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();

        let mut updated = command_bundle(vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "printf '{\"version\":\"new\"}'".to_owned(),
        ]);
        updated
            .description
            .push_str(" updated while prior work drains");
        let second = runtime.upsert(updated, Some(&worker_id)).await.unwrap();
        assert_ne!(second.version, old_version);
        let new_run = runtime
            .invoke(request(&worker_id, json!({}), "routed-new"))
            .await
            .unwrap();
        assert_eq!(new_run.worker_version, second.version);
        assert_eq!(new_run.output, Some(json!({"version":"new"})));

        std::fs::write(&release, "release").unwrap();
        let drained = old_run.await.unwrap();
        assert_eq!(drained.worker_version, old_version);
        assert_eq!(drained.output, Some(json!({"version":"old"})));
        assert_eq!(
            runtime
                .store()
                .load_active(&worker_id)
                .unwrap()
                .summary
                .active_version,
            second.version
        );
    }

    #[tokio::test]
    async fn causal_ceiling_rejects_before_persisting_an_invocation() {
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
                None,
            )
            .await
            .unwrap();
        let mut too_deep = request(&outcome.worker.worker_id, json!({}), "too-deep");
        too_deep.causal_depth = MAX_CAUSAL_DEPTH + 1;

        let error = runtime.invoke(too_deep).await.unwrap_err();

        assert!(error.contains("causal depth"));
        assert!(runtime.store().runs(None, 10).unwrap().is_empty());
    }

    #[tokio::test]
    async fn over_depth_engine_event_is_durably_suppressed_and_cursor_advances() {
        let (runtime, _home) = test_runtime(None);
        let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        bundle.worker_id = Some("depth-suppression".to_owned());
        bundle.name = "Depth Suppression".to_owned();
        bundle.description =
            "Engine-event fixture proving terminal causal suppression does not jam delivery"
                .to_owned();
        bundle.tool_name = Some("worker_depth_suppression".to_owned());
        bundle.triggers = vec![WorkerTrigger::EngineEvent {
            id: "depth-event".to_owned(),
            topic: "worker.depth-fixture".to_owned(),
            filter: json!({"ready":true}),
            input: json!({"kind":"event"}),
        }];
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let trace_id = TraceId::new("depth-suppression-trace").unwrap();
        runtime
            .publish_event(
                "worker.depth-fixture",
                json!({"ready":true,"causalDepth":MAX_CAUSAL_DEPTH}),
                Some(trace_id.clone()),
            )
            .await;

        let mut runs = JoinSet::new();
        runtime.dispatch_events(&mut runs).await;

        assert!(runs.is_empty());
        assert!(runtime.store().runs(None, 10).unwrap().is_empty());
        let trace = runtime
            .store()
            .trace(trace_id.as_str())
            .unwrap()
            .expect("suppressed trace");
        assert_eq!(trace["suppressedCount"], 1);
        assert_eq!(trace["maxCausalDepth"], MAX_CAUSAL_DEPTH + 1);
        let cursor_after_suppression = runtime
            .store()
            .event_triggers()
            .unwrap()
            .into_iter()
            .find(|(worker_id, _, _)| worker_id == &outcome.worker.worker_id)
            .expect("event trigger")
            .2;
        assert!(cursor_after_suppression > 0);

        runtime.dispatch_events(&mut runs).await;
        let trace_after_repoll = runtime
            .store()
            .trace(trace_id.as_str())
            .unwrap()
            .expect("suppressed trace after repoll");
        assert_eq!(trace_after_repoll["suppressedCount"], 1);
        let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
        assert!(inspection["audit"].as_array().unwrap().iter().any(|entry| {
            entry["action"] == "delivery_suppressed"
                && entry["details"]["reason"] == "causal_depth_limit"
        }));
    }

    #[tokio::test]
    async fn invalid_engine_event_projection_disables_worker_instead_of_jamming_cursor() {
        let (runtime, _home) = test_runtime(None);
        let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        bundle.worker_id = Some("invalid-event-materialization".to_owned());
        bundle.name = "Invalid Event Materialization".to_owned();
        bundle.description =
            "Engine-event fixture whose projected input intentionally lacks a required field"
                .to_owned();
        bundle.tool_name = Some("worker_invalid_event_materialization".to_owned());
        bundle.input_schema = json!({
            "type":"object",
            "additionalProperties":false,
            "required":["kind","requiredValue"],
            "properties":{"kind":{"type":"string"},"requiredValue":{"type":"integer"}}
        });
        bundle.triggers = vec![WorkerTrigger::EngineEvent {
            id: "invalid-event".to_owned(),
            topic: "worker.invalid-event-fixture".to_owned(),
            filter: json!({"ready":true}),
            input: json!({"kind":"event"}),
        }];
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        runtime
            .publish_event(
                "worker.invalid-event-fixture",
                json!({"ready":true}),
                Some(TraceId::new("invalid-event-materialization-trace").unwrap()),
            )
            .await;

        let mut runs = JoinSet::new();
        runtime.dispatch_events(&mut runs).await;

        assert!(runs.is_empty());
        assert!(runtime.store().runs(None, 10).unwrap().is_empty());
        let summary = runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap();
        assert!(!summary.enabled);
        assert_eq!(summary.health, "failed");
        let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
        assert!(inspection["triggers"][0]["streamCursor"].as_i64().unwrap() > 0);
        assert_eq!(inspection["triggers"][0]["enabled"], false);
        assert_eq!(inspection["healthHistory"][0]["source"], "trigger_dispatch");
        let inbox = runtime
            .store()
            .inbox(Some(&outcome.worker.worker_id), 10)
            .unwrap();
        assert!(inbox.iter().any(|item| {
            item["result"]["phase"] == "trigger_dispatch" && item["result"]["disabled"] == true
        }));
    }

    #[tokio::test]
    async fn profile_and_worker_concurrency_overflow_stays_durably_queued() {
        let (runtime, _home) = test_runtime(None);
        let mut worker_ids = Vec::new();
        for index in 0..5 {
            let mut bundle = command_bundle(vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "sleep 2; cat".to_owned(),
            ]);
            bundle.worker_id = Some(format!("concurrency-{index}"));
            bundle.name = format!("Concurrency Fixture {index}");
            bundle.description =
                format!("Deterministic concurrency lane {index} with a distinct explicit identity");
            bundle.tool_name = Some(format!("worker_concurrency_{index}"));
            let outcome = runtime.upsert(bundle, None).await.unwrap();
            assert_eq!(outcome.worker.worker_id, format!("concurrency-{index}"));
            worker_ids.push(outcome.worker.worker_id);
        }

        let mut tasks = Vec::new();
        for index in 0..40 {
            let runtime = Arc::clone(&runtime);
            let worker_id = worker_ids[index % worker_ids.len()].clone();
            tasks.push(tokio::spawn(async move {
                runtime
                    .invoke(request(
                        &worker_id,
                        json!({"index":index}),
                        &format!("concurrency-{index}"),
                    ))
                    .await
            }));
        }

        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        let mut observed_limits = false;
        while tokio::time::Instant::now() < deadline {
            let runs = runtime.store().runs(None, 100).unwrap();
            let running = runs.iter().filter(|run| run.status == "running").count();
            let queued = runs.iter().filter(|run| run.status == "queued").count();
            if runtime.profile_limit.available_permits() == 0
                && running <= MAX_PROFILE_CONCURRENCY
                && queued >= 8
            {
                observed_limits = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        assert!(
            observed_limits,
            "profile overflow was not observed as queued"
        );
        assert_eq!(runtime.profile_limit.available_permits(), 0);
        for worker_id in &worker_ids {
            let running = runtime
                .store()
                .runs(Some(worker_id), 100)
                .unwrap()
                .iter()
                .filter(|run| run.status == "running")
                .count();
            assert!(running <= MAX_WORKER_CONCURRENCY);
        }

        for task in tasks {
            let record = task.await.unwrap().unwrap();
            assert_eq!(record.status, "completed");
        }
        assert_eq!(runtime.store().runs(None, 100).unwrap().len(), 40);
    }

    #[tokio::test]
    async fn stop_all_blocks_new_dispatch_but_preserves_and_resumes_queued_work() {
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
                None,
            )
            .await
            .unwrap();
        let queued = runtime
            .enqueue(request(
                &outcome.worker.worker_id,
                json!({"preserved":true}),
                "preserved-queue",
            ))
            .unwrap();
        assert_eq!(queued.status, "queued");

        runtime.set_stop_all(true).await.unwrap();
        assert!(
            runtime
                .invoke(request(
                    &outcome.worker.worker_id,
                    json!({"blocked":true}),
                    "blocked-new",
                ))
                .await
                .unwrap_err()
                .contains("stopped")
        );
        assert_eq!(
            runtime
                .store()
                .invocation(&queued.invocation_id)
                .unwrap()
                .unwrap()
                .status,
            "queued"
        );

        runtime.set_stop_all(false).await.unwrap();
        let resumed = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"ignored":"idempotent replay uses durable input"}),
                "preserved-queue",
            ))
            .await
            .unwrap();
        assert_eq!(resumed.status, "completed");
        assert_eq!(resumed.output, Some(json!({"preserved":true})));
    }

    #[tokio::test]
    async fn disabling_a_worker_stops_its_active_invocation() {
        let (runtime, home) = test_runtime(None);
        let child_started = home.path().join("disable-descendant-started");
        let child_survived = home.path().join("disable-descendant-survived");
        let mut bundle = command_bundle(vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import pathlib,subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import pathlib,sys,time; time.sleep(.4); pathlib.Path(sys.argv[1]).write_text(\"survived\")',sys.argv[2]]); pathlib.Path(sys.argv[1]).write_text('started'); time.sleep(30)".to_owned(),
            child_started.display().to_string(),
            child_survived.display().to_string(),
        ]);
        bundle.triggers = vec![WorkerTrigger::Manual {
            id: "manual".to_owned(),
        }];
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let worker_id = outcome.worker.worker_id;
        let invoking = {
            let runtime = Arc::clone(&runtime);
            let worker_id = worker_id.clone();
            tokio::spawn(async move {
                runtime
                    .invoke(request(&worker_id, json!({}), "disable-running"))
                    .await
            })
        };
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        while tokio::time::Instant::now() < deadline {
            if child_started.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(child_started.exists(), "worker descendant never started");

        runtime.set_enabled(&worker_id, false).await.unwrap();
        let result = invoking.await.unwrap().unwrap();
        assert_eq!(result.status, "failed");
        assert!(result.error.unwrap().contains("disabled"));
        assert!(
            !runtime
                .store()
                .summary(&worker_id)
                .unwrap()
                .unwrap()
                .enabled
        );
        let disabled = runtime.store().inspect(&worker_id).unwrap();
        assert_eq!(disabled["route"]["enabled"], false);
        assert_eq!(disabled["triggers"][0]["enabled"], false);
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(
            !child_survived.exists(),
            "worker descendant survived disable"
        );

        runtime.set_enabled(&worker_id, true).await.unwrap();
        let enabled = runtime.store().inspect(&worker_id).unwrap();
        assert_eq!(enabled["route"]["enabled"], true);
        assert_eq!(enabled["triggers"][0]["enabled"], true);
    }

    #[tokio::test]
    async fn stopping_one_worker_cancels_current_work_without_disabling_future_dispatch() {
        let (runtime, home) = test_runtime(None);
        let child_started = home.path().join("stop-descendant-started");
        let child_survived = home.path().join("stop-descendant-survived");
        let mut bundle = command_bundle(vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import json,pathlib,subprocess,sys,time; request=json.load(sys.stdin); block=request.get('block',False); subprocess.Popen([sys.executable,'-c','import pathlib,sys,time; time.sleep(.4); pathlib.Path(sys.argv[1]).write_text(\"survived\")',sys.argv[2]]) if block else None; pathlib.Path(sys.argv[1]).write_text('started') if block else None; time.sleep(30) if block else None; print(json.dumps(request))".to_owned(),
            child_started.display().to_string(),
            child_survived.display().to_string(),
        ]);
        bundle.triggers = vec![WorkerTrigger::Manual {
            id: "manual".to_owned(),
        }];
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let worker_id = outcome.worker.worker_id;
        let invoking = {
            let runtime = Arc::clone(&runtime);
            let worker_id = worker_id.clone();
            tokio::spawn(async move {
                runtime
                    .invoke(request(&worker_id, json!({"block":true}), "stop-running"))
                    .await
            })
        };
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        while tokio::time::Instant::now() < deadline {
            if child_started.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(child_started.exists(), "worker descendant never started");

        let stopped = runtime.stop_worker(&worker_id).await.unwrap();
        assert_eq!(stopped["enabled"], true);
        assert_eq!(stopped["retired"], false);
        let result = invoking.await.unwrap().unwrap();
        assert_eq!(result.status, "failed");
        assert!(result.error.unwrap().contains("per-worker stop"));
        let inspection = runtime.store().inspect(&worker_id).unwrap();
        assert_eq!(inspection["worker"]["enabled"], true);
        assert_eq!(inspection["worker"]["health"], "healthy");
        assert_eq!(inspection["route"]["enabled"], true);
        assert_eq!(inspection["triggers"][0]["enabled"], true);
        assert!(
            inspection["audit"]
                .as_array()
                .is_some_and(|audit| { audit.iter().any(|entry| entry["action"] == "stopped") })
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(
            !child_survived.exists(),
            "worker descendant survived per-worker stop"
        );

        let resumed = runtime
            .invoke(request(
                &worker_id,
                json!({"block":false,"value":"after-stop"}),
                "after-stop",
            ))
            .await
            .unwrap();
        assert_eq!(resumed.status, "completed");
        assert_eq!(
            resumed.output,
            Some(json!({"block":false,"value":"after-stop"}))
        );
    }

    #[tokio::test]
    async fn shutdown_cancels_process_trees_and_restart_redelivers_the_interrupted_attempt() {
        let (runtime, home) = test_runtime(None);
        let child_started = home.path().join("shutdown-descendant-started");
        let child_survived = home.path().join("shutdown-descendant-survived");
        let bundle = command_bundle(vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import json,pathlib,subprocess,sys,time; started=pathlib.Path(sys.argv[1]); survived=pathlib.Path(sys.argv[2]); print(json.dumps({})) if started.exists() else (subprocess.Popen([sys.executable,'-c','import pathlib,sys,time; time.sleep(.4); pathlib.Path(sys.argv[1]).write_text(\"survived\")',str(survived)]),started.write_text('started'),time.sleep(30))".to_owned(),
            child_started.display().to_string(),
            child_survived.display().to_string(),
        ]);
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let worker_id = outcome.worker.worker_id;
        let invoking = {
            let runtime = Arc::clone(&runtime);
            let worker_id = worker_id.clone();
            tokio::spawn(async move {
                runtime
                    .invoke(request(&worker_id, json!({}), "shutdown-running"))
                    .await
            })
        };
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        while tokio::time::Instant::now() < deadline {
            if child_started.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(child_started.exists(), "worker descendant never started");

        runtime.shutdown().await;
        let error = invoking.await.unwrap().unwrap_err();
        assert!(error.contains("runtime shutdown"));
        let interrupted = runtime
            .store()
            .runs(Some(&worker_id), 10)
            .unwrap()
            .into_iter()
            .next()
            .unwrap();
        assert_eq!(interrupted.status, "running");
        assert_eq!(interrupted.attempt_count, 1);
        let summary = runtime.store().summary(&worker_id).unwrap().unwrap();
        assert!(summary.enabled);
        assert_eq!(summary.health, "healthy");
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(
            !child_survived.exists(),
            "worker descendant survived runtime shutdown"
        );

        let restarted = test_runtime_at(home.path(), None);
        let recovered = restarted
            .invoke(request(&worker_id, json!({}), "shutdown-running"))
            .await
            .unwrap();
        assert_eq!(recovered.status, "completed");
        assert_eq!(recovered.attempt_count, 2);
        let attempts = restarted
            .store()
            .attempts(&recovered.invocation_id)
            .unwrap();
        assert_eq!(attempts[0]["status"], "interrupted");
        assert_eq!(attempts[1]["status"], "completed");
    }

    #[tokio::test]
    async fn every_worker_console_lifecycle_mutation_emits_live_refresh_evidence() {
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
                None,
            )
            .await
            .unwrap();
        let worker_id = outcome.worker.worker_id;
        let version = outcome.version;

        runtime.set_enabled(&worker_id, false).await.unwrap();
        runtime.set_enabled(&worker_id, true).await.unwrap();
        runtime.stop_worker(&worker_id).await.unwrap();
        runtime.rollback(&worker_id, &version).await.unwrap();
        runtime.retire(&worker_id).await.unwrap();
        runtime.purge(&worker_id).await.unwrap();
        runtime.set_stop_all(true).await.unwrap();
        runtime.set_stop_all(false).await.unwrap();

        let events = runtime
            .host
            .poll_stream_topic(
                "worker.lifecycle",
                StreamCursor(0),
                100,
                &StreamActorScope::admin(),
            )
            .await
            .unwrap();
        let actions = events
            .events
            .iter()
            .filter_map(|event| event.payload["action"].as_str())
            .collect::<BTreeSet<_>>();
        for expected in [
            "activated",
            "disabled",
            "enabled",
            "stopped",
            "rolled_back",
            "retired",
            "purged",
            "stop_all",
            "resumed_all",
        ] {
            assert!(
                actions.contains(expected),
                "missing {expected}: {actions:?}"
            );
        }
    }

    #[tokio::test]
    async fn schedule_event_and_authenticated_webhook_share_the_durable_dispatch_path() {
        let (runtime, home) = test_runtime(None);
        let mut bundle = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        bundle.worker_id = Some("all-trigger-worker".to_owned());
        bundle.name = "All Trigger Worker".to_owned();
        bundle.tool_name = Some("worker_all_triggers".to_owned());
        bundle.triggers = vec![
            WorkerTrigger::Manual {
                id: "manual".to_owned(),
            },
            WorkerTrigger::Schedule {
                id: "scheduled".to_owned(),
                every_seconds: 1,
                input: json!({"kind":"schedule"}),
            },
            WorkerTrigger::EngineEvent {
                id: "engine-event".to_owned(),
                topic: "worker.fixture".to_owned(),
                filter: json!({"ready":true,"nested":{"state":"active"}}),
                input: json!({"kind":"event"}),
            },
            WorkerTrigger::Webhook {
                id: "local-webhook".to_owned(),
                input: json!({"kind":"webhook"}),
            },
        ];
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        assert_eq!(outcome.webhooks.len(), 1);
        let credential = &outcome.webhooks[0];
        assert!(
            runtime
                .store()
                .verify_webhook(
                    &outcome.worker.worker_id,
                    &credential.trigger_id,
                    "wrong-token"
                )
                .is_err()
        );
        let mut webhook_input = runtime
            .store()
            .verify_webhook(
                &outcome.worker.worker_id,
                &credential.trigger_id,
                &credential.token,
            )
            .unwrap();
        webhook_input
            .as_object_mut()
            .unwrap()
            .insert("payload".to_owned(), json!(1));
        let webhook = runtime
            .invoke(InvokeRequest {
                worker_id: outcome.worker.worker_id.clone(),
                input: webhook_input,
                idempotency_key: "webhook:local-webhook:request-1".to_owned(),
                trace_id: "webhook-trace".to_owned(),
                causal_depth: 0,
                trigger_kind: "webhook".to_owned(),
            })
            .await
            .unwrap();
        assert_eq!(webhook.status, "completed");

        runtime
            .publish_event(
                "worker.fixture",
                json!({"ready":true,"nested":{"state":"active","extra":1}}),
                Some(TraceId::new("fixture-event-trace").unwrap()),
            )
            .await;
        let mut event_runs = JoinSet::new();
        runtime.dispatch_events(&mut event_runs).await;
        while event_runs.join_next().await.is_some() {}

        tokio::time::sleep(Duration::from_millis(1_100)).await;
        let mut schedule_runs = JoinSet::new();
        runtime.dispatch_schedules(&mut schedule_runs).await;
        while schedule_runs.join_next().await.is_some() {}

        let runs = runtime
            .store()
            .runs(Some(&outcome.worker.worker_id), 20)
            .unwrap();
        assert!(runs.iter().any(|run| run.trigger_kind == "webhook"));
        assert!(runs.iter().any(|run| run.trigger_kind == "engine_event"));
        assert!(runs.iter().any(|run| run.trigger_kind == "schedule"));
        assert!(runs.iter().all(|run| run.status == "completed"));
        let durable_bytes =
            std::fs::read(home.path().join("internal/database/workers.sqlite")).unwrap();
        assert!(!String::from_utf8_lossy(&durable_bytes).contains(&credential.token));
        assert!(
            !walkdir::WalkDir::new(home.path().join("workspace/workers"))
                .into_iter()
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().is_file())
                .any(|entry| {
                    std::fs::read(entry.path()).is_ok_and(|bytes| {
                        String::from_utf8_lossy(&bytes).contains(&credential.token)
                    })
                })
        );
    }

    #[tokio::test]
    async fn dependency_or_smoke_failure_never_changes_active_version() {
        let (runtime, home) = test_runtime(None);
        let first = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
                None,
            )
            .await
            .unwrap();
        let active = first.version;

        let dependency = home.path().join("dependency");
        std::fs::create_dir_all(&dependency).unwrap();
        std::fs::write(dependency.join("source.txt"), "locked").unwrap();
        let mut bad_dependency =
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        bad_dependency.description.push_str(" updated");
        bad_dependency.dependencies.push(WorkerDependency {
            name: "upstream".to_owned(),
            source: format!("file://{}", dependency.display()),
            version: "1".to_owned(),
            checksum: Some(format!("sha256:{}", "0".repeat(64))),
            install: None,
        });
        assert!(
            runtime
                .upsert(bad_dependency, Some("echo-worker"))
                .await
                .unwrap_err()
                .contains("checksum mismatch")
        );

        let mut bad_smoke =
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        bad_smoke.description.push_str(" smoke update");
        bad_smoke.smoke_tests.push(WorkerCommand {
            command: vec!["sh".to_owned(), "-c".to_owned(), "exit 9".to_owned()],
            timeout_seconds: 5,
        });
        assert!(
            runtime
                .upsert(bad_smoke, Some("echo-worker"))
                .await
                .is_err()
        );
        let mut bad_health =
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        bad_health.description.push_str(" health update");
        bad_health.health_checks.push(WorkerCommand {
            command: vec!["sh".to_owned(), "-c".to_owned(), "exit 10".to_owned()],
            timeout_seconds: 5,
        });
        assert!(
            runtime
                .upsert(bad_health, Some("echo-worker"))
                .await
                .is_err()
        );
        assert_eq!(
            runtime
                .store()
                .summary("echo-worker")
                .unwrap()
                .unwrap()
                .active_version,
            active
        );
    }

    #[tokio::test]
    async fn post_activation_failure_disables_worker_and_enters_inbox() {
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec![
                    "sh".to_owned(),
                    "-c".to_owned(),
                    "echo execution-failed >&2; exit 7".to_owned(),
                ]),
                None,
            )
            .await
            .unwrap();
        let result = runtime
            .invoke(request(&outcome.worker.worker_id, json!({}), "failure"))
            .await
            .unwrap();

        assert_eq!(result.status, "failed");
        let summary = runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap();
        assert!(!summary.enabled);
        assert_eq!(summary.health, "failed");
        let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
        assert_eq!(inspection["route"]["enabled"], false);
        assert_eq!(inspection["healthHistory"][0]["status"], "failed");
        let inbox = runtime
            .store()
            .inbox(Some(&outcome.worker.worker_id), 10)
            .unwrap();
        assert_eq!(inbox[0]["severity"], "error");
        assert!(
            runtime
                .store()
                .audit(Some(&outcome.worker.worker_id), 10)
                .unwrap()
                .iter()
                .any(|item| item["action"] == "failed")
        );
    }

    #[tokio::test]
    async fn canonical_version_tampering_disables_routing_before_execution() {
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
                None,
            )
            .await
            .unwrap();
        let active = runtime
            .store()
            .load_active(&outcome.worker.worker_id)
            .unwrap();
        std::fs::write(active.version_dir.join("files/tampered.txt"), "changed").unwrap();

        let record = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({}),
                "tampered-version",
            ))
            .await
            .unwrap();

        assert_eq!(record.status, "failed", "{record:?}");
        assert!(
            record
                .error
                .as_deref()
                .is_some_and(|error| error.contains("integrity check failed")),
            "{record:?}"
        );
        assert_eq!(record.attempt_count, 1);
        assert_eq!(
            runtime
                .store()
                .summary(&outcome.worker.worker_id)
                .unwrap()
                .unwrap()
                .enabled,
            false
        );
        assert_eq!(
            runtime
                .store()
                .inbox(Some(&outcome.worker.worker_id), 10)
                .unwrap()
                .len(),
            1
        );
        assert!(
            runtime
                .host
                .inspect_function(
                    &FunctionId::new(format!(
                        "worker_kernel::dynamic_{}",
                        outcome.worker.worker_id
                    ))
                    .unwrap(),
                    None,
                )
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn direct_tool_activation_failure_cannot_leave_an_enabled_unroutable_worker() {
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
                None,
            )
            .await
            .unwrap();

        let reason = runtime
            .handle_tool_activation_failure(
                &outcome.worker.worker_id,
                &outcome.version,
                "enable",
                "synthetic catalog collision",
            )
            .await;

        assert!(reason.contains("synthetic catalog collision"));
        let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
        assert_eq!(inspection["worker"]["enabled"], false);
        assert_eq!(inspection["route"]["enabled"], false);
        assert_eq!(inspection["healthHistory"][0]["status"], "failed");
        let inbox = runtime
            .store()
            .inbox(Some(&outcome.worker.worker_id), 10)
            .unwrap();
        assert_eq!(inbox[0]["severity"], "error");
        assert_eq!(inbox[0]["result"]["phase"], "enable");
        assert!(
            runtime
                .host
                .inspect_function(
                    &FunctionId::new(format!(
                        "worker_kernel::dynamic_{}",
                        outcome.worker.worker_id
                    ))
                    .unwrap(),
                    None,
                )
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn dynamic_tool_registration_cannot_escape_disabled_autonomy() {
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
                None,
            )
            .await
            .unwrap();
        let before =
            crate::domains::agent::r#loop::primitive_surface::resolve_provider_primitive_surface(
                &runtime.host,
                "dynamic-registration-race",
                None,
            )
            .await
            .unwrap();
        assert!(
            before
                .targets_by_name
                .contains_key(&outcome.worker.tool_name)
        );

        let settings_path = crate::shared::server::test_support::test_user_profile_path(
            runtime.profile_runtime.home(),
        );
        crate::domains::settings::profile::SettingsStore::new(settings_path)
            .update(json!({"autonomousWorkers":false}))
            .unwrap();
        runtime
            .profile_runtime
            .reload_now("dynamic registration autonomy race test")
            .unwrap();

        runtime
            .register_dynamic_tool(&outcome.worker.worker_id)
            .await
            .unwrap();

        let after =
            crate::domains::agent::r#loop::primitive_surface::resolve_provider_primitive_surface(
                &runtime.host,
                "dynamic-registration-race",
                None,
            )
            .await
            .unwrap();
        assert!(
            !after
                .targets_by_name
                .contains_key(&outcome.worker.tool_name)
        );
        assert!(
            runtime
                .store()
                .summary(&outcome.worker.worker_id)
                .unwrap()
                .unwrap()
                .enabled,
            "profile mode changes must preserve canonical worker enablement"
        );
    }

    #[tokio::test]
    async fn secret_values_are_injected_then_redacted_from_durable_results() {
        let (captured_logs, _log_guard) = crate::shared::observability::capture_logs();
        let (runtime, home) = test_runtime(None);
        let vault = home.path().join("workspace/vault");
        std::fs::create_dir_all(&vault).unwrap();
        let secret = "top-secret-test-value";
        let undeclared_secret = "another-vault-only-secret";
        std::fs::write(vault.join("api-key"), secret).unwrap();
        std::fs::write(vault.join("other-key"), undeclared_secret).unwrap();
        let mut bundle = command_bundle(vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "printf '{\"value\":\"%s\"}' \"$TRON_SECRET_API_KEY\"".to_owned(),
        ]);
        bundle.secret_bindings = vec![super::super::types::WorkerSecretBinding::Optional(
            "api-key".to_owned(),
        )];
        let outcome = runtime.upsert(bundle.clone(), None).await.unwrap();
        let result = runtime
            .invoke(request(&outcome.worker.worker_id, json!({}), "secret"))
            .await
            .unwrap();
        assert_eq!(
            result.output,
            Some(json!({"value":"[REDACTED]"})),
            "secret worker result: {result:?}"
        );
        let diagnostics = format!(
            "{}{}",
            serde_json::to_string(&runtime.store().runs(None, 10).unwrap()).unwrap(),
            serde_json::to_string(&runtime.store().inbox(None, 10).unwrap()).unwrap()
        );
        assert!(!diagnostics.contains(secret));
        assert!(
            runtime
                .invoke(request(
                    &outcome.worker.worker_id,
                    json!({"copiedSecret":secret}),
                    "secret-in-input",
                ))
                .await
                .unwrap_err()
                .contains("only through declared logical bindings")
        );
        assert_eq!(runtime.store().runs(None, 10).unwrap().len(), 1);

        let mut failing = bundle.clone();
        failing
            .description
            .push_str(" with failure redaction evidence");
        failing.runner = WorkerRunner::Command {
            command: vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "printf '%s' \"$TRON_SECRET_API_KEY\" >&2; exit 17".to_owned(),
            ],
        };
        let failed_version = runtime
            .upsert(failing, Some(&outcome.worker.worker_id))
            .await
            .unwrap();
        let failed = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({}),
                "secret-error",
            ))
            .await
            .unwrap();
        assert_eq!(failed.status, "failed");
        assert!(
            failed
                .error
                .as_deref()
                .is_some_and(|error| error.contains("[REDACTED]") && !error.contains(secret))
        );
        let events = runtime
            .host
            .poll_stream_topic(
                "worker.invocations",
                StreamCursor(0),
                100,
                &StreamActorScope::admin(),
            )
            .await
            .unwrap();
        let operational_evidence = format!(
            "{}{}{}{}{:?}",
            serde_json::to_string(&runtime.store().inspect(&outcome.worker.worker_id).unwrap())
                .unwrap(),
            serde_json::to_string(&runtime.store().runs(None, 100).unwrap()).unwrap(),
            serde_json::to_string(&runtime.store().inbox(None, 100).unwrap()).unwrap(),
            serde_json::to_string(&events).unwrap(),
            captured_logs.events(),
        );
        assert!(!operational_evidence.contains(secret));
        for entry in walkdir::WalkDir::new(
            home.path()
                .join("workspace/workers")
                .join(&outcome.worker.worker_id),
        )
        .follow_links(false)
        {
            let entry = entry.unwrap();
            if entry.file_type().is_file() {
                let bytes = std::fs::read(entry.path()).unwrap();
                assert!(
                    !bytes
                        .windows(secret.len())
                        .any(|window| window == secret.as_bytes()),
                    "secret leaked into {}",
                    entry.path().display()
                );
            }
        }
        assert_eq!(
            failed_version.worker.active_version, failed.worker_version,
            "redaction failure must still be pinned to the activated version"
        );

        bundle
            .files
            .insert("leak.txt".to_owned(), secret.to_owned());
        assert!(
            runtime
                .upsert(bundle, None)
                .await
                .unwrap_err()
                .contains("contains the value")
        );

        let mut undeclared_leak =
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        undeclared_leak
            .files
            .insert("undeclared.txt".to_owned(), undeclared_secret.to_owned());
        assert!(
            runtime
                .upsert(undeclared_leak, None)
                .await
                .unwrap_err()
                .contains("other-key")
        );
    }

    #[tokio::test]
    async fn command_timeout_is_bounded_and_kills_the_child() {
        let temporary = tempfile::tempdir().unwrap();
        let started = std::time::Instant::now();
        let error = run_worker_command(
            &WorkerCommand {
                command: vec!["sh".to_owned(), "-c".to_owned(), "sleep 5".to_owned()],
                timeout_seconds: 1,
            },
            temporary.path(),
            None,
            &HashMap::new(),
            None,
        )
        .await
        .unwrap_err();
        assert!(error.contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[tokio::test]
    async fn successful_command_may_ignore_typed_input_without_a_broken_pipe_failure() {
        let temporary = tempfile::tempdir().unwrap();
        let output = run_worker_command(
            &WorkerCommand {
                command: vec![
                    "sh".to_owned(),
                    "-c".to_owned(),
                    "printf '{\"accepted\":true}'".to_owned(),
                ],
                timeout_seconds: 5,
            },
            temporary.path(),
            Some(&json!({"payload":"x".repeat(2_000_000)})),
            &HashMap::new(),
            None,
        )
        .await
        .unwrap();

        assert_eq!(output, json!({"accepted":true}));
    }

    #[tokio::test]
    async fn worker_command_rejects_oversized_stdout_after_draining_the_child() {
        let temporary = tempfile::tempdir().unwrap();
        let started = std::time::Instant::now();
        let error = run_worker_command(
            &WorkerCommand {
                command: vec![
                    "python3".to_owned(),
                    "-c".to_owned(),
                    format!(
                        "import sys; sys.stdout.write('x'*{})",
                        MAX_PROCESS_CAPTURE_BYTES + 1
                    ),
                ],
                timeout_seconds: 5,
            },
            temporary.path(),
            None,
            &HashMap::new(),
            None,
        )
        .await
        .unwrap_err();

        assert!(error.contains("capture ceiling"), "{error}");
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    struct JsonResponder;

    fn worker_test_responder_info() -> ModelResponderInfo {
        ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::Anthropic,
            provider_name: "worker-test",
            model: "worker-test-model".to_owned(),
            context_window: 20_000,
        }
    }

    #[async_trait]
    impl ModelResponder for JsonResponder {
        fn info(&self) -> ModelResponderInfo {
            worker_test_responder_info()
        }

        async fn respond(
            &self,
            request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
            let context = serde_json::to_string(&request.context.messages)
                .expect("serialize agent worker prompt context");
            assert!(context.contains("idempotencyKey"), "{context}");
            assert!(context.contains("trace-agent"), "{context}");
            let text = "{\"answer\":\"agent-runner\"}";
            let events = vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: text.to_owned(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(text)],
                        token_usage: None,
                    },
                    stop_reason: "end_turn".to_owned(),
                }),
            ];
            Ok(ModelResponse {
                info: self.info(),
                stream: Box::pin(stream::iter(events)) as ModelResponseStream,
            })
        }
    }

    struct JsonResponderFactory;

    #[async_trait]
    impl ModelResponderFactory for JsonResponderFactory {
        async fn create_for_model(
            &self,
            _model: &str,
            _settings: &crate::domains::settings::ApiSettings,
        ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
            Ok(Arc::new(JsonResponder))
        }
    }

    #[tokio::test]
    async fn agent_runner_returns_typed_json() {
        let (runtime, _home) = test_runtime(Some(Arc::new(JsonResponderFactory)));
        let mut bundle = command_bundle(Vec::new());
        bundle.name = "Agent Worker".to_owned();
        bundle.description = "Executes a durable agent instruction contract".to_owned();
        bundle.tool_name = Some("worker_agent_test".to_owned());
        bundle.output_schema = json!({
            "type":"object",
            "required":["answer"],
            "properties":{"answer":{"type":"string"}}
        });
        bundle.runner = WorkerRunner::Agent {
            instructions: "Return the requested typed JSON answer.".to_owned(),
            model: None,
        };
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let result = runtime
            .invoke(request(&outcome.worker.worker_id, json!({}), "agent"))
            .await
            .unwrap();
        assert_eq!(
            result.output,
            Some(json!({"answer":"agent-runner"})),
            "agent worker result: {result:?}"
        );
    }

    struct NestedDepthResponder {
        calls: Arc<AtomicUsize>,
    }

    impl NestedDepthResponder {
        fn response(events: Vec<Result<StreamEvent, ModelResponseError>>) -> ModelResponse {
            ModelResponse {
                info: worker_test_responder_info(),
                stream: Box::pin(stream::iter(events)) as ModelResponseStream,
            }
        }

        fn tool_call() -> ModelResponse {
            let arguments = serde_json::Map::from_iter([
                ("workerId".to_owned(), json!("nested-depth-target")),
                ("input".to_owned(), json!({})),
                ("idempotencyKey".to_owned(), json!("nested-depth-delivery")),
            ]);
            Self::response(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::CapabilityInvocationDraftStart {
                    invocation_id: "nested-depth-call".to_owned(),
                    name: "worker_invoke".to_owned(),
                }),
                Ok(StreamEvent::CapabilityInvocationDraftDelta {
                    invocation_id: "nested-depth-call".to_owned(),
                    arguments_delta: serde_json::to_string(&arguments).unwrap(),
                }),
                Ok(StreamEvent::CapabilityInvocationDraftEnd {
                    capability_invocation:
                        crate::shared::protocol::messages::CapabilityInvocationDraft::new(
                            "nested-depth-call",
                            "worker_invoke",
                            arguments,
                        ),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: Vec::new(),
                        token_usage: None,
                    },
                    stop_reason: "capability_invocation".to_owned(),
                }),
            ])
        }
    }

    #[async_trait]
    impl ModelResponder for NestedDepthResponder {
        fn info(&self) -> ModelResponderInfo {
            worker_test_responder_info()
        }

        async fn respond(
            &self,
            request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
            match self.calls.fetch_add(1, Ordering::SeqCst) {
                0 => {
                    let tools = request
                        .context
                        .capabilities
                        .as_ref()
                        .expect("agent worker tools")
                        .iter()
                        .map(|tool| tool.name.as_str())
                        .collect::<Vec<_>>();
                    assert!(tools.contains(&"worker_invoke"), "{tools:?}");
                    Ok(Self::tool_call())
                }
                1 => {
                    let messages = serde_json::to_string(&request.context.messages).unwrap();
                    assert!(
                        messages.contains("causal depth 17") && messages.contains("limit 16"),
                        "nested worker call escaped the causal ceiling: {messages}"
                    );
                    let result = "{\"answer\":\"depth-blocked\"}";
                    Ok(Self::response(vec![
                        Ok(StreamEvent::Start),
                        Ok(StreamEvent::TextDelta {
                            delta: result.to_owned(),
                        }),
                        Ok(StreamEvent::Done {
                            message: AssistantMessage {
                                content: vec![AssistantContent::text(result)],
                                token_usage: None,
                            },
                            stop_reason: "end_turn".to_owned(),
                        }),
                    ]))
                }
                call => panic!("unexpected nested-depth responder call {call}"),
            }
        }
    }

    struct NestedDepthResponderFactory {
        calls: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl ModelResponderFactory for NestedDepthResponderFactory {
        async fn create_for_model(
            &self,
            _model: &str,
            _settings: &crate::domains::settings::ApiSettings,
        ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
            Ok(Arc::new(NestedDepthResponder {
                calls: Arc::clone(&self.calls),
            }))
        }
    }

    #[tokio::test]
    async fn agent_runner_preserves_causal_depth_for_nested_worker_calls() {
        let calls = Arc::new(AtomicUsize::new(0));
        let (runtime, _home) = test_runtime(Some(Arc::new(NestedDepthResponderFactory {
            calls: Arc::clone(&calls),
        })));

        let mut target = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
        target.worker_id = Some("nested-depth-target".to_owned());
        target.name = "Nested Depth Target".to_owned();
        target.description =
            "Target used only to detect an escaped causal-depth ceiling".to_owned();
        target.tool_name = Some("worker_nested_depth_target".to_owned());
        runtime.upsert(target, None).await.unwrap();

        let mut agent = command_bundle(Vec::new());
        agent.worker_id = Some("nested-depth-agent".to_owned());
        agent.name = "Nested Depth Agent".to_owned();
        agent.description = "Agent runner that attempts one nested worker dispatch".to_owned();
        agent.tool_name = Some("worker_nested_depth_agent".to_owned());
        agent.output_schema = json!({
            "type":"object",
            "required":["answer"],
            "properties":{"answer":{"type":"string"}}
        });
        agent.runner = WorkerRunner::Agent {
            instructions: "Attempt the nested worker call, then return typed JSON.".to_owned(),
            model: None,
        };
        let outcome = runtime.upsert(agent, None).await.unwrap();
        let mut invocation = request(&outcome.worker.worker_id, json!({}), "nested-depth-agent");
        invocation.causal_depth = MAX_CAUSAL_DEPTH;

        let completed = runtime.invoke(invocation).await.unwrap();

        assert_eq!(completed.status, "completed", "{completed:?}");
        assert_eq!(completed.output, Some(json!({"answer":"depth-blocked"})));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(
            runtime
                .store()
                .runs(Some("nested-depth-target"), 10)
                .unwrap()
                .is_empty(),
            "over-depth nested dispatch must fail before persistence"
        );
    }

    struct PendingResponder;

    #[async_trait]
    impl ModelResponder for PendingResponder {
        fn info(&self) -> ModelResponderInfo {
            worker_test_responder_info()
        }

        async fn respond(
            &self,
            _request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
            Ok(ModelResponse {
                info: self.info(),
                stream: Box::pin(stream::pending::<Result<StreamEvent, ModelResponseError>>())
                    as ModelResponseStream,
            })
        }
    }

    struct PendingResponderFactory;

    #[async_trait]
    impl ModelResponderFactory for PendingResponderFactory {
        async fn create_for_model(
            &self,
            _model: &str,
            _settings: &crate::domains::settings::ApiSettings,
        ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
            Ok(Arc::new(PendingResponder))
        }
    }

    #[tokio::test]
    async fn disabling_agent_worker_aborts_its_spawned_child_session() {
        let (runtime, _home) = test_runtime(Some(Arc::new(PendingResponderFactory)));
        let mut bundle = command_bundle(Vec::new());
        bundle.worker_id = Some("cancellable-agent".to_owned());
        bundle.name = "Cancellable Agent".to_owned();
        bundle.description = "Pending agent runner used to prove lifecycle cancellation".to_owned();
        bundle.tool_name = Some("worker_cancellable_agent".to_owned());
        bundle.runner = WorkerRunner::Agent {
            instructions: "Wait until the invocation is stopped.".to_owned(),
            model: None,
        };
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let worker_id = outcome.worker.worker_id.clone();
        let invoke_runtime = Arc::clone(&runtime);
        let invoke_worker_id = worker_id.clone();
        let invocation = tokio::spawn(async move {
            invoke_runtime
                .invoke(request(&invoke_worker_id, json!({}), "cancellable-agent"))
                .await
                .unwrap()
        });

        tokio::time::timeout(Duration::from_secs(5), async {
            while runtime.orchestrator.active_run_count() == 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("agent worker child session did not start");

        runtime.set_enabled(&worker_id, false).await.unwrap();
        let record = tokio::time::timeout(Duration::from_secs(5), invocation)
            .await
            .expect("disabled agent worker invocation did not terminate")
            .unwrap();
        assert_eq!(record.status, "failed", "{record:?}");
        assert!(
            record
                .error
                .as_deref()
                .is_some_and(|error| error.contains("disabled")),
            "{record:?}"
        );
        tokio::time::timeout(Duration::from_secs(5), async {
            while runtime.orchestrator.active_run_count() != 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("agent worker child session outlived its disabled invocation");
    }

    #[tokio::test]
    async fn resident_service_starts_lazily_and_handles_multiple_calls() {
        let (runtime, home) = test_runtime(None);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let escaped_descendant = home.path().join("resident-descendant-escaped");
        let script = r#"import http.server,json,subprocess,sys
subprocess.Popen([sys.executable,'-c','import os,pathlib,sys,time; parent=os.getppid();\nwhile os.getppid()==parent: time.sleep(.01)\npathlib.Path(sys.argv[1]).write_text(\"escaped\")',sys.argv[2]])
open('service-runtime-only.txt','w').write('runtime')
sys.stderr.write('resident startup log\n'*200000); sys.stderr.flush()
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
 def do_POST(self):
  n=int(self.headers.get('Content-Length','0')); body=self.rfile.read(n)
  value=json.loads(body); value['idempotencyKey']=self.headers.get('x-tron-idempotency-key'); value['traceId']=self.headers.get('x-tron-trace-id')
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(value).encode())
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#;
        let mut bundle = command_bundle(Vec::new());
        bundle.name = "Resident Echo".to_owned();
        bundle.description = "Lazy supervised resident HTTP echo service".to_owned();
        bundle.tool_name = Some("worker_resident_echo".to_owned());
        bundle.runner = WorkerRunner::Service {
            command: vec![
                "python3".to_owned(),
                "-u".to_owned(),
                "-c".to_owned(),
                script.to_owned(),
                port.to_string(),
                escaped_descendant.display().to_string(),
            ],
            invoke_url: format!("http://127.0.0.1:{port}/invoke"),
            health_url: Some(format!("http://127.0.0.1:{port}/health")),
        };
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        assert!(runtime.residents.is_empty());
        for index in 0..2 {
            let result = runtime
                .invoke(request(
                    &outcome.worker.worker_id,
                    json!({"index":index}),
                    &format!("service-{index}"),
                ))
                .await
                .unwrap();
            assert_eq!(
                result.output,
                Some(json!({
                    "index":index,
                    "idempotencyKey":format!("service-{index}"),
                    "traceId":format!("trace-service-{index}"),
                }))
            );
        }
        assert_eq!(runtime.residents.len(), 1);
        assert!(
            !home
                .path()
                .join("workspace/workers")
                .join(&outcome.worker.worker_id)
                .join("versions")
                .join(&outcome.version)
                .join("files/service-runtime-only.txt")
                .exists(),
            "resident service mutated its immutable canonical version"
        );

        runtime.set_stop_all(true).await.unwrap();
        assert!(runtime.residents.is_empty());
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert!(
            !escaped_descendant.exists(),
            "resident descendant survived stop-all"
        );
        runtime.set_stop_all(false).await.unwrap();
        let resumed = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"index":2}),
                "service-after-stop-all",
            ))
            .await
            .unwrap();
        assert_eq!(resumed.output.as_ref().unwrap()["index"], 2);
        assert_eq!(runtime.residents.len(), 1);
        assert!(!escaped_descendant.exists());

        runtime
            .set_enabled(&outcome.worker.worker_id, false)
            .await
            .unwrap();
        assert!(runtime.residents.is_empty());
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert!(
            !escaped_descendant.exists(),
            "resident descendant survived disable"
        );
        runtime
            .set_enabled(&outcome.worker.worker_id, true)
            .await
            .unwrap();
        let enabled = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"index":3}),
                "service-after-enable",
            ))
            .await
            .unwrap();
        assert_eq!(enabled.output.as_ref().unwrap()["index"], 3);
        assert_eq!(runtime.residents.len(), 1);
        assert!(!escaped_descendant.exists());

        runtime.shutdown().await;
        assert!(runtime.residents.is_empty());
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert!(
            !escaped_descendant.exists(),
            "resident descendant survived runtime shutdown"
        );
    }

    #[tokio::test]
    async fn oversized_resident_response_fails_bounded_and_disables_the_worker() {
        let (runtime, _home) = test_runtime(None);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let script = format!(
            r#"import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{{}}')
 def do_POST(self):
  self.send_response(200); self.end_headers(); self.wfile.write(b'x'*{})
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#,
            MAX_PROCESS_CAPTURE_BYTES + 1
        );
        let mut bundle = command_bundle(Vec::new());
        bundle.worker_id = Some("oversized-resident".to_owned());
        bundle.name = "Oversized Resident".to_owned();
        bundle.description = "Resident response ceiling regression fixture".to_owned();
        bundle.tool_name = Some("worker_oversized_resident".to_owned());
        bundle.runner = WorkerRunner::Service {
            command: vec![
                "python3".to_owned(),
                "-u".to_owned(),
                "-c".to_owned(),
                script,
                port.to_string(),
            ],
            invoke_url: format!("http://127.0.0.1:{port}/invoke"),
            health_url: Some(format!("http://127.0.0.1:{port}/health")),
        };
        let outcome = runtime.upsert(bundle, None).await.unwrap();

        let record = runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({}),
                "oversized-resident",
            ))
            .await
            .unwrap();

        assert_eq!(record.status, "failed", "{record:?}");
        assert!(
            record
                .error
                .as_deref()
                .is_some_and(|error| error.contains("4194304-byte ceiling")),
            "{record:?}"
        );
        assert_eq!(
            runtime
                .store()
                .summary(&outcome.worker.worker_id)
                .unwrap()
                .unwrap()
                .enabled,
            false
        );
        assert!(runtime.residents.is_empty());
    }

    #[tokio::test]
    async fn resident_supervisor_disables_an_exited_service_without_another_invocation() {
        let (runtime, _home) = test_runtime(None);
        let mut bundle = command_bundle(Vec::new());
        bundle.worker_id = Some("resident-supervision".to_owned());
        bundle.name = "Resident Supervision".to_owned();
        bundle.description =
            "Long-lived resident fixture whose unexpected exit must be detected proactively"
                .to_owned();
        bundle.tool_name = Some("worker_resident_supervision".to_owned());
        bundle.runner = WorkerRunner::Service {
            command: vec!["sh".to_owned(), "-c".to_owned(), "sleep 30".to_owned()],
            invoke_url: "http://127.0.0.1:1/invoke".to_owned(),
            health_url: None,
        };
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let active = runtime
            .store()
            .load_active(&outcome.worker.worker_id)
            .unwrap();
        let WorkerRunner::Service {
            command,
            health_url,
            ..
        } = &active.bundle.runner
        else {
            panic!("fixture must be a resident service");
        };
        runtime
            .ensure_resident(&active, command, health_url.as_deref(), &HashMap::new())
            .await
            .unwrap();
        let key = resident_key(&active);
        let process = runtime
            .residents
            .get(&key)
            .expect("resident process")
            .clone();
        process
            .lock()
            .await
            .child
            .as_mut()
            .expect("resident child")
            .terminate()
            .await;

        runtime.supervise_residents().await;

        let summary = runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap();
        assert!(!summary.enabled);
        assert_eq!(summary.health, "failed");
        assert!(runtime.residents.is_empty());
        assert!(
            runtime
                .host
                .inspect_function(
                    &FunctionId::new("worker_kernel::dynamic_resident-supervision").unwrap(),
                    None,
                )
                .await
                .is_err(),
            "failed resident must be removed from direct routing"
        );
        let inbox = runtime
            .store()
            .inbox(Some(&outcome.worker.worker_id), 10)
            .unwrap();
        assert!(inbox.iter().any(|item| {
            item["result"]["phase"] == "resident_supervision" && item["result"]["disabled"] == true
        }));
        let inspection = runtime.store().inspect(&outcome.worker.worker_id).unwrap();
        assert_eq!(
            inspection["healthHistory"][0]["source"],
            "resident_supervision"
        );
    }

    #[tokio::test]
    async fn resident_supervisor_requires_repeated_health_failures_before_disabling() {
        let (runtime, _home) = test_runtime(None);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let script = r#"import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(503); self.end_headers()
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()"#;
        let mut bundle = command_bundle(Vec::new());
        bundle.worker_id = Some("resident-health-supervision".to_owned());
        bundle.name = "Resident Health Supervision".to_owned();
        bundle.description =
            "Resident fixture requiring repeated health failures before disablement".to_owned();
        bundle.tool_name = Some("worker_resident_health_supervision".to_owned());
        bundle.runner = WorkerRunner::Service {
            command: vec![
                "python3".to_owned(),
                "-u".to_owned(),
                "-c".to_owned(),
                script.to_owned(),
                port.to_string(),
            ],
            invoke_url: format!("http://127.0.0.1:{port}/invoke"),
            health_url: Some(format!("http://127.0.0.1:{port}/health")),
        };
        let outcome = runtime.upsert(bundle, None).await.unwrap();
        let active = runtime
            .store()
            .load_active(&outcome.worker.worker_id)
            .unwrap();
        let WorkerRunner::Service { command, .. } = &active.bundle.runner else {
            panic!("fixture must be a resident service");
        };
        runtime
            .ensure_resident(&active, command, None, &HashMap::new())
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;

        for attempt in 1..RESIDENT_HEALTH_FAILURE_LIMIT {
            runtime.supervise_residents().await;
            assert!(
                runtime
                    .store()
                    .summary(&outcome.worker.worker_id)
                    .unwrap()
                    .unwrap()
                    .enabled,
                "transient resident health failure {attempt} disabled the worker"
            );
        }
        runtime.supervise_residents().await;

        let summary = runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap();
        assert!(!summary.enabled);
        assert_eq!(summary.health, "failed");
    }

    #[test]
    fn engine_event_filters_are_recursive_json_subsets() {
        assert!(json_subset_matches(
            &json!({"kind":"message","nested":{"status":"ready"}}),
            &json!({"kind":"message","nested":{"status":"ready","extra":1}}),
        ));
        assert!(!json_subset_matches(
            &json!({"kind":"different"}),
            &json!({"kind":"message"}),
        ));
    }

    #[test]
    fn engine_event_projection_overlays_only_typed_payload_fields_without_an_envelope() {
        let materialized = materialize_engine_event_input(
            &json!({"topic":"configured","asOf":"2026-07-20"}),
            &json!({"topic":"from-event","ready":true,"requestId":"ignored"}),
            &json!({
                "type":"object",
                "additionalProperties":false,
                "properties":{"topic":{"type":"string"},"asOf":{"type":"string"}}
            }),
        );
        assert_eq!(
            materialized,
            json!({"topic":"from-event","asOf":"2026-07-20"})
        );
        assert!(materialized.get("event").is_none());
        assert!(materialized.get("requestId").is_none());
    }
}
