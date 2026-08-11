//! Focused core coordination service tests.

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::{ConnectionPool, EventStore, ensure_schema};

fn setup() -> (ConnectionPool, Arc<EventStore>, CoordinationService) {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let connection = pool.get().unwrap();
        ensure_schema(&connection).unwrap();
    }
    let store = Arc::new(EventStore::new(pool.clone()));
    let service = CoordinationService::new(store.clone());
    (pool, store, service)
}

fn root(store: &EventStore, service: &CoordinationService, path: &str, name: &str) -> AgentRecord {
    let session = store
        .create_session("test-model", path, Some(name), None)
        .unwrap()
        .session;
    service
        .ensure_root_agent(&EnsureRootAgent {
            transcript_session_id: session.id,
            name: name.to_owned(),
            defaults: AgentDefaults::default(),
        })
        .unwrap()
}

fn spawn(
    service: &CoordinationService,
    root: &AgentRecord,
    key: &str,
    name: &str,
    parent_assignment_id: Option<&str>,
    trace_id: Option<&str>,
) -> AgentAdmission {
    service
        .spawn(&SpawnAgent {
            admission_key: key.to_owned(),
            parent_agent_id: root.agent_id.clone(),
            parent_assignment_id: parent_assignment_id.map(ToOwned::to_owned),
            name: name.to_owned(),
            task: format!("Complete {name}'s first assignment"),
            context: json!({"fixture":name}),
            defaults: AgentDefaults::default(),
            trace_id: trace_id.map(ToOwned::to_owned),
            autonomous_hop: 0,
            deadline_at: None,
        })
        .unwrap()
}

#[test]
fn root_and_spawn_are_stable_atomic_and_worker_independent() {
    let (pool, store, service) = setup();
    let root = root(&store, &service, "/tmp/core-coordination-root", "Root");
    let replayed_root = service
        .ensure_root_agent(&EnsureRootAgent {
            transcript_session_id: root.transcript_session_id.clone(),
            name: "A later display proposal".to_owned(),
            defaults: AgentDefaults::default(),
        })
        .unwrap();
    assert_eq!(root.agent_id, replayed_root.agent_id);
    assert_eq!(replayed_root.name, "Root");

    let child = spawn(&service, &root, "spawn-child", "Researcher", None, None);
    assert!(child.created);
    assert_eq!(child.assignment.status, AssignmentStatus::Queued);
    assert_eq!(child.agent.parent_agent_id, Some(root.agent_id.clone()));
    assert_eq!(child.agent.root_agent_id, root.agent_id);
    assert!(
        store
            .get_session(&child.agent.transcript_session_id)
            .unwrap()
            .unwrap()
            .is_agent_session()
    );
    let replay = spawn(&service, &root, "spawn-child", "Researcher", None, None);
    assert!(!replay.created);
    assert_eq!(replay.agent.agent_id, child.agent.agent_id);
    assert_eq!(
        replay.assignment.assignment_id,
        child.assignment.assignment_id
    );
    assert_eq!(
        replay.agent.transcript_session_id,
        child.agent.transcript_session_id
    );

    let connection = pool.get().unwrap();
    for table in ["agents", "agent_assignments"] {
        let mut statement = connection
            .prepare(&format!("PRAGMA table_info({table})"))
            .unwrap();
        let columns = statement
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        for removed in [
            "execution_id",
            "worker_invocation_id",
            "role_id",
            "skill_ids_json",
        ] {
            assert!(
                !columns.iter().any(|column| column == removed),
                "{table} retained removed dependency {removed}"
            );
        }
    }
}

#[test]
fn reusable_agent_runs_fifo_and_results_resume_durably() {
    let (_pool, store, service) = setup();
    let root = root(&store, &service, "/tmp/core-coordination-fifo", "Root");
    let child = spawn(&service, &root, "spawn-fifo", "Builder", None, None);
    let second = service
        .admit_assignment(&NewAssignment {
            admission_key: "fifo-second".to_owned(),
            agent_id: child.agent.agent_id.clone(),
            requested_by_agent_id: Some(root.agent_id.clone()),
            parent_assignment_id: None,
            retry_of_assignment_id: None,
            kind: AssignmentKind::Instruction,
            task: "Run the second assignment".to_owned(),
            context: json!({}),
            trace_id: Some("trace-fifo-second".to_owned()),
            autonomous_hop: 0,
            model: None,
            reasoning_level: None,
            capability_grant: None,
            write_scopes: None,
            limits: None,
            deadline_at: None,
        })
        .unwrap();
    assert!(second.queue_ordinal > child.assignment.queue_ordinal);

    let first_claim = service
        .claim_next(&ClaimAssignment {
            agent_id: child.agent.agent_id.clone(),
            run_id: "run-fifo-one".to_owned(),
            baseline_event_sequence: 0,
        })
        .unwrap()
        .unwrap();
    assert_eq!(
        first_claim.assignment.assignment_id,
        child.assignment.assignment_id
    );
    assert_eq!(first_claim.attempt.attempt_number, 1);
    assert!(
        service
            .claim_next(&ClaimAssignment {
                agent_id: child.agent.agent_id.clone(),
                run_id: "run-must-not-overlap".to_owned(),
                baseline_event_sequence: 0,
            })
            .unwrap()
            .is_none()
    );
    let result = service
        .complete(&CompleteAssignment {
            assignment_id: first_claim.assignment.assignment_id,
            terminal_status: TerminalAssignmentStatus::Completed,
            payload: Some(json!({"summary":"first complete"})),
            error: None,
        })
        .unwrap();
    assert!(result.payload_blob_id.is_none());
    assert_eq!(
        service.result(&result.result_id).unwrap().unwrap().payload,
        result.payload
    );
    let replay = service
        .complete(&CompleteAssignment {
            assignment_id: result.assignment_id.clone(),
            terminal_status: TerminalAssignmentStatus::Completed,
            payload: Some(json!({"summary":"first complete"})),
            error: None,
        })
        .unwrap();
    assert_eq!(replay.result_id, result.result_id);

    let second_claim = service
        .claim_next(&ClaimAssignment {
            agent_id: child.agent.agent_id,
            run_id: "run-fifo-two".to_owned(),
            baseline_event_sequence: 4,
        })
        .unwrap()
        .unwrap();
    assert_eq!(second_claim.assignment.assignment_id, second.assignment_id);
    let large = json!({"content":"x".repeat(12_000)});
    let large_result = service
        .complete(&CompleteAssignment {
            assignment_id: second.assignment_id,
            terminal_status: TerminalAssignmentStatus::Completed,
            payload: Some(large.clone()),
            error: None,
        })
        .unwrap();
    assert!(large_result.payload_blob_id.is_some());
    assert_eq!(large_result.payload, Some(large));

    let wakes = service.pending_wakes(20).unwrap();
    assert_eq!(
        wakes
            .iter()
            .filter(|wake| wake.cause_kind == "assignment_result")
            .count(),
        2
    );
    let leased = store
        .lease_next_core_agent_wake(&root.agent_id, "wake-delivery-one")
        .unwrap()
        .unwrap();
    assert_eq!(leased.disposition, "leased");
    assert_eq!(store.recover_core_agent_wake_leases().unwrap(), 1);
    assert!(
        service
            .pending_wakes(20)
            .unwrap()
            .iter()
            .any(|wake| wake.wake_id == leased.wake_id)
    );
    let leased_again = store
        .lease_next_core_agent_wake(&root.agent_id, "wake-delivery-two")
        .unwrap()
        .unwrap();
    let delivered = store
        .finish_core_agent_wake(&leased_again.wake_id, "wake-delivery-two", true, None)
        .unwrap();
    assert_eq!(delivered.disposition, "delivered");
}

#[test]
fn semantic_messages_derive_authority_assignments_and_wakes() {
    let (_pool, store, service) = setup();
    let root = root(&store, &service, "/tmp/core-coordination-messages", "Root");
    let first = spawn(&service, &root, "spawn-message-a", "First", None, None);
    let second = spawn(&service, &root, "spawn-message-b", "Second", None, None);

    let passive = service
        .send(&SendMessage {
            idempotency_key: "message-information".to_owned(),
            source_agent_id: root.agent_id.clone(),
            target_agent_id: first.agent.agent_id.clone(),
            kind: MessageKind::Information,
            content: "Reference evidence only".to_owned(),
            assignment_id: None,
            reply_to_message_id: None,
            parent_assignment_id: None,
            trace_id: "trace-message-information".to_owned(),
            autonomous_hop: 0,
        })
        .unwrap();
    assert!(passive.wake.is_none());

    let question = service
        .send(&SendMessage {
            idempotency_key: "message-question".to_owned(),
            source_agent_id: root.agent_id.clone(),
            target_agent_id: first.agent.agent_id.clone(),
            kind: MessageKind::Question,
            content: "What did you find?".to_owned(),
            assignment_id: None,
            reply_to_message_id: None,
            parent_assignment_id: None,
            trace_id: "trace-message-question".to_owned(),
            autonomous_hop: 0,
        })
        .unwrap();
    assert!(question.wake.is_some());
    let answer = service
        .send(&SendMessage {
            idempotency_key: "message-answer".to_owned(),
            source_agent_id: first.agent.agent_id.clone(),
            target_agent_id: root.agent_id.clone(),
            kind: MessageKind::Answer,
            content: "The evidence is durable.".to_owned(),
            assignment_id: None,
            reply_to_message_id: Some(question.message_id),
            parent_assignment_id: None,
            trace_id: "trace-message-question".to_owned(),
            autonomous_hop: 1,
        })
        .unwrap();
    assert!(answer.wake.is_some());

    let peer_instruction = service
        .send(&SendMessage {
            idempotency_key: "peer-instruction-denied".to_owned(),
            source_agent_id: first.agent.agent_id.clone(),
            target_agent_id: second.agent.agent_id.clone(),
            kind: MessageKind::Instruction,
            content: "You must do this".to_owned(),
            assignment_id: None,
            reply_to_message_id: None,
            parent_assignment_id: Some(first.assignment.assignment_id.clone()),
            trace_id: first.assignment.trace_id.clone(),
            autonomous_hop: 1,
        })
        .unwrap_err();
    assert!(peer_instruction.to_string().contains("may request"));
    let peer_request = service
        .send(&SendMessage {
            idempotency_key: "peer-request".to_owned(),
            source_agent_id: first.agent.agent_id,
            target_agent_id: second.agent.agent_id,
            kind: MessageKind::Request,
            content: "Would you inspect this evidence?".to_owned(),
            assignment_id: None,
            reply_to_message_id: None,
            parent_assignment_id: Some(first.assignment.assignment_id),
            trace_id: first.assignment.trace_id,
            autonomous_hop: 1,
        })
        .unwrap();
    let offer = peer_request.assignment.unwrap();
    assert_eq!(offer.status, AssignmentStatus::Offered);
    assert!(peer_request.wake.is_some());
    assert_eq!(
        service
            .respond_to_offer(&RespondToOffer {
                actor_agent_id: offer.agent_id.clone(),
                assignment_id: offer.assignment_id.clone(),
                accept: false,
            })
            .unwrap()
            .status,
        AssignmentStatus::Declined
    );
}

#[test]
fn assignment_waits_reject_cycles_and_coalesce_result_wakes() {
    let (pool, store, service) = setup();
    let root = root(&store, &service, "/tmp/core-coordination-wait", "Root");
    let root_assignment = service
        .admit_assignment(&NewAssignment {
            admission_key: "root-active-assignment".to_owned(),
            agent_id: root.agent_id.clone(),
            requested_by_agent_id: None,
            parent_assignment_id: None,
            retry_of_assignment_id: None,
            kind: AssignmentKind::Operator,
            task: "Coordinate a child".to_owned(),
            context: json!({}),
            trace_id: Some("trace-structured-wait".to_owned()),
            autonomous_hop: 0,
            model: None,
            reasoning_level: None,
            capability_grant: None,
            write_scopes: None,
            limits: None,
            deadline_at: None,
        })
        .unwrap();
    let _ = service
        .claim_next(&ClaimAssignment {
            agent_id: root.agent_id.clone(),
            run_id: "run-root-wait".to_owned(),
            baseline_event_sequence: 0,
        })
        .unwrap()
        .unwrap();
    let child = spawn(
        &service,
        &root,
        "spawn-wait-child",
        "Child",
        Some(&root_assignment.assignment_id),
        Some(&root_assignment.trace_id),
    );
    let _ = service
        .claim_next(&ClaimAssignment {
            agent_id: child.agent.agent_id.clone(),
            run_id: "run-child-wait".to_owned(),
            baseline_event_sequence: 0,
        })
        .unwrap()
        .unwrap();
    let parent_wait = service
        .wait(&RegisterWait {
            idempotency_key: "parent-waits-child".to_owned(),
            owner_agent_id: root.agent_id.clone(),
            owner_assignment_id: Some(root_assignment.assignment_id.clone()),
            trace_id: root_assignment.trace_id.clone(),
            autonomous_hop: 0,
            mode: WaitMode::All,
            targets: vec![WaitTarget::Assignment(
                child.assignment.assignment_id.clone(),
            )],
        })
        .unwrap();
    assert_eq!(parent_wait.disposition, "pending");
    assert_eq!(
        service
            .reconcile_parking(&root_assignment.assignment_id)
            .unwrap()
            .status,
        AssignmentStatus::Waiting
    );
    let cycle = service
        .wait(&RegisterWait {
            idempotency_key: "child-waits-parent".to_owned(),
            owner_agent_id: child.agent.agent_id.clone(),
            owner_assignment_id: Some(child.assignment.assignment_id.clone()),
            trace_id: root_assignment.trace_id,
            autonomous_hop: 0,
            mode: WaitMode::All,
            targets: vec![WaitTarget::Assignment(
                root_assignment.assignment_id.clone(),
            )],
        })
        .unwrap_err();
    assert!(cycle.to_string().contains("AGENT_WAIT_CYCLE"));

    let _ = service
        .complete(&CompleteAssignment {
            assignment_id: child.assignment.assignment_id,
            terminal_status: TerminalAssignmentStatus::Completed,
            payload: Some(json!({"joined":true})),
            error: None,
        })
        .unwrap();
    let wakes = service.pending_wakes(20).unwrap();
    assert_eq!(
        wakes
            .iter()
            .filter(|wake| wake.target_agent_id == root.agent_id)
            .map(|wake| wake.cause_kind.as_str())
            .collect::<Vec<_>>(),
        vec!["wait_result"]
    );
    let leased = service
        .lease_wake(&root.agent_id, "wait-result-before-restart")
        .unwrap()
        .unwrap();
    assert_eq!(leased.cause_kind, "wait_result");

    // A restart releases only the wake lease. The owner assignment remains
    // durably parked until the recovered wake reaches a safe boundary.
    assert_eq!(service.recover_wake_leases().unwrap(), 1);
    assert_eq!(
        pool.get()
            .unwrap()
            .query_row(
                "SELECT status FROM agent_assignments WHERE assignment_id=?1",
                [&root_assignment.assignment_id],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "waiting",
    );
    let leased = service
        .lease_wake(&root.agent_id, "wait-result-after-restart")
        .unwrap()
        .unwrap();
    service
        .finish_wake(&leased.wake_id, "wait-result-after-restart", true, None)
        .unwrap();
    assert_eq!(
        service
            .reconcile_parking(&root_assignment.assignment_id)
            .unwrap()
            .status,
        AssignmentStatus::Running,
    );
}

#[test]
fn completion_before_wait_atomically_absorbs_even_a_leased_individual_wake() {
    let (_pool, store, service) = setup();
    let root = root(&store, &service, "/tmp/core-coordination-race", "Root");
    let root_assignment = service
        .admit_assignment(&NewAssignment {
            admission_key: "race-root-assignment".to_owned(),
            agent_id: root.agent_id.clone(),
            requested_by_agent_id: None,
            parent_assignment_id: None,
            retry_of_assignment_id: None,
            kind: AssignmentKind::Operator,
            task: "Wait after a child races to completion".to_owned(),
            context: json!({}),
            trace_id: Some("trace-wait-race".to_owned()),
            autonomous_hop: 0,
            model: None,
            reasoning_level: None,
            capability_grant: None,
            write_scopes: None,
            limits: None,
            deadline_at: None,
        })
        .unwrap();
    service
        .claim_next(&ClaimAssignment {
            agent_id: root.agent_id.clone(),
            run_id: "race-root-run".to_owned(),
            baseline_event_sequence: 0,
        })
        .unwrap()
        .unwrap();
    let child = spawn(
        &service,
        &root,
        "race-child-spawn",
        "Child",
        Some(&root_assignment.assignment_id),
        Some(&root_assignment.trace_id),
    );
    service
        .claim_next(&ClaimAssignment {
            agent_id: child.agent.agent_id.clone(),
            run_id: "race-child-run".to_owned(),
            baseline_event_sequence: 0,
        })
        .unwrap()
        .unwrap();
    service
        .complete(&CompleteAssignment {
            assignment_id: child.assignment.assignment_id.clone(),
            terminal_status: TerminalAssignmentStatus::Completed,
            payload: Some(json!({"finished":"before wait registration"})),
            error: None,
        })
        .unwrap();
    let raced_wake = service
        .lease_wake(&root.agent_id, "raced-individual-result")
        .unwrap()
        .unwrap();
    assert_eq!(raced_wake.cause_kind, "assignment_result");

    let wait_request = RegisterWait {
        idempotency_key: "race-wait-registration".to_owned(),
        owner_agent_id: root.agent_id.clone(),
        owner_assignment_id: Some(root_assignment.assignment_id.clone()),
        trace_id: root_assignment.trace_id,
        autonomous_hop: 0,
        mode: WaitMode::All,
        targets: vec![WaitTarget::Assignment(child.assignment.assignment_id)],
    };
    let admitted = service.wait(&wait_request).unwrap();
    assert_eq!(admitted.disposition, "satisfied");
    assert_eq!(admitted.satisfied_targets, wait_request.targets);
    assert_eq!(
        service.wait(&wait_request).unwrap().satisfied_targets,
        wait_request.targets,
        "idempotent replay must return the same already-satisfied handles",
    );
    assert_eq!(
        service
            .reconcile_parking(&root_assignment.assignment_id)
            .unwrap()
            .status,
        AssignmentStatus::Running,
    );
    assert!(
        service
            .finish_wake(&raced_wake.wake_id, "raced-individual-result", true, None,)
            .unwrap_err()
            .to_string()
            .contains("no longer belongs"),
        "registration must revoke a concurrently leased unobserved wake",
    );
    assert_eq!(service.recover_wake_leases().unwrap(), 0);
    assert!(
        service
            .pending_wakes(20)
            .unwrap()
            .iter()
            .all(|wake| wake.cause_id != raced_wake.cause_id),
    );
}
