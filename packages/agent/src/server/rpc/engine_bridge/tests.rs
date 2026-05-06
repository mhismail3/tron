use std::collections::BTreeSet;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::*;
use crate::engine::{ActorKind, DeliveryMode, EffectClass, Invocation, RiskLevel, VisibilityScope};
use crate::server::rpc::handlers;
use crate::server::rpc::handlers::test_helpers::make_test_context;
use crate::server::rpc::registry::{MethodHandler, MethodRegistry};
use crate::server::rpc::types::RpcRequest;

const GENERIC_READ_METHODS: &[&str] = &[
    "system.ping",
    "system.getInfo",
    "settings.get",
    "model.list",
    "skill.list",
    "logs.recent",
    "events.getHistory",
    "events.getSince",
    "filesystem.getHome",
    "promptHistory.list",
    "promptSnippet.list",
    "promptSnippet.get",
];

async fn direct_engine_value(ctx: &RpcContext, method: &'static str, params: Value) -> Value {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: format!("direct-{method}"),
        method: method.to_owned(),
        params: Some(params),
    };
    let envelope = RpcEngineInvocation::from_request(&registry, ctx, &request)
        .unwrap()
        .unwrap();
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            envelope.function_id,
            envelope.params_payload,
            envelope.causal_context,
        ))
        .await;
    assert!(result.error.is_none(), "{method}: {:?}", result.error);
    result.value.unwrap()
}

async fn rpc_dispatch_value(ctx: &RpcContext, method: &str, params: Value) -> Value {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let response = registry
        .dispatch(
            RpcRequest {
                id: format!("test-{method}"),
                method: method.to_owned(),
                params: Some(params),
            },
            ctx,
        )
        .await;
    assert!(response.success, "{method}: {:?}", response.error);
    response.result.unwrap()
}

fn normalize_unstable_fields(method: &str, mut value: Value) -> Value {
    if method == "system.ping" {
        value["timestamp"] = json!("<timestamp>");
    }
    if method == "system.getInfo" {
        value["uptime"] = json!(0);
    }
    value
}

#[test]
fn bridge_specs_cover_every_registered_rpc_method() {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let specs = capability_specs(&registry).unwrap();
    assert_eq!(registry.methods().len(), 167);
    assert_eq!(specs.len(), registry.methods().len());

    let spec_methods = specs
        .iter()
        .map(|spec| spec.method.to_owned())
        .collect::<BTreeSet<_>>();
    let registry_methods = registry.methods().into_iter().collect::<BTreeSet<_>>();
    assert_eq!(spec_methods, registry_methods);
}

#[test]
fn bridge_specs_classify_selected_reads_as_generic_triggers() {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let specs = capability_specs(&registry).unwrap();
    for method in GENERIC_READ_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert_eq!(spec.migration_state, RpcMigrationState::GenericTrigger);
        assert_eq!(spec.execution_policy, RpcExecutionPolicy::GenericTrigger);
        assert_eq!(spec.effect_class, EffectClass::PureRead);
        assert_eq!(spec.schema_mode, RpcSchemaMode::StrictJson);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.authority_scope, Some(RPC_READ_AUTHORITY));
        assert!(
            super::schemas::request_schema_for_method(method).is_some(),
            "{method} must declare a request schema"
        );
        assert!(
            super::schemas::response_schema_for_method(method).is_some(),
            "{method} must declare a response schema"
        );
    }
}

#[test]
fn bridge_specs_classify_representative_effect_and_risk_levels() {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let specs = capability_specs(&registry).unwrap();
    let find = |method: &str| specs.iter().find(|spec| spec.method == method).unwrap();

    let session_list = find("session.list");
    assert_eq!(session_list.effect_class, EffectClass::PureRead);
    assert_eq!(session_list.risk_level, RiskLevel::Low);

    let settings_update = find("settings.update");
    assert_eq!(settings_update.effect_class, EffectClass::IdempotentWrite);
    assert_eq!(settings_update.risk_level, RiskLevel::Medium);

    let events_append = find("events.append");
    assert_eq!(events_append.effect_class, EffectClass::AppendOnlyEvent);
    assert_eq!(events_append.risk_level, RiskLevel::Medium);

    let message_delete = find("message.delete");
    assert_eq!(
        message_delete.effect_class,
        EffectClass::IrreversibleSideEffect
    );
    assert_eq!(message_delete.risk_level, RiskLevel::High);

    let system_shutdown = find("system.shutdown");
    assert_eq!(
        system_shutdown.effect_class,
        EffectClass::IrreversibleSideEffect
    );
    assert_eq!(system_shutdown.risk_level, RiskLevel::Critical);

    let git_push = find("git.push");
    assert_eq!(git_push.effect_class, EffectClass::ExternalSideEffect);
    assert_eq!(git_push.risk_level, RiskLevel::Critical);
}

#[test]
fn bridge_specs_fail_closed_for_unclassified_registry_methods() {
    struct Echo;

    #[async_trait]
    impl MethodHandler for Echo {
        async fn handle(
            &self,
            _params: Option<Value>,
            _ctx: &RpcContext,
        ) -> Result<Value, RpcError> {
            Ok(Value::Null)
        }
    }

    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    registry.register("new.method", Echo);
    let err = capability_specs(&registry).unwrap_err();
    assert!(matches!(
        err,
        EngineError::PolicyViolation(message)
            if message.contains("new.method") && message.contains("without an engine bridge spec")
    ));
}

#[test]
fn rpc_engine_invocation_preserves_transport_metadata() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "req-123".to_owned(),
        method: "events.getHistory".to_owned(),
        params: Some(json!({"sessionId": "session-a", "workspaceId": "workspace-a", "limit": 5})),
    };
    let envelope = RpcEngineInvocation::from_request(&registry, &ctx, &request)
        .unwrap()
        .unwrap();
    assert_eq!(envelope.request_id, "req-123");
    assert_eq!(envelope.method, "events.getHistory");
    assert_eq!(envelope.params_payload["limit"], 5);
    assert_eq!(
        envelope.function_id,
        specs::function_id_for_method("events.getHistory").unwrap()
    );
    assert_eq!(envelope.causal_context.actor_id.as_str(), "rpc-client");
    assert_eq!(
        envelope.causal_context.authority_grant_id.as_str(),
        RPC_AUTHORITY_GRANT
    );
    assert!(envelope.causal_context.has_scope(RPC_READ_AUTHORITY));
    assert_eq!(
        envelope.causal_context.session_id.as_deref(),
        Some("session-a")
    );
    assert_eq!(
        envelope.causal_context.workspace_id.as_deref(),
        Some("workspace-a")
    );
    assert!(!envelope.causal_context.trace_id.as_str().is_empty());
}

#[test]
fn rpc_engine_invocation_defaults_missing_params_to_empty_object() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "req-empty".to_owned(),
        method: "settings.get".to_owned(),
        params: None,
    };
    let envelope = RpcEngineInvocation::from_request(&registry, &ctx, &request)
        .unwrap()
        .unwrap();
    assert_eq!(envelope.params_payload, json!({}));
}

#[test]
fn handler_only_methods_do_not_build_generic_envelopes() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "req-handler".to_owned(),
        method: "session.list".to_owned(),
        params: Some(json!({})),
    };
    assert!(
        RpcEngineInvocation::from_request(&registry, &ctx, &request)
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn handler_only_engine_functions_are_not_client_routable() {
    let ctx = make_test_context();
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            specs::function_id_for_method("session.list").unwrap(),
            json!({}),
            super::dispatch::rpc_causal_context(),
        ))
        .await;
    assert!(
        result.error.is_some(),
        "handler-only bridge functions must stay non-routable through engine invocation"
    );
}

#[tokio::test]
async fn generic_trigger_bypasses_marker_handlers() {
    let ctx = make_test_context();
    let result = rpc_dispatch_value(&ctx, "system.ping", json!({"protocolVersion": 1})).await;
    assert_eq!(result["pong"], true);

    let err = RpcGenericTriggerHandler::new("system.ping")
        .handle(None, &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), errors::INTERNAL_ERROR);
    assert!(err.to_string().contains("registry interception failed"));
}

#[tokio::test]
async fn generic_trigger_engine_errors_keep_rpc_error_shape() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let response = registry
        .dispatch(
            RpcRequest {
                id: "bad-ping".to_owned(),
                method: "system.ping".to_owned(),
                params: Some(json!({})),
            },
            &ctx,
        )
        .await;
    assert!(!response.success);
    let error = response.error.unwrap();
    assert_eq!(error.code, errors::INVALID_PARAMS);
    assert!(error.message.contains("required field"));
}

#[tokio::test]
async fn generic_trigger_strict_request_schemas_reject_unknown_fields() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let response = registry
        .dispatch(
            RpcRequest {
                id: "bad-settings".to_owned(),
                method: "settings.get".to_owned(),
                params: Some(json!({"unexpected": true})),
            },
            &ctx,
        )
        .await;
    assert!(!response.success);
    let error = response.error.unwrap();
    assert_eq!(error.code, errors::INVALID_PARAMS);
    assert!(error.message.contains("additional property"));
}

#[tokio::test]
async fn generic_rpc_outputs_match_direct_engine_outputs() {
    let ctx = make_test_context();
    let cases = [
        ("system.ping", json!({"protocolVersion": 1})),
        ("system.getInfo", json!({})),
        ("settings.get", json!({})),
        ("model.list", json!({})),
        ("skill.list", json!({})),
        ("logs.recent", json!({})),
        ("filesystem.getHome", json!({})),
        ("promptHistory.list", json!({})),
        ("promptSnippet.list", json!({})),
    ];

    for (method, payload) in cases {
        let direct = normalize_unstable_fields(
            method,
            direct_engine_value(&ctx, method, payload.clone()).await,
        );
        let rpc =
            normalize_unstable_fields(method, rpc_dispatch_value(&ctx, method, payload).await);
        assert_eq!(direct, rpc, "{method}");
    }
}

#[tokio::test]
async fn generic_rpc_outputs_match_direct_engine_outputs_for_stateful_reads() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("stateful"), None)
        .unwrap();
    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let snippet =
        crate::prompt_library::store::create_snippet(ctx.event_store.pool(), "n", "t").unwrap();

    let cases = [
        ("events.getHistory", json!({"sessionId": session_id})),
        (
            "events.getSince",
            json!({"sessionId": session_id, "afterSequence": 0}),
        ),
        ("promptSnippet.get", json!({"id": snippet.id})),
    ];

    for (method, payload) in cases {
        let direct = direct_engine_value(&ctx, method, payload.clone()).await;
        let rpc = rpc_dispatch_value(&ctx, method, payload).await;
        assert_eq!(direct, rpc, "{method}");
    }
}

#[tokio::test]
async fn handler_only_methods_pass_through_current_handlers() {
    let ctx = make_test_context();
    let result = rpc_dispatch_value(&ctx, "session.list", json!({})).await;
    assert!(result["sessions"].is_array());
}

#[tokio::test]
async fn custom_unclassified_methods_are_not_intercepted_by_generic_dispatch() {
    struct Echo;

    #[async_trait]
    impl MethodHandler for Echo {
        async fn handle(
            &self,
            params: Option<Value>,
            _ctx: &RpcContext,
        ) -> Result<Value, RpcError> {
            Ok(params.unwrap_or(Value::Null))
        }
    }

    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    registry.register("custom.echo", Echo);
    let response = registry
        .dispatch(
            RpcRequest {
                id: "echo".to_owned(),
                method: "custom.echo".to_owned(),
                params: Some(json!({"ok": true})),
            },
            &ctx,
        )
        .await;
    assert!(response.success, "{:?}", response.error);
    assert_eq!(response.result.unwrap(), json!({"ok": true}));
}

#[tokio::test]
async fn generic_trigger_records_invocation_ledger_metadata() {
    let ctx = make_test_context();
    let _ = rpc_dispatch_value(&ctx, "system.ping", json!({"protocolVersion": 1})).await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("system.ping").unwrap()
    );
    assert_eq!(record.worker_id, specs::worker_id(RPC_WORKER_ID).unwrap());
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert!(
        record
            .authority_scopes
            .contains(&RPC_READ_AUTHORITY.to_owned())
    );
}
