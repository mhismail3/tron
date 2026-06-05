use super::*;

#[tokio::test]
async fn agent_high_risk_invocation_creates_pending_approval_and_stream_event() {
    let _settings = set_agent_approval_prompt_mode(
        crate::domains::settings::AutonomyApprovalPromptMode::Testing,
    );
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
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
    .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
        "danger",
        "danger:{id}",
        60_000,
    ))
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test delete is manually compensated",
    ));
    handle
        .register_function_for_setup(function, Some(handler()), false)
        .unwrap();
    handle
        .subscribe_stream(
            "approval-test".to_owned(),
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
            Some("approval-key".to_owned()),
            None,
        )
        .await;
    let Some(EngineError::DomainFailure { code, details, .. }) = result.error else {
        panic!("expected approval domain failure, got {:?}", result.error);
    };
    assert_eq!(code, "APPROVAL_REQUIRED");
    let approval_id = details.unwrap()["approvalId"].as_str().unwrap().to_owned();
    let record = handle.get_approval(&approval_id).await.unwrap().unwrap();
    assert_eq!(record.status, ApprovalStatus::Pending);
    assert_eq!(record.function_id, fid("danger::delete"));
    assert_eq!(record.session_id.as_deref(), Some("session-a"));
    let metadata = record
        .target_metadata
        .as_ref()
        .expect("approval records snapshot target metadata");
    assert_eq!(metadata.effect_class, EffectClass::IrreversibleSideEffect);
    assert_eq!(metadata.risk_level, RiskLevel::High);
    assert_eq!(
        metadata.required_authority.scopes,
        vec!["danger.write".to_owned()]
    );
    assert!(metadata.required_authority.approval_required);
    assert_eq!(
        metadata.idempotency.as_ref().unwrap().ledger_kind,
        LedgerKind::EngineLedger
    );
    assert_eq!(
        metadata
            .resource_lease
            .as_ref()
            .unwrap()
            .resource_id_template,
        "danger:{id}"
    );
    assert_eq!(
        metadata.compensation.as_ref().unwrap().kind,
        CompensationKind::ManualOnly
    );

    let page = handle
        .poll_stream(
            "approval-test",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    assert_eq!(page.events.len(), 1);
    assert_eq!(page.events[0].payload["type"], "approval.pending");
    assert_eq!(
        page.events[0].payload["approval"]["approvalId"],
        approval_id
    );
    assert_eq!(
        page.events[0].payload["approval"]["targetMetadata"]["effectClass"],
        "IrreversibleSideEffect"
    );
    assert_eq!(
        page.events[0].payload["approval"]["targetMetadata"]["riskLevel"],
        "High"
    );
    assert_eq!(
        page.events[0].payload["approval"]["targetMetadata"]["requiredAuthority"]["scopes"][0],
        "danger.write"
    );
    assert_eq!(
        page.events[0].payload["approval"]["targetMetadata"]["idempotency"]["ledgerKind"],
        "EngineLedger"
    );
    assert_eq!(
        page.events[0].payload["approval"]["targetMetadata"]["resourceLease"]["resourceIdTemplate"],
        "danger:{id}"
    );
    assert_eq!(
        page.events[0].payload["approval"]["targetMetadata"]["compensation"]["kind"],
        "manualOnly"
    );

    let trace = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": record.trace_id.as_str()}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("system-grant"),
                trace("approval-observe"),
            )
            .with_scope("observability.read"),
        ))
        .await;
    assert_eq!(trace.error, None);
    let invocations = trace.value.as_ref().unwrap()["invocations"]
        .as_array()
        .unwrap();
    assert!(invocations.iter().any(|invocation| {
        invocation["functionId"] == "danger::delete"
            && invocation["succeeded"] == false
            && invocation["error"]["message"]
                .as_str()
                .is_some_and(|message| message.contains("APPROVAL_REQUIRED"))
    }));
}

#[tokio::test]
async fn approval_request_function_publishes_once_and_replays_by_idempotency() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .subscribe_stream(
            "approval-request-test".to_owned(),
            "approvals".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();
    let context = mutating_causal("approval-request-key").with_scope("approval.request");
    let payload = json!({
        "functionId": "danger::delete",
        "payload": {"id": "target"}
    });

    let created = handle
        .invoke(host_invocation(
            "approval::request",
            payload.clone(),
            context.clone(),
        ))
        .await;
    assert_eq!(created.error, None);
    let approval_id = created.value.as_ref().unwrap()["approval"]["approvalId"]
        .as_str()
        .unwrap()
        .to_owned();
    let replayed = handle
        .invoke(host_invocation("approval::request", payload, context))
        .await;
    assert_eq!(replayed.error, None);
    assert_eq!(replayed.replayed_from, Some(created.invocation_id));
    assert_eq!(
        replayed.value.as_ref().unwrap()["approval"]["approvalId"],
        approval_id
    );

    let page = handle
        .poll_stream(
            "approval-request-test",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    assert_eq!(page.events.len(), 1);
    assert_eq!(page.events[0].payload["type"], "approval.pending");
    assert_eq!(
        page.events[0].payload["approval"]["approvalId"],
        approval_id
    );
}

#[tokio::test]
async fn terminal_approval_replay_does_not_publish_fresh_pending_event() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::write"),
        wid("danger"),
        "approval-gated write",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval replay test write is manually compensated",
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
            "approval-terminal-replay-test".to_owned(),
            "approvals".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();

    let request = crate::engine::EngineApprovalRequest {
        function_id: fid("danger::write"),
        payload: json!({"value": 1}),
        causal_context: mutating_causal("terminal-approval-key").with_scope("danger.write"),
        delivery_mode: DeliveryMode::Sync,
        target_metadata: None,
    };
    let pending = handle.request_approval(request.clone()).await.unwrap();
    assert_eq!(pending.status, ApprovalStatus::Pending);

    let resolved = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": pending.approval_id, "decision": "approve"}),
            CausalContext::new(
                actor("admin"),
                ActorKind::Admin,
                grant("approval-admin"),
                trace("approval-terminal-replay-trace"),
            )
            .with_scope("approval.resolve")
            .with_idempotency_key("terminal-approval-resolve-key"),
        ))
        .await;
    assert_eq!(resolved.error, None);
    assert_eq!(
        resolved.value.as_ref().unwrap()["approval"]["status"],
        "executed"
    );

    let replayed = handle.request_approval(request).await.unwrap();
    assert_eq!(replayed.status, ApprovalStatus::Executed);
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let page = handle
        .poll_stream(
            "approval-terminal-replay-test",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    let pending_events = page
        .events
        .iter()
        .filter(|event| event.payload["type"] == "approval.pending")
        .count();
    assert_eq!(pending_events, 1);
}

#[tokio::test]
async fn approval_idempotency_is_scoped_to_session() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let first = handle
        .request_approval(crate::engine::EngineApprovalRequest {
            function_id: fid("danger::write"),
            payload: json!({"value": 1}),
            causal_context: mutating_causal("shared-approval-key").with_scope("danger.write"),
            delivery_mode: DeliveryMode::Sync,
            target_metadata: None,
        })
        .await
        .unwrap();
    let second = handle
        .request_approval(crate::engine::EngineApprovalRequest {
            function_id: fid("danger::write"),
            payload: json!({"value": 2}),
            causal_context: mutating_causal("shared-approval-key")
                .with_scope("danger.write")
                .with_session_id("session-b"),
            delivery_mode: DeliveryMode::Sync,
            target_metadata: None,
        })
        .await
        .unwrap();

    assert_ne!(first.approval_id, second.approval_id);
    assert_eq!(first.idempotency_key, second.idempotency_key);
    assert_eq!(first.session_id.as_deref(), Some("session-a"));
    assert_eq!(second.session_id.as_deref(), Some("session-b"));

    let records = handle.list_approvals(None, None, 10).await.unwrap();
    assert_eq!(records.len(), 2);
}

#[tokio::test]
async fn approval_idempotency_still_conflicts_within_session() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .request_approval(crate::engine::EngineApprovalRequest {
            function_id: fid("danger::write"),
            payload: json!({"value": 1}),
            causal_context: mutating_causal("session-scoped-conflict").with_scope("danger.write"),
            delivery_mode: DeliveryMode::Sync,
            target_metadata: None,
        })
        .await
        .unwrap();
    let result = handle
        .request_approval(crate::engine::EngineApprovalRequest {
            function_id: fid("danger::write"),
            payload: json!({"value": 2}),
            causal_context: mutating_causal("session-scoped-conflict").with_scope("danger.write"),
            delivery_mode: DeliveryMode::Sync,
            target_metadata: None,
        })
        .await;

    assert!(matches!(
        result,
        Err(EngineError::IdempotencyConflict { key, .. }) if key == "session-scoped-conflict"
    ));
}

#[tokio::test]
async fn approval_resolution_rejects_agent_even_with_resolve_scope() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let request_context = mutating_causal("approval-agent-deny-key").with_scope("approval.request");
    let created = handle
        .invoke(host_invocation(
            "approval::request",
            json!({
                "functionId": "danger::write",
                "payload": {"value": 1}
            }),
            request_context,
        ))
        .await;
    assert_eq!(created.error, None);
    let approval_id = created.value.as_ref().unwrap()["approval"]["approvalId"]
        .as_str()
        .unwrap()
        .to_owned();

    let agent_resolve_context = CausalContext::new(
        actor("agent"),
        ActorKind::Agent,
        grant("approval-agent"),
        trace("approval-agent-trace"),
    )
    .with_scope("approval.resolve")
    .with_idempotency_key("approval-agent-resolve-key");
    let rejected = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": approval_id, "decision": "approve"}),
            agent_resolve_context,
        ))
        .await;
    let Some(EngineError::PolicyViolation(message)) = rejected.error else {
        panic!("expected policy violation, got {:?}", rejected.error);
    };
    assert!(message.contains("admin, system, or user-authorized actor"));
    let record = handle.get_approval(&approval_id).await.unwrap().unwrap();
    assert_eq!(record.status, ApprovalStatus::Pending);
}

#[tokio::test]
async fn agent_capability_client_hides_all_approval_primitives_without_new_approval() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["approval.resolve"])
        .with_session_id("session-a");
    let visible_approval_functions = client
        .discover(FunctionQuery {
            namespace_prefix: Some("approval".to_owned()),
            ..FunctionQuery::default()
        })
        .await;
    assert!(
        visible_approval_functions.is_empty(),
        "approval primitives are client-owned and must not be visible to agent discovery"
    );
    assert!(client.inspect(&fid("approval::get")).await.is_err());
    assert!(client.inspect(&fid("approval::list")).await.is_err());
    assert!(client.inspect(&fid("approval::resolve")).await.is_err());

    let rejected = client
        .invoke(
            fid("approval::resolve"),
            json!({"approvalId": "approval-a", "decision": "approve"}),
            Some("agent-approval-resolve-key".to_owned()),
            None,
        )
        .await;

    let Some(EngineError::PolicyViolation(message)) = rejected.error else {
        panic!("expected policy violation, got {:?}", rejected.error);
    };
    assert!(message.contains("user/client approval flow"));
    let approvals = handle.list_approvals(None, None, 100).await.unwrap();
    assert!(approvals.is_empty());
}

#[tokio::test]
async fn agent_approval_preflight_rejects_invalid_payload_before_request() {
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
        "approval preflight test delete is manually compensated",
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
            Some("invalid-approval-key".to_owned()),
            None,
        )
        .await;

    assert!(matches!(
        rejected.error,
        Some(EngineError::SchemaViolation { .. })
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let approvals = handle.list_approvals(None, None, 100).await.unwrap();
    assert!(approvals.is_empty());
}

#[tokio::test]
async fn approval_resolution_resumes_original_invocation_with_original_causality() {
    let _settings = set_agent_approval_prompt_mode(
        crate::domains::settings::AutonomyApprovalPromptMode::Testing,
    );
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::write"),
        wid("danger"),
        "approval-gated write",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test write is manually compensated",
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
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let pending = client
        .invoke(
            fid("danger::write"),
            json!({"value": 1}),
            Some("approval-run-key".to_owned()),
            None,
        )
        .await;
    let approval_id = match pending.error.unwrap() {
        EngineError::DomainFailure { details, .. } => {
            details.unwrap()["approvalId"].as_str().unwrap().to_owned()
        }
        other => panic!("unexpected error {other:?}"),
    };

    let resolve_context = CausalContext::new(
        actor("admin"),
        ActorKind::Admin,
        grant("approval-admin"),
        trace("approval-trace"),
    )
    .with_scope("approval.resolve")
    .with_idempotency_key("resolve-key");
    let resolved = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": approval_id, "decision": "approve"}),
            resolve_context,
        ))
        .await;
    assert_eq!(resolved.error, None);
    assert_eq!(
        resolved.value.as_ref().unwrap()["approval"]["status"],
        "executed"
    );
    assert_eq!(
        resolved.value.as_ref().unwrap()["child"]["value"]["call"],
        1
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn approval_resolution_resumes_host_dispatched_primitives() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("volatile-helper", "demo"), true)
        .unwrap();
    let pending = handle
        .request_approval(crate::engine::EngineApprovalRequest {
            function_id: fid("worker::disconnect"),
            payload: json!({
                "workerId": "volatile-helper",
                "reason": "approval cleanup proof"
            }),
            causal_context: mutating_causal("approval-worker-disconnect-child")
                .with_scope("worker.write"),
            delivery_mode: DeliveryMode::Sync,
            target_metadata: None,
        })
        .await
        .unwrap();
    assert_eq!(pending.status, ApprovalStatus::Pending);

    let resolved = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": pending.approval_id, "decision": "approve"}),
            CausalContext::new(
                actor("admin"),
                ActorKind::Admin,
                grant("approval-admin"),
                trace("approval-host-primitive-trace"),
            )
            .with_scope("approval.resolve")
            .with_idempotency_key("approval-host-primitive-resolve"),
        ))
        .await;

    assert_eq!(resolved.error, None);
    assert_eq!(
        resolved.value.as_ref().unwrap()["approval"]["status"],
        "executed"
    );
    assert_eq!(
        resolved.value.as_ref().unwrap()["child"]["value"]["disconnected"],
        true
    );

    let missing = handle
        .invoke(host_invocation(
            "worker::get",
            json!({"workerId": "volatile-helper"}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("system-grant"),
                trace("approval-host-primitive-worker-get"),
            )
            .with_scope("worker.read"),
        ))
        .await;
    assert!(matches!(missing.error, Some(EngineError::NotFound { .. })));
}

#[tokio::test]
async fn engine_invoke_routes_approval_resolve_through_host_resume_path() {
    let _settings = set_agent_approval_prompt_mode(
        crate::domains::settings::AutonomyApprovalPromptMode::Testing,
    );
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::write"),
        wid("danger"),
        "approval-gated write",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test write is manually compensated",
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
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let pending = client
        .invoke(
            fid("danger::write"),
            json!({"value": 1}),
            Some("approval-engine-invoke-child-key".to_owned()),
            None,
        )
        .await;
    let approval_id = match pending.error.unwrap() {
        EngineError::DomainFailure { details, .. } => {
            details.unwrap()["approvalId"].as_str().unwrap().to_owned()
        }
        other => panic!("unexpected error {other:?}"),
    };

    let resolved = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "approval::resolve",
                "payload": {"approvalId": approval_id, "decision": "approve"},
                "idempotencyKey": "transport-approval-resolve-key"
            }),
            CausalContext::new(
                actor("engine-user"),
                ActorKind::User,
                grant("engine-transport"),
                trace("transport-approval-trace"),
            )
            .with_scope("approval.resolve")
            .with_session_id("session-a"),
        ))
        .await;

    assert_eq!(resolved.error, None);
    assert_eq!(
        resolved.value.as_ref().unwrap()["child"]["value"]["approval"]["status"],
        "executed"
    );
    assert_eq!(
        resolved.value.as_ref().unwrap()["child"]["value"]["child"]["value"]["call"],
        1
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}
