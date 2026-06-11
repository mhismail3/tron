use super::*;
use crate::engine::kernel::ids::{ActorId, WorkerId};
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

#[test]
fn in_memory_resource_pages_resume_without_duplicates() {
    let mut store = InMemoryEngineResourceStore::new();
    store.register_type(artifact_type()).unwrap();
    for index in 0..7 {
        store
            .create(create_artifact(&format!("res_page_{index}")))
            .unwrap();
    }

    let first = store
        .list_page(ListResourcesPageRequest {
            filter: ListResources {
                kind: Some("artifact".to_owned()),
                limit: 3,
                ..ListResources::default()
            },
            cursor: None,
        })
        .unwrap();
    assert_eq!(first.resources.len(), 3);
    assert!(first.has_more);
    assert_eq!(
        first.next_cursor,
        first
            .resources
            .last()
            .map(ResourceListCursor::from_resource)
    );

    let second = store
        .list_page(ListResourcesPageRequest {
            filter: ListResources {
                kind: Some("artifact".to_owned()),
                limit: 3,
                ..ListResources::default()
            },
            cursor: first.next_cursor.clone(),
        })
        .unwrap();
    assert_eq!(second.resources.len(), 3);
    assert!(second.has_more);

    let third = store
        .list_page(ListResourcesPageRequest {
            filter: ListResources {
                kind: Some("artifact".to_owned()),
                limit: 3,
                ..ListResources::default()
            },
            cursor: second.next_cursor.clone(),
        })
        .unwrap();
    assert_eq!(third.resources.len(), 1);
    assert!(!third.has_more);

    let paged_ids = first
        .resources
        .iter()
        .chain(second.resources.iter())
        .chain(third.resources.iter())
        .map(|resource| resource.resource_id.clone())
        .collect::<Vec<_>>();
    let listed_ids = store
        .list(ListResources {
            kind: Some("artifact".to_owned()),
            limit: 10,
            ..ListResources::default()
        })
        .unwrap()
        .iter()
        .map(|resource| resource.resource_id.clone())
        .collect::<Vec<_>>();

    assert_eq!(paged_ids, listed_ids);
    let unique = paged_ids.iter().collect::<std::collections::BTreeSet<_>>();
    assert_eq!(
        unique.len(),
        paged_ids.len(),
        "pagination must not duplicate resources"
    );
}

#[test]
fn sqlite_resource_pages_match_in_memory_cursor_semantics() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("resources.sqlite");
    let mut sqlite = SqliteEngineResourceStore::open(&path).unwrap();
    let mut memory = InMemoryEngineResourceStore::new();
    sqlite.register_type(artifact_type()).unwrap();
    memory.register_type(artifact_type()).unwrap();
    for index in 0..7 {
        let id = format!("res_page_{index}");
        sqlite.create(create_artifact(&id)).unwrap();
        memory.create(create_artifact(&id)).unwrap();
    }

    let mut sqlite_ids = Vec::new();
    let mut sqlite_cursor = None;
    loop {
        let page = sqlite
            .list_page(ListResourcesPageRequest {
                filter: ListResources {
                    kind: Some("artifact".to_owned()),
                    limit: 2,
                    ..ListResources::default()
                },
                cursor: sqlite_cursor,
            })
            .unwrap();
        sqlite_ids.extend(
            page.resources
                .iter()
                .map(|resource| resource.resource_id.clone()),
        );
        if !page.has_more {
            break;
        }
        sqlite_cursor = page.next_cursor;
    }

    let mut memory_ids = Vec::new();
    let mut memory_cursor = None;
    loop {
        let page = memory
            .list_page(ListResourcesPageRequest {
                filter: ListResources {
                    kind: Some("artifact".to_owned()),
                    limit: 2,
                    ..ListResources::default()
                },
                cursor: memory_cursor,
            })
            .unwrap();
        memory_ids.extend(
            page.resources
                .iter()
                .map(|resource| resource.resource_id.clone()),
        );
        if !page.has_more {
            break;
        }
        memory_cursor = page.next_cursor;
    }

    assert_eq!(sqlite_ids.len(), 7);
    assert_eq!(memory_ids.len(), 7);
    assert_eq!(
        sqlite_ids
            .iter()
            .collect::<std::collections::BTreeSet<_>>()
            .len(),
        sqlite_ids.len(),
        "sqlite pagination must not duplicate resources"
    );
    assert_eq!(
        memory_ids
            .iter()
            .collect::<std::collections::BTreeSet<_>>()
            .len(),
        memory_ids.len(),
        "memory pagination must not duplicate resources"
    );
}
