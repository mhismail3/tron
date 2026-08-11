//! Semantic coordination-message and generalized-wait store tests.

use super::*;
use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliverySourceKind, AgentDeliveryTarget,
    AgentDeliveryWakePolicy, CoordinationDependencyEdge, CoordinationDependencyEdgeKind,
    CoordinationTargetKind, CoordinationTerminalEvidence, CoordinationWaitDependency,
    CoordinationWaitMode, CoordinationWaitTarget, NewAgentDelivery, NewAgentMessageMetadata,
    NewCoordinationWait,
};
use crate::shared::protocol::messages::{
    AgentMessageAuthority, AgentMessageContent, AgentMessageKind,
};

fn message(
    source_agent_id: &str,
    target_agent_id: &str,
    target_session_id: &str,
    id: &str,
    kind: AgentMessageKind,
    reply_to: Option<&str>,
) -> NewAgentMessageMetadata {
    let mut participants = [source_agent_id, target_agent_id];
    participants.sort_unstable();
    NewAgentMessageMetadata {
        idempotency_key: format!("send_{id}"),
        channel_id: format!("agent_channel:{}:{}", participants[0], participants[1]),
        channel_sequence: None,
        source_session_id: None,
        target_agent_id: target_agent_id.to_owned(),
        target_session_id: target_session_id.to_owned(),
        trace_id: "trace_coordination_test".to_owned(),
        autonomous_hop: 1,
        content: AgentMessageContent {
            message_id: id.to_owned(),
            source_agent_id: source_agent_id.to_owned(),
            source_name: Some("Coordinator".to_owned()),
            kind,
            authority: AgentMessageAuthority::Peer,
            text: "Inspect the durable evidence.".to_owned(),
            assignment_id: Some("assignment_test".to_owned()),
            reply_to: reply_to.map(ToOwned::to_owned),
        },
    }
}

fn wait_request(
    idempotency_key: &str,
    session_id: &str,
    owner_agent_id: &str,
    owner_assignment_id: Option<&str>,
    trace_id: &str,
    autonomous_hop: u32,
    mode: CoordinationWaitMode,
    targets: Vec<CoordinationWaitTarget>,
) -> NewCoordinationWait {
    let dependencies = targets
        .iter()
        .map(|target| CoordinationWaitDependency {
            target: target.clone(),
            dependency_id: format!("test_dependency:{:?}:{}", target.kind, target.id),
        })
        .collect();
    NewCoordinationWait {
        idempotency_key: idempotency_key.to_owned(),
        session_id: session_id.to_owned(),
        owner_agent_id: owner_agent_id.to_owned(),
        owner_assignment_id: owner_assignment_id.map(ToOwned::to_owned),
        trace_id: trace_id.to_owned(),
        autonomous_hop,
        mode,
        targets,
        owner_dependency_id: format!("coordination_agent:{owner_agent_id}"),
        dependencies,
        dependency_edges: Vec::new(),
    }
}

fn agent_dependency(agent_id: &str) -> String {
    format!("coordination_agent:{agent_id}")
}

fn execution_dependency(execution_id: &str) -> String {
    format!("coordination_execution:{execution_id}")
}

fn dependency_edge(
    source_dependency_id: String,
    target_dependency_id: String,
    kind: CoordinationDependencyEdgeKind,
) -> CoordinationDependencyEdge {
    CoordinationDependencyEdge {
        source_dependency_id,
        target_dependency_id,
        kind,
    }
}

#[test]
fn outgoing_message_is_durable_before_safe_boundary_and_materializes_once() {
    let store = setup();
    let target = store
        .create_session("model", "/tmp/coordination", None, None)
        .unwrap()
        .session;
    let request = message(
        "agent_source",
        "agent_target",
        &target.id,
        "agent_message_one",
        AgentMessageKind::Instruction,
        None,
    );
    let pending = store.record_agent_message(&request).unwrap();
    let replay = store.record_agent_message(&request).unwrap();
    assert_eq!(pending.message_id, replay.message_id);
    assert_eq!(
        store
            .coordination_message_count("trace_coordination_test")
            .unwrap(),
        1
    );
    let mut conflict = request.clone();
    conflict.content.text = "Conflicting replay content".to_owned();
    assert!(
        store
            .record_agent_message(&conflict)
            .unwrap_err()
            .to_string()
            .contains("idempotency conflict")
    );
    assert_eq!(pending.channel_sequence, 0);
    assert_eq!(
        pending.disposition,
        super::super::coordination::AgentMessageDisposition::Pending
    );
    assert_eq!(
        store
            .list_pending_agent_messages_for_session(&target.id, 20)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(store.count_events(&target.id).unwrap(), 1);

    let first = store
        .materialize_agent_message(&pending.message_id)
        .unwrap();
    let second = store
        .materialize_agent_message(&pending.message_id)
        .unwrap();
    assert!(first.created);
    assert!(!second.created);
    assert_eq!(first.event.id, second.event.id);
    assert_eq!(first.content, request.content);
    assert_eq!(store.count_events(&target.id).unwrap(), 2);
    assert_eq!(
        store
            .observe_agent_messages(&target.id, std::slice::from_ref(&pending.message_id))
            .unwrap(),
        1
    );

    let source_history = store
        .list_agent_messages_for_participant("agent_source", None, 20)
        .unwrap();
    let target_history = store
        .list_agent_messages_for_participant("agent_target", None, 20)
        .unwrap();
    assert_eq!(source_history.len(), 1);
    assert_eq!(target_history.len(), 1);
    assert_eq!(
        store.list_agent_correspondents("agent_source", 20).unwrap()[0].agent_id,
        "agent_target"
    );
}

#[test]
fn pending_message_can_be_cancelled_but_materialized_transcript_cannot() {
    let store = setup();
    let target = store
        .create_session("model", "/tmp/coordination-cancel", None, None)
        .unwrap()
        .session;
    let request = message(
        "agent_source",
        "agent_target",
        &target.id,
        "agent_message_cancel",
        AgentMessageKind::Information,
        None,
    );
    let pending = store.record_agent_message(&request).unwrap();
    assert!(
        store
            .cancel_pending_agent_message(&pending.message_id)
            .unwrap()
    );
    assert!(
        !store
            .cancel_pending_agent_message(&pending.message_id)
            .unwrap()
    );
    assert!(
        store
            .materialize_agent_message(&pending.message_id)
            .unwrap_err()
            .to_string()
            .contains("cancelled before materialization")
    );
    assert_eq!(store.count_events(&target.id).unwrap(), 1);
}

#[test]
fn message_correspondent_and_unread_pages_continue_beyond_two_hundred() {
    let store = setup();
    let target = store
        .create_session("model", "/tmp/coordination-pages", None, None)
        .unwrap()
        .session;
    for ordinal in 0..205_u32 {
        store
            .record_agent_message(&message(
                "agent_source",
                &format!("agent_target_{ordinal:03}"),
                &target.id,
                &format!("agent_message_page_{ordinal:03}"),
                AgentMessageKind::Information,
                None,
            ))
            .unwrap();
    }

    let first_correspondents = store
        .agent_correspondent_page("agent_source", &[], 0, 200)
        .unwrap();
    let second_correspondents = store
        .agent_correspondent_page("agent_source", &[], 200, 200)
        .unwrap();
    assert_eq!(first_correspondents.total, 205);
    assert_eq!(first_correspondents.items.len(), 200);
    assert_eq!(second_correspondents.items.len(), 5);
    let exclusions = (0..3_u32)
        .map(|ordinal| format!("agent_target_{ordinal:03}"))
        .collect::<Vec<_>>();
    assert_eq!(
        store
            .agent_correspondent_page("agent_source", &exclusions, 0, 1)
            .unwrap()
            .total,
        202
    );

    let first_unread = store
        .unobserved_agent_message_page(&target.id, 0, 200)
        .unwrap();
    let second_unread = store
        .unobserved_agent_message_page(&target.id, 200, 200)
        .unwrap();
    assert_eq!(first_unread.total, 205);
    assert_eq!(first_unread.items.len(), 200);
    assert_eq!(second_unread.items.len(), 5);

    // Communication history is keyset-paged, so an old message cannot become
    // unreachable merely because more than one bounded page was written.
    let first_history = store
        .list_agent_messages_for_participant("agent_source", None, 100)
        .unwrap();
    let first_cursor = first_history.last().unwrap();
    let second_history = store
        .list_agent_messages_for_participant(
            "agent_source",
            Some((&first_cursor.created_at, &first_cursor.message_id)),
            100,
        )
        .unwrap();
    let second_cursor = second_history.last().unwrap();
    let third_history = store
        .list_agent_messages_for_participant(
            "agent_source",
            Some((&second_cursor.created_at, &second_cursor.message_id)),
            100,
        )
        .unwrap();
    assert_eq!(first_history.len(), 100);
    assert_eq!(second_history.len(), 100);
    assert_eq!(third_history.len(), 5);
}

#[test]
fn answers_require_the_exact_reverse_question_pair() {
    let store = setup();
    let first = store
        .create_session("model", "/tmp/coordination-answer-a", None, None)
        .unwrap()
        .session;
    let second = store
        .create_session("model", "/tmp/coordination-answer-b", None, None)
        .unwrap()
        .session;
    let mut question = message(
        "agent_a",
        "agent_b",
        &second.id,
        "question_one",
        AgentMessageKind::Question,
        None,
    );
    question.source_session_id = Some(first.id);
    store.record_agent_message(&question).unwrap();

    let answer = message(
        "agent_b",
        "agent_a",
        &question.source_session_id.clone().unwrap(),
        "answer_one",
        AgentMessageKind::Answer,
        Some("question_one"),
    );
    store.record_agent_message(&answer).unwrap();
    let wrong = message(
        "agent_other",
        "agent_a",
        &question.source_session_id.unwrap(),
        "answer_wrong",
        AgentMessageKind::Answer,
        Some("question_one"),
    );
    assert!(
        store
            .record_agent_message(&wrong)
            .unwrap_err()
            .to_string()
            .contains("exact question sender/recipient pair")
    );
}

#[test]
fn generalized_wait_fans_in_and_rejects_cycles() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/coordination-wait", None, None)
        .unwrap()
        .session;
    let mut first_request = wait_request(
        "wait_a_on_b",
        &session.id,
        "agent_a",
        Some("assignment_a"),
        "trace_wait_a",
        3,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::AgentAssignment,
            id: "assignment_b".to_owned(),
        }],
    );
    first_request.dependencies[0].dependency_id = execution_dependency("execution_b");
    first_request.dependency_edges = vec![dependency_edge(
        execution_dependency("execution_b"),
        agent_dependency("agent_b"),
        CoordinationDependencyEdgeKind::Executor,
    )];
    let first = store.create_coordination_wait(&first_request, &[]).unwrap();
    assert_eq!(first.wait.disposition, "pending");
    assert!(
        store
            .has_pending_coordination_wait_for_agent("agent_a")
            .unwrap()
    );
    let replay_conflict = store
        .create_coordination_wait(
            &wait_request(
                "wait_a_on_b",
                &session.id,
                "agent_a",
                Some("assignment_a"),
                "trace_wait_a",
                3,
                CoordinationWaitMode::All,
                vec![CoordinationWaitTarget {
                    kind: CoordinationTargetKind::AgentAssignment,
                    id: "assignment_other".to_owned(),
                }],
            ),
            &[],
        )
        .unwrap_err();
    assert!(replay_conflict.to_string().contains("idempotency conflict"));
    let mut reciprocal_request = wait_request(
        "wait_b_on_a",
        &session.id,
        "agent_b",
        Some("assignment_b"),
        "trace_wait_b",
        0,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::AgentAssignment,
            id: "assignment_a".to_owned(),
        }],
    );
    reciprocal_request.dependencies[0].dependency_id = execution_dependency("execution_a");
    reciprocal_request.dependency_edges = vec![dependency_edge(
        execution_dependency("execution_a"),
        agent_dependency("agent_a"),
        CoordinationDependencyEdgeKind::Executor,
    )];
    let cycle = store
        .create_coordination_wait(&reciprocal_request, &[])
        .unwrap_err();
    assert!(cycle.to_string().contains("AGENT_WAIT_CYCLE"));

    assert!(
        store
            .coordination_wait_owns_automatic_delivery(
                &CoordinationWaitTarget {
                    kind: CoordinationTargetKind::AgentAssignment,
                    id: "assignment_b".to_owned(),
                },
                &session.id,
                Some("agent_a"),
            )
            .unwrap()
    );

    let resolved = store
        .reconcile_coordination_waits(&[CoordinationTerminalEvidence {
            target: CoordinationWaitTarget {
                kind: CoordinationTargetKind::AgentAssignment,
                id: "assignment_b".to_owned(),
            },
            status: "completed".to_owned(),
            evidence_reference: serde_json::json!({"resultId":"agent_result_b"}),
        }])
        .unwrap();
    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved[0].wait.wait_id, first.wait.wait_id);
    assert_eq!(resolved[0].satisfied.len(), 1);
    let recovered = store.reconcile_coordination_waits(&[]).unwrap();
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].wait.wait_id, first.wait.wait_id);
    let conflict = store
        .reconcile_coordination_waits(&[CoordinationTerminalEvidence {
            target: CoordinationWaitTarget {
                kind: CoordinationTargetKind::AgentAssignment,
                id: "assignment_b".to_owned(),
            },
            status: "failed".to_owned(),
            evidence_reference: serde_json::json!({"error":"contradictory replay"}),
        }])
        .unwrap_err();
    assert!(conflict.to_string().contains("terminal evidence conflict"));

    let mut aggregate = message(
        "agent_engine",
        "agent_a",
        &session.id,
        "wait_a_aggregate",
        AgentMessageKind::Result,
        None,
    );
    aggregate.content.authority = AgentMessageAuthority::Engine;
    let aggregate = store.record_agent_message(&aggregate).unwrap();
    assert!(
        store
            .bind_coordination_wait_message(&first.wait.wait_id, &aggregate.message_id)
            .unwrap()
    );
    assert!(store.reconcile_coordination_waits(&[]).unwrap().is_empty());
    assert!(
        !store
            .has_pending_coordination_wait_for_agent("agent_a")
            .unwrap()
    );
    assert!(
        store
            .coordination_wait_owns_automatic_delivery(
                &CoordinationWaitTarget {
                    kind: CoordinationTargetKind::AgentAssignment,
                    id: "assignment_b".to_owned(),
                },
                &session.id,
                Some("agent_a"),
            )
            .unwrap()
    );
}

#[test]
fn normalized_wait_graph_rejects_self_and_descendant_to_ancestor_cycles() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/coordination-topology", None, None)
        .unwrap()
        .session;

    let mut self_wait = wait_request(
        "wait_self",
        &session.id,
        "agent_self",
        Some("assignment_self"),
        "trace_self",
        0,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::AgentAssignment,
            id: "assignment_self".to_owned(),
        }],
    );
    self_wait.dependencies[0].dependency_id = execution_dependency("execution_self");
    self_wait.dependency_edges = vec![dependency_edge(
        execution_dependency("execution_self"),
        agent_dependency("agent_self"),
        CoordinationDependencyEdgeKind::Executor,
    )];
    let self_cycle = store.create_coordination_wait(&self_wait, &[]).unwrap_err();
    assert!(self_cycle.to_string().contains("AGENT_WAIT_CYCLE"));

    let topology = vec![
        dependency_edge(
            execution_dependency("execution_parent"),
            execution_dependency("execution_child"),
            CoordinationDependencyEdgeKind::Causal,
        ),
        dependency_edge(
            execution_dependency("execution_parent"),
            agent_dependency("agent_parent"),
            CoordinationDependencyEdgeKind::Executor,
        ),
        dependency_edge(
            execution_dependency("execution_child"),
            agent_dependency("agent_child"),
            CoordinationDependencyEdgeKind::Executor,
        ),
    ];
    let mut legal_parent_wait = wait_request(
        "wait_parent_on_descendant",
        &session.id,
        "agent_parent",
        Some("assignment_parent"),
        "trace_parent_child",
        0,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::AgentAssignment,
            id: "assignment_child".to_owned(),
        }],
    );
    legal_parent_wait.dependencies[0].dependency_id = execution_dependency("execution_child");
    legal_parent_wait.dependency_edges.clone_from(&topology);
    assert_eq!(
        store
            .create_coordination_wait(&legal_parent_wait, &[])
            .unwrap()
            .wait
            .disposition,
        "pending"
    );

    let mut illegal_child_wait = wait_request(
        "wait_descendant_on_parent",
        &session.id,
        "agent_child",
        Some("assignment_child"),
        "trace_parent_child",
        0,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::AgentAssignment,
            id: "assignment_parent".to_owned(),
        }],
    );
    illegal_child_wait.dependencies[0].dependency_id = execution_dependency("execution_parent");
    illegal_child_wait.dependency_edges = topology;
    let ancestor_cycle = store
        .create_coordination_wait(&illegal_child_wait, &[])
        .unwrap_err();
    assert!(ancestor_cycle.to_string().contains("AGENT_WAIT_CYCLE"));
}

#[test]
fn normalized_wait_graph_rejects_mutual_replies_and_topology_replay_drift() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/coordination-replies", None, None)
        .unwrap()
        .session;
    let mut a_waits_b = wait_request(
        "reply_a_waits_b",
        &session.id,
        "agent_a",
        None,
        "trace_reply_cycle",
        0,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::Reply,
            id: "question_a_to_b".to_owned(),
        }],
    );
    a_waits_b.dependencies[0].dependency_id = agent_dependency("agent_b");
    let admitted = store.create_coordination_wait(&a_waits_b, &[]).unwrap();
    let replay = store.create_coordination_wait(&a_waits_b, &[]).unwrap();
    assert_eq!(replay.wait.wait_id, admitted.wait.wait_id);

    let mut drifted = a_waits_b.clone();
    drifted.dependencies[0].dependency_id = agent_dependency("agent_other");
    let drift = store.create_coordination_wait(&drifted, &[]).unwrap_err();
    assert!(
        drift
            .to_string()
            .contains("dependency idempotency conflict")
    );
    let mut topology_drift = a_waits_b.clone();
    topology_drift.dependency_edges.push(dependency_edge(
        execution_dependency("unexpected_parent"),
        execution_dependency("unexpected_child"),
        CoordinationDependencyEdgeKind::Causal,
    ));
    let topology_drift = store
        .create_coordination_wait(&topology_drift, &[])
        .unwrap_err();
    assert!(
        topology_drift
            .to_string()
            .contains("topology idempotency conflict")
    );

    let mut b_waits_a = wait_request(
        "reply_b_waits_a",
        &session.id,
        "agent_b",
        None,
        "trace_reply_cycle",
        0,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::Reply,
            id: "question_b_to_a".to_owned(),
        }],
    );
    b_waits_a.dependencies[0].dependency_id = agent_dependency("agent_a");
    let cycle = store.create_coordination_wait(&b_waits_a, &[]).unwrap_err();
    assert!(cycle.to_string().contains("AGENT_WAIT_CYCLE"));
}

#[test]
fn normalized_wait_graph_rejects_mixed_assignment_worker_cycle() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/coordination-mixed", None, None)
        .unwrap()
        .session;
    let topology = vec![
        dependency_edge(
            execution_dependency("execution_assignment"),
            execution_dependency("execution_worker"),
            CoordinationDependencyEdgeKind::Causal,
        ),
        dependency_edge(
            execution_dependency("execution_assignment"),
            agent_dependency("agent_parent"),
            CoordinationDependencyEdgeKind::Executor,
        ),
        dependency_edge(
            execution_dependency("execution_worker"),
            agent_dependency("agent_worker"),
            CoordinationDependencyEdgeKind::Executor,
        ),
    ];
    let mut parent_wait = wait_request(
        "assignment_waits_worker",
        &session.id,
        "agent_parent",
        Some("assignment_parent"),
        "trace_mixed",
        0,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::WorkerInvocation,
            id: "worker_invocation".to_owned(),
        }],
    );
    parent_wait.dependencies[0].dependency_id = execution_dependency("execution_worker");
    parent_wait.dependency_edges.clone_from(&topology);
    store.create_coordination_wait(&parent_wait, &[]).unwrap();

    let mut worker_wait = wait_request(
        "worker_waits_assignment",
        &session.id,
        "agent_worker",
        Some("assignment_direct_worker"),
        "trace_mixed",
        0,
        CoordinationWaitMode::All,
        vec![CoordinationWaitTarget {
            kind: CoordinationTargetKind::AgentAssignment,
            id: "assignment_parent".to_owned(),
        }],
    );
    worker_wait.dependencies[0].dependency_id = execution_dependency("execution_assignment");
    worker_wait.dependency_edges = topology;
    let cycle = store
        .create_coordination_wait(&worker_wait, &[])
        .unwrap_err();
    assert!(cycle.to_string().contains("AGENT_WAIT_CYCLE"));
}

#[test]
fn wait_member_ownership_is_exact_to_the_registering_recipient() {
    let store = setup();
    let delegator_session = store
        .create_session("model", "/tmp/wait-delegator", None, None)
        .unwrap()
        .session;
    let manager_session = store
        .create_session("model", "/tmp/wait-manager", None, None)
        .unwrap()
        .session;
    let target = CoordinationWaitTarget {
        kind: CoordinationTargetKind::AgentAssignment,
        id: "shared_assignment".to_owned(),
    };
    let admitted = store
        .create_coordination_wait(
            &wait_request(
                "manager_waits_on_shared_assignment",
                &manager_session.id,
                "agent_manager",
                None,
                "trace_manager_wait",
                0,
                CoordinationWaitMode::All,
                vec![target.clone()],
            ),
            &[],
        )
        .unwrap();

    assert!(
        !store
            .coordination_wait_owns_automatic_delivery(
                &target,
                &delegator_session.id,
                Some("agent_delegator"),
            )
            .unwrap(),
        "a manager's wait must not consume the delegator's automatic result"
    );
    assert!(
        store
            .coordination_wait_owns_automatic_delivery(
                &target,
                &manager_session.id,
                Some("agent_manager"),
            )
            .unwrap()
    );
    assert!(
        !store
            .coordination_wait_owns_automatic_delivery(
                &target,
                &manager_session.id,
                Some("agent_other"),
            )
            .unwrap(),
        "session equality must not mask an agent ownership mismatch"
    );
    assert!(
        store
            .coordination_wait_owns_automatic_delivery(&target, &manager_session.id, None)
            .unwrap(),
        "session-only ownership remains available to legacy worker recipients"
    );

    let resolutions = store
        .reconcile_coordination_waits(&[CoordinationTerminalEvidence {
            target: target.clone(),
            status: "completed".to_owned(),
            evidence_reference: serde_json::json!({"resultId":"shared_result"}),
        }])
        .unwrap();
    assert_eq!(resolutions.len(), 1);
    let mut aggregate = message(
        "agent_engine",
        "agent_manager",
        &manager_session.id,
        "manager_aggregate",
        AgentMessageKind::Result,
        None,
    );
    aggregate.content.authority = AgentMessageAuthority::Engine;
    let aggregate = store.record_agent_message(&aggregate).unwrap();
    assert!(
        store
            .bind_coordination_wait_message(&admitted.wait.wait_id, &aggregate.message_id)
            .unwrap()
    );
    assert!(
        store
            .coordination_wait_owns_automatic_delivery(
                &target,
                &manager_session.id,
                Some("agent_manager"),
            )
            .unwrap(),
        "terminal replay must retain the recipient's aggregate ownership marker"
    );
}

#[test]
fn wait_registration_atomically_absorbs_imported_agent_result_and_wake() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/coordination-imported-agent", None, None)
        .unwrap()
        .session;
    let mut result = message(
        "agent_child",
        "agent_parent",
        &session.id,
        "assignment_result_message",
        AgentMessageKind::Result,
        None,
    );
    result.content.assignment_id = Some("assignment_done".to_owned());
    result.content.authority = AgentMessageAuthority::Engine;
    result.content.text = serde_json::json!({
        "assignmentId":"assignment_done",
        "status":"completed",
        "result":{"resultId":"result_done"},
        "error":null,
    })
    .to_string();
    let metadata = store.record_agent_message(&result).unwrap();
    let delivery = store
        .create_agent_delivery(&NewAgentDelivery {
            idempotency_key: format!("agent-message-delivery:{}", metadata.message_id),
            source_kind: AgentDeliverySourceKind::AgentMessage,
            intent: Some(AgentDeliveryIntent::Request),
            source_session_id: None,
            source_workspace_id: session.workspace_id.clone(),
            source_invocation_id: None,
            source_trace_id: Some("trace_imported_agent".to_owned()),
            source_root_invocation_id: None,
            causal_depth: 1,
            target: AgentDeliveryTarget::Session {
                session_id: session.id.clone(),
            },
            wake_policy: AgentDeliveryWakePolicy::Wake,
            boundary: AgentDeliveryBoundary::NextTurn,
            originating_run_id: None,
            arrived_during_run_id: None,
            defer_until_run_id: None,
            result_invocation_id: None,
            content: serde_json::json!({
                "protocol":crate::domains::worker_kernel::AGENT_COORDINATION_CAPABILITY,
                "messageId":metadata.message_id,
            })
            .to_string(),
            not_before: None,
            expires_at: None,
        })
        .unwrap();
    let admitted = store
        .create_coordination_wait(
            &wait_request(
                "wait_imported_agent",
                &session.id,
                "agent_parent",
                Some("assignment_parent"),
                "trace_wait_imported_agent",
                4,
                CoordinationWaitMode::All,
                vec![CoordinationWaitTarget {
                    kind: CoordinationTargetKind::AgentAssignment,
                    id: "assignment_done".to_owned(),
                }],
            ),
            &[],
        )
        .unwrap();
    assert_eq!(admitted.wait.disposition, "satisfied");
    assert_eq!(admitted.resolution.unwrap().satisfied.len(), 1);
    assert!(
        store.reconcile_coordination_waits(&[]).unwrap().is_empty(),
        "an immediately returned wait result must be durably consumed by the tool call"
    );
    assert_eq!(
        store
            .agent_message_metadata(&metadata.message_id)
            .unwrap()
            .unwrap()
            .disposition,
        super::super::coordination::AgentMessageDisposition::Cancelled
    );
    assert_eq!(
        store
            .agent_delivery(&delivery.delivery_id)
            .unwrap()
            .unwrap()
            .disposition,
        super::super::deliveries::AgentDeliveryDisposition::Cancelled
    );
    assert!(store.pending_agent_wakes(20).unwrap().is_empty());
}

#[test]
fn wait_registration_absorbs_imported_worker_result_and_any_releases_others() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/coordination-imported-worker", None, None)
        .unwrap()
        .session;
    let delivery = store
        .create_agent_delivery(&NewAgentDelivery {
            idempotency_key: "worker-terminal:worker_done".to_owned(),
            source_kind: AgentDeliverySourceKind::WorkerResult,
            intent: Some(AgentDeliveryIntent::Information),
            source_session_id: Some(session.id.clone()),
            source_workspace_id: session.workspace_id.clone(),
            source_invocation_id: Some("worker_done".to_owned()),
            source_trace_id: Some("trace_imported_worker".to_owned()),
            source_root_invocation_id: None,
            causal_depth: 1,
            target: AgentDeliveryTarget::Session {
                session_id: session.id.clone(),
            },
            wake_policy: AgentDeliveryWakePolicy::Wake,
            boundary: AgentDeliveryBoundary::NextTurn,
            originating_run_id: None,
            arrived_during_run_id: None,
            defer_until_run_id: None,
            result_invocation_id: Some("worker_done".to_owned()),
            content: serde_json::json!({
                "kind":"worker_result",
                "invocationId":"worker_done",
                "status":"completed",
                "evidence":{"reference":{"kind":"worker_result_reference"}},
            })
            .to_string(),
            not_before: None,
            expires_at: None,
        })
        .unwrap();
    let admitted = store
        .create_coordination_wait(
            &wait_request(
                "wait_imported_worker",
                &session.id,
                "agent_parent",
                Some("assignment_parent"),
                "trace_wait_imported_worker",
                5,
                CoordinationWaitMode::Any,
                vec![
                    CoordinationWaitTarget {
                        kind: CoordinationTargetKind::AgentAssignment,
                        id: "assignment_later".to_owned(),
                    },
                    CoordinationWaitTarget {
                        kind: CoordinationTargetKind::WorkerInvocation,
                        id: "worker_done".to_owned(),
                    },
                ],
            ),
            &[],
        )
        .unwrap();
    let resolution = admitted.resolution.unwrap();
    assert_eq!(resolution.satisfied.len(), 1);
    assert!(
        store.reconcile_coordination_waits(&[]).unwrap().is_empty(),
        "an immediately returned any-wait must not later emit an aggregate wake"
    );
    let members = store
        .coordination_wait_members(&admitted.wait.wait_id)
        .unwrap();
    assert_eq!(members[0].disposition, "released");
    assert_eq!(members[1].disposition, "satisfied");
    assert_eq!(
        store
            .agent_delivery(&delivery.delivery_id)
            .unwrap()
            .unwrap()
            .disposition,
        super::super::deliveries::AgentDeliveryDisposition::Cancelled
    );
}

#[test]
fn completion_delivery_admitted_after_initial_resolution_is_born_cancelled() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/coordination-late-delivery", None, None)
        .unwrap()
        .session;
    let target = CoordinationWaitTarget {
        kind: CoordinationTargetKind::AgentAssignment,
        id: "assignment_already_done".to_owned(),
    };
    let admitted = store
        .create_coordination_wait(
            &wait_request(
                "wait_initial_terminal",
                &session.id,
                "agent_parent",
                Some("assignment_parent"),
                "trace_wait_initial_terminal",
                2,
                CoordinationWaitMode::All,
                vec![target.clone()],
            ),
            &[CoordinationTerminalEvidence {
                target,
                status: "completed".to_owned(),
                evidence_reference: serde_json::json!({
                    "assignmentId":"assignment_already_done",
                    "result":null,
                    "error":null,
                }),
            }],
        )
        .unwrap();
    assert_eq!(admitted.wait.disposition, "satisfied");
    assert!(
        store.reconcile_coordination_waits(&[]).unwrap().is_empty(),
        "initial terminal evidence is delivered inline exactly once"
    );
    let mut result = message(
        "agent_child",
        "agent_parent",
        &session.id,
        "late_assignment_result_message",
        AgentMessageKind::Result,
        None,
    );
    result.content.assignment_id = Some("assignment_already_done".to_owned());
    result.content.authority = AgentMessageAuthority::Engine;
    result.content.text = serde_json::json!({
        "assignmentId":"assignment_already_done",
        "status":"completed",
        "result":null,
        "error":null,
    })
    .to_string();
    let metadata = store.record_agent_message(&result).unwrap();
    let delivery = store
        .create_agent_delivery(&NewAgentDelivery {
            idempotency_key: format!("agent-message-delivery:{}", metadata.message_id),
            source_kind: AgentDeliverySourceKind::AgentMessage,
            intent: Some(AgentDeliveryIntent::Request),
            source_session_id: None,
            source_workspace_id: session.workspace_id,
            source_invocation_id: None,
            source_trace_id: Some("trace_late_delivery".to_owned()),
            source_root_invocation_id: None,
            causal_depth: 1,
            target: AgentDeliveryTarget::Session {
                session_id: session.id,
            },
            wake_policy: AgentDeliveryWakePolicy::Wake,
            boundary: AgentDeliveryBoundary::NextTurn,
            originating_run_id: None,
            arrived_during_run_id: None,
            defer_until_run_id: None,
            result_invocation_id: None,
            content: serde_json::json!({
                "protocol":crate::domains::worker_kernel::AGENT_COORDINATION_CAPABILITY,
                "messageId":metadata.message_id,
            })
            .to_string(),
            not_before: None,
            expires_at: None,
        })
        .unwrap();
    assert_eq!(
        delivery.disposition,
        super::super::deliveries::AgentDeliveryDisposition::Cancelled
    );
    assert_eq!(
        store
            .agent_message_metadata(&metadata.message_id)
            .unwrap()
            .unwrap()
            .disposition,
        super::super::coordination::AgentMessageDisposition::Cancelled
    );
}

#[test]
fn assignment_cancellation_releases_every_wait_beyond_the_audit_page_limit() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/coordination-cancel-many", None, None)
        .unwrap()
        .session;
    for ordinal in 0..205 {
        store
            .create_coordination_wait(
                &wait_request(
                    &format!("wait_many_{ordinal}"),
                    &session.id,
                    "agent_many",
                    Some("assignment_many"),
                    "trace_wait_many",
                    0,
                    CoordinationWaitMode::All,
                    vec![CoordinationWaitTarget {
                        kind: CoordinationTargetKind::Reply,
                        id: format!("question_many_{ordinal}"),
                    }],
                ),
                &[],
            )
            .unwrap();
    }
    assert_eq!(
        store
            .list_coordination_waits(&session.id, 500)
            .unwrap()
            .len(),
        200,
        "the audit read remains deliberately page-bounded"
    );
    assert!(
        store
            .has_pending_coordination_wait_for_assignment("assignment_many")
            .unwrap()
    );
    assert_eq!(
        store
            .cancel_coordination_waits_for_assignment("assignment_many")
            .unwrap(),
        205
    );
    assert!(
        !store
            .has_pending_coordination_wait_for_assignment("assignment_many")
            .unwrap()
    );
    assert_eq!(
        store
            .cancel_coordination_waits_for_assignment("assignment_many")
            .unwrap(),
        0,
        "cancellation replay must be idempotent"
    );
}
