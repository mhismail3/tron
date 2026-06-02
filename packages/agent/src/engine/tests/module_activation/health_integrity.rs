use super::*;

#[tokio::test]
async fn module_check_health_writes_evidence_and_updates_activation() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let (_package_version_id, activation_resource_id, activation_version_id) =
        activate_demo_package(
            &handle,
            "health-tools",
            "health_demo",
            "health-worker",
            "module-health",
        )
        .await;

    let checked = handle
        .invoke(host_invocation(
            "module::check_health",
            json!({
                "activationResourceId": activation_resource_id,
                "activationVersionId": activation_version_id,
                "expectedCurrentVersionId": activation_version_id,
                "mode": "on_demand"
            }),
            mutating_causal("module-health-check").with_scope("module.write"),
        ))
        .await;
    assert_eq!(checked.error, None);
    let value = checked.value.as_ref().unwrap();
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "activation_record")
    );
    assert_eq!(value["healthResult"]["status"], "healthy");
    assert_eq!(
        value["activation"]["payload"]["healthEvidenceRef"]["kind"],
        "evidence"
    );
    assert_eq!(
        value["activation"]["payload"]["healthInvocationIds"][0],
        checked.invocation_id.as_str()
    );

    let replayed = handle
        .invoke(host_invocation(
            "module::check_health",
            json!({
                "activationResourceId": "activation:workspace-a:health-tools",
                "activationVersionId": activation_version_id,
                "expectedCurrentVersionId": activation_version_id,
                "mode": "on_demand"
            }),
            mutating_causal("module-health-check").with_scope("module.write"),
        ))
        .await;
    assert!(replayed.replayed_from.is_some());
}

#[tokio::test]
async fn module_check_health_invoke_function_records_child_lineage() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    register_demo_worker(&handle, "invoke_health", "invoke-health-worker");
    handle
        .register_function_for_setup(
            read_function("invoke_health::health", "invoke-health-worker")
                .with_required_authority(AuthorityRequirement::scope("invoke_health.read")),
            Some(Arc::new(StaticValueHandler(json!({"ok": true})))),
            false,
        )
        .unwrap();
    let mut manifest = package_manifest(
        "invoke-health-tools",
        "invoke_health",
        "invoke-health-worker",
    );
    manifest["declaredCapabilities"]
        .as_array_mut()
        .unwrap()
        .push(json!({
            "functionId": "invoke_health::health",
            "effectClass": "PureRead",
            "risk": "low",
            "requiredAuthority": ["invoke_health.read"],
            "outputResourceKinds": []
        }));
    manifest["requiredGrants"]["allowedCapabilities"]
        .as_array_mut()
        .unwrap()
        .push(json!("invoke_health::health"));
    manifest["healthPolicy"] = json!({
        "mode": "invoke_function",
        "functionId": "invoke_health::health",
        "payload": {}
    });
    let registered = register_package(
        &handle,
        manifest_with_digest(manifest),
        "module-invoke-health-register",
    )
    .await;
    assert_eq!(registered.error, None);
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": "worker-package:invoke-health-tools",
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:invoke-health"}
            }),
            mutating_causal("module-invoke-health-configure").with_scope("module.write"),
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
                "packageResourceId": "worker-package:invoke-health-tools",
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:invoke-health-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "invoke-health-worker",
                "childGrantRequest": {
                    "allowedCapabilities": ["invoke_health::inspect", "invoke_health::write_artifact", "invoke_health::health"],
                    "allowedNamespaces": ["invoke_health"],
                    "allowedAuthorityScopes": ["invoke_health.read", "invoke_health.write"],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal("module-invoke-health-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    let activation_version_id = activated.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let checked = handle
        .invoke(host_invocation(
            "module::check_health",
            json!({
                "activationResourceId": "activation:workspace-a:invoke-health-tools",
                "activationVersionId": activation_version_id,
                "expectedCurrentVersionId": activation_version_id,
                "mode": "on_demand"
            }),
            mutating_causal("module-invoke-health-check").with_scope("module.write"),
        ))
        .await;
    assert_eq!(checked.error, None);
    let value = checked.value.as_ref().unwrap();
    let child_ids = value["healthResult"]["childInvocationIds"]
        .as_array()
        .expect("health result records child invocation ids");
    assert_eq!(child_ids.len(), 1);
    let child_id = child_ids[0].as_str().unwrap();
    assert!(
        value["activation"]["payload"]["healthInvocationIds"]
            .as_array()
            .unwrap()
            .iter()
            .any(|id| id == checked.invocation_id.as_str())
    );
    assert_eq!(
        value["activation"]["payload"]["healthInvocationIds"]
            .as_array()
            .unwrap()
            .iter()
            .any(|id| id == child_id),
        true
    );
    assert_eq!(value["healthResult"]["status"], "healthy");
    assert_eq!(
        value["healthResult"]["diagnostics"]["functionId"],
        "invoke_health::health"
    );
    let evidence_id = value["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "evidence")
        .unwrap()["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let evidence = inspect_resource(&handle, &evidence_id).await;
    let evidence_payload = &evidence["versions"].as_array().unwrap().last().unwrap()["payload"];
    assert_eq!(evidence_payload["metadata"]["status"], "healthy");
    assert_eq!(
        evidence_payload["metadata"]["childInvocationIds"][0],
        child_id
    );
    assert!(
        evidence["outgoingLinks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|link| link["relation"] == "evidence_for"
                && link["targetResourceId"] == "activation:workspace-a:invoke-health-tools")
    );
}

#[tokio::test]
async fn module_verify_integrity_records_evidence_and_rejects_stale_activation_version() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let (_package_version_id, activation_resource_id, activation_version_id) =
        activate_demo_package(
            &handle,
            "integrity-tools",
            "integrity_demo",
            "integrity-worker",
            "module-integrity",
        )
        .await;

    let verified = handle
        .invoke(host_invocation(
            "module::verify_integrity",
            json!({
                "targetType": "activation_record",
                "resourceId": activation_resource_id,
                "resourceVersionId": activation_version_id,
                "expectedCurrentVersionId": activation_version_id
            }),
            mutating_causal("module-integrity-verify").with_scope("module.write"),
        ))
        .await;
    assert_eq!(verified.error, None);
    let value = verified.value.as_ref().unwrap();
    assert_eq!(value["integrity"]["status"], "valid");
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
    let updated_activation_version = value["activation"]["version"]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let stale = handle
        .invoke(host_invocation(
            "module::verify_integrity",
            json!({
                "targetType": "activation_record",
                "resourceId": "activation:workspace-a:integrity-tools",
                "resourceVersionId": activation_version_id,
                "expectedCurrentVersionId": activation_version_id
            }),
            mutating_causal("module-integrity-stale").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("expectedCurrentVersionId")
    ));

    let reverified = handle
        .invoke(host_invocation(
            "module::verify_integrity",
            json!({
                "targetType": "activation_record",
                "resourceId": "activation:workspace-a:integrity-tools",
                "resourceVersionId": updated_activation_version,
                "expectedCurrentVersionId": updated_activation_version
            }),
            mutating_causal("module-integrity-reverify").with_scope("module.write"),
        ))
        .await;
    assert_eq!(reverified.error, None);
}

#[tokio::test]
async fn module_run_conformance_links_evidence_and_updates_package_policy() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("conformance-policy-worker.sh"),
        "module-conformance-policy-executable",
    )
    .await;
    let manifest = manifest_with_digest(local_process_manifest(
        "conformance-policy-tools",
        "conformance_policy",
        "conformance-policy-worker",
        executable,
    ));
    let registered =
        register_package(&handle, manifest, "module-conformance-policy-register").await;
    assert_eq!(registered.error, None);
    let package_resource_id = "worker-package:conformance-policy-tools";
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let verified = verify_source(
        &handle,
        package_resource_id,
        &package_version_id,
        "module-conformance-policy-verify",
    )
    .await;
    assert_eq!(verified.error, None);
    let verified_package_version_id = verified.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "worker_package")
        .unwrap()["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let conformance = handle
        .invoke(host_invocation(
            "module::run_conformance",
            json!({
                "targetType": "worker_package",
                "resourceId": package_resource_id,
                "resourceVersionId": verified_package_version_id,
                "expectedCurrentVersionId": verified_package_version_id,
                "mode": "activation",
                "childGrantRequest": {
                    "allowedCapabilities": [
                        "conformance_policy::inspect",
                        "conformance_policy::write_artifact"
                    ],
                    "allowedNamespaces": ["conformance_policy"],
                    "allowedAuthorityScopes": [
                        "conformance_policy.read",
                        "conformance_policy.write"
                    ],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal("module-conformance-policy-run").with_scope("module.write"),
        ))
        .await;
    assert_eq!(conformance.error, None);
    let value = conformance.value.as_ref().unwrap();
    assert_eq!(value["conformance"]["status"], "valid");
    assert_eq!(
        value["conformance"]["findings"].as_array().unwrap().len(),
        0
    );
    let evidence_ref = value["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "evidence")
        .unwrap()
        .clone();
    let package_ref = value["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "worker_package")
        .unwrap()
        .clone();
    assert_eq!(package_ref["role"], "conformance_checked");

    let evidence = inspect_resource(&handle, evidence_ref["resourceId"].as_str().unwrap()).await;
    let evidence_payload = &evidence["versions"].as_array().unwrap().last().unwrap()["payload"];
    assert_eq!(evidence_payload["metadata"]["targetType"], "worker_package");
    assert_eq!(evidence_payload["metadata"]["mode"], "activation");
    assert_eq!(evidence_payload["metadata"]["status"], "valid");
    assert_eq!(
        evidence_payload["metadata"]["findings"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert!(
        evidence["outgoingLinks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|link| link["relation"] == "evidence_for"
                && link["targetResourceId"] == package_resource_id)
    );

    let package = inspect_resource(&handle, package_resource_id).await;
    let package_payload = &package["versions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|version| version["versionId"] == package_ref["versionId"])
        .unwrap()["payload"];
    assert!(
        package_payload["conformanceEvidenceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["resourceId"] == evidence_ref["resourceId"])
    );
    assert_eq!(
        package_payload["policyDiagnostics"]["conformance"]["evidenceRef"]["resourceId"],
        evidence_ref["resourceId"]
    );
    assert_eq!(
        package_payload["policyDiagnostics"]["conformance"]["status"],
        "valid"
    );
}

#[tokio::test]
async fn module_recover_activation_revokes_unsafe_authority_and_preserves_evidence() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let (_package_version_id, activation_resource_id, activation_version_id) =
        activate_demo_package(
            &handle,
            "recover-tools",
            "recover_demo",
            "recover-worker",
            "module-recover",
        )
        .await;
    let disabled = handle
        .invoke(host_invocation(
            "module::disable",
            json!({
                "activationResourceId": activation_resource_id,
                "expectedCurrentVersionId": activation_version_id
            }),
            mutating_causal("module-recover-disable").with_scope("module.write"),
        ))
        .await;
    assert_eq!(disabled.error, None);
    let disabled_version = disabled.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let recovered = handle
        .invoke(host_invocation(
            "module::recover_activation",
            json!({
                "activationResourceId": "activation:workspace-a:recover-tools",
                "expectedCurrentVersionId": disabled_version,
                "reason": "test detected disabled activation"
            }),
            mutating_causal("module-recover-cleanup").with_scope("module.write"),
        ))
        .await;
    assert_eq!(recovered.error, None);
    let value = recovered.value.as_ref().unwrap();
    assert_eq!(
        value["activation"]["payload"]["activationStatus"],
        "quarantined"
    );
    assert_eq!(
        value["activation"]["payload"]["recovery"]["status"],
        "cleaned"
    );
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "activation_record")
    );
}

#[tokio::test]
async fn module_recover_activation_records_manual_recovery_when_spawned_worker_stop_fails() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let _spawn_calls = register_recording_worker_spawn(&handle);
    let stop_calls = register_recording_sandbox_stop_with_behavior(&handle, true);
    let activate_payload = local_process_activate_payload(
        &handle,
        "recovery-stop-failure-tools",
        "recovery-stop-worker",
        "module-recovery-stop-failure",
    )
    .await;
    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            activate_payload,
            mutating_causal("module-recovery-stop-failure-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    let activation_version_id = activated.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let derived_grant_id =
        activated.value.as_ref().unwrap()["activation"]["payload"]["derivedGrantId"]
            .as_str()
            .unwrap()
            .to_owned();
    let revoked = handle
        .invoke(host_invocation(
            "grant::revoke",
            json!({"grantId": derived_grant_id}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("trace"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("module-recovery-stop-failure-revoke"),
        ))
        .await;
    assert_eq!(revoked.error, None);

    let recovered = handle
        .invoke(host_invocation(
            "module::recover_activation",
            json!({
                "activationResourceId": "activation:workspace-a:recovery-stop-failure-tools",
                "expectedCurrentVersionId": activation_version_id,
                "reason": "test detected failed stop path"
            }),
            mutating_causal("module-recovery-stop-failure-recover").with_scope("module.write"),
        ))
        .await;
    assert_eq!(recovered.error, None);
    let recovery = &recovered.value.as_ref().unwrap()["recovery"];
    assert_eq!(recovery["status"], "manual_recovery_required");
    assert_eq!(recovery["cleanupStatus"], "manual_recovery_required");
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);
    assert!(
        worker_is_registered(&handle, "recovery-stop-worker").await,
        "failed stop should surface manual recovery rather than pretending the worker is gone"
    );
    let inspected = handle
        .invoke(host_invocation(
            "module::inspect_package",
            json!({"packageId": "recovery-stop-failure-tools"}),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    let diagnostics = &inspected.value.as_ref().unwrap()["diagnostics"];
    assert_eq!(diagnostics["cleanupStatus"], "manual_recovery_required");
    assert_eq!(diagnostics["recoveryStatus"], "manual_recovery_required");
    assert!(diagnostics["leakedWorkerRefs"].as_array().unwrap().len() == 1);
    assert!(
        diagnostics["recommendedCanonicalActions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|action| action["targetFunctionId"] == "module::recover_activation")
    );
}

#[tokio::test]
async fn module_health_monitor_enqueues_due_checks_without_health_tables() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut manifest = package_manifest("scheduled-tools", "scheduled_demo", "scheduled-worker");
    manifest["healthPolicy"] = json!({"mode": "catalog_registered", "intervalSeconds": 60});
    register_demo_worker(&handle, "scheduled_demo", "scheduled-worker");
    let registered = register_package(
        &handle,
        manifest_with_digest(manifest),
        "module-scheduled-register",
    )
    .await;
    assert_eq!(registered.error, None);
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": "worker-package:scheduled-tools",
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:scheduled"}
            }),
            mutating_causal("module-scheduled-configure").with_scope("module.write"),
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
                "packageResourceId": "worker-package:scheduled-tools",
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:scheduled-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "scheduled-worker",
                "childGrantRequest": {
                    "allowedCapabilities": ["scheduled_demo::inspect", "scheduled_demo::write_artifact"],
                    "allowedNamespaces": ["scheduled_demo"],
                    "allowedAuthorityScopes": ["scheduled_demo.read", "scheduled_demo.write"],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal("module-scheduled-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);

    let due_at = chrono::Utc::now() + chrono::Duration::seconds(120);
    let enqueued = handle
        .enqueue_due_module_health_checks(due_at)
        .await
        .unwrap();
    assert_eq!(enqueued, 1);
    let duplicate = handle
        .enqueue_due_module_health_checks(due_at)
        .await
        .unwrap();
    assert_eq!(duplicate, 0, "same health bucket should not queue twice");
    let drained = EngineQueueDrainer::drain_once(&handle, "module", "module-health-test")
        .await
        .unwrap()
        .expect("module health queue item should drain");
    assert_eq!(drained.error, None);
    assert_eq!(
        drained.value.as_ref().unwrap()["healthResult"]["status"],
        "healthy"
    );
}
