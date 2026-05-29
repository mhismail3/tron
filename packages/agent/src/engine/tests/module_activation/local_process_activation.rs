//! Local-process module activation runtime tests.

use super::*;
#[tokio::test]
async fn module_activate_local_process_invokes_worker_spawn_and_records_integrity() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("demo-local-worker.sh"),
        "module-local-activate-executable",
    )
    .await;
    let manifest = manifest_with_digest(local_process_manifest(
        "demo-local-tools",
        "demo_local",
        "demo-local-worker",
        executable.clone(),
    ));
    let package_digest = manifest["packageDigest"].as_str().unwrap().to_owned();
    let registered = register_package(&handle, manifest, "module-local-activate-register").await;
    assert_eq!(registered.error, None);
    let registered_package_version_id =
        registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();
    let verified = verify_source(
        &handle,
        "worker-package:demo-local-tools",
        &registered_package_version_id,
        "module-local-activate-verify",
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
        &handle,
        "worker-package:demo-local-tools",
        &package_version_id,
        &package_digest,
        "demo-local-tools",
        "module-local-activate-approve",
    )
    .await;
    assert_eq!(approved.error, None);
    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": "worker-package:demo-local-tools",
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:demo-local-key"}
            }),
            mutating_causal("module-local-activate-config").with_scope("module.write"),
        ))
        .await;
    assert_eq!(configured.error, None);
    let config_version_id = configured.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let activate_payload = json!({
        "packageResourceId": "worker-package:demo-local-tools",
        "packageVersionId": package_version_id,
        "moduleConfigResourceId": "module-config:workspace-a:demo-local-tools",
        "configVersionId": config_version_id,
        "scope": "workspace",
        "workspaceId": "workspace-a",
        "childGrantRequest": {
            "allowedCapabilities": ["demo_local::inspect", "demo_local::write_artifact"],
            "allowedNamespaces": ["demo_local"],
            "allowedAuthorityScopes": ["demo_local.read", "demo_local.write"],
            "allowedResourceKinds": ["artifact"],
            "resourceSelectors": ["*"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium"
        }
    });
    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            activate_payload.clone(),
            mutating_causal("module-local-activate-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    let value = activated.value.as_ref().unwrap();
    assert_eq!(value["resourceRefs"][0]["kind"], "activation_record");
    assert_eq!(value["activation"]["payload"]["activationStatus"], "active");
    assert_eq!(
        value["activation"]["payload"]["derivedGrantId"],
        value["activation"]["payload"]["spawnResult"]["authorityGrantId"]
    );
    assert_eq!(
        value["activation"]["payload"]["spawnResult"]["workerId"],
        "demo-local-worker"
    );
    assert!(
        value["activation"]["payload"]["spawnInvocationId"]
            .as_str()
            .is_some_and(|id| !id.is_empty())
    );
    let calls = spawn_calls.lock().expect("spawn calls").clone();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0]["workerId"], "demo-local-worker");
    assert_eq!(
        calls[0]["expectedFunctionIds"],
        json!(["demo_local::inspect", "demo_local::write_artifact"])
    );
    let inspection = handle
        .invoke(host_invocation(
            "module::inspect_package",
            json!({"packageId": "demo-local-tools"}),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(inspection.error, None);
    let diagnostics = &inspection.value.as_ref().unwrap()["diagnostics"];
    assert_eq!(diagnostics["digestStatus"], "valid");
    assert_eq!(diagnostics["fileHashStatus"], "valid");
    assert_eq!(diagnostics["configStatus"], "configured");
    assert_eq!(diagnostics["activationStatus"], "active");
    assert_eq!(diagnostics["grantStatus"], "active");
    assert_eq!(diagnostics["workerStatus"], "registered");
    assert_eq!(diagnostics["registeredCapabilityStatus"], "valid");
    assert_eq!(diagnostics["healthStatus"], "healthy");
    assert!(
        inspection.value.as_ref().unwrap()["availableActions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|action| action["functionId"] == "module::verify_source"
                && action["consequence"]["recommendedCanonicalAction"] == "module::verify_source")
    );

    let replayed = handle
        .invoke(host_invocation(
            "module::activate",
            activate_payload,
            mutating_causal("module-local-activate-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(replayed.error, None);
    assert!(
        replayed.replayed_from.is_some(),
        "duplicate activation must replay rather than spawn again"
    );
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
}

#[tokio::test]
async fn module_queued_activation_retry_does_not_duplicate_runtime_state() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn_with_behavior(
        &handle,
        RecordingWorkerSpawnBehavior::FailOnceThenSuccess,
    );
    let activate_payload = local_process_activate_payload(
        &handle,
        "queued-retry-tools",
        "queued-retry-worker",
        "module-queued-retry",
    )
    .await;
    let grants_before = grant_count(&handle).await;
    let activations_before = resource_count(&handle, "activation_record").await;
    let evidence_before = resource_count(&handle, "evidence").await;

    let queued = handle
        .invoke(host_invocation(
            "queue::enqueue",
            json!({
                "queue": "module",
                "functionId": "module::activate",
                "payload": activate_payload
            }),
            mutating_causal("module-queued-retry-activate")
                .with_scope("queue.write")
                .with_scope("module.write"),
        ))
        .await;
    assert_eq!(queued.error, None);
    let receipt = queued.value.as_ref().unwrap()["item"]["receiptId"]
        .as_str()
        .unwrap()
        .to_owned();

    let first = EngineQueueDrainer::drain_receipt(&handle, &receipt, "module-queued-retry")
        .await
        .unwrap()
        .expect("queued activation should run once");
    assert!(matches!(
        first.error,
        Some(EngineError::HandlerFailed(message))
            if message.contains("recording worker spawn transient failure")
    ));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    assert_eq!(grant_count(&handle).await, grants_before);
    assert_eq!(
        resource_count(&handle, "activation_record").await,
        activations_before
    );
    assert!(
        resource_count(&handle, "evidence").await > evidence_before,
        "failed queued activation should leave bounded runtime diagnostic evidence"
    );

    tokio::time::sleep(std::time::Duration::from_millis(1_100)).await;
    let second = EngineQueueDrainer::drain_receipt(&handle, &receipt, "module-queued-retry")
        .await
        .unwrap()
        .expect("queued activation should retry");
    assert_eq!(second.error, None);
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 2);
    let retry_grant_id = second.value.as_ref().unwrap()["activation"]["payload"]["derivedGrantId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        grant_lifecycle(&handle, &retry_grant_id).await,
        Some("active".to_owned())
    );
    assert!(
        worker_is_registered(&handle, "queued-retry-worker").await,
        "successful retry should leave exactly one live spawned worker"
    );
    assert_eq!(
        resource_count(&handle, "activation_record").await,
        activations_before + 1
    );
    let activation = inspect_resource(&handle, "activation:workspace-a:queued-retry-tools").await;
    assert_eq!(
        activation["versions"].as_array().unwrap().len(),
        1,
        "retry success should not create duplicate activation versions"
    );
    let item = handle
        .invoke(host_invocation(
            "queue::get",
            json!({"receiptId": receipt}),
            causal().with_scope("queue.read"),
        ))
        .await;
    assert_eq!(item.error, None);
    assert_eq!(item.value.as_ref().unwrap()["item"]["status"], "completed");
    assert_eq!(item.value.as_ref().unwrap()["item"]["attempts"], 1);
}

#[tokio::test]
async fn module_activate_local_process_cleans_missing_registration_after_spawn() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn_with_behavior(
        &handle,
        RecordingWorkerSpawnBehavior::MissingRegistration,
    );
    let activate_payload = local_process_activate_payload(
        &handle,
        "missing-registration-tools",
        "missing-worker",
        "module-missing-registration",
    )
    .await;
    let evidence_before = resource_count(&handle, "evidence").await;
    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            activate_payload,
            mutating_causal("module-missing-registration-activate").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        activated.error,
        Some(EngineError::NotFound { .. })
    ));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    let grant_id = spawn_calls.lock().expect("spawn calls")[0]["grantId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        grant_lifecycle(&handle, &grant_id).await,
        Some("revoked".to_owned()),
        "a spawn grant must not stay active when worker registration is missing"
    );
    assert_eq!(resource_count(&handle, "activation_record").await, 0);
    assert!(
        resource_count(&handle, "evidence").await > evidence_before,
        "activation runtime diagnostics should record post-spawn cleanup"
    );
}

#[tokio::test]
async fn module_activate_local_process_spawn_error_does_not_create_runtime_state() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn_with_behavior(
        &handle,
        RecordingWorkerSpawnBehavior::SpawnError,
    );
    let grant_count_before = grant_count(&handle).await;
    let activation_count_before = resource_count(&handle, "activation_record").await;
    let activate_payload = local_process_activate_payload(
        &handle,
        "spawn-error-tools",
        "spawn-error-worker",
        "module-spawn-error",
    )
    .await;
    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            activate_payload,
            mutating_causal("module-spawn-error-activate").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        activated.error,
        Some(EngineError::HandlerFailed(message)) if message.contains("recording worker spawn failure")
    ));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    assert_eq!(grant_count(&handle).await, grant_count_before);
    assert_eq!(
        resource_count(&handle, "activation_record").await,
        activation_count_before
    );
    assert!(!worker_is_registered(&handle, "spawn-error-worker").await);
}

#[tokio::test]
async fn module_activate_local_process_cleans_overbroad_registration() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn_with_behavior(
        &handle,
        RecordingWorkerSpawnBehavior::OverbroadRegistration,
    );
    let stop_calls = register_recording_sandbox_stop(&handle);
    let activate_payload = local_process_activate_payload(
        &handle,
        "overbroad-registration-tools",
        "overbroad-worker",
        "module-overbroad-registration",
    )
    .await;
    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            activate_payload,
            mutating_causal("module-overbroad-registration-activate").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        activated.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("not declared by package")
    ));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);
    let grant_id = spawn_calls.lock().expect("spawn calls")[0]["grantId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        grant_lifecycle(&handle, &grant_id).await,
        Some("revoked".to_owned())
    );
    assert!(
        !worker_is_registered(&handle, "overbroad-worker").await,
        "failed spawned workers must be removed through the sandbox lifecycle"
    );
    assert_eq!(resource_count(&handle, "activation_record").await, 0);
}

#[tokio::test]
async fn module_activate_local_process_persistence_failure_cleans_spawned_worker() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let (_package_version_id, _activation_resource_id, _activation_version_id) =
        activate_demo_package(
            &handle,
            "persist-failure-tools",
            "persist_existing",
            "persist-existing-worker",
            "module-persist-failure-existing",
        )
        .await;
    let activation_count_before = resource_count(&handle, "activation_record").await;
    let spawn_calls = register_recording_worker_spawn(&handle);
    let stop_calls = register_recording_sandbox_stop(&handle);
    let mut activate_payload = local_process_activate_payload(
        &handle,
        "persist-failure-tools",
        "persist-failure-worker",
        "module-persist-failure",
    )
    .await;
    activate_payload["expectedCurrentVersionId"] = json!("stale-version");
    let evidence_before = resource_count(&handle, "evidence").await;
    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            activate_payload,
            mutating_causal("module-persist-failure-activate").with_scope("module.write"),
        ))
        .await;
    assert!(
        activated.error.is_some(),
        "activation unexpectedly succeeded: {:?}",
        activated.value
    );
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);
    let grant_id = spawn_calls.lock().expect("spawn calls")[0]["grantId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        grant_lifecycle(&handle, &grant_id).await,
        Some("revoked".to_owned())
    );
    assert!(!worker_is_registered(&handle, "persist-failure-worker").await);
    assert_eq!(
        resource_count(&handle, "activation_record").await,
        activation_count_before
    );
    assert!(
        resource_count(&handle, "evidence").await > evidence_before,
        "persistence cleanup failures should leave runtime diagnostic evidence"
    );
}
