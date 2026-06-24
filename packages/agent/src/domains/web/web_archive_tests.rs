use super::*;

#[tokio::test]
async fn web_source_archive_preserves_source_evidence_and_filters_list_by_default() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/archive"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "text/plain")
                .set_body_string("archive source body"),
        )
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fetch = WebFixture::new(&ctx, "web-source-archive", "declared").await;
    let fetched = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/archive", server.uri()),
            "idempotencyKey": "web-source-archive-fetch"
        }))
        .await;
    let resource_id = fetched["details"]["web"]["webSourceResourceId"]
        .as_str()
        .expect("resource id")
        .to_owned();
    let fetched_version_id = fetched["details"]["web"]["webSourceVersionId"]
        .as_str()
        .expect("version id")
        .to_owned();
    let before = ctx
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .expect("inspect before")
        .expect("source before");
    let before_payload = current_payload(&before);
    let before_hash = before_payload["byteEvidence"]["sha256"].clone();

    let archive = WebFixture::new(&ctx, "web-source-archive", "none").await;
    let archived = archive
        .invoke_ok(json!({
            "operation": "web_source_archive",
            "webSourceResourceId": resource_id,
            "expectedWebSourceVersionId": fetched_version_id,
            "reason": "citation cache no longer active",
            "idempotencyKey": "web-source-archive-key"
        }))
        .await;
    let archived_web = &archived["details"]["web"];
    assert_eq!(archived_web["operation"], json!("web_source_archive"));
    assert_eq!(archived_web["network"]["performed"], json!(false));
    assert_eq!(archived_web["network"]["requiredPolicy"], json!("none"));
    assert_eq!(
        archived_web["previousWebSourceVersionId"],
        json!(before.resource.current_version_id)
    );

    let after = ctx
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .expect("inspect after")
        .expect("source after");
    assert_eq!(after.resource.lifecycle, "archived");
    assert_eq!(
        after.versions.len(),
        2,
        "archive must append exactly one version"
    );
    let archived_payload = current_payload(&after);
    assert_eq!(archived_payload["state"], json!("archived"));
    assert_eq!(archived_payload["byteEvidence"]["sha256"], before_hash);
    assert_eq!(
        archived_payload["requestedUrl"], before_payload["requestedUrl"],
        "archive must preserve source URL evidence"
    );
    assert_eq!(
        archived_payload["archive"]["previousVersionId"],
        before.resource.current_version_id.clone().unwrap()
    );
    assert_eq!(
        archived_payload["archive"]["reason"],
        json!("citation cache no longer active")
    );
    assert_eq!(
        archived_payload["archive"]["retentionPolicy"]["deletesSourceEvidence"],
        json!(false)
    );
    assert_eq!(
        archived_payload["archive"]["archivedBy"]["networkPolicy"],
        json!("none")
    );

    let listed_default = archive
        .invoke_ok(json!({
            "operation": "web_source_list",
            "idempotencyKey": "web-source-archive-list-default"
        }))
        .await;
    assert_eq!(
        listed_default["details"]["web"]["sources"]
            .as_array()
            .expect("sources")
            .len(),
        0,
        "default list should exclude archived sources"
    );

    let listed_archived = archive
        .invoke_ok(json!({
            "operation": "web_source_list",
            "includeArchived": true,
            "idempotencyKey": "web-source-archive-list-archived"
        }))
        .await;
    let archived_source = &listed_archived["details"]["web"]["sources"][0];
    assert_eq!(archived_source["state"], json!("archived"));
    assert_eq!(
        archived_source["resourceRefs"][0]["resourceId"],
        json!(resource_id)
    );
    assert_eq!(
        listed_archived["details"]["web"]["limits"]["includeArchived"],
        json!(true)
    );

    let inspected = archive
        .invoke_ok(json!({
            "operation": "web_source_inspect",
            "webSourceResourceId": resource_id,
            "webSourceVersionId": archived_web["webSourceVersionId"],
            "idempotencyKey": "web-source-archive-inspect"
        }))
        .await;
    let inspected_source = &inspected["details"]["web"]["source"];
    assert_eq!(inspected_source["state"], json!("archived"));
    assert_eq!(
        inspected_source["archive"]["previousVersionId"],
        archived_payload["archive"]["previousVersionId"]
    );
    assert_eq!(
        inspected_source["byteEvidence"]["sha256"],
        before_payload["byteEvidence"]["sha256"]
    );

    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(
        requests.len(),
        1,
        "archive/list/inspect must not perform network I/O"
    );
}

#[tokio::test]
async fn web_source_archive_rejects_stale_expected_version_without_mutation() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/stale-archive"))
        .respond_with(ResponseTemplate::new(200).set_body_string("stale body"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fetch = WebFixture::new(&ctx, "web-source-archive-stale", "declared").await;
    let fetched = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/stale-archive", server.uri()),
            "idempotencyKey": "web-source-archive-stale-fetch"
        }))
        .await;
    let resource_id = fetched["details"]["web"]["webSourceResourceId"]
        .as_str()
        .expect("resource id")
        .to_owned();
    let first_version_id = fetched["details"]["web"]["webSourceVersionId"]
        .as_str()
        .expect("version id")
        .to_owned();
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
            expected_current_version_id: Some(first_version_id.clone()),
            lifecycle: Some("fetched".to_owned()),
            payload,
            state: None,
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("append stale current");

    let archive = WebFixture::new(&ctx, "web-source-archive-stale", "none").await;
    let error = archive
        .invoke_error(json!({
            "operation": "web_source_archive",
            "webSourceResourceId": resource_id,
            "expectedWebSourceVersionId": first_version_id,
            "reason": "stale check",
            "idempotencyKey": "web-source-archive-stale-key"
        }))
        .await;
    assert!(error.contains("expectedWebSourceVersionId is stale"));
    let after = ctx
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .expect("inspect after")
        .expect("source after");
    assert_eq!(after.resource.lifecycle, "fetched");
    assert_eq!(after.versions.len(), 2);
}

#[tokio::test]
async fn web_source_archive_rejects_wrong_kind_scope_and_missing_authority() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/authority-archive"))
        .respond_with(ResponseTemplate::new(200).set_body_string("authority body"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fetch = WebFixture::new(&ctx, "web-source-archive-auth", "declared").await;
    let fetched = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/authority-archive", server.uri()),
            "idempotencyKey": "web-source-archive-auth-fetch"
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
    let archive = WebFixture::new(&ctx, "web-source-archive-auth", "none").await;

    let wrong_kind = ctx
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some("web_source:archive-wrong-kind".to_owned()),
            kind: "goal".to_owned(),
            schema_id: Some("tron.resource.goal.v1".to_owned()),
            scope: EngineResourceScope::Session(archive.session_id.clone()),
            owner_worker_id: WorkerId::new("web-test").expect("worker id"),
            owner_actor_id: archive.actor_id.clone(),
            lifecycle: Some("open".to_owned()),
            policy: json!({"test": "wrong-kind"}),
            initial_payload: Some(json!({"intent": "wrong kind"})),
            locations: Vec::new(),
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("create wrong-kind resource");
    let wrong_kind_error = archive
        .invoke_error(json!({
            "operation": "web_source_archive",
            "webSourceResourceId": wrong_kind.resource_id,
            "expectedWebSourceVersionId": "ver_missing",
            "reason": "wrong kind",
            "idempotencyKey": "web-source-archive-wrong-kind"
        }))
        .await;
    assert!(wrong_kind_error.contains("resource kind"));

    let cross_session = WebFixture::new(&ctx, "web-source-archive-other", "none").await;
    let cross_session_error = cross_session
        .invoke_error(json!({
            "operation": "web_source_archive",
            "webSourceResourceId": resource_id,
            "expectedWebSourceVersionId": version_id,
            "reason": "wrong session",
            "idempotencyKey": "web-source-archive-cross-session"
        }))
        .await;
    assert!(cross_session_error.contains("outside the current session scope"));

    let no_write = WebFixture::new_with_authority(
        &ctx,
        "web-source-archive-auth",
        "none",
        &["capability.execute", "web.read", "resource.read"],
        &["agent_state", "web_source"],
        &["kind:agent_state", "kind:web_source"],
    )
    .await;
    let authority_error = no_write
        .invoke_error(json!({
            "operation": "web_source_archive",
            "webSourceResourceId": resource_id,
            "expectedWebSourceVersionId": version_id,
            "reason": "missing write authority",
            "idempotencyKey": "web-source-archive-missing-authority"
        }))
        .await;
    assert!(authority_error.contains("web.write") || authority_error.contains("resource.write"));
    let after = ctx
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .expect("inspect after")
        .expect("source after");
    assert_eq!(after.resource.lifecycle, "fetched");
    assert_eq!(after.versions.len(), 1);
}

#[tokio::test]
async fn web_source_archive_replays_same_idempotency_key_without_duplicate_version() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/archive-replay"))
        .respond_with(ResponseTemplate::new(200).set_body_string("replay body"))
        .mount(&server)
        .await;

    let ctx = make_test_context();
    let fetch = WebFixture::new(&ctx, "web-source-archive-replay", "declared").await;
    let fetched = fetch
        .invoke_ok(json!({
            "operation": "web_fetch",
            "url": format!("{}/archive-replay", server.uri()),
            "idempotencyKey": "web-source-archive-replay-fetch"
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
    let archive = WebFixture::new(&ctx, "web-source-archive-replay", "none").await;
    let payload = json!({
        "operation": "web_source_archive",
        "webSourceResourceId": resource_id,
        "expectedWebSourceVersionId": version_id,
        "reason": "replay archive",
        "idempotencyKey": "web-source-archive-replay-key"
    });
    let first = archive.invoke_ok(payload.clone()).await;
    let second_result = archive
        .ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            payload,
            archive.context("web-source-archive-replay-context-key"),
        ))
        .await;
    assert_eq!(
        second_result.error, None,
        "execute failed: {:?}",
        second_result.error
    );
    let second = second_result.value.expect("value");
    assert_eq!(second["isError"], json!(false), "{second}");
    assert_eq!(
        first["details"]["web"]["webSourceVersionId"],
        second["details"]["web"]["webSourceVersionId"]
    );
    assert_eq!(second["details"]["web"]["cache"]["hit"], json!(true));
    let inspection = ctx
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .expect("inspect replay")
        .expect("source replay");
    assert_eq!(
        inspection.versions.len(),
        2,
        "idempotency replay must not duplicate archive versions"
    );
}
