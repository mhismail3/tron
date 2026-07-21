//! Worker lifecycle, engine stop state, autonomy transitions, and direct-tool
//! publication.

use super::*;

impl WorkerRuntime {
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

    pub(super) fn worker_stop(&self, worker_id: &str) -> CancellationToken {
        self.worker_stops
            .entry(worker_id.to_owned())
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

    pub(super) async fn apply_autonomy_state(
        self: &Arc<Self>,
        enabled: bool,
    ) -> Result<(), String> {
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

    pub(super) async fn sync_kernel_primitive_visibility(
        &self,
        enabled: bool,
    ) -> Result<(), String> {
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
                .register_function(next.clone(), Arc::clone(handler))
                .await
            {
                let mut rollback_failures = Vec::new();
                for (_, rollback, rollback_handler) in prepared.iter().take(updated).rev() {
                    if let Err(rollback_error) = self
                        .host
                        .register_function(rollback.clone(), Arc::clone(rollback_handler))
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

    pub(super) async fn unregister_all_dynamic_tools(&self) -> Result<(), String> {
        for worker in self.store.list(true)? {
            self.unregister_dynamic_tool(&worker.worker_id).await;
        }
        Ok(())
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
        if !self.autonomous_enabled() {
            self.unregister_dynamic_tool(worker_id).await;
            return Ok(());
        }
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
            .collect::<Vec<_>>()
            .join(", ");
        let model_description = format!(
            "{}\nPersistent worker: activeVersion={}; provenance={}",
            active.summary.description, active.summary.active_version, provenance,
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
        .with_response_schema(active.bundle.output_schema.clone())
        .with_health(FunctionHealth::Healthy);
        definition.metadata = json!({
            "modelPrimitive": true,
            "modelPrimitiveName": active.summary.tool_name,
            "workerId": active.summary.worker_id,
            "workerName": active.summary.name,
            "workerVersion": active.summary.active_version,
            "workerUpdatedAt": active.summary.updated_at,
            "workerDynamic": true,
            "workerRouting": active.bundle.routing,
            "workerProvenance": active.bundle.provenance,
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
        if !self.autonomous_enabled() {
            self.unregister_dynamic_tool(worker_id).await;
        }
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
                "health": summary.health,
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
