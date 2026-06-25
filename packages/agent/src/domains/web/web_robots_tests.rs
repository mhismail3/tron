use super::*;
use crate::domains::web::{Deps, robots};

#[tokio::test]
async fn web_robots_check_fetches_only_origin_robots_and_records_allow_evidence() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(ResponseTemplate::new(200).set_body_string(
            "User-agent: *\nDisallow: /private\nAllow: /private/public\nSitemap: https://example.test/sitemap.xml\n",
        ))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/private/public/page"))
        .respond_with(ResponseTemplate::new(200).set_body_string("must not fetch target"))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/sitemap.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string("must not fetch sitemap"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new_robots(&ctx, "web-robots-allow", "declared").await;
    let value = fixture
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/private/public/page?token=hide-me", server.uri()),
            "userAgent": "TronBot",
            "idempotencyKey": "web-robots-allow"
        }))
        .await;
    let web = &value["details"]["web"];
    assert_eq!(web["operation"], json!("web_robots_check"));
    let resource_id = web["webRobotsPolicyResourceId"]
        .as_str()
        .expect("resource id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("robots policy resource");
    assert_eq!(inspection.resource.kind, WEB_ROBOTS_POLICY_KIND);
    assert_eq!(
        inspection.resource.schema_id.as_str(),
        WEB_ROBOTS_POLICY_SCHEMA_ID
    );
    let payload = current_payload(&inspection);
    assert_eq!(payload["operation"], json!("web_robots_check"));
    assert_eq!(payload["state"], json!("checked"));
    assert_eq!(payload["status"], json!(200));
    assert_eq!(payload["policy"]["decision"], json!("allow"));
    assert_eq!(
        payload["policy"]["relevantMatchedRule"]["directive"],
        json!("allow")
    );
    assert_eq!(
        payload["policy"]["relevantMatchedRule"]["path"],
        json!("/private/public")
    );
    assert_eq!(payload["policy"]["matchedUserAgent"], json!("*"));
    assert_eq!(payload["sitemaps"]["metadataOnly"], json!(true));
    assert_eq!(payload["sitemaps"]["traversed"], json!(false));
    assert_eq!(
        payload["sitemaps"]["refs"],
        json!(["https://example.test/sitemap.xml"])
    );
    assert_eq!(
        payload["targetUrl"]
            .as_str()
            .expect("target url")
            .contains("hide-me"),
        false
    );
    assert_eq!(payload["authority"]["networkPolicy"], json!("declared"));
    assert_eq!(
        payload["authority"]["resourceKind"],
        json!(WEB_ROBOTS_POLICY_KIND)
    );
    assert!(
        payload["bodyEvidence"]["sha256"]
            .as_str()
            .is_some_and(|hash| hash.len() == 64)
    );

    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(requests.len(), 1, "only robots.txt should be fetched");
    assert_eq!(requests[0].url.path(), "/robots.txt");
}

#[tokio::test]
async fn web_robots_check_records_deterministic_deny_for_matched_user_agent() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(
            ResponseTemplate::new(200).set_body_string(
                "User-agent: BadBot\nDisallow: /secret\n\nUser-agent: *\nAllow: /\n",
            ),
        )
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new_robots(&ctx, "web-robots-deny", "declared").await;
    let value = fixture
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/secret/report", server.uri()),
            "userAgent": "BadBot/1.0",
            "idempotencyKey": "web-robots-deny"
        }))
        .await;
    let resource_id = value["details"]["web"]["webRobotsPolicyResourceId"]
        .as_str()
        .expect("resource id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("robots policy");
    let payload = current_payload(&inspection);
    assert_eq!(payload["policy"]["matchedUserAgent"], json!("badbot"));
    assert_eq!(payload["policy"]["decision"], json!("deny"));
    assert_eq!(
        payload["policy"]["relevantMatchedRule"]["directive"],
        json!("disallow")
    );
    assert_eq!(
        payload["policy"]["relevantMatchedRule"]["path"],
        json!("/secret")
    );
}

#[tokio::test]
async fn web_robots_check_records_missing_malformed_and_oversized_bodies() {
    let missing = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(ResponseTemplate::new(404).set_body_string("missing"))
        .mount(&missing)
        .await;

    let malformed = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(vec![
            b'U', b's', b'e', b'r', b'-', b'a', b'g', b'e', b'n', b't', b':', b' ', b'*', b'\n',
            0xff, b'\n',
        ]))
        .mount(&malformed)
        .await;

    let oversized = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string("User-agent: *\nDisallow: /private\nAllow: /private/public\n"),
        )
        .mount(&oversized)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new_robots(&ctx, "web-robots-edge", "declared").await;
    let missing_value = fixture
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/anything", missing.uri()),
            "idempotencyKey": "web-robots-missing"
        }))
        .await;
    let missing_payload = robots_payload(&ctx, &missing_value).await;
    assert_eq!(missing_payload["missing"], json!(true));
    assert_eq!(missing_payload["policy"]["decision"], json!("allow"));
    assert_eq!(missing_payload["policy"]["reason"], json!("robots_missing"));

    let malformed_value = fixture
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/ok", malformed.uri()),
            "maxOutputBytes": 8,
            "idempotencyKey": "web-robots-malformed"
        }))
        .await;
    let malformed_payload = robots_payload(&ctx, &malformed_value).await;
    assert_eq!(
        malformed_payload["bodyEvidence"]["malformedUtf8"],
        json!(true)
    );
    assert_eq!(
        malformed_payload["bodyEvidence"]["previewTruncated"],
        json!(true)
    );
    assert_eq!(
        malformed_payload["parser"]["tolerantMalformedBody"],
        json!(true)
    );

    let oversized_value = fixture
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/private/public", oversized.uri()),
            "maxRobotsBytes": 8,
            "idempotencyKey": "web-robots-oversized"
        }))
        .await;
    let oversized_payload = robots_payload(&ctx, &oversized_value).await;
    assert_eq!(
        oversized_payload["bodyEvidence"]["robotsBytesTruncated"],
        json!(true)
    );
    assert_eq!(
        oversized_payload["policy"]["reason"],
        json!("robots_body_truncated_fail_closed")
    );
    assert_eq!(oversized_payload["policy"]["decision"], json!("deny"));
}

#[tokio::test]
async fn web_robots_check_authority_failures_happen_before_network_io() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(ResponseTemplate::new(200).set_body_string("User-agent: *\nAllow: /\n"))
        .mount(&server)
        .await;
    let ctx = make_test_context();

    let no_network = WebFixture::new_robots(&ctx, "web-robots-no-network", "none").await;
    let no_network_error = no_network
        .invoke_error(json!({
            "operation": "web_robots_check",
            "url": format!("{}/anything", server.uri()),
            "idempotencyKey": "web-robots-no-network"
        }))
        .await;
    assert!(no_network_error.contains("networkPolicy declared"));

    let no_kind = WebFixture::new_with_authority(
        &ctx,
        "web-robots-no-kind",
        "declared",
        &[
            "capability.execute",
            "web.write",
            "resource.read",
            "resource.write",
        ],
        &["agent_state", "web_source"],
        &["kind:agent_state", "kind:web_source"],
    )
    .await;
    let no_kind_error = no_kind
        .invoke_error(json!({
            "operation": "web_robots_check",
            "url": format!("{}/anything", server.uri()),
            "idempotencyKey": "web-robots-no-kind"
        }))
        .await;
    assert!(no_kind_error.contains("web_robots_policy"));

    let no_resource_read = WebFixture::new_with_authority(
        &ctx,
        "web-robots-no-resource-read",
        "declared",
        &["capability.execute", "web.write", "resource.write"],
        &["agent_state", "web_robots_policy"],
        &["kind:agent_state", "kind:web_robots_policy"],
    )
    .await;
    let no_resource_read_error = no_resource_read
        .invoke_error(json!({
            "operation": "web_robots_check",
            "url": format!("{}/anything", server.uri()),
            "idempotencyKey": "web-robots-no-resource-read"
        }))
        .await;
    assert!(
        no_resource_read_error.contains("resource.read"),
        "missing resource.read should reject robots cache/evidence access before I/O, got: {no_resource_read_error}"
    );

    let no_selector = WebFixture::new_with_authority(
        &ctx,
        "web-robots-no-selector",
        "declared",
        &[
            "capability.execute",
            "web.write",
            "resource.read",
            "resource.write",
        ],
        &["agent_state", "web_robots_policy"],
        &["kind:agent_state"],
    )
    .await;
    let no_selector_error = no_selector
        .invoke_error(json!({
            "operation": "web_robots_check",
            "url": format!("{}/anything", server.uri()),
            "idempotencyKey": "web-robots-no-selector"
        }))
        .await;
    assert!(
        no_selector_error.contains("web_robots_policy"),
        "wrong resource selector should reject robots policy evidence before I/O, got: {no_selector_error}"
    );

    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(
        requests.len(),
        0,
        "authority failures must happen before HTTP client network I/O"
    );
}

#[tokio::test]
async fn web_robots_check_production_mode_rejects_http_loopback_before_network_io() {
    let (port, accepts) = loopback_accept_probe().await;
    let ctx = make_test_context();
    let fixture = WebFixture::new_robots(&ctx, "web-robots-http-loopback", "declared").await;
    let payload = json!({
        "operation": "web_robots_check",
        "url": format!("http://127.0.0.1:{port}/private"),
        "idempotencyKey": "web-robots-http-loopback"
    });
    let deps = Deps {
        engine_host: ctx.engine_host.clone(),
        dns_overrides: None,
        allow_test_http_loopback_for_robots: false,
    };
    let invocation = Invocation::new_sync(
        FunctionId::new("capability::execute").expect("function id"),
        payload.clone(),
        fixture.context("web-robots-http-loopback"),
    );
    let error = robots::web_robots_check_value(&deps, &invocation, &payload)
        .await
        .expect_err("production-mode robots check should reject http loopback")
        .to_string();
    assert!(
        error.contains("https URLs"),
        "production-mode robots check should reject http loopback by URL policy, got: {error}"
    );
    assert_eq!(
        accepts.await.expect("accept probe"),
        0,
        "production-mode http loopback rejection must happen before network I/O"
    );
}

#[tokio::test]
async fn web_robots_check_rejects_unsafe_initial_redirect_and_dns_targets() {
    let ctx = make_test_context();
    let fixture = WebFixture::new_robots(&ctx, "web-robots-safety", "declared").await;
    let unsafe_initial = fixture
        .invoke_error(json!({
            "operation": "web_robots_check",
            "url": "https://localhost/private",
            "idempotencyKey": "web-robots-unsafe-initial"
        }))
        .await;
    assert!(unsafe_initial.contains("localhost"));

    let redirect_server = MockServer::start().await;
    let forbidden_server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(
            ResponseTemplate::new(302)
                .insert_header("Location", format!("{}/robots.txt", forbidden_server.uri())),
        )
        .mount(&redirect_server)
        .await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(ResponseTemplate::new(200).set_body_string("must not fetch"))
        .mount(&forbidden_server)
        .await;
    let redirect_error = fixture
        .invoke_error(json!({
            "operation": "web_robots_check",
            "url": format!("{}/target", redirect_server.uri()),
            "maxRedirects": 2,
            "idempotencyKey": "web-robots-unsafe-redirect"
        }))
        .await;
    assert!(redirect_error.contains("redirect policy rejected"));
    assert_eq!(
        forbidden_server
            .received_requests()
            .await
            .expect("recording")
            .len(),
        0,
        "forbidden redirect target must not be requested"
    );

    let (port, accepts) = loopback_accept_probe().await;
    let mut overrides = HashMap::new();
    overrides.insert(
        "robots-rebind.test".to_owned(),
        vec![SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)],
    );
    let dns_error = fixture
        .invoke_direct_robots_error_with_dns_overrides(
            json!({
                "operation": "web_robots_check",
                "url": format!("https://robots-rebind.test:{port}/target"),
                "idempotencyKey": "web-robots-unsafe-dns"
            }),
            overrides,
        )
        .await;
    assert!(
        dns_error.contains("connection failed"),
        "unsafe DNS result should fail closed through resolver, got: {dns_error}"
    );
    assert_eq!(
        accepts.await.expect("accept probe"),
        0,
        "unsafe DNS result must be rejected before TCP connect"
    );
}

#[tokio::test]
async fn web_robots_check_replays_idempotently_without_duplicate_resource() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(ResponseTemplate::new(200).set_body_string("User-agent: *\nAllow: /\n"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new_robots(&ctx, "web-robots-replay", "declared").await;
    let payload = json!({
        "operation": "web_robots_check",
        "url": format!("{}/one", server.uri()),
        "idempotencyKey": "web-robots-replay-key"
    });
    let deps = Deps {
        engine_host: ctx.engine_host.clone(),
        dns_overrides: None,
        allow_test_http_loopback_for_robots: true,
    };
    let invocation = Invocation::new_sync(
        FunctionId::new("capability::execute").expect("function id"),
        payload.clone(),
        fixture.context("web-robots-replay-key"),
    );
    let first = robots::web_robots_check_value(&deps, &invocation, &payload)
        .await
        .expect("first robots check");
    let second = robots::web_robots_check_value(&deps, &invocation, &payload)
        .await
        .expect("second robots check");
    assert_eq!(
        first["webRobotsPolicyResourceId"],
        second["webRobotsPolicyResourceId"]
    );
    assert_eq!(second["cache"]["hit"], json!(true));
    assert_eq!(second["streamCursor"], json!(0));
    let resources = ctx
        .engine_host
        .list_resources(ListResources {
            kind: Some(WEB_ROBOTS_POLICY_KIND.to_owned()),
            scope: Some(EngineResourceScope::Session(fixture.session_id.clone())),
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list resources");
    assert_eq!(
        resources.len(),
        1,
        "idempotent replay must not duplicate robots evidence"
    );
    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(
        requests.len(),
        1,
        "idempotent replay must not refetch robots.txt"
    );
}

async fn robots_payload(ctx: &ServerRuntimeContext, value: &Value) -> Value {
    let resource_id = value["details"]["web"]["webRobotsPolicyResourceId"]
        .as_str()
        .expect("resource id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect")
        .expect("robots policy");
    current_payload(&inspection)
}
