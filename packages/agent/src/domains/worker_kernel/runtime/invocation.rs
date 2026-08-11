//! Claimed invocation execution, concurrency, completion, and runner dispatch.

use super::*;

#[derive(Debug)]
pub(super) struct WorkerExecutionError {
    message: String,
    disables_worker: bool,
}

impl WorkerExecutionError {
    fn isolated_agent_failure(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            disables_worker: false,
        }
    }
}

impl From<String> for WorkerExecutionError {
    fn from(message: String) -> Self {
        Self {
            message,
            disables_worker: true,
        }
    }
}

/// Synchronous last-resort custody for one claimed attempt.
///
/// Normal execution disarms this immediately after durable terminalization.
/// If the async future is dropped, panics, or returns through an unhandled
/// error path after the claim, `Drop` marks the attempt interrupted and
/// requeues the same invocation before its in-process owner disappears.
struct ClaimedInvocationFinalizer {
    store: WorkerStore,
    invocation_id: String,
    armed: bool,
}

impl ClaimedInvocationFinalizer {
    fn new(store: WorkerStore, invocation_id: String) -> Self {
        Self {
            store,
            invocation_id,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for ClaimedInvocationFinalizer {
    fn drop(&mut self) {
        if self.armed {
            let _ = self.store.interrupt_running_invocation(
                &self.invocation_id,
                "claimed worker delivery lost its execution future",
            );
        }
    }
}

/// Own the in-process identity and cancellation registration for one delivery.
/// This must clean up even when the async task itself is aborted.
struct InvocationExecutionOwnership {
    runtime: Arc<WorkerRuntime>,
    invocation_id: String,
}

impl Drop for InvocationExecutionOwnership {
    fn drop(&mut self) {
        let _ = self.runtime.inflight.remove(&self.invocation_id);
        let _ = self.runtime.invocation_stops.remove(&self.invocation_id);
    }
}

impl WorkerRuntime {
    pub(super) async fn execute_queued(
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
        let _execution_ownership = InvocationExecutionOwnership {
            runtime: Arc::clone(self),
            invocation_id: invocation_id.clone(),
        };
        let invocation_stop = self.invocation_stop(&invocation_id);
        let result = self
            .execute_queued_inner(queued, invocation_stop.clone())
            .await;
        let result = self.finalize_claimed_delivery(&invocation_id, result).await;
        self.delivery_maintenance.notify_one();
        result
    }

    /// Ensure that losing an execution future cannot leave a claimed attempt
    /// in the running state until the next process restart.
    async fn finalize_claimed_delivery(
        &self,
        invocation_id: &str,
        result: Result<InvocationRecord, String>,
    ) -> Result<InvocationRecord, String> {
        let current = self.store.invocation(invocation_id)?;
        let Some(current) = current else {
            return result;
        };
        if current.status != "running" {
            return match result {
                Ok(record) => Ok(record),
                Err(_) => Ok(current),
            };
        }
        let terminal = if self.shutting_down.load(Ordering::SeqCst) {
            self.store.interrupt_running_invocation(
                invocation_id,
                "worker delivery interrupted by runtime shutdown",
            )?
        } else {
            let error = result
                .err()
                .unwrap_or_else(|| "worker delivery returned without terminal evidence".to_owned());
            let secrets = self.load_all_runtime_secrets().unwrap_or_default();
            let redacted = redact_known_secrets(&error, &secrets);
            self.store
                .complete_invocation(invocation_id, &current.worker_id, Err(&redacted))?
        };
        self.publish_invocation_event(
            &terminal,
            json!({
                "action":terminal.status,
                "invocationId":terminal.invocation_id,
                "workerId":terminal.worker_id,
                "error":terminal.error,
                "causalDepth":terminal.causal_depth,
                "recoveredOwnership":true,
            }),
        )
        .await;
        Ok(terminal)
    }

    pub(super) async fn execute_queued_inner(
        self: &Arc<Self>,
        queued: InvocationRecord,
        invocation_stop: CancellationToken,
    ) -> Result<InvocationRecord, String> {
        let summary = self
            .store
            .summary(&queued.worker_id)?
            .ok_or_else(|| format!("worker '{}' was not found", queued.worker_id))?;
        if !summary.enabled || summary.retired {
            return Ok(queued);
        }
        // INVARIANT: a healthy resident executes only from the private,
        // verified snapshot that launched it. Reusing that snapshot avoids a
        // full canonical-tree hash on every request without weakening restart
        // integrity: once the process is gone, canonical loading below must
        // verify the complete immutable version again.
        let worker = if let Some(worker) = self
            .running_resident_worker(&queued.worker_id, &queued.worker_version)
            .await
        {
            worker
        } else {
            match self
                .store
                .load_version(&queued.worker_id, &queued.worker_version)
            {
                Ok(worker) => worker,
                Err(error) => {
                    return self.fail_queued_integrity_check(queued, &error).await;
                }
            }
        };
        let global_stop = self.execution_stop.lock().await.clone();
        let worker_stop = self.worker_stop(&queued.worker_id);
        let engine_permit = self.engine_limit.clone().acquire_owned();
        let engine_permit = tokio::select! {
            permit = engine_permit => permit,
            () = global_stop.cancelled() => return Err("worker dispatch stopped while queued".to_owned()),
            () = worker_stop.cancelled() => return Err(self.worker_cancelled_error(&queued.worker_id, true)),
            () = invocation_stop.cancelled() => return self.store.invocation(&queued.invocation_id)?.ok_or_else(|| "cancelled worker invocation disappeared".to_owned()),
        }
            .map_err(|_| "worker engine concurrency gate is closed".to_owned())?;
        let worker_limit = self
            .worker_limits
            .entry(queued.worker_id.clone())
            .or_insert_with(|| Arc::new(Semaphore::new(MAX_WORKER_CONCURRENCY)))
            .clone();
        let worker_permit = tokio::select! {
            permit = worker_limit.acquire_owned() => permit,
            () = global_stop.cancelled() => return Err("worker dispatch stopped while queued".to_owned()),
            () = worker_stop.cancelled() => return Err(self.worker_cancelled_error(&queued.worker_id, true)),
            () = invocation_stop.cancelled() => return self.store.invocation(&queued.invocation_id)?.ok_or_else(|| "cancelled worker invocation disappeared".to_owned()),
        }
            .map_err(|_| "worker concurrency gate is closed".to_owned())?;
        let _permits = (engine_permit, worker_permit);
        if !self.store.claim_running(&queued.invocation_id)? {
            return self
                .store
                .invocation(&queued.invocation_id)?
                .ok_or_else(|| "claimed worker invocation disappeared".to_owned());
        }
        let mut finalization_guard =
            ClaimedInvocationFinalizer::new(self.store.clone(), queued.invocation_id.clone());

        self.publish_invocation_event(
            &queued,
            json!({
                "action": "started",
                "invocationId": queued.invocation_id,
                "workerId": queued.worker_id,
                "version": queued.worker_version,
                "triggerKind": queued.trigger_kind,
                "causalDepth": queued.causal_depth,
            }),
        )
        .await;
        let worker_name = worker.summary.name.clone();
        self.emit_model_tool_progress(
            &queued.invocation_id,
            format!("Running {worker_name}"),
            Some(0.08),
        );
        self.emit_model_tool_output(
            &queued.invocation_id,
            format!("Worker execution started: {worker_name}"),
        );

        let invocation_timeout_seconds = worker
            .bundle
            .execution_limits
            .max_invocation_seconds
            .unwrap_or(MAX_INVOCATION_SECONDS);
        let timed = tokio::time::timeout(
            Duration::from_secs(invocation_timeout_seconds),
            self.execute_worker(&worker, &queued),
        );
        let execution = tokio::select! {
            result = timed => result
                .map_err(|_| {
                    let message = format!("worker invocation exceeded {invocation_timeout_seconds} seconds");
                    if matches!(&worker.bundle.runner, WorkerRunner::Agent { .. }) {
                        WorkerExecutionError::isolated_agent_failure(message)
                    } else {
                        WorkerExecutionError::from(message)
                    }
                })
                .and_then(|result| result),
            () = global_stop.cancelled() => Err("worker invocation stopped by engine stop-all".to_owned().into()),
            () = worker_stop.cancelled() => Err(self.worker_cancelled_error(&queued.worker_id, false).into()),
            () = invocation_stop.cancelled() => Err("worker invocation cancelled explicitly".to_owned().into()),
        };
        if execution.is_ok() {
            self.store.record_run_stage(
                &queued.invocation_id,
                WorkerRunStage::Validation,
                "Validating the typed worker result",
            )?;
            self.emit_model_tool_progress(
                &queued.invocation_id,
                "Validating the typed worker result",
                Some(0.94),
            );
        }
        if invocation_stop.is_cancelled() {
            return self
                .store
                .invocation(&queued.invocation_id)?
                .ok_or_else(|| "cancelled worker invocation disappeared".to_owned());
        }
        if self.shutting_down.load(Ordering::SeqCst) && global_stop.is_cancelled() {
            return Err("worker invocation interrupted by runtime shutdown".to_owned());
        }
        let was_stopped = global_stop.is_cancelled() || worker_stop.is_cancelled();

        let worker_function =
            FunctionId::new(format!("worker_kernel::dynamic_{}", queued.worker_id))
                .map_err(|error| error.to_string())?;
        let execution = execution.and_then(|output| {
            let secrets = self.load_all_runtime_secrets()?;
            let output = redact_json_known_secrets(output, &secrets);
            crate::engine::validate_engine_schema_payload(
                &worker_function,
                "response",
                &worker.bundle.output_schema,
                &output,
            )
            .map_err(|error| format!("worker output does not match its schema: {error}"))?;
            let notification_intents =
                crate::domains::worker_kernel::notifications::notification_intents_for_bundle(
                    &worker.bundle,
                    &output,
                    chrono::Utc::now(),
                )?;
            let artifact_intents =
                crate::domains::worker_kernel::artifacts::artifact_intents_for_bundle(
                    &worker.bundle,
                    &queued.invocation_id,
                    &output,
                )?;
            let agent_delivery_effects =
                crate::domains::worker_kernel::agent_delivery_effects::parse_agent_delivery_effects(
                    &worker.bundle,
                    &output,
                )?;
            let worker_dispatches = self.prepare_worker_dispatches(&worker.bundle, &output)?;
            let worker_wakeup = crate::domains::worker_kernel::wakeups::parse_worker_wakeup(
                &worker.bundle,
                &output,
                chrono::Utc::now(),
            )?;
            let session_organization =
                crate::domains::worker_kernel::session_organization::session_organization_intent_for_bundle(
                    &worker.bundle,
                    &output,
                )?;
            if let Some(wakeup) = &worker_wakeup {
                crate::engine::validate_engine_schema_payload(
                    &worker_function,
                    "request",
                    &worker.bundle.input_schema,
                    &wakeup.input,
                )
                .map_err(|error| {
                    format!("workerWakeup.input does not match inputSchema: {error}")
                })?;
            }
            Ok((
                output,
                notification_intents,
                artifact_intents,
                agent_delivery_effects,
                worker_dispatches,
                worker_wakeup,
                session_organization,
            ))
        });
        let execution = match execution {
            Ok((
                output,
                notification_intents,
                artifact_intents,
                agent_delivery_effects,
                worker_dispatches,
                worker_wakeup,
                session_organization,
            )) => self
                .apply_session_title_result(&queued, &output)
                .await
                .map_err(WorkerExecutionError::from)
                .and_then(|session_organization_dispatch| {
                    let mut worker_dispatches = worker_dispatches;
                    if let Some(dispatch) = session_organization_dispatch {
                        if worker_dispatches.len()
                            >= crate::domains::worker_kernel::dispatches::MAX_WORKER_DISPATCHES_PER_INVOCATION
                        {
                            return Err(WorkerExecutionError::from(
                                "session organization handoff exceeds the per-invocation worker dispatch limit"
                                    .to_owned(),
                            ));
                        }
                        worker_dispatches.push(dispatch);
                    }
                    Ok((
                        output,
                        notification_intents,
                        artifact_intents,
                        agent_delivery_effects,
                        worker_dispatches,
                        worker_wakeup,
                        session_organization,
                    ))
                }),
            Err(error) => Err(error),
        };
        let completed = match execution {
            Ok((
                output,
                notification_intents,
                artifact_intents,
                agent_delivery_effects,
                worker_dispatches,
                worker_wakeup,
                session_organization,
            )) => self
                .store
                .complete_invocation_with_effects_and_session_organization(
                    &queued.invocation_id,
                    &queued.worker_id,
                    &output,
                    &notification_intents,
                    &artifact_intents,
                    &agent_delivery_effects,
                    &worker_dispatches,
                    worker_wakeup.as_ref(),
                    session_organization.as_ref(),
                )?,
            Err(error) => {
                let secrets = self.load_all_runtime_secrets().unwrap_or_default();
                let redacted = redact_known_secrets(&error.message, &secrets);
                let completed = self.store.complete_invocation(
                    &queued.invocation_id,
                    &queued.worker_id,
                    Err(&redacted),
                )?;
                if !was_stopped
                    && error.disables_worker
                    && execution_failure_disables_worker(&queued.trigger_kind)
                {
                    self.store
                        .mark_failed(&queued.worker_id, "execution", &redacted)?;
                    let _ = self
                        .refresh_worker_surface_evidence(&queued.worker_id)
                        .await;
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
                completed
            }
        };
        finalization_guard.disarm();
        self.publish_invocation_event(
            &completed,
            json!({
                "action": completed.status,
                "invocationId": completed.invocation_id,
                "workerId": completed.worker_id,
                "error": completed.error,
                "causalDepth": completed.causal_depth,
            }),
        )
        .await;
        if let Some(dispatch) = self
            .store
            .worker_dispatch_for_target(&completed.invocation_id)
            .unwrap_or_default()
        {
            self.publish_event(
                "worker.dispatches",
                json!({
                    "action":dispatch["state"],
                    "dispatchId":dispatch["dispatchId"],
                    "sourceInvocationId":dispatch["sourceInvocationId"],
                    "sourceWorkerId":dispatch["sourceWorkerId"],
                    "route":dispatch["route"],
                    "targetWorkerId":dispatch["targetWorkerId"],
                    "targetWorkerVersion":dispatch["targetWorkerVersion"],
                    "targetInvocationId":dispatch["targetInvocationId"],
                    "responseBinding":dispatch["responseBinding"],
                    "state":dispatch["state"],
                    "causalDepth":completed.causal_depth,
                }),
                TraceId::new(completed.trace_id.clone()).ok(),
            )
            .await;
        }
        if completed.status == "completed" {
            for dispatch in self
                .store
                .worker_dispatches_for_source(&completed.invocation_id)
                .unwrap_or_default()
            {
                self.publish_event(
                    "worker.dispatches",
                    json!({
                        "action":"queued",
                        "sourceInvocationId":completed.invocation_id,
                        "sourceWorkerId":completed.worker_id,
                        "dispatchId":dispatch["dispatchId"],
                        "route":dispatch["route"],
                        "targetWorkerId":dispatch["targetWorkerId"],
                        "targetWorkerVersion":dispatch["targetWorkerVersion"],
                        "targetInvocationId":dispatch["targetInvocationId"],
                        "responseBinding":dispatch["responseBinding"],
                        "state":dispatch["state"],
                        "causalDepth":completed.causal_depth.saturating_add(1),
                    }),
                    TraceId::new(completed.trace_id.clone()).ok(),
                )
                .await;
            }
            let _ = self
                .refresh_worker_surface_evidence(&completed.worker_id)
                .await;
        }
        Ok(completed)
    }

    pub(super) async fn fail_queued_integrity_check(
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
        let secrets = self.load_all_runtime_secrets().unwrap_or_default();
        let reason = redact_known_secrets(
            &format!("worker immutable-version integrity check failed: {error}"),
            &secrets,
        );
        let completed = self.store.complete_invocation(
            &queued.invocation_id,
            &queued.worker_id,
            Err(&reason),
        )?;
        self.store
            .mark_failed(&queued.worker_id, "integrity", &reason)?;
        let _ = self
            .refresh_worker_surface_evidence(&queued.worker_id)
            .await;
        self.cancel_worker(&queued.worker_id);
        self.unregister_dynamic_tool(&queued.worker_id).await;
        self.stop_residents(Some(&queued.worker_id)).await;
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
        self.publish_invocation_event(
            &completed,
            json!({
                "action":completed.status,
                "invocationId":completed.invocation_id,
                "workerId":completed.worker_id,
                "error":completed.error,
                "causalDepth":completed.causal_depth,
            }),
        )
        .await;
        Ok(completed)
    }

    pub(super) async fn execute_worker(
        self: &Arc<Self>,
        worker: &ActiveWorker,
        invocation: &InvocationRecord,
    ) -> Result<Value, WorkerExecutionError> {
        let secrets = self.load_secrets(&worker.bundle)?;
        match &worker.bundle.runner {
            WorkerRunner::Agent {
                instructions,
                model,
                reasoning_level,
            } => {
                self.execute_agent(
                    worker,
                    invocation,
                    instructions,
                    invocation.effective_model.as_deref().or(model.as_deref()),
                    invocation
                        .effective_reasoning_level
                        .as_deref()
                        .or(reasoning_level.as_deref()),
                    &secrets,
                )
                .await
            }
            WorkerRunner::Command { command } => {
                let state_dir = self.store.state_dir(&worker.summary.worker_id)?;
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
                    Some(&state_dir),
                    Some(&invocation.input),
                    &secrets,
                    Some(invocation),
                )
                .await
                .map_err(WorkerExecutionError::from)
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
                result.map_err(WorkerExecutionError::from)
            }
        }
    }

    pub(super) fn materialize_runtime_artifact(
        &self,
        worker: &ActiveWorker,
        category: &str,
        identity: &str,
    ) -> Result<(PathBuf, PathBuf), String> {
        let runtime_root = self
            .store
            .home()
            .join(crate::shared::foundation::paths::dirs::INTERNAL)
            .join(crate::shared::foundation::paths::dirs::RUN)
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

    pub(super) async fn execute_agent(
        &self,
        worker: &ActiveWorker,
        invocation: &InvocationRecord,
        instructions: &str,
        model: Option<&str>,
        reasoning_level: Option<&str>,
        secrets: &HashMap<String, String>,
    ) -> Result<Value, WorkerExecutionError> {
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
            .settings_runtime
            .current()
            .settings
            .server
            .default_model
            .clone();
        let state_dir = self.store.state_dir(&worker.summary.worker_id)?;
        let output_schema = serde_json::to_string_pretty(&worker.bundle.output_schema)
            .map_err(|error| format!("encode agent worker output schema: {error}"))?;
        let prompt = format!(
            "You are executing persistent worker '{}'. Follow its durable contract exactly.\n\n{}\n\nInvocation metadata (preserve the idempotency key when deduplicating side effects):\n{}\n\nInput JSON:\n{}\n\nOutput JSON Schema:\n{}\n\nThe kernel rejects a terminal result that does not match this exact schema. Return only one JSON value matching it; do not wrap the value in prose or Markdown.\n\nDurable worker-owned state is at {}. This path survives worker updates, rollback, disable, retirement, and server restart. Named secrets, when configured, are available as files under {}. Never reveal their values or copy them into worker state.",
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
            output_schema,
            state_dir.display(),
            secret_dir.display(),
        );
        let effective_model = model.unwrap_or(&default_model).to_owned();
        let profile = &self.settings_runtime.current().settings.agent.coordination;
        let max_seconds = worker
            .bundle
            .execution_limits
            .max_invocation_seconds
            .unwrap_or(MAX_INVOCATION_SECONDS);
        let max_turns = worker.bundle.execution_limits.max_agent_turns.unwrap_or(32);
        let max_children = worker
            .bundle
            .execution_limits
            .max_child_invocations
            .unwrap_or(profile.max_execution_nodes)
            .min(profile.max_execution_nodes);
        let limits = json!({
            "maxAssignmentSeconds":max_seconds,
            "maxAssignmentTurns":max_turns,
            "maxChildExecutions":max_children,
            "maxQueuedAssignments":1,
        });
        let tools = match worker.bundle.agent_tools.as_ref() {
            Some(tools) => tools.clone(),
            None => self.delegable_tool_names().await?,
        };
        if let Some(origin_session_id) = invocation.origin_session_id.as_deref() {
            self.ensure_agent_identity_for_session(origin_session_id)
                .await
                .map_err(WorkerExecutionError::from)?;
        }
        let admission = self
            .store
            .admit_direct_worker_agent(&NewDirectWorkerAgentAdmission {
                invocation_id: invocation.invocation_id.clone(),
                workspace_path: workdir.display().to_string(),
                max_active_children: profile.max_active_children,
                name: format!("Worker: {}", worker.summary.name),
                task: prompt,
                context: json!({
                    "workerInvocationId":invocation.invocation_id,
                    "workerId":worker.summary.worker_id,
                    "workerVersion":worker.summary.active_version,
                    "roleResult":{
                        "mode":"schema",
                        "schema":worker.bundle.output_schema,
                    },
                }),
                model: effective_model,
                reasoning_level: reasoning_level.map(ToOwned::to_owned),
                tool_grant: json!(tools),
                limits,
                deadline_at: chrono::Duration::try_seconds(
                    i64::try_from(max_seconds).unwrap_or(i64::MAX),
                )
                .map(|duration| (chrono::Utc::now() + duration).to_rfc3339()),
            })?;
        // The agent run is spawned asynchronously by the delivery-wake path.
        // Couple its process-local lifetime to this claimed worker future so
        // timeout, disablement, stop-all, panic, or task abort cannot leave
        // provider/tool work running after the worker terminalizes.
        let agent_session_id = admission.agent.session_id.clone();
        let mut abort_agent_run =
            AbortAgentRunOnDrop::new(Arc::clone(&self.orchestrator), agent_session_id.clone());
        self.import_agent_coordination_outbox()
            .await
            .map_err(WorkerExecutionError::isolated_agent_failure)?;
        let assignment_id = admission.assignment.assignment_id;
        loop {
            let assignment = self
                .store
                .agent_assignment(&assignment_id)?
                .ok_or_else(|| "direct worker assignment disappeared".to_owned())?;
            if assignment.status.is_terminal() {
                let terminal = match assignment.status {
                    AgentAssignmentStatus::Completed => assignment
                        .result_id
                        .as_deref()
                        .ok_or_else(|| {
                            WorkerExecutionError::isolated_agent_failure(
                                "direct worker completed without result custody",
                            )
                        })
                        .and_then(|result_id| {
                            self.store
                                .resolve_agent_result(result_id)
                                .map_err(WorkerExecutionError::from)?
                                .ok_or_else(|| {
                                    WorkerExecutionError::isolated_agent_failure(
                                        "direct worker result custody disappeared",
                                    )
                                })
                        }),
                    _ => Err(WorkerExecutionError::isolated_agent_failure(
                        assignment.error.unwrap_or_else(|| {
                            format!(
                                "direct worker assignment ended {}",
                                assignment.status.as_str()
                            )
                        }),
                    )),
                };
                // Completion normally means the provider run already ended;
                // cancellation/failure may win the durable race first. Abort
                // idempotently in both cases before disarming the drop guard.
                let _ = self.orchestrator.abort(&agent_session_id);
                abort_agent_run.disarm();
                return terminal;
            }
            if self
                .agent_assignment_inflight
                .insert(assignment.assignment_id.clone())
            {
                let driven = self.drive_agent_assignment(assignment).await;
                self.agent_assignment_inflight.remove(&assignment_id);
                driven.map_err(WorkerExecutionError::isolated_agent_failure)?;
                tokio::time::sleep(Duration::from_millis(100)).await;
            } else {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

pub(super) fn execution_failure_disables_worker(trigger_kind: &str) -> bool {
    !matches!(
        trigger_kind,
        "engine_hook:continuity_context"
            | "engine_hook:inbox_context"
            | "engine_hook:mailbox_curation"
            | "engine_hook:session_organization"
            | "engine_hook:session_title"
            | "engine_hook:worker_relevance"
    )
}

#[cfg(test)]
mod failure_policy_tests {
    use super::execution_failure_disables_worker;

    #[test]
    fn optional_semantic_hook_failure_is_isolated_to_its_invocation() {
        for hook in [
            "continuity_context",
            "inbox_context",
            "mailbox_curation",
            "session_organization",
            "session_title",
            "worker_relevance",
        ] {
            assert!(
                !execution_failure_disables_worker(&format!("engine_hook:{hook}")),
                "{hook} is optional semantic work and must not globally disable its owner"
            );
        }
        assert!(execution_failure_disables_worker(
            "engine_hook:context_summary"
        ));
        assert!(execution_failure_disables_worker("manual"));
    }
}
