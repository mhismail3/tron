//! Notifications persistence tests.

use super::*;

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
    super::super::notifications::enqueue_refreshes(&transaction, &now).unwrap();
    transaction.commit().unwrap();

    let first = store.claim_notification_refreshes(1).unwrap().remove(0);
    assert_eq!(first.attempt_number, 1);

    let later = (chrono::Utc::now() + chrono::Duration::milliseconds(1)).to_rfc3339();
    let mut connection = store.connection().unwrap();
    let transaction = connection.transaction().unwrap();
    super::super::notifications::enqueue_refreshes(&transaction, &later).unwrap();
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
