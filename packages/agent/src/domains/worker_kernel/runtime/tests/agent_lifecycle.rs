use super::*;
use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliverySourceKind, AgentDeliveryTarget,
    AgentDeliveryWakePolicy, NewAgentDelivery,
};

struct LifecycleResponder;

#[async_trait]
impl ModelResponder for LifecycleResponder {
    fn info(&self) -> ModelResponderInfo {
        ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::Anthropic,
            provider_name: "agent-lifecycle-test",
            model: "agent-lifecycle-test-model".to_owned(),
            context_window: 20_000,
        }
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        Ok(ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("Assignment complete.")],
                        token_usage: None,
                    },
                    stop_reason: "end_turn".to_owned(),
                }),
            ])) as ModelResponseStream,
        })
    }
}

struct LifecycleResponderFactory;

#[async_trait]
impl ModelResponderFactory for LifecycleResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(LifecycleResponder))
    }
}

fn lifecycle_invocation(
    actor_kind: ActorKind,
    function: &str,
    payload: Value,
    session_id: &str,
    workspace_id: &str,
    suffix: &str,
) -> Invocation {
    let mut causal = CausalContext::new(
        ActorId::new(format!("agent:lifecycle-{suffix}")).unwrap(),
        actor_kind,
        TraceId::new(format!("trace-agent-lifecycle-{suffix}")).unwrap(),
    )
    .with_session_id(session_id)
    .with_workspace_id(workspace_id)
    .with_working_directory("/tmp/agent-lifecycle");
    if let Some(key) = payload.get("clientMutationId").and_then(Value::as_str) {
        causal = causal.with_idempotency_key(key);
    }
    Invocation::new_sync(FunctionId::new(function).unwrap(), payload, causal)
}

async fn idle_lifecycle_child(
    runtime: &WorkerRuntime,
    root_session_id: &str,
    workspace_id: &str,
) -> crate::domains::worker_kernel::persistence::AgentInstanceRecord {
    let spawned = runtime
        .agent_spawn(&lifecycle_invocation(
            ActorKind::Agent,
            "worker_kernel::agent_spawn",
            json!({
                "task":"Become idle for lifecycle admission testing.",
                "name":"Lifecycle child",
                "tools":["agent_spawn","agent_send","agent_manage"]
            }),
            root_session_id,
            workspace_id,
            "spawn",
        ))
        .await
        .unwrap();
    let assignment = runtime
        .store
        .agent_assignment(spawned["assignmentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    runtime.drive_agent_assignment(assignment).await.unwrap();
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(
        child.state,
        crate::domains::worker_kernel::persistence::AgentInstanceState::Idle
    );
    child
}

fn action_enabled(document: &Value, action: &str) -> bool {
    action_projection(document, action)["enabled"]
        .as_bool()
        .unwrap()
}

fn action_projection<'a>(document: &'a Value, action: &str) -> &'a Value {
    document["allowedActions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|candidate| candidate["action"] == action)
        .unwrap_or_else(|| panic!("missing allowed action '{action}'"))
}

#[tokio::test]
async fn model_and_native_lifecycle_mutations_share_the_auxiliary_run_gate() {
    let (runtime, _home) = test_runtime(Some(Arc::new(LifecycleResponderFactory)));
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/agent-lifecycle",
            Some("Lifecycle owner"),
            None,
        )
        .unwrap()
        .session;
    let child = idle_lifecycle_child(&runtime, &root.id, &root.workspace_id).await;

    let admission_key = "reserved-auxiliary-lifecycle-run";
    let reservation = runtime
        .orchestrator
        .try_reserve_auxiliary_run(&child.session_id, admission_key)
        .expect("reserve pending auxiliary run");

    let model_error = runtime
        .agent_manage(&lifecycle_invocation(
            ActorKind::Agent,
            "worker_kernel::agent_manage",
            json!({"action":"close","agentId":child.agent_id}),
            &root.id,
            &root.workspace_id,
            "model-close-reserved",
        ))
        .await
        .unwrap_err();
    assert!(model_error.contains("transcript work is pending or active"));

    let native_error = runtime
        .client_agent_promote(&lifecycle_invocation(
            ActorKind::Client,
            "worker_kernel::client_agent_promote",
            json!({
                "ownerSessionId":root.id,
                "agentId":child.agent_id,
                "clientMutationId":"native-promote-reserved"
            }),
            &root.id,
            &root.workspace_id,
            "native-promote-reserved",
        ))
        .await
        .unwrap_err();
    assert!(native_error.contains("transcript work is pending or active"));

    let inspect = runtime
        .client_agent_inspect(&lifecycle_invocation(
            ActorKind::Client,
            "worker_kernel::client_agent_inspect",
            json!({"ownerSessionId":root.id,"agentId":child.agent_id}),
            &root.id,
            &root.workspace_id,
            "inspect-reserved",
        ))
        .await
        .unwrap();
    for action in ["configure", "promote", "close"] {
        assert!(!action_enabled(&inspect, action));
    }

    let active_run = runtime
        .orchestrator
        .begin_run_with_admission_key(&child.session_id, "active-auxiliary", Some(admission_key))
        .expect("consume the exact auxiliary reservation");
    drop(reservation);
    let native_close_error = runtime
        .client_agent_manage(&lifecycle_invocation(
            ActorKind::Client,
            "worker_kernel::client_agent_manage",
            json!({
                "ownerSessionId":root.id,
                "agentId":child.agent_id,
                "action":"close",
                "clientMutationId":"native-close-active"
            }),
            &root.id,
            &root.workspace_id,
            "native-close-active",
        ))
        .await
        .unwrap_err();
    assert!(native_close_error.contains("transcript work is pending or active"));
    drop(active_run);

    let configured = runtime
        .agent_manage(&lifecycle_invocation(
            ActorKind::Agent,
            "worker_kernel::agent_manage",
            json!({
                "action":"configure",
                "agentId":child.agent_id,
                "configuration":{}
            }),
            &root.id,
            &root.workspace_id,
            "model-configure-released",
        ))
        .await
        .unwrap();
    assert_eq!(configured["status"], "configured");
}

#[tokio::test]
async fn close_wins_before_wake_admission_and_closed_callers_stay_inert() {
    let (runtime, _home) = test_runtime(Some(Arc::new(LifecycleResponderFactory)));
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/agent-lifecycle-close",
            Some("Closed lifecycle owner"),
            None,
        )
        .unwrap()
        .session;
    let child = idle_lifecycle_child(&runtime, &root.id, &root.workspace_id).await;
    let pending = runtime
        .event_store
        .create_agent_delivery(&NewAgentDelivery {
            idempotency_key: "agent-lifecycle-delayed-import".to_owned(),
            source_kind: AgentDeliverySourceKind::AgentMessage,
            intent: Some(AgentDeliveryIntent::Information),
            source_session_id: Some(root.id.clone()),
            source_workspace_id: root.workspace_id.clone(),
            source_invocation_id: None,
            source_trace_id: Some("trace-agent-lifecycle-delayed-import".to_owned()),
            source_root_invocation_id: None,
            causal_depth: 1,
            target: AgentDeliveryTarget::Session {
                session_id: child.session_id.clone(),
            },
            wake_policy: AgentDeliveryWakePolicy::Wake,
            boundary: AgentDeliveryBoundary::NextTurn,
            originating_run_id: None,
            arrived_during_run_id: None,
            defer_until_run_id: None,
            result_invocation_id: None,
            content: "Durable message imported across the close boundary.".to_owned(),
            not_before: None,
            expires_at: None,
        })
        .unwrap();

    let closed = runtime
        .agent_manage(&lifecycle_invocation(
            ActorKind::Agent,
            "worker_kernel::agent_manage",
            json!({"action":"close","agentId":child.agent_id}),
            &root.id,
            &root.workspace_id,
            "model-close-before-wake",
        ))
        .await
        .unwrap();
    assert_eq!(closed["status"], "closed");

    assert_eq!(
        runtime
            .event_store
            .agent_delivery(&pending.delivery_id)
            .unwrap()
            .unwrap()
            .wake_policy,
        AgentDeliveryWakePolicy::Passive,
        "close must retain but proactively demote every pending wake"
    );

    runtime
        .request_agent_delivery_wake(&child.session_id, 1)
        .await;
    assert!(!runtime.orchestrator.has_active_run(&child.session_id));
    assert_eq!(
        runtime
            .event_store
            .agent_delivery(&pending.delivery_id)
            .unwrap()
            .unwrap()
            .wake_policy,
        AgentDeliveryWakePolicy::Passive
    );

    let closed_caller = runtime
        .agent_discover(&lifecycle_invocation(
            ActorKind::Agent,
            "worker_kernel::agent_discover",
            json!({"scope":"agents"}),
            &child.session_id,
            &child.workspace_id,
            "closed-caller",
        ))
        .await
        .unwrap_err();
    assert_eq!(closed_caller, "closed agents cannot use coordination tools");
}

#[tokio::test]
async fn subtree_cancel_revokes_reserved_and_active_auxiliary_runs_without_touching_a_peer() {
    let (runtime, _home) = test_runtime(Some(Arc::new(LifecycleResponderFactory)));
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/agent-lifecycle-cancel",
            Some("Auxiliary cancellation owner"),
            None,
        )
        .unwrap()
        .session;
    let child = idle_lifecycle_child(&runtime, &root.id, &root.workspace_id).await;
    let descendant = idle_lifecycle_child(&runtime, &child.session_id, &child.workspace_id).await;
    let peer = idle_lifecycle_child(&runtime, &root.id, &root.workspace_id).await;
    // The descendant's completed bootstrap assignment legitimately returned a
    // wake to its parent. Make that retained evidence passive so this test's
    // destructive-impact count isolates the live descendant reservation below.
    runtime.import_agent_coordination_outbox().await.unwrap();
    runtime.import_agent_delivery_outbox().await;
    runtime
        .event_store
        .demote_all_agent_wakes_for_session(&child.session_id)
        .unwrap();

    let mut reserved_wake = NewAgentDelivery {
        idempotency_key: "agent-lifecycle-reserved-cancel".to_owned(),
        source_kind: AgentDeliverySourceKind::AgentMessage,
        intent: Some(AgentDeliveryIntent::Information),
        source_session_id: Some(root.id.clone()),
        source_workspace_id: root.workspace_id.clone(),
        source_invocation_id: None,
        source_trace_id: Some("trace-agent-lifecycle-reserved-cancel".to_owned()),
        source_root_invocation_id: None,
        causal_depth: 1,
        target: AgentDeliveryTarget::Session {
            session_id: descendant.session_id.clone(),
        },
        wake_policy: AgentDeliveryWakePolicy::Wake,
        boundary: AgentDeliveryBoundary::NextTurn,
        originating_run_id: None,
        arrived_during_run_id: None,
        defer_until_run_id: None,
        result_invocation_id: None,
        content: "Reserved auxiliary cancellation evidence.".to_owned(),
        not_before: None,
        expires_at: None,
    };
    let reserved_wake_record = runtime
        .event_store
        .create_agent_delivery(&reserved_wake)
        .unwrap();
    let reservation_key = "cancel-reserved-auxiliary-run";
    let reservation = runtime
        .orchestrator
        .try_reserve_auxiliary_run(&descendant.session_id, reservation_key)
        .expect("reserve pending auxiliary run in the owned descendant");
    let peer_run = runtime
        .orchestrator
        .begin_run(&peer.session_id, "unrelated-peer-run")
        .unwrap();
    let peer_cancel = peer_run.cancel_token();

    let inspect = runtime
        .client_agent_inspect(&lifecycle_invocation(
            ActorKind::Client,
            "worker_kernel::client_agent_inspect",
            json!({"ownerSessionId":root.id,"agentId":child.agent_id}),
            &root.id,
            &root.workspace_id,
            "inspect-reserved-cancel",
        ))
        .await
        .unwrap();
    assert!(action_enabled(&inspect, "cancel"));
    let projected_affected = action_projection(&inspect, "cancel")["affectedCount"]
        .as_u64()
        .unwrap();
    assert!(projected_affected >= 1);

    let cancelled = runtime
        .agent_manage(&lifecycle_invocation(
            ActorKind::Agent,
            "worker_kernel::agent_manage",
            json!({
                "action":"cancel",
                "target":{"kind":"agent","id":child.agent_id}
            }),
            &root.id,
            &root.workspace_id,
            "model-cancel-reserved",
        ))
        .await
        .unwrap();
    assert_eq!(cancelled["affected"].as_u64(), Some(projected_affected));
    assert!(
        runtime
            .orchestrator
            .begin_run_with_admission_key(
                &descendant.session_id,
                "cancelled-reservation-run",
                Some(reservation_key),
            )
            .is_err(),
        "cancelled admission must remain blocked until its owner exits"
    );
    assert_eq!(
        runtime
            .event_store
            .agent_delivery(&reserved_wake_record.delivery_id)
            .unwrap()
            .unwrap()
            .wake_policy,
        AgentDeliveryWakePolicy::Passive
    );
    assert!(!peer_cancel.is_cancelled());
    drop(reservation);

    reserved_wake.idempotency_key = "agent-lifecycle-active-cancel".to_owned();
    reserved_wake.source_trace_id = Some("trace-agent-lifecycle-active-cancel".to_owned());
    reserved_wake.content = "Active auxiliary cancellation evidence.".to_owned();
    let active_wake = runtime
        .event_store
        .create_agent_delivery(&reserved_wake)
        .unwrap();
    let active_key = "cancel-active-auxiliary-run";
    let active_reservation = runtime
        .orchestrator
        .try_reserve_auxiliary_run(&descendant.session_id, active_key)
        .expect("reserve active auxiliary run in the owned descendant");
    let active_run = runtime
        .orchestrator
        .begin_run_with_admission_key(
            &descendant.session_id,
            "active-cancel-run",
            Some(active_key),
        )
        .unwrap();
    let active_cancel = active_run.cancel_token();
    drop(active_reservation);

    runtime
        .client_agent_manage(&lifecycle_invocation(
            ActorKind::Client,
            "worker_kernel::client_agent_manage",
            json!({
                "ownerSessionId":root.id,
                "agentId":child.agent_id,
                "action":"cancel",
                "clientMutationId":"native-cancel-active"
            }),
            &root.id,
            &root.workspace_id,
            "native-cancel-active",
        ))
        .await
        .unwrap();
    assert!(active_cancel.is_cancelled());
    assert!(!peer_cancel.is_cancelled());
    assert_eq!(
        runtime
            .event_store
            .agent_delivery(&active_wake.delivery_id)
            .unwrap()
            .unwrap()
            .wake_policy,
        AgentDeliveryWakePolicy::Passive
    );
    assert_eq!(
        runtime
            .store
            .agent_assignment_history_page(&peer.agent_id, 0, 1)
            .unwrap()
            .items[0]
            .status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed
    );
    drop(active_run);
    drop(peer_run);
}
