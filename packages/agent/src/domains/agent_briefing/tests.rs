use serde_json::json;

use crate::domains::agent_briefing::{Deps, contract, service};
use crate::engine::{ActorId, EngineResourceScope, FunctionId, Invocation, TraceId, WorkerId};

fn trace_id(value: &str) -> TraceId {
    TraceId::new(value).expect("trace id")
}

fn invocation() -> Invocation {
    Invocation::new_sync(
        FunctionId::new("agent_briefing::overview").expect("function id"),
        json!({"limit": 10}),
        crate::engine::CausalContext::new(
            ActorId::new("system:test").expect("actor id"),
            crate::engine::ActorKind::System,
            crate::engine::AuthorityGrantId::new("engine-transport").expect("grant id"),
            trace_id("agent-briefing-test-invocation"),
        )
        .with_scope(contract::READ_SCOPE)
        .with_scope(crate::domains::module_activity::contract::READ_SCOPE)
        .with_session_id("test-session")
        .with_workspace_id("test-workspace"),
    )
}

async fn create_runtime_resource(
    engine_host: &crate::engine::EngineHostHandle,
    scope: EngineResourceScope,
    suffix: &str,
    label: &str,
    raw_detail: &str,
) {
    engine_host
        .create_resource(crate::engine::CreateResource {
            resource_id: Some(format!("module_runtime_state:{suffix}")),
            kind: crate::engine::MODULE_RUNTIME_STATE_KIND.to_owned(),
            schema_id: Some(crate::engine::MODULE_RUNTIME_STATE_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: WorkerId::new("agent_briefing_test").expect("worker id"),
            owner_actor_id: ActorId::new("system:test").expect("actor id"),
            lifecycle: Some("running".to_owned()),
            policy: json!({}),
            initial_payload: Some(json!({
                "schemaVersion": crate::engine::MODULE_RUNTIME_STATE_PAYLOAD_SCHEMA_VERSION,
                "state": "running",
                "runtimeRequestId": format!("runtime-request-{suffix}"),
                "scope": {"kind": scope.kind(), "value": scope.value()},
                "moduleLifecycle": {"kind": "module_lifecycle_state", "resourceId": "module_lifecycle_state:test"},
                "runtime": {"label": label},
                "supervision": {"state": "running"},
                "inputRefs": [],
                "outputArtifactRefs": [],
                "evidenceRefs": [],
                "traceRefs": [],
                "replayRefs": [],
                "reason": raw_detail,
                "authority": {
                    "grantRedacted": true,
                    "derivedRuntimeGrantRequired": true,
                    "wildcardGrantsAllowed": false
                },
                "idempotency": {
                    "fingerprint": format!("runtime-fingerprint-{suffix}"),
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
                "createdAt": "2026-06-20T12:00:00Z",
                "updatedAt": "2026-06-20T12:00:00Z",
                "revision": 1
            })),
            locations: vec![],
            trace_id: trace_id("agent-briefing-test-create-resource"),
            invocation_id: None,
        })
        .await
        .expect("create module resource");
}

#[tokio::test]
async fn overview_projects_chief_of_staff_sections_from_module_activity() {
    let engine_host = crate::engine::EngineHostHandle::new_in_memory().expect("host");
    let deps = Deps {
        engine_host: engine_host.clone(),
    };
    create_runtime_resource(
        &engine_host,
        EngineResourceScope::Session("test-session".to_owned()),
        "current-session",
        "Session summarizer",
        "run requested",
    )
    .await;

    let value = service::overview_value(&deps, &invocation())
        .await
        .expect("briefing");
    assert_eq!(value["operation"], "agent_briefing_overview");
    assert_eq!(value["summary"]["activeWorkCount"], 1);
    assert_eq!(value["scope"]["sessionScoped"], true);
    let sections = value["sections"].as_array().expect("sections");
    for expected in [
        "what_tron_has_been_doing",
        "how_tron_adapted",
        "active_work",
        "needs_you",
        "weak_points_failures",
        "memory_learned_state",
        "audit_trail",
    ] {
        assert!(
            sections.iter().any(|section| section["id"] == expected),
            "missing section {expected}"
        );
    }
}

#[tokio::test]
async fn overview_preserves_scope_and_redaction_policy() {
    let engine_host = crate::engine::EngineHostHandle::new_in_memory().expect("host");
    let deps = Deps {
        engine_host: engine_host.clone(),
    };
    create_runtime_resource(
        &engine_host,
        EngineResourceScope::Session("test-session".to_owned()),
        "current-session",
        "/Users/example/private/module",
        "token=abcdef0123456789",
    )
    .await;
    create_runtime_resource(
        &engine_host,
        EngineResourceScope::Session("other-session".to_owned()),
        "other-session",
        "Other session activity",
        "run requested",
    )
    .await;

    let value = service::overview_value(&deps, &invocation())
        .await
        .expect("briefing");
    let serialized = serde_json::to_string(&value).expect("json");
    assert!(!serialized.contains("/Users/example"));
    assert!(!serialized.contains("token=abcdef"));
    assert!(!serialized.contains("Other session activity"));
    assert_eq!(value["projection"]["rawCommandsReturned"], false);
    assert_eq!(value["projection"]["authorityIdsReturned"], false);
    assert_eq!(value["projection"]["autonomyBehaviorCreated"], false);
}

#[tokio::test]
async fn overview_fails_closed_without_trusted_scope() {
    let engine_host = crate::engine::EngineHostHandle::new_in_memory().expect("host");
    let deps = Deps { engine_host };
    let invocation = Invocation::new_sync(
        FunctionId::new("agent_briefing::overview").expect("function id"),
        json!({"limit": 10, "sessionId": "payload-only"}),
        crate::engine::CausalContext::new(
            ActorId::new("system:test").expect("actor id"),
            crate::engine::ActorKind::System,
            crate::engine::AuthorityGrantId::new("engine-transport").expect("grant id"),
            trace_id("agent-briefing-test-no-scope"),
        )
        .with_scope(contract::READ_SCOPE),
    );

    let error = service::overview_value(&deps, &invocation)
        .await
        .expect_err("briefing must fail without trusted scope");
    match error {
        crate::shared::server::errors::CapabilityError::InvalidParams { message } => {
            assert!(message.contains("trusted session or workspace context"));
        }
        other => panic!("unexpected error: {other:?}"),
    }
}

#[test]
fn static_guard_no_primary_runtime_cockpit_or_mutation_behavior() {
    let source = include_str!("projection.rs");
    for rejected in [
        "Runtime Cockpit",
        "rawCommandsReturned: true",
        "rawLogsReturned: true",
        "autonomyBehaviorCreated\": true",
        "create_resource",
        "launch_worker",
        "compact",
        "clear",
    ] {
        assert!(
            !source.contains(rejected),
            "agent briefing must stay read-only and high-signal: {rejected}"
        );
    }
}
