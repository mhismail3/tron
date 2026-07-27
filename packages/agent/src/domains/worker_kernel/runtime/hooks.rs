//! Worker-owned semantic engine hooks.
//!
//! A hook is immutable bundle metadata activated by the normal atomic worker
//! publication path. This module performs deterministic newest-healthy owner
//! selection and invokes that worker through the ordinary durable dispatcher;
//! it is not a second plugin, binding, or authorization plane.

use super::*;

const MAX_ENGINE_HOOK_SECONDS: u64 = 60;
const ENGINE_HOOK_CACHE_WINDOW_SECONDS: i64 = 30;

pub(crate) struct EngineHookExecution {
    pub(crate) invocation_id: String,
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
        if hook == WorkerEngineHook::ContextSummary
            && let Err(validation_error) =
                super::super::validate_context_summary_narrative(&narrative)
        {
            let reason = self
                .handle_worker_runtime_failure(
                    &execution.worker_id,
                    &execution.worker_version,
                    "engine_hook",
                    &format!(
                        "engine hook '{}' returned an invalid narrative: {validation_error}",
                        hook.as_str(),
                    ),
                )
                .await;
            return Err(reason);
        }
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
        let Some((worker, queued)) =
            self.enqueue_engine_hook(hook, input, origin_worker_id, invocation)?
        else {
            return Ok(None);
        };
        let (record, timed_out) = self
            .await_invocation(
                &queued.invocation_id,
                Duration::from_secs(MAX_ENGINE_HOOK_SECONDS),
            )
            .await?;
        if timed_out {
            let _ = self.cancel_invocation(&queued.invocation_id).await;
            let reason = self
                .handle_worker_runtime_failure(
                    &worker.summary.worker_id,
                    &worker.summary.active_version,
                    "engine_hook",
                    &format!(
                        "engine hook '{}' exceeded its {MAX_ENGINE_HOOK_SECONDS}-second policy ceiling",
                        hook.as_str()
                    ),
                )
                .await;
            return Err(reason);
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
            invocation_id: record.invocation_id,
            worker_id: worker.summary.worker_id,
            worker_version: worker.summary.active_version,
            output,
        }))
    }

    /// Durably admit a semantic hook without waiting for its terminal result.
    ///
    /// Hooks that guard an interactive boundary may still call
    /// `execute_engine_hook`; fire-and-observe hooks such as session naming use
    /// this admission path and consume their result inside worker completion.
    pub(crate) fn enqueue_engine_hook(
        self: &Arc<Self>,
        hook: WorkerEngineHook,
        input: Value,
        origin_worker_id: Option<&str>,
        invocation: &Invocation,
    ) -> Result<Option<(ActiveWorker, InvocationRecord)>, String> {
        let Some(worker) = self.active_engine_hook(hook, origin_worker_id)? else {
            return Ok(None);
        };
        let idempotency_key = engine_hook_invocation_key(
            hook,
            &worker.summary.active_version,
            &input,
            chrono::Utc::now().timestamp(),
            invocation.causal_context.idempotency_key.as_deref(),
            invocation.id.as_str(),
        );
        let queued = self.enqueue_and_dispatch(InvokeRequest {
            worker_id: worker.summary.worker_id.clone(),
            input,
            idempotency_key,
            trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
            causal_depth: invocation.causal_context.trigger_depth(),
            trigger_kind: format!("engine_hook:{}", hook.as_str()),
            origin_session_id: invocation.causal_context.session_id.clone(),
        })?;
        Ok(Some((worker, queued)))
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

    pub(super) fn active_engine_hook(
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

fn engine_hook_invocation_key(
    hook: WorkerEngineHook,
    worker_version: &str,
    input: &Value,
    unix_seconds: i64,
    causal_key: Option<&str>,
    invocation_id: &str,
) -> String {
    if matches!(
        hook,
        WorkerEngineHook::WorkerRelevance | WorkerEngineHook::InboxContext
    ) {
        return engine_hook_cache_key(hook, worker_version, input, unix_seconds);
    }
    causal_key
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("engine-hook:{}:{invocation_id}", hook.as_str()))
}

/// Reuse the ordinary durable invocation ledger as a tiny result cache only
/// for pure ranking/selection hooks. Session- or trace-bound hooks retain their
/// causal key because their result may own effects outside the typed output.
fn engine_hook_cache_key(
    hook: WorkerEngineHook,
    worker_version: &str,
    input: &Value,
    unix_seconds: i64,
) -> String {
    let mut canonical_input = String::new();
    write_canonical_json(input, &mut canonical_input);
    let window = unix_seconds.div_euclid(ENGINE_HOOK_CACHE_WINDOW_SECONDS);
    let digest = Sha256::digest(
        format!(
            "{}\n{worker_version}\n{window}\n{canonical_input}",
            hook.as_str()
        )
        .as_bytes(),
    );
    format!("engine-hook-cache:{}", hex::encode(digest))
}

fn write_canonical_json(value: &Value, output: &mut String) {
    match value {
        Value::Null => output.push_str("null"),
        Value::Bool(value) => output.push_str(if *value { "true" } else { "false" }),
        Value::Number(value) => output.push_str(&value.to_string()),
        Value::String(value) => {
            output.push_str(&serde_json::to_string(value).expect("JSON strings always serialize"));
        }
        Value::Array(values) => {
            output.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                write_canonical_json(value, output);
            }
            output.push(']');
        }
        Value::Object(values) => {
            output.push('{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_unstable();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                output.push_str(
                    &serde_json::to_string(key).expect("JSON object keys always serialize"),
                );
                output.push(':');
                write_canonical_json(
                    values.get(key).expect("key came from the same JSON object"),
                    output,
                );
            }
            output.push('}');
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semantic_hook_cache_key_is_exact_canonical_versioned_and_short_lived() {
        let input = json!({"query":"compiler","candidates":[{"workerId":"research"}]});
        let reordered =
            serde_json::from_str(r#"{"candidates":[{"workerId":"research"}],"query":"compiler"}"#)
                .unwrap();
        let key = engine_hook_cache_key(WorkerEngineHook::WorkerRelevance, "version-a", &input, 60);
        assert_eq!(
            key,
            engine_hook_cache_key(
                WorkerEngineHook::WorkerRelevance,
                "version-a",
                &reordered,
                89,
            )
        );
        assert_ne!(
            key,
            engine_hook_cache_key(
                WorkerEngineHook::WorkerRelevance,
                "version-a",
                &json!({"query":"different","candidates":[{"workerId":"research"}]}),
                60,
            )
        );
        assert_ne!(
            key,
            engine_hook_cache_key(WorkerEngineHook::WorkerRelevance, "version-b", &input, 60,)
        );
        assert_ne!(
            key,
            engine_hook_cache_key(WorkerEngineHook::WorkerRelevance, "version-a", &input, 90,)
        );
    }

    #[test]
    fn session_and_trace_bound_hooks_preserve_causal_idempotency() {
        let input = json!({"userPrompt":"Question","assistantResponse":"Answer"});
        assert_eq!(
            engine_hook_invocation_key(
                WorkerEngineHook::SessionTitle,
                "version-a",
                &input,
                60,
                Some("session-title:session-a"),
                "invocation-a",
            ),
            "session-title:session-a"
        );
        assert_ne!(
            engine_hook_invocation_key(
                WorkerEngineHook::SessionTitle,
                "version-a",
                &input,
                60,
                None,
                "invocation-a",
            ),
            engine_hook_invocation_key(
                WorkerEngineHook::SessionTitle,
                "version-a",
                &input,
                60,
                None,
                "invocation-b",
            )
        );
        assert_eq!(
            engine_hook_invocation_key(
                WorkerEngineHook::ContextSummary,
                "version-a",
                &json!({"messages":[]}),
                60,
                Some("compaction:trace-a"),
                "invocation-c",
            ),
            "compaction:trace-a"
        );
    }
}
