use super::support::*;

#[test]
fn search_hits_persist_agent_recipe_in_index_documents() {
    let notification_spec = crate::domains::notifications::contract::capabilities()
        .expect("notification specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "notifications::send")
        .expect("notifications::send spec");
    let function = crate::domains::contract::function_definition_for_capability(&notification_spec);
    let entry = CapabilityRegistryEntry::from_function(function, 12);
    let document = entry.search_document();
    let recipe = document.recipe.as_ref().expect("recipe");

    assert_eq!(recipe.contract_id, "notifications::send");
    assert!(
        recipe
            .required_payload
            .iter()
            .any(|field| field.starts_with("title:"))
    );
    assert!(
        recipe
            .required_payload
            .iter()
            .any(|field| field.starts_with("body:"))
    );
    assert_eq!(
        recipe.execute_template["arguments"]["title"],
        json!("Tron test")
    );
}

#[test]
fn hybrid_index_reports_vector_hits_in_tests() {
    let docs = vec![
        CapabilityRegistryEntry::from_function(test_function("filesystem::read_file"), 1)
            .search_document(),
        CapabilityRegistryEntry::from_function(test_function("process::run"), 1).search_document(),
    ];
    let result = HybridLocalCapabilityIndex::new(CapabilitySearchPolicy::default())
        .search("read path", docs, 10)
        .expect("search");
    assert!(result.status.local_vector);
    assert_eq!(result.status.state, "ready");
    assert_eq!(result.hits[0].function_id, "filesystem::read_file");
    assert!(result.hits[0].vector_score.is_some());
}

#[test]
fn search_kind_function_matches_runnable_implementations() {
    let snapshot = CapabilityRegistrySnapshot::new(vec![test_function("process::run")], 1);
    let mut store = InMemoryCapabilityRegistryStore::default();
    let provider = HashEmbeddingProvider::new(64);
    let policy = CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    };
    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("sync");
    let results = store
        .search(
            "process run",
            &CapabilitySearchFilters {
                kind: Some("function".to_owned()),
                include_unavailable: true,
                ..CapabilitySearchFilters::default()
            },
            &policy,
            10,
            &provider,
        )
        .expect("search");
    assert!(
        results
            .hits
            .iter()
            .any(|hit| { hit.kind == "implementation" && hit.function_id == "process::run" }),
        "function searches should include runnable implementation documents"
    );
}

#[test]
fn search_relaxes_risk_filter_after_zero_discovery_hits() {
    let mut process_function = test_function("process::run");
    process_function.effect_class = EffectClass::ExternalSideEffect;
    process_function.risk_level = RiskLevel::High;
    let snapshot = CapabilityRegistrySnapshot::new(vec![process_function], 1);
    let mut store = InMemoryCapabilityRegistryStore::default();
    let provider = HashEmbeddingProvider::new(64);
    let policy = CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    };
    store
        .sync_snapshot(&snapshot, &provider, &policy)
        .expect("sync");

    let result = store
        .search(
            "process run shell command date",
            &CapabilitySearchFilters {
                kind: Some("contract".to_owned()),
                risk_max: Some(RiskLevel::Low),
                ..CapabilitySearchFilters::default()
            },
            &policy,
            10,
            &provider,
        )
        .expect("search");

    assert!(
        result
            .hits
            .iter()
            .any(|hit| hit.contract_id == "process::run"),
        "search should still explain the shell capability even when a discovery risk filter is too narrow"
    );
    assert!(
        result
            .status
            .degraded_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("riskMax relaxed"))
    );
}

#[test]
fn strict_registry_sync_returns_explicit_index_unavailable() {
    let snapshot = CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 1);
    let mut store = InMemoryCapabilityRegistryStore::default();
    let strict_policy = CapabilitySearchPolicy {
        require_local_vector: true,
        allow_lexical_only_when_degraded: false,
        ..CapabilitySearchPolicy::default()
    };
    let error = store
        .sync_snapshot(&snapshot, &FailingEmbeddingProvider, &strict_policy)
        .expect_err("strict vector policy must fail");
    assert!(error.starts_with("CAPABILITY_INDEX_UNAVAILABLE:"));
}

#[test]
fn degraded_policy_allows_lexical_only_with_status_reason() {
    let snapshot = CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 1);
    let mut store = InMemoryCapabilityRegistryStore::default();
    let policy = CapabilitySearchPolicy {
        require_local_vector: false,
        allow_lexical_only_when_degraded: true,
        ..CapabilitySearchPolicy::default()
    };
    let status = store
        .sync_snapshot(&snapshot, &FailingEmbeddingProvider, &policy)
        .expect("degraded sync");
    assert_eq!(status.state, "unavailable");
    assert_eq!(
        status.degraded_reason.as_deref(),
        Some("embedding assets unavailable")
    );
}
