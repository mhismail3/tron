use super::*;

#[tokio::test]
async fn queue_inspection_records_replay_lease_and_compensation_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let compensated = write_function("alpha::compensated_write", "alpha")
        .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
        .with_required_authority(AuthorityRequirement::scope("alpha.write"))
        .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
            "session",
            "session:{sessionId}:queue-write",
            30_000,
        ))
        .with_compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "queued writes expose manual recovery references",
        ));
    handle
        .register_function_for_setup(compensated, Some(handler()), false)
        .unwrap();

    let first_item = handle
        .enqueue_invocation(crate::engine::EnqueueInvocation {
            queue: "default".to_owned(),
            function_id: fid("alpha::compensated_write"),
            payload: json!({"sessionId": "session-a", "message": "first"}),
            actor_id: actor("agent"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: grant("manual-grant"),
            authority_scopes: vec!["alpha.write".to_owned()],
            runtime_metadata: Default::default(),
            trace_id: trace("queue-compensated"),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some("session-a".to_owned()),
            workspace_id: Some("workspace-a".to_owned()),
            idempotency_key: Some("queue-compensated-target".to_owned()),
        })
        .await
        .unwrap();
    let first = EngineQueueDrainer::drain_receipt(&handle, &first_item.receipt_id, "worker-a")
        .await
        .unwrap()
        .expect("queued compensated item should drain");
    assert_eq!(first.error, None);
    let first_inspected = handle
        .invoke(host_invocation(
            "queue::get",
            json!({"receiptId": first_item.receipt_id}),
            causal()
                .with_scope("queue.read")
                .with_session_id("session-a")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(first_inspected.error, None);
    let first_json = &first_inspected.value.as_ref().unwrap()["item"];
    let first_attempts = first_json["attemptRecords"].as_array().unwrap();
    assert_eq!(first_attempts.len(), 1);
    let first_attempt = &first_attempts[0];
    assert_eq!(first_attempt["outcome"], "completed");
    assert_eq!(
        first_attempt["deliveryInvocationId"],
        first.invocation_id.as_str()
    );
    assert_eq!(
        first_attempt["resultInvocationId"],
        first.invocation_id.as_str()
    );
    assert_eq!(first_attempt["leaseOwner"], "worker-a");
    assert_eq!(first_attempt["compensationStatus"], "recorded");
    let lease_id = first_attempt["resourceLeaseIds"][0].as_str().unwrap();
    let compensation_id = first_attempt["compensationId"].as_str().unwrap();
    let lease = handle
        .get_resource_lease(lease_id)
        .await
        .unwrap()
        .expect("queue attempt lease ref should be inspectable");
    assert_eq!(lease.status, EngineResourceLeaseStatus::Released);
    let compensation = handle.list_compensation_records().await.unwrap();
    assert!(compensation.iter().any(|record| {
        record.compensation_id == compensation_id && record.resource_lease_ids == vec![lease_id]
    }));

    let replay_item = handle
        .enqueue_invocation(crate::engine::EnqueueInvocation {
            queue: "default".to_owned(),
            function_id: fid("alpha::compensated_write"),
            payload: json!({"sessionId": "session-a", "message": "first"}),
            actor_id: actor("agent"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: grant("manual-grant"),
            authority_scopes: vec!["alpha.write".to_owned()],
            runtime_metadata: Default::default(),
            trace_id: trace("queue-compensated-replay"),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some("session-a".to_owned()),
            workspace_id: Some("workspace-a".to_owned()),
            idempotency_key: Some("queue-compensated-target".to_owned()),
        })
        .await
        .unwrap();
    let replay = EngineQueueDrainer::drain_receipt(&handle, &replay_item.receipt_id, "worker-b")
        .await
        .unwrap()
        .expect("queued replay item should drain");
    assert_eq!(replay.error, None);
    assert_eq!(replay.replayed_from.as_ref(), Some(&first.invocation_id));
    let replay_inspected = handle
        .get_queue_item(&replay_item.receipt_id)
        .await
        .unwrap()
        .expect("replay queue item should stay inspectable");
    assert_eq!(replay_inspected.status, queue::QueueItemStatus::Completed);
    assert_eq!(replay_inspected.attempt_records.len(), 1);
    let replay_attempt = &replay_inspected.attempt_records[0];
    assert_eq!(
        replay_attempt.outcome,
        queue::QueueAttemptOutcome::Completed
    );
    assert_eq!(
        replay_attempt.replayed_from_invocation_id.as_ref(),
        Some(&first.invocation_id)
    );
    assert_eq!(replay_attempt.resource_lease_ids, Vec::<String>::new());
    assert_eq!(replay_attempt.compensation_id, None);
}

#[tokio::test]
async fn sqlite_primitive_stores_persist_stream_state_and_queue_records() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();

    let state_set = handle
        .invoke(host_invocation(
            "state::set",
            json!({
                "scope": "system",
                "namespace": "agent",
                "key": "boot",
                "value": {"ready": true}
            }),
            mutating_causal("sqlite-state-set").with_scope("state.write"),
        ))
        .await;
    assert_eq!(state_set.error, None);
    handle
        .subscribe_stream(
            "sqlite-sub".to_owned(),
            "catalog.changes".to_owned(),
            StreamCursor(0),
            VisibilityScope::System,
            None,
            None,
        )
        .await
        .unwrap();
    handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "catalog.changes".to_owned(),
            payload: json!({"subject": "alpha::one"}),
            visibility: VisibilityScope::System,
            session_id: None,
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("sqlite-stream-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();
    let queued = handle
        .invoke(host_invocation(
            "queue::enqueue",
            json!({
                "queue": "durable",
                "functionId": "state::get",
                "payload": {"scope": "system", "namespace": "agent", "key": "boot"}
            }),
            mutating_causal("sqlite-queue-enqueue").with_scope("queue.write"),
        ))
        .await;
    assert_eq!(queued.error, None);
    let receipt = queued.value.as_ref().unwrap()["item"]["receiptId"]
        .as_str()
        .unwrap()
        .to_owned();
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let state_get = reopened
        .invoke(host_invocation(
            "state::get",
            json!({"scope": "system", "namespace": "agent", "key": "boot"}),
            causal().with_scope("state.read"),
        ))
        .await;
    assert_eq!(state_get.error, None);
    assert_eq!(
        state_get.value.as_ref().unwrap()["entry"]["value"],
        json!({"ready": true})
    );
    let stream_page = reopened
        .poll_stream(
            "sqlite-sub",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::admin(),
        )
        .await
        .unwrap();
    assert_eq!(stream_page.events.len(), 1);
    assert_eq!(
        stream_page.events[0].payload,
        json!({"subject": "alpha::one"})
    );
    let queue_get = reopened
        .invoke(host_invocation(
            "queue::get",
            json!({"receiptId": receipt}),
            causal().with_scope("queue.read"),
        ))
        .await;
    assert_eq!(queue_get.error, None);
    assert_eq!(
        queue_get.value.as_ref().unwrap()["item"]["queue"],
        "durable"
    );
}
