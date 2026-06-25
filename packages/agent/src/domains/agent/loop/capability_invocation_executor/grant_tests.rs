use super::*;

#[tokio::test]
async fn web_fetch_runtime_grant_stays_source_only_without_robots_evidence() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "web_fetch",
        "url": "https://example.com/source",
        "idempotencyKey": "web-fetch-grant-source-only"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.network_policy, "declared");
    assert!(
        grant
            .allowed_authority_scopes
            .contains(&"web.write".to_owned())
    );
    assert!(
        grant
            .allowed_authority_scopes
            .contains(&"resource.write".to_owned())
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"resource.read".to_owned()),
        "plain web_fetch must not gain robots-policy read authority"
    );
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"web_source".to_owned())
    );
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"web_robots_policy".to_owned()),
        "plain web_fetch must not gain robots-policy resource authority"
    );
    assert!(
        grant
            .resource_selectors
            .contains(&"kind:web_source".to_owned())
    );
    assert!(
        !grant
            .resource_selectors
            .contains(&"kind:web_robots_policy".to_owned())
    );
}

#[tokio::test]
async fn web_fetch_runtime_grant_stays_source_only_with_null_robots_fields() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "web_fetch",
        "url": "https://example.com/source",
        "webRobotsPolicyResourceId": null,
        "expectedWebRobotsPolicyVersionId": null,
        "idempotencyKey": "web-fetch-grant-null-robots"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.network_policy, "declared");
    assert!(
        grant
            .allowed_authority_scopes
            .contains(&"web.write".to_owned())
    );
    assert!(
        grant
            .allowed_authority_scopes
            .contains(&"resource.write".to_owned())
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"web.read".to_owned()),
        "null robots fields must not gain web.read authority"
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"resource.read".to_owned()),
        "null robots fields must not gain resource.read authority"
    );
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"web_source".to_owned())
    );
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"web_robots_policy".to_owned()),
        "null robots fields must not gain robots-policy resource authority"
    );
    assert!(
        !grant
            .resource_selectors
            .contains(&"kind:web_robots_policy".to_owned())
    );
}

#[tokio::test]
async fn web_fetch_runtime_grant_includes_robots_policy_authority_when_linked() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "web_fetch",
        "url": "https://example.com/source",
        "webRobotsPolicyResourceId": "web_robots_policy:abc123",
        "expectedWebRobotsPolicyVersionId": "rver_abc123",
        "idempotencyKey": "web-fetch-grant-robots-linked"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.network_policy, "declared");
    for scope in ["web.read", "web.write", "resource.read", "resource.write"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "linked web_fetch grant should include {scope}"
        );
    }
    for kind in ["web_source", "web_robots_policy"] {
        assert!(
            grant.allowed_resource_kinds.contains(&kind.to_owned()),
            "linked web_fetch grant should include kind {kind}"
        );
        assert!(
            grant.resource_selectors.contains(&format!("kind:{kind}")),
            "linked web_fetch grant should include selector kind:{kind}"
        );
    }
}

async fn captured_execute_invocation_for_payload(payload: Value) -> (EngineHostHandle, Invocation) {
    let engine_host = EngineHostHandle::new_in_memory().expect("engine host");
    engine_host
        .register_worker(
            WorkerDefinition::new(
                WorkerId::new("capability").expect("worker id"),
                WorkerKind::InProcess,
                ActorId::new("capability-owner").expect("actor id"),
                AuthorityGrantId::new("capability-grant").expect("grant id"),
            )
            .with_namespace_claim("capability"),
            false,
        )
        .await
        .expect("register worker");

    let captured = Arc::new(Mutex::new(None));
    let function_id = FunctionId::new("capability::execute").expect("function id");
    let function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("capability").expect("worker id"),
        "Capture execute invocation".to_owned(),
        VisibilityScope::System,
        EffectClass::DelegatedInvocation,
    )
    .with_risk(RiskLevel::Medium)
    .with_required_authority(AuthorityRequirement::scope("capability.execute"));
    engine_host
        .register_function(
            function.clone(),
            Some(Arc::new(CapturingCapabilityHandler {
                captured: Arc::clone(&captured),
            })),
            false,
        )
        .await
        .expect("register function");

    let mut targets_by_name = BTreeMap::new();
    let _ = targets_by_name.insert(
        "execute".to_owned(),
        PrimitiveExecutionTarget {
            model_capability_id: "execute".to_owned(),
            function_id,
            function,
            stops_turn: false,
            execution_mode: ExecutionMode::Parallel,
        },
    );
    let surface = ResolvedPrimitiveSurface {
        capabilities: Vec::new(),
        targets_by_name,
        turn_stopping_capabilities: HashSet::new(),
    };
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel);
    ctx.engine_host = Some(&engine_host);
    let tempdir = tempfile::tempdir().expect("working directory");
    let working_directory = crate::shared::foundation::paths::normalize_working_directory(
        tempdir.path().to_str().expect("utf8 tempdir"),
    )
    .expect("normalized working directory")
    .display()
    .to_string();
    let call =
        CapabilityInvocationDraft::new("provider-call-grant", "execute", payload_object(&payload));

    let result =
        execute_capability_invocation(&call, "session-grant", &working_directory, &ctx).await;
    assert_eq!(result.result.is_error, None, "{:?}", result.result);
    let invocation = captured
        .lock()
        .clone()
        .expect("capability invocation should be captured");
    (engine_host, invocation)
}
