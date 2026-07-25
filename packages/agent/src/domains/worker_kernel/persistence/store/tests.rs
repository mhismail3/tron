use super::*;
use crate::domains::worker_kernel::types::{WorkerPresentation, WorkerRunner, WorkerTrigger};

fn bundle() -> WorkerBundle {
    WorkerBundle {
        schema_version: BUNDLE_SCHEMA.to_owned(),
        worker_id: None,
        name: "Recent Research".to_owned(),
        description: "Research a topic across recent sources".to_owned(),
        tool_name: None,
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
fn schema_v10_preserves_run_evidence_and_adds_result_ownership() {
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
    let retained = store.inbox_filtered(None, Some(true), None, 10).unwrap();
    assert_eq!(retained.len(), 1);
    assert_eq!(retained[0]["contextAttached"], true);
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row("SELECT MAX(version) FROM worker_schema", [], |row| {
                row.get::<_, u32>(0)
            })
            .unwrap(),
        10
    );
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
    assert_eq!(
        reopened
            .connection()
            .unwrap()
            .query_row("SELECT MAX(version) FROM worker_schema", [], |row| {
                row.get::<_, u32>(0)
            })
            .unwrap(),
        10
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
    let mut invalid_turns = bundle();
    invalid_turns.execution_limits.max_agent_turns = Some(0);
    let error = store.prepare(invalid_turns, None).unwrap_err();
    assert!(error.contains("maxAgentTurns"), "{error}");

    let mut invalid_children = bundle();
    invalid_children.execution_limits.max_child_invocations = Some(257);
    let error = store.prepare(invalid_children, None).unwrap_err();
    assert!(error.contains("maxChildInvocations"), "{error}");

    let mut bounded = bundle();
    bounded.execution_limits.max_agent_turns = Some(7);
    bounded.execution_limits.max_child_invocations = Some(6);
    let mut prepared = store.prepare(bounded, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let active = store.load_active(&published.worker.worker_id).unwrap();
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
    assert_eq!(attention.len(), 3);
    assert!(
        attention
            .iter()
            .all(|item| item["requiresAttention"] == true)
    );
    assert!(
        attention
            .iter()
            .any(|item| { item["triggerKind"] == "schedule" && item["hasInvocation"] == true })
    );
    assert!(attention.iter().any(|item| {
        item["invocationId"] == detached_manual.invocation_id && item["triggerKind"] == "manual"
    }));
    assert!(
        attention
            .iter()
            .any(|item| { item["triggerKind"] == "system" && item["hasInvocation"] == false })
    );
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
