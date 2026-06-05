use super::*;

#[tokio::test]
async fn agent_high_risk_invocation_auto_decides_by_default_without_pending_prompt() {
    let _settings = set_agent_approval_prompt_mode(
        crate::domains::settings::AutonomyApprovalPromptMode::Disabled,
    );
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::delete"),
        wid("danger"),
        "approval-gated delete",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test delete is manually compensated",
    ))
    .with_request_schema(json!({
        "type": "object",
        "required": ["id"],
        "additionalProperties": false,
        "properties": {"id": {"type": "string"}}
    }));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();
    handle
        .subscribe_stream(
            "approval-auto-test".to_owned(),
            "approvals".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();

    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let result = client
        .invoke(
            fid("danger::delete"),
            json!({"id": "target"}),
            Some("approval-auto-key".to_owned()),
            None,
        )
        .await;

    assert_eq!(result.error, None);
    assert_eq!(result.value.as_ref().unwrap()["call"], 1);
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let approvals = handle
        .list_approvals(None, Some("session-a"), 10)
        .await
        .unwrap();
    assert_eq!(approvals.len(), 1);
    assert_eq!(approvals[0].status, ApprovalStatus::Executed);
    assert_eq!(approvals[0].function_id, fid("danger::delete"));
    assert_eq!(
        approvals[0].decision_actor_id.as_ref().unwrap().as_str(),
        "system"
    );

    let page = handle
        .poll_stream(
            "approval-auto-test",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    assert!(
        page.events
            .iter()
            .all(|event| event.payload["type"] != "approval.pending"),
        "default autonomy must not publish interactive pending approval prompts"
    );
    assert!(page.events.iter().any(|event| {
        event.payload["type"] == "approval.resolved"
            && event.payload["autoDecision"] == true
            && event.payload["approval"]["status"] == "executed"
    }));
}

#[tokio::test]
async fn agent_high_risk_auto_decision_replay_keeps_single_audit_record_and_child_effect() {
    let _settings = set_agent_approval_prompt_mode(
        crate::domains::settings::AutonomyApprovalPromptMode::Disabled,
    );
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::delete"),
        wid("danger"),
        "approval-gated delete",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test delete is manually compensated",
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
    handle
        .subscribe_stream(
            "approval-auto-replay-test".to_owned(),
            "approvals".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();

    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let first = client
        .invoke(
            fid("danger::delete"),
            json!({"id": "target"}),
            Some("approval-auto-replay-key".to_owned()),
            None,
        )
        .await;
    let second = client
        .invoke(
            fid("danger::delete"),
            json!({"id": "target"}),
            Some("approval-auto-replay-key".to_owned()),
            None,
        )
        .await;

    assert_eq!(first.error, None);
    assert_eq!(second.error, None);
    assert_eq!(first.value.as_ref().unwrap()["call"], 1);
    assert_eq!(second.value.as_ref().unwrap()["call"], 1);
    assert_eq!(second.replayed_from, Some(first.invocation_id.clone()));
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let approvals = handle
        .list_approvals(None, Some("session-a"), 10)
        .await
        .unwrap();
    assert_eq!(approvals.len(), 1);
    assert_eq!(approvals[0].status, ApprovalStatus::Executed);

    let page = handle
        .poll_stream(
            "approval-auto-replay-test",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    assert_eq!(
        page.events
            .iter()
            .filter(|event| event.payload["type"] == "approval.resolved")
            .count(),
        1
    );
}

#[tokio::test]
async fn agent_high_risk_auto_decision_replays_denied_approval_without_child_effect() {
    let _settings = set_agent_approval_prompt_mode(
        crate::domains::settings::AutonomyApprovalPromptMode::Disabled,
    );
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::delete"),
        wid("danger"),
        "approval-gated delete",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval denied replay test delete is manually compensated",
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

    let pending = handle
        .request_approval(crate::engine::EngineApprovalRequest {
            function_id: fid("danger::delete"),
            payload: json!({"id": "target"}),
            causal_context: mutating_causal("approval-auto-denied-replay-key")
                .with_scope("danger.write"),
            delivery_mode: DeliveryMode::Sync,
            target_metadata: None,
        })
        .await
        .unwrap();
    let denied = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": pending.approval_id, "decision": "deny"}),
            CausalContext::new(
                actor("admin"),
                ActorKind::Admin,
                grant("approval-admin"),
                trace("approval-auto-denied-replay-resolve"),
            )
            .with_scope("approval.resolve")
            .with_idempotency_key("approval-auto-denied-resolve-key"),
        ))
        .await;
    assert_eq!(denied.error, None);
    assert_eq!(
        denied.value.as_ref().unwrap()["approval"]["status"],
        "denied"
    );
    let baseline_records = handle.invocation_records().await.len();

    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["danger.write"])
        .with_session_id("session-a")
        .with_workspace_id("workspace-a");
    let replayed = client
        .invoke(
            fid("danger::delete"),
            json!({"id": "target"}),
            Some("approval-auto-denied-replay-key".to_owned()),
            None,
        )
        .await;

    let Some(EngineError::DomainFailure { code, details, .. }) = replayed.error else {
        panic!("expected denied approval failure, got {:?}", replayed.error);
    };
    assert_eq!(code, "APPROVAL_DENIED");
    assert_eq!(details.unwrap()["approvalId"], pending.approval_id.as_str());
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert_eq!(handle.invocation_records().await.len(), baseline_records);
    let approvals = handle
        .list_approvals(None, Some("session-a"), 10)
        .await
        .unwrap();
    assert_eq!(approvals.len(), 1);
    assert_eq!(approvals[0].status, ApprovalStatus::Denied);
}

#[tokio::test]
async fn agent_high_risk_auto_decision_replays_failed_approval_without_child_retry() {
    let _settings = set_agent_approval_prompt_mode(
        crate::domains::settings::AutonomyApprovalPromptMode::Disabled,
    );
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::delete"),
        wid("danger"),
        "approval-gated delete",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval failed replay test delete is manually compensated",
    ));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(CountingFailHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();

    let pending = handle
        .request_approval(crate::engine::EngineApprovalRequest {
            function_id: fid("danger::delete"),
            payload: json!({"id": "target"}),
            causal_context: mutating_causal("approval-auto-failed-replay-key")
                .with_scope("danger.write"),
            delivery_mode: DeliveryMode::Sync,
            target_metadata: None,
        })
        .await
        .unwrap();
    let failed = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": pending.approval_id, "decision": "approve"}),
            CausalContext::new(
                actor("admin"),
                ActorKind::Admin,
                grant("approval-admin"),
                trace("approval-auto-failed-replay-resolve"),
            )
            .with_scope("approval.resolve")
            .with_idempotency_key("approval-auto-failed-resolve-key"),
        ))
        .await;
    assert_eq!(failed.error, None);
    assert_eq!(
        failed.value.as_ref().unwrap()["approval"]["status"],
        "failed"
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let baseline_records = handle.invocation_records().await;
    let original_child = baseline_records
        .iter()
        .find(|record| record.function_id == fid("danger::delete"))
        .expect("failed approval records the original child invocation")
        .invocation_id
        .clone();

    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["danger.write"])
        .with_session_id("session-a")
        .with_workspace_id("workspace-a");
    let replayed = client
        .invoke(
            fid("danger::delete"),
            json!({"id": "target"}),
            Some("approval-auto-failed-replay-key".to_owned()),
            None,
        )
        .await;

    assert!(matches!(
        replayed.error,
        Some(EngineError::StoredInvocationError { ref kind, .. }) if kind == "handler_failed"
    ));
    assert_eq!(replayed.replayed_from, Some(original_child));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        handle.invocation_records().await.len(),
        baseline_records.len()
    );
    let approvals = handle
        .list_approvals(None, Some("session-a"), 10)
        .await
        .unwrap();
    assert_eq!(approvals.len(), 1);
    assert_eq!(approvals[0].status, ApprovalStatus::Failed);
}

#[tokio::test]
async fn agent_high_risk_invocation_guardrail_block_creates_no_auto_decision() {
    let _settings = set_agent_approval_prompt_mode(
        crate::domains::settings::AutonomyApprovalPromptMode::Disabled,
    );
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::delete"),
        wid("danger"),
        "approval-gated delete",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test delete is manually compensated",
    ))
    .with_request_schema(json!({
        "type": "object",
        "required": ["id"],
        "additionalProperties": false,
        "properties": {"id": {"type": "string"}}
    }));
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
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let rejected = client
        .invoke(
            fid("danger::delete"),
            json!({}),
            Some("approval-auto-blocked-key".to_owned()),
            None,
        )
        .await;

    assert!(matches!(
        rejected.error,
        Some(EngineError::SchemaViolation { .. })
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let approvals = handle
        .list_approvals(None, Some("session-a"), 10)
        .await
        .unwrap();
    assert!(approvals.is_empty());
}
