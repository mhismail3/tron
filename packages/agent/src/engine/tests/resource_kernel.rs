use super::*;
use crate::engine::durability::resources::{
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
        "decides",
        "promotes",
        "discards",
        "supports",
        "supported_by",
        "contradicted_by",
        "derived_from",
        "supersedes",
        "evidence_for",
    ] {
        assert!(
            decision
                .allowed_link_relations
                .iter()
                .any(|allowed| allowed == relation),
            "decision resources must keep primitive relation `{relation}`"
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
async fn materialized_file_update_resolves_relative_paths_with_runtime_working_directory() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let relative = format!("tron-runtime-cwd-test-{}/result.txt", uuid::Uuid::now_v7());
    let causal = mutating_causal("materialized-file-runtime-cwd")
        .with_scope("resource.write")
        .with_runtime_metadata(
            crate::engine::invocation::model::RUNTIME_METADATA_WORKING_DIRECTORY,
            tmp.path().to_string_lossy(),
        );

    let result = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": relative,
                "content": "runtime-owned bytes"
            }),
            causal,
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        std::fs::read_to_string(tmp.path().join(&relative)).unwrap(),
        "runtime-owned bytes"
    );
    assert!(
        !std::path::Path::new(&relative).exists(),
        "relative materialized paths must not fall back to the server cwd when runtime working directory is present"
    );
}

#[tokio::test]
async fn materialized_file_update_rejects_relative_runtime_path_escape() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let causal = mutating_causal("materialized-file-runtime-cwd-escape")
        .with_scope("resource.write")
        .with_runtime_metadata(
            crate::engine::invocation::model::RUNTIME_METADATA_WORKING_DIRECTORY,
            tmp.path().to_string_lossy(),
        );

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": "../escape.txt",
                "content": "should not be written"
            }),
            causal,
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("must stay inside")
    ));
    assert!(!tmp.path().parent().unwrap().join("escape.txt").exists());
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
async fn materialized_file_hash_verify_marks_missing_bytes_as_damaged_truth() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let missing = tmp.path().join("missing.txt");

    let created = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": "materialized_file:missing-bytes-test",
                "kind": "materialized_file",
                "scope": "session",
                "lifecycle": "materialized",
                "payload": {
                    "canonicalPath": missing.to_string_lossy(),
                    "relativePath": "missing.txt",
                    "entryType": "file",
                    "content": "expected bytes",
                    "contentHash": "expected-hash",
                    "sizeBytes": 14,
                    "mimeType": "text/plain",
                    "metadata": {"fixture": "missing-bytes"}
                },
                "locations": [{
                    "kind": "file",
                    "uri": missing.to_string_lossy(),
                    "mimeType": "text/plain",
                    "sizeBytes": 14
                }]
            }),
            mutating_causal("materialized-file-missing-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let original_current = created.value.as_ref().unwrap()["resource"]["currentVersionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let verified = handle
        .invoke(host_invocation(
            "materialized_file::hash_verify",
            json!({"resourceId": "materialized_file:missing-bytes-test"}),
            mutating_causal("materialized-file-missing-verify").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(verified.error, None);
    let value = verified.value.as_ref().unwrap();
    assert_eq!(value["version"]["state"], "damaged");
    assert_eq!(value["resourceRefs"][0]["role"], "damaged");
    assert!(value["version"]["payload"]["actualContentHash"].is_null());
    assert!(
        value["version"]["payload"]["damageReason"]
            .as_str()
            .unwrap()
            .contains("missing or unreadable")
    );

    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": "materialized_file:missing-bytes-test"}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    let inspection = &inspected.value.as_ref().unwrap()["inspection"];
    assert_eq!(inspection["resource"]["lifecycle"], "damaged");
    assert_eq!(inspection["resource"]["currentVersionId"], original_current);
    assert_eq!(inspection["versions"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn materialized_file_read_rejects_discarded_resource_but_inspect_remains_available() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("discarded.txt");
    let resource_id = "materialized_file:discarded-read-test";

    let created = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "resourceId": resource_id,
                "path": target.to_string_lossy(),
                "content": "discard me",
                "scope": "session"
            }),
            mutating_causal("materialized-file-discarded-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let current = created.value.as_ref().unwrap()["version"]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let discarded = handle
        .invoke(host_invocation(
            "materialized_file::discard",
            json!({
                "resourceId": resource_id,
                "expectedCurrentVersionId": current
            }),
            mutating_causal("materialized-file-discarded-discard").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(discarded.error, None);

    let inspected = handle
        .invoke(host_invocation(
            "materialized_file::inspect",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    assert_eq!(
        inspected.value.as_ref().unwrap()["inspection"]["resource"]["lifecycle"],
        "discarded"
    );

    let read = handle
        .invoke(host_invocation(
            "materialized_file::read",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert!(matches!(
        read.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("discarded")
    ));
}

#[tokio::test]
async fn materialized_file_update_rejects_discarded_resource_without_touching_bytes() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("discarded-update.txt");
    let resource_id = "materialized_file:discarded-update-test";

    let created = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "resourceId": resource_id,
                "path": target.to_string_lossy(),
                "content": "discard me",
                "scope": "session"
            }),
            mutating_causal("materialized-file-discarded-update-create")
                .with_scope("resource.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let current = created.value.as_ref().unwrap()["version"]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let discarded = handle
        .invoke(host_invocation(
            "materialized_file::discard",
            json!({
                "resourceId": resource_id,
                "expectedCurrentVersionId": current
            }),
            mutating_causal("materialized-file-discarded-update-discard")
                .with_scope("resource.write"),
        ))
        .await;
    assert_eq!(discarded.error, None);

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "resourceId": resource_id,
                "path": target.to_string_lossy(),
                "content": "revived bytes"
            }),
            mutating_causal("materialized-file-discarded-update-reject")
                .with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("discarded")
    ));
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "discard me");
}

#[tokio::test]
async fn patch_proposal_omits_absent_optional_string_fields() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let proposed = handle
        .invoke(host_invocation(
            "patch::propose",
            json!({
                "targetPath": "README.md",
                "diff": "--- README.md\n+++ README.md\n@@\n-old\n+new\n"
            }),
            mutating_causal("patch-propose-optional-fields").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(proposed.error, None);
    let resource_id = proposed.value.as_ref().unwrap()["resource"]["resourceId"]
        .as_str()
        .unwrap();

    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    let payload = &inspected.value.as_ref().unwrap()["inspection"]["versions"][0]["payload"];
    assert_eq!(payload["targetPath"], "README.md");
    assert_eq!(payload["status"], "proposed");
    assert!(
        payload.get("targetResourceId").is_none(),
        "absent optional targetResourceId must not be serialized as null"
    );
    assert!(
        payload.get("baseVersionId").is_none(),
        "absent optional baseVersionId must not be serialized as null"
    );
    assert!(
        payload.get("baseContentHash").is_none(),
        "absent optional baseContentHash must not be serialized as null"
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
async fn resource_backed_primitive_outputs_have_trace_identity() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("capability", "capability"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("capability::execute"),
        wid("capability"),
        "execute primitive",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("capability.execute"))
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
            "capability::execute",
            json!({
                "operation": "file_write",
                "path": "/tmp/tron-materialized-output.txt",
                "content": "draft"
            }),
            mutating_causal("capability-materialized-output")
                .with_scope("capability.execute")
                .with_idempotency_key("capability-materialized-output"),
        ))
        .await;
    assert_eq!(result.error, None);
    let refs = result.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap();
    assert_eq!(refs[0]["kind"], "materialized_file");

    assert!(
        !result.trace_id.as_str().is_empty(),
        "resource-backed writes still carry primitive trace identity"
    );
}

#[tokio::test]
async fn resource_primitive_manages_typed_resources_through_capabilities() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let admin_context = || {
        CausalContext::new(
            actor("system"),
            ActorKind::System,
            grant("grant"),
            trace("trace"),
        )
        .with_session_id("session-a")
        .with_workspace_id("workspace-a")
        .with_idempotency_key("resource-type-1")
        .with_scope("resource.admin")
        .with_scope("resource.write")
    };
    let agent_register = handle
        .invoke(host_invocation(
            "resource::register_type",
            json!({
                "kind": "artifact",
                "schemaId": "artifact.v1",
                "schema": {"type": "object"},
                "lifecycleStates": ["draft", "promoted", "discarded"]
            }),
            mutating_causal("resource-type-agent")
                .with_scope("resource.admin")
                .with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        agent_register.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let registered = handle
        .invoke(host_invocation(
            "resource::register_type",
            json!({
                "kind": "artifact",
                "schemaId": "artifact.v1",
                "schema": {
                    "type": "object",
                    "required": ["title", "body"],
                    "additionalProperties": false,
                    "properties": {
                        "title": {"type": "string"},
                        "body": {"type": "string"}
                    }
                },
                "lifecycleStates": ["draft", "promoted", "discarded"],
                "allowedLinkRelations": ["supports", "supersedes"],
                "requiredCapabilities": {
                    "read": "resource::inspect",
                    "write": "resource::update"
                }
            }),
            admin_context(),
        ))
        .await;
    assert_eq!(registered.error, None);
    assert_eq!(
        registered.value.as_ref().unwrap()["typeDefinition"]["kind"],
        "artifact"
    );

    let invalid_create = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": "res_invalid_artifact",
                "kind": "artifact",
                "scope": "workspace",
                "lifecycle": "draft",
                "payload": {"title": "draft"}
            }),
            mutating_causal("resource-create-invalid")
                .with_scope("resource.write")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert!(matches!(
        invalid_create.error,
        Some(EngineError::SchemaViolation { .. })
    ));

    let malformed_list = handle
        .invoke(host_invocation(
            "resource::list",
            json!({"scope": "workspace"}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert!(matches!(
        malformed_list.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("workspace-scoped resource requires workspaceId")
    ));

    let write_context = |key: &str| {
        mutating_causal(key)
            .with_scope("resource.write")
            .with_workspace_id("workspace-a")
    };
    let created = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": "res_test_artifact",
                "kind": "artifact",
                "scope": "workspace",
                "lifecycle": "draft",
                "payload": {"title": "draft", "body": "one"}
            }),
            write_context("resource-create-1"),
        ))
        .await;
    assert_eq!(created.error, None);
    let current = created.value.as_ref().unwrap()["resource"]["currentVersionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let stale = handle
        .invoke(host_invocation(
            "resource::update",
            json!({
                "resourceId": "res_test_artifact",
                "expectedCurrentVersionId": "stale",
                "payload": {"title": "draft", "body": "bad"}
            }),
            write_context("resource-update-stale"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("version conflict")
    ));

    let updated = handle
        .invoke(host_invocation(
            "resource::update",
            json!({
                "resourceId": "res_test_artifact",
                "expectedCurrentVersionId": current,
                "lifecycle": "promoted",
                "payload": {"title": "draft", "body": "two"}
            }),
            write_context("resource-update-1"),
        ))
        .await;
    assert_eq!(updated.error, None);

    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": "res_test_artifact"}),
            causal()
                .with_scope("resource.read")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    let inspection = &inspected.value.as_ref().unwrap()["inspection"];
    assert_eq!(inspection["resource"]["lifecycle"], "promoted");
    assert_eq!(inspection["versions"].as_array().unwrap().len(), 2);

    let listed = handle
        .invoke(host_invocation(
            "resource::list",
            json!({
                "kind": "artifact",
                "scope": "workspace",
                "workspaceId": "workspace-a"
            }),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(listed.error, None);
    assert_eq!(
        listed.value.as_ref().unwrap()["resources"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn artifact_goal_decision_wrappers_produce_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let artifact = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "resourceId": "artifact-wrapper-test",
                "payload": {"title": "Audit", "body": "draft"}
            }),
            mutating_causal("artifact-wrapper-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(artifact.error, None);
    assert_eq!(
        artifact.value.as_ref().unwrap()["resource"]["resourceId"],
        "artifact-wrapper-test"
    );

    let promoted = handle
        .invoke(host_invocation(
            "artifact::promote",
            json!({"resourceId": "artifact-wrapper-test"}),
            mutating_causal("artifact-wrapper-promote").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(promoted.error, None);
    assert_eq!(
        promoted.value.as_ref().unwrap()["version"]["resourceId"],
        "artifact-wrapper-test"
    );

    let goal = handle
        .invoke(host_invocation(
            "goal::create",
            json!({
                "resourceId": "goal-wrapper-test",
                "payload": {"intent": "Finish substrate", "successCriteria": ["decision recorded"]}
            }),
            mutating_causal("goal-wrapper-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(goal.error, None);

    let agent_result = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "agent_result",
                "resourceId": "agent-result-wrapper-test",
                "payload": {
                    "message": "Completed",
                    "promotedRefs": ["artifact-wrapper-test"],
                    "decisionRefs": [],
                    "subgoalRefs": [],
                    "stopReason": "completed",
                    "tokenUsage": {}
                }
            }),
            mutating_causal("agent-result-wrapper-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(agent_result.error, None);

    let completed = handle
        .invoke(host_invocation(
            "goal::complete",
            json!({
                "goalResourceId": "goal-wrapper-test",
                "agentResultResourceId": "agent-result-wrapper-test",
                "promotedResourceIds": ["artifact-wrapper-test"],
                "decision": {"status": "done", "summary": "Substrate checkpoint complete"}
            }),
            mutating_causal("goal-wrapper-complete").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(completed.error, None);
    let value = completed.value.as_ref().unwrap();
    assert_eq!(value["goalVersion"]["resourceId"], "goal-wrapper-test");
    assert_eq!(value["decision"]["kind"], "decision");
    assert_eq!(value["link"]["relation"], "decided_by");
    assert_eq!(value["agentResultLink"]["relation"], "produced");
    assert_eq!(value["promotedLinks"][0]["relation"], "promoted_output");
}

#[tokio::test]
async fn artifact_curation_and_goal_working_set_return_bounded_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let source = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "resourceId": "curation-source",
                "payload": {"title": "Source", "body": "alpha beta gamma"}
            }),
            mutating_causal("curation-source").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(source.error, None);

    let split = handle
        .invoke(host_invocation(
            "artifact::split",
            json!({
                "resourceId": "curation-source",
                "parts": [
                    {"resourceId": "curation-part-a", "payload": {"title": "A", "body": "alpha"}},
                    {"resourceId": "curation-part-b", "payload": {"title": "B", "body": "beta"}}
                ]
            }),
            mutating_causal("curation-split").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(split.error, None);
    assert_eq!(
        split.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    let composed = handle
        .invoke(host_invocation(
            "artifact::compose",
            json!({
                "resourceId": "curation-composed",
                "inputResourceIds": ["curation-part-a", "curation-part-b"],
                "payload": {"title": "Composed", "body": "alpha beta"}
            }),
            mutating_causal("curation-compose").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(composed.error, None);
    assert_eq!(
        composed.value.as_ref().unwrap()["resourceRefs"][0]["kind"],
        "artifact"
    );

    let search = handle
        .invoke(host_invocation(
            "artifact::search",
            json!({"query": "source", "scope": "workspace", "workspaceId": "workspace-a", "limit": 5}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(search.error, None);
    assert!(
        !search.value.as_ref().unwrap()["matches"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    let goal = handle
        .invoke(host_invocation(
            "goal::create",
            json!({
                "resourceId": "curation-goal",
                "payload": {"intent": "Curate artifacts", "successCriteria": ["candidate output identified"]}
            }),
            mutating_causal("curation-goal").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(goal.error, None);
    let link = handle
        .invoke(host_invocation(
            "resource::link",
            json!({
                "sourceResourceId": "curation-goal",
                "targetResourceId": "curation-composed",
                "relation": "candidate_output"
            }),
            mutating_causal("curation-link").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(link.error, None);
    let working_set = handle
        .invoke(host_invocation(
            "goal::working_set",
            json!({"goalResourceId": "curation-goal", "previewBytes": 12, "limit": 10}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(working_set.error, None);
    assert_eq!(
        working_set.value.as_ref().unwrap()["candidateOutputs"][0]["resource"]["resourceId"],
        "curation-composed"
    );
    assert!(
        working_set.value.as_ref().unwrap()["resources"][0]["preview"]
            .as_str()
            .unwrap()
            .chars()
            .count()
            <= 12
    );
}
