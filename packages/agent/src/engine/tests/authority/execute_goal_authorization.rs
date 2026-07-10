use super::*;

const EXECUTE_FUNCTION_ID: &str = "capability::execute";

fn setup_execute_handler() -> (EngineHostHandle, Arc<AtomicUsize>) {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("capability", "capability"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let handler = Arc::new(CountingResourceHandler {
        calls: calls.clone(),
    });
    let mut execute = FunctionDefinition::new(
        fid(EXECUTE_FUNCTION_ID),
        wid("capability"),
        "execute",
        VisibilityScope::System,
        EffectClass::DelegatedInvocation,
    )
    .with_required_authority(AuthorityRequirement::scope("capability.execute"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger());
    execute.risk_level = RiskLevel::Medium;
    handle
        .register_function_for_setup(execute, Some(handler), false)
        .unwrap();
    (handle, calls)
}

fn capability_grant_payload(
    scopes: &[&str],
    resource_kinds: &[&str],
    resource_selectors: &[&str],
    file_roots: &[&str],
) -> Value {
    json!({
        "allowedCapabilities": [EXECUTE_FUNCTION_ID],
        "allowedNamespaces": ["capability"],
        "allowedAuthorityScopes": scopes,
        "allowedResourceKinds": resource_kinds,
        "resourceSelectors": resource_selectors,
        "fileRoots": file_roots,
        "networkPolicy": "none",
        "maxRisk": "medium",
        "budget": {"remainingInvocations": 10},
        "provenance": {"source": "generic-capability-authority-test"}
    })
}

fn capability_context(grant_id: &str, key: &str) -> CausalContext {
    CausalContext::new(
        actor("agent:session-a"),
        ActorKind::Agent,
        grant(grant_id),
        trace(key),
    )
    .with_session_id("session-a")
    .with_workspace_id("workspace-a")
    .with_idempotency_key(key)
}

#[test]
fn engine_authorizer_contains_no_capability_operation_literals() {
    let source = include_str!("../../authority/grants/authorization.rs");

    assert!(
        !source.contains(".get(\"operation\")"),
        "engine authorization must not branch on the delegated operation field"
    );
    for operation in crate::domains::capability::supported_operation_names() {
        let literal = format!("\"{operation}\"");
        assert!(
            !source.contains(&literal),
            "engine authorization contains capability operation literal {operation}"
        );
    }
}

#[tokio::test]
async fn capability_grants_reject_wildcard_scopes_kinds_and_selectors() {
    let (handle, calls) = setup_execute_handler();
    let cases = [
        (
            "wildcard-scope",
            capability_grant_payload(&["*"], &[], &[], &["*"]),
            "wildcard authority scopes",
        ),
        (
            "wildcard-kind",
            capability_grant_payload(
                &["capability.execute"],
                &["future_*"],
                &["kind:future_*"],
                &["*"],
            ),
            "wildcard resource kinds",
        ),
        (
            "wildcard-selector",
            capability_grant_payload(&["capability.execute"], &[], &["resource:future:*"], &["*"]),
            "wildcard resource selectors",
        ),
    ];

    for (grant_id, payload, expected) in cases {
        let derived = derive_bootstrap_grant(&handle, grant_id, payload).await;
        assert_eq!(derived.error, None);

        let result = handle
            .invoke(host_invocation(
                EXECUTE_FUNCTION_ID,
                json!({"operation": "opaque_test_operation"}),
                capability_context(grant_id, &format!("invoke-{grant_id}")),
            ))
            .await;
        assert!(
            matches!(
                result.error,
                Some(EngineError::PolicyViolation(ref message)) if message.contains(expected)
            ),
            "{grant_id} should fail with {expected}, got {:?}",
            result.error
        );
    }
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn capability_grants_require_an_exact_selector_for_every_allowed_kind() {
    let (handle, calls) = setup_execute_handler();
    let grant_id = "missing-exact-kind-selector";
    let derived = derive_bootstrap_grant(
        &handle,
        grant_id,
        capability_grant_payload(
            &["capability.execute"],
            &["future_primary", "future_secondary"],
            &["kind:future_primary"],
            &["*"],
        ),
    )
    .await;
    assert_eq!(derived.error, None);

    let result = handle
        .invoke(host_invocation(
            EXECUTE_FUNCTION_ID,
            json!({"operation": "opaque_test_operation"}),
            capability_context(grant_id, "missing-exact-kind-selector-invoke"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("requires exact kind:future_secondary selector")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn capability_payload_resource_suffixes_require_exact_selectors_and_fail_closed() {
    let (handle, calls) = setup_execute_handler();
    let grant_id = "generic-exact-resource-selectors";
    let derived = derive_bootstrap_grant(
        &handle,
        grant_id,
        capability_grant_payload(
            &["capability.execute"],
            &["future_record"],
            &[
                "kind:future_record",
                "resource:future_record:allowed-id",
                "resource:future_record:allowed-ref",
                "resource:future_record:",
            ],
            &["*"],
        ),
    )
    .await;
    assert_eq!(derived.error, None);

    for (field, value) in [
        ("unregisteredFutureResourceId", "future_record:denied-id"),
        ("unregisteredFutureResourceRef", "future_record:denied-ref"),
    ] {
        let result = handle
            .invoke(host_invocation(
                EXECUTE_FUNCTION_ID,
                json!({
                    "operation": "opaque_test_operation",
                    field: value
                }),
                capability_context(grant_id, &format!("deny-{field}")),
            ))
            .await;
        assert!(
            matches!(
                result.error,
                Some(EngineError::PolicyViolation(ref message))
                    if message.contains(&format!("requires exact selector for {field} resource {value}"))
            ),
            "{field} should fail closed despite kind and prefix selectors, got {:?}",
            result.error
        );
    }

    let accepted = handle
        .invoke(host_invocation(
            EXECUTE_FUNCTION_ID,
            json!({
                "operation": "opaque_test_operation",
                "unregisteredFutureResourceId": "future_record:allowed-id",
                "unregisteredFutureResourceRef": "future_record:allowed-ref"
            }),
            capability_context(grant_id, "accept-exact-resource-selectors"),
        ))
        .await;
    assert_eq!(accepted.error, None);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn capability_authorization_preserves_function_required_scopes() {
    let (handle, calls) = setup_execute_handler();
    let grant_id = "missing-function-required-scope";
    let derived = derive_bootstrap_grant(
        &handle,
        grant_id,
        capability_grant_payload(&["resource.read"], &[], &[], &["*"]),
    )
    .await;
    assert_eq!(derived.error, None);

    let result = handle
        .invoke(host_invocation(
            EXECUTE_FUNCTION_ID,
            json!({"operation": "opaque_test_operation"}),
            capability_context(grant_id, "missing-function-required-scope-invoke"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow required authority capability.execute")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn capability_authorization_preserves_generic_file_root_checks() {
    let (handle, calls) = setup_execute_handler();
    let temp = tempfile::tempdir().unwrap();
    let allowed_root = temp.path().join("allowed");
    let denied_root = temp.path().join("denied");
    std::fs::create_dir_all(&allowed_root).unwrap();
    std::fs::create_dir_all(&denied_root).unwrap();
    let allowed_file = allowed_root.join("inside.txt");
    let denied_file = denied_root.join("outside.txt");
    std::fs::write(&allowed_file, "allowed").unwrap();
    std::fs::write(&denied_file, "denied").unwrap();
    let allowed_root_string = allowed_root.to_string_lossy().to_string();
    let allowed_roots = [allowed_root_string.as_str()];
    let grant_id = "capability-file-root";
    let derived = derive_bootstrap_grant(
        &handle,
        grant_id,
        capability_grant_payload(&["capability.execute"], &[], &[], &allowed_roots),
    )
    .await;
    assert_eq!(derived.error, None);

    let accepted = handle
        .invoke(host_invocation(
            EXECUTE_FUNCTION_ID,
            json!({
                "operation": "opaque_test_operation",
                "path": "inside.txt"
            }),
            capability_context(grant_id, "capability-file-root-allowed").with_runtime_metadata(
                crate::engine::invocation::model::RUNTIME_METADATA_WORKING_DIRECTORY,
                allowed_root_string.clone(),
            ),
        ))
        .await;
    assert_eq!(accepted.error, None);

    let denied = handle
        .invoke(host_invocation(
            EXECUTE_FUNCTION_ID,
            json!({
                "operation": "opaque_test_operation",
                "path": denied_file.to_string_lossy()
            }),
            capability_context(grant_id, "capability-file-root-denied").with_runtime_metadata(
                crate::engine::invocation::model::RUNTIME_METADATA_WORKING_DIRECTORY,
                allowed_root_string,
            ),
        ))
        .await;
    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("does not allow file path")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}
