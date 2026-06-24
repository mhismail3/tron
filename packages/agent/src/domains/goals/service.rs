use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{CreateResource, EngineHostHandle, FunctionId, Invocation};
use crate::shared::server::errors::CapabilityError;

use super::support::{
    answer_summary, authority, bounded_values, engine_error, expected_question_version,
    goal_record, goal_summary, idempotency, invalid, list_limit, malformed_id, object_value,
    publish_lifecycle_event, question_record, question_summary, replay_refs, require_goal,
    require_question, required_reason, required_string, resource_policy, resource_ref,
    resource_scope, string_array, to_value, trace_refs, truncate_chars, update_goal_record,
    update_question_record, value_array, version_ref, worker_id,
};
use super::types::{
    ANSWER_SCHEMA_VERSION, AnswerRecord, GOAL_SCHEMA_VERSION, GoalCancellationRecord, GoalRecord,
    GoalState, QUESTION_SCHEMA_VERSION, QuestionAnswerRecord, QuestionRecord, QuestionState,
};
use super::{
    GOAL_ANSWER_KIND, GOAL_ANSWER_SCHEMA_ID, GOAL_INSPECT_FUNCTION, GOAL_KIND, GOAL_SCHEMA_ID,
    USER_QUESTION_KIND, USER_QUESTION_SCHEMA_ID,
};

pub(crate) async fn goal_create_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let objective = required_string(payload, "objective")?;
    let now = Utc::now();
    let goal_resource_id = format!("goal:{}", invocation.id.as_str());
    let mut record = GoalRecord {
        schema_version: GOAL_SCHEMA_VERSION.to_owned(),
        state: GoalState::Open,
        objective,
        success_criteria: string_array(payload, "successCriteria")?,
        constraints: object_value(payload, "constraints")?,
        queue_refs: Vec::new(),
        plan_refs: value_array(payload, "planRefs")?,
        evidence_refs: value_array(payload, "evidenceRefs")?,
        question_refs: Vec::new(),
        answer_refs: Vec::new(),
        cancellation: None,
        authority: authority(invocation),
        idempotency: idempotency(invocation, payload),
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        created_at: now,
        updated_at: now,
        revision: 1,
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(goal_resource_id.clone()),
            kind: GOAL_KIND.to_owned(),
            schema_id: Some(GOAL_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(GoalState::Open.as_str().to_owned()),
            policy: resource_policy(),
            initial_payload: Some(to_value(&record, "goal")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let goal_version_id = resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid("goal resource was created without an initial version"))?;

    let queue_ref = enqueue_goal_receipt(engine_host, invocation, &goal_resource_id).await?;
    record.queue_refs.push(queue_ref.clone());
    record.updated_at = Utc::now();
    record.revision += 1;
    let updated = update_goal_record(
        engine_host,
        invocation,
        &goal_resource_id,
        Some(goal_version_id),
        &record,
    )
    .await?;
    let inspected = engine_host
        .inspect_resource(&goal_resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid("goal vanished after create"))?;
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "goals.goal_created",
        json!({
            "goalResourceId": goal_resource_id,
            "goalVersionId": updated.version_id,
            "state": GoalState::Open.as_str(),
            "queueRefs": [queue_ref],
            "resourceRefs": [resource_ref(&inspected.resource, "goal")]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": GOAL_SCHEMA_VERSION,
        "status": "open",
        "goal": goal_summary(&inspected.resource, &updated.version_id, &record),
        "streamCursor": cursor.0,
        "queueRefs": record.queue_refs,
        "resourceRefs": [resource_ref(&inspected.resource, "goal")]
    }))
}

pub(crate) async fn goal_list_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let requested_limit = list_limit(payload)?;
    let resources = engine_host
        .list_resources(crate::engine::ListResources {
            kind: Some(GOAL_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: super::support::optional_string(payload, "state")?,
            limit: requested_limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > requested_limit;
    let mut goals = Vec::new();
    for resource in resources.into_iter().take(requested_limit) {
        if let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        {
            let (version_id, record) = goal_record(&inspection)?;
            goals.push(goal_summary(&inspection.resource, &version_id, &record));
        }
    }
    Ok(json!({
        "schemaVersion": GOAL_SCHEMA_VERSION,
        "status": "ok",
        "goals": goals,
        "truncated": truncated,
        "limit": requested_limit
    }))
}

pub(crate) async fn goal_inspect_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let goal_resource_id = required_string(payload, "goalResourceId")?;
    malformed_id(&goal_resource_id, "goal:", "goalResourceId")?;
    let inspection = require_goal(engine_host, invocation, payload).await?;
    let (version_id, record) = goal_record(&inspection)?;
    let (question_refs, question_refs_truncated) = bounded_values(&record.question_refs, 50);
    let (answer_refs, answer_refs_truncated) = bounded_values(&record.answer_refs, 50);
    Ok(json!({
        "schemaVersion": GOAL_SCHEMA_VERSION,
        "status": record.state.as_str(),
        "goal": {
            "summary": goal_summary(&inspection.resource, &version_id, &record),
            "record": record,
            "boundedRefs": {
                "questionRefs": question_refs,
                "questionRefsTruncated": question_refs_truncated,
                "answerRefs": answer_refs,
                "answerRefsTruncated": answer_refs_truncated
            }
        },
        "resourceRefs": [resource_ref(&inspection.resource, "goal")]
    }))
}

pub(crate) async fn goal_cancel_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let reason = required_reason(payload)?;
    let inspection = require_goal(engine_host, invocation, payload).await?;
    let (version_id, mut record) = goal_record(&inspection)?;
    if record.state == GoalState::Cancelled {
        return Ok(json!({
            "schemaVersion": GOAL_SCHEMA_VERSION,
            "status": "already_cancelled",
            "goal": goal_summary(&inspection.resource, &version_id, &record),
            "idempotent": true,
            "resourceRefs": [resource_ref(&inspection.resource, "goal")]
        }));
    }
    if record.state.is_terminal() {
        return Err(invalid("goal_cancel cannot transition a terminal goal"));
    }
    record.state = GoalState::Cancelled;
    record.cancellation = Some(GoalCancellationRecord {
        cancelled_at: Utc::now(),
        cancelled_by: invocation.causal_context.actor_id.as_str().to_owned(),
        reason,
    });
    record.updated_at = Utc::now();
    record.revision += 1;
    let version = update_goal_record(
        engine_host,
        invocation,
        &inspection.resource.resource_id,
        Some(version_id),
        &record,
    )
    .await?;
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "goals.goal_cancelled",
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
        "status": "cancelled",
        "goal": goal_summary(&inspection.resource, &version.version_id, &record),
        "streamCursor": cursor.0,
        "resourceRefs": [version_ref(&inspection.resource, &version, "goal")]
    }))
}

pub(crate) async fn question_create_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let prompt = required_string(payload, "prompt")?;
    let goal_resource_id = super::support::optional_string(payload, "goalResourceId")?;
    if let Some(goal_resource_id) = &goal_resource_id {
        malformed_id(goal_resource_id, "goal:", "goalResourceId")?;
        let goal_payload = json!({"goalResourceId": goal_resource_id});
        let goal = require_goal(engine_host, invocation, &goal_payload).await?;
        let (_, goal_record) = goal_record(&goal)?;
        if goal_record.state.is_terminal() {
            return Err(invalid("question_create cannot attach to a terminal goal"));
        }
    }
    let expires_at = optional_time(payload, "expiresAt")?;
    if expires_at.is_some_and(|expires_at| expires_at <= Utc::now()) {
        return Err(invalid("question_create expiresAt must be in the future"));
    }
    let now = Utc::now();
    let question_resource_id = format!("user_question:{}", invocation.id.as_str());
    let record = QuestionRecord {
        schema_version: QUESTION_SCHEMA_VERSION.to_owned(),
        state: QuestionState::Pending,
        prompt,
        goal_resource_id: goal_resource_id.clone(),
        scope: object_value(payload, "scope")?,
        answer_options: string_array(payload, "answerOptions")?,
        allow_free_form: super::support::optional_bool(payload, "allowFreeForm", true)?,
        expires_at,
        answer: None,
        authority: authority(invocation),
        idempotency: idempotency(invocation, payload),
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        created_at: now,
        updated_at: now,
        revision: 1,
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(question_resource_id.clone()),
            kind: USER_QUESTION_KIND.to_owned(),
            schema_id: Some(USER_QUESTION_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some(QuestionState::Pending.as_str().to_owned()),
            policy: resource_policy(),
            initial_payload: Some(to_value(&record, "question")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let question_version_id = resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid("question resource was created without an initial version"))?;
    if let Some(goal_resource_id) = &goal_resource_id {
        attach_question_to_goal(
            engine_host,
            invocation,
            goal_resource_id,
            &resource,
            &question_version_id,
        )
        .await?;
    }
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "goals.question_created",
        json!({
            "questionResourceId": question_resource_id,
            "questionVersionId": question_version_id,
            "goalResourceId": goal_resource_id,
            "state": QuestionState::Pending.as_str(),
            "resourceRefs": [resource_ref(&resource, "user_question")]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": QUESTION_SCHEMA_VERSION,
        "status": "pending",
        "question": question_summary(&resource, &question_version_id, &record),
        "streamCursor": cursor.0,
        "resourceRefs": [resource_ref(&resource, "user_question")]
    }))
}

pub(crate) async fn question_list_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let requested_limit = list_limit(payload)?;
    let resources = engine_host
        .list_resources(crate::engine::ListResources {
            kind: Some(USER_QUESTION_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: super::support::optional_string(payload, "state")?,
            limit: requested_limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let goal_filter = super::support::optional_string(payload, "goalResourceId")?;
    let mut questions = Vec::new();
    let mut seen = 0usize;
    for resource in resources {
        if let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        {
            let (version_id, record) = question_record(&inspection)?;
            if goal_filter
                .as_ref()
                .is_some_and(|goal| record.goal_resource_id.as_ref() != Some(goal))
            {
                continue;
            }
            seen += 1;
            if questions.len() < requested_limit {
                questions.push(question_summary(&inspection.resource, &version_id, &record));
            }
        }
    }
    Ok(json!({
        "schemaVersion": QUESTION_SCHEMA_VERSION,
        "status": "ok",
        "questions": questions,
        "truncated": seen > requested_limit,
        "limit": requested_limit
    }))
}

pub(crate) async fn question_inspect_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let question_resource_id = required_string(payload, "questionResourceId")?;
    malformed_id(
        &question_resource_id,
        "user_question:",
        "questionResourceId",
    )?;
    let inspection = require_question(engine_host, invocation, payload).await?;
    let (version_id, record) = question_record(&inspection)?;
    Ok(json!({
        "schemaVersion": QUESTION_SCHEMA_VERSION,
        "status": record.state.as_str(),
        "question": {
            "summary": question_summary(&inspection.resource, &version_id, &record),
            "record": record
        },
        "resourceRefs": [resource_ref(&inspection.resource, "user_question")]
    }))
}

pub(crate) async fn question_answer_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let text = required_string(payload, "text")?;
    let reason = required_reason(payload)?;
    let expected_version_id = expected_question_version(payload)?;
    let inspection = require_question(engine_host, invocation, payload).await?;
    let (version_id, mut question) = question_record(&inspection)?;
    if version_id != expected_version_id {
        return Err(invalid(format!(
            "question_answer stale expectedQuestionVersionId: expected {expected_version_id}, actual {version_id}"
        )));
    }
    if question.state == QuestionState::Answered {
        let answer = question
            .answer
            .clone()
            .ok_or_else(|| invalid("answered question has no answer record"))?;
        return Ok(json!({
            "schemaVersion": QUESTION_SCHEMA_VERSION,
            "status": "already_answered",
            "question": question_summary(&inspection.resource, &version_id, &question),
            "answer": answer,
            "idempotent": true,
            "resourceRefs": [resource_ref(&inspection.resource, "user_question")]
        }));
    }
    if let Some(expires_at) = question.expires_at
        && expires_at <= Utc::now()
    {
        question.state = QuestionState::Expired;
        question.updated_at = Utc::now();
        question.revision += 1;
        let _ = update_question_record(
            engine_host,
            invocation,
            &inspection.resource.resource_id,
            Some(version_id),
            &question,
        )
        .await?;
        return Err(invalid("question_answer cannot answer an expired question"));
    }
    if question.state.is_terminal() {
        return Err(invalid("question_answer cannot answer a closed question"));
    }
    if !question.allow_free_form && !question.answer_options.iter().any(|option| option == &text) {
        return Err(invalid(
            "question_answer text is not one of the allowed answerOptions",
        ));
    }
    let now = Utc::now();
    let (text_preview, text_truncated) = truncate_chars(&text, super::support::SUMMARY_CHARS);
    let answer_record = AnswerRecord {
        schema_version: ANSWER_SCHEMA_VERSION.to_owned(),
        state: "recorded".to_owned(),
        question_resource_id: inspection.resource.resource_id.clone(),
        question_version_id: version_id.clone(),
        goal_resource_id: question.goal_resource_id.clone(),
        text,
        text_preview: text_preview.clone(),
        text_truncated,
        reason: reason.clone(),
        authority: authority(invocation),
        idempotency: idempotency(invocation, payload),
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        created_at: now,
        revision: 1,
    };
    let answer_resource_id = format!("goal_answer:{}", invocation.id.as_str());
    let answer_resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(answer_resource_id.clone()),
            kind: GOAL_ANSWER_KIND.to_owned(),
            schema_id: Some(GOAL_ANSWER_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("recorded".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(to_value(&answer_record, "answer")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let answer_version_id = answer_resource
        .current_version_id
        .clone()
        .ok_or_else(|| invalid("answer resource was created without an initial version"))?;
    question.state = QuestionState::Answered;
    question.answer = Some(QuestionAnswerRecord {
        answer_resource_id: answer_resource_id.clone(),
        answer_version_id: answer_version_id.clone(),
        text_preview,
        text_truncated,
        reason,
        answered_at: now,
        answered_by: invocation.causal_context.actor_id.as_str().to_owned(),
        expected_question_version_id: version_id.clone(),
        idempotency: idempotency(invocation, payload),
    });
    question.updated_at = now;
    question.revision += 1;
    let question_version = update_question_record(
        engine_host,
        invocation,
        &inspection.resource.resource_id,
        Some(version_id),
        &question,
    )
    .await?;
    if let Some(goal_resource_id) = &question.goal_resource_id {
        attach_answer_to_goal(
            engine_host,
            invocation,
            goal_resource_id,
            &answer_resource,
            &answer_version_id,
        )
        .await?;
    }
    let answer_version = engine_host
        .inspect_resource(&answer_resource_id)
        .await
        .map_err(engine_error)?
        .and_then(|inspection| {
            inspection
                .versions
                .into_iter()
                .find(|version| version.version_id == answer_version_id)
        })
        .ok_or_else(|| invalid("answer version missing after create"))?;
    let cursor = publish_lifecycle_event(
        engine_host,
        invocation,
        "goals.question_answered",
        json!({
            "questionResourceId": inspection.resource.resource_id,
            "questionVersionId": question_version.version_id,
            "answerResourceId": answer_resource.resource_id,
            "answerVersionId": answer_version.version_id,
            "goalResourceId": question.goal_resource_id,
            "state": QuestionState::Answered.as_str(),
            "resourceRefs": [
                version_ref(&inspection.resource, &question_version, "user_question"),
                version_ref(&answer_resource, &answer_version, "goal_answer")
            ]
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": QUESTION_SCHEMA_VERSION,
        "status": "answered",
        "question": question_summary(&inspection.resource, &question_version.version_id, &question),
        "answer": answer_summary(&answer_record, &answer_resource, &answer_version),
        "streamCursor": cursor.0,
        "resourceRefs": [
            version_ref(&inspection.resource, &question_version, "user_question"),
            version_ref(&answer_resource, &answer_version, "goal_answer")
        ]
    }))
}

async fn enqueue_goal_receipt(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    goal_resource_id: &str,
) -> Result<Value, CapabilityError> {
    let idempotency_key = format!(
        "goals-create-queue-{}",
        invocation
            .causal_context
            .idempotency_key
            .as_deref()
            .unwrap_or_else(|| invocation.id.as_str())
    );
    let mut context = crate::engine::CausalContext::new(
        crate::engine::ActorId::new("system:goals").map_err(engine_error)?,
        crate::engine::ActorKind::System,
        crate::engine::AuthorityGrantId::new("engine-transport").map_err(engine_error)?,
        invocation.causal_context.trace_id.clone(),
    )
    .with_scope("queue.write")
    .with_idempotency_key(idempotency_key);
    if let Some(session_id) = &invocation.causal_context.session_id {
        context = context.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &invocation.causal_context.workspace_id {
        context = context.with_workspace_id(workspace_id.clone());
    }
    let result = engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("queue::enqueue").map_err(engine_error)?,
            json!({
                "queue": "goals.lifecycle",
                "functionId": GOAL_INSPECT_FUNCTION,
                "payload": {"goalResourceId": goal_resource_id}
            }),
            context,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(invalid(format!("goal queue receipt failed: {error}")));
    }
    let value = result
        .value
        .ok_or_else(|| invalid("goal queue receipt returned no value"))?;
    Ok(json!({
        "queue": "goals.lifecycle",
        "receiptId": value["item"]["receiptId"],
        "functionId": GOAL_INSPECT_FUNCTION,
        "status": value["item"]["status"],
        "traceId": invocation.causal_context.trace_id.as_str()
    }))
}

async fn attach_question_to_goal(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    goal_resource_id: &str,
    question_resource: &crate::engine::EngineResource,
    question_version_id: &str,
) -> Result<(), CapabilityError> {
    let goal_payload = json!({"goalResourceId": goal_resource_id});
    let goal = require_goal(engine_host, invocation, &goal_payload).await?;
    let (goal_version_id, mut record) = goal_record(&goal)?;
    record.question_refs.push(json!({
        "resourceId": question_resource.resource_id,
        "kind": question_resource.kind,
        "versionId": question_version_id,
        "role": "blocking_question"
    }));
    record.updated_at = Utc::now();
    record.revision += 1;
    let _ = update_goal_record(
        engine_host,
        invocation,
        goal_resource_id,
        Some(goal_version_id),
        &record,
    )
    .await?;
    Ok(())
}

async fn attach_answer_to_goal(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    goal_resource_id: &str,
    answer_resource: &crate::engine::EngineResource,
    answer_version_id: &str,
) -> Result<(), CapabilityError> {
    let goal_payload = json!({"goalResourceId": goal_resource_id});
    let goal = require_goal(engine_host, invocation, &goal_payload).await?;
    let (goal_version_id, mut record) = goal_record(&goal)?;
    if record.state.is_terminal() {
        return Err(invalid(
            "question_answer cannot attach answer to a terminal goal",
        ));
    }
    record.answer_refs.push(json!({
        "resourceId": answer_resource.resource_id,
        "kind": answer_resource.kind,
        "versionId": answer_version_id,
        "role": "question_answer"
    }));
    record.updated_at = Utc::now();
    record.revision += 1;
    let _ = update_goal_record(
        engine_host,
        invocation,
        goal_resource_id,
        Some(goal_version_id),
        &record,
    )
    .await?;
    Ok(())
}

fn optional_time(payload: &Value, field: &str) -> Result<Option<DateTime<Utc>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => DateTime::parse_from_rfc3339(value)
            .map(|value| Some(value.with_timezone(&Utc)))
            .map_err(|_| invalid(format!("{field} must be RFC3339"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}
