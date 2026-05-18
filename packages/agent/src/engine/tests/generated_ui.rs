use super::*;

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
