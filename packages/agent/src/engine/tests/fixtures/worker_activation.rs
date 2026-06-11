use super::*;

#[derive(Clone)]
pub(in crate::engine::tests) struct WorkerActivationGovernanceConfig {
    pub suffix: String,
    pub function_id: String,
    pub target_visibility: VisibilityScope,
    pub workspace_id: Option<String>,
    pub candidate_kind: String,
    pub candidate_lifecycle: String,
    pub candidate_function_id: Option<String>,
    pub candidate_visibility: Option<VisibilityScope>,
    pub decision_lifecycle: String,
    pub decision_status: String,
    pub evidence_lifecycle: String,
    pub evidence_verified: bool,
    pub link_chain: bool,
    pub resource_scope: Option<VisibilityScope>,
}

impl WorkerActivationGovernanceConfig {
    pub(in crate::engine::tests) fn session(suffix: &str, function_id: &str) -> Self {
        Self {
            suffix: suffix.to_owned(),
            function_id: function_id.to_owned(),
            target_visibility: VisibilityScope::Session,
            workspace_id: None,
            candidate_kind: "capability_definition".to_owned(),
            candidate_lifecycle: "reviewed".to_owned(),
            candidate_function_id: None,
            candidate_visibility: None,
            decision_lifecycle: "final".to_owned(),
            decision_status: "accepted".to_owned(),
            evidence_lifecycle: "accepted".to_owned(),
            evidence_verified: true,
            link_chain: true,
            resource_scope: None,
        }
    }

    pub(in crate::engine::tests) fn workspace(suffix: &str, function_id: &str) -> Self {
        Self {
            target_visibility: VisibilityScope::Workspace,
            workspace_id: Some("workspace-a".to_owned()),
            ..Self::session(suffix, function_id)
        }
    }
}

pub(in crate::engine::tests) struct WorkerActivationGovernanceFixture {
    pub function_id: String,
    pub target_visibility: VisibilityScope,
    pub workspace_id: Option<String>,
    pub candidate_resource_id: String,
    pub decision_resource_id: String,
    pub evidence_resource_ids: Vec<String>,
}

pub(in crate::engine::tests) async fn create_worker_activation_governance(
    handle: &EngineHostHandle,
    config: WorkerActivationGovernanceConfig,
) -> WorkerActivationGovernanceFixture {
    let decision_resource_id = format!("saawa-{}-decision", config.suffix);
    let evidence_resource_id = format!("saawa-{}-evidence", config.suffix);
    let candidate_resource_id = format!("saawa-{}-candidate", config.suffix);
    let target_visibility = config.target_visibility.as_str();

    let mut decision_payload = json!({
        "status": config.decision_status,
        "summary": "worker activation accepted",
        "functionId": config.function_id,
        "targetVisibility": target_visibility,
        "candidateResourceIds": [candidate_resource_id.as_str()],
        "promotedResources": [candidate_resource_id.as_str()],
        "metadata": {
            "approvedFunctionId": config.function_id,
            "approvedTargetVisibility": target_visibility,
        }
    });
    if let Some(workspace_id) = config.workspace_id.as_deref() {
        decision_payload["workspaceId"] = json!(workspace_id);
        decision_payload["metadata"]["workspaceId"] = json!(workspace_id);
    }

    create_worker_activation_resource(
        handle,
        &decision_resource_id,
        "decision",
        &config.decision_lifecycle,
        decision_payload,
        &config,
        "decision-create",
    )
    .await;
    create_worker_activation_resource(
        handle,
        &evidence_resource_id,
        "evidence",
        &config.evidence_lifecycle,
        json!({
            "summary": "activation verification passed",
            "source": "test",
            "metadata": {
                "verified": config.evidence_verified,
                "verificationStatus": if config.evidence_verified { "verified" } else { "draft" }
            }
        }),
        &config,
        "evidence-create",
    )
    .await;
    create_worker_activation_resource(
        handle,
        &candidate_resource_id,
        &config.candidate_kind,
        &config.candidate_lifecycle,
        worker_activation_candidate_payload(&config),
        &config,
        "candidate-create",
    )
    .await;
    if config.link_chain {
        link_worker_activation_resources(
            handle,
            &decision_resource_id,
            &evidence_resource_id,
            "supported_by",
            &config,
            "decision-evidence",
        )
        .await;
        link_worker_activation_resources(
            handle,
            &decision_resource_id,
            &candidate_resource_id,
            "promotes",
            &config,
            "decision-candidate",
        )
        .await;
    }

    WorkerActivationGovernanceFixture {
        function_id: config.function_id,
        target_visibility: config.target_visibility,
        workspace_id: config.workspace_id,
        candidate_resource_id,
        decision_resource_id,
        evidence_resource_ids: vec![evidence_resource_id],
    }
}

pub(in crate::engine::tests) fn worker_activation_issue_payload(
    fixture: &WorkerActivationGovernanceFixture,
    idempotency_key: &str,
) -> Value {
    let mut payload = json!({
        "functionId": fixture.function_id,
        "candidateResourceId": fixture.candidate_resource_id,
        "decisionResourceId": fixture.decision_resource_id,
        "evidenceResourceIds": fixture.evidence_resource_ids,
        "targetVisibility": fixture.target_visibility.as_str(),
        "activationReason": "accepted activation governance",
        "idempotencyKey": idempotency_key,
    });
    if let Some(workspace_id) = fixture.workspace_id.as_deref() {
        payload["workspaceId"] = json!(workspace_id);
    }
    payload
}

pub(in crate::engine::tests) fn worker_activation_admin_causal(
    idempotency_key: &str,
) -> CausalContext {
    CausalContext::new(
        actor("admin"),
        ActorKind::Admin,
        grant("grant"),
        trace(&format!("worker-activation-{idempotency_key}")),
    )
    .with_scope("worker.activate")
    .with_session_id("session-a")
    .with_workspace_id("workspace-a")
    .with_idempotency_key(idempotency_key)
}

pub(in crate::engine::tests) async fn issue_worker_activation(
    handle: &EngineHostHandle,
    fixture: &WorkerActivationGovernanceFixture,
    idempotency_key: &str,
) -> InvocationResult {
    handle
        .invoke(host_invocation(
            "worker::issue_activation",
            worker_activation_issue_payload(fixture, idempotency_key),
            worker_activation_admin_causal(idempotency_key),
        ))
        .await
}

fn worker_activation_candidate_payload(config: &WorkerActivationGovernanceConfig) -> Value {
    if config.candidate_kind != "capability_definition" {
        return json!({
            "title": "Invalid activation candidate",
            "body": "not a capability definition"
        });
    }
    let candidate_function_id = config
        .candidate_function_id
        .as_deref()
        .unwrap_or(config.function_id.as_str());
    let candidate_visibility = config
        .candidate_visibility
        .clone()
        .unwrap_or_else(|| config.target_visibility.clone());
    let mut definition = external_visible_function(
        FunctionDefinition::new(
            fid(candidate_function_id),
            wid("reviewed-candidate-worker"),
            "reviewed activation function",
            candidate_visibility,
            EffectClass::PureRead,
        )
        .with_provenance(match config.target_visibility {
            VisibilityScope::Session => Provenance::system().with_session_id("session-a"),
            VisibilityScope::Workspace => Provenance::system()
                .with_workspace_id(config.workspace_id.as_deref().unwrap_or("workspace-a")),
            _ => Provenance::system(),
        }),
    );
    definition.metadata["signatureStatus"] = json!("engine_issued");
    json!({
        "functionId": config.function_id,
        "definition": serde_json::to_value(definition).unwrap(),
        "generatedBy": "saawa-test",
        "metadata": {
            "source": "reviewed capability definition"
        }
    })
}

async fn create_worker_activation_resource(
    handle: &EngineHostHandle,
    resource_id: &str,
    kind: &str,
    lifecycle: &str,
    payload: Value,
    config: &WorkerActivationGovernanceConfig,
    suffix: &str,
) {
    let resource_scope = config
        .resource_scope
        .as_ref()
        .unwrap_or(&config.target_visibility);
    let mut request = json!({
        "resourceId": resource_id,
        "kind": kind,
        "scope": resource_scope.as_str(),
        "lifecycle": lifecycle,
        "payload": payload
    });
    if *resource_scope == VisibilityScope::Session {
        request["sessionId"] = json!("session-a");
    }
    if *resource_scope == VisibilityScope::Workspace {
        request["workspaceId"] = json!(config.workspace_id.as_deref().unwrap_or("workspace-a"));
    }
    let key = format!("saawa-{}-{suffix}", config.suffix);
    let result = handle
        .invoke(host_invocation(
            "resource::create",
            request,
            mutating_causal(&key).with_scope("resource.write"),
        ))
        .await;
    assert_eq!(
        result.error, None,
        "resource create failed for {resource_id}: {:?}",
        result.value
    );
}

async fn link_worker_activation_resources(
    handle: &EngineHostHandle,
    source: &str,
    target: &str,
    relation: &str,
    config: &WorkerActivationGovernanceConfig,
    suffix: &str,
) {
    let key = format!("saawa-{}-{suffix}", config.suffix);
    let result = handle
        .invoke(host_invocation(
            "resource::link",
            json!({
                "sourceResourceId": source,
                "targetResourceId": target,
                "relation": relation
            }),
            mutating_causal(&key).with_scope("resource.write"),
        ))
        .await;
    assert_eq!(
        result.error, None,
        "resource link failed for {source}->{target}: {:?}",
        result.value
    );
}
