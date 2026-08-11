//! Coordination-message intent tests kept separate from wait/cancel scenarios.

use super::*;
use crate::domains::session::event_store::{AgentDeliveryIntent, AgentDeliveryWakePolicy};
use crate::domains::worker_kernel::persistence::{
    AgentAssignmentKind, AgentAssignmentStatus, AgentAssignmentTransition, NewAgentAssignment,
    NewAgentAssignmentMessage, NewRootAgent,
};
use crate::shared::protocol::messages::{AgentMessageAuthority, AgentMessageKind};

fn coordination_invocation(
    payload: Value,
    session_id: &str,
    workspace_id: &str,
    suffix: &str,
) -> Invocation {
    Invocation::new_sync(
        FunctionId::new("worker_kernel::agent_send").unwrap(),
        payload,
        CausalContext::new(
            ActorId::new(format!("agent:information-{suffix}")).unwrap(),
            ActorKind::Agent,
            TraceId::new(format!("trace-information-{suffix}")).unwrap(),
        )
        .with_session_id(session_id)
        .with_workspace_id(workspace_id)
        .with_working_directory("/tmp/project"),
    )
}

fn channel(first: &str, second: &str) -> String {
    let mut participants = [first, second];
    participants.sort_unstable();
    format!("agent_channel:{}:{}", participants[0], participants[1])
}

#[tokio::test]
async fn assignment_linked_information_wakes_safely_while_unlinked_information_is_passive() {
    let (runtime, _home) = test_runtime(None);
    let source_session = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Source"), None)
        .unwrap()
        .session;
    let target_session = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Target"), None)
        .unwrap()
        .session;
    let source = runtime
        .store
        .ensure_root_agent(&NewRootAgent {
            session_id: source_session.id.clone(),
            workspace_id: source_session.workspace_id.clone(),
            name: "Source".to_owned(),
            model: Some("gpt-5.6-sol".to_owned()),
            reasoning_level: None,
            tool_grant: json!(["agent_send"]),
            limits: json!({"maxAssignmentTurns":32}),
        })
        .unwrap();
    let target = runtime
        .store
        .ensure_root_agent(&NewRootAgent {
            session_id: target_session.id.clone(),
            workspace_id: target_session.workspace_id.clone(),
            name: "Target".to_owned(),
            model: Some("gpt-5.6-sol".to_owned()),
            reasoning_level: None,
            tool_grant: json!(["agent_send"]),
            limits: json!({"maxAssignmentTurns":32}),
        })
        .unwrap();
    let request = NewAgentAssignment {
        admission_key: "linked-information-assignment".to_owned(),
        agent_id: target.agent_id.clone(),
        requester_agent_id: Some(source.agent_id.clone()),
        delegator_agent_id: Some(source.agent_id.clone()),
        kind: AgentAssignmentKind::Instruction,
        offered: false,
        task: "Hold a durable waiting assignment.".to_owned(),
        context: json!({}),
        parent_execution_id: None,
        trace_id: "trace-linked-information-assignment".to_owned(),
        causal_depth: 1,
        child_slot: Some(0),
        max_active_children: 8,
        max_child_executions: 64,
        max_execution_nodes: 64,
        max_causal_depth: 16,
        max_queued_assignments: 8,
        model: None,
        reasoning_level: None,
        authority_snapshot: json!(["agent_send"]),
        resource_snapshot: json!({}),
        write_scopes_snapshot: json!([]),
        limits_snapshot: json!({"maxAssignmentTurns":32}),
        retry_of_assignment_id: None,
        deadline_at: None,
        message: NewAgentAssignmentMessage {
            deduplication_key: "linked-information-assignment-message".to_owned(),
            message_id: "linked-information-assignment-message".to_owned(),
            channel_id: channel(&source.agent_id, &target.agent_id),
            source_agent_id: source.agent_id.clone(),
            source_session_id: source.session_id.clone(),
            source_name: Some(source.name.clone()),
            target_session_id: target.session_id.clone(),
            kind: AgentMessageKind::Instruction,
            authority: AgentMessageAuthority::Owner,
            reply_to: None,
            text: "Hold a durable waiting assignment.".to_owned(),
            autonomous_hop: 1,
        },
    };
    let (assignment, _) = runtime.store.enqueue_agent_assignment(&request).unwrap();
    let initial_outbox = runtime
        .store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|row| row.assignment_id.as_deref() == Some(&assignment.assignment_id))
        .unwrap();
    runtime
        .store
        .mark_agent_outbox_imported(&initial_outbox.outbox_id)
        .unwrap();
    runtime
        .store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: assignment.assignment_id.clone(),
            expected_status: AgentAssignmentStatus::Accepted,
            target_status: AgentAssignmentStatus::Running,
            result: None,
            error: None,
        })
        .unwrap();
    runtime
        .store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: assignment.assignment_id.clone(),
            expected_status: AgentAssignmentStatus::Running,
            target_status: AgentAssignmentStatus::Waiting,
            result: None,
            error: None,
        })
        .unwrap();

    // Keep the target inside an existing provider boundary. A linked message
    // must be persisted as a wake for that next safe boundary, never interrupt
    // this run or start another one during the assertion.
    let _active_run = runtime
        .orchestrator
        .begin_run(&target.session_id, "run-linked-information")
        .unwrap();
    let linked_result = runtime
        .agent_send(&coordination_invocation(
            json!({
                "to":target.agent_id,
                "kind":"information",
                "content":"Evidence linked to the waiting assignment.",
                "assignmentId":assignment.assignment_id,
            }),
            &source.session_id,
            &source.workspace_id,
            "linked",
        ))
        .await
        .unwrap();
    let unlinked_result = runtime
        .agent_send(&coordination_invocation(
            json!({
                "to":target.agent_id,
                "kind":"information",
                "content":"Background evidence with no active coordination link.",
            }),
            &source.session_id,
            &source.workspace_id,
            "unlinked",
        ))
        .await
        .unwrap();

    let deliveries = runtime
        .event_store
        .list_agent_deliveries_for_session(&target.session_id, 20)
        .unwrap();
    let linked = deliveries
        .iter()
        .find(|delivery| {
            delivery
                .content
                .contains(linked_result["messageId"].as_str().unwrap())
        })
        .unwrap();
    let unlinked = deliveries
        .iter()
        .find(|delivery| {
            delivery
                .content
                .contains(unlinked_result["messageId"].as_str().unwrap())
        })
        .unwrap();
    assert_eq!(linked.wake_policy, AgentDeliveryWakePolicy::Wake);
    assert_eq!(linked.intent, Some(AgentDeliveryIntent::Request));
    assert_eq!(unlinked.wake_policy, AgentDeliveryWakePolicy::Passive);
    assert_eq!(unlinked.intent, Some(AgentDeliveryIntent::Information));
}
