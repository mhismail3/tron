use super::*;

#[tokio::test]
async fn resource_lease_acquire_release_conflict_and_stream_records() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let first = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await
        .unwrap();
    assert_eq!(first.status, EngineResourceLeaseStatus::Active);
    assert_eq!(first.resource_kind, "session");
    assert_eq!(first.resource_id, "s1:model");

    let conflict = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await;
    assert!(matches!(
        conflict,
        Err(EngineError::PolicyViolation(message)) if message.contains("resource lease conflict")
    ));

    let released = handle
        .release_resource_lease(&first.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(released.status, EngineResourceLeaseStatus::Released);
    let released_again = handle
        .release_resource_lease(&first.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(released_again.status, EngineResourceLeaseStatus::Released);

    let second = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await
        .unwrap();
    assert_ne!(first.lease_id, second.lease_id);

    handle
        .subscribe_stream(
            "lease-sub".to_owned(),
            "resource.leases".to_owned(),
            StreamCursor(0),
            VisibilityScope::System,
            None,
            None,
        )
        .await
        .unwrap();
    let page = handle
        .poll_stream(
            "lease-sub",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::admin(),
        )
        .await
        .unwrap();
    let event_types = page
        .events
        .iter()
        .map(|event| event.payload["type"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(event_types.contains(&"resource_lease.acquired"));
    assert!(event_types.contains(&"resource_lease.released"));
}

#[tokio::test]
async fn resource_lease_expiry_and_sqlite_reopen_preserve_records() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    let first = handle
        .acquire_resource_lease(lease_request("import", "session.json", 1))
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    let second = handle
        .acquire_resource_lease(lease_request("import", "session.json", 30_000))
        .await
        .unwrap();
    assert_ne!(first.lease_id, second.lease_id);
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let loaded = reopened
        .get_resource_lease(&second.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(loaded.status, EngineResourceLeaseStatus::Active);
    assert_eq!(loaded.resource_kind, "import");
    assert_eq!(loaded.resource_id, "session.json");
    assert_eq!(loaded.function_id, fid("test::write"));
    assert_eq!(loaded.idempotency_key.as_deref(), Some("idem"));
}

#[tokio::test]
async fn host_invocation_enforces_resource_lease_and_records_compensation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"sessionId": "session-a", "value": 1}),
            mutating_causal("lease-key").with_scope("alpha.write"),
        ))
        .await;

    assert_eq!(result.error, None);
    let host = handle.lock().await;
    let record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| record.function_id == fid("alpha::write"))
        .unwrap();
    assert_eq!(record.resource_lease_ids.len(), 1);
    assert_eq!(record.compensation_status.as_deref(), Some("recorded"));
    let lease_id = record.resource_lease_ids[0].clone();
    drop(host);

    let lease = handle.get_resource_lease(&lease_id).await.unwrap().unwrap();
    assert_eq!(lease.status, EngineResourceLeaseStatus::Released);
    let compensation = handle.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert_eq!(compensation[0].resource_lease_ids, vec![lease_id]);
    assert!(compensation[0].succeeded);
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let compensation = reopened.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert_eq!(compensation[0].function_id, fid("alpha::write"));
}

#[tokio::test]
async fn resource_lease_template_uses_causal_session_when_payload_omits_session_id() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"value": 1}),
            mutating_causal("lease-context-key").with_scope("alpha.write"),
        ))
        .await;

    assert_eq!(result.error, None);
    let host = handle.lock().await;
    let record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| record.function_id == fid("alpha::write"))
        .unwrap();
    let lease_id = record.resource_lease_ids[0].clone();
    drop(host);

    let lease = handle.get_resource_lease(&lease_id).await.unwrap().unwrap();
    assert_eq!(lease.resource_id, "session:session-a:write");
}

#[tokio::test]
async fn resource_lease_template_rejects_payload_session_that_conflicts_with_causal_context() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"sessionId": "session-b", "value": 1}),
            mutating_causal("lease-context-conflict-key").with_scope("alpha.write"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("payload field sessionId does not match invocation context")
    ));
}

#[tokio::test]
async fn host_resource_lease_conflict_fails_before_handler_execution() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    handle
        .register_function_for_setup(
            write_function("alpha::locked", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:locked",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "lease conflict should be auditable",
                )),
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();
    let held = handle
        .acquire_resource_lease(lease_request("session", "session:session-a:locked", 30_000))
        .await
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::locked",
            json!({"sessionId": "session-a"}),
            mutating_causal("locked-key").with_scope("alpha.write"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("resource lease conflict")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let compensation = handle.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert!(!compensation[0].succeeded);
    let _ = handle.release_resource_lease(&held.lease_id).await.unwrap();
}
