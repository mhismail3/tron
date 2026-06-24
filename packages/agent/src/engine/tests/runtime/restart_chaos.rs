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
    .with_namespace_claim("restart_chaos");
    let mut hello = WorkerHello::loopback(worker).with_session_scope("hmh-f7-session");
    hello.registration_mode = WorkerRegistrationMode::Durable;
    runtime.hello(hello).await.unwrap();
    runtime
        .register_function(RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("restart_chaos::echo"),
                worker_id.clone(),
                "durable external function",
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
        .inspect_function(&fid("restart_chaos::echo"), Some(&admin))
        .await
        .unwrap();
    assert_eq!(function.health, FunctionHealth::Unhealthy);
    assert_eq!(
        reopened.inspect_worker(&worker_id).await.unwrap().lifecycle,
        WorkerLifecycleState::Stopped
    );

    let result = reopened
        .invoke(host_invocation(
            "restart_chaos::echo",
            json!({}),
            causal()
                .with_scope("restart_chaos.read")
                .with_session_id("hmh-f7-session"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::NotRoutable { .. })
    ));
}
