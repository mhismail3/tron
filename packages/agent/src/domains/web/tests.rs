use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::net::TcpListener;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineResourceScope, FunctionId,
    Invocation, ListResources, RUNTIME_METADATA_MODEL_PRIMITIVE_NAME,
    RUNTIME_METADATA_PROVIDER_INVOCATION_ID, RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY, TraceId, WEB_SOURCE_KIND, WEB_SOURCE_SCHEMA_ID,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

#[tokio::test]
async fn web_fetch_requires_declared_network_policy_before_network_io() {
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-network-denied", "none").await;
    let error = fixture
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": "http://127.0.0.1:1/should-not-connect",
            "idempotencyKey": "web-fetch-network-denied"
        }))
        .await;
    assert!(
        error.contains("networkPolicy declared"),
        "web_fetch must fail closed before network I/O, got: {error}"
    );
}

#[tokio::test]
async fn web_fetch_records_bounded_redacted_source_evidence() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/source"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "text/plain; charset=utf-8")
                .set_body_string("alpha api_key=super-secret-token omega tail"),
        )
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-success", "declared").await;
    let value = fixture
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/source?token=hide-me", server.uri()),
            "maxResponseBytes": 18,
            "maxOutputBytes": 12,
            "idempotencyKey": "web-fetch-success"
        }))
        .await;
    let web = &value["details"]["web"];
    assert_eq!(web["operation"], json!("web_fetch"));
    let resource_id = web["webSourceResourceId"].as_str().expect("resource id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("web source resource");
    assert_eq!(inspection.resource.kind, WEB_SOURCE_KIND);
    assert_eq!(inspection.resource.schema_id.as_str(), WEB_SOURCE_SCHEMA_ID);
    let payload = current_payload(&inspection);
    assert_eq!(payload["status"], json!(200));
    assert!(
        payload["contentType"]
            .as_str()
            .is_some_and(|content_type| content_type.starts_with("text/plain"))
    );
    assert_eq!(
        payload["byteEvidence"]["responseBytesTruncated"],
        json!(true)
    );
    assert_eq!(payload["byteEvidence"]["maxResponseBytes"], json!(18));
    assert_eq!(payload["textEvidence"]["outputTextTruncated"], json!(true));
    assert_eq!(payload["textEvidence"]["maxOutputBytes"], json!(12));
    assert_eq!(payload["textEvidence"]["binaryBodyOmitted"], json!(false));
    assert_eq!(
        payload["requestedUrl"]
            .as_str()
            .unwrap()
            .contains("hide-me"),
        false,
        "sensitive query values must be redacted"
    );
    assert_eq!(payload["authority"]["networkPolicy"], json!("declared"));
    assert_eq!(payload["cache"]["cacheHit"], json!(false));
    assert!(
        payload["byteEvidence"]["sha256"]
            .as_str()
            .is_some_and(|hash| hash.len() == 64)
    );
}

#[tokio::test]
async fn web_fetch_redacts_secret_text_and_replays_idempotently() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/secret"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "application/json")
                .set_body_string(r#"{"token":"Bearer abcdefghijk","password=letmein":true}"#),
        )
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-replay", "declared").await;
    let first = fixture
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/secret", server.uri()),
            "idempotencyKey": "web-fetch-replay-key"
        }))
        .await;
    let second = fixture
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/secret", server.uri()),
            "idempotencyKey": "web-fetch-replay-key"
        }))
        .await;
    let first_id = first["details"]["web"]["webSourceResourceId"]
        .as_str()
        .expect("first id");
    let second_id = second["details"]["web"]["webSourceResourceId"]
        .as_str()
        .expect("second id");
    assert_eq!(first_id, second_id);
    let resources = ctx
        .engine_host
        .list_resources(ListResources {
            kind: Some(WEB_SOURCE_KIND.to_owned()),
            scope: Some(EngineResourceScope::Session(fixture.session_id.clone())),
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list resources");
    assert_eq!(
        resources.len(),
        1,
        "idempotent replay must not duplicate evidence"
    );
    let inspection = ctx
        .engine_host
        .inspect_resource(first_id)
        .await
        .expect("inspect")
        .expect("web source resource");
    let payload = current_payload(&inspection);
    assert_eq!(payload["redaction"]["applied"], json!(true));
    let preview = payload["textEvidence"]["preview"].as_str().unwrap();
    assert!(!preview.contains("abcdefghijk"));
    assert!(!preview.contains("letmein"));
}

#[tokio::test]
async fn web_fetch_records_redirect_final_url_evidence() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/redirect"))
        .respond_with(
            ResponseTemplate::new(302).insert_header("Location", format!("{}/final", server.uri())),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/final"))
        .respond_with(ResponseTemplate::new(200).set_body_string("redirected"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-redirect", "declared").await;
    let value = fixture
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/redirect", server.uri()),
            "maxRedirects": 2,
            "idempotencyKey": "web-fetch-redirect"
        }))
        .await;
    let resource_id = value["details"]["web"]["webSourceResourceId"]
        .as_str()
        .expect("resource id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("web source resource");
    let payload = current_payload(&inspection);
    assert_eq!(payload["status"], json!(200));
    assert!(payload["finalUrl"].as_str().unwrap().ends_with("/final"));
    assert_eq!(payload["redirects"]["finalUrlChanged"], json!(true));
    assert_eq!(payload["redirects"]["maxRedirects"], json!(2));
}

#[tokio::test]
async fn web_fetch_rejects_redirect_to_forbidden_target_before_requesting_it() {
    let redirect_server = MockServer::start().await;
    let forbidden_server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/redirect"))
        .respond_with(
            ResponseTemplate::new(302)
                .insert_header("Location", format!("{}/forbidden", forbidden_server.uri())),
        )
        .mount(&redirect_server)
        .await;
    Mock::given(method("GET"))
        .and(path("/forbidden"))
        .respond_with(ResponseTemplate::new(200).set_body_string("must not fetch"))
        .mount(&forbidden_server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-redirect-forbidden", "declared").await;
    let error = fixture
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/redirect", redirect_server.uri()),
            "maxRedirects": 2,
            "idempotencyKey": "web-fetch-redirect-forbidden"
        }))
        .await;
    assert!(
        error.contains("redirect policy rejected"),
        "forbidden redirect target should be rejected by policy, got: {error}"
    );
    let forbidden_requests = forbidden_server
        .received_requests()
        .await
        .expect("request recording");
    assert_eq!(
        forbidden_requests.len(),
        0,
        "redirect target must be rejected before network I/O"
    );
}

#[tokio::test]
async fn web_fetch_rejects_canonical_localhost_alias_before_network_io() {
    let (port, accepts) = loopback_accept_probe().await;
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-localhost-dot", "declared").await;
    let error = fixture
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("https://localhost.:{port}/forbidden"),
            "idempotencyKey": "web-fetch-localhost-dot"
        }))
        .await;
    assert!(
        error.contains("localhost"),
        "canonical localhost alias should be rejected, got: {error}"
    );
    assert_eq!(
        accepts.await.expect("accept probe"),
        0,
        "canonical localhost alias must fail before opening a socket"
    );
}

#[tokio::test]
async fn web_fetch_rejects_hostname_resolving_to_internal_ip_before_network_io() {
    let (port, accepts) = loopback_accept_probe().await;
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-rebinding", "declared").await;
    let mut overrides = HashMap::new();
    overrides.insert(
        "rebind.test".to_owned(),
        vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)],
    );

    let error = fixture
        .invoke_direct_error_with_dns_overrides(
            json!({
                "operation": "web_fetch",
                "url": format!("https://rebind.test:{port}/forbidden"),
                "idempotencyKey": "web-fetch-rebinding-loopback"
            }),
            overrides,
        )
        .await;
    assert!(
        error.contains("connection failed"),
        "DNS rebinding target should fail closed through resolver, got: {error}"
    );
    assert_eq!(
        accepts.await.expect("accept probe"),
        0,
        "unsafe DNS result must be rejected before TCP connect"
    );

    let mut private_overrides = HashMap::new();
    private_overrides.insert(
        "private.test".to_owned(),
        vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 10)), 0)],
    );
    let private_error = fixture
        .invoke_direct_error_with_dns_overrides(
            json!({
                "operation": "web_fetch",
                "url": "https://private.test/forbidden",
                "idempotencyKey": "web-fetch-rebinding-private"
            }),
            private_overrides,
        )
        .await;
    assert!(
        private_error.contains("connection failed"),
        "private DNS result should fail closed through resolver, got: {private_error}"
    );
}

#[tokio::test]
async fn web_fetch_rejects_hostname_resolving_to_unsafe_ipv6_before_network_io() {
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-rebinding-v6", "declared").await;
    for (host, addr) in [
        (
            "site-local-v6.test",
            Ipv6Addr::new(0xfec0, 0, 0, 0, 0, 0, 0, 1),
        ),
        (
            "compatible-loopback-v6.test",
            Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0x7f00, 1),
        ),
        (
            "translated-loopback-v6.test",
            Ipv6Addr::new(0, 0, 0, 0, 0xffff, 0, 0x7f00, 1),
        ),
    ] {
        let mut overrides = HashMap::new();
        overrides.insert(host.to_owned(), vec![SocketAddr::new(IpAddr::V6(addr), 0)]);
        let error = fixture
            .invoke_direct_error_with_dns_overrides(
                json!({
                    "operation": "web_fetch",
                    "url": format!("https://{host}/forbidden"),
                    "idempotencyKey": format!("web-fetch-rebinding-v6-{host}")
                }),
                overrides,
            )
            .await;
        assert!(
            error.contains("connection failed"),
            "unsafe IPv6 DNS result for {host} should fail closed through resolver, got: {error}"
        );
    }
}

#[tokio::test]
async fn web_fetch_rejects_unsafe_ipv6_url_literals() {
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-ipv6-url-validation", "declared").await;
    for url in [
        "https://[fec0::1]/private",
        "https://[::7f00:1]/private",
        "https://[::ffff:0:7f00:1]/private",
    ] {
        let error = fixture
            .invoke_error(json!({
                "operation": "web_fetch",
                "url": url,
                "idempotencyKey": format!("web-fetch-ipv6-url-validation-{url}")
            }))
            .await;
        assert!(
            error.contains("local/internal IP"),
            "unsafe IPv6 literal {url} should be rejected by URL validation, got: {error}"
        );
    }
}

#[tokio::test]
async fn web_fetch_rejects_unsupported_or_unsafe_urls() {
    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-url-validation", "declared").await;
    for (url, expected) in [
        ("ftp://example.com/file", "unsupported URL scheme"),
        ("https://user:pass@example.com/", "credentials"),
        ("http://example.com/insecure", "http only for test loopback"),
        ("https://10.0.0.1/private", "local/internal IP"),
        ("https://[fec0::1]/private", "local/internal IP"),
        ("https://[::7f00:1]/private", "local/internal IP"),
        ("https://localhost/private", "localhost"),
        ("https://localhost./private", "localhost"),
        ("http://localhost/test", "http only for test loopback IP"),
        ("not a url", "malformed url"),
    ] {
        let error = fixture
            .invoke_error(json!({
                "operation": "web_fetch",
                "url": url,
                "idempotencyKey": format!("web-fetch-url-validation-{url}")
            }))
            .await;
        assert!(
            error.contains(expected),
            "expected {expected:?} for {url}, got {error}"
        );
    }
    let overlong = format!("https://example.com/{}", "a".repeat(2_100));
    let error = fixture
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": overlong,
            "idempotencyKey": "web-fetch-url-validation-overlong"
        }))
        .await;
    assert!(error.contains("exceeds 2048 bytes"));
}

struct WebFixture<'a> {
    ctx: &'a ServerRuntimeContext,
    actor_id: ActorId,
    grant_id: AuthorityGrantId,
    session_id: String,
    workspace_id: String,
    root: tempfile::TempDir,
}

impl<'a> WebFixture<'a> {
    async fn new(ctx: &'a ServerRuntimeContext, session_id: &str, network_policy: &str) -> Self {
        let root = tempdir().expect("root");
        let workspace_id = format!("{session_id}-workspace");
        let actor_id = ActorId::new(format!("agent:{session_id}")).expect("actor id");
        let grant_id = derive_execute_grant(
            ctx,
            &actor_id,
            session_id,
            &workspace_id,
            root.path().to_str().unwrap(),
            network_policy,
        )
        .await;
        Self {
            ctx,
            actor_id,
            grant_id,
            session_id: session_id.to_owned(),
            workspace_id,
            root,
        }
    }

    async fn invoke_ok(&self, payload: Value) -> Value {
        let idempotency_key = payload
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .unwrap_or("web-fixture-context-key")
            .to_owned();
        let result = self
            .ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("capability::execute").expect("function id"),
                payload,
                self.context(&idempotency_key),
            ))
            .await;
        assert_eq!(result.error, None, "execute failed: {:?}", result.error);
        let value = result.value.expect("value");
        assert_eq!(value["isError"], json!(false), "{value}");
        value
    }

    async fn invoke_error(&self, payload: Value) -> String {
        let idempotency_key = payload
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .unwrap_or("web-fixture-context-key")
            .to_owned();
        let result = self
            .ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("capability::execute").expect("function id"),
                payload,
                self.context(&idempotency_key),
            ))
            .await;
        result.error.expect("execute should fail").to_string()
    }

    async fn invoke_direct_error_with_dns_overrides(
        &self,
        payload: Value,
        dns_overrides: HashMap<String, Vec<SocketAddr>>,
    ) -> String {
        let idempotency_key = payload
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .unwrap_or("web-fixture-context-key")
            .to_owned();
        let deps = super::Deps {
            engine_host: self.ctx.engine_host.clone(),
            dns_overrides: Some(Arc::new(dns_overrides)),
        };
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            payload.clone(),
            self.context(&idempotency_key),
        );
        super::fetch::web_fetch_value(&deps, &invocation, &payload)
            .await
            .expect_err("web_fetch should fail")
            .to_string()
    }

    fn context(&self, idempotency_key: &str) -> CausalContext {
        CausalContext::new(
            self.actor_id.clone(),
            ActorKind::Agent,
            self.grant_id.clone(),
            TraceId::generate(),
        )
        .with_scope("capability.execute")
        .with_scope("web.read")
        .with_scope("web.write")
        .with_session_id(self.session_id.clone())
        .with_workspace_id(self.workspace_id.clone())
        .with_idempotency_key(idempotency_key.to_owned())
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            self.root.path().display().to_string(),
        )
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID, "provider-web-test")
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1")
    }
}

async fn derive_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    session_id: &str,
    workspace_id: &str,
    root: &str,
    network_policy: &str,
) -> AuthorityGrantId {
    let grant = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("grant::derive").expect("function id"),
            json!({
                "parentGrantId": "agent-capability-runtime",
                "subjectActorId": actor_id.as_str(),
                "allowedCapabilities": ["capability::execute"],
                "allowedNamespaces": ["__no_namespace_authority__"],
                "allowedAuthorityScopes": ["capability.execute", "web.read", "web.write"],
                "allowedResourceKinds": ["agent_state", "web_source"],
                "resourceSelectors": ["kind:agent_state", "kind:web_source"],
                "fileRoots": [root],
                "networkPolicy": network_policy,
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 20},
                "canDelegate": false,
                "provenance": {"source": "web-test"}
            }),
            CausalContext::new(
                ActorId::new("system:web-test").expect("actor id"),
                ActorKind::System,
                AuthorityGrantId::new("grant").expect("grant id"),
                TraceId::generate(),
            )
            .with_scope("grant.write")
            .with_session_id(session_id.to_owned())
            .with_workspace_id(workspace_id.to_owned())
            .with_idempotency_key(format!("derive-{session_id}-{network_policy}")),
        ))
        .await;
    assert_eq!(grant.error, None, "derive grant failed: {:?}", grant.error);
    AuthorityGrantId::new(
        grant.value.expect("grant value")["grant"]["grantId"]
            .as_str()
            .expect("grant id"),
    )
    .expect("grant id")
}

fn current_payload(inspection: &crate::engine::EngineResourceInspection) -> Value {
    let current = inspection
        .resource
        .current_version_id
        .as_ref()
        .expect("current version");
    inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .expect("current payload")
        .payload
        .clone()
}

async fn loopback_accept_probe() -> (u16, tokio::task::JoinHandle<usize>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .expect("bind loopback probe");
    let port = listener.local_addr().expect("probe addr").port();
    let handle = tokio::spawn(async move {
        match tokio::time::timeout(Duration::from_millis(200), listener.accept()).await {
            Ok(Ok((_stream, _addr))) => 1,
            _ => 0,
        }
    });
    (port, handle)
}
