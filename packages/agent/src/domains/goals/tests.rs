use std::path::Path;

use chrono::{Duration as ChronoDuration, Utc};
use serde_json::{Value, json};
use tempfile::tempdir;

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, InvocationResult,
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY, TraceId, builtin_resource_type_definitions,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

#[test]
fn goal_question_resource_definitions_cover_slice_7a_lifecycles() {
    let definitions = builtin_resource_type_definitions();
    let goal = definitions
        .iter()
        .find(|definition| definition.kind == super::GOAL_KIND)
        .expect("goal definition");
    assert_eq!(goal.schema_id, super::GOAL_SCHEMA_ID);
    assert!(goal.lifecycle_states.iter().any(|state| state == "open"));
    assert!(
        goal.lifecycle_states
            .iter()
            .any(|state| state == "cancelled")
    );
    assert!(
        goal.allowed_link_relations
            .iter()
            .any(|relation| relation == "blocked_by")
    );
    assert!(
        goal.allowed_link_relations
            .iter()
            .any(|relation| relation == "answered_by")
    );
    assert!(goal.schema["properties"]["objective"].is_object());
    assert!(goal.schema["properties"]["queueRefs"].is_object());

    let question = definitions
        .iter()
        .find(|definition| definition.kind == super::USER_QUESTION_KIND)
        .expect("user question definition");
    assert_eq!(question.schema_id, super::USER_QUESTION_SCHEMA_ID);
    for state in ["pending", "answered", "expired", "cancelled", "archived"] {
        assert!(
            question
                .lifecycle_states
                .iter()
                .any(|candidate| candidate == state),
            "missing question state {state}"
        );
    }
    assert!(question.schema["properties"]["answer"].is_object());
    assert!(
        question
            .allowed_link_relations
            .iter()
            .any(|relation| relation == "answered_by")
    );

    let answer = definitions
        .iter()
        .find(|definition| definition.kind == super::GOAL_ANSWER_KIND)
        .expect("goal answer definition");
    assert_eq!(answer.schema_id, super::GOAL_ANSWER_SCHEMA_ID);
    for state in ["recorded", "archived"] {
        assert!(
            answer
                .lifecycle_states
                .iter()
                .any(|candidate| candidate == state),
            "missing answer state {state}"
        );
    }
    assert!(answer.schema["properties"]["questionVersionId"].is_object());
    assert!(answer.schema["properties"]["reason"].is_object());
}

#[tokio::test]
async fn goal_create_list_inspect_and_cancel_records_resource_queue_stream_and_replay_evidence() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let fixture = ExecuteFixture::new(&ctx, root.path(), "goals-lifecycle").await;

    let created = fixture
        .invoke_ok(
            json!({
                "operation": "goal_create",
                "objective": "Ship Slice 7A with durable goal state",
                "successCriteria": ["goal records exist", "question answers are version guarded"],
                "constraints": {"noRunner": true},
                "idempotencyKey": "goals-lifecycle-create"
            }),
            Some("goals-lifecycle-create"),
        )
        .await;
    let details = goals_details(&created);
    let goal_resource_id = details["goal"]["goalResourceId"].as_str().unwrap();
    assert!(goal_resource_id.starts_with("goal:"));
    assert_eq!(details["status"], "open");
    assert_eq!(
        details["queueRefs"][0]["functionId"],
        super::GOAL_INSPECT_FUNCTION
    );
    assert!(details["streamCursor"].as_u64().unwrap() > 0);

    let inspection = ctx
        .engine_host
        .inspect_resource(goal_resource_id)
        .await
        .expect("inspect")
        .expect("goal resource");
    assert_eq!(inspection.resource.kind, super::GOAL_KIND);
    assert_eq!(inspection.resource.lifecycle, "open");
    let payload = &inspection.versions.last().unwrap().payload;
    assert_eq!(payload["traceRefs"][0]["functionId"], "capability::execute");
    assert_eq!(payload["replayRefs"][0]["kind"], "engine_invocation");
    assert_eq!(
        payload["queueRefs"][0]["receiptId"]
            .as_str()
            .unwrap()
            .is_empty(),
        false
    );

    let listed = fixture
        .invoke_ok(json!({"operation": "goal_list", "limit": 1}), None)
        .await;
    let list = goals_details(&listed);
    assert_eq!(list["goals"].as_array().unwrap().len(), 1);
    assert_eq!(list["truncated"], false);

    let inspected = fixture
        .invoke_ok(
            json!({"operation": "goal_inspect", "goalResourceId": goal_resource_id}),
            None,
        )
        .await;
    assert_eq!(goals_details(&inspected)["goal"]["record"]["revision"], 2);

    let cancelled = fixture
        .invoke_ok(
            json!({
                "operation": "goal_cancel",
                "goalResourceId": goal_resource_id,
                "reason": "test complete",
                "idempotencyKey": "goals-lifecycle-cancel"
            }),
            Some("goals-lifecycle-cancel"),
        )
        .await;
    assert_eq!(goals_details(&cancelled)["status"], "cancelled");

    let second_cancel = fixture
        .invoke_ok(
            json!({
                "operation": "goal_cancel",
                "goalResourceId": goal_resource_id,
                "reason": "test complete",
                "idempotencyKey": "goals-lifecycle-cancel-2"
            }),
            Some("goals-lifecycle-cancel-2"),
        )
        .await;
    assert_eq!(goals_details(&second_cancel)["status"], "already_cancelled");
}

#[tokio::test]
async fn question_create_answer_and_idempotent_replay_are_version_guarded() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let fixture = ExecuteFixture::new(&ctx, root.path(), "questions-answer").await;
    let goal = fixture
        .invoke_ok(
            json!({
                "operation": "goal_create",
                "objective": "Answer question",
                "idempotencyKey": "questions-answer-goal"
            }),
            Some("questions-answer-goal"),
        )
        .await;
    let goal_resource_id = goals_details(&goal)["goal"]["goalResourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let question = fixture
        .invoke_ok(
            json!({
                "operation": "question_create",
                "goalResourceId": goal_resource_id,
                "prompt": "Which path should be used?",
                "answerOptions": ["A", "B"],
                "allowFreeForm": false,
                "idempotencyKey": "questions-answer-question"
            }),
            Some("questions-answer-question"),
        )
        .await;
    let question_details = goals_details(&question);
    let question_resource_id = question_details["question"]["questionResourceId"]
        .as_str()
        .unwrap();
    let question_version_id = question_details["question"]["questionVersionId"]
        .as_str()
        .unwrap();

    let answered = fixture
        .invoke_ok(
            json!({
                "operation": "question_answer",
                "questionResourceId": question_resource_id,
                "expectedQuestionVersionId": question_version_id,
                "text": "A",
                "reason": "explicit test answer",
                "idempotencyKey": "questions-answer-answer"
            }),
            Some("questions-answer-answer"),
        )
        .await;
    let answer = goals_details(&answered);
    assert_eq!(answer["status"], "answered");
    let answer_resource_id = answer["answer"]["answerResourceId"].as_str().unwrap();
    assert!(answer_resource_id.starts_with("goal_answer:"));

    let replayed = fixture
        .invoke_ok(
            json!({
                "operation": "question_answer",
                "questionResourceId": question_resource_id,
                "expectedQuestionVersionId": question_version_id,
                "text": "A",
                "reason": "explicit test answer",
                "idempotencyKey": "questions-answer-answer"
            }),
            Some("questions-answer-answer"),
        )
        .await;
    assert_eq!(
        goals_details(&replayed)["answer"]["answerResourceId"],
        json!(answer_resource_id)
    );

    let stale = fixture
        .invoke_error(
            json!({
                "operation": "question_answer",
                "questionResourceId": question_resource_id,
                "expectedQuestionVersionId": question_version_id,
                "text": "B",
                "reason": "stale retry",
                "idempotencyKey": "questions-answer-stale"
            }),
            Some("questions-answer-stale"),
        )
        .await;
    assert!(
        stale.contains("stale expectedQuestionVersionId") || stale.contains("already_answered")
    );
}

#[tokio::test]
async fn question_and_goal_fail_closed_for_invalid_scope_expiry_reason_and_bounds() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let fixture = ExecuteFixture::new(&ctx, root.path(), "questions-fail").await;

    let missing_context = invoke(
        &ctx,
        json!({
            "operation": "goal_create",
            "objective": "missing context",
            "idempotencyKey": "questions-fail-no-session"
        }),
        CausalContext::new(
            ActorId::new("agent:wrong").unwrap(),
            ActorKind::Agent,
            fixture.grant_id.clone(),
            TraceId::new("questions-fail-no-session").unwrap(),
        )
        .with_scope("capability.execute")
        .with_idempotency_key("questions-fail-no-session"),
    )
    .await;
    assert!(missing_context.error.is_some());

    let malformed = fixture
        .invoke_error(
            json!({"operation": "goal_inspect", "goalResourceId": "goal:../bad"}),
            None,
        )
        .await;
    assert!(malformed.contains("malformed"));

    let empty = fixture
        .invoke_error(
            json!({
                "operation": "goal_create",
                "objective": " ",
                "idempotencyKey": "questions-fail-empty"
            }),
            Some("questions-fail-empty"),
        )
        .await;
    assert!(empty.contains("must not be empty"));

    let expired = fixture
        .invoke_error(
            json!({
                "operation": "question_create",
                "prompt": "too late?",
                "expiresAt": (Utc::now() - ChronoDuration::minutes(1)).to_rfc3339(),
                "idempotencyKey": "questions-fail-expired"
            }),
            Some("questions-fail-expired"),
        )
        .await;
    assert!(expired.contains("expiresAt must be in the future"));

    let question = fixture
        .invoke_ok(
            json!({
                "operation": "question_create",
                "prompt": "Needs a reason",
                "idempotencyKey": "questions-fail-question"
            }),
            Some("questions-fail-question"),
        )
        .await;
    let q = goals_details(&question)["question"].clone();
    let missing_reason = fixture
        .invoke_error(
            json!({
                "operation": "question_answer",
                "questionResourceId": q["questionResourceId"],
                "expectedQuestionVersionId": q["questionVersionId"],
                "text": "answer",
                "idempotencyKey": "questions-fail-missing-reason"
            }),
            Some("questions-fail-missing-reason"),
        )
        .await;
    assert!(missing_reason.contains("missing reason"));
}

#[tokio::test]
async fn bounded_list_output_truncates_deterministically() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let fixture = ExecuteFixture::new(&ctx, root.path(), "goals-list").await;
    for index in 0..3 {
        fixture
            .invoke_ok(
                json!({
                    "operation": "goal_create",
                    "objective": format!("Goal {index}"),
                    "idempotencyKey": format!("goals-list-create-{index}")
                }),
                Some(&format!("goals-list-create-{index}")),
            )
            .await;
    }
    let listed = fixture
        .invoke_ok(json!({"operation": "goal_list", "limit": 2}), None)
        .await;
    let details = goals_details(&listed);
    assert_eq!(details["goals"].as_array().unwrap().len(), 2);
    assert_eq!(details["truncated"], true);
    assert_eq!(details["limit"], 2);
}

struct ExecuteFixture<'a> {
    ctx: &'a ServerRuntimeContext,
    root: &'a Path,
    session_id: String,
    workspace_id: String,
    actor_id: ActorId,
    grant_id: AuthorityGrantId,
}

impl<'a> ExecuteFixture<'a> {
    async fn new(ctx: &'a ServerRuntimeContext, root: &'a Path, name: &str) -> Self {
        let session_id = format!("{name}-session");
        let workspace_id = format!("{name}-workspace");
        let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
        let grant_id = derive_execute_grant(ctx, &actor_id, &session_id, &workspace_id, root).await;
        Self {
            ctx,
            root,
            session_id,
            workspace_id,
            actor_id,
            grant_id,
        }
    }

    async fn invoke_ok(&self, payload: Value, idempotency_key: Option<&str>) -> Value {
        let result = invoke(self.ctx, payload, self.context(idempotency_key)).await;
        assert_eq!(result.error, None, "expected ok, got {:?}", result.error);
        result.value.unwrap()
    }

    async fn invoke_error(&self, payload: Value, idempotency_key: Option<&str>) -> String {
        invoke(self.ctx, payload, self.context(idempotency_key))
            .await
            .error
            .expect("error")
            .to_string()
    }

    fn context(&self, idempotency_key: Option<&str>) -> CausalContext {
        let trace_id = idempotency_key
            .and_then(|key| TraceId::new(key).ok())
            .unwrap_or_else(TraceId::generate);
        let mut context = CausalContext::new(
            self.actor_id.clone(),
            ActorKind::Agent,
            self.grant_id.clone(),
            trace_id,
        )
        .with_scope("capability.execute")
        .with_session_id(self.session_id.clone())
        .with_workspace_id(self.workspace_id.clone())
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            self.root.display().to_string(),
        )
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID, "provider-goals")
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run-goals")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1");
        if let Some(idempotency_key) = idempotency_key {
            context = context.with_idempotency_key(idempotency_key.to_owned());
        }
        context
    }
}

async fn invoke(
    ctx: &ServerRuntimeContext,
    payload: Value,
    causal_context: CausalContext,
) -> InvocationResult {
    ctx.engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            payload,
            causal_context,
        ))
        .await
}

async fn derive_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    session_id: &str,
    workspace_id: &str,
    root: &Path,
) -> AuthorityGrantId {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("grant::derive").unwrap(),
            json!({
                "parentGrantId": "agent-capability-runtime",
                "subjectActorId": actor_id.as_str(),
                "allowedCapabilities": ["capability::execute"],
                "allowedNamespaces": ["__no_namespace_authority__"],
                "allowedAuthorityScopes": ["capability.execute"],
                "allowedResourceKinds": ["agent_state", "goal", "user_question", "goal_answer"],
                "resourceSelectors": ["kind:agent_state", "kind:goal", "kind:user_question", "kind:goal_answer"],
                "fileRoots": [root.display().to_string()],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 32},
                "canDelegate": false,
                "provenance": {"source": "goals_test"}
            }),
            CausalContext::new(
                ActorId::new("system:goals-test").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("grant").unwrap(),
                TraceId::new(format!("derive-{session_id}")).unwrap(),
            )
            .with_scope("grant.write")
            .with_session_id(session_id)
            .with_idempotency_key(format!("derive-{workspace_id}")),
        ))
        .await;
    assert_eq!(
        result.error, None,
        "grant derive failed: {:?}",
        result.error
    );
    AuthorityGrantId::new(result.value.unwrap()["grant"]["grantId"].as_str().unwrap()).unwrap()
}

fn goals_details(value: &Value) -> &Value {
    &value["details"]["goals"]
}
