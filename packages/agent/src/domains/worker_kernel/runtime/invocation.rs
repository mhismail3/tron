//! Durable invocation admission, concurrency, idempotency, and the agent,
//! command, and resident runner paths.

use super::*;

impl WorkerRuntime {
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

    /// Persist an invocation and start an immediate best-effort delivery task.
    /// The durable dispatcher remains authoritative recovery if this task is
    /// cancelled by shutdown before producing a terminal record.
    pub fn enqueue_and_dispatch(
        self: &Arc<Self>,
        request: InvokeRequest,
    ) -> Result<InvocationRecord, String> {
        let (queued, replayed) = self.enqueue_request(request)?;
        if queued.status == "queued" {
            let runtime = Arc::clone(self);
            let delivery = queued.clone();
            let task = tokio::spawn(async move {
                let _ = runtime.execute_queued(delivery).await;
            });
            drop(task);
        } else if !replayed {
            return Err(format!(
                "new worker invocation '{}' was not durably queued",
                queued.invocation_id
            ));
        }
        Ok(queued)
    }

    /// Observe one durable invocation until terminal state or a bounded wait
    /// expires. Timeout is observational: it never cancels durable work.
    pub async fn await_invocation(
        &self,
        invocation_id: &str,
        timeout: Duration,
    ) -> Result<(InvocationRecord, bool), String> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let record = self
                .store
                .invocation(invocation_id)?
                .ok_or_else(|| format!("worker invocation '{invocation_id}' was not found"))?;
            if matches!(record.status.as_str(), "completed" | "failed") {
                return Ok((record, false));
            }
            let now = tokio::time::Instant::now();
            if now >= deadline {
                return Ok((record, true));
            }
            tokio::time::sleep((deadline - now).min(Duration::from_millis(50))).await;
        }
    }

    pub(super) fn enqueue_request(
        &self,
        request: InvokeRequest,
    ) -> Result<(InvocationRecord, bool), String> {
        if !self.autonomous_enabled() {
            return Err(
                "autonomous workers are disabled for this engine; set autonomousWorkers=true"
                    .to_owned(),
            );
        }
        if self.stopped.load(Ordering::SeqCst) || self.store.stop_all()? {
            return Err("worker dispatch is stopped for this engine".to_owned());
        }
        if request.causal_depth > MAX_CAUSAL_DEPTH {
            return Err(format!(
                "worker causal depth {} exceeds the engine limit {MAX_CAUSAL_DEPTH}",
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
        let result = self.execute_queued_inner(queued).await;
        let _ = self.inflight.remove(&invocation_id);
        result
    }

    pub(super) async fn execute_queued_inner(
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
        let engine_permit = self.engine_limit.clone().acquire_owned();
        let engine_permit = tokio::select! {
            permit = engine_permit => permit,
            () = global_stop.cancelled() => return Err("worker dispatch stopped while queued".to_owned()),
            () = worker_stop.cancelled() => return Err(self.worker_cancelled_error(&queued.worker_id, true)),
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
        }
            .map_err(|_| "worker concurrency gate is closed".to_owned())?;
        let _permits = (engine_permit, worker_permit);
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
            () = global_stop.cancelled() => Err("worker invocation stopped by engine stop-all".to_owned()),
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
        let secrets = self.load_all_vault_secrets().unwrap_or_default();
        let reason = redact_known_secrets(
            &format!("worker immutable-version integrity check failed: {error}"),
            &secrets,
        );
        self.store
            .mark_failed(&queued.worker_id, "integrity", &reason)?;
        let _ = self
            .refresh_worker_surface_evidence(&queued.worker_id)
            .await;
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

    pub(super) async fn execute_worker(
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
            .settings_runtime
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
        // Subscribe before prompt admission. A provider construction failure can
        // start and finish between the synchronous acknowledgement and the next
        // scheduler poll; the terminal broadcast is the lossless join point.
        let mut agent_events = self.orchestrator.subscribe();
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
        let terminal_error =
            wait_for_agent_terminal(&self.orchestrator, &mut agent_events, &session_id).await?;
        agent_run_guard.disarm();
        if let Some(error) = terminal_error {
            return Err(format!("agent worker failed: {error}"));
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

    pub(super) async fn ensure_resident(
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
}
