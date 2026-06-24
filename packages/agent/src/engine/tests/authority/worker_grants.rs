use super::*;

#[tokio::test]
async fn worker_registration_and_functions_cannot_exceed_worker_grant() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "demo-worker-grant",
                "parentGrantId": "grant",
                "allowedCapabilities": ["demo::echo"],
                "allowedNamespaces": ["demo"],
                "allowedAuthorityScopes": ["demo.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("worker-grant-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-demo-worker"),
        ))
        .await;
    assert_eq!(derived.error, None);

    let rejected_worker = handle.register_worker_for_setup(
        WorkerDefinition::new(
            wid("bad-demo-worker"),
            WorkerKind::InProcess,
            actor("owner"),
            grant("demo-worker-grant"),
        )
        .with_namespace_claim("other"),
        false,
    );
    assert!(matches!(
        rejected_worker,
        Err(EngineError::PolicyViolation(message)) if message.contains("namespace other exceeds")
    ));

    handle
        .register_worker_for_setup(
            WorkerDefinition::new(
                wid("demo-worker"),
                WorkerKind::InProcess,
                actor("owner"),
                grant("demo-worker-grant"),
            )
            .with_namespace_claim("demo"),
            false,
        )
        .unwrap();

    let rejected_function = handle.register_function_for_setup(
        FunctionDefinition::new(
            fid("demo::write"),
            wid("demo-worker"),
            "write",
            VisibilityScope::Agent,
            EffectClass::IdempotentWrite,
        )
        .with_required_authority(AuthorityRequirement::scope("demo.write"))
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger()),
        Some(handler()),
        false,
    );
    assert!(matches!(
        rejected_function,
        Err(EngineError::PolicyViolation(message)) if message.contains("exceeds worker grant")
    ));
}
