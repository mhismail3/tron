//! Worker lifecycle, engine stop state, and direct-tool publication.

use super::*;
use crate::engine::FunctionDefinition;

impl WorkerRuntime {
    pub async fn cancel_invocation(&self, invocation_id: &str) -> Result<InvocationRecord, String> {
        self.invocation_stop(invocation_id).cancel();
        let record = self.store.cancel_invocation(invocation_id)?;
        let _ = self.invocation_stops.remove(invocation_id);
        self.publish_event(
            "worker.invocations",
            json!({
                "action":"cancelled",
                "invocationId":record.invocation_id,
                "workerId":record.worker_id,
                "causalDepth":record.causal_depth,
            }),
            TraceId::new(record.trace_id.clone()).ok(),
        )
        .await;
        Ok(record)
    }

    pub async fn set_enabled(
        self: &Arc<Self>,
        worker_id: &str,
        enabled: bool,
    ) -> Result<Value, String> {
        let worker = self.store.set_enabled(worker_id, enabled)?;
        if enabled {
            self.reset_worker_stop(worker_id);
            if let Err(error) = self.register_dynamic_tool(worker_id).await {
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
        if let Err(error) = self.register_dynamic_tool(worker_id).await {
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

    pub async fn purge(self: &Arc<Self>, worker_id: &str) -> Result<PurgeOutcome, String> {
        self.cancel_worker(worker_id);
        self.stop_residents(Some(worker_id)).await;
        self.unregister_dynamic_tool(worker_id).await;
        let secrets = self
            .load_all_runtime_secrets()?
            .into_values()
            .collect::<Vec<_>>();
        let outcome = self.store.purge(worker_id, &secrets)?;
        if outcome.purged {
            self.publish_event(
                "worker.lifecycle",
                json!({"action":"purged","workerId":worker_id}),
                None,
            )
            .await;
        }
        Ok(outcome)
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

    pub(super) fn worker_stop(&self, worker_id: &str) -> CancellationToken {
        self.worker_stops
            .entry(worker_id.to_owned())
            .or_insert_with(CancellationToken::new)
            .clone()
    }

    pub(super) fn invocation_stop(&self, invocation_id: &str) -> CancellationToken {
        self.invocation_stops
            .entry(invocation_id.to_owned())
            .or_insert_with(CancellationToken::new)
            .clone()
    }

    pub(super) fn cancel_worker(&self, worker_id: &str) {
        self.worker_stop(worker_id).cancel();
    }

    pub(super) fn reset_worker_stop(&self, worker_id: &str) {
        let _ = self
            .worker_stops
            .insert(worker_id.to_owned(), CancellationToken::new());
    }

    pub(super) fn worker_cancelled_error(&self, worker_id: &str, queued: bool) -> String {
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

    pub(super) async fn register_active_tools(self: &Arc<Self>) -> Result<(), String> {
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

    pub(super) async fn register_dynamic_tool(
        self: &Arc<Self>,
        worker_id: &str,
    ) -> Result<(), String> {
        let active = self.store.load_active(worker_id)?;
        self.refresh_worker_surface_evidence(worker_id).await?;
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
            .collect::<Vec<_>>();
        let model_description = format!(
            "{}\nPersistent worker: activeVersion={}; provenance={}",
            active.summary.description,
            active.summary.active_version,
            provenance.join(", "),
        );
        let function_id = FunctionId::new(format!("worker_kernel::dynamic_{worker_id}"))
            .map_err(|error| error.to_string())?;
        let mut definition = FunctionDefinition::new(
            function_id,
            WorkerId::new("worker_kernel").map_err(|error| error.to_string())?,
            model_description,
            FunctionVisibility::Public,
            EffectClass::ExternalSideEffect,
        )
        .with_risk(RiskLevel::High)
        .with_idempotency(IdempotencyContract::session())
        .with_request_schema(active.bundle.input_schema.clone())
        .with_response_schema(active.bundle.output_schema.clone());
        definition.model_tool = Some(ModelToolContract {
            name: active.summary.tool_name,
            callable: true,
            order: None,
            group: None,
            worker: Some(DirectWorkerToolContract {
                worker_id: active.summary.worker_id,
                worker_name: active.summary.name,
                worker_version: active.summary.active_version,
                runner_kind: active.summary.runner_kind,
                updated_at: active.summary.updated_at,
                intents: active.bundle.routing.intents,
                examples: active.bundle.routing.examples,
                provenance,
            }),
        });
        self.host
            .register_function(
                definition,
                Arc::new(DynamicWorkerHandler {
                    runtime: Arc::clone(self),
                    worker_id: worker_id.to_owned(),
                }),
            )
            .await
            .map_err(|error| format!("register dynamic worker tool: {error}"))?;
        Ok(())
    }

    pub(super) async fn refresh_worker_surface_evidence(
        &self,
        worker_id: &str,
    ) -> Result<(), String> {
        let summary = self
            .store
            .summary(worker_id)?
            .ok_or_else(|| format!("worker '{worker_id}' was not found"))?;
        super::super::surface::publish_worker_surface_evidence(
            &self.host,
            worker_id,
            json!({
                "updatedAt": summary.updated_at,
                "successEvidence": self.store.success_evidence(worker_id)?,
            }),
        )
        .await
    }

    pub(super) async fn unregister_dynamic_tool(&self, worker_id: &str) {
        let Ok(function_id) = FunctionId::new(format!("worker_kernel::dynamic_{worker_id}")) else {
            return;
        };
        let Ok(owner) = WorkerId::new("worker_kernel") else {
            return;
        };
        let _ = self.host.unregister_function(&function_id, &owner).await;
    }
}
