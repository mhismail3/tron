use super::*;

use std::collections::BTreeMap;

#[tokio::test]
async fn state_primitive_revisions_cas_list_and_delete_are_idempotent() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let context = |key: &str| {
        mutating_causal(key)
            .with_scope("state.write")
            .with_session_id("session-a")
    };
    let set = handle
        .invoke(host_invocation(
            "state::set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "value": {"text": "one"}
            }),
            context("state-set-1"),
        ))
        .await;
    assert_eq!(set.error, None);
    assert_eq!(set.value.as_ref().unwrap()["entry"]["revision"], 1);

    let replay = handle
        .invoke(host_invocation(
            "state::set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "value": {"text": "one"}
            }),
            context("state-set-1"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.replayed_from, Some(set.invocation_id.clone()));

    let cas = handle
        .invoke(host_invocation(
            "state::compare_and_set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "expectedRevision": 1,
                "value": {"text": "two"}
            }),
            context("state-cas-1"),
        ))
        .await;
    assert_eq!(cas.error, None);
    assert_eq!(cas.value.as_ref().unwrap()["entry"]["revision"], 2);

    let stale = handle
        .invoke(host_invocation(
            "state::compare_and_set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "expectedRevision": 1,
                "value": {"text": "three"}
            }),
            context("state-cas-stale"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("revision conflict")
    ));

    let listed = handle
        .invoke(host_invocation(
            "state::list",
            json!({"scope": "session", "namespace": "agent", "keyPrefix": "dr"}),
            causal()
                .with_scope("state.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(listed.error, None);
    assert_eq!(
        listed.value.as_ref().unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let deleted = handle
        .invoke(host_invocation(
            "state::delete",
            json!({"scope": "session", "namespace": "agent", "key": "draft"}),
            context("state-delete-1"),
        ))
        .await;
    assert_eq!(deleted.error, None);
    assert_eq!(deleted.value.as_ref().unwrap()["deleted"], true);
}

#[tokio::test]
async fn enqueue_trigger_returns_receipt_and_queue_drain_preserves_causality() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let mut trigger_type = TriggerTypeDefinition::new(
        TriggerTypeId::new("manual").unwrap(),
        wid("alpha"),
        "manual",
    );
    trigger_type.allowed_delivery_modes = vec![DeliveryMode::Sync, DeliveryMode::Enqueue];
    handle
        .register_trigger_type_for_setup(trigger_type, false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("alpha::queued", "alpha")
                .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
                .with_required_authority(AuthorityRequirement::scope("queue.test")),
            Some(handler()),
            false,
        )
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.queued").unwrap();
    handle
        .register_trigger_for_setup(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("alpha"),
                TriggerTypeId::new("manual").unwrap(),
                fid("alpha::queued"),
                grant("manual-grant"),
            )
            .with_delivery_mode(DeliveryMode::Enqueue),
            false,
        )
        .unwrap();

    let mut request = TriggerDispatchRequest::new(
        trigger_id.clone(),
        json!({"queued": true}),
        actor("agent"),
        ActorKind::Agent,
    );
    request.delivery_mode = Some(DeliveryMode::Enqueue);
    request.authority_scopes = vec!["queue.test".to_owned()];
    request.runtime_metadata = BTreeMap::from([("transport".to_owned(), "queue-test".to_owned())]);
    request.trace_id = Some(trace("queued-trace"));
    request.session_id = Some("session-a".to_owned());
    request.idempotency_key = Some("queue-target-key".to_owned());
    let queued = EngineTriggerRuntime::dispatch(&handle, request).await;
    assert_eq!(queued.error, None);
    let receipt = queued.value.as_ref().unwrap()["receiptId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(queued.value.as_ref().unwrap()["queued"], true);
    let item = handle
        .get_queue_item(&receipt)
        .await
        .unwrap()
        .expect("queued trigger receipt should be inspectable");
    assert_eq!(
        item.runtime_metadata.get("transport").map(String::as_str),
        Some("queue-test")
    );
    assert_eq!(
        item.runtime_metadata
            .get(crate::engine::invocation::RUNTIME_METADATA_TRIGGER_DEPTH)
            .map(String::as_str),
        Some("1")
    );

    let drained = EngineQueueDrainer::drain_once(&handle, "default", "worker-a")
        .await
        .unwrap()
        .expect("queued item should drain");
    assert_eq!(drained.error, None);
    assert_eq!(
        drained.value.as_ref().unwrap()["echo"],
        json!({"queued": true})
    );

    let host = handle.lock().await;
    let target_record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| record.function_id == fid("alpha::queued"))
        .expect("queued target invocation should be recorded");
    assert_eq!(target_record.trigger_id, Some(trigger_id));
    assert_eq!(target_record.trace_id, trace("queued-trace"));
    assert_eq!(target_record.delivery_mode, DeliveryMode::Sync);
    assert_eq!(
        target_record.idempotency_key.as_deref(),
        Some("queue-target-key")
    );
    assert!(host.catalog().invocations().iter().any(|record| {
        record.result_value.as_ref().is_some_and(|value| {
            value.get("receiptId").and_then(Value::as_str) == Some(receipt.as_str())
        })
    }));
}

#[tokio::test]
async fn trigger_dispatch_primitive_enqueues_and_drains_triggered_invocation() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let mut trigger_type = TriggerTypeDefinition::new(
        TriggerTypeId::new("manual").unwrap(),
        wid("alpha"),
        "manual",
    );
    trigger_type.allowed_delivery_modes = vec![DeliveryMode::Sync, DeliveryMode::Enqueue];
    handle
        .register_trigger_type_for_setup(trigger_type, false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("alpha::queued", "alpha")
                .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
                .with_required_authority(AuthorityRequirement::scope("queue.test")),
            Some(handler()),
            false,
        )
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.queued").unwrap();
    handle
        .register_trigger_for_setup(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("alpha"),
                TriggerTypeId::new("manual").unwrap(),
                fid("alpha::queued"),
                grant("manual-grant"),
            )
            .with_delivery_mode(DeliveryMode::Enqueue),
            false,
        )
        .unwrap();

    let dispatched = handle
        .invoke(host_invocation(
            "trigger::dispatch",
            json!({
                "triggerId": trigger_id.as_str(),
                "payload": {"queued": true},
                "deliveryMode": "enqueue",
                "targetIdempotencyKey": "trigger-queued-target"
            }),
            mutating_causal("trigger-dispatch-1")
                .with_scope("trigger.dispatch")
                .with_scope("queue.test"),
        ))
        .await;
    assert_eq!(dispatched.error, None);
    assert_eq!(dispatched.value.as_ref().unwrap()["dispatched"], true);
    assert_eq!(dispatched.value.as_ref().unwrap()["queued"], true);
    let receipt = dispatched.value.as_ref().unwrap()["receiptId"]
        .as_str()
        .unwrap()
        .to_owned();

    let drained = EngineQueueDrainer::drain_once(&handle, "default", "worker-a")
        .await
        .unwrap()
        .expect("queued item should drain");
    assert_eq!(drained.error, None);
    assert_eq!(
        drained.value.as_ref().unwrap()["echo"],
        json!({"queued": true})
    );

    let host = handle.lock().await;
    let dispatch_record = host
        .catalog()
        .invocations()
        .iter()
        .find(|record| record.function_id == fid("trigger::dispatch"))
        .expect("dispatch invocation should be recorded");
    let enqueued_record = host
        .catalog()
        .invocations()
        .iter()
        .find(|record| {
            record.function_id == fid("alpha::queued")
                && record.delivery_mode == DeliveryMode::Enqueue
        })
        .expect("trigger enqueue handoff should be recorded");
    assert_eq!(enqueued_record.trigger_id, Some(trigger_id.clone()));
    assert_eq!(
        enqueued_record.parent_invocation_id.as_ref(),
        Some(&dispatch_record.invocation_id)
    );
    assert_eq!(enqueued_record.authority_grant_id, grant("manual-grant"));
    assert!(host.catalog().invocations().iter().any(|record| {
        record.result_value.as_ref().is_some_and(|value| {
            value.get("receiptId").and_then(Value::as_str) == Some(receipt.as_str())
        })
    }));
    let drained_record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| {
            record.function_id == fid("alpha::queued") && record.delivery_mode == DeliveryMode::Sync
        })
        .expect("drained target invocation should be recorded");
    assert_eq!(drained_record.trigger_id, Some(trigger_id));
    assert_eq!(
        drained_record.idempotency_key.as_deref(),
        Some("trigger-queued-target")
    );
}

#[tokio::test]
async fn queue_failure_event_records_updated_retry_state() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("alpha::flaky", "alpha")
                .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
                .with_required_authority(AuthorityRequirement::scope("queue.test")),
            Some(Arc::new(FailHandler)),
            false,
        )
        .unwrap();
    handle
        .subscribe_stream(
            "queue-failure-sub".to_owned(),
            "queue.lifecycle".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();
    let item = handle
        .enqueue_invocation(crate::engine::EnqueueInvocation {
            queue: "default".to_owned(),
            function_id: fid("alpha::flaky"),
            target_revision: None,
            payload: json!({"message": "fail once"}),
            actor_id: actor("agent"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: grant("manual-grant"),
            authority_scopes: vec!["queue.test".to_owned()],
            runtime_metadata: Default::default(),
            trace_id: trace("rwo-n16-queue-failure"),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            idempotency_key: Some("rwo-n16-queue-target".to_owned()),
        })
        .await
        .unwrap();

    let drained = EngineQueueDrainer::drain_receipt(&handle, &item.receipt_id, "worker-a")
        .await
        .unwrap()
        .expect("queued item should drain to a failed attempt");
    assert!(drained.error.is_some());
    let updated = handle
        .get_queue_item(&item.receipt_id)
        .await
        .unwrap()
        .expect("queue item should remain inspectable");
    assert_eq!(updated.status, crate::engine::queue::QueueItemStatus::Ready);
    assert_eq!(updated.attempts, 1);
    assert_eq!(updated.lease_owner, None);
    assert_eq!(updated.lease_expires_at, None);
    assert_eq!(updated.attempt_records.len(), 1);
    let attempt = &updated.attempt_records[0];
    assert_eq!(attempt.attempt, 1);
    assert_eq!(attempt.outcome, queue::QueueAttemptOutcome::Failed);
    assert_eq!(attempt.lease_owner.as_deref(), Some("worker-a"));
    assert_eq!(
        attempt.delivery_invocation_id.as_ref(),
        Some(&drained.invocation_id)
    );
    assert_eq!(
        attempt.result_invocation_id.as_ref(),
        Some(&drained.invocation_id)
    );
    assert_eq!(attempt.replayed_from_invocation_id, None);
    assert!(
        attempt
            .error
            .as_deref()
            .is_some_and(|message| message.contains("boom"))
    );

    let page = handle
        .poll_stream(
            "queue-failure-sub",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    let fail_event = page
        .events
        .iter()
        .find(|event| {
            event.payload["type"] == "queue.fail" && event.payload["receiptId"] == item.receipt_id
        })
        .expect("queue failure event should be published");
    assert_eq!(fail_event.payload["status"], "ready");
    assert_eq!(fail_event.payload["attempts"], 1);
    assert!(
        fail_event
            .payload
            .get("error")
            .and_then(Value::as_str)
            .is_some_and(|message| message.contains("boom"))
    );
}

#[tokio::test]
async fn queue_cancel_during_claim_preserves_terminal_cancelled_state() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let started = Arc::new(Barrier::new(2));
    let release = Arc::new(Notify::new());
    handle
        .register_function_for_setup(
            read_function("alpha::blocked", "alpha")
                .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
                .with_required_authority(AuthorityRequirement::scope("queue.test")),
            Some(Arc::new(BlockingHandler {
                started: started.clone(),
                release: release.clone(),
            })),
            false,
        )
        .unwrap();
    handle
        .subscribe_stream(
            "queue-cancel-sub".to_owned(),
            "queue.lifecycle".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();
    let item = handle
        .enqueue_invocation(crate::engine::EnqueueInvocation {
            queue: "default".to_owned(),
            function_id: fid("alpha::blocked"),
            target_revision: None,
            payload: json!({"message": "block"}),
            actor_id: actor("agent"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: grant("manual-grant"),
            authority_scopes: vec!["queue.test".to_owned()],
            runtime_metadata: Default::default(),
            trace_id: trace("rwo-n16b-cancel"),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            idempotency_key: Some("rwo-n16b-cancel-target".to_owned()),
        })
        .await
        .unwrap();

    let drain_handle = handle.clone();
    let receipt = item.receipt_id.clone();
    let drain_task = tokio::spawn(async move {
        EngineQueueDrainer::drain_receipt(&drain_handle, &receipt, "worker-a").await
    });
    started.wait().await;

    let cancelled = handle
        .invoke(host_invocation(
            "queue::cancel",
            json!({"receiptId": item.receipt_id}),
            mutating_causal("rwo-n16b-cancel")
                .with_scope("queue.write")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(cancelled.error, None);
    assert_eq!(cancelled.value.as_ref().unwrap()["cancelled"], true);
    let after_cancel = handle
        .get_queue_item(&item.receipt_id)
        .await
        .unwrap()
        .expect("cancelled queue item should remain inspectable");
    assert_eq!(after_cancel.status, queue::QueueItemStatus::Cancelled);
    assert_eq!(after_cancel.lease_owner, None);
    assert_eq!(after_cancel.lease_expires_at, None);

    release.notify_waiters();
    let drained = drain_task
        .await
        .unwrap()
        .unwrap()
        .expect("drain should complete after blocked handler releases");
    assert_eq!(drained.error, None);
    let final_item = handle
        .get_queue_item(&item.receipt_id)
        .await
        .unwrap()
        .expect("cancelled queue item should remain inspectable");
    assert_eq!(final_item.status, queue::QueueItemStatus::Cancelled);
    assert_eq!(final_item.lease_owner, None);
    assert_eq!(final_item.lease_expires_at, None);

    let page = handle
        .poll_stream(
            "queue-cancel-sub",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    let receipt_events: Vec<_> = page
        .events
        .iter()
        .filter(|event| event.payload["receiptId"] == item.receipt_id)
        .collect();
    assert!(
        receipt_events
            .iter()
            .any(|event| event.payload["type"] == "queue.claim")
    );
    let cancel_event = receipt_events
        .iter()
        .find(|event| event.payload["type"] == "queue.cancel")
        .expect("queue cancellation should be visible on lifecycle stream");
    assert_eq!(cancel_event.payload["status"], "cancelled");
    assert!(
        !receipt_events
            .iter()
            .any(|event| event.payload["type"] == "queue.complete")
    );
}

#[tokio::test]
async fn queue_terminal_failure_publishes_dead_letter_lifecycle_event() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("alpha::always_fail", "alpha")
                .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
                .with_required_authority(AuthorityRequirement::scope("queue.test")),
            Some(Arc::new(FailHandler)),
            false,
        )
        .unwrap();
    handle
        .subscribe_stream(
            "queue-dead-letter-sub".to_owned(),
            "queue.lifecycle".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();
    let item = handle
        .enqueue_invocation(crate::engine::EnqueueInvocation {
            queue: "default".to_owned(),
            function_id: fid("alpha::always_fail"),
            target_revision: None,
            payload: json!({"message": "fail"}),
            actor_id: actor("agent"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: grant("manual-grant"),
            authority_scopes: vec!["queue.test".to_owned()],
            runtime_metadata: Default::default(),
            trace_id: trace("rwo-n16b-dead-letter"),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            idempotency_key: Some("rwo-n16b-dead-letter-target".to_owned()),
        })
        .await
        .unwrap();

    for attempt in 1..=3 {
        let drained = EngineQueueDrainer::drain_receipt(&handle, &item.receipt_id, "worker-a")
            .await
            .unwrap()
            .unwrap_or_else(|| panic!("attempt {attempt} should drain"));
        assert!(drained.error.is_some());
        if attempt < 3 {
            tokio::time::sleep(std::time::Duration::from_millis(1_100)).await;
        }
    }
    let updated = handle
        .get_queue_item(&item.receipt_id)
        .await
        .unwrap()
        .expect("dead-lettered queue item should remain inspectable");
    assert_eq!(updated.status, queue::QueueItemStatus::DeadLettered);
    assert_eq!(updated.attempts, 3);
    assert_eq!(updated.lease_owner, None);
    assert_eq!(updated.lease_expires_at, None);
    assert_eq!(updated.attempt_records.len(), 3);
    assert_eq!(
        updated
            .attempt_records
            .iter()
            .map(|attempt| attempt.attempt)
            .collect::<Vec<_>>(),
        vec![1, 2, 3]
    );
    assert_eq!(
        updated
            .attempt_records
            .last()
            .map(|attempt| attempt.outcome),
        Some(queue::QueueAttemptOutcome::DeadLettered)
    );

    let page = handle
        .poll_stream(
            "queue-dead-letter-sub",
            Some(StreamCursor(0)),
            20,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    let receipt_events: Vec<_> = page
        .events
        .iter()
        .filter(|event| event.payload["receiptId"] == item.receipt_id)
        .collect();
    assert_eq!(
        receipt_events
            .iter()
            .filter(|event| event.payload["type"] == "queue.fail")
            .count(),
        2
    );
    let dead_letter_event = receipt_events
        .iter()
        .find(|event| event.payload["type"] == "queue.dead_letter")
        .expect("terminal queue failure should publish an explicit dead-letter event");
    assert_eq!(dead_letter_event.payload["status"], "dead_lettered");
    assert_eq!(dead_letter_event.payload["attempts"], 3);
    assert!(
        dead_letter_event
            .payload
            .get("error")
            .and_then(Value::as_str)
            .is_some_and(|message| message.contains("boom"))
    );
}

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
            target_revision: None,
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
            target_revision: None,
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
