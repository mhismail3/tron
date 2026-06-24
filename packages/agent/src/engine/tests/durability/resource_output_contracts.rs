use super::*;
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
