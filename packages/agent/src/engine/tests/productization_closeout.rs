//! Productization closeout soak tests.

use super::*;

struct ProductizationSoakInvoker;

#[async_trait]
impl external::ExternalWorkerInvoker for ProductizationSoakInvoker {
    async fn invoke(&self, invoke: WorkerInvoke) -> Result<WorkerInvocationResult> {
        Ok(WorkerInvocationResult {
            invocation_id: invoke.invocation_id,
            result: Some(json!({
                "functionId": invoke.function_id.as_str(),
                "payload": invoke.payload,
                "sessionId": invoke.session_id,
                "traceId": invoke.trace_id.as_str(),
            })),
            error: None,
        })
    }
}

#[tokio::test]
async fn tprod_l_external_worker_soak_registers_invokes_disconnects_and_reopens() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&db_path).unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let mut registered_function_ids = Vec::new();

    for cycle in 0..6 {
        let namespace = format!("tprod_l_soak_{cycle}");
        let worker_id = wid(&format!("tprod-l-soak-worker-{cycle}"));
        let function_id = format!("{namespace}::echo");
        let session_id = format!("tprod-l-session-{cycle}");
        let worker = WorkerDefinition::new(
            worker_id.clone(),
            WorkerKind::External,
            actor("owner"),
            grant("external-grant"),
        )
        .with_namespace_claim(&namespace);
        let mut hello = WorkerHello::loopback(worker);
        hello.session_id = Some(session_id.clone());
        runtime.hello(hello).await.unwrap();
        runtime
            .attach_invoker(worker_id.clone(), Arc::new(ProductizationSoakInvoker))
            .unwrap();
        assert!(runtime.connections().contains(&worker_id));

        runtime
            .register_function(RegisterFunction {
                definition: external_visible_function(
                    FunctionDefinition::new(
                        fid(&function_id),
                        worker_id.clone(),
                        format!("TPROD-L soak echo cycle {cycle}"),
                        VisibilityScope::Session,
                        EffectClass::PureRead,
                    )
                    .with_provenance(Provenance::system().with_session_id(&session_id)),
                ),
                default_visibility: VisibilityScope::Session,
            })
            .await
            .unwrap();

        let result = handle
            .invoke(host_invocation(
                &function_id,
                json!({"cycle": cycle, "proof": "tprod-l-soak"}),
                causal()
                    .with_scope(format!("{namespace}.read"))
                    .with_session_id(&session_id)
                    .with_workspace_id("tprod-l-workspace"),
            ))
            .await;
        assert_eq!(result.error, None);
        assert_eq!(result.value.as_ref().unwrap()["payload"]["cycle"], cycle);
        assert_eq!(
            result.value.as_ref().unwrap()["payload"]["proof"],
            "tprod-l-soak"
        );

        runtime
            .disconnect(WorkerDisconnect {
                worker_id: worker_id.clone(),
                reason: format!("TPROD-L soak cycle {cycle} complete"),
            })
            .await
            .unwrap();
        assert!(!runtime.connections().contains(&worker_id));
        assert!(matches!(
            handle
                .inspect_function(
                    &fid(&function_id),
                    Some(
                        &ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
                            .with_session_id(&session_id)
                    ),
                )
                .await,
            Err(EngineError::NotFound { .. })
        ));
        registered_function_ids.push((function_id, session_id));
    }

    let revision_after_soak = handle.catalog_revision().await.0;
    assert!(
        revision_after_soak >= 12,
        "connect/register/disconnect cycles must advance catalog revision"
    );
    drop(runtime);
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&db_path).unwrap();
    for (function_id, session_id) in registered_function_ids {
        assert!(matches!(
            reopened
                .inspect_function(
                    &fid(&function_id),
                    Some(
                        &ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
                            .with_session_id(&session_id)
                    ),
                )
                .await,
            Err(EngineError::NotFound { .. })
        ));
    }
}
