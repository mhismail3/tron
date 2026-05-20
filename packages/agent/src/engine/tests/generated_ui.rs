use super::*;

fn generated_surface_request(target_type: &str, target_id: &str) -> Value {
    json!({
        "targetType": target_type,
        "targetId": target_id,
        "purpose": "Inspect substrate target",
        "layoutProfile": "compact",
        "maxPreviewBytes": 512,
        "expiresAt": "2100-01-01T00:00:00Z"
    })
}

fn generated_prompt_collection_request(layout_profile: &str, target_id: &str) -> Value {
    json!({
        "targetType": "resource_collection",
        "targetId": target_id,
        "purpose": "Manage prompt library resources",
        "layoutProfile": layout_profile,
        "maxPreviewBytes": 512,
        "expiresAt": "2100-01-01T00:00:00Z"
    })
}

fn prompt_ui_context(key: &str) -> CausalContext {
    mutating_causal(key)
        .with_scope("ui.write")
        .with_scope("prompt_library.read")
        .with_scope("prompt_library.write")
}

fn sessionless_prompt_ui_context(key: &str) -> CausalContext {
    causal()
        .with_idempotency_key(key)
        .with_scope("ui.write")
        .with_scope("prompt_library.read")
        .with_scope("prompt_library.write")
}

fn prompt_write_context(key: &str) -> CausalContext {
    mutating_causal(key).with_scope("prompt_library.write")
}

fn prompt_internal_write_context(key: &str) -> CausalContext {
    prompt_write_context(key).with_scope(crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE)
}

#[tokio::test]
async fn ui_surface_resource_type_is_registered_and_validated() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let snapshot = handle
        .invoke(host_invocation(
            "control::snapshot",
            json!({"limit": 25}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(snapshot.error, None);
    assert!(
        snapshot.value.as_ref().unwrap()["resourceTypes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|resource_type| resource_type["kind"] == "ui_surface")
    );

    let invalid = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "ui_surface",
                "resourceId": "bad-ui-surface",
                "payload": {
                    "surfaceId": "bad",
                    "title": "Bad",
                    "purpose": "Reject unknown catalog",
                    "catalog": {"id": "tron.ui.catalog.unknown.v1", "revision": 1},
                    "layout": {"type": "Text", "props": {"text": "bad"}},
                    "bindings": [],
                    "actions": [],
                    "redactionPolicy": {"mode": "redacted"},
                    "expiresAt": "2100-01-01T00:00:00Z",
                    "refreshPolicy": {"mode": "manual"}
                }
            }),
            mutating_causal("ui-surface-invalid").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        invalid.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("catalog")
    ));

    let mut invalid_placeholder = valid_ui_surface("demo::inspect", 1);
    invalid_placeholder["actions"][0]["payloadTemplate"]["message"] = json!("${input.missing}");
    let invalid_placeholder_result = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "ui_surface",
                "resourceId": "bad-ui-placeholder",
                "payload": invalid_placeholder
            }),
            mutating_causal("bad-ui-placeholder").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        invalid_placeholder_result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("unknown input field")
    ));

    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-registered",
                "surface": valid_ui_surface("demo::inspect", 1)
            }),
            mutating_causal("ui-surface-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let value = created.value.as_ref().unwrap();
    assert_eq!(value["resourceRefs"][0]["kind"], "ui_surface");
    assert_eq!(value["resource"]["kind"], "ui_surface");
    assert_eq!(value["resource"]["lifecycle"], "active");
}

#[tokio::test]
async fn ui_surface_payload_bounds_and_secret_guards_fail_before_persistence() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let cases = [
        (
            "bad-component",
            {
                let mut surface = valid_ui_surface("demo::inspect", 1);
                surface["layout"]["children"][0]["type"] = json!("UnsupportedComponent");
                surface
            },
            "unsupported ui component",
        ),
        (
            "bad-prop",
            {
                let mut surface = valid_ui_surface("demo::inspect", 1);
                surface["layout"]["children"][0]["props"]["unexpected"] = json!("no");
                surface
            },
            "does not allow prop",
        ),
        (
            "too-many-rows",
            {
                let mut surface = valid_ui_surface("demo::inspect", 1);
                surface["layout"] = json!({
                    "type": "Table",
                    "props": {
                        "columns": ["value"],
                        "rows": (0..201).map(|idx| json!({"value": idx})).collect::<Vec<_>>()
                    }
                });
                surface
            },
            "Table rows exceed",
        ),
        (
            "raw-secret",
            {
                let mut surface = valid_ui_surface("demo::inspect", 1);
                surface["layout"]["children"][1]["props"]["text"] =
                    json!("sk-abcdefghijklmnopqrstuvwxyz012345");
                surface
            },
            "raw secret-like value",
        ),
        (
            "local-file-url",
            {
                let mut surface = valid_ui_surface("demo::inspect", 1);
                surface["layout"]["children"][1]["props"]["text"] = json!("file:///tmp/secret");
                surface
            },
            "local-file content",
        ),
    ];

    for (resource_id, surface, expected) in cases {
        let rejected = handle
            .invoke(host_invocation(
                "resource::create",
                json!({
                    "kind": "ui_surface",
                    "resourceId": resource_id,
                    "payload": surface
                }),
                mutating_causal(resource_id).with_scope("resource.write"),
            ))
            .await;
        assert!(
            matches!(
                rejected.error,
                Some(EngineError::PolicyViolation(ref message)) if message.contains(expected)
            ),
            "expected `{expected}` rejection for {resource_id}, got {:?}",
            rejected.error
        );

        let inspect = handle
            .invoke(host_invocation(
                "resource::inspect",
                json!({"resourceId": resource_id}),
                causal().with_scope("resource.read"),
            ))
            .await;
        assert_eq!(inspect.error, None);
        assert_eq!(inspect.value.as_ref().unwrap()["inspection"], Value::Null);
    }
}

#[tokio::test]
async fn ui_surface_for_target_creates_deterministic_worker_surface() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let created = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_surface_request("worker", "demo"),
            mutating_causal("ui-surface-for-worker").with_scope("ui.write"),
        ))
        .await;

    assert_eq!(created.error, None);
    let value = created.value.as_ref().unwrap();
    assert_eq!(value["resourceRefs"][0]["kind"], "ui_surface");
    assert_eq!(value["surface"]["authoring"]["mode"], "generated");
    assert_eq!(value["surface"]["authoring"]["targetType"], "worker");
    assert_eq!(value["surface"]["authoring"]["targetId"], "demo");
    assert_eq!(value["surface"]["bindings"][0]["targetType"], "worker");
    assert_eq!(
        value["surface"]["actions"][0]["targetFunctionId"],
        "ui::refresh_surface"
    );
    assert_eq!(
        value["surface"]["actions"][0]["payloadTemplate"]["surfaceResourceId"],
        "${surface.resourceId}"
    );
    assert_eq!(
        value["surface"]["actions"][0]["consequence"]["targetFunctionId"],
        "ui::refresh_surface"
    );
    assert_eq!(
        value["surface"]["actions"][0]["consequence"]["recommendedCanonicalAction"],
        "ui::refresh_surface"
    );

    let replayed = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_surface_request("worker", "demo"),
            mutating_causal("ui-surface-for-worker").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(replayed.error, None);
    assert_eq!(
        replayed.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"],
        value["resourceRefs"][0]["resourceId"]
    );
}

#[tokio::test]
async fn ui_surface_for_target_supports_core_substrate_targets() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let resource = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "goal",
                "resourceId": "goal-surface-target",
                "payload": {
                    "intent": "inspect generated UI target coverage",
                    "successCriteria": ["surface exists"],
                    "inputResources": [],
                    "expectedOutputKinds": ["ui_surface"],
                    "constraints": {},
                    "riskBudget": {"maxRisk": "low"},
                    "approvalPolicy": {"required": false},
                    "retentionPolicy": {"mode": "keep"},
                    "completionCondition": "manual"
                }
            }),
            mutating_causal("ui-target-goal").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(resource.error, None);

    let invocation = handle
        .invoke(host_invocation(
            "demo::inspect",
            json!({"message": "surface target"}),
            causal().with_scope("demo.read"),
        ))
        .await;
    assert_eq!(invocation.error, None);

    for (target_type, target_id) in [
        ("worker", "demo".to_owned()),
        ("capability", "demo::inspect".to_owned()),
        ("grant", "grant".to_owned()),
        ("resource", "goal-surface-target".to_owned()),
        ("goal", "goal-surface-target".to_owned()),
        ("invocation", invocation.invocation_id.to_string()),
        ("storage", "default".to_owned()),
        ("integrity", "default".to_owned()),
    ] {
        let created = handle
            .invoke(host_invocation(
                "ui::surface_for_target",
                generated_surface_request(target_type, &target_id),
                mutating_causal(&format!("surface-{target_type}")).with_scope("ui.write"),
            ))
            .await;
        assert_eq!(
            created.error, None,
            "surface target {target_type}:{target_id} should be authored"
        );
        assert_eq!(
            created.value.as_ref().unwrap()["surface"]["authoring"]["targetType"],
            target_type
        );
    }
}

#[tokio::test]
async fn ui_surface_for_target_authors_prompt_library_resource_collections() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    let snippet = handle
        .invoke(host_invocation(
            "prompt_library::snippet_create",
            json!({"name": "Explain", "text": "Explain the selected code"}),
            prompt_write_context("generated-ui-prompt-snippet"),
        ))
        .await;
    assert_eq!(snippet.error, None);
    let unrelated = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "artifact",
                "resourceId": "artifact:not-a-prompt",
                "payload": {"title": "Unrelated", "body": "not prompt library"}
            }),
            mutating_causal("generated-ui-unrelated-artifact").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(unrelated.error, None);
    let history = handle
        .invoke(host_invocation(
            "prompt_library::history_record",
            json!({"prompt": "Summarize the current plan"}),
            prompt_internal_write_context("generated-ui-prompt-history"),
        ))
        .await;
    assert_eq!(history.error, None);

    let snippets = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_prompt_collection_request(
                "prompt_library.snippets.v1",
                "artifact:prompt-snippet",
            ),
            prompt_ui_context("generated-ui-snippet-collection"),
        ))
        .await;
    assert_eq!(snippets.error, None);
    let snippet_surface = &snippets.value.as_ref().unwrap()["surface"];
    assert_eq!(
        snippet_surface["authoring"]["targetType"],
        "resource_collection"
    );
    assert_eq!(
        snippet_surface["authoring"]["layoutProfile"],
        "prompt_library.snippets.v1"
    );
    assert!(
        snippet_surface["layout"].to_string().contains("Explain"),
        "snippet surface should include bounded prompt-library previews"
    );
    assert!(
        !snippet_surface["layout"]
            .to_string()
            .contains("not-a-prompt"),
        "resource_collection must filter unrelated artifacts"
    );
    let snippet_actions = snippet_surface["actions"].as_array().unwrap();
    for action_id in ["refresh-surface", "create-snippet"] {
        assert!(
            snippet_actions
                .iter()
                .any(|action| action["actionId"] == action_id),
            "missing prompt snippet action {action_id}"
        );
    }
    assert!(snippet_actions.iter().any(|action| {
        action["targetFunctionId"] == "prompt_library::snippet_update"
            && action["payloadTemplate"]["id"].is_string()
            && action["targetRevision"].is_u64()
            && action["idempotencyKeyTemplate"] == "${submission.idempotencyKey}"
    }));
    assert!(snippet_actions.iter().any(|action| {
        action["targetFunctionId"] == "prompt_library::snippet_delete"
            && action["approvalPolicy"]["required"] == true
    }));

    let histories = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_prompt_collection_request(
                "prompt_library.history.v1",
                "artifact:prompt-history",
            ),
            prompt_ui_context("generated-ui-history-collection"),
        ))
        .await;
    assert_eq!(histories.error, None);
    let history_surface = &histories.value.as_ref().unwrap()["surface"];
    assert_eq!(
        history_surface["authoring"]["layoutProfile"],
        "prompt_library.history.v1"
    );
    assert!(
        history_surface["layout"]
            .to_string()
            .contains("Summarize the current plan")
    );
    let history_actions = history_surface["actions"].as_array().unwrap();
    assert!(history_actions.iter().any(|action| {
        action["actionId"] == "clear-history"
            && action["targetFunctionId"] == "prompt_library::history_clear"
            && action["approvalPolicy"]["required"] == true
    }));
    assert!(history_actions.iter().any(|action| {
        action["targetFunctionId"] == "prompt_library::history_delete"
            && action["payloadTemplate"]["id"].is_string()
    }));
}

#[tokio::test]
async fn ui_prompt_collection_empty_states_do_not_expose_inapp_refresh_or_destructive_actions() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    let snippets = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_prompt_collection_request(
                "prompt_library.snippets.v1",
                "artifact:prompt-snippet",
            ),
            prompt_ui_context("generated-ui-empty-snippet-collection"),
        ))
        .await;
    assert_eq!(snippets.error, None);
    let snippet_surface = &snippets.value.as_ref().unwrap()["surface"];
    let snippet_layout = snippet_surface["layout"].to_string();
    assert!(
        !snippet_layout.contains("Refresh"),
        "resource_collection management refresh belongs to the sheet toolbar/action list, not the body"
    );
    assert_eq!(
        snippet_layout.matches("Prompt Snippets").count(),
        1,
        "prompt collection layouts should not duplicate their title as a heading"
    );
    assert!(
        snippet_surface["actions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|action| action["actionId"] == "create-snippet")
    );

    let histories = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_prompt_collection_request(
                "prompt_library.history.v1",
                "artifact:prompt-history",
            ),
            prompt_ui_context("generated-ui-empty-history-collection"),
        ))
        .await;
    assert_eq!(histories.error, None);
    let history_surface = &histories.value.as_ref().unwrap()["surface"];
    let history_layout = history_surface["layout"].to_string();
    assert!(
        !history_layout.contains("Clear history"),
        "empty history surfaces should not present a destructive clear affordance"
    );
    assert!(
        !history_layout.contains("Refresh"),
        "resource_collection management refresh belongs to the sheet toolbar/action list, not the body"
    );
    assert_eq!(
        history_layout.matches("Prompt History").count(),
        1,
        "prompt collection layouts should not duplicate their title as a heading"
    );
    assert!(
        !history_surface["actions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|action| action["actionId"] == "clear-history"),
        "clear-history is only a valid stored action when history rows exist"
    );
}

#[tokio::test]
async fn ui_prompt_collection_bounds_and_redacts_prompt_previews() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let long_prompt = "x".repeat(900);
    for (resource_id, payload) in [
        (
            "artifact:prompt-snippet:redacted",
            json!({
                "id": "redacted",
                "title": "Unsafe",
                "name": "Unsafe",
                "body": "api_key=secret_ref:prompt-value",
                "text": "api_key=secret_ref:prompt-value",
                "updatedAt": "2100-01-01T00:00:00Z"
            }),
        ),
        (
            "artifact:prompt-snippet:long",
            json!({
                "id": "long",
                "title": "Long",
                "name": "Long",
                "body": long_prompt,
                "text": long_prompt,
                "updatedAt": "2100-01-02T00:00:00Z"
            }),
        ),
    ] {
        let created = handle
            .invoke(host_invocation(
                "resource::create",
                json!({
                    "kind": "artifact",
                    "resourceId": resource_id,
                    "payload": payload
                }),
                mutating_causal(&format!("generated-ui-prompt-preview-{resource_id}"))
                    .with_scope("resource.write"),
            ))
            .await;
        assert_eq!(created.error, None);
    }

    let surface = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_prompt_collection_request(
                "prompt_library.snippets.v1",
                "artifact:prompt-snippet",
            ),
            prompt_ui_context("generated-ui-prompt-preview-surface"),
        ))
        .await;
    assert_eq!(surface.error, None);
    let layout = surface.value.as_ref().unwrap()["surface"]["layout"].to_string();
    assert!(
        layout.contains("[redacted]"),
        "unsafe prompt previews must be redacted before rendering"
    );
    assert!(
        !layout.contains("api_key=secret_ref:prompt-value"),
        "raw secret-like prompt text must not appear in the surface"
    );
    assert!(
        !layout.contains(&"x".repeat(900)),
        "oversized prompt bodies must be bounded previews"
    );
}

#[tokio::test]
async fn ui_prompt_collection_actions_submit_through_stored_surface_coordinates() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let created = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_prompt_collection_request(
                "prompt_library.snippets.v1",
                "artifact:prompt-snippet",
            ),
            prompt_ui_context("generated-ui-submit-collection"),
        ))
        .await;
    assert_eq!(created.error, None);
    let value = created.value.as_ref().unwrap();
    let resource_ref = &value["resourceRefs"][0];
    let resource_id = resource_ref["resourceId"].as_str().unwrap();
    let surface_version_id = resource_ref["versionId"].as_str().unwrap();

    let submitted = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": resource_id,
                "surfaceVersionId": surface_version_id,
                "actionId": "create-snippet",
                "userInput": {
                    "name": "Generated action",
                    "text": "Created from a stored generated UI action"
                },
                "idempotencyKey": "generated-ui-create-snippet"
            }),
            prompt_ui_context("generated-ui-create-snippet"),
        ))
        .await;
    assert_eq!(submitted.error, None);
    let submitted_value = submitted.value.as_ref().unwrap();
    assert_eq!(
        submitted_value["targetFunctionId"],
        "prompt_library::snippet_create"
    );
    assert!(
        submitted_value["result"]["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "artifact")
    );
    let records = handle.lock().await.catalog().invocations().to_vec();
    assert!(
        records.iter().any(|record| {
            record.function_id.as_str() == "prompt_library::snippet_create"
                && record
                    .parent_invocation_id
                    .as_ref()
                    .is_some_and(|parent| parent == &submitted.invocation_id)
        }),
        "generated prompt action must execute as a child invocation"
    );
}

#[tokio::test]
async fn ui_prompt_collection_actions_submit_through_public_engine_invoke_transport_path() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let created = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_prompt_collection_request(
                "prompt_library.snippets.v1",
                "artifact:prompt-snippet",
            ),
            prompt_ui_context("generated-ui-transport-surface"),
        ))
        .await;
    assert_eq!(created.error, None);
    let value = created.value.as_ref().unwrap();
    let resource_ref = &value["resourceRefs"][0];
    let resource_id = resource_ref["resourceId"].as_str().unwrap();
    let surface_version_id = resource_ref["versionId"].as_str().unwrap();

    let submitted = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "ui::submit_action",
                "payload": {
                    "surfaceResourceId": resource_id,
                    "surfaceVersionId": surface_version_id,
                    "actionId": "create-snippet",
                    "userInput": {
                        "name": "Transport action",
                        "text": "Created through the public engine invoke transport path"
                    },
                    "idempotencyKey": "generated-ui-transport-create-snippet"
                },
                "idempotencyKey": "generated-ui-transport-create-snippet"
            }),
            prompt_ui_context("generated-ui-transport-submit"),
        ))
        .await;
    assert_eq!(submitted.error, None);
    let child = &submitted.value.as_ref().unwrap()["child"];
    assert_eq!(child["functionId"], "ui::submit_action");
    assert_eq!(child["error"], Value::Null);
    assert_eq!(
        child["value"]["targetFunctionId"],
        "prompt_library::snippet_create"
    );
    assert!(
        child["value"]["result"]["resourceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|reference| reference["kind"] == "artifact")
    );

    let ui_submit_invocation_id = child["invocationId"].as_str().unwrap();
    let records = handle.lock().await.catalog().invocations().to_vec();
    assert!(records.iter().any(|record| {
        record.function_id.as_str() == "ui::submit_action"
            && record.invocation_id.as_str() == ui_submit_invocation_id
            && record
                .parent_invocation_id
                .as_ref()
                .is_some_and(|parent| parent == &submitted.invocation_id)
    }));
    assert!(records.iter().any(|record| {
        record.function_id.as_str() == "prompt_library::snippet_create"
            && record
                .parent_invocation_id
                .as_ref()
                .is_some_and(|parent| parent.as_str() == ui_submit_invocation_id)
    }));
}

#[tokio::test]
async fn ui_prompt_collection_management_is_sessionless_and_system_idempotent() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let created = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_prompt_collection_request(
                "prompt_library.snippets.v1",
                "artifact:prompt-snippet",
            ),
            sessionless_prompt_ui_context("generated-ui-sessionless-surface"),
        ))
        .await;
    assert_eq!(created.error, None);
    let value = created.value.as_ref().unwrap();
    let resource_ref = &value["resourceRefs"][0];
    let resource_id = resource_ref["resourceId"].as_str().unwrap();
    let surface_version_id = resource_ref["versionId"].as_str().unwrap();

    let submitted = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": resource_id,
                "surfaceVersionId": surface_version_id,
                "actionId": "create-snippet",
                "userInput": {
                    "name": "Sessionless generated action",
                    "text": "Created outside a chat session"
                },
                "idempotencyKey": "generated-ui-sessionless-create-snippet"
            }),
            sessionless_prompt_ui_context("generated-ui-sessionless-submit"),
        ))
        .await;
    assert_eq!(submitted.error, None);

    let records = handle.lock().await.catalog().invocations().to_vec();
    let surface_record = records
        .iter()
        .find(|record| record.invocation_id == created.invocation_id)
        .expect("surface_for_target invocation should be recorded");
    assert_eq!(surface_record.session_id, None);
    assert_eq!(
        surface_record.idempotency_scope,
        Some(IdempotencyScope::new("system", "system"))
    );
    let submit_record = records
        .iter()
        .find(|record| record.invocation_id == submitted.invocation_id)
        .expect("ui::submit_action invocation should be recorded");
    assert_eq!(submit_record.session_id, None);
    assert_eq!(
        submit_record.idempotency_scope,
        Some(IdempotencyScope::new("system", "system"))
    );
    assert!(records.iter().any(|record| {
        record.function_id.as_str() == "prompt_library::snippet_create"
            && record
                .parent_invocation_id
                .as_ref()
                .is_some_and(|parent| parent == &submitted.invocation_id)
            && record.session_id.is_none()
            && record.idempotency_scope == Some(IdempotencyScope::new("system", "system"))
    }));
}

#[tokio::test]
async fn ui_prompt_collection_rejects_unknown_targets_and_profiles() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    for (layout_profile, target_id, expected) in [
        (
            "prompt_library.snippets.v1",
            "artifact:unknown",
            "unsupported resource_collection target",
        ),
        (
            "prompt_library.history.v1",
            "artifact:prompt-snippet",
            "requires layoutProfile prompt_library.snippets.v1",
        ),
    ] {
        let rejected = handle
            .invoke(host_invocation(
                "ui::surface_for_target",
                generated_prompt_collection_request(layout_profile, target_id),
                prompt_ui_context(&format!("generated-ui-reject-{target_id}-{layout_profile}")),
            ))
            .await;
        assert!(
            matches!(
                rejected.error,
                Some(EngineError::PolicyViolation(ref message)) if message.contains(expected)
            ),
            "expected `{expected}` rejection, got {:?}",
            rejected.error
        );
    }
}

#[tokio::test]
async fn ui_validate_surface_detects_stale_expired_and_invalid_surfaces() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let created = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_surface_request("capability", "demo::inspect"),
            mutating_causal("validate-generated-surface").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let resource_id = created.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let original_version_id = created.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let valid = handle
        .invoke(host_invocation(
            "ui::validate_surface",
            json!({"surfaceResourceId": resource_id}),
            causal().with_scope("ui.read"),
        ))
        .await;
    assert_eq!(valid.error, None);
    assert_eq!(valid.value.as_ref().unwrap()["validationState"], "valid");

    let mut changed_function = read_function("demo::inspect", "demo");
    changed_function.description = "changed description".to_owned();
    handle
        .register_function_for_setup(changed_function, Some(handler()), false)
        .unwrap();
    let stale = handle
        .invoke(host_invocation(
            "ui::validate_surface",
            json!({"surfaceResourceId": resource_id}),
            causal().with_scope("ui.read"),
        ))
        .await;
    assert_eq!(stale.error, None);
    assert_eq!(stale.value.as_ref().unwrap()["validationState"], "stale");

    let refreshed = handle
        .invoke(host_invocation(
            "ui::refresh_surface",
            json!({
                "surfaceResourceId": resource_id,
                "expectedCurrentVersionId": original_version_id.clone()
            }),
            mutating_causal("refresh-stale-generated-surface").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(refreshed.error, None);
    assert_eq!(
        refreshed.value.as_ref().unwrap()["surface"]["authoring"]["refreshedFromVersionId"],
        original_version_id
    );

    let refreshed_validation = handle
        .invoke(host_invocation(
            "ui::validate_surface",
            json!({"surfaceResourceId": resource_id}),
            causal().with_scope("ui.read"),
        ))
        .await;
    assert_eq!(refreshed_validation.error, None);
    assert_eq!(
        refreshed_validation.value.as_ref().unwrap()["validationState"],
        "valid"
    );

    let expired = handle
        .invoke(host_invocation(
            "ui::expire_surface",
            json!({"surfaceResourceId": resource_id}),
            mutating_causal("expire-generated-surface").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(expired.error, None);
    let expired_validation = handle
        .invoke(host_invocation(
            "ui::validate_surface",
            json!({"surfaceResourceId": resource_id}),
            causal().with_scope("ui.read"),
        ))
        .await;
    assert_eq!(expired_validation.error, None);
    assert_eq!(
        expired_validation.value.as_ref().unwrap()["validationState"],
        "expired"
    );

    let expired_refresh = handle
        .invoke(host_invocation(
            "ui::refresh_surface",
            json!({
                "surfaceResourceId": resource_id,
                "expectedCurrentVersionId": expired.value.as_ref().unwrap()["resourceRefs"][0]["versionId"].as_str().unwrap()
            }),
            mutating_causal("refresh-expired-generated-surface").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(expired_refresh.error, None);
    let live_after_expired_refresh = handle
        .invoke(host_invocation(
            "ui::validate_surface",
            json!({"surfaceResourceId": resource_id}),
            causal().with_scope("ui.read"),
        ))
        .await;
    assert_eq!(live_after_expired_refresh.error, None);
    assert_eq!(
        live_after_expired_refresh.value.as_ref().unwrap()["validationState"],
        "valid"
    );

    let missing = handle
        .invoke(host_invocation(
            "ui::validate_surface",
            json!({"surfaceResourceId": "missing-surface"}),
            causal().with_scope("ui.read"),
        ))
        .await;
    assert_eq!(missing.error, None);
    assert_eq!(
        missing.value.as_ref().unwrap()["validationState"],
        "invalid"
    );
}

#[tokio::test]
async fn ui_refresh_surface_requires_generated_authoring_and_cas() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let manual = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "manual-refresh-rejected",
                "surface": valid_ui_surface("demo::inspect", 1)
            }),
            mutating_causal("manual-refresh-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(manual.error, None);
    let manual_version = manual.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let manual_refresh = handle
        .invoke(host_invocation(
            "ui::refresh_surface",
            json!({
                "surfaceResourceId": "manual-refresh-rejected",
                "expectedCurrentVersionId": manual_version
            }),
            mutating_causal("manual-refresh-rejected").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        manual_refresh.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("generated authoring")
    ));

    let generated = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            generated_surface_request("worker", "demo"),
            mutating_causal("generated-refresh-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(generated.error, None);
    let resource_id = generated.value.as_ref().unwrap()["resourceRefs"][0]["resourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let version_id = generated.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let rejected = handle
        .invoke(host_invocation(
            "ui::refresh_surface",
            json!({
                "surfaceResourceId": resource_id,
                "expectedCurrentVersionId": "wrong-version"
            }),
            mutating_causal("generated-refresh-stale").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("version conflict")
    ));

    let refreshed = handle
        .invoke(host_invocation(
            "ui::refresh_surface",
            json!({
                "surfaceResourceId": resource_id,
                "expectedCurrentVersionId": version_id
            }),
            mutating_causal("generated-refresh-ok").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(refreshed.error, None);
    assert_eq!(
        refreshed.value.as_ref().unwrap()["surface"]["authoring"]["refreshedFromVersionId"],
        version_id
    );
    assert_eq!(
        refreshed.value.as_ref().unwrap()["resourceRefs"][0]["kind"],
        "ui_surface"
    );
}

#[tokio::test]
async fn control_advertises_generated_surface_authoring_without_layout_templates() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let inspect = handle
        .invoke(host_invocation(
            "control::inspect",
            json!({"targetType": "worker", "targetId": "demo"}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(inspect.error, None);
    let value = inspect.value.as_ref().unwrap();
    assert!(
        value["availableActions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|action| action["functionId"] == "ui::surface_for_target"
                && action["consequence"]["recommendedCanonicalAction"] == "ui::surface_for_target")
    );
    let text = serde_json::to_string(value).unwrap();
    assert!(!text.contains("payloadTemplate"));
    assert!(!text.contains("inputSchema"));
    assert!(!text.contains("\"layout\""));
}

#[tokio::test]
async fn ui_surface_update_requires_expected_current_version() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-cas",
                "surface": valid_ui_surface("demo::inspect", 1)
            }),
            mutating_causal("ui-surface-cas-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);

    let rejected = handle
        .invoke(host_invocation(
            "ui::update_surface",
            json!({
                "resourceId": "ui-surface-cas",
                "expectedCurrentVersionId": "wrong-version",
                "surface": valid_ui_surface("demo::inspect", 1)
            }),
            mutating_causal("ui-surface-cas-update").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("version conflict")
    ));
}

#[tokio::test]
async fn ui_create_surface_rejects_unknown_action_target() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let rejected = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-missing-target",
                "surface": valid_ui_surface("missing::target", 1)
            }),
            mutating_causal("ui-surface-missing-target").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::NotFound { kind, id })
            if kind == "function" && id == "missing::target"
    ));
}

#[tokio::test]
async fn ui_create_surface_rejects_action_template_outside_target_request_schema() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let target = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "schema-constrained write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_request_schema(json!({
        "type": "object",
        "required": ["message"],
        "additionalProperties": false,
        "properties": {
            "message": {"type": "string"}
        }
    }))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(target, Some(handler()), false)
        .unwrap();

    let rejected = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-bad-template",
                "surface": valid_ui_surface("demo::write", 1)
            }),
            mutating_causal("ui-surface-bad-template").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("payloadTemplate")
                && message.contains("sourceSurface")
                && message.contains("not accepted")
    ));
}

#[tokio::test]
async fn ui_submit_action_validates_stored_surface_and_creates_child_invocation() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let target = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "resource-backed write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            target,
            Some(Arc::new(StaticValueHandler(json!({
                "accepted": true,
                "resourceRefs": [{
                    "resourceId": "artifact-from-ui",
                    "kind": "artifact",
                    "versionId": "ver-ui",
                    "role": "created",
                    "contentHash": "hash-ui"
                }]
            })))),
            false,
        )
        .unwrap();

    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-action",
                "surface": valid_ui_surface("demo::write", 1)
            }),
            mutating_causal("ui-surface-action-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let surface_version = created.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let stale = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": "ui-surface-action",
                "surfaceVersionId": "wrong-version",
                "actionId": "submit-test",
                "userInput": {"message": "hello"},
                "idempotencyKey": "ui-action-stale"
            }),
            mutating_causal("ui-action-stale").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("stale")
    ));

    let submitted = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": "ui-surface-action",
                "surfaceVersionId": surface_version,
                "actionId": "submit-test",
                "userInput": {"message": "hello"},
                "idempotencyKey": "ui-action-submit"
            }),
            mutating_causal("ui-action-submit").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(submitted.error, None);
    let value = submitted.value.as_ref().unwrap();
    assert_eq!(value["targetFunctionId"], "demo::write");
    assert_eq!(
        value["result"]["resourceRefs"][0]["resourceId"],
        "artifact-from-ui"
    );

    let records = handle.lock().await.catalog().invocations().to_vec();
    let child = records
        .iter()
        .find(|record| {
            record.function_id.as_str() == "demo::write"
                && record
                    .parent_invocation_id
                    .as_ref()
                    .is_some_and(|parent| parent == &submitted.invocation_id)
        })
        .expect("ui submit must create a trace-linked child invocation");
    assert_eq!(
        child.produced_resource_refs[0]["resourceId"],
        "artifact-from-ui"
    );

    let discarded = handle
        .invoke(host_invocation(
            "ui::discard_surface",
            json!({
                "surfaceResourceId": "ui-surface-action",
                "expectedCurrentVersionId": surface_version
            }),
            mutating_causal("ui-action-discard").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(discarded.error, None);
    let inspect = handle
        .invoke(host_invocation(
            "ui::inspect_surface",
            json!({"surfaceResourceId": "ui-surface-action"}),
            causal().with_scope("ui.read"),
        ))
        .await;
    assert_eq!(inspect.error, None);
    assert_eq!(
        inspect.value.as_ref().unwrap()["validationState"],
        "damaged",
        "discarded surfaces remain inspectable but not actionable"
    );
    let rejected = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": "ui-surface-action",
                "surfaceVersionId": discarded.value.as_ref().unwrap()["resourceRefs"][0]["versionId"],
                "actionId": "submit-test",
                "userInput": {"message": "hello"},
                "idempotencyKey": "ui-action-discarded"
            }),
            mutating_causal("ui-action-discarded").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("ui_surface ui-surface-action is discarded")
    ));
}

#[tokio::test]
async fn ui_submit_action_rejects_invalid_input_and_stale_target_before_child_invocation() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let target = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "resource-backed write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            target,
            Some(Arc::new(StaticValueHandler(json!({
                "accepted": true,
                "resourceRefs": [{
                    "resourceId": "artifact-from-invalid-ui",
                    "kind": "artifact",
                    "versionId": "ver-ui",
                    "role": "created",
                    "contentHash": "hash-ui"
                }]
            })))),
            false,
        )
        .unwrap();

    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-reject-action",
                "surface": valid_ui_surface("demo::write", 1)
            }),
            mutating_causal("ui-reject-action-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let surface_version = created.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let child_count = || async {
        handle
            .lock()
            .await
            .catalog()
            .invocations()
            .iter()
            .filter(|record| record.function_id.as_str() == "demo::write")
            .count()
    };

    let before = child_count().await;
    let invalid_input = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": "ui-surface-reject-action",
                "surfaceVersionId": surface_version,
                "actionId": "submit-test",
                "userInput": {},
                "idempotencyKey": "ui-invalid-input"
            }),
            mutating_causal("ui-invalid-input").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        invalid_input.error,
        Some(EngineError::SchemaViolation { .. })
    ));
    assert_eq!(
        child_count().await,
        before,
        "invalid user input must fail before target child invocation"
    );

    let changed_target = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "resource-backed write with changed revision",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            changed_target,
            Some(Arc::new(StaticValueHandler(json!({
                "accepted": true,
                "resourceRefs": [{
                    "resourceId": "artifact-from-stale-ui",
                    "kind": "artifact",
                    "versionId": "ver-ui-stale",
                    "role": "created",
                    "contentHash": "hash-ui-stale"
                }]
            })))),
            false,
        )
        .unwrap();
    let stale_target = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": "ui-surface-reject-action",
                "surfaceVersionId": created.value.as_ref().unwrap()["resourceRefs"][0]["versionId"],
                "actionId": "submit-test",
                "userInput": {"message": "hello"},
                "idempotencyKey": "ui-stale-target"
            }),
            mutating_causal("ui-stale-target").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        stale_target.error,
        Some(EngineError::StaleFunctionRevision { .. })
    ));
    assert_eq!(
        child_count().await,
        before,
        "stale target revision must fail before target child invocation"
    );
}

#[tokio::test]
async fn control_snapshot_and_inspect_expose_ui_surface_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();
    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-control",
                "surface": valid_ui_surface("demo::inspect", 1),
                "links": [
                    {"targetType": "worker", "targetId": "demo"},
                    {"targetType": "capability", "targetId": "demo::inspect"}
                ]
            }),
            mutating_causal("ui-surface-control-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);

    let snapshot = handle
        .invoke(host_invocation(
            "control::snapshot",
            json!({"limit": 25}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(snapshot.error, None);
    assert!(
        snapshot.value.as_ref().unwrap()["uiSurfaceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|surface| surface["resourceId"] == "ui-surface-control")
    );

    let inspect = handle
        .invoke(host_invocation(
            "control::inspect",
            json!({"targetType": "worker", "targetId": "demo"}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(inspect.error, None);
    assert!(
        inspect.value.as_ref().unwrap()["uiSurfaceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|surface| surface["resourceId"] == "ui-surface-control")
    );
}

#[tokio::test]
async fn control_snapshot_projects_substrate_without_control_state() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let context = CausalContext::new(
        actor("system"),
        ActorKind::System,
        grant("grant"),
        trace("control-snapshot"),
    )
    .with_scope("control.read");
    let snapshot = handle
        .invoke(host_invocation(
            "control::snapshot",
            json!({"limit": 25}),
            context,
        ))
        .await;
    assert_eq!(snapshot.error, None);
    let value = snapshot.value.as_ref().unwrap();
    assert!(
        value["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability["id"] == "resource::create")
    );
    assert!(
        value["resourceTypes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|resource_type| resource_type["kind"] == "goal")
    );
    assert!(
        value["availableActions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|action| action["functionId"] != "control::act")
    );
}
