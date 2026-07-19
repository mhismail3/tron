use super::projection;
use super::{Deps, service};
use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::engine::durability::resources::EngineResourceVersionState;
use crate::engine::{
    DELEGATION_KIND, DELEGATION_SCHEMA_ID, EngineResource, EngineResourceScope,
    EngineResourceVersion, TraceId, WorkerId,
};
use chrono::Utc;
use futures::stream;
use serde_json::json;
use std::sync::Arc;

use crate::domains::model::responder::{
    ModelResponder, ModelResponderFactory, ModelResponderInfo, ModelResponse, ModelResponseError,
    ModelResponseRequest, ModelResponseStream,
};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, StreamEvent};
use crate::shared::protocol::messages::TokenUsage;

struct SuccessfulDelegationResponder;

#[async_trait::async_trait]
impl ModelResponder for SuccessfulDelegationResponder {
    fn info(&self) -> ModelResponderInfo {
        ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::Anthropic,
            provider_name: "anthropic",
            model: "mock".to_owned(),
            context_window: 200_000,
        }
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        let result = "The delegated parser boundary is sound.";
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: result.to_owned(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(result)],
                    token_usage: Some(TokenUsage {
                        input_tokens: 10,
                        output_tokens: 8,
                        ..Default::default()
                    }),
                },
                stop_reason: "end_turn".to_owned(),
            }),
        ];
        Ok(ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::iter(events)) as ModelResponseStream,
        })
    }
}

struct SuccessfulDelegationFactory;

#[async_trait::async_trait]
impl ModelResponderFactory for SuccessfulDelegationFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _api_settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(SuccessfulDelegationResponder))
    }
}

fn invocation(
    session_id: &str,
    function: &str,
    payload: serde_json::Value,
) -> crate::engine::Invocation {
    crate::engine::Invocation::new_sync(
        crate::engine::FunctionId::new(function).unwrap(),
        payload,
        crate::engine::CausalContext::new(
            crate::engine::ActorId::new("system:test").unwrap(),
            crate::engine::ActorKind::System,
            crate::engine::AuthorityGrantId::new("engine-system").unwrap(),
            TraceId::generate(),
        )
        .with_session_id(session_id)
        .with_scope("delegation.write")
        .with_idempotency_key("test-operation"),
    )
}

fn deps() -> (crate::shared::server::context::ServerRuntimeContext, Deps) {
    let context = crate::shared::server::test_support::make_test_context();
    let deps = Deps::from_components(
        context.engine_host.clone(),
        context.event_store.clone(),
        context.orchestrator.clone(),
        context.session_manager.clone(),
    );
    (context, deps)
}

async fn create_delegation(
    deps: &Deps,
    parent: &str,
    child: Option<&str>,
    state: &str,
    suffix: &str,
) -> String {
    let now = Utc::now().to_rfc3339();
    let resource = deps.engine_host.create_resource(crate::engine::CreateResource {
        resource_id: Some(format!("delegation:{suffix}")), kind: DELEGATION_KIND.to_owned(),
        schema_id: Some(DELEGATION_SCHEMA_ID.to_owned()), scope: EngineResourceScope::Session(parent.to_owned()),
        owner_worker_id: WorkerId::new("delegation").unwrap(), owner_actor_id: crate::engine::ActorId::new("system:test").unwrap(),
        lifecycle: Some(state.to_owned()), policy: json!({}), locations: vec![], trace_id: TraceId::generate(), invocation_id: None,
        initial_payload: Some(json!({
            "schemaVersion": "tron.delegation.v1", "state": state, "parentSessionId": parent,
            "childSessionId": child, "childRunId": child.map(|_| "run-1"), "objectiveSummary": "inspect",
            "successCriteria": ["report"], "handoffRefs": [], "resultSummary": if state == "result_ready" { Some("ready") } else { None::<&str> },
            "resultRefs": [], "failure": null, "authority": {"workspace": "shared_read_only", "network": "none", "canDelegate": false},
            "limits": {"maxDepth": 1, "maxConcurrentPerParent": 3}, "idempotencyKey": suffix,
            "cancelIdempotencyKey": null, "acceptIdempotencyKey": null,
            "createdAt": now, "updatedAt": now, "revision": 1
        })),
    }).await.unwrap();
    resource.resource_id
}

#[test]
fn summary_is_bounded_to_workflow_fields() {
    let trace = TraceId::new("trace-delegation-summary").unwrap();
    let version = EngineResourceVersion {
        version_id: "version-1".to_owned(),
        resource_id: "delegation:1".to_owned(),
        parent_version_id: None,
        content_hash: "hash".to_owned(),
        state: EngineResourceVersionState::Available,
        payload: json!({
            "parentSessionId": "parent", "objectiveSummary": "Inspect the parser",
            "childSessionId": "child", "createdAt": "created", "updatedAt": "updated",
            "resultSummary": "done", "resultRefs": [{"resourceId": "agent_result:1"}],
            "secretInternalField": "must not project"
        }),
        locations: vec![],
        created_by_invocation_id: None,
        trace_id: trace.clone(),
        created_at: Utc::now(),
    };
    let resource = EngineResource {
        resource_id: "delegation:1".to_owned(),
        kind: DELEGATION_KIND.to_owned(),
        schema_id: DELEGATION_SCHEMA_ID.to_owned(),
        scope: EngineResourceScope::Session("parent".to_owned()),
        owner_worker_id: WorkerId::new("delegation").unwrap(),
        owner_actor_id: crate::engine::ActorId::new("system:test").unwrap(),
        lifecycle: "result_ready".to_owned(),
        policy: json!({}),
        current_version_id: Some(version.version_id.clone()),
        trace_id: trace,
        created_by_invocation_id: None,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    };
    let summary = projection::summary(&resource, &version, &version.payload);
    assert_eq!(summary["state"], "result_ready");
    assert_eq!(summary["childSessionId"], "child");
    assert_eq!(summary["versionRef"]["resourceKind"], DELEGATION_KIND);
    assert_eq!(summary["versionRef"]["lifecycle"], "result_ready");
    assert!(summary["resultSummary"].is_null());
    assert_eq!(summary["resultRefs"], json!([]));
    assert!(summary.get("secretInternalField").is_none());
}

#[tokio::test]
async fn start_prepares_durable_record_and_fresh_nonfork_child_before_prompt_failure() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    let payload = json!({"sessionId": parent, "objectiveSummary": "inspect parser", "successCriteria": ["report findings"], "handoffRefs": [], "idempotencyKey": "same"});
    let first = service::start(
        &invocation(&parent, "delegation::start", payload.clone()),
        &deps,
    )
    .await;
    assert!(
        first.is_err(),
        "test runtime has no responder, so child prompt must fail closed"
    );
    let resources = deps
        .engine_host
        .list_resources(crate::engine::ListResources {
            kind: Some(DELEGATION_KIND.to_owned()),
            scope: Some(EngineResourceScope::Session(parent.clone())),
            lifecycle: None,
            limit: 10,
        })
        .await
        .unwrap();
    assert_eq!(resources.len(), 1);
    assert_eq!(resources[0].lifecycle, "failed");
    let inspection = deps
        .engine_host
        .inspect_resource(&resources[0].resource_id)
        .await
        .unwrap()
        .unwrap();
    let version = inspection
        .versions
        .iter()
        .find(|v| Some(v.version_id.as_str()) == inspection.resource.current_version_id.as_deref())
        .unwrap();
    let child = version.payload["childSessionId"].as_str().unwrap();
    let failure = version.payload["failure"]["message"].as_str().unwrap();
    assert!(
        !failure.contains("schema") && !failure.contains("executionPolicy"),
        "hidden delegated prompt must pass contract validation before runtime failure: {failure}"
    );
    let child_row = context.event_store.get_session(child).unwrap().unwrap();
    assert!(
        child_row.parent_session_id.is_none(),
        "delegation child must not be fork lineage"
    );

    let replay = service::start(&invocation(&parent, "delegation::start", payload), &deps)
        .await
        .unwrap();
    assert_eq!(replay["replayed"], true);
    let collision = json!({"sessionId": parent, "objectiveSummary": "different", "successCriteria": ["report findings"], "handoffRefs": [], "idempotencyKey": "same"});
    assert!(
        service::start(&invocation(&parent, "delegation::start", collision), &deps)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn successful_start_runs_real_child_reconciles_and_accepts_provider_result() {
    let context = crate::shared::server::test_support::make_test_context_with_responder_factory(
        Some(Arc::new(SuccessfulDelegationFactory)),
    );
    let deps = Deps::from_components(
        context.engine_host.clone(),
        context.event_store.clone(),
        context.orchestrator.clone(),
        context.session_manager.clone(),
    );
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    let started = service::start(
        &invocation(
            &parent,
            "delegation::start",
            json!({
                "sessionId": parent,
                "objectiveSummary": "inspect parser",
                "successCriteria": ["report findings"],
                "handoffRefs": [],
                "idempotencyKey": "real-success"
            }),
        ),
        &deps,
    )
    .await
    .unwrap();
    let delegation_id = started["delegation"]["workflowRef"]["id"]
        .as_str()
        .unwrap()
        .to_owned();

    let ready = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            let inspection = deps
                .engine_host
                .inspect_resource(&delegation_id)
                .await
                .unwrap()
                .unwrap();
            if inspection.resource.lifecycle == "result_ready" {
                break inspection;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("real child run must reconcile to result_ready");
    let ready_version = ready.resource.current_version_id.clone().unwrap();
    let current = ready
        .versions
        .iter()
        .find(|version| version.version_id == ready_version)
        .unwrap();
    assert_eq!(
        current.payload["resultSummary"],
        "The delegated parser boundary is sound."
    );
    assert_eq!(current.payload["resultRefs"].as_array().unwrap().len(), 1);

    let child = current.payload["childSessionId"].as_str().unwrap();
    let child_events = context
        .event_store
        .get_events_by_type(child, &["message.assistant", "stream.turn_end"], None)
        .unwrap();
    assert!(
        child_events
            .iter()
            .any(|event| event.event_type == "message.assistant")
    );
    assert!(
        child_events
            .iter()
            .any(|event| event.event_type == "stream.turn_end")
    );
    let child_results = deps
        .engine_host
        .list_resources(crate::engine::ListResources {
            kind: Some("agent_result".to_owned()),
            scope: Some(EngineResourceScope::Session(child.to_owned())),
            lifecycle: Some("final".to_owned()),
            limit: 10,
        })
        .await
        .unwrap();
    assert_eq!(
        child_results.len(),
        1,
        "real prompt completion must own its result"
    );

    let accepted = service::accept_result(
        &invocation(
            &parent,
            "delegation::accept_result",
            json!({
                "sessionId": parent,
                "delegationResourceId": delegation_id,
                "expectedVersionId": ready_version,
                "idempotencyKey": "accept-real-success"
            }),
        ),
        &deps,
    )
    .await
    .unwrap();
    assert_eq!(accepted["delegation"]["state"], "accepted");
    assert_eq!(
        accepted["delegation"]["resultSummary"],
        "The delegated parser boundary is sound."
    );
    assert_eq!(
        accepted["delegation"]["resultRefs"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn handoff_refs_reject_unbounded_or_authority_bearing_fields() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    let payload = json!({
        "sessionId": parent,
        "objectiveSummary": "inspect parser",
        "successCriteria": ["report findings"],
        "handoffRefs": [{
            "kind": "artifact",
            "id": "artifact:1",
            "path": "/private/input",
            "authority": {"workspace": "write"}
        }],
        "idempotencyKey": "smuggled-ref"
    });
    assert!(
        service::start(&invocation(&parent, "delegation::start", payload), &deps)
            .await
            .is_err()
    );
    let resources = deps
        .engine_host
        .list_resources(crate::engine::ListResources {
            kind: Some(DELEGATION_KIND.to_owned()),
            scope: Some(EngineResourceScope::Session(parent)),
            lifecycle: None,
            limit: 10,
        })
        .await
        .unwrap();
    assert!(
        resources.is_empty(),
        "invalid handoff refs must fail before durable creation"
    );
}

#[tokio::test]
async fn capacity_scope_and_lazy_restart_repair_are_enforced() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    let mut active_runs = Vec::new();
    for index in 0..3 {
        let child = context
            .session_manager
            .create_session("mock", "/tmp", Some("child"))
            .unwrap();
        context.orchestrator.init_sequence_counter(&child, 0);
        active_runs.push(context.orchestrator.begin_run(&child, "run-1").unwrap());
        create_delegation(
            &deps,
            &parent,
            Some(&child),
            "running",
            &format!("slot-{index}"),
        )
        .await;
    }
    let payload = json!({"sessionId": parent, "objectiveSummary": "fourth", "successCriteria": ["report"], "idempotencyKey": "fourth"});
    assert!(
        service::start(&invocation(&parent, "delegation::start", payload), &deps)
            .await
            .is_err()
    );
    drop(active_runs);
    let first = deps
        .engine_host
        .list_resources(crate::engine::ListResources {
            kind: Some(DELEGATION_KIND.to_owned()),
            scope: Some(EngineResourceScope::Session(parent.clone())),
            lifecycle: Some("running".to_owned()),
            limit: 10,
        })
        .await
        .unwrap()[0]
        .resource_id
        .clone();
    let inspect = json!({"sessionId": parent, "delegationResourceId": first});
    let _ = service::inspect(&invocation(&parent, "delegation::inspect", inspect), &deps)
        .await
        .unwrap();
    let failed = deps
        .engine_host
        .list_resources(crate::engine::ListResources {
            kind: Some(DELEGATION_KIND.to_owned()),
            scope: Some(EngineResourceScope::Session(parent.clone())),
            lifecycle: Some("failed".to_owned()),
            limit: 10,
        })
        .await
        .unwrap();
    assert!(
        !failed.is_empty(),
        "lazy inspect must repair an orphaned running delegation"
    );

    let other = context
        .session_manager
        .create_session("mock", "/tmp", Some("other"))
        .unwrap();
    let id = failed[0].resource_id.clone();
    let wrong_scope = json!({"sessionId": other, "delegationResourceId": id});
    assert!(
        service::inspect(
            &invocation(&other, "delegation::inspect", wrong_scope),
            &deps
        )
        .await
        .is_err()
    );
}

#[tokio::test]
async fn result_ready_delegations_consume_parent_capacity_until_accepted() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    for index in 0..3 {
        create_delegation(
            &deps,
            &parent,
            Some(&format!("child-{index}")),
            "result_ready",
            &format!("ready-{index}"),
        )
        .await;
    }
    let payload = json!({
        "sessionId": parent,
        "objectiveSummary": "fourth",
        "successCriteria": ["report"],
        "idempotencyKey": "ready-fourth"
    });
    assert!(
        service::start(&invocation(&parent, "delegation::start", payload), &deps)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn concurrent_distinct_starts_never_exceed_parent_capacity() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    let mut baseline_runs = Vec::new();
    for index in 0..2 {
        let child = context
            .session_manager
            .create_session("mock", "/tmp", Some("baseline"))
            .unwrap();
        context.orchestrator.init_sequence_counter(&child, 0);
        baseline_runs.push(context.orchestrator.begin_run(&child, "run-1").unwrap());
        create_delegation(
            &deps,
            &parent,
            Some(&child),
            "running",
            &format!("baseline-{index}"),
        )
        .await;
    }
    let mut starts = tokio::task::JoinSet::new();
    for index in 0..12 {
        let deps = deps.clone();
        let parent = parent.clone();
        starts.spawn(async move {
            let payload = json!({"sessionId": parent, "objectiveSummary": format!("overlap-{index}"), "successCriteria": ["report"], "idempotencyKey": format!("overlap-{index}")});
            service::start(&invocation(&parent, "delegation::start", payload), &deps).await
        });
    }
    let mut max_active = 0;
    while !starts.is_empty() {
        let mut active = 0;
        for state in ["preparing", "running", "result_ready"] {
            active += deps
                .engine_host
                .list_resources(crate::engine::ListResources {
                    kind: Some(DELEGATION_KIND.to_owned()),
                    scope: Some(EngineResourceScope::Session(parent.clone())),
                    lifecycle: Some(state.to_owned()),
                    limit: 100,
                })
                .await
                .unwrap()
                .len();
        }
        max_active = max_active.max(active);
        assert!(active <= 3, "observed {active} active delegations");
        if starts.join_next().await.is_none() {
            break;
        }
    }
    assert!(max_active >= 2);
    drop(baseline_runs);
}

#[tokio::test]
async fn cancel_repairs_an_ended_child_before_attempting_terminal_overwrite() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    let child = context
        .session_manager
        .create_session("mock", "/tmp", Some("child"))
        .unwrap();
    context.orchestrator.init_sequence_counter(&child, 0);
    let run = context.orchestrator.begin_run(&child, "run-1").unwrap();
    let id = create_delegation(&deps, &parent, Some(&child), "running", "ended-child").await;
    drop(run);

    let inspection = deps
        .engine_host
        .inspect_resource(&id)
        .await
        .unwrap()
        .unwrap();
    let expected = inspection.resource.current_version_id.unwrap();
    let payload = json!({
        "sessionId": parent,
        "delegationResourceId": id,
        "expectedVersionId": expected,
        "idempotencyKey": "cancel-ended"
    });
    assert!(
        service::cancel(&invocation(&parent, "delegation::cancel", payload), &deps)
            .await
            .is_err(),
        "cancel must not replace lazy-repaired terminal state"
    );
    let repaired = deps
        .engine_host
        .inspect_resource(&id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(repaired.resource.lifecycle, "failed");
}

#[tokio::test]
async fn cancel_lost_response_replays_with_original_version_and_key() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    let child = context
        .session_manager
        .create_session("mock", "/tmp", Some("child"))
        .unwrap();
    context.orchestrator.init_sequence_counter(&child, 0);
    let _run = context.orchestrator.begin_run(&child, "run-1").unwrap();
    let id = create_delegation(&deps, &parent, Some(&child), "running", "cancel-replay").await;
    let original = deps
        .engine_host
        .inspect_resource(&id)
        .await
        .unwrap()
        .unwrap()
        .resource
        .current_version_id
        .unwrap();
    let payload = json!({"sessionId": parent, "delegationResourceId": id, "expectedVersionId": original, "idempotencyKey": "cancel-same"});
    let first = service::cancel(
        &invocation(&parent, "delegation::cancel", payload.clone()),
        &deps,
    )
    .await
    .unwrap();
    assert_eq!(first["delegation"]["state"], "cancelled");
    let replay = service::cancel(&invocation(&parent, "delegation::cancel", payload), &deps)
        .await
        .unwrap();
    assert_eq!(replay["replayed"], true);
}

#[tokio::test]
async fn restart_repair_rejects_intermediate_turn_and_selects_exact_final_run_result() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();

    let intermediate_child = context
        .session_manager
        .create_session("mock", "/tmp", Some("tool-loop"))
        .unwrap();
    append_assistant_and_turn_end(
        &context.event_store,
        &intermediate_child,
        1,
        "intermediate tool call",
        "run-1",
    );
    seed_agent_result(&deps, &intermediate_child, "run-other", "wrong result").await;
    let intermediate_id = create_delegation(
        &deps,
        &parent,
        Some(&intermediate_child),
        "running",
        "intermediate-only",
    )
    .await;
    let _ = service::inspect(
        &invocation(
            &parent,
            "delegation::inspect",
            json!({"sessionId": parent, "delegationResourceId": intermediate_id}),
        ),
        &deps,
    )
    .await
    .unwrap();
    assert_eq!(
        deps.engine_host
            .inspect_resource(&intermediate_id)
            .await
            .unwrap()
            .unwrap()
            .resource
            .lifecycle,
        "failed"
    );

    let final_child = context
        .session_manager
        .create_session("mock", "/tmp", Some("final-loop"))
        .unwrap();
    append_assistant_and_turn_end(
        &context.event_store,
        &final_child,
        1,
        "intermediate tool call",
        "run-1",
    );
    append_assistant_and_turn_end(
        &context.event_store,
        &final_child,
        2,
        "final exact answer",
        "run-1",
    );
    seed_agent_result(&deps, &final_child, "run-1", "final exact answer").await;
    let final_id =
        create_delegation(&deps, &parent, Some(&final_child), "running", "final-exact").await;
    let _ = service::inspect(
        &invocation(
            &parent,
            "delegation::inspect",
            json!({"sessionId": parent, "delegationResourceId": final_id}),
        ),
        &deps,
    )
    .await
    .unwrap();
    let repaired = deps
        .engine_host
        .inspect_resource(&final_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(repaired.resource.lifecycle, "result_ready");
    let version = repaired
        .versions
        .iter()
        .find(|version| {
            Some(version.version_id.as_str()) == repaired.resource.current_version_id.as_deref()
        })
        .unwrap();
    assert_eq!(version.payload["resultSummary"], "final exact answer");
    assert_eq!(version.payload["resultRefs"].as_array().unwrap().len(), 1);
}

fn append_assistant_and_turn_end(
    store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
    turn: i64,
    text: &str,
    run_id: &str,
) {
    store
        .append(&AppendOptions {
            session_id,
            event_type: EventType::MessageAssistant,
            payload: json!({"content": [{"type": "text", "text": text}], "turn": turn}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id,
            event_type: EventType::StreamTurnEnd,
            payload: json!({"turn": turn, "runId": run_id}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
}

async fn seed_agent_result(deps: &Deps, child: &str, run_id: &str, message: &str) {
    deps.engine_host.create_resource(crate::engine::CreateResource {
        resource_id: None, kind: "agent_result".to_owned(), schema_id: Some("tron.resource.agent_result.v1".to_owned()),
        scope: EngineResourceScope::Session(child.to_owned()), owner_worker_id: WorkerId::new("agent").unwrap(),
        owner_actor_id: crate::engine::ActorId::new("system:test").unwrap(), lifecycle: Some("final".to_owned()), policy: json!({}), locations: vec![],
        trace_id: TraceId::generate(), invocation_id: None,
        initial_payload: Some(json!({"message": message, "stopReason": "EndTurn", "metadata": {"runId": run_id, "interrupted": false}})),
    }).await.unwrap();
}

#[test]
fn exact_run_cancel_rejects_stale_identity() {
    let context = crate::shared::server::test_support::make_test_context();
    let session = context
        .session_manager
        .create_session("mock", "/tmp", Some("child"))
        .unwrap();
    let _run = context
        .orchestrator
        .begin_run(&session, "current-run")
        .unwrap();
    assert!(
        context
            .orchestrator
            .abort_run(&session, "stale-run")
            .is_err()
    );
    assert_eq!(
        context.orchestrator.get_run_id(&session).as_deref(),
        Some("current-run")
    );
    assert_eq!(
        context
            .orchestrator
            .abort_run(&session, "current-run")
            .unwrap(),
        true
    );
}

#[tokio::test]
async fn result_acceptance_requires_exact_version_and_replays_terminal_state() {
    let (context, deps) = deps();
    let parent = context
        .session_manager
        .create_session("mock", "/tmp", Some("parent"))
        .unwrap();
    let id = create_delegation(&deps, &parent, Some("child"), "result_ready", "ready").await;
    let inspection = deps
        .engine_host
        .inspect_resource(&id)
        .await
        .unwrap()
        .unwrap();
    let version = inspection.resource.current_version_id.clone().unwrap();
    let stale = json!({"sessionId": parent, "delegationResourceId": id, "expectedVersionId": "stale", "idempotencyKey": "accept"});
    assert!(
        service::accept_result(
            &invocation(&parent, "delegation::accept_result", stale),
            &deps
        )
        .await
        .is_err()
    );
    let accept = json!({"sessionId": parent, "delegationResourceId": id, "expectedVersionId": version, "idempotencyKey": "accept"});
    let accepted = service::accept_result(
        &invocation(&parent, "delegation::accept_result", accept),
        &deps,
    )
    .await
    .unwrap();
    assert_eq!(accepted["delegation"]["state"], "accepted");
    let replay = json!({"sessionId": parent, "delegationResourceId": id, "expectedVersionId": version, "idempotencyKey": "accept"});
    assert_eq!(
        service::accept_result(
            &invocation(&parent, "delegation::accept_result", replay),
            &deps
        )
        .await
        .unwrap()["replayed"],
        true
    );
}
