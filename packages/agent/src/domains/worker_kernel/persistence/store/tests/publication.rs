//! Publication persistence tests.

use super::*;

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
fn retired_worker_relevance_hook_is_decode_only() {
    let mut candidate = bundle();
    candidate.engine_hooks = vec![WorkerEngineHook::WorkerRelevance];

    let decoded: WorkerBundle = serde_json::from_value(serde_json::to_value(&candidate).unwrap())
        .expect("historical hook tag remains decodable");
    assert_eq!(decoded.engine_hooks, candidate.engine_hooks);
    assert_eq!(
        validate_publishable_bundle(&candidate).unwrap_err(),
        "engine hook 'worker_relevance' is retired; use deterministic worker routing"
    );
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let error = match store.prepare(candidate, None) {
        Ok(_) => panic!("fresh worker relevance publication must stay retired"),
        Err(error) => error,
    };
    assert_eq!(
        error,
        "engine hook 'worker_relevance' is retired; use deterministic worker routing"
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
        .push(crate::domains::worker_kernel::types::WorkerCommand {
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
    for row in store.pending_agent_delivery_outbox(100).unwrap() {
        assert!(
            store
                .mark_agent_delivery_outbox_imported(&row.outbox_id)
                .unwrap()
        );
    }
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
