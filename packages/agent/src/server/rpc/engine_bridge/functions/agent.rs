use super::*;

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::EventType;
use crate::server::rpc::agent_commands::AgentCommandService;
use crate::server::rpc::errors;
use crate::server::rpc::handlers::agent::prompt_runtime::{
    format_subagent_results, get_pending_subagent_results,
};
use crate::server::rpc::handlers::agent::prompt_service::{PromptRequest, spawn_prompt_run};
use crate::server::rpc::prompt_queue::PromptQueueService;
use crate::server::rpc::validation;
use serde::Deserialize;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "agent.status" => status_value(Some(payload), deps).await,
        "agent.abort" => abort_value(Some(payload), deps).await,
        "agent.abortTool" => abort_tool_value(Some(payload), deps).await,
        "agent.queuePrompt" => queue_prompt_value(Some(payload), invocation, deps).await,
        "agent.dequeuePrompt" => dequeue_prompt_value(Some(payload), invocation, deps).await,
        "agent.clearQueue" => clear_queue_value(Some(payload), invocation, deps).await,
        "agent.deliverSubagentResults" => deliver_subagent_results_value(Some(payload), deps).await,
        "agent.submitConfirmation" => submit_confirmation_value(Some(payload), deps).await,
        "agent.submitAnswers" => submit_answers_value(Some(payload), deps).await,
        _ => Err(RpcError::Internal {
            message: format!("agent method {method} is not engine-owned"),
        }),
    }
}

async fn status_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_store = deps.event_store.clone();
    let sid_for_check = session_id.clone();
    let session_exists = run_blocking_task("agent.status.session_check", move || {
        event_store
            .get_session(&sid_for_check)
            .map(|opt| opt.is_some())
            .map_err(crate::server::rpc::handlers::map_event_store_error)
    })
    .await?;
    if !session_exists {
        return Err(RpcError::NotFound {
            code: "SESSION_NOT_FOUND".into(),
            message: format!("Session '{session_id}' not found"),
        });
    }

    let run_id = deps.orchestrator.get_run_id(&session_id);
    let phase = if run_id.is_some() {
        "processing"
    } else {
        "idle"
    };
    let current_tool = deps
        .orchestrator
        .turn_accumulators()
        .current_running_tool(&session_id);
    let event_store = deps.event_store.clone();
    let sid_for_latest = session_id.clone();
    let latest_timestamp = run_blocking_task("agent.status.latest_event", move || {
        let pool = event_store.pool().clone();
        let conn = pool.get().map_err(|e| RpcError::Internal {
            message: format!("DB connection failed: {e}"),
        })?;
        crate::events::sqlite::repositories::event::EventRepo::get_latest(&conn, &sid_for_latest)
            .map(|opt| opt.map(|row| row.timestamp))
            .map_err(crate::server::rpc::handlers::map_event_store_error)
    })
    .await?;
    let time_since_last_event_ms = latest_timestamp
        .as_deref()
        .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
        .and_then(|parsed| {
            let now = chrono::Utc::now();
            let delta = now.signed_duration_since(parsed.with_timezone(&chrono::Utc));
            delta.num_milliseconds().try_into().ok()
        })
        .map(|ms: i64| ms.max(0));
    let current_tool_value = current_tool.map(|snap| {
        json!({
            "name": snap.tool_name,
            "toolCallId": snap.tool_call_id,
            "startedAt": snap.started_at,
        })
    });

    Ok(json!({
        "sessionId": session_id,
        "phase": phase,
        "runId": run_id,
        "currentTool": current_tool_value,
        "lastEventTimestamp": latest_timestamp,
        "timeSinceLastEventMs": time_since_last_event_ms,
    }))
}

async fn abort_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    AgentCommandService::abort(&deps.rpc_context, &session_id)
}

async fn abort_tool_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let tool_call_id = require_string_param(params, "toolCallId")?;
    AgentCommandService::abort_tool(&deps.rpc_context, &session_id, &tool_call_id)
}

async fn queue_prompt_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let prompt = require_string_param(params, "prompt")?;
    validation::validate_string_param(&prompt, "prompt", validation::MAX_PROMPT_LENGTH)?;

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let prompt_for_queue = prompt.clone();
    let item = run_blocking_task("agent.queuePrompt", move || {
        PromptQueueService::enqueue(&event_store, &sid, &prompt_for_queue)
    })
    .await?;

    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::MessageQueued {
            base: BaseEvent::now(&session_id),
            queue_id: item.queue_id.clone(),
            text: item.text.clone(),
            position: item.position,
        });
    publish_agent_queue_stream(invocation, deps, &session_id, "queued", json!(&item)).await;

    serde_json::to_value(&item).map_err(|e| RpcError::Internal {
        message: format!("Failed to serialize queue item: {e}"),
    })
}

async fn dequeue_prompt_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let queue_id = require_string_param(params, "queueId")?;

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let qid = queue_id.clone();
    run_blocking_task("agent.dequeuePrompt", move || {
        PromptQueueService::dequeue(&event_store, &sid, &qid, "cancelled")
    })
    .await?;

    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::MessageDequeued {
            base: BaseEvent::now(&session_id),
            queue_id: queue_id.clone(),
            reason: "cancelled".into(),
        });
    publish_agent_queue_stream(
        invocation,
        deps,
        &session_id,
        "dequeued",
        json!({"queueId": queue_id, "reason": "cancelled"}),
    )
    .await;

    Ok(json!({ "ok": true }))
}

async fn clear_queue_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_store = deps.event_store.clone();
    let sid = session_id.clone();

    let pending = run_blocking_task("agent.clearQueue.query", {
        let es = event_store.clone();
        let s = sid.clone();
        move || PromptQueueService::get_pending_queue(&es, &s)
    })
    .await?;

    let cleared = run_blocking_task("agent.clearQueue", move || {
        PromptQueueService::clear_queue(&event_store, &sid)
    })
    .await?;

    for item in &pending {
        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::MessageDequeued {
                base: BaseEvent::now(&session_id),
                queue_id: item.queue_id.clone(),
                reason: "cleared".into(),
            });
    }
    publish_agent_queue_stream(
        invocation,
        deps,
        &session_id,
        "cleared",
        json!({"cleared": cleared, "items": pending}),
    )
    .await;

    Ok(json!({ "cleared": cleared }))
}

async fn submit_confirmation_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let action = require_string_param(params, "action")?;
    let decision = require_string_param(params, "decision")?;
    let note = params
        .and_then(|p| p.get("note"))
        .and_then(Value::as_str)
        .map(String::from);
    let mut lines = vec![
        "[Confirmation response]".to_string(),
        String::new(),
        format!("Action: {action}"),
        format!("Decision: {decision}"),
    ];
    if let Some(ref note) = note
        && !note.is_empty()
    {
        lines.push(format!("Note: {note}"));
    }
    let prompt = lines.join("\n");
    let mut metadata_obj = serde_json::Map::new();
    let _ = metadata_obj.insert("messageKind".into(), json!("confirmation_response"));
    let _ = metadata_obj.insert("confirmationDecision".into(), json!(decision));
    if let Some(ref n) = note
        && !n.is_empty()
    {
        let _ = metadata_obj.insert("confirmationNote".into(), json!(n));
    }
    start_or_queue_prompt(
        deps,
        session_id,
        prompt,
        Some(Value::Object(metadata_obj)),
        "agent.submitConfirmation.queue",
        true,
    )
    .await
}

#[derive(Deserialize)]
struct AnswerSubmission {
    question: String,
    #[serde(default)]
    #[serde(rename = "selectedValues")]
    selected_values: Vec<String>,
    #[serde(rename = "otherValue")]
    other_value: Option<String>,
}

async fn submit_answers_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let questions_value =
        params
            .and_then(|p| p.get("questions"))
            .ok_or_else(|| RpcError::InvalidParams {
                message: "Missing required param: questions".into(),
            })?;
    let answers: Vec<AnswerSubmission> =
        serde_json::from_value(questions_value.clone()).map_err(|e| RpcError::InvalidParams {
            message: format!("Invalid questions format: {e}"),
        })?;
    if answers.is_empty() {
        return Err(RpcError::InvalidParams {
            message: "questions array must not be empty".into(),
        });
    }
    let mut lines = vec!["[Answers to your questions]".to_string(), String::new()];
    for answer in &answers {
        lines.push(format!("**{}**", answer.question));
        if let Some(ref other) = answer.other_value {
            if !other.is_empty() {
                lines.push(format!("Answer: [Other] {other}"));
            } else if !answer.selected_values.is_empty() {
                lines.push(format!("Answer: {}", answer.selected_values.join(", ")));
            } else {
                lines.push("Answer: (no selection)".to_string());
            }
        } else if !answer.selected_values.is_empty() {
            lines.push(format!("Answer: {}", answer.selected_values.join(", ")));
        } else {
            lines.push("Answer: (no selection)".to_string());
        }
        lines.push(String::new());
    }
    start_or_queue_prompt(
        deps,
        session_id,
        lines.join("\n"),
        Some(json!({
            "messageKind": "answered_questions",
            "answerCount": answers.len(),
        })),
        "agent.submitAnswers.queue",
        true,
    )
    .await
}

async fn deliver_subagent_results_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let session =
        load_prompt_session(deps, &session_id, "agent.deliverSubagentResults.verify").await?;
    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let (prompt, count) = run_blocking_task("agent.deliverSubagentResults.format", move || {
        let pending = get_pending_subagent_results(&event_store, &sid);
        if pending.is_empty() {
            return Err(RpcError::NotFound {
                code: "NO_PENDING_RESULTS".into(),
                message: "No unconsumed subagent results found".into(),
            });
        }
        let count = pending.len();
        let event_ids: Vec<String> = pending.iter().map(|(id, _)| id.clone()).collect();
        let formatted = format_subagent_results(&pending).ok_or_else(|| RpcError::Internal {
            message: "Failed to format subagent results".into(),
        })?;
        let _ = event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: EventType::SubagentResultsConsumed,
            payload: json!({
                "consumedEventIds": event_ids,
                "count": count,
            }),
            parent_id: None,
            sequence: None,
        });
        Ok((formatted, count))
    })
    .await?;
    let metadata = json!({
        "messageKind": "subagent_results_delivered",
        "subagentCount": count,
    });
    start_or_queue_prompt_with_loaded_session(
        deps,
        session,
        session_id,
        prompt,
        Some(metadata),
        "agent.deliverSubagentResults.queue",
        false,
        Some(json!({"subagentCount": count})),
    )
    .await
}

async fn start_or_queue_prompt(
    deps: &RpcEngineDeps,
    session_id: String,
    prompt: String,
    message_metadata: Option<Value>,
    queue_task: &'static str,
    require_agent_deps: bool,
) -> Result<Value, RpcError> {
    let session = AgentCommandService::load_prompt_session(&deps.rpc_context, &session_id).await?;
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

async fn start_or_queue_prompt_with_loaded_session(
    deps: &RpcEngineDeps,
    session: crate::events::sqlite::row_types::SessionRow,
    session_id: String,
    prompt: String,
    message_metadata: Option<Value>,
    queue_task: &'static str,
    require_agent_deps: bool,
    extra_success_fields: Option<Value>,
) -> Result<Value, RpcError> {
    let run_id = uuid::Uuid::now_v7().to_string();
    if let Some(agent_deps) = deps.agent_deps.as_ref() {
        if let Ok(started_run) = deps.orchestrator.begin_run(&session_id, &run_id) {
            spawn_prompt_run(
                &deps.rpc_context,
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
        return Err(RpcError::NotAvailable {
            message: "Agent execution dependencies are not configured".into(),
        });
    }

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let queued_metadata = message_metadata.clone();
    let _ = run_blocking_task(queue_task, move || {
        PromptQueueService::enqueue_with_metadata(&event_store, &sid, &prompt, queued_metadata)
            .map_err(|e| RpcError::Internal {
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

fn merge_success_fields(target: &mut Value, extra: Option<Value>) {
    let Some(Value::Object(extra)) = extra else {
        return;
    };
    if let Some(target) = target.as_object_mut() {
        for (key, value) in extra {
            let _ = target.insert(key, value);
        }
    }
}

async fn load_prompt_session(
    deps: &RpcEngineDeps,
    session_id: &str,
    task: &'static str,
) -> Result<crate::events::sqlite::row_types::SessionRow, RpcError> {
    let session_manager = deps.session_manager.clone();
    let sid_check = session_id.to_owned();
    run_blocking_task(task, move || {
        session_manager
            .get_session(&sid_check)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{sid_check}' not found"),
            })
    })
    .await
}

async fn publish_agent_queue_stream(
    invocation: &Invocation,
    deps: &RpcEngineDeps,
    session_id: &str,
    action: &str,
    payload: Value,
) {
    let _ = deps
        .engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: "agent.queue".to_owned(),
            payload: json!({
                "action": action,
                "sessionId": session_id,
                "payload": payload,
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: "agent::queue".to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await;
}
