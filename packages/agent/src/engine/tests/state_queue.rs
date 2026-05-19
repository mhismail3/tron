use super::*;

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
    let approval = handle
        .invoke(host_invocation(
            "approval::request",
            json!({
                "functionId": "state::set",
                "payload": {"scope": "system", "namespace": "agent", "key": "boot", "value": {"ready": false}}
            }),
            mutating_causal("sqlite-approval").with_scope("approval.request"),
        ))
        .await;
    assert_eq!(approval.error, None);
    let approval_id = approval.value.as_ref().unwrap()["approval"]["approvalId"]
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
    let approval_get = reopened
        .invoke(host_invocation(
            "approval::get",
            json!({"approvalId": approval_id}),
            causal()
                .with_scope("approval.read")
                .with_session_id("session-a")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(approval_get.error, None);
    assert_eq!(
        approval_get.value.as_ref().unwrap()["approval"]["status"],
        "pending"
    );
}
