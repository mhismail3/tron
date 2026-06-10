use super::*;

pub(super) struct PromotionGovernanceFixture {
    pub(super) decision_resource_id: String,
    pub(super) evidence_resource_ids: Vec<String>,
    pub(super) candidate_resource_ids: Vec<String>,
}

pub(super) async fn create_promotion_governance(
    host: &mut EngineHost,
    suffix: &str,
    function_id: &str,
    target_visibility: &str,
    workspace_id: Option<&str>,
    candidate_kind: &str,
) -> PromotionGovernanceFixture {
    let decision_resource_id = format!("sapg-{suffix}-decision");
    let evidence_resource_id = format!("sapg-{suffix}-evidence");
    let candidate_resource_id = format!("sapg-{suffix}-candidate");

    let mut decision_payload = json!({
        "status": "accepted",
        "summary": "governed promotion accepted",
        "functionId": function_id,
        "targetVisibility": target_visibility,
        "candidateResourceIds": [candidate_resource_id.as_str()],
        "promotedResources": [candidate_resource_id.as_str()],
        "metadata": {
            "approvedFunctionId": function_id,
            "approvedTargetVisibility": target_visibility
        }
    });
    if let Some(workspace_id) = workspace_id {
        decision_payload["workspaceId"] = json!(workspace_id);
        decision_payload["metadata"]["workspaceId"] = json!(workspace_id);
    }

    create_resource(
        host,
        &decision_resource_id,
        "decision",
        "final",
        decision_payload,
        &format!("sapg-{suffix}-decision-create"),
    )
    .await;
    create_resource(
        host,
        &evidence_resource_id,
        "evidence",
        "accepted",
        json!({
            "summary": "verification passed",
            "source": "test",
            "metadata": {
                "verified": true,
                "verificationStatus": "verified"
            }
        }),
        &format!("sapg-{suffix}-evidence-create"),
    )
    .await;
    create_resource(
        host,
        &candidate_resource_id,
        candidate_kind,
        "draft",
        candidate_payload(candidate_kind, function_id),
        &format!("sapg-{suffix}-candidate-create"),
    )
    .await;
    link_resources(
        host,
        &decision_resource_id,
        &evidence_resource_id,
        "supported_by",
        &format!("sapg-{suffix}-decision-evidence"),
    )
    .await;
    link_resources(
        host,
        &decision_resource_id,
        &candidate_resource_id,
        "promotes",
        &format!("sapg-{suffix}-decision-candidate"),
    )
    .await;

    PromotionGovernanceFixture {
        decision_resource_id,
        evidence_resource_ids: vec![evidence_resource_id],
        candidate_resource_ids: vec![candidate_resource_id],
    }
}

async fn create_resource(
    host: &mut EngineHost,
    resource_id: &str,
    kind: &str,
    lifecycle: &str,
    payload: Value,
    idempotency_key: &str,
) {
    let result = host
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": resource_id,
                "kind": kind,
                "scope": "session",
                "sessionId": "session-a",
                "lifecycle": lifecycle,
                "payload": payload
            }),
            resource_write_causal(idempotency_key),
        ))
        .await;
    assert_eq!(
        result.error, None,
        "resource create failed for {resource_id}: {:?}",
        result.value
    );
}

async fn link_resources(
    host: &mut EngineHost,
    source: &str,
    target: &str,
    relation: &str,
    idempotency_key: &str,
) {
    let result = host
        .invoke(host_invocation(
            "resource::link",
            json!({
                "sourceResourceId": source,
                "targetResourceId": target,
                "relation": relation
            }),
            resource_write_causal(idempotency_key),
        ))
        .await;
    assert_eq!(
        result.error, None,
        "resource link failed for {source}->{target}: {:?}",
        result.value
    );
}

fn resource_write_causal(idempotency_key: &str) -> CausalContext {
    mutating_causal(idempotency_key).with_scope("resource.write")
}

fn candidate_payload(kind: &str, function_id: &str) -> Value {
    match kind {
        "artifact" => json!({
            "title": "Generated artifact",
            "body": "candidate body",
            "metadata": {"generated": true}
        }),
        "capability_definition" => json!({
            "functionId": function_id,
            "definition": {
                "functionId": function_id,
                "visibility": "session",
                "source": "generated"
            },
            "generatedBy": "sapg-test"
        }),
        "materialized_file" => json!({
            "canonicalPath": "/tmp/sapg-generated.md",
            "relativePath": "sapg-generated.md",
            "entryType": "file",
            "content": "generated",
            "contentHash": "sha256:test",
            "sizeBytes": 9,
            "metadata": {"generated": true}
        }),
        other => panic!("unsupported candidate kind {other}"),
    }
}

pub(super) fn governed_promote_payload(
    function_id: &str,
    target_visibility: &str,
    workspace_id: Option<&str>,
    idempotency_key: &str,
    refs: &PromotionGovernanceFixture,
) -> Value {
    let mut payload = json!({
        "functionId": function_id,
        "targetVisibility": target_visibility,
        "idempotencyKey": idempotency_key,
        "decisionResourceId": refs.decision_resource_id,
        "evidenceResourceIds": refs.evidence_resource_ids,
        "candidateResourceIds": refs.candidate_resource_ids,
        "promotionReason": "accepted governance record"
    });
    if let Some(workspace_id) = workspace_id {
        payload["workspaceId"] = json!(workspace_id);
    }
    payload
}
