use super::*;

#[tokio::test]
async fn module_simulate_trust_change_is_side_effect_free() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("simulate-trust-worker.sh"),
        "module-simulate-trust-executable",
    )
    .await;
    let (signing_key, public_key, key_id) = signing_fixture();
    let manifest = signed_package_manifest(
        local_process_manifest(
            "simulate-trust-tools",
            "demo_local",
            "simulate-trust-worker",
            executable,
        ),
        &signing_key,
        &key_id,
    );
    let package_resource_id = "worker-package:simulate-trust-tools";
    let registered = register_package(&handle, manifest, "module-simulate-trust-register").await;
    assert_eq!(registered.error, None);
    let registered_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let trust_root = register_trust_root(
        &handle,
        &public_key,
        &key_id,
        "simulate-trust-tools",
        "demo_local",
        "module-simulate-trust-root",
    )
    .await;
    assert_eq!(trust_root.error, None);
    let trust_root_decision_id =
        trust_root.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
            .as_str()
            .unwrap()
            .to_owned();
    let trust_root_version_id = trust_root.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let verified = verify_signature(
        &handle,
        package_resource_id,
        &registered_version_id,
        "module-simulate-trust-verify",
    )
    .await;
    assert_eq!(verified.error, None);
    let package_version_id = verified.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "worker_package")
        .unwrap()["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:simulate-trust"}
            }),
            mutating_causal("module-simulate-trust-configure").with_scope("module.write"),
        ))
        .await;
    assert_eq!(configured.error, None);
    let config_version_id = configured.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:simulate-trust-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            mutating_causal("module-simulate-trust-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    let activation_resource_id = activated.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);

    let evidence_before = resource_count(&handle, "evidence").await;
    let decision_before = resource_count(&handle, "decision").await;
    let activation_before = resource_count(&handle, "activation_record").await;
    let grants_before = grant_count(&handle).await;
    let queue_before = queue_count(&handle, "module").await;

    for operation in [
        "expire",
        "renew",
        "rotate",
        "revoke",
        "enforce_disable",
        "enforce_quarantine",
        "approve_source",
        "reconcile",
    ] {
        let (target_type, target_id) = if matches!(operation, "approve_source" | "reconcile") {
            ("package", package_resource_id)
        } else {
            ("trust_root", trust_root_decision_id.as_str())
        };
        let simulated = handle
            .invoke(host_invocation(
                "module::simulate_trust_change",
                json!({
                    "targetType": target_type,
                    "targetResourceId": target_id,
                    "targetVersionId": trust_root_version_id,
                    "operation": operation,
                    "activationResourceIds": [activation_resource_id],
                    "includeGeneratedUi": true,
                    "limit": 50
                }),
                causal().with_scope("module.read"),
            ))
            .await;
        assert_eq!(simulated.error, None, "operation {operation}");
        let value = simulated.value.as_ref().unwrap();
        assert_eq!(value["operation"], operation);
        assert!(
            ["allow", "deny", "blocked", "noop"].contains(
                &value["decision"]
                    .as_str()
                    .expect("simulation returns decision")
            ),
            "simulation decision must be bounded"
        );
        assert!(
            value["affectedPackages"]
                .as_array()
                .unwrap()
                .iter()
                .any(|package| package["packageResourceId"] == package_resource_id)
        );
    }

    let broader = handle
        .invoke(host_invocation(
            "module::simulate_trust_change",
            json!({
                "targetType": "trust_root",
                "targetResourceId": trust_root_decision_id,
                "targetVersionId": trust_root_version_id,
                "operation": "renew",
                "proposedBounds": {
                    "allowedPackageSelectors": ["simulate-trust-tools", "other-tools"],
                    "grantCeiling": {
                        "allowedCapabilities": ["demo_local::inspect", "demo_local::write_artifact"],
                        "allowedNamespaces": ["demo_local"],
                        "allowedAuthorityScopes": ["demo_local.read", "demo_local.write"],
                        "allowedResourceKinds": ["artifact"],
                        "resourceSelectors": ["*"],
                        "fileRoots": ["*"],
                        "networkPolicy": "none",
                        "maxRisk": "medium",
                        "canDelegate": false,
                        "approvalRequired": false
                    },
                    "trustTierCeiling": "signed_local",
                    "expiresAt": "2100-06-01T00:00:00Z"
                }
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(broader.error, None);
    assert_eq!(broader.value.as_ref().unwrap()["decision"], "blocked");
    assert!(
        broader.value.as_ref().unwrap()["warnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|warning| warning["code"] == "proposed_bounds_exceed_current")
    );

    assert_eq!(resource_count(&handle, "evidence").await, evidence_before);
    assert_eq!(resource_count(&handle, "decision").await, decision_before);
    assert_eq!(
        resource_count(&handle, "activation_record").await,
        activation_before
    );
    assert_eq!(grant_count(&handle).await, grants_before);
    assert_eq!(queue_count(&handle, "module").await, queue_before);
    assert_eq!(
        spawn_calls.lock().expect("spawn calls").len(),
        1,
        "simulation must not spawn workers"
    );
}

#[tokio::test]
async fn module_record_trust_review_writes_bounded_evidence_only() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    register_demo_worker(&handle, "review_demo", "review-worker");
    let registered = register_package(
        &handle,
        manifest_with_digest(package_manifest(
            "review-tools",
            "review_demo",
            "review-worker",
        )),
        "module-review-register",
    )
    .await;
    assert_eq!(registered.error, None);
    let package_resource_id = "worker-package:review-tools";
    let evidence_before = resource_count(&handle, "evidence").await;
    let decision_before = resource_count(&handle, "decision").await;

    let review = handle
        .invoke(host_invocation(
            "module::record_trust_review",
            json!({
                "targetType": "package",
                "targetResourceId": package_resource_id,
                "operation": "reconcile",
                "operatorNotes": "bounded operator review",
                "limit": 25
            }),
            mutating_causal("module-record-trust-review").with_scope("module.write"),
        ))
        .await;
    assert_eq!(review.error, None);
    let value = review.value.as_ref().unwrap();
    assert_eq!(value["review"]["operation"], "reconcile");
    assert_eq!(value["evidence"]["kind"], "evidence");
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
    let evidence_id = value["resourceRefs"][0]["resourceId"].as_str().unwrap();
    let evidence = inspect_resource(&handle, evidence_id).await;
    assert!(
        evidence["outgoingLinks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|link| link["relation"] == "affects_package"
                && link["targetResourceId"] == package_resource_id)
    );
    assert_eq!(
        resource_count(&handle, "evidence").await,
        evidence_before + 1
    );
    assert_eq!(resource_count(&handle, "decision").await, decision_before);

    let replayed = handle
        .invoke(host_invocation(
            "module::record_trust_review",
            json!({
                "targetType": "package",
                "targetResourceId": package_resource_id,
                "operation": "reconcile",
                "operatorNotes": "bounded operator review",
                "limit": 25
            }),
            mutating_causal("module-record-trust-review").with_scope("module.write"),
        ))
        .await;
    assert!(replayed.replayed_from.is_some());

    let unicode_review = handle
        .invoke(host_invocation(
            "module::record_trust_review",
            json!({
                "targetType": "package",
                "targetResourceId": package_resource_id,
                "operation": "reconcile",
                "operatorNotes": "€".repeat(900),
                "limit": 25
            }),
            mutating_causal("module-record-trust-review-unicode").with_scope("module.write"),
        ))
        .await;
    assert_eq!(unicode_review.error, None);
    let unicode_evidence_id =
        unicode_review.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
            .as_str()
            .unwrap();
    let unicode_evidence = inspect_resource(&handle, unicode_evidence_id).await;
    let stored_notes = unicode_evidence["versions"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()["payload"]["metadata"]["operatorNotes"]
        .as_str()
        .unwrap();
    assert!(stored_notes.len() <= 2048);

    let fabricated = handle
        .invoke(host_invocation(
            "module::record_trust_review",
            json!({
                "targetType": "package",
                "targetResourceId": package_resource_id,
                "operation": "reconcile",
                "simulation": {"decision": "allow"}
            }),
            mutating_causal("module-record-trust-review-fabricated").with_scope("module.write"),
        ))
        .await;
    assert!(fabricated.error.is_some());
}

#[tokio::test]
async fn module_trust_audit_schedules_are_decision_backed_and_queued() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    register_demo_worker(&handle, "audit_demo", "audit-worker");
    let registered = register_package(
        &handle,
        manifest_with_digest(package_manifest(
            "audit-tools",
            "audit_demo",
            "audit-worker",
        )),
        "module-trust-audit-register",
    )
    .await;
    assert_eq!(registered.error, None);

    let schedule_payload = json!({
        "scheduleId": "daily-audit",
        "scope": "workspace",
        "workspaceId": "workspace-a",
        "selectors": ["audit-tools"],
        "cadence": "daily",
        "timezone": "UTC",
        "wallClockTime": "00:00",
        "expiresAt": "2100-01-01T00:00:00Z",
        "grantCeiling": grant_ceiling_for_namespace("audit_demo"),
        "reason": "test schedules module trust audit"
    });
    let scheduled = handle
        .invoke(host_invocation(
            "module::schedule_trust_audit",
            schedule_payload.clone(),
            mutating_causal("module-trust-audit-schedule").with_scope("module.write"),
        ))
        .await;
    assert_eq!(scheduled.error, None);
    let schedule_ref = scheduled.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "decision")
        .unwrap()
        .clone();
    let schedule_resource_id = schedule_ref["resourceId"].as_str().unwrap().to_owned();
    let schedule_version_id = schedule_ref["versionId"].as_str().unwrap().to_owned();
    let schedule_inspection = inspect_resource(&handle, &schedule_resource_id).await;
    assert_eq!(
        schedule_inspection["versions"]
            .as_array()
            .unwrap()
            .last()
            .unwrap()["payload"]["metadata"]["decisionType"],
        "module_trust_audit_schedule"
    );

    let replayed = handle
        .invoke(host_invocation(
            "module::schedule_trust_audit",
            schedule_payload.clone(),
            mutating_causal("module-trust-audit-schedule").with_scope("module.write"),
        ))
        .await;
    assert!(replayed.replayed_from.is_some());

    let duplicate_without_cas = handle
        .invoke(host_invocation(
            "module::schedule_trust_audit",
            schedule_payload.clone(),
            mutating_causal("module-trust-audit-duplicate-no-cas").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        duplicate_without_cas.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("expectedCurrentVersionId")
    ));

    let mut update_payload = schedule_payload.clone();
    update_payload["expectedCurrentVersionId"] = json!(schedule_version_id);
    update_payload["wallClockTime"] = json!("01:00");
    let updated = handle
        .invoke(host_invocation(
            "module::schedule_trust_audit",
            update_payload,
            mutating_causal("module-trust-audit-update").with_scope("module.write"),
        ))
        .await;
    assert_eq!(updated.error, None);
    let updated_schedule_version_id = updated.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "decision")
        .unwrap()["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let due_at = chrono::DateTime::parse_from_rfc3339("2026-05-19T01:30:00Z")
        .unwrap()
        .with_timezone(&chrono::Utc);
    let enqueued = handle
        .enqueue_due_module_trust_audits(due_at)
        .await
        .unwrap();
    assert_eq!(enqueued, 1);
    let duplicate = handle
        .enqueue_due_module_trust_audits(due_at)
        .await
        .unwrap();
    assert_eq!(
        duplicate, 0,
        "same trust audit bucket should not queue twice"
    );
    let drained = EngineQueueDrainer::drain_once(&handle, "module", "module-trust-audit-test")
        .await
        .unwrap()
        .expect("module trust audit queue item should drain");
    assert_eq!(drained.error, None);
    let value = drained.value.as_ref().unwrap();
    assert_eq!(value["schedule"]["resourceId"], schedule_resource_id);
    assert_eq!(value["schedule"]["versionId"], updated_schedule_version_id);
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );

    let expired_run = handle
        .invoke(host_invocation(
            "module::run_scheduled_trust_audit",
            json!({
                "scheduleDecisionResourceId": schedule_resource_id,
                "scheduleDecisionVersionId": "stale-version",
                "dueBucket": "2026-05-19T01:00:00Z"
            }),
            mutating_causal("module-trust-audit-stale-run").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        expired_run.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not current")
    ));
}
