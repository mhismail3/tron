//! Agent workflow operations.
use super::{AgentCommandService, PromptQueueService, PromptRequest, errors, spawn_prompt_run};
use crate::engine::Invocation;
use crate::server::domains::agent::Deps;
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn start_or_queue_prompt(
    deps: &Deps,
    session_id: String,
    prompt: String,
    message_metadata: Option<Value>,
    queue_task: &'static str,
    require_agent_deps: bool,
) -> Result<Value, CapabilityError> {
    let session = AgentCommandService::load_prompt_session(deps, &session_id).await?;
    start_or_queue_prompt_with_loaded_session(
        deps,
        session,
        session_id,
        prompt,
        message_metadata,
        queue_task,
        require_agent_deps,
        None,
    )
    .await
}

pub(crate) async fn start_or_queue_prompt_with_loaded_session(
    deps: &Deps,
    session: crate::events::sqlite::row_types::SessionRow,
    session_id: String,
    prompt: String,
    message_metadata: Option<Value>,
    queue_task: &'static str,
    require_agent_deps: bool,
    extra_success_fields: Option<Value>,
) -> Result<Value, CapabilityError> {
    let run_id = uuid::Uuid::now_v7().to_string();
    if let Some(agent_deps) = deps.agent_deps.as_ref() {
        if let Ok(started_run) = deps.orchestrator.begin_run(&session_id, &run_id) {
            spawn_prompt_run(
                &deps.prompt_runtime(),
                agent_deps,
                &session,
                started_run,
                run_id.clone(),
                PromptRequest {
                    session_id,
                    prompt,
                    reasoning_level: None,
                    images: None,
                    attachments: None,
                    message_metadata,
                    engine_causality: None,
                },
            );
            let mut result = json!({
                "acknowledged": true,
                "queued": false,
                "runId": run_id,
            });
            merge_success_fields(&mut result, extra_success_fields);
            return Ok(result);
        }
    } else if require_agent_deps {
        return Err(CapabilityError::NotAvailable {
            message: "Agent execution dependencies are not configured".into(),
        });
    }

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let queued_metadata = message_metadata.clone();
    let _ = run_blocking_task(queue_task, move || {
        PromptQueueService::enqueue_with_metadata(&event_store, &sid, &prompt, queued_metadata)
            .map_err(|e| CapabilityError::Internal {
                message: e.to_string(),
            })
    })
    .await?;
    let mut result = json!({
        "acknowledged": true,
        "queued": true,
    });
    merge_success_fields(&mut result, extra_success_fields);
    Ok(result)
}

pub(crate) fn merge_success_fields(target: &mut Value, extra: Option<Value>) {
    let Some(Value::Object(extra)) = extra else {
        return;
    };
    if let Some(target) = target.as_object_mut() {
        for (key, value) in extra {
            let _ = target.insert(key, value);
        }
    }
}

pub(crate) async fn load_prompt_session(
    deps: &Deps,
    session_id: &str,
    task: &'static str,
) -> Result<crate::events::sqlite::row_types::SessionRow, CapabilityError> {
    let session_manager = deps.session_manager.clone();
    let sid_check = session_id.to_owned();
    run_blocking_task(task, move || {
        session_manager
            .get_session(&sid_check)
            .map_err(|e| CapabilityError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| CapabilityError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{sid_check}' not found"),
            })
    })
    .await
}

pub(crate) async fn publish_agent_queue_stream(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    action: &str,
    payload: Value,
) {
    crate::server::domains::agent::stream::AgentStreamPublisher::new(&deps.engine_host)
        .queue(invocation, session_id, action, payload)
        .await;
}
