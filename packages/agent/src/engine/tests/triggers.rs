use super::*;

#[test]
fn trigger_registration_validates_owner_type_target_and_delivery() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();

    let trigger_type = TriggerTypeDefinition::new(
        TriggerTypeId::new("cron").unwrap(),
        wid("w1"),
        "cron trigger",
    );
    catalog.register_trigger_type(trigger_type, true).unwrap();

    let trigger = TriggerDefinition::new(
        TriggerId::new("t1").unwrap(),
        wid("w1"),
        TriggerTypeId::new("cron").unwrap(),
        fid("alpha::read"),
        grant("grant"),
    );
    let rev = catalog.register_trigger(trigger, true).unwrap();
    assert_eq!(rev.0, 1);

    let mut stale_target = TriggerDefinition::new(
        TriggerId::new("t-stale").unwrap(),
        wid("w1"),
        TriggerTypeId::new("cron").unwrap(),
        fid("alpha::read"),
        grant("grant"),
    );
    stale_target.target_revision = Some(FunctionRevision(99));
    assert!(matches!(
        catalog.register_trigger(stale_target, true),
        Err(EngineError::StaleFunctionRevision {
            expected: 99,
            actual: 1,
            ..
        })
    ));

    let unsupported = TriggerDefinition::new(
        TriggerId::new("t2").unwrap(),
        wid("w1"),
        TriggerTypeId::new("cron").unwrap(),
        fid("alpha::read"),
        grant("grant"),
    )
    .with_delivery_mode(DeliveryMode::Enqueue);
    assert!(matches!(
        catalog.register_trigger(unsupported, true),
        Err(EngineError::DeliveryModeNotAllowed { .. })
    ));
}

#[tokio::test]
async fn trigger_runtime_manual_dispatch_records_trigger_metadata() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_trigger_type_for_setup(
            TriggerTypeDefinition::new(
                TriggerTypeId::new("manual").unwrap(),
                wid("alpha"),
                "manual",
            ),
            false,
        )
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("alpha::echo", "alpha")
                .with_required_authority(AuthorityRequirement::scope("manual.invoke")),
            Some(handler()),
            false,
        )
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.echo").unwrap();
    handle
        .register_trigger_for_setup(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("alpha"),
                TriggerTypeId::new("manual").unwrap(),
                fid("alpha::echo"),
                grant("manual-grant"),
            ),
            false,
        )
        .unwrap();

    let mut request = TriggerDispatchRequest::new(
        trigger_id.clone(),
        json!({"value": 1}),
        actor("agent"),
        ActorKind::Agent,
    );
    request.authority_scopes = vec!["manual.invoke".to_owned()];
    request.trace_id = Some(trace("trigger-trace"));
    request.session_id = Some("session-a".to_owned());

    let result = EngineTriggerRuntime::dispatch(&handle, request).await;
    assert_eq!(result.error, None);
    assert_eq!(result.value.unwrap()["echo"], json!({"value": 1}));

    let host = handle.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert_eq!(record.authority_grant_id, grant("manual-grant"));
    assert_eq!(record.trace_id, trace("trigger-trace"));
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
}

#[tokio::test]
async fn trigger_runtime_fails_closed_for_missing_trigger() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let trigger_id = TriggerId::new("manual:missing").unwrap();
    let result = EngineTriggerRuntime::dispatch(
        &handle,
        TriggerDispatchRequest::new(
            trigger_id.clone(),
            json!({}),
            actor("agent"),
            ActorKind::Agent,
        ),
    )
    .await;
    assert!(matches!(result.error, Some(EngineError::NotFound { .. })));

    let host = handle.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(record.function_id, fid("engine::trigger_dispatch"));
    assert_eq!(record.worker_id, wid("engine"));
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert_eq!(record.actor_id, actor("agent"));
    assert!(matches!(
        record.error.as_ref(),
        Some(EngineError::NotFound { .. })
    ));
}

#[tokio::test]
async fn trigger_runtime_records_delivery_mismatch_prepare_failure() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_trigger_type_for_setup(
            TriggerTypeDefinition::new(
                TriggerTypeId::new("manual").unwrap(),
                wid("alpha"),
                "manual",
            ),
            false,
        )
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("alpha::echo", "alpha"),
            Some(handler()),
            false,
        )
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.echo").unwrap();
    handle
        .register_trigger_for_setup(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("alpha"),
                TriggerTypeId::new("manual").unwrap(),
                fid("alpha::echo"),
                grant("manual-grant"),
            )
            .with_delivery_mode(DeliveryMode::Sync),
            false,
        )
        .unwrap();

    let mut request = TriggerDispatchRequest::new(
        trigger_id.clone(),
        json!({}),
        actor("agent"),
        ActorKind::Agent,
    );
    request.delivery_mode = Some(DeliveryMode::Void);
    let result = EngineTriggerRuntime::dispatch(&handle, request).await;
    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(_))
    ));

    let host = handle.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(record.function_id, fid("alpha::echo"));
    assert_eq!(record.worker_id, wid("alpha"));
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert_eq!(record.delivery_mode, DeliveryMode::Void);
    assert!(matches!(
        record.error.as_ref(),
        Some(EngineError::PolicyViolation(_))
    ));
}

#[tokio::test]
async fn trigger_runtime_target_failures_keep_trigger_metadata_in_ledger() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_trigger_type_for_setup(
            TriggerTypeDefinition::new(
                TriggerTypeId::new("manual").unwrap(),
                wid("alpha"),
                "manual",
            ),
            false,
        )
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("alpha::schema", "alpha").with_request_schema(json!({
                "type": "object",
                "required": ["ok"],
                "additionalProperties": false,
                "properties": {
                    "ok": {"type": "boolean"}
                }
            })),
            Some(handler()),
            false,
        )
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.schema").unwrap();
    handle
        .register_trigger_for_setup(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("alpha"),
                TriggerTypeId::new("manual").unwrap(),
                fid("alpha::schema"),
                grant("manual-grant"),
            ),
            false,
        )
        .unwrap();

    let result = EngineTriggerRuntime::dispatch(
        &handle,
        TriggerDispatchRequest::new(
            trigger_id.clone(),
            json!({"bad": true}),
            actor("agent"),
            ActorKind::Agent,
        ),
    )
    .await;
    assert!(matches!(
        result.error,
        Some(EngineError::SchemaViolation { .. })
    ));

    let host = handle.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(record.function_id, fid("alpha::schema"));
    assert_eq!(record.worker_id, wid("alpha"));
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert!(matches!(
        record.error.as_ref(),
        Some(EngineError::SchemaViolation { .. })
    ));
}

#[tokio::test]
async fn trigger_runtime_stale_target_revision_records_attempt() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_trigger_type_for_setup(
            TriggerTypeDefinition::new(
                TriggerTypeId::new("manual").unwrap(),
                wid("alpha"),
                "manual",
            ),
            false,
        )
        .unwrap();
    let mut target = read_function("alpha::echo", "alpha")
        .with_provenance(Provenance::system().with_session_id("session-a"));
    target.visibility = VisibilityScope::Session;
    let revision = handle
        .register_function_for_setup(target, Some(handler()), false)
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.echo").unwrap();
    let mut trigger = TriggerDefinition::new(
        trigger_id.clone(),
        wid("alpha"),
        TriggerTypeId::new("manual").unwrap(),
        fid("alpha::echo"),
        grant("manual-grant"),
    );
    trigger.target_revision = Some(revision);
    handle.register_trigger_for_setup(trigger, false).unwrap();
    handle
        .promote_function_visibility(
            &fid("alpha::echo"),
            &wid("alpha"),
            VisibilityScope::Workspace,
            Some("workspace-a".to_owned()),
        )
        .await
        .unwrap();

    let mut request = TriggerDispatchRequest::new(
        trigger_id.clone(),
        json!({}),
        actor("agent"),
        ActorKind::Agent,
    );
    request.workspace_id = Some("workspace-a".to_owned());
    let result = EngineTriggerRuntime::dispatch(&handle, request).await;
    assert!(matches!(
        result.error,
        Some(EngineError::StaleFunctionRevision { .. })
    ));

    let host = handle.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(record.function_id, fid("alpha::echo"));
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert!(
        record.function_revision > revision,
        "ledger should record the actual target revision that caused the stale-target failure"
    );
    assert!(matches!(
        record.error.as_ref(),
        Some(EngineError::StaleFunctionRevision { .. })
    ));
}

#[tokio::test]
async fn trigger_runtime_does_not_block_discovery_while_target_runs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_trigger_type_for_setup(
            TriggerTypeDefinition::new(
                TriggerTypeId::new("manual").unwrap(),
                wid("alpha"),
                "manual",
            ),
            false,
        )
        .unwrap();
    let started = Arc::new(Barrier::new(2));
    let release = Arc::new(Notify::new());
    handle
        .register_function_for_setup(
            read_function("alpha::slow", "alpha"),
            Some(Arc::new(BlockingHandler {
                started: Arc::clone(&started),
                release: Arc::clone(&release),
            })),
            false,
        )
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.slow").unwrap();
    handle
        .register_trigger_for_setup(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("alpha"),
                TriggerTypeId::new("manual").unwrap(),
                fid("alpha::slow"),
                grant("manual-grant"),
            ),
            false,
        )
        .unwrap();

    let running = {
        let handle = handle.clone();
        tokio::spawn(async move {
            EngineTriggerRuntime::dispatch(
                &handle,
                TriggerDispatchRequest::new(
                    trigger_id,
                    json!({"x": 1}),
                    actor("agent"),
                    ActorKind::Agent,
                ),
            )
            .await
        })
    };

    started.wait().await;
    let functions = tokio::time::timeout(
        std::time::Duration::from_millis(100),
        handle.discover(&FunctionQuery {
            actor: Some(ActorContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("grant"),
            )),
            ..FunctionQuery::default()
        }),
    )
    .await
    .expect("trigger target execution should not block discovery");
    assert!(
        functions
            .iter()
            .any(|function| function.id == fid("alpha::slow"))
    );

    release.notify_waiters();
    let result = running.await.unwrap();
    assert_eq!(result.error, None);
}
