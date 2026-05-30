use super::*;
use crate::engine::ids::{ActorId, WorkerId};
use serde_json::json;
use tempfile::tempdir;

fn worker(value: &str) -> WorkerId {
    WorkerId::new(value).unwrap()
}

fn actor(value: &str) -> ActorId {
    ActorId::new(value).unwrap()
}

fn trace(value: &str) -> TraceId {
    TraceId::new(value).unwrap()
}

fn artifact_type() -> RegisterResourceType {
    RegisterResourceType {
        kind: "artifact".to_owned(),
        schema_id: "artifact.v1".to_owned(),
        schema: json!({"type": "object"}),
        lifecycle_states: vec![
            "draft".to_owned(),
            "promoted".to_owned(),
            "discarded".to_owned(),
        ],
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: vec!["supports".to_owned(), "supersedes".to_owned()],
        default_retention: json!({"class": "durable"}),
        redaction_rules: json!({"preview": "safe"}),
        materialization_rules: json!({"allowed": ["blob", "file"]}),
        required_capabilities: json!({
            "read": "resource::inspect",
            "write": "resource::update"
        }),
        owner_worker_id: worker("resource"),
    }
}

fn create_artifact(id: &str) -> CreateResource {
    CreateResource {
        resource_id: Some(id.to_owned()),
        kind: "artifact".to_owned(),
        schema_id: None,
        scope: EngineResourceScope::Workspace("workspace-1".to_owned()),
        owner_worker_id: worker("resource"),
        owner_actor_id: actor("actor"),
        lifecycle: Some("draft".to_owned()),
        policy: json!({"retention": "durable"}),
        initial_payload: Some(json!({"title": id, "body": "first"})),
        locations: vec![EngineResourceLocation {
            kind: "blob".to_owned(),
            uri: format!("blob://{id}"),
            mime_type: Some("application/json".to_owned()),
            size_bytes: Some(16),
        }],
        trace_id: trace("trace"),
        invocation_id: None,
    }
}

#[test]
fn in_memory_resources_are_versioned_and_inspectable() {
    let mut store = InMemoryEngineResourceStore::new();
    let definition = store.register_type(artifact_type()).unwrap();
    assert_eq!(definition.revision, 1);

    let resource = store.create(create_artifact("res_test")).unwrap();
    let current = resource.current_version_id.clone().unwrap();
    let version = store
        .update(UpdateResource {
            resource_id: "res_test".to_owned(),
            expected_current_version_id: Some(current.clone()),
            lifecycle: Some("promoted".to_owned()),
            payload: json!({"title": "res_test", "body": "second"}),
            state: None,
            locations: Vec::new(),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap();

    assert_eq!(version.parent_version_id.as_deref(), Some(current.as_str()));
    let inspection = store.inspect("res_test").unwrap().unwrap();
    assert_eq!(inspection.resource.lifecycle, "promoted");
    assert_eq!(inspection.versions.len(), 2);
    assert_eq!(inspection.events.len(), 3);
}

#[test]
fn compare_and_set_rejects_stale_resource_updates() {
    let mut store = InMemoryEngineResourceStore::new();
    store.register_type(artifact_type()).unwrap();
    let resource = store.create(create_artifact("res_test")).unwrap();
    let current = resource.current_version_id.unwrap();
    store
        .update(UpdateResource {
            resource_id: "res_test".to_owned(),
            expected_current_version_id: Some(current),
            lifecycle: None,
            payload: json!({"body": "second"}),
            state: None,
            locations: Vec::new(),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap();

    let err = store
        .update(UpdateResource {
            resource_id: "res_test".to_owned(),
            expected_current_version_id: Some("stale".to_owned()),
            lifecycle: None,
            payload: json!({"body": "third"}),
            state: None,
            locations: Vec::new(),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap_err();
    assert!(matches!(err, EngineError::PolicyViolation(_)));
}

#[test]
fn non_available_versions_do_not_advance_current_pointer() {
    let mut store = InMemoryEngineResourceStore::new();
    store.register_type(artifact_type()).unwrap();
    let resource = store.create(create_artifact("res_test")).unwrap();
    let current = resource.current_version_id.clone();
    let damaged = store
        .update(UpdateResource {
            resource_id: "res_test".to_owned(),
            expected_current_version_id: current.clone(),
            lifecycle: Some("draft".to_owned()),
            payload: json!({"title": "res_test", "body": "damaged"}),
            state: Some(EngineResourceVersionState::Damaged),
            locations: Vec::new(),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap();
    assert_eq!(damaged.state, EngineResourceVersionState::Damaged);
    let inspection = store.inspect("res_test").unwrap().unwrap();
    assert_eq!(inspection.resource.current_version_id, current);
    assert_eq!(inspection.versions.len(), 2);
}

#[test]
fn resource_payloads_must_match_registered_schema_before_persisting() {
    let mut strict_type = artifact_type();
    strict_type.schema = json!({
        "type": "object",
        "required": ["title", "body"],
        "additionalProperties": false,
        "properties": {
            "title": {"type": "string"},
            "body": {"type": "string"}
        }
    });
    let mut store = InMemoryEngineResourceStore::new();
    store.register_type(strict_type).unwrap();

    let mut invalid_create = create_artifact("res_invalid");
    invalid_create.initial_payload = Some(json!({"title": "missing body"}));
    let err = store.create(invalid_create).unwrap_err();
    assert!(matches!(err, EngineError::SchemaViolation { .. }));
    assert!(store.inspect("res_invalid").unwrap().is_none());

    let resource = store.create(create_artifact("res_valid")).unwrap();
    let err = store
        .update(UpdateResource {
            resource_id: "res_valid".to_owned(),
            expected_current_version_id: resource.current_version_id,
            lifecycle: None,
            payload: json!({"title": "missing body"}),
            state: None,
            locations: Vec::new(),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap_err();
    assert!(matches!(err, EngineError::SchemaViolation { .. }));
    let inspection = store.inspect("res_valid").unwrap().unwrap();
    assert_eq!(inspection.versions.len(), 1);
}

#[test]
fn links_must_use_declared_relations() {
    let mut store = InMemoryEngineResourceStore::new();
    store.register_type(artifact_type()).unwrap();
    store.create(create_artifact("res_source")).unwrap();
    store.create(create_artifact("res_target")).unwrap();

    let link = store
        .link(LinkResources {
            source_resource_id: "res_source".to_owned(),
            target_resource_id: "res_target".to_owned(),
            relation: "supports".to_owned(),
            metadata: json!({}),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap();
    assert_eq!(link.relation, "supports");

    let err = store
        .link(LinkResources {
            source_resource_id: "res_source".to_owned(),
            target_resource_id: "res_target".to_owned(),
            relation: "unknown".to_owned(),
            metadata: json!({}),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap_err();
    assert!(matches!(err, EngineError::PolicyViolation(_)));
}

#[test]
fn sqlite_resource_store_round_trips_full_substrate() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("resources.sqlite");
    let mut store = SqliteEngineResourceStore::open(&path).unwrap();
    store.register_type(artifact_type()).unwrap();
    let resource = store.create(create_artifact("res_test")).unwrap();
    let current = resource.current_version_id.clone().unwrap();
    store
        .update(UpdateResource {
            resource_id: "res_test".to_owned(),
            expected_current_version_id: Some(current),
            lifecycle: Some("promoted".to_owned()),
            payload: json!({"title": "res_test", "body": "second"}),
            state: None,
            locations: Vec::new(),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap();
    store
        .link(LinkResources {
            source_resource_id: "res_test".to_owned(),
            target_resource_id: "res_test".to_owned(),
            relation: "supersedes".to_owned(),
            metadata: json!({"self": true}),
            trace_id: trace("trace"),
            invocation_id: None,
        })
        .unwrap();
    drop(store);

    let store = SqliteEngineResourceStore::open(&path).unwrap();
    let inspection = store.inspect("res_test").unwrap().unwrap();
    assert_eq!(inspection.resource.lifecycle, "promoted");
    assert_eq!(inspection.versions.len(), 2);
    assert_eq!(inspection.outgoing_links.len(), 1);
    assert_eq!(inspection.events.len(), 4);
}

#[test]
fn resource_list_is_filtered_by_kind_scope_and_lifecycle() {
    let mut store = InMemoryEngineResourceStore::new();
    store.register_type(artifact_type()).unwrap();
    store.create(create_artifact("res_a")).unwrap();
    store.create(create_artifact("res_b")).unwrap();

    let resources = store
        .list(ListResources {
            kind: Some("artifact".to_owned()),
            scope: Some(EngineResourceScope::Workspace("workspace-1".to_owned())),
            lifecycle: Some("draft".to_owned()),
            limit: 10,
        })
        .unwrap();
    assert_eq!(resources.len(), 2);
}
