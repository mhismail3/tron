use super::*;

#[tokio::test]
async fn rejected_grants_fail_before_handler_execution_or_successful_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let handler = Arc::new(CountingResourceHandler {
        calls: calls.clone(),
    });
    let write = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "resource write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(write, Some(handler.clone()), false)
        .unwrap();
    let mut over_risk = FunctionDefinition::new(
        fid("demo::critical"),
        wid("demo"),
        "over-risk write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    over_risk.risk_level = RiskLevel::Medium;
    handle
        .register_function_for_setup(over_risk, Some(handler), false)
        .unwrap();

    let tmp = tempfile::tempdir().unwrap();
    let allowed_root = tmp.path().join("allowed");
    let denied_root = tmp.path().join("denied");
    std::fs::create_dir_all(&allowed_root).unwrap();
    std::fs::create_dir_all(&denied_root).unwrap();
    let allowed_root = allowed_root.to_string_lossy().to_string();
    let denied_path = denied_root
        .join("outside.txt")
        .to_string_lossy()
        .to_string();

    let valid_payload = json!({
        "allowedCapabilities": ["demo::write"],
        "allowedNamespaces": ["demo"],
        "allowedAuthorityScopes": ["demo.write"],
        "allowedResourceKinds": ["artifact"],
        "resourceSelectors": ["resource:allowed-artifact"],
        "fileRoots": [allowed_root],
        "networkPolicy": "none",
        "maxRisk": "medium",
        "budget": {"remainingInvocations": 5},
        "provenance": {"source": "grant-authority-test"}
    });
    assert_eq!(
        derive_bootstrap_grant(&handle, "grant-authority-valid", valid_payload.clone())
            .await
            .error,
        None
    );
    assert_eq!(
        derive_bootstrap_grant(&handle, "grant-authority-revoked", valid_payload.clone())
            .await
            .error,
        None
    );
    let revoked = handle
        .invoke(host_invocation(
            "grant::revoke",
            json!({"grantId": "grant-authority-revoked"}),
            grant_context(
                "revoke-grant-authority-revoked",
                "revoke-grant-authority-revoked",
            ),
        ))
        .await;
    assert_eq!(revoked.error, None);
    assert_eq!(
        derive_bootstrap_grant(
            &handle,
            "grant-authority-actor-mismatch",
            json!({
                "subjectActorId": "other-actor",
                "allowedCapabilities": ["demo::write"],
                "allowedNamespaces": ["demo"],
                "allowedAuthorityScopes": ["demo.write"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["resource:allowed-artifact"],
                "fileRoots": [allowed_root],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 5},
                "provenance": {"source": "grant-authority-test"}
            })
        )
        .await
        .error,
        None
    );
    assert_eq!(
        derive_bootstrap_grant(
            &handle,
            "grant-authority-worker-mismatch",
            json!({
                "subjectWorkerId": "other-worker",
                "allowedCapabilities": ["demo::write"],
                "allowedNamespaces": ["demo"],
                "allowedAuthorityScopes": ["demo.write"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["resource:allowed-artifact"],
                "fileRoots": [allowed_root],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 5},
                "provenance": {"source": "grant-authority-test"}
            })
        )
        .await
        .error,
        None
    );
    assert_eq!(
        derive_bootstrap_grant(
            &handle,
            "grant-authority-budget-exhausted",
            json!({
                "allowedCapabilities": ["demo::write"],
                "allowedNamespaces": ["demo"],
                "allowedAuthorityScopes": ["demo.write"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["resource:allowed-artifact"],
                "fileRoots": [allowed_root],
                "networkPolicy": "none",
                "maxRisk": "low",
                "budget": {"remainingInvocations": 0},
                "provenance": {"source": "grant-authority-test"}
            })
        )
        .await
        .error,
        None
    );
    assert_eq!(
        derive_bootstrap_grant(
            &handle,
            "grant-authority-raw-scope-only",
            json!({
                "allowedCapabilities": ["demo::write"],
                "allowedNamespaces": ["demo"],
                "allowedAuthorityScopes": ["demo.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["resource:allowed-artifact"],
                "fileRoots": [allowed_root],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 5},
                "provenance": {"source": "grant-authority-test"}
            })
        )
        .await
        .error,
        None
    );
    assert_eq!(
        derive_bootstrap_grant(
            &handle,
            "grant-authority-risk",
            json!({
                "allowedCapabilities": ["demo::critical"],
                "allowedNamespaces": ["demo"],
                "allowedAuthorityScopes": ["demo.write"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["resource:allowed-artifact"],
                "fileRoots": [allowed_root],
                "networkPolicy": "none",
                "maxRisk": "low",
                "budget": {"remainingInvocations": 5},
                "provenance": {"source": "grant-authority-test"}
            })
        )
        .await
        .error,
        None
    );
    assert_eq!(
        derive_bootstrap_grant(
            &handle,
            "grant-authority-expiring",
            json!({
                "allowedCapabilities": ["demo::write"],
                "allowedNamespaces": ["demo"],
                "allowedAuthorityScopes": ["demo.write"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["resource:allowed-artifact"],
                "fileRoots": [allowed_root],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 5},
                "expiresAt": (Utc::now() + ChronoDuration::milliseconds(20)).to_rfc3339(),
                "provenance": {"source": "grant-authority-test"}
            })
        )
        .await
        .error,
        None
    );
    tokio::time::sleep(std::time::Duration::from_millis(40)).await;

    let cases = [
        (
            "missing",
            "demo::write",
            "grant-authority-missing",
            json!({"targetResourceId": "allowed-artifact"}),
            "not found",
        ),
        (
            "revoked",
            "demo::write",
            "grant-authority-revoked",
            json!({"targetResourceId": "allowed-artifact"}),
            "not active",
        ),
        (
            "expired",
            "demo::write",
            "grant-authority-expiring",
            json!({"targetResourceId": "allowed-artifact"}),
            "expired",
        ),
        (
            "subject-actor",
            "demo::write",
            "grant-authority-actor-mismatch",
            json!({"targetResourceId": "allowed-artifact"}),
            "subject actor mismatch",
        ),
        (
            "subject-worker",
            "demo::write",
            "grant-authority-worker-mismatch",
            json!({"targetResourceId": "allowed-artifact"}),
            "subject worker mismatch",
        ),
        (
            "selector",
            "demo::write",
            "grant-authority-valid",
            json!({"targetResourceId": "denied-artifact"}),
            "does not allow resource",
        ),
        (
            "file-root",
            "demo::write",
            "grant-authority-valid",
            json!({"targetResourceId": "allowed-artifact", "path": denied_path}),
            "does not allow file path",
        ),
        (
            "budget",
            "demo::write",
            "grant-authority-budget-exhausted",
            json!({"targetResourceId": "allowed-artifact"}),
            "budget remainingInvocations is exhausted",
        ),
        (
            "raw-scope",
            "demo::write",
            "grant-authority-raw-scope-only",
            json!({"targetResourceId": "allowed-artifact"}),
            "does not allow required authority",
        ),
        (
            "risk",
            "demo::critical",
            "grant-authority-risk",
            json!({"targetResourceId": "allowed-artifact"}),
            "risk",
        ),
    ];

    for (case, function_id, grant_id, payload, expected) in cases {
        let result = handle
            .invoke(host_invocation(
                function_id,
                payload,
                CausalContext::new(
                    actor("agent"),
                    ActorKind::Agent,
                    grant(grant_id),
                    trace(&format!("grant-rejected-{case}")),
                )
                .with_session_id("session-a")
                .with_workspace_id("workspace-a")
                .with_scope("demo.write")
                .with_idempotency_key(&format!("grant-rejected-{case}")),
            ))
            .await;
        assert!(
            matches!(
                result.error,
                Some(EngineError::PolicyViolation(ref message)) if message.contains(expected)
            ),
            "case {case} should reject with `{expected}`, got {:?}",
            result.error
        );
        assert_eq!(
            calls.load(Ordering::SeqCst),
            0,
            "case {case} must fail before handler execution"
        );
        let records = handle.lock().await.catalog().invocations().to_vec();
        let record = records
            .iter()
            .find(|record| record.invocation_id == result.invocation_id)
            .expect("rejected invocation should remain inspectable in the ledger");
        assert!(!record.succeeded);
        assert!(
            record.produced_resource_refs.is_empty(),
            "prepare failures must not record produced resource refs"
        );
    }

    let accepted = handle
        .invoke(host_invocation(
            "demo::write",
            json!({"targetResourceId": "allowed-artifact"}),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("grant-authority-valid"),
                trace("grant-accepted"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_scope("demo.write")
            .with_idempotency_key("grant-accepted"),
        ))
        .await;
    assert_eq!(accepted.error, None);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn invocation_authorization_uses_grant_not_raw_scope_strings() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "artifact-read-only",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::inspect"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["kind:artifact"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-raw-scope"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-read-only"),
        ))
        .await;
    assert_eq!(derived.error, None);

    let result = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "payload": {"title": "draft", "body": "body"}
            }),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("artifact-read-only"),
                trace("raw-scope-ignored"),
            )
            .with_scope("resource.write")
            .with_idempotency_key("artifact-create-denied"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow function")
                || message.contains("does not allow required authority")
                || message.contains("exceeds grant")
    ));
}

#[tokio::test]
async fn revoked_grants_fail_before_handler_execution() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "revoked-artifact-read",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::inspect"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
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
                trace("grant-revoked-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-revoked"),
        ))
        .await;
    assert_eq!(derived.error, None);

    let revoked = handle
        .invoke(host_invocation(
            "grant::revoke",
            json!({"grantId": "revoked-artifact-read"}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-revoked"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("revoke-artifact-read"),
        ))
        .await;
    assert_eq!(revoked.error, None);

    let denied = handle
        .invoke(host_invocation(
            "artifact::inspect",
            json!({"resourceId": "missing-artifact"}),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("revoked-artifact-read"),
                trace("grant-revoked-invoke"),
            )
            .with_scope("resource.read"),
        ))
        .await;

    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not active")
    ));
}

#[tokio::test]
async fn expired_grants_fail_before_handler_execution() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let expires_at = (Utc::now() + ChronoDuration::milliseconds(100)).to_rfc3339();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "expiring-artifact-read",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::inspect"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low",
                "expiresAt": expires_at,
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-expired-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-expiring"),
        ))
        .await;
    assert_eq!(derived.error, None);

    tokio::time::sleep(std::time::Duration::from_millis(150)).await;
    let denied = handle
        .invoke(host_invocation(
            "artifact::inspect",
            json!({"resourceId": "missing-artifact"}),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("expiring-artifact-read"),
                trace("grant-expired-invoke"),
            )
            .with_scope("resource.read"),
        ))
        .await;
    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("is expired")
    ));
}

#[tokio::test]
async fn grant_resource_selectors_block_unauthorized_resource_mutations() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "one-artifact-writer",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::create"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.write"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["resource:allowed-artifact"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "medium"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-selector-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-selector"),
        ))
        .await;
    assert_eq!(derived.error, None);

    let denied = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "resourceId": "denied-artifact",
                "payload": {"title": "draft", "body": "body"}
            }),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("one-artifact-writer"),
                trace("grant-selector-denied"),
            )
            .with_scope("resource.write")
            .with_idempotency_key("denied-artifact-create"),
        ))
        .await;

    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("does not allow resource")
    ));
}
