//! Worker-owned semantic engine hooks.
//!
//! A hook is immutable bundle metadata activated by the normal atomic worker
//! publication path. This module performs deterministic newest-healthy owner
//! selection and invokes that worker through the ordinary durable dispatcher;
//! it is not a second plugin, binding, or authorization plane.

use super::*;

pub(crate) struct EngineHookExecution {
    pub(crate) worker_id: String,
    pub(crate) worker_version: String,
    pub(crate) output: Value,
}

impl WorkerRuntime {
    pub(super) fn engine_hook_inventory(&self) -> Result<Vec<Value>, String> {
        WorkerEngineHook::all()
            .iter()
            .filter_map(|hook| match self.active_engine_hook(*hook, None) {
                Ok(Some(worker)) => Some(Ok(json!({
                    "hook": hook.as_str(),
                    "workerId": worker.summary.worker_id,
                    "workerVersion": worker.summary.active_version,
                }))),
                Ok(None) => None,
                Err(error) => Some(Err(error)),
            })
            .collect()
    }

    pub(crate) async fn invoke_engine_hook(
        self: &Arc<Self>,
        hook: WorkerEngineHook,
        input: Value,
        origin_worker_id: Option<&str>,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let Some(execution) = self
            .execute_engine_hook(hook, input, origin_worker_id, invocation)
            .await?
        else {
            return Ok(json!({"handled":false}));
        };
        let narrative = execution
            .output
            .get("narrative")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(ToOwned::to_owned);
        let Some(narrative) = narrative else {
            let reason = self
                .handle_worker_runtime_failure(
                    &execution.worker_id,
                    &execution.worker_version,
                    "engine_hook",
                    &format!(
                        "engine hook '{}' returned no non-empty narrative",
                        hook.as_str()
                    ),
                )
                .await;
            return Err(reason);
        };
        Ok(json!({
            "handled":true,
            "workerId":execution.worker_id,
            "workerVersion":execution.worker_version,
            "narrative":narrative,
        }))
    }

    pub(crate) async fn execute_engine_hook(
        self: &Arc<Self>,
        hook: WorkerEngineHook,
        input: Value,
        origin_worker_id: Option<&str>,
        invocation: &Invocation,
    ) -> Result<Option<EngineHookExecution>, String> {
        let Some(worker) = self.active_engine_hook(hook, origin_worker_id)? else {
            return Ok(None);
        };
        let queued = self.enqueue_and_dispatch(InvokeRequest {
            worker_id: worker.summary.worker_id.clone(),
            input,
            idempotency_key: invocation
                .causal_context
                .idempotency_key
                .clone()
                .unwrap_or_else(|| format!("engine-hook:{}:{}", hook.as_str(), invocation.id)),
            trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
            causal_depth: invocation.causal_context.trigger_depth(),
            trigger_kind: format!("engine_hook:{}", hook.as_str()),
        })?;
        let (record, timed_out) = self
            .await_invocation(
                &queued.invocation_id,
                Duration::from_secs(MAX_INVOCATION_SECONDS),
            )
            .await?;
        if timed_out {
            return Err(format!(
                "engine hook '{}' exceeded the invocation ceiling",
                hook.as_str()
            ));
        }
        if record.status != "completed" {
            return Err(record
                .error
                .unwrap_or_else(|| format!("engine hook '{}' did not complete", hook.as_str())));
        }
        let output = record
            .output
            .ok_or_else(|| format!("engine hook '{}' returned no output", hook.as_str()))?;
        Ok(Some(EngineHookExecution {
            worker_id: worker.summary.worker_id,
            worker_version: worker.summary.active_version,
            output,
        }))
    }

    pub(crate) async fn reject_engine_hook_output(
        &self,
        execution: &EngineHookExecution,
        hook: WorkerEngineHook,
        error: &str,
    ) -> String {
        self.handle_worker_runtime_failure(
            &execution.worker_id,
            &execution.worker_version,
            "engine_hook",
            &format!("engine hook '{}' output is invalid: {error}", hook.as_str()),
        )
        .await
    }

    fn active_engine_hook(
        &self,
        hook: WorkerEngineHook,
        excluded_worker_id: Option<&str>,
    ) -> Result<Option<ActiveWorker>, String> {
        for summary in self.store.list(true)? {
            let worker = self.store.load_indexed_active(&summary.worker_id)?;
            if worker.bundle.engine_hooks.contains(&hook) {
                return Ok((summary.enabled
                    && !summary.retired
                    && summary.health == "healthy"
                    && excluded_worker_id != Some(summary.worker_id.as_str()))
                .then_some(worker));
            }
        }
        Ok(None)
    }
}
