use chrono::Utc;
use serde_json::{Value, json};

use crate::engine::{
    AcquireResourceLease, CreateResource, EngineHostHandle, EngineResourceInspection,
    ListResources, UpdateResource, WorkerId,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::support::*;
use super::types::{
    ANSWER_SCHEMA_VERSION, AnswerRecord, GOAL_KIND, GOAL_SCHEMA_ID, GOAL_SCHEMA_VERSION,
    GoalCancellationRecord, GoalRecord, GoalState, QUESTION_SCHEMA_VERSION, QuestionAnswerSummary,
    QuestionRecord, QuestionState,
};
use super::{
    GOAL_ANSWER_KIND, GOAL_ANSWER_SCHEMA_ID, USER_QUESTION_KIND, USER_QUESTION_SCHEMA_ID, WORKER,
};

const QUESTION_ANSWER_LEASE_TTL_MS: i64 = 60_000;

pub(crate) async fn create_goal_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let now = Utc::now();
    let objective = bounded_text(
        "objective",
        &required_string(payload, "objective")?,
        1,
        OBJECTIVE_MAX_CHARS,
    )?;
    let record = GoalRecord {
        schema_version: GOAL_SCHEMA_VERSION.to_owned(),
        state: GoalState::Open,
        intent: objective.clone(),
        objective,
        owner: actor_record(invocation),
        scope: scope_record(invocation),
        success_criteria: optional_string_array(payload, "successCriteria", 20, 500)?,
        constraints: optional_object(payload, "constraints")?.unwrap_or_else(|| json!({})),
        queue_refs: optional_array(payload, "queueRefs")?,
        plan_refs: optional_array(payload, "planRefs")?,
        evidence_refs: optional_array(payload, "evidenceRefs")?,
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        created_at: now,
        updated_at: now,
        cancellation: None,
        revision: 1,
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!("{GOAL_KIND}:{}", invocation.id.as_str())),
            kind: GOAL_KIND.to_owned(),
            schema_id: Some(GOAL_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(GoalState::Open.as_str().to_owned()),
            policy: resource_policy("goal"),
            initial_payload: Some(to_value(&record, "goal")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "goal.created",
        json!({
            "goalResourceId": resource.resource_id,
            "goalVersionId": resource.current_version_id,
            "state": GoalState::Open.as_str(),
            "resourceRefs": [resource_ref(&resource, "goal")]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": GOAL_SCHEMA_VERSION,
        "status": GoalState::Open.as_str(),
        "goalResourceId": resource.resource_id,
        "goalVersionId": resource.current_version_id,
        "streamCursor": cursor.0,
        "resourceRefs": [resource_ref(&resource, "goal")]
    }))
}

pub(crate) async fn list_goals_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let limit = list_limit(payload)?;
    let requested = limit.saturating_add(1);
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(GOAL_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: optional_string(payload, "state")?,
            limit: requested,
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut goals = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let inspection = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
            .ok_or_else(|| invalid_params("listed goal disappeared before inspection"))?;
        let (_, record) = goal_record(&inspection)?;
        goals.push(goal_summary(&inspection, &record));
    }
    Ok(json!({
        "schemaVersion": GOAL_SCHEMA_VERSION,
        "status": "ok",
        "goals": goals,
        "truncated": truncated,
        "limit": limit
    }))
}

pub(crate) async fn inspect_goal_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let inspection = require_goal(engine_host, invocation, payload).await?;
    let (version_id, record) = goal_record(&inspection)?;
    Ok(json!({
        "schemaVersion": GOAL_SCHEMA_VERSION,
        "status": record.state.as_str(),
        "goal": goal_detail(&inspection, &version_id, &record),
        "resourceRefs": [resource_ref(&inspection.resource, "goal")]
    }))
}

pub(crate) async fn cancel_goal_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let mut inspection = require_goal(engine_host, invocation, payload).await?;
    let (current_version_id, mut record) = goal_record(&inspection)?;
    if record.state == GoalState::Cancelled {
        return Ok(json!({
            "schemaVersion": GOAL_SCHEMA_VERSION,
            "status": "already_cancelled",
            "goalResourceId": inspection.resource.resource_id,
            "goalVersionId": current_version_id,
            "idempotent": true,
            "resourceRefs": [resource_ref(&inspection.resource, "goal")]
        }));
    }
    if record.state.is_terminal() {
        return Err(invalid_params("goal is already terminal"));
    }
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        1,
        REASON_MAX_CHARS,
    )?;
    let now = Utc::now();
    record.state = GoalState::Cancelled;
    record.updated_at = now;
    record.revision = record.revision.saturating_add(1);
    record.cancellation = Some(GoalCancellationRecord {
        reason,
        cancelled_at: now,
        actor_id: invocation.causal_context.actor_id.as_str().to_owned(),
        idempotency: idempotency(invocation),
    });
    let version = engine_host
        .update_resource(UpdateResource {
            resource_id: inspection.resource.resource_id.clone(),
            expected_current_version_id: Some(current_version_id),
            lifecycle: Some(GoalState::Cancelled.as_str().to_owned()),
            payload: to_value(&record, "goal cancellation")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    inspection.resource.lifecycle = GoalState::Cancelled.as_str().to_owned();
    inspection.resource.current_version_id = Some(version.version_id.clone());
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "goal.cancelled",
        json!({
            "goalResourceId": inspection.resource.resource_id,
            "goalVersionId": version.version_id,
            "state": GoalState::Cancelled.as_str(),
            "resourceRefs": [version_ref(&inspection.resource, &version, "goal")]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": GOAL_SCHEMA_VERSION,
        "status": GoalState::Cancelled.as_str(),
        "goalResourceId": inspection.resource.resource_id,
        "goalVersionId": version.version_id,
        "streamCursor": cursor.0,
        "idempotent": false,
        "resourceRefs": [version_ref(&inspection.resource, &version, "goal")]
    }))
}

pub(crate) async fn create_question_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let now = Utc::now();
    let prompt = bounded_text(
        "prompt",
        &required_string(payload, "prompt")?,
        1,
        PROMPT_MAX_CHARS,
    )?;
    let goal_ref = optional_goal_ref(engine_host, invocation, payload).await?;
    let record = QuestionRecord {
        schema_version: QUESTION_SCHEMA_VERSION.to_owned(),
        state: QuestionState::Pending,
        prompt,
        requester: actor_record(invocation),
        scope: scope_record(invocation),
        goal_ref,
        options: optional_string_array(payload, "options", 20, 500)?,
        allow_free_form: optional_bool(payload, "allowFreeForm")?.unwrap_or(true),
        expires_at: optional_datetime(payload, "expiresAt")?,
        created_at: now,
        answered_at: None,
        cancelled_at: None,
        answer: None,
        queue_refs: optional_array(payload, "queueRefs")?,
        evidence_refs: optional_array(payload, "evidenceRefs")?,
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        revision: 1,
    };
    if !record.allow_free_form && record.options.is_empty() {
        return Err(invalid_params(
            "question requires options when allowFreeForm is false",
        ));
    }
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!("{USER_QUESTION_KIND}:{}", invocation.id.as_str())),
            kind: USER_QUESTION_KIND.to_owned(),
            schema_id: Some(USER_QUESTION_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(QuestionState::Pending.as_str().to_owned()),
            policy: resource_policy("user_question"),
            initial_payload: Some(to_value(&record, "question")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "question.created",
        json!({
            "questionResourceId": resource.resource_id,
            "questionVersionId": resource.current_version_id,
            "goalRef": record.goal_ref,
            "state": QuestionState::Pending.as_str(),
            "resourceRefs": [resource_ref(&resource, "user_question")]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": QUESTION_SCHEMA_VERSION,
        "status": QuestionState::Pending.as_str(),
        "questionResourceId": resource.resource_id,
        "questionVersionId": resource.current_version_id,
        "streamCursor": cursor.0,
        "resourceRefs": [resource_ref(&resource, "user_question")]
    }))
}

pub(crate) async fn list_questions_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let limit = list_limit(payload)?;
    let requested = limit.saturating_add(1);
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(USER_QUESTION_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: optional_string(payload, "state")?,
            limit: requested,
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut questions = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let inspection = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
            .ok_or_else(|| invalid_params("listed question disappeared before inspection"))?;
        let (_, record) = question_record(&inspection)?;
        questions.push(question_summary(&inspection, &record));
    }
    Ok(json!({
        "schemaVersion": QUESTION_SCHEMA_VERSION,
        "status": "ok",
        "questions": questions,
        "truncated": truncated,
        "limit": limit
    }))
}

pub(crate) async fn inspect_question_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let inspection = require_question(engine_host, invocation, payload).await?;
    let (version_id, record) = question_record(&inspection)?;
    Ok(json!({
        "schemaVersion": QUESTION_SCHEMA_VERSION,
        "status": record.state.as_str(),
        "question": question_detail(&inspection, &version_id, &record),
        "resourceRefs": [resource_ref(&inspection.resource, "user_question")]
    }))
}

pub(crate) async fn answer_question_value(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let question_resource_id = required_string(payload, "questionResourceId")?;
    validate_resource_id(
        "questionResourceId",
        &question_resource_id,
        "user_question:",
    )?;
    let lease = engine_host
        .acquire_resource_lease(AcquireResourceLease {
            resource_kind: USER_QUESTION_KIND.to_owned(),
            resource_id: question_resource_id,
            holder_invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            actor_id: invocation.causal_context.actor_id.clone(),
            authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
            trace_id: invocation.causal_context.trace_id.clone(),
            parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
            idempotency_key: invocation.causal_context.idempotency_key.clone(),
            ttl_ms: QUESTION_ANSWER_LEASE_TTL_MS,
        })
        .await
        .map_err(engine_error)?;
    let result = answer_question_value_locked(engine_host, invocation, payload).await;
    let release_result = engine_host
        .release_resource_lease(&lease.lease_id)
        .await
        .map_err(engine_error);
    match (result, release_result) {
        (Ok(value), Ok(_)) => Ok(value),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), _) => Err(error),
    }
}

async fn answer_question_value_locked(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let mut inspection = require_question(engine_host, invocation, payload).await?;
    let expected = required_string(payload, "expectedQuestionVersionId")?;
    let (current_version_id, mut record) = question_record(&inspection)?;
    if current_version_id != expected {
        return Err(invalid_params(format!(
            "question revision conflict: expected {expected}, actual {current_version_id}"
        )));
    }
    if record.state.is_terminal() {
        return Err(question_terminal_error(&record.state));
    }
    let now = Utc::now();
    if record
        .expires_at
        .is_some_and(|expires_at| expires_at <= now)
    {
        record.state = QuestionState::Expired;
        record.revision = record.revision.saturating_add(1);
        let _ = engine_host
            .update_resource(UpdateResource {
                resource_id: inspection.resource.resource_id.clone(),
                expected_current_version_id: Some(current_version_id),
                lifecycle: Some(QuestionState::Expired.as_str().to_owned()),
                payload: to_value(&record, "expired question")?,
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
        return Err(invalid_params("question is expired and cannot be answered"));
    }
    let answer_text = bounded_text(
        "answerText",
        &required_string(payload, "answerText")?,
        1,
        ANSWER_MAX_CHARS,
    )?;
    if !record.allow_free_form && !record.options.iter().any(|option| option == &answer_text) {
        return Err(invalid_params(
            "answerText must match one of the question options",
        ));
    }
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        1,
        REASON_MAX_CHARS,
    )?;
    let (answer_preview, answer_truncated) = truncate(&answer_text, SUMMARY_MAX_CHARS);
    let answer = AnswerRecord {
        schema_version: ANSWER_SCHEMA_VERSION.to_owned(),
        question_resource_id: inspection.resource.resource_id.clone(),
        question_version_id: current_version_id.clone(),
        goal_ref: record.goal_ref.clone(),
        answer_text,
        answer_text_truncated: answer_truncated,
        actor: actor_record(invocation),
        reason: reason.clone(),
        authority: authority_record(invocation),
        freshness: json!({
            "expectedQuestionVersionId": expected,
            "actualQuestionVersionId": current_version_id,
            "expiresAt": record.expires_at,
            "checkedAt": now
        }),
        unblocks_goal: record.goal_ref.is_some(),
        evidence_refs: optional_array(payload, "evidenceRefs")?,
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        idempotency: idempotency(invocation),
        answered_at: now,
        revision: 1,
    };
    let answer_resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!("{GOAL_ANSWER_KIND}:{}", invocation.id.as_str())),
            kind: GOAL_ANSWER_KIND.to_owned(),
            schema_id: Some(GOAL_ANSWER_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("recorded".to_owned()),
            policy: resource_policy("goal_answer"),
            initial_payload: Some(to_value(&answer, "answer")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let answer_version_id = answer_resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid_params("answer resource has no version"))?;
    record.state = QuestionState::Answered;
    record.answered_at = Some(now);
    record.revision = record.revision.saturating_add(1);
    record.answer = Some(QuestionAnswerSummary {
        answer_resource_id: answer_resource.resource_id.clone(),
        answer_version_id: answer_version_id.clone(),
        text_preview: answer_preview,
        text_truncated: answer_truncated,
        actor: actor_record(invocation),
        reason,
        idempotency: idempotency(invocation),
    });
    let question_version = engine_host
        .update_resource(UpdateResource {
            resource_id: inspection.resource.resource_id.clone(),
            expected_current_version_id: Some(answer.question_version_id.clone()),
            lifecycle: Some(QuestionState::Answered.as_str().to_owned()),
            payload: to_value(&record, "answered question")?,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    inspection.resource.lifecycle = QuestionState::Answered.as_str().to_owned();
    inspection.resource.current_version_id = Some(question_version.version_id.clone());
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "question.answered",
        json!({
            "questionResourceId": inspection.resource.resource_id,
            "questionVersionId": question_version.version_id,
            "answerResourceId": answer_resource.resource_id,
            "answerVersionId": answer_version_id,
            "unblocksGoal": answer.unblocks_goal,
            "answerDoesNotMintAuthority": true,
            "resourceRefs": [
                version_ref(&inspection.resource, &question_version, "user_question"),
                resource_ref(&answer_resource, "goal_answer")
            ]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": ANSWER_SCHEMA_VERSION,
        "status": QuestionState::Answered.as_str(),
        "questionResourceId": inspection.resource.resource_id,
        "questionVersionId": question_version.version_id,
        "answerResourceId": answer_resource.resource_id,
        "answerVersionId": answer_version_id,
        "streamCursor": cursor.0,
        "idempotent": false,
        "unblocksGoal": answer.unblocks_goal,
        "resourceRefs": [
            version_ref(&inspection.resource, &question_version, "user_question"),
            resource_ref(&answer_resource, "goal_answer")
        ]
    }))
}

async fn optional_goal_ref(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<Option<Value>, CapabilityError> {
    let Some(goal_resource_id) = optional_string(payload, "goalResourceId")? else {
        return Ok(None);
    };
    validate_resource_id("goalResourceId", &goal_resource_id, "goal:")?;
    let inspection = engine_host
        .inspect_resource(&goal_resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("goal resource {goal_resource_id} was not found")))?;
    if inspection.resource.kind != GOAL_KIND {
        return Err(invalid_params("goalResourceId is not a goal resource"));
    }
    ensure_scope(invocation, &inspection.resource.scope)?;
    Ok(Some(resource_ref(&inspection.resource, "goal")))
}

async fn require_goal(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<EngineResourceInspection, CapabilityError> {
    let id = required_string(payload, "goalResourceId")?;
    validate_resource_id("goalResourceId", &id, "goal:")?;
    let inspection = engine_host
        .inspect_resource(&id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("goal resource {id} was not found")))?;
    if inspection.resource.kind != GOAL_KIND {
        return Err(invalid_params(format!(
            "resource {id} is not a goal resource"
        )));
    }
    ensure_scope(invocation, &inspection.resource.scope)?;
    Ok(inspection)
}

async fn require_question(
    engine_host: &EngineHostHandle,
    invocation: &crate::engine::Invocation,
    payload: &Value,
) -> Result<EngineResourceInspection, CapabilityError> {
    let id = required_string(payload, "questionResourceId")?;
    validate_resource_id("questionResourceId", &id, "user_question:")?;
    let inspection = engine_host
        .inspect_resource(&id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("question resource {id} was not found")))?;
    if inspection.resource.kind != USER_QUESTION_KIND {
        return Err(invalid_params(format!(
            "resource {id} is not a user_question resource"
        )));
    }
    ensure_scope(invocation, &inspection.resource.scope)?;
    Ok(inspection)
}

fn goal_record(
    inspection: &EngineResourceInspection,
) -> Result<(String, GoalRecord), CapabilityError> {
    let (version_id, payload) = current_payload(inspection)
        .ok_or_else(|| invalid_params("goal resource has no version"))?;
    let record = serde_json::from_value(payload)
        .map_err(|error| invalid_params(format!("malformed goal payload: {error}")))?;
    Ok((version_id, record))
}

fn question_record(
    inspection: &EngineResourceInspection,
) -> Result<(String, QuestionRecord), CapabilityError> {
    let (version_id, payload) = current_payload(inspection)
        .ok_or_else(|| invalid_params("question resource has no version"))?;
    let record = serde_json::from_value(payload)
        .map_err(|error| invalid_params(format!("malformed question payload: {error}")))?;
    Ok((version_id, record))
}

fn goal_summary(inspection: &EngineResourceInspection, record: &GoalRecord) -> Value {
    let (summary, summary_truncated) = truncate(&record.objective, SUMMARY_MAX_CHARS);
    json!({
        "goalResourceId": inspection.resource.resource_id,
        "goalVersionId": inspection.resource.current_version_id,
        "state": record.state.as_str(),
        "summary": summary,
        "summaryTruncated": summary_truncated,
        "queueRefCount": record.queue_refs.len(),
        "planRefCount": record.plan_refs.len(),
        "evidenceRefCount": record.evidence_refs.len(),
        "revision": record.revision,
        "resourceRefs": [resource_ref(&inspection.resource, "goal")]
    })
}

fn goal_detail(
    inspection: &EngineResourceInspection,
    version_id: &str,
    record: &GoalRecord,
) -> Value {
    let mut value = to_value(record, "goal detail").expect("goal detail serialization");
    value["goalResourceId"] = json!(inspection.resource.resource_id);
    value["goalVersionId"] = json!(version_id);
    value["resourceRefs"] = json!([resource_ref(&inspection.resource, "goal")]);
    value
}

fn question_summary(inspection: &EngineResourceInspection, record: &QuestionRecord) -> Value {
    let (summary, summary_truncated) = truncate(&record.prompt, SUMMARY_MAX_CHARS);
    json!({
        "questionResourceId": inspection.resource.resource_id,
        "questionVersionId": inspection.resource.current_version_id,
        "state": record.state.as_str(),
        "summary": summary,
        "summaryTruncated": summary_truncated,
        "goalRef": record.goal_ref,
        "expiresAt": record.expires_at,
        "answer": record.answer,
        "revision": record.revision,
        "resourceRefs": [resource_ref(&inspection.resource, "user_question")]
    })
}

fn question_detail(
    inspection: &EngineResourceInspection,
    version_id: &str,
    record: &QuestionRecord,
) -> Value {
    let mut value = to_value(record, "question detail").expect("question detail serialization");
    value["questionResourceId"] = json!(inspection.resource.resource_id);
    value["questionVersionId"] = json!(version_id);
    value["resourceRefs"] = json!([resource_ref(&inspection.resource, "user_question")]);
    value
}
