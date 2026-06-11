use super::*;
use crate::engine::EngineGrantLifecycle;

#[tokio::test]
async fn worker_activation_issues_scoped_resource_grant_token_and_replays_idempotently() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let refs = create_worker_activation_governance(
        &handle,
        WorkerActivationGovernanceConfig::session("valid", "activated_demo::echo"),
    )
    .await;

    let issued = issue_worker_activation(&handle, &refs, "saawa-issue-valid").await;
    assert_eq!(issued.error, None);
    let value = issued.value.as_ref().unwrap();
    let activation_resource_id = value["activationResourceId"].as_str().unwrap();
    let worker_id = value["workerId"].as_str().unwrap();
    assert_eq!(
        value["activationBundle"]["scopedWorkerToken"]["activationResourceId"],
        activation_resource_id
    );
    assert_eq!(
        value["activationBundle"]["workerHello"]["worker"]["id"],
        worker_id
    );
    assert_eq!(
        value["activationBundle"]["expectedFunctionDefinition"]["id"],
        "activated_demo::echo"
    );
    assert_eq!(
        value["activationBundle"]["expectedFunctionDefinition"]["metadata"]["runtimeRequirements"]
            ["registrationMode"],
        "volatile"
    );
    assert_eq!(
        value["activationBundle"]["expectedFunctionDefinition"]["metadata"]["runtimeRequirements"]
            ["networkPolicy"],
        "loopback"
    );

    let inspection = handle
        .inspect_resource(activation_resource_id)
        .await
        .unwrap()
        .expect("activation resource should be inspectable");
    assert_eq!(inspection.resource.kind, "worker_activation");
    assert_eq!(inspection.resource.lifecycle, "issued");
    let payload = activation_current_payload(&inspection);
    assert_eq!(payload["status"], "issued");
    assert_eq!(payload["functionId"], "activated_demo::echo");
    assert_eq!(payload["workerId"], worker_id);
    assert_eq!(payload["targetVisibility"], "session");
    assert_eq!(payload["registrationMode"], "volatile");
    assert_eq!(payload["networkPolicy"], "loopback");
    assert_eq!(payload["tokenStorage"]["redacted"], true);
    assert!(payload.get("scopedWorkerToken").is_none());
    assert!(payload.get("workerHello").is_none());
    assert!(payload["tokenFingerprint"].as_str().unwrap().len() >= 32);
    assert!(payload["governanceFingerprint"].as_str().unwrap().len() >= 32);
    let vault_metadata = handle
        .worker_activation_bundle_metadata_for_test(activation_resource_id)
        .await
        .unwrap()
        .expect("live activation bundle should be held in memory");
    assert_eq!(
        vault_metadata.activation_resource_id,
        activation_resource_id
    );
    assert_eq!(vault_metadata.worker_id.as_str(), worker_id);
    assert_eq!(vault_metadata.function_id.as_str(), "activated_demo::echo");
    assert_eq!(
        vault_metadata.token_fingerprint,
        payload["tokenFingerprint"].as_str().unwrap()
    );
    assert!(vault_metadata.bundle_byte_count > 0);

    let grant_id = grant(payload["grantId"].as_str().unwrap());
    let grant_record = handle
        .inspect_authority_grant(&grant_id)
        .await
        .unwrap()
        .expect("activation grant should exist");
    assert_eq!(grant_record.lifecycle, EngineGrantLifecycle::Active);
    assert_eq!(
        grant_record.parent_grant_id.as_ref().map(|id| id.as_str()),
        Some("worker-runtime")
    );
    assert_eq!(
        grant_record
            .subject_worker_id
            .as_ref()
            .map(|id| id.as_str()),
        Some(worker_id)
    );
    assert_eq!(
        grant_record
            .subject_actor_id
            .as_ref()
            .map(ToString::to_string),
        Some(format!("worker:{worker_id}"))
    );
    assert_eq!(
        grant_record.allowed_capabilities,
        vec!["activated_demo::echo", "stream::publish"]
    );
    assert_eq!(grant_record.allowed_namespaces, vec!["activated_demo"]);
    assert!(!grant_record.can_delegate);
    assert_eq!(grant_record.network_policy, "loopback");
    assert!(
        !grant_record
            .resource_selectors
            .iter()
            .any(|selector| selector == "*")
    );
    assert!(
        grant_record
            .expires_at
            .is_some_and(|expires_at| expires_at <= Utc::now() + ChronoDuration::hours(24))
    );

    let replay = issue_worker_activation(&handle, &refs, "saawa-issue-valid").await;
    assert_eq!(replay.error, None);
    let issued_invocation_id = issued.invocation_id.clone();
    assert_eq!(replay.replayed_from, Some(issued_invocation_id.clone()));
    assert_eq!(
        replay.value.as_ref().unwrap()["activationResourceId"],
        activation_resource_id
    );
    assert_eq!(
        replay.value.as_ref().unwrap()["activationBundle"]["redacted"],
        true
    );
    assert!(
        replay.value.as_ref().unwrap()["activationBundle"]["scopedWorkerToken"]
            .get("authorityGrantHash")
            .is_none(),
        "durable idempotency replay must not return token material"
    );
    let replay_snapshot = handle.replay_snapshot("session-a").await.unwrap();
    let durable_invocation = replay_snapshot
        .invocations
        .iter()
        .find(|record| record.invocation_id == issued_invocation_id)
        .expect("issue invocation should be durable");
    let durable_text = serde_json::to_string(&durable_invocation.result_value).unwrap();
    assert!(durable_text.contains("activation_bundle_not_persisted"));
    assert!(!durable_text.contains("scopedWorkerToken\":{\"pluginId"));
    let durable_idempotency = replay_snapshot
        .idempotency_entries
        .iter()
        .find(|entry| entry.first_invocation_id == issued_invocation_id)
        .expect("issue idempotency outcome should be durable");
    let durable_outcome_text = serde_json::to_string(&durable_idempotency.outcome).unwrap();
    assert!(durable_outcome_text.contains("activation_bundle_not_persisted"));
    assert!(!durable_outcome_text.contains("authorityGrantHash"));

    let workspace_refs = create_worker_activation_governance(
        &handle,
        WorkerActivationGovernanceConfig::workspace("valid-workspace", "activated_demo::workspace"),
    )
    .await;
    let workspace_issued =
        issue_worker_activation(&handle, &workspace_refs, "saawa-issue-workspace").await;
    assert_eq!(workspace_issued.error, None);
    let workspace_value = workspace_issued.value.as_ref().unwrap();
    assert_eq!(
        workspace_value["activationBundle"]["workerHello"]["defaultVisibility"],
        "workspace"
    );
    let workspace_inspection = handle
        .inspect_resource(workspace_value["activationResourceId"].as_str().unwrap())
        .await
        .unwrap()
        .expect("workspace activation resource should be inspectable");
    let workspace_payload = activation_current_payload(&workspace_inspection);
    assert_eq!(workspace_payload["targetVisibility"], "workspace");
    assert_eq!(workspace_payload["scope"]["workspaceId"], "workspace-a");
}

#[tokio::test]
async fn worker_activation_rejects_invalid_governance_chain_inputs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let valid = create_worker_activation_governance(
        &handle,
        WorkerActivationGovernanceConfig::session("invalid-base", "activated_invalid::echo"),
    )
    .await;

    let empty_evidence = handle
        .invoke(host_invocation(
            "worker::issue_activation",
            json!({
                "functionId": valid.function_id,
                "candidateResourceId": valid.candidate_resource_id,
                "decisionResourceId": valid.decision_resource_id,
                "evidenceResourceIds": [],
                "targetVisibility": "session",
                "activationReason": "empty evidence",
                "idempotencyKey": "saawa-empty-evidence"
            }),
            worker_activation_admin_causal("saawa-empty-evidence"),
        ))
        .await;
    assert!(matches!(
        empty_evidence.error,
        Some(EngineError::SchemaViolation { .. }) | Some(EngineError::PolicyViolation(_))
    ));

    let duplicate_refs = handle
        .invoke(host_invocation(
            "worker::issue_activation",
            json!({
                "functionId": valid.function_id,
                "candidateResourceId": valid.candidate_resource_id,
                "decisionResourceId": valid.decision_resource_id,
                "evidenceResourceIds": [
                    valid.evidence_resource_ids[0],
                    valid.evidence_resource_ids[0]
                ],
                "targetVisibility": "session",
                "activationReason": "duplicate evidence",
                "idempotencyKey": "saawa-duplicate-evidence"
            }),
            worker_activation_admin_causal("saawa-duplicate-evidence"),
        ))
        .await;
    assert!(matches!(
        duplicate_refs.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("duplicate")
    ));

    let mut wrong_kind =
        WorkerActivationGovernanceConfig::session("wrong-kind", "activated_invalid::wrong_kind");
    wrong_kind.candidate_kind = "artifact".to_owned();
    wrong_kind.candidate_lifecycle = "draft".to_owned();
    let wrong_kind = create_worker_activation_governance(&handle, wrong_kind).await;
    let wrong_kind_result = issue_worker_activation(&handle, &wrong_kind, "saawa-wrong-kind").await;
    assert!(matches!(
        wrong_kind_result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("must be capability_definition")
    ));

    let mut unverified =
        WorkerActivationGovernanceConfig::session("unverified", "activated_invalid::unverified");
    unverified.evidence_verified = false;
    let unverified = create_worker_activation_governance(&handle, unverified).await;
    let unverified_result = issue_worker_activation(&handle, &unverified, "saawa-unverified").await;
    assert!(matches!(
        unverified_result.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("must be verified")
    ));

    let mut non_final =
        WorkerActivationGovernanceConfig::session("non-final", "activated_invalid::non_final");
    non_final.decision_lifecycle = "draft".to_owned();
    let non_final = create_worker_activation_governance(&handle, non_final).await;
    let non_final_result = issue_worker_activation(&handle, &non_final, "saawa-non-final").await;
    assert!(matches!(
        non_final_result.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("must be final")
    ));

    let mut mismatched_function = WorkerActivationGovernanceConfig::session(
        "mismatch-function",
        "activated_invalid::expected",
    );
    mismatched_function.candidate_function_id = Some("activated_invalid::actual".to_owned());
    let mismatched_function =
        create_worker_activation_governance(&handle, mismatched_function).await;
    let mismatch_result =
        issue_worker_activation(&handle, &mismatched_function, "saawa-mismatch").await;
    assert!(matches!(
        mismatch_result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("definition id does not match")
    ));

    let system_target = handle
        .invoke(host_invocation(
            "worker::issue_activation",
            json!({
                "functionId": valid.function_id,
                "candidateResourceId": valid.candidate_resource_id,
                "decisionResourceId": valid.decision_resource_id,
                "evidenceResourceIds": valid.evidence_resource_ids,
                "targetVisibility": "system",
                "activationReason": "system target",
                "idempotencyKey": "saawa-system-target"
            }),
            worker_activation_admin_causal("saawa-system-target"),
        ))
        .await;
    assert!(matches!(
        system_target.error,
        Some(EngineError::SchemaViolation { .. })
    ));
}

fn activation_current_payload(
    inspection: &crate::engine::EngineResourceInspection,
) -> &serde_json::Value {
    let current = inspection.resource.current_version_id.as_ref().unwrap();
    &inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .unwrap()
        .payload
}
