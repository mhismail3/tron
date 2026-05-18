use super::*;
use sha2::{Digest, Sha256};

fn package_manifest(package_id: &str, namespace: &str, worker_id: &str) -> Value {
    json!({
        "packageId": package_id,
        "version": "1.0.0",
        "manifestSchemaId": "tron.module.package_manifest.v1",
        "sourceProvenance": {"kind": "builtin"},
        "trustTier": "builtin",
        "signatureStatus": "trusted_builtin",
        "declaredWorkerKind": "in_process",
        "namespace": namespace,
        "declaredCapabilities": [
            {
                "functionId": format!("{namespace}::inspect"),
                "effectClass": "PureRead",
                "risk": "low",
                "requiredAuthority": [format!("{namespace}.read")],
                "outputResourceKinds": []
            },
            {
                "functionId": format!("{namespace}::write_artifact"),
                "effectClass": "IdempotentWrite",
                "risk": "medium",
                "requiredAuthority": [format!("{namespace}.write")],
                "idempotent": true,
                "outputResourceKinds": ["artifact"]
            }
        ],
        "requiredGrants": {
            "allowedCapabilities": [
                format!("{namespace}::inspect"),
                format!("{namespace}::write_artifact")
            ],
            "allowedNamespaces": [namespace],
            "allowedAuthorityScopes": [
                format!("{namespace}.read"),
                format!("{namespace}.write")
            ],
            "allowedResourceKinds": ["artifact"],
            "resourceSelectors": ["*"],
            "fileRoots": ["*"],
            "networkPolicy": "none",
            "maxRisk": "medium",
            "canDelegate": false,
            "approvalRequired": false
        },
        "configSchema": {
            "type": "object",
            "required": ["enabled"],
            "additionalProperties": false,
            "properties": {
                "enabled": {"type": "boolean"},
                "apiKeyRef": {"type": "string"}
            }
        },
        "runtimeEntryPoint": {"kind": "existing_worker", "workerId": worker_id},
        "healthPolicy": {"mode": "catalog_registered"},
        "sandboxProcessPolicy": {"networkPolicy": "none", "fileRoots": ["*"]},
        "redactionPolicy": {"mode": "redacted"}
    })
}

fn manifest_with_digest(mut manifest: Value) -> Value {
    let digest = manifest_digest(&manifest);
    manifest["packageDigest"] = json!(digest);
    manifest
}

fn manifest_digest(manifest: &Value) -> String {
    let mut canonical = manifest.clone();
    if let Some(object) = canonical.as_object_mut() {
        object.remove("packageDigest");
    }
    let bytes = serde_json::to_vec(&canonical).unwrap();
    format!("sha256:{:x}", Sha256::digest(bytes))
}

fn generated_surface_request(target_type: &str, target_id: &str) -> Value {
    json!({
        "targetType": target_type,
        "targetId": target_id,
        "purpose": "Inspect module target",
        "layoutProfile": "compact",
        "maxPreviewBytes": 512,
        "expiresAt": "2100-01-01T00:00:00Z"
    })
}

fn register_demo_worker(handle: &EngineHostHandle, namespace: &str, worker_id: &str) {
    handle
        .register_worker_for_setup(worker(worker_id, namespace), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function(&format!("{namespace}::inspect"), worker_id)
                .with_required_authority(AuthorityRequirement::scope(format!("{namespace}.read"))),
            Some(handler()),
            false,
        )
        .unwrap();
    handle
        .register_function_for_setup(
            write_function(&format!("{namespace}::write_artifact"), worker_id)
                .with_required_authority(AuthorityRequirement::scope(format!("{namespace}.write")))
                .with_output_contract(DurableOutputContract::resource_backed(["artifact"])),
            Some(Arc::new(StaticValueHandler(json!({
                "resourceRefs": [{
                    "resourceId": "artifact-from-module",
                    "kind": "artifact",
                    "versionId": "ver-artifact-from-module",
                    "role": "created",
                    "contentHash": "sha256:artifact"
                }]
            })))),
            false,
        )
        .unwrap();
}

async fn register_package(
    handle: &EngineHostHandle,
    manifest: Value,
    key: &str,
) -> super::super::InvocationResult {
    handle
        .invoke(host_invocation(
            "module::register_package",
            json!({"manifest": manifest}),
            mutating_causal(key).with_scope("module.write"),
        ))
        .await
}

async fn grant_count(handle: &EngineHostHandle) -> usize {
    let result = handle
        .invoke(host_invocation(
            "grant::list",
            json!({"limit": 500}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("trace"),
            )
            .with_scope("grant.read"),
        ))
        .await;
    assert_eq!(result.error, None);
    result.value.as_ref().unwrap()["grants"]
        .as_array()
        .unwrap()
        .len()
}

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
    for function_id in [
        "module::register_package",
        "module::inspect_package",
        "module::configure",
        "module::activate",
        "module::disable",
        "module::upgrade",
        "module::rollback",
        "module::quarantine",
    ] {
        let function = value["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .find(|capability| capability["id"] == function_id)
            .unwrap_or_else(|| panic!("{function_id} must be discoverable"));
        if function_id != "module::inspect_package" {
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
async fn module_configure_and_activate_enforce_secret_and_grant_boundaries() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    register_demo_worker(&handle, "demo", "demo-worker");
    let registered = register_package(
        &handle,
        manifest_with_digest(package_manifest("demo-tools", "demo", "demo-worker")),
        "module-flow-register",
    )
    .await;
    assert_eq!(registered.error, None);
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let raw_secret = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": "worker-package:demo-tools",
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "sk-raw-secret-value"}
            }),
            mutating_causal("module-config-raw-secret").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        raw_secret.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("secret_ref")
    ));

    let configured = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": "worker-package:demo-tools",
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:demo-key"}
            }),
            mutating_causal("module-config-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(configured.error, None);
    assert_eq!(
        configured.value.as_ref().unwrap()["resourceRefs"][0]["kind"],
        "module_config"
    );
    let config_version_id = configured.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let broader = handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": "worker-package:demo-tools",
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:demo-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "demo-worker",
                "childGrantRequest": {
                    "allowedCapabilities": ["demo::inspect", "demo::write_artifact", "other::too_much"],
                    "allowedNamespaces": ["demo"],
                    "allowedAuthorityScopes": ["demo.read", "demo.write"],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal("module-activate-broader").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        broader.error,
        Some(EngineError::PolicyViolation(_))
    ));

    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": "worker-package:demo-tools",
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:demo-tools",
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "demo-worker",
                "childGrantRequest": {
                    "allowedCapabilities": ["demo::inspect", "demo::write_artifact"],
                    "allowedNamespaces": ["demo"],
                    "allowedAuthorityScopes": ["demo.read", "demo.write"],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal("module-activate-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    let value = activated.value.as_ref().unwrap();
    assert_eq!(value["resourceRefs"][0]["kind"], "activation_record");
    assert_eq!(value["activation"]["payload"]["activationStatus"], "active");
    assert_eq!(value["worker"]["id"], "demo-worker");
    let original_activation_version_id = value["resourceRefs"][0]["versionId"].as_str().unwrap();
    let original_grant_id = value["activation"]["payload"]["derivedGrantId"]
        .as_str()
        .unwrap()
        .to_owned();

    let mut upgraded_manifest = package_manifest("demo-tools", "demo", "demo-worker");
    upgraded_manifest["version"] = json!("1.1.0");
    let upgraded_package = register_package(
        &handle,
        manifest_with_digest(upgraded_manifest),
        "module-flow-upgrade-register",
    )
    .await;
    assert_eq!(upgraded_package.error, None);
    let upgraded_package_version_id =
        upgraded_package.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();
    let upgraded_config = handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": "worker-package:demo-tools",
                "packageVersionId": upgraded_package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": {"enabled": true, "apiKeyRef": "secret_ref:demo-key-v2"}
            }),
            mutating_causal("module-config-upgrade").with_scope("module.write"),
        ))
        .await;
    assert_eq!(upgraded_config.error, None);
    let upgraded_config_version_id =
        upgraded_config.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();

    let grant_count_before_rejected_upgrade = grant_count(&handle).await;
    let rejected_upgrade = handle
        .invoke(host_invocation(
            "module::upgrade",
            json!({
                "activationResourceId": "activation:workspace-a:wrong-package",
                "packageResourceId": "worker-package:demo-tools",
                "packageVersionId": upgraded_package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:demo-tools",
                "configVersionId": upgraded_config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "demo-worker",
                "childGrantRequest": {
                    "allowedCapabilities": ["demo::inspect", "demo::write_artifact"],
                    "allowedNamespaces": ["demo"],
                    "allowedAuthorityScopes": ["demo.read", "demo.write"],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal("module-upgrade-wrong-activation").with_scope("module.write"),
        ))
        .await;
    assert!(matches!(
        rejected_upgrade.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("activationResourceId")
    ));
    assert_eq!(
        grant_count(&handle).await,
        grant_count_before_rejected_upgrade
    );

    let upgraded = handle
        .invoke(host_invocation(
            "module::upgrade",
            json!({
                "activationResourceId": "activation:workspace-a:demo-tools",
                "packageResourceId": "worker-package:demo-tools",
                "packageVersionId": upgraded_package_version_id,
                "moduleConfigResourceId": "module-config:workspace-a:demo-tools",
                "configVersionId": upgraded_config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": "demo-worker",
                "expectedCurrentVersionId": original_activation_version_id,
                "childGrantRequest": {
                    "allowedCapabilities": ["demo::inspect", "demo::write_artifact"],
                    "allowedNamespaces": ["demo"],
                    "allowedAuthorityScopes": ["demo.read", "demo.write"],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal("module-upgrade-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(upgraded.error, None);
    let upgraded_value = upgraded.value.as_ref().unwrap();
    assert_eq!(
        upgraded_value["activation"]["payload"]["supersedes"]["grantId"],
        original_grant_id
    );
    assert_eq!(upgraded_value["replacedGrant"]["lifecycle"], "revoked");
    assert_ne!(
        upgraded_value["activation"]["payload"]["derivedGrantId"],
        original_grant_id
    );

    let disabled = handle
        .invoke(host_invocation(
            "module::disable",
            json!({
                "activationResourceId": "activation:workspace-a:demo-tools",
                "expectedCurrentVersionId": upgraded_value["resourceRefs"][0]["versionId"].as_str().unwrap()
            }),
            mutating_causal("module-disable-good").with_scope("module.write"),
        ))
        .await;
    assert_eq!(disabled.error, None);
    assert_eq!(
        disabled.value.as_ref().unwrap()["activation"]["payload"]["activationStatus"],
        "disabled"
    );
    assert_eq!(
        disabled.value.as_ref().unwrap()["revokedGrant"]["lifecycle"],
        "revoked"
    );
}

#[tokio::test]
async fn generated_ui_can_author_package_and_activation_operator_surfaces() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    register_demo_worker(&handle, "demo", "demo-worker");
    let registered = register_package(
        &handle,
        manifest_with_digest(package_manifest("demo-tools", "demo", "demo-worker")),
        "module-ui-register",
    )
    .await;
    assert_eq!(registered.error, None);

    for (target_type, target_id) in [
        ("package", "demo-tools"),
        ("resource", "worker-package:demo-tools"),
    ] {
        let surface = handle
            .invoke(host_invocation(
                "ui::surface_for_target",
                generated_surface_request(target_type, target_id),
                mutating_causal(&format!("module-ui-{target_type}")).with_scope("ui.write"),
            ))
            .await;
        assert_eq!(surface.error, None);
        assert_eq!(
            surface.value.as_ref().unwrap()["surface"]["authoring"]["targetType"],
            target_type
        );
        assert!(
            surface.value.as_ref().unwrap()["surface"]["actions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|action| action["targetFunctionId"] == "ui::refresh_surface")
        );
    }
}
