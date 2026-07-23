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
        routing: Default::default(),
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
fn schema_v5_preserves_and_truthfully_renames_inbox_delivery_state() {
    let temp = tempfile::tempdir().unwrap();
    let database_dir = temp.path().join("internal/database");
    std::fs::create_dir_all(&database_dir).unwrap();
    let database = database_dir.join("workers.sqlite");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE worker_schema(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
             INSERT INTO worker_schema VALUES(4, 'now');
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
        5
    );
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
    assert_eq!(attention.len(), 2);
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
    assert!(
        attention
            .iter()
            .any(|item| { item["triggerKind"] == "system" && item["hasInvocation"] == false })
    );
    let first = store
        .take_notable_pending(Some("recent research"), 10)
        .unwrap();
    assert_eq!(first.len(), 2);
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
    assert_eq!(retained.len(), 3);
    assert!(retained.iter().any(|item| {
        item["result"]["phase"] == "resident_supervision" && item["requiresAttention"] == false
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
