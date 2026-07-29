//! Results persistence tests.

use super::*;

#[test]
fn terminal_worker_truth_and_agent_outbox_signal_commit_together() {
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
            "agent-outbox-terminal",
            "trace-agent-outbox-terminal",
            0,
            "manual",
            Some("session-agent-outbox"),
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .complete_invocation(
            &run.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"summary":"complete"})),
        )
        .unwrap();

    let rows = store.pending_agent_delivery_outbox(10).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].invocation_id, run.invocation_id);
    assert_eq!(rows[0].payload["status"], "completed");
    assert_eq!(
        rows[0].payload["automaticDeliveryEligible"], false,
        "a foreground result already reached its caller"
    );
    assert!(
        store
            .mark_agent_delivery_outbox_imported(&rows[0].outbox_id)
            .unwrap()
    );
    assert!(store.pending_agent_delivery_outbox(10).unwrap().is_empty());
}

#[test]
fn outbox_rejection_and_operator_attention_commit_atomically() {
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
            "atomic-rejection",
            "trace-atomic-rejection",
            0,
            "manual",
            Some("deleted-session"),
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    store
        .complete_invocation(
            &run.invocation_id,
            &published.worker.worker_id,
            Ok(&json!({"summary":"cannot import"})),
        )
        .unwrap();
    let pending = store.pending_agent_delivery_outbox(10).unwrap();
    assert_eq!(pending.len(), 1);
    let outbox_id = pending[0].outbox_id.clone();
    let attention_id = format!("agent_delivery_outbox_attention_{outbox_id}");
    store
        .connection()
        .unwrap()
        .execute_batch(&format!(
            "CREATE TRIGGER fail_agent_delivery_attention
             BEFORE INSERT ON worker_inbox
             WHEN NEW.inbox_id='{attention_id}'
             BEGIN SELECT RAISE(ABORT,'forced attention failure'); END;"
        ))
        .unwrap();

    assert!(
        store
            .reject_agent_delivery_outbox(&outbox_id, "deleted target")
            .is_err()
    );
    assert_eq!(
        store
            .agent_delivery_outbox(&outbox_id)
            .unwrap()
            .unwrap()
            .disposition,
        "pending",
        "a failed Attention insert must roll back permanent rejection"
    );

    store
        .connection()
        .unwrap()
        .execute_batch("DROP TRIGGER fail_agent_delivery_attention")
        .unwrap();
    assert!(
        store
            .reject_agent_delivery_outbox(&outbox_id, "deleted target")
            .unwrap()
    );
    assert!(
        !store
            .reject_agent_delivery_outbox(&outbox_id, "deleted target")
            .unwrap()
    );
    assert_eq!(
        store
            .agent_delivery_outbox(&outbox_id)
            .unwrap()
            .unwrap()
            .disposition,
        "rejected"
    );
    let attention = store
        .inbox_filtered(Some(&published.worker.worker_id), None, Some("error"), 10)
        .unwrap();
    assert_eq!(
        attention
            .iter()
            .filter(|item| item["inboxId"] == attention_id)
            .count(),
        1
    );
}

#[test]
fn declared_delivery_effect_and_terminal_truth_share_one_completion_transaction() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut source_bundle = bundle();
    source_bundle.engine_deliveries =
        vec![crate::domains::worker_kernel::types::WorkerEngineDelivery::AgentDelivery];
    source_bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["summary","agentDeliveries"],
        "properties":{
            "summary":{"type":"string"},
            "agentDeliveries":{
                "type":"array",
                "maxItems":16,
                "items":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":["deduplicationKey","target","content"],
                    "properties":{
                        "deduplicationKey":{"type":"string"},
                        "target":{"type":"object"},
                        "content":{"type":"string"},
                        "intent":{"type":"string"},
                        "wakePolicy":{"type":"string"},
                        "boundary":{"type":"string"},
                        "expiresAt":{"type":"string"}
                    }
                }
            }
        }
    });
    let mut prepared = store.prepare(source_bundle.clone(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (run, _) = store
        .begin_invocation_with_context(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "agent-outbox-effect",
            "trace-agent-outbox-effect",
            2,
            "manual",
            Some("session-agent-outbox"),
            WorkerInteractionMode::Foreground,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(store.claim_running(&run.invocation_id).unwrap());
    let output = json!({
        "summary":"complete",
        "agentDeliveries":[{
            "deduplicationKey":"peer-update",
            "target":{"kind":"session","sessionId":"session-agent-outbox"},
            "content":"A bounded peer update.",
            "intent":"information",
            "wakePolicy":"passive",
            "boundary":"next_turn"
        }]
    });
    let effects =
        crate::domains::worker_kernel::agent_delivery_effects::parse_agent_delivery_effects(
            &source_bundle,
            &output,
        )
        .unwrap();
    store
        .complete_invocation_with_effects_and_session_organization(
            &run.invocation_id,
            &published.worker.worker_id,
            &output,
            &[],
            &[],
            &effects,
            &[],
            None,
            None,
        )
        .unwrap();

    let rows = store.pending_agent_delivery_outbox(10).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(
        rows.iter().map(|row| row.kind.as_str()).collect::<Vec<_>>(),
        ["terminal", "delivery"],
        "stable outbox ordering does not change their shared-transaction truth"
    );
    assert_eq!(rows[0].payload["status"], "completed");
    assert_eq!(rows[1].payload["deduplicationKey"], "peer-update");
}

#[test]
fn detached_terminal_signal_is_eligible_and_rejection_does_not_block_later_rows() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();

    for ordinal in 0..2 {
        let (run, _) = store
            .begin_invocation_with_context(
                &published.worker.worker_id,
                &published.version,
                &json!({}),
                &format!("agent-outbox-background-{ordinal}"),
                &format!("trace-agent-outbox-background-{ordinal}"),
                0,
                "manual",
                Some("session-agent-outbox"),
                WorkerInteractionMode::Background,
                None,
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
                Ok(&json!({"summary":ordinal})),
            )
            .unwrap();
    }

    let rows = store.pending_agent_delivery_outbox(10).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].payload["automaticDeliveryEligible"], true);
    assert!(
        store
            .reject_agent_delivery_outbox(&rows[0].outbox_id, "invalid target")
            .unwrap()
    );
    let rejected = store
        .agent_delivery_outbox(&rows[0].outbox_id)
        .unwrap()
        .expect("rejected outbox row remains as durable evidence");
    assert_eq!(rejected.disposition, "rejected");
    assert_eq!(rejected.attempts, 1);
    assert_eq!(rejected.last_error.as_deref(), Some("invalid target"));
    assert!(rejected.processed_at.is_some());
    let remaining = store.pending_agent_delivery_outbox(10).unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].outbox_id, rows[1].outbox_id);
}

#[test]
fn invocation_queue_waits_for_an_existing_writer_before_reading_trace_state() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();

    let mut blocking_connection = store.connection().unwrap();
    let blocking_transaction = blocking_connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let queued_store = store.clone();
    let queued_barrier = barrier.clone();
    let worker_id = published.worker.worker_id.clone();
    let version = published.version.clone();
    let queued = std::thread::spawn(move || {
        queued_barrier.wait();
        queued_store.begin_invocation(
            &worker_id,
            &version,
            &json!({"topic":"concurrent admission"}),
            "concurrent-admission",
            "trace-concurrent-admission",
            0,
            "engine_hook:continuity_context",
            Some("session-concurrent-admission"),
        )
    });

    barrier.wait();
    std::thread::sleep(std::time::Duration::from_millis(100));
    blocking_transaction.commit().unwrap();

    let (run, replayed) = queued.join().unwrap().unwrap();
    assert!(!replayed);
    assert_eq!(run.status, "queued");
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
        super::super::results::result_reference_from_connection(&transaction, &run.invocation_id)
            .unwrap();
    transaction
        .execute(
            "INSERT INTO worker_result_migration_v10(
                invocation_id,stored_output,receipt_json
             ) VALUES (?1,?2,?3)",
            params![
                run.invocation_id,
                staged_output,
                serde_json::to_string(&super::super::results::completed_result_receipt(
                    &staged_reference,
                ))
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
fn worker_inbox_keeps_background_manual_and_system_history() {
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
    assert_eq!(
        store
            .inbox_filtered(Some(&outcome.worker.worker_id), None, None, 10)
            .unwrap()
            .iter()
            .filter(|item| item["contextAttached"] == false)
            .count(),
        4
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
}
