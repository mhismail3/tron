use chrono::{Duration, SecondsFormat, Utc};
use serde_json::json;

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineResourceVersioningMode, FunctionId,
    Invocation, ListResources, RegisterResourceType, TraceId, WorkerId,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

const EXECUTE_FUNCTION: &str = "capability::execute";
const GOAL_CREATE_FUNCTION: &str = "goals::create";
const GOAL_CANCEL_FUNCTION: &str = "goals::cancel";
const QUESTION_CREATE_FUNCTION: &str = "goals::question_create";
const QUESTION_LIST_FUNCTION: &str = "goals::question_list";
const QUESTION_INSPECT_FUNCTION: &str = "goals::question_inspect";
const QUESTION_ANSWER_FUNCTION: &str = "goals::question_answer";

#[tokio::test]
async fn create_list_inspect_and_cancel_goal_records_resource_evidence() {
    let ctx = test_context().await;
    let create_invocation = invocation("goals-create", GOAL_CREATE_FUNCTION, Some("create-key"));
    let created = super::service::create_goal_value(
        &ctx.engine_host,
        &create_invocation,
        &json!({
            "objective": "Ship the goal/question foundation",
            "successCriteria": ["goals are durable", "questions are answerable"],
            "queueRefs": [{"queue": "goals", "receiptId": "receipt-1"}],
            "planRefs": [{"resourceId": "goal_plan:test"}],
            "evidenceRefs": [{"resourceId": "evidence:test"}]
        }),
    )
    .await
    .expect("create goal");

    assert_eq!(created["status"], "open");
    assert!(created["streamCursor"].as_u64().unwrap_or_default() > 0);
    assert_eq!(created["resourceRefs"][0]["kind"], "goal");
    let goal_id = created["goalResourceId"].as_str().unwrap();
    let goal_version = created["goalVersionId"].as_str().unwrap();

    let inspected = super::service::inspect_goal_value(
        &ctx.engine_host,
        &create_invocation,
        &json!({"goalResourceId": goal_id}),
    )
    .await
    .expect("inspect goal");
    assert_eq!(inspected["goal"]["goalVersionId"], goal_version);
    assert_eq!(
        inspected["goal"]["queueRefs"][0]["receiptId"],
        json!("receipt-1")
    );
    assert!(
        inspected["goal"]["traceRefs"]
            .as_array()
            .is_some_and(|refs| !refs.is_empty())
    );
    assert!(
        inspected["goal"]["replayRefs"]
            .as_array()
            .is_some_and(|refs| !refs.is_empty())
    );

    let list = super::service::list_goals_value(
        &ctx.engine_host,
        &create_invocation,
        &json!({"limit": 1}),
    )
    .await
    .expect("list goals");
    assert_eq!(list["goals"].as_array().unwrap().len(), 1);
    assert_eq!(list["truncated"], false);
    assert_eq!(list["goals"][0]["summaryTruncated"], false);

    let cancel_invocation = invocation("goals-cancel", GOAL_CANCEL_FUNCTION, Some("cancel-key"));
    let cancelled = super::service::cancel_goal_value(
        &ctx.engine_host,
        &cancel_invocation,
        &json!({"goalResourceId": goal_id, "reason": "superseded by user"}),
    )
    .await
    .expect("cancel goal");
    assert_eq!(cancelled["status"], "cancelled");
    assert_eq!(cancelled["idempotent"], false);

    let replay = super::service::cancel_goal_value(
        &ctx.engine_host,
        &cancel_invocation,
        &json!({"goalResourceId": goal_id, "reason": "superseded by user"}),
    )
    .await
    .expect("cancel replay");
    assert_eq!(replay["status"], "already_cancelled");
    assert_eq!(replay["idempotent"], true);
}

#[tokio::test]
async fn create_question_and_answer_once_with_expected_version_guard() {
    let ctx = test_context().await;
    let goal_invocation = invocation("question-goal", GOAL_CREATE_FUNCTION, Some("goal-key"));
    let goal = super::service::create_goal_value(
        &ctx.engine_host,
        &goal_invocation,
        &json!({"objective": "Need user input"}),
    )
    .await
    .expect("create goal");
    let goal_id = goal["goalResourceId"].as_str().unwrap();

    let question_invocation = invocation(
        "question-create",
        QUESTION_CREATE_FUNCTION,
        Some("question-key"),
    );
    let question = super::service::create_question_value(
        &ctx.engine_host,
        &question_invocation,
        &json!({
            "goalResourceId": goal_id,
            "prompt": "Which direction should the implementation take?",
            "options": ["minimal", "broad"],
            "allowFreeForm": true,
            "expiresAt": future_time()
        }),
    )
    .await
    .expect("create question");
    assert_eq!(question["status"], "pending");
    let question_id = question["questionResourceId"].as_str().unwrap();
    let question_version = question["questionVersionId"].as_str().unwrap();

    let answer_invocation = invocation(
        "question-answer",
        QUESTION_ANSWER_FUNCTION,
        Some("answer-key"),
    );
    let answered = super::service::answer_question_value(
        &ctx.engine_host,
        &answer_invocation,
        &json!({
            "questionResourceId": question_id,
            "expectedQuestionVersionId": question_version,
            "answerText": "Use the minimal backend foundation.",
            "reason": "User selected the small Slice 7A contract.",
            "evidenceRefs": [{"resourceId": "evidence:answer"}]
        }),
    )
    .await
    .expect("answer question");
    assert_eq!(answered["status"], "answered");
    assert_eq!(answered["unblocksGoal"], true);
    assert_eq!(
        answered["resourceRefs"][0]["kind"],
        super::USER_QUESTION_KIND
    );
    assert_eq!(answered["resourceRefs"][1]["kind"], super::GOAL_ANSWER_KIND);

    let stale = super::service::answer_question_value(
        &ctx.engine_host,
        &answer_invocation,
        &json!({
            "questionResourceId": question_id,
            "expectedQuestionVersionId": question_version,
            "answerText": "Second answer",
            "reason": "Stale retry must fail."
        }),
    )
    .await
    .expect_err("stale answer must fail");
    assert!(
        stale.to_string().contains("revision conflict")
            || stale.to_string().contains("closed and cannot be answered"),
        "{stale}"
    );
}

#[tokio::test]
async fn execute_question_answer_replays_same_idempotency_key_without_double_answer() {
    let ctx = test_context().await;
    let grant_id = derive_execute_grant(&ctx, "answer-replay-grant").await;
    let question_invocation = invocation(
        "answer-replay-question",
        QUESTION_CREATE_FUNCTION,
        Some("answer-replay-question"),
    );
    let question = super::service::create_question_value(
        &ctx.engine_host,
        &question_invocation,
        &json!({"prompt": "Which answer should be recorded?"}),
    )
    .await
    .expect("create question");
    let question_id = question["questionResourceId"].as_str().unwrap();
    let question_version = question["questionVersionId"].as_str().unwrap();
    let payload = json!({
        "operation": "question_answer",
        "questionResourceId": question_id,
        "expectedQuestionVersionId": question_version,
        "answerText": "Record exactly one answer.",
        "reason": "The user provided a final answer.",
        "idempotencyKey": "answer-replay"
    });

    let first = ctx
        .engine_host
        .invoke(execute_invocation(
            "answer-replay-first",
            grant_id.clone(),
            payload.clone(),
            "answer-replay",
        ))
        .await;
    assert_eq!(first.error, None, "first answer failed: {:?}", first.error);
    let first_value = first.value.as_ref().expect("first value");
    assert_eq!(first_value["isError"], false, "{first_value}");
    let answer_resource_id = first_value["details"]["answerResourceId"]
        .as_str()
        .expect("answer resource id")
        .to_owned();

    let replay = ctx
        .engine_host
        .invoke(execute_invocation(
            "answer-replay-second",
            grant_id,
            payload,
            "answer-replay",
        ))
        .await;
    assert_eq!(replay.error, None, "replay failed: {:?}", replay.error);
    assert_eq!(replay.value, first.value);
    assert_eq!(replay.replayed_from, Some(first.invocation_id));
    assert_eq!(
        replay.value.as_ref().unwrap()["details"]["answerResourceId"],
        answer_resource_id
    );

    let answers = ctx
        .engine_host
        .list_resources(ListResources {
            kind: Some(super::GOAL_ANSWER_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list answers");
    assert_eq!(answers.len(), 1, "idempotent replay must not double-answer");
}

#[tokio::test]
async fn bounded_question_list_reports_truncation() {
    let ctx = test_context().await;
    for index in 0..3 {
        let invocation = invocation(
            &format!("question-list-{index}"),
            QUESTION_CREATE_FUNCTION,
            Some(&format!("question-list-key-{index}")),
        );
        super::service::create_question_value(
            &ctx.engine_host,
            &invocation,
            &json!({"prompt": format!("Question {index}?")}),
        )
        .await
        .expect("create question");
    }

    let list = super::service::list_questions_value(
        &ctx.engine_host,
        &invocation("question-list", QUESTION_LIST_FUNCTION, None),
        &json!({"limit": 2}),
    )
    .await
    .expect("list questions");
    assert_eq!(list["questions"].as_array().unwrap().len(), 2);
    assert_eq!(list["truncated"], true);
}

#[tokio::test]
async fn invalid_scope_expired_question_and_oversized_text_fail_closed() {
    let ctx = test_context().await;
    let create = invocation(
        "question-expired",
        QUESTION_CREATE_FUNCTION,
        Some("expired-key"),
    );
    let question = super::service::create_question_value(
        &ctx.engine_host,
        &create,
        &json!({"prompt": "Expired?", "expiresAt": past_time()}),
    )
    .await
    .expect("create expired question");
    let question_id = question["questionResourceId"].as_str().unwrap();
    let question_version = question["questionVersionId"].as_str().unwrap();
    let expired = super::service::answer_question_value(
        &ctx.engine_host,
        &invocation(
            "answer-expired",
            QUESTION_ANSWER_FUNCTION,
            Some("expired-answer"),
        ),
        &json!({
            "questionResourceId": question_id,
            "expectedQuestionVersionId": question_version,
            "answerText": "too late",
            "reason": "expired"
        }),
    )
    .await
    .expect_err("expired answer should fail");
    assert!(expired.to_string().contains("expired"));

    let option_invocation = invocation(
        "question-options",
        QUESTION_CREATE_FUNCTION,
        Some("option-key"),
    );
    let option_question = super::service::create_question_value(
        &ctx.engine_host,
        &option_invocation,
        &json!({
            "prompt": "Proceed?",
            "options": ["yes"],
            "allowFreeForm": false
        }),
    )
    .await
    .expect("create option question");
    let option_rejection = super::service::answer_question_value(
        &ctx.engine_host,
        &invocation(
            "answer-bad-option",
            QUESTION_ANSWER_FUNCTION,
            Some("bad-option-answer"),
        ),
        &json!({
            "questionResourceId": option_question["questionResourceId"].as_str().unwrap(),
            "expectedQuestionVersionId": option_question["questionVersionId"].as_str().unwrap(),
            "answerText": "no",
            "reason": "outside the allowed choices"
        }),
    )
    .await
    .expect_err("non-free-form question should reject answers outside options");
    assert!(option_rejection.to_string().contains("question options"));

    let other_scope = CausalContext::new(
        ActorId::new("agent:other-session").unwrap(),
        ActorKind::Agent,
        AuthorityGrantId::new("grant-other").unwrap(),
        TraceId::new("other-scope").unwrap(),
    )
    .with_session_id("other-session")
    .with_workspace_id("workspace-goals")
    .with_scope(super::WRITE_SCOPE);
    let wrong_scope = super::service::inspect_question_value(
        &ctx.engine_host,
        &Invocation::new_sync(
            FunctionId::new(QUESTION_INSPECT_FUNCTION).unwrap(),
            json!({}),
            other_scope,
        ),
        &json!({"questionResourceId": question_id}),
    )
    .await
    .expect_err("wrong scope should fail");
    assert!(wrong_scope.to_string().contains("scope mismatch"));

    let too_large = super::service::create_goal_value(
        &ctx.engine_host,
        &invocation("goal-too-large", GOAL_CREATE_FUNCTION, Some("too-large")),
        &json!({"objective": "x".repeat(super::support::OBJECTIVE_MAX_CHARS + 1)}),
    )
    .await
    .expect_err("oversized objective should fail");
    assert!(too_large.to_string().contains("too large"));
}

async fn test_context() -> ServerRuntimeContext {
    let ctx = make_test_context();
    register_goal_question_types(&ctx).await;
    ctx
}

async fn register_goal_question_types(ctx: &ServerRuntimeContext) {
    for definition in [
        test_type(
            "goal",
            "tron.resource.goal.v1",
            &["open", "cancelled", "completed", "failed", "archived"],
        ),
        test_type(
            super::USER_QUESTION_KIND,
            super::USER_QUESTION_SCHEMA_ID,
            &["pending", "answered", "expired", "cancelled", "archived"],
        ),
        test_type(
            super::GOAL_ANSWER_KIND,
            super::GOAL_ANSWER_SCHEMA_ID,
            &["recorded", "archived"],
        ),
    ] {
        ctx.engine_host
            .register_resource_type(definition)
            .await
            .expect("register test resource type");
    }
}

fn test_type(kind: &str, schema_id: &str, lifecycle_states: &[&str]) -> RegisterResourceType {
    RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema: json!({"type": "object", "additionalProperties": true}),
        lifecycle_states: lifecycle_states
            .iter()
            .map(|state| (*state).to_owned())
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: vec!["derived_from".to_owned()],
        default_retention: json!({"class": "test"}),
        redaction_rules: json!({"preview": "test"}),
        materialization_rules: json!({}),
        required_capabilities: json!({"read": ["goals.read"], "write": ["goals.write"]}),
        owner_worker_id: WorkerId::new("resource").unwrap(),
    }
}

fn invocation(trace_id: &str, function_id: &str, key: Option<&str>) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new("agent:goals-session").unwrap(),
        ActorKind::Agent,
        AuthorityGrantId::new("grant-goals").unwrap(),
        TraceId::new(trace_id).unwrap(),
    )
    .with_session_id("goals-session")
    .with_workspace_id("workspace-goals")
    .with_scope(super::WRITE_SCOPE);
    if let Some(key) = key {
        context = context.with_idempotency_key(key);
    }
    Invocation::new_sync(FunctionId::new(function_id).unwrap(), json!({}), context)
}

fn future_time() -> String {
    (Utc::now() + Duration::minutes(5)).to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn past_time() -> String {
    (Utc::now() - Duration::minutes(5)).to_rfc3339_opts(SecondsFormat::Secs, true)
}

async fn derive_execute_grant(ctx: &ServerRuntimeContext, key: &str) -> AuthorityGrantId {
    let grant = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("grant::derive").unwrap(),
            json!({
                "parentGrantId": "agent-capability-runtime",
                "subjectActorId": "agent:goals-session",
                "allowedCapabilities": [EXECUTE_FUNCTION],
                "allowedNamespaces": ["__no_namespace_authority__"],
                "allowedAuthorityScopes": ["capability.execute", super::WRITE_SCOPE],
                "allowedResourceKinds": ["goal", super::USER_QUESTION_KIND, super::GOAL_ANSWER_KIND],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 10},
                "canDelegate": false,
                "provenance": {"source": "goals-test"}
            }),
            CausalContext::new(
                ActorId::new("system:goals-test").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("grant").unwrap(),
                TraceId::new(key).unwrap(),
            )
            .with_scope("grant.write")
            .with_session_id("goals-session")
            .with_workspace_id("workspace-goals")
            .with_idempotency_key(key),
        ))
        .await;
    assert_eq!(
        grant.error, None,
        "grant derivation failed: {:?}",
        grant.error
    );
    AuthorityGrantId::new(
        grant.value.unwrap()["grant"]["grantId"]
            .as_str()
            .expect("grant id"),
    )
    .unwrap()
}

fn execute_invocation(
    trace_id: &str,
    grant_id: AuthorityGrantId,
    payload: serde_json::Value,
    idempotency_key: &str,
) -> Invocation {
    Invocation::new_sync(
        FunctionId::new(EXECUTE_FUNCTION).unwrap(),
        payload,
        CausalContext::new(
            ActorId::new("agent:goals-session").unwrap(),
            ActorKind::Agent,
            grant_id,
            TraceId::new(trace_id).unwrap(),
        )
        .with_session_id("goals-session")
        .with_workspace_id("workspace-goals")
        .with_scope("capability.execute")
        .with_scope(super::WRITE_SCOPE)
        .with_idempotency_key(idempotency_key),
    )
}
