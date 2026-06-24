use super::*;
use crate::engine::authority::grants::{
    ConsumeGrantInvocationBudget, DeriveGrant, SqliteEngineGrantStore,
};

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
    let escaping_denied_path = allowed_root
        .join("missing")
        .join("..")
        .join("..")
        .join("denied")
        .join("escape.txt")
        .to_string_lossy()
        .to_string();
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
            "file-root-parent-component-escape",
            "demo::write",
            "grant-authority-valid",
            json!({"targetResourceId": "allowed-artifact", "path": escaping_denied_path}),
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
async fn remaining_invocation_budget_is_consumed_before_handler_execution_and_replay_is_free() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("budget-demo", "budget_demo"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let handler = Arc::new(CountingResourceHandler {
        calls: calls.clone(),
    });
    let write = FunctionDefinition::new(
        fid("budget_demo::write"),
        wid("budget-demo"),
        "budgeted write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("budget.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger());
    handle
        .register_function_for_setup(write, Some(handler), false)
        .unwrap();

    let derived = derive_bootstrap_grant(
        &handle,
        "one-shot-budget",
        json!({
            "allowedCapabilities": ["budget_demo::write"],
            "allowedNamespaces": ["budget_demo"],
            "allowedAuthorityScopes": ["budget.write"],
            "allowedResourceKinds": ["artifact"],
            "resourceSelectors": ["kind:artifact"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 1},
            "provenance": {"source": "grant-budget-consumption-test"}
        }),
    )
    .await;
    assert_eq!(derived.error, None);

    let context = |trace_id: &str, key: &str| {
        CausalContext::new(
            actor("agent"),
            ActorKind::Agent,
            grant("one-shot-budget"),
            trace(trace_id),
        )
        .with_session_id("session-budget")
        .with_scope("budget.write")
        .with_idempotency_key(key)
    };
    let payload = json!({"kind": "artifact"});
    let first = handle
        .invoke(host_invocation(
            "budget_demo::write",
            payload.clone(),
            context("budget-first", "budget-key-1"),
        ))
        .await;
    assert_eq!(first.error, None);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let consumed = handle
        .inspect_authority_grant(&grant("one-shot-budget"))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(consumed.budget["remainingInvocations"], json!(0));
    assert_eq!(consumed.revision, 2);

    let replay = handle
        .invoke(host_invocation(
            "budget_demo::write",
            payload.clone(),
            context("budget-replay", "budget-key-1"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "completed idempotency replay must not execute or consume budget"
    );
    let after_replay = handle
        .inspect_authority_grant(&grant("one-shot-budget"))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(after_replay.budget["remainingInvocations"], json!(0));
    assert_eq!(after_replay.revision, 2);

    let denied = handle
        .invoke(host_invocation(
            "budget_demo::write",
            payload,
            context("budget-second", "budget-key-2"),
        ))
        .await;
    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("budget remainingInvocations is exhausted")
    ));
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "exhausted budget must fail before handler execution"
    );
}

#[test]
fn sqlite_grant_store_consumes_remaining_invocations_durably() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("grant-budget.sqlite");
    let mut store = SqliteEngineGrantStore::open(&db_path).unwrap();
    let grant_id = grant("sqlite-budget-grant");
    let grant = store
        .derive(DeriveGrant {
            grant_id: Some(grant_id.clone()),
            parent_grant_id: grant("grant"),
            subject_actor_id: None,
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec!["demo::write".to_owned()],
            allowed_namespaces: vec!["demo".to_owned()],
            allowed_authority_scopes: vec!["demo.write".to_owned()],
            allowed_resource_kinds: vec!["artifact".to_owned()],
            resource_selectors: vec!["kind:artifact".to_owned()],
            file_roots: vec!["*".to_owned()],
            network_policy: "none".to_owned(),
            max_risk: RiskLevel::Medium,
            budget: json!({"remainingInvocations": 1}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "sqlite-grant-budget-test"}),
            trace_id: trace("sqlite-budget-derive"),
        })
        .unwrap();
    assert_eq!(grant.revision, 1);

    let consumed = store
        .consume_invocation_budget(ConsumeGrantInvocationBudget {
            grant_id: grant_id.clone(),
            invocation_id: InvocationId::new("sqlite-budget-invocation").unwrap(),
            function_id: fid("demo::write"),
            trace_id: trace("sqlite-budget-consume"),
        })
        .unwrap();
    assert_eq!(consumed.budget["remainingInvocations"], json!(0));
    assert_eq!(consumed.revision, 2);
    drop(store);

    let reopened = SqliteEngineGrantStore::open(&db_path).unwrap();
    let persisted = reopened.inspect(&grant_id).unwrap().unwrap();
    assert_eq!(persisted.budget["remainingInvocations"], json!(0));
    assert_eq!(persisted.revision, 2);
    assert!(persisted.updated_at > persisted.created_at);
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

#[tokio::test]
async fn capability_execute_inner_goal_operations_require_resource_authority() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("capability", "capability"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let handler = Arc::new(CountingResourceHandler {
        calls: calls.clone(),
    });
    let mut execute = FunctionDefinition::new(
        fid("capability::execute"),
        wid("capability"),
        "execute",
        VisibilityScope::System,
        EffectClass::DelegatedInvocation,
    )
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger());
    execute.risk_level = RiskLevel::Medium;
    handle
        .register_function_for_setup(execute, Some(handler), false)
        .unwrap();

    let denied_kind_grant = derive_bootstrap_grant(
        &handle,
        "execute-agent-state-only",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute"],
            "allowedResourceKinds": ["agent_state"],
            "resourceSelectors": ["kind:agent_state"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 5},
            "provenance": {"source": "execute-inner-resource-kind-test"}
        }),
    )
    .await;
    assert_eq!(denied_kind_grant.error, None);

    let denied_goal = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "operation": "goal_create",
                "objective": "must be denied before execute handler runs"
            }),
            CausalContext::new(
                actor("agent:session-a"),
                ActorKind::Agent,
                grant("execute-agent-state-only"),
                trace("execute-goal-kind-denied"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("execute-goal-kind-denied"),
        ))
        .await;
    assert!(matches!(
        denied_goal.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow resource kind goal")
    ));

    let denied_selector_grant = derive_bootstrap_grant(
        &handle,
        "execute-question-without-answer-selector",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute"],
            "allowedResourceKinds": ["user_question", "goal_answer"],
            "resourceSelectors": ["resource:user_question:authorized"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 5},
            "provenance": {"source": "execute-inner-created-kind-selector-test"}
        }),
    )
    .await;
    assert_eq!(denied_selector_grant.error, None);

    let denied_answer = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "operation": "question_answer",
                "questionResourceId": "user_question:authorized",
                "expectedQuestionVersionId": "ver_authorized",
                "answerText": "selected",
                "reason": "must be denied before execute handler runs"
            }),
            CausalContext::new(
                actor("agent:session-a"),
                ActorKind::Agent,
                grant("execute-question-without-answer-selector"),
                trace("execute-answer-selector-denied"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("execute-answer-selector-denied"),
        ))
        .await;
    assert!(matches!(
        denied_answer.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow new resource kind goal_answer")
    ));
    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "inner execute resource authority denials must happen before handler execution"
    );
}
