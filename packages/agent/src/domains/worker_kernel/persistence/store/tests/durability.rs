//! Durability persistence tests.

use super::*;

#[test]
fn self_wakeup_completion_is_atomic_deduplicated_and_not_early() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.worker_id = Some("self-wakeup-worker".to_owned());
    candidate.name = "Self Wakeup Worker".to_owned();
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let not_before = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();

    for source_key in ["wakeup-source-one", "wakeup-source-two"] {
        let (source, replayed) = store
            .begin_invocation(
                &published.worker.worker_id,
                &published.version,
                &json!({"topic":"tick"}),
                source_key,
                &format!("trace-{source_key}"),
                0,
                "manual",
                None,
            )
            .unwrap();
        assert!(!replayed);
        assert!(store.claim_running(&source.invocation_id).unwrap());
        store
            .complete_invocation_with_effects(
                &source.invocation_id,
                &published.worker.worker_id,
                &json!({"status":"accepted"}),
                &[],
                &[],
                &[],
                Some(&PreparedWorkerWakeup {
                    not_before: not_before.clone(),
                    deduplication_key: "same-next-wakeup".to_owned(),
                    input: json!({"topic":"tick"}),
                }),
            )
            .unwrap();
    }

    let connection = store.connection().unwrap();
    let (count, version, source, stored_not_before, stored_key): (
        u32,
        String,
        String,
        String,
        String,
    ) = connection
        .query_row(
            "SELECT COUNT(*),worker_version,wake_source_invocation_id,not_before,idempotency_key
             FROM worker_invocations WHERE trigger_kind='self_wakeup'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(count, 1);
    assert_eq!(version, published.version);
    assert!(source.starts_with("worker_run_"));
    assert_eq!(stored_not_before, not_before);
    assert_eq!(stored_key, "self_wakeup:same-next-wakeup");
    assert!(
        store
            .queued_invocations(100)
            .unwrap()
            .iter()
            .all(|invocation| invocation.trigger_kind != "self_wakeup")
    );
    connection
        .execute(
            "UPDATE worker_invocations SET not_before=?1 WHERE trigger_kind='self_wakeup'",
            [(chrono::Utc::now() - chrono::Duration::seconds(1)).to_rfc3339()],
        )
        .unwrap();
    assert!(
        store
            .queued_invocations(100)
            .unwrap()
            .iter()
            .any(|invocation| invocation.trigger_kind == "self_wakeup")
    );
}

#[test]
fn interrupted_claim_is_terminalized_before_redelivery() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"recover"}),
            "recover-owned-delivery",
            "trace-recover-owned-delivery",
            0,
            "manual",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());

    let queued = store
        .interrupt_running_invocation(&run.invocation_id, "test owner disappeared")
        .unwrap();
    assert_eq!(queued.status, "queued");
    let attempts = store.attempts(&run.invocation_id).unwrap();
    assert_eq!(attempts[0]["status"], "interrupted");
    assert!(store.claim_running(&run.invocation_id).unwrap());
    assert_eq!(store.attempts(&run.invocation_id).unwrap().len(), 2);
}

#[test]
fn interrupted_attempt_count_survives_store_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let (worker_id, version) = {
        let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
        let mut prepared = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let published = store.publish(prepared).unwrap();
        (published.worker.worker_id, published.version)
    };
    let reason = "claimed worker delivery lost its in-process owner";

    for index in 1..=3 {
        let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
        let (run, _) = store
            .begin_invocation(
                &worker_id,
                &version,
                &json!({"index":index}),
                &format!("durable-orphan-{index}"),
                &format!("trace-durable-orphan-{index}"),
                0,
                "manual",
                None,
            )
            .unwrap();
        assert!(store.claim_running(&run.invocation_id).unwrap());
        store
            .interrupt_running_invocation(&run.invocation_id, reason)
            .unwrap();
        assert_eq!(
            store.interrupted_attempt_count(&worker_id, reason).unwrap(),
            index
        );
    }
}

#[test]
fn worker_dispatch_completion_atomically_queues_one_causal_child_and_replays() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();

    let mut target = bundle();
    target.worker_id = Some("dispatch-target".to_owned());
    target.name = "Dispatch Target".to_owned();
    target.description = "Accept a closed dispatched input".to_owned();
    target.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["action"],
        "properties":{"action":{"const":"deliver"}}
    });
    let mut prepared = store.prepare(target, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let target = store.publish(prepared).unwrap();

    let mut source = bundle();
    source.worker_id = Some("dispatch-source".to_owned());
    source.name = "Dispatch Source".to_owned();
    source.description = "Emit a fixed asynchronous route".to_owned();
    let mut prepared = store.prepare(source, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let source = store.publish(prepared).unwrap();

    for key in ["source-run-one", "source-run-two"] {
        let (run, replayed) = store
            .begin_invocation(
                &source.worker.worker_id,
                &source.version,
                &json!({"action":"start"}),
                key,
                "trace-dispatch",
                0,
                "manual",
                Some("session-dispatch"),
            )
            .unwrap();
        assert!(!replayed);
        assert!(store.claim_running(&run.invocation_id).unwrap());
        store
            .complete_invocation_with_effects(
                &run.invocation_id,
                &source.worker.worker_id,
                &json!({"status":"accepted"}),
                &[],
                &[],
                &[PreparedWorkerDispatch {
                    route: "policy".to_owned(),
                    deduplication_key: "logical-occurrence".to_owned(),
                    input: json!({"action":"deliver"}),
                    target_worker_id: target.worker.worker_id.clone(),
                    target_worker_version: target.version.clone(),
                    response_owner:
                        crate::domains::worker_kernel::types::WorkerDispatchResponseOwner::Source,
                }],
                None,
            )
            .unwrap();
    }

    let connection = store.connection().unwrap();
    let (dispatch_count, child_count): (u32, u32) = connection
        .query_row(
            "SELECT
                (SELECT COUNT(*) FROM worker_dispatches),
                (SELECT COUNT(*) FROM worker_invocations WHERE trigger_kind='worker_dispatch')",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((dispatch_count, child_count), (1, 1));
    let child = connection
        .query_row(
            "SELECT status,trace_id,causal_depth,parent_worker_invocation_id,
                    origin_session_id,interaction_mode,input_json
             FROM worker_invocations WHERE trigger_kind='worker_dispatch'",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, u32>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(child.0, "queued");
    assert_eq!(child.1, "trace-dispatch");
    assert_eq!(child.2, 1);
    assert_eq!(child.4, "session-dispatch");
    assert_eq!(child.5, "background");
    assert_eq!(
        serde_json::from_str::<Value>(&child.6).unwrap(),
        json!({"action":"deliver"})
    );
    drop(connection);
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    assert_eq!(
        reopened
            .queued_invocations(10)
            .unwrap()
            .into_iter()
            .filter(|run| run.trigger_kind == "worker_dispatch")
            .count(),
        1
    );
}

#[test]
fn worker_dispatch_admission_failure_rolls_back_source_completion_for_retry() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();

    let mut target = bundle();
    target.worker_id = Some("session-organizer".to_owned());
    target.name = "Session Organizer".to_owned();
    let mut prepared = store.prepare(target, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let target = store.publish(prepared).unwrap();

    let mut source = bundle();
    source.worker_id = Some("session-title-policy".to_owned());
    source.name = "Session Title Policy".to_owned();
    let mut prepared = store.prepare(source, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let source = store.publish(prepared).unwrap();
    let (run, replayed) = store
        .begin_invocation(
            &source.worker.worker_id,
            &source.version,
            &json!({"userPrompt":"Organize this session."}),
            "session-title-organization-admission",
            "trace-session-organization",
            0,
            "engine_hook:session_title",
            Some("session-organization-source"),
        )
        .unwrap();
    assert!(!replayed);
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .connection()
        .unwrap()
        .execute_batch(
            "CREATE TRIGGER fail_session_organization_dispatch
             BEFORE INSERT ON worker_dispatches
             WHEN NEW.route='session-organization-after-title'
             BEGIN
                 SELECT RAISE(ABORT,'simulated organization admission failure');
             END;",
        )
        .unwrap();
    let dispatch = PreparedWorkerDispatch {
        route: "session-organization-after-title".to_owned(),
        deduplication_key: "session-title-source".to_owned(),
        input: json!({"action":"session_organization"}),
        target_worker_id: target.worker.worker_id.clone(),
        target_worker_version: target.version.clone(),
        response_owner: crate::domains::worker_kernel::types::WorkerDispatchResponseOwner::Target,
    };

    let error = store
        .complete_invocation_with_effects(
            &run.invocation_id,
            &source.worker.worker_id,
            &json!({"title":"Organized Session"}),
            &[],
            &[],
            std::slice::from_ref(&dispatch),
            None,
        )
        .unwrap_err();
    assert!(error.contains("simulated organization admission failure"));
    let still_running = store.invocation(&run.invocation_id).unwrap().unwrap();
    assert_eq!(still_running.status, "running");
    assert!(still_running.output.is_none());
    assert!(
        store
            .worker_dispatches_for_source(&run.invocation_id)
            .unwrap()
            .is_empty()
    );

    store
        .connection()
        .unwrap()
        .execute_batch("DROP TRIGGER fail_session_organization_dispatch;")
        .unwrap();
    let completed = store
        .complete_invocation_with_effects(
            &run.invocation_id,
            &source.worker.worker_id,
            &json!({"title":"Organized Session"}),
            &[],
            &[],
            &[dispatch],
            None,
        )
        .unwrap();
    assert_eq!(completed.status, "completed");
    assert_eq!(
        store
            .worker_dispatches_for_source(&run.invocation_id)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn run_events_and_causal_tree_are_durable_ordered_server_truth() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let worker_id = published.worker.worker_id;
    let worker_version = published.version;

    let (parent, _) = store
        .begin_invocation_with_context(
            &worker_id,
            &worker_version,
            &json!({"topic":"durability"}),
            "parent-key",
            "trace-graph",
            0,
            "manual",
            Some("session-origin"),
            WorkerInteractionMode::Background,
            Some("model-tool-parent"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(store.claim_running(&parent.invocation_id).unwrap());
    let (child, _) = store
        .begin_invocation_with_context(
            &worker_id,
            &worker_version,
            &json!({"topic":"child"}),
            "child-key",
            "trace-graph",
            1,
            "manual",
            None,
            WorkerInteractionMode::Foreground,
            Some("model-tool-child"),
            Some(&parent.invocation_id),
            Some(0),
            None,
            None,
        )
        .unwrap();
    assert!(store.claim_running(&child.invocation_id).unwrap());
    let _ = store
        .complete_invocation(&child.invocation_id, &worker_id, Ok(&json!({"ok":true})))
        .unwrap();
    store
        .record_run_stage(
            &parent.invocation_id,
            WorkerRunStage::Validation,
            "Validating parent output",
        )
        .unwrap();
    let _ = store
        .complete_invocation(&parent.invocation_id, &worker_id, Ok(&json!({"ok":true})))
        .unwrap();

    assert_eq!(
        store.invocation_tree_root(&child.invocation_id).unwrap(),
        parent.invocation_id
    );
    let tree = store.invocation_tree(&parent.invocation_id, 10).unwrap();
    assert_eq!(
        tree.iter()
            .map(|record| record.invocation_id.as_str())
            .collect::<Vec<_>>(),
        vec![parent.invocation_id.as_str(), child.invocation_id.as_str()]
    );
    let events = store
        .run_events(
            &tree
                .iter()
                .map(|record| record.invocation_id.clone())
                .collect::<Vec<_>>(),
        )
        .unwrap();
    assert!(events.iter().any(|event| {
        event.invocation_id == parent.invocation_id && event.stage == WorkerRunStage::Detached
    }));
    assert!(events.iter().any(|event| {
        event.invocation_id == parent.invocation_id && event.stage == WorkerRunStage::Validation
    }));
    assert_eq!(
        events
            .iter()
            .filter(|event| event.invocation_id == child.invocation_id)
            .next_back()
            .unwrap()
            .stage,
        WorkerRunStage::Completed
    );
    let operational_export = store.purge_operational_export(&worker_id).unwrap();
    assert!(
        operational_export["runEvents"][parent.invocation_id.as_str()]
            .as_array()
            .is_some_and(|events| !events.is_empty())
    );
    let exact = store
        .runs_filtered_page_exact(None, None, None, None, Some("model-tool-child"), 10, 0)
        .unwrap();
    assert_eq!(exact.len(), 1);
    assert_eq!(exact[0].invocation_id, child.invocation_id);

    let (second_root, _) = store
        .begin_invocation_with_context(
            &worker_id,
            &worker_version,
            &json!({"topic":"second root"}),
            "second-root-key",
            "trace-graph-two",
            0,
            "manual",
            Some("session-origin"),
            WorkerInteractionMode::Background,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let roots = store
        .run_roots_filtered_page(None, None, Some("session-origin"), 10, 0)
        .unwrap();
    assert_eq!(
        roots
            .iter()
            .map(|record| record.invocation_id.as_str())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from([
            parent.invocation_id.as_str(),
            second_root.invocation_id.as_str()
        ])
    );
}

#[test]
fn run_history_retains_output_when_an_immutable_worker_version_was_purged() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (invocation, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"retained history"}),
            "retained-history-key",
            "trace-retained-history",
            0,
            "manual",
            Some("session-retained-history"),
        )
        .unwrap();
    assert!(store.claim_running(&invocation.invocation_id).unwrap());
    store
        .complete_invocation(
            &invocation.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"ok":true})),
        )
        .unwrap();

    store
        .connection()
        .unwrap()
        .execute(
            "UPDATE worker_invocations
             SET worker_version='purged-version'
             WHERE invocation_id=?1",
            [&invocation.invocation_id],
        )
        .unwrap();

    let roots = store
        .run_roots_filtered_page(None, None, Some("session-retained-history"), 10, 0)
        .unwrap();
    assert_eq!(roots.len(), 1);
    assert_eq!(roots[0].output, Some(json!({"ok":true})));
}

#[test]
fn restart_records_interruption_and_retry_without_replacing_the_invocation() {
    let temp = tempfile::tempdir().unwrap();
    let invocation_id = {
        let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
        let mut prepared = store.prepare(bundle(), None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let published = store.publish(prepared).unwrap();
        let (invocation, _) = store
            .begin_invocation(
                &published.worker.worker_id,
                &published.version,
                &json!({"topic":"restart"}),
                "restart-key",
                "trace-restart",
                0,
                "manual",
                Some("session-restart"),
            )
            .unwrap();
        assert!(store.claim_running(&invocation.invocation_id).unwrap());
        invocation.invocation_id
    };

    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let recovered = reopened.invocation(&invocation_id).unwrap().unwrap();
    assert_eq!(recovered.status, "queued");
    assert_eq!(recovered.attempt_count, 1);
    assert!(reopened.claim_running(&invocation_id).unwrap());
    let retrying = reopened.invocation(&invocation_id).unwrap().unwrap();
    assert_eq!(retrying.attempt_count, 2);
    let stages = reopened
        .run_events(std::slice::from_ref(&invocation_id))
        .unwrap()
        .into_iter()
        .map(|event| event.stage)
        .collect::<Vec<_>>();
    assert!(stages.contains(&WorkerRunStage::Interrupted));
    assert_eq!(stages.last(), Some(&WorkerRunStage::RetryRepair));
}

#[test]
fn index_reconstruction_recovers_canonical_bundle_and_interrupted_queue() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let outcome = store.publish(prepared).unwrap();
    let (queued, _) = store
        .begin_invocation(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({"topic":"recovery"}),
            "recovery-key",
            "trace-recovery",
            0,
            "schedule",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&queued.invocation_id).unwrap());
    store
        .set_agent_session_id(&queued.invocation_id, "sess_interrupted")
        .unwrap();
    store
        .connection()
        .unwrap()
        .execute("DELETE FROM worker_triggers", [])
        .unwrap();
    store
        .connection()
        .unwrap()
        .execute("DELETE FROM worker_versions", [])
        .unwrap();
    store
        .connection()
        .unwrap()
        .execute("DELETE FROM workers", [])
        .unwrap();
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    assert!(reopened.load_active("recent-research").is_ok());
    let rebuilt = reopened.inspect("recent-research").unwrap();
    assert_eq!(rebuilt["triggers"][0]["kind"], "webhook");
    assert_eq!(rebuilt["triggers"][0]["tokenConfigured"], false);
    assert_eq!(rebuilt["triggers"][0]["enabled"], false);
    reopened.set_enabled("recent-research", false).unwrap();
    reopened.set_enabled("recent-research", true).unwrap();
    assert_eq!(
        reopened.inspect("recent-research").unwrap()["triggers"][0]["enabled"],
        false,
        "engine enablement must not revive a rebuilt webhook without a token"
    );
    assert_eq!(
        reopened
            .invocation(&queued.invocation_id)
            .unwrap()
            .unwrap()
            .status,
        "queued"
    );
    assert_eq!(
        reopened
            .invocation(&queued.invocation_id)
            .unwrap()
            .unwrap()
            .agent_session_id,
        None,
        "a redelivered agent attempt must not inherit its interrupted child session"
    );
    let recovered_attempts = reopened.attempts(&queued.invocation_id).unwrap();
    assert_eq!(recovered_attempts.len(), 1);
    assert_eq!(recovered_attempts[0]["status"], "interrupted");
    assert!(reopened.claim_running(&queued.invocation_id).unwrap());
    reopened
        .set_agent_session_id(&queued.invocation_id, "sess_recovered")
        .unwrap();
    assert_eq!(
        reopened
            .invocation(&queued.invocation_id)
            .unwrap()
            .unwrap()
            .agent_session_id
            .as_deref(),
        Some("sess_recovered")
    );
    let completed = reopened
        .complete_invocation(
            &queued.invocation_id,
            &outcome.worker.worker_id,
            Ok(&json!({"recovered":true})),
        )
        .unwrap();
    assert_eq!(completed.attempt_count, 2);
    let attempts = reopened.attempts(&queued.invocation_id).unwrap();
    assert_eq!(attempts.len(), 2);
    assert_eq!(attempts[1]["status"], "completed");
    let trace = reopened.trace("trace-recovery").unwrap().unwrap();
    assert_eq!(trace["invocationCount"], 1);
    assert_eq!(trace["maxCausalDepth"], 0);
    assert_eq!(
        reopened.inspect("recent-research").unwrap()["versions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn background_invocation_identity_survives_interrupted_delivery_recovery() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let outcome = store.publish(prepared).unwrap();
    let (queued, replayed) = store
        .begin_invocation_with_context(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({"topic":"durable background"}),
            "background-recovery-key",
            "trace-background-recovery",
            0,
            "manual",
            Some("session-background-recovery"),
            WorkerInteractionMode::Background,
            Some("provider-background-recovery"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(!replayed);
    assert!(store.claim_running(&queued.invocation_id).unwrap());
    let detached_at = queued.detached_at.clone();
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let recovered = reopened.invocation(&queued.invocation_id).unwrap().unwrap();
    assert_eq!(recovered.invocation_id, queued.invocation_id);
    assert_eq!(recovered.status, "queued");
    assert_eq!(
        recovered.interaction_mode,
        WorkerInteractionMode::Background
    );
    assert_eq!(recovered.detached_at, detached_at);
    assert_eq!(
        recovered.model_tool_invocation_id.as_deref(),
        Some("provider-background-recovery")
    );
    assert_eq!(recovered.retry_of_invocation_id, None);
    assert_eq!(recovered.attempt_count, 1);
}

#[test]
fn completed_schedule_and_reminder_outcomes_remain_history_without_attention() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();

    for (worker_id, trigger_kind) in [
        ("automation-schedules", "schedule"),
        ("automation-reminders", "worker_dispatch"),
    ] {
        let mut candidate = bundle();
        candidate.worker_id = Some(worker_id.to_owned());
        candidate.name = worker_id.replace('-', " ");
        let mut prepared = store.prepare(candidate, None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let outcome = store.publish(prepared).unwrap();
        let (run, _) = store
            .begin_invocation(
                &outcome.worker.worker_id,
                &outcome.version,
                &json!({"action":"reconcile"}),
                &format!("{worker_id}-completed"),
                &format!("trace-{worker_id}-completed"),
                0,
                trigger_kind,
                None,
            )
            .unwrap();
        assert!(store.claim_running(&run.invocation_id).unwrap());
        store
            .complete_invocation(
                &run.invocation_id,
                &outcome.worker.worker_id,
                Ok(&json!({"status":"completed"})),
            )
            .unwrap();
    }

    let history = store.inbox_filtered(None, None, None, 10).unwrap();
    assert_eq!(history.len(), 2);
    assert!(history.iter().all(|item| {
        item["severity"] == "info"
            && item["requiresAttention"] == false
            && item["contextAttached"] == false
    }));
    assert!(
        store
            .inbox_filtered_page(None, None, None, true, 10, 0)
            .unwrap()
            .is_empty(),
        "successful scheduler and reminder history is not a current operator problem"
    );
}

#[test]
fn optional_fallback_hook_timeouts_are_history_while_other_hook_failures_need_attention() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();

    for (worker_id, trigger_kind, error) in [
        (
            "worker-relevance-timeout",
            "engine_hook:worker_relevance",
            "worker invocation exceeded 3 seconds",
        ),
        (
            "inbox-context-timeout",
            "engine_hook:inbox_context",
            "worker invocation exceeded 3 seconds",
        ),
        (
            "worker-relevance-invalid",
            "engine_hook:worker_relevance",
            "worker output does not match its schema",
        ),
        (
            "context-summary-timeout",
            "engine_hook:context_summary",
            "worker invocation exceeded 3 seconds",
        ),
    ] {
        let mut candidate = bundle();
        candidate.worker_id = Some(worker_id.to_owned());
        candidate.name = worker_id.replace('-', " ");
        candidate.execution_limits.max_invocation_seconds = Some(3);
        let mut prepared = store.prepare(candidate, None).unwrap();
        store.finalize(&mut prepared).unwrap();
        let outcome = store.publish(prepared).unwrap();
        let (run, _) = store
            .begin_invocation(
                &outcome.worker.worker_id,
                &outcome.version,
                &json!({}),
                &format!("{worker_id}-failure"),
                &format!("trace-{worker_id}-failure"),
                0,
                trigger_kind,
                None,
            )
            .unwrap();
        assert!(store.claim_running(&run.invocation_id).unwrap());
        store
            .complete_invocation(&run.invocation_id, &outcome.worker.worker_id, Err(error))
            .unwrap();
    }

    let history = store.inbox_filtered(None, None, Some("error"), 10).unwrap();
    assert_eq!(history.len(), 4);
    for worker_id in ["worker-relevance-timeout", "inbox-context-timeout"] {
        let timeout = history
            .iter()
            .find(|item| item["workerId"] == worker_id)
            .unwrap();
        assert_eq!(timeout["requiresAttention"], false);
    }
    let pending = store.pending_inbox_context_candidates(10).unwrap();
    assert_eq!(pending.len(), 2);
    assert!(pending.iter().all(|item| {
        item["workerId"] != "worker-relevance-timeout"
            && item["workerId"] != "inbox-context-timeout"
    }));
    let relevance_timeout_id = history
        .iter()
        .find(|item| item["workerId"] == "worker-relevance-timeout")
        .unwrap()["inboxId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        store
            .attach_pending_inbox_context(&[relevance_timeout_id])
            .unwrap()
            .is_empty(),
        "an expected fallback timeout cannot be injected into later agent context"
    );
    let invalid_output_id = history
        .iter()
        .find(|item| item["workerId"] == "worker-relevance-invalid")
        .unwrap()["inboxId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        store
            .attach_pending_inbox_context(&[invalid_output_id])
            .unwrap()
            .len(),
        1,
        "invalid typed output remains actionable context"
    );
    let notable = store.take_notable_pending(None, 10).unwrap();
    assert_eq!(notable.len(), 1);
    assert_eq!(notable[0]["workerId"], "context-summary-timeout");
    let attention = store
        .inbox_filtered_page(None, None, None, true, 10, 0)
        .unwrap();
    assert_eq!(attention.len(), 2);
    assert!(attention.iter().any(|item| {
        item["workerId"] == "worker-relevance-invalid"
            && item["result"]["error"] == "worker output does not match its schema"
    }));
    assert!(attention.iter().any(|item| {
        item["workerId"] == "context-summary-timeout"
            && item["result"]["error"] == "worker invocation exceeded 3 seconds"
    }));
}

#[test]
fn verified_recovery_resolves_invocation_errors_without_erasing_history() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let initial = store.publish(prepared).unwrap();

    let (failed, _) = store
        .begin_invocation(
            &initial.worker.worker_id,
            &initial.version,
            &json!({}),
            "failed-before-update",
            "trace-failed-before-update",
            0,
            "manual",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&failed.invocation_id).unwrap());
    store
        .mark_failed(
            &initial.worker.worker_id,
            "execution",
            "invalid typed output",
        )
        .unwrap();
    store
        .complete_invocation(
            &failed.invocation_id,
            &initial.worker.worker_id,
            Err("invalid typed output"),
        )
        .unwrap();

    let attention = store
        .inbox_filtered_page(Some(&initial.worker.worker_id), None, None, true, 10, 0)
        .unwrap();
    assert_eq!(attention.len(), 1);
    assert_eq!(attention[0]["requiresAttention"], true);
    assert_eq!(store.pending_inbox_context_candidates(10).unwrap().len(), 1);

    store.set_enabled(&initial.worker.worker_id, true).unwrap();
    assert_eq!(
        store
            .inbox_filtered_page(Some(&initial.worker.worker_id), None, None, true, 10, 0,)
            .unwrap()
            .len(),
        1,
        "an unverified enable toggle cannot resolve a worker failure"
    );

    let mut updated = bundle();
    updated.description = "Research a topic across recent verified sources".to_owned();
    let mut prepared = store
        .prepare(updated, Some(&initial.worker.worker_id))
        .unwrap();
    store.finalize(&mut prepared).unwrap();
    let activated = store.publish(prepared).unwrap();
    assert_ne!(activated.version, initial.version);
    assert!(
        store
            .inbox_filtered_page(Some(&initial.worker.worker_id), None, None, true, 10, 0,)
            .unwrap()
            .is_empty()
    );
    assert!(
        store
            .pending_inbox_context_candidates(10)
            .unwrap()
            .is_empty()
    );
    assert!(
        store
            .take_notable_pending(Some("recent research"), 10)
            .unwrap()
            .is_empty()
    );
    let retained = store
        .inbox_filtered(Some(&initial.worker.worker_id), None, None, 10)
        .unwrap();
    assert_eq!(retained.len(), 1);
    assert_eq!(retained[0]["severity"], "error");
    assert_eq!(retained[0]["requiresAttention"], false);
    assert_eq!(
        store
            .invocation(&failed.invocation_id)
            .unwrap()
            .unwrap()
            .status,
        "failed"
    );

    let (failed_after_update, _) = store
        .begin_invocation(
            &activated.worker.worker_id,
            &activated.version,
            &json!({}),
            "failed-before-rollback",
            "trace-failed-before-rollback",
            0,
            "manual",
            None,
        )
        .unwrap();
    assert!(
        store
            .claim_running(&failed_after_update.invocation_id)
            .unwrap()
    );
    store
        .mark_failed(
            &activated.worker.worker_id,
            "execution",
            "regressed typed output",
        )
        .unwrap();
    store
        .complete_invocation(
            &failed_after_update.invocation_id,
            &activated.worker.worker_id,
            Err("regressed typed output"),
        )
        .unwrap();
    assert_eq!(
        store
            .inbox_filtered_page(Some(&activated.worker.worker_id), None, None, true, 10, 0,)
            .unwrap()
            .len(),
        1
    );

    store
        .rollback(&activated.worker.worker_id, &initial.version)
        .unwrap();
    assert!(
        store
            .inbox_filtered_page(Some(&activated.worker.worker_id), None, None, true, 10, 0,)
            .unwrap()
            .is_empty()
    );
    let retained = store
        .inbox_filtered(Some(&activated.worker.worker_id), None, None, 10)
        .unwrap();
    assert_eq!(retained.len(), 2);
    assert!(
        retained
            .iter()
            .all(|item| item["requiresAttention"] == false)
    );
}

#[test]
fn inbox_context_candidates_are_bounded_previews_and_claim_atomically() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let outcome = store.publish(prepared).unwrap();
    let (foreground, _) = store
        .begin_invocation(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({}),
            "foreground-context-candidate",
            "trace-foreground-context-candidate",
            0,
            "manual",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&foreground.invocation_id).unwrap());
    store
        .complete_invocation(
            &foreground.invocation_id,
            &outcome.worker.worker_id,
            Ok(&json!({"report":"x".repeat(8_000)})),
        )
        .unwrap();
    assert!(
        store
            .pending_inbox_context_candidates(64)
            .unwrap()
            .is_empty(),
        "a successful foreground manual result already reached its caller"
    );

    let (run, _) = store
        .begin_invocation(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({}),
            "scheduled-context-candidate",
            "trace-scheduled-context-candidate",
            0,
            "schedule",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .complete_invocation(
            &run.invocation_id,
            &outcome.worker.worker_id,
            Ok(&json!({"report":"x".repeat(8_000)})),
        )
        .unwrap();

    let candidates = store.pending_inbox_context_candidates(64).unwrap();
    assert_eq!(candidates.len(), 1);
    assert!(candidates[0]["resultPreview"].as_str().unwrap().len() <= 4_096);
    let inbox_id = candidates[0]["inboxId"].as_str().unwrap().to_owned();
    assert!(
        store
            .attach_pending_inbox_context(&[inbox_id.clone(), "missing".to_owned()])
            .unwrap()
            .is_empty()
    );
    assert_eq!(store.pending_inbox_context_candidates(64).unwrap().len(), 1);
    assert_eq!(
        store
            .attach_pending_inbox_context(std::slice::from_ref(&inbox_id))
            .unwrap()
            .len(),
        1
    );
    assert!(
        store
            .pending_inbox_context_candidates(64)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn invocation_trace_preserves_and_filters_by_its_originating_session() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let outcome = store.publish(prepared).unwrap();

    let (root, _) = store
        .begin_invocation(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({"step":"root"}),
            "origin-root",
            "trace-origin-session",
            0,
            "manual",
            Some("sess_parent"),
        )
        .unwrap();
    let (descendant, _) = store
        .begin_invocation(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({"step":"descendant"}),
            "origin-descendant",
            "trace-origin-session",
            1,
            "manual",
            Some("sess_child"),
        )
        .unwrap();
    let (unrelated, _) = store
        .begin_invocation(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({"step":"unrelated"}),
            "origin-unrelated",
            "trace-unrelated-session",
            0,
            "manual",
            Some("sess_other"),
        )
        .unwrap();

    assert_eq!(root.origin_session_id.as_deref(), Some("sess_parent"));
    assert_eq!(descendant.origin_session_id.as_deref(), Some("sess_parent"));
    assert_eq!(unrelated.origin_session_id.as_deref(), Some("sess_other"));

    let session_runs = store
        .runs_filtered_page(None, None, Some("sess_parent"), 20, 0)
        .unwrap();
    assert_eq!(session_runs.len(), 2);
    assert!(
        session_runs
            .iter()
            .all(|run| run.origin_session_id.as_deref() == Some("sess_parent"))
    );
}

#[test]
fn session_organization_outbox_is_atomic_due_bounded_and_recovers_stale_claims() {
    use crate::domains::worker_kernel::session_organization::{
        PreparedSessionOrganizationIntent, SessionOrganizationArchiveAction,
        SessionOrganizationMutation,
    };

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.worker_id = Some("session-organizer".to_owned());
    candidate.name = "Session Organizer".to_owned();
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (run, replayed) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"action":"organize"}),
            "organizer-outbox",
            "trace-organizer-outbox",
            0,
            "manual",
            Some("sess-organized"),
        )
        .unwrap();
    assert!(!replayed);
    assert!(store.claim_running(&run.invocation_id).unwrap());
    assert_eq!(
        store
            .session_organization_intent_state(&run.invocation_id)
            .unwrap(),
        None
    );
    let intent = PreparedSessionOrganizationIntent {
        mutations: vec![SessionOrganizationMutation {
            session_id: "sess-organized".to_owned(),
            labels: Some(vec!["Work".to_owned()]),
            group: Some(Some("Projects".to_owned())),
            archive_action: SessionOrganizationArchiveAction::Preserve,
        }],
    };
    store
        .complete_invocation_with_effects_and_session_organization(
            &run.invocation_id,
            &published.worker.worker_id,
            &json!({"status":"accepted"}),
            &[],
            &[],
            &[],
            None,
            Some(&intent),
        )
        .unwrap();
    assert_eq!(
        store
            .session_organization_intent_state(&run.invocation_id)
            .unwrap()
            .as_deref(),
        Some("queued")
    );

    let dispatch = store
        .pending_session_organization_intents(8)
        .unwrap()
        .remove(0);
    assert!(
        store
            .claim_session_organization_intent(&dispatch.intent_id)
            .unwrap()
    );
    assert_eq!(
        store
            .release_session_organization_intent(
                &dispatch.intent_id,
                "temporarily unavailable",
                false,
            )
            .unwrap(),
        1
    );
    assert!(
        store
            .pending_session_organization_intents(8)
            .unwrap()
            .is_empty(),
        "bounded retry backoff must keep a released claim from hot-looping"
    );

    let connection = store.connection().unwrap();
    connection
        .execute(
            "UPDATE worker_session_organization_intents
             SET state='applying',attempt_count=3,
                 updated_at='2000-01-01T00:00:00Z',
                 next_attempt_at='2000-01-01T00:00:00Z'
             WHERE intent_id=?1",
            [&dispatch.intent_id],
        )
        .unwrap();
    drop(connection);
    store.recover_stale_session_organization_intents().unwrap();
    assert_eq!(
        store.pending_session_organization_intents(8).unwrap().len(),
        1,
        "a stale in-process claim must return to the same durable dispatcher"
    );
    let connection = store.connection().unwrap();
    let attention: u32 = connection
        .query_row(
            "SELECT COUNT(*) FROM worker_inbox
             WHERE worker_id='session-organizer'
               AND result_json LIKE '%session_organization%'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(attention, 1);
    assert_eq!(
        connection
            .query_row("SELECT MAX(version) FROM worker_schema", [], |row| {
                row.get::<_, u32>(0)
            })
            .unwrap(),
        15
    );
    connection
        .execute(
            "UPDATE worker_session_organization_intents
             SET state='applying',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
             WHERE intent_id=?1",
            [&dispatch.intent_id],
        )
        .unwrap();
    drop(connection);
    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    assert_eq!(
        reopened
            .session_organization_intent_state(&run.invocation_id)
            .unwrap()
            .as_deref(),
        Some("queued"),
        "startup must recover an interrupted canonical apply claim"
    );
}
