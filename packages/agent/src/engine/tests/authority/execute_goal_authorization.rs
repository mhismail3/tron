use super::*;

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

    let denied_scope_grant = derive_bootstrap_grant(
        &handle,
        "execute-without-goals-write",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute"],
            "allowedResourceKinds": ["goal"],
            "resourceSelectors": ["kind:goal"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 5},
            "provenance": {"source": "execute-inner-scope-test"}
        }),
    )
    .await;
    assert_eq!(denied_scope_grant.error, None);

    let denied_scope = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "operation": "goal_create",
                "objective": "must be denied before execute handler runs"
            }),
            CausalContext::new(
                actor("agent:session-a"),
                ActorKind::Agent,
                grant("execute-without-goals-write"),
                trace("execute-goal-scope-denied"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("execute-goal-scope-denied"),
        ))
        .await;
    assert!(matches!(
        denied_scope.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow required authority goals.write")
    ));

    let denied_kind_grant = derive_bootstrap_grant(
        &handle,
        "execute-agent-state-only",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute", "goals.write"],
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
            "allowedAuthorityScopes": ["capability.execute", "goals.write"],
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

#[tokio::test]
async fn capability_execute_subagent_task_reads_require_read_resource_authority() {
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
    .with_required_authority(AuthorityRequirement::scope("capability.execute"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger());
    execute.risk_level = RiskLevel::Medium;
    handle
        .register_function_for_setup(execute, Some(handler), false)
        .unwrap();

    let missing_subagent_read_grant = derive_bootstrap_grant(
        &handle,
        "execute-subagent-without-subagents-read",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute", "resource.read"],
            "allowedResourceKinds": ["subagent_task"],
            "resourceSelectors": ["kind:subagent_task"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 5},
            "provenance": {"source": "execute-subagent-read-scope-test"}
        }),
    )
    .await;
    assert_eq!(missing_subagent_read_grant.error, None);

    let denied_scope = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "operation": "subagent_task_list",
                "limit": 10
            }),
            CausalContext::new(
                actor("agent:session-a"),
                ActorKind::Agent,
                grant("execute-subagent-without-subagents-read"),
                trace("execute-subagent-read-scope-denied"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("execute-subagent-read-scope-denied"),
        ))
        .await;
    assert!(matches!(
        denied_scope.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow required authority subagents.read")
    ));

    let missing_resource_read_grant = derive_bootstrap_grant(
        &handle,
        "execute-subagent-without-resource-read",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute", "subagents.read"],
            "allowedResourceKinds": ["subagent_task"],
            "resourceSelectors": ["kind:subagent_task"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 5},
            "provenance": {"source": "execute-subagent-resource-read-test"}
        }),
    )
    .await;
    assert_eq!(missing_resource_read_grant.error, None);

    let denied_resource_scope = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "operation": "subagent_task_inspect",
                "subagentTaskResourceId": "subagent_task:authorized"
            }),
            CausalContext::new(
                actor("agent:session-a"),
                ActorKind::Agent,
                grant("execute-subagent-without-resource-read"),
                trace("execute-subagent-resource-read-denied"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("execute-subagent-resource-read-denied"),
        ))
        .await;
    assert!(matches!(
        denied_resource_scope.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow required authority resource.read")
    ));

    let missing_kind_grant = derive_bootstrap_grant(
        &handle,
        "execute-subagent-without-kind",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute", "subagents.read", "resource.read"],
            "allowedResourceKinds": ["agent_state"],
            "resourceSelectors": ["kind:agent_state"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 5},
            "provenance": {"source": "execute-subagent-kind-test"}
        }),
    )
    .await;
    assert_eq!(missing_kind_grant.error, None);

    let denied_kind = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "operation": "subagent_task_list",
                "limit": 10
            }),
            CausalContext::new(
                actor("agent:session-a"),
                ActorKind::Agent,
                grant("execute-subagent-without-kind"),
                trace("execute-subagent-kind-denied"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("execute-subagent-kind-denied"),
        ))
        .await;
    assert!(matches!(
        denied_kind.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow resource kind subagent_task")
    ));

    let missing_selector_grant = derive_bootstrap_grant(
        &handle,
        "execute-subagent-without-selector",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute", "subagents.read", "resource.read"],
            "allowedResourceKinds": ["subagent_task"],
            "resourceSelectors": ["kind:agent_state"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 5},
            "provenance": {"source": "execute-subagent-selector-test"}
        }),
    )
    .await;
    assert_eq!(missing_selector_grant.error, None);

    let denied_selector = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "operation": "subagent_task_inspect",
                "subagentTaskResourceId": "subagent_task:authorized"
            }),
            CausalContext::new(
                actor("agent:session-a"),
                ActorKind::Agent,
                grant("execute-subagent-without-selector"),
                trace("execute-subagent-selector-denied"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("execute-subagent-selector-denied"),
        ))
        .await;
    assert!(matches!(
        denied_selector.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow new resource kind subagent_task")
    ));

    let accepted_grant = derive_bootstrap_grant(
        &handle,
        "execute-subagent-read-only",
        json!({
            "allowedCapabilities": ["capability::execute"],
            "allowedNamespaces": ["capability"],
            "allowedAuthorityScopes": ["capability.execute", "subagents.read", "resource.read"],
            "allowedResourceKinds": ["subagent_task"],
            "resourceSelectors": ["kind:subagent_task"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 5},
            "provenance": {"source": "execute-subagent-accepted-test"}
        }),
    )
    .await;
    assert_eq!(accepted_grant.error, None);

    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "subagent read authority denials must happen before handler execution"
    );
    let accepted = handle
        .invoke(host_invocation(
            "capability::execute",
            json!({
                "operation": "subagent_task_list",
                "limit": 10
            }),
            CausalContext::new(
                actor("agent:session-a"),
                ActorKind::Agent,
                grant("execute-subagent-read-only"),
                trace("execute-subagent-accepted"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("execute-subagent-accepted"),
        ))
        .await;
    assert_eq!(accepted.error, None);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}
