use std::collections::BTreeSet;
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::*;
use crate::engine::{
    ActorKind, DeliveryMode, EffectClass, EngineError, Invocation, RiskLevel, VisibilityScope,
};
use crate::server::codex_app::{
    CodexAppServerChild, CodexAppServerExit, CodexAppServerLaunchSpec, CodexAppServerManager,
    CodexAppServerSpawner, CodexAppServerState,
};
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

const GENERIC_WRITE_METHODS: &[&str] = &[
    "settings.update",
    "settings.resetToDefaults",
    "promptHistory.delete",
    "promptHistory.clear",
    "promptSnippet.create",
    "promptSnippet.update",
    "promptSnippet.delete",
];

const SETTINGS_METHODS: &[&str] = &[
    "settings.get",
    "settings.update",
    "settings.resetToDefaults",
];

const PROMPT_LIBRARY_METHODS: &[&str] = &[
    "promptHistory.list",
    "promptHistory.delete",
    "promptHistory.clear",
    "promptSnippet.list",
    "promptSnippet.get",
    "promptSnippet.create",
    "promptSnippet.update",
    "promptSnippet.delete",
];

struct SettingsTestGuard {
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl Drop for SettingsTestGuard {
    fn drop(&mut self) {
        crate::settings::init_settings(crate::settings::TronSettings::default());
    }
}

fn settings_test_guard() -> SettingsTestGuard {
    let guard = crate::settings::test_settings_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    crate::settings::init_settings(crate::settings::TronSettings::default());
    SettingsTestGuard { _guard: guard }
}

#[derive(Default)]
struct SettingsFakeSpawner {
    specs: Mutex<Vec<CodexAppServerLaunchSpec>>,
}

#[async_trait]
impl CodexAppServerSpawner for SettingsFakeSpawner {
    async fn spawn(
        &self,
        spec: CodexAppServerLaunchSpec,
    ) -> io::Result<Box<dyn CodexAppServerChild>> {
        self.specs.lock().unwrap().push(spec);
        Ok(Box::new(SettingsFakeChild))
    }
}

struct SettingsFakeChild;

#[async_trait]
impl CodexAppServerChild for SettingsFakeChild {
    fn id(&self) -> Option<u32> {
        Some(456)
    }

    fn try_wait(&mut self) -> io::Result<Option<CodexAppServerExit>> {
        Ok(None)
    }

    async fn terminate(&mut self, _timeout: Duration) -> io::Result<()> {
        Ok(())
    }
}

fn attach_codex_manager(
    ctx: &mut crate::server::rpc::context::RpcContext,
    token_dir: &tempfile::TempDir,
) -> (Arc<CodexAppServerManager>, Arc<SettingsFakeSpawner>) {
    let spawner = Arc::new(SettingsFakeSpawner::default());
    let manager = Arc::new(
        CodexAppServerManager::with_deps(
            crate::settings::CodexAppServerSettings::default(),
            token_dir.path().join("codex-token"),
            spawner.clone(),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap(),
    );
    ctx.codex_app_server = Some(manager.clone());
    (manager, spawner)
}

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
fn bridge_specs_classify_generic_writes_as_generic_triggers() {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let specs = capability_specs(&registry).unwrap();
    for method in GENERIC_WRITE_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert_eq!(spec.migration_state, RpcMigrationState::GenericTrigger);
        assert_eq!(spec.execution_policy, RpcExecutionPolicy::GenericTrigger);
        assert!(spec.effect_class.is_mutating());
        assert_eq!(spec.schema_mode, RpcSchemaMode::StrictJson);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.authority_scope, Some(RPC_WRITE_AUTHORITY));
        assert_eq!(
            spec.idempotency_mode,
            RpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        assert!(
            super::schemas::request_schema_for_method(method).is_some(),
            "{method} must declare a request schema"
        );
        assert!(
            super::schemas::response_schema_for_method(method).is_some(),
            "{method} must declare a response schema"
        );
    }

    let delete = specs
        .iter()
        .find(|spec| spec.method == "promptSnippet.delete")
        .unwrap();
    assert_eq!(delete.effect_class, EffectClass::IrreversibleSideEffect);
    let definition = specs::function_definition_for_spec(delete);
    assert!(definition.required_authority.approval_required);
}

#[test]
fn bridge_specs_classify_prompt_library_as_fully_generic_triggered() {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let specs = capability_specs(&registry).unwrap();

    for method in PROMPT_LIBRARY_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert_eq!(spec.migration_state, RpcMigrationState::GenericTrigger);
        assert_eq!(spec.execution_policy, RpcExecutionPolicy::GenericTrigger);
        assert_eq!(spec.schema_mode, RpcSchemaMode::StrictJson);
        assert!(
            registry.is_generic_trigger_marker(method),
            "{method} must be marker-registered, not method-specific business logic"
        );
    }
}

#[test]
fn bridge_specs_classify_prompt_history_writes_as_guarded_irreversible_triggers() {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let specs = capability_specs(&registry).unwrap();
    for method in ["promptHistory.delete", "promptHistory.clear"] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert_eq!(spec.effect_class, EffectClass::IrreversibleSideEffect);
        assert_eq!(spec.risk_level, RiskLevel::High);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.authority_scope, Some(RPC_WRITE_AUTHORITY));
        assert_eq!(
            spec.idempotency_mode,
            RpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        assert!(super::schemas::request_schema_for_method(method).is_some());
        assert!(super::schemas::response_schema_for_method(method).is_some());
        let definition = specs::function_definition_for_spec(spec);
        assert!(definition.required_authority.approval_required);
    }
}

#[test]
fn bridge_specs_classify_settings_as_fully_generic_triggered() {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let specs = capability_specs(&registry).unwrap();

    for method in SETTINGS_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert_eq!(spec.migration_state, RpcMigrationState::GenericTrigger);
        assert_eq!(spec.execution_policy, RpcExecutionPolicy::GenericTrigger);
        assert_eq!(spec.schema_mode, RpcSchemaMode::StrictJson);
        assert!(
            registry.is_generic_trigger_marker(method),
            "{method} must be marker-registered, not method-specific business logic"
        );
    }
}

#[test]
fn bridge_specs_classify_settings_writes_as_guarded_reversible_triggers() {
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let specs = capability_specs(&registry).unwrap();
    for method in ["settings.update", "settings.resetToDefaults"] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert_eq!(spec.effect_class, EffectClass::ReversibleSideEffect);
        assert_eq!(spec.risk_level, RiskLevel::High);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.authority_scope, Some(RPC_WRITE_AUTHORITY));
        assert_eq!(
            spec.idempotency_mode,
            RpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        assert!(super::schemas::request_schema_for_method(method).is_some());
        assert!(super::schemas::response_schema_for_method(method).is_some());
        let definition = specs::function_definition_for_spec(spec);
        assert!(definition.required_authority.approval_required);
        assert_eq!(
            definition
                .idempotency
                .as_ref()
                .map(|contract| contract.dedupe_scope.clone()),
            Some(VisibilityScope::System)
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
    assert_eq!(
        settings_update.effect_class,
        EffectClass::ReversibleSideEffect
    );
    assert_eq!(settings_update.risk_level, RiskLevel::High);

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
fn rpc_engine_invocation_derives_write_authority_and_idempotency_key() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let payload = json!({"name": "Greeting", "text": "Hello!"});
    let request = RpcRequest {
        id: "write-1".to_owned(),
        method: "promptSnippet.create".to_owned(),
        params: Some(payload.clone()),
    };
    let first = RpcEngineInvocation::from_request(&registry, &ctx, &request)
        .unwrap()
        .unwrap();
    let second = RpcEngineInvocation::from_request(&registry, &ctx, &request)
        .unwrap()
        .unwrap();

    assert!(first.causal_context.has_scope(RPC_WRITE_AUTHORITY));
    assert!(!first.causal_context.has_scope(RPC_READ_AUTHORITY));
    assert_eq!(
        first.causal_context.idempotency_key,
        second.causal_context.idempotency_key
    );
    assert!(
        first
            .causal_context
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );

    let changed = RpcEngineInvocation::from_request(
        &registry,
        &ctx,
        &RpcRequest {
            id: "write-1".to_owned(),
            method: "promptSnippet.create".to_owned(),
            params: Some(json!({"name": "Greeting 2", "text": "Hello!"})),
        },
    )
    .unwrap()
    .unwrap();
    assert_ne!(
        first.causal_context.idempotency_key,
        changed.causal_context.idempotency_key
    );
    assert_eq!(first.params_payload, payload);
}

#[test]
fn rpc_engine_invocation_rejects_empty_write_request_id() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let err = RpcEngineInvocation::from_request(
        &registry,
        &ctx,
        &RpcRequest {
            id: String::new(),
            method: "promptSnippet.create".to_owned(),
            params: Some(json!({"name": "n", "text": "t"})),
        },
    )
    .unwrap_err();
    assert_eq!(err.code(), errors::INVALID_PARAMS);
    assert!(err.to_string().contains("request id"));
}

#[test]
fn rpc_engine_invocation_rejects_empty_prompt_history_write_request_id() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let err = RpcEngineInvocation::from_request(
        &registry,
        &ctx,
        &RpcRequest {
            id: " ".to_owned(),
            method: "promptHistory.delete".to_owned(),
            params: Some(json!({"id": "history-1"})),
        },
    )
    .unwrap_err();
    assert_eq!(err.code(), errors::INVALID_PARAMS);
    assert!(err.to_string().contains("request id"));
}

#[test]
fn rpc_engine_invocation_rejects_empty_settings_write_request_id() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let err = RpcEngineInvocation::from_request(
        &registry,
        &ctx,
        &RpcRequest {
            id: " ".to_owned(),
            method: "settings.update".to_owned(),
            params: Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
        },
    )
    .unwrap_err();
    assert_eq!(err.code(), errors::INVALID_PARAMS);
    assert!(err.to_string().contains("request id"));
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
async fn settings_outputs_match_direct_engine_outputs() {
    let _guard = settings_test_guard();

    let get_ctx = make_test_context();
    let get_direct = direct_engine_value(&get_ctx, "settings.get", json!({})).await;
    let get_rpc = rpc_dispatch_value(&get_ctx, "settings.get", json!({})).await;
    assert_eq!(get_direct, get_rpc);

    let update_ctx = make_test_context();
    let update_direct = direct_engine_value(
        &update_ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    assert_eq!(update_direct, json!({"success": true}));

    let update_rpc_ctx = make_test_context();
    let update_rpc = rpc_dispatch_value(
        &update_rpc_ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    assert_eq!(update_direct, update_rpc);

    let reset_ctx = make_test_context();
    let _ = direct_engine_value(
        &reset_ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    let reset_direct = direct_engine_value(&reset_ctx, "settings.resetToDefaults", json!({})).await;
    assert_eq!(reset_direct["server"]["heartbeatIntervalMs"], 30_000);

    let reset_rpc_ctx = make_test_context();
    let _ = rpc_dispatch_value(
        &reset_rpc_ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    let reset_rpc = rpc_dispatch_value(&reset_rpc_ctx, "settings.resetToDefaults", json!({})).await;
    assert_eq!(reset_direct, reset_rpc);
}

#[tokio::test]
async fn prompt_snippet_write_outputs_match_direct_engine_outputs() {
    let ctx = make_test_context();

    let create_direct = direct_engine_value(
        &ctx,
        "promptSnippet.create",
        json!({"name": "direct", "text": "body"}),
    )
    .await;
    assert_eq!(create_direct["snippet"]["name"], "direct");

    let create_rpc = rpc_dispatch_value(
        &ctx,
        "promptSnippet.create",
        json!({"name": "rpc", "text": "body"}),
    )
    .await;
    assert_eq!(create_rpc["snippet"]["name"], "rpc");

    let created_id = create_rpc["snippet"]["id"].as_str().unwrap().to_owned();
    let update_direct = direct_engine_value(
        &ctx,
        "promptSnippet.update",
        json!({"id": created_id, "name": "renamed"}),
    )
    .await;
    assert_eq!(update_direct["snippet"]["name"], "renamed");

    let delete_direct = direct_engine_value(
        &ctx,
        "promptSnippet.delete",
        json!({"id": update_direct["snippet"]["id"].as_str().unwrap()}),
    )
    .await;
    assert_eq!(delete_direct, json!({"deleted": true}));
}

#[tokio::test]
async fn prompt_history_write_outputs_match_direct_engine_outputs() {
    let direct_delete_ctx = make_test_context();
    let direct_delete_pool = direct_delete_ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(direct_delete_pool, "delete me").unwrap();
    let direct_delete_page =
        crate::prompt_library::store::list_history(direct_delete_pool, 10, None, None).unwrap();
    let delete_direct = direct_engine_value(
        &direct_delete_ctx,
        "promptHistory.delete",
        json!({"id": direct_delete_page.items[0].id}),
    )
    .await;
    assert_eq!(delete_direct, json!({"deleted": true}));

    let rpc_delete_ctx = make_test_context();
    let rpc_delete_pool = rpc_delete_ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(rpc_delete_pool, "delete me").unwrap();
    let rpc_delete_page =
        crate::prompt_library::store::list_history(rpc_delete_pool, 10, None, None).unwrap();
    let delete_rpc = rpc_dispatch_value(
        &rpc_delete_ctx,
        "promptHistory.delete",
        json!({"id": rpc_delete_page.items[0].id}),
    )
    .await;
    assert_eq!(delete_direct, delete_rpc);

    let direct_clear_ctx = make_test_context();
    let direct_clear_pool = direct_clear_ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(direct_clear_pool, "clear a").unwrap();
    crate::prompt_library::store::record_prompt(direct_clear_pool, "clear b").unwrap();
    let clear_direct =
        direct_engine_value(&direct_clear_ctx, "promptHistory.clear", json!({})).await;
    assert_eq!(clear_direct, json!({"deletedCount": 2}));

    let rpc_clear_ctx = make_test_context();
    let rpc_clear_pool = rpc_clear_ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(rpc_clear_pool, "clear a").unwrap();
    crate::prompt_library::store::record_prompt(rpc_clear_pool, "clear b").unwrap();
    let clear_rpc = rpc_dispatch_value(&rpc_clear_ctx, "promptHistory.clear", json!({})).await;
    assert_eq!(clear_rpc, json!({"deletedCount": 2}));
    assert_eq!(clear_direct, clear_rpc);
}

#[tokio::test]
async fn prompt_history_delete_missing_target_returns_false() {
    let ctx = make_test_context();
    let value = rpc_dispatch_value(
        &ctx,
        "promptHistory.delete",
        json!({"id": "missing-history-id"}),
    )
    .await;
    assert_eq!(value, json!({"deleted": false}));
}

#[tokio::test]
async fn prompt_snippet_write_duplicate_transport_replays_without_rerun() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "snippet-create-retry".to_owned(),
        method: "promptSnippet.create".to_owned(),
        params: Some(json!({"name": "retry", "text": "body"})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);

    let snippets = crate::prompt_library::store::list_snippets(ctx.event_store.pool()).unwrap();
    assert_eq!(snippets.len(), 1);

    let host = ctx.engine_host.lock().await;
    let records = host.catalog().invocations();
    let replay = records.last().unwrap();
    assert!(replay.replayed_from.is_some());
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
}

#[tokio::test]
async fn prompt_snippet_reused_request_id_with_different_payload_is_distinct_command() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);

    for name in ["first", "second"] {
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "reused-id".to_owned(),
                    method: "promptSnippet.create".to_owned(),
                    params: Some(json!({"name": name, "text": "body"})),
                },
                &ctx,
            )
            .await;
        assert!(response.success, "{:?}", response.error);
    }

    let snippets = crate::prompt_library::store::list_snippets(ctx.event_store.pool()).unwrap();
    assert_eq!(snippets.len(), 2);
}

#[tokio::test]
async fn prompt_snippet_update_duplicate_transport_replays_without_second_mutation() {
    let ctx = make_test_context();
    let snippet =
        crate::prompt_library::store::create_snippet(ctx.event_store.pool(), "original", "body")
            .unwrap();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "update-retry".to_owned(),
        method: "promptSnippet.update".to_owned(),
        params: Some(json!({"id": snippet.id, "name": "renamed"})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert_eq!(first.result.as_ref().unwrap()["snippet"]["name"], "renamed");

    crate::prompt_library::store::update_snippet(
        ctx.event_store.pool(),
        first.result.as_ref().unwrap()["snippet"]["id"]
            .as_str()
            .unwrap(),
        Some("outside-change".to_owned()),
        None,
    )
    .unwrap();

    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(second.result, first.result);

    let stored = crate::prompt_library::store::get_snippet(
        ctx.event_store.pool(),
        first.result.as_ref().unwrap()["snippet"]["id"]
            .as_str()
            .unwrap(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(stored.name, "outside-change");
}

#[tokio::test]
async fn prompt_snippet_delete_duplicate_transport_replays_true() {
    let ctx = make_test_context();
    let snippet =
        crate::prompt_library::store::create_snippet(ctx.event_store.pool(), "delete", "body")
            .unwrap();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "delete-retry".to_owned(),
        method: "promptSnippet.delete".to_owned(),
        params: Some(json!({"id": snippet.id})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert_eq!(first.result.unwrap(), json!({"deleted": true}));
    assert_eq!(second.result.unwrap(), json!({"deleted": true}));
}

#[tokio::test]
async fn prompt_snippet_write_errors_complete_idempotency_and_replay() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "invalid-create-retry".to_owned(),
        method: "promptSnippet.create".to_owned(),
        params: Some(json!({"name": "   ", "text": "body"})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert!(!first.success);
    assert!(!second.success);
    assert_eq!(first.error.as_ref().unwrap().code, errors::INVALID_PARAMS);
    assert_eq!(second.error.as_ref().unwrap().code, errors::INVALID_PARAMS);
    assert_eq!(
        first.error.as_ref().unwrap().message,
        second.error.as_ref().unwrap().message
    );

    let host = ctx.engine_host.lock().await;
    let records = host.catalog().invocations();
    let replay = records.last().unwrap();
    let original = records
        .iter()
        .find(|record| Some(record.invocation_id.clone()) == replay.replayed_from)
        .unwrap();
    assert!(!original.succeeded);
    assert!(original.error.is_some());
    assert!(!replay.succeeded);
    assert!(replay.error.is_some());
    assert_eq!(original.idempotency_key, replay.idempotency_key);
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
}

#[tokio::test]
async fn prompt_history_delete_duplicate_transport_replays_without_second_delete() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "delete retry").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let id = page.items[0].id.clone();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "history-delete-retry".to_owned(),
        method: "promptHistory.delete".to_owned(),
        params: Some(json!({"id": id})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert_eq!(first.result.unwrap(), json!({"deleted": true}));
    assert_eq!(second.result.unwrap(), json!({"deleted": true}));
}

#[tokio::test]
async fn prompt_history_clear_duplicate_transport_replays_original_count() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "first").unwrap();
    crate::prompt_library::store::record_prompt(pool, "second").unwrap();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    let request = RpcRequest {
        id: "history-clear-retry".to_owned(),
        method: "promptHistory.clear".to_owned(),
        params: Some(json!({})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    assert_eq!(first.result.as_ref().unwrap(), &json!({"deletedCount": 2}));
    crate::prompt_library::store::record_prompt(pool, "after first clear").unwrap();

    let second = registry.dispatch(request, &ctx).await;
    assert_eq!(second.result.as_ref().unwrap(), &json!({"deletedCount": 2}));
    let host = ctx.engine_host.lock().await;
    let replay = host.catalog().invocations().last().unwrap();
    assert!(replay.replayed_from.is_some());
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );

    let remaining = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    assert_eq!(remaining.items.len(), 1);
    assert_eq!(remaining.items[0].text, "after first clear");
}

#[tokio::test]
async fn prompt_history_reused_request_id_with_different_payload_is_distinct_command() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "first").unwrap();
    crate::prompt_library::store::record_prompt(pool, "second").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);

    for item in page.items.iter().take(2) {
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "same-history-request-id".to_owned(),
                    method: "promptHistory.delete".to_owned(),
                    params: Some(json!({"id": item.id})),
                },
                &ctx,
            )
            .await;
        assert!(response.success, "{:?}", response.error);
        assert_eq!(response.result.as_ref().unwrap(), &json!({"deleted": true}));
    }

    let remaining = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    assert_eq!(remaining.items.len(), 0);
}

#[tokio::test]
async fn prompt_history_direct_engine_explicit_key_conflict_maps_to_rpc_code() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "first").unwrap();
    crate::prompt_library::store::record_prompt(pool, "second").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let function_id = specs::function_id_for_method("promptHistory.delete").unwrap();

    let first = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"id": page.items[0].id}),
            super::dispatch::rpc_causal_context_for_scope(RPC_WRITE_AUTHORITY)
                .with_idempotency_key("history-explicit-key"),
        ))
        .await;
    assert!(first.error.is_none(), "{:?}", first.error);

    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id,
            json!({"id": page.items[1].id}),
            super::dispatch::rpc_causal_context_for_scope(RPC_WRITE_AUTHORITY)
                .with_idempotency_key("history-explicit-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    let rpc = result_to_rpc(conflict).unwrap_err();
    assert_eq!(rpc.code(), errors::IDEMPOTENCY_CONFLICT);
}

#[tokio::test]
async fn settings_update_duplicate_transport_replays_without_second_side_effect() {
    let _guard = settings_test_guard();
    let mut ctx = make_test_context();
    let token_dir = tempfile::tempdir().unwrap();
    let (manager, spawner) = attach_codex_manager(&mut ctx, &token_dir);
    ctx.engine_host = crate::engine::EngineHostHandle::new_in_memory().unwrap();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);
    register_rpc_worker_for_context(&ctx, &registry).unwrap();
    let request = RpcRequest {
        id: "settings-update-retry".to_owned(),
        method: "settings.update".to_owned(),
        params: Some(json!({"settings": {"server": {"codexAppServer": {"port": 4517}}}})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);
    assert_eq!(spawner.specs.lock().unwrap().len(), 1);
    let status = manager.status().await;
    assert_eq!(status.state, CodexAppServerState::Running);
    assert_eq!(status.endpoint.unwrap().port, 4517);

    let host = ctx.engine_host.lock().await;
    let replay = host.catalog().invocations().last().unwrap();
    assert!(replay.replayed_from.is_some());
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
}

#[tokio::test]
async fn settings_reset_duplicate_transport_replays_without_second_reset() {
    let _guard = settings_test_guard();
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);

    let seed = registry
        .dispatch(
            RpcRequest {
                id: "settings-seed".to_owned(),
                method: "settings.update".to_owned(),
                params: Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
            },
            &ctx,
        )
        .await;
    assert!(seed.success, "{:?}", seed.error);

    let request = RpcRequest {
        id: "settings-reset-retry".to_owned(),
        method: "settings.resetToDefaults".to_owned(),
        params: Some(json!({})),
    };
    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert_eq!(
        first.result.as_ref().unwrap()["server"]["heartbeatIntervalMs"],
        30_000
    );

    crate::settings::SettingsStore::new(&ctx.settings_path)
        .update(json!({"server": {"heartbeatIntervalMs": 55_000}}))
        .unwrap();

    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(second.result, first.result);
    let saved = crate::settings::SettingsStore::new(&ctx.settings_path)
        .read_sparse_value()
        .unwrap();
    assert_eq!(saved["server"]["heartbeatIntervalMs"], 55_000);
}

#[tokio::test]
async fn settings_update_reused_request_id_with_different_payload_is_distinct_command() {
    let _guard = settings_test_guard();
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    handlers::register_all(&mut registry);

    for interval in [40_000, 45_000] {
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "same-settings-request-id".to_owned(),
                    method: "settings.update".to_owned(),
                    params: Some(
                        json!({"settings": {"server": {"heartbeatIntervalMs": interval}}}),
                    ),
                },
                &ctx,
            )
            .await;
        assert!(response.success, "{:?}", response.error);
    }

    let saved = crate::settings::SettingsStore::new(&ctx.settings_path)
        .read_sparse_value()
        .unwrap();
    assert_eq!(saved["server"]["heartbeatIntervalMs"], 45_000);
}

#[tokio::test]
async fn settings_direct_engine_explicit_key_conflict_maps_to_rpc_code() {
    let _guard = settings_test_guard();
    let ctx = make_test_context();
    let function_id = specs::function_id_for_method("settings.update").unwrap();
    let first = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
            super::dispatch::rpc_causal_context_for_scope(RPC_WRITE_AUTHORITY)
                .with_idempotency_key("settings-explicit-key"),
        ))
        .await;
    assert!(first.error.is_none(), "{:?}", first.error);

    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id,
            json!({"settings": {"server": {"heartbeatIntervalMs": 45_000}}}),
            super::dispatch::rpc_causal_context_for_scope(RPC_WRITE_AUTHORITY)
                .with_idempotency_key("settings-explicit-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    let rpc = result_to_rpc(conflict).unwrap_err();
    assert_eq!(rpc.code(), errors::IDEMPOTENCY_CONFLICT);
}

#[tokio::test]
async fn prompt_snippet_direct_engine_explicit_key_conflict_maps_to_rpc_code() {
    let ctx = make_test_context();
    let function_id = specs::function_id_for_method("promptSnippet.create").unwrap();
    let first = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"name": "same", "text": "body"}),
            super::dispatch::rpc_causal_context_for_scope(RPC_WRITE_AUTHORITY)
                .with_idempotency_key("explicit-key"),
        ))
        .await;
    assert!(first.error.is_none(), "{:?}", first.error);

    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id,
            json!({"name": "different", "text": "body"}),
            super::dispatch::rpc_causal_context_for_scope(RPC_WRITE_AUTHORITY)
                .with_idempotency_key("explicit-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    let rpc = result_to_rpc(conflict).unwrap_err();
    assert_eq!(rpc.code(), errors::IDEMPOTENCY_CONFLICT);
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

#[tokio::test]
async fn generic_write_records_invocation_ledger_metadata() {
    let ctx = make_test_context();
    let _ = rpc_dispatch_value(
        &ctx,
        "promptSnippet.create",
        json!({"name": "ledger", "text": "body"}),
    )
    .await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("promptSnippet.create").unwrap()
    );
    assert_eq!(record.worker_id, specs::worker_id(RPC_WORKER_ID).unwrap());
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert!(
        record
            .authority_scopes
            .contains(&RPC_WRITE_AUTHORITY.to_owned())
    );
    assert_eq!(
        record
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
    assert!(
        record
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );
    assert!(record.result_value.is_some());
}

#[tokio::test]
async fn generic_settings_write_records_invocation_ledger_metadata() {
    let _guard = settings_test_guard();
    let ctx = make_test_context();
    let _ = rpc_dispatch_value(
        &ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("settings.update").unwrap()
    );
    assert_eq!(record.worker_id, specs::worker_id(RPC_WORKER_ID).unwrap());
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert!(
        record
            .authority_scopes
            .contains(&RPC_WRITE_AUTHORITY.to_owned())
    );
    assert_eq!(
        record
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
    assert!(
        record
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );
    assert!(record.result_value.is_some());
}

#[tokio::test]
async fn generic_prompt_history_write_records_invocation_ledger_metadata() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "ledger").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let _ = rpc_dispatch_value(
        &ctx,
        "promptHistory.delete",
        json!({"id": page.items[0].id}),
    )
    .await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("promptHistory.delete").unwrap()
    );
    assert_eq!(record.worker_id, specs::worker_id(RPC_WORKER_ID).unwrap());
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert!(
        record
            .authority_scopes
            .contains(&RPC_WRITE_AUTHORITY.to_owned())
    );
    assert_eq!(
        record
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
    assert!(
        record
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );
    assert!(record.result_value.is_some());
}
