//! Invocation admission, schema validation, idempotency, and durable enqueue.

use super::*;

const INTERACTION_BUDGET: Duration = Duration::from_secs(10);
const LATENCY_SAMPLE_MINIMUM: usize = 5;
const LATENCY_HISTORY_LIMIT: u32 = 20;

pub(in crate::domains::worker_kernel) enum ModelToolInvocationOutcome {
    Terminal(InvocationRecord),
    Background(InvocationRecord),
}

#[derive(Clone, Debug)]
struct InvocationAdmission<'a> {
    interaction_mode: WorkerInteractionMode,
    model_tool_invocation_id: Option<&'a str>,
    parent_worker_invocation_id: Option<&'a str>,
    parent_agent_execution_id: Option<&'a str>,
    parent_worker_tool_ordinal: Option<u32>,
    retry_of_invocation_id: Option<&'a str>,
    worker_version: Option<&'a str>,
    pinned_effective_model: Option<&'a str>,
    pinned_effective_reasoning_level: Option<&'a str>,
}

impl Default for InvocationAdmission<'_> {
    fn default() -> Self {
        Self {
            interaction_mode: WorkerInteractionMode::Foreground,
            model_tool_invocation_id: None,
            parent_worker_invocation_id: None,
            parent_agent_execution_id: None,
            parent_worker_tool_ordinal: None,
            retry_of_invocation_id: None,
            worker_version: None,
            pinned_effective_model: None,
            pinned_effective_reasoning_level: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum InteractionPlan {
    Background,
    ForegroundGrace,
}

/// Distinguishes invalid typed worker input from a failure to load the
/// canonical worker contract. Transports can therefore report caller mistakes
/// without disguising storage or integrity failures as invalid requests.
#[derive(Debug)]
pub(crate) enum WorkerInputContractError {
    Invalid(String),
    Internal(String),
}

impl std::fmt::Display for WorkerInputContractError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invalid(message) | Self::Internal(message) => formatter.write_str(message),
        }
    }
}

impl WorkerRuntime {
    /// Validate the selected dynamic worker's own input contract before
    /// durable admission. `worker_kernel::invoke` has a fixed outer schema;
    /// this is the nested typed boundary chosen by `workerId`.
    pub(crate) fn validate_active_input_contract(
        &self,
        worker_id: &str,
        input: &Value,
    ) -> Result<(), WorkerInputContractError> {
        let worker = self
            .store
            .load_indexed_active(worker_id)
            .map_err(WorkerInputContractError::Internal)?;
        self.validate_input_contract(&worker, input)
    }

    fn validate_input_contract(
        &self,
        worker: &ActiveWorker,
        input: &Value,
    ) -> Result<(), WorkerInputContractError> {
        let worker_function = FunctionId::new(format!(
            "worker_kernel::dynamic_{}",
            worker.summary.worker_id
        ))
        .map_err(|error| WorkerInputContractError::Internal(error.to_string()))?;
        crate::engine::validate_engine_schema_payload(
            &worker_function,
            "request",
            &worker.bundle.input_schema,
            input,
        )
        .map_err(|error| {
            WorkerInputContractError::Invalid(format!(
                "worker input does not match its schema: {error}"
            ))
        })?;
        self.reject_secret_material_in_value(input, "worker input")
            .map_err(WorkerInputContractError::Invalid)
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

    /// Provider-facing fixed `worker_invoke(mode=wait)` execution.
    ///
    /// Top-level calls share the direct-tool interaction budget and return the
    /// existing invocation record envelope. A nested wait synchronously joins
    /// its typed child up to the worker reliability ceiling. `mode=enqueue`
    /// uses the separate admission path and returns a durable background child
    /// for both root and nested callers; reusable parent assignments join that
    /// child structurally.
    pub(crate) async fn invoke_from_provider_tool(
        self: &Arc<Self>,
        request: InvokeRequest,
        model_tool_invocation_id: Option<&str>,
        parent_worker_invocation_id: Option<&str>,
        parent_agent_execution_id: Option<&str>,
        parent_worker_tool_ordinal: Option<u32>,
    ) -> Result<InvocationRecord, String> {
        self.invoke_from_provider_tool_with_admission(
            request,
            model_tool_invocation_id,
            parent_worker_invocation_id,
            parent_agent_execution_id,
            parent_worker_tool_ordinal,
            None,
            None,
            None,
            None,
        )
        .await
    }

    /// Retry one terminal invocation with its immutable version and typed
    /// input. Only causal/idempotency identity comes from the new caller.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn retry_from_provider_tool(
        self: &Arc<Self>,
        retry_of_invocation_id: &str,
        idempotency_key: String,
        trace_id: String,
        causal_depth: u32,
        origin_session_id: Option<String>,
        model_tool_invocation_id: Option<&str>,
        parent_worker_invocation_id: Option<&str>,
        parent_agent_execution_id: Option<&str>,
        parent_worker_tool_ordinal: Option<u32>,
    ) -> Result<InvocationRecord, String> {
        let original = self
            .store
            .invocation(retry_of_invocation_id)?
            .ok_or_else(|| format!("worker invocation '{retry_of_invocation_id}' was not found"))?;
        if !matches!(
            original.status.as_str(),
            "completed" | "failed" | "cancelled"
        ) {
            return Err(format!(
                "worker invocation '{retry_of_invocation_id}' is not terminal"
            ));
        }
        self.invoke_from_provider_tool_with_admission(
            InvokeRequest {
                worker_id: original.worker_id.clone(),
                input: original.input.clone(),
                model: original.requested_model.clone(),
                reasoning_level: original.requested_reasoning_level.clone(),
                idempotency_key,
                trace_id,
                causal_depth,
                trigger_kind: "manual_retry".to_owned(),
                origin_session_id,
            },
            model_tool_invocation_id,
            parent_worker_invocation_id,
            parent_agent_execution_id,
            parent_worker_tool_ordinal,
            Some(&original.worker_version),
            Some(retry_of_invocation_id),
            original.effective_model.as_deref(),
            original.effective_reasoning_level.as_deref(),
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn retry_enqueue_from_provider_tool(
        self: &Arc<Self>,
        retry_of_invocation_id: &str,
        idempotency_key: String,
        trace_id: String,
        causal_depth: u32,
        origin_session_id: Option<String>,
        model_tool_invocation_id: Option<&str>,
        parent_worker_invocation_id: Option<&str>,
        parent_agent_execution_id: Option<&str>,
        parent_worker_tool_ordinal: Option<u32>,
    ) -> Result<InvocationRecord, String> {
        let original = self
            .store
            .invocation(retry_of_invocation_id)?
            .ok_or_else(|| format!("worker invocation '{retry_of_invocation_id}' was not found"))?;
        if !matches!(
            original.status.as_str(),
            "completed" | "failed" | "cancelled"
        ) {
            return Err(format!(
                "worker invocation '{retry_of_invocation_id}' is not terminal"
            ));
        }
        let request = InvokeRequest {
            worker_id: original.worker_id.clone(),
            input: original.input.clone(),
            model: original.requested_model.clone(),
            reasoning_level: original.requested_reasoning_level.clone(),
            idempotency_key,
            trace_id,
            causal_depth,
            trigger_kind: "manual_retry".to_owned(),
            origin_session_id,
        };
        let (queued, replayed) = self.enqueue_request_with_admission(
            request,
            InvocationAdmission {
                interaction_mode: WorkerInteractionMode::Background,
                model_tool_invocation_id,
                parent_worker_invocation_id,
                parent_agent_execution_id,
                parent_worker_tool_ordinal,
                retry_of_invocation_id: Some(retry_of_invocation_id),
                worker_version: Some(&original.worker_version),
                pinned_effective_model: original.effective_model.as_deref(),
                pinned_effective_reasoning_level: original.effective_reasoning_level.as_deref(),
            },
        )?;
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

    async fn invoke_from_provider_tool_with_admission(
        self: &Arc<Self>,
        request: InvokeRequest,
        model_tool_invocation_id: Option<&str>,
        parent_worker_invocation_id: Option<&str>,
        parent_agent_execution_id: Option<&str>,
        parent_worker_tool_ordinal: Option<u32>,
        worker_version: Option<&str>,
        retry_of_invocation_id: Option<&str>,
        pinned_effective_model: Option<&str>,
        pinned_effective_reasoning_level: Option<&str>,
    ) -> Result<InvocationRecord, String> {
        if parent_worker_invocation_id.is_some() {
            let (queued, _) = self.enqueue_request_with_admission(
                request,
                InvocationAdmission {
                    model_tool_invocation_id,
                    parent_worker_invocation_id,
                    parent_agent_execution_id,
                    parent_worker_tool_ordinal,
                    retry_of_invocation_id,
                    worker_version,
                    pinned_effective_model,
                    pinned_effective_reasoning_level,
                    ..Default::default()
                },
            )?;
            return self.finish_nested_invocation(queued).await;
        }

        let plan = self.interaction_plan_for_version(&request.worker_id, worker_version)?;
        let interaction_mode = match plan {
            InteractionPlan::Background => WorkerInteractionMode::Background,
            InteractionPlan::ForegroundGrace => WorkerInteractionMode::Foreground,
        };
        let (queued, replayed) = self.enqueue_request_with_admission(
            request,
            InvocationAdmission {
                interaction_mode,
                model_tool_invocation_id,
                parent_agent_execution_id,
                retry_of_invocation_id,
                worker_version,
                pinned_effective_model,
                pinned_effective_reasoning_level,
                ..Default::default()
            },
        )?;
        if replayed && queued.status != "queued" {
            return Ok(queued);
        }
        let invocation_id = queued.invocation_id.clone();
        let runtime = Arc::clone(self);
        let mut delivery = tokio::spawn(async move { runtime.execute_queued(queued).await });
        if matches!(plan, InteractionPlan::Background) {
            return self
                .store
                .invocation(&invocation_id)?
                .ok_or_else(|| format!("worker invocation '{invocation_id}' disappeared"));
        }
        tokio::select! {
            result = &mut delivery => result
                .map_err(|error| format!("worker delivery task failed: {error}"))?,
            () = tokio::time::sleep(INTERACTION_BUDGET) => {
                self.detach_invocation(&invocation_id).await
            }
        }
    }

    /// Invoke a worker on behalf of one live provider/model tool call.
    ///
    /// Durable admission and execution are identical to [`Self::invoke`].
    /// The additional target is a transient presentation bridge only: it lets
    /// the runtime stream exact progress back to the awaiting conversation
    /// chip without putting client state into the durable worker schema.
    pub(super) async fn invoke_from_model_tool(
        self: &Arc<Self>,
        request: InvokeRequest,
        target: ModelToolProgressTarget,
        parent_worker_invocation_id: Option<&str>,
        parent_agent_execution_id: Option<&str>,
        parent_worker_tool_ordinal: Option<u32>,
    ) -> Result<InvocationRecord, String> {
        let (queued, _) = self.enqueue_request_with_admission(
            request,
            InvocationAdmission {
                model_tool_invocation_id: Some(&target.invocation_id),
                parent_worker_invocation_id,
                parent_agent_execution_id,
                parent_worker_tool_ordinal,
                ..Default::default()
            },
        )?;
        let invocation_id = queued.invocation_id.clone();
        self.model_tool_progress
            .insert(invocation_id.clone(), target);
        let _progress_bridge = RemoveModelToolProgressOnDrop {
            runtime: Arc::clone(self),
            worker_invocation_id: invocation_id.clone(),
        };
        self.emit_model_tool_progress(&invocation_id, "Queued for worker execution", Some(0.02));
        self.finish_nested_invocation(queued).await
    }

    /// Deliver or observe one nested invocation until its typed terminal state.
    ///
    /// A parent retry may reach a child that is already completed, running
    /// under restart recovery, or queued for the dispatcher. All three states
    /// retain the original durable child identity; nested callers never create
    /// a replacement merely because their provider session was reconstructed.
    async fn finish_nested_invocation(
        self: &Arc<Self>,
        queued: InvocationRecord,
    ) -> Result<InvocationRecord, String> {
        let invocation_id = queued.invocation_id.clone();
        let observed = match queued.status.as_str() {
            "completed" | "failed" | "cancelled" => queued,
            "queued" => self.execute_queued(queued).await?,
            _ => queued,
        };
        if matches!(
            observed.status.as_str(),
            "completed" | "failed" | "cancelled"
        ) {
            return Ok(observed);
        }
        let (terminal, timed_out) = self
            .await_invocation(&invocation_id, Duration::from_secs(MAX_INVOCATION_SECONDS))
            .await?;
        if timed_out {
            return Err(format!(
                "nested worker invocation '{invocation_id}' did not reach a terminal result within its reliability ceiling"
            ));
        }
        Ok(terminal)
    }

    /// Admit a top-level direct worker using the generic interaction budget.
    ///
    /// Agent runners are predicted slow from their execution class and begin
    /// detached. Command/service versions use exact-version completed p95 once
    /// five samples exist; unknown or predicted-fast work gets the bounded
    /// foreground grace. Detachment never cancels or recreates the invocation.
    pub(super) async fn invoke_from_model_tool_adaptive(
        self: &Arc<Self>,
        request: InvokeRequest,
        target: ModelToolProgressTarget,
        parent_agent_execution_id: Option<&str>,
    ) -> Result<ModelToolInvocationOutcome, String> {
        self.invoke_from_model_tool_with_budget(
            request,
            target,
            parent_agent_execution_id,
            INTERACTION_BUDGET,
            false,
        )
        .await
    }

    #[cfg(test)]
    pub(super) async fn invoke_from_model_tool_with_grace(
        self: &Arc<Self>,
        request: InvokeRequest,
        target: ModelToolProgressTarget,
        foreground_grace: Duration,
    ) -> Result<ModelToolInvocationOutcome, String> {
        self.invoke_from_model_tool_with_budget(request, target, None, foreground_grace, true)
            .await
    }

    async fn invoke_from_model_tool_with_budget(
        self: &Arc<Self>,
        request: InvokeRequest,
        target: ModelToolProgressTarget,
        parent_agent_execution_id: Option<&str>,
        interaction_budget: Duration,
        force_foreground_grace: bool,
    ) -> Result<ModelToolInvocationOutcome, String> {
        let plan = if force_foreground_grace {
            InteractionPlan::ForegroundGrace
        } else {
            self.interaction_plan(&request.worker_id)?
        };
        let mode = match plan {
            InteractionPlan::Background => WorkerInteractionMode::Background,
            InteractionPlan::ForegroundGrace => WorkerInteractionMode::Foreground,
        };
        let (queued, replayed) = self.enqueue_request_with_admission(
            request,
            InvocationAdmission {
                interaction_mode: mode,
                model_tool_invocation_id: Some(&target.invocation_id),
                parent_agent_execution_id,
                ..Default::default()
            },
        )?;
        if replayed && queued.status != "queued" {
            return if queued.interaction_mode == WorkerInteractionMode::Background
                && !matches!(queued.status.as_str(), "completed" | "failed" | "cancelled")
            {
                Ok(ModelToolInvocationOutcome::Background(queued))
            } else {
                Ok(ModelToolInvocationOutcome::Terminal(queued))
            };
        }
        let invocation_id = queued.invocation_id.clone();
        self.model_tool_progress
            .insert(invocation_id.clone(), target);
        self.emit_model_tool_progress(&invocation_id, "Queued for worker execution", Some(0.02));

        let runtime = Arc::clone(self);
        let delivery_id = invocation_id.clone();
        let mut delivery = tokio::spawn(async move {
            let _progress_bridge = RemoveModelToolProgressOnDrop {
                runtime: Arc::clone(&runtime),
                worker_invocation_id: delivery_id,
            };
            runtime.execute_queued(queued).await
        });

        if matches!(plan, InteractionPlan::Background) {
            self.emit_model_tool_progress(&invocation_id, "Continuing in the background", None);
            let record = self
                .store
                .invocation(&invocation_id)?
                .ok_or_else(|| format!("worker invocation '{invocation_id}' disappeared"))?;
            return if matches!(record.status.as_str(), "completed" | "failed" | "cancelled") {
                Ok(ModelToolInvocationOutcome::Terminal(record))
            } else {
                Ok(ModelToolInvocationOutcome::Background(record))
            };
        }

        tokio::select! {
            result = &mut delivery => {
                let record = result
                    .map_err(|error| format!("worker delivery task failed: {error}"))??;
                Ok(ModelToolInvocationOutcome::Terminal(record))
            }
            () = tokio::time::sleep(interaction_budget) => {
                self.emit_model_tool_progress(
                    &invocation_id,
                    "Continuing in the background",
                    None,
                );
                self.emit_model_tool_output(
                    &invocation_id,
                    "Foreground wait ended; the durable worker run is continuing",
                );
                let record = self.detach_invocation(&invocation_id).await?;
                if matches!(record.status.as_str(), "completed" | "failed" | "cancelled") {
                    Ok(ModelToolInvocationOutcome::Terminal(record))
                } else {
                    Ok(ModelToolInvocationOutcome::Background(record))
                }
            }
        }
    }

    pub fn enqueue(&self, request: InvokeRequest) -> Result<InvocationRecord, String> {
        self.enqueue_request_with_admission(
            request,
            InvocationAdmission {
                interaction_mode: WorkerInteractionMode::Background,
                ..Default::default()
            },
        )
        .map(|(record, _)| record)
    }

    /// Persist an invocation and start an immediate best-effort delivery task.
    /// The durable dispatcher remains authoritative recovery if this task is
    /// cancelled by shutdown before producing a terminal record.
    pub fn enqueue_and_dispatch(
        self: &Arc<Self>,
        request: InvokeRequest,
    ) -> Result<InvocationRecord, String> {
        let (queued, replayed) = self.enqueue_request_with_admission(
            request,
            InvocationAdmission {
                interaction_mode: WorkerInteractionMode::Background,
                ..Default::default()
            },
        )?;
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

    pub(crate) fn enqueue_from_provider_tool(
        self: &Arc<Self>,
        request: InvokeRequest,
        model_tool_invocation_id: Option<&str>,
        parent_worker_invocation_id: Option<&str>,
        parent_agent_execution_id: Option<&str>,
        parent_worker_tool_ordinal: Option<u32>,
    ) -> Result<InvocationRecord, String> {
        let (queued, replayed) = self.enqueue_request_with_admission(
            request,
            InvocationAdmission {
                interaction_mode: WorkerInteractionMode::Background,
                model_tool_invocation_id,
                parent_worker_invocation_id,
                parent_agent_execution_id,
                parent_worker_tool_ordinal,
                ..Default::default()
            },
        )?;
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
            if matches!(record.status.as_str(), "completed" | "failed" | "cancelled") {
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
        self.enqueue_request_with_admission(request, InvocationAdmission::default())
    }

    fn enqueue_request_with_admission(
        &self,
        request: InvokeRequest,
        admission: InvocationAdmission<'_>,
    ) -> Result<(InvocationRecord, bool), String> {
        if self.stopped.load(Ordering::SeqCst) || self.store.stop_all()? {
            return Err("worker dispatch is stopped for this engine".to_owned());
        }
        if request.causal_depth > MAX_CAUSAL_DEPTH {
            return Err(format!(
                "worker causal depth {} exceeds the engine limit {MAX_CAUSAL_DEPTH}",
                request.causal_depth
            ));
        }
        let worker = admission.worker_version.map_or_else(
            || self.store.load_indexed_active(&request.worker_id),
            |version| self.store.load_version(&request.worker_id, version),
        )?;
        if !worker.summary.enabled || worker.summary.retired {
            return Err(format!("worker '{}' is not enabled", request.worker_id));
        }
        self.validate_input_contract(&worker, &request.input)
            .map_err(|error| error.to_string())?;
        let requested_model = request
            .model
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty());
        let requested_reasoning_level = request
            .reasoning_level
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty());
        if request.model.is_some() && requested_model.is_none() {
            return Err("model override must be a non-empty string".to_owned());
        }
        if request.reasoning_level.is_some() && requested_reasoning_level.is_none() {
            return Err("reasoningLevel override must be a non-empty string".to_owned());
        }
        let (effective_model, effective_reasoning_level) = match &worker.bundle.runner {
            WorkerRunner::Agent {
                model,
                reasoning_level,
                ..
            } => {
                let default_model = self
                    .settings_runtime
                    .current()
                    .settings
                    .server
                    .default_model
                    .clone();
                let effective_model = admission
                    .pinned_effective_model
                    .or(requested_model)
                    .or(model.as_deref())
                    .unwrap_or(default_model.as_str());
                let effective_reasoning_level = admission
                    .pinned_effective_reasoning_level
                    .or(requested_reasoning_level)
                    .or(reasoning_level.as_deref());
                let auth_path =
                    crate::shared::foundation::paths::auth_path_for_home(self.store.home());
                // INVARIANT: every durable agent-worker invocation validates
                // the exact effective pair, regardless of whether it came
                // from an override, immutable bundle, retry pin, or fallback.
                crate::domains::model::routing::catalog::validate_explicit_model(
                    effective_model,
                    &auth_path,
                )?;
                if let Some(effective_reasoning_level) = effective_reasoning_level {
                    crate::domains::model::routing::catalog::validate_explicit_reasoning_level(
                        effective_model,
                        effective_reasoning_level,
                        &auth_path,
                    )?;
                }
                (
                    Some(effective_model.to_owned()),
                    effective_reasoning_level.map(ToOwned::to_owned),
                )
            }
            WorkerRunner::Command { .. } | WorkerRunner::Service { .. } => {
                if requested_model.is_some() || requested_reasoning_level.is_some() {
                    return Err(format!(
                        "worker '{}' does not use an agent runner and cannot accept model overrides",
                        request.worker_id
                    ));
                }
                (None, None)
            }
        };
        let max_sibling_invocations =
            if let Some(parent_id) = admission.parent_worker_invocation_id {
                let parent = self.store.invocation(parent_id)?.ok_or_else(|| {
                    format!("parent worker invocation '{parent_id}' was not found")
                })?;
                self.store
                    .load_version(&parent.worker_id, &parent.worker_version)?
                    .bundle
                    .execution_limits
                    .max_child_invocations
            } else {
                None
            };
        let profile_execution_ceiling = self
            .settings_runtime
            .current()
            .settings
            .agent
            .coordination
            .max_execution_nodes;
        let max_child_executions =
            if let Some(parent_execution_id) = admission.parent_agent_execution_id {
                let parent = self
                    .store
                    .execution_node(parent_execution_id)?
                    .ok_or_else(|| {
                        format!("parent agent execution '{parent_execution_id}' was not found")
                    })?;
                let assignment_id = parent.assignment_id.as_deref().ok_or_else(|| {
                    format!("parent agent execution '{parent_execution_id}' has no assignment")
                })?;
                self.store
                    .agent_assignment(assignment_id)?
                    .and_then(|assignment| {
                        assignment
                            .limits_snapshot
                            .get("maxChildExecutions")
                            .and_then(Value::as_u64)
                    })
                    .and_then(|limit| u32::try_from(limit).ok())
                    .unwrap_or(profile_execution_ceiling)
                    .min(profile_execution_ceiling)
            } else {
                max_sibling_invocations
                    .unwrap_or(profile_execution_ceiling)
                    .min(profile_execution_ceiling)
            };
        let (queued, replayed) = self.store.begin_invocation_with_model_context(
            &request.worker_id,
            &worker.summary.active_version,
            &request.input,
            &request.idempotency_key,
            &request.trace_id,
            request.causal_depth,
            &request.trigger_kind,
            request.origin_session_id.as_deref(),
            admission.interaction_mode,
            admission.model_tool_invocation_id,
            admission.parent_worker_invocation_id,
            admission.parent_agent_execution_id,
            admission.parent_worker_tool_ordinal,
            admission.retry_of_invocation_id,
            requested_model,
            requested_reasoning_level,
            effective_model.as_deref(),
            effective_reasoning_level.as_deref(),
            max_sibling_invocations,
            max_child_executions,
            profile_execution_ceiling,
        )?;
        Ok((queued, replayed))
    }

    fn interaction_plan(&self, worker_id: &str) -> Result<InteractionPlan, String> {
        self.interaction_plan_for_version(worker_id, None)
    }

    fn interaction_plan_for_version(
        &self,
        worker_id: &str,
        worker_version: Option<&str>,
    ) -> Result<InteractionPlan, String> {
        let worker = worker_version.map_or_else(
            || self.store.load_indexed_active(worker_id),
            |version| self.store.load_version(worker_id, version),
        )?;
        let samples = self.store.completed_wall_durations(
            worker_id,
            &worker.summary.active_version,
            LATENCY_HISTORY_LIMIT,
        )?;
        Ok(interaction_plan_from_evidence(
            &worker.bundle.runner,
            samples,
            INTERACTION_BUDGET,
        ))
    }
}

pub(super) fn interaction_plan_from_evidence(
    runner: &WorkerRunner,
    mut samples: Vec<Duration>,
    interaction_budget: Duration,
) -> InteractionPlan {
    if matches!(runner, WorkerRunner::Agent { .. }) {
        return InteractionPlan::Background;
    }
    if samples.len() < LATENCY_SAMPLE_MINIMUM {
        return InteractionPlan::ForegroundGrace;
    }
    samples.sort_unstable();
    let nearest_rank = (samples.len() * 95).div_ceil(100).saturating_sub(1);
    if samples[nearest_rank] > interaction_budget {
        InteractionPlan::Background
    } else {
        InteractionPlan::ForegroundGrace
    }
}
