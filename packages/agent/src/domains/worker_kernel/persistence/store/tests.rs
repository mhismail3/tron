use super::*;
use crate::domains::worker_kernel::types::{WorkerPresentation, WorkerRunner, WorkerTrigger};

fn bundle() -> WorkerBundle {
    WorkerBundle {
        schema_version: BUNDLE_SCHEMA.to_owned(),
        worker_id: None,
        name: "Recent Research".to_owned(),
        description: "Research a topic across recent sources".to_owned(),
        tool_name: None,
        model_exposure: Default::default(),
        tool_input_schema: Some(json!({
            "type":"object",
            "properties":{"topic":{"type":"string"}}
        })),
        agent_tools: None,
        input_schema: json!({"type":"object","properties":{"topic":{"type":"string"}}}),
        output_schema: json!({"type":"object"}),
        runner: WorkerRunner::Command {
            command: vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()],
        },
        files: Default::default(),
        dependencies: Vec::new(),
        triggers: vec![WorkerTrigger::Webhook {
            id: "research".to_owned(),
            input: json!({}),
        }],
        secret_bindings: Vec::new(),
        smoke_tests: Vec::new(),
        health_checks: Vec::new(),
        provenance: vec![super::super::super::types::SourceProvenance {
            source: "test:worker-store".to_owned(),
            revision: Some("1".to_owned()),
            checksum: None,
        }],
        engine_hooks: Vec::new(),
        client_actions: Vec::new(),
        client_deliveries: Vec::new(),
        worker_dispatch_routes: Vec::new(),
        routing: Default::default(),
        execution_limits: Default::default(),
        presentation: None,
    }
}

#[test]
fn prepare_and_publish_is_atomic_and_versioned() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.files.insert(
        "content.sha256".to_owned(),
        "worker-owned content".to_owned(),
    );
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let version = prepared.version.clone();
    let outcome = store.publish(prepared).unwrap();

    assert!(outcome.created);
    assert_eq!(outcome.worker.active_version, version);
    assert_eq!(outcome.webhooks.len(), 1);
    assert!(store.load_active("recent-research").is_ok());
    let inspection = store.inspect("recent-research").unwrap();
    assert_eq!(inspection["route"]["workerVersion"], version);
    assert_eq!(inspection["route"]["enabled"], true);
    assert_eq!(inspection["healthHistory"][0]["status"], "healthy");
}

#[test]
fn candidate_rejects_a_non_object_direct_tool_schema() {
    let mut candidate = bundle();
    candidate.tool_input_schema = Some(json!({"type":"string"}));
    assert_eq!(
        validate_bundle(&candidate).unwrap_err(),
        "toolInputSchema must be a JSON object schema"
    );
}

#[test]
fn direct_worker_requires_an_outcome_oriented_tool_schema() {
    let mut candidate = bundle();
    candidate.tool_input_schema = None;
    assert_eq!(
        validate_bundle(&candidate).unwrap_err(),
        "modelExposure direct requires toolInputSchema"
    );
}

#[test]
fn internal_worker_rejects_unused_direct_tool_schema() {
    let mut candidate = bundle();
    candidate.model_exposure = crate::domains::worker_kernel::types::WorkerModelExposure::Internal;
    candidate.tool_input_schema = Some(json!({"type":"object"}));
    assert_eq!(
        validate_bundle(&candidate).unwrap_err(),
        "toolInputSchema is only valid when modelExposure is direct"
    );
}

#[test]
fn agent_tool_allowlist_is_agent_only_unique_and_bounded() {
    let mut command = bundle();
    command.agent_tools = Some(vec!["web_fetch".to_owned()]);
    assert_eq!(
        validate_bundle(&command).unwrap_err(),
        "agentTools is only valid for agent runners"
    );

    let mut agent = bundle();
    agent.runner = WorkerRunner::Agent {
        instructions: "Return an object.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    agent.agent_tools = Some(vec!["web_fetch".to_owned(), "web_fetch".to_owned()]);
    assert_eq!(
        validate_bundle(&agent).unwrap_err(),
        "duplicate agentTools entry 'web_fetch'"
    );

    agent.agent_tools = Some(
        (0..33)
            .map(|index| format!("worker_tool_{index}"))
            .collect(),
    );
    assert_eq!(
        validate_bundle(&agent).unwrap_err(),
        "agentTools must contain at most 32 model tool names"
    );

    agent.agent_tools = Some(vec!["tool/name".to_owned()]);
    assert_eq!(
        validate_bundle(&agent).unwrap_err(),
        "agentTools entry must contain only ASCII letters, numbers, '-' or '_'"
    );

    agent.agent_tools = Some(vec!["a".repeat(65)]);
    assert_eq!(
        validate_bundle(&agent).unwrap_err(),
        "agentTools entries must be at most 64 UTF-8 bytes"
    );
}

#[test]
fn artifact_delivery_requires_the_reserved_output_property() {
    let mut candidate = bundle();
    candidate.client_deliveries = vec![WorkerClientDelivery::ArtifactDelivery];
    assert_eq!(
        validate_bundle(&candidate).unwrap_err(),
        "outputSchema must explicitly declare the reserved artifactDeliveries property when clientDeliveries contains artifact_delivery"
    );
}

#[test]
fn notification_policy_can_publish_title_body_without_internal_protocol_fields() {
    let mut candidate = bundle();
    candidate.worker_id = Some("notification-policy".to_owned());
    candidate.name = "Notification Policy".to_owned();
    candidate.tool_input_schema = Some(json!({
        "type":"object",
        "additionalProperties":false,
        "required":["title","body"],
        "properties":{
            "title":{"type":"string","minLength":1,"maxLength":120},
            "body":{"type":"string","minLength":1,"maxLength":512}
        }
    }));
    candidate.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "oneOf":[
            {
                "not":{"required":["action"]},
                "required":["title","body"]
            },
            {
                "properties":{"action":{"const":"deliver"}},
                "required":["action","sourceRecordId","title","body"]
            }
        ],
        "properties":{
            "action":{"const":"deliver"},
            "sourceRecordId":{"type":"string"},
            "title":{"type":"string"},
            "body":{"type":"string"}
        }
    });

    validate_bundle(&candidate).unwrap();
    assert!(
        candidate
            .effective_tool_input_schema()
            .pointer("/properties/action")
            .is_none()
    );
    assert!(
        candidate
            .input_schema
            .pointer("/properties/action")
            .is_some()
    );
}

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
fn schema_v13_or_later_retains_only_delayed_invocation_custody() {
    let directory = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(directory.path().to_path_buf()).unwrap();
    let connection = store.connection().unwrap();
    let version: u32 = connection
        .query_row("SELECT MAX(version) FROM worker_schema", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert!(version >= 13);
    let columns = connection
        .prepare("PRAGMA table_info(worker_invocations)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    assert!(columns.contains(&"not_before".to_owned()));
    assert!(columns.contains(&"wake_source_invocation_id".to_owned()));
    let extra_tables: u32 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_schema
             WHERE type='table' AND name LIKE '%wakeup%'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        extra_tables, 0,
        "self-wakeup must reuse the invocation ledger"
    );
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
fn dispatched_notification_binds_responses_to_the_declared_source_owner() {
    use crate::domains::worker_kernel::notifications::{
        NotificationIntent, NotificationResponseAction,
    };
    use crate::domains::worker_kernel::types::WorkerDispatchResponseOwner;

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();

    let mut policy = bundle();
    policy.worker_id = Some("notification-policy".to_owned());
    policy.name = "Notification Policy".to_owned();
    let mut prepared = store.prepare(policy, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let policy = store.publish(prepared).unwrap();

    let mut reminder = bundle();
    reminder.worker_id = Some("automation-reminders".to_owned());
    reminder.name = "Automation Reminders".to_owned();
    let mut prepared = store.prepare(reminder, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let reminder = store.publish(prepared).unwrap();

    let (source, _) = store
        .begin_invocation(
            &reminder.worker.worker_id,
            &reminder.version,
            &json!({"action":"reconcile"}),
            "reminder-policy-source",
            "trace-reminder-policy",
            0,
            "schedule",
            Some("session-reminder-policy"),
        )
        .unwrap();
    assert!(store.claim_running(&source.invocation_id).unwrap());
    store
        .complete_invocation_with_effects(
            &source.invocation_id,
            &reminder.worker.worker_id,
            &json!({"status":"queued"}),
            &[],
            &[],
            &[PreparedWorkerDispatch {
                route: "notification-policy".to_owned(),
                deduplication_key: "occurrence-one-attempt-one".to_owned(),
                input: json!({"action":"deliver"}),
                target_worker_id: policy.worker.worker_id.clone(),
                target_worker_version: policy.version.clone(),
                response_owner: WorkerDispatchResponseOwner::Source,
            }],
            None,
        )
        .unwrap();
    let child = store
        .worker_dispatches_for_source(&source.invocation_id)
        .unwrap()[0]["targetInvocationId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(store.claim_running(&child).unwrap());
    let intent = NotificationIntent {
        deduplication_key: "logical-occurrence-one".to_owned(),
        title: "Reminder".to_owned(),
        body: "The policy worker produced this notification.".to_owned(),
        expires_at: chrono::Utc::now() + chrono::Duration::hours(1),
        not_before: chrono::Utc::now(),
        thread_key: Some("reminders".to_owned()),
        source_record_id: Some("occurrence-one".to_owned()),
        actions: vec![
            NotificationResponseAction::Snooze,
            NotificationResponseAction::Complete,
        ],
        on_open_complete: true,
    };
    store
        .complete_invocation_with_notifications(
            &child,
            &policy.worker.worker_id,
            &json!({"status":"accepted"}),
            &[intent],
        )
        .unwrap();

    let ownership: (String, String, String, String, String) = store
        .connection()
        .unwrap()
        .query_row(
            "SELECT worker_id,source_worker_id,producer_worker_id,
                    source_invocation_id,invocation_id
             FROM notification_deliveries",
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
    assert_eq!(ownership.0, "automation-reminders");
    assert_eq!(ownership.1, "automation-reminders");
    assert_eq!(ownership.2, "notification-policy");
    assert_eq!(ownership.3, source.invocation_id);
    assert_eq!(ownership.4, child);
}

#[test]
fn schema_v12_preserves_run_evidence_and_adds_dispatch_notification_ownership() {
    let temp = tempfile::tempdir().unwrap();
    let database_dir = temp.path().join("internal/database");
    std::fs::create_dir_all(&database_dir).unwrap();
    let database = database_dir.join("workers.sqlite");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE worker_schema(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
             INSERT INTO worker_schema VALUES(5, 'now');
             CREATE TABLE worker_invocations (
                invocation_id TEXT PRIMARY KEY,
                worker_id TEXT NOT NULL,
                worker_version TEXT NOT NULL,
                status TEXT NOT NULL,
                input_json TEXT NOT NULL,
                output_json TEXT,
                error TEXT,
                idempotency_key TEXT NOT NULL,
                trace_id TEXT NOT NULL,
                causal_depth INTEGER NOT NULL,
                trigger_kind TEXT NOT NULL,
                agent_session_id TEXT,
                created_at TEXT NOT NULL,
                started_at TEXT,
                completed_at TEXT,
                UNIQUE(worker_id, idempotency_key)
             );
             CREATE TABLE worker_inbox (
                inbox_id TEXT PRIMARY KEY,
                invocation_id TEXT NOT NULL,
                worker_id TEXT NOT NULL,
                severity TEXT NOT NULL,
                result_json TEXT NOT NULL,
                seen INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
             );
             INSERT INTO worker_inbox VALUES(
                'inbox-v4','run-v4','worker-v4','info','{}',1,'2026-07-22T00:00:00Z'
             );",
        )
        .unwrap();
    drop(connection);

    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let columns = {
        let connection = store.connection().unwrap();
        let mut statement = connection
            .prepare("PRAGMA table_info(worker_inbox)")
            .unwrap();
        statement
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    };
    assert!(columns.contains(&"context_attached".to_owned()));
    assert!(!columns.contains(&"seen".to_owned()));
    let invocation_columns = store
        .connection()
        .unwrap()
        .prepare("PRAGMA table_info(worker_invocations)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    for column in [
        "origin_session_id",
        "interaction_mode",
        "detached_at",
        "model_tool_invocation_id",
        "parent_worker_invocation_id",
        "parent_worker_tool_ordinal",
        "retry_of_invocation_id",
    ] {
        assert!(invocation_columns.contains(&column.to_owned()), "{column}");
    }
    assert!(
        store
            .connection()
            .unwrap()
            .prepare("SELECT stage,summary FROM worker_run_events")
            .is_ok()
    );
    assert!(
        store
            .connection()
            .unwrap()
            .prepare("SELECT payload_hash,payload_blob_id FROM storage_payload_refs")
            .is_ok()
    );
    for table in [
        "worker_dispatches",
        "notification_installations",
        "notification_deliveries",
        "notification_delivery_targets",
        "notification_delivery_attempts",
        "notification_responses",
        "notification_refreshes",
    ] {
        assert!(
            store
                .connection()
                .unwrap()
                .prepare(&format!("SELECT * FROM {table} LIMIT 0"))
                .is_ok(),
            "{table}"
        );
    }
    let retained = store.inbox_filtered(None, Some(true), None, 10).unwrap();
    assert_eq!(retained.len(), 1);
    assert_eq!(retained[0]["contextAttached"], true);
    assert!(
        store
            .connection()
            .unwrap()
            .query_row("SELECT MAX(version) FROM worker_schema", [], |row| {
                row.get::<_, u32>(0)
            })
            .unwrap()
            >= 12
    );
    let delivery_columns = store
        .connection()
        .unwrap()
        .prepare("PRAGMA table_info(notification_deliveries)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap();
    for column in [
        "source_worker_id",
        "source_worker_version",
        "producer_worker_id",
        "producer_worker_version",
        "source_invocation_id",
        "not_before",
    ] {
        assert!(delivery_columns.contains(&column.to_owned()), "{column}");
    }
}

#[test]
fn canonical_results_keep_small_json_inline_and_deduplicate_large_blobs() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let small = json!({"answer":"concise"});
    let large = json!({"report":"repeatable evidence ".repeat(700)});
    let mut invocation_ids = Vec::new();

    for (key, output) in [
        ("small-result", &small),
        ("large-result-a", &large),
        ("large-result-b", &large),
    ] {
        let (run, replayed) = store
            .begin_invocation(
                &published.worker.worker_id,
                &published.version,
                &json!({"topic":key}),
                key,
                &format!("trace-{key}"),
                0,
                "manual",
                None,
            )
            .unwrap();
        assert!(!replayed);
        assert!(store.claim_running(&run.invocation_id).unwrap());
        store
            .complete_invocation(&run.invocation_id, &published.worker.worker_id, Ok(output))
            .unwrap();
        assert_eq!(
            store.resolve_result(&run.invocation_id).unwrap(),
            Some(output.clone())
        );
        assert_eq!(
            store.result_reference(&run.invocation_id).unwrap().unwrap()["kind"],
            "worker_result_reference"
        );
        invocation_ids.push(run.invocation_id);
    }

    let connection = store.connection().unwrap();
    let small_stored: String = connection
        .query_row(
            "SELECT output_json FROM worker_invocations WHERE invocation_id=?1",
            [&invocation_ids[0]],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(serde_json::from_str::<Value>(&small_stored).unwrap(), small);
    let large_stored: Value = connection
        .query_row(
            "SELECT output_json FROM worker_invocations WHERE invocation_id=?1",
            [&invocation_ids[1]],
            |row| {
                let stored = row.get::<_, String>(0)?;
                Ok(serde_json::from_str(&stored).unwrap())
            },
        )
        .unwrap();
    assert!(large_stored.get("__tronPayloadRef").is_some());
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM storage_payload_refs
                 WHERE owner_kind='worker_invocation' AND field_name='output'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        3
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
    let (compression, ref_count): (String, i64) = connection
        .query_row("SELECT compression,ref_count FROM blobs", [], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap();
    assert_eq!(compression, "zstd");
    assert_eq!(ref_count, 2);
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM worker_inbox
                 WHERE severity='info'
                   AND json_extract(result_json,'$.output') IS NOT NULL",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM worker_inbox
                 WHERE severity='info'
                   AND json_extract(result_json,'$.reference.kind')='worker_result_reference'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        3
    );
    connection
        .execute("UPDATE blobs SET content=x'00'", [])
        .unwrap();
    drop(connection);
    let summaries = store
        .runs_filtered(Some(&published.worker.worker_id), Some("completed"), 10)
        .unwrap();
    assert_eq!(summaries.len(), 3);
    assert!(summaries.iter().all(|record| {
        record
            .output
            .as_ref()
            .is_some_and(|output| output["kind"] == "worker_result_reference")
    }));
    let error = store.resolve_result(&invocation_ids[1]).unwrap_err();
    assert!(error.contains("storage integrity failure"), "{error}");
}

#[test]
fn provider_projection_hydrates_only_fresh_authorized_small_results() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let small = json!({"answer":"fresh"});
    let large = json!({"report":"bounded ".repeat(2_000)});
    let mut invocation_ids = Vec::new();

    for (key, model_tool_id, output) in [
        ("projection-small", "call-small", &small),
        ("projection-large", "call-large", &large),
    ] {
        let (run, _) = store
            .begin_invocation_with_context(
                &published.worker.worker_id,
                &published.version,
                &json!({"topic":key}),
                key,
                "trace-provider-projection",
                0,
                "manual",
                Some("session-provider-projection"),
                WorkerInteractionMode::Foreground,
                Some(model_tool_id),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        assert!(store.claim_running(&run.invocation_id).unwrap());
        store
            .complete_invocation(&run.invocation_id, &published.worker.worker_id, Ok(output))
            .unwrap();
        invocation_ids.push(run.invocation_id);
    }

    let model_ids = vec!["call-small".to_owned(), "call-large".to_owned()];
    let fresh = HashSet::from_iter(model_ids.iter().cloned());
    let projected = store
        .provider_result_projections(
            &model_ids,
            &[],
            &fresh,
            &HashSet::new(),
            Some("session-provider-projection"),
            None,
        )
        .unwrap();
    assert_eq!(projected.len(), 2);
    assert_eq!(projected[0]["providerValue"], small);
    assert_eq!(
        projected[1]["providerValue"]["kind"],
        "worker_result_reference"
    );
    assert_eq!(projected[1]["reference"]["invocationId"], invocation_ids[1]);

    let (replayed_small, replayed) = store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"provider regenerated valid arguments"}),
            "projection-small",
            "trace-provider-projection",
            0,
            "manual",
            Some("session-provider-projection"),
            WorkerInteractionMode::Foreground,
            Some("call-small-after-recovery"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(replayed);
    assert_eq!(replayed_small.invocation_id, invocation_ids[0]);
    let recovered_projection = store
        .provider_result_projections(
            &["call-small-after-recovery".to_owned()],
            &[],
            &HashSet::from(["call-small-after-recovery".to_owned()]),
            &HashSet::new(),
            Some("session-provider-projection"),
            None,
        )
        .unwrap();
    assert_eq!(recovered_projection.len(), 1);
    assert_eq!(recovered_projection[0]["invocationId"], invocation_ids[0]);
    assert_eq!(recovered_projection[0]["providerValue"], small);

    let historical = store
        .provider_result_projections(
            &model_ids,
            &[],
            &HashSet::new(),
            &HashSet::new(),
            Some("session-provider-projection"),
            None,
        )
        .unwrap();
    assert!(historical.iter().all(|item| {
        item["providerValue"]["kind"] == "worker_result_reference"
            && item["reference"] == item["providerValue"]
    }));
    assert!(
        store
            .provider_result_projections(
                &model_ids,
                &[],
                &fresh,
                &HashSet::new(),
                Some("another-session"),
                Some("another-trace"),
            )
            .unwrap()
            .is_empty()
    );

    store
        .connection()
        .unwrap()
        .execute(
            "UPDATE storage_payload_refs SET payload_hash='corrupt'
             WHERE owner_kind='worker_invocation' AND owner_id=?1",
            [&invocation_ids[0]],
        )
        .unwrap();
    let error = store
        .provider_result_projections(
            &["call-small".to_owned()],
            &[],
            &HashSet::from(["call-small".to_owned()]),
            &HashSet::new(),
            Some("session-provider-projection"),
            None,
        )
        .unwrap_err();
    assert!(error.contains("storage integrity failure"), "{error}");
}

#[test]
fn model_tool_result_associations_backfill_on_reopen() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (run, _) = store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"association backfill"}),
            "association-backfill",
            "trace-association-backfill",
            0,
            "manual",
            Some("session-association-backfill"),
            WorkerInteractionMode::Foreground,
            Some("call-association-backfill"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .complete_invocation(
            &run.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"answer":"durable"})),
        )
        .unwrap();
    store
        .connection()
        .unwrap()
        .execute("DROP TABLE worker_model_tool_result_associations", [])
        .unwrap();
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let projection = reopened
        .provider_result_projections(
            &["call-association-backfill".to_owned()],
            &[],
            &HashSet::new(),
            &HashSet::new(),
            Some("session-association-backfill"),
            None,
        )
        .unwrap();
    assert_eq!(projection.len(), 1);
    assert_eq!(projection[0]["invocationId"], run.invocation_id);
    assert_eq!(
        projection[0]["providerValue"]["kind"],
        "worker_result_reference"
    );
}

#[test]
fn result_completion_rolls_back_ownership_and_terminal_state_together() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"atomic"}),
            "atomic-result",
            "trace-atomic-result",
            0,
            "manual",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .connection()
        .unwrap()
        .execute_batch(
            "CREATE TRIGGER reject_completed_result
             BEFORE INSERT ON worker_inbox
             WHEN NEW.severity='info'
             BEGIN
               SELECT RAISE(ABORT, 'injected inbox failure');
             END;",
        )
        .unwrap();

    let error = store
        .complete_invocation(
            &run.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"report":"x".repeat(9_000)})),
        )
        .unwrap_err();
    assert!(error.contains("injected inbox failure"), "{error}");
    let connection = store.connection().unwrap();
    let (status, output): (String, Option<String>) = connection
        .query_row(
            "SELECT status,output_json FROM worker_invocations WHERE invocation_id=?1",
            [&run.invocation_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(status, "running");
    assert!(output.is_none());
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM storage_payload_refs
                 WHERE owner_kind='worker_invocation' AND owner_id=?1",
                [&run.invocation_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        0
    );
}

#[test]
fn schema_v10_result_migration_is_resumable_and_idempotent() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let expected = json!({"report":"migration evidence ".repeat(700)});
    let (run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"topic":"migration"}),
            "migration-result",
            "trace-migration-result",
            0,
            "manual",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .complete_invocation(
            &run.invocation_id,
            &published.worker.worker_id,
            Ok(&expected),
        )
        .unwrap();
    let legacy_output = serde_json::to_string(&expected).unwrap();
    let legacy_inbox = serde_json::to_string(&json!({
        "status":"completed",
        "output":expected,
    }))
    .unwrap();
    let mut connection = store.connection().unwrap();
    connection
        .execute("DELETE FROM worker_schema WHERE version=10", [])
        .unwrap();
    connection
        .execute(
            "UPDATE worker_invocations SET output_json=?2 WHERE invocation_id=?1",
            params![run.invocation_id, legacy_output],
        )
        .unwrap();
    connection
        .execute(
            "UPDATE worker_inbox SET result_json=?2 WHERE invocation_id=?1",
            params![run.invocation_id, legacy_inbox],
        )
        .unwrap();
    connection
        .execute("DELETE FROM storage_payload_refs", [])
        .unwrap();
    connection.execute("DELETE FROM blobs", []).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE worker_result_migration_v10 (
                invocation_id TEXT PRIMARY KEY,
                stored_output TEXT NOT NULL,
                receipt_json TEXT NOT NULL
             );",
        )
        .unwrap();
    let transaction = connection.transaction().unwrap();
    let staged_output = WorkerStore::store_result_in_transaction(
        &transaction,
        &run.invocation_id,
        &json!({"report":"migration evidence ".repeat(700)}),
        "trace-migration-result",
        None,
    )
    .unwrap();
    let staged_reference =
        super::results::result_reference_from_connection(&transaction, &run.invocation_id).unwrap();
    transaction
        .execute(
            "INSERT INTO worker_result_migration_v10(
                invocation_id,stored_output,receipt_json
             ) VALUES (?1,?2,?3)",
            params![
                run.invocation_id,
                staged_output,
                serde_json::to_string(&super::results::completed_result_receipt(&staged_reference))
                    .unwrap(),
            ],
        )
        .unwrap();
    transaction.commit().unwrap();
    drop(connection);
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    assert!(
        reopened
            .connection()
            .unwrap()
            .query_row("SELECT MAX(version) FROM worker_schema", [], |row| {
                row.get::<_, u32>(0)
            })
            .unwrap()
            >= 12
    );
    assert_eq!(
        reopened.resolve_result(&run.invocation_id).unwrap(),
        Some(json!({"report":"migration evidence ".repeat(700)}))
    );
    let connection = reopened.connection().unwrap();
    let stored: Value = connection
        .query_row(
            "SELECT output_json FROM worker_invocations WHERE invocation_id=?1",
            [&run.invocation_id],
            |row| {
                let value = row.get::<_, String>(0)?;
                Ok(serde_json::from_str(&value).unwrap())
            },
        )
        .unwrap();
    assert!(stored.get("__tronPayloadRef").is_some());
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM worker_inbox
                 WHERE invocation_id=?1
                   AND json_extract(result_json,'$.output') IS NOT NULL",
                [&run.invocation_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
    drop(connection);
    drop(reopened);

    let restarted = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    assert_eq!(
        restarted.resolve_result(&run.invocation_id).unwrap(),
        Some(json!({"report":"migration evidence ".repeat(700)}))
    );
    assert_eq!(
        restarted
            .connection()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
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
fn presentation_binding_is_immutable_indexed_and_reconstructed() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.presentation = Some(WorkerPresentation {
        experience_id: "research-suite".to_owned(),
        contract_version: 1,
        suite_id: Some("research".to_owned()),
        component_role: Some("search".to_owned()),
        primary: false,
        sections: vec![
            serde_json::from_value(json!({
                "sectionId":"summary",
                "kind":"text",
                "title":"Summary",
                "valuePointer":"/summary"
            }))
            .unwrap(),
        ],
    });
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let version = prepared.version.clone();
    let outcome = store.publish(prepared).unwrap();
    assert_eq!(
        outcome
            .worker
            .presentation
            .as_ref()
            .unwrap()
            .suite_id
            .as_deref(),
        Some("research")
    );
    assert_eq!(
        store
            .load_version("recent-research", &version)
            .unwrap()
            .bundle
            .presentation
            .as_ref()
            .unwrap()
            .component_role
            .as_deref(),
        Some("search")
    );
    assert_eq!(
        store
            .load_version("recent-research", &version)
            .unwrap()
            .bundle
            .presentation
            .as_ref()
            .unwrap()
            .sections[0]
            .value_pointer
            .as_deref(),
        Some("/summary")
    );

    store
        .connection()
        .unwrap()
        .execute("UPDATE workers SET presentation_json=NULL", [])
        .unwrap();
    super::super::rebuild::rebuild_indexes(&store.root, &store.database).unwrap();
    assert_eq!(
        store
            .summary("recent-research")
            .unwrap()
            .unwrap()
            .presentation
            .as_ref()
            .unwrap()
            .experience_id,
        "research-suite"
    );
    assert_eq!(
        store
            .summary("recent-research")
            .unwrap()
            .unwrap()
            .presentation
            .as_ref()
            .unwrap()
            .sections
            .len(),
        1
    );
}

#[test]
fn declarative_presentation_is_bounded_result_bound_and_schema_validated() {
    let mut candidate = bundle();
    candidate.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["action"],
        "properties":{"action":{"type":"string","enum":["refresh","approve"]}}
    });
    candidate.presentation = Some(
        serde_json::from_value(json!({
            "experienceId":"generic-workflow",
            "contractVersion":1,
            "sections":[
                {"sectionId":"summary","kind":"text","title":"Summary","valuePointer":"/summary"},
                {"sectionId":"state","kind":"status","valuePointer":"/status"},
                {"sectionId":"completion","kind":"progress","valuePointer":"/progress"},
                {
                    "sectionId":"records","kind":"table","title":"Records","valuePointer":"/records",
                    "columns":[
                        {"label":"Name","valuePointer":"/name"},
                        {"label":"State","valuePointer":"/status"}
                    ]
                },
                {"sectionId":"notes","kind":"list","valuePointer":"/notes"},
                {"sectionId":"source","kind":"link","label":"Open source","url":"https://example.com/source"},
                {"sectionId":"artifact","kind":"artifact","label":"Inspect report","valuePointer":"/report"},
                {
                    "sectionId":"approve","kind":"confirmation","title":"Approve result",
                    "detail":"Run the immutable approval action?",
                    "action":{"actionId":"approve","label":"Approve","input":{"action":"approve"}}
                },
                {
                    "sectionId":"refresh","kind":"worker_action",
                    "action":{"actionId":"refresh","label":"Refresh","input":{"action":"refresh"}}
                }
            ]
        }))
        .unwrap(),
    );
    validate_bundle(&candidate).expect("closed presentation is valid");

    let mut unsafe_link = candidate.clone();
    unsafe_link
        .presentation
        .as_mut()
        .unwrap()
        .sections
        .iter_mut()
        .find(|section| section.section_id == "source")
        .unwrap()
        .url = Some("javascript:alert(1)".to_owned());
    assert!(
        validate_bundle(&unsafe_link)
            .unwrap_err()
            .contains("absolute public HTTPS URL")
    );
    unsafe_link
        .presentation
        .as_mut()
        .unwrap()
        .sections
        .iter_mut()
        .find(|section| section.section_id == "source")
        .unwrap()
        .url = Some("https://127.0.0.1/private".to_owned());
    assert!(
        validate_bundle(&unsafe_link)
            .unwrap_err()
            .contains("absolute public HTTPS URL")
    );

    let mut invalid_pointer = candidate.clone();
    invalid_pointer.presentation.as_mut().unwrap().sections[0].value_pointer =
        Some("/bad~2pointer".to_owned());
    assert!(
        validate_bundle(&invalid_pointer)
            .unwrap_err()
            .contains("invalid RFC 6901 escape")
    );

    let mut invalid_action = candidate;
    invalid_action
        .presentation
        .as_mut()
        .unwrap()
        .sections
        .last_mut()
        .unwrap()
        .action
        .as_mut()
        .unwrap()
        .input = json!({"action":"delete-device"});
    assert!(
        validate_bundle(&invalid_action)
            .unwrap_err()
            .contains("does not match inputSchema")
    );
}

#[test]
fn declarative_presentation_struct_rejects_arbitrary_native_code_fields() {
    for field in ["html", "javascript", "swiftView", "clientCommand"] {
        let mut value = json!({
            "experienceId":"generic-workflow",
            "contractVersion":1,
            "sections":[
                {"sectionId":"summary","kind":"text","valuePointer":"/summary"}
            ]
        });
        value["sections"][0][field] = json!("unsafe");
        let error = serde_json::from_value::<WorkerPresentation>(value).unwrap_err();
        assert!(error.to_string().contains("unknown field"), "{error}");
    }
}

#[test]
fn purge_rejects_known_secret_material_before_removing_bundle_or_state() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let _ = store.publish(prepared).unwrap();
    let state = store.state_dir("recent-research").unwrap();
    let secret = "purge-archive-secret-value";
    std::fs::write(
        state.join("state.json"),
        format!("{{\"secret\":\"{secret}\"}}"),
    )
    .unwrap();
    let _ = store.retire("recent-research").unwrap();

    let error = store
        .purge("recent-research", &[secret.to_owned()])
        .unwrap_err();
    assert!(error.contains("credential material"), "{error}");
    assert!(
        temp.path()
            .join("workspace/workers/recent-research")
            .is_dir()
    );
    assert!(state.join("state.json").is_file());
    assert!(store.summary("recent-research").unwrap().is_some());
}

#[test]
fn prepare_normalizes_a_plain_tool_name_without_an_authoring_retry() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.tool_name = Some("last30days-research".to_owned());

    let prepared = store.prepare(candidate, None).unwrap();

    assert_eq!(
        prepared.bundle.tool_name.as_deref(),
        Some("worker_last30days_research")
    );
}

#[test]
fn failed_candidate_can_be_abandoned_without_changing_active_version() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut first = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut first).unwrap();
    let active = first.version.clone();
    let _ = store.publish(first).unwrap();
    let mut next = bundle();
    next.description.push_str(" with citations");
    let candidate = store.prepare(next, Some("recent-research")).unwrap();
    store.abandon(&candidate);

    assert_eq!(
        store
            .summary("recent-research")
            .unwrap()
            .unwrap()
            .active_version,
        active
    );
}

#[test]
fn database_publication_failure_removes_the_unpublished_version_tree() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut first = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut first).unwrap();
    let first = store.publish(first).unwrap();

    let mut colliding = bundle();
    colliding.worker_id = Some("distinct-worker".to_owned());
    colliding.name = "Distinct Formatting Utility".to_owned();
    colliding.description = "Formats archival documents into a stable layout".to_owned();
    colliding.tool_name = Some(first.worker.tool_name.clone());
    let mut prepared = store.prepare(colliding, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let unpublished_directory = store
        .root
        .join("distinct-worker")
        .join("versions")
        .join(&prepared.version);

    assert!(store.publish(prepared).is_err());
    assert!(!unpublished_directory.exists());
    assert!(!store.root.join("distinct-worker").exists());
    assert!(store.read_state("distinct-worker").unwrap().is_none());
    assert_eq!(
        store
            .summary(&first.worker.worker_id)
            .unwrap()
            .unwrap()
            .active_version,
        first.version
    );
}

#[test]
fn pointer_publication_failure_cleans_candidate_before_index_reconstruction() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut first = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut first).unwrap();
    let first = store.publish(first).unwrap();

    let mut updated = bundle();
    updated.description.push_str(" with a pointer failure test");
    let mut candidate = store
        .prepare(updated, Some(&first.worker.worker_id))
        .unwrap();
    store.finalize(&mut candidate).unwrap();
    let candidate_version = candidate.version.clone();
    let candidate_directory = store
        .root
        .join(&first.worker.worker_id)
        .join("versions")
        .join(&candidate_version);

    let error = store
        .publish_with_pointer_writer(candidate, |_path, _state| {
            Err("injected canonical pointer failure".to_owned())
        })
        .unwrap_err();

    assert!(error.contains("injected canonical pointer failure"));
    assert!(error.contains("restored indexes from filesystem state"));
    assert!(!candidate_directory.exists());
    let inspection = store.inspect(&first.worker.worker_id).unwrap();
    assert_eq!(inspection["worker"]["activeVersion"], first.version);
    assert_eq!(inspection["route"]["workerVersion"], first.version);
    assert_eq!(inspection["versions"].as_array().unwrap().len(), 1);
    assert!(
        inspection["versions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|version| version["version"] != candidate_version)
    );
}

#[test]
fn semantic_overlap_updates_existing_worker_even_when_candidate_suggests_a_new_id() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut first = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut first).unwrap();
    let first = store.publish(first).unwrap();

    let mut overlapping = bundle();
    overlapping.worker_id = Some("duplicate-recent-research".to_owned());
    let prepared = store.prepare(overlapping, None).unwrap();

    assert_eq!(prepared.worker_id, first.worker.worker_id);
    assert_eq!(
        prepared
            .prior_state
            .as_ref()
            .map(|state| state.worker_id.as_str()),
        Some(first.worker.worker_id.as_str())
    );
}

#[test]
fn crash_after_index_commit_before_pointer_keeps_prior_version_canonical() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut first = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut first).unwrap();
    let first_version = first.version.clone();
    store.publish(first).unwrap();
    let prior_state = store.read_state("recent-research").unwrap().unwrap();

    let mut updated = bundle();
    updated.description.push_str(" with crash-safe publication");
    let mut second = store.prepare(updated, Some("recent-research")).unwrap();
    store.finalize(&mut second).unwrap();
    let second_version = second.version.clone();
    store.publish(second).unwrap();
    assert_ne!(first_version, second_version);

    // Model a process death after the SQLite transaction commits but
    // before the atomic filesystem-pointer rename linearizes activation.
    write_json_atomic(
        &temp
            .path()
            .join("workspace/workers/recent-research/worker.json"),
        &prior_state,
    )
    .unwrap();
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    assert_eq!(
        reopened
            .summary("recent-research")
            .unwrap()
            .unwrap()
            .active_version,
        first_version
    );
    assert_eq!(
        reopened.inspect("recent-research").unwrap()["versions"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn traversal_in_worker_files_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut invalid = bundle();
    invalid
        .files
        .insert("../escape".to_owned(), "no".to_owned());
    assert!(store.prepare(invalid, None).is_err());
}

#[test]
fn worker_selected_execution_ceilings_are_bounded_before_publication() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut invalid_timeout = bundle();
    invalid_timeout.execution_limits.max_invocation_seconds = Some(0);
    let error = store.prepare(invalid_timeout, None).unwrap_err();
    assert!(error.contains("maxInvocationSeconds"), "{error}");

    let mut invalid_turns = bundle();
    invalid_turns.execution_limits.max_agent_turns = Some(0);
    let error = store.prepare(invalid_turns, None).unwrap_err();
    assert!(error.contains("maxAgentTurns"), "{error}");

    let mut invalid_children = bundle();
    invalid_children.execution_limits.max_child_invocations = Some(257);
    let error = store.prepare(invalid_children, None).unwrap_err();
    assert!(error.contains("maxChildInvocations"), "{error}");

    let mut bounded = bundle();
    bounded.execution_limits.max_invocation_seconds = Some(3);
    bounded.execution_limits.max_agent_turns = Some(7);
    bounded.execution_limits.max_child_invocations = Some(6);
    let mut prepared = store.prepare(bounded, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let active = store.load_active(&published.worker.worker_id).unwrap();
    assert_eq!(
        active.bundle.execution_limits.max_invocation_seconds,
        Some(3)
    );
    assert_eq!(active.bundle.execution_limits.max_agent_turns, Some(7));
    assert_eq!(
        active.bundle.execution_limits.max_child_invocations,
        Some(6)
    );
}

#[test]
fn runner_and_check_configuration_is_validated_before_staging() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut invalid_reasoning = bundle();
    invalid_reasoning.runner = WorkerRunner::Agent {
        instructions: "Return a typed result.".to_owned(),
        model: None,
        reasoning_level: Some("fastest".to_owned()),
    };
    assert!(
        store
            .prepare(invalid_reasoning, None)
            .unwrap_err()
            .contains("reasoningLevel")
    );

    let mut remote_service = bundle();
    remote_service.runner = WorkerRunner::Service {
        command: vec!["worker-service".to_owned()],
        invoke_url: "https://example.com/invoke".to_owned(),
        health_url: None,
    };
    assert!(
        store
            .prepare(remote_service, None)
            .unwrap_err()
            .contains("loopback")
    );

    let mut unbounded_check = bundle();
    unbounded_check
        .health_checks
        .push(super::super::super::types::WorkerCommand {
            command: vec!["true".to_owned()],
            timeout_seconds: 0,
        });
    assert!(
        store
            .prepare(unbounded_check, None)
            .unwrap_err()
            .contains("timeoutSeconds")
    );

    let mut invalid_schedule = bundle();
    invalid_schedule.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["topic"],
        "properties":{"topic":{"type":"string"}}
    });
    invalid_schedule.triggers = vec![WorkerTrigger::Schedule {
        id: "invalid-input".to_owned(),
        every_seconds: 60,
        input: json!({}),
    }];
    assert!(
        store
            .prepare(invalid_schedule, None)
            .unwrap_err()
            .contains("does not match inputSchema")
    );
    assert!(!temp.path().join("workspace/workers/.staging").exists());
}

#[test]
fn versions_are_immutable_rollback_restores_triggers_and_purge_leaves_audit() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut first = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut first).unwrap();
    let first_version = first.version.clone();
    let first_outcome = store.publish(first).unwrap();
    let first_token = first_outcome.webhooks[0].token.clone();

    let mut updated_bundle = bundle();
    updated_bundle.description.push_str(" with citations");
    updated_bundle.triggers = vec![WorkerTrigger::Schedule {
        id: "daily".to_owned(),
        every_seconds: 86_400,
        input: json!({"topic":"workers"}),
    }];
    let mut second = store
        .prepare(updated_bundle, Some("recent-research"))
        .unwrap();
    store.finalize(&mut second).unwrap();
    let second_version = second.version.clone();
    store.publish(second).unwrap();
    assert_ne!(first_version, second_version);

    let (rolled_back, credentials) = store.rollback("recent-research", &first_version).unwrap();
    assert_eq!(rolled_back.active_version, first_version);
    assert_eq!(credentials.len(), 1);
    assert_ne!(credentials[0].token, first_token);
    let inspection = store.inspect("recent-research").unwrap();
    assert_eq!(inspection["triggers"][0]["kind"], "webhook");
    assert_eq!(inspection["versions"].as_array().unwrap().len(), 2);
    let (run, _) = store
        .begin_invocation(
            "recent-research",
            &first_version,
            &json!({"topic":"purge archive"}),
            "purge-result",
            "trace-purge-result",
            0,
            "manual",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .complete_invocation(
            &run.invocation_id,
            "recent-research",
            Ok(&json!({"report":"archived exact result ".repeat(700)})),
        )
        .unwrap();
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );

    let retired = store.retire("recent-research").unwrap();
    assert!(retired.retired);
    let state = store.state_dir("recent-research").unwrap();
    std::fs::write(state.join("ledger.sqlite"), b"durable worker state").unwrap();
    let retired_inspection = store.inspect("recent-research").unwrap();
    assert!(
        !retired_inspection["triggers"][0]["enabled"]
            .as_bool()
            .unwrap_or(true)
    );
    let purge = store.purge("recent-research", &[]).unwrap();
    assert!(purge.purged);
    assert!(std::path::Path::new(&purge.archive_path).is_file());
    assert_eq!(purge.archive_sha256.len(), 64);
    let decoder =
        zstd::stream::read::Decoder::new(std::fs::File::open(&purge.archive_path).unwrap())
            .unwrap();
    let archived_paths = tar::Archive::new(decoder)
        .entries()
        .unwrap()
        .map(|entry| entry.unwrap().path().unwrap().into_owned())
        .collect::<Vec<_>>();
    assert!(
        archived_paths.iter().any(|path| path
            == std::path::Path::new(
                "payload/workspace/worker-state/recent-research/ledger.sqlite",
            )),
        "purge archive omitted durable worker state: {archived_paths:?}"
    );
    assert!(
        !temp
            .path()
            .join("workspace/worker-state/recent-research")
            .exists()
    );
    assert!(store.summary("recent-research").unwrap().is_none());
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0
    );
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert!(
        store
            .audit(Some("recent-research"), 20)
            .unwrap()
            .iter()
            .any(|item| item["action"] == "purged")
    );
}

#[test]
fn canonical_version_tampering_and_non_hash_paths_are_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let outcome = store.publish(prepared).unwrap();
    let version_dir = temp
        .path()
        .join("workspace/workers/recent-research/versions")
        .join(&outcome.version);
    fs::write(
        version_dir.join("files/content.sha256"),
        "tampered worker-owned content",
    )
    .unwrap();

    let error = store.load_active("recent-research").unwrap_err();
    assert!(error.contains("failed integrity verification"), "{error}");
    let traversal = store
        .rollback("recent-research", "../../worker.json")
        .unwrap_err();
    assert!(traversal.contains("content hash"), "{traversal}");
    let worker_traversal = store.load_active("../recent-research").unwrap_err();
    assert!(worker_traversal.contains("workerId"), "{worker_traversal}");
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
fn notable_inbox_claims_background_results_once_and_keeps_manual_results() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let outcome = store.publish(prepared).unwrap();
    for (key, trigger) in [("background", "schedule"), ("manual", "manual")] {
        let (run, _) = store
            .begin_invocation(
                &outcome.worker.worker_id,
                &outcome.version,
                &json!({}),
                key,
                &format!("trace-{key}"),
                0,
                trigger,
                None,
            )
            .unwrap();
        assert!(store.claim_running(&run.invocation_id).unwrap());
        store
            .complete_invocation(
                &run.invocation_id,
                &outcome.worker.worker_id,
                Ok(&json!({"ok":true})),
            )
            .unwrap();
    }
    let (detached_manual, _) = store
        .begin_invocation_with_context(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({}),
            "detached-manual",
            "trace-detached-manual",
            0,
            "manual",
            Some("session-detached-manual"),
            WorkerInteractionMode::Background,
            Some("provider-detached-manual"),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(store.claim_running(&detached_manual.invocation_id).unwrap());
    store
        .complete_invocation(
            &detached_manual.invocation_id,
            &outcome.worker.worker_id,
            Ok(&json!({"ok":true,"delivery":"detached"})),
        )
        .unwrap();
    store
        .record_system_inbox(
            &outcome.worker.worker_id,
            "resident_supervision",
            &json!({"status":"failed","phase":"resident_supervision"}),
        )
        .unwrap();
    let attention = store
        .inbox_filtered_page(Some(&outcome.worker.worker_id), None, None, true, 10, 0)
        .unwrap();
    assert_eq!(attention.len(), 1);
    assert_eq!(attention[0]["requiresAttention"], true);
    assert_eq!(attention[0]["triggerKind"], "system");
    assert_eq!(attention[0]["hasInvocation"], false);
    let history = store
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
        .unwrap();
    assert!(history.iter().any(|item| {
        item["triggerKind"] == "schedule"
            && item["severity"] == "info"
            && item["requiresAttention"] == false
    }));
    assert!(history.iter().any(|item| {
        item["invocationId"] == detached_manual.invocation_id
            && item["severity"] == "info"
            && item["requiresAttention"] == false
    }));
    let first = store
        .take_notable_pending(Some("recent research"), 10)
        .unwrap();
    assert_eq!(first.len(), 3);
    assert!(first.iter().any(|item| item["triggerKind"] == "schedule"));
    assert!(first.iter().any(|item| {
        item["triggerKind"] == "system" && item["result"]["phase"] == "resident_supervision"
    }));
    assert!(
        store
            .take_notable_pending(Some("recent research"), 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
            .unwrap()
            .iter()
            .filter(|item| item["contextAttached"] == false)
            .count(),
        1
    );
    store
        .rollback(&outcome.worker.worker_id, &outcome.version)
        .unwrap();
    assert!(
        store
            .inbox_filtered_page(Some(&outcome.worker.worker_id), None, None, true, 10, 0)
            .unwrap()
            .is_empty(),
        "verified recovery must remove the resolved system failure from Attention"
    );
    let retained = store
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
        .unwrap();
    assert_eq!(retained.len(), 4);
    assert!(retained.iter().any(|item| {
        item["result"]["phase"] == "resident_supervision" && item["requiresAttention"] == false
    }));
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
fn successful_engine_hook_results_are_audited_without_reentering_context() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let outcome = store.publish(prepared).unwrap();

    for (key, trigger, result) in [
        (
            "hook-success",
            "engine_hook:session_title",
            Ok(json!({"title":"A Durable Session Title"})),
        ),
        (
            "hook-failure",
            "engine_hook:session_title",
            Err("title policy failed"),
        ),
        (
            "scheduled-success",
            "schedule",
            Ok(json!({"status":"completed"})),
        ),
    ] {
        let (run, _) = store
            .begin_invocation(
                &outcome.worker.worker_id,
                &outcome.version,
                &json!({}),
                key,
                &format!("trace-{key}"),
                0,
                trigger,
                None,
            )
            .unwrap();
        assert!(store.claim_running(&run.invocation_id).unwrap());
        match result {
            Ok(output) => {
                store
                    .complete_invocation(&run.invocation_id, &outcome.worker.worker_id, Ok(&output))
                    .unwrap();
            }
            Err(error) => {
                store
                    .complete_invocation(&run.invocation_id, &outcome.worker.worker_id, Err(error))
                    .unwrap();
            }
        }
    }

    let inbox = store
        .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
        .unwrap();
    assert_eq!(inbox.len(), 3);
    let successful_hook = inbox
        .iter()
        .find(|item| {
            item["triggerKind"] == "engine_hook:session_title" && item["severity"] == "info"
        })
        .unwrap();
    assert_eq!(successful_hook["contextAttached"], true);
    assert_eq!(successful_hook["requiresAttention"], false);

    let failed_hook = inbox
        .iter()
        .find(|item| {
            item["triggerKind"] == "engine_hook:session_title" && item["severity"] == "error"
        })
        .unwrap();
    assert_eq!(failed_hook["contextAttached"], false);
    assert_eq!(failed_hook["requiresAttention"], true);

    let pending = store.pending_inbox_context_candidates(10).unwrap();
    assert_eq!(pending.len(), 2);
    assert!(pending.iter().any(|item| {
        item["triggerKind"] == "engine_hook:session_title" && item["severity"] == "error"
    }));
    assert!(pending.iter().any(|item| item["triggerKind"] == "schedule"));
    assert!(!pending.iter().any(|item| {
        item["triggerKind"] == "engine_hook:session_title" && item["severity"] == "info"
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
    let (run, _) = store
        .begin_invocation(
            &outcome.worker.worker_id,
            &outcome.version,
            &json!({}),
            "context-candidate",
            "trace-context-candidate",
            0,
            "manual",
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
fn notification_intents_are_atomic_deduplicated_and_fan_out_to_active_installations() {
    use crate::domains::worker_kernel::notifications::{
        NotificationAuthorizationStatus, NotificationDeviceUpsertRequest, NotificationEnvironment,
        NotificationIntent, NotificationResponseAction,
    };

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    for installation_id in ["installation-one", "installation-two"] {
        let response = store
            .notification_device_upsert(NotificationDeviceUpsertRequest {
                installation_id: installation_id.to_owned(),
                client_server_id: "paired-server".to_owned(),
                topic: "com.tron.mobile.beta".to_owned(),
                environment: NotificationEnvironment::Sandbox,
                authorization_status: NotificationAuthorizationStatus::Authorized,
                token: Some("ab".repeat(32)),
            })
            .unwrap();
        assert_eq!(response["ready"], true);
        assert!(response.to_string().find(&"ab".repeat(32)).is_none());
    }
    let intent = NotificationIntent {
        deduplication_key: "stable-occurrence".to_owned(),
        title: "Reminder".to_owned(),
        body: "Validate transactional delivery.".to_owned(),
        expires_at: chrono::Utc::now() + chrono::Duration::hours(1),
        not_before: chrono::Utc::now(),
        thread_key: Some("reminders".to_owned()),
        source_record_id: Some("occurrence-one".to_owned()),
        actions: vec![
            NotificationResponseAction::Snooze,
            NotificationResponseAction::Complete,
        ],
        on_open_complete: true,
    };

    for key in ["delivery-run-one", "delivery-run-two"] {
        let (run, replayed) = store
            .begin_invocation(
                &published.worker.worker_id,
                &published.version,
                &json!({"action":"tick"}),
                key,
                &format!("trace-{key}"),
                0,
                "schedule",
                None,
            )
            .unwrap();
        assert!(!replayed);
        assert!(store.claim_running(&run.invocation_id).unwrap());
        store
            .complete_invocation_with_notifications(
                &run.invocation_id,
                &published.worker.worker_id,
                &json!({"status":"evaluated"}),
                std::slice::from_ref(&intent),
            )
            .unwrap();
    }

    let connection = store.connection().unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM notification_deliveries", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM notification_delivery_targets",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        2
    );
    drop(connection);

    let page = store
        .notification_deliveries(
            crate::domains::worker_kernel::notifications::NotificationDeliveriesRequest {
                cursor: None,
                limit: 100,
                unread_only: false,
            },
        )
        .unwrap();
    assert_eq!(page["unreadCount"], 1);
    assert_eq!(page["deliveries"].as_array().unwrap().len(), 1);
    assert_eq!(page["deliveries"][0]["targetSummary"]["total"], 2);
    assert_eq!(page["deliveries"][0]["targetSummary"]["queued"], 2);
    assert!(!page.to_string().contains(&"ab".repeat(32)));
}

#[test]
fn notification_terminal_response_races_are_idempotent_and_invalidate_bad_tokens() {
    use crate::domains::worker_kernel::notifications::{
        NotificationAcknowledgeRequest, NotificationAcknowledgementKind,
        NotificationAuthorizationStatus, NotificationDeviceUpsertRequest, NotificationEnvironment,
        NotificationIntent, NotificationResponseAction,
    };

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    store
        .notification_device_upsert(NotificationDeviceUpsertRequest {
            installation_id: "installation-race".to_owned(),
            client_server_id: "paired-server".to_owned(),
            topic: "com.tron.mobile".to_owned(),
            environment: NotificationEnvironment::Production,
            authorization_status: NotificationAuthorizationStatus::Authorized,
            token: Some("cd".repeat(32)),
        })
        .unwrap();
    let intent = NotificationIntent {
        deduplication_key: "race-occurrence".to_owned(),
        title: "Race".to_owned(),
        body: "First response wins.".to_owned(),
        expires_at: chrono::Utc::now() + chrono::Duration::hours(1),
        not_before: chrono::Utc::now(),
        thread_key: None,
        source_record_id: Some("occurrence-race".to_owned()),
        actions: vec![
            NotificationResponseAction::Snooze,
            NotificationResponseAction::Complete,
        ],
        on_open_complete: true,
    };
    let (run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "race-run",
            "trace-race",
            0,
            "schedule",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .complete_invocation_with_notifications(
            &run.invocation_id,
            &published.worker.worker_id,
            &json!({"status":"evaluated"}),
            &[intent],
        )
        .unwrap();
    let delivery_id: String = store
        .connection()
        .unwrap()
        .query_row(
            "SELECT delivery_id FROM notification_deliveries",
            [],
            |row| row.get(0),
        )
        .unwrap();

    let opened = store
        .acknowledge_notification_delivery(NotificationAcknowledgeRequest {
            delivery_id: delivery_id.clone(),
            installation_id: "installation-race".to_owned(),
            client_mutation_id: "mutation-opened".to_owned(),
            acknowledgement: NotificationAcknowledgementKind::Opened,
            occurred_at: None,
        })
        .unwrap();
    assert_eq!(opened["accepted"], true);
    assert_eq!(opened["eventRequired"], true);
    let duplicate = store
        .acknowledge_notification_delivery(NotificationAcknowledgeRequest {
            delivery_id: delivery_id.clone(),
            installation_id: "installation-race".to_owned(),
            client_mutation_id: "mutation-complete".to_owned(),
            acknowledgement: NotificationAcknowledgementKind::Complete,
            occurred_at: None,
        })
        .unwrap();
    assert_eq!(duplicate["accepted"], false);
    assert_eq!(duplicate["currentTerminalResponse"], "opened");
    let replay = store
        .acknowledge_notification_delivery(NotificationAcknowledgeRequest {
            delivery_id: delivery_id.clone(),
            installation_id: "installation-race".to_owned(),
            client_mutation_id: "mutation-opened".to_owned(),
            acknowledgement: NotificationAcknowledgementKind::Opened,
            occurred_at: None,
        })
        .unwrap();
    assert_eq!(replay, opened);

    let target = store.claim_notification_targets(1).unwrap().remove(0);
    store
        .record_notification_target_outcome(
            &target,
            "direct",
            NotificationDispatchOutcome::Permanent {
                code: "BadDeviceToken".to_owned(),
                invalidate_token: true,
            },
        )
        .unwrap();
    let (enabled, token): (bool, Option<String>) = store
        .connection()
        .unwrap()
        .query_row(
            "SELECT enabled,token FROM notification_installations
             WHERE installation_id='installation-race'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert!(!enabled);
    assert!(token.is_none());
}

#[test]
fn notification_clear_unread_preserves_deferred_delivery_until_a_terminal_response() {
    use crate::domains::worker_kernel::notifications::{
        NotificationAcknowledgeRequest, NotificationAcknowledgementKind,
        NotificationAuthorizationStatus, NotificationDeviceUpsertRequest, NotificationEnvironment,
        NotificationIntent, NotificationResponseAction,
    };

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    store
        .notification_device_upsert(NotificationDeviceUpsertRequest {
            installation_id: "installation-deferred".to_owned(),
            client_server_id: "paired-server".to_owned(),
            topic: "com.tron.mobile.beta".to_owned(),
            environment: NotificationEnvironment::Sandbox,
            authorization_status: NotificationAuthorizationStatus::Authorized,
            token: Some("de".repeat(32)),
        })
        .unwrap();
    let intent = NotificationIntent {
        deduplication_key: "deferred-occurrence".to_owned(),
        title: "Deferred".to_owned(),
        body: "Wait until quiet hours end.".to_owned(),
        expires_at: chrono::Utc::now() + chrono::Duration::hours(2),
        not_before: chrono::Utc::now() + chrono::Duration::hours(1),
        thread_key: None,
        source_record_id: Some("occurrence-deferred".to_owned()),
        actions: vec![NotificationResponseAction::Complete],
        on_open_complete: true,
    };
    let (run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "deferred-run",
            "trace-deferred",
            0,
            "schedule",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .complete_invocation_with_notifications(
            &run.invocation_id,
            &published.worker.worker_id,
            &json!({"status":"evaluated"}),
            &[intent],
        )
        .unwrap();
    let delivery_id: String = store
        .connection()
        .unwrap()
        .query_row(
            "SELECT delivery_id FROM notification_deliveries",
            [],
            |row| row.get(0),
        )
        .unwrap();

    let clear_unread = store
        .acknowledge_notification_delivery(NotificationAcknowledgeRequest {
            delivery_id: delivery_id.clone(),
            installation_id: "installation-deferred".to_owned(),
            client_mutation_id: "mutation-clear-unread".to_owned(),
            acknowledgement: NotificationAcknowledgementKind::ClearUnread,
            occurred_at: None,
        })
        .unwrap();
    assert_eq!(clear_unread["eventRequired"], false);
    let (terminal_response, target_state): (Option<String>, String) = store
        .connection()
        .unwrap()
        .query_row(
            "SELECT delivery.terminal_response,target.state
             FROM notification_deliveries delivery
             JOIN notification_delivery_targets target USING(delivery_id)
             WHERE delivery.delivery_id=?1",
            [&delivery_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert!(terminal_response.is_none());
    assert_eq!(target_state, "queued");

    let complete = store
        .acknowledge_notification_delivery(NotificationAcknowledgeRequest {
            delivery_id: delivery_id.clone(),
            installation_id: "installation-deferred".to_owned(),
            client_mutation_id: "mutation-complete-deferred".to_owned(),
            acknowledgement: NotificationAcknowledgementKind::Complete,
            occurred_at: None,
        })
        .unwrap();
    assert_eq!(complete["accepted"], true);
    assert_eq!(complete["eventRequired"], true);
    let (terminal_response, target_state): (Option<String>, String) = store
        .connection()
        .unwrap()
        .query_row(
            "SELECT delivery.terminal_response,target.state
             FROM notification_deliveries delivery
             JOIN notification_delivery_targets target USING(delivery_id)
             WHERE delivery.delivery_id=?1",
            [&delivery_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(terminal_response.as_deref(), Some("complete"));
    assert_eq!(target_state, "cancelled");
}

#[test]
fn notification_targets_expire_and_stale_installations_do_not_fan_out() {
    use crate::domains::worker_kernel::notifications::{
        NotificationAuthorizationStatus, NotificationDeviceUpsertRequest, NotificationEnvironment,
        NotificationIntent,
    };

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    store
        .notification_device_upsert(NotificationDeviceUpsertRequest {
            installation_id: "installation-expiry".to_owned(),
            client_server_id: "paired-server".to_owned(),
            topic: "com.tron.mobile.beta".to_owned(),
            environment: NotificationEnvironment::Sandbox,
            authorization_status: NotificationAuthorizationStatus::Authorized,
            token: Some("ef".repeat(32)),
        })
        .unwrap();
    let first_intent = NotificationIntent {
        deduplication_key: "expiring-occurrence".to_owned(),
        title: "Expiry".to_owned(),
        body: "Stop retrying after expiry.".to_owned(),
        expires_at: chrono::Utc::now() + chrono::Duration::minutes(5),
        not_before: chrono::Utc::now(),
        thread_key: None,
        source_record_id: Some("occurrence-expiry".to_owned()),
        actions: Vec::new(),
        on_open_complete: false,
    };
    let (first_run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"action":"tick"}),
            "expiry-run",
            "trace-expiry",
            0,
            "schedule",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&first_run.invocation_id).unwrap());
    store
        .complete_invocation_with_notifications(
            &first_run.invocation_id,
            &published.worker.worker_id,
            &json!({"status":"evaluated"}),
            &[first_intent],
        )
        .unwrap();
    store
        .connection()
        .unwrap()
        .execute(
            "UPDATE notification_deliveries SET expires_at=?1",
            [(chrono::Utc::now() - chrono::Duration::minutes(1)).to_rfc3339()],
        )
        .unwrap();
    assert!(store.claim_notification_targets(10).unwrap().is_empty());
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row(
                "SELECT state FROM notification_delivery_targets",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "expired"
    );

    store
        .connection()
        .unwrap()
        .execute(
            "UPDATE notification_installations SET last_registered_at=?1",
            [(chrono::Utc::now() - chrono::Duration::days(31)).to_rfc3339()],
        )
        .unwrap();
    let second_intent = NotificationIntent {
        deduplication_key: "stale-installation-occurrence".to_owned(),
        title: "Stale".to_owned(),
        body: "Do not fan out to stale registrations.".to_owned(),
        expires_at: chrono::Utc::now() + chrono::Duration::hours(1),
        not_before: chrono::Utc::now(),
        thread_key: None,
        source_record_id: Some("occurrence-stale".to_owned()),
        actions: Vec::new(),
        on_open_complete: false,
    };
    let (second_run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"action":"tick"}),
            "stale-run",
            "trace-stale",
            0,
            "schedule",
            None,
        )
        .unwrap();
    assert!(store.claim_running(&second_run.invocation_id).unwrap());
    store
        .complete_invocation_with_notifications(
            &second_run.invocation_id,
            &published.worker.worker_id,
            &json!({"status":"evaluated"}),
            &[second_intent],
        )
        .unwrap();
    let connection = store.connection().unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM notification_delivery_targets target
                 JOIN notification_deliveries delivery USING(delivery_id)
                 WHERE delivery.deduplication_key='stale-installation-occurrence'",
                [],
                |row| row.get::<_, u32>(0),
            )
            .unwrap(),
        0
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT json_extract(result_json,'$.errorCode')
                 FROM worker_inbox
                 WHERE json_extract(result_json,'$.deliveryId') IN (
                    SELECT delivery_id FROM notification_deliveries
                    WHERE deduplication_key='stale-installation-occurrence'
                 )",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "no_active_installations"
    );
}

#[test]
fn notification_history_keeps_only_the_newest_five_hundred_within_ninety_days() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"action":"tick"}),
            "retention-run",
            "trace-retention",
            0,
            "schedule",
            None,
        )
        .unwrap();
    let now = chrono::Utc::now();
    let mut connection = store.connection().unwrap();
    let transaction = connection.transaction().unwrap();
    for index in 0..=500 {
        let created_at = (now + chrono::Duration::milliseconds(index)).to_rfc3339();
        transaction
            .execute(
                "INSERT INTO notification_deliveries(
                    delivery_id,worker_id,worker_version,invocation_id,deduplication_key,
                    title,body,expires_at,actions_json,on_open_complete,trace_id,
                    created_at,updated_at
                 ) VALUES (?1,?2,?3,?4,?5,'Retention','Retain bounded history.',?6,'[]',0,?7,?8,?8)",
                rusqlite::params![
                    format!("notification_retention_{index}"),
                    published.worker.worker_id,
                    published.version,
                    run.invocation_id,
                    format!("retention-{index}"),
                    (now + chrono::Duration::days(1)).to_rfc3339(),
                    run.trace_id,
                    created_at,
                ],
            )
            .unwrap();
    }
    let old_created_at = (now - chrono::Duration::days(91)).to_rfc3339();
    transaction
        .execute(
            "INSERT INTO notification_deliveries(
                delivery_id,worker_id,worker_version,invocation_id,deduplication_key,
                title,body,expires_at,actions_json,on_open_complete,trace_id,
                created_at,updated_at
             ) VALUES ('notification_retention_old',?1,?2,?3,'retention-old',
                       'Old','Age out.',?4,'[]',0,?5,?6,?6)",
            rusqlite::params![
                published.worker.worker_id,
                published.version,
                run.invocation_id,
                (now + chrono::Duration::days(1)).to_rfc3339(),
                run.trace_id,
                old_created_at,
            ],
        )
        .unwrap();
    transaction.commit().unwrap();
    drop(connection);

    store.maintain_notification_history().unwrap();
    let connection = store.connection().unwrap();
    assert_eq!(
        connection
            .query_row("SELECT COUNT(*) FROM notification_deliveries", [], |row| {
                row.get::<_, u32>(0)
            })
            .unwrap(),
        500
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM notification_deliveries
                 WHERE delivery_id IN ('notification_retention_old','notification_retention_0')",
                [],
                |row| row.get::<_, u32>(0),
            )
            .unwrap(),
        0
    );
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM notification_deliveries
                 WHERE delivery_id='notification_retention_500'",
                [],
                |row| row.get::<_, u32>(0),
            )
            .unwrap(),
        1
    );
}

#[test]
fn quiet_refresh_updates_wait_behind_the_inflight_attempt() {
    use crate::domains::worker_kernel::notifications::{
        NotificationAuthorizationStatus, NotificationDeviceUpsertRequest, NotificationEnvironment,
    };

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    store
        .notification_device_upsert(NotificationDeviceUpsertRequest {
            installation_id: "installation-refresh".to_owned(),
            client_server_id: "paired-server".to_owned(),
            topic: "com.tron.mobile.beta".to_owned(),
            environment: NotificationEnvironment::Sandbox,
            authorization_status: NotificationAuthorizationStatus::Authorized,
            token: Some("ab".repeat(32)),
        })
        .unwrap();

    let now = chrono::Utc::now().to_rfc3339();
    let mut connection = store.connection().unwrap();
    let transaction = connection.transaction().unwrap();
    notifications::enqueue_refreshes(&transaction, &now).unwrap();
    transaction.commit().unwrap();

    let first = store.claim_notification_refreshes(1).unwrap().remove(0);
    assert_eq!(first.attempt_number, 1);

    let later = (chrono::Utc::now() + chrono::Duration::milliseconds(1)).to_rfc3339();
    let mut connection = store.connection().unwrap();
    let transaction = connection.transaction().unwrap();
    notifications::enqueue_refreshes(&transaction, &later).unwrap();
    transaction.commit().unwrap();
    assert!(store.claim_notification_refreshes(1).unwrap().is_empty());
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row(
                "SELECT state FROM notification_refreshes
                 WHERE installation_id='installation-refresh'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "sending_pending"
    );

    let accepted = NotificationDispatchOutcome::Accepted {
        apns_id: "provider-id".to_owned(),
    };
    store
        .record_notification_refresh_outcome(&first, "relay", accepted.clone())
        .unwrap();
    store
        .record_notification_refresh_outcome(&first, "relay", accepted)
        .unwrap();

    let second = store.claim_notification_refreshes(1).unwrap().remove(0);
    assert_eq!(second.attempt_number, 2);
    store
        .record_notification_refresh_outcome(
            &second,
            "relay",
            NotificationDispatchOutcome::Accepted {
                apns_id: "provider-id-2".to_owned(),
            },
        )
        .unwrap();
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM notification_refreshes", [], |row| {
                row.get::<_, u64>(0)
            })
            .unwrap(),
        0
    );
}

#[test]
fn artifact_custody_is_atomic_content_addressed_and_explicitly_deleted() {
    use crate::domains::worker_kernel::artifacts::artifact_intents_for_bundle;

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.worker_id = Some("document-artifact".to_owned());
    candidate.name = "Document Artifact".to_owned();
    candidate.client_deliveries = vec![WorkerClientDelivery::ArtifactDelivery];
    candidate.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["document","artifactDeliveries"],
        "properties":{
            "document":{
                "type":"object","required":["data"],
                "properties":{"data":{"type":"string"}}
            },
            "artifactDeliveries":{"type":"array"}
        }
    });
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();

    let (run, replayed) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"title":"Report"}),
            "artifact-run-one",
            "trace-artifact-one",
            0,
            "manual",
            Some("session-artifact"),
        )
        .unwrap();
    assert!(!replayed);
    assert!(store.claim_running(&run.invocation_id).unwrap());
    let output = json!({
        "document":{"data":"aGVsbG8="},
        "artifactDeliveries":[{
            "artifactId":"report-1",
            "displayName":"report.md",
            "mediaType":"text/markdown",
            "sizeBytes":5,
            "contentReference":{
                "kind":"worker_result_reference",
                "invocationId":run.invocation_id,
                "pointer":"/document/data",
                "encoding":"base64"
            }
        }]
    });
    let active = store
        .load_version(&published.worker.worker_id, &published.version)
        .unwrap();
    let intents = artifact_intents_for_bundle(&active.bundle, &run.invocation_id, &output).unwrap();
    store
        .complete_invocation_with_effects(
            &run.invocation_id,
            &published.worker.worker_id,
            &output,
            &[],
            &intents,
            &[],
            None,
        )
        .unwrap();

    let inbox = store.artifact_deliveries(20, 0).unwrap();
    assert_eq!(inbox["returned"], 1);
    assert_eq!(inbox["artifacts"][0]["artifactId"], "report-1");
    assert_eq!(inbox["artifacts"][0]["traceId"], "trace-artifact-one");
    assert_eq!(
        inbox["artifacts"][0]["contentReference"]["kind"],
        "artifact_content_reference"
    );
    let content = store
        .artifact_content(&published.worker.worker_id, "report-1")
        .unwrap();
    assert_eq!(content["data"], "aGVsbG8=");
    assert_eq!(content["artifact"]["sizeBytes"], 5);

    let connection = store.connection().unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM storage_payload_refs
                 WHERE owner_kind='worker_artifact'
                   AND retention_class='user_artifact'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1
    );
    let schema_version = connection
        .query_row("SELECT MAX(version) FROM worker_schema", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    assert!(schema_version >= 14);
    drop(connection);

    assert_eq!(
        store
            .delete_artifact(&published.worker.worker_id, "report-1")
            .unwrap()["deleted"],
        true
    );
    assert_eq!(
        store
            .delete_artifact(&published.worker.worker_id, "report-1")
            .unwrap()["deleted"],
        false
    );
    assert!(
        store.artifact_deliveries(20, 0).unwrap()["artifacts"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let connection = store.connection().unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM storage_payload_refs
                 WHERE owner_kind='worker_artifact'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
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

#[test]
fn immutable_artifact_collision_rolls_back_invocation_completion() {
    use crate::domains::worker_kernel::artifacts::artifact_intents_for_bundle;

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.worker_id = Some("document-artifact".to_owned());
    candidate.client_deliveries = vec![WorkerClientDelivery::ArtifactDelivery];
    candidate.output_schema = json!({
        "type":"object",
        "properties":{
            "document":{"type":"object"},
            "artifactDeliveries":{"type":"array"}
        }
    });
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let active = store
        .load_version(&published.worker.worker_id, &published.version)
        .unwrap();

    for (index, encoded) in ["b25l", "dHdv"].into_iter().enumerate() {
        let (run, _) = store
            .begin_invocation(
                &published.worker.worker_id,
                &published.version,
                &json!({}),
                &format!("artifact-collision-{index}"),
                &format!("trace-artifact-{index}"),
                0,
                "manual",
                None,
            )
            .unwrap();
        assert!(store.claim_running(&run.invocation_id).unwrap());
        let output = json!({
            "document":{"data":encoded},
            "artifactDeliveries":[{
                "artifactId":"stable-report",
                "displayName":"report.txt",
                "mediaType":"text/plain",
                "sizeBytes":3,
                "contentReference":{
                    "kind":"worker_result_reference",
                    "invocationId":run.invocation_id,
                    "pointer":"/document/data",
                    "encoding":"base64"
                }
            }]
        });
        let intents =
            artifact_intents_for_bundle(&active.bundle, &run.invocation_id, &output).unwrap();
        let result = store.complete_invocation_with_effects(
            &run.invocation_id,
            &published.worker.worker_id,
            &output,
            &[],
            &intents,
            &[],
            None,
        );
        if index == 0 {
            result.unwrap();
        } else {
            assert!(
                result
                    .unwrap_err()
                    .contains("immutable and already names different content")
            );
            assert_eq!(
                store
                    .invocation(&run.invocation_id)
                    .unwrap()
                    .unwrap()
                    .status,
                "running"
            );
        }
    }
    assert_eq!(store.artifact_deliveries(20, 0).unwrap()["returned"], 1);
}

#[test]
fn artifact_storage_attention_is_transition_aware_and_resolvable() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "artifact-pressure-source",
            "trace-artifact-pressure",
            0,
            "manual",
            None,
        )
        .unwrap();
    let created_at = chrono::Utc::now().to_rfc3339();

    let mut connection = store.connection().unwrap();
    let transaction = connection.transaction().unwrap();
    super::artifacts::reconcile_artifact_storage_attention_with_budget(
        &transaction,
        &run.invocation_id,
        &published.worker.worker_id,
        &created_at,
        1,
    )
    .unwrap();
    super::artifacts::reconcile_artifact_storage_attention_with_budget(
        &transaction,
        &run.invocation_id,
        &published.worker.worker_id,
        &created_at,
        1,
    )
    .unwrap();
    transaction.commit().unwrap();

    let attention = store
        .inbox_filtered_page(None, None, None, true, 20, 0)
        .unwrap();
    assert_eq!(attention.len(), 1);
    assert_eq!(
        attention[0]["result"]["status"],
        "artifact_storage_pressure"
    );

    let mut connection = store.connection().unwrap();
    let transaction = connection.transaction().unwrap();
    super::artifacts::reconcile_artifact_storage_attention_with_budget(
        &transaction,
        &run.invocation_id,
        &published.worker.worker_id,
        &chrono::Utc::now().to_rfc3339(),
        u64::MAX,
    )
    .unwrap();
    transaction.commit().unwrap();
    assert!(
        store
            .inbox_filtered_page(None, None, None, true, 20, 0)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM worker_inbox
                 WHERE json_extract(result_json,'$.status')='artifact_storage_pressure'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1,
        "resolved attention remains immutable audit evidence"
    );
}
