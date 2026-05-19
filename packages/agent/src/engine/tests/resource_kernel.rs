use super::*;
use crate::engine::resources::{
    CreateResource, EngineResourceLocation, EngineResourceScope, EngineResourceVersionState,
    InMemoryEngineResourceStore, LinkResources, UpdateResource, builtin_resource_type_definitions,
};

#[test]
fn resource_kernel_builtin_definitions_keep_core_kinds_and_relations() {
    let definitions = builtin_resource_type_definitions();
    for required in [
        "artifact",
        "goal",
        "decision",
        "claim",
        "evidence",
        "ui_surface",
        "materialized_file",
        "patch_proposal",
        "execution_output",
        "agent_result",
        "worker_package",
        "module_config",
        "activation_record",
    ] {
        assert!(
            definitions
                .iter()
                .any(|definition| definition.kind == required),
            "built-in resource kind `{required}` must stay registered"
        );
    }
    let decision = definitions
        .iter()
        .find(|definition| definition.kind == "decision")
        .unwrap();
    for relation in [
        "trusts_source",
        "verifies_signature",
        "affects_package",
        "affects_activation",
        "revokes",
        "supersedes",
        "enforces_revocation",
    ] {
        assert!(
            decision
                .allowed_link_relations
                .iter()
                .any(|allowed| allowed == relation),
            "decision resources must keep module trust relation `{relation}`"
        );
    }
}

#[test]
fn resource_kernel_rejects_invalid_payload_stale_cas_and_unsupported_links() {
    let mut store = InMemoryEngineResourceStore::new();
    for definition in builtin_resource_type_definitions() {
        store.register_type(definition).unwrap();
    }

    let invalid = store
        .create(CreateResource {
            resource_id: Some("goal-invalid".to_owned()),
            kind: "goal".to_owned(),
            schema_id: None,
            scope: EngineResourceScope::Workspace("workspace-1".to_owned()),
            owner_worker_id: wid("resource"),
            owner_actor_id: actor("actor"),
            lifecycle: Some("open".to_owned()),
            policy: json!({}),
            initial_payload: Some(json!({"successCriteria": ["missing intent"]})),
            locations: Vec::new(),
            trace_id: trace("resource-kernel-invalid"),
            invocation_id: None,
        })
        .unwrap_err();
    assert!(matches!(invalid, EngineError::SchemaViolation { .. }));
    assert!(store.inspect("goal-invalid").unwrap().is_none());

    let resource = store
        .create(CreateResource {
            resource_id: Some("artifact-kernel-test".to_owned()),
            kind: "artifact".to_owned(),
            schema_id: None,
            scope: EngineResourceScope::Workspace("workspace-1".to_owned()),
            owner_worker_id: wid("resource"),
            owner_actor_id: actor("actor"),
            lifecycle: Some("draft".to_owned()),
            policy: json!({}),
            initial_payload: Some(json!({"title": "Kernel", "body": "available"})),
            locations: vec![EngineResourceLocation {
                kind: "blob".to_owned(),
                uri: "blob://artifact-kernel-test".to_owned(),
                mime_type: Some("application/json".to_owned()),
                size_bytes: Some(32),
            }],
            trace_id: trace("resource-kernel-create"),
            invocation_id: None,
        })
        .unwrap();
    let current = resource.current_version_id.clone();

    let damaged = store
        .update(UpdateResource {
            resource_id: "artifact-kernel-test".to_owned(),
            expected_current_version_id: current.clone(),
            lifecycle: Some("draft".to_owned()),
            payload: json!({"title": "Kernel", "body": "damaged"}),
            state: Some(EngineResourceVersionState::Damaged),
            locations: Vec::new(),
            trace_id: trace("resource-kernel-damaged"),
            invocation_id: None,
        })
        .unwrap();
    assert_eq!(damaged.state, EngineResourceVersionState::Damaged);
    let inspection = store.inspect("artifact-kernel-test").unwrap().unwrap();
    assert_eq!(inspection.resource.current_version_id, current);
    assert_eq!(inspection.versions.len(), 2);

    let stale = store
        .update(UpdateResource {
            resource_id: "artifact-kernel-test".to_owned(),
            expected_current_version_id: Some("stale-version".to_owned()),
            lifecycle: None,
            payload: json!({"title": "Kernel", "body": "stale"}),
            state: None,
            locations: Vec::new(),
            trace_id: trace("resource-kernel-stale"),
            invocation_id: None,
        })
        .unwrap_err();
    assert!(
        matches!(stale, EngineError::PolicyViolation(message) if message.contains("version conflict"))
    );

    let unsupported_link = store
        .link(LinkResources {
            source_resource_id: "artifact-kernel-test".to_owned(),
            target_resource_id: "artifact-kernel-test".to_owned(),
            relation: "not_allowed".to_owned(),
            metadata: json!({}),
            trace_id: trace("resource-kernel-link"),
            invocation_id: None,
        })
        .unwrap_err();
    assert!(matches!(
        unsupported_link,
        EngineError::PolicyViolation(message) if message.contains("does not allow relation")
    ));
}

#[tokio::test]
async fn materialized_file_update_writes_file_and_returns_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("nested").join("result.txt");

    let result = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "resource-owned bytes"
            }),
            mutating_causal("materialized-file-update").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "resource-owned bytes"
    );
    let value = result.value.as_ref().unwrap();
    assert_eq!(value["version"]["state"], "available");
    assert_eq!(value["resourceRefs"][0]["kind"], "materialized_file");
    assert_eq!(value["resourceRefs"][0]["role"], "updated");
}

#[tokio::test]
async fn materialized_file_version_conflict_does_not_touch_target_file() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("result.txt");

    let first = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "first version"
            }),
            mutating_causal("materialized-file-conflict-first").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(first.error, None);

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "should not be written",
                "expectedCurrentVersionId": "wrong-version"
            }),
            mutating_causal("materialized-file-conflict-second").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("version conflict")
    ));
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "first version");
}

#[tokio::test]
async fn materialized_file_invalid_scope_does_not_touch_target_file() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("result.txt");

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "should not be written",
                "scope": "workspace",
                "workspaceId": ""
            }),
            mutating_causal("materialized-file-invalid-scope").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("workspaceId must not be empty")
    ));
    assert!(
        !target.exists(),
        "invalid resource scope must fail before target bytes are written"
    );
}

#[tokio::test]
async fn resource_backed_invocation_fails_without_top_level_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(StaticValueHandler(json!({"ok": true})))),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "demo::write",
            json!({}),
            mutating_causal("resource-backed-missing-refs").with_scope("demo.write"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("resource-backed output")
                && message.contains("resourceRefs")
    ));
}

#[tokio::test]
async fn resource_backed_invocation_rejects_malformed_or_wrong_kind_refs_without_persisting_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();

    let cases = [
        (
            "wrong-kind",
            json!({
                "resourceRefs": [{
                    "resourceId": "artifact-wrong-kind",
                    "kind": "materialized_file",
                    "versionId": "ver-test",
                    "role": "created",
                    "contentHash": "hash-test"
                }]
            }),
            "allowed kinds",
        ),
        (
            "missing-role",
            json!({
                "resourceRefs": [{
                    "resourceId": "artifact-missing-role",
                    "kind": "artifact",
                    "versionId": "ver-test",
                    "contentHash": "hash-test"
                }]
            }),
            "without role",
        ),
        (
            "invalid-version",
            json!({
                "resourceRefs": [{
                    "resourceId": "artifact-invalid-version",
                    "kind": "artifact",
                    "versionId": "",
                    "role": "created",
                    "contentHash": "hash-test"
                }]
            }),
            "invalid resourceRef versionId",
        ),
        (
            "invalid-hash",
            json!({
                "resourceRefs": [{
                    "resourceId": "artifact-invalid-hash",
                    "kind": "artifact",
                    "versionId": "ver-test",
                    "role": "created",
                    "contentHash": 42
                }]
            }),
            "invalid resourceRef contentHash",
        ),
        (
            "non-object",
            json!({"resourceRefs": ["artifact-id"]}),
            "non-object",
        ),
    ];

    for (case, response, expected) in cases {
        let function_id = format!("demo::write_{case}");
        let function = FunctionDefinition::new(
            fid(&function_id),
            wid("demo"),
            "write",
            VisibilityScope::Agent,
            EffectClass::IdempotentWrite,
        )
        .with_required_authority(AuthorityRequirement::scope("demo.write"))
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
        handle
            .register_function_for_setup(
                function,
                Some(Arc::new(StaticValueHandler(response))),
                false,
            )
            .unwrap();

        let result = handle
            .invoke(host_invocation(
                &function_id,
                json!({}),
                mutating_causal(&format!("resource-backed-invalid-{case}"))
                    .with_scope("demo.write"),
            ))
            .await;
        assert!(
            matches!(
                result.error,
                Some(EngineError::PolicyViolation(ref message)) if message.contains(expected)
            ),
            "case {case} should reject with `{expected}`, got {:?}",
            result.error
        );
        let records = handle.lock().await.catalog().invocations().to_vec();
        let record = records
            .iter()
            .find(|record| record.invocation_id == result.invocation_id)
            .expect("failed output-contract invocation should stay inspectable");
        assert!(!record.succeeded);
        assert!(
            record.produced_resource_refs.is_empty(),
            "invalid refs must not be persisted as produced refs"
        );
    }
}

#[tokio::test]
async fn resource_backed_refs_are_persisted_in_invocation_records() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(StaticValueHandler(json!({
                "resourceRefs": [{
                    "resourceId": "artifact-test",
                    "kind": "artifact",
                    "versionId": "ver-test",
                    "role": "created",
                    "contentHash": "hash-test"
                }]
            })))),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "demo::write",
            json!({}),
            mutating_causal("resource-backed-persisted").with_scope("demo.write"),
        ))
        .await;
    assert_eq!(result.error, None);

    let records = handle.lock().await.catalog().invocations().to_vec();
    let record = records
        .iter()
        .find(|record| record.invocation_id == result.invocation_id)
        .unwrap();
    assert_eq!(record.produced_resource_refs.len(), 1);
    assert_eq!(
        record.produced_resource_refs[0]["resourceId"],
        "artifact-test"
    );
}

#[tokio::test]
async fn converted_filesystem_outputs_have_no_audit_projection() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("filesystem", "filesystem"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("filesystem::write_file"),
        wid("filesystem"),
        "write file",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("filesystem.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed([
        "materialized_file",
    ]));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(StaticValueHandler(json!({
                "path": "/tmp/tron-materialized-output.txt",
                "bytesWritten": 5,
                "created": true,
                "resourceRefs": [{
                    "resourceId": "materialized_file:test",
                    "kind": "materialized_file",
                    "versionId": "ver-test",
                    "role": "updated",
                    "contentHash": "hash-test"
                }]
            })))),
            false,
        )
        .unwrap();
    let result = handle
        .invoke(host_invocation(
            "filesystem::write_file",
            json!({"path": "/tmp/tron-materialized-output.txt", "content": "draft"}),
            mutating_causal("filesystem-materialized-output")
                .with_scope("filesystem.write")
                .with_idempotency_key("filesystem-materialized-output"),
        ))
        .await;
    assert_eq!(result.error, None);
    let refs = result.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap();
    assert_eq!(refs[0]["kind"], "materialized_file");

    let trace = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": result.trace_id.as_str()}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("materialized-output-trace"),
            )
            .with_scope("observability.read"),
        ))
        .await;
    assert_eq!(trace.error, None);
    assert!(
        trace.value.as_ref().unwrap().get("outputAudit").is_none(),
        "output audit must not remain an active trace projection"
    );
}
