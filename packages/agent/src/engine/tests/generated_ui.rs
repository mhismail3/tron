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
