use super::*;

#[tokio::test]
async fn resource_backed_direct_worker_outputs_have_trace_identity() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("worker_test", "worker_test"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("worker_test::materialize"),
        wid("worker_test"),
        "materialize artifact",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope(
        "legacy.scope.is.not.a.local_gate",
    ))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(StaticValueHandler(json!({
                "path": "/tmp/tron-materialized-output.txt",
                "bytesWritten": 5,
                "created": true,
                "resourceRefs": [{
                    "resourceId": "artifact:test",
                    "kind": "artifact",
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
            "worker_test::materialize",
            json!({
                "path": "/tmp/tron-materialized-output.txt",
                "content": "draft"
            }),
            CausalContext::trusted_local(
                actor("system"),
                ActorKind::System,
                trace("direct-worker-materialized-output"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_idempotency_key("direct-worker-materialized-output"),
        ))
        .await;
    assert_eq!(result.error, None);
    let refs = result.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap();
    assert_eq!(refs[0]["kind"], "artifact");

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
