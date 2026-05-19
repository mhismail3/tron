use super::*;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use ed25519_dalek::{Signer, SigningKey};
use sha2::{Digest, Sha256};

mod health_integrity;
mod source_trust;
mod trust_review;

#[derive(Clone)]
struct RecordingWorkerSpawnHandler {
    handle: EngineHostHandle,
    calls: Arc<std::sync::Mutex<Vec<Value>>>,
    behavior: RecordingWorkerSpawnBehavior,
}

#[derive(Clone, Copy)]
enum RecordingWorkerSpawnBehavior {
    Success,
    SpawnError,
    FailOnceThenSuccess,
    MissingRegistration,
    OverbroadRegistration,
}

#[async_trait]
impl InProcessFunctionHandler for RecordingWorkerSpawnHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let call_count = {
            let mut calls = self.calls.lock().expect("recording spawn calls lock");
            calls.push(invocation.payload.clone());
            calls.len()
        };
        if matches!(
            self.behavior,
            RecordingWorkerSpawnBehavior::FailOnceThenSuccess
        ) && call_count == 1
        {
            return Err(EngineError::HandlerFailed(
                "recording worker spawn transient failure".to_owned(),
            ));
        }
        if matches!(self.behavior, RecordingWorkerSpawnBehavior::SpawnError) {
            return Err(EngineError::HandlerFailed(
                "recording worker spawn failure".to_owned(),
            ));
        }
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
        if !matches!(
            self.behavior,
            RecordingWorkerSpawnBehavior::MissingRegistration
        ) {
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
            if matches!(
                self.behavior,
                RecordingWorkerSpawnBehavior::OverbroadRegistration
            ) {
                self.handle
                    .register_function(
                        read_function(&format!("{namespace}::undeclared"), worker_id)
                            .with_required_authority(AuthorityRequirement::scope(format!(
                                "{namespace}.read"
                            ))),
                        Some(handler()),
                        true,
                    )
                    .await?;
            }
        }
        let grant_result = self
            .handle
            .invoke(host_invocation(
                "grant::derive",
                json!({
                    "grantId": invocation
                        .payload
                        .get("grantId")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| format!("sandbox-worker:{worker_id}")),
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

struct RecordingSandboxStopHandler {
    handle: EngineHostHandle,
    calls: Arc<std::sync::Mutex<Vec<Value>>>,
    fail: bool,
}

#[async_trait]
impl InProcessFunctionHandler for RecordingSandboxStopHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        self.calls
            .lock()
            .expect("recording sandbox stop calls lock")
            .push(invocation.payload.clone());
        if self.fail {
            return Err(EngineError::HandlerFailed(
                "recording sandbox stop failure".to_owned(),
            ));
        }
        let worker_id = invocation.payload["workerId"]
            .as_str()
            .expect("sandbox stop payload has workerId");
        if let Ok(worker_id) = WorkerId::new(worker_id.to_owned())
            && let Ok(worker) = self.handle.inspect_worker(&worker_id).await
        {
            self.handle
                .unregister_worker(&worker_id, worker.owner_actor.as_str())
                .await?;
        }
        Ok(json!({"status": "stopped"}))
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
        for field in [
            "packageDigest",
            "sourceRef",
            "sourceDigest",
            "sourceTrustStatus",
            "effectiveTrustTier",
            "signature",
            "signatureKeyRef",
            "signatureVerification",
            "sourceEvidenceRefs",
            "sourceApprovalRefs",
            "conformanceEvidenceRefs",
            "policyDiagnostics",
        ] {
            object.remove(field);
        }
    }
    let bytes = serde_json::to_vec(&canonical).unwrap();
    format!("sha256:{:x}", Sha256::digest(bytes))
}

fn signing_fixture() -> (SigningKey, String, String) {
    signing_fixture_with_seed(7)
}

fn signing_fixture_with_seed(seed: u8) -> (SigningKey, String, String) {
    let signing_key = SigningKey::from_bytes(&[seed; 32]);
    let public_key = signing_key.verifying_key().to_bytes();
    let key_id = format!("ed25519:{:x}", Sha256::digest(public_key));
    (signing_key, BASE64_STANDARD.encode(public_key), key_id)
}

fn signed_package_manifest(mut manifest: Value, signing_key: &SigningKey, key_id: &str) -> Value {
    let digest = manifest_digest(&manifest);
    let message = format!("tron.module.package_manifest.v1\n{digest}");
    let signature = signing_key.sign(message.as_bytes());
    manifest["packageDigest"] = json!(digest);
    manifest["signature"] = json!({
        "algorithm": "ed25519",
        "value": format!("base64:{}", BASE64_STANDARD.encode(signature.to_bytes()))
    });
    manifest["signatureKeyRef"] = json!(format!("trust-root:{key_id}"));
    manifest
}

fn grant_ceiling_for_namespace(namespace: &str) -> Value {
    json!({
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
    })
}

async fn register_trust_root(
    handle: &EngineHostHandle,
    public_key: &str,
    key_id: &str,
    selector: &str,
    namespace: &str,
    key: &str,
) -> super::super::InvocationResult {
    handle
        .invoke(host_invocation(
            "module::register_source",
            json!({
                "sourceKind": "ed25519_trust_root",
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "algorithm": "ed25519",
                "publicKey": format!("base64:{public_key}"),
                "keyId": key_id,
                "allowedPackageSelectors": [selector],
                "trustTierCeiling": "signed_local",
                "grantCeiling": grant_ceiling_for_namespace(namespace),
                "expiresAt": "2100-01-01T00:00:00Z",
                "reason": "test registers local Ed25519 trust root"
            }),
            mutating_causal(key).with_scope("module.write"),
        ))
        .await
}

async fn verify_signature(
    handle: &EngineHostHandle,
    package_resource_id: &str,
    package_version_id: &str,
    key: &str,
) -> super::super::InvocationResult {
    handle
        .invoke(host_invocation(
            "module::verify_signature",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "expectedCurrentVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a"
            }),
            mutating_causal(key).with_scope("module.write"),
        ))
        .await
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

async fn inspect_resource(handle: &EngineHostHandle, resource_id: &str) -> Value {
    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    inspected.value.unwrap()["inspection"].clone()
}

fn register_recording_worker_spawn(handle: &EngineHostHandle) -> Arc<std::sync::Mutex<Vec<Value>>> {
    register_recording_worker_spawn_with_behavior(handle, RecordingWorkerSpawnBehavior::Success)
}

fn register_recording_worker_spawn_with_behavior(
    handle: &EngineHostHandle,
    behavior: RecordingWorkerSpawnBehavior,
) -> Arc<std::sync::Mutex<Vec<Value>>> {
    let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
    handle
        .register_function_for_setup(
            write_function("worker::spawn", "worker")
                .with_required_authority(AuthorityRequirement::scope("worker.write")),
            Some(Arc::new(RecordingWorkerSpawnHandler {
                handle: handle.clone(),
                calls: calls.clone(),
                behavior,
            })),
            false,
        )
        .unwrap();
    calls
}

fn register_recording_sandbox_stop(handle: &EngineHostHandle) -> Arc<std::sync::Mutex<Vec<Value>>> {
    register_recording_sandbox_stop_with_behavior(handle, false)
}

fn register_recording_sandbox_stop_with_behavior(
    handle: &EngineHostHandle,
    fail: bool,
) -> Arc<std::sync::Mutex<Vec<Value>>> {
    let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
    handle
        .register_worker_for_setup(worker("sandbox", "sandbox"), true)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("sandbox::stop_spawned_worker", "sandbox")
                .with_required_authority(AuthorityRequirement::scope("sandbox.write")),
            Some(Arc::new(RecordingSandboxStopHandler {
                handle: handle.clone(),
                calls: calls.clone(),
                fail,
            })),
            true,
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

async fn verify_source(
    handle: &EngineHostHandle,
    package_resource_id: &str,
    package_version_id: &str,
    key: &str,
) -> super::super::InvocationResult {
    handle
        .invoke(host_invocation(
            "module::verify_source",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "expectedCurrentVersionId": package_version_id,
                "mode": "on_demand"
            }),
            mutating_causal(key).with_scope("module.write"),
        ))
        .await
}

async fn approve_source(
    handle: &EngineHostHandle,
    package_resource_id: &str,
    package_version_id: &str,
    package_digest: &str,
    package_id: &str,
    key: &str,
) -> super::super::InvocationResult {
    handle
        .invoke(host_invocation(
            "module::approve_source",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "packageDigest": package_digest,
                "packageId": package_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "trustTierCeiling": "local_digest_pinned",
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
                "expiresAt": "2100-01-01T00:00:00Z",
                "reason": "test approves digest-pinned local worker"
            }),
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
                grant("engine-system"),
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

async fn grant_lifecycle(handle: &EngineHostHandle, grant_id: &str) -> Option<String> {
    let result = handle
        .invoke(host_invocation(
            "grant::inspect",
            json!({"grantId": grant_id}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("engine-system"),
                trace("trace"),
            )
            .with_scope("grant.read"),
        ))
        .await;
    assert_eq!(result.error, None);
    result.value.as_ref().unwrap()["grant"]["lifecycle"]
        .as_str()
        .map(ToOwned::to_owned)
}

async fn worker_is_registered(handle: &EngineHostHandle, worker_id: &str) -> bool {
    handle
        .inspect_worker(&WorkerId::new(worker_id.to_owned()).unwrap())
        .await
        .is_ok()
}

async fn resource_count(handle: &EngineHostHandle, kind: &str) -> usize {
    let result = handle
        .invoke(host_invocation(
            "resource::list",
            json!({"kind": kind, "limit": 500}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(result.error, None);
    result.value.as_ref().unwrap()["resources"]
        .as_array()
        .unwrap()
        .len()
}

async fn queue_count(handle: &EngineHostHandle, queue: &str) -> usize {
    let result = handle
        .invoke(host_invocation(
            "queue::list",
            json!({"queue": queue, "limit": 500}),
            causal().with_scope("queue.read"),
        ))
        .await;
    assert_eq!(result.error, None);
    result.value.as_ref().unwrap()["items"]
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

async fn local_process_activate_payload(
    handle: &EngineHostHandle,
    package_id: &str,
    worker_id: &str,
    key_prefix: &str,
) -> Value {
    let tmp = tempfile::tempdir().unwrap();
    let executable = materialized_executable_ref(
        handle,
        &tmp.path().join(format!("{worker_id}.sh")),
        &format!("{key_prefix}-executable"),
    )
    .await;
    let manifest = manifest_with_digest(local_process_manifest(
        package_id,
        "demo_local",
        worker_id,
        executable,
    ));
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

    json!({
        "packageResourceId": format!("worker-package:{package_id}"),
        "packageVersionId": package_version_id,
        "moduleConfigResourceId": format!("module-config:workspace-a:{package_id}"),
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
    })
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
    let (_signing_key, public_key, key_id) = signing_fixture();
    let trust_root = register_trust_root(
        &handle,
        &public_key,
        &key_id,
        "demo-tools",
        "demo",
        "module-ui-trust-root",
    )
    .await;
    assert_eq!(trust_root.error, None);
    let trust_root_decision_id =
        trust_root.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
            .as_str()
            .unwrap()
            .to_owned();

    for (target_type, target_id) in [
        ("package", "demo-tools"),
        ("resource", "worker-package:demo-tools"),
        ("decision", trust_root_decision_id.as_str()),
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
        if target_type == "package" {
            for function_id in [
                "module::verify_source",
                "module::run_conformance",
                "module::simulate_trust_change",
                "module::record_trust_review",
                "module::schedule_trust_audit",
            ] {
                assert!(
                    surface.value.as_ref().unwrap()["surface"]["actions"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|action| action["targetFunctionId"] == function_id),
                    "package surface must expose {function_id}"
                );
            }
        }
        if target_type == "decision" {
            for function_id in [
                "module::inspect_trust",
                "module::simulate_trust_change",
                "module::record_trust_review",
                "module::renew_trust_root",
                "module::rotate_signature_key",
                "module::expire_trust_decision",
                "module::enforce_revocation",
            ] {
                assert!(
                    surface.value.as_ref().unwrap()["surface"]["actions"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|action| action["targetFunctionId"] == function_id),
                    "decision trust surface must expose {function_id}"
                );
            }
        }
    }

    let scheduled = handle
        .invoke(host_invocation(
            "module::schedule_trust_audit",
            json!({
                "scheduleId": "ui-schedule",
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "selectors": ["demo-tools"],
                "cadence": "daily",
                "timezone": "UTC",
                "wallClockTime": "00:00",
                "expiresAt": "2100-01-01T00:00:00Z",
                "grantCeiling": grant_ceiling_for_namespace("demo"),
                "reason": "generate schedule surface"
            }),
            mutating_causal("module-ui-schedule-audit").with_scope("module.write"),
        ))
        .await;
    assert_eq!(scheduled.error, None);
    let schedule_decision_id = scheduled.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "decision")
        .unwrap()["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let surface = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_surface_request("decision", &schedule_decision_id),
            mutating_causal("module-ui-schedule-decision").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(surface.error, None);
    for function_id in [
        "module::trust_audit_status",
        "module::run_scheduled_trust_audit",
        "module::record_trust_audit_retention",
        "module::expire_trust_decision",
    ] {
        assert!(
            surface.value.as_ref().unwrap()["surface"]["actions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|action| action["targetFunctionId"] == function_id),
            "schedule trust surface must expose {function_id}"
        );
    }
}
