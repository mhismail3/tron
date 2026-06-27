use chrono::Utc;
use serde_json::{Value, json};

use crate::domains::module_activity::projection::{ModuleActivityItem, test_item, test_projection};
use crate::domains::module_activity::{Deps, contract, service};
use crate::engine::durability::resources::EngineResourceVersionState;
use crate::engine::{
    ActorId, EngineResource, EngineResourceScope, EngineResourceVersion, FunctionId, Invocation,
    ListResources, TraceId, WorkerId,
};

fn resource(kind: &str, lifecycle: &str) -> EngineResource {
    EngineResource {
        resource_id: format!("{kind}:example"),
        kind: kind.to_owned(),
        schema_id: format!("schema:{kind}"),
        scope: EngineResourceScope::Session("test-session".to_owned()),
        owner_worker_id: WorkerId::new("module_activity_test").expect("worker id"),
        owner_actor_id: ActorId::new("system:test").expect("actor id"),
        lifecycle: lifecycle.to_owned(),
        policy: json!({}),
        current_version_id: Some("version-1".to_owned()),
        trace_id: TraceId::generate(),
        created_by_invocation_id: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    }
}

fn version(resource: &EngineResource, payload: Value) -> EngineResourceVersion {
    EngineResourceVersion {
        version_id: "version-1".to_owned(),
        resource_id: resource.resource_id.clone(),
        parent_version_id: None,
        content_hash: "hash".to_owned(),
        state: EngineResourceVersionState::Available,
        payload,
        locations: Vec::new(),
        created_by_invocation_id: None,
        trace_id: TraceId::generate(),
        created_at: Utc::now(),
    }
}

#[test]
fn runtime_running_derives_active_without_raw_output() {
    let resource = resource(crate::engine::MODULE_RUNTIME_STATE_KIND, "running");
    let payload = json!({
        "runtime": {"label": "Generic summarizer"},
        "supervision": {"state": "running"},
        "authority": {
            "grantRedacted": true,
            "derivedRuntimeGrantRequired": true,
            "wildcardGrantsAllowed": false
        },
        "outputArtifactRefs": [
            {"resourceId": "prompt_artifact:summary", "summary": "bounded output"}
        ],
        "reason": "run requested",
        "updatedAt": "2026-06-20T12:00:00Z",
        "rawLogs": "must not project"
    });
    let item = test_item(
        &resource,
        &version(&resource, payload),
        &json!({
            "runtime": {"label": "Generic summarizer"},
            "supervision": {"state": "running"},
            "authority": {
                "grantRedacted": true,
                "derivedRuntimeGrantRequired": true,
                "wildcardGrantsAllowed": false
            },
            "outputArtifactRefs": [
                {"resourceId": "prompt_artifact:summary", "summary": "bounded output"}
            ],
            "reason": "run requested",
            "updatedAt": "2026-06-20T12:00:00Z",
            "rawLogs": "must not project"
        }),
    );

    assert_eq!(item["status"], "active");
    assert_eq!(item["title"], "Generic summarizer");
    assert_eq!(item["touchedResources"][0]["label"], "output refs");
    assert!(
        !serde_json::to_string(&item)
            .expect("json")
            .contains("must not project")
    );
}

#[test]
fn blocked_and_waiting_states_are_derived_from_existing_facts() {
    let lifecycle = resource(crate::engine::MODULE_LIFECYCLE_STATE_KIND, "enabled");
    let lifecycle_payload = json!({
        "transition": {"action": "rollback", "reason": "bad validation"},
        "rollback": {"status": "blocked"},
        "updatedAt": "2026-06-20T12:00:00Z"
    });
    let install = resource(crate::engine::MODULE_INSTALL_REQUEST_KIND, "pending_review");
    let install_payload = json!({
        "identity": {"title": "Candidate module"},
        "installGate": {"state": "pending_review"},
        "updatedAt": "2026-06-19T12:00:00Z"
    });

    let blocked = ModuleActivityItem::from_resource(
        &lifecycle,
        &version(&lifecycle, lifecycle_payload.clone()),
        &lifecycle_payload,
    );
    let waiting = ModuleActivityItem::from_resource(
        &install,
        &version(&install, install_payload.clone()),
        &install_payload,
    );
    let projection = test_projection(vec![blocked, waiting], 40);

    assert_eq!(projection["summary"]["blocked"], 1);
    assert_eq!(projection["summary"]["waiting"], 1);
    assert_eq!(projection["blocked"][0]["status"], "blocked");
    assert_eq!(projection["waiting"][0]["status"], "waiting");
}

#[test]
fn projection_redacts_sensitive_shapes_and_declares_policy() {
    let resource = resource(crate::engine::MODULE_PROPOSAL_KIND, "draft");
    let payload = json!({
        "identity": {
            "title": "/Users/example/private/module",
            "summary": "token=abcdef0123456789"
        },
        "authority": {
            "grantRedacted": true,
            "rawAuthorityIdsStored": false
        },
        "traceRefs": [{"id": "trace:abc"}],
        "updatedAt": "2026-06-20T12:00:00Z"
    });
    let item = test_item(&resource, &version(&resource, payload.clone()), &payload);

    assert_eq!(item["title"], "[redacted]");
    assert_eq!(item["detail"], "[redacted]");
    assert_eq!(item["authorityLabels"][0], "grant redacted");
    assert!(
        !serde_json::to_string(&item)
            .expect("json")
            .contains("/Users/example")
    );
}

#[tokio::test]
async fn overview_lists_module_resources_only() {
    let engine_host = crate::engine::EngineHostHandle::new_in_memory().expect("host");
    let deps = Deps {
        engine_host: engine_host.clone(),
    };
    let invocation = Invocation::new_sync(
        FunctionId::new("module_activity::overview").expect("function id"),
        json!({"limit": 10}),
        crate::engine::CausalContext::new(
            ActorId::new("system:test").expect("actor id"),
            crate::engine::ActorKind::System,
            crate::engine::AuthorityGrantId::new("engine-transport").expect("grant id"),
            TraceId::generate(),
        )
        .with_scope(contract::READ_SCOPE),
    );

    let runtime = resource(crate::engine::MODULE_RUNTIME_STATE_KIND, "running");
    engine_host
        .create_resource(crate::engine::CreateResource {
            resource_id: Some(runtime.resource_id.clone()),
            kind: runtime.kind.clone(),
            schema_id: Some(crate::engine::MODULE_RUNTIME_STATE_SCHEMA_ID.to_owned()),
            scope: runtime.scope.clone(),
            owner_worker_id: runtime.owner_worker_id.clone(),
            owner_actor_id: runtime.owner_actor_id.clone(),
            lifecycle: Some(runtime.lifecycle.clone()),
            policy: json!({}),
            initial_payload: Some(json!({
                "schemaVersion": crate::engine::MODULE_RUNTIME_STATE_PAYLOAD_SCHEMA_VERSION,
                "state": "running",
                "runtimeRequestId": "runtime-request",
                "scope": {"kind": "session", "value": "test-session"},
                "moduleLifecycle": {"kind": "module_lifecycle_state", "resourceId": "module_lifecycle_state:test"},
                "runtime": {"label": "Activity runtime"},
                "supervision": {"state": "running"},
                "inputRefs": [],
                "outputArtifactRefs": [],
                "evidenceRefs": [],
                "traceRefs": [],
                "replayRefs": [],
                "authority": {
                    "grantRedacted": true,
                    "derivedRuntimeGrantRequired": true,
                    "wildcardGrantsAllowed": false
                },
                "idempotency": {
                    "fingerprint": "runtime-fingerprint",
                    "fingerprintAlgorithm": "test",
                    "keyRedacted": true,
                    "rawKeyStored": false
                },
                "sideEffectProof": {
                    "supervisorEnvelopeOnly": true,
                    "installPerformed": false,
                    "activationPerformed": false,
                    "dependencyRestorePerformed": false,
                    "packageManagerUsed": false,
                    "networkAccessPerformed": false,
                    "repoManagedSkillsTouched": false,
                    "physicalWorkspaceDirectoryCreated": false,
                    "ptyAllocated": false,
                    "browserAutomationPerformed": false,
                    "rawCommandsStored": false,
                    "rawLogsStored": false,
                    "rawOutputStored": false,
                    "secretsExposed": false,
                    "fileContentsStored": false,
                    "absolutePathsStored": false,
                    "networkPolicy": "none"
                },
                "reason": "test runtime",
                "createdAt": "2026-06-20T12:00:00Z",
                "updatedAt": "2026-06-20T12:00:00Z"
                ,
                "revision": 1
            })),
            locations: vec![],
            trace_id: TraceId::generate(),
            invocation_id: None,
        })
        .await
        .expect("create module resource");

    let value = service::overview_value(&deps, &invocation.payload)
        .await
        .expect("overview");
    assert_eq!(value["operation"], "module_activity_overview");
    assert_eq!(value["summary"]["active"], 1);
    assert_eq!(value["timeline"][0]["title"], "Activity runtime");

    let listed = engine_host
        .list_resources(ListResources {
            kind: Some(crate::engine::MODULE_RUNTIME_STATE_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list");
    assert_eq!(listed.len(), 1);
}

#[test]
fn static_guard_no_legacy_cockpit_panel_names() {
    let source = include_str!("projection.rs");
    for retired in [
        "SourceControlPanel",
        "MemoryPanel",
        "ProcessPanel",
        "SubagentPanel",
        "NotificationPanel",
        "SkillPanel",
        "rawCommandsReturned: true",
        "rawLogsReturned: true",
    ] {
        assert!(
            !source.contains(retired),
            "module activity must not restore retired panel/source {retired}"
        );
    }
}
