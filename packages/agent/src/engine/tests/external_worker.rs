use super::*;

#[test]
fn external_worker_protocol_roundtrips_local_session_default_messages() {
    let worker = WorkerDefinition::new(
        wid("local-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("local");
    let hello =
        super::WorkerProtocolMessage::Hello(Box::new(super::WorkerHello::loopback(worker.clone())));
    let function = FunctionDefinition::new(
        fid("local::echo"),
        wid("local-worker"),
        "session-default external function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::system().with_session_id("session-a"));
    let register =
        super::WorkerProtocolMessage::RegisterFunction(Box::new(super::RegisterFunction {
            definition: external_visible_function(function),
            default_visibility: VisibilityScope::Session,
        }));
    if let super::WorkerProtocolMessage::RegisterFunction(message) = &register {
        assert_eq!(message.default_visibility, VisibilityScope::Session);
        assert_eq!(message.definition.visibility, VisibilityScope::Session);
    }
    let trigger = super::WorkerProtocolMessage::RegisterTrigger(super::RegisterTrigger {
        definition: TriggerDefinition::new(
            TriggerId::new("manual:local.echo").unwrap(),
            wid("local-worker"),
            TriggerTypeId::new("manual").unwrap(),
            fid("local::echo"),
            grant("external-grant"),
        ),
    });
    let invoke = super::WorkerProtocolMessage::Invoke(super::WorkerInvoke {
        invocation_id: super::InvocationId::generate(),
        function_id: fid("local::echo"),
        payload: json!({"hello": "worker"}),
        actor_kind: ActorKind::Agent,
        authority_grant_id: grant("agent-grant"),
        authority_scopes: vec!["local.read".to_owned()],
        trace_id: trace("worker-trace"),
        parent_invocation_id: None,
        trigger_id: Some(TriggerId::new("manual:local.echo").unwrap()),
        expected_function_revision: None,
        idempotency_key: None,
        session_id: Some("session-a".to_owned()),
        workspace_id: None,
        timeout_ms: 30_000,
    });
    for message in [hello, register, trigger, invoke] {
        let json = serde_json::to_string(&message).unwrap();
        let decoded: super::WorkerProtocolMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, message);
    }
}

#[tokio::test]
async fn local_external_worker_runtime_registers_session_functions_and_disconnects_cleanly() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_trigger_type_for_setup(
            TriggerTypeDefinition::new(
                TriggerTypeId::new("manual").unwrap(),
                wid("engine"),
                "manual test trigger",
            ),
            false,
        )
        .unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker = WorkerDefinition::new(
        wid("local-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("local");
    let snapshot = runtime
        .hello(super::WorkerHello::loopback(worker))
        .await
        .unwrap();
    assert_eq!(runtime.connections(), vec![wid("local-worker")]);
    assert!(
        snapshot
            .functions
            .iter()
            .all(|function| function.id.namespace() != "rpc")
    );

    let function = FunctionDefinition::new(
        fid("local::echo"),
        wid("local-worker"),
        "session-default external function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::system().with_session_id("session-a"));
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(function),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    assert!(
        handle
            .inspect_function(
                &fid("local::echo"),
                Some(
                    &ActorContext::new(actor("agent"), ActorKind::Agent, grant("agent-grant"))
                        .with_session_id("session-a"),
                ),
            )
            .await
            .is_ok()
    );

    runtime
        .disconnect(super::WorkerDisconnect {
            worker_id: wid("local-worker"),
            reason: "test complete".to_owned(),
        })
        .await
        .unwrap();
    assert!(matches!(
        handle.inspect_function(&fid("local::echo"), None).await,
        Err(EngineError::NotFound { .. })
    ));
}

#[tokio::test]
async fn local_external_worker_rejects_visible_functions_without_capability_metadata() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker_id = wid("local-invalid-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("invalid_local");
    runtime
        .hello(super::WorkerHello::loopback(worker))
        .await
        .unwrap();
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: FunctionDefinition::new(
                fid("invalid_local::echo"),
                worker_id,
                "invalid external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            ),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("requires request and response schemas")
    ));
}

#[tokio::test]
async fn local_external_worker_rejects_metadata_outside_scoped_token() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker_id = wid("local-token-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("token_local");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.worker_token.plugin_id = "session_generated.allowed-plugin".to_owned();
    runtime.hello(hello).await.unwrap();
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("token_local::echo"),
                worker_id,
                "token bounded external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("does not match scoped token plugin")
    ));
}

#[tokio::test]
async fn local_external_worker_lifecycle_events_publish_through_streams_and_traces() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let subscribe = handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "worker-lifecycle-sub",
                "topic": "worker.lifecycle",
                "sessionId": "session-a"
            }),
            mutating_causal("worker-lifecycle-subscribe").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(subscribe.error, None);

    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-lifecycle-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("lifecycle_local");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.session_id = Some("session-a".to_owned());
    runtime.hello(hello).await.unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(
                FunctionDefinition::new(
                    fid("lifecycle_local::echo"),
                    worker_id.clone(),
                    "lifecycle external function",
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
        .disconnect(super::WorkerDisconnect {
            worker_id: worker_id.clone(),
            reason: "test complete".to_owned(),
        })
        .await
        .unwrap();

    let poll = handle
        .invoke(host_invocation(
            "stream::poll",
            json!({"subscriptionId": "worker-lifecycle-sub", "limit": 10}),
            causal()
                .with_scope("stream.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(poll.error, None);
    let events = poll.value.as_ref().unwrap()["events"].as_array().unwrap();
    let event_types = events
        .iter()
        .map(|event| event["payload"]["eventType"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        event_types,
        vec![
            "worker.connected",
            "worker.function_registered",
            "worker.disconnected",
            "worker.unregistered",
        ]
    );
    let trace_id = events[0]["payload"]["traceId"].as_str().unwrap();
    let trace = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": trace_id}),
            causal().with_scope("observability.read"),
        ))
        .await;
    assert_eq!(trace.error, None);
    assert!(
        trace.value.as_ref().unwrap()["streams"]
            .as_array()
            .unwrap()
            .iter()
            .any(|stream| stream["topic"] == "worker.lifecycle")
    );
}

struct EchoExternalInvoker;

#[async_trait]
impl super::external::ExternalWorkerInvoker for EchoExternalInvoker {
    async fn invoke(&self, invoke: super::WorkerInvoke) -> Result<super::WorkerInvocationResult> {
        Ok(super::WorkerInvocationResult {
            invocation_id: invoke.invocation_id,
            result: Some(json!({
                "functionId": invoke.function_id,
                "payload": invoke.payload,
                "traceId": invoke.trace_id,
            })),
            error: None,
        })
    }
}

#[tokio::test]
async fn local_external_worker_runtime_registers_executable_proxy_handler() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-exec-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("local_exec");
    runtime
        .hello(super::WorkerHello::loopback(worker))
        .await
        .unwrap();
    runtime
        .attach_invoker(worker_id.clone(), Arc::new(EchoExternalInvoker))
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(
                FunctionDefinition::new(
                    fid("local_exec::echo"),
                    worker_id,
                    "executable external function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(Provenance::system().with_session_id("session-a")),
            ),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();

    let result = handle
        .invoke(Invocation::new_sync(
            fid("local_exec::echo"),
            json!({"hello": "worker"}),
            causal()
                .with_scope("local_exec.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        result.value.as_ref().unwrap()["payload"],
        json!({"hello": "worker"})
    );
}

#[tokio::test]
async fn local_external_worker_hello_rejects_identity_mismatch() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker = WorkerDefinition::new(
        wid("local-identity-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("identity_local");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.identity.worker_id = wid("different-worker");

    let error = runtime.hello(hello).await.unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("does not match definition")
    ));
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
    let mut hello = super::WorkerHello::loopback(worker);
    hello.registration_mode = super::WorkerRegistrationMode::Durable;
    hello.session_id = Some("session-a".to_owned());
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
                "topic": "worker.events",
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
    let mut hello = super::WorkerHello::loopback(worker);
    hello.session_id = Some("session-a".to_owned());
    runtime.hello(hello).await.unwrap();
    let response = runtime
        .handle_message(super::WorkerProtocolMessage::PublishStream(
            super::WorkerStreamPublish {
                worker_id: worker_id.clone(),
                topic: "worker.events".to_owned(),
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
        .hello(super::WorkerHello::loopback(worker))
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
