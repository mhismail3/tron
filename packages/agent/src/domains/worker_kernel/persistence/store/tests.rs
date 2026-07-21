use super::*;
use crate::domains::worker_kernel::types::{WorkerRunner, WorkerTrigger};

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
        routing: Default::default(),
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
    let retired_inspection = store.inspect("recent-research").unwrap();
    assert!(
        !retired_inspection["triggers"][0]["enabled"]
            .as_bool()
            .unwrap_or(true)
    );
    assert!(store.purge("recent-research").unwrap());
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
    let recovered_attempts = reopened.attempts(&queued.invocation_id).unwrap();
    assert_eq!(recovered_attempts.len(), 1);
    assert_eq!(recovered_attempts[0]["status"], "interrupted");
    assert!(reopened.claim_running(&queued.invocation_id).unwrap());
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
    let first = store
        .take_notable_unseen(Some("recent research"), 10)
        .unwrap();
    assert_eq!(first.len(), 2);
    assert!(first.iter().any(|item| item["triggerKind"] == "schedule"));
    assert!(first.iter().any(|item| {
        item["triggerKind"] == "system" && item["result"]["phase"] == "resident_supervision"
    }));
    assert!(
        store
            .take_notable_unseen(Some("recent research"), 10)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .inbox(Some(&outcome.worker.worker_id), 10)
            .unwrap()
            .iter()
            .filter(|item| item["seen"] == false)
            .count(),
        1
    );
}
