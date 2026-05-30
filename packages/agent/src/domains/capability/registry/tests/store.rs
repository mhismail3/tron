use super::support::*;

#[test]
fn sqlite_registry_store_round_trips_documents_bindings_and_conformance() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    let snapshot =
        CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 11);
    let policy = CapabilitySearchPolicy::default();
    let provider = HashEmbeddingProvider::new(64);
    let status = store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("sync");
    assert_eq!(status.state, "ready");

    let results = store
        .search(
            "read path",
            &CapabilitySearchFilters::default(),
            &policy,
            10,
            &provider,
        )
        .expect("search");
    assert!(
        results
            .hits
            .iter()
            .any(|hit| hit.function_id == "filesystem::read_file")
    );
    assert_eq!(
        store
            .implementation_conformance_state("first_party.filesystem.v1.read_file")
            .expect("conformance"),
        Some("healthy".to_owned())
    );
    let plugin_count: i64 = store
        .conn
        .query_row("SELECT COUNT(*) FROM capability_plugins", [], |row| {
            row.get(0)
        })
        .expect("plugin count");
    assert_eq!(plugin_count, 1);
    store
        .conn
        .execute(
            "INSERT INTO capability_bindings
               (contract_id, scope_kind, scope_value, selected_implementation,
                selection_policy, enabled, updated_at)
             VALUES (?1, 'system', 'default', ?2, 'test_binding', 1, ?3)",
            rusqlite::params![
                "filesystem::read_file",
                "first_party.filesystem.v1.read_file",
                Utc::now().to_rfc3339()
            ],
        )
        .expect("binding");
    let binding = store
        .active_binding("filesystem::read_file", None, None)
        .expect("active binding")
        .expect("binding present");
    assert_eq!(binding.selection_policy, "test_binding");

    let entry = snapshot.entries[0].clone();
    let handle = entry.inspection_handle();
    let decision = CapabilityBindingDecision {
        decision_id: "binding_decision_test".to_owned(),
        contract_id: entry.contract_id.clone(),
        selected_implementation: entry.implementation_id.clone(),
        selected_function_id: entry.function_id.clone(),
        selection_policy: "test".to_owned(),
        rejected_candidates: Vec::new(),
        catalog_revision: entry.catalog_revision,
        schema_digest: entry.schema_digest.clone(),
    };
    store
        .record_inspection(&handle, &entry, &decision)
        .expect("record inspection");
    assert!(
        store
            .validate_inspection(&handle.handle, &entry)
            .expect("validate inspection")
    );
    let mut stale_entry = entry.clone();
    stale_entry.schema_digest = "different".to_owned();
    assert!(
        !store
            .validate_inspection(&handle.handle, &stale_entry)
            .expect("stale inspection rejected")
    );
}

#[test]
fn sqlite_registry_records_degraded_vector_metadata() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    let snapshot =
        CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 11);
    let policy = CapabilitySearchPolicy {
        require_local_vector: false,
        allow_lexical_only_when_degraded: true,
        ..CapabilitySearchPolicy::default()
    };

    let status = store
        .sync_snapshot(&snapshot, &FailingEmbeddingProvider, &policy)
        .expect("degraded sync");

    assert_eq!(status.state, "unavailable");
    let admin = store.admin_status().expect("status");
    assert_eq!(admin["indexStatus"]["state"], "unavailable");
    assert_eq!(
        admin["indexStatus"]["degradedReason"],
        "embedding assets unavailable"
    );
    assert_eq!(admin["indexStatus"]["embeddingModel"], "test:failing");
}

#[test]
fn sqlite_search_degrades_while_filtered_vectors_are_still_indexing() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    let snapshot =
        CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 11);
    let metadata_only_policy = CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    };
    let strict_search_policy = CapabilitySearchPolicy {
        local_vector: true,
        require_local_vector: true,
        allow_lexical_only_when_degraded: false,
        ..CapabilitySearchPolicy::default()
    };
    let provider = HashEmbeddingProvider::new(64);

    store
        .sync_snapshot(&snapshot, &provider, &metadata_only_policy)
        .expect("metadata sync");
    let result = store
        .search(
            "read file",
            &CapabilitySearchFilters {
                kind: Some("contract".to_owned()),
                contract_id: Some("filesystem::read_file".to_owned()),
                ..CapabilitySearchFilters::default()
            },
            &strict_search_policy,
            5,
            &provider,
        )
        .expect("indexing vectors should not make search unavailable");

    assert!(
        result
            .hits
            .iter()
            .any(|hit| hit.contract_id == "filesystem::read_file")
    );
    assert_eq!(result.status.state, "indexing");
    assert!(
        result
            .status
            .degraded_reason
            .as_deref()
            .is_some_and(|reason| reason.starts_with("CAPABILITY_INDEX_INDEXING:"))
    );
}

#[test]
fn sqlite_registry_recreates_missing_vector_table_when_metadata_remains() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    let snapshot =
        CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 11);
    let policy = CapabilitySearchPolicy::default();
    let provider = HashEmbeddingProvider::new(64);
    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("initial vector sync");
    store
        .conn
        .execute_batch("DROP TABLE capability_index_vectors;")
        .expect("drop vector table");

    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("resync recreates vector table");
    let vector_count: i64 = store
        .conn
        .query_row("SELECT COUNT(*) FROM capability_index_vectors", [], |row| {
            row.get(0)
        })
        .expect("vector count");
    assert!(
        vector_count > 0,
        "resync should recreate and repopulate the vector table"
    );
}

#[test]
fn sqlite_registry_batches_vector_indexing_for_registry_warmup() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    let functions = (0..20)
        .map(|index| test_function(&format!("test{index}::capability")))
        .collect::<Vec<_>>();
    let snapshot = CapabilityRegistrySnapshot::new(functions, 11);
    let policy = CapabilitySearchPolicy::default();
    let provider = CountingEmbeddingProvider::new();

    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("batched vector sync");

    let vector_count: i64 = store
        .conn
        .query_row("SELECT COUNT(*) FROM capability_index_vectors", [], |row| {
            row.get(0)
        })
        .expect("vector count");
    assert!(
        vector_count > 32,
        "test should exercise multiple vector jobs"
    );
    assert!(
        provider.calls() < vector_count as usize,
        "vector writes should use batched embedding calls"
    );
    assert!(
        provider.max_batch() > 1,
        "at least one embedding call should contain multiple documents"
    );
}

#[test]
fn sqlite_registry_skips_unchanged_vector_documents_on_resync() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    let functions = (0..8)
        .map(|index| test_function(&format!("stable{index}::capability")))
        .collect::<Vec<_>>();
    let snapshot = CapabilityRegistrySnapshot::new(functions, 11);
    let policy = CapabilitySearchPolicy::default();
    let provider = CountingEmbeddingProvider::new();

    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("initial vector sync");
    let calls_after_initial = provider.calls();
    assert!(calls_after_initial > 0, "initial sync embeds documents");

    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("unchanged resync");
    assert_eq!(
        provider.calls(),
        calls_after_initial,
        "unchanged documents must not be re-embedded on the query or warmup path"
    );
}

#[test]
fn sqlite_program_runs_keep_trace_parent_binding_and_redaction_metadata() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    store
        .record_program_run(&CapabilityProgramRunRecord {
            program_run_id: "program_run_test".to_owned(),
            parent_invocation_id: Some("invocation_parent".to_owned()),
            root_invocation_id: "invocation_root".to_owned(),
            binding_decision_id: Some("binding_decision_test".to_owned()),
            status: "ok".to_owned(),
            trace_id: "trace_test".to_owned(),
            code_hash: "code_hash".to_owned(),
            args_hash: "args_hash".to_owned(),
            limits: json!({"timeoutMs": 1000}),
            allowed_contracts: vec!["filesystem::read_file".to_owned()],
            allowed_implementations: vec!["first_party.filesystem.v1.read_file".to_owned()],
            child_invocations: vec!["child_invocation".to_owned()],
            selected_implementations: vec!["first_party.filesystem.v1.read_file".to_owned()],
            approval_state: None,
            artifacts: vec![json!({"path": "artifact.txt"})],
            logs: vec!["sensitive log".to_owned()],
            error: None,
            compensation_attempts: vec![json!({"status": "not_declared"})],
        })
        .expect("record program run");

    let redacted = store
        .program_run_query(Some("trace_test"), None, 10, false)
        .expect("program runs");
    let run = &redacted["programRuns"][0];
    assert_eq!(run["parentInvocationId"], "invocation_parent");
    assert_eq!(run["rootInvocationId"], "invocation_root");
    assert_eq!(run["bindingDecisionId"], "binding_decision_test");
    assert_eq!(run["logs"]["redacted"], true);
    assert_eq!(run["artifacts"]["count"], 1);
    assert_eq!(run["compensationAttempts"]["count"], 1);
    assert_eq!(
        run["payloadSummary"]["bindingDecisionId"],
        "binding_decision_test"
    );

    let revealed = store
        .program_run_query(Some("trace_test"), None, 10, true)
        .expect("revealed program runs");
    assert_eq!(revealed["programRuns"][0]["logs"][0], "sensitive log");
    assert_eq!(
        revealed["programRuns"][0]["compensationAttempts"][0]["status"],
        "not_declared"
    );
}

#[test]
fn lifecycle_pause_and_run_records_round_trip_in_registry_store() {
    let mut store = InMemoryCapabilityRegistryStore::default();
    store
        .record_pause(&CapabilityPauseRecord {
            pause_id: "pause_test".to_owned(),
            invocation_id: "invocation_test".to_owned(),
            contract_id: "agent::ask_user".to_owned(),
            implementation_id: "first_party.agent.v1.ask_user".to_owned(),
            function_id: "agent::ask_user".to_owned(),
            plugin_id: Some("first_party.agent".to_owned()),
            worker_id: Some("agent".to_owned()),
            kind: "user_input".to_owned(),
            status: "pending".to_owned(),
            prompt_payload: json!({"question": "Proceed?"}),
            resume_schema: Some(json!({"type": "object"})),
            answer_authority: "user_client".to_owned(),
            expires_at: Some("2026-05-14T00:00:00Z".to_owned()),
            trace_id: Some("trace_test".to_owned()),
            root_invocation_id: Some("root_test".to_owned()),
            binding_decision_id: Some("binding_test".to_owned()),
        })
        .expect("record pause");
    let resolved = store
        .resolve_pause("pause_test", "resumed", json!({"answers": 1}))
        .expect("resolve pause")
        .expect("pause present");
    assert_eq!(resolved.status, "pending");
    let duplicate = store
        .resolve_pause("pause_test", "resumed", json!({"answers": 2}))
        .expect("duplicate resolve")
        .expect("pause present");
    assert_eq!(duplicate.status, "resumed");
    assert_eq!(duplicate.prompt_payload["resolution"]["answers"], json!(1));

    store
        .record_run(&CapabilityRunRecord {
            run_id: "run_test".to_owned(),
            invocation_id: "invocation_test".to_owned(),
            contract_id: "agent::spawn_subagent".to_owned(),
            implementation_id: "first_party.agent.v1.spawn_subagent".to_owned(),
            function_id: "agent::spawn_subagent".to_owned(),
            plugin_id: Some("first_party.agent".to_owned()),
            worker_id: Some("agent".to_owned()),
            status: "running".to_owned(),
            stream_topic: Some("agent.runtime".to_owned()),
            child_invocations: vec!["child_test".to_owned()],
            trace_id: Some("trace_test".to_owned()),
            root_invocation_id: Some("root_test".to_owned()),
            binding_decision_id: Some("binding_test".to_owned()),
            details: json!({"task": "check"}),
        })
        .expect("record run");
    let updated = store
        .update_run_status("run_test", "completed", json!({"result": "ok"}))
        .expect("update run")
        .expect("run present");
    assert_eq!(updated.status, "completed");
    assert_eq!(updated.details["statusDetails"]["result"], json!("ok"));
    assert_eq!(store.admin_status().expect("status")["runs"], json!(1));
}

#[test]
fn audit_query_redacts_payload_by_default() {
    let mut store = InMemoryCapabilityRegistryStore::default();
    store
        .record_audit_event(
            "capability.execute",
            Some("trace-1"),
            json!({
                "contractId": "filesystem::read_file",
                "secret": "should-not-render",
            }),
        )
        .expect("audit");
    let redacted = store
        .audit_query(Some("capability.execute"), Some("trace-1"), 10, false)
        .expect("query");
    let event = &redacted["events"][0];
    assert_eq!(event["redacted"], json!(true));
    assert_eq!(event["payload"]["redacted"], json!(true));
    assert_eq!(
        event["payloadSummary"]["contractId"],
        json!("filesystem::read_file")
    );
    assert_eq!(event["payload"].get("secret"), None);

    let revealed = store
        .audit_query(Some("capability.execute"), Some("trace-1"), 10, true)
        .expect("revealed query");
    assert_eq!(
        revealed["events"][0]["payload"]["secret"],
        json!("should-not-render")
    );
}
