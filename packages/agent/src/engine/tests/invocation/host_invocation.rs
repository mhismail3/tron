use super::*;

#[tokio::test]
async fn sync_invocation_succeeds_and_records_revisions() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_function(read_function("alpha::read", "w1"), handler())
        .unwrap();
    let invocation = Invocation::new_sync(fid("alpha::read"), json!({"x": 1}), causal());

    let result = catalog.invoke_sync(invocation).await;
    assert!(result.error.is_none());
    assert_eq!(result.function_revision, FunctionRevision(1));
    assert_eq!(result.catalog_revision, catalog.revision());
    assert_eq!(result.value.unwrap()["echo"]["x"], 1);
}

#[tokio::test]
async fn invocation_rejects_a_function_surface_that_changed_after_advertisement() {
    let mut catalog = LiveCatalog::new();
    let mut first = read_function("alpha::read", "w1");
    first.model_tool = Some(crate::engine::ModelToolContract {
        name: "worker_alpha".to_owned(),
        callable: true,
        order: None,
        group: None,
        worker: Some(crate::engine::DirectWorkerToolContract {
            worker_id: "alpha".to_owned(),
            worker_name: "Alpha".to_owned(),
            worker_version: "worker-v1".to_owned(),
            updated_at: String::new(),
            intents: Vec::new(),
            examples: Vec::new(),
            provenance: Vec::new(),
        }),
    });
    let advertised_revision = catalog.register_function(first.clone(), handler()).unwrap();

    let mut second = first;
    second
        .model_tool
        .as_mut()
        .and_then(|tool| tool.worker.as_mut())
        .expect("worker tool")
        .worker_version = "worker-v2".to_owned();
    let current_revision = catalog.register_function(second, handler()).unwrap();
    let invocation = Invocation::new_sync(
        fid("alpha::read"),
        json!({"x": 1}),
        causal().with_advertised_function(advertised_revision, Some("worker-v1".to_owned())),
    );

    let result = catalog.invoke_sync(invocation).await;

    assert!(matches!(
        result.error,
        Some(EngineError::StaleFunctionSurface {
            expected_revision,
            actual_revision,
            ref expected_worker_version,
            ref actual_worker_version,
            ..
        }) if expected_revision == advertised_revision.0
            && actual_revision == current_revision.0
            && expected_worker_version.as_deref() == Some("worker-v1")
            && actual_worker_version.as_deref() == Some("worker-v2")
    ));
    assert_eq!(catalog.ledger_invocations().unwrap().len(), 1);
}

#[tokio::test]
async fn invocation_ledger_records_success_error_and_full_causality() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_function(read_function("alpha::read", "w1"), handler())
        .unwrap();

    let parent = super::ids::InvocationId::new("parent-invocation").unwrap();
    let invocation = Invocation::new_sync(
        fid("alpha::read"),
        json!({"x": 1}),
        causal()
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_parent_invocation(parent.clone()),
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

    let records = catalog.ledger_invocations().unwrap();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].function_id.as_str(), "alpha::read");
    assert_eq!(records[0].actor_id, actor("agent"));
    assert_eq!(records[0].trace_id, trace("trace"));
    assert_eq!(records[0].parent_invocation_id, Some(parent));
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
            handler(),
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
        catalog.register_function(invalid_schema, handler()),
        Err(EngineError::InvalidSchema { .. })
    ));
}

#[tokio::test]
async fn schema_validation_enforces_array_max_items() {
    let mut catalog = LiveCatalog::new();
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
            handler(),
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
        catalog.register_function(invalid_schema, handler()),
        Err(EngineError::InvalidSchema { .. })
    ));
}

#[tokio::test]
async fn schema_validation_enforces_array_max_items_without_items_schema() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_function(
            read_function("alpha::bare_bounded", "w1").with_request_schema(json!({
                "type": "array",
                "maxItems": 1
            })),
            handler(),
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
async fn host_unregister_function_updates_discovery() {
    let host = EngineHostHandle::new_in_memory().unwrap();
    host.register_function_for_setup(read_function("alpha::read", "w1"), handler())
        .unwrap();

    let actor_context = ActorContext::new(actor("system"), ActorKind::System);
    assert_eq!(host.visible_functions(&actor_context).await.len(), 1);

    host.unregister_function(&fid("alpha::read"), &wid("w1"))
        .await
        .unwrap();

    assert!(host.visible_functions(&actor_context).await.is_empty());
}

#[tokio::test]
async fn invocation_returns_structured_errors() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_function(read_function("alpha::read", "w1"), Arc::new(FailHandler))
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
async fn invocation_enforces_health_and_idempotency_key() {
    let mut catalog = LiveCatalog::new();
    let function = write_function("alpha::write", "w1");
    catalog.register_function(function, handler()).unwrap();

    let no_key = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            causal(),
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
            mutating_causal("write-1"),
        ))
        .await;
    assert!(ok.error.is_none());

    catalog
        .register_function(
            write_function("alpha::write", "w1").with_health(FunctionHealth::Unhealthy),
            handler(),
        )
        .unwrap();
    let unhealthy = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            mutating_causal("write-2"),
        ))
        .await;
    assert!(matches!(
        unhealthy.error,
        Some(EngineError::NotRoutable { .. })
    ));
}

#[tokio::test]
async fn invocation_enforces_internal_function_boundary() {
    let mut catalog = LiveCatalog::new();
    let internal_function = FunctionDefinition::new(
        fid("alpha::internal"),
        wid("w1"),
        "internal function",
        FunctionVisibility::Internal,
        EffectClass::PureRead,
    );
    catalog
        .register_function(internal_function, handler())
        .unwrap();

    let hidden = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::internal"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(matches!(
        hidden.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let visible = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::internal"),
            json!({}),
            CausalContext::new(actor("system"), ActorKind::System, trace("system-trace")),
        ))
        .await;
    assert!(visible.error.is_none());
}

#[tokio::test]
async fn engine_host_handle_starts_without_registered_wrapper_functions() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    let host = handle.lock().await;
    assert!(host.catalog().function(&fid("engine::invoke")).is_none());
}

#[tokio::test]
async fn engine_host_handle_invokes_handlers_without_blocking_discovery() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    let started = Arc::new(Barrier::new(2));
    let release = Arc::new(Notify::new());
    handle
        .register_function(
            read_function("alpha::slow", "w1"),
            Arc::new(BlockingHandler {
                started: Arc::clone(&started),
                release: Arc::clone(&release),
            }),
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
        handle.visible_functions(&ActorContext::new(actor("agent"), ActorKind::Agent)),
    )
    .await
    .expect("discovery should not wait for slow handler");
    assert!(
        functions
            .iter()
            .any(|function| function.id == fid("alpha::slow"))
    );
    handle
        .register_function(read_function("alpha::new_read", "w1"), handler())
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
async fn engine_host_handle_records_panics_and_replays_panic_errors() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
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
            Arc::new(CountingPanicHandler {
                calls: Arc::clone(&calls),
            }),
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
async fn regular_cancellation_records_and_replays_typed_error() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let started = Arc::new(Barrier::new(2));
    handle
        .register_function_for_setup(
            write_function("alpha::cancellable", "w1")
                .with_idempotency(IdempotencyContract::session()),
            Arc::new(BlockingHandler {
                started: Arc::clone(&started),
                release: Arc::new(Notify::new()),
            }),
        )
        .unwrap();

    let cancellation = tokio_util::sync::CancellationToken::new();
    let invocation = Invocation::new_sync(
        fid("alpha::cancellable"),
        json!({"sessionId": "session-a"}),
        mutating_causal("cancel-key"),
    );
    let running = {
        let handle = handle.clone();
        let cancellation = cancellation.clone();
        tokio::spawn(async move {
            handle
                .invoke_regular_cancellable(invocation, &cancellation)
                .await
                .expect("regular cancellable invocation")
        })
    };

    started.wait().await;
    cancellation.cancel();
    let first = running.await.unwrap();
    assert_eq!(first.error, Some(EngineError::InvocationCancelled));

    let first_record = {
        let host = handle.lock().await;
        host.catalog()
            .ledger_invocations()
            .unwrap()
            .into_iter()
            .find(|record| record.invocation_id == first.invocation_id)
            .expect("cancelled invocation record")
    };
    assert!(!first_record.succeeded);
    assert_eq!(first_record.error, Some(EngineError::InvocationCancelled));

    let replay = tokio::time::timeout(
        std::time::Duration::from_millis(100),
        handle.invoke(Invocation::new_sync(
            fid("alpha::cancellable"),
            json!({"sessionId": "session-a"}),
            mutating_causal("cancel-key"),
        )),
    )
    .await
    .expect("idempotent replay must not re-enter the blocking handler");
    assert_eq!(replay.replayed_from, Some(first.invocation_id));
    assert_eq!(replay.error, Some(EngineError::InvocationCancelled));
}

#[tokio::test]
async fn sqlite_engine_host_handle_reopens_catalog_revision() {
    let dir = tempfile::tempdir().unwrap();
    let ledger_path = dir.path().join("tron.sqlite");
    {
        let handle = super::host::EngineHostHandle::open_sqlite(&ledger_path).unwrap();
        let mut host = handle.lock().await;
        host.catalog_mut()
            .register_function(read_function("alpha::read", "w1"), handler())
            .unwrap();
    }

    let reopened = super::host::EngineHostHandle::open_sqlite(&ledger_path).unwrap();
    let host = reopened.lock().await;
    assert_eq!(host.catalog().revision(), CatalogRevision(1));
}
