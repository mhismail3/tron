//! Invocation admission, schema validation, idempotency, and durable enqueue.

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
}
