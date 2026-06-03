//! Product example-pack tests for TPROD-J.

use super::*;

use std::collections::BTreeMap;
use std::path::Path;

use crate::engine::InvocationResult;

#[derive(Clone)]
struct ExamplePackSpec {
    slug: &'static str,
    package_id: &'static str,
    namespace: &'static str,
    worker_id: &'static str,
    category: &'static str,
    config: Value,
}

#[derive(Clone)]
struct ExampleCapabilitySpec {
    function_id: String,
    description: String,
    effect: EffectClass,
    risk: RiskLevel,
    required_authority: Vec<String>,
    output_resource_kinds: Vec<String>,
}

#[derive(Clone)]
struct ExamplePackSpawnHandler {
    handle: EngineHostHandle,
    calls: Arc<std::sync::Mutex<Vec<Value>>>,
    specs: Arc<std::sync::Mutex<BTreeMap<String, Vec<ExampleCapabilitySpec>>>>,
}

#[async_trait]
impl InProcessFunctionHandler for ExamplePackSpawnHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        self.calls
            .lock()
            .expect("example pack spawn calls")
            .push(invocation.payload.clone());
        let worker_id = invocation.payload["workerId"]
            .as_str()
            .expect("example pack spawn payload has workerId");
        let expected = invocation.payload["expectedFunctionIds"]
            .as_array()
            .expect("example pack spawn payload has expectedFunctionIds")
            .iter()
            .map(|value| value.as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        let namespace = expected
            .first()
            .and_then(|function_id| function_id.split_once("::").map(|(namespace, _)| namespace))
            .expect("example pack function id has namespace");
        let specs = self
            .specs
            .lock()
            .expect("example pack spawn specs")
            .get(worker_id)
            .cloned()
            .unwrap_or_else(|| panic!("missing example pack specs for worker {worker_id}"));
        self.handle
            .register_worker(worker(worker_id, namespace), true)
            .await?;
        for spec in specs {
            assert!(
                expected
                    .iter()
                    .any(|function_id| function_id == &spec.function_id),
                "spawn expected ids must include {}",
                spec.function_id
            );
            let mut definition = FunctionDefinition::new(
                fid(&spec.function_id),
                wid(worker_id),
                spec.description,
                VisibilityScope::Agent,
                spec.effect,
            )
            .with_required_authority(AuthorityRequirement {
                scopes: spec.required_authority.clone(),
                approval_required: false,
            })
            .with_risk(spec.risk);
            if spec.effect.requires_idempotency() {
                definition = definition
                    .with_idempotency(IdempotencyContract::caller_session_engine_ledger());
            }
            let handler: Arc<dyn InProcessFunctionHandler> = if spec
                .output_resource_kinds
                .is_empty()
            {
                handler()
            } else {
                definition =
                    definition.with_output_contract(DurableOutputContract::resource_backed(
                        spec.output_resource_kinds.iter().cloned(),
                    ));
                Arc::new(StaticValueHandler(json!({
                    "resourceRefs": spec.output_resource_kinds.iter().map(|kind| {
                        json!({
                            "resourceId": format!("{kind}:example:{}", spec.function_id.replace("::", ":")),
                            "kind": kind,
                            "versionId": format!("ver-example-{}", spec.function_id.replace("::", "-")),
                            "role": "created",
                            "contentHash": format!("sha256:{}", spec.function_id.replace("::", "-"))
                        })
                    }).collect::<Vec<_>>()
                })))
            };
            self.handle
                .register_function(definition, Some(handler), true)
                .await?;
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
                    "budget": invocation.payload.get("budget").cloned().unwrap_or_else(|| json!({"class": "tprod_j_example_pack"})),
                    "approvalRequired": invocation.payload.get("approvalRequired").cloned().unwrap_or_else(|| json!(false)),
                    "provenance": {"source": "tprod_j_example_pack_spawn"}
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
            "registeredFunctionIds": invocation.payload["expectedFunctionIds"],
            "catalogRevision": self.handle.catalog_revision().await.0,
            "visibility": invocation.payload.get("visibility").and_then(Value::as_str).unwrap_or("workspace"),
            "workerEndpoint": "test://tprod-j-example-pack",
            "streamTopic": "sandbox.lifecycle"
        }))
    }
}

#[tokio::test]
async fn tprod_j_local_example_packs_register_activate_and_author_generated_ui() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/local-packs");
    let packs = example_pack_specs();
    assert_local_pack_files_are_polished(&root, &packs);

    let handle = EngineHostHandle::new_in_memory().unwrap();
    let spawn_specs = Arc::new(std::sync::Mutex::new(BTreeMap::new()));
    let spawn_calls = register_example_pack_spawn(&handle, spawn_specs.clone());
    let tmp = tempfile::tempdir().unwrap();
    let runtime_ref = materialize_example_file(
        &handle,
        &root.join("pack_runtime.py"),
        &tmp.path().join("pack_runtime.py"),
        "tprod-j-pack-runtime",
    )
    .await;

    for pack in &packs {
        let worker_ref = materialize_example_file(
            &handle,
            &root.join(pack.slug).join("worker.py"),
            &tmp.path().join(pack.slug).join("worker.py"),
            &format!("tprod-j-{}-worker", pack.slug),
        )
        .await;
        let manifest = rendered_example_manifest(&root, pack.slug, &worker_ref, &runtime_ref);
        assert_eq!(manifest["packageId"], pack.package_id);
        assert_eq!(manifest["namespace"], pack.namespace);
        assert_eq!(manifest["sourceProvenance"]["kind"], "local_digest_pinned");
        assert_eq!(manifest["presentation"]["category"], pack.category);
        assert_eq!(manifest["presentation"]["generatedUiTarget"], "package");
        let capabilities = capability_specs_from_manifest(&manifest);
        assert_eq!(
            capabilities.len(),
            3,
            "{} must have three functions",
            pack.slug
        );
        spawn_specs
            .lock()
            .expect("example spawn specs")
            .insert(pack.worker_id.to_owned(), capabilities.clone());

        let package_resource_id = format!("worker-package:{}", pack.package_id);
        let registered = register_package(
            &handle,
            manifest.clone(),
            &format!("tprod-j-{}-register", pack.slug),
        )
        .await;
        assert_eq!(registered.error, None);
        let registered_version_id =
            registered.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
                .as_str()
                .unwrap()
                .to_owned();
        let verified = verify_source(
            &handle,
            &package_resource_id,
            &registered_version_id,
            &format!("tprod-j-{}-verify-source", pack.slug),
        )
        .await;
        assert_eq!(verified.error, None);
        let package_version_id = package_version_id_from(&verified);
        let conformance = run_example_pack_conformance(
            &handle,
            &package_resource_id,
            &package_version_id,
            pack.slug,
            manifest["requiredGrants"].clone(),
        )
        .await;
        assert_eq!(conformance["conformance"]["status"], "valid");
        let conformed_version_id = package_version_id_from_value(&conformance);
        let approved = approve_example_source(
            &handle,
            &package_resource_id,
            &conformed_version_id,
            manifest["packageDigest"].as_str().unwrap(),
            pack,
            manifest["requiredGrants"].clone(),
        )
        .await;
        assert_eq!(approved.error, None);

        let configured =
            configure_example_pack(&handle, &package_resource_id, &conformed_version_id, pack)
                .await;
        assert_eq!(configured.error, None);
        let config_version_id = configured.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
            .as_str()
            .unwrap()
            .to_owned();
        let activated = activate_example_pack(
            &handle,
            &package_resource_id,
            &conformed_version_id,
            &config_version_id,
            pack,
            manifest["requiredGrants"].clone(),
        )
        .await;
        assert_eq!(activated.error, None);
        assert_eq!(
            activated.value.as_ref().unwrap()["activation"]["payload"]["activationStatus"],
            "active"
        );
        assert_eq!(
            activated.value.as_ref().unwrap()["activation"]["payload"]["spawnResult"]["workerId"],
            pack.worker_id
        );

        let inspection = handle
            .invoke(host_invocation(
                "module::inspect_package",
                json!({"packageId": pack.package_id}),
                causal().with_scope("module.read"),
            ))
            .await;
        assert_eq!(inspection.error, None);
        let diagnostics = &inspection.value.as_ref().unwrap()["diagnostics"];
        assert_eq!(diagnostics["digestStatus"], "valid");
        assert_eq!(diagnostics["fileHashStatus"], "valid");
        assert_eq!(diagnostics["configStatus"], "configured");
        assert_eq!(diagnostics["activationStatus"], "active");
        assert_eq!(diagnostics["registeredCapabilityStatus"], "valid");

        let first_function = capabilities
            .iter()
            .find(|capability| !capability.effect.requires_idempotency())
            .expect("example pack has a read/compute function");
        let invoked = handle
            .invoke(host_invocation(
                &first_function.function_id,
                json!({"probe": "tprod-j"}),
                causal().with_scope(format!("{}.read", pack.namespace)),
            ))
            .await;
        assert_eq!(invoked.error, None);
        assert_eq!(invoked.value.as_ref().unwrap()["echo"]["probe"], "tprod-j");

        let surface = handle
            .invoke(host_invocation(
                "ui::surface_for_target",
                generated_surface_request("package", pack.package_id),
                mutating_causal(&format!("tprod-j-{}-surface", pack.slug)).with_scope("ui.write"),
            ))
            .await;
        assert_eq!(surface.error, None);
        let surface_value = surface.value.as_ref().unwrap();
        assert_eq!(
            surface_value["surface"]["title"],
            format!("Pack {}", pack.package_id)
        );
        assert_eq!(surface_value["resourceRefs"][0]["kind"], "ui_surface");
        for action in [
            "module::inspect_package",
            "module::configure",
            "module::activate",
            "module::run_conformance",
            "module::remove_package",
        ] {
            assert!(
                surface_value["surface"]["actions"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|candidate| candidate["targetFunctionId"] == action),
                "{} package surface missing {action}",
                pack.slug
            );
        }
    }
    assert_eq!(spawn_calls.lock().expect("spawn calls").len(), packs.len());
}

fn example_pack_specs() -> Vec<ExamplePackSpec> {
    vec![
        ExamplePackSpec {
            slug: "tron-maintainer",
            package_id: "tron-maintainer-example",
            namespace: "tron_maintainer_example",
            worker_id: "tron-maintainer-example-worker",
            category: "tron-maintainer",
            config: json!({
                "enabled": true,
                "repoPath": ".",
                "scorecardPath": "packages/agent/docs/tron-productization-scorecard.md",
                "evidencePath": "packages/agent/docs/tron-productization-evidence-manifest.md"
            }),
        },
        ExamplePackSpec {
            slug: "everyday-organizer",
            package_id: "everyday-organizer-example",
            namespace: "everyday_organizer_example",
            worker_id: "everyday-organizer-example-worker",
            category: "everyday-organizer",
            config: json!({
                "enabled": true,
                "digestFolder": "local-digests",
                "notifyOnCompletion": true
            }),
        },
        ExamplePackSpec {
            slug: "creative-knowledge",
            package_id: "creative-knowledge-example",
            namespace: "creative_knowledge_example",
            worker_id: "creative-knowledge-example-worker",
            category: "creative-knowledge",
            config: json!({
                "enabled": true,
                "defaultStyle": "clear",
                "saveTransformArtifacts": true
            }),
        },
    ]
}

fn assert_local_pack_files_are_polished(root: &Path, packs: &[ExamplePackSpec]) {
    let root_readme = std::fs::read_to_string(root.join("README.md")).expect("root README");
    assert!(root_readme.contains("local-only Tron package workflows"));
    assert!(root_readme.contains("remote package discovery"));
    let runtime = std::fs::read_to_string(root.join("pack_runtime.py")).expect("pack runtime");
    assert!(runtime.contains("TRON_ENGINE_WORKER_ENDPOINT"));
    assert!(
        !runtime.contains("http://") && !runtime.contains("https://"),
        "shared runtime must not contain remote package URLs"
    );
    for pack in packs {
        let pack_root = root.join(pack.slug);
        let readme = std::fs::read_to_string(pack_root.join("README.md"))
            .unwrap_or_else(|_| panic!("{} README missing", pack.slug));
        let manifest = std::fs::read_to_string(pack_root.join("manifest.template.json"))
            .unwrap_or_else(|_| panic!("{} manifest template missing", pack.slug));
        let worker = std::fs::read_to_string(pack_root.join("worker.py"))
            .unwrap_or_else(|_| panic!("{} worker missing", pack.slug));
        for content in [&readme, &manifest, &worker] {
            assert!(
                !content.contains("http://") && !content.contains("https://"),
                "{} must not contain remote package URLs",
                pack.slug
            );
            assert!(
                !content.contains('@'),
                "{} must not contain email-like personal info literals",
                pack.slug
            );
        }
        assert!(readme.contains("Generated UI target"));
        assert!(manifest.contains("\"kind\": \"local_digest_pinned\""));
        assert!(manifest.contains("\"__PACKAGE_DIGEST__\""));
        assert!(worker.contains("run_pack_worker"));
        assert!(worker.contains(pack.namespace));
    }
}

async fn materialize_example_file(
    handle: &EngineHostHandle,
    source_path: &Path,
    dest_path: &Path,
    key: &str,
) -> Value {
    if let Some(parent) = dest_path.parent() {
        std::fs::create_dir_all(parent).expect("create example pack temp dir");
    }
    let content = std::fs::read_to_string(source_path)
        .unwrap_or_else(|_| panic!("read example source {}", source_path.display()));
    let created = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": dest_path.to_string_lossy(),
                "content": content
            }),
            mutating_causal(key).with_scope("resource.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    created.value.as_ref().unwrap()["resourceRefs"][0].clone()
}

fn rendered_example_manifest(
    root: &Path,
    slug: &str,
    worker_ref: &Value,
    runtime_ref: &Value,
) -> Value {
    let template = std::fs::read_to_string(root.join(slug).join("manifest.template.json"))
        .unwrap_or_else(|_| panic!("read {slug} manifest template"));
    let rendered = replace_ref_placeholders(
        replace_ref_placeholders(template, "WORKER", worker_ref),
        "RUNTIME",
        runtime_ref,
    );
    let mut manifest: Value = serde_json::from_str(&rendered)
        .unwrap_or_else(|error| panic!("parse rendered {slug} manifest: {error}"));
    manifest = manifest_with_digest(manifest);
    assert!(
        !manifest.to_string().contains("__"),
        "{slug} manifest still contains placeholders"
    );
    manifest
}

fn replace_ref_placeholders(mut template: String, prefix: &str, reference: &Value) -> String {
    for (field, value) in [
        ("RESOURCE_ID", reference["resourceId"].as_str().unwrap()),
        ("VERSION_ID", reference["versionId"].as_str().unwrap()),
        ("CONTENT_HASH", reference["contentHash"].as_str().unwrap()),
    ] {
        template = template.replace(&format!("__{prefix}_{field}__"), value);
    }
    template
}

fn capability_specs_from_manifest(manifest: &Value) -> Vec<ExampleCapabilitySpec> {
    manifest["declaredCapabilities"]
        .as_array()
        .unwrap()
        .iter()
        .map(|capability| ExampleCapabilitySpec {
            function_id: capability["functionId"].as_str().unwrap().to_owned(),
            description: capability["displayName"].as_str().unwrap().to_owned(),
            effect: parse_example_effect(capability["effectClass"].as_str().unwrap()),
            risk: parse_example_risk(capability["risk"].as_str().unwrap()),
            required_authority: capability["requiredAuthority"]
                .as_array()
                .unwrap()
                .iter()
                .map(|scope| scope.as_str().unwrap().to_owned())
                .collect(),
            output_resource_kinds: capability["outputResourceKinds"]
                .as_array()
                .unwrap()
                .iter()
                .map(|kind| kind.as_str().unwrap().to_owned())
                .collect(),
        })
        .collect()
}

fn parse_example_effect(value: &str) -> EffectClass {
    match value {
        "PureRead" | "pure_read" => EffectClass::PureRead,
        "DeterministicCompute" | "deterministic_compute" => EffectClass::DeterministicCompute,
        "IdempotentWrite" | "idempotent_write" => EffectClass::IdempotentWrite,
        "ExternalSideEffect" | "external_side_effect" => EffectClass::ExternalSideEffect,
        other => panic!("unsupported example effect {other}"),
    }
}

fn parse_example_risk(value: &str) -> RiskLevel {
    match value {
        "low" | "Low" => RiskLevel::Low,
        "medium" | "Medium" => RiskLevel::Medium,
        "high" | "High" => RiskLevel::High,
        other => panic!("unsupported example risk {other}"),
    }
}

fn register_example_pack_spawn(
    handle: &EngineHostHandle,
    specs: Arc<std::sync::Mutex<BTreeMap<String, Vec<ExampleCapabilitySpec>>>>,
) -> Arc<std::sync::Mutex<Vec<Value>>> {
    let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
    handle
        .register_function_for_setup(
            write_function("worker::spawn", "worker")
                .with_required_authority(AuthorityRequirement::scope("worker.write")),
            Some(Arc::new(ExamplePackSpawnHandler {
                handle: handle.clone(),
                calls: calls.clone(),
                specs,
            })),
            false,
        )
        .unwrap();
    calls
}

fn package_version_id_from(result: &InvocationResult) -> String {
    package_version_id_from_value(result.value.as_ref().unwrap())
}

fn package_version_id_from_value(value: &Value) -> String {
    value["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"] == "worker_package")
        .unwrap()["versionId"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn run_example_pack_conformance(
    handle: &EngineHostHandle,
    package_resource_id: &str,
    package_version_id: &str,
    slug: &str,
    grant_request: Value,
) -> Value {
    let result = handle
        .invoke(host_invocation(
            "module::run_conformance",
            json!({
                "targetType": "worker_package",
                "resourceId": package_resource_id,
                "resourceVersionId": package_version_id,
                "expectedCurrentVersionId": package_version_id,
                "mode": "activation",
                "childGrantRequest": grant_request
            }),
            mutating_causal(&format!("tprod-j-{slug}-conformance")).with_scope("module.write"),
        ))
        .await;
    assert_eq!(result.error, None);
    result.value.unwrap()
}

async fn approve_example_source(
    handle: &EngineHostHandle,
    package_resource_id: &str,
    package_version_id: &str,
    package_digest: &str,
    pack: &ExamplePackSpec,
    grant_ceiling: Value,
) -> InvocationResult {
    handle
        .invoke(host_invocation(
            "module::approve_source",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "packageDigest": package_digest,
                "packageId": pack.package_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "trustTierCeiling": "local_digest_pinned",
                "grantCeiling": grant_ceiling,
                "expiresAt": "2100-01-01T00:00:00Z",
                "reason": format!("approve local TPROD-J example pack {}", pack.slug)
            }),
            mutating_causal(&format!("tprod-j-{}-approve-source", pack.slug))
                .with_scope("module.write"),
        ))
        .await
}

async fn configure_example_pack(
    handle: &EngineHostHandle,
    package_resource_id: &str,
    package_version_id: &str,
    pack: &ExamplePackSpec,
) -> InvocationResult {
    handle
        .invoke(host_invocation(
            "module::configure",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "config": pack.config
            }),
            mutating_causal(&format!("tprod-j-{}-configure", pack.slug)).with_scope("module.write"),
        ))
        .await
}

async fn activate_example_pack(
    handle: &EngineHostHandle,
    package_resource_id: &str,
    package_version_id: &str,
    config_version_id: &str,
    pack: &ExamplePackSpec,
    grant_request: Value,
) -> InvocationResult {
    handle
        .invoke(host_invocation(
            "module::activate",
            json!({
                "packageResourceId": package_resource_id,
                "packageVersionId": package_version_id,
                "moduleConfigResourceId": format!("module-config:workspace-a:{}", pack.package_id),
                "configVersionId": config_version_id,
                "scope": "workspace",
                "workspaceId": "workspace-a",
                "childGrantRequest": grant_request
            }),
            mutating_causal(&format!("tprod-j-{}-activate", pack.slug)).with_scope("module.write"),
        ))
        .await
}
