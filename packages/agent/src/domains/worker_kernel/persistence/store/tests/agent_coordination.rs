//! Reusable-agent identity, result, authority, and resource-custody tests.

use super::*;

fn root(store: &WorkerStore, suffix: &str) -> AgentInstanceRecord {
    store
        .ensure_root_agent(&NewRootAgent {
            session_id: format!("session_{suffix}"),
            workspace_id: "workspace_test".to_owned(),
            name: format!("Root {suffix}"),
            model: Some("test-model".to_owned()),
            reasoning_level: None,
            tool_grant: json!({"functions":["agent_spawn","agent_send"]}),
            limits: json!({"maxChildren":8}),
        })
        .unwrap()
}

fn channel(first: &str, second: &str) -> String {
    let mut participants = [first, second];
    participants.sort_unstable();
    format!("agent_channel:{}:{}", participants[0], participants[1])
}

fn admission(root: &AgentInstanceRecord, key: &str, slot: u32) -> NewAgentAdmission {
    NewAgentAdmission {
        admission_key: key.to_owned(),
        root_session_id: root.session_id.clone(),
        workspace_id: root.workspace_id.clone(),
        spawned_by_agent_id: root.agent_id.clone(),
        management_owner_agent_id: root.agent_id.clone(),
        kind: AgentInstanceKind::General,
        role_id: None,
        role_version: None,
        name: format!("Child {slot}"),
        task: format!("Inspect subsystem {slot}"),
        context: json!({"evidence":"bounded"}),
        assignment_kind: AgentAssignmentKind::Instruction,
        requester_agent_id: Some(root.agent_id.clone()),
        delegator_agent_id: Some(root.agent_id.clone()),
        parent_execution_id: None,
        trace_id: format!("trace_{key}"),
        causal_depth: 1,
        child_slot: Some(slot),
        max_active_children: 8,
        max_child_executions: 64,
        max_execution_nodes: 64,
        max_causal_depth: 16,
        autonomous_hop: 1,
        model: None,
        reasoning_level: None,
        tool_grant: json!({"functions":["filesystem_read"]}),
        resource_snapshot: json!({"workspace":"shared"}),
        write_scopes: json!([format!("Sources/{slot}")]),
        limits: json!({"turns":32}),
        retry_of_assignment_id: None,
        deadline_at: None,
    }
}

fn reassignment(
    owner: &AgentInstanceRecord,
    target: &AgentInstanceRecord,
    ordinal: u32,
) -> NewAgentAssignment {
    let suffix = format!("page_{ordinal:03}");
    NewAgentAssignment {
        admission_key: format!("assignment_{suffix}"),
        agent_id: target.agent_id.clone(),
        requester_agent_id: Some(owner.agent_id.clone()),
        delegator_agent_id: Some(owner.agent_id.clone()),
        kind: AgentAssignmentKind::Instruction,
        offered: false,
        task: format!("Inspect durable history item {ordinal}"),
        context: json!({"ordinal":ordinal}),
        parent_execution_id: None,
        trace_id: format!("trace_{suffix}"),
        causal_depth: 1,
        child_slot: Some(ordinal),
        max_active_children: 8,
        max_child_executions: 64,
        max_execution_nodes: 64,
        max_causal_depth: 16,
        max_queued_assignments: 8,
        model: None,
        reasoning_level: None,
        authority_snapshot: json!({"functions":["filesystem_read"]}),
        resource_snapshot: json!({"workspaceId":owner.workspace_id}),
        write_scopes_snapshot: json!([]),
        limits_snapshot: json!({"turns":32}),
        retry_of_assignment_id: None,
        deadline_at: None,
        message: NewAgentAssignmentMessage {
            deduplication_key: format!("message_effect_{suffix}"),
            message_id: format!("agent_message_{suffix}"),
            channel_id: channel(&owner.agent_id, &target.agent_id),
            source_agent_id: owner.agent_id.clone(),
            source_session_id: owner.session_id.clone(),
            source_name: Some(owner.name.clone()),
            target_session_id: target.session_id.clone(),
            kind: crate::shared::protocol::messages::AgentMessageKind::Instruction,
            authority: crate::shared::protocol::messages::AgentMessageAuthority::Owner,
            reply_to: None,
            text: format!("Inspect durable history item {ordinal}"),
            autonomous_hop: 1,
        },
    }
}

fn complete_assignment(store: &WorkerStore, assignment_id: String) {
    let assignment = store.agent_assignment(&assignment_id).unwrap().unwrap();
    let assignment = if assignment.status == AgentAssignmentStatus::Accepted {
        store
            .transition_agent_assignment(&AgentAssignmentTransition {
                assignment_id,
                expected_status: AgentAssignmentStatus::Accepted,
                target_status: AgentAssignmentStatus::Running,
                result: None,
                error: None,
            })
            .unwrap()
    } else {
        store
            .transition_agent_assignment(&AgentAssignmentTransition {
                assignment_id,
                expected_status: AgentAssignmentStatus::Queued,
                target_status: AgentAssignmentStatus::Running,
                result: None,
                error: None,
            })
            .unwrap()
    };
    store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: assignment.assignment_id,
            expected_status: AgentAssignmentStatus::Running,
            target_status: AgentAssignmentStatus::Completed,
            result: Some(json!({"completed":true})),
            error: None,
        })
        .unwrap();
}

fn exhaust_coordination_outbox(
    store: &WorkerStore,
    outbox_id: &str,
    error: &str,
) -> AgentOutboxRetryOutcome {
    let mut claim_at = chrono::Utc::now();
    for expected_attempt in 1..=10 {
        assert!(
            store
                .mark_agent_outbox_importing_for_test(outbox_id, claim_at)
                .unwrap()
        );
        let outcome = store
            .retry_agent_outbox_for_test(outbox_id, error, claim_at)
            .unwrap();
        match &outcome {
            AgentOutboxRetryOutcome::Scheduled {
                attempts,
                next_attempt_at,
            } => {
                assert_eq!(*attempts, expected_attempt);
                assert!(expected_attempt < 10);
                claim_at = chrono::DateTime::parse_from_rfc3339(next_attempt_at)
                    .unwrap()
                    .with_timezone(&chrono::Utc);
            }
            AgentOutboxRetryOutcome::Rejected { attempts, .. } => {
                assert_eq!(expected_attempt, 10);
                assert_eq!(*attempts, 10);
                return outcome;
            }
        }
    }
    panic!("coordination outbox did not terminally reject")
}

fn acknowledge_coordination_outbox(store: &WorkerStore, outbox_id: &str) {
    assert!(store.mark_agent_outbox_importing(outbox_id).unwrap());
    store.mark_agent_outbox_imported(outbox_id).unwrap();
}

fn direct_worker_admission(
    invocation: &InvocationRecord,
    workspace_path: &str,
    max_active_children: u32,
) -> NewDirectWorkerAgentAdmission {
    NewDirectWorkerAgentAdmission {
        invocation_id: invocation.invocation_id.clone(),
        workspace_path: workspace_path.to_owned(),
        max_active_children,
        name: "Direct worker agent".to_owned(),
        task: "Return one schema-valid result.".to_owned(),
        context: json!({"workerInvocationId":invocation.invocation_id}),
        model: "test-model".to_owned(),
        reasoning_level: Some("medium".to_owned()),
        tool_grant: json!(["filesystem_read", "worker_await"]),
        limits: json!({
            "maxAssignmentSeconds":900,
            "maxAssignmentTurns":32,
            "maxChildExecutions":8,
            "maxQueuedAssignments":1,
        }),
        deadline_at: None,
    }
}

#[test]
fn direct_worker_bridge_reuses_identity_recovers_and_couples_cancellation() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "direct_worker_owner");
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (invocation, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"bridge"}),
            "direct-worker-bridge",
            "trace-direct-worker-bridge",
            0,
            "manual",
            Some(&owner.session_id),
        )
        .unwrap();
    assert!(store.claim_running(&invocation.invocation_id).unwrap());

    let request = direct_worker_admission(&invocation, directory.path().to_str().unwrap(), 1);
    let admitted = store.admit_direct_worker_agent(&request).unwrap();
    let replay = store.admit_direct_worker_agent(&request).unwrap();
    assert!(admitted.created);
    assert!(!replay.created);
    assert_eq!(admitted.agent.agent_id, replay.agent.agent_id);
    assert_eq!(
        admitted.agent.management_owner_agent_id.as_deref(),
        Some(owner.agent_id.as_str())
    );
    assert_eq!(
        admitted.agent.spawned_by_agent_id.as_deref(),
        Some(owner.agent_id.as_str())
    );
    assert_eq!(admitted.agent.kind, AgentInstanceKind::DirectWorker);
    assert_eq!(
        admitted.execution.assignment_id.as_deref(),
        Some(admitted.assignment.assignment_id.as_str())
    );
    assert_eq!(
        store
            .invocation(&invocation.invocation_id)
            .unwrap()
            .unwrap()
            .agent_session_id,
        Some(admitted.agent.session_id.clone())
    );

    // The direct bridge is a real active child even though its assignment
    // reuses the worker execution node. A second concurrent bridge under the
    // same root is rejected atomically at a profile ceiling of one.
    let (second_invocation, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"ceiling"}),
            "direct-worker-ceiling",
            "trace-direct-worker-ceiling",
            0,
            "manual",
            Some(&owner.session_id),
        )
        .unwrap();
    assert!(
        store
            .claim_running(&second_invocation.invocation_id)
            .unwrap()
    );
    assert!(
        store
            .admit_direct_worker_agent(&direct_worker_admission(
                &second_invocation,
                directory.path().to_str().unwrap(),
                1,
            ))
            .unwrap_err()
            .contains("ceiling")
    );

    store
        .mark_agent_provisioned(&admitted.agent.agent_id, &admitted.assignment.assignment_id)
        .unwrap();
    store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: admitted.assignment.assignment_id.clone(),
            expected_status: AgentAssignmentStatus::Queued,
            target_status: AgentAssignmentStatus::Running,
            result: None,
            error: None,
        })
        .unwrap();
    let attempt = store
        .begin_agent_assignment_attempt(&admitted.assignment.assignment_id, None, 37)
        .unwrap();
    let interrupted = store
        .interrupt_running_invocation(
            &invocation.invocation_id,
            "test direct worker restart boundary",
        )
        .unwrap();
    assert_eq!(interrupted.status, "queued");
    assert_eq!(
        interrupted.agent_session_id.as_deref(),
        Some(admitted.agent.session_id.as_str())
    );
    assert_eq!(
        store
            .agent_assignment(&admitted.assignment.assignment_id)
            .unwrap()
            .unwrap()
            .status,
        AgentAssignmentStatus::Queued
    );
    assert_eq!(
        store
            .list_agent_assignment_attempts(&admitted.assignment.assignment_id, 1)
            .unwrap()[0]
            .attempt_id,
        attempt.attempt_id
    );
    assert_eq!(
        store
            .list_agent_assignment_attempts(&admitted.assignment.assignment_id, 1)
            .unwrap()[0]
            .baseline_event_sequence,
        37
    );
    assert_eq!(
        store
            .list_agent_assignment_attempts(&admitted.assignment.assignment_id, 1)
            .unwrap()[0]
            .status,
        "interrupted"
    );

    assert!(store.claim_running(&invocation.invocation_id).unwrap());
    store
        .cancel_invocation_with_reason(&invocation.invocation_id, "cancel bridge")
        .unwrap();
    let cancelled = store
        .agent_assignment(&admitted.assignment.assignment_id)
        .unwrap()
        .unwrap();
    assert_eq!(cancelled.status, AgentAssignmentStatus::Cancelled);
    assert_eq!(
        store
            .agent_instance(&admitted.agent.agent_id)
            .unwrap()
            .unwrap()
            .state,
        AgentInstanceState::Closed
    );
    assert!(store.pending_agent_outbox(20).unwrap().iter().any(|row| {
        row.assignment_id.as_deref() == Some(cancelled.assignment_id.as_str())
            && row.kind == AgentOutboxKind::Result
    }));
}

#[test]
fn direct_worker_failure_cannot_orphan_its_single_assignment() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "direct_worker_failure_owner");
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (invocation, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"failure"}),
            "direct-worker-failure",
            "trace-direct-worker-failure",
            0,
            "manual",
            Some(&owner.session_id),
        )
        .unwrap();
    assert!(store.claim_running(&invocation.invocation_id).unwrap());
    let admitted = store
        .admit_direct_worker_agent(&direct_worker_admission(
            &invocation,
            directory.path().to_str().unwrap(),
            8,
        ))
        .unwrap();
    store
        .complete_invocation(
            &invocation.invocation_id,
            &published.worker.worker_id,
            Err("provider failed before assignment terminalization"),
        )
        .unwrap();
    let assignment = store
        .agent_assignment(&admitted.assignment.assignment_id)
        .unwrap()
        .unwrap();
    assert_eq!(assignment.status, AgentAssignmentStatus::Failed);
    assert_eq!(
        store
            .agent_instance(&admitted.agent.agent_id)
            .unwrap()
            .unwrap()
            .state,
        AgentInstanceState::Closed
    );
}

#[test]
fn owned_subtree_live_assignment_query_is_not_hidden_by_historical_pages() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "uncapped_owned_assignments");
    for slot in 0..205_u32 {
        let admitted = store
            .admit_agent(&admission(
                &owner,
                &format!("historical_owned_assignment_{slot}"),
                slot,
            ))
            .unwrap();
        store
            .mark_agent_provisioned(&admitted.agent.agent_id, &admitted.assignment.assignment_id)
            .unwrap();
        store
            .transition_agent_assignment(&AgentAssignmentTransition {
                assignment_id: admitted.assignment.assignment_id.clone(),
                expected_status: AgentAssignmentStatus::Queued,
                target_status: AgentAssignmentStatus::Running,
                result: None,
                error: None,
            })
            .unwrap();
        store
            .transition_agent_assignment(&AgentAssignmentTransition {
                assignment_id: admitted.assignment.assignment_id,
                expected_status: AgentAssignmentStatus::Running,
                target_status: AgentAssignmentStatus::Completed,
                result: Some(json!({"slot":slot})),
                error: None,
            })
            .unwrap();
    }
    let live = store
        .admit_agent(&admission(&owner, "live_owned_assignment", 999))
        .unwrap();
    store
        .mark_agent_provisioned(&live.agent.agent_id, &live.assignment.assignment_id)
        .unwrap();

    let assignments = store
        .nonterminal_agent_assignments_for_owned_subtree(&owner.agent_id)
        .unwrap();
    assert_eq!(assignments.len(), 1);
    assert_eq!(assignments[0].assignment_id, live.assignment.assignment_id);
}

#[test]
fn assignment_attempt_interruption_is_exact_durable_and_idempotent() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "attempt_interruption");
    let admitted = store
        .admit_agent(&admission(&owner, "attempt_interruption", 0))
        .unwrap();
    store
        .mark_agent_provisioned(&admitted.agent.agent_id, &admitted.assignment.assignment_id)
        .unwrap();
    store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: admitted.assignment.assignment_id.clone(),
            expected_status: AgentAssignmentStatus::Queued,
            target_status: AgentAssignmentStatus::Running,
            result: None,
            error: None,
        })
        .unwrap();
    let attempt = store
        .begin_agent_assignment_attempt(
            &admitted.assignment.assignment_id,
            Some("run_attempt_interruption"),
            41,
        )
        .unwrap();

    assert_eq!(
        store
            .interrupt_running_agent_assignment_attempts(
                &admitted.assignment.assignment_id,
                "cancelled with retained attempt evidence",
            )
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .interrupt_running_agent_assignment_attempts(
                &admitted.assignment.assignment_id,
                "idempotent replay",
            )
            .unwrap(),
        0
    );
    let persisted = store
        .list_agent_assignment_attempts(&admitted.assignment.assignment_id, 20)
        .unwrap();
    assert_eq!(persisted.len(), 1);
    assert_eq!(persisted[0].attempt_id, attempt.attempt_id);
    assert_eq!(persisted[0].status, "interrupted");
    assert_eq!(
        persisted[0].error.as_deref(),
        Some("cancelled with retained attempt evidence")
    );
    assert!(
        store
            .list_agent_execution_events(&admitted.execution.execution_id, None, 20)
            .unwrap()
            .iter()
            .any(|event| {
                event.kind == "attempt_finished"
                    && event.details["attemptId"] == attempt.attempt_id
                    && event.details["status"] == "interrupted"
            })
    );
}

#[test]
fn admission_is_idempotent_and_terminal_result_has_integrity_custody() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let root = root(&store, "one");
    let first = store
        .admit_agent(&admission(&root, "spawn_one", 0))
        .unwrap();
    let replay = store
        .admit_agent(&admission(&root, "spawn_one", 0))
        .unwrap();
    assert!(first.created);
    assert!(!replay.created);
    assert_eq!(first.agent.agent_id, replay.agent.agent_id);
    assert_eq!(
        first.assignment.assignment_id,
        replay.assignment.assignment_id
    );
    assert_eq!(
        first.execution.assignment_id,
        Some(first.assignment.assignment_id.clone())
    );
    assert_eq!(store.pending_agent_outbox(10).unwrap().len(), 1);

    let queued = store
        .mark_agent_provisioned(&first.agent.agent_id, &first.assignment.assignment_id)
        .unwrap();
    assert_eq!(queued.status, AgentAssignmentStatus::Queued);
    assert_eq!(
        store
            .next_queued_agent_assignment(&first.agent.agent_id)
            .unwrap()
            .unwrap()
            .assignment_id,
        first.assignment.assignment_id
    );
    assert_eq!(store.list_runnable_agent_assignments(10).unwrap().len(), 1);

    store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: first.assignment.assignment_id.clone(),
            expected_status: AgentAssignmentStatus::Queued,
            target_status: AgentAssignmentStatus::Running,
            result: None,
            error: None,
        })
        .unwrap();
    let completed = store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: first.assignment.assignment_id,
            expected_status: AgentAssignmentStatus::Running,
            target_status: AgentAssignmentStatus::Completed,
            result: Some(json!({"answer":"durable","items":[1,2,3]})),
            error: None,
        })
        .unwrap();
    let result_id = completed.result_id.as_deref().unwrap();
    let replay = store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: completed.assignment_id.clone(),
            expected_status: AgentAssignmentStatus::Running,
            target_status: AgentAssignmentStatus::Completed,
            result: Some(json!({"answer":"durable","items":[1,2,3]})),
            error: None,
        })
        .unwrap();
    assert_eq!(replay.result_id, completed.result_id);
    assert!(
        store
            .transition_agent_assignment(&AgentAssignmentTransition {
                assignment_id: completed.assignment_id.clone(),
                expected_status: AgentAssignmentStatus::Running,
                target_status: AgentAssignmentStatus::Completed,
                result: Some(json!({"answer":"different"})),
                error: None,
            })
            .unwrap_err()
            .contains("idempotency conflict")
    );
    assert_eq!(
        store.resolve_agent_result(result_id).unwrap().unwrap(),
        json!({"answer":"durable","items":[1,2,3]})
    );
    let result = store.agent_result(result_id).unwrap().unwrap();
    assert_eq!(result.agent_id, first.agent.agent_id);
    assert_eq!(
        result.reference["kind"],
        "agent_assignment_result_reference"
    );
    assert_eq!(store.pending_agent_outbox(10).unwrap().len(), 2);
    assert_eq!(
        store
            .list_agent_assignment_attempts(&completed.assignment_id, 20)
            .unwrap()
            .len(),
        0
    );
    assert!(
        !store
            .list_agent_execution_events(&completed.execution_id, None, 20)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn parked_recovery_page_cannot_hide_a_later_queued_assignment() {
    const PARKED_ASSIGNMENTS: usize = 128;
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();

    for index in 0..PARKED_ASSIGNMENTS {
        let owner = root(&store, &format!("dispatcher_parked_{index:03}"));
        let admitted = store
            .admit_agent(&admission(
                &owner,
                &format!("dispatcher_parked_spawn_{index:03}"),
                0,
            ))
            .unwrap();
        store
            .mark_agent_provisioned(&admitted.agent.agent_id, &admitted.assignment.assignment_id)
            .unwrap();
        store
            .transition_agent_assignment(&AgentAssignmentTransition {
                assignment_id: admitted.assignment.assignment_id.clone(),
                expected_status: AgentAssignmentStatus::Queued,
                target_status: AgentAssignmentStatus::Running,
                result: None,
                error: None,
            })
            .unwrap();
        store
            .transition_agent_assignment(&AgentAssignmentTransition {
                assignment_id: admitted.assignment.assignment_id,
                expected_status: AgentAssignmentStatus::Running,
                target_status: AgentAssignmentStatus::Waiting,
                result: None,
                error: None,
            })
            .unwrap();
    }

    let later_owner = root(&store, "dispatcher_later_queued");
    let later = store
        .admit_agent(&admission(&later_owner, "dispatcher_later_queued_spawn", 0))
        .unwrap();
    store
        .mark_agent_provisioned(&later.agent.agent_id, &later.assignment.assignment_id)
        .unwrap();

    assert_eq!(
        store
            .list_recoverable_agent_assignments(PARKED_ASSIGNMENTS)
            .unwrap()
            .len(),
        PARKED_ASSIGNMENTS
    );
    let runnable = store
        .list_runnable_agent_assignments(PARKED_ASSIGNMENTS)
        .unwrap();
    assert_eq!(runnable.len(), 1);
    assert_eq!(runnable[0].assignment_id, later.assignment.assignment_id);
}

#[test]
fn assignment_write_scope_snapshots_require_canonical_unambiguous_prefixes() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let root = root(&store, "invalid_write_scopes");

    let mut parent_escape = admission(&root, "invalid_scope_parent", 0);
    parent_escape.write_scopes = json!(["Sources/../Secrets"]);
    assert!(
        store
            .admit_agent(&parent_escape)
            .unwrap_err()
            .contains("canonical workspace-relative prefix")
    );

    let mut ambiguous_case = admission(&root, "invalid_scope_case", 1);
    ambiguous_case.write_scopes = json!(["Sources/A", "sources/B"]);
    assert!(
        store
            .admit_agent(&ambiguous_case)
            .unwrap_err()
            .contains("case-ambiguous prefix")
    );

    let mut normalized_alias = admission(&root, "invalid_scope_alias", 2);
    normalized_alias.write_scopes = json!(["Sources//A"]);
    assert!(
        store
            .admit_agent(&normalized_alias)
            .unwrap_err()
            .contains("canonical workspace-relative prefix")
    );
}

#[test]
fn coordination_pause_survives_restart_and_excludes_runnable_work_and_effects() {
    let directory = tempfile::tempdir().unwrap();
    let database_root = directory.path().to_path_buf();
    let store = WorkerStore::open_without_snapshot(database_root.clone()).unwrap();
    let owner = root(&store, "paused_trace");
    let child = store
        .admit_agent(&admission(&owner, "paused_trace_spawn", 0))
        .unwrap();
    store
        .mark_agent_provisioned(&child.agent.agent_id, &child.assignment.assignment_id)
        .unwrap();
    assert_eq!(store.list_runnable_agent_assignments(10).unwrap().len(), 1);
    let provision_outbox_id = store.pending_agent_outbox(10).unwrap()[0].outbox_id.clone();

    let paused = store
        .pause_coordination_trace(
            &child.execution.trace_id,
            "AGENT_AUTONOMY_PAUSED: autonomous wake ceiling reached",
        )
        .unwrap();
    assert!(paused.paused);
    assert_eq!(paused.root_session_id, owner.session_id);
    assert_eq!(
        paused.reason,
        "AGENT_AUTONOMY_PAUSED: autonomous wake ceiling reached"
    );
    assert!(paused.resumed_at.is_none());
    assert!(
        store
            .coordination_trace_is_paused(&child.execution.trace_id)
            .unwrap()
    );
    assert!(
        store
            .list_runnable_agent_assignments(10)
            .unwrap()
            .is_empty()
    );
    assert!(
        store
            .next_queued_agent_assignment(&child.agent.agent_id)
            .unwrap()
            .is_none()
    );
    assert!(store.pending_agent_outbox(10).unwrap().is_empty());
    assert!(
        !store
            .mark_agent_outbox_importing(&provision_outbox_id)
            .unwrap()
    );
    let error = store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: child.assignment.assignment_id.clone(),
            expected_status: AgentAssignmentStatus::Queued,
            target_status: AgentAssignmentStatus::Running,
            result: None,
            error: None,
        })
        .unwrap_err();
    assert!(error.contains("AGENT_AUTONOMY_PAUSED"));

    drop(store);
    let reopened = WorkerStore::open_without_snapshot(database_root).unwrap();
    assert!(
        reopened
            .coordination_trace_is_paused(&child.execution.trace_id)
            .unwrap()
    );
    let replay = reopened
        .pause_coordination_trace(
            &child.execution.trace_id,
            "a repeated detector must not rewrite the original evidence",
        )
        .unwrap();
    assert_eq!(replay.reason, paused.reason);
    assert_eq!(replay.paused_at, paused.paused_at);
    assert!(
        reopened
            .resume_coordination_trace(&child.execution.trace_id)
            .unwrap()
    );
    assert!(
        !reopened
            .resume_coordination_trace(&child.execution.trace_id)
            .unwrap()
    );
    let resumed = reopened
        .coordination_trace_state(&child.execution.trace_id)
        .unwrap()
        .unwrap();
    assert!(!resumed.paused);
    assert!(resumed.resumed_at.is_some());
    assert_eq!(
        reopened.list_runnable_agent_assignments(10).unwrap().len(),
        1
    );
    assert_eq!(reopened.pending_agent_outbox(10).unwrap().len(), 1);
    assert!(
        reopened
            .pause_coordination_trace("trace_missing", "must have durable graph evidence")
            .unwrap_err()
            .contains("was not found")
    );
}

#[test]
fn root_only_coordination_pause_is_durable_and_owner_bound() {
    let directory = tempfile::tempdir().unwrap();
    let database_root = directory.path().to_path_buf();
    let store = WorkerStore::open_without_snapshot(database_root.clone()).unwrap();
    let owner = root(&store, "root_only_pause");
    let other = root(&store, "root_only_pause_other");
    let paused = store
        .pause_coordination_trace_for_root(
            "trace_root_only",
            &owner.root_session_id,
            "AGENT_AUTONOMY_PAUSED: root-only message loop",
        )
        .unwrap();
    assert!(paused.paused);
    assert_eq!(paused.root_session_id, owner.root_session_id);
    assert!(
        store
            .pause_coordination_trace_for_root(
                "trace_root_only",
                &other.root_session_id,
                "conflicting owner",
            )
            .unwrap_err()
            .contains("ownership conflict")
    );
    drop(store);
    let reopened = WorkerStore::open_without_snapshot(database_root).unwrap();
    assert!(
        reopened
            .coordination_trace_is_paused("trace_root_only")
            .unwrap()
    );
}

#[test]
fn deadlines_are_first_admission_owned_and_due_even_while_paused() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "deadline");
    let mut request = admission(&owner, "deadline_assignment", 0);
    let past = (chrono::Utc::now() - chrono::Duration::minutes(1)).to_rfc3339();
    request.deadline_at = Some(past.clone());
    let admitted = store.admit_agent(&request).unwrap();
    let mut replay = request.clone();
    replay.deadline_at = Some((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339());
    let replayed = store.admit_agent(&replay).unwrap();
    assert!(!replayed.created);
    assert_eq!(
        replayed.assignment.deadline_at.as_deref(),
        Some(past.as_str())
    );
    store
        .pause_coordination_trace(
            &admitted.execution.trace_id,
            "paused but deadline remains due",
        )
        .unwrap();
    let due = store
        .list_due_agent_assignments(&chrono::Utc::now().to_rfc3339(), 20)
        .unwrap();
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].assignment_id, admitted.assignment.assignment_id);
}

#[test]
fn direct_child_execution_ceiling_is_atomic_and_zero_forbids_children() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "child_ceiling");
    let mut first = admission(&owner, "child_ceiling_first", 0);
    first.trace_id = "trace_child_ceiling".to_owned();
    first.max_child_executions = 1;
    store.admit_agent(&first).unwrap();
    let mut second = admission(&owner, "child_ceiling_second", 1);
    second.trace_id = first.trace_id.clone();
    second.max_child_executions = 1;
    assert!(
        store
            .admit_agent(&second)
            .unwrap_err()
            .contains("direct child execution ceiling (1)")
    );
    let mut forbidden = admission(&owner, "child_ceiling_zero", 2);
    forbidden.max_child_executions = 0;
    assert!(
        store
            .admit_agent(&forbidden)
            .unwrap_err()
            .contains("direct child execution ceiling (0)")
    );
}

#[test]
fn message_outbox_is_idempotent_and_failed_import_is_retryable() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "messages");
    let child = store
        .admit_agent(&admission(&owner, "spawn_message_target", 0))
        .unwrap();
    let request = NewAgentMessageOutbox {
        deduplication_key: "message_effect_one".to_owned(),
        source_agent_id: owner.agent_id.clone(),
        target_agent_id: child.agent.agent_id.clone(),
        assignment_id: Some(child.assignment.assignment_id.clone()),
        payload: json!({
            "messageId":"agent_message_effect_one",
            "channelId":channel(&owner.agent_id,&child.agent.agent_id),
            "kind":"question",
            "authority":"owner",
            "text":"What evidence remains?",
            "sourceSessionId":owner.session_id.clone(),
            "targetSessionId":child.agent.session_id.clone(),
            "replyTo":null,
            "traceId":"trace_message_effect_one",
            "autonomousHop":1,
        }),
    };
    let (effect, created) = store.enqueue_agent_message_outbox(&request).unwrap();
    let (replay, replay_created) = store.enqueue_agent_message_outbox(&request).unwrap();
    assert!(created);
    assert!(!replay_created);
    assert_eq!(effect.outbox_id, replay.outbox_id);
    assert_eq!(effect.payload["targetAgentId"], child.agent.agent_id);
    assert!(
        store
            .mark_agent_outbox_importing(&effect.outbox_id)
            .unwrap()
    );
    let retry_at = chrono::Utc::now();
    let next_attempt_at = match store
        .retry_agent_outbox_for_test(
            &effect.outbox_id,
            "event store temporarily unavailable",
            retry_at,
        )
        .unwrap()
    {
        AgentOutboxRetryOutcome::Scheduled {
            attempts,
            next_attempt_at,
        } => {
            assert_eq!(attempts, 1);
            next_attempt_at
        }
        AgentOutboxRetryOutcome::Rejected { .. } => panic!("first failure must remain retryable"),
    };
    let next_attempt_at = chrono::DateTime::parse_from_rfc3339(&next_attempt_at)
        .unwrap()
        .with_timezone(&chrono::Utc);
    assert!(
        store
            .mark_agent_outbox_importing_for_test(&effect.outbox_id, next_attempt_at)
            .unwrap()
    );
    assert_eq!(store.reset_importing_agent_outbox().unwrap(), 1);
}

#[test]
fn outbox_retry_schedule_survives_restart_and_poison_cannot_starve_later_work() {
    const EXPECTED_MAX_ATTEMPTS: u32 = 10;
    const EXPECTED_RETRY_CAP_SECONDS: i64 = 300;
    const EXPECTED_MAX_ERROR_BYTES: usize = 4_096;
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "poison_outbox");
    let child = store
        .admit_agent(&admission(&owner, "spawn_poison_outbox_target", 0))
        .unwrap();
    let make_message = |suffix: &str| NewAgentMessageOutbox {
        deduplication_key: format!("poison_fairness_{suffix}"),
        source_agent_id: owner.agent_id.clone(),
        target_agent_id: child.agent.agent_id.clone(),
        assignment_id: Some(child.assignment.assignment_id.clone()),
        payload: json!({
            "messageId":format!("agent_message_poison_{suffix}"),
            "channelId":channel(&owner.agent_id,&child.agent.agent_id),
            "kind":"information",
            "authority":"owner",
            "text":format!("bounded evidence {suffix}"),
            "sourceSessionId":owner.session_id.clone(),
            "targetSessionId":child.agent.session_id.clone(),
            "replyTo":null,
            "traceId":"trace_poison_fairness",
            "autonomousHop":1,
        }),
    };
    let (poison, _) = store
        .enqueue_agent_message_outbox(&make_message("poison"))
        .unwrap();
    let (later, _) = store
        .enqueue_agent_message_outbox(&make_message("later"))
        .unwrap();
    let first_failure_at = chrono::Utc::now();
    assert!(
        store
            .mark_agent_outbox_importing_for_test(&poison.outbox_id, first_failure_at)
            .unwrap()
    );
    let first_next_attempt = match store
        .retry_agent_outbox_for_test(
            &poison.outbox_id,
            "malformed cross-store payload",
            first_failure_at,
        )
        .unwrap()
    {
        AgentOutboxRetryOutcome::Scheduled {
            attempts,
            next_attempt_at,
        } => {
            assert_eq!(attempts, 1);
            chrono::DateTime::parse_from_rfc3339(&next_attempt_at)
                .unwrap()
                .with_timezone(&chrono::Utc)
        }
        AgentOutboxRetryOutcome::Rejected { .. } => panic!("first failure must back off"),
    };
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let before_retry = reopened
        .pending_agent_outbox_at(first_next_attempt - chrono::Duration::milliseconds(1), 200)
        .unwrap();
    assert!(
        before_retry
            .iter()
            .any(|candidate| candidate.outbox_id == later.outbox_id),
        "a later due row must remain selectable while the poison row backs off"
    );
    assert!(
        before_retry
            .iter()
            .all(|candidate| candidate.outbox_id != poison.outbox_id)
    );
    let scheduled = reopened
        .agent_outbox_for_test(&poison.outbox_id)
        .unwrap()
        .unwrap();
    assert_eq!(scheduled.attempts, 1);
    assert_eq!(
        chrono::DateTime::parse_from_rfc3339(&scheduled.next_attempt_at)
            .unwrap()
            .with_timezone(&chrono::Utc),
        first_next_attempt
    );
    assert_eq!(
        scheduled.last_error.as_deref(),
        Some("malformed cross-store payload")
    );

    let mut claim_at = first_next_attempt;
    let mut observed_cap = false;
    for expected_attempt in 2..=EXPECTED_MAX_ATTEMPTS {
        let import_error = if expected_attempt == EXPECTED_MAX_ATTEMPTS {
            "🧨".repeat(2_000)
        } else {
            "malformed cross-store payload".to_owned()
        };
        assert!(
            reopened
                .mark_agent_outbox_importing_for_test(&poison.outbox_id, claim_at)
                .unwrap()
        );
        match reopened
            .retry_agent_outbox_for_test(&poison.outbox_id, &import_error, claim_at)
            .unwrap()
        {
            AgentOutboxRetryOutcome::Scheduled {
                attempts,
                next_attempt_at,
            } => {
                assert_eq!(attempts, expected_attempt);
                let next = chrono::DateTime::parse_from_rfc3339(&next_attempt_at)
                    .unwrap()
                    .with_timezone(&chrono::Utc);
                let delay = next.signed_duration_since(claim_at).num_seconds();
                assert!(delay <= EXPECTED_RETRY_CAP_SECONDS);
                observed_cap |= delay == EXPECTED_RETRY_CAP_SECONDS;
                claim_at = next;
            }
            AgentOutboxRetryOutcome::Rejected {
                attempts,
                processed_at,
            } => {
                assert_eq!(expected_attempt, EXPECTED_MAX_ATTEMPTS);
                assert_eq!(attempts, EXPECTED_MAX_ATTEMPTS);
                assert_eq!(
                    chrono::DateTime::parse_from_rfc3339(&processed_at)
                        .unwrap()
                        .with_timezone(&chrono::Utc),
                    claim_at
                );
            }
        }
    }
    assert!(observed_cap, "exponential retry must reach its bounded cap");
    let rejected = reopened
        .agent_outbox_for_test(&poison.outbox_id)
        .unwrap()
        .unwrap();
    assert_eq!(rejected.disposition, AgentOutboxDisposition::Rejected);
    assert_eq!(rejected.attempts, EXPECTED_MAX_ATTEMPTS);
    assert!(rejected.processed_at.is_some());
    assert!(rejected.last_error.as_ref().is_some_and(|error| {
        error.len() <= EXPECTED_MAX_ERROR_BYTES
            && !error.is_empty()
            && error.is_char_boundary(error.len())
    }));
    assert!(
        reopened
            .pending_agent_outbox_at(claim_at + chrono::Duration::hours(1), 200)
            .unwrap()
            .iter()
            .all(|candidate| candidate.outbox_id != poison.outbox_id),
        "terminal poison evidence must never be selected again"
    );
}

#[test]
fn exhausted_provision_compensates_assignment_and_replays_across_restart() {
    let directory = tempfile::tempdir().unwrap();
    let database_root = directory.path().to_path_buf();
    let store = WorkerStore::open_without_snapshot(database_root.clone()).unwrap();
    let owner = root(&store, "poison_provision_compensation");
    let admitted = store
        .admit_agent(&admission(&owner, "poison_provision_compensation_spawn", 0))
        .unwrap();
    let provision = store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|row| {
            row.kind == AgentOutboxKind::Provision
                && row.assignment_id.as_deref() == Some(admitted.assignment.assignment_id.as_str())
        })
        .unwrap();

    let rejected = exhaust_coordination_outbox(
        &store,
        &provision.outbox_id,
        "hidden transcript provisioning is permanently unavailable",
    );
    let (attempts, processed_at) = match rejected {
        AgentOutboxRetryOutcome::Rejected {
            attempts,
            processed_at,
        } => (attempts, processed_at),
        AgentOutboxRetryOutcome::Scheduled { .. } => unreachable!(),
    };
    assert_eq!(attempts, 10);
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(database_root).unwrap();
    let assignment = reopened
        .agent_assignment(&admitted.assignment.assignment_id)
        .unwrap()
        .unwrap();
    assert_eq!(assignment.status, AgentAssignmentStatus::Failed);
    assert!(
        assignment
            .error
            .as_deref()
            .is_some_and(|error| error.contains("provision delivery failed after 10 attempts"))
    );
    assert_eq!(
        reopened
            .agent_instance(&admitted.agent.agent_id)
            .unwrap()
            .unwrap()
            .state,
        AgentInstanceState::Closed
    );
    let result_rows = reopened
        .pending_agent_outbox(200)
        .unwrap()
        .into_iter()
        .filter(|row| {
            row.kind == AgentOutboxKind::Result
                && row.assignment_id.as_deref() == Some(assignment.assignment_id.as_str())
        })
        .collect::<Vec<_>>();
    assert_eq!(result_rows.len(), 1);
    assert_eq!(result_rows[0].payload["status"], "failed");
    let attention = reopened
        .inbox_filtered(Some("agent-coordination"), None, Some("error"), 20)
        .unwrap();
    assert_eq!(attention.len(), 1);
    assert_eq!(
        attention[0]["result"]["compensation"],
        "assignment_failed_result_queued"
    );
    assert_eq!(attention[0]["result"]["outboxKind"], "provision");

    let replay = reopened
        .retry_agent_outbox_for_test(
            &provision.outbox_id,
            "a replay must not rewrite terminal evidence",
            chrono::Utc::now(),
        )
        .unwrap();
    assert_eq!(
        replay,
        AgentOutboxRetryOutcome::Rejected {
            attempts,
            processed_at,
        }
    );
    assert_eq!(
        reopened
            .inbox_filtered(Some("agent-coordination"), None, Some("error"), 20)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        reopened
            .pending_agent_outbox(200)
            .unwrap()
            .into_iter()
            .filter(|row| {
                row.kind == AgentOutboxKind::Result
                    && row.assignment_id.as_deref() == Some(assignment.assignment_id.as_str())
            })
            .count(),
        1
    );
}

#[test]
fn poison_rejection_rolls_back_assignment_and_attention_together() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "poison_atomic_compensation");
    let admitted = store
        .admit_agent(&admission(&owner, "poison_atomic_compensation_spawn", 0))
        .unwrap();
    let provision = store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|row| row.kind == AgentOutboxKind::Provision)
        .unwrap();
    let mut claim_at = chrono::Utc::now();
    for expected_attempt in 1..10 {
        assert!(
            store
                .mark_agent_outbox_importing_for_test(&provision.outbox_id, claim_at)
                .unwrap()
        );
        let AgentOutboxRetryOutcome::Scheduled {
            attempts,
            next_attempt_at,
        } = store
            .retry_agent_outbox_for_test(
                &provision.outbox_id,
                "permanent provisioning failure",
                claim_at,
            )
            .unwrap()
        else {
            panic!("attempt {expected_attempt} rejected before the terminal boundary")
        };
        assert_eq!(attempts, expected_attempt);
        claim_at = chrono::DateTime::parse_from_rfc3339(&next_attempt_at)
            .unwrap()
            .with_timezone(&chrono::Utc);
    }
    assert!(
        store
            .mark_agent_outbox_importing_for_test(&provision.outbox_id, claim_at)
            .unwrap()
    );
    let attention_id = format!(
        "agent_coordination_outbox_attention_{}",
        provision.outbox_id
    );
    store
        .connection()
        .unwrap()
        .execute_batch(&format!(
            "CREATE TRIGGER reject_coordination_attention_fixture
             BEFORE INSERT ON worker_inbox
             WHEN NEW.inbox_id='{attention_id}'
             BEGIN SELECT RAISE(ABORT,'injected attention failure'); END;"
        ))
        .unwrap();
    assert!(
        store
            .retry_agent_outbox_for_test(
                &provision.outbox_id,
                "permanent provisioning failure",
                claim_at,
            )
            .unwrap_err()
            .contains("injected attention failure")
    );
    assert_eq!(
        store
            .agent_outbox_for_test(&provision.outbox_id)
            .unwrap()
            .unwrap()
            .disposition,
        AgentOutboxDisposition::Importing
    );
    assert_eq!(
        store
            .agent_assignment(&admitted.assignment.assignment_id)
            .unwrap()
            .unwrap()
            .status,
        AgentAssignmentStatus::Accepted
    );
    assert!(
        store
            .inbox_filtered(Some("agent-coordination"), None, Some("error"), 20)
            .unwrap()
            .is_empty()
    );
    assert!(
        store
            .pending_agent_outbox(200)
            .unwrap()
            .into_iter()
            .all(|row| row.kind != AgentOutboxKind::Result)
    );

    store
        .connection()
        .unwrap()
        .execute_batch("DROP TRIGGER reject_coordination_attention_fixture")
        .unwrap();
    assert!(matches!(
        store
            .retry_agent_outbox_for_test(
                &provision.outbox_id,
                "permanent provisioning failure",
                claim_at,
            )
            .unwrap(),
        AgentOutboxRetryOutcome::Rejected { attempts: 10, .. }
    ));
    assert_eq!(
        store
            .agent_assignment(&admitted.assignment.assignment_id)
            .unwrap()
            .unwrap()
            .status,
        AgentAssignmentStatus::Failed
    );
    assert_eq!(
        store
            .inbox_filtered(Some("agent-coordination"), None, Some("error"), 20)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn exhausted_assignment_message_fails_queued_work_and_retains_result() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "poison_assignment_message");
    let admitted = store
        .admit_agent(&admission(&owner, "poison_assignment_message_spawn", 0))
        .unwrap();
    let provision = store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|row| row.kind == AgentOutboxKind::Provision)
        .unwrap();
    acknowledge_coordination_outbox(&store, &provision.outbox_id);
    store
        .mark_agent_provisioned(&admitted.agent.agent_id, &admitted.assignment.assignment_id)
        .unwrap();
    complete_assignment(&store, admitted.assignment.assignment_id.clone());
    for prior in store.pending_agent_outbox(20).unwrap() {
        acknowledge_coordination_outbox(&store, &prior.outbox_id);
    }

    let (queued, created) = store
        .enqueue_agent_assignment(&reassignment(&owner, &admitted.agent, 1))
        .unwrap();
    assert!(created);
    let message = store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|row| {
            row.kind == AgentOutboxKind::Message
                && row.assignment_id.as_deref() == Some(queued.assignment_id.as_str())
        })
        .unwrap();
    assert_eq!(message.payload["messagePurpose"], "assignment_admission");
    exhaust_coordination_outbox(
        &store,
        &message.outbox_id,
        "assignment message cannot cross the event-store boundary",
    );

    let failed = store
        .agent_assignment(&queued.assignment_id)
        .unwrap()
        .unwrap();
    assert_eq!(failed.status, AgentAssignmentStatus::Failed);
    assert_eq!(
        store
            .agent_instance(&admitted.agent.agent_id)
            .unwrap()
            .unwrap()
            .state,
        AgentInstanceState::Idle
    );
    assert_eq!(
        store
            .pending_agent_outbox(200)
            .unwrap()
            .into_iter()
            .filter(|row| {
                row.kind == AgentOutboxKind::Result
                    && row.assignment_id.as_deref() == Some(queued.assignment_id.as_str())
            })
            .count(),
        1
    );
    let attention = store
        .inbox_filtered(Some("agent-coordination"), None, Some("error"), 20)
        .unwrap();
    assert_eq!(attention.len(), 1);
    assert_eq!(attention[0]["result"]["outboxKind"], "message");
    assert_eq!(
        attention[0]["result"]["compensation"],
        "assignment_failed_result_queued"
    );
}

#[test]
fn exhausted_message_result_and_projection_retain_operator_evidence() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "poison_terminal_effects");
    let admitted = store
        .admit_agent(&admission(&owner, "poison_terminal_effects_spawn", 0))
        .unwrap();
    let provision = store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|row| row.kind == AgentOutboxKind::Provision)
        .unwrap();
    acknowledge_coordination_outbox(&store, &provision.outbox_id);
    store
        .mark_agent_provisioned(&admitted.agent.agent_id, &admitted.assignment.assignment_id)
        .unwrap();
    complete_assignment(&store, admitted.assignment.assignment_id.clone());
    let result = store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|row| row.kind == AgentOutboxKind::Result)
        .unwrap();
    let (message, created) = store
        .enqueue_agent_message_outbox(&NewAgentMessageOutbox {
            deduplication_key: "poison_terminal_information".to_owned(),
            source_agent_id: owner.agent_id.clone(),
            target_agent_id: admitted.agent.agent_id.clone(),
            assignment_id: None,
            payload: json!({
                "messageId":"agent_message_poison_terminal_information",
                "channelId":channel(&owner.agent_id,&admitted.agent.agent_id),
                "kind":"information",
                "authority":"owner",
                "text":"Retain delivery evidence.",
                "sourceSessionId":owner.session_id,
                "targetSessionId":admitted.agent.session_id,
                "replyTo":null,
                "traceId":"trace_poison_terminal_information",
                "autonomousHop":1,
            }),
        })
        .unwrap();
    assert!(created);
    store.close_agent_subtree(&admitted.agent.agent_id).unwrap();
    let projection = store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|row| row.kind == AgentOutboxKind::Projection)
        .unwrap();

    for row in [&message, &result, &projection] {
        exhaust_coordination_outbox(
            &store,
            &row.outbox_id,
            "terminal effect cannot cross the event-store boundary",
        );
    }
    let retained = store
        .agent_assignment(&admitted.assignment.assignment_id)
        .unwrap()
        .unwrap();
    assert_eq!(retained.status, AgentAssignmentStatus::Completed);
    assert!(retained.result_id.is_some());
    let attention = store
        .inbox_filtered(Some("agent-coordination"), None, Some("error"), 20)
        .unwrap();
    assert_eq!(attention.len(), 3);
    let kinds = attention
        .iter()
        .filter_map(|item| item["result"]["outboxKind"].as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(kinds, BTreeSet::from(["message", "projection", "result"]));
    assert!(attention.iter().all(|item| {
        item["result"]["compensation"] == "operator_attention_recorded"
            && item["result"]["code"] == "AGENT_COORDINATION_DELIVERY_FAILED"
    }));
}

#[test]
fn reusable_assignment_and_its_semantic_message_commit_atomically() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "atomic_message");
    let child = store
        .admit_agent(&admission(&owner, "spawn_atomic_message_target", 0))
        .unwrap();
    store
        .mark_agent_provisioned(&child.agent.agent_id, &child.assignment.assignment_id)
        .unwrap();
    let request = NewAgentAssignment {
        admission_key: "assignment_atomic_message".to_owned(),
        agent_id: child.agent.agent_id.clone(),
        requester_agent_id: Some(owner.agent_id.clone()),
        delegator_agent_id: Some(owner.agent_id.clone()),
        kind: AgentAssignmentKind::Instruction,
        offered: false,
        task: "Inspect the next durable unit.".to_owned(),
        context: json!({"source":"test"}),
        parent_execution_id: None,
        trace_id: "trace_atomic_message".to_owned(),
        causal_depth: 1,
        child_slot: Some(1),
        max_active_children: 8,
        max_child_executions: 64,
        max_execution_nodes: 64,
        max_causal_depth: 16,
        max_queued_assignments: 8,
        model: None,
        reasoning_level: None,
        authority_snapshot: json!({"functions":["filesystem_read"]}),
        resource_snapshot: json!({"workspaceId":owner.workspace_id}),
        write_scopes_snapshot: json!([]),
        limits_snapshot: json!({"turns":32}),
        retry_of_assignment_id: None,
        deadline_at: None,
        message: NewAgentAssignmentMessage {
            deduplication_key: "agent_message_atomic_effect".to_owned(),
            message_id: "agent_message_atomic".to_owned(),
            channel_id: channel(&owner.agent_id, &child.agent.agent_id),
            source_agent_id: owner.agent_id.clone(),
            source_session_id: owner.session_id.clone(),
            source_name: Some(owner.name.clone()),
            target_session_id: child.agent.session_id.clone(),
            kind: crate::shared::protocol::messages::AgentMessageKind::Instruction,
            authority: crate::shared::protocol::messages::AgentMessageAuthority::Owner,
            reply_to: None,
            text: "Inspect the next durable unit.".to_owned(),
            autonomous_hop: 1,
        },
    };
    let (assignment, created) = store.enqueue_agent_assignment(&request).unwrap();
    let (replay, replay_created) = store.enqueue_agent_assignment(&request).unwrap();
    assert!(created);
    assert!(!replay_created);
    assert_eq!(assignment.assignment_id, replay.assignment_id);
    let effect = store
        .pending_agent_outbox(20)
        .unwrap()
        .into_iter()
        .find(|effect| effect.deduplication_key == "agent_message_atomic_effect")
        .unwrap();
    assert_eq!(effect.assignment_id, Some(assignment.assignment_id));
    assert_eq!(effect.payload["messageId"], "agent_message_atomic");
    assert_eq!(effect.payload["traceId"], "trace_atomic_message");
}

#[test]
fn management_is_owned_or_explicit_and_promotion_preserves_identity() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "owner");
    let peer = root(&store, "peer");
    let child = store
        .admit_agent(&admission(&owner, "spawn_managed", 0))
        .unwrap();
    assert_eq!(
        store
            .agent_owned_subtree_ids(&child.agent.agent_id)
            .unwrap(),
        vec![child.agent.agent_id.clone()]
    );
    assert!(
        store
            .has_agent_management(
                &owner.agent_id,
                &child.agent.agent_id,
                AgentManagementCapability::Cancel,
            )
            .unwrap()
    );
    assert_eq!(
        store
            .list_agent_instances_for_root(&owner.session_id, false, 20)
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        store
            .list_child_agent_instances(&owner.agent_id, false, 20)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        store
            .list_agent_management_grants_for_subtree(&child.agent.agent_id, false, 20)
            .unwrap()
            .len(),
        0
    );
    assert!(
        !store
            .has_agent_management(
                &peer.agent_id,
                &child.agent.agent_id,
                AgentManagementCapability::Cancel,
            )
            .unwrap()
    );
    store
        .grant_agent_management(&NewAgentManagementGrant {
            idempotency_key: "grant_peer_cancel".to_owned(),
            target_agent_id: child.agent.agent_id.clone(),
            grantee_agent_id: peer.agent_id.clone(),
            granted_by_agent_id: owner.agent_id.clone(),
            capability: AgentManagementCapability::Cancel,
        })
        .unwrap();
    assert_eq!(
        store
            .list_agent_management_grants_for_subtree(&child.agent.agent_id, false, 20)
            .unwrap()
            .len(),
        1
    );
    assert!(
        store
            .has_agent_management(
                &peer.agent_id,
                &child.agent.agent_id,
                AgentManagementCapability::Cancel,
            )
            .unwrap()
    );

    store
        .mark_agent_provisioned(&child.agent.agent_id, &child.assignment.assignment_id)
        .unwrap();

    store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: child.assignment.assignment_id.clone(),
            expected_status: AgentAssignmentStatus::Queued,
            target_status: AgentAssignmentStatus::Running,
            result: None,
            error: None,
        })
        .unwrap();
    store
        .transition_agent_assignment(&AgentAssignmentTransition {
            assignment_id: child.assignment.assignment_id,
            expected_status: AgentAssignmentStatus::Running,
            target_status: AgentAssignmentStatus::Completed,
            result: Some(json!({"done":true})),
            error: None,
        })
        .unwrap();
    let promoted = store
        .promote_agent(&child.agent.agent_id, "promote_child")
        .unwrap();
    assert_eq!(promoted.agent_id, child.agent.agent_id);
    assert_eq!(promoted.session_id, child.agent.session_id);
    assert_eq!(promoted.visibility, AgentVisibility::Visible);
    assert_eq!(promoted.spawned_by_agent_id, Some(owner.agent_id));
    assert_eq!(promoted.management_owner_agent_id, None);
    assert_eq!(promoted.root_session_id, promoted.session_id);
    assert!(
        !store
            .has_agent_management(
                &peer.agent_id,
                &promoted.agent_id,
                AgentManagementCapability::Cancel,
            )
            .unwrap()
    );
    assert!(
        store
            .list_agent_management_grants_for_subtree(&promoted.agent_id, false, 20)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn management_grant_batch_is_atomic_and_replays_exact_result_set() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "grant_batch_owner");
    let peer = root(&store, "grant_batch_peer");
    let child = store
        .admit_agent(&admission(&owner, "grant_batch_child", 0))
        .unwrap();
    let request = NewAgentManagementGrantBatch {
        idempotency_key: "grant_batch_one".to_owned(),
        target_agent_id: child.agent.agent_id.clone(),
        grantee_agent_id: peer.agent_id.clone(),
        granted_by_agent_id: owner.agent_id.clone(),
        capabilities: vec![
            AgentManagementCapability::Assign,
            AgentManagementCapability::Cancel,
        ],
    };
    let first = store.grant_agent_management_batch(&request).unwrap();
    let mut replay = request.clone();
    replay.capabilities.reverse();
    let second = store.grant_agent_management_batch(&replay).unwrap();
    assert_eq!(first.len(), 2);
    assert_eq!(
        first
            .iter()
            .map(|grant| grant.grant_id.as_str())
            .collect::<Vec<_>>(),
        second
            .iter()
            .map(|grant| grant.grant_id.as_str())
            .collect::<Vec<_>>()
    );
    let mut conflict = request;
    conflict.capabilities = vec![AgentManagementCapability::Close];
    assert!(
        store
            .grant_agent_management_batch(&conflict)
            .unwrap_err()
            .contains("idempotency conflict")
    );
}

#[test]
fn stable_agent_directory_relationships_and_assignment_history_page_beyond_two_hundred() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let owner = root(&store, "pagination_owner");
    let mut children = Vec::new();

    // Stable agents may outlive arbitrarily many individual coordination
    // graphs. Complete each initial assignment so the active-child ceiling is
    // respected while the durable relationship directory grows beyond one
    // store page.
    for slot in 0..205_u32 {
        let admitted = store
            .admit_agent(&admission(
                &owner,
                &format!("pagination_child_{slot:03}"),
                slot,
            ))
            .unwrap();
        store
            .mark_agent_provisioned(&admitted.agent.agent_id, &admitted.assignment.assignment_id)
            .unwrap();
        complete_assignment(&store, admitted.assignment.assignment_id);
        children.push(admitted.agent);
    }

    // A nested branch proves that relationship ordering remains parent-first
    // even when the branch crosses a client page boundary.
    let mut nested_request = admission(&children[199], "pagination_grandchild", 999);
    nested_request.root_session_id = owner.root_session_id.clone();
    let grandchild = store.admit_agent(&nested_request).unwrap();
    store
        .mark_agent_provisioned(
            &grandchild.agent.agent_id,
            &grandchild.assignment.assignment_id,
        )
        .unwrap();
    complete_assignment(&store, grandchild.assignment.assignment_id);

    let closed_id = children.last().unwrap().agent_id.clone();
    store.close_agent_subtree(&closed_id).unwrap();

    let first_directory = store
        .agent_instance_directory_page(false, &[], "", 0, 200)
        .unwrap();
    let second_directory = store
        .agent_instance_directory_page(false, &[], "", 200, 200)
        .unwrap();
    assert_eq!(first_directory.total, 206);
    assert_eq!(first_directory.items.len(), 200);
    assert_eq!(second_directory.items.len(), 6);
    assert!(
        first_directory
            .items
            .iter()
            .chain(&second_directory.items)
            .all(|agent| agent.agent_id != closed_id)
    );
    assert_eq!(
        store
            .agent_instance_directory_page(true, &[], "", 0, 1)
            .unwrap()
            .total,
        207
    );

    let mut related_ids = children
        .iter()
        .map(|agent| agent.agent_id.clone())
        .collect::<Vec<_>>();
    related_ids.push(grandchild.agent.agent_id.clone());
    let first_relations = store
        .agent_relationship_page(&owner.agent_id, &related_ids, 0, 200)
        .unwrap();
    let second_relations = store
        .agent_relationship_page(&owner.agent_id, &related_ids, 200, 200)
        .unwrap();
    assert_eq!(first_relations.total, 206);
    assert_eq!(first_relations.items.len(), 200);
    assert_eq!(second_relations.items.len(), 6);
    let ordered_ids = first_relations
        .items
        .iter()
        .chain(&second_relations.items)
        .map(|agent| agent.agent_id.as_str())
        .collect::<Vec<_>>();
    let parent_index = ordered_ids
        .iter()
        .position(|agent_id| *agent_id == children[199].agent_id)
        .unwrap();
    let grandchild_index = ordered_ids
        .iter()
        .position(|agent_id| *agent_id == grandchild.agent.agent_id)
        .unwrap();
    assert!(parent_index < grandchild_index);

    let reusable = &children[0];
    for ordinal in 1..205_u32 {
        let (assignment, created) = store
            .enqueue_agent_assignment(&reassignment(&owner, reusable, ordinal))
            .unwrap();
        assert!(created);
        complete_assignment(&store, assignment.assignment_id);
    }
    let first_history = store
        .agent_assignment_history_page(&reusable.agent_id, 0, 200)
        .unwrap();
    let second_history = store
        .agent_assignment_history_page(&reusable.agent_id, 200, 200)
        .unwrap();
    assert_eq!(first_history.total, 205);
    assert_eq!(first_history.items.len(), 200);
    assert_eq!(second_history.items.len(), 5);
    assert!(
        first_history.items.last().unwrap().queue_ordinal
            > second_history.items.first().unwrap().queue_ordinal
    );
}

#[test]
fn disjoint_writes_coexist_and_process_claim_waits_for_all_writers() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let root = root(&store, "claims");
    let first = store
        .admit_agent(&admission(&root, "spawn_claim_a", 0))
        .unwrap();
    let second = store
        .admit_agent(&admission(&root, "spawn_claim_b", 1))
        .unwrap();
    let write_a = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "claim_a".to_owned(),
            holder: WorkspaceClaimHolder::AgentExecution {
                execution_id: first.execution.execution_id.clone(),
                agent_id: first.agent.agent_id.clone(),
            },
            workspace_id: root.workspace_id.clone(),
            kind: WorkspaceClaimKind::ScopedWrite,
            canonical_scope: "Sources/A".to_owned(),
        })
        .unwrap();
    let write_b = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "claim_b".to_owned(),
            holder: WorkspaceClaimHolder::AgentExecution {
                execution_id: second.execution.execution_id.clone(),
                agent_id: second.agent.agent_id.clone(),
            },
            workspace_id: root.workspace_id.clone(),
            kind: WorkspaceClaimKind::ScopedWrite,
            canonical_scope: "Sources/B".to_owned(),
        })
        .unwrap();
    assert_eq!(write_a.state, WorkspaceClaimState::Held);
    assert_eq!(write_b.state, WorkspaceClaimState::Held);
    let process = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "claim_process".to_owned(),
            holder: WorkspaceClaimHolder::AgentExecution {
                execution_id: first.execution.execution_id,
                agent_id: first.agent.agent_id,
            },
            workspace_id: root.workspace_id.clone(),
            kind: WorkspaceClaimKind::WorkspaceProcess,
            canonical_scope: ".".to_owned(),
        })
        .unwrap();
    assert_eq!(process.state, WorkspaceClaimState::Queued);
    assert_eq!(
        store
            .list_workspace_claims(None, Some(&root.workspace_id), false, 20)
            .unwrap()
            .len(),
        3
    );
    store
        .release_workspace_claim(&write_a.claim_id, false)
        .unwrap();
    assert_eq!(
        store
            .request_workspace_claim(&NewWorkspaceClaim {
                idempotency_key: "claim_process".to_owned(),
                holder: WorkspaceClaimHolder::AgentExecution {
                    execution_id: process.execution_id.clone().unwrap(),
                    agent_id: process.agent_id.clone().unwrap(),
                },
                workspace_id: process.workspace_id.clone(),
                kind: process.kind,
                canonical_scope: process.canonical_scope.clone(),
            })
            .unwrap()
            .state,
        WorkspaceClaimState::Queued
    );
    let promoted = store
        .release_workspace_claim(&write_b.claim_id, false)
        .unwrap();
    assert_eq!(promoted.len(), 1);
    assert_eq!(promoted[0].claim_id, process.claim_id);
    assert_eq!(promoted[0].state, WorkspaceClaimState::Held);
}

#[test]
fn root_sessions_hold_claims_without_synthetic_assignment_authority() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let claim = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "root_session_claim".to_owned(),
            holder: WorkspaceClaimHolder::Session {
                session_id: "session_visible_root".to_owned(),
            },
            workspace_id: "workspace_test".to_owned(),
            kind: WorkspaceClaimKind::WorkspaceProcess,
            canonical_scope: ".".to_owned(),
        })
        .unwrap();

    assert_eq!(claim.state, WorkspaceClaimState::Held);
    assert_eq!(claim.execution_id, None);
    assert_eq!(claim.agent_id, None);
    assert_eq!(
        claim.holder_session_id.as_deref(),
        Some("session_visible_root")
    );
}

#[test]
fn earlier_process_waiter_has_fifo_priority_over_later_disjoint_write() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let root = root(&store, "fifo");
    let first = store
        .admit_agent(&admission(&root, "fifo_first", 0))
        .unwrap();
    let second = store
        .admit_agent(&admission(&root, "fifo_second", 1))
        .unwrap();
    let held = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "fifo_held".to_owned(),
            holder: WorkspaceClaimHolder::AgentExecution {
                execution_id: first.execution.execution_id.clone(),
                agent_id: first.agent.agent_id.clone(),
            },
            workspace_id: root.workspace_id.clone(),
            kind: WorkspaceClaimKind::ScopedWrite,
            canonical_scope: "Sources/A".to_owned(),
        })
        .unwrap();
    let process = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "fifo_process".to_owned(),
            holder: WorkspaceClaimHolder::AgentExecution {
                execution_id: first.execution.execution_id,
                agent_id: first.agent.agent_id,
            },
            workspace_id: root.workspace_id.clone(),
            kind: WorkspaceClaimKind::WorkspaceProcess,
            canonical_scope: ".".to_owned(),
        })
        .unwrap();
    let later = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "fifo_later".to_owned(),
            holder: WorkspaceClaimHolder::AgentExecution {
                execution_id: second.execution.execution_id,
                agent_id: second.agent.agent_id,
            },
            workspace_id: root.workspace_id,
            kind: WorkspaceClaimKind::ScopedWrite,
            canonical_scope: "Sources/B".to_owned(),
        })
        .unwrap();

    assert_eq!(process.state, WorkspaceClaimState::Queued);
    assert_eq!(later.state, WorkspaceClaimState::Queued);
    let promoted = store
        .release_workspace_claim(&held.claim_id, false)
        .unwrap();
    assert_eq!(promoted.len(), 1);
    assert_eq!(promoted[0].claim_id, process.claim_id);
    assert_eq!(
        store
            .workspace_claim(&later.claim_id)
            .unwrap()
            .unwrap()
            .state,
        WorkspaceClaimState::Queued
    );
    let promoted = store
        .release_workspace_claim(&process.claim_id, false)
        .unwrap();
    assert_eq!(promoted.len(), 1);
    assert_eq!(promoted[0].claim_id, later.claim_id);
}

#[test]
fn active_claims_reject_case_ambiguous_path_prefixes() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let root = root(&store, "case");
    let first = store
        .admit_agent(&admission(&root, "case_first", 0))
        .unwrap();
    let second = store
        .admit_agent(&admission(&root, "case_second", 1))
        .unwrap();
    store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "case_upper".to_owned(),
            holder: WorkspaceClaimHolder::AgentExecution {
                execution_id: first.execution.execution_id,
                agent_id: first.agent.agent_id,
            },
            workspace_id: root.workspace_id.clone(),
            kind: WorkspaceClaimKind::ScopedWrite,
            canonical_scope: "Sources/A/file.rs".to_owned(),
        })
        .unwrap();
    let error = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "case_lower".to_owned(),
            holder: WorkspaceClaimHolder::AgentExecution {
                execution_id: second.execution.execution_id,
                agent_id: second.agent.agent_id,
            },
            workspace_id: root.workspace_id,
            kind: WorkspaceClaimKind::ScopedWrite,
            canonical_scope: "sources/B/file.rs".to_owned(),
        })
        .unwrap_err();
    assert!(error.contains("ambiguous case"));
}

#[test]
fn restart_reconciliation_cancels_orphaned_claims() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let claim = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "restart_claim".to_owned(),
            holder: WorkspaceClaimHolder::Session {
                session_id: "session_restart".to_owned(),
            },
            workspace_id: "workspace_test".to_owned(),
            kind: WorkspaceClaimKind::ScopedWrite,
            canonical_scope: "Sources/restart.rs".to_owned(),
        })
        .unwrap();
    assert_eq!(store.recover_interrupted_workspace_claims().unwrap(), 1);
    assert_eq!(
        store
            .workspace_claim(&claim.claim_id)
            .unwrap()
            .unwrap()
            .state,
        WorkspaceClaimState::Cancelled
    );
}

#[cfg(unix)]
#[test]
fn restart_recovery_signals_only_a_process_proving_its_claim_identity() {
    use std::os::unix::process::CommandExt;

    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let claim = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "restart_process_claim".to_owned(),
            holder: WorkspaceClaimHolder::Session {
                session_id: "session_restart_process".to_owned(),
            },
            workspace_id: "workspace_test".to_owned(),
            kind: WorkspaceClaimKind::WorkspaceProcess,
            canonical_scope: ".".to_owned(),
        })
        .unwrap();
    let mut command = std::process::Command::new("/bin/sh");
    command.args(["-c", "sleep 10"]).process_group(0);
    let mut child = command.spawn().unwrap();
    store
        .bind_workspace_process_claim(&claim.claim_id, child.id())
        .unwrap();

    assert_eq!(store.recover_interrupted_workspace_claims().unwrap(), 1);
    let mut status = None;
    for _ in 0..100 {
        status = child.try_wait().unwrap();
        if status.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    if status.is_none() {
        let _ = child.kill();
        let _ = child.wait();
        panic!("recovery did not terminate the captured process group");
    }
    let status = status.unwrap();
    assert!(!status.success());
    assert_eq!(
        store
            .workspace_claim(&claim.claim_id)
            .unwrap()
            .unwrap()
            .state,
        WorkspaceClaimState::Cancelled
    );
}

#[cfg(unix)]
#[test]
fn restart_closes_an_unbound_process_gate_before_user_code_can_run() {
    use std::os::unix::process::CommandExt;

    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let claim = store
        .request_workspace_claim(&NewWorkspaceClaim {
            idempotency_key: "restart_unbound_process_gate".to_owned(),
            holder: WorkspaceClaimHolder::Session {
                session_id: "session_restart_unbound_process".to_owned(),
            },
            workspace_id: "workspace_test".to_owned(),
            kind: WorkspaceClaimKind::WorkspaceProcess,
            canonical_scope: ".".to_owned(),
        })
        .unwrap();
    let gate = store
        .prepare_workspace_process_gate(&claim.claim_id)
        .unwrap();
    let marker = directory.path().join("user-code-ran");
    let mut command = std::process::Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(
            "while [ -d \"$1\" ] && [ ! -f \"$1/go\" ]; do sleep 0.01; done; \
             [ -f \"$1/go\" ] || exit 125; shift; exec \"$@\"",
        )
        .arg("tron-process-admission-test")
        .arg(&gate)
        .arg("/usr/bin/touch")
        .arg(&marker)
        .process_group(0);
    let mut child = command.spawn().unwrap();
    std::thread::sleep(std::time::Duration::from_millis(40));
    assert!(child.try_wait().unwrap().is_none());
    assert!(!marker.exists());

    assert_eq!(store.recover_interrupted_workspace_claims().unwrap(), 1);
    let mut status = None;
    for _ in 0..100 {
        status = child.try_wait().unwrap();
        if status.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    if status.is_none() {
        let _ = child.kill();
        let _ = child.wait();
        panic!("unbound process helper did not observe its closed admission gate");
    }
    assert!(!marker.exists());
    assert_eq!(
        store
            .workspace_claim(&claim.claim_id)
            .unwrap()
            .unwrap()
            .state,
        WorkspaceClaimState::Cancelled
    );
}
