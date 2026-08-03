use super::*;
use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliverySourceKind, AgentDeliveryTarget,
    AgentDeliveryWakePolicy, AgentMailboxScope, AgentWaitMode, NewAgentDelivery,
    NewAgentTaskDelivery, NewAgentWait, WorkerTerminalEvidence,
};

fn session_delivery(
    session: &SessionRow,
    idempotency_key: &str,
    content: &str,
) -> NewAgentDelivery {
    NewAgentDelivery {
        idempotency_key: idempotency_key.to_owned(),
        source_kind: AgentDeliverySourceKind::AgentMessage,
        intent: Some(AgentDeliveryIntent::Information),
        source_session_id: Some(session.id.clone()),
        source_workspace_id: session.workspace_id.clone(),
        source_invocation_id: None,
        source_trace_id: Some("trace-delivery".to_owned()),
        source_root_invocation_id: None,
        causal_depth: 1,
        target: AgentDeliveryTarget::Session {
            session_id: session.id.clone(),
        },
        wake_policy: AgentDeliveryWakePolicy::Passive,
        boundary: AgentDeliveryBoundary::NextTurn,
        originating_run_id: None,
        arrived_during_run_id: None,
        defer_until_run_id: None,
        result_invocation_id: None,
        content: content.to_owned(),
        not_before: None,
        expires_at: None,
    }
}

#[test]
fn delivery_is_idempotent_and_observed_only_after_its_leased_turn() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let first = store
        .create_agent_delivery(&session_delivery(&session, "send:one", "reference"))
        .unwrap();
    let replay = store
        .create_agent_delivery(&session_delivery(&session, "send:one", "reference"))
        .unwrap();
    assert_eq!(first.delivery_id, replay.delivery_id);

    let leased = store
        .lease_agent_deliveries(&session.id, "run-one", 2, None)
        .unwrap();
    assert_eq!(leased.len(), 1);
    assert_eq!(leased[0].leased_run_id.as_deref(), Some("run-one"));
    assert_eq!(leased[0].lease_count, 1);
    assert_eq!(
        store
            .observe_agent_deliveries(&session.id, "run-one", 1)
            .unwrap(),
        0
    );
    assert_eq!(
        store
            .observe_agent_deliveries(&session.id, "run-one", 2)
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .agent_delivery(&first.delivery_id)
            .unwrap()
            .unwrap()
            .disposition,
        super::super::deliveries::AgentDeliveryDisposition::Observed
    );
}

#[test]
fn next_run_delivery_excludes_the_recorded_run() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let mut delivery = session_delivery(&session, "send:next-run", "later");
    delivery.boundary = AgentDeliveryBoundary::NextRun;
    delivery.defer_until_run_id = Some("run-current".to_owned());
    let created = store.create_agent_delivery(&delivery).unwrap();

    assert!(
        store
            .lease_agent_deliveries(&session.id, "run-current", 1, None)
            .unwrap()
            .is_empty()
    );
    let next = store
        .lease_agent_deliveries(&session.id, "run-next", 1, None)
        .unwrap();
    assert_eq!(next[0].delivery_id, created.delivery_id);
}

#[test]
fn mailbox_claim_is_all_or_none_and_transfers_result_grant() {
    let store = setup();
    let source = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let target = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let mut mailbox = session_delivery(&source, "mailbox:one", "worker result");
    mailbox.source_kind = AgentDeliverySourceKind::WorkerResult;
    mailbox.result_invocation_id = Some("worker-run-one".to_owned());
    mailbox.target = AgentDeliveryTarget::Mailbox {
        scope: AgentMailboxScope::Workspace,
        workspace_id: Some(source.workspace_id.clone()),
        name: "results".to_owned(),
    };
    let created = store.create_agent_delivery(&mailbox).unwrap();

    let error = store
        .claim_agent_mailbox(
            &target.id,
            &[created.delivery_id.clone(), "missing".to_owned()],
        )
        .unwrap_err();
    assert!(error.to_string().contains("unavailable"));
    assert!(
        !store
            .session_has_agent_result_grant(&target.id, "worker-run-one")
            .unwrap()
    );

    let claimed = store
        .claim_agent_mailbox(&target.id, std::slice::from_ref(&created.delivery_id))
        .unwrap();
    assert_eq!(
        claimed[0].target_session_id.as_deref(),
        Some(target.id.as_str())
    );
    assert!(
        store
            .session_has_agent_result_grant(&target.id, "worker-run-one")
            .unwrap()
    );
}

#[test]
fn concurrent_mailbox_claim_has_exactly_one_winner() {
    let store = std::sync::Arc::new(setup());
    let source = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let first_target = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let second_target = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let mut mailbox = session_delivery(&source, "mailbox:race", "claim exactly once");
    mailbox.target = AgentDeliveryTarget::Mailbox {
        scope: AgentMailboxScope::Workspace,
        workspace_id: Some(source.workspace_id),
        name: "race".to_owned(),
    };
    let delivery_id = store.create_agent_delivery(&mailbox).unwrap().delivery_id;
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));

    let claim = |target_id: String| {
        let store = store.clone();
        let barrier = barrier.clone();
        let delivery_id = delivery_id.clone();
        std::thread::spawn(move || {
            barrier.wait();
            store.claim_agent_mailbox(&target_id, &[delivery_id])
        })
    };
    let first = claim(first_target.id);
    let second = claim(second_target.id);
    barrier.wait();
    let results = [first.join().unwrap(), second.join().unwrap()];

    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(results.iter().filter(|result| result.is_err()).count(), 1);
}

#[test]
fn task_and_initial_delivery_are_created_atomically_and_replay_together() {
    let store = setup();
    let source = store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Source"), None)
        .unwrap()
        .session;
    let request = NewAgentTaskDelivery {
        idempotency_key: "agent-send:new-task".to_owned(),
        source_session_id: source.id.clone(),
        title: "Investigate delivery".to_owned(),
        model: None,
        working_directory: None,
        intent: AgentDeliveryIntent::Request,
        wake_policy: AgentDeliveryWakePolicy::Wake,
        boundary: AgentDeliveryBoundary::NextRun,
        content: "Inspect the durable result.".to_owned(),
        expires_at: None,
        source_invocation_id: Some("tool-call-one".to_owned()),
        source_trace_id: Some("trace-one".to_owned()),
        source_root_invocation_id: None,
        causal_depth: 2,
    };
    let first = store.create_agent_task_with_delivery(&request).unwrap();
    let replay = store.create_agent_task_with_delivery(&request).unwrap();
    assert!(first.created);
    assert!(!replay.created);
    assert_eq!(first.session.session.id, replay.session.session.id);
    assert_eq!(first.delivery.delivery_id, replay.delivery.delivery_id);
    assert_eq!(
        first.session.session.latest_model, source.latest_model,
        "new visible tasks inherit the source model"
    );
    assert_eq!(
        first.session.session.working_directory,
        source.working_directory
    );
}

#[test]
fn wait_reconciliation_is_idempotent_and_any_ignores_remaining_members() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let wait = store
        .create_agent_wait(&NewAgentWait {
            idempotency_key: "wait:one".to_owned(),
            session_id: session.id.clone(),
            source_invocation_id: "agent-call-one".to_owned(),
            source_trace_id: "trace-one".to_owned(),
            source_root_invocation_id: None,
            causal_depth: 1,
            mode: AgentWaitMode::Any,
            invocation_ids: vec!["run-a".to_owned(), "run-b".to_owned()],
        })
        .unwrap();
    let deliveries = store
        .reconcile_agent_waits(&[WorkerTerminalEvidence {
            invocation_id: "run-b".to_owned(),
            status: "failed".to_owned(),
            evidence: "bounded failure".to_owned(),
        }])
        .unwrap();
    assert_eq!(deliveries.len(), 1);
    assert_eq!(deliveries[0].wake_policy, AgentDeliveryWakePolicy::Wake);
    assert!(
        store
            .reconcile_agent_waits(&[WorkerTerminalEvidence {
                invocation_id: "run-b".to_owned(),
                status: "failed".to_owned(),
                evidence: "bounded failure".to_owned(),
            }])
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .create_agent_wait(&NewAgentWait {
                idempotency_key: "wait:one".to_owned(),
                session_id: session.id,
                source_invocation_id: "agent-call-one".to_owned(),
                source_trace_id: "trace-one".to_owned(),
                source_root_invocation_id: None,
                causal_depth: 1,
                mode: AgentWaitMode::Any,
                invocation_ids: vec!["run-a".to_owned(), "run-b".to_owned()],
            })
            .unwrap()
            .wait_id,
        wait.wait_id
    );
}

#[test]
fn delivery_scope_is_closed_except_for_profile_mailboxes() {
    let store = setup();
    let source = store
        .create_session("gpt-5.6-sol", "/tmp/source-workspace", None, None)
        .unwrap()
        .session;
    let peer = store
        .create_session("gpt-5.6-sol", "/tmp/source-workspace", None, None)
        .unwrap()
        .session;
    let foreign = store
        .create_session("gpt-5.6-sol", "/tmp/foreign-workspace", None, None)
        .unwrap()
        .session;

    let mut same_workspace = session_delivery(&source, "send:peer", "same workspace");
    same_workspace.target = AgentDeliveryTarget::Session {
        session_id: peer.id.clone(),
    };
    assert!(store.create_agent_delivery(&same_workspace).is_ok());

    let mut cross_workspace = session_delivery(&source, "send:foreign", "forged target");
    cross_workspace.target = AgentDeliveryTarget::Session {
        session_id: foreign.id.clone(),
    };
    assert!(
        store
            .create_agent_delivery(&cross_workspace)
            .unwrap_err()
            .to_string()
            .contains("source workspace")
    );

    let mut forged_source = session_delivery(&source, "send:forged-source", "forged source");
    forged_source.source_workspace_id = foreign.workspace_id.clone();
    assert!(
        store
            .create_agent_delivery(&forged_source)
            .unwrap_err()
            .to_string()
            .contains("derived workspace")
    );

    let mut workspace_mailbox = session_delivery(&source, "mailbox:workspace", "workspace only");
    workspace_mailbox.target = AgentDeliveryTarget::Mailbox {
        scope: AgentMailboxScope::Workspace,
        workspace_id: Some(source.workspace_id.clone()),
        name: "updates".to_owned(),
    };
    store.create_agent_delivery(&workspace_mailbox).unwrap();
    assert_eq!(
        store
            .list_agent_mailbox(&peer.id, AgentMailboxScope::Workspace, "updates", 10)
            .unwrap()
            .len(),
        1
    );
    assert!(
        store
            .list_agent_mailbox(&foreign.id, AgentMailboxScope::Workspace, "updates", 10)
            .unwrap()
            .is_empty()
    );

    let mut profile_mailbox = session_delivery(&source, "mailbox:profile", "profile-wide");
    profile_mailbox.target = AgentDeliveryTarget::Mailbox {
        scope: AgentMailboxScope::Profile,
        workspace_id: None,
        name: "updates".to_owned(),
    };
    let profile = store.create_agent_delivery(&profile_mailbox).unwrap();
    assert_eq!(
        store
            .list_agent_mailbox(&foreign.id, AgentMailboxScope::Profile, "updates", 10)
            .unwrap()[0]
            .delivery_id,
        profile.delivery_id
    );
}

#[test]
fn leasing_is_fifo_bounded_and_release_preserves_at_least_once_delivery() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    for ordinal in 0..10 {
        store
            .create_agent_delivery(&session_delivery(
                &session,
                &format!("send:{ordinal:02}"),
                &format!("delivery-{ordinal}"),
            ))
            .unwrap();
    }

    let first = store
        .lease_agent_deliveries(&session.id, "run-first", 1, None)
        .unwrap();
    assert_eq!(first.len(), 8);
    assert_eq!(first[0].content, "delivery-0");
    assert_eq!(first[7].content, "delivery-7");
    assert_eq!(store.release_agent_delivery_leases("run-first").unwrap(), 8);

    let replay = store
        .lease_agent_deliveries(&session.id, "run-replay", 1, None)
        .unwrap();
    assert_eq!(
        replay
            .iter()
            .map(|delivery| delivery.delivery_id.as_str())
            .collect::<Vec<_>>(),
        first
            .iter()
            .map(|delivery| delivery.delivery_id.as_str())
            .collect::<Vec<_>>()
    );
    assert!(replay.iter().all(AgentDeliveryRecord::is_redelivery));
}

#[test]
fn startup_lease_recovery_preserves_unobserved_delivery() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let delivery = store
        .create_agent_delivery(&session_delivery(
            &session,
            "send:startup-recovery",
            "recover after process restart",
        ))
        .unwrap();
    assert_eq!(
        store
            .lease_agent_deliveries(&session.id, "run-before-crash", 1, None)
            .unwrap()
            .len(),
        1
    );

    assert_eq!(store.clear_agent_delivery_leases().unwrap(), 1);
    let recovered = store
        .lease_agent_deliveries(&session.id, "run-after-restart", 1, None)
        .unwrap();
    assert_eq!(recovered[0].delivery_id, delivery.delivery_id);
    assert!(recovered[0].is_redelivery());
}

#[test]
fn not_before_expiry_archiving_and_wake_retry_are_durable_policy() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let mut future = session_delivery(&session, "send:future", "future");
    future.wake_policy = AgentDeliveryWakePolicy::Wake;
    future.not_before = Some((chrono::Utc::now() + chrono::Duration::minutes(5)).to_rfc3339());
    store.create_agent_delivery(&future).unwrap();
    assert!(
        store
            .pending_agent_wakes_for_session(&session.id, 8)
            .unwrap()
            .is_empty()
    );

    let mut expired = session_delivery(&session, "send:expired", "expired");
    expired.expires_at = Some((chrono::Utc::now() - chrono::Duration::minutes(5)).to_rfc3339());
    expired.result_invocation_id = Some("expired-result".to_owned());
    let expired = store.create_agent_delivery(&expired).unwrap();
    assert!(
        !store
            .session_has_agent_result_grant(&session.id, "expired-result")
            .unwrap(),
        "read-side expiry must revoke a result grant before any provider lease"
    );
    assert!(
        store
            .lease_agent_deliveries(&session.id, "run-expired", 1, None)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .agent_delivery(&expired.delivery_id)
            .unwrap()
            .unwrap()
            .disposition,
        super::super::deliveries::AgentDeliveryDisposition::Cancelled
    );

    let mut wake = session_delivery(&session, "send:wake-retry", "wake");
    wake.wake_policy = AgentDeliveryWakePolicy::Wake;
    let wake = store.create_agent_delivery(&wake).unwrap();
    store.end_session(&session.id).unwrap();
    assert!(
        store
            .pending_agent_wakes_for_session(&session.id, 8)
            .unwrap()
            .is_empty(),
        "archived sessions retain deliveries but suppress wakes"
    );
    store.clear_session_ended(&session.id).unwrap();
    assert_eq!(
        store
            .pending_agent_wakes_for_session(&session.id, 8)
            .unwrap(),
        vec![wake.delivery_id.clone()]
    );

    assert!(
        !store
            .record_agent_wake_failure(&session.id, std::slice::from_ref(&wake.delivery_id), "one")
            .unwrap()
    );
    assert!(
        !store
            .record_agent_wake_failure(&session.id, std::slice::from_ref(&wake.delivery_id), "two")
            .unwrap()
    );
    assert!(
        store
            .record_agent_wake_failure(
                &session.id,
                std::slice::from_ref(&wake.delivery_id),
                "three"
            )
            .unwrap()
    );
    let exhausted = store.agent_delivery(&wake.delivery_id).unwrap().unwrap();
    assert_eq!(exhausted.wake_attempts, 3);
    assert_eq!(exhausted.wake_policy, AgentDeliveryWakePolicy::Passive);
    assert_eq!(exhausted.projection_status(), "retry_exhausted");
    assert_eq!(
        store.retry_exhausted_agent_deliveries(8).unwrap(),
        vec![(wake.delivery_id, session.id, "three".to_owned(),)]
    );
}

#[test]
fn worker_audit_sessions_cannot_use_agent_delivery_or_mailboxes() {
    let store = setup();
    let visible = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let worker = store
        .create_worker_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;

    let mut from_worker = session_delivery(&worker, "worker:source", "not allowed");
    from_worker.target = AgentDeliveryTarget::Session {
        session_id: visible.id.clone(),
    };
    assert!(
        store
            .create_agent_delivery(&from_worker)
            .unwrap_err()
            .to_string()
            .contains("worker audit sessions")
    );

    let mut to_worker = session_delivery(&visible, "worker:target", "not allowed");
    to_worker.target = AgentDeliveryTarget::Session {
        session_id: worker.id.clone(),
    };
    assert!(
        store
            .create_agent_delivery(&to_worker)
            .unwrap_err()
            .to_string()
            .contains("worker audit sessions")
    );
    assert!(
        store
            .list_agent_mailbox(&worker.id, AgentMailboxScope::Workspace, "results", 8)
            .unwrap_err()
            .to_string()
            .contains("worker audit sessions")
    );
}

#[test]
fn causal_depth_suppresses_autonomous_wakes_and_deletion_revokes_state() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let mut deep = session_delivery(&session, "send:deep", "bounded loop");
    deep.causal_depth = 17;
    deep.wake_policy = AgentDeliveryWakePolicy::Wake;
    deep.result_invocation_id = Some("result-deep".to_owned());
    let delivery = store.create_agent_delivery(&deep).unwrap();
    assert_eq!(delivery.wake_policy, AgentDeliveryWakePolicy::Passive);
    assert!(
        store
            .session_has_agent_result_grant(&session.id, "result-deep")
            .unwrap()
    );
    store
        .create_agent_wait(&NewAgentWait {
            idempotency_key: "wait:delete".to_owned(),
            session_id: session.id.clone(),
            source_invocation_id: "agent-call".to_owned(),
            source_trace_id: "trace".to_owned(),
            source_root_invocation_id: None,
            causal_depth: 1,
            mode: AgentWaitMode::All,
            invocation_ids: vec!["worker-run".to_owned()],
        })
        .unwrap();

    assert!(store.delete_session(&session.id).unwrap());
    assert!(!store.has_agent_result_grant("result-deep").unwrap());
    let connection = store.conn().unwrap();
    let delivery_count: usize = connection
        .query_row(
            "SELECT COUNT(*) FROM agent_deliveries WHERE delivery_id=?1",
            [delivery.delivery_id],
            |row| row.get(0),
        )
        .unwrap();
    let wait_count: usize = connection
        .query_row(
            "SELECT COUNT(*) FROM agent_waits WHERE idempotency_key='wait:delete'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!((delivery_count, wait_count), (0, 0));
}

#[test]
fn all_wait_records_mixed_terminal_evidence_once() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    store
        .create_agent_wait(&NewAgentWait {
            idempotency_key: "wait:all".to_owned(),
            session_id: session.id,
            source_invocation_id: "agent-call".to_owned(),
            source_trace_id: "trace".to_owned(),
            source_root_invocation_id: None,
            causal_depth: 1,
            mode: AgentWaitMode::All,
            invocation_ids: vec!["worker-ok".to_owned(), "worker-cancelled".to_owned()],
        })
        .unwrap();
    assert!(
        store
            .reconcile_agent_waits(&[WorkerTerminalEvidence {
                invocation_id: "worker-ok".to_owned(),
                status: "completed".to_owned(),
                evidence: "done".to_owned(),
            }])
            .unwrap()
            .is_empty()
    );
    let resolved = store
        .reconcile_agent_waits(&[WorkerTerminalEvidence {
            invocation_id: "worker-cancelled".to_owned(),
            status: "cancelled".to_owned(),
            evidence: "cancelled by caller".to_owned(),
        }])
        .unwrap();
    assert_eq!(resolved.len(), 1);
    assert!(resolved[0].content.contains("\"status\":\"completed\""));
    assert!(resolved[0].content.contains("\"status\":\"cancelled\""));
    assert!(
        store
            .reconcile_agent_waits(&[WorkerTerminalEvidence {
                invocation_id: "worker-ok".to_owned(),
                status: "completed".to_owned(),
                evidence: "duplicate".to_owned(),
            }])
            .unwrap()
            .is_empty()
    );
}

#[test]
fn explicit_wait_replaces_an_unprepared_automatic_worker_delivery() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let mut automatic = session_delivery(
        &session,
        "worker-terminal:worker-before-wait",
        "passive worker completion",
    );
    automatic.source_kind = AgentDeliverySourceKind::WorkerResult;
    automatic.result_invocation_id = Some("worker-before-wait".to_owned());
    let passive = store.create_agent_delivery(&automatic).unwrap();
    store
        .create_agent_wait(&NewAgentWait {
            idempotency_key: "wait:after-completion".to_owned(),
            session_id: session.id.clone(),
            source_invocation_id: "agent-call".to_owned(),
            source_trace_id: "trace".to_owned(),
            source_root_invocation_id: None,
            causal_depth: 1,
            mode: AgentWaitMode::All,
            invocation_ids: vec!["worker-before-wait".to_owned()],
        })
        .unwrap();

    let resolved = store
        .reconcile_agent_waits(&[WorkerTerminalEvidence {
            invocation_id: "worker-before-wait".to_owned(),
            status: "completed".to_owned(),
            evidence: r#"{"workerId":"waited-worker","status":"completed"}"#.to_owned(),
        }])
        .unwrap();

    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved[0].wake_policy, AgentDeliveryWakePolicy::Wake);
    assert_ne!(resolved[0].delivery_id, passive.delivery_id);
    assert_eq!(
        store
            .agent_delivery(&passive.delivery_id)
            .unwrap()
            .unwrap()
            .projection_status(),
        "cancelled"
    );
    assert!(store.has_agent_wait_member("worker-before-wait").unwrap());
}

#[test]
fn explicit_wait_reuses_an_automatic_delivery_already_in_provider_context() {
    let store = setup();
    let session = store
        .create_session("gpt-5.6-sol", "/tmp/project", None, None)
        .unwrap()
        .session;
    let mut automatic = session_delivery(
        &session,
        "worker-terminal:worker-already-prepared",
        "prepared worker completion",
    );
    automatic.source_kind = AgentDeliverySourceKind::WorkerResult;
    automatic.result_invocation_id = Some("worker-already-prepared".to_owned());
    let passive = store.create_agent_delivery(&automatic).unwrap();
    let leased = store
        .lease_agent_deliveries(&session.id, "active-run", 1, None)
        .unwrap();
    assert_eq!(leased[0].delivery_id, passive.delivery_id);
    store
        .create_agent_wait(&NewAgentWait {
            idempotency_key: "wait:after-preparation".to_owned(),
            session_id: session.id,
            source_invocation_id: "agent-call".to_owned(),
            source_trace_id: "trace".to_owned(),
            source_root_invocation_id: None,
            causal_depth: 1,
            mode: AgentWaitMode::All,
            invocation_ids: vec!["worker-already-prepared".to_owned()],
        })
        .unwrap();

    let resolved = store
        .reconcile_agent_waits(&[WorkerTerminalEvidence {
            invocation_id: "worker-already-prepared".to_owned(),
            status: "completed".to_owned(),
            evidence: r#"{"workerId":"waited-worker","status":"completed"}"#.to_owned(),
        }])
        .unwrap();

    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved[0].delivery_id, passive.delivery_id);
    assert_eq!(
        store
            .list_agent_deliveries_for_session(&resolved[0].target_session_id.clone().unwrap(), 10)
            .unwrap()
            .len(),
        1
    );
}
