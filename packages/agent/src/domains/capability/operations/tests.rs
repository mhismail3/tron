use super::*;
use std::sync::Arc;

use crate::domains::session::event_store::AgentTraceListOptions;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, DeriveGrant, FunctionId,
    InvocationId, RiskLevel, TraceId,
};
use crate::shared::server::test_support::make_test_context;

#[test]
fn execute_error_redaction_removes_authority_grant_tokens() {
    let error = CapabilityError::InvalidParams {
        message: "authority grant authority_grant_019f3a requires explicit kind selector"
            .to_owned(),
    };
    let redacted = redact_provider_visible_error(error).to_string();

    assert!(redacted.contains("authority grant <redacted> requires"));
    assert!(!redacted.contains("authority_grant_019f3a"));
}

#[tokio::test]
async fn unsupported_operation_is_persisted_as_a_failed_trace() {
    let ctx = make_test_context();
    let deps = Deps {
        engine_host: ctx.engine_host.clone(),
        event_store: ctx.event_store.clone(),
        session_manager: ctx.session_manager.clone(),
        shutdown_coordinator: ctx.shutdown_coordinator.clone(),
        jobs: crate::domains::jobs::RuntimeState::new(),
        apns_runtime: crate::platform::apns::ApnsRuntime::disabled_for_test(),
    };
    let session_id = "unsupported-operation-trace-session";
    let actor_id = ActorId::new(format!("agent:{session_id}")).expect("actor id");
    let grant_id = ctx
        .engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new("unsupported-operation-grant").unwrap()),
            parent_grant_id: AuthorityGrantId::new("agent-capability-runtime").unwrap(),
            subject_actor_id: Some(actor_id.clone()),
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec!["capability::execute".to_owned()],
            allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
            allowed_authority_scopes: vec!["capability.execute".to_owned()],
            allowed_resource_kinds: Vec::new(),
            resource_selectors: Vec::new(),
            file_roots: vec!["/tmp".to_owned()],
            network_policy: "none".to_owned(),
            max_risk: RiskLevel::Medium,
            budget: json!({"remainingInvocations": 1}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"operation": "guessed_operation"}),
            trace_id: TraceId::new("unsupported-operation-grant-trace").unwrap(),
        })
        .await
        .expect("derive rejection grant")
        .grant_id;
    let invocation = Invocation {
        id: InvocationId::new("unsupported-operation-invocation").expect("invocation id"),
        function_id: FunctionId::new("capability::execute").expect("function id"),
        delivery_mode: DeliveryMode::Sync,
        payload: json!({
            "operation": "guessed_operation",
            "unsafePayload": "sensitive-fixture-value"
        }),
        causal_context: CausalContext::new(
            actor_id,
            ActorKind::Agent,
            grant_id,
            TraceId::new("unsupported-operation-trace").expect("trace id"),
        )
        .with_session_id(session_id),
    };

    let error = execute_value(&invocation, &deps)
        .await
        .expect_err("unsupported operation must fail");
    assert!(error.to_string().contains("catalog_search"));

    let records = ctx
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: Some(session_id),
            trace_id: None,
            operation: None,
            status: None,
            limit: Some(10),
        })
        .expect("list failed validation trace");
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].operation, "guessed_operation");
    assert_eq!(records[0].status, "failed");
    assert!(records[0].completed_at.is_some());
    assert_eq!(
        records[0].record_json["metadata"]["dev.tron"]["rawRequestStored"],
        false
    );
    assert!(
        !records[0]
            .record_json
            .to_string()
            .contains("sensitive-fixture-value")
    );

    let filtered = ctx
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: Some(session_id),
            trace_id: None,
            operation: Some("guessed_operation"),
            status: Some("failed"),
            limit: Some(10),
        })
        .expect("filter failed validation trace");
    assert_eq!(filtered.len(), 1);
    let excluded = ctx
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: Some(session_id),
            trace_id: None,
            operation: Some("guessed_operation"),
            status: Some("ok"),
            limit: Some(10),
        })
        .expect("filter nonmatching validation trace");
    assert!(excluded.is_empty());
}

#[tokio::test]
async fn cancellation_terminalizes_the_running_trace_before_returning() {
    let ctx = make_test_context();
    let event_store = Arc::clone(&ctx.event_store);
    let deps = Deps {
        engine_host: ctx.engine_host,
        event_store: Arc::clone(&event_store),
        session_manager: ctx.session_manager,
        shutdown_coordinator: ctx.shutdown_coordinator,
        jobs: crate::domains::jobs::RuntimeState::new(),
        apns_runtime: crate::platform::apns::ApnsRuntime::disabled_for_test(),
    };
    let session_id = "cancelled-operation-trace-session";
    let invocation = Invocation {
        id: InvocationId::new("cancelled-operation-invocation").expect("invocation id"),
        function_id: FunctionId::new("capability::execute").expect("function id"),
        delivery_mode: DeliveryMode::Sync,
        payload: json!({"operation": "catalog_search", "text": "pending"}),
        causal_context: CausalContext::new(
            ActorId::new(format!("agent:{session_id}")).expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("cancelled-operation-grant").expect("grant id"),
            TraceId::new("cancelled-operation-trace").expect("trace id"),
        )
        .with_session_id(session_id),
    };
    let cancellation = CancellationToken::new();
    let task_cancellation = cancellation.clone();
    let running = tokio::spawn(async move {
        execute_traced_operation(
            &invocation,
            &deps,
            "catalog_search",
            Utc::now(),
            std::future::pending::<Result<CapabilityResult, CapabilityError>>(),
            Some(&task_cancellation),
        )
        .await
    });

    let running_record = loop {
        let records = event_store
            .list_trace_records(&AgentTraceListOptions {
                session_id: Some(session_id),
                trace_id: None,
                operation: None,
                status: Some("running"),
                limit: Some(10),
            })
            .expect("list running trace");
        if let Some(record) = records.into_iter().next() {
            break record;
        }
        tokio::task::yield_now().await;
    };
    assert!(running_record.completed_at.is_none());

    cancellation.cancel();
    assert!(matches!(
        running.await.expect("join cancellation task"),
        Err(error) if error.code() == RUNTIME_CANCELLED
    ));
    let record = event_store
        .get_trace_record(&running_record.id)
        .expect("get cancelled trace")
        .expect("cancelled trace exists");
    assert_eq!(record.status, "failed");
    assert!(record.completed_at.is_some());
    assert_eq!(
        record.record_json["metadata"]["dev.tron"]["result"]["details"]["status"],
        "cancelled"
    );
    assert_eq!(
        record.record_json["metadata"]["dev.tron"]["error"],
        "Operation cancelled"
    );
}
