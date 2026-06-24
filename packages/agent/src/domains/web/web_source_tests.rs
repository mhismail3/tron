use super::*;

#[tokio::test]
async fn web_source_inspect_returns_bounded_citation_fields_without_network_policy_declared() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/citation"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "text/plain")
                .set_body_string("alpha beta gamma delta epsilon"),
        )
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fetch = WebFixture::new(&ctx, "web-source-inspect", "declared").await;
    let fetched = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/citation", server.uri()),
            "idempotencyKey": "web-source-inspect-fetch"
        }))
        .await;
    let resource_id = fetched["details"]["web"]["webSourceResourceId"]
        .as_str()
        .expect("resource id");
    let version_id = fetched["details"]["web"]["webSourceVersionId"]
        .as_str()
        .expect("version id");

    let read = WebFixture::new(&ctx, "web-source-inspect", "none").await;
    let inspected = read
        .invoke_ok(json!({
            "operation": "web_source_inspect",
            "webSourceResourceId": resource_id,
            "webSourceVersionId": version_id,
            "maxSnippetBytes": 10
        }))
        .await;
    let web = &inspected["details"]["web"];
    assert_eq!(web["operation"], json!("web_source_inspect"));
    assert_eq!(web["network"]["performed"], json!(false));
    assert_eq!(web["network"]["requiredPolicy"], json!("none"));
    let source = &web["source"];
    assert_eq!(
        source["requestedUrl"],
        json!(format!("{}/citation", server.uri()))
    );
    assert_eq!(
        source["finalUrl"],
        json!(format!("{}/citation", server.uri()))
    );
    assert_eq!(source["status"], json!(200));
    assert_eq!(source["byteEvidence"]["sha256"].is_string(), true);
    assert_eq!(source["textEvidence"]["snippet"], json!("alpha beta"));
    assert_eq!(source["textEvidence"]["snippetTruncated"], json!(true));
    assert_eq!(source["resourceRefs"][0]["resourceId"], json!(resource_id));
    assert_eq!(source["resourceRefs"][0]["versionId"], json!(version_id));

    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(
        requests.len(),
        1,
        "web_source_inspect must not perform network I/O"
    );
}

#[tokio::test]
async fn web_source_list_is_current_session_bounded_and_count_truncated() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/one"))
        .respond_with(ResponseTemplate::new(200).set_body_string("one source body"))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/two"))
        .respond_with(ResponseTemplate::new(200).set_body_string("two source body"))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/other-session"))
        .respond_with(ResponseTemplate::new(200).set_body_string("other session body"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fetch = WebFixture::new(&ctx, "web-source-list", "declared").await;
    let first = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/one", server.uri()),
            "idempotencyKey": "web-source-list-one"
        }))
        .await;
    tokio::time::sleep(Duration::from_millis(2)).await;
    let second = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/two", server.uri()),
            "idempotencyKey": "web-source-list-two"
        }))
        .await;
    let other = WebFixture::new(&ctx, "web-source-list-other", "declared").await;
    let _other_source = other
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/other-session", server.uri()),
            "idempotencyKey": "web-source-list-other"
        }))
        .await;

    let read = WebFixture::new(&ctx, "web-source-list", "none").await;
    let listed = read
        .invoke_ok(json!({
            "operation": "web_source_list",
            "limit": 1,
            "maxPreviewBytes": 4
        }))
        .await;
    let web = &listed["details"]["web"];
    assert_eq!(web["operation"], json!("web_source_list"));
    assert_eq!(web["network"]["performed"], json!(false));
    assert_eq!(web["limits"]["returned"], json!(1));
    assert_eq!(web["limits"]["truncated"], json!(true));
    assert_eq!(
        web["sources"][0]["finalUrl"],
        json!(format!("{}/two", server.uri()))
    );
    assert_eq!(web["sources"][0]["snippet"], json!("two "));
    assert_eq!(
        web["sources"][0]["truncation"]["snippetTruncated"],
        json!(true)
    );
    assert_eq!(web["sources"][0]["truncation"]["maxPreviewBytes"], json!(4));
    assert_ne!(
        web["sources"][0]["resourceRefs"][0]["resourceId"],
        first["details"]["web"]["webSourceResourceId"]
    );
    assert_eq!(
        web["sources"][0]["resourceRefs"][0]["resourceId"],
        second["details"]["web"]["webSourceResourceId"]
    );
}

#[tokio::test]
async fn web_source_inspect_rejects_invalid_scope_kind_version_and_authority() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/rejects"))
        .respond_with(ResponseTemplate::new(200).set_body_string("reject body"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fetch = WebFixture::new(&ctx, "web-source-rejects", "declared").await;
    let fetched = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/rejects", server.uri()),
            "idempotencyKey": "web-source-rejects-fetch"
        }))
        .await;
    let resource_id = fetched["details"]["web"]["webSourceResourceId"]
        .as_str()
        .expect("resource id")
        .to_owned();
    let version_id = fetched["details"]["web"]["webSourceVersionId"]
        .as_str()
        .expect("version id")
        .to_owned();
    let read = WebFixture::new(&ctx, "web-source-rejects", "none").await;

    let malformed = read
        .invoke_error(json!({
            "operation": "web_source_inspect",
            "webSourceResourceId": "not a source id",
            "idempotencyKey": "web-source-rejects-malformed"
        }))
        .await;
    assert!(malformed.contains("must start with web_source:"));

    let goal = ctx
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some("web_source:wrong-kind".to_owned()),
            kind: "goal".to_owned(),
            schema_id: Some("tron.resource.goal.v1".to_owned()),
            scope: EngineResourceScope::Session(read.session_id.clone()),
            owner_worker_id: WorkerId::new("web-test").expect("worker id"),
            owner_actor_id: read.actor_id.clone(),
            lifecycle: Some("open".to_owned()),
            policy: json!({"test": "wrong-kind"}),
            initial_payload: Some(json!({"intent": "wrong kind"})),
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("create wrong-kind resource");
    let wrong_kind = read
        .invoke_error(json!({
            "operation": "web_source_inspect",
            "webSourceResourceId": goal.resource_id,
            "idempotencyKey": "web-source-rejects-wrong-kind"
        }))
        .await;
    assert!(
        wrong_kind.contains("resource kind mismatch") || wrong_kind.contains("resource kind"),
        "wrong kind should be rejected, got: {wrong_kind}"
    );

    let missing_version = read
        .invoke_error(json!({
            "operation": "web_source_inspect",
            "webSourceResourceId": resource_id,
            "webSourceVersionId": "rver_missing",
            "idempotencyKey": "web-source-rejects-missing-version"
        }))
        .await;
    assert!(missing_version.contains("webSourceVersionId was not found"));

    let inspection = ctx
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .expect("inspect source")
        .expect("source");
    let mut payload = current_payload(&inspection);
    payload["revision"] = json!(2);
    ctx.engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(version_id.clone()),
            lifecycle: Some("fetched".to_owned()),
            payload,
            state: None,
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("append stale-test version");
    let stale_version = read
        .invoke_error(json!({
            "operation": "web_source_inspect",
            "webSourceResourceId": resource_id,
            "webSourceVersionId": version_id,
            "idempotencyKey": "web-source-rejects-stale-version"
        }))
        .await;
    assert!(stale_version.contains("webSourceVersionId is stale"));

    let cross_session = WebFixture::new(&ctx, "web-source-rejects-other", "none").await;
    let cross_session_error = cross_session
        .invoke_error(json!({
            "operation": "web_source_inspect",
            "webSourceResourceId": resource_id,
            "idempotencyKey": "web-source-rejects-cross-session"
        }))
        .await;
    assert!(cross_session_error.contains("outside the current session scope"));

    let no_read = WebFixture::new_with_authority(
        &ctx,
        "web-source-rejects",
        "none",
        &["capability.execute", "web.write", "resource.write"],
        &["agent_state", "web_source"],
        &["kind:agent_state", "kind:web_source"],
    )
    .await;
    let authority_error = no_read
        .invoke_error(json!({
            "operation": "web_source_list",
            "idempotencyKey": "web-source-rejects-authority"
        }))
        .await;
    assert!(authority_error.contains("web.read") || authority_error.contains("resource.read"));
}
