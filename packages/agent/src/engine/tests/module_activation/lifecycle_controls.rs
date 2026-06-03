//! Module upgrade, rollback, disable, and quarantine control tests.

use super::*;

#[tokio::test]
async fn module_upgrade_and_rollback_require_current_version_before_spawn_and_replay() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let stop_calls = register_recording_sandbox_stop(&handle);
    let package_id = "rollback-local-tools";
    let activation_resource_id = format!("activation:workspace-a:{package_id}");

    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            local_process_activate_payload(
                &handle,
                package_id,
                "rollback-local-worker-v1",
                "module-rollback-local-v1",
            )
            .await,
            mutating_causal("module-rollback-local-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    let activated_value = activated.value.as_ref().unwrap();
    let original_version_id = activated_value["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let original_grant_id = activated_value["activation"]["payload"]["derivedGrantId"]
        .as_str()
        .unwrap()
        .to_owned();

    let (upgrade_package_version_id, upgrade_config_version_id) = register_local_process_version(
        &handle,
        package_id,
        "rollback-local-worker-v2",
        "module-rollback-local-v2",
    )
    .await;
    let mut upgrade_payload = json!({
        "activationResourceId": activation_resource_id,
        "packageResourceId": format!("worker-package:{package_id}"),
        "packageVersionId": upgrade_package_version_id,
        "moduleConfigResourceId": format!("module-config:workspace-a:{package_id}"),
        "configVersionId": upgrade_config_version_id,
        "scope": "workspace",
        "workspaceId": "workspace-a",
        "workerId": "rollback-local-worker-v2",
        "expectedCurrentVersionId": original_version_id,
        "childGrantRequest": grant_ceiling_for_namespace("demo_local"),
    });

    let mut missing_expected_upgrade = upgrade_payload.clone();
    missing_expected_upgrade
        .as_object_mut()
        .unwrap()
        .remove("expectedCurrentVersionId");
    let missing_upgrade = handle
        .invoke(host_invocation(
            "module::upgrade",
            missing_expected_upgrade,
            mutating_causal("module-upgrade-missing-expected").with_scope("module.write"),
        ))
        .await;
    assert!(error_contains(&missing_upgrade, "expectedCurrentVersionId"));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 0);

    upgrade_payload["expectedCurrentVersionId"] = json!("stale-version");
    let stale_upgrade = handle
        .invoke(host_invocation(
            "module::upgrade",
            upgrade_payload.clone(),
            mutating_causal("module-upgrade-stale-expected").with_scope("module.write"),
        ))
        .await;
    assert!(error_contains(&stale_upgrade, "expectedCurrentVersionId"));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 0);

    upgrade_payload["expectedCurrentVersionId"] = json!(original_version_id);
    let upgraded = handle
        .invoke(host_invocation(
            "module::upgrade",
            upgrade_payload.clone(),
            mutating_causal("module-upgrade-local-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(upgraded.error, None);
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 2);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);
    let upgraded_value = upgraded.value.as_ref().unwrap();
    let upgraded_version_id = upgraded_value["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let upgraded_grant_id = upgraded_value["activation"]["payload"]["derivedGrantId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(upgraded_value["replacedGrant"]["lifecycle"], "revoked");
    assert_eq!(
        upgraded_value["disconnectedWorker"]["status"],
        "stopped_spawned_worker"
    );
    assert_eq!(
        grant_lifecycle(&handle, &original_grant_id).await,
        Some("revoked".to_owned())
    );
    assert!(!worker_is_registered(&handle, "rollback-local-worker-v1").await);
    assert!(worker_is_registered(&handle, "rollback-local-worker-v2").await);

    let replayed_upgrade = handle
        .invoke(host_invocation(
            "module::upgrade",
            upgrade_payload,
            mutating_causal("module-upgrade-local-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(replayed_upgrade.error, None);
    assert!(replayed_upgrade.replayed_from.is_some());
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 2);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);

    let rollback_payload = json!({
        "activationResourceId": format!("activation:workspace-a:{package_id}"),
        "targetVersionId": original_version_id,
        "scope": "workspace",
        "workspaceId": "workspace-a",
        "expectedCurrentVersionId": upgraded_version_id,
        "childGrantRequest": grant_ceiling_for_namespace("demo_local"),
    });
    let mut missing_expected_rollback = rollback_payload.clone();
    missing_expected_rollback
        .as_object_mut()
        .unwrap()
        .remove("expectedCurrentVersionId");
    let missing_rollback = handle
        .invoke(host_invocation(
            "module::rollback",
            missing_expected_rollback,
            mutating_causal("module-rollback-missing-expected").with_scope("module.write"),
        ))
        .await;
    assert!(error_contains(
        &missing_rollback,
        "expectedCurrentVersionId"
    ));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 2);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);

    let mut stale_rollback_payload = rollback_payload.clone();
    stale_rollback_payload["expectedCurrentVersionId"] = json!("stale-version");
    let stale_rollback = handle
        .invoke(host_invocation(
            "module::rollback",
            stale_rollback_payload,
            mutating_causal("module-rollback-stale-expected").with_scope("module.write"),
        ))
        .await;
    assert!(error_contains(&stale_rollback, "expectedCurrentVersionId"));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 2);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);

    let rolled_back = handle
        .invoke(host_invocation(
            "module::rollback",
            rollback_payload.clone(),
            mutating_causal("module-rollback-local-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(rolled_back.error, None);
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 3);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 2);
    let rolled_back_value = rolled_back.value.as_ref().unwrap();
    assert_eq!(
        rolled_back_value["activation"]["payload"]["activationStatus"],
        "rolled_back"
    );
    assert_eq!(
        rolled_back_value["activation"]["payload"]["rollbackTarget"]["targetVersionId"],
        rollback_payload["targetVersionId"]
    );
    assert_eq!(
        rolled_back_value["activation"]["payload"]["supersedes"]["grantId"],
        upgraded_grant_id
    );
    assert_eq!(rolled_back_value["replacedGrant"]["lifecycle"], "revoked");
    assert_eq!(
        rolled_back_value["disconnectedWorker"]["status"],
        "stopped_spawned_worker"
    );
    assert_eq!(
        grant_lifecycle(&handle, &upgraded_grant_id).await,
        Some("revoked".to_owned())
    );
    assert!(worker_is_registered(&handle, "rollback-local-worker-v1").await);
    assert!(!worker_is_registered(&handle, "rollback-local-worker-v2").await);

    let replayed_rollback = handle
        .invoke(host_invocation(
            "module::rollback",
            rollback_payload,
            mutating_causal("module-rollback-local-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(replayed_rollback.error, None);
    assert!(replayed_rollback.replayed_from.is_some());
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 3);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 2);
}

#[tokio::test]
async fn module_quarantine_stale_activation_fails_before_stop_and_blocks_stale_grant() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let stop_calls = register_recording_sandbox_stop(&handle);
    let package_id = "quarantine-local-tools";
    let worker_id = "quarantine-local-worker";
    let activation_resource_id = format!("activation:workspace-a:{package_id}");

    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            local_process_activate_payload(
                &handle,
                package_id,
                worker_id,
                "module-quarantine-local",
            )
            .await,
            mutating_causal("module-quarantine-local-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    let activated_value = activated.value.as_ref().unwrap();
    let activation_version_id = activated_value["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let derived_grant_id = activated_value["activation"]["payload"]["derivedGrantId"]
        .as_str()
        .unwrap()
        .to_owned();
    let spawn_invocation_id = activated_value["activation"]["payload"]["spawnInvocationId"]
        .as_str()
        .unwrap()
        .to_owned();

    let active_call = handle
        .invoke(host_invocation(
            "demo_local::inspect",
            json!({}),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant(&derived_grant_id),
                trace("module-quarantine-active-call"),
            )
            .with_parent_invocation(InvocationId::new(spawn_invocation_id.clone()).unwrap())
            .with_scope("demo_local.read"),
        ))
        .await;
    assert_eq!(active_call.error, None);

    let stale_quarantine = handle
        .invoke(host_invocation(
            "module::quarantine",
            json!({
                "resourceId": activation_resource_id,
                "expectedCurrentVersionId": "stale-version",
                "evidenceResourceIds": []
            }),
            mutating_causal("module-quarantine-stale").with_scope("module.write"),
        ))
        .await;
    assert!(error_contains(
        &stale_quarantine,
        "expectedCurrentVersionId"
    ));
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 0);
    assert_eq!(
        grant_lifecycle(&handle, &derived_grant_id).await,
        Some("active".to_owned())
    );
    assert!(worker_is_registered(&handle, worker_id).await);

    let quarantined = handle
        .invoke(host_invocation(
            "module::quarantine",
            json!({
                "resourceId": format!("activation:workspace-a:{package_id}"),
                "expectedCurrentVersionId": activation_version_id,
                "evidenceResourceIds": []
            }),
            mutating_causal("module-quarantine-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(quarantined.error, None);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);
    let quarantined_value = quarantined.value.as_ref().unwrap();
    assert_eq!(
        quarantined_value["payload"]["activationStatus"],
        "quarantined"
    );
    assert_eq!(quarantined_value["revokedGrant"]["lifecycle"], "revoked");
    assert_eq!(
        quarantined_value["workerLifecycle"]["status"],
        "stopped_spawned_worker"
    );
    assert_eq!(
        grant_lifecycle(&handle, &derived_grant_id).await,
        Some("revoked".to_owned())
    );
    assert!(!worker_is_registered(&handle, worker_id).await);

    let stale_call = handle
        .invoke(host_invocation(
            "demo_local::inspect",
            json!({}),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant(&derived_grant_id),
                trace("module-quarantine-stale-call"),
            )
            .with_parent_invocation(InvocationId::new(spawn_invocation_id).unwrap())
            .with_scope("demo_local.read"),
        ))
        .await;
    assert!(stale_call.error.is_some());
    assert_eq!(stale_call.value, None);
}

#[tokio::test]
async fn module_remove_package_requires_disabled_activations_and_discards_configs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    register_demo_worker(&handle, "demo", "demo-worker");
    let registered = register_package(
        &handle,
        manifest_with_digest(package_manifest("removable-tools", "demo", "demo-worker")),
        "module-remove-register",
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
                "packageResourceId": "worker-package:removable-tools",
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true}
            }),
            mutating_causal("module-remove-configure").with_scope("module.write"),
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
                "packageResourceId": "worker-package:removable-tools",
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:removable-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "demo-worker",
                "childGrantRequest": grant_ceiling_for_namespace("demo")
            }),
            mutating_causal("module-remove-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);

    let blocked_remove = handle
        .invoke(host_invocation(
            "module::remove_package",
            json!({
                "packageResourceId": "worker-package:removable-tools",
                "expectedCurrentVersionId": package_version_id,
                "reason": "local pack cleanup"
            }),
            mutating_causal("module-remove-blocked").with_scope("module.write"),
        ))
        .await;
    assert!(
        error_contains(&blocked_remove, "active activation"),
        "remove must fail closed while activations are still live"
    );

    let disabled = handle
        .invoke(host_invocation(
            "module::disable",
            json!({
                "activationResourceId": "activation:workspace-a:removable-tools",
                "expectedCurrentVersionId": activated.value.as_ref().unwrap()["resourceRefs"][0]["versionId"].as_str().unwrap()
            }),
            mutating_causal("module-remove-disable").with_scope("module.write"),
        ))
        .await;
    assert_eq!(disabled.error, None);

    let removed = handle
        .invoke(host_invocation(
            "module::remove_package",
            json!({
                "packageResourceId": "worker-package:removable-tools",
                "expectedCurrentVersionId": package_version_id,
                "reason": "local pack cleanup"
            }),
            mutating_causal("module-remove-package").with_scope("module.write"),
        ))
        .await;
    assert_eq!(removed.error, None);
    let refs = removed.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap();
    assert!(refs.iter().any(|reference| {
        reference["resourceId"] == "worker-package:removable-tools"
            && reference["kind"] == "worker_package"
            && reference["role"] == "removed"
    }));
    assert!(refs.iter().any(|reference| {
        reference["resourceId"] == "module-config:workspace-a:removable-tools"
            && reference["kind"] == "module_config"
            && reference["role"] == "removed"
    }));

    let package = inspect_resource(&handle, "worker-package:removable-tools").await;
    assert_eq!(package["resource"]["lifecycle"], "discarded");
    let current_package_version = package["resource"]["currentVersionId"].as_str().unwrap();
    let package_payload = package["versions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|version| version["versionId"] == current_package_version)
        .unwrap()["payload"]
        .clone();
    assert_eq!(package_payload["packageStatus"], "removed");
    assert_eq!(package_payload["removalReason"], "local pack cleanup");

    let config = inspect_resource(&handle, "module-config:workspace-a:removable-tools").await;
    assert_eq!(config["resource"]["lifecycle"], "discarded");

    let snapshot = handle
        .invoke(host_invocation(
            "control::snapshot",
            json!({}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(snapshot.error, None);
    let source_trust = snapshot.value.as_ref().unwrap()["moduleSourceTrust"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["packageResourceId"] == "worker-package:removable-tools")
        .expect("removed package source trust projection");
    assert_eq!(source_trust["trustPresentation"]["statusLabel"], "Removed");
    assert_eq!(
        source_trust["trustPresentation"]["cleanupLabel"],
        "Removed locally"
    );

    let configure_removed = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": "worker-package:removable-tools",
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true}
            }),
            mutating_causal("module-remove-configure-discarded").with_scope("module.write"),
        ))
        .await;
    assert!(
        error_contains(&configure_removed, "removed"),
        "removed packs must be read-only until explicitly re-registered"
    );

    let activate_removed = handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": "worker-package:removable-tools",
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:removable-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "demo-worker",
                "childGrantRequest": grant_ceiling_for_namespace("demo")
            }),
            mutating_causal("module-remove-activate-discarded").with_scope("module.write"),
        ))
        .await;
    assert!(
        error_contains(&activate_removed, "removed"),
        "removed packs must not be activatable until explicitly re-registered"
    );
}

#[tokio::test]
async fn module_local_process_replacement_spawn_failure_marks_activation_failed_closed() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let _initial_spawn_calls = register_recording_worker_spawn(&handle);
    let stop_calls = register_recording_sandbox_stop(&handle);
    let package_id = "replacement-failure-tools";
    let activation_resource_id = format!("activation:workspace-a:{package_id}");

    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            local_process_activate_payload(
                &handle,
                package_id,
                "replacement-failure-worker-v1",
                "module-replacement-failure-v1",
            )
            .await,
            mutating_causal("module-replacement-failure-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    let activated_value = activated.value.as_ref().unwrap();
    let original_version_id = activated_value["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let original_grant_id = activated_value["activation"]["payload"]["derivedGrantId"]
        .as_str()
        .unwrap()
        .to_owned();

    let failing_spawn_calls = register_recording_worker_spawn_with_behavior(
        &handle,
        RecordingWorkerSpawnBehavior::SpawnError,
    );
    let (upgrade_package_version_id, upgrade_config_version_id) = register_local_process_version(
        &handle,
        package_id,
        "replacement-failure-worker-v2",
        "module-replacement-failure-v2",
    )
    .await;

    let failed_upgrade = handle
        .invoke(host_invocation(
            "module::upgrade",
            json!({
                "activationResourceId": activation_resource_id,
                "packageResourceId": format!("worker-package:{package_id}"),
                "packageVersionId": upgrade_package_version_id,
                "moduleConfigResourceId": format!("module-config:workspace-a:{package_id}"),
                "configVersionId": upgrade_config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "replacement-failure-worker-v2",
                "expectedCurrentVersionId": original_version_id,
                "childGrantRequest": grant_ceiling_for_namespace("demo_local"),
            }),
            mutating_causal("module-replacement-failure-upgrade").with_scope("module.write"),
        ))
        .await;
    assert!(error_contains(
        &failed_upgrade,
        "recording worker spawn failure"
    ));
    assert_eq!(failing_spawn_calls.lock().expect("spawn calls").len(), 1);
    let stop_calls = stop_calls.lock().expect("stop calls").clone();
    assert!(
        stop_calls
            .iter()
            .any(|call| call["workerId"] == "replacement-failure-worker-v1")
    );
    assert_eq!(
        grant_lifecycle(&handle, &original_grant_id).await,
        Some("revoked".to_owned())
    );
    assert!(!worker_is_registered(&handle, "replacement-failure-worker-v1").await);
    assert!(!worker_is_registered(&handle, "replacement-failure-worker-v2").await);

    let activation =
        inspect_resource(&handle, &format!("activation:workspace-a:{package_id}")).await;
    assert_eq!(activation["resource"]["lifecycle"], "failed");
    let payload = &activation["versions"].as_array().unwrap().last().unwrap()["payload"];
    assert_eq!(payload["activationStatus"], "failed");
    assert_eq!(payload["compensationState"]["status"], "failed_closed");
    assert_eq!(
        payload["runtimeDiagnostics"]["recoveryStatus"],
        "failed_closed"
    );
    assert!(
        payload["runtimeDiagnostics"]["latestRecoveryEvidenceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
}

async fn register_local_process_version(
    handle: &EngineHostHandle,
    package_id: &str,
    worker_id: &str,
    key_prefix: &str,
) -> (String, String) {
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        handle,
        &tmp.path().join(format!("{worker_id}.sh")),
        &format!("{key_prefix}-executable"),
    )
    .await;
    let mut manifest = local_process_manifest(package_id, "demo_local", worker_id, executable);
    manifest["version"] = json!("2.0.0");
    let manifest = manifest_with_digest(manifest);
    let package_digest = manifest["packageDigest"].as_str().unwrap().to_owned();
    let registered = register_package(handle, manifest, &format!("{key_prefix}-register")).await;
    assert_eq!(registered.error, None);
    let registered_package_version_id =
        registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();
    let verified = verify_source(
        handle,
        &format!("worker-package:{package_id}"),
        &registered_package_version_id,
        &format!("{key_prefix}-verify"),
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
    let approved = approve_source(
        handle,
        &format!("worker-package:{package_id}"),
        &package_version_id,
        &package_digest,
        package_id,
        &format!("{key_prefix}-approve"),
    )
    .await;
    assert_eq!(approved.error, None);
    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": format!("worker-package:{package_id}"),
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": format!("secret_ref:{key_prefix}")}
            }),
            mutating_causal(&format!("{key_prefix}-configure")).with_scope("module.write"),
        ))
        .await;
    assert_eq!(configured.error, None);
    let config_version_id = configured.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    (package_version_id, config_version_id)
}

fn error_contains(result: &crate::engine::InvocationResult, needle: &str) -> bool {
    result
        .error
        .as_ref()
        .is_some_and(|error| error.to_string().contains(needle))
}
