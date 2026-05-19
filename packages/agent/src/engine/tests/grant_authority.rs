use super::*;
use async_trait::async_trait;

fn grant_context(trace_id: &str, key: &str) -> CausalContext {
    CausalContext::new(
        actor("system"),
        ActorKind::System,
        grant("grant"),
        trace(trace_id),
    )
    .with_scope("grant.write")
    .with_idempotency_key(key)
}

fn base_child_grant_payload(grant_id: &str, parent_grant_id: &str, root: &str) -> Value {
    json!({
        "grantId": grant_id,
        "parentGrantId": parent_grant_id,
        "allowedCapabilities": ["demo::write"],
        "allowedNamespaces": ["demo"],
        "allowedAuthorityScopes": ["demo.write"],
        "allowedResourceKinds": ["artifact"],
        "resourceSelectors": ["resource:artifact-a"],
        "fileRoots": [root],
        "networkPolicy": "loopback",
        "maxRisk": "medium",
        "budget": {"remainingInvocations": 5, "maxTokens": 100},
        "expiresAt": (Utc::now() + ChronoDuration::minutes(30)).to_rfc3339(),
        "canDelegate": false,
        "approvalRequired": true,
        "provenance": {"source": "grant-authority-test"}
    })
}

async fn derive_grant(
    handle: &EngineHostHandle,
    payload: Value,
    key: &str,
) -> crate::engine::invocation::InvocationResult {
    handle
        .invoke(host_invocation(
            "grant::derive",
            payload,
            grant_context(&format!("derive-{key}"), key),
        ))
        .await
}

async fn grant_exists(handle: &EngineHostHandle, grant_id: &str) -> bool {
    let inspected = handle
        .invoke(host_invocation(
            "grant::inspect",
            json!({"grantId": grant_id}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace(&format!("inspect-{grant_id}")),
            )
            .with_scope("grant.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    !inspected.value.as_ref().unwrap()["grant"].is_null()
}

async fn derive_bootstrap_grant(
    handle: &EngineHostHandle,
    grant_id: &str,
    mut payload: Value,
) -> crate::engine::invocation::InvocationResult {
    let object = payload.as_object_mut().unwrap();
    object.insert("grantId".to_owned(), json!(grant_id));
    object.insert("parentGrantId".to_owned(), json!("grant"));
    derive_grant(handle, payload, grant_id).await
}

#[derive(Clone)]
struct CountingResourceHandler {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl InProcessFunctionHandler for CountingResourceHandler {
    async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        Ok(json!({
            "call": call,
            "resourceRefs": [{
                "resourceId": format!("artifact-from-grant-{call}"),
                "kind": "artifact",
                "versionId": format!("version-from-grant-{call}"),
                "role": "created",
                "contentHash": format!("hash-from-grant-{call}")
            }]
        }))
    }
}

#[tokio::test]
async fn grant_derive_rejects_child_expansion_by_authority_dimension() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let allowed_root = tmp.path().join("allowed");
    std::fs::create_dir_all(&allowed_root).unwrap();
    let sibling_root = tmp.path().join("sibling");
    std::fs::create_dir_all(&sibling_root).unwrap();
    let allowed_root = allowed_root.to_string_lossy().to_string();
    let sibling_root = sibling_root.to_string_lossy().to_string();
    let parent_expiry = Utc::now() + ChronoDuration::hours(1);

    let parent = derive_grant(
        &handle,
        json!({
            "grantId": "grant-authority-parent",
            "parentGrantId": "grant",
            "allowedCapabilities": ["demo::write", "demo::read"],
            "allowedNamespaces": ["demo"],
            "allowedAuthorityScopes": ["demo.write", "demo.read"],
            "allowedResourceKinds": ["artifact"],
            "resourceSelectors": ["resource:artifact-a", "kind:artifact"],
            "fileRoots": [allowed_root],
            "networkPolicy": "loopback",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 10, "maxTokens": 100},
            "expiresAt": parent_expiry.to_rfc3339(),
            "canDelegate": true,
            "approvalRequired": true,
            "provenance": {"source": "grant-authority-test"}
        }),
        "grant-authority-parent",
    )
    .await;
    assert_eq!(parent.error, None);

    let cases: Vec<(&str, Value, &str)> = vec![
        (
            "capability",
            json!({"allowedCapabilities": ["other::write"]}),
            "capabilities",
        ),
        (
            "namespace",
            json!({"allowedNamespaces": ["other"]}),
            "namespaces",
        ),
        (
            "authority-scope",
            json!({"allowedAuthorityScopes": ["other.write"]}),
            "authority scopes",
        ),
        (
            "resource-kind",
            json!({"allowedResourceKinds": ["materialized_file"]}),
            "resource kinds",
        ),
        (
            "resource-selector",
            json!({"resourceSelectors": ["resource:artifact-b"]}),
            "resource selectors",
        ),
        (
            "file-root",
            json!({"fileRoots": [sibling_root]}),
            "file roots",
        ),
        (
            "network",
            json!({"networkPolicy": "declared"}),
            "network policy",
        ),
        ("risk", json!({"maxRisk": "high"}), "risk"),
        (
            "budget",
            json!({"budget": {"remainingInvocations": 11, "maxTokens": 100}}),
            "budget",
        ),
        (
            "expiry",
            json!({"expiresAt": (parent_expiry + ChronoDuration::minutes(1)).to_rfc3339()}),
            "expiry",
        ),
        ("approval", json!({"approvalRequired": false}), "approval"),
        (
            "empty-selector",
            json!({"resourceSelectors": []}),
            "resourceSelectors",
        ),
    ];

    for (case, override_fields, expected) in cases {
        let grant_id = format!("grant-authority-child-{case}");
        let mut payload =
            base_child_grant_payload(&grant_id, "grant-authority-parent", &allowed_root);
        let payload_object = payload.as_object_mut().unwrap();
        for (key, value) in override_fields.as_object().unwrap() {
            payload_object.insert(key.clone(), value.clone());
        }
        let result = derive_grant(&handle, payload, &grant_id).await;
        assert!(
            matches!(
                result.error,
                Some(EngineError::PolicyViolation(ref message)) if message.contains(expected)
            ),
            "case {case} should reject with `{expected}`, got {:?}",
            result.error
        );
        assert!(
            !grant_exists(&handle, &grant_id).await,
            "rejected child grant {grant_id} must not be persisted"
        );
    }
}

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
