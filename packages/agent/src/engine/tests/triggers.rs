use super::*;

use std::collections::BTreeMap;
use std::sync::Mutex;

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

#[test]
fn trigger_registration_restricts_void_to_explicit_loss_tolerant_targets() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("alpha", "alpha"), true)
        .unwrap();
    let mut trigger_type = TriggerTypeDefinition::new(
        TriggerTypeId::new("manual").unwrap(),
        wid("alpha"),
        "manual",
    );
    trigger_type.allowed_delivery_modes = vec![DeliveryMode::Sync, DeliveryMode::Void];
    catalog.register_trigger_type(trigger_type, true).unwrap();

    catalog
        .register_function(
            write_function("alpha::important_write", "alpha")
                .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Void]),
            Some(handler()),
            true,
        )
        .unwrap();
    let unsafe_void = TriggerDefinition::new(
        TriggerId::new("manual:alpha.important_write").unwrap(),
        wid("alpha"),
        TriggerTypeId::new("manual").unwrap(),
        fid("alpha::important_write"),
        grant("grant"),
    )
    .with_delivery_mode(DeliveryMode::Void);
    assert!(
        matches!(
            catalog.register_trigger(unsafe_void, true),
            Err(EngineError::PolicyViolation(ref message))
                if message.contains("loss-tolerant")
        ),
        "Void trigger delivery must be explicit and loss-tolerant"
    );

    catalog
        .register_function(
            loss_tolerant_void_function("alpha::telemetry", "alpha"),
            Some(handler()),
            true,
        )
        .unwrap();
    let allowed_void = TriggerDefinition::new(
        TriggerId::new("manual:alpha.telemetry").unwrap(),
        wid("alpha"),
        TriggerTypeId::new("manual").unwrap(),
        fid("alpha::telemetry"),
        grant("grant"),
    )
    .with_delivery_mode(DeliveryMode::Void);
    catalog.register_trigger(allowed_void, true).unwrap();
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
async fn trigger_runtime_void_dispatch_records_causal_metadata_once() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let mut trigger_type = TriggerTypeDefinition::new(
        TriggerTypeId::new("manual").unwrap(),
        wid("alpha"),
        "manual",
    );
    trigger_type.allowed_delivery_modes = vec![DeliveryMode::Sync, DeliveryMode::Void];
    handle
        .register_trigger_type_for_setup(trigger_type, false)
        .unwrap();
    let captured = Arc::new(Mutex::new(Vec::new()));
    let calls = Arc::new(AtomicUsize::new(0));
    handle
        .register_function_for_setup(
            loss_tolerant_void_function("alpha::telemetry", "alpha")
                .with_required_authority(AuthorityRequirement::scope("telemetry.append")),
            Some(Arc::new(CaptureInvocationHandler {
                calls: Arc::clone(&calls),
                invocations: Arc::clone(&captured),
            })),
            false,
        )
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.telemetry").unwrap();
    let mut trigger = TriggerDefinition::new(
        trigger_id.clone(),
        wid("alpha"),
        TriggerTypeId::new("manual").unwrap(),
        fid("alpha::telemetry"),
        grant("manual-grant"),
    )
    .with_delivery_mode(DeliveryMode::Void);
    trigger.max_depth = Some(2);
    handle.register_trigger_for_setup(trigger, false).unwrap();

    let parent = InvocationId::generate();
    let mut request = TriggerDispatchRequest::new(
        trigger_id.clone(),
        json!({"metric": "cache_miss"}),
        actor("agent"),
        ActorKind::Agent,
    );
    request.delivery_mode = Some(DeliveryMode::Void);
    request.authority_scopes = vec!["telemetry.append".to_owned()];
    request.runtime_metadata = BTreeMap::from([("transport".to_owned(), "test".to_owned())]);
    request.trace_id = Some(trace("void-trigger-trace"));
    request.parent_invocation_id = Some(parent.clone());
    request.session_id = Some("session-void".to_owned());
    request.workspace_id = Some("workspace-void".to_owned());
    request.idempotency_key = Some("void-trigger-key".to_owned());

    let result = EngineTriggerRuntime::dispatch(&handle, request).await;
    assert_eq!(result.error, None);
    assert_eq!(result.function_id, fid("alpha::telemetry"));
    assert_eq!(result.trace_id, trace("void-trigger-trace"));

    let captured = captured.lock().unwrap();
    assert_eq!(captured.len(), 1);
    let invocation = &captured[0];
    assert_eq!(invocation.delivery_mode, DeliveryMode::Void);
    assert_eq!(
        invocation.causal_context.trace_id,
        trace("void-trigger-trace")
    );
    assert_eq!(
        invocation.causal_context.trigger_id,
        Some(trigger_id.clone())
    );
    assert_eq!(
        invocation.causal_context.parent_invocation_id.as_ref(),
        Some(&parent)
    );
    assert_eq!(
        invocation.causal_context.session_id.as_deref(),
        Some("session-void")
    );
    assert_eq!(
        invocation.causal_context.workspace_id.as_deref(),
        Some("workspace-void")
    );
    assert_eq!(
        invocation.causal_context.idempotency_key.as_deref(),
        Some("void-trigger-key")
    );
    assert_eq!(
        invocation.causal_context.runtime_metadata("transport"),
        Some("test")
    );
    assert_eq!(
        invocation
            .causal_context
            .runtime_metadata(crate::engine::invocation::RUNTIME_METADATA_TRIGGER_DEPTH),
        Some("1")
    );

    let record = handle
        .invocation_records()
        .await
        .into_iter()
        .find(|record| record.function_id == fid("alpha::telemetry"))
        .expect("void trigger target should be recorded");
    assert_eq!(record.delivery_mode, DeliveryMode::Void);
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert_eq!(record.trace_id, trace("void-trigger-trace"));
    assert_eq!(record.parent_invocation_id.as_ref(), Some(&parent));
    assert_eq!(record.idempotency_key.as_deref(), Some("void-trigger-key"));
    assert!(record.succeeded);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn direct_void_invocation_without_trigger_runtime_stays_unsupported() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            loss_tolerant_void_function("alpha::telemetry", "alpha"),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(
            Invocation::new_sync(
                fid("alpha::telemetry"),
                json!({"metric": "direct"}),
                CausalContext::new(
                    actor("agent"),
                    ActorKind::Agent,
                    grant("grant"),
                    trace("direct-void"),
                )
                .with_idempotency_key("direct-void-key"),
            )
            .with_delivery_mode(DeliveryMode::Void),
        )
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::UnsupportedDeliveryMode { mode: "void" })
    ));

    let forged_result = handle
        .invoke(
            Invocation::new_sync(
                fid("alpha::telemetry"),
                json!({"metric": "forged"}),
                CausalContext::new(
                    actor("agent"),
                    ActorKind::Agent,
                    grant("grant"),
                    trace("forged-void"),
                )
                .with_trigger_id(TriggerId::new("forged-trigger").unwrap())
                .with_runtime_metadata(
                    crate::engine::invocation::RUNTIME_METADATA_TRIGGER_DEPTH,
                    "1",
                )
                .with_runtime_metadata(
                    crate::engine::invocation::RUNTIME_METADATA_TRIGGER_PATH,
                    "[\"forged-trigger\"]",
                )
                .with_idempotency_key("forged-void-key"),
            )
            .with_delivery_mode(DeliveryMode::Void),
        )
        .await;
    assert!(matches!(
        forged_result.error,
        Some(EngineError::UnsupportedDeliveryMode { mode: "void" })
    ));
}

#[tokio::test]
async fn trigger_runtime_stops_cascades_at_depth_budget_before_handler() {
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
    let trigger_id = TriggerId::new("manual:alpha.cascade").unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let captured = Arc::new(Mutex::new(Vec::new()));
    handle
        .register_function_for_setup(
            read_function("alpha::cascade", "alpha"),
            Some(Arc::new(CascadingTriggerHandler {
                handle: handle.clone(),
                trigger_id: trigger_id.clone(),
                calls: Arc::clone(&calls),
                invocations: Arc::clone(&captured),
            })),
            false,
        )
        .unwrap();
    let mut trigger = TriggerDefinition::new(
        trigger_id.clone(),
        wid("alpha"),
        TriggerTypeId::new("manual").unwrap(),
        fid("alpha::cascade"),
        grant("manual-grant"),
    );
    trigger.max_depth = Some(0);
    handle.register_trigger_for_setup(trigger, false).unwrap();

    let mut request = TriggerDispatchRequest::new(
        trigger_id.clone(),
        json!({"root": true}),
        actor("agent"),
        ActorKind::Agent,
    );
    request.trace_id = Some(trace("cascade-trace"));
    request.session_id = Some("session-cascade".to_owned());

    let result = EngineTriggerRuntime::dispatch(&handle, request).await;
    assert_eq!(result.error, None);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(captured.lock().unwrap().len(), 1);
    assert_eq!(
        result.value.as_ref().unwrap()["cascadeError"]["kind"],
        "policy_violation"
    );

    let records = handle.invocation_records().await;
    let cascade_records: Vec<_> = records
        .iter()
        .filter(|record| record.function_id == fid("alpha::cascade"))
        .collect();
    assert_eq!(
        cascade_records.len(),
        2,
        "root invocation and failed cascade attempt should both be ledgered"
    );
    assert!(cascade_records.iter().any(|record| record.succeeded));
    let failed_cascade = cascade_records
        .iter()
        .find(|record| !record.succeeded)
        .expect("over-depth cascade attempt should be ledgered as failed");
    assert_eq!(failed_cascade.trigger_id, Some(trigger_id));
    assert_eq!(failed_cascade.trace_id, trace("cascade-trace"));
    assert!(matches!(
        failed_cascade.error.as_ref(),
        Some(EngineError::PolicyViolation(message))
            if message.contains("trigger cascade depth")
    ));
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
async fn trigger_runtime_records_current_target_revision_after_promotion() {
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
    let trigger = TriggerDefinition::new(
        trigger_id.clone(),
        wid("alpha"),
        TriggerTypeId::new("manual").unwrap(),
        fid("alpha::echo"),
        grant("manual-grant"),
    );
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
    assert_eq!(result.error, None);

    let host = handle.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(record.function_id, fid("alpha::echo"));
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert!(
        record.function_revision > revision,
        "ledger should record the current target revision at execution time"
    );
    assert_eq!(record.error, None);
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

fn loss_tolerant_void_function(id: &str, owner: &str) -> FunctionDefinition {
    let mut function = FunctionDefinition::new(
        fid(id),
        wid(owner),
        "loss-tolerant telemetry",
        VisibilityScope::Agent,
        EffectClass::AppendOnlyEvent,
    )
    .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Void])
    .with_idempotency(IdempotencyContract::caller_session());
    function.metadata = json!({
        "delivery": {
            "voidLossTolerant": true
        }
    });
    function
}

#[derive(Clone)]
struct CaptureInvocationHandler {
    calls: Arc<AtomicUsize>,
    invocations: Arc<Mutex<Vec<Invocation>>>,
}

#[async_trait]
impl InProcessFunctionHandler for CaptureInvocationHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.invocations.lock().unwrap().push(invocation.clone());
        Ok(json!({
            "payload": invocation.payload,
            "deliveryMode": invocation.delivery_mode.as_str(),
        }))
    }
}

#[derive(Clone)]
struct CascadingTriggerHandler {
    handle: EngineHostHandle,
    trigger_id: TriggerId,
    calls: Arc<AtomicUsize>,
    invocations: Arc<Mutex<Vec<Invocation>>>,
}

#[async_trait]
impl InProcessFunctionHandler for CascadingTriggerHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        self.invocations.lock().unwrap().push(invocation.clone());
        let cascade = if call == 1 {
            let mut request = TriggerDispatchRequest::new(
                self.trigger_id.clone(),
                json!({"cascade": true}),
                invocation.causal_context.actor_id.clone(),
                invocation.causal_context.actor_kind.clone(),
            );
            request.authority_scopes = invocation.causal_context.authority_scopes.clone();
            request.runtime_metadata = invocation.causal_context.runtime_metadata.clone();
            request.trace_id = Some(invocation.causal_context.trace_id.clone());
            request.parent_invocation_id = Some(invocation.id.clone());
            request.session_id = invocation.causal_context.session_id.clone();
            request.workspace_id = invocation.causal_context.workspace_id.clone();
            let result = EngineTriggerRuntime::dispatch(&self.handle, request).await;
            let kind = match result.error.as_ref() {
                Some(EngineError::PolicyViolation(_)) => Some("policy_violation"),
                Some(_) => Some("unexpected_error"),
                None => None,
            };
            json!({
                "error": result.error.as_ref().map(|error| error.to_string()),
                "kind": kind,
            })
        } else {
            Value::Null
        };
        Ok(json!({
            "call": call,
            "cascadeError": cascade,
        }))
    }
}
