use super::*;
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
