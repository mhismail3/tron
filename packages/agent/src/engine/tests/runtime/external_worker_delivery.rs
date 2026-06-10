use super::external_worker_helpers::*;
use super::*;
use crate::engine::{EnqueueInvocation, QueueItemStatus};

#[tokio::test]
async fn queued_external_worker_disconnect_records_queue_retry_not_failed_target_invocation() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-queue-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("local_queue");
    runtime
        .hello(session_hello(worker, "session-a"))
        .await
        .unwrap();
    runtime
        .attach_invoker(worker_id.clone(), Arc::new(DisconnectExternalInvoker))
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(
                FunctionDefinition::new(
                    fid("local_queue::echo"),
                    worker_id,
                    "queue disconnect external function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
                .with_provenance(Provenance::system().with_session_id("session-a")),
            ),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    handle
        .subscribe_stream(
            "queue-disconnect-sub".to_owned(),
            "queue.lifecycle".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();

    let item = handle
        .enqueue_invocation(EnqueueInvocation {
            queue: "default".to_owned(),
            function_id: fid("local_queue::echo"),
            payload: json!({"message": "retry"}),
            actor_id: actor("agent"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: grant("agent-grant"),
            authority_scopes: Vec::new(),
            runtime_metadata: Default::default(),
            trace_id: trace("queue-disconnect"),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            idempotency_key: None,
        })
        .await
        .unwrap();

    let drained = EngineQueueDrainer::drain_receipt(&handle, &item.receipt_id, "worker-a")
        .await
        .unwrap()
        .expect("queued item should produce a retryable delivery failure");
    assert!(matches!(
        drained.error,
        Some(EngineError::WorkerTransportFailure { ref code, .. })
            if code == "WORKER_DISCONNECTED"
    ));
    let updated = handle
        .get_queue_item(&item.receipt_id)
        .await
        .unwrap()
        .expect("queue item should remain inspectable");
    assert_eq!(updated.status, QueueItemStatus::Ready);
    assert_eq!(updated.attempts, 1);

    let records = handle.lock().await.catalog().invocations().to_vec();
    assert!(
        !records.iter().any(|record| {
            record.function_id == fid("local_queue::echo")
                && record.delivery_mode == DeliveryMode::Sync
        }),
        "transport disconnect before a pure-read queue result should not be stored as a failed target invocation"
    );

    let page = handle
        .poll_stream(
            "queue-disconnect-sub",
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
        fail_event.payload["deliveryInvocationId"]
            .as_str()
            .is_some(),
        "queue delivery attempt id should stay visible even without a target invocation row"
    );
    assert!(
        fail_event.payload["resultInvocationId"].is_null(),
        "queue delivery failure must not point resultInvocationId at an unrecorded invocation"
    );
    assert!(
        fail_event
            .payload
            .get("error")
            .and_then(Value::as_str)
            .is_some_and(|message| message.contains("WORKER_DISCONNECTED"))
    );
}

#[tokio::test]
async fn local_external_worker_durable_disconnect_marks_functions_unhealthy() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-durable-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("durable_local");
    let mut hello = session_hello(worker, "session-a");
    hello.registration_mode = super::WorkerRegistrationMode::Durable;
    runtime.hello(hello).await.unwrap();
    runtime
        .attach_invoker(worker_id.clone(), Arc::new(EchoExternalInvoker))
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("durable_local::echo"),
                worker_id.clone(),
                "durable external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();

    runtime
        .disconnect(super::WorkerDisconnect {
            worker_id: worker_id.clone(),
            reason: "connection closed".to_owned(),
        })
        .await
        .unwrap();

    let admin = ActorContext::new(actor("admin"), ActorKind::System, grant("admin-grant"));
    let function = handle
        .inspect_function(&fid("durable_local::echo"), Some(&admin))
        .await
        .unwrap();
    assert_eq!(function.health, FunctionHealth::Unhealthy);
    assert_eq!(
        handle.inspect_worker(&worker_id).await.unwrap().lifecycle,
        super::WorkerLifecycleState::Stopped
    );
    let result = handle
        .invoke(Invocation::new_sync(
            fid("durable_local::echo"),
            json!({}),
            causal()
                .with_scope("durable_local.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::NotRoutable { .. })
    ));
}

#[tokio::test]
async fn local_external_worker_publish_stream_routes_through_stream_primitive() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let subscribe = handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "worker-sub-a",
                "topic": "stream_local.events",
                "sessionId": "session-a"
            }),
            mutating_causal("worker-stream-subscribe").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(subscribe.error, None);

    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-stream-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("stream_local");
    let hello = session_hello(worker, "session-a");
    runtime.hello(hello).await.unwrap();
    let response = runtime
        .handle_message(super::WorkerProtocolMessage::PublishStream(
            super::WorkerStreamPublish {
                worker_id: worker_id.clone(),
                topic: "stream_local.events".to_owned(),
                payload: json!({"from": "worker"}),
                visibility: VisibilityScope::Session,
                session_id: Some("session-a".to_owned()),
                workspace_id: None,
                trace_id: Some(trace("worker-stream-trace")),
                parent_invocation_id: Some(InvocationId::generate()),
                idempotency_key: "worker-stream-event-1".to_owned(),
            },
        ))
        .await
        .unwrap();
    assert!(matches!(
        response,
        Some(super::WorkerProtocolMessage::CatalogChange(change))
            if change.kind == "stream_published" && change.owner_worker == worker_id
    ));

    let poll = handle
        .invoke(host_invocation(
            "stream::poll",
            json!({"subscriptionId": "worker-sub-a", "limit": 10}),
            causal()
                .with_scope("stream.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(poll.error, None);
    let events = poll.value.as_ref().unwrap()["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["payload"], json!({"from": "worker"}));
    assert_eq!(events[0]["producer"], "local-stream-worker");
}

#[tokio::test]
async fn local_external_worker_rejects_stream_publish_outside_scoped_session() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker_id = wid("local-stream-session-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("stream_session");
    runtime
        .hello(session_hello(worker, "session-a"))
        .await
        .unwrap();

    let error = runtime
        .publish_stream(super::WorkerStreamPublish {
            worker_id,
            topic: "stream_session.events".to_owned(),
            payload: json!({"from": "worker"}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-b".to_owned()),
            workspace_id: None,
            trace_id: Some(trace("worker-stream-scope-trace")),
            parent_invocation_id: None,
            idempotency_key: "worker-stream-scope-event-1".to_owned(),
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("sessionId must match the scoped worker session")
    ));
}

#[tokio::test]
async fn local_external_worker_rejects_stream_publish_outside_token_selectors() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker_id = wid("local-stream-topic-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("stream_topic");
    runtime
        .hello(session_hello(worker, "session-a"))
        .await
        .unwrap();

    let error = runtime
        .publish_stream(super::WorkerStreamPublish {
            worker_id,
            topic: "other_topic.events".to_owned(),
            payload: json!({"from": "worker"}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            trace_id: Some(trace("worker-stream-topic-trace")),
            parent_invocation_id: None,
            idempotency_key: "worker-stream-topic-event-1".to_owned(),
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("not allowed by scoped token selectors")
    ));
}

#[tokio::test]
async fn local_external_worker_heartbeat_timeout_unregisters_volatile_capabilities() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-timeout-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("timeout_local");
    runtime
        .hello(session_hello(worker, "session-a"))
        .await
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(
                FunctionDefinition::new(
                    fid("timeout_local::echo"),
                    worker_id.clone(),
                    "timeout external function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(Provenance::system().with_session_id("session-a")),
            ),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    runtime
        .set_last_heartbeat_for_test(
            &worker_id,
            chrono::Utc::now() - chrono::Duration::seconds(120),
        )
        .unwrap();

    let expired = runtime
        .disconnect_timed_out(std::time::Duration::from_secs(30))
        .await
        .unwrap();
    assert_eq!(expired, vec![worker_id]);
    assert!(runtime.connections().is_empty());
    assert!(matches!(
        handle
            .inspect_function(&fid("timeout_local::echo"), None)
            .await,
        Err(EngineError::NotFound { .. })
    ));
}
