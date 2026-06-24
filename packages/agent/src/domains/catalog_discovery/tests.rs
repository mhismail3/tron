use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EffectClass, FunctionDefinition,
    FunctionId, InProcessFunctionHandler, Invocation, RiskLevel, TraceId, VisibilityScope,
    WorkerDefinition, WorkerId, WorkerKind,
};
use crate::shared::server::test_support::make_test_context;

struct CountingHandler {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl InProcessFunctionHandler for CountingHandler {
    async fn invoke(&self, _invocation: Invocation) -> crate::engine::Result<Value> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(json!({"called": true}))
    }
}

#[tokio::test]
async fn search_omits_protected_function_names_but_reports_counts() {
    let ctx = make_test_context();
    register_demo_function(&ctx, "demo::visible", VisibilityScope::System, None).await;
    register_demo_function(
        &ctx,
        "demo::internal_secret",
        VisibilityScope::Internal,
        None,
    )
    .await;
    register_demo_function(&ctx, "demo::admin_secret", VisibilityScope::Admin, None).await;

    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(super::SEARCH_FUNCTION).unwrap(),
            json!({"namespacePrefix": "demo", "includeProtectedCounts": true}),
            client_context("catalog-discovery-search").with_scope(super::READ_SCOPE),
        ))
        .await;
    assert_eq!(result.error, None, "search failed: {:?}", result.error);
    let value = result.value.expect("search value");
    let serialized = serde_json::to_string(&value).unwrap();

    assert!(serialized.contains("demo::visible"), "{serialized}");
    assert!(
        !serialized.contains("demo::internal_secret"),
        "{serialized}"
    );
    assert!(!serialized.contains("demo::admin_secret"), "{serialized}");
    assert_eq!(value["summary"]["protected"]["functions"]["omitted"], 2);
    assert_eq!(
        value["summary"]["protected"]["functions"]["byVisibility"]["internal"],
        1
    );
    assert_eq!(
        value["summary"]["protected"]["functions"]["byVisibility"]["admin"],
        1
    );
}

#[tokio::test]
async fn inspect_returns_schema_metadata_and_conformance_without_execution() {
    let ctx = make_test_context();
    let calls = Arc::new(AtomicUsize::new(0));
    register_demo_function(
        &ctx,
        "demo::inspectable",
        VisibilityScope::System,
        Some(calls.clone()),
    )
    .await;

    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(super::INSPECT_FUNCTION).unwrap(),
            json!({"kind": "function", "id": "demo::inspectable"}),
            client_context("catalog-discovery-inspect").with_scope(super::READ_SCOPE),
        ))
        .await;
    assert_eq!(result.error, None, "inspect failed: {:?}", result.error);
    let value = result.value.expect("inspect value");

    assert_eq!(value["definition"]["id"], "demo::inspectable");
    assert_eq!(value["schemaHints"]["requestSchemaPresent"], true);
    assert_eq!(value["schemaHints"]["responseSchemaPresent"], true);
    assert_eq!(value["conformance"]["routable"], true);
    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "inspect must not invoke target handlers"
    );
}

#[tokio::test]
async fn conformance_report_writes_resource_stream_event_and_does_not_execute_targets() {
    let ctx = make_test_context();
    let calls = Arc::new(AtomicUsize::new(0));
    register_demo_function(
        &ctx,
        "demo::call_guard",
        VisibilityScope::System,
        Some(calls.clone()),
    )
    .await;
    register_demo_function(&ctx, "demo::hidden_guard", VisibilityScope::Internal, None).await;

    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(super::CONFORMANCE_REPORT_FUNCTION).unwrap(),
            json!({"namespacePrefix": "demo", "reason": "test report"}),
            client_context("catalog-discovery-report")
                .with_scope(super::WRITE_SCOPE)
                .with_idempotency_key("catalog-discovery-report-test"),
        ))
        .await;
    assert_eq!(result.error, None, "report failed: {:?}", result.error);
    let value = result.value.expect("report value");
    let resource_id = value["reportResourceId"].as_str().expect("resource id");

    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "conformance report must not invoke discovered targets"
    );
    assert_eq!(value["status"], "passed");
    assert!(value["streamCursor"].as_u64().unwrap_or_default() > 0);
    assert_eq!(
        value["resourceRefs"][0]["kind"],
        crate::engine::CATALOG_DISCOVERY_REPORT_KIND
    );

    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .unwrap()
        .expect("report resource");
    assert_eq!(
        inspection.resource.kind,
        crate::engine::CATALOG_DISCOVERY_REPORT_KIND
    );
    let payload = &inspection.versions.last().expect("report version").payload;
    let serialized = serde_json::to_string(payload).unwrap();
    assert!(serialized.contains("demo::call_guard"));
    assert!(!serialized.contains("demo::hidden_guard"));
    assert_eq!(payload["protected"]["functions"]["omitted"], 1);
}

#[tokio::test]
async fn inspect_rejects_protected_functions_for_public_clients() {
    let ctx = make_test_context();
    register_demo_function(
        &ctx,
        "demo::hidden_inspect",
        VisibilityScope::Internal,
        None,
    )
    .await;

    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(super::INSPECT_FUNCTION).unwrap(),
            json!({"kind": "function", "id": "demo::hidden_inspect"}),
            client_context("catalog-discovery-hidden-inspect").with_scope(super::READ_SCOPE),
        ))
        .await;

    assert!(
        result
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("not visible")),
        "hidden inspect must fail closed, got: {:?}",
        result.error
    );
}

async fn register_demo_function(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    id: &str,
    visibility: VisibilityScope,
    calls: Option<Arc<AtomicUsize>>,
) {
    let mut worker = WorkerDefinition::new(
        WorkerId::new("demo").unwrap(),
        WorkerKind::InProcess,
        ActorId::new("system:catalog-discovery-test").unwrap(),
        AuthorityGrantId::new("engine-system").unwrap(),
    )
    .with_namespace_claim("demo");
    worker.visibility = VisibilityScope::System;
    let _ = ctx.engine_host.register_worker(worker, true).await;

    let mut function = FunctionDefinition::new(
        FunctionId::new(id).unwrap(),
        WorkerId::new("demo").unwrap(),
        "Demo catalog discovery function",
        visibility,
        EffectClass::PureRead,
    )
    .with_risk(RiskLevel::Low)
    .with_request_schema(json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {}
    }))
    .with_response_schema(json!({
        "type": "object",
        "additionalProperties": true,
        "properties": {}
    }));
    function.metadata = json!({
        "domainWorker": "demo",
        "operationKey": id.rsplit_once("::").map(|(_, operation)| operation).unwrap_or(id),
        "streamTopics": []
    });
    let handler =
        calls.map(|calls| Arc::new(CountingHandler { calls }) as Arc<dyn InProcessFunctionHandler>);
    ctx.engine_host
        .register_function(function, handler, true)
        .await
        .unwrap();
}

fn client_context(trace_id: &str) -> CausalContext {
    CausalContext::new(
        ActorId::new("engine-client").unwrap(),
        ActorKind::Client,
        AuthorityGrantId::new("engine-transport").unwrap(),
        TraceId::new(trace_id).unwrap(),
    )
    .with_session_id("catalog-discovery-session")
    .with_workspace_id("catalog-discovery-workspace")
}
