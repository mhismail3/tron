use chrono::{Duration, SecondsFormat, TimeZone, Utc};
use serde_json::{Value, json};

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, EngineResourceScope,
    FunctionId, Invocation, TraceId, UpdateResource, WorkerId,
};
use crate::shared::server::test_support::make_test_context;

use super::types::ApprovalCheckOutcome;

#[tokio::test]
async fn request_writes_resource_and_lifecycle_stream_event() {
    let ctx = make_test_context();
    let response =
        create_request(&ctx, "approval-request-stream", future_time(30), json!({})).await;
    let request_resource_id = response["requestResourceId"].as_str().expect("request id");
    let request_version_id = response["requestVersionId"].as_str().expect("version id");

    assert_eq!(response["status"], "pending");
    assert!(response["streamCursor"].as_u64().unwrap_or_default() > 0);
    assert_eq!(
        response["resourceRefs"][0]["kind"],
        super::APPROVAL_REQUEST_KIND
    );

    let inspection = ctx
        .engine_host
        .inspect_resource(request_resource_id)
        .await
        .unwrap()
        .expect("request resource");
    assert_eq!(inspection.resource.kind, super::APPROVAL_REQUEST_KIND);
    assert_eq!(
        inspection.resource.current_version_id.as_deref(),
        Some(request_version_id)
    );
    let payload = &inspection.versions.last().expect("request version").payload;
    assert_eq!(payload["state"], "pending");
    assert_eq!(payload["action"], action());
    assert_eq!(payload["scope"], scope());
    assert_eq!(payload["riskClass"], "high");
    assert_eq!(payload["denialBehavior"]["mode"], "fail_closed");
    assert!(
        payload["traceRefs"]
            .as_array()
            .is_some_and(|refs| !refs.is_empty()),
        "trace refs should be captured: {payload}"
    );
    assert!(
        payload["replayRefs"]
            .as_array()
            .is_some_and(|refs| !refs.is_empty()),
        "replay refs should be captured: {payload}"
    );
}

#[tokio::test]
async fn approved_decision_passes_check_with_evidence_explanation() {
    let ctx = make_test_context();
    let request = create_request(
        &ctx,
        "approval-approved-request",
        future_time(30),
        json!({}),
    )
    .await;
    let decision = decide(
        &ctx,
        &request,
        "approved",
        "approval-approved-decision",
        future_time(20),
        None,
    )
    .await;

    let check = check(
        &ctx,
        &request,
        Some(&decision),
        action(),
        scope(),
        selectors(),
    )
    .await;

    assert_eq!(check["allowed"], true);
    assert_eq!(check["outcome"], "approved");
    assert_eq!(check["reason"], "approval_decision_approved");
    assert_eq!(
        check["explanation"]["request"]["evidenceRefs"][0]["resourceId"],
        "evidence:approval-test"
    );
    assert_eq!(
        check["explanation"]["decision"]["replayRefs"][0]["source"],
        "engine_invocation_ledger"
    );
}

#[tokio::test]
async fn denied_expired_pending_missing_malformed_stale_and_scope_mismatch_fail_closed() {
    let ctx = make_test_context();

    let pending_request =
        create_request(&ctx, "approval-pending-request", future_time(30), json!({})).await;
    let pending = check(&ctx, &pending_request, None, action(), scope(), selectors()).await;
    assert_denied(&pending, "pending");

    let denied_request =
        create_request(&ctx, "approval-denied-request", future_time(30), json!({})).await;
    let denied_decision = decide(
        &ctx,
        &denied_request,
        "denied",
        "approval-denied-decision",
        future_time(20),
        None,
    )
    .await;
    let denied = check(
        &ctx,
        &denied_request,
        Some(&denied_decision),
        action(),
        scope(),
        selectors(),
    )
    .await;
    assert_denied(&denied, "denied");

    let expired_request =
        create_request(&ctx, "approval-expired-request", past_time(1), json!({})).await;
    let expired = check(&ctx, &expired_request, None, action(), scope(), selectors()).await;
    assert_denied(&expired, "expired");

    let missing = invoke_check(
        &ctx,
        json!({
            "requestResourceId": "approval_request:missing",
            "action": action(),
            "scope": scope(),
            "riskClass": "high",
            "resourceSelectors": selectors()
        }),
    )
    .await;
    assert_denied(&missing, "missing");

    let malformed = check_wrong_kind_request(&ctx).await;
    assert_denied(&malformed, "malformed");

    let mismatch_request = create_request(
        &ctx,
        "approval-mismatch-request",
        future_time(30),
        json!({}),
    )
    .await;
    let mismatch_decision = decide(
        &ctx,
        &mismatch_request,
        "approved",
        "approval-mismatch-decision",
        future_time(20),
        None,
    )
    .await;
    let mismatch = check(
        &ctx,
        &mismatch_request,
        Some(&mismatch_decision),
        action(),
        json!({"kind": "workspace", "id": "different"}),
        selectors(),
    )
    .await;
    assert_denied(&mismatch, "scope_mismatch");

    let stale_request =
        create_request(&ctx, "approval-stale-request", future_time(30), json!({})).await;
    let stale_decision = decide(
        &ctx,
        &stale_request,
        "approved",
        "approval-stale-decision",
        future_time(20),
        None,
    )
    .await;
    force_request_revision(&ctx, stale_request["requestResourceId"].as_str().unwrap()).await;
    let stale = check(
        &ctx,
        &stale_request,
        Some(&stale_decision),
        action(),
        scope(),
        selectors(),
    )
    .await;
    assert_denied(&stale, "stale");
}

#[tokio::test]
async fn idempotent_decision_replays_without_new_revision_and_stale_revision_conflicts() {
    let ctx = make_test_context();
    let request = create_request(
        &ctx,
        "approval-idempotent-request",
        future_time(30),
        json!({}),
    )
    .await;
    let request_resource_id = request["requestResourceId"].as_str().unwrap();
    let expected_version = request["requestVersionId"].as_str().unwrap();
    let payload = decide_payload(&request, "approved", future_time(20), None);

    let first = invoke_decide(&ctx, payload.clone(), "approval-idempotent-decision").await;
    let second = invoke_decide(&ctx, payload, "approval-idempotent-decision").await;
    assert_eq!(first["decisionResourceId"], second["decisionResourceId"]);
    assert_eq!(first["decisionVersionId"], second["decisionVersionId"]);

    let inspection = ctx
        .engine_host
        .inspect_resource(request_resource_id)
        .await
        .unwrap()
        .expect("request resource");
    assert_eq!(
        inspection.versions.len(),
        2,
        "idempotency replay must not append another request revision"
    );

    let conflict_payload = json!({
        "requestResourceId": request_resource_id,
        "expectedRequestVersionId": expected_version,
        "state": "approved",
        "decisionActor": {"kind": "user", "id": "operator"},
        "expiresAt": future_time(20)
    });
    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(super::DECIDE_FUNCTION).unwrap(),
            conflict_payload,
            client_context("approval-revision-conflict")
                .with_scope(super::WRITE_SCOPE)
                .with_idempotency_key("approval-conflict-decision"),
        ))
        .await;
    assert!(
        conflict
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("revision conflict")),
        "stale revision must fail, got {:?}",
        conflict.error
    );
}

#[tokio::test]
async fn reusable_service_check_returns_stale_for_freshness_timeout() {
    let ctx = make_test_context();
    let request = create_request(
        &ctx,
        "approval-service-stale-request",
        future_time(30),
        json!({"staleAt": past_time(1)}),
    )
    .await;
    let requirement = super::types::ApprovalCheckRequirement {
        request_resource_id: request["requestResourceId"].as_str().unwrap().to_owned(),
        decision_resource_id: None,
        action: action(),
        scope: scope(),
        risk_class: "high".to_owned(),
        resource_selectors: selectors(),
    };

    let result = super::service::check_approval_at(&ctx.engine_host, requirement, test_now())
        .await
        .expect("service check");

    assert_eq!(result.allowed, false);
    assert_eq!(result.outcome, ApprovalCheckOutcome::Stale);
    assert_eq!(result.reason, "approval_request_stale");
}

async fn create_request(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    key: &str,
    expires_at: String,
    freshness: Value,
) -> Value {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(super::REQUEST_FUNCTION).unwrap(),
            json!({
                "action": action(),
                "scope": scope(),
                "riskClass": "high",
                "expiresAt": expires_at,
                "freshness": freshness,
                "evidenceRefs": [{"resourceId": "evidence:approval-test"}],
                "resourceSelectors": selectors(),
                "denialBehavior": {"mode": "fail_closed", "onDenied": "return_denial"}
            }),
            client_context(key)
                .with_scope(super::WRITE_SCOPE)
                .with_idempotency_key(key),
        ))
        .await;
    assert_eq!(result.error, None, "request failed: {:?}", result.error);
    result.value.expect("request value")
}

async fn decide(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    request: &Value,
    state: &str,
    key: &str,
    expires_at: String,
    freshness_until: Option<String>,
) -> Value {
    invoke_decide(
        ctx,
        decide_payload(request, state, expires_at, freshness_until),
        key,
    )
    .await
}

fn decide_payload(
    request: &Value,
    state: &str,
    expires_at: String,
    freshness_until: Option<String>,
) -> Value {
    let mut payload = json!({
        "requestResourceId": request["requestResourceId"],
        "expectedRequestVersionId": request["requestVersionId"],
        "state": state,
        "decisionActor": {"kind": "user", "id": "operator"},
        "expiresAt": expires_at
    });
    if let Some(freshness_until) = freshness_until {
        payload["freshnessUntil"] = json!(freshness_until);
    }
    payload
}

async fn invoke_decide(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    payload: Value,
    key: &str,
) -> Value {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(super::DECIDE_FUNCTION).unwrap(),
            payload,
            client_context(key)
                .with_scope(super::WRITE_SCOPE)
                .with_idempotency_key(key),
        ))
        .await;
    assert_eq!(result.error, None, "decide failed: {:?}", result.error);
    result.value.expect("decision value")
}

async fn check(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    request: &Value,
    decision: Option<&Value>,
    action: Value,
    scope: Value,
    resource_selectors: Vec<Value>,
) -> Value {
    let mut payload = json!({
        "requestResourceId": request["requestResourceId"],
        "action": action,
        "scope": scope,
        "riskClass": "high",
        "resourceSelectors": resource_selectors
    });
    if let Some(decision) = decision {
        payload["decisionResourceId"] = decision["decisionResourceId"].clone();
    }
    invoke_check(ctx, payload).await
}

async fn invoke_check(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    payload: Value,
) -> Value {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(super::CHECK_FUNCTION).unwrap(),
            payload,
            client_context("approval-check").with_scope(super::READ_SCOPE),
        ))
        .await;
    assert_eq!(result.error, None, "check failed: {:?}", result.error);
    result.value.expect("check value")
}

async fn check_wrong_kind_request(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
) -> Value {
    let resource = ctx
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some("approval_test:not_request".to_owned()),
            kind: "artifact".to_owned(),
            schema_id: Some("tron.resource.artifact.v1".to_owned()),
            scope: EngineResourceScope::Session("approval-session".to_owned()),
            owner_worker_id: WorkerId::new("approval").unwrap(),
            owner_actor_id: ActorId::new("approval-test").unwrap(),
            lifecycle: Some("draft".to_owned()),
            policy: json!({}),
            initial_payload: Some(json!({"title": "not approval", "body": "wrong kind"})),
            locations: Vec::new(),
            trace_id: TraceId::new("approval-wrong-kind").unwrap(),
            invocation_id: None,
        })
        .await
        .unwrap();
    invoke_check(
        ctx,
        json!({
            "requestResourceId": resource.resource_id,
            "action": action(),
            "scope": scope(),
            "riskClass": "high",
            "resourceSelectors": selectors()
        }),
    )
    .await
}

async fn force_request_revision(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    request_resource_id: &str,
) {
    let inspection = ctx
        .engine_host
        .inspect_resource(request_resource_id)
        .await
        .unwrap()
        .expect("request resource");
    let version_id = inspection
        .resource
        .current_version_id
        .clone()
        .expect("current version");
    let payload = inspection
        .versions
        .iter()
        .find(|version| version.version_id == version_id)
        .unwrap()
        .payload
        .clone();
    ctx.engine_host
        .update_resource(UpdateResource {
            resource_id: request_resource_id.to_owned(),
            expected_current_version_id: Some(version_id),
            lifecycle: Some("decided".to_owned()),
            payload,
            state: None,
            locations: Vec::new(),
            trace_id: TraceId::new("approval-forced-revision").unwrap(),
            invocation_id: None,
        })
        .await
        .unwrap();
}

fn assert_denied(value: &Value, outcome: &str) {
    assert_eq!(value["allowed"], false, "{value}");
    assert_eq!(value["outcome"], outcome, "{value}");
    assert!(value["explanation"].is_object(), "{value}");
}

fn action() -> Value {
    json!({"kind": "future_tool", "operation": "write_file"})
}

fn scope() -> Value {
    json!({"kind": "workspace", "id": "approval-workspace"})
}

fn selectors() -> Vec<Value> {
    vec![json!({"kind": "resource", "id": "workspace-file:/tmp/example"})]
}

fn future_time(minutes: i64) -> String {
    (future_anchor() + Duration::minutes(minutes)).to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn past_time(minutes: i64) -> String {
    (past_anchor() - Duration::minutes(minutes)).to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn test_now() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 6, 19, 12, 0, 0)
        .single()
        .expect("valid approval test timestamp")
}

fn future_anchor() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2099, 1, 1, 12, 0, 0)
        .single()
        .expect("valid approval future timestamp")
}

fn past_anchor() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2000, 1, 1, 12, 0, 0)
        .single()
        .expect("valid approval past timestamp")
}

fn client_context(trace_id: &str) -> CausalContext {
    CausalContext::new(
        ActorId::new("engine-client").unwrap(),
        ActorKind::Client,
        AuthorityGrantId::new("engine-transport").unwrap(),
        TraceId::new(trace_id).unwrap(),
    )
    .with_session_id("approval-session")
    .with_workspace_id("approval-workspace")
}
