//! Package registration and capability/resource declaration tests.

use super::*;
#[tokio::test]
async fn module_resource_types_and_capabilities_are_registered() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let snapshot = handle
        .invoke(host_invocation(
            "control::snapshot",
            json!({"limit": 100}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(snapshot.error, None);
    let value = snapshot.value.as_ref().unwrap();
    for kind in ["worker_package", "module_config", "activation_record"] {
        assert!(
            value["resourceTypes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|resource_type| resource_type["kind"] == kind),
            "resource kind {kind} must be registered"
        );
    }
    for (kind, relation) in [
        ("decision", "trusts_source"),
        ("decision", "verifies_signature"),
        ("decision", "affects_package"),
        ("decision", "affects_activation"),
        ("decision", "revokes"),
        ("decision", "supersedes"),
        ("decision", "renewed_by"),
        ("decision", "rotates_from"),
        ("decision", "rotates_to"),
        ("decision", "enforces_revocation"),
        ("decision", "evidence_for"),
        ("evidence", "affects_package"),
        ("evidence", "affects_activation"),
        ("evidence", "enforces_revocation"),
    ] {
        let resource_type = value["resourceTypes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|resource_type| resource_type["kind"] == kind)
            .unwrap_or_else(|| panic!("resource kind {kind} must be registered"));
        assert!(
            resource_type["allowedLinkRelations"]
                .as_array()
                .unwrap()
                .iter()
                .any(|candidate| candidate == relation),
            "{kind} must allow relation {relation}"
        );
    }
    for function_id in [
        "module::register_package",
        "module::inspect_package",
        "module::configure",
        "module::activate",
        "module::disable",
        "module::upgrade",
        "module::rollback",
        "module::quarantine",
        "module::remove_package",
        "module::check_health",
        "module::verify_integrity",
        "module::recover_activation",
        "module::verify_source",
        "module::approve_source",
        "module::revoke_source_approval",
        "module::policy_decide",
        "module::run_conformance",
        "module::register_source",
        "module::verify_signature",
        "module::audit_policy",
        "module::record_policy_audit",
        "module::reconcile_trust",
        "module::inspect_trust",
        "module::renew_trust_root",
        "module::rotate_signature_key",
        "module::expire_trust_decision",
        "module::enforce_revocation",
        "module::simulate_trust_change",
        "module::record_trust_review",
        "module::trust_audit_status",
        "module::schedule_trust_audit",
        "module::run_scheduled_trust_audit",
        "module::record_trust_audit_retention",
    ] {
        let function = value["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .find(|capability| capability["id"] == function_id)
            .unwrap_or_else(|| panic!("{function_id} must be discoverable"));
        if !matches!(
            function_id,
            "module::inspect_package"
                | "module::policy_decide"
                | "module::audit_policy"
                | "module::inspect_trust"
                | "module::simulate_trust_change"
                | "module::trust_audit_status"
        ) {
            assert!(
                function["idempotency"].is_object(),
                "{function_id} must be idempotent"
            );
            let output_contract = function
                .get("outputContract")
                .or_else(|| function.get("output_contract"))
                .unwrap_or(&Value::Null);
            let output_kind = output_contract.to_string();
            assert!(
                output_kind.contains("ResourceBacked")
                    || output_kind.contains("resourceBacked")
                    || output_kind.contains("resource_backed"),
                "{function_id} must be resource-backed, got {output_kind}"
            );
        }
    }
}

#[tokio::test]
async fn module_register_package_validates_digest_namespace_and_contracts() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    register_demo_worker(&handle, "demo", "demo-worker");

    let good = register_package(
        &handle,
        manifest_with_digest(package_manifest("demo-tools", "demo", "demo-worker")),
        "module-register-good",
    )
    .await;
    assert_eq!(good.error, None);
    assert_eq!(
        good.value.as_ref().unwrap()["resourceRefs"][0]["kind"],
        "worker_package"
    );
    assert_eq!(
        good.value.as_ref().unwrap()["resource"]["resourceId"],
        "worker-package:demo-tools"
    );

    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("demo-local-resource-worker.sh"),
        "module-register-local-executable",
    )
    .await;
    let local_manifest = manifest_with_digest(local_process_manifest(
        "demo-local-resource-backed",
        "demo_local_resource",
        "demo-local-resource-worker",
        executable.clone(),
    ));
    let local_digest = local_manifest["packageDigest"].as_str().unwrap().to_owned();
    let registered_local = register_package(
        &handle,
        local_manifest,
        "module-register-local-resource-backed",
    )
    .await;
    assert_eq!(registered_local.error, None);
    let local_ref = &registered_local.value.as_ref().unwrap()["resourceRefs"][0];
    assert_eq!(local_ref["kind"], "worker_package");
    assert_eq!(
        local_ref["resourceId"],
        "worker-package:demo-local-resource-backed"
    );
    let inspected = inspect_resource(&handle, "worker-package:demo-local-resource-backed").await;
    assert_eq!(inspected["resource"]["kind"], "worker_package");
    assert_eq!(inspected["resource"]["ownerWorkerId"], "module");
    assert_eq!(inspected["resource"]["lifecycle"], "available");
    assert_eq!(
        inspected["resource"]["currentVersionId"], local_ref["versionId"],
        "registration must persist the current worker_package version"
    );
    let payload = current_version_payload(&inspected);
    assert_eq!(payload["packageId"], "demo-local-resource-backed");
    assert_eq!(payload["packageDigest"], local_digest);
    assert_eq!(payload["sourceDigest"], local_digest);
    assert_eq!(payload["sourceProvenance"]["kind"], "local_digest_pinned");
    assert_eq!(
        payload["sourceRef"]["provenance"]["kind"],
        "local_digest_pinned"
    );
    assert_eq!(payload["sourceTrustStatus"], "unverified");
    assert_eq!(payload["effectiveTrustTier"], "untrusted");
    assert_eq!(payload["signatureVerification"]["status"], "not_verified");
    assert_eq!(payload["sourceEvidenceRefs"].as_array().unwrap().len(), 0);
    assert_eq!(payload["sourceApprovalRefs"].as_array().unwrap().len(), 0);
    assert_eq!(
        payload["conformanceEvidenceRefs"].as_array().unwrap().len(),
        0
    );
    assert_eq!(
        payload["declaredCapabilities"]
            .as_array()
            .unwrap()
            .iter()
            .map(|capability| capability["functionId"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec![
            "demo_local_resource::inspect",
            "demo_local_resource::write_artifact"
        ]
    );
    assert_eq!(
        payload["requiredGrants"]["allowedCapabilities"]
            .as_array()
            .unwrap()
            .iter()
            .map(|function_id| function_id.as_str().unwrap())
            .collect::<Vec<_>>(),
        vec![
            "demo_local_resource::inspect",
            "demo_local_resource::write_artifact"
        ]
    );
    assert_eq!(payload["runtimeEntryPoint"]["kind"], "local_process");
    assert_eq!(
        payload["runtimeEntryPoint"]["workerId"],
        "demo-local-resource-worker"
    );
    assert_eq!(
        payload["runtimeEntryPoint"]["expectedFunctionIds"]
            .as_array()
            .unwrap()
            .iter()
            .map(|function_id| function_id.as_str().unwrap())
            .collect::<Vec<_>>(),
        vec![
            "demo_local_resource::inspect",
            "demo_local_resource::write_artifact"
        ]
    );
    assert_eq!(
        payload["runtimeEntryPoint"]["commandTemplate"]["resourceId"],
        executable["resourceId"]
    );
    assert_eq!(
        payload["runtimeEntryPoint"]["commandTemplate"]["versionId"],
        executable["versionId"]
    );
    assert_eq!(
        payload["runtimeEntryPoint"]["executableRefs"][0]["resourceId"],
        executable["resourceId"]
    );
    assert_eq!(
        payload["runtimeEntryPoint"]["executableRefs"][0]["versionId"],
        executable["versionId"]
    );
    assert_eq!(
        payload["runtimeEntryPoint"]["environmentPolicy"]["mode"],
        "empty"
    );
    let stored_manifest = serde_json::to_string(payload).unwrap();
    assert!(
        !stored_manifest.contains("sk-") && !stored_manifest.contains("secret="),
        "worker_package payload must not persist raw secret-like material"
    );

    let mut raw_secret_runtime = manifest_with_digest(local_process_manifest(
        "raw-secret-runtime",
        "raw_secret_runtime",
        "raw-secret-runtime-worker",
        executable,
    ));
    raw_secret_runtime["runtimeEntryPoint"]["environmentPolicy"] = json!({
        "mode": "empty",
        "apiKey": "sk-test-secret"
    });
    raw_secret_runtime["packageDigest"] = json!(manifest_digest(&raw_secret_runtime));
    let rejected_secret = register_package(
        &handle,
        raw_secret_runtime,
        "module-register-raw-secret-runtime",
    )
    .await;
    assert!(matches!(
        rejected_secret.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("secret-like value")
    ));

    let mut bad_digest =
        manifest_with_digest(package_manifest("bad-digest", "demo", "demo-worker"));
    bad_digest["packageDigest"] = json!("sha256:not-the-digest");
    let rejected_digest = register_package(&handle, bad_digest, "module-register-bad-digest").await;
    assert!(matches!(
        rejected_digest.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("packageDigest")
    ));

    let mut bad_namespace =
        manifest_with_digest(package_manifest("bad-namespace", "demo", "demo-worker"));
    bad_namespace["declaredCapabilities"][0]["functionId"] = json!("other::inspect");
    bad_namespace["packageDigest"] = json!(manifest_digest(&bad_namespace));
    let rejected_namespace =
        register_package(&handle, bad_namespace, "module-register-bad-namespace").await;
    assert!(matches!(
        rejected_namespace.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("namespace")
    ));

    let mut missing_contract =
        manifest_with_digest(package_manifest("missing-contract", "demo", "demo-worker"));
    missing_contract["declaredCapabilities"][1]["idempotent"] = json!(false);
    missing_contract["packageDigest"] = json!(manifest_digest(&missing_contract));
    let rejected_contract = register_package(
        &handle,
        missing_contract,
        "module-register-missing-contract",
    )
    .await;
    assert!(matches!(
        rejected_contract.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("idempotency")
    ));
}

#[tokio::test]
async fn module_local_package_install_shape_is_resource_backed_and_rejects_implicit_remote_trust() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("marketplace-local-worker.sh"),
        "module-marketplace-local-executable",
    )
    .await;
    let manifest = manifest_with_digest(local_process_manifest(
        "marketplace-local-tools",
        "marketplace_local",
        "marketplace-local-worker",
        executable,
    ));
    let package_digest = manifest["packageDigest"].as_str().unwrap().to_owned();
    let installed = register_package(&handle, manifest, "module-marketplace-local-install").await;
    assert_eq!(installed.error, None);
    let installed_ref = &installed.value.as_ref().unwrap()["resourceRefs"][0];
    assert_eq!(installed_ref["kind"], "worker_package");
    assert_eq!(installed_ref["role"], "created");
    assert_eq!(
        installed_ref["resourceId"],
        "worker-package:marketplace-local-tools"
    );

    let inspected = inspect_resource(&handle, "worker-package:marketplace-local-tools").await;
    assert_eq!(inspected["resource"]["kind"], "worker_package");
    assert_eq!(inspected["resource"]["ownerWorkerId"], "module");
    let payload = current_version_payload(&inspected);
    assert_eq!(payload["sourceProvenance"]["kind"], "local_digest_pinned");
    assert_eq!(
        payload["sourceRef"]["provenance"]["kind"],
        "local_digest_pinned"
    );
    assert_eq!(payload["sourceDigest"], package_digest);
    assert_eq!(payload["sourceTrustStatus"], "unverified");
    assert_eq!(payload["effectiveTrustTier"], "untrusted");
    assert_eq!(payload["sourceEvidenceRefs"], json!([]));
    assert_eq!(payload["sourceApprovalRefs"], json!([]));

    let package_view = handle
        .invoke(host_invocation(
            "module::inspect_package",
            json!({"packageId": "marketplace-local-tools"}),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(package_view.error, None);
    for function_id in [
        "module::verify_source",
        "module::approve_source",
        "module::run_conformance",
        "module::configure",
        "module::activate",
    ] {
        assert!(
            package_view.value.as_ref().unwrap()["availableActions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|action| action["functionId"] == function_id
                    && action["consequence"]["targetFunctionId"] == function_id),
            "package install surface must expose canonical {function_id}"
        );
    }

    let source_registration = handle
        .invoke(host_invocation(
            "module::register_source",
            json!({
                "sourceKind": "local_digest_source",
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "sourceDigest": package_digest,
                "sourceRef": {"provenance": {"kind": "local_digest_pinned"}},
                "allowedPackageSelectors": ["marketplace-local-tools"],
                "trustTierCeiling": "local_digest_pinned",
                "grantCeiling": grant_ceiling_for_namespace("marketplace_local"),
                "expiresAt": "2100-01-01T00:00:00Z",
                "reason": "test registers explicit local install source policy"
            }),
            mutating_causal("module-marketplace-register-source").with_scope("module.write"),
        ))
        .await;
    assert_eq!(source_registration.error, None);
    let source_value = source_registration.value.as_ref().unwrap();
    assert!(
        source_value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "decision")
    );
    assert!(
        source_value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
    assert_eq!(
        source_value["decision"]["metadata"]["allowedPackageSelectors"],
        json!(["marketplace-local-tools"])
    );
    assert_eq!(
        source_value["decision"]["metadata"]["grantCeiling"]["allowedCapabilities"],
        json!([
            "marketplace_local::inspect",
            "marketplace_local::write_artifact"
        ])
    );

    let package_count_before_remote = resource_count(&handle, "worker_package").await;
    let mut remote_manifest =
        manifest_with_digest(package_manifest("remote-tools", "remote", "remote-worker"));
    remote_manifest["sourceProvenance"] = json!({
        "kind": "remote_url",
        "url": "https://example.invalid/remote-tools.json"
    });
    remote_manifest["packageDigest"] = json!(manifest_digest(&remote_manifest));
    let rejected_remote_package = register_package(
        &handle,
        remote_manifest,
        "module-marketplace-remote-package",
    )
    .await;
    assert!(matches!(
        rejected_remote_package.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("unsupported package provenance")
    ));
    assert_eq!(
        resource_count(&handle, "worker_package").await,
        package_count_before_remote
    );

    let rejected_remote_source = handle
        .invoke(host_invocation(
            "module::register_source",
            json!({
                "sourceKind": "remote_url",
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "reason": "implicit remote marketplace trust must not be accepted"
            }),
            mutating_causal("module-marketplace-remote-source").with_scope("module.write"),
        ))
        .await;
    assert!(
        rejected_remote_source
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("sourceKind"))
    );
}

fn current_version_payload(inspection: &Value) -> &Value {
    let current_version_id = inspection["resource"]["currentVersionId"]
        .as_str()
        .expect("resource inspection has a current version");
    &inspection["versions"]
        .as_array()
        .expect("resource inspection has versions")
        .iter()
        .find(|version| version["versionId"].as_str() == Some(current_version_id))
        .expect("current resource version is inspectable")["payload"]
}

#[tokio::test]
async fn module_register_package_validates_local_process_runtime_manifest() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("demo-worker.sh"),
        "module-local-manifest-executable",
    )
    .await;

    let good = register_package(
        &handle,
        manifest_with_digest(local_process_manifest(
            "demo-local-tools",
            "demo_local",
            "demo-local-worker",
            executable.clone(),
        )),
        "module-local-register-good",
    )
    .await;
    assert_eq!(good.error, None);

    let mut missing_file_refs = local_process_manifest(
        "demo-local-missing-files",
        "demo_local",
        "demo-local-worker",
        executable.clone(),
    );
    missing_file_refs["runtimeEntryPoint"]
        .as_object_mut()
        .unwrap()
        .remove("executableRefs");
    let rejected_file_refs = register_package(
        &handle,
        manifest_with_digest(missing_file_refs),
        "module-local-register-missing-file-refs",
    )
    .await;
    assert!(matches!(
        rejected_file_refs.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("executableRefs")
    ));

    let mut missing_expected = local_process_manifest(
        "demo-local-missing-expected",
        "demo_local",
        "demo-local-worker",
        executable,
    );
    missing_expected["runtimeEntryPoint"]
        .as_object_mut()
        .unwrap()
        .remove("expectedFunctionIds");
    let rejected_expected = register_package(
        &handle,
        manifest_with_digest(missing_expected),
        "module-local-register-missing-expected",
    )
    .await;
    assert!(matches!(
        rejected_expected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("expectedFunctionIds")
    ));
}
