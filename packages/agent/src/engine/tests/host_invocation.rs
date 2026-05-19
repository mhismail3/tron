use super::*;

#[tokio::test]
async fn sync_invocation_succeeds_and_records_revisions() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let function_revision = catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    let invocation = Invocation::new_sync(fid("alpha::read"), json!({"x": 1}), causal())
        .expecting_revision(function_revision);

    let result = catalog.invoke_sync(invocation).await;
    assert!(result.error.is_none());
    assert_eq!(result.function_revision, FunctionRevision(1));
    assert_eq!(result.catalog_revision, catalog.revision());
    assert_eq!(result.value.unwrap()["echo"]["x"], 1);
}

#[tokio::test]
async fn invocation_ledger_records_success_error_and_full_causality() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();

    let parent = super::ids::InvocationId::new("parent-invocation").unwrap();
    let trigger = TriggerId::new("trigger-a").unwrap();
    let invocation = Invocation::new_sync(
        fid("alpha::read"),
        json!({"x": 1}),
        causal()
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_parent_invocation(parent.clone())
            .with_trigger_id(trigger.clone()),
    );
    let result = catalog.invoke_sync(invocation).await;
    assert!(result.error.is_none());

    let missing = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::missing"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(missing.error.is_some());

    let records = catalog.invocations();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].function_id.as_str(), "alpha::read");
    assert_eq!(records[0].actor_id, actor("agent"));
    assert_eq!(records[0].authority_grant_id, grant("grant"));
    assert_eq!(records[0].trace_id, trace("trace"));
    assert_eq!(records[0].parent_invocation_id, Some(parent));
    assert_eq!(records[0].trigger_id, Some(trigger));
    assert_eq!(records[0].delivery_mode, DeliveryMode::Sync);
    assert_eq!(records[0].catalog_revision, catalog.revision());
    assert_eq!(records[0].function_revision, FunctionRevision(1));
    assert!(records[0].succeeded);
    assert!(!records[1].succeeded);
    assert!(matches!(
        records[1].error,
        Some(EngineError::NotFound {
            kind: "function",
            ..
        })
    ));
}

#[tokio::test]
async fn schema_validation_checks_request_and_response_payloads() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let schema = json!({
        "type": "object",
        "required": ["name"],
        "properties": {
            "name": {"type": "string"},
            "count": {"type": "integer"}
        },
        "additionalProperties": false
    });
    catalog
        .register_function(
            read_function("alpha::schema", "w1")
                .with_request_schema(schema)
                .with_response_schema(json!({
                    "type": "object",
                    "required": ["echo"],
                    "properties": {"echo": {"type": "object"}},
                    "additionalProperties": true
                })),
            Some(handler()),
            true,
        )
        .unwrap();

    let missing = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::schema"),
            json!({"count": 1}),
            causal(),
        ))
        .await;
    assert!(matches!(
        missing.error,
        Some(EngineError::SchemaViolation {
            direction: "request",
            ..
        })
    ));

    let wrong_type = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::schema"),
            json!({"name": "ok", "count": 1.25}),
            causal(),
        ))
        .await;
    assert!(matches!(
        wrong_type.error,
        Some(EngineError::SchemaViolation {
            direction: "request",
            ..
        })
    ));

    let valid = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::schema"),
            json!({"name": "ok", "count": 1}),
            causal(),
        ))
        .await;
    assert!(valid.error.is_none());

    let invalid_schema = read_function("alpha::invalid_schema", "w1")
        .with_request_schema(json!({"type": "definitely-not-json-schema"}));
    assert!(matches!(
        catalog.register_function(invalid_schema, Some(handler()), true),
        Err(EngineError::InvalidSchema { .. })
    ));
}

#[tokio::test]
async fn schema_validation_enforces_array_max_items() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::bounded", "w1").with_request_schema(json!({
                "type": "object",
                "required": ["items"],
                "properties": {
                    "items": {
                        "type": "array",
                        "maxItems": 2,
                        "items": {"type": "string"}
                    }
                },
                "additionalProperties": false
            })),
            Some(handler()),
            true,
        )
        .unwrap();

    let valid = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::bounded"),
            json!({"items": ["a", "b"]}),
            causal(),
        ))
        .await;
    assert!(valid.error.is_none());

    let too_many = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::bounded"),
            json!({"items": ["a", "b", "c"]}),
            causal(),
        ))
        .await;
    assert!(matches!(
        too_many.error,
        Some(EngineError::SchemaViolation {
            direction: "request",
            ..
        })
    ));

    let invalid_schema = read_function("alpha::bad_max_items", "w1")
        .with_request_schema(json!({"type": "array", "maxItems": -1}));
    assert!(matches!(
        catalog.register_function(invalid_schema, Some(handler()), true),
        Err(EngineError::InvalidSchema { .. })
    ));
}

#[tokio::test]
async fn schema_validation_enforces_array_max_items_without_items_schema() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::bare_bounded", "w1").with_request_schema(json!({
                "type": "array",
                "maxItems": 1
            })),
            Some(handler()),
            true,
        )
        .unwrap();

    let too_many = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::bare_bounded"),
            json!(["a", "b"]),
            causal(),
        ))
        .await;
    assert!(matches!(
        too_many.error,
        Some(EngineError::SchemaViolation {
            direction: "request",
            ..
        })
    ));
}

#[tokio::test]
async fn host_unregister_function_updates_discovery_and_watch() {
    let host = EngineHostHandle::new_in_memory().unwrap();
    host.register_worker_for_setup(worker("w1", "alpha"), true)
        .unwrap();
    host.register_function_for_setup(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();

    let actor_context = ActorContext::new(actor("system"), ActorKind::System, grant("grant"));
    let query = FunctionQuery {
        actor: Some(actor_context.clone()),
        namespace_prefix: Some("alpha::".to_owned()),
        include_internal: true,
        ..FunctionQuery::default()
    };
    assert_eq!(host.discover(&query).await.len(), 1);

    let before = host
        .watch(&actor_context, CatalogWatchRequest::default())
        .await
        .unwrap()
        .current_revision;
    host.unregister_function(&fid("alpha::read"), &wid("w1"))
        .await
        .unwrap();

    assert!(host.discover(&query).await.is_empty());
    let page = host
        .watch(
            &actor_context,
            CatalogWatchRequest {
                after_revision: before,
                classes: Some(vec![CatalogChangeClass::Availability]),
                subject_prefix: Some("alpha::".to_owned()),
                owner_worker: Some(wid("w1")),
                ..CatalogWatchRequest::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(page.changes.len(), 1);
    assert_eq!(
        page.changes[0].kind,
        CatalogChangeKind::FunctionUnregistered
    );
    assert_eq!(page.changes[0].subject_id, "alpha::read");
}

#[tokio::test]
async fn invocation_returns_structured_errors() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::read", "w1"),
            Some(Arc::new(FailHandler)),
            true,
        )
        .unwrap();

    let missing = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::missing"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(matches!(
        missing.error,
        Some(EngineError::NotFound {
            kind: "function",
            ..
        })
    ));

    let stale = catalog
        .invoke_sync(
            Invocation::new_sync(fid("alpha::read"), json!({}), causal())
                .expecting_revision(FunctionRevision(99)),
        )
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::StaleFunctionRevision {
            expected: 99,
            actual: 1,
            ..
        })
    ));

    let unsupported = catalog
        .invoke_sync(
            Invocation::new_sync(fid("alpha::read"), json!({}), causal())
                .with_delivery_mode(DeliveryMode::Void),
        )
        .await;
    assert!(matches!(
        unsupported.error,
        Some(EngineError::UnsupportedDeliveryMode { mode: "void" })
    ));

    let handler_failure = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::read"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(matches!(
        handler_failure.error,
        Some(EngineError::HandlerFailed(message)) if message == "boom"
    ));
}

#[tokio::test]
async fn invocation_enforces_authority_health_and_idempotency_key() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let function = write_function("alpha::write", "w1")
        .with_required_authority(AuthorityRequirement::scope("write"));
    catalog
        .register_function(function, Some(handler()), true)
        .unwrap();

    let no_scope = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(matches!(
        no_scope.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("idempotency key")
    ));

    let no_key = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            causal().with_scope("write"),
        ))
        .await;
    assert!(matches!(
        no_key.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("idempotency key")
    ));

    let ok = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            mutating_causal("write-1").with_scope("write"),
        ))
        .await;
    assert!(ok.error.is_none());

    catalog
        .register_function(
            write_function("alpha::write", "w1")
                .with_required_authority(AuthorityRequirement::scope("write"))
                .with_health(FunctionHealth::Unhealthy),
            Some(handler()),
            true,
        )
        .unwrap();
    let unhealthy = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            mutating_causal("write-2").with_scope("write"),
        ))
        .await;
    assert!(matches!(
        unhealthy.error,
        Some(EngineError::NotRoutable { .. })
    ));
}

#[tokio::test]
async fn invocation_enforces_visibility_scope() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let session_function = FunctionDefinition::new(
        fid("alpha::session"),
        wid("w1"),
        "session function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a"));
    catalog
        .register_function(session_function, Some(handler()), true)
        .unwrap();

    let hidden = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::session"),
            json!({}),
            causal().with_session_id("session-b"),
        ))
        .await;
    assert!(matches!(
        hidden.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let visible = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::session"),
            json!({}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert!(visible.error.is_none());
}

#[tokio::test]
async fn engine_host_handle_bootstraps_in_memory_host() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    let host = handle.lock().await;
    assert!(host.catalog().worker(&wid("engine")).is_some());
    for id in [
        "engine::discover",
        "engine::inspect",
        "engine::watch",
        "engine::invoke",
        "engine::promote",
    ] {
        assert!(host.catalog().function(&fid(id)).is_some(), "{id}");
    }
}

#[tokio::test]
async fn engine_host_handle_invokes_handlers_without_blocking_discovery() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker(worker("w1", "alpha"), true)
        .await
        .unwrap();

    let started = Arc::new(Barrier::new(2));
    let release = Arc::new(Notify::new());
    handle
        .register_function(
            read_function("alpha::slow", "w1"),
            Some(Arc::new(BlockingHandler {
                started: Arc::clone(&started),
                release: Arc::clone(&release),
            })),
            true,
        )
        .await
        .unwrap();

    let invocation = Invocation::new_sync(fid("alpha::slow"), json!({"x": 1}), causal());
    let running = {
        let handle = handle.clone();
        tokio::spawn(async move { handle.invoke(invocation).await })
    };

    started.wait().await;
    let functions = tokio::time::timeout(
        std::time::Duration::from_millis(100),
        handle.discover(&FunctionQuery {
            actor: Some(ActorContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("grant"),
            )),
            ..FunctionQuery::default()
        }),
    )
    .await
    .expect("discovery should not wait for slow handler");
    assert!(
        functions
            .iter()
            .any(|function| function.id == fid("alpha::slow"))
    );
    handle
        .register_function(
            read_function("alpha::new_read", "w1"),
            Some(handler()),
            true,
        )
        .await
        .expect("catalog updates should not wait for slow handler");

    release.notify_waiters();
    let result = running.await.unwrap();
    assert_eq!(result.value.as_ref().unwrap()["payload"], json!({"x": 1}));
    let host = handle.lock().await;
    assert!(
        result.catalog_revision < host.catalog().revision(),
        "finished invocation should preserve the catalog revision captured before the concurrent update"
    );
}

#[tokio::test]
async fn engine_invoke_meta_does_not_block_discovery_while_child_runs() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker(worker("w1", "alpha"), true)
        .await
        .unwrap();

    let started = Arc::new(Barrier::new(2));
    let release = Arc::new(Notify::new());
    handle
        .register_function(
            read_function("alpha::slow", "w1"),
            Some(Arc::new(BlockingHandler {
                started: Arc::clone(&started),
                release: Arc::clone(&release),
            })),
            true,
        )
        .await
        .unwrap();

    let invocation = Invocation::new_sync(
        fid("engine::invoke"),
        json!({
            "functionId": "alpha::slow",
            "payload": {"x": 1}
        }),
        causal(),
    );
    let running = {
        let handle = handle.clone();
        tokio::spawn(async move { handle.invoke(invocation).await })
    };

    started.wait().await;
    let functions = tokio::time::timeout(
        std::time::Duration::from_millis(100),
        handle.discover(&FunctionQuery {
            actor: Some(ActorContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("grant"),
            )),
            ..FunctionQuery::default()
        }),
    )
    .await
    .expect("engine::invoke child execution should not block discovery");
    assert!(
        functions
            .iter()
            .any(|function| function.id == fid("alpha::slow"))
    );
    handle
        .register_function(
            read_function("alpha::new_read", "w1"),
            Some(handler()),
            true,
        )
        .await
        .expect("catalog updates should not wait for delegated child execution");

    release.notify_waiters();
    let result = running.await.unwrap();
    assert_eq!(
        result.value.as_ref().unwrap()["child"]["value"]["payload"],
        json!({"x": 1})
    );
    let host = handle.lock().await;
    let child_record = host
        .catalog()
        .invocations()
        .iter()
        .find(|record| record.function_id == fid("alpha::slow"))
        .unwrap();
    assert_eq!(
        child_record.parent_invocation_id,
        Some(result.invocation_id.clone())
    );
    assert!(
        child_record.catalog_revision < host.catalog().revision(),
        "delegated child should preserve the catalog revision captured before the concurrent update"
    );
}

#[tokio::test]
async fn engine_host_handle_records_panics_and_replays_panic_errors() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker(worker("w1", "alpha"), true)
        .await
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    #[derive(Clone)]
    struct CountingPanicHandler {
        calls: Arc<AtomicUsize>,
    }
    #[async_trait]
    impl InProcessFunctionHandler for CountingPanicHandler {
        async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
            let _ = self.calls.fetch_add(1, Ordering::SeqCst);
            panic!("panic stored for replay");
        }
    }

    handle
        .register_function(
            write_function("alpha::panic", "w1"),
            Some(Arc::new(CountingPanicHandler {
                calls: Arc::clone(&calls),
            })),
            true,
        )
        .await
        .unwrap();

    let first = handle
        .invoke(Invocation::new_sync(
            fid("alpha::panic"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert!(matches!(
        first.error,
        Some(EngineError::HandlerFailed(message))
            if message.contains("handler panicked") && message.contains("panic stored for replay")
    ));

    let duplicate = handle
        .invoke(Invocation::new_sync(
            fid("alpha::panic"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(duplicate.replayed_from, Some(first.invocation_id));
    assert!(matches!(
        duplicate.error,
        Some(EngineError::StoredInvocationError { message, .. })
            if message.contains("handler failed")
    ));
}

#[tokio::test]
async fn sqlite_engine_host_handle_reopens_watchable_catalog_changes() {
    let dir = tempfile::tempdir().unwrap();
    let ledger_path = dir.path().join("tron.sqlite");
    {
        let handle = super::host::EngineHostHandle::open_sqlite(&ledger_path).unwrap();
        let mut host = handle.lock().await;
        host.catalog_mut()
            .register_worker(worker("w1", "alpha"), true)
            .unwrap();
    }

    let reopened = super::host::EngineHostHandle::open_sqlite(&ledger_path).unwrap();
    let host = reopened.lock().await;
    let changes = host
        .catalog()
        .catalog_changes_after(CatalogRevision(0), 500)
        .unwrap();
    assert!(
        changes
            .iter()
            .any(|change| change.subject_id == "engine::discover")
    );
    assert!(changes.iter().any(|change| change.subject_id == "w1"));
}
