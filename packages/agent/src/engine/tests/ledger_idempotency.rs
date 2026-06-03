use super::*;

#[test]
fn in_memory_and_sqlite_ledgers_share_storage_contract() {
    let mut memory = InMemoryEngineLedgerStore::new();
    engine_ledger_contract(&mut memory);

    let mut sqlite = SqliteEngineLedgerStore::open_in_memory().unwrap();
    engine_ledger_contract(&mut sqlite);
}

#[test]
fn sqlite_engine_ledger_persists_records_across_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");

    {
        let mut store = SqliteEngineLedgerStore::open(&db_path).unwrap();
        engine_ledger_contract(&mut store);
    }

    let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
    assert_eq!(store.list_catalog_changes().unwrap().len(), 1);
    assert_eq!(store.list_invocations().unwrap().len(), 1);

    let reservation = IdempotencyReservation {
        key: IdempotencyKey {
            function_id: fid("alpha::write"),
            scope: IdempotencyScope::new("session", "session-a"),
            key: "dedupe-key".to_owned(),
        },
        payload_fingerprint: "fingerprint-a".to_owned(),
        function_revision: FunctionRevision(1),
        replay_behavior: ReplayBehavior::ReturnPrevious,
        invocation_id: super::ids::InvocationId::new("reservation-two").unwrap(),
    };
    let existing = store
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM engine_idempotency_entries WHERE idempotency_key = 'dedupe-key'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(existing, 1);
    let mut reopened = SqliteEngineLedgerStore::open(&db_path).unwrap();
    assert!(matches!(
        reopened.reserve_idempotency(reservation).unwrap(),
        IdempotencyReservationOutcome::Existing(entry)
            if entry.status == IdempotencyStatus::Completed
    ));
}

#[test]
fn sqlite_engine_ledger_blobs_large_results_but_replays_public_value() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let large = json!({"items": vec!["same payload"; 2048]});
    let invocation = Invocation::new_sync(
        fid("alpha::large"),
        json!({}),
        causal()
            .with_session_id("session-large")
            .with_workspace_id("workspace-large"),
    );
    let result = crate::engine::invocation::InvocationResult::success(
        &invocation,
        wid("w1"),
        FunctionRevision(1),
        CatalogRevision(1),
        large.clone(),
    );
    let record =
        crate::engine::invocation::InvocationRecord::from_result(&invocation, &result, None);

    {
        let mut store = SqliteEngineLedgerStore::open(&db_path).unwrap();
        store.append_invocation(&record).unwrap();
        let stored: String = store
            .connection()
            .query_row(
                "SELECT result_json FROM engine_invocations WHERE invocation_id = ?1",
                [invocation.id.as_str()],
                |row| row.get(0),
            )
            .unwrap();
        assert!(stored.contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY));
    }

    let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
    let records = store.list_invocations().unwrap();
    assert_eq!(records[0].result_value, Some(large));
    let refs: i64 = store
        .connection()
        .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
            row.get(0)
        })
        .unwrap();
    let blobs: i64 = store
        .connection()
        .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
        .unwrap();
    assert_eq!(refs, 1);
    assert_eq!(blobs, 1);
}

#[test]
fn sqlite_queue_blobs_large_payload_but_claim_returns_original_payload() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let large = json!({"items": vec!["queued"; 2048]});
    let mut store = super::queue::SqliteEngineQueueStore::open(&db_path).unwrap();
    let item = store
        .enqueue(super::queue::EnqueueInvocation {
            queue: "agent".to_owned(),
            function_id: fid("agent::run_turn"),
            target_revision: Some(FunctionRevision(1)),
            payload: large.clone(),
            actor_id: actor("agent"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: grant("grant"),
            authority_scopes: vec!["agent.run".to_owned()],
            runtime_metadata: Default::default(),
            trace_id: TraceId::generate(),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some("session-queue".to_owned()),
            workspace_id: Some("workspace-queue".to_owned()),
            idempotency_key: Some("queue-key".to_owned()),
        })
        .unwrap();
    let stored: String = store
        .connection()
        .query_row(
            "SELECT payload_json FROM engine_queue_items WHERE receipt_id = ?1",
            [item.receipt_id.as_str()],
            |row| row.get(0),
        )
        .unwrap();
    assert!(stored.contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY));
    let claimed = store.claim("agent", "test", 1000).unwrap().unwrap();
    assert_eq!(claimed.payload, large);
}

#[test]
fn sqlite_stream_blobs_large_payload_but_poll_returns_original_payload() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let large = json!({"items": vec!["streamed"; 2048]});
    let mut store = SqliteEngineStreamStore::open(&db_path).unwrap();
    store
        .publish(PublishStreamEvent {
            topic: "agent.runtime".to_owned(),
            payload: large.clone(),
            visibility: VisibilityScope::Session,
            session_id: Some("session-stream".to_owned()),
            workspace_id: Some("workspace-stream".to_owned()),
            producer: "agent".to_owned(),
            trace_id: Some(TraceId::generate()),
            parent_invocation_id: None,
        })
        .unwrap();
    let stored: String = store
        .connection()
        .query_row(
            "SELECT payload_json FROM engine_stream_events WHERE cursor = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(stored.contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY));
    store
        .subscribe(
            "sub".to_owned(),
            "agent.runtime".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-stream".to_owned()),
            Some("workspace-stream".to_owned()),
        )
        .unwrap();
    let page = store
        .poll(
            "sub",
            None,
            10,
            &StreamActorScope {
                session_id: Some("session-stream".to_owned()),
                workspace_id: Some("workspace-stream".to_owned()),
                admin: false,
            },
        )
        .unwrap();
    assert_eq!(page.events[0].payload, large);
}

#[tokio::test]
async fn idempotency_replays_or_rejects_duplicates_without_reinvoking_handler() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    catalog
        .register_function(
            write_function("alpha::write", "w1"),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let first = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert_eq!(first.value.as_ref().unwrap()["call"], 1);

    let replay = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert_eq!(replay.value.as_ref().unwrap()["call"], 1);
    assert_eq!(replay.replayed_from, Some(first.invocation_id.clone()));
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let conflict = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 2}),
            mutating_causal("same-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let records = catalog.invocations();
    assert_eq!(records.len(), 3);
    assert_eq!(records[0].idempotency_key.as_deref(), Some("same-key"));
    assert_eq!(records[1].replayed_from, Some(first.invocation_id));
    assert!(!records[2].succeeded);
}

#[tokio::test]
async fn idempotency_reject_and_noop_policies_are_enforced() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    catalog
        .register_function(
            write_function("alpha::reject", "w1").with_idempotency(reject_idempotency()),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();
    catalog
        .register_function(
            write_function("alpha::noop", "w1").with_idempotency(noop_idempotency()),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let first_reject = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::reject"),
            json!({"x": 1}),
            mutating_causal("reject-key"),
        ))
        .await;
    assert!(first_reject.error.is_none());
    let duplicate_reject = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::reject"),
            json!({"x": 1}),
            mutating_causal("reject-key"),
        ))
        .await;
    assert!(matches!(
        duplicate_reject.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));

    let first_noop = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::noop"),
            json!({"x": 1}),
            mutating_causal("noop-key"),
        ))
        .await;
    assert!(first_noop.error.is_none());
    let duplicate_noop = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::noop"),
            json!({"x": 1}),
            mutating_causal("noop-key"),
        ))
        .await;
    assert_eq!(duplicate_noop.value, Some(Value::Null));
    assert_eq!(duplicate_noop.replayed_from, Some(first_noop.invocation_id));
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn sqlite_idempotency_replays_after_catalog_recreation_without_reinvoking_handler() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let calls = Arc::new(AtomicUsize::new(0));

    {
        let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
        let mut catalog = LiveCatalog::with_ledger_store(Box::new(store));
        catalog
            .register_worker(worker("w1", "alpha"), true)
            .unwrap();
        catalog
            .register_function(
                write_function("alpha::write", "w1")
                    .with_idempotency(IdempotencyContract::caller_session_engine_ledger()),
                Some(Arc::new(CountingHandler {
                    calls: calls.clone(),
                })),
                true,
            )
            .unwrap();

        let first = catalog
            .invoke_sync(Invocation::new_sync(
                fid("alpha::write"),
                json!({"x": 1}),
                mutating_causal("same-key"),
            ))
            .await;
        assert_eq!(first.error, None);
        assert_eq!(first.value.as_ref().unwrap()["call"], 1);
    }

    let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
    let mut restarted = LiveCatalog::with_ledger_store(Box::new(store));
    restarted
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    restarted
        .register_function(
            write_function("alpha::write", "w1")
                .with_idempotency(IdempotencyContract::caller_session_engine_ledger()),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let replay = restarted
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.value.as_ref().unwrap()["call"], 1);
    assert!(replay.replayed_from.is_some());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn duplicate_after_handler_failure_replays_stored_error_without_reinvoking() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    catalog
        .register_function(
            write_function("alpha::write", "w1"),
            Some(Arc::new(CountingFailHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let first = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("error-key"),
        ))
        .await;
    assert!(matches!(
        first.error,
        Some(EngineError::HandlerFailed(message)) if message == "boom"
    ));

    let duplicate = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("error-key"),
        ))
        .await;
    assert!(matches!(
        duplicate.error,
        Some(EngineError::StoredInvocationError { kind, .. }) if kind == "handler_failed"
    ));
    assert_eq!(duplicate.replayed_from, Some(first.invocation_id));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn idempotency_reservation_failure_prevents_handler_execution() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut catalog = LiveCatalog::with_ledger_store(Box::new(ReserveFailingLedger));
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            write_function("alpha::write", "w1"),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let result = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("reserve-fails"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::LedgerFailure {
            operation: "reserve_idempotency",
            ..
        })
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[test]
fn sqlite_ledger_reopen_preserves_watch_scope_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    {
        let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
        let mut host = EngineHost::with_ledger_store(Box::new(store)).unwrap();
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
                .with_provenance(
                    Provenance::new(actor("agent"), "test").with_session_id("session-a"),
                ),
                Some(handler()),
                true,
            )
            .unwrap();
    }

    let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
    let changes = store
        .catalog_changes_after(CatalogRevision(0), 500)
        .unwrap();
    assert!(changes.iter().any(|change| {
        change.subject_kind == CatalogSubjectKind::Function
            && change.class == CatalogChangeClass::Availability
            && change.visibility == VisibilityScope::Session
            && change.session_id.as_deref() == Some("session-a")
    }));
}
