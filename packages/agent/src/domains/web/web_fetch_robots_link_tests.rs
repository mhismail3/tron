use super::*;

#[tokio::test]
async fn web_fetch_with_null_robots_policy_fields_uses_plain_fetch() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/plain"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "text/plain")
                .set_body_string("plain fetch body"),
        )
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fixture = WebFixture::new(&ctx, "web-fetch-null-robots", "declared").await;
    let value = fixture
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/plain", server.uri()),
            "webRobotsPolicyResourceId": null,
            "expectedWebRobotsPolicyVersionId": null,
            "idempotencyKey": "web-fetch-null-robots"
        }))
        .await;
    let web = &value["details"]["web"];
    assert_eq!(web["operation"], json!("web_fetch"));
    assert!(
        web.get("robotsPolicyRefs")
            .is_none_or(|refs| refs == &json!([]))
    );

    let resource_id = web["webSourceResourceId"].as_str().expect("source id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect source")
        .expect("source");
    assert_eq!(current_payload(&inspection)["robotsPolicyRefs"], json!([]));

    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].url.path(), "/plain");
}

#[tokio::test]
async fn web_fetch_links_allow_robots_policy_and_source_reads_expose_bounded_refs() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_string("User-agent: *\nDisallow: /private\nAllow: /allowed\n"),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/allowed"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "text/plain")
                .set_body_string("robots linked source body"),
        )
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let robots = WebFixture::new_robots(&ctx, "web-fetch-robots-linked", "declared").await;
    let checked = robots
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/allowed", server.uri()),
            "idempotencyKey": "web-fetch-robots-linked-policy"
        }))
        .await;
    let policy_id = checked["details"]["web"]["webRobotsPolicyResourceId"]
        .as_str()
        .expect("policy id")
        .to_owned();
    let policy_version_id = checked["details"]["web"]["webRobotsPolicyVersionId"]
        .as_str()
        .expect("policy version")
        .to_owned();

    let fetch =
        WebFixture::new_with_web_and_robots(&ctx, "web-fetch-robots-linked", "declared").await;
    let fetched = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": policy_id,
            "expectedWebRobotsPolicyVersionId": policy_version_id,
            "idempotencyKey": "web-fetch-robots-linked-source"
        }))
        .await;
    let web = &fetched["details"]["web"];
    assert_eq!(web["operation"], json!("web_fetch"));
    assert_eq!(web["robotsPolicyRefs"][0]["resourceId"], json!(policy_id));
    assert_eq!(
        web["robotsPolicyRefs"][0]["versionId"],
        json!(policy_version_id)
    );

    let source_id = web["webSourceResourceId"].as_str().expect("source id");
    let source_version_id = web["webSourceVersionId"].as_str().expect("source version");
    let inspection = ctx
        .engine_host
        .inspect_resource(source_id)
        .await
        .expect("inspect source")
        .expect("source");
    let payload = current_payload(&inspection);
    let refs = payload["robotsPolicyRefs"].as_array().expect("robots refs");
    assert_eq!(refs.len(), 1);
    assert_eq!(refs[0]["role"], json!("robots_policy"));
    assert_eq!(refs[0]["kind"], json!(WEB_ROBOTS_POLICY_KIND));
    assert_eq!(refs[0]["resourceId"], json!(policy_id));
    assert_eq!(refs[0]["versionId"], json!(policy_version_id));
    assert_eq!(refs[0]["decision"], json!("allow"));
    assert!(
        refs[0].get("boundedBody").is_none()
            && refs[0].get("bodyEvidence").is_none()
            && refs[0].get("sitemaps").is_none(),
        "web_source must persist only bounded robots refs, got: {}",
        refs[0]
    );

    let read = WebFixture::new(&ctx, "web-fetch-robots-linked", "none").await;
    let listed = read
        .invoke_ok(json!({
            "operation": "web_source_list",
            "idempotencyKey": "web-fetch-robots-linked-list"
        }))
        .await;
    let listed_ref = &listed["details"]["web"]["sources"][0]["robotsPolicyRefs"][0];
    assert_eq!(listed_ref["resourceId"], json!(policy_id));
    assert_eq!(listed_ref["versionId"], json!(policy_version_id));
    assert!(listed_ref.get("boundedBody").is_none());

    let inspected = read
        .invoke_ok(json!({
            "operation": "web_source_inspect",
            "webSourceResourceId": source_id,
            "webSourceVersionId": source_version_id,
            "idempotencyKey": "web-fetch-robots-linked-inspect"
        }))
        .await;
    let inspected_ref = &inspected["details"]["web"]["source"]["robotsPolicyRefs"][0];
    assert_eq!(inspected_ref["resourceId"], json!(policy_id));
    assert_eq!(inspected_ref["versionId"], json!(policy_version_id));
    assert!(inspected_ref.get("bodyEvidence").is_none());

    let requests = server.received_requests().await.expect("recorded requests");
    let paths = requests
        .iter()
        .map(|request| request.url.path().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(paths, vec!["/robots.txt", "/allowed"]);
}

#[tokio::test]
async fn web_fetch_rejects_non_allow_robots_policy_before_target_network_io() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(
            ResponseTemplate::new(200).set_body_string("User-agent: *\nDisallow: /denied\n"),
        )
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/denied"))
        .respond_with(ResponseTemplate::new(200).set_body_string("must not fetch target"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let robots = WebFixture::new_robots(&ctx, "web-fetch-robots-deny", "declared").await;
    let checked = robots
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/denied", server.uri()),
            "idempotencyKey": "web-fetch-robots-deny-policy"
        }))
        .await;
    let policy_id = checked["details"]["web"]["webRobotsPolicyResourceId"]
        .as_str()
        .expect("policy id");
    let policy_version_id = checked["details"]["web"]["webRobotsPolicyVersionId"]
        .as_str()
        .expect("policy version");

    let fetch =
        WebFixture::new_with_web_and_robots(&ctx, "web-fetch-robots-deny", "declared").await;
    let error = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/denied", server.uri()),
            "webRobotsPolicyResourceId": policy_id,
            "expectedWebRobotsPolicyVersionId": policy_version_id,
            "idempotencyKey": "web-fetch-robots-deny-source"
        }))
        .await;
    assert!(
        error.contains("decision allow"),
        "deny policy should fail closed, got: {error}"
    );

    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(requests.len(), 1, "target fetch must not run after deny");
    assert_eq!(requests[0].url.path(), "/robots.txt");
}

#[tokio::test]
async fn web_fetch_rejects_sensitive_query_mismatch_before_target_network_io() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(ResponseTemplate::new(200).set_body_string("User-agent: *\nAllow: /\n"))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/allowed"))
        .respond_with(ResponseTemplate::new(200).set_body_string("must not fetch target"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let robots = WebFixture::new_robots(&ctx, "web-fetch-robots-query", "declared").await;
    let checked = robots
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/allowed?token=redacted-one", server.uri()),
            "idempotencyKey": "web-fetch-robots-query-policy"
        }))
        .await;
    let policy_id = checked["details"]["web"]["webRobotsPolicyResourceId"]
        .as_str()
        .expect("policy id")
        .to_owned();
    let policy_version_id = checked["details"]["web"]["webRobotsPolicyVersionId"]
        .as_str()
        .expect("policy version")
        .to_owned();
    let inspection = ctx
        .engine_host
        .inspect_resource(&policy_id)
        .await
        .expect("inspect policy")
        .expect("policy");
    let policy_payload = current_payload(&inspection);
    assert!(
        !policy_payload["targetUrl"]
            .as_str()
            .expect("sanitized target")
            .contains("redacted-one"),
        "display target must stay sanitized"
    );
    assert!(
        policy_payload["targetUrlFingerprint"]["sha256"]
            .as_str()
            .is_some_and(|hash| hash.len() == 64)
    );
    let payload_text = policy_payload.to_string();
    assert!(!payload_text.contains("redacted-one"));
    assert!(!payload_text.contains("redacted-two"));

    let fetch =
        WebFixture::new_with_web_and_robots(&ctx, "web-fetch-robots-query", "declared").await;
    let error = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed?token=redacted-two", server.uri()),
            "webRobotsPolicyResourceId": policy_id,
            "expectedWebRobotsPolicyVersionId": policy_version_id,
            "idempotencyKey": "web-fetch-robots-query-source"
        }))
        .await;
    assert!(
        error.contains("targetUrl fingerprint does not match"),
        "sensitive query mismatch must fail exact target validation, got: {error}"
    );

    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(
        requests.len(),
        1,
        "target fetch must not run after exact target mismatch"
    );
    assert_eq!(requests[0].url.path(), "/robots.txt");
}

#[tokio::test]
async fn web_fetch_robots_policy_rejects_invalid_evidence_before_target_network_io() {
    let server = MockServer::start().await;
    let other_origin = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/robots.txt"))
        .respond_with(ResponseTemplate::new(200).set_body_string("User-agent: *\nAllow: /\n"))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/allowed"))
        .respond_with(ResponseTemplate::new(200).set_body_string("must not fetch allowed"))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/other"))
        .respond_with(ResponseTemplate::new(200).set_body_string("must not fetch other"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let robots = WebFixture::new_robots(&ctx, "web-fetch-robots-invalid", "declared").await;
    let checked = robots
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/allowed", server.uri()),
            "idempotencyKey": "web-fetch-robots-invalid-policy"
        }))
        .await;
    let policy_id = checked["details"]["web"]["webRobotsPolicyResourceId"]
        .as_str()
        .expect("policy id")
        .to_owned();
    let policy_version_id = checked["details"]["web"]["webRobotsPolicyVersionId"]
        .as_str()
        .expect("policy version")
        .to_owned();
    let fetch =
        WebFixture::new_with_web_and_robots(&ctx, "web-fetch-robots-invalid", "declared").await;

    let no_resource_read = WebFixture::new_with_authority(
        &ctx,
        "web-fetch-robots-invalid",
        "declared",
        &["capability.execute", "web.write", "resource.write"],
        &["agent_state", "web_source", "web_robots_policy"],
        &[
            "kind:agent_state",
            "kind:web_source",
            "kind:web_robots_policy",
        ],
    )
    .await;
    let missing_read = no_resource_read
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": policy_id,
            "expectedWebRobotsPolicyVersionId": policy_version_id,
            "idempotencyKey": "web-fetch-robots-invalid-missing-read"
        }))
        .await;
    assert!(missing_read.contains("resource.read"));

    let target_mismatch = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/other", server.uri()),
            "webRobotsPolicyResourceId": policy_id,
            "expectedWebRobotsPolicyVersionId": policy_version_id,
            "idempotencyKey": "web-fetch-robots-invalid-target"
        }))
        .await;
    assert!(target_mismatch.contains("targetUrl does not match"));

    let origin_mismatch = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", other_origin.uri()),
            "webRobotsPolicyResourceId": policy_id,
            "expectedWebRobotsPolicyVersionId": policy_version_id,
            "idempotencyKey": "web-fetch-robots-invalid-origin"
        }))
        .await;
    assert!(origin_mismatch.contains("origin does not match"));

    let wrong_kind = ctx
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some("web_robots_policy:wrong-kind".to_owned()),
            kind: WEB_SOURCE_KIND.to_owned(),
            schema_id: Some(WEB_SOURCE_SCHEMA_ID.to_owned()),
            scope: EngineResourceScope::Session(fetch.session_id.clone()),
            owner_worker_id: WorkerId::new("web-test").expect("worker id"),
            owner_actor_id: fetch.actor_id.clone(),
            lifecycle: Some("fetched".to_owned()),
            policy: json!({"test": "wrong kind"}),
            initial_payload: Some(json!({
                "schemaVersion": crate::domains::web::WEB_SOURCE_SCHEMA_VERSION,
                "operation": "web_fetch",
                "state": "fetched",
                "requestedUrl": format!("{}/allowed", server.uri()),
                "finalUrl": format!("{}/allowed", server.uri()),
                "fetchedAt": "2026-06-24T00:00:00Z",
                "status": 200,
                "contentType": "text/plain",
                "byteEvidence": {
                    "capturedBytes": 0,
                    "maxResponseBytes": 1,
                    "responseBytesTruncated": false,
                    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                    "hashScope": "captured_response_bytes"
                },
                "textEvidence": {
                    "preview": "",
                    "textBytes": 0,
                    "maxOutputBytes": 1,
                    "outputTextTruncated": false,
                    "binaryBodyOmitted": false
                },
                "redaction": {"applied": false, "replacementCount": 0},
                "authority": {"networkPolicy": "declared"},
                "traceRefs": [],
                "replayRefs": [],
                "cache": {"cacheKey": "web_robots_policy:wrong-kind"},
                "idempotency": {"key": "wrong-kind"},
                "revision": 1
            })),
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("create wrong-kind");
    let wrong_kind_error = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": wrong_kind.resource_id,
            "expectedWebRobotsPolicyVersionId": "rver_wrong_kind",
            "idempotencyKey": "web-fetch-robots-invalid-wrong-kind"
        }))
        .await;
    assert!(wrong_kind_error.contains("resource kind mismatch"));

    let no_current = ctx
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some("web_robots_policy:no-current".to_owned()),
            kind: WEB_ROBOTS_POLICY_KIND.to_owned(),
            schema_id: Some(WEB_ROBOTS_POLICY_SCHEMA_ID.to_owned()),
            scope: EngineResourceScope::Session(fetch.session_id.clone()),
            owner_worker_id: WorkerId::new("web-test").expect("worker id"),
            owner_actor_id: fetch.actor_id.clone(),
            lifecycle: Some("checked".to_owned()),
            policy: json!({"test": "no current"}),
            initial_payload: None,
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("create no-current");
    let no_current_error = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": no_current.resource_id,
            "expectedWebRobotsPolicyVersionId": "rver_no_current",
            "idempotencyKey": "web-fetch-robots-invalid-no-current"
        }))
        .await;
    assert!(no_current_error.contains("has no current version"));

    let non_current = ctx
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some("web_robots_policy:non-current".to_owned()),
            kind: WEB_ROBOTS_POLICY_KIND.to_owned(),
            schema_id: Some(WEB_ROBOTS_POLICY_SCHEMA_ID.to_owned()),
            scope: EngineResourceScope::Session(fetch.session_id.clone()),
            owner_worker_id: WorkerId::new("web-test").expect("worker id"),
            owner_actor_id: fetch.actor_id.clone(),
            lifecycle: Some("checked".to_owned()),
            policy: json!({"test": "non current"}),
            initial_payload: None,
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("create non-current");
    let non_current_version = ctx
        .engine_host
        .update_resource(UpdateResource {
            resource_id: non_current.resource_id.clone(),
            expected_current_version_id: None,
            lifecycle: Some("checked".to_owned()),
            payload: current_payload(&valid_robots_inspection(&ctx, &policy_id).await),
            state: Some(EngineResourceVersionState::Discarded),
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("create discarded version");
    let non_current_error = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": non_current.resource_id,
            "expectedWebRobotsPolicyVersionId": non_current_version.version_id,
            "idempotencyKey": "web-fetch-robots-invalid-non-current"
        }))
        .await;
    assert!(non_current_error.contains("has no current version"));

    let malformed = ctx
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some("web_robots_policy:malformed".to_owned()),
            kind: WEB_ROBOTS_POLICY_KIND.to_owned(),
            schema_id: Some(WEB_ROBOTS_POLICY_SCHEMA_ID.to_owned()),
            scope: EngineResourceScope::Session(fetch.session_id.clone()),
            owner_worker_id: WorkerId::new("web-test").expect("worker id"),
            owner_actor_id: fetch.actor_id.clone(),
            lifecycle: Some("checked".to_owned()),
            policy: json!({"test": "malformed"}),
            initial_payload: Some(json!({
                "schemaVersion": crate::domains::web::robots::WEB_ROBOTS_POLICY_SCHEMA_VERSION,
                "operation": "web_robots_check",
                "state": "checked",
                "origin": server.uri(),
                "targetUrl": format!("{}/allowed", server.uri()),
                "robotsUrl": format!("{}/robots.txt", server.uri()),
                "fetchedAt": "2026-06-24T00:00:00Z",
                "status": 200,
                "bodyEvidence": {},
                "parser": {},
                "policy": {},
                "sitemaps": {},
                "authority": {},
                "traceRefs": [],
                "replayRefs": [],
                "cache": {},
                "idempotency": {},
                "revision": 1
            })),
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("create malformed");
    let malformed_version = malformed
        .current_version_id
        .as_ref()
        .expect("malformed version");
    let malformed_error = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": malformed.resource_id,
            "expectedWebRobotsPolicyVersionId": malformed_version,
            "idempotencyKey": "web-fetch-robots-invalid-malformed"
        }))
        .await;
    assert!(malformed_error.contains("payload missing string field /policy/decision"));

    let other_robots =
        WebFixture::new_robots(&ctx, "web-fetch-robots-invalid-other", "declared").await;
    let other_checked = other_robots
        .invoke_ok(json!({
            "operation": "web_robots_check",
            "url": format!("{}/allowed", server.uri()),
            "idempotencyKey": "web-fetch-robots-invalid-other-policy"
        }))
        .await;
    let wrong_session = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": other_checked["details"]["web"]["webRobotsPolicyResourceId"],
            "expectedWebRobotsPolicyVersionId": other_checked["details"]["web"]["webRobotsPolicyVersionId"],
            "idempotencyKey": "web-fetch-robots-invalid-wrong-session"
        }))
        .await;
    assert!(wrong_session.contains("outside the current session scope"));

    let valid_inspection = ctx
        .engine_host
        .inspect_resource(&policy_id)
        .await
        .expect("inspect valid")
        .expect("valid robots");
    let mut updated_payload = current_payload(&valid_inspection);
    updated_payload["revision"] = json!(2);
    ctx.engine_host
        .update_resource(UpdateResource {
            resource_id: policy_id.clone(),
            expected_current_version_id: Some(policy_version_id.clone()),
            lifecycle: Some("checked".to_owned()),
            payload: updated_payload,
            state: None,
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("append stale robots version");
    let stale_version = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": policy_id,
            "expectedWebRobotsPolicyVersionId": policy_version_id,
            "idempotencyKey": "web-fetch-robots-invalid-stale"
        }))
        .await;
    assert!(stale_version.contains("expectedWebRobotsPolicyVersionId is stale"));

    let missing_version = fetch
        .invoke_error(json!({
            "operation": "web_fetch",
            "url": format!("{}/allowed", server.uri()),
            "webRobotsPolicyResourceId": "web_robots_policy:missing",
            "expectedWebRobotsPolicyVersionId": "rver_missing",
            "idempotencyKey": "web-fetch-robots-invalid-missing"
        }))
        .await;
    assert!(missing_version.contains("was not found"));

    let requests = server.received_requests().await.expect("recorded requests");
    assert!(
        requests
            .iter()
            .all(|request| request.url.path() == "/robots.txt"),
        "invalid robots evidence must fail before target network I/O, got paths: {:?}",
        requests
            .iter()
            .map(|request| request.url.path().to_owned())
            .collect::<Vec<_>>()
    );
    assert!(
        other_origin
            .received_requests()
            .await
            .expect("other origin requests")
            .is_empty(),
        "origin-mismatched target must not be fetched"
    );
}

async fn valid_robots_inspection(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    policy_id: &str,
) -> crate::engine::EngineResourceInspection {
    ctx.engine_host
        .inspect_resource(policy_id)
        .await
        .expect("inspect valid")
        .expect("valid robots")
}
