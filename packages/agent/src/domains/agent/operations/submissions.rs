//! Agent workflow operations.
use super::{
    BaseEvent, EventType, PromptQueueService, TronEvent, format_subagent_results,
    get_pending_subagent_results,
};
use super::{
    load_prompt_session, publish_agent_queue_stream, start_or_queue_prompt,
    start_or_queue_prompt_with_loaded_session,
};
use crate::domains::agent::Deps;
use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use serde::Deserialize;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn clear_queue_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_store = deps.event_store.clone();
    let sid = session_id.clone();

    let pending = run_blocking_task("agent.clearQueue.query", {
        let es = event_store.clone();
        let s = sid.clone();
        move || PromptQueueService::get_pending_queue(&es, &s)
    })
    .await?;

    let cleared = run_blocking_task("agent::clear_queue", move || {
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

#[derive(Deserialize)]
pub(crate) struct AnswerSubmission {
    #[serde(default)]
    id: Option<String>,
    question: String,
    #[serde(default)]
    #[serde(rename = "selectedValues")]
    selected_values: Vec<String>,
    #[serde(rename = "otherValue")]
    other_value: Option<String>,
}

pub(crate) async fn submit_answers_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let questions_value =
        params
            .and_then(|p| p.get("questions"))
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: "Missing required param: questions".into(),
            })?;
    let answers: Vec<AnswerSubmission> =
        serde_json::from_value(questions_value.clone()).map_err(|e| {
            CapabilityError::InvalidParams {
                message: format!("Invalid questions format: {e}"),
            }
        })?;
    if answers.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "questions array must not be empty".into(),
        });
    }
    let mut lines = vec!["[Answers to your questions]".to_string(), String::new()];
    for answer in &answers {
        lines.push(format!("**{}**", answer.question));
        if let Some(id) = answer.id.as_deref()
            && !id.is_empty()
        {
            lines.push(format!("Question ID: {id}"));
        }
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

pub(crate) async fn deliver_subagent_results_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let session =
        load_prompt_session(deps, &session_id, "agent.deliverSubagentResults.verify").await?;
    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let (prompt, count) = run_blocking_task("agent.deliverSubagentResults.format", move || {
        let pending = get_pending_subagent_results(&event_store, &sid);
        if pending.is_empty() {
            return Err(CapabilityError::NotFound {
                code: "NO_PENDING_RESULTS".into(),
                message: "No unconsumed subagent results found".into(),
            });
        }
        let count = pending.len();
        let event_ids: Vec<String> = pending.iter().map(|(id, _)| id.clone()).collect();
        let formatted =
            format_subagent_results(&pending).ok_or_else(|| CapabilityError::Internal {
                message: "Failed to format subagent results".into(),
            })?;
        let _ = event_store.append(&crate::domains::session::event_store::AppendOptions {
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
