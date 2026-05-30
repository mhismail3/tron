use super::support::*;

#[test]
fn registry_entry_defaults_to_first_party_metadata() {
    let entry = CapabilityRegistryEntry::from_function(test_function("filesystem::read_file"), 7);
    assert_eq!(entry.contract_id, "filesystem::read_file");
    assert_eq!(
        entry.implementation_id,
        "first_party.filesystem.v1.read_file"
    );
    assert_eq!(entry.plugin_id, "first_party.filesystem");
    assert_eq!(entry.trust_tier, "first_party_signed");
    assert_eq!(entry.context_primer_level, "core");
    assert!(!entry.schema_digest.is_empty());
}

#[test]
fn registry_snapshot_projects_related_triggers_into_function_metadata() {
    let snapshot = CapabilityRegistrySnapshot::with_triggers(
        vec![session_generated_function("rwo_n7::echo", "rwo-n7-worker")],
        vec![manual_trigger(
            "manual:rwo_n7.echo",
            "rwo-n7-worker",
            "rwo_n7::echo",
        )],
        7,
    );
    let entry = snapshot
        .entries
        .iter()
        .find(|entry| entry.function_id == "rwo_n7::echo")
        .expect("entry");
    assert_eq!(
        entry.function.metadata["relatedTriggers"][0]["triggerId"],
        json!("manual:rwo_n7.echo")
    );
    assert!(entry.search_text.contains("manual:rwo_n7.echo"));
}

#[test]
fn registry_entry_surfaces_conditional_approval_metadata() {
    let mut function = test_function("process::run");
    function.effect_class = EffectClass::ExternalSideEffect;
    function.risk_level = RiskLevel::High;
    function.metadata = json!({
        "highRiskContract": {
            "conditionalApproval": {
                "owner": "process",
                "policy": "process::run command classifier",
                "approvalRequiredFor": ["destructive commands"],
                "approvalNotRequiredFor": ["date"]
            }
        }
    });
    let entry = CapabilityRegistryEntry::from_function(function, 17);
    let contract = entry.contract_record();
    let inspection = entry.inspection(CapabilityBindingDecision {
        decision_id: "binding_decision_test".to_owned(),
        contract_id: entry.contract_id.clone(),
        selected_implementation: entry.implementation_id.clone(),
        selected_function_id: entry.function_id.clone(),
        selection_policy: "test".to_owned(),
        rejected_candidates: Vec::new(),
        catalog_revision: entry.catalog_revision,
        schema_digest: entry.schema_digest.clone(),
    });

    assert_eq!(contract.approval_contract["approvalMode"], "conditional");
    assert_eq!(contract.approval_contract["approvalRequired"], false);
    assert_eq!(
        contract.approval_contract["conditionalApproval"]["policy"],
        "process::run command classifier"
    );
    assert_eq!(
        inspection.execution_requirements["approvalMode"],
        "conditional"
    );
    assert_eq!(
        inspection.execution_requirements["conditionalApproval"]["approvalNotRequiredFor"][0],
        "date"
    );
}

#[test]
fn registry_preserves_manual_conformance_state_across_resync() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    let snapshot = CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 1);
    let policy = CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    };
    let provider = HashEmbeddingProvider::new(64);
    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("initial sync");
    store
        .set_implementation_state("first_party.filesystem.v1.read_file", "disabled")
        .expect("disable implementation");
    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("resync");
    assert_eq!(
        store
            .implementation_conformance_state("first_party.filesystem.v1.read_file")
            .expect("state"),
        Some("disabled".to_owned())
    );
}

#[test]
fn registry_promotes_candidate_conformance_on_authoritative_resync() {
    let function = session_generated_function("rwo_n7::echo", "rwo-n7-worker");
    let snapshot = CapabilityRegistrySnapshot::new(vec![function], 1);
    let implementation_id = "session_generated.rwo_n7.echo";

    let mut memory_store = InMemoryCapabilityRegistryStore::default();
    sync_without_vectors(&mut memory_store, &snapshot);
    memory_store
        .set_implementation_state(implementation_id, "candidate")
        .expect("set candidate");
    sync_without_vectors(&mut memory_store, &snapshot);
    assert_eq!(
        memory_store
            .implementation_conformance_state(implementation_id)
            .expect("memory state"),
        Some("healthy".to_owned())
    );

    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut sqlite_store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    sync_without_vectors(&mut sqlite_store, &snapshot);
    sqlite_store
        .set_implementation_state(implementation_id, "candidate")
        .expect("set candidate");
    sync_without_vectors(&mut sqlite_store, &snapshot);
    assert_eq!(
        sqlite_store
            .implementation_conformance_state(implementation_id)
            .expect("sqlite state"),
        Some("healthy".to_owned())
    );
}

#[test]
fn registry_sync_removes_stale_session_generated_projection() {
    let snapshot = CapabilityRegistrySnapshot::new(
        vec![session_generated_function("rwo_n7::echo", "rwo-n7-worker")],
        1,
    );
    let empty_snapshot = CapabilityRegistrySnapshot::new(Vec::<FunctionDefinition>::new(), 2);
    let implementation_id = "session_generated.rwo_n7.echo";
    let plugin_id = "session_generated.rwo-n7-worker";

    let mut memory_store = InMemoryCapabilityRegistryStore::default();
    sync_without_vectors(&mut memory_store, &snapshot);
    assert_eq!(
        memory_store
            .implementation_conformance_state(implementation_id)
            .expect("memory state"),
        Some("healthy".to_owned())
    );
    assert!(
        memory_store
            .plugin_inspect(plugin_id)
            .expect("memory plugin inspect")
            .is_some()
    );
    sync_without_vectors(&mut memory_store, &empty_snapshot);
    assert_eq!(
        memory_store
            .implementation_conformance_state(implementation_id)
            .expect("memory state"),
        None
    );
    assert!(
        memory_store
            .plugin_inspect(plugin_id)
            .expect("memory plugin inspect")
            .is_none()
    );

    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("tron.sqlite");
    let mut sqlite_store = SqliteCapabilityRegistryStore::open(&path).expect("store");
    sync_without_vectors(&mut sqlite_store, &snapshot);
    assert_eq!(
        sqlite_store
            .implementation_conformance_state(implementation_id)
            .expect("sqlite state"),
        Some("healthy".to_owned())
    );
    assert!(
        sqlite_store
            .plugin_inspect(plugin_id)
            .expect("sqlite plugin inspect")
            .is_some()
    );
    sync_without_vectors(&mut sqlite_store, &empty_snapshot);
    assert_eq!(
        sqlite_store
            .implementation_conformance_state(implementation_id)
            .expect("sqlite state"),
        None
    );
    assert!(
        sqlite_store
            .plugin_inspect(plugin_id)
            .expect("sqlite plugin inspect")
            .is_none()
    );
}
