use super::external_worker_helpers::*;
use super::*;

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
        .hello(session_hello(worker, "session-a"))
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
    let hello = session_hello(worker, "session-a");
    runtime.hello(hello).await.unwrap();
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
    let mut hello = session_hello(worker, "session-a");
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
async fn local_external_worker_rejects_namespace_substring_claim_escape() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker_id = wid("local-namespace-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("git");
    runtime
        .hello(session_hello(worker, "session-a"))
        .await
        .unwrap();

    let error = runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("legit::echo"),
                worker_id,
                "substring namespace escape",
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
            if message.contains("metadata must stay within namespace claims")
    ));
}

#[tokio::test]
async fn local_external_worker_rejects_trust_tier_outside_scoped_token() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker_id = wid("local-trust-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("trust_local");
    let hello = session_hello(worker, "session-a");
    runtime.hello(hello).await.unwrap();
    let mut function = external_visible_function(FunctionDefinition::new(
        fid("trust_local::echo"),
        worker_id,
        "token bounded external function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    ));
    function.metadata["trustTier"] = json!("first_party_signed");
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: function,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("does not match scoped token trust")
    ));
}

#[tokio::test]
async fn local_external_worker_hello_requires_session_scoped_token_binding() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker = WorkerDefinition::new(
        wid("local-unbound-session-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("unbound_session");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.session_id = Some("session-a".to_owned());

    let error = runtime.hello(hello).await.unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("workerToken.sessionId binding")
    ));
}

#[tokio::test]
async fn local_external_worker_hello_rejects_wildcard_resource_selectors() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker = WorkerDefinition::new(
        wid("local-wildcard-selector-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("wildcard_selector");
    let mut hello = session_hello(worker, "session-a");
    hello.worker_token.resource_selectors = vec!["*".to_owned()];

    let error = runtime.hello(hello).await.unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("wildcard selectors are not allowed")
    ));
}

#[tokio::test]
async fn local_external_worker_stamps_capability_policy_metadata_from_scoped_token() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-policy-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("policy_local");
    let hello = session_hello(worker, "session-a");
    runtime.hello(hello).await.unwrap();
    let mut function = external_visible_function(FunctionDefinition::new(
        fid("policy_local::echo"),
        worker_id,
        "policy stamped external function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    ));
    function.metadata["healthState"] = json!("disabled");
    function.metadata["signatureStatus"] = json!("valid");
    runtime
        .register_function(super::RegisterFunction {
            definition: function,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();

    let stored = handle
        .inspect_function(
            &fid("policy_local::echo"),
            Some(
                &ActorContext::new(actor("agent"), ActorKind::Agent, grant("agent-grant"))
                    .with_session_id("session-a"),
            ),
        )
        .await
        .unwrap();
    assert_eq!(stored.metadata["trustTier"], json!("session_generated"));
    assert_eq!(
        stored.metadata["pluginId"],
        json!("session_generated.local-policy-worker")
    );
    assert_eq!(stored.metadata["signatureStatus"], json!("session_scoped"));
    assert_eq!(stored.metadata["healthState"], json!("healthy"));
}

#[tokio::test]
async fn local_external_worker_engine_issued_token_is_binding_selectable() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("engine-issued-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("engine_issued");
    let mut hello = session_hello(worker, "session-a");
    hello.worker_token.signature_status = "engine_issued".to_owned();
    runtime.hello(hello).await.unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("engine_issued::echo"),
                worker_id,
                "engine-issued external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();

    let stored = handle
        .inspect_function(
            &fid("engine_issued::echo"),
            Some(
                &ActorContext::new(actor("agent"), ActorKind::Agent, grant("agent-grant"))
                    .with_session_id("session-a"),
            ),
        )
        .await
        .unwrap();
    assert_eq!(stored.metadata["signatureStatus"], json!("engine_issued"));
    assert_eq!(stored.metadata["healthState"], json!("healthy"));
}

#[tokio::test]
async fn local_external_worker_rejects_trigger_target_owned_by_another_worker() {
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
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let victim_worker_id = wid("local-trigger-victim");
    let victim = WorkerDefinition::new(
        victim_worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("shared_trigger");
    runtime
        .hello(session_hello(victim, "session-a"))
        .await
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("shared_trigger::echo"),
                victim_worker_id,
                "victim external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();

    let attacker_worker_id = wid("local-trigger-attacker");
    let attacker = WorkerDefinition::new(
        attacker_worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("shared_trigger");
    runtime
        .hello(session_hello(attacker, "session-a"))
        .await
        .unwrap();
    let mut trigger = TriggerDefinition::new(
        TriggerId::new("manual:shared_trigger.echo").unwrap(),
        attacker_worker_id,
        TriggerTypeId::new("manual").unwrap(),
        fid("shared_trigger::echo"),
        grant("external-grant"),
    );
    trigger.visibility = VisibilityScope::Session;

    let error = runtime
        .register_trigger(super::RegisterTrigger {
            definition: trigger,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("cannot target function")
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
    let hello = session_hello(worker, "session-a");
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
    assert!(!trace_id.is_empty());
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
        .hello(session_hello(worker, "session-a"))
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
