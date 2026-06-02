use super::*;

#[tokio::test]
async fn module_local_source_policy_requires_verification_and_approval_before_spawn() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("policy-local-worker.sh"),
        "module-policy-local-executable",
    )
    .await;
    let manifest = manifest_with_digest(local_process_manifest(
        "policy-local-tools",
        "demo_local",
        "policy-local-worker",
        executable,
    ));
    let package_digest = manifest["packageDigest"].as_str().unwrap().to_owned();
    let registered = register_package(&handle, manifest, "module-policy-local-register").await;
    assert_eq!(registered.error, None);
    let package_resource_id = "worker-package:policy-local-tools";
    let registered_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": registered_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:policy-local-key"}
            }),
            mutating_causal("module-policy-local-configure").with_scope("module.write"),
        ))
        .await;
    assert_eq!(configured.error, None);
    let config_version_id = configured.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let activate_payload = json!({
        "packageResourceId": package_resource_id,
        "packageVersionId": registered_version_id,
        "moduleConfigResourceId": "module-config:workspace-a:policy-local-tools",
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
    let denied = handle
        .invoke(host_invocation(
            "module::activate",
            activate_payload.clone(),
            mutating_causal("module-policy-local-denied").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("source policy")
                || message.contains("source verification")
                || message.contains("source approval")
    ));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 0);

    let verified = verify_source(
        &handle,
        package_resource_id,
        &registered_version_id,
        "module-policy-local-verify",
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
    assert_eq!(
        verified.value.as_ref().unwrap()["sourceVerification"]["status"],
        "verified"
    );

    let approved = approve_source(
        &handle,
        package_resource_id,
        &verified_package_version_id,
        &package_digest,
        "policy-local-tools",
        "module-policy-local-approve",
    )
    .await;
    assert_eq!(approved.error, None);
    assert_eq!(
        approved.value.as_ref().unwrap()["decision"]["status"],
        "approved"
    );

    let policy = handle
        .invoke(host_invocation(
            "module::policy_decide",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
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
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(policy.error, None);
    assert_eq!(policy.value.as_ref().unwrap()["decision"], "allow");
}

#[tokio::test]
async fn module_source_approval_ceiling_denies_overbroad_activation_before_spawn() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("approval-ceiling-worker.sh"),
        "module-approval-ceiling-executable",
    )
    .await;
    let manifest = manifest_with_digest(local_process_manifest(
        "approval-ceiling-tools",
        "ceiling_demo",
        "approval-ceiling-worker",
        executable,
    ));
    let package_digest = manifest["packageDigest"].as_str().unwrap().to_owned();
    let registered = register_package(&handle, manifest, "module-approval-ceiling-register").await;
    assert_eq!(registered.error, None);
    let package_resource_id = "worker-package:approval-ceiling-tools";
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let verified = verify_source(
        &handle,
        package_resource_id,
        &package_version_id,
        "module-approval-ceiling-verify",
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
    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:approval-ceiling-key"}
            }),
            mutating_causal("module-approval-ceiling-configure").with_scope("module.write"),
        ))
        .await;
    assert_eq!(configured.error, None);
    let config_version_id = configured.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let approval_ceiling = json!({
        "allowedCapabilities": ["ceiling_demo::inspect"],
        "allowedNamespaces": ["ceiling_demo"],
        "allowedAuthorityScopes": ["ceiling_demo.read"],
        "allowedResourceKinds": ["artifact"],
        "resourceSelectors": ["*"],
        "fileRoots": ["*"],
        "networkPolicy": "none",
        "maxRisk": "low",
        "canDelegate": false,
        "approvalRequired": false
    });
    let approved = handle
        .invoke(host_invocation(
            "module::approve_source",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "packageDigest": package_digest,
                "packageId": "approval-ceiling-tools",
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "trustTierCeiling": "local_digest_pinned",
                "grantCeiling": approval_ceiling,
                "expiresAt": "2100-01-01T00:00:00Z",
                "reason": "test approves only the read capability"
            }),
            mutating_causal("module-approval-ceiling-approve").with_scope("module.write"),
        ))
        .await;
    assert_eq!(approved.error, None);
    let decision_resource_id = approved.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let decision = inspect_resource(&handle, &decision_resource_id).await;
    let decision_payload =
        decision["versions"].as_array().unwrap().last().unwrap()["payload"].clone();
    assert_eq!(
        decision_payload["metadata"]["decisionType"],
        "module_source_approval"
    );
    assert_eq!(
        decision_payload["metadata"]["grantCeiling"]["allowedCapabilities"]
            .as_array()
            .unwrap()
            .iter()
            .map(|function_id| function_id.as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["ceiling_demo::inspect"]
    );

    let narrow_policy = handle
        .invoke(host_invocation(
            "module::policy_decide",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": {
                    "allowedCapabilities": ["ceiling_demo::inspect"],
                    "allowedNamespaces": ["ceiling_demo"],
                    "allowedAuthorityScopes": ["ceiling_demo.read"],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "low"
                }
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(narrow_policy.error, None);
    assert_eq!(narrow_policy.value.as_ref().unwrap()["decision"], "allow");

    let overbroad_activation = handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:approval-ceiling-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": {
                    "allowedCapabilities": [
                        "ceiling_demo::inspect",
                        "ceiling_demo::write_artifact"
                    ],
                    "allowedNamespaces": ["ceiling_demo"],
                    "allowedAuthorityScopes": ["ceiling_demo.read", "ceiling_demo.write"],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal("module-approval-ceiling-activate-overbroad")
                .with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        overbroad_activation.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("approval grant capabilities")
                || message.contains("approval grant authority scopes")
                || message.contains("requested maxRisk exceeds source approval")
    ));
    assert_eq!(
        spawn_calls.lock().expect("spawn calls").len(),
        0,
        "source approval ceiling must be enforced before worker::spawn"
    );
}

#[tokio::test]
async fn module_source_approval_revocation_and_conformance_are_resource_backed() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("conformance-local-worker.sh"),
        "module-conformance-local-executable",
    )
    .await;
    let manifest = manifest_with_digest(local_process_manifest(
        "conformance-local-tools",
        "demo_local",
        "conformance-local-worker",
        executable,
    ));
    let package_digest = manifest["packageDigest"].as_str().unwrap().to_owned();
    let registered = register_package(&handle, manifest, "module-conformance-local-register").await;
    assert_eq!(registered.error, None);
    let package_resource_id = "worker-package:conformance-local-tools";
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let verified = verify_source(
        &handle,
        package_resource_id,
        &package_version_id,
        "module-conformance-local-verify",
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
                "mode": "static"
            }),
            mutating_causal("module-conformance-run").with_scope("module.write"),
        ))
        .await;
    assert_eq!(conformance.error, None);
    assert_eq!(
        conformance.value.as_ref().unwrap()["conformance"]["status"],
        "valid"
    );
    assert!(
        conformance.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
    let conformed_package_version_id = conformance.value.as_ref().unwrap()["resourceRefs"]
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
        package_resource_id,
        &conformed_package_version_id,
        &package_digest,
        "conformance-local-tools",
        "module-conformance-approve",
    )
    .await;
    assert_eq!(approved.error, None);
    let decision_resource_id = approved.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let revoked = handle
        .invoke(host_invocation(
            "module::revoke_source_approval",
            json!({
                "decisionResourceId": decision_resource_id,
                "reason": "test revokes source approval"
            }),
            mutating_causal("module-conformance-revoke").with_scope("module.write"),
        ))
        .await;
    assert_eq!(revoked.error, None);
    assert_eq!(
        revoked.value.as_ref().unwrap()["decision"]["status"],
        "revoked"
    );

    let policy = handle
        .invoke(host_invocation(
            "module::policy_decide",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": conformed_package_version_id,
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
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(policy.error, None);
    assert_eq!(policy.value.as_ref().unwrap()["decision"], "deny");
    assert!(
        policy.value.as_ref().unwrap()["reasons"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reason| reason.as_str().unwrap_or_default().contains("approval"))
    );
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
        .find(|entry| entry["packageResourceId"] == package_resource_id)
        .expect("package source trust projection");
    assert!(
        source_trust["sourceApprovalRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["resourceId"] == decision_resource_id)
    );
    assert!(
        source_trust["approvalWarnings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|warning| warning["code"] == "source_approval_revoked")
    );
}

#[tokio::test]
async fn module_trust_root_signature_policy_allows_signed_activation() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("signed-local-worker.sh"),
        "module-signed-policy-executable",
    )
    .await;
    let (signing_key, public_key, key_id) = signing_fixture();
    let manifest = signed_package_manifest(
        local_process_manifest(
            "signed-policy-tools",
            "demo_local",
            "signed-policy-worker",
            executable,
        ),
        &signing_key,
        &key_id,
    );
    let package_resource_id = "worker-package:signed-policy-tools";
    let registered = register_package(&handle, manifest, "module-signed-policy-register").await;
    assert_eq!(registered.error, None);
    let registered_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let configured_unverified = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": registered_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:signed-policy-key"}
            }),
            mutating_causal("module-signed-policy-configure-unverified").with_scope("module.write"),
        ))
        .await;
    assert_eq!(configured_unverified.error, None);
    let unverified_config_version_id =
        configured_unverified.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();

    let child_grant = grant_ceiling_for_namespace("demo_local");
    let denied = handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": registered_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:signed-policy-tools",
                "configVersionId": unverified_config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": child_grant
            }),
            mutating_causal("module-signed-policy-denied").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("signature trust") || message.contains("signature verification")
    ));
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 0);

    let trust_root = register_trust_root(
        &handle,
        &public_key,
        &key_id,
        "signed-policy-tools",
        "demo_local",
        "module-signed-policy-trust-root",
    )
    .await;
    assert_eq!(trust_root.error, None);
    assert_eq!(
        trust_root.value.as_ref().unwrap()["trustRoot"]["trustRootRef"],
        format!("trust-root:{key_id}")
    );

    let verified = verify_signature(
        &handle,
        package_resource_id,
        &registered_version_id,
        "module-signed-policy-verify-signature",
    )
    .await;
    assert_eq!(verified.error, None);
    assert_eq!(
        verified.value.as_ref().unwrap()["signatureVerification"]["status"],
        "verified"
    );
    let verified_package_version_id = verified.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "worker_package")
        .unwrap()["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let audit = handle
        .invoke(host_invocation(
            "module::audit_policy",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(audit.error, None);
    assert_eq!(audit.value.as_ref().unwrap()["audit"]["decision"], "allow");
    assert_eq!(
        audit.value.as_ref().unwrap()["audit"]["approval"]["status"],
        "trusted_signature"
    );

    let configured_verified = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:signed-policy-key"}
            }),
            mutating_causal("module-signed-policy-configure-verified").with_scope("module.write"),
        ))
        .await;
    assert_eq!(configured_verified.error, None);
    let verified_config_version_id = configured_verified.value.as_ref().unwrap()["resourceRefs"][0]
        ["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:signed-policy-tools",
                "configVersionId": verified_config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            mutating_causal("module-signed-policy-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    assert!(
        activated.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "activation_record")
    );
}

#[tokio::test]
async fn module_verify_signature_rejects_unknown_keys_and_bad_signatures() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("unknown-key-worker.sh"),
        "module-signature-unknown-key-executable",
    )
    .await;
    let (signing_key, public_key, key_id) = signing_fixture();
    let manifest = signed_package_manifest(
        local_process_manifest(
            "unknown-key-tools",
            "demo_local",
            "unknown-key-worker",
            executable,
        ),
        &signing_key,
        &key_id,
    );
    let package_resource_id = "worker-package:unknown-key-tools";
    let registered =
        register_package(&handle, manifest, "module-signature-unknown-key-register").await;
    assert_eq!(registered.error, None);
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let unknown_key = verify_signature(
        &handle,
        package_resource_id,
        &package_version_id,
        "module-signature-unknown-key-verify",
    )
    .await;
    assert!(matches!(
        unknown_key.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("active trust root")
    ));

    let trust_root = register_trust_root(
        &handle,
        &public_key,
        &key_id,
        "bad-signature-tools",
        "demo_local",
        "module-signature-bad-trust-root",
    )
    .await;
    assert_eq!(trust_root.error, None);

    let bad_executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("bad-signature-worker.sh"),
        "module-signature-bad-executable",
    )
    .await;
    let (wrong_signing_key, _, _) = signing_fixture_with_seed(9);
    let bad_manifest = signed_package_manifest(
        local_process_manifest(
            "bad-signature-tools",
            "demo_local",
            "bad-signature-worker",
            bad_executable,
        ),
        &wrong_signing_key,
        &key_id,
    );
    let bad_registered =
        register_package(&handle, bad_manifest, "module-signature-bad-register").await;
    assert_eq!(bad_registered.error, None);
    let bad_version_id = bad_registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let bad_signature = verify_signature(
        &handle,
        "worker-package:bad-signature-tools",
        &bad_version_id,
        "module-signature-bad-verify",
    )
    .await;
    assert!(matches!(
        bad_signature.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("signature verification failed")
    ));
}

#[tokio::test]
async fn module_policy_audit_and_reconcile_track_revoked_trust_roots() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("revoked-trust-worker.sh"),
        "module-revoked-trust-executable",
    )
    .await;
    let (signing_key, public_key, key_id) = signing_fixture();
    let manifest = signed_package_manifest(
        local_process_manifest(
            "revoked-trust-tools",
            "demo_local",
            "revoked-trust-worker",
            executable,
        ),
        &signing_key,
        &key_id,
    );
    let package_resource_id = "worker-package:revoked-trust-tools";
    let registered = register_package(&handle, manifest, "module-revoked-trust-register").await;
    assert_eq!(registered.error, None);
    let registered_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let trust_root = register_trust_root(
        &handle,
        &public_key,
        &key_id,
        "revoked-trust-tools",
        "demo_local",
        "module-revoked-trust-root",
    )
    .await;
    assert_eq!(trust_root.error, None);
    let trust_root_decision_id =
        trust_root.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
            .as_str()
            .unwrap()
            .to_owned();

    let verified = verify_signature(
        &handle,
        package_resource_id,
        &registered_version_id,
        "module-revoked-trust-verify-signature",
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

    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:revoked-trust-key"}
            }),
            mutating_causal("module-revoked-trust-configure").with_scope("module.write"),
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
                "packageVersionId": verified_package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:revoked-trust-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            mutating_causal("module-revoked-trust-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    let activation_resource_id = activated.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();

    let revoked = handle
        .invoke(host_invocation(
            "module::register_source",
            json!({
                "sourceKind": "source_revocation",
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "revokedDecisionResourceId": trust_root_decision_id,
                "reason": "test revokes local trust root"
            }),
            mutating_causal("module-revoked-trust-revoke").with_scope("module.write"),
        ))
        .await;
    assert_eq!(revoked.error, None);

    let audit = handle
        .invoke(host_invocation(
            "module::audit_policy",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(audit.error, None);
    assert_eq!(audit.value.as_ref().unwrap()["audit"]["decision"], "deny");
    assert!(
        audit.value.as_ref().unwrap()["audit"]["missingPrerequisites"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item == "signature_trust")
    );

    let recorded = handle
        .invoke(host_invocation(
            "module::record_policy_audit",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            mutating_causal("module-revoked-trust-record-audit").with_scope("module.write"),
        ))
        .await;
    assert_eq!(recorded.error, None);
    assert!(
        recorded.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );

    let reconciled = handle
        .invoke(host_invocation(
            "module::reconcile_trust",
            json!({
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "packageResourceId": package_resource_id,
                "reason": "test reconcile after trust-root revocation"
            }),
            mutating_causal("module-revoked-trust-reconcile").with_scope("module.write"),
        ))
        .await;
    assert_eq!(reconciled.error, None);
    assert!(
        reconciled.value.as_ref().unwrap()["reconciliation"]["affectedPackages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|package| package["packageResourceId"] == package_resource_id)
    );
    assert!(
        reconciled.value.as_ref().unwrap()["reconciliation"]["affectedActivations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|activation| activation["activationResourceId"] == activation_resource_id)
    );
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
}

#[tokio::test]
async fn module_trust_operations_manage_renewal_expiry_and_rotation() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("trust-ops-worker.sh"),
        "module-trust-ops-executable",
    )
    .await;
    let (signing_key, public_key, key_id) = signing_fixture();
    let manifest = signed_package_manifest(
        local_process_manifest(
            "trust-ops-tools",
            "demo_local",
            "trust-ops-worker",
            executable,
        ),
        &signing_key,
        &key_id,
    );
    let package_resource_id = "worker-package:trust-ops-tools";
    let registered = register_package(&handle, manifest, "module-trust-ops-register").await;
    assert_eq!(registered.error, None);
    let registered_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let trust_root = register_trust_root(
        &handle,
        &public_key,
        &key_id,
        "trust-ops-tools",
        "demo_local",
        "module-trust-ops-root",
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
        "module-trust-ops-verify",
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

    let inspected = handle
        .invoke(host_invocation(
            "module::inspect_trust",
            json!({
                "targetType": "trust_root",
                "targetResourceId": trust_root_decision_id,
                "targetVersionId": trust_root_version_id,
                "includeEvidence": true,
                "limit": 20
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    assert!(
        inspected.value.as_ref().unwrap()["affectedPackages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|package| package["packageResourceId"] == package_resource_id)
    );

    let renewed = handle
        .invoke(host_invocation(
            "module::renew_trust_root",
            json!({
                "trustRootDecisionResourceId": trust_root_decision_id,
                "trustRootDecisionVersionId": trust_root_version_id,
                "expectedCurrentVersionId": trust_root_version_id,
                "expiresAt": "2100-06-01T00:00:00Z",
                "allowedPackageSelectors": ["trust-ops-tools"],
                "grantCeiling": grant_ceiling_for_namespace("demo_local"),
                "trustTierCeiling": "signed_local",
                "reason": "test renews same-key trust root"
            }),
            mutating_causal("module-trust-ops-renew").with_scope("module.write"),
        ))
        .await;
    assert_eq!(renewed.error, None);
    let renewed_decision_id = renewed.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "decision")
        .unwrap()["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let renewed_inspection = inspect_resource(&handle, &renewed_decision_id).await;
    assert!(
        renewed_inspection["outgoingLinks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|link| link["relation"] == "supersedes"
                && link["targetResourceId"] == trust_root_decision_id),
        "renewed trust root must require durable supersedes lineage"
    );

    let expired_old = handle
        .invoke(host_invocation(
            "module::expire_trust_decision",
            json!({
                "decisionResourceId": trust_root_decision_id,
                "decisionVersionId": trust_root_version_id,
                "expectedCurrentVersionId": trust_root_version_id,
                "reason": "old trust root was renewed"
            }),
            mutating_causal("module-trust-ops-expire-old").with_scope("module.write"),
        ))
        .await;
    assert_eq!(expired_old.error, None);
    let audit_with_renewal = handle
        .invoke(host_invocation(
            "module::audit_policy",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(audit_with_renewal.error, None);
    assert_eq!(
        audit_with_renewal.value.as_ref().unwrap()["audit"]["decision"],
        "allow",
        "same-key renewed trust root should satisfy an existing signed package"
    );

    let renewed_version_id = renewed.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "decision")
        .unwrap()["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let (_new_signing_key, new_public_key, new_key_id) = signing_fixture_with_seed(9);
    let new_trust_root = register_trust_root(
        &handle,
        &new_public_key,
        &new_key_id,
        "trust-ops-tools",
        "demo_local",
        "module-trust-ops-new-root",
    )
    .await;
    assert_eq!(new_trust_root.error, None);
    let new_trust_root_decision_id =
        new_trust_root.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
            .as_str()
            .unwrap()
            .to_owned();
    let new_trust_root_version_id =
        new_trust_root.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();
    let rotated = handle
        .invoke(host_invocation(
            "module::rotate_signature_key",
            json!({
                "oldTrustRootDecisionResourceId": renewed_decision_id,
                "oldTrustRootDecisionVersionId": renewed_version_id,
                "newTrustRootDecisionResourceId": new_trust_root_decision_id,
                "newTrustRootDecisionVersionId": new_trust_root_version_id,
                "reason": "test records key rotation lineage"
            }),
            mutating_causal("module-trust-ops-rotate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(rotated.error, None);
    let rotation_evidence_id = rotated.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let rotation_inspection = inspect_resource(&handle, &rotation_evidence_id).await;
    assert!(
        rotation_inspection["outgoingLinks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|link| link["relation"] == "rotates_from"
                && link["targetResourceId"] == renewed_decision_id)
    );
    assert!(
        rotation_inspection["outgoingLinks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|link| link["relation"] == "rotates_to"
                && link["targetResourceId"] == new_trust_root_decision_id)
    );
    let expired_renewal = handle
        .invoke(host_invocation(
            "module::expire_trust_decision",
            json!({
                "decisionResourceId": renewed_decision_id,
                "decisionVersionId": renewed_version_id,
                "expectedCurrentVersionId": renewed_version_id,
                "reason": "test expires active renewal"
            }),
            mutating_causal("module-trust-ops-expire-renewal").with_scope("module.write"),
        ))
        .await;
    assert_eq!(expired_renewal.error, None);
    let audit_without_trust = handle
        .invoke(host_invocation(
            "module::audit_policy",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(audit_without_trust.error, None);
    assert_eq!(
        audit_without_trust.value.as_ref().unwrap()["audit"]["decision"],
        "deny"
    );
    let audit_after_rotation = handle
        .invoke(host_invocation(
            "module::audit_policy",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": verified_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            causal().with_scope("module.read"),
        ))
        .await;
    assert_eq!(audit_after_rotation.error, None);
    assert_eq!(
        audit_after_rotation.value.as_ref().unwrap()["audit"]["decision"],
        "deny",
        "rotation lineage must not satisfy packages signed by the old key"
    );
}

#[tokio::test]
async fn module_enforce_revocation_composes_canonical_activation_mutations() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_calls = register_recording_worker_spawn(&handle);
    let stop_calls = register_recording_sandbox_stop(&handle);
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("enforce-revocation-worker.sh"),
        "module-enforce-revocation-executable",
    )
    .await;
    let (signing_key, public_key, key_id) = signing_fixture();
    let manifest = signed_package_manifest(
        local_process_manifest(
            "enforce-revocation-tools",
            "demo_local",
            "enforce-revocation-worker",
            executable,
        ),
        &signing_key,
        &key_id,
    );
    let package_resource_id = "worker-package:enforce-revocation-tools";
    let registered =
        register_package(&handle, manifest, "module-enforce-revocation-register").await;
    assert_eq!(registered.error, None);
    let registered_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let trust_root = register_trust_root(
        &handle,
        &public_key,
        &key_id,
        "enforce-revocation-tools",
        "demo_local",
        "module-enforce-revocation-root",
    )
    .await;
    assert_eq!(trust_root.error, None);
    let trust_root_decision_id =
        trust_root.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
            .as_str()
            .unwrap()
            .to_owned();
    let verified = verify_signature(
        &handle,
        package_resource_id,
        &registered_version_id,
        "module-enforce-revocation-verify",
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
                "config": {"enabled": true, "apiKeyRef": "secret_ref:enforce-revocation"}
            }),
            mutating_causal("module-enforce-revocation-configure").with_scope("module.write"),
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
                "moduleConfigResourceId": "module-config:workspace-a:enforce-revocation-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_ceiling_for_namespace("demo_local")
            }),
            mutating_causal("module-enforce-revocation-activate").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), 1);
    let activation_resource_id = activated.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();

    let revoked = handle
        .invoke(host_invocation(
            "module::register_source",
            json!({
                "sourceKind": "source_revocation",
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "revokedDecisionResourceId": trust_root_decision_id,
                "reason": "test revokes trust before enforcement"
            }),
            mutating_causal("module-enforce-revocation-revoke").with_scope("module.write"),
        ))
        .await;
    assert_eq!(revoked.error, None);
    let revocation_decision_id = revoked.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let revocation_version_id = revoked.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let rejected_unrelated = handle
        .invoke(host_invocation(
            "module::enforce_revocation",
            json!({
                "revocationDecisionResourceId": revocation_decision_id,
                "expectedDecisionVersionId": revocation_version_id,
                "mode": "quarantine",
                "activationResourceIds": ["activation:workspace-a:not-affected"],
                "reason": "test rejects unrelated activation"
            }),
            mutating_causal("module-enforce-revocation-unrelated").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        rejected_unrelated.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not affected")
    ));

    let enforced = handle
        .invoke(host_invocation(
            "module::enforce_revocation",
            json!({
                "revocationDecisionResourceId": revocation_decision_id,
                "expectedDecisionVersionId": revocation_version_id,
                "mode": "quarantine",
                "activationResourceIds": [activation_resource_id],
                "reason": "test explicitly quarantines affected activation"
            }),
            mutating_causal("module-enforce-revocation-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(enforced.error, None);
    assert_eq!(stop_calls.lock().expect("stop calls").len(), 1);
    let value = enforced.value.as_ref().unwrap();
    assert!(
        value["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "evidence")
    );
    assert!(
        value["childInvocationIds"]
            .as_array()
            .unwrap()
            .iter()
            .all(|id| id.as_str().is_some_and(|id| !id.is_empty()))
    );
    let activation =
        inspect_resource(&handle, "activation:workspace-a:enforce-revocation-tools").await;
    assert_eq!(activation["resource"]["lifecycle"], "quarantined");
    assert_eq!(
        activation["versions"].as_array().unwrap().last().unwrap()["payload"]
            .get("activationStatus")
            .and_then(Value::as_str),
        Some("quarantined")
    );
}

#[tokio::test]
async fn module_verify_source_rejects_signature_material_without_trust_root() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("signed-local-worker.sh"),
        "module-signed-local-executable",
    )
    .await;
    let mut manifest = local_process_manifest(
        "signed-local-tools",
        "demo_local",
        "signed-local-worker",
        executable,
    );
    manifest["signature"] = json!({
        "algorithm": "ed25519",
        "value": "base64:unsigned-test-fixture"
    });
    manifest["signatureKeyRef"] = json!("secret_ref:test-signing-key");
    manifest["packageDigest"] = json!(manifest_digest(&manifest));
    let registered = register_package(&handle, manifest, "module-signed-local-register").await;
    assert_eq!(registered.error, None);
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let rejected = verify_source(
        &handle,
        "worker-package:signed-local-tools",
        &package_version_id,
        "module-signed-local-verify",
    )
    .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("signature_verification_unsupported")
    ));
}

#[tokio::test]
async fn module_register_package_rejects_adversarial_manifest_shapes_without_persistence() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        &handle,
        &tmp.path().join("adversarial-worker.sh"),
        "module-adversarial-manifest-executable",
    )
    .await;

    let mut duplicate = local_process_manifest(
        "adversarial-duplicate",
        "demo_local",
        "adversarial-worker",
        executable.clone(),
    );
    duplicate["declaredCapabilities"][1]["functionId"] =
        duplicate["declaredCapabilities"][0]["functionId"].clone();

    let mut raw_secret = local_process_manifest(
        "adversarial-secret",
        "demo_local",
        "adversarial-worker",
        executable.clone(),
    );
    raw_secret["runtimeEntryPoint"]["environmentPolicy"] = json!({
        "mode": "empty",
        "apiSecret": "sk-abcdefghijklmnopqrstuvwxyz012345"
    });

    let mut missing_command_ref = local_process_manifest(
        "adversarial-command-ref",
        "demo_local",
        "adversarial-worker",
        executable.clone(),
    );
    missing_command_ref["runtimeEntryPoint"]["commandTemplate"]["resourceId"] =
        json!("materialized_file:missing");

    let mut unsafe_visibility = local_process_manifest(
        "adversarial-visibility",
        "demo_local",
        "adversarial-worker",
        executable,
    );
    unsafe_visibility["runtimeEntryPoint"]["visibility"] = json!("admin");

    let cases = [
        ("adversarial-duplicate", duplicate, "duplicate functionId"),
        ("adversarial-secret", raw_secret, "secret-like value"),
        (
            "adversarial-command-ref",
            missing_command_ref,
            "commandTemplate",
        ),
        (
            "adversarial-visibility",
            unsafe_visibility,
            "unsupported local_process visibility",
        ),
    ];

    for (package_id, manifest, expected) in cases {
        let rejected = register_package(
            &handle,
            manifest_with_digest(manifest),
            &format!("module-register-{package_id}"),
        )
        .await;
        assert!(
            matches!(
                rejected.error,
                Some(EngineError::PolicyViolation(ref message)) if message.contains(expected)
            ),
            "package {package_id} should reject with `{expected}`, got {:?}",
            rejected.error
        );
        let inspected = inspect_resource(&handle, &format!("worker-package:{package_id}")).await;
        assert_eq!(
            inspected,
            Value::Null,
            "rejected package {package_id} must not persist a worker_package resource"
        );
    }
}
