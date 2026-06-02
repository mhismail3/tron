//! Module package activation engine tests.
//!
//! This parent module owns shared fixtures. Concern modules below own package
//! registration, local-process activation, lifecycle controls, source trust,
//! health/integrity, trust-review, and generated operator-surface behavior.

use super::*;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD};
use ed25519_dalek::{Signer, SigningKey};
use sha2::{Digest, Sha256};

mod health_integrity;
mod lifecycle_controls;
mod local_process_activation;
mod operator_surfaces;
mod package_registration;
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
                .with_idempotency_key(format!("derive-{worker_id}-{}", invocation.id.as_str()))
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
