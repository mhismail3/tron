use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::net::TcpListener;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

use crate::engine::durability::resources::EngineResourceVersionState;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, EngineResourceScope,
    FunctionId, Invocation, ListResources, RUNTIME_METADATA_MODEL_PRIMITIVE_NAME,
    RUNTIME_METADATA_PROVIDER_INVOCATION_ID, RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY, TraceId, UpdateResource, WEB_ROBOTS_POLICY_KIND,
    WEB_ROBOTS_POLICY_SCHEMA_ID, WEB_SOURCE_KIND, WEB_SOURCE_SCHEMA_ID, WorkerId,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

mod archive_tests;
mod extraction_tests;
mod fetch_robots_link_tests;
mod policy_tests;
mod robots_tests;
mod source_tests;

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
    let extraction_mode = payload["textEvidence"]["extractionMode"].clone();
    let extracted_text_bytes = payload["textEvidence"]["extractedTextBytes"].clone();
    assert_eq!(extraction_mode, json!("plain_text"));

    let replayed = ctx
        .engine_host
        .inspect_resource(first_id)
        .await
        .expect("inspect replayed")
        .expect("web source resource");
    let replayed_payload = current_payload(&replayed);
    assert_eq!(
        replayed_payload["textEvidence"]["extractionMode"],
        extraction_mode
    );
    assert_eq!(
        replayed_payload["textEvidence"]["extractedTextBytes"],
        extracted_text_bytes
    );
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

struct WebFixture<'a> {
    ctx: &'a ServerRuntimeContext,
    actor_id: ActorId,
    grant_id: AuthorityGrantId,
    session_id: String,
    workspace_id: String,
    root: tempfile::TempDir,
    network_policy: String,
    allowed_authority_scopes: Vec<String>,
    allowed_resource_kinds: Vec<String>,
    resource_selectors: Vec<String>,
}

impl<'a> WebFixture<'a> {
    async fn new(ctx: &'a ServerRuntimeContext, session_id: &str, network_policy: &str) -> Self {
        Self::new_with_authority(
            ctx,
            session_id,
            network_policy,
            &[
                "capability.execute",
                "web.read",
                "web.write",
                "resource.read",
                "resource.write",
            ],
            &["web_source"],
            &["kind:web_source"],
        )
        .await
    }

    async fn new_robots(
        ctx: &'a ServerRuntimeContext,
        session_id: &str,
        network_policy: &str,
    ) -> Self {
        Self::new_with_authority(
            ctx,
            session_id,
            network_policy,
            &[
                "capability.execute",
                "web.read",
                "web.write",
                "resource.read",
                "resource.write",
            ],
            &["web_robots_policy"],
            &["kind:web_robots_policy"],
        )
        .await
    }

    async fn new_with_web_and_robots(
        ctx: &'a ServerRuntimeContext,
        session_id: &str,
        network_policy: &str,
    ) -> Self {
        Self::new_with_authority(
            ctx,
            session_id,
            network_policy,
            &[
                "capability.execute",
                "web.read",
                "web.write",
                "resource.read",
                "resource.write",
            ],
            &["web_source", "web_robots_policy"],
            &["kind:web_source", "kind:web_robots_policy"],
        )
        .await
    }

    async fn new_with_authority(
        ctx: &'a ServerRuntimeContext,
        session_id: &str,
        network_policy: &str,
        allowed_authority_scopes: &[&str],
        allowed_resource_kinds: &[&str],
        resource_selectors: &[&str],
    ) -> Self {
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
            allowed_authority_scopes,
            allowed_resource_kinds,
            resource_selectors,
        )
        .await;
        Self {
            ctx,
            actor_id,
            grant_id,
            session_id: session_id.to_owned(),
            workspace_id,
            root,
            network_policy: network_policy.to_owned(),
            allowed_authority_scopes: allowed_authority_scopes
                .iter()
                .map(|value| (*value).to_owned())
                .collect(),
            allowed_resource_kinds: allowed_resource_kinds
                .iter()
                .map(|value| (*value).to_owned())
                .collect(),
            resource_selectors: resource_selectors
                .iter()
                .map(|value| (*value).to_owned())
                .collect(),
        }
    }

    async fn invoke_ok(&self, payload: Value) -> Value {
        let idempotency_key = payload
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let grant_id = self.grant_for_payload(&payload).await;
        let result = self
            .ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("capability::execute").expect("function id"),
                payload,
                self.context_with_optional_grant(idempotency_key.as_deref(), grant_id),
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
            .map(str::to_owned);
        let grant_id = self.grant_for_payload(&payload).await;
        let result = self
            .ctx
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("capability::execute").expect("function id"),
                payload,
                self.context_with_optional_grant(idempotency_key.as_deref(), grant_id),
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
            allow_test_http_loopback_for_robots: false,
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

    async fn invoke_direct_robots_error_with_dns_overrides(
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
            allow_test_http_loopback_for_robots: true,
        };
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            payload.clone(),
            self.context(&idempotency_key),
        );
        super::robots::web_robots_check_value(&deps, &invocation, &payload)
            .await
            .expect_err("web_robots_check should fail")
            .to_string()
    }

    fn context(&self, idempotency_key: &str) -> CausalContext {
        self.context_with_grant(idempotency_key, self.grant_id.clone())
    }

    fn context_with_grant(
        &self,
        idempotency_key: &str,
        grant_id: AuthorityGrantId,
    ) -> CausalContext {
        self.context_with_optional_grant(Some(idempotency_key), grant_id)
    }

    fn context_with_optional_grant(
        &self,
        idempotency_key: Option<&str>,
        grant_id: AuthorityGrantId,
    ) -> CausalContext {
        let mut context = CausalContext::new(
            self.actor_id.clone(),
            ActorKind::Agent,
            grant_id,
            TraceId::generate(),
        )
        .with_scope("capability.execute")
        .with_scope("web.read")
        .with_scope("web.write")
        .with_scope("resource.read")
        .with_scope("resource.write")
        .with_session_id(self.session_id.clone())
        .with_workspace_id(self.workspace_id.clone())
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            self.root.path().display().to_string(),
        )
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID, "provider-web-test")
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1");
        if let Some(idempotency_key) = idempotency_key {
            context = context.with_idempotency_key(idempotency_key.to_owned());
        }
        context
    }

    async fn grant_for_payload(&self, payload: &Value) -> AuthorityGrantId {
        let mut selectors = self.resource_selectors.clone();
        for resource_id in payload
            .as_object()
            .into_iter()
            .flat_map(|object| object.iter())
            .filter(|(field, _)| field.ends_with("ResourceId"))
            .filter_map(|(_, value)| value.as_str())
        {
            let kind = resource_id.split(':').next().unwrap_or_default();
            if self
                .allowed_resource_kinds
                .iter()
                .any(|allowed| allowed == kind)
            {
                selectors.push(format!("resource:{resource_id}"));
            }
        }
        selectors.sort();
        selectors.dedup();
        if selectors == self.resource_selectors {
            return self.grant_id.clone();
        }
        let authority_scopes = self
            .allowed_authority_scopes
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let resource_kinds = self
            .allowed_resource_kinds
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let selector_refs = selectors.iter().map(String::as_str).collect::<Vec<_>>();
        derive_execute_grant(
            self.ctx,
            &self.actor_id,
            &self.session_id,
            &self.workspace_id,
            self.root.path().to_str().expect("root path"),
            &self.network_policy,
            &authority_scopes,
            &resource_kinds,
            &selector_refs,
        )
        .await
    }
}

async fn derive_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    session_id: &str,
    workspace_id: &str,
    root: &str,
    network_policy: &str,
    allowed_authority_scopes: &[&str],
    allowed_resource_kinds: &[&str],
    resource_selectors: &[&str],
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
                "allowedAuthorityScopes": allowed_authority_scopes,
                "allowedResourceKinds": allowed_resource_kinds,
                "resourceSelectors": resource_selectors,
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
            .with_idempotency_key(format!(
                "derive-{session_id}-{network_policy}-{}-{}-{}",
                allowed_authority_scopes.join("."),
                allowed_resource_kinds.join("."),
                resource_selectors.join(".")
            )),
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
