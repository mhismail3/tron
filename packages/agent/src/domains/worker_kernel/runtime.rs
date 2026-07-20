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
use tokio::process::{Child, Command};
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
    PublishStreamEvent, RiskLevel, StreamActorScope, StreamCursor, TraceId, VisibilityScope,
    WorkerId,
};

use super::core_proposals::{CoreProposal, CoreProposalService};
use super::store::WorkerStore;
use super::types::{
    ActiveWorker, InvocationRecord, InvokeRequest, MAX_CAUSAL_DEPTH, MAX_INVOCATION_SECONDS,
    MAX_PROFILE_CONCURRENCY, MAX_WORKER_CONCURRENCY, PreparedWorker, UpsertOutcome, WorkerBundle,
    WorkerCommand, WorkerDependency, WorkerRunner, WorkerTrigger,
};

struct ResidentProcess {
    child: Option<Child>,
}

struct RemoveDirectoryOnDrop(PathBuf);

impl Drop for RemoveDirectoryOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
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
    stopped: AtomicBool,
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
        let stopped = store.stop_all()?;
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
            stopped: AtomicBool::new(stopped),
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
            tracing::error!(%error, "failed to register persistent worker tools");
        }
        self.run_dispatcher(cancellation).await;
    }

    pub async fn shutdown(&self) {
        self.stop_residents(None).await;
    }

    pub async fn upsert(
        self: &Arc<Self>,
        bundle: WorkerBundle,
        predecessor: Option<&str>,
    ) -> Result<UpsertOutcome, String> {
        self.reject_secret_material_in_bundle(&bundle)?;
        let mut prepared = self.store.prepare(bundle, predecessor)?;
        if let Err(error) = self.prepare_dependencies_and_test(&prepared).await {
            self.store.abandon(&prepared);
            return Err(error);
        }
        self.store.finalize(&mut prepared)?;
        let outcome = self.store.publish(prepared)?;
        self.stop_obsolete_residents(&outcome.worker.worker_id, &outcome.version)
            .await;
        self.reset_worker_stop(&outcome.worker.worker_id);
        if let Err(error) = self.register_dynamic_tool(&outcome.worker.worker_id).await {
            let reason = format!("dynamic tool activation failed: {error}");
            self.store.mark_failed(&outcome.worker.worker_id, &reason)?;
            self.unregister_dynamic_tool(&outcome.worker.worker_id)
                .await;
            self.publish_event(
                "worker.failed",
                json!({
                    "workerId": outcome.worker.worker_id,
                    "version": outcome.version,
                    "reason": reason,
                    "disabled": true,
                }),
                None,
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

    async fn prepare_dependencies_and_test(&self, prepared: &PreparedWorker) -> Result<(), String> {
        let workdir = prepared.staging_dir.join("files");
        let dependencies = prepared.staging_dir.join("dependencies");
        let runtime = prepared.staging_dir.join("dependency-runtime");
        let secrets = self.load_secrets(&prepared.bundle)?;
        std::fs::create_dir_all(&dependencies).map_err(|error| error.to_string())?;
        std::fs::create_dir_all(&runtime).map_err(|error| error.to_string())?;
        for dependency in &prepared.bundle.dependencies {
            let dependency_dir = dependencies.join(&dependency.name);
            self.fetch_dependency(dependency, &dependency_dir).await?;
            if let Some(install) = &dependency.install {
                run_worker_command(install, &dependency_dir, None, &secrets).await?;
            }
        }
        for test in &prepared.bundle.smoke_tests {
            run_worker_command(test, &workdir, None, &secrets).await?;
        }
        Ok(())
    }

    async fn fetch_dependency(
        &self,
        dependency: &WorkerDependency,
        destination: &Path,
    ) -> Result<(), String> {
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
            run_worker_command(&clone, destination, None, &HashMap::new()).await?;
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
            run_worker_command(&checkout, destination, None, &HashMap::new()).await?;
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
                .is_some_and(|length| length > 134_217_728)
            {
                return Err(format!("dependency '{}' exceeds 128 MiB", dependency.name));
            }
            let bytes = response
                .bytes()
                .await
                .map_err(|error| format!("read dependency '{}': {error}", dependency.name))?;
            if bytes.len() > 134_217_728 {
                return Err(format!("dependency '{}' exceeds 128 MiB", dependency.name));
            }
            std::fs::write(destination.join("source"), bytes)
                .map_err(|error| format!("store dependency '{}': {error}", dependency.name))?;
        }
        let actual = format!("sha256:{}", digest_tree(destination)?);
        if !actual.eq_ignore_ascii_case(&dependency.checksum) {
            return Err(format!(
                "dependency '{}' checksum mismatch: expected {}, got {actual}",
                dependency.name, dependency.checksum
            ));
        }
        Ok(())
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
        if self.stopped.load(Ordering::SeqCst) || self.store.stop_all()? {
            return Err("worker dispatch is stopped for this profile".to_owned());
        }
        if request.causal_depth > MAX_CAUSAL_DEPTH {
            return Err(format!(
                "worker causal depth {} exceeds the profile limit {MAX_CAUSAL_DEPTH}",
                request.causal_depth
            ));
        }
        let worker = self.store.load_active(&request.worker_id)?;
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
        let worker = self
            .store
            .load_version(&queued.worker_id, &queued.worker_version)?;
        if !worker.summary.enabled || worker.summary.retired {
            return Ok(queued);
        }
        let global_stop = self.execution_stop.lock().await.clone();
        let worker_stop = self.worker_stop(&queued.worker_id);
        let profile_permit = self.profile_limit.clone().acquire_owned();
        let profile_permit = tokio::select! {
            permit = profile_permit => permit,
            () = global_stop.cancelled() => return Err("worker dispatch stopped while queued".to_owned()),
            () = worker_stop.cancelled() => return Err("worker was disabled while queued".to_owned()),
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
            () = worker_stop.cancelled() => return Err("worker was disabled while queued".to_owned()),
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
            () = worker_stop.cancelled() => Err("worker invocation stopped because the worker was disabled".to_owned()),
        };
        let was_stopped = global_stop.is_cancelled() || worker_stop.is_cancelled();

        let worker_function =
            FunctionId::new(format!("worker_kernel::dynamic_{}", queued.worker_id))
                .map_err(|error| error.to_string())?;
        let execution = execution.and_then(|output| {
            let secrets = self.load_secrets(&worker.bundle)?;
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
                let secrets = self.load_secrets(&worker.bundle).unwrap_or_default();
                let redacted = redact_known_secrets(&error, &secrets);
                if !was_stopped {
                    self.store.mark_failed(&queued.worker_id, &redacted)?;
                    self.unregister_dynamic_tool(&queued.worker_id).await;
                    self.stop_residents(Some(&queued.worker_id)).await;
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
                let command = WorkerCommand {
                    command: command.clone(),
                    timeout_seconds: MAX_INVOCATION_SECONDS,
                };
                run_worker_command(
                    &command,
                    &worker.version_dir.join("files"),
                    Some(&invocation.input),
                    &secrets,
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
                    let response = self
                        .http
                        .post(invoke_url)
                        .json(&invocation.input)
                        .send()
                        .await
                        .map_err(|error| format!("invoke resident worker: {error}"))?;
                    let status = response.status();
                    let bytes = response
                        .bytes()
                        .await
                        .map_err(|error| format!("read resident worker response: {error}"))?;
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

    async fn execute_agent(
        &self,
        worker: &ActiveWorker,
        invocation: &InvocationRecord,
        instructions: &str,
        model: Option<&str>,
        secrets: &HashMap<String, String>,
    ) -> Result<Value, String> {
        let ephemeral = self
            .store
            .home()
            .join("internal")
            .join("run")
            .join("worker-invocations")
            .join(&invocation.invocation_id);
        let _ephemeral_cleanup = RemoveDirectoryOnDrop(ephemeral.clone());
        let workdir = ephemeral.join("work");
        std::fs::create_dir_all(&workdir)
            .map_err(|error| format!("create agent worker work directory: {error}"))?;
        copy_tree(&worker.version_dir.join("files"), &workdir)?;
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
            "You are executing persistent worker '{}'. Follow its durable contract exactly.\n\n{}\n\nInput JSON:\n{}\n\nNamed secrets, when configured, are available as files under {}. Never reveal their values. Return only the result required by the output schema.",
            worker.summary.name,
            instructions,
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
        .with_idempotency_key(format!("worker-agent:{}", invocation.invocation_id))
        .with_runtime_metadata(
            "workerCausalDepth",
            invocation.causal_depth.saturating_add(1).to_string(),
        );
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
            .or_insert_with(|| Arc::new(Mutex::new(ResidentProcess { child: None })))
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
                let _ = child.kill().await;
            }
            process.child = Some(spawn_process(
                command,
                &worker.version_dir.join("files"),
                secrets,
                Stdio::null(),
            )?);
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
                        let _ = child.kill().await;
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
            self.register_dynamic_tool(worker_id).await?;
        } else {
            self.cancel_worker(worker_id);
            self.unregister_dynamic_tool(worker_id).await;
            self.stop_residents(Some(worker_id)).await;
        }
        Ok(serde_json::to_value(worker).map_err(|error| error.to_string())?)
    }

    pub async fn rollback(
        self: &Arc<Self>,
        worker_id: &str,
        version: &str,
    ) -> Result<Value, String> {
        let (worker, webhooks) = self.store.rollback(worker_id, version)?;
        self.stop_obsolete_residents(worker_id, version).await;
        self.reset_worker_stop(worker_id);
        self.register_dynamic_tool(worker_id).await?;
        Ok(json!({"worker":worker,"webhooks":webhooks}))
    }

    pub async fn retire(self: &Arc<Self>, worker_id: &str) -> Result<Value, String> {
        self.cancel_worker(worker_id);
        self.stop_residents(Some(worker_id)).await;
        self.unregister_dynamic_tool(worker_id).await;
        let worker = self.store.retire(worker_id)?;
        Ok(serde_json::to_value(worker).map_err(|error| error.to_string())?)
    }

    pub async fn purge(self: &Arc<Self>, worker_id: &str) -> Result<bool, String> {
        self.cancel_worker(worker_id);
        self.stop_residents(Some(worker_id)).await;
        self.unregister_dynamic_tool(worker_id).await;
        self.store.purge(worker_id)
    }

    pub async fn set_stop_all(&self, stopped: bool) -> Result<(), String> {
        self.store.set_stop_all(stopped)?;
        self.stopped.store(stopped, Ordering::SeqCst);
        if stopped {
            self.execution_stop.lock().await.cancel();
            self.stop_residents(None).await;
        } else {
            *self.execution_stop.lock().await = CancellationToken::new();
        }
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

    async fn register_active_tools(self: &Arc<Self>) -> Result<(), String> {
        for worker in self.store.list(false)? {
            if worker.enabled && !worker.retired {
                self.register_dynamic_tool(&worker.worker_id).await?;
            }
        }
        Ok(())
    }

    async fn register_dynamic_tool(self: &Arc<Self>, worker_id: &str) -> Result<(), String> {
        let active = self.store.load_active(worker_id)?;
        let function_id = FunctionId::new(format!("worker_kernel::dynamic_{worker_id}"))
            .map_err(|error| error.to_string())?;
        let mut definition = FunctionDefinition::new(
            function_id,
            WorkerId::new("worker_kernel").map_err(|error| error.to_string())?,
            active.summary.description.clone(),
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
            "workerSuccessEvidence": self.store.success_evidence(worker_id)?,
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

    async fn run_dispatcher(self: &Arc<Self>, cancellation: CancellationToken) {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut runs = JoinSet::new();
        loop {
            tokio::select! {
                () = cancellation.cancelled() => break,
                _ = ticker.tick() => {
                    if !self.autonomous_enabled() {
                        self.execution_stop.lock().await.cancel();
                        self.stop_residents(None).await;
                    } else if !self.stopped.load(Ordering::SeqCst) {
                        if self.execution_stop.lock().await.is_cancelled() {
                            *self.execution_stop.lock().await = CancellationToken::new();
                        }
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
            let next_cursor = page.next_cursor.0;
            let mut durable = Vec::new();
            let mut persistence_failed = false;
            for event in page.events {
                if !json_subset_matches(&filter, &event.payload) {
                    continue;
                }
                let mut merged = input.clone();
                if let Some(object) = merged.as_object_mut() {
                    let _ = object.insert(
                        "event".to_owned(),
                        serde_json::to_value(&event).unwrap_or(Value::Null),
                    );
                }
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
                match self.enqueue_request(InvokeRequest {
                    worker_id: event_worker,
                    input: merged,
                    idempotency_key: format!("event:{event_trigger}:{event_cursor}"),
                    trace_id: event.trace_id.map_or_else(
                        || format!("worker-event-{}", uuid::Uuid::now_v7()),
                        |id| id.as_str().to_owned(),
                    ),
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
                let _ = child.kill().await;
                let _ = child.wait().await;
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
        let secrets = self.load_secrets(bundle)?;
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
            .get("workerCausalDepth")
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

async fn run_worker_command(
    spec: &WorkerCommand,
    workdir: &Path,
    input: Option<&Value>,
    secrets: &HashMap<String, String>,
) -> Result<Value, String> {
    let mut child = spawn_process(&spec.command, workdir, secrets, Stdio::piped())?;
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        stdin
            .write_all(
                &serde_json::to_vec(input)
                    .map_err(|error| format!("encode worker input: {error}"))?,
            )
            .await
            .map_err(|error| format!("write worker input: {error}"))?;
    }
    let output = tokio::time::timeout(
        Duration::from_secs(spec.timeout_seconds),
        child.wait_with_output(),
    )
    .await
    .map_err(|_| {
        format!(
            "worker command timed out after {} seconds",
            spec.timeout_seconds
        )
    })?
    .map_err(|error| format!("wait for worker command: {error}"))?;
    if !output.status.success() {
        return Err(redact_known_secrets(
            &format!(
                "worker command exited {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            ),
            secrets,
        ));
    }
    if output.stdout.is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_slice(&output.stdout)
        .or_else(|_| {
            Ok::<Value, serde_json::Error>(json!({
                "stdout": String::from_utf8_lossy(&output.stdout).trim_end()
            }))
        })
        .map_err(|error| error.to_string())
}

fn spawn_process(
    command: &[String],
    workdir: &Path,
    secrets: &HashMap<String, String>,
    stdout: Stdio,
) -> Result<Child, String> {
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
        .stderr(Stdio::piped())
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
    process
        .spawn()
        .map_err(|error| format!("start worker command: {error}"))
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
    entries.retain(|entry| entry.file_type().is_file());
    entries.sort_by(|left, right| left.path().cmp(right.path()));
    let mut digest = Sha256::new();
    for entry in entries {
        let relative = entry
            .path()
            .strip_prefix(root)
            .map_err(|error| error.to_string())?;
        digest.update(relative.to_string_lossy().as_bytes());
        digest.update([0]);
        digest.update(std::fs::read(entry.path()).map_err(|error| error.to_string())?);
        digest.update([0xff]);
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
        }
    }
    Ok(())
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

        let outcome = runtime
            .upsert(last30days_bundle(source_url), None)
            .await
            .unwrap();
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
            2
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
        let checkout = tempfile::tempdir().unwrap();
        assert!(
            std::process::Command::new("git")
                .args(["clone", "--quiet", "--no-checkout", source_url, "."])
                .current_dir(checkout.path())
                .status()
                .unwrap()
                .success()
        );
        assert!(
            std::process::Command::new("git")
                .args(["checkout", "--quiet", "--detach", &revision])
                .current_dir(checkout.path())
                .status()
                .unwrap()
                .success()
        );
        std::fs::remove_dir_all(checkout.path().join(".git")).unwrap();
        let checksum = format!("sha256:{}", digest_tree(checkout.path()).unwrap());

        let mut bundle = last30days_bundle(source_url);
        bundle
            .description
            .push_str(" using a locked upstream checkout");
        bundle.dependencies.push(WorkerDependency {
            name: "upstream".to_owned(),
            source: format!("git+{source_url}"),
            version: revision.clone(),
            checksum: checksum.clone(),
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
        bundle.provenance[0].checksum = Some(checksum);

        let (runtime, _home) = test_runtime(None);
        let outcome = runtime.upsert(bundle, None).await.unwrap();
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
    async fn command_runner_upserts_invokes_and_replays_idempotently() {
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
                None,
            )
            .await
            .unwrap();
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
        assert_eq!(first.output, Some(json!({"topic":"workers"})));
        assert_eq!(replay.invocation_id, first.invocation_id);
        assert_eq!(runtime.store().runs(None, 10).unwrap().len(), 1);

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
        assert_eq!(direct.value, Some(json!({"topic":"direct typed tool"})));
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
        let (runtime, _home) = test_runtime(None);
        let outcome = runtime
            .upsert(
                command_bundle(vec![
                    "sh".to_owned(),
                    "-c".to_owned(),
                    "sleep 30; cat".to_owned(),
                ]),
                None,
            )
            .await
            .unwrap();
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
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while tokio::time::Instant::now() < deadline {
            if runtime
                .store()
                .runs(Some(&worker_id), 10)
                .unwrap()
                .iter()
                .any(|run| run.status == "running")
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

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
            .insert("webhook".to_owned(), json!({"payload":1}));
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
            checksum: format!("sha256:{}", "0".repeat(64)),
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
    async fn secret_values_are_injected_then_redacted_from_durable_results() {
        let (runtime, home) = test_runtime(None);
        let vault = home.path().join("workspace/vault");
        std::fs::create_dir_all(&vault).unwrap();
        let secret = "top-secret-test-value";
        std::fs::write(vault.join("api-key"), secret).unwrap();
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
        assert_eq!(result.output, Some(json!({"value":"[REDACTED]"})));
        let diagnostics = format!(
            "{}{}",
            serde_json::to_string(&runtime.store().runs(None, 10).unwrap()).unwrap(),
            serde_json::to_string(&runtime.store().inbox(None, 10).unwrap()).unwrap()
        );
        assert!(!diagnostics.contains(secret));

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
        )
        .await
        .unwrap_err();
        assert!(error.contains("timed out"));
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    struct JsonResponder;

    #[async_trait]
    impl ModelResponder for JsonResponder {
        fn info(&self) -> ModelResponderInfo {
            ModelResponderInfo {
                provider_type: crate::shared::protocol::messages::Provider::Anthropic,
                provider_name: "worker-test",
                model: "worker-test-model".to_owned(),
                context_window: 20_000,
            }
        }

        async fn respond(
            &self,
            _request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
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

    #[tokio::test]
    async fn resident_service_starts_lazily_and_handles_multiple_calls() {
        let (runtime, _home) = test_runtime(None);
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let script = r#"import http.server,json,sys
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{}')
 def do_POST(self):
  n=int(self.headers.get('Content-Length','0')); body=self.rfile.read(n)
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
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
            assert_eq!(result.output, Some(json!({"index":index})));
        }
        assert_eq!(runtime.residents.len(), 1);
        runtime.shutdown().await;
        assert!(runtime.residents.is_empty());
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
}
