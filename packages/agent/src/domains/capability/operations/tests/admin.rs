use super::support::*;

#[test]
fn agent_search_requires_profile_policy_runtime_metadata() {
    let causal = CausalContext::new(
        crate::engine::ActorId::new("agent:s1").expect("actor id"),
        ActorKind::Agent,
        AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
        crate::engine::TraceId::new("trace").expect("trace id"),
    );
    let invocation = Invocation::new_sync(
        FunctionId::new("capability::search").expect("function id"),
        json!({"query": "read"}),
        causal,
    );
    let error = search_policy_from_runtime(&invocation).unwrap_err();
    assert!(matches!(
        error,
        CapabilityError::Custom { code, .. } if code == "CAPABILITY_SEARCH_POLICY_REQUIRED"
    ));
}

#[test]
fn agent_search_uses_internal_profile_policy_metadata() {
    let policy = CapabilitySearchPolicy {
        require_local_vector: false,
        allow_lexical_only_when_degraded: true,
        ..CapabilitySearchPolicy::default()
    };
    let causal = CausalContext::new(
        crate::engine::ActorId::new("agent:s1").expect("actor id"),
        ActorKind::Agent,
        AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
        crate::engine::TraceId::new("trace").expect("trace id"),
    )
    .with_runtime_metadata(
        "capability.searchPolicy",
        serde_json::to_string(&policy).expect("policy json"),
    );
    let invocation = Invocation::new_sync(
        FunctionId::new("capability::search").expect("function id"),
        json!({"query": "read"}),
        causal,
    );
    let parsed = search_policy_from_runtime(&invocation).expect("policy");
    assert!(!parsed.require_local_vector);
    assert!(parsed.allow_lexical_only_when_degraded);
}

#[test]
fn operator_vector_warmup_policy_allows_visible_degradation() {
    let policy = registry_operator_sync_policy();

    assert!(policy.local_vector);
    assert!(!policy.require_local_vector);
    assert!(policy.allow_lexical_only_when_degraded);
    assert!(allows_degraded_vector_search(&policy));
}

#[test]
fn vector_warmup_status_detects_incomplete_indexes() {
    let ready = CapabilityIndexStatus {
        lexical: true,
        local_vector: true,
        cloud_embeddings: false,
        vector_store: "sqlite-vec".to_owned(),
        embedding_model: "test".to_owned(),
        state: "ready".to_owned(),
        degraded_reason: None,
    };
    assert!(!index_status_needs_vector_warmup(&ready));

    let indexing = CapabilityIndexStatus {
        state: "indexing".to_owned(),
        degraded_reason: Some(
            "CAPABILITY_INDEX_INDEXING: local vector index has 606/716 current documents"
                .to_owned(),
        ),
        ..ready.clone()
    };
    assert!(index_status_needs_vector_warmup(&indexing));

    let stale_ready_metadata = CapabilityIndexStatus {
        degraded_reason: Some(
            "CAPABILITY_INDEX_INDEXING: local vector index has 606/716 current documents"
                .to_owned(),
        ),
        ..ready
    };
    assert!(index_status_needs_vector_warmup(&stale_ready_metadata));
}

#[test]
fn vector_warmup_signature_changes_when_documents_change_without_catalog_revision() {
    let first = CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 7);
    let second = CapabilityRegistrySnapshot::new(
        vec![
            test_function("filesystem::read_file"),
            test_function("filesystem::search_text"),
        ],
        7,
    );

    assert_ne!(
        vector_warmup_signature(&first),
        vector_warmup_signature(&second)
    );
}

#[test]
fn binding_resolution_sync_stays_metadata_only() {
    let policy = registry_metadata_sync_policy();

    assert!(!policy.local_vector);
    assert!(!policy.require_local_vector);
}

#[test]
fn search_metadata_sync_runs_only_for_empty_or_changed_catalog() {
    let current = json!({
        "catalogRevision": 42,
        "documents": 178,
    });
    assert!(!registry_needs_metadata_sync(&current, 42));

    let changed = json!({
        "catalogRevision": 41,
        "documents": 178,
    });
    assert!(registry_needs_metadata_sync(&changed, 42));

    let empty = json!({
        "catalogRevision": 42,
        "documents": 0,
    });
    assert!(registry_needs_metadata_sync(&empty, 42));
}

#[test]
fn plugin_manifest_validation_rejects_reserved_namespace_claims() {
    let manifest = CapabilityPluginManifest {
        id: "external.test".to_owned(),
        name: "Test".to_owned(),
        version: "1.0.0".to_owned(),
        publisher: "test".to_owned(),
        signature_status: "unsigned".to_owned(),
        runtime: "mcp".to_owned(),
        namespace_claims: vec!["capability".to_owned()],
        provided_contracts: vec!["capability::status".to_owned()],
        provided_implementations: vec!["capability.status.impl".to_owned()],
        requested_authorities: Vec::new(),
        trust_tier: "external_mcp".to_owned(),
        visibility_ceiling: "session".to_owned(),
        conformance_state: "candidate".to_owned(),
        docs: json!({}),
        examples: Vec::new(),
        search_metadata: json!({}),
    };
    let error = validate_plugin_manifest(&manifest).unwrap_err();
    assert!(matches!(error, CapabilityError::InvalidParams { .. }));
}

#[test]
fn policy_validation_reports_structured_errors_without_updating() {
    let validation = validate_capability_execution_policy_payload(json!({
        "allowedContracts": "filesystem::read_file"
    }));
    assert_eq!(validation["valid"], json!(false));
    assert!(
        validation["errors"]
            .as_array()
            .is_some_and(|errors| !errors.is_empty())
    );
}
