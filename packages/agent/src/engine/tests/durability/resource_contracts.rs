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
        "schedule",
        "schedule_run",
        "media_artifact",
        "repository_tree_snapshot",
        "update_diagnostic_record",
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
