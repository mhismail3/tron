//! Session metadata custody and automatic worker-owned naming.

use std::sync::Arc;

use serde_json::{Value, json};

use super::WorkerRuntime;
use crate::domains::worker_kernel::dispatches::PreparedWorkerDispatch;
use crate::domains::worker_kernel::types::{InvocationRecord, WorkerEngineHook};
use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{SESSION_NOT_FOUND, ToolError};

const MAX_SESSION_TITLE_CONTEXT_CHARS: usize = 4_096;

impl WorkerRuntime {
    /// Durably enqueue the active title policy for one still-untitled session.
    ///
    /// The kernel owns eligibility and the final compare-and-set. The worker
    /// sees bounded durable conversation previews and can only propose a title;
    /// it cannot select or mutate an arbitrary session.
    pub(crate) async fn enqueue_session_title_hook(
        self: &Arc<Self>,
        invocation: &Invocation,
    ) -> Result<Value, String> {
        let session_id = title_target_session_id(invocation.causal_context.session_id.as_deref())?;
        let store = self.event_store.clone();
        let load_session_id = session_id.clone();
        let session = run_blocking_task("worker_kernel.session_title_context", move || {
            let Some(session) =
                store
                    .get_session(&load_session_id)
                    .map_err(|error| ToolError::Internal {
                        message: error.to_string(),
                    })?
            else {
                return Err(ToolError::NotFound {
                    code: SESSION_NOT_FOUND.to_owned(),
                    message: format!("session not found: {load_session_id}"),
                });
            };
            Ok(session)
        })
        .await
        .map_err(|error| error.to_string())?;

        if session.is_worker_session() || session_title_is_present(session.title.as_deref()) {
            return Ok(json!({"handled":false,"queued":false,"updated":false}));
        }

        let Some((worker, queued)) = self.enqueue_engine_hook(
            WorkerEngineHook::SessionTitle,
            json!({
                "userPrompt":truncate_title_context(
                    invocation.payload["userPrompt"].as_str().unwrap_or_default()
                ),
                "assistantResponse":truncate_title_context(
                    invocation.payload["assistantResponse"].as_str().unwrap_or_default()
                ),
            }),
            invocation.causal_context.origin_worker_id(),
            invocation,
        )?
        else {
            return Ok(json!({"handled":false,"queued":false,"updated":false}));
        };

        Ok(json!({
            "handled":true,
            "queued":true,
            "updated":false,
            "invocationId":queued.invocation_id,
            "workerId":worker.summary.worker_id,
            "workerVersion":worker.summary.active_version,
        }))
    }

    /// Validate and apply a completed asynchronous title-policy result before
    /// the worker invocation commits its terminal row.
    ///
    /// A crash before terminal commit requeues the same durable invocation.
    /// Re-execution is safe because the session store compare-and-set never
    /// overwrites an explicit or previously applied title.
    pub(super) async fn apply_session_title_result(
        self: &Arc<Self>,
        invocation: &InvocationRecord,
        output: &Value,
    ) -> Result<Option<PreparedWorkerDispatch>, String> {
        if invocation.trigger_kind != "engine_hook:session_title" {
            return Ok(None);
        }
        let session_id = title_target_session_id(invocation.origin_session_id.as_deref())?;
        let title = proposed_title(output).ok_or_else(|| {
            "engine hook 'session_title' output is invalid: title must contain 1 to 160 characters"
                .to_owned()
        })?;
        let (_, session) = crate::domains::session::title::set_title_if_untitled(
            self.event_store.clone(),
            &self.session_manager,
            &self.orchestrator,
            session_id,
            title,
        )
        .await
        .map_err(|error| error.to_string())?;
        self.prepare_session_organization_after_title(invocation, session)
    }
}

fn title_target_session_id(causal_session_id: Option<&str>) -> Result<String, String> {
    causal_session_id
        .map(str::trim)
        .filter(|session_id| !session_id.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| "session title policy requires a current causal session".to_owned())
}

fn session_title_is_present(title: Option<&str>) -> bool {
    title.is_some_and(|value| !value.trim().is_empty())
}

fn truncate_title_context(value: &str) -> String {
    value
        .chars()
        .take(MAX_SESSION_TITLE_CONTEXT_CHARS)
        .collect()
}

fn proposed_title(output: &Value) -> Option<String> {
    output
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| {
            !value.is_empty()
                && value.chars().count() <= crate::domains::session::title::MAX_SESSION_TITLE_CHARS
        })
        .map(ToOwned::to_owned)
}
