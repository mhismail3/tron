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
async fn primitive_catalog_and_worker_read_functions_share_engine_path() {
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
            .any(|function| function["id"] == "worker::list")
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
            .any(|worker| worker["id"] == "worker")
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
async fn resource_read_primitives_are_visible_to_engine_client_without_write_access() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let client_context = || {
        CausalContext::new(
            actor("engine-client"),
            ActorKind::Client,
            grant("engine-transport"),
            trace("resource-client-read"),
        )
        .with_scope("resource.read")
        .with_scope("resource.write")
        .with_session_id("session-a")
    };

    let listed = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({"functionId": "resource::list", "payload": {"kind": "ui_surface", "limit": 25}}),
            client_context(),
        ))
        .await;
    assert_eq!(listed.error, None, "engine::invoke wraps child outcomes");
    let child = &listed.value.as_ref().unwrap()["child"];
    assert_eq!(child["error"], serde_json::Value::Null);
    assert!(
        child["value"]["resources"].is_array(),
        "engine-client resource::list should return the resource array"
    );

    let create = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "resource::create",
                "payload": {
                    "kind": "ui_surface",
                    "scope": "session",
                    "payload": {"title": "client mutation must not run"}
                },
                "idempotencyKey": "client-resource-create"
            }),
            client_context(),
        ))
        .await;
    assert_eq!(create.error, None, "engine::invoke wraps child outcomes");
    assert!(
        create.value.unwrap()["child"]["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("not visible")),
        "engine-client must not reach resource writes through engine::invoke"
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
async fn public_engine_invoke_cannot_reach_hidden_visibility_targets() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    for (id, visibility) in [
        ("alpha::internal", VisibilityScope::Internal),
        ("alpha::admin", VisibilityScope::Admin),
        ("alpha::worker_only", VisibilityScope::Worker),
    ] {
        host.catalog_mut()
            .register_function(
                FunctionDefinition::new(
                    fid(id),
                    wid("w1"),
                    "hidden function",
                    visibility,
                    EffectClass::PureRead,
                ),
                Some(Arc::new(CountingHandler {
                    calls: calls.clone(),
                })),
                true,
            )
            .unwrap();
    }

    let public_context = || {
        CausalContext::new(
            actor("engine-client"),
            ActorKind::Client,
            grant("engine-transport"),
            trace("public-engine-invoke-hidden"),
        )
        .with_scope("alpha.read")
        .with_scope("alpha.write")
    };

    for target in ["alpha::internal", "alpha::admin", "alpha::worker_only"] {
        let result = host
            .invoke(host_invocation(
                "engine::invoke",
                json!({"functionId": target, "payload": {}}),
                public_context(),
            ))
            .await;
        assert_eq!(result.error, None, "engine::invoke wraps child failures");
        assert!(
            result.value.unwrap()["child"]["error"]["message"]
                .as_str()
                .is_some_and(|message| message.contains("not visible")),
            "{target} should be hidden from public engine::invoke"
        );
    }
    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "hidden target handlers must not run"
    );
}

#[tokio::test]
async fn engine_internal_invoke_scope_does_not_make_public_context_trusted() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::internal"),
                wid("w1"),
                "hidden function",
                VisibilityScope::Internal,
                EffectClass::PureRead,
            ),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let public_raw_scope = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({"functionId": "alpha::internal", "payload": {}}),
            CausalContext::new(
                actor("engine-client"),
                ActorKind::Client,
                grant("engine-transport"),
                trace("public-engine-invoke-raw-internal"),
            )
            .with_scope(crate::engine::ENGINE_INTERNAL_INVOKE_SCOPE),
        ))
        .await;
    assert_eq!(public_raw_scope.error, None);
    assert!(
        public_raw_scope.value.unwrap()["child"]["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("not visible"))
    );
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    let trusted_runtime = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({"functionId": "alpha::internal", "payload": {}}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("engine-system"),
                trace("trusted-engine-invoke-internal"),
            )
            .with_scope(crate::engine::ENGINE_INTERNAL_INVOKE_SCOPE),
        ))
        .await;
    assert_eq!(trusted_runtime.error, None);
    assert_eq!(
        trusted_runtime.value.as_ref().unwrap()["child"]["value"]["call"],
        1
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
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
async fn engine_promote_requires_authority_and_session_ownership() {
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
                "workspaceId": "workspace-a"
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

    let cross_session = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a"
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
                "workspaceId": "workspace-a"
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
                "workspaceId": "workspace-a"
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
                "workspaceId": "workspace-a"
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
                "workspaceId": "workspace-a"
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
