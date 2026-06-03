use super::*;
use sha2::{Digest, Sha256};

#[tokio::test]
async fn real_shared_mutation_contracts_declare_leases_and_compensation() {
    let mut domain_specs = Vec::new();
    domain_specs.extend(crate::domains::filesystem::contract::capabilities().unwrap());
    domain_specs.extend(crate::domains::process::contract::capabilities().unwrap());
    domain_specs.extend(crate::domains::worktree::contract::capabilities().unwrap());
    for spec in domain_specs
        .iter()
        .filter(|spec| spec.effect_class.is_mutating())
    {
        assert!(
            spec.resource_lease.is_some(),
            "{} must declare an engine resource lease",
            spec.function_id
        );
        let compensation = spec
            .compensation
            .as_ref()
            .unwrap_or_else(|| panic!("{} must declare compensation", spec.function_id));
        assert!(
            compensation.has_notes(),
            "{} compensation must include recovery notes",
            spec.function_id
        );
    }

    let handle = EngineHostHandle::new_in_memory().unwrap();
    let host = handle.lock().await;
    for function_id in module_write_functions()
        .into_iter()
        .chain(ui_write_functions())
    {
        let function = host
            .catalog()
            .function(&fid(function_id))
            .unwrap_or_else(|| panic!("{function_id} must be registered"));
        assert!(
            function.resource_lease.is_some(),
            "{function_id} must declare an engine resource lease"
        );
        let compensation = function
            .compensation
            .as_ref()
            .unwrap_or_else(|| panic!("{function_id} must declare compensation"));
        assert!(
            compensation.has_notes(),
            "{function_id} compensation must include recovery notes"
        );
    }
}

#[tokio::test]
async fn real_primitive_mutations_record_visible_leases_and_compensation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();

    register_demo_module_worker(&handle, "lease_demo", "lease-demo-worker");
    let module_result = handle
        .invoke(host_invocation(
            "module::register_package",
            json!({"manifest": manifest_with_digest(package_manifest(
                "lease-demo-tools",
                "lease_demo",
                "lease-demo-worker"
            ))}),
            mutating_causal("hmh-f5-module-register").with_scope("module.write"),
        ))
        .await;
    assert_eq!(module_result.error, None);
    assert_invocation_has_recovery_record(
        &handle,
        module_result.invocation_id.as_str(),
        "module::register_package",
    )
    .await;

    handle
        .register_worker_for_setup(worker("ui-lease-demo", "ui_lease_demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("ui_lease_demo::inspect", "ui-lease-demo")
                .with_required_authority(AuthorityRequirement::scope("ui_lease_demo.read")),
            Some(handler()),
            false,
        )
        .unwrap();
    let ui_result = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "hmh-f5-ui-surface",
                "surface": valid_ui_surface("ui_lease_demo::inspect", 1)
            }),
            mutating_causal("hmh-f5-ui-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(ui_result.error, None);
    assert_invocation_has_recovery_record(
        &handle,
        ui_result.invocation_id.as_str(),
        "ui::create_surface",
    )
    .await;

    drop(handle);
    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let compensation = reopened.list_compensation_records().await.unwrap();
    assert!(
        compensation.iter().any(
            |record| record.function_id == fid("module::register_package") && record.succeeded
        ),
        "module compensation record must survive reopen"
    );
    assert!(
        compensation
            .iter()
            .any(|record| record.function_id == fid("ui::create_surface") && record.succeeded),
        "ui compensation record must survive reopen"
    );
}

#[tokio::test]
async fn resource_lease_acquire_release_conflict_and_stream_records() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let first = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await
        .unwrap();
    assert_eq!(first.status, EngineResourceLeaseStatus::Active);
    assert_eq!(first.resource_kind, "session");
    assert_eq!(first.resource_id, "s1:model");

    let conflict = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await;
    assert!(matches!(
        conflict,
        Err(EngineError::PolicyViolation(message)) if message.contains("resource lease conflict")
    ));

    let released = handle
        .release_resource_lease(&first.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(released.status, EngineResourceLeaseStatus::Released);
    let released_again = handle
        .release_resource_lease(&first.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(released_again.status, EngineResourceLeaseStatus::Released);

    let second = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await
        .unwrap();
    assert_ne!(first.lease_id, second.lease_id);

    handle
        .subscribe_stream(
            "lease-sub".to_owned(),
            "resource.leases".to_owned(),
            StreamCursor(0),
            VisibilityScope::System,
            None,
            None,
        )
        .await
        .unwrap();
    let page = handle
        .poll_stream(
            "lease-sub",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::admin(),
        )
        .await
        .unwrap();
    let event_types = page
        .events
        .iter()
        .map(|event| event.payload["type"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(event_types.contains(&"resource_lease.acquired"));
    assert!(event_types.contains(&"resource_lease.released"));
}

#[tokio::test]
async fn resource_lease_expiry_and_sqlite_reopen_preserve_records() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    let first = handle
        .acquire_resource_lease(lease_request("import", "session.json", 1))
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    let second = handle
        .acquire_resource_lease(lease_request("import", "session.json", 30_000))
        .await
        .unwrap();
    assert_ne!(first.lease_id, second.lease_id);
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let loaded = reopened
        .get_resource_lease(&second.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(loaded.status, EngineResourceLeaseStatus::Active);
    assert_eq!(loaded.resource_kind, "import");
    assert_eq!(loaded.resource_id, "session.json");
    assert_eq!(loaded.function_id, fid("test::write"));
    assert_eq!(loaded.idempotency_key.as_deref(), Some("idem"));
}

#[tokio::test]
async fn host_invocation_enforces_resource_lease_and_records_compensation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"sessionId": "session-a", "value": 1}),
            mutating_causal("lease-key").with_scope("alpha.write"),
        ))
        .await;

    assert_eq!(result.error, None);
    let host = handle.lock().await;
    let record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| record.function_id == fid("alpha::write"))
        .unwrap();
    assert_eq!(record.resource_lease_ids.len(), 1);
    assert_eq!(record.compensation_status.as_deref(), Some("recorded"));
    let lease_id = record.resource_lease_ids[0].clone();
    drop(host);

    let lease = handle.get_resource_lease(&lease_id).await.unwrap().unwrap();
    assert_eq!(lease.status, EngineResourceLeaseStatus::Released);
    let compensation = handle.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert_eq!(compensation[0].resource_lease_ids, vec![lease_id]);
    assert!(compensation[0].succeeded);
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let compensation = reopened.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert_eq!(compensation[0].function_id, fid("alpha::write"));
}

#[tokio::test]
async fn resource_lease_template_uses_causal_session_when_payload_omits_session_id() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"value": 1}),
            mutating_causal("lease-context-key").with_scope("alpha.write"),
        ))
        .await;

    assert_eq!(result.error, None);
    let host = handle.lock().await;
    let record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| record.function_id == fid("alpha::write"))
        .unwrap();
    let lease_id = record.resource_lease_ids[0].clone();
    drop(host);

    let lease = handle.get_resource_lease(&lease_id).await.unwrap().unwrap();
    assert_eq!(lease.resource_id, "session:session-a:write");
}

#[tokio::test]
async fn resource_lease_template_rejects_payload_session_that_conflicts_with_causal_context() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"sessionId": "session-b", "value": 1}),
            mutating_causal("lease-context-conflict-key").with_scope("alpha.write"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("payload field sessionId does not match invocation context")
    ));
}

#[tokio::test]
async fn host_resource_lease_conflict_fails_before_handler_execution() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    handle
        .register_function_for_setup(
            write_function("alpha::locked", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:locked",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "lease conflict should be auditable",
                )),
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();
    let held = handle
        .acquire_resource_lease(lease_request("session", "session:session-a:locked", 30_000))
        .await
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::locked",
            json!({"sessionId": "session-a"}),
            mutating_causal("locked-key").with_scope("alpha.write"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("resource lease conflict")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let compensation = handle.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert!(!compensation[0].succeeded);
    let _ = handle.release_resource_lease(&held.lease_id).await.unwrap();
}

async fn assert_invocation_has_recovery_record(
    handle: &EngineHostHandle,
    invocation_id: &str,
    function_id: &str,
) {
    let host = handle.lock().await;
    let record = host
        .catalog()
        .invocations()
        .iter()
        .find(|record| record.invocation_id.as_str() == invocation_id)
        .unwrap_or_else(|| panic!("{function_id} invocation must be recorded"));
    assert_eq!(record.function_id, fid(function_id));
    assert!(
        matches!(
            record.compensation_status.as_deref(),
            Some("recorded") | Some("succeeded")
        ),
        "{function_id} invocation must expose compensation status"
    );
    assert_eq!(
        record.resource_lease_ids.len(),
        1,
        "{function_id} must record exactly one lease"
    );
    let lease_id = record.resource_lease_ids[0].clone();
    drop(host);

    let lease = handle.get_resource_lease(&lease_id).await.unwrap().unwrap();
    assert_eq!(lease.status, EngineResourceLeaseStatus::Released);
    assert_eq!(lease.function_id, fid(function_id));

    let compensation = handle.list_compensation_records().await.unwrap();
    assert!(
        compensation
            .iter()
            .any(|record| record.function_id == fid(function_id)
                && record.resource_lease_ids == vec![lease_id.clone()]
                && record.succeeded),
        "{function_id} must have a matching succeeded compensation record"
    );
}

fn module_write_functions() -> Vec<&'static str> {
    vec![
        "module::register_package",
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
        "module::run_conformance",
        "module::register_source",
        "module::verify_signature",
        "module::record_policy_audit",
        "module::reconcile_trust",
        "module::renew_trust_root",
        "module::rotate_signature_key",
        "module::expire_trust_decision",
        "module::enforce_revocation",
        "module::record_trust_review",
        "module::schedule_trust_audit",
        "module::run_scheduled_trust_audit",
        "module::record_trust_audit_retention",
    ]
}

fn ui_write_functions() -> Vec<&'static str> {
    vec![
        "ui::create_surface",
        "ui::surface_for_target",
        "ui::update_surface",
        "ui::refresh_surface",
        "ui::expire_surface",
        "ui::discard_surface",
        "ui::submit_action",
    ]
}

fn register_demo_module_worker(handle: &EngineHostHandle, namespace: &str, worker_id: &str) {
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
                    "resourceId": "artifact-from-hmh-f5",
                    "kind": "artifact",
                    "versionId": "ver-artifact-from-hmh-f5",
                    "role": "created",
                    "contentHash": "sha256:artifact"
                }]
            })))),
            false,
        )
        .unwrap();
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
