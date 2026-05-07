use serde_json::json;

use crate::engine::{ActorKind, CausalContext, TraceId};
use crate::server::capabilities::catalog;
use crate::server::services::test_support::make_test_context;
use crate::server::transport::json_rpc::bindings;
use crate::server::transport::json_rpc::registry::JsonRpcTransportRegistry;
use crate::server::transport::json_rpc::types::JsonRpcRequest;

fn forbidden_namespace_id(name: &str) -> String {
    format!("{}::{name}", "rpc")
}

fn rust_sources_under(path: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(path).unwrap() {
        let entry = entry.unwrap();
        let path = entry.path();
        if path.is_dir() {
            rust_sources_under(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            out.push(path);
        }
    }
}

fn make_request(id: &str, method: &str, params: Option<serde_json::Value>) -> JsonRpcRequest {
    JsonRpcRequest {
        id: id.to_owned(),
        method: method.to_owned(),
        params,
    }
}

fn register_test_engine(ctx: &crate::server::services::context::ServerCapabilityContext) {
    let mut registry = JsonRpcTransportRegistry::new();
    bindings::register_all(&mut registry);
    super::register_engine_transport_for_context(ctx, &registry).unwrap();
}

#[test]
fn public_json_rpc_surface_is_engine_only() {
    let mut registry = JsonRpcTransportRegistry::new();
    bindings::register_all(&mut registry);

    assert_eq!(
        registry.methods(),
        vec![
            "engine.discover",
            "engine.inspect",
            "engine.invoke",
            "engine.promote",
            "engine.watch",
        ]
    );
    assert!(!registry.has_method("system.ping"));
    assert!(!registry.has_method("agent.prompt"));
    assert!(!registry.has_method("settings.get"));
}

#[test]
fn public_transport_specs_are_engine_only() {
    let mut registry = JsonRpcTransportRegistry::new();
    bindings::register_all(&mut registry);
    let specs = catalog::public_json_rpc_specs(&registry).unwrap();
    let methods = specs.iter().map(|spec| spec.method).collect::<Vec<_>>();

    assert_eq!(
        methods,
        vec![
            "engine.discover",
            "engine.inspect",
            "engine.watch",
            "engine.invoke",
            "engine.promote",
        ]
    );
    assert!(
        specs
            .iter()
            .all(|spec| spec.function_id.as_str().starts_with("engine::"))
    );
    assert!(specs.iter().all(|spec| {
        !spec
            .function_id
            .as_str()
            .starts_with(&forbidden_namespace_id(""))
    }));
}

#[test]
fn canonical_capability_specs_exclude_rpc_namespace() {
    let specs = catalog::canonical_capability_specs().unwrap();

    assert!(
        specs
            .iter()
            .any(|spec| spec.function_id.as_str() == "agent::prompt")
    );
    assert!(
        specs
            .iter()
            .any(|spec| spec.function_id.as_str() == "settings::get")
    );
    assert!(specs.iter().all(|spec| {
        !spec
            .function_id
            .as_str()
            .starts_with(&forbidden_namespace_id(""))
    }));
}

#[test]
fn dotted_rpc_module_and_handler_shapes_are_absent() {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    assert!(!manifest.join("src/server/rpc").exists());

    let mut files = Vec::new();
    rust_sources_under(&manifest.join("src/server"), &mut files);
    let forbidden = [
        "MethodHandler",
        "HandlerEntry",
        "RpcGenericTriggerHandler",
        "JsonRpcAliasSpec",
        "RpcCapabilitySpec",
        "JsonRpcRequestIdSeed",
        "server::rpc",
        "engine_bridge",
    ];
    for file in files {
        if file.ends_with("engine_transport/tests.rs") {
            continue;
        }
        let text = std::fs::read_to_string(&file).unwrap();
        for needle in forbidden {
            assert!(
                !text.contains(needle),
                "{} contains forbidden removed transport symbol {needle}",
                file.display()
            );
        }
    }
}

#[tokio::test]
async fn removed_dotted_methods_return_method_not_found() {
    let ctx = make_test_context();
    let mut registry = JsonRpcTransportRegistry::new();
    bindings::register_all(&mut registry);
    register_test_engine(&ctx);

    for method in ["system.ping", "agent.prompt", "settings.get"] {
        let response = registry
            .dispatch(make_request("old", method, Some(json!({}))), &ctx)
            .await;
        assert!(!response.success);
        let error = response.error.expect("removed method should fail");
        assert_eq!(error.code, "METHOD_NOT_FOUND");
        assert!(error.message.contains(method));
    }
}

#[tokio::test]
async fn engine_discover_transport_returns_canonical_ids() {
    let ctx = make_test_context();
    let mut registry = JsonRpcTransportRegistry::new();
    bindings::register_all(&mut registry);
    register_test_engine(&ctx);

    let response = registry
        .dispatch(
            make_request(
                "discover",
                "engine.discover",
                Some(json!({"text": "settings"})),
            ),
            &ctx,
        )
        .await;

    assert!(response.success, "{:?}", response.error);
    let result = response.result.unwrap();
    let serialized = result.to_string();
    assert!(serialized.contains("settings::get"));
    assert!(!serialized.contains(&forbidden_namespace_id("")));
}

#[tokio::test]
async fn engine_invoke_rejects_rpc_namespace_targets() {
    let ctx = make_test_context();
    let mut registry = JsonRpcTransportRegistry::new();
    bindings::register_all(&mut registry);
    register_test_engine(&ctx);

    let response = registry
        .dispatch(
            make_request(
                "invoke",
                "engine.invoke",
                Some(json!({
                    "functionId": forbidden_namespace_id("system.ping"),
                    "payload": {}
                })),
            ),
            &ctx,
        )
        .await;

    assert!(!response.success);
    let error = response.error.unwrap();
    assert_eq!(error.code, "INVALID_PARAMS");
    assert!(error.message.contains("canonical function id"));
}

#[tokio::test]
async fn engine_promote_requires_explicit_idempotency_key() {
    let ctx = make_test_context();
    let mut registry = JsonRpcTransportRegistry::new();
    bindings::register_all(&mut registry);
    register_test_engine(&ctx);

    let response = registry
        .dispatch(
            make_request(
                "promote",
                "engine.promote",
                Some(json!({
                    "functionId": "missing::function",
                    "expectedFunctionRevision": 1,
                    "targetVisibility": "workspace",
                    "workspaceId": "workspace-a"
                })),
            ),
            &ctx,
        )
        .await;

    assert!(!response.success);
    let error = response.error.unwrap();
    assert_eq!(error.code, "INVALID_PARAMS");
    assert!(error.message.contains("idempotencyKey"));
}

#[test]
fn direct_engine_context_uses_engine_transport_grant_without_rpc_scopes() {
    let context = CausalContext::new(
        catalog::actor_id("engine-client").unwrap(),
        ActorKind::Client,
        catalog::grant_id(catalog::SYSTEM_AUTHORITY_GRANT).unwrap(),
        TraceId::generate(),
    )
    .with_scope("settings.read");

    assert!(context.has_scope("settings.read"));
    assert!(!context.has_scope(&format!("{}.read", "rpc")));
    assert!(!context.has_scope(&format!("{}.write", "rpc")));
}
