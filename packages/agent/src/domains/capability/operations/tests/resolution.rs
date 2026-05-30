use super::support::*;

#[test]
fn intent_strong_name_match_breaks_near_score_filesystem_ties() {
    let read = CapabilityIndexHit {
        kind: "implementation".to_owned(),
        capability_id: "filesystem::read_file".to_owned(),
        contract_id: "filesystem::read_file".to_owned(),
        implementation_id: "first_party.filesystem.v1.read_file".to_owned(),
        plugin_id: "first_party.filesystem".to_owned(),
        worker_id: "filesystem".to_owned(),
        function_id: "filesystem::read_file".to_owned(),
        catalog_revision: 1,
        schema_digest: "digest-read".to_owned(),
        trust_tier: "first_party_signed".to_owned(),
        health: "Healthy".to_owned(),
        visibility: "system".to_owned(),
        effect_class: "pure_read".to_owned(),
        risk_level: "low".to_owned(),
        lexical_score: 1.0,
        vector_score: Some(0.1),
        fused_score: 0.09,
        matched_by: "hybrid_local".to_owned(),
        snippet: "read a file".to_owned(),
        requires_inspect: false,
        recipe: None,
    };
    let list = CapabilityIndexHit {
        contract_id: "filesystem::list_dir".to_owned(),
        function_id: "filesystem::list_dir".to_owned(),
        implementation_id: "first_party.filesystem.v1.list_dir".to_owned(),
        capability_id: "filesystem::list_dir".to_owned(),
        schema_digest: "digest-list".to_owned(),
        snippet: "list a directory".to_owned(),
        ..read.clone()
    };

    assert!(intent_strongly_matches_hit(
        "Use the filesystem read file capability to read a file",
        &read
    ));
    assert!(!intent_strongly_matches_hit(
        "Use the filesystem read file capability to read a file",
        &list
    ));
}

#[test]
fn low_confidence_unanchored_intent_is_not_treated_as_selection() {
    let hit = CapabilityIndexHit {
        kind: "implementation".to_owned(),
        capability_id: "module::verify_source".to_owned(),
        contract_id: "module::verify_source".to_owned(),
        implementation_id: "first_party.module.v1.verify_source".to_owned(),
        plugin_id: "first_party.module".to_owned(),
        worker_id: "module".to_owned(),
        function_id: "module::verify_source".to_owned(),
        catalog_revision: 1,
        schema_digest: "digest".to_owned(),
        trust_tier: "first_party_signed".to_owned(),
        health: "Healthy".to_owned(),
        visibility: "system".to_owned(),
        effect_class: "idempotent_write".to_owned(),
        risk_level: "medium".to_owned(),
        lexical_score: 0.01,
        vector_score: Some(0.07),
        fused_score: 0.07,
        matched_by: "hybrid_local".to_owned(),
        snippet: "verify package source refs".to_owned(),
        requires_inspect: false,
        recipe: None,
    };

    assert!(lacks_sufficient_intent_resolution_evidence(
        "calibrate the starship warp-core coolant pump",
        &json!({}),
        &hit
    ));

    let anchored_arguments = json!({"expectedCurrentVersionId": "ver_test"});
    assert!(!lacks_sufficient_intent_resolution_evidence(
        "verify source",
        &anchored_arguments,
        &hit
    ));
}

#[test]
fn high_score_lexical_noise_without_anchor_is_not_treated_as_selection() {
    let hit = CapabilityIndexHit {
        kind: "implementation".to_owned(),
        capability_id: "module::run_conformance".to_owned(),
        contract_id: "module::run_conformance".to_owned(),
        implementation_id: "first_party.module.v1.run_conformance".to_owned(),
        plugin_id: "first_party.module".to_owned(),
        worker_id: "module".to_owned(),
        function_id: "module::run_conformance".to_owned(),
        catalog_revision: 1,
        schema_digest: "digest".to_owned(),
        trust_tier: "first_party_signed".to_owned(),
        health: "Healthy".to_owned(),
        visibility: "system".to_owned(),
        effect_class: "idempotent_write".to_owned(),
        risk_level: "medium".to_owned(),
        lexical_score: 11.17,
        vector_score: None,
        fused_score: 11.17,
        matched_by: "local_lexical".to_owned(),
        snippet: "record bounded package runtime conformance evidence".to_owned(),
        requires_inspect: false,
        recipe: None,
    };

    assert!(lacks_sufficient_intent_resolution_evidence(
        "calibrate warp-core coolant harmonics for a starship drive",
        &json!({}),
        &hit
    ));
}

#[test]
fn vague_known_namespace_intent_returns_clarification_candidates() {
    let read = test_function("filesystem::read_file");
    let search = test_function("filesystem::search_text");
    let process = test_function("process::run");
    let execute = test_function("capability::execute");
    let snapshot = CapabilityRegistrySnapshot::new(vec![process, execute, search, read], 11);

    let candidates = clarification_candidates_for_intent(
        "do something useful with files",
        &snapshot,
        &json!({}),
    )
    .expect("clarification")
    .expect("filesystem candidates");

    assert!(
        candidates
            .iter()
            .any(|candidate| candidate["functionId"] == json!("filesystem::read_file"))
    );
    assert!(
        candidates
            .iter()
            .any(|candidate| candidate["functionId"] == json!("filesystem::search_text"))
    );
    assert!(
        candidates
            .iter()
            .all(|candidate| candidate["functionId"] != json!("process::run"))
    );
    assert!(
        candidates
            .iter()
            .all(|candidate| candidate["functionId"] != json!("capability::execute"))
    );
    assert!(candidates.iter().all(|candidate| {
        candidate["matchedBy"] == json!("namespace_clarification")
            && candidate["score"].as_f64().is_some_and(|score| score > 0.0)
    }));
}

#[test]
fn deterministic_intent_route_prefers_filesystem_read_for_path_arguments() {
    let read = test_function("filesystem::read_file");
    let mut stop = test_function("sandbox::stop_spawned_worker");
    stop.effect_class = EffectClass::ExternalSideEffect;
    stop.risk_level = RiskLevel::High;
    let snapshot = CapabilityRegistrySnapshot::new(vec![stop, read], 7);

    let hit = deterministic_intent_route(
        "Read the first 3 lines of README.md from the current workspace.",
        &json!({"path": "README.md", "startLine": 1, "endLine": 3}),
        &snapshot,
        &json!({}),
    )
    .expect("route check")
    .expect("filesystem read route");

    assert_eq!(hit.function_id, "filesystem::read_file");
    assert_eq!(hit.matched_by, "deterministic_path_read");
    assert!(hit.fused_score > 10.0);
}

#[test]
fn deterministic_intent_route_prefers_filesystem_read_for_path_in_intent() {
    let read = test_function("filesystem::read_file");
    let mut stop = test_function("sandbox::stop_spawned_worker");
    stop.effect_class = EffectClass::ExternalSideEffect;
    stop.risk_level = RiskLevel::High;
    let snapshot = CapabilityRegistrySnapshot::new(vec![stop, read], 7);

    let hit = deterministic_intent_route(
        "Read only the first line of README.md.",
        &json!({}),
        &snapshot,
        &json!({}),
    )
    .expect("route check")
    .expect("filesystem read route");

    assert_eq!(hit.function_id, "filesystem::read_file");
    assert_eq!(hit.matched_by, "deterministic_path_read");
}

#[test]
fn deterministic_intent_route_preempts_bad_search_ranking() {
    let read = test_function("filesystem::read_file");
    let mut stop = test_function("sandbox::stop_spawned_worker");
    stop.effect_class = EffectClass::ExternalSideEffect;
    stop.risk_level = RiskLevel::High;
    let snapshot = CapabilityRegistrySnapshot::new(vec![stop.clone(), read], 7);
    let mut hits = vec![orchestration_hit_from_entry(
        &CapabilityRegistryEntry::from_function(stop, 7),
        "local_lexical",
        7.8,
    )];

    apply_deterministic_intent_route(
        "Read the first 3 lines of README.md from the current workspace.",
        &json!({"path": "README.md", "startLine": 1, "endLine": 3}),
        &snapshot,
        &json!({}),
        &mut hits,
    )
    .expect("route applied");

    assert_eq!(hits[0].function_id, "filesystem::read_file");
    assert_eq!(hits[1].function_id, "sandbox::stop_spawned_worker");
}

#[test]
fn deterministic_intent_route_respects_constraints_and_write_intents() {
    let read = test_function("filesystem::read_file");
    let snapshot = CapabilityRegistrySnapshot::new(vec![read], 7);

    let write_intent = deterministic_intent_route(
        "Write the first 3 lines to README.md.",
        &json!({"path": "README.md"}),
        &snapshot,
        &json!({}),
    )
    .expect("route check");
    assert!(write_intent.is_none());

    let constrained_out = deterministic_intent_route(
        "Read the first 3 lines of README.md.",
        &json!({"path": "README.md"}),
        &snapshot,
        &json!({"allowedNamespaces": ["sandbox"]}),
    )
    .expect("route check");
    assert!(constrained_out.is_none());
}

#[test]
fn orchestration_constraints_reject_broader_or_unsupported_targets() {
    let mut function = test_function("process::run");
    function.effect_class = EffectClass::ExternalSideEffect;
    function.risk_level = RiskLevel::High;
    let entry = CapabilityRegistryEntry::from_function(function, 4);

    validate_orchestration_constraints(
        &json!({
            "riskMax": "high",
            "effect": "external_side_effect",
            "allowedContracts": ["process::run"],
            "allowedNamespaces": ["process"]
        }),
        &entry,
    )
    .expect("covered constraints");

    let risk_error = validate_orchestration_constraints(&json!({"riskMax": "medium"}), &entry)
        .expect_err("risk rejected");
    assert!(risk_error.to_string().contains("above constraint riskMax"));

    let contract_error = validate_orchestration_constraints(
        &json!({"allowedContracts": ["filesystem::read_file"]}),
        &entry,
    )
    .expect_err("contract rejected");
    assert!(
        contract_error
            .to_string()
            .contains("outside execute.constraints.allowedContracts")
    );

    let unsupported_error =
        validate_orchestration_constraints(&json!({"networkPolicy": "none"}), &entry)
            .expect_err("unsupported rejected");
    assert!(
        unsupported_error
            .to_string()
            .contains("Unsupported execute.constraints field")
    );

    let typed_error = validate_orchestration_constraints(&json!({"riskMax": 1}), &entry)
        .expect_err("typed risk rejected");
    assert!(typed_error.to_string().contains("riskMax must be"));
}

#[test]
fn orchestration_constraint_shape_rejects_malformed_values_before_resolution() {
    let unsupported = validate_orchestration_constraint_shape(&json!({"networkPolicy": "none"}))
        .expect_err("unsupported rejected");
    assert!(
        unsupported
            .to_string()
            .contains("Unsupported execute.constraints field")
    );

    let bad_risk = validate_orchestration_constraint_shape(&json!({"riskMax": "impossible"}))
        .expect_err("risk rejected");
    assert!(bad_risk.to_string().contains("Unsupported riskMax"));

    let bad_namespaces =
        validate_orchestration_constraint_shape(&json!({"allowedNamespaces": ["filesystem", 1]}))
            .expect_err("namespace rejected");
    assert!(
        bad_namespaces
            .to_string()
            .contains("allowedNamespaces must contain only non-empty strings")
    );
}

#[test]
fn orchestration_constraints_filter_resolution_candidates() {
    let read_hit = CapabilityIndexHit {
        kind: "implementation".to_owned(),
        capability_id: "filesystem::read_file".to_owned(),
        contract_id: "filesystem::read_file".to_owned(),
        implementation_id: "first_party.filesystem.v1.read_file".to_owned(),
        plugin_id: "first_party.filesystem".to_owned(),
        worker_id: "filesystem".to_owned(),
        function_id: "filesystem::read_file".to_owned(),
        catalog_revision: 1,
        schema_digest: "digest-read".to_owned(),
        trust_tier: "first_party_signed".to_owned(),
        health: "Healthy".to_owned(),
        visibility: "system".to_owned(),
        effect_class: "pure_read".to_owned(),
        risk_level: "low".to_owned(),
        lexical_score: 1.0,
        vector_score: Some(0.1),
        fused_score: 0.9,
        matched_by: "hybrid_local".to_owned(),
        snippet: "read a file".to_owned(),
        requires_inspect: false,
        recipe: None,
    };
    let process_hit = CapabilityIndexHit {
        contract_id: "process::run".to_owned(),
        function_id: "process::run".to_owned(),
        implementation_id: "first_party.process.v1.run".to_owned(),
        capability_id: "process::run".to_owned(),
        schema_digest: "digest-process".to_owned(),
        effect_class: "external_side_effect".to_owned(),
        risk_level: "high".to_owned(),
        snippet: "run a process".to_owned(),
        ..read_hit.clone()
    };

    let constraints = json!({
        "riskMax": "low",
        "effect": "pure_read",
        "allowedNamespaces": ["filesystem"]
    });
    assert!(
        orchestration_constraints_allow_hit(&constraints, &read_hit).expect("read constraints")
    );
    assert!(
        !orchestration_constraints_allow_hit(&constraints, &process_hit)
            .expect("process constraints")
    );
}

#[test]
fn deterministic_route_prefers_worktree_diff_for_current_diff_intent() {
    let functions = crate::domains::worktree::contract::capabilities()
        .expect("worktree specs")
        .into_iter()
        .map(|spec| crate::domains::contract::function_definition_for_capability(&spec))
        .collect::<Vec<_>>();
    let snapshot = CapabilityRegistrySnapshot::new(functions, 392);

    let hit = deterministic_intent_route(
        "Report the current git worktree diff summary without shell commands.",
        &json!({}),
        &snapshot,
        &json!({}),
    )
    .expect("route")
    .expect("worktree diff route");

    assert_eq!(hit.function_id, "worktree::get_diff");
    assert_eq!(hit.matched_by, "deterministic_worktree_diff");
}

#[test]
fn orchestration_argument_filter_prefers_candidate_that_accepts_supplied_arguments() {
    let functions = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .filter(|spec| {
            matches!(
                spec.function_id.as_str(),
                "filesystem::search_text" | "filesystem::glob"
            )
        })
        .map(|spec| crate::domains::contract::function_definition_for_capability(&spec))
        .collect::<Vec<_>>();
    let snapshot = CapabilityRegistrySnapshot::new(functions, 42);
    let mut hits = snapshot
        .entries
        .iter()
        .map(|entry| orchestration_hit_from_entry(entry, "hybrid_local", 0.09))
        .collect::<Vec<_>>();
    hits.sort_by(|left, right| left.function_id.cmp(&right.function_id));

    let rejected = apply_argument_schema_fit_filter(
        &json!({
            "pattern": "Testing out",
            "path": ".",
            "filePattern": "README.md",
            "maxResults": 5
        }),
        &snapshot,
        &mut hits,
    );

    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].function_id, "filesystem::search_text");
    assert!(
        rejected.iter().any(|candidate| {
            candidate["functionId"] == json!("filesystem::glob")
                && candidate["rejectionReason"] == json!("argument_schema_mismatch")
        }),
        "glob should not remain ambiguous when filePattern proves search_text"
    );
}

#[test]
fn orchestration_argument_filter_uses_target_specific_normalization() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let read_spec = crate::domains::filesystem::contract::capabilities()
        .expect("filesystem specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "filesystem::read_file")
        .expect("filesystem::read_file spec");
    let snapshot = CapabilityRegistrySnapshot::new(
        vec![
            crate::domains::contract::function_definition_for_capability(&process_spec),
            crate::domains::contract::function_definition_for_capability(&read_spec),
        ],
        43,
    );
    let mut hits = snapshot
        .entries
        .iter()
        .map(|entry| orchestration_hit_from_entry(entry, "hybrid_local", 0.09))
        .collect::<Vec<_>>();
    hits.sort_by(|left, right| left.function_id.cmp(&right.function_id));

    let rejected = apply_argument_schema_fit_filter(
        &json!({
            "command": "printf hi > out.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputPaths": ["out.txt"]
        }),
        &snapshot,
        &mut hits,
    );

    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].function_id, "process::run");
    assert!(
        rejected.iter().any(|candidate| {
            candidate["functionId"] == json!("filesystem::read_file")
                && candidate["rejectionReason"] == json!("argument_missing_required")
        }),
        "read_file should not remain ambiguous when process aliases normalize cleanly"
    );
}

#[test]
fn orchestration_argument_fit_promotes_schema_match_missing_from_search_hits() {
    let process_spec = crate::domains::process::contract::capabilities()
        .expect("process specs")
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .expect("process::run spec");
    let mut unrelated = test_function("job::stream_output");
    unrelated.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["jobId"],
        "properties": {
            "jobId": {"type": "string"},
            "offset": {"type": "integer"}
        }
    }));
    let snapshot = CapabilityRegistrySnapshot::new(
        vec![
            unrelated.clone(),
            crate::domains::contract::function_definition_for_capability(&process_spec),
        ],
        44,
    );
    let mut hits = vec![orchestration_hit_from_entry(
        &CapabilityRegistryEntry::from_function(unrelated, 44),
        "hybrid_local",
        0.09,
    )];

    promote_argument_schema_fit_candidates(
        &json!({
            "command": "date",
            "executionMode": "read_only"
        }),
        &snapshot,
        &json!({}),
        &mut hits,
    )
    .expect("promotion");
    let rejected = apply_argument_schema_fit_filter(
        &json!({
            "command": "date",
            "executionMode": "read_only"
        }),
        &snapshot,
        &mut hits,
    );

    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].function_id, "process::run");
    assert_eq!(hits[0].matched_by, "argument_schema_fit");
    assert!(
        rejected.iter().any(|candidate| {
            candidate["functionId"] == json!("job::stream_output")
                && candidate["rejectionReason"] == json!("argument_missing_required")
        }),
        "search hits that do not accept the supplied arguments must be rejected"
    );
}
