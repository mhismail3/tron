use super::*;

#[tokio::test]
async fn sqlite_restart_marks_durable_worker_unhealthy_without_socket_reconnect() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("hmh-f7-durable-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("hmh_f7");
    let mut hello = WorkerHello::loopback(worker);
    hello.registration_mode = WorkerRegistrationMode::Durable;
    hello.session_id = Some("hmh-f7-session".to_owned());
    runtime.hello(hello).await.unwrap();
    runtime
        .register_function(RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("hmh_f7::echo"),
                worker_id.clone(),
                "HMH-F7 durable external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();

    drop(runtime);
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let admin = ActorContext::new(actor("admin"), ActorKind::System, grant("admin-grant"));
    let function = reopened
        .inspect_function(&fid("hmh_f7::echo"), Some(&admin))
        .await
        .unwrap();
    assert_eq!(function.health, FunctionHealth::Unhealthy);
    assert_eq!(
        reopened.inspect_worker(&worker_id).await.unwrap().lifecycle,
        WorkerLifecycleState::Stopped
    );

    let result = reopened
        .invoke(host_invocation(
            "hmh_f7::echo",
            json!({}),
            causal()
                .with_scope("hmh_f7.read")
                .with_session_id("hmh-f7-session"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::NotRoutable { .. })
    ));
}

#[tokio::test]
async fn missing_approval_resolve_primitive_leaves_pending_child_unexecuted() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("hmh-f7-danger", "hmh_f7_danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("hmh_f7_danger::write"),
        wid("hmh-f7-danger"),
        "approval-gated HMH-F7 write",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("hmh_f7.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "HMH-F7 approval absence test write is manually compensated",
    ));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();

    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["hmh_f7.write"])
        .with_session_id("hmh-f7-session");
    let pending = client
        .invoke(
            fid("hmh_f7_danger::write"),
            json!({"value": 1}),
            Some("hmh-f7-pending-child-key".to_owned()),
            None,
        )
        .await;
    let Some(EngineError::DomainFailure { code, details, .. }) = pending.error else {
        panic!("expected approval-required stop, got {:?}", pending.error);
    };
    assert_eq!(code, "APPROVAL_REQUIRED");
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let approval_id = details.unwrap()["approvalId"].as_str().unwrap().to_owned();

    handle
        .unregister_function(&fid("approval::resolve"), &wid("approval"))
        .await
        .unwrap();

    let resolved = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "approval::resolve",
                "payload": {"approvalId": approval_id, "decision": "approve"},
                "idempotencyKey": "hmh-f7-missing-resolve-child"
            }),
            CausalContext::new(
                actor("engine-user"),
                ActorKind::User,
                grant("engine-transport"),
                trace("hmh-f7-approval-absence"),
            )
            .with_scope("approval.resolve")
            .with_session_id("hmh-f7-session"),
        ))
        .await;
    assert_eq!(resolved.error, None);
    let child_error = &resolved.value.as_ref().unwrap()["child"]["error"];
    assert_eq!(child_error["kind"], "not_found");
    assert!(
        child_error["message"]
            .as_str()
            .is_some_and(|message| message.contains("approval::resolve"))
    );

    let record = handle.get_approval(&approval_id).await.unwrap().unwrap();
    assert_eq!(record.status, ApprovalStatus::Pending);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}
