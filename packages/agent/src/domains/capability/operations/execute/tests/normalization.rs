use super::support::*;

#[test]
fn orchestrated_execute_removes_self_target_before_resolution() {
    for target in [
        json!("capability::execute"),
        json!({"functionId": "capability::execute"}),
        json!({"capabilityId": "capability::execute"}),
        json!({"implementationId": "function:capability::execute"}),
        json!({"implementationId": "first_party.capability.v1.execute"}),
    ] {
        let input = parse_orchestrated_execute_input(&json!({
            "intent": "read README.md lines 1 through 5",
            "target": target
        }))
        .expect("parse execute input");

        assert!(
            input.target_params.is_none(),
            "self-target should be removed before resolve"
        );
        assert!(
            input
                .corrections
                .iter()
                .any(|correction| { correction["kind"] == json!("execute_self_target_removed") })
        );
    }
}

#[test]
fn contextual_normalization_binds_current_session_id_for_session_scoped_targets() {
    let function = function_from_capability("git::list_local_branches");
    let invocation = test_invocation_with_session_context();
    let mut arguments = json!({
        "path": "/tmp/tron/.worktrees/session/sess-context"
    });
    let mut corrections = Vec::new();

    normalize_contextual_target_arguments(&function, &invocation, &mut arguments, &mut corrections);

    assert_eq!(arguments["sessionId"], json!("sess-context"));
    assert!(arguments.get("path").is_none());
    assert!(corrections.iter().any(|correction| {
        correction["kind"] == json!("runtime_session_id_to_target_argument")
    }));
    assert!(
        corrections.iter().any(|correction| {
            correction["kind"] == json!("current_worktree_path_hint_removed")
        })
    );
    let entry = CapabilityRegistryEntry::from_function(function, 391);
    validate_target_payload(&entry, &arguments)
        .expect("trusted session binding should make payload schema-valid");
}

#[test]
fn contextual_normalization_does_not_hide_arbitrary_path_arguments() {
    let function = function_from_capability("git::list_local_branches");
    let invocation = test_invocation_with_session_context();
    let mut arguments = json!({
        "path": "/tmp/other-repo"
    });
    let mut corrections = Vec::new();

    normalize_contextual_target_arguments(&function, &invocation, &mut arguments, &mut corrections);

    assert_eq!(arguments["sessionId"], json!("sess-context"));
    assert_eq!(arguments["path"], json!("/tmp/other-repo"));
    let entry = CapabilityRegistryEntry::from_function(function, 391);
    validate_target_payload(&entry, &arguments)
        .expect_err("non-current path must remain visible to schema validation");
}

#[test]
fn contextual_normalization_binds_working_directory_for_git_repo_probe() {
    let function = function_from_capability("worktree::is_git_repo");
    let invocation = test_invocation_with_session_context();
    let mut arguments = json!({});
    let mut corrections = Vec::new();

    normalize_contextual_target_arguments(&function, &invocation, &mut arguments, &mut corrections);

    assert_eq!(
        arguments["path"],
        json!("/tmp/tron/.worktrees/session/sess-context")
    );
    assert!(corrections.iter().any(|correction| {
        correction["kind"] == json!("runtime_working_directory_to_target_path")
    }));
    let entry = CapabilityRegistryEntry::from_function(function, 391);
    validate_target_payload(&entry, &arguments)
        .expect("trusted working directory should make repo probe schema-valid");
}

#[test]
fn intent_argument_normalization_binds_safe_filesystem_path_and_line_range() {
    let function = function_from_capability("filesystem::read_file");
    let mut arguments = json!({});
    let mut corrections = Vec::new();

    normalize_intent_target_arguments(
        &function,
        Some("Read only the first three lines of README.md."),
        &mut arguments,
        &mut corrections,
    );

    assert_eq!(arguments["path"], json!("README.md"));
    assert_eq!(arguments["startLine"], json!(1));
    assert_eq!(arguments["endLine"], json!(3));
    assert!(
        corrections.iter().any(|correction| {
            correction["kind"] == json!("intent_file_path_to_target_argument")
        })
    );
    assert!(corrections.iter().any(|correction| {
        correction["kind"] == json!("intent_line_bounds_to_target_arguments")
    }));
    let entry = CapabilityRegistryEntry::from_function(function, 391);
    validate_target_payload(&entry, &arguments)
        .expect("intent binding should make read_file payload schema-valid");
}

#[test]
fn deterministic_intent_route_prefers_resource_list_for_module_resource_inventory() {
    let resource_list = resource_list_function();
    let mut binding_list = FunctionDefinition::new(
        FunctionId::new("capability::binding_list").expect("function id"),
        crate::engine::WorkerId::new("capability").expect("worker id"),
        "list capability bindings",
        crate::engine::VisibilityScope::System,
        crate::engine::EffectClass::PureRead,
    );
    binding_list.description = "inspect capability registration and binding metadata".to_owned();
    let snapshot = CapabilityRegistrySnapshot::new(vec![binding_list, resource_list], 391);

    let hit = deterministic_intent_route(
        "Discover whether current engine has existing worker_package and activation_record resources by using pure-read resource listing only, and report whether full RWO-011 can proceed safely from the app without hand-authoring a manifest.",
        &json!({}),
        &snapshot,
        &json!({}),
    )
    .expect("route check")
    .expect("resource list route");

    assert_eq!(hit.function_id, "resource::list");
    assert_eq!(hit.matched_by, "deterministic_resource_inventory");
}

#[test]
fn deterministic_intent_route_prefers_operator_status_targets() {
    let snapshot = CapabilityRegistrySnapshot::new(
        vec![
            function_from_capability("filesystem::read_file"),
            function_from_capability("model::list"),
            function_from_capability("settings::get"),
            function_from_capability("logs::recent"),
            observability_metrics_function(),
        ],
        391,
    );

    let cases = [
        (
            "Report the current model/provider status without running shell or mutating anything.",
            "model::list",
        ),
        (
            "Report the current settings summary without mutating settings.",
            "settings::get",
        ),
        (
            "Report the recent server/event/log count from pure-read capabilities.",
            "logs::recent",
        ),
        (
            "Do not mutate settings, state, resources, files, prompts, or memory. Use the canonical pure-read logs capability to fetch recent server/app logs.",
            "logs::recent",
        ),
        (
            "Report the current engine metrics count from pure-read observability.",
            "observability::metrics_snapshot",
        ),
    ];
    for (intent, expected) in cases {
        let hit = deterministic_intent_route(intent, &json!({}), &snapshot, &json!({}))
            .expect("route check")
            .unwrap_or_else(|| panic!("expected route for {intent}"));
        assert_eq!(hit.function_id, expected);
        assert_eq!(hit.matched_by, "deterministic_operator_status");
    }
}

#[test]
fn intent_argument_normalization_binds_module_resource_kind_for_resource_list() {
    let function = resource_list_function();
    let mut arguments = json!({});
    let mut corrections = Vec::new();

    normalize_intent_target_arguments(
        &function,
        Some("List existing module_package resources."),
        &mut arguments,
        &mut corrections,
    );

    assert_eq!(arguments["kind"], json!(WORKER_PACKAGE_KIND));
    assert!(corrections.iter().any(|correction| {
        correction["kind"] == json!("intent_resource_kind_to_target_argument")
    }));
    let entry = CapabilityRegistryEntry::from_function(function, 391);
    validate_target_payload(&entry, &arguments)
        .expect("intent binding should make resource::list payload schema-valid");
}

#[test]
fn multi_resource_kind_inventory_requires_decomposition() {
    let target = resolved_target_for(resource_list_function());
    let resolve = OrchestrationResolve {
        target_params: json!({"functionId": "resource::list"}),
        mode: "intent_resolution".to_owned(),
        candidates: Vec::new(),
        rejected_candidates: Vec::new(),
        search_status: Value::Null,
    };

    let details = decomposition_phase_details(
        &resolve,
        &target,
        Some("List existing module_package and module_activation resources."),
        &json!({}),
    )
    .expect("resource inventory should decompose by kind");

    assert_eq!(
        details["decomposition"]["reason"],
        json!("multiple_resource_kinds_for_single_inventory_request")
    );
    assert_eq!(
        details["suggestedCalls"][0]["target"],
        json!("resource::list")
    );
    assert_eq!(
        details["suggestedCalls"][0]["arguments"]["kind"],
        json!(WORKER_PACKAGE_KIND)
    );
    assert_eq!(
        details["suggestedCalls"][1]["arguments"]["kind"],
        json!(ACTIVATION_RECORD_KIND)
    );
}

#[test]
fn intent_argument_normalization_binds_explicit_line_range() {
    let function = function_from_capability("filesystem::read_file");
    let mut arguments = json!({});
    let mut corrections = Vec::new();

    normalize_intent_target_arguments(
        &function,
        Some(
            "Read packages/agent/docs/capability-orchestration-test-scorecard.md lines 1 through 20.",
        ),
        &mut arguments,
        &mut corrections,
    );

    assert_eq!(
        arguments["path"],
        json!("packages/agent/docs/capability-orchestration-test-scorecard.md")
    );
    assert_eq!(arguments["startLine"], json!(1));
    assert_eq!(arguments["endLine"], json!(20));
    assert!(corrections.iter().any(|correction| {
        correction["kind"] == json!("intent_line_bounds_to_target_arguments")
    }));
    let entry = CapabilityRegistryEntry::from_function(function, 391);
    validate_target_payload(&entry, &arguments)
        .expect("explicit line range should make read_file payload schema-valid");
}

#[test]
fn multi_file_read_intent_requires_decomposition_instead_of_partial_binding() {
    let function = function_from_capability("filesystem::read_file");
    let intent = "Read packages/agent/docs/capability-orchestration-test-scorecard.md lines 1 through 20, read README.md lines 1 through 5.";
    let requests = intent_file_read_requests(intent);

    assert_eq!(requests.len(), 2);
    assert_eq!(
        requests[0],
        IntentFileReadRequest {
            path: "packages/agent/docs/capability-orchestration-test-scorecard.md".to_owned(),
            start_line: Some(1),
            end_line: Some(20),
        }
    );
    assert_eq!(
        requests[1],
        IntentFileReadRequest {
            path: "README.md".to_owned(),
            start_line: Some(1),
            end_line: Some(5),
        }
    );

    let mut arguments = json!({});
    let mut corrections = Vec::new();
    normalize_intent_target_arguments(&function, Some(intent), &mut arguments, &mut corrections);

    assert_eq!(
        arguments,
        json!({}),
        "multi-target intent must not silently bind only the first path"
    );
    assert!(corrections.is_empty());
    assert!(!orchestration_status_is_error("needs_decomposition"));
}

#[test]
fn multi_file_read_intent_splits_conjunction_line_bounds_per_target() {
    let intent = "Read packages/agent/docs/capability-orchestration-test-scorecard.md lines 1 through 20 and read README.md lines 1 through 5.";
    let requests = intent_file_read_requests(intent);

    assert_eq!(
        requests,
        vec![
            IntentFileReadRequest {
                path: "packages/agent/docs/capability-orchestration-test-scorecard.md".to_owned(),
                start_line: Some(1),
                end_line: Some(20),
            },
            IntentFileReadRequest {
                path: "README.md".to_owned(),
                start_line: Some(1),
                end_line: Some(5),
            }
        ]
    );
}

#[test]
fn decomposition_result_message_surfaces_suggested_calls_in_content() {
    let details = json!({
        "suggestedCalls": [
            {
                "target": "filesystem::read_file",
                "arguments": {
                    "path": "packages/agent/docs/capability-orchestration-test-scorecard.md",
                    "startLine": 1,
                    "endLine": 20
                }
            },
            {
                "target": "filesystem::read_file",
                "arguments": {
                    "path": "README.md",
                    "startLine": 1,
                    "endLine": 5
                }
            }
        ]
    });

    let message = decomposition_result_message(&details);

    assert!(message.contains("Suggested execute calls:"));
    assert!(message.contains("target=filesystem::read_file"));
    assert!(message.contains("\"path\":\"README.md\""));
    assert!(message.contains("\"endLine\":5"));
}

#[test]
fn intent_argument_normalization_rejects_unsafe_paths_from_intent() {
    let function = function_from_capability("filesystem::read_file");
    let unsafe_intents = [
        "Read the first line of /etc/passwd.",
        "Read the first line of ../README.md.",
        "Read the first line of https://example.com/README.md.",
        "Read the first line of README.md;rm.",
    ];

    for intent in unsafe_intents {
        let mut arguments = json!({});
        let mut corrections = Vec::new();

        normalize_intent_target_arguments(
            &function,
            Some(intent),
            &mut arguments,
            &mut corrections,
        );

        assert!(
            arguments.get("path").is_none(),
            "unsafe intent should not bind a path: {intent}"
        );
        assert!(corrections.is_empty());
    }
}
