use super::*;

#[test]
fn engine_host_bootstrap_registers_reserved_meta_capabilities_once() {
    let mut host = EngineHost::new().unwrap();
    let initial_revision = host.catalog().revision();
    let engine_worker = host.catalog().worker(&wid("engine")).unwrap();
    assert_eq!(engine_worker.kind, WorkerKind::System);
    assert_eq!(engine_worker.namespace_claims, vec!["engine".to_owned()]);

    for id in [
        "engine::discover",
        "engine::inspect",
        "engine::watch",
        "engine::invoke",
        "engine::promote",
    ] {
        let function = host.catalog().function(&fid(id)).unwrap();
        assert_eq!(function.owner_worker, wid("engine"));
        assert_eq!(function.visibility, VisibilityScope::System);
    }

    host.bootstrap_meta_capabilities().unwrap();
    assert_eq!(host.catalog().revision(), initial_revision);
}

#[tokio::test]
async fn storage_primitives_report_and_checkpoint_unified_sqlite_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();

    let stats = handle
        .invoke(Invocation::new_sync(
            fid("storage::stats"),
            json!({}),
            causal().with_scope("storage.read"),
        ))
        .await;
    assert_eq!(stats.error, None);
    assert_eq!(
        stats.value.as_ref().unwrap()["stats"]["databasePath"],
        path.to_string_lossy().as_ref()
    );

    let checkpoint = handle
        .invoke(Invocation::new_sync(
            fid("storage::checkpoint"),
            json!({}),
            causal()
                .with_scope("storage.write")
                .with_session_id("session-a")
                .with_idempotency_key("storage-checkpoint-test"),
        ))
        .await;
    assert_eq!(checkpoint.error, None);
    assert_eq!(
        checkpoint.value.as_ref().unwrap()["checkpoint"]["databasePath"],
        path.to_string_lossy().as_ref()
    );
}

#[tokio::test]
async fn observability_log_query_reads_storage_logs_and_expands_payloads_only_when_requested() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    {
        let runtime = crate::shared::storage::StorageRuntime::new(&path);
        let conn = runtime.open_connection().unwrap();
        conn.execute_batch(
            "CREATE TABLE logs (
                id INTEGER PRIMARY KEY,
                timestamp TEXT NOT NULL,
                level TEXT NOT NULL,
                level_num INTEGER NOT NULL,
                component TEXT NOT NULL DEFAULT '',
                message TEXT DEFAULT '',
                session_id TEXT,
                workspace_id TEXT,
                event_id TEXT,
                turn INTEGER,
                trace_id TEXT,
                parent_trace_id TEXT,
                depth INTEGER,
                data TEXT,
                error_message TEXT,
                error_stack TEXT,
                origin TEXT
            );",
        )
        .unwrap();
        let data = crate::shared::storage::store_json_bytes(
            &conn,
            serde_json::json!({"items": vec!["logged"; 2048]})
                .to_string()
                .as_bytes(),
            &crate::shared::storage::StorePayloadOptions::new(
                "log_entry",
                "log-query-row",
                "data",
                "diagnostic_verbose",
            )
            .with_scope(
                Some("trace-log".to_owned()),
                Some("session-log".to_owned()),
                Some("workspace-log".to_owned()),
            )
            .with_inline_threshold(1),
        )
        .unwrap();
        conn.execute(
            "INSERT INTO logs (
                timestamp, level, level_num, component, message, session_id,
                workspace_id, trace_id, data, origin
             ) VALUES (?1, 'debug', 20, 'StorageTest', 'large log payload',
                       'session-log', 'workspace-log', 'trace-log', ?2, 'test')",
            rusqlite::params![chrono::Utc::now().to_rfc3339(), data],
        )
        .unwrap();
    }

    let compact = handle
        .invoke(Invocation::new_sync(
            fid("observability::log_query"),
            json!({"traceId": "trace-log", "includeFullPayloads": false}),
            causal().with_scope("observability.read"),
        ))
        .await;
    assert_eq!(compact.error, None);
    let compact_logs = compact.value.as_ref().unwrap()["logs"].as_array().unwrap();
    assert_eq!(compact_logs.len(), 1);
    assert!(
        compact_logs[0]["data"]
            .get(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY)
            .is_some()
    );

    let expanded = handle
        .invoke(Invocation::new_sync(
            fid("observability::log_query"),
            json!({"traceId": "trace-log", "includeFullPayloads": true}),
            causal().with_scope("observability.read"),
        ))
        .await;
    assert_eq!(expanded.error, None);
    let expanded_logs = expanded.value.as_ref().unwrap()["logs"].as_array().unwrap();
    assert_eq!(expanded_logs.len(), 1);
    assert_eq!(
        expanded_logs[0]["data"]["items"]
            .as_array()
            .unwrap()
            .first()
            .and_then(Value::as_str),
        Some("logged")
    );
}

#[tokio::test]
async fn engine_meta_discover_and_inspect_are_live_and_scope_checked() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            read_function("alpha::public", "w1").with_tags(vec!["visible".to_owned()]),
            Some(handler()),
            true,
        )
        .unwrap();
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::session"),
                wid("w1"),
                "session function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )
            .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a")),
            Some(handler()),
            true,
        )
        .unwrap();

    let session_a = causal().with_session_id("session-a");
    let discovered = host
        .invoke(host_invocation(
            "engine::discover",
            json!({"namespacePrefix": "alpha"}),
            session_a.clone(),
        ))
        .await;
    assert_eq!(discovered.error, None);
    let functions = discovered.value.unwrap()["functions"]
        .as_array()
        .unwrap()
        .clone();
    let ids: Vec<&str> = functions
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&"alpha::public"));
    assert!(ids.contains(&"alpha::session"));

    let hidden = host
        .invoke(host_invocation(
            "engine::inspect",
            json!({"kind": "function", "id": "alpha::session"}),
            causal().with_session_id("session-b"),
        ))
        .await;
    assert!(matches!(
        hidden.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let malformed = host
        .invoke(host_invocation(
            "engine::inspect",
            json!({"kind": "function"}),
            session_a,
        ))
        .await;
    assert!(matches!(
        malformed.error,
        Some(EngineError::SchemaViolation { .. })
    ));
}

#[tokio::test]
async fn primitive_catalog_worker_and_observability_functions_share_engine_path() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let system_context = |trace_id: &str, scope: &str| {
        CausalContext::new(
            actor("system"),
            ActorKind::System,
            grant("system-grant"),
            trace(trace_id),
        )
        .with_scope(scope)
    };

    let catalog = handle
        .invoke(host_invocation(
            "catalog::list",
            json!({"includeInternal": true}),
            system_context("primitive-trace", "catalog.read"),
        ))
        .await;
    assert_eq!(catalog.error, None);
    assert!(
        catalog.value.as_ref().unwrap()["functions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|function| function["id"] == "observability::trace_get")
    );

    let workers = handle
        .invoke(host_invocation(
            "worker::list",
            json!({}),
            system_context("primitive-trace", "worker.read"),
        ))
        .await;
    assert_eq!(workers.error, None);
    assert!(
        workers.value.as_ref().unwrap()["workers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|worker| worker["id"] == "observability")
    );

    let guide = handle
        .invoke(host_invocation(
            "worker::protocol_guide",
            json!({
                "functionId": "demo::echo",
                "workerId": "demo-echo-worker",
                "language": "python"
            }),
            system_context("primitive-trace", "worker.read"),
        ))
        .await;
    assert_eq!(guide.error, None);
    let guide_value = guide.value.as_ref().unwrap();
    assert_eq!(guide_value["protocolVersion"], 1);
    assert_eq!(
        guide_value["environment"]["TRON_ENGINE_BEARER_TOKEN"],
        "Bearer token injected by worker::spawn; send it as Authorization: Bearer <token>"
    );
    let template = guide_value["pythonTemplate"].as_str().unwrap();
    assert!(template.contains("Authorization: Bearer"));
    assert!(template.contains("import select"));
    assert!(template.contains("select.select([sock], [], [], 0.25)"));
    assert!(template.contains("\"type\": \"register_function\""));
    assert!(
        template.find("catalog_snapshot").unwrap() < template.find("register_function").unwrap(),
        "worker template must wait for the hello catalog snapshot before registering functions"
    );
    assert!(template.contains("\"output_contract\": {\"kind\": \"none\"}"));
    assert!(template.contains("\"sequence\": heartbeat_sequence"));
    assert!(template.contains("demo::echo"));
    assert!(template.contains("endpoint = \"ws://\" + endpoint"));
    assert!(template.contains("must target /engine/workers"));
    let rules = guide_value["rules"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|rule| rule.as_str())
        .collect::<Vec<_>>();
    assert!(
        rules
            .iter()
            .any(|rule| rule.contains("Copy pythonTemplate as-is"))
    );
    assert!(
        rules
            .iter()
            .any(|rule| rule.contains("Do not hand-roll WebSocket framing"))
    );

    let node_guide = handle
        .invoke(host_invocation(
            "worker::protocol_guide",
            json!({
                "functionId": "demo::echo",
                "workerId": "demo-echo-worker",
                "language": "node"
            }),
            system_context("primitive-trace-node", "worker.read"),
        ))
        .await;
    assert_eq!(node_guide.error, None);
    let node_guide_value = node_guide.value.as_ref().unwrap();
    assert_eq!(node_guide_value["requestedLanguage"], "node");
    assert_eq!(node_guide_value["templateLanguage"], "python");
    assert!(
        node_guide_value["pythonTemplate"]
            .as_str()
            .unwrap()
            .contains("demo::echo")
    );

    let trace_id = trace("primitive-trace");
    let parent_invocation_id = InvocationId::generate();
    let lease = handle
        .acquire_resource_lease(AcquireResourceLease {
            resource_kind: "test-resource".to_owned(),
            resource_id: "primitive-trace-resource".to_owned(),
            holder_invocation_id: parent_invocation_id.clone(),
            function_id: fid("test::write"),
            actor_id: actor("system"),
            authority_grant_id: grant("system-grant"),
            trace_id: trace_id.clone(),
            parent_invocation_id: Some(parent_invocation_id.clone()),
            idempotency_key: Some("primitive-trace-lease".to_owned()),
            ttl_ms: 30_000,
        })
        .await
        .unwrap();
    let stream_cursor = handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "test.observability".to_owned(),
            payload: json!({"ok": true}),
            visibility: VisibilityScope::System,
            session_id: None,
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace_id),
            parent_invocation_id: Some(parent_invocation_id),
        })
        .await
        .unwrap();

    let trace_get = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": "primitive-trace"}),
            system_context("observability-query", "observability.read"),
        ))
        .await;
    assert_eq!(trace_get.error, None);
    assert!(
        trace_get.value.as_ref().unwrap()["summary"]["streamCount"]
            .as_u64()
            .unwrap()
            >= 1
    );
    assert_eq!(
        trace_get.value.as_ref().unwrap()["summary"]["leaseCount"],
        1
    );
    let invocations = trace_get.value.as_ref().unwrap()["invocations"]
        .as_array()
        .unwrap();
    assert!(
        invocations
            .iter()
            .any(|record| record["functionId"] == "catalog::list")
    );
    assert!(
        trace_get.value.as_ref().unwrap()["streams"]
            .as_array()
            .unwrap()
            .iter()
            .any(|event| event["cursor"] == stream_cursor.0)
    );
    assert!(
        trace_get.value.as_ref().unwrap()["leases"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["leaseId"] == lease.lease_id)
    );

    let spans = handle
        .invoke(host_invocation(
            "observability::span_list",
            json!({"traceId": "primitive-trace"}),
            system_context("observability-query", "observability.read"),
        ))
        .await;
    assert_eq!(spans.error, None);
    assert!(
        spans.value.as_ref().unwrap()["spans"]
            .as_array()
            .unwrap()
            .iter()
            .any(|span| span["functionId"] == "worker::list")
    );
    assert!(
        spans.value.as_ref().unwrap()["spans"]
            .as_array()
            .unwrap()
            .iter()
            .any(|span| span["kind"] == "stream" && span["topic"] == "test.observability")
    );
    assert!(
        spans.value.as_ref().unwrap()["spans"]
            .as_array()
            .unwrap()
            .iter()
            .any(|span| span["kind"] == "resource_lease"
                && span["resourceId"] == "primitive-trace-resource")
    );

    let stream_logs = handle
        .invoke(host_invocation(
            "observability::log_query",
            json!({"traceId": "primitive-trace", "text": "stream"}),
            system_context("observability-query", "observability.read"),
        ))
        .await;
    assert_eq!(stream_logs.error, None);
    let logs = stream_logs.value.as_ref().unwrap()["logs"]
        .as_array()
        .unwrap();
    assert!(
        logs.iter()
            .any(|log| log["kind"] == "stream" && log["topic"] == "test.observability")
    );

    let metrics = handle
        .invoke(host_invocation(
            "observability::metrics_snapshot",
            json!({}),
            system_context("observability-query", "observability.read"),
        ))
        .await;
    assert_eq!(metrics.error, None);
    assert!(
        metrics.value.as_ref().unwrap()["metrics"]["workers"]
            .as_u64()
            .unwrap()
            >= 1
    );
    assert!(
        metrics.value.as_ref().unwrap()["metrics"]["traces"]
            .as_u64()
            .unwrap()
            >= 1
    );

    let delegated_metrics = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "observability::metrics_snapshot",
                "payload": {},
            }),
            system_context("observability-query-delegated", "observability.read"),
        ))
        .await;
    assert_eq!(delegated_metrics.error, None);
    let delegated_child = &delegated_metrics.value.as_ref().unwrap()["child"];
    assert_eq!(delegated_child["error"], Value::Null);
    assert!(
        delegated_child["value"]["metrics"]["workers"]
            .as_u64()
            .unwrap()
            >= 1
    );
}

#[tokio::test]
async fn catalog_read_primitives_are_visible_to_engine_client() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let client_context = CausalContext::new(
        actor("engine-client"),
        ActorKind::Client,
        grant("engine-transport"),
        trace("catalog-client-read"),
    )
    .with_scope("catalog.read");

    let list = handle
        .invoke(host_invocation(
            "catalog::list",
            json!({"includeInternal": true}),
            client_context.clone(),
        ))
        .await;
    assert_eq!(list.error, None);
    assert!(
        list.value.as_ref().unwrap()["functions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|function| function["id"] == "catalog::watch_snapshot")
    );

    let inspect = handle
        .invoke(host_invocation(
            "catalog::inspect",
            json!({"kind": "function", "id": "catalog::watch_snapshot"}),
            client_context.clone(),
        ))
        .await;
    assert_eq!(inspect.error, None);
    assert_eq!(
        inspect.value.as_ref().unwrap()["definition"]["id"],
        "catalog::watch_snapshot"
    );

    let snapshot = handle
        .invoke(host_invocation(
            "catalog::watch_snapshot",
            json!({"limit": 10}),
            client_context,
        ))
        .await;
    assert_eq!(snapshot.error, None);
    assert!(
        snapshot.value.as_ref().unwrap()["snapshot"]["functions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|function| function["id"] == "catalog::watch_snapshot")
    );
}

#[tokio::test]
async fn engine_watch_filters_catalog_changes_without_leaking_hidden_scopes() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(read_function("alpha::public", "w1"), Some(handler()), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::session"),
                wid("w1"),
                "session function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )
            .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a")),
            Some(handler()),
            true,
        )
        .unwrap();
    let future_revision = host.catalog().revision().0 + 10;

    let visible = host
        .invoke(host_invocation(
            "engine::watch",
            json!({
                "afterRevision": 0,
                "classes": ["availability"],
                "subjectPrefix": "alpha::",
                "limit": 10
            }),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(visible.error, None);
    let changes = visible.value.unwrap()["changes"]
        .as_array()
        .unwrap()
        .clone();
    assert!(changes.iter().any(|change| {
        change["subjectId"] == "alpha::public"
            && change["subjectKind"] == "function"
            && change["class"] == "availability"
    }));
    assert!(changes.iter().any(|change| {
        change["subjectId"] == "alpha::session" && change["sessionId"] == "session-a"
    }));

    let hidden = host
        .invoke(host_invocation(
            "engine::watch",
            json!({"afterRevision": 0, "subjectPrefix": "alpha::", "limit": 10}),
            causal().with_session_id("session-b"),
        ))
        .await;
    assert_eq!(hidden.error, None);
    let hidden_changes = hidden.value.unwrap()["changes"].as_array().unwrap().clone();
    assert!(
        hidden_changes
            .iter()
            .all(|change| change["subjectId"] != "alpha::session")
    );

    host.catalog_mut()
        .unregister_function(&fid("alpha::session"), &wid("w1"))
        .unwrap();
    let removal = host
        .invoke(host_invocation(
            "engine::watch",
            json!({"afterRevision": 0, "kinds": ["function_unregistered"]}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(removal.error, None);
    assert!(
        removal.value.unwrap()["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|change| change["subjectId"] == "alpha::session")
    );

    let future = host
        .invoke(host_invocation(
            "engine::watch",
            json!({"afterRevision": future_revision}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(future.error, None);
    let future_value = future.value.unwrap();
    assert_eq!(future_value["changes"].as_array().unwrap().len(), 0);
    assert_eq!(future_value["currentRevision"], host.catalog().revision().0);

    let zero_limit = host
        .invoke(host_invocation(
            "engine::watch",
            json!({"afterRevision": 0, "limit": 0}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert!(matches!(
        zero_limit.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("limit")
    ));
}

#[tokio::test]
async fn engine_invoke_delegates_with_parent_causality_and_target_policy() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    host.catalog_mut()
        .register_function(
            write_function("alpha::write", "w1"),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let missing_key = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({"functionId": "alpha::write", "payload": {"x": 1}}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(missing_key.error, None);
    assert!(
        missing_key.value.unwrap()["child"]["error"]["message"]
            .as_str()
            .unwrap()
            .contains("idempotency key")
    );
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    let first = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "alpha::write",
                "payload": {"x": 1},
                "idempotencyKey": "child-key"
            }),
            causal()
                .with_session_id("session-a")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(first.error, None);
    assert_eq!(first.value.as_ref().unwrap()["child"]["value"]["call"], 1);

    let replay = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "alpha::write",
                "payload": {"x": 1},
                "idempotencyKey": "child-key"
            }),
            causal()
                .with_session_id("session-a")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.value.as_ref().unwrap()["child"]["value"]["call"], 1);
    assert!(replay.value.unwrap()["child"]["replayedFrom"].is_string());
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let child_records: Vec<_> = host
        .catalog()
        .invocations()
        .iter()
        .filter(|record| record.function_id == fid("alpha::write"))
        .collect();
    assert!(
        child_records
            .iter()
            .all(|record| record.parent_invocation_id.is_some())
    );
}

#[tokio::test]
async fn engine_invoke_reports_target_errors_in_child_envelope() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            read_function("alpha::fail", "w1"),
            Some(Arc::new(FailHandler)),
            true,
        )
        .unwrap();

    let result = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({"functionId": "alpha::fail", "payload": {}}),
            causal(),
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        result.value.unwrap()["child"]["error"]["kind"],
        "handler_failed"
    );
}

#[tokio::test]
async fn engine_promote_requires_authority_revision_and_session_ownership() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::session"),
                wid("w1"),
                "session function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )
            .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a")),
            Some(handler()),
            true,
        )
        .unwrap();

    let no_promote_grant = host
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "no-promote-grant",
                "parentGrantId": "grant",
                "allowedCapabilities": ["engine::discover"],
                "allowedNamespaces": ["engine"],
                "allowedAuthorityScopes": ["engine.discover"],
                "allowedResourceKinds": ["*"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "critical"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("promote-grant-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-no-promote"),
        ))
        .await;
    assert_eq!(no_promote_grant.error, None);

    let no_scope = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("no-promote-grant"),
                trace("promote-no-grant"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_scope("engine.promote")
            .with_idempotency_key("promote-no-scope"),
        ))
        .await;
    assert!(matches!(
        no_scope.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow function")
                || message.contains("does not allow required authority")
    ));

    let stale = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 2
            }),
            mutating_causal("promote-stale").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::StaleFunctionRevision { .. })
    ));

    let cross_session = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            causal()
                .with_session_id("session-b")
                .with_workspace_id("workspace-a")
                .with_idempotency_key("promote-cross")
                .with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        cross_session.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("session")
    ));

    let promoted = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-ok").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert_eq!(promoted.error, None);
    assert_eq!(promoted.value.as_ref().unwrap()["revision"], 2);
    let function = host.catalog().function(&fid("alpha::session")).unwrap();
    assert_eq!(function.visibility, VisibilityScope::Workspace);
    assert_eq!(function.provenance.session_id, None);
    assert_eq!(
        function.provenance.workspace_id.as_deref(),
        Some("workspace-a")
    );

    let replay = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-ok").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.replayed_from, Some(promoted.invocation_id));
    assert_eq!(replay.value.as_ref().unwrap()["revision"], 2);
    assert_eq!(
        host.catalog()
            .function(&fid("alpha::session"))
            .unwrap()
            .revision,
        FunctionRevision(2)
    );
}

#[tokio::test]
async fn engine_promote_conflicting_duplicate_key_does_not_mutate_new_target() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    for id in ["alpha::one", "alpha::two"] {
        host.catalog_mut()
            .register_function(
                FunctionDefinition::new(
                    fid(id),
                    wid("w1"),
                    "session function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(
                    Provenance::new(actor("agent"), "test").with_session_id("session-a"),
                ),
                Some(handler()),
                true,
            )
            .unwrap();
    }

    let first = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::one",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-shared-key").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert_eq!(first.error, None);

    let conflict = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::two",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-shared-key").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    assert_eq!(
        host.catalog()
            .function(&fid("alpha::two"))
            .unwrap()
            .visibility,
        VisibilityScope::Session
    );
}
