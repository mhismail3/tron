use super::*;
use sha2::{Digest, Sha256};

#[derive(Clone)]
struct RecordingWorkerSpawnHandler {
    handle: EngineHostHandle,
    calls: Arc<std::sync::Mutex<Vec<Value>>>,
}

#[async_trait]
impl InProcessFunctionHandler for RecordingWorkerSpawnHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        self.calls
            .lock()
            .expect("recording spawn calls lock")
            .push(invocation.payload.clone());
        let worker_id = invocation.payload["workerId"]
            .as_str()
            .expect("worker::spawn test payload has workerId");
        let expected = invocation.payload["expectedFunctionIds"]
            .as_array()
            .expect("worker::spawn test payload has expectedFunctionIds")
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        let namespace = expected
            .first()
            .and_then(|function_id| function_id.split_once("::").map(|(namespace, _)| namespace))
            .expect("expected function id has namespace");
        self.handle
            .register_worker(worker(worker_id, namespace), true)
            .await?;
        for function_id in &expected {
            let function = if function_id.ends_with("::write_artifact") {
                write_function(function_id, worker_id)
                    .with_required_authority(AuthorityRequirement::scope(format!(
                        "{namespace}.write"
                    )))
                    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]))
            } else {
                read_function(function_id, worker_id).with_required_authority(
                    AuthorityRequirement::scope(format!("{namespace}.read")),
                )
            };
            let handler: Arc<dyn InProcessFunctionHandler> =
                if function_id.ends_with("::write_artifact") {
                    Arc::new(StaticValueHandler(json!({
                        "resourceRefs": [{
                            "resourceId": "artifact-from-local-process",
                            "kind": "artifact",
                            "versionId": "ver-artifact-from-local-process",
                            "role": "created",
                            "contentHash": "sha256:artifact"
                        }]
                    })))
                } else {
                    handler()
                };
            self.handle
                .register_function(function, Some(handler), true)
                .await?;
        }
        let grant_result = self
            .handle
            .invoke(host_invocation(
                "grant::derive",
                json!({
                    "grantId": format!("sandbox-worker:{worker_id}"),
                    "parentGrantId": invocation.causal_context.authority_grant_id.as_str(),
                    "subjectWorkerId": worker_id,
                    "subjectInvocationId": invocation.id.as_str(),
                    "allowedCapabilities": expected,
                    "allowedNamespaces": invocation.payload.get("allowedNamespaces").cloned().unwrap_or_else(|| json!([namespace])),
                    "allowedAuthorityScopes": invocation.payload.get("allowedAuthorityScopes").cloned().unwrap_or_else(|| json!([])),
                    "allowedResourceKinds": invocation.payload.get("allowedResourceKinds").cloned().unwrap_or_else(|| json!([])),
                    "resourceSelectors": invocation.payload.get("resourceSelectors").cloned().unwrap_or_else(|| json!(["*"])),
                    "fileRoots": invocation.payload.get("fileRoots").cloned().unwrap_or_else(|| json!(["*"])),
                    "networkPolicy": invocation.payload.get("networkPolicy").cloned().unwrap_or_else(|| json!("none")),
                    "maxRisk": invocation.payload.get("maxRisk").cloned().unwrap_or_else(|| json!("medium")),
                    "budget": invocation.payload.get("budget").cloned().unwrap_or_else(|| json!({"class": "module_activation_test"})),
                    "approvalRequired": invocation.payload.get("approvalRequired").cloned().unwrap_or_else(|| json!(false)),
                    "provenance": {"source": "recording_worker_spawn_handler"}
                }),
                CausalContext::new(
                    actor("system"),
                    ActorKind::System,
                    invocation.causal_context.authority_grant_id.clone(),
                    invocation.causal_context.trace_id.clone(),
                )
                .with_idempotency_key(format!("derive-{worker_id}"))
                .with_scope("grant.write"),
            ))
            .await;
        assert_eq!(grant_result.error, None);
        let grant = grant_result.value.as_ref().unwrap()["grant"].clone();
        Ok(json!({
            "workerId": worker_id,
            "authorityGrantId": grant["grantId"],
            "authorityGrantRevision": grant["revision"],
            "processId": null,
            "registeredFunctionIds": expected,
            "catalogRevision": self.handle.catalog_revision().await.0,
            "visibility": invocation.payload.get("visibility").and_then(Value::as_str).unwrap_or("session"),
            "workerEndpoint": "test://recording-worker-spawn",
            "streamTopic": "sandbox.lifecycle"
        }))
    }
}

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

fn local_process_manifest(
    package_id: &str,
    namespace: &str,
    worker_id: &str,
    executable_ref: Value,
) -> Value {
    let mut manifest = package_manifest(package_id, namespace, worker_id);
    manifest["sourceProvenance"] = json!({"kind": "local_digest_pinned"});
    manifest["trustTier"] = json!("local_digest_pinned");
    manifest["signatureStatus"] = json!("unsigned_digest_pinned");
    manifest["declaredWorkerKind"] = json!("local_process");
    manifest["declaredFiles"] = json!([executable_ref.clone()]);
    manifest["runtimeEntryPoint"] = json!({
        "kind": "local_process",
        "workerId": worker_id,
        "commandTemplate": {
            "kind": "materialized_file",
            "resourceId": executable_ref["resourceId"],
            "versionId": executable_ref["versionId"]
        },
        "argsTemplate": [{"literal": "--stdio"}],
        "workingDirectory": {
            "kind": "package_file_parent",
            "resourceId": executable_ref["resourceId"],
            "versionId": executable_ref["versionId"]
        },
        "executableRefs": [executable_ref],
        "expectedFunctionIds": [
            format!("{namespace}::inspect"),
            format!("{namespace}::write_artifact")
        ],
        "environmentPolicy": {"mode": "empty"},
        "visibility": "session",
        "timeoutMs": 5000
    });
    manifest
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

async fn materialized_executable_ref(
    handle: &EngineHostHandle,
    path: &std::path::Path,
    key: &str,
) -> Value {
    let created = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": path.to_string_lossy(),
                "content": "#!/bin/sh\necho tron-local-process-worker\n"
            }),
            mutating_causal(key).with_scope("resource.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    created.value.as_ref().unwrap()["resourceRefs"][0].clone()
}

fn register_recording_worker_spawn(handle: &EngineHostHandle) -> Arc<std::sync::Mutex<Vec<Value>>> {
    let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
    handle
        .register_function_for_setup(
            write_function("worker::spawn", "worker")
                .with_required_authority(AuthorityRequirement::scope("worker.write")),
            Some(Arc::new(RecordingWorkerSpawnHandler {
                handle: handle.clone(),
                calls: calls.clone(),
            })),
            false,
        )
        .unwrap();
    calls
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

async fn activate_demo_package(
    handle: &EngineHostHandle,
    package_id: &str,
    namespace: &str,
    worker_id: &str,
    key_prefix: &str,
) -> (String, String, String) {
    register_demo_worker(handle, namespace, worker_id);
    let registered = register_package(
        handle,
        manifest_with_digest(package_manifest(package_id, namespace, worker_id)),
        &format!("{key_prefix}-register"),
    )
    .await;
    assert_eq!(registered.error, None);
    let package_resource_id = format!("worker-package:{package_id}");
    let package_version_id = registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
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
    let activated = handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": format!("module-config:workspace-a:{package_id}"),
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "workerId": worker_id,
                "childGrantRequest": {
                    "allowedCapabilities": [format!("{namespace}::inspect"), format!("{namespace}::write_artifact")],
                    "allowedNamespaces": [namespace],
                    "allowedAuthorityScopes": [format!("{namespace}.read"), format!("{namespace}.write")],
                    "allowedResourceKinds": ["artifact"],
                    "resourceSelectors": ["*"],
                    "fileRoots": ["*"],
                    "networkPolicy": "none",
                    "maxRisk": "medium"
                }
            }),
            mutating_causal(&format!("{key_prefix}-activate")).with_scope("module.write"),
        ))
        .await;
    assert_eq!(activated.error, None);
    let activation_resource_id = format!("activation:workspace-a:{package_id}");
    let activation_version_id = activated.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    (
        package_version_id,
        activation_resource_id,
        activation_version_id,
    )
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
        "module::check_health",
        "module::verify_integrity",
        "module::recover_activation",
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
    let child_ids =
        checked.value.as_ref().unwrap()["healthResult"]["diagnostics"]["childInvocationIds"]
            .as_array()
            .cloned()
            .unwrap_or_default();
    assert!(
        checked.value.as_ref().unwrap()["activation"]["payload"]["healthInvocationIds"]
            .as_array()
            .unwrap()
            .len()
            >= 2
    );
    assert_eq!(
        checked.value.as_ref().unwrap()["healthResult"]["status"],
        "healthy"
    );
    assert!(
        checked.value.as_ref().unwrap()["healthResult"]["diagnostics"]
            .to_string()
            .contains("invoke_health::health")
            || !child_ids.is_empty()
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
    let registered = register_package(
        &handle,
        manifest_with_digest(local_process_manifest(
            "demo-local-tools",
            "demo_local",
            "demo-local-worker",
            executable.clone(),
        )),
        "module-local-activate-register",
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
        "sandbox-worker:demo-local-worker"
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
