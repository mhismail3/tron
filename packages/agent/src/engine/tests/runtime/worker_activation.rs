use super::external_worker_helpers::*;
use super::*;
use crate::engine::{EngineGrantLifecycle, WorkerVisibility};

#[tokio::test]
async fn worker_activation_runtime_connects_registers_invokes_and_disconnects_volatile_function() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let (activation_id, hello, expected_function) =
        issued_activation_bundle(&handle, "runtime-valid", "activated_runtime::echo").await;
    let function_id = expected_function.id.clone();
    let worker_id = expected_function.owner_worker.clone();

    let before_registration = handle
        .inspect_function(
            &function_id,
            Some(
                &ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
                    .with_session_id("session-a"),
            ),
        )
        .await;
    assert!(matches!(
        before_registration,
        Err(EngineError::NotFound { .. })
    ));

    handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "saawa-worker-lifecycle",
                "topic": "worker.lifecycle",
                "sessionId": "session-a"
            }),
            mutating_causal("saawa-worker-lifecycle-sub").with_scope("stream.write"),
        ))
        .await;

    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let snapshot = runtime.hello(hello).await.unwrap();
    assert!(
        snapshot
            .functions
            .iter()
            .all(|function| function.id != function_id)
    );
    assert_eq!(
        activation_resource_status(&handle, &activation_id).await,
        "connected"
    );

    runtime
        .attach_invoker(worker_id.clone(), Arc::new(EchoExternalInvoker))
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: expected_function.clone(),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    assert_eq!(
        activation_resource_status(&handle, &activation_id).await,
        "registered"
    );

    let invoked = handle
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"message": "activated"}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(invoked.error, None);
    assert_eq!(
        invoked.value.as_ref().unwrap()["functionId"],
        function_id.as_str()
    );
    assert_eq!(
        invoked.value.as_ref().unwrap()["payload"]["message"],
        "activated"
    );

    runtime
        .disconnect(super::WorkerDisconnect {
            worker_id: worker_id.clone(),
            reason: "activation test complete".to_owned(),
        })
        .await
        .unwrap();
    assert_eq!(
        activation_resource_status(&handle, &activation_id).await,
        "disconnected"
    );
    assert!(matches!(
        handle.inspect_function(&function_id, None).await,
        Err(EngineError::NotFound { .. })
    ));

    let page = handle
        .poll_stream(
            "saawa-worker-lifecycle",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    let event_types = page
        .events
        .iter()
        .map(|event| event.payload["eventType"].as_str().unwrap_or_default())
        .collect::<Vec<_>>();
    assert!(event_types.contains(&"worker.connected"));
    assert!(event_types.contains(&"worker.function_registered"));
    assert!(event_types.contains(&"worker.disconnected"));
    assert!(event_types.contains(&"worker.unregistered"));
}

#[tokio::test]
async fn worker_activation_hello_rejects_token_scope_expansion_durable_and_revoked_grant() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let (_activation_id, hello, _expected_function) =
        issued_activation_bundle(&handle, "runtime-reject", "activated_reject::echo").await;

    let mut wrong_activation = hello.clone();
    wrong_activation.worker_token.activation_resource_id =
        Some("worker_activation:missing".to_owned());
    let error = EngineExternalWorkerRuntime::new(handle.clone())
        .hello(wrong_activation)
        .await
        .unwrap_err();
    assert!(matches!(error, EngineError::NotFound { .. }));

    let mut durable = hello.clone();
    durable.registration_mode = super::WorkerRegistrationMode::Durable;
    let error = EngineExternalWorkerRuntime::new(handle.clone())
        .hello(durable)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("volatile")
    ));

    let mut system_visibility = hello.clone();
    system_visibility.default_visibility = WorkerVisibility::System;
    system_visibility.worker_token.visibility_ceiling = WorkerVisibility::System;
    let error = EngineExternalWorkerRuntime::new(handle.clone())
        .hello(system_visibility)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("visibility")
            || message.contains("token fingerprint")
    ));

    let mut namespace_expansion = hello.clone();
    namespace_expansion
        .worker
        .namespace_claims
        .push("other".to_owned());
    let error = EngineExternalWorkerRuntime::new(handle.clone())
        .hello(namespace_expansion)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("exceeds scoped token claims")
    ));

    let mut wrong_session = hello.clone();
    wrong_session.session_id = Some("session-b".to_owned());
    let error = EngineExternalWorkerRuntime::new(handle.clone())
        .hello(wrong_session)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("sessionId")
    ));

    let mut wildcard_selector = hello.clone();
    wildcard_selector.worker_token.resource_selectors = vec!["*".to_owned()];
    let error = EngineExternalWorkerRuntime::new(handle.clone())
        .hello(wildcard_selector)
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("wildcard selectors")
    ));

    let revoke = handle
        .invoke(host_invocation(
            "grant::revoke",
            json!({"grantId": hello.worker_token.authority_grant_id.as_str()}),
            CausalContext::new(
                actor("admin"),
                ActorKind::Admin,
                grant("grant"),
                trace("saawa-revoke-activation-grant"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("saawa-revoke-activation-grant"),
        ))
        .await;
    assert_eq!(revoke.error, None);
    assert_eq!(
        handle
            .inspect_authority_grant(&hello.worker_token.authority_grant_id)
            .await
            .unwrap()
            .unwrap()
            .lifecycle,
        EngineGrantLifecycle::Revoked
    );
    let error = EngineExternalWorkerRuntime::new(handle.clone())
        .hello(hello.clone())
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("revoked")
    ));
    let activation_id = hello
        .worker_token
        .activation_resource_id
        .as_deref()
        .unwrap();
    assert_eq!(
        activation_resource_status(&handle, activation_id).await,
        "revoked"
    );
}

#[tokio::test]
async fn worker_activation_registration_rejects_function_metadata_and_trigger_expansion() {
    let (mut runtime, _handle, expected) =
        connected_activation_runtime("registration-wrong-id", "activated_register::expected").await;
    let mut wrong_id = expected.clone();
    wrong_id.id = fid("activated_register::other");
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: wrong_id,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("function id")
    ));

    let (mut runtime, _handle, expected) =
        connected_activation_runtime("registration-wrong-owner", "activated_owner::echo").await;
    let mut wrong_owner = expected.clone();
    wrong_owner.owner_worker = wid("other-worker");
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: wrong_owner,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    match error {
        EngineError::NotFound { .. } => {}
        EngineError::PolicyViolation(message) if message.contains("owner worker") => {}
        other => panic!("unexpected wrong-owner rejection: {other:?}"),
    }

    let (mut runtime, _handle, expected) =
        connected_activation_runtime("registration-missing-schema", "activated_schema::echo").await;
    let mut missing_schema = expected.clone();
    missing_schema.request_schema = None;
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: missing_schema,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("contract")
    ));

    let (mut runtime, _handle, expected) =
        connected_activation_runtime("registration-wrong-plugin", "activated_plugin::echo").await;
    let mut wrong_plugin = expected.clone();
    wrong_plugin.metadata["pluginId"] = json!("session_generated.other-plugin");
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: wrong_plugin,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("metadata pluginId")
    ));

    let (mut runtime, _handle, expected) =
        connected_activation_runtime("registration-wrong-trust", "activated_trust::echo").await;
    let mut wrong_trust = expected.clone();
    wrong_trust.metadata["trustTier"] = json!("first_party_signed");
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: wrong_trust,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("metadata trustTier")
    ));

    let (mut runtime, _handle, expected) =
        connected_activation_runtime("registration-wrong-signature", "activated_signature::echo")
            .await;
    let mut wrong_signature = expected.clone();
    wrong_signature.metadata["signatureStatus"] = json!("unsigned");
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: wrong_signature,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("metadata signatureStatus")
    ));

    let (mut runtime, _handle, expected) =
        connected_activation_runtime("registration-trigger", "activated_trigger::echo").await;
    let mut trigger = TriggerDefinition::new(
        TriggerId::new("manual:activated_trigger.echo").unwrap(),
        expected.owner_worker.clone(),
        TriggerTypeId::new("manual").unwrap(),
        expected.id.clone(),
        expected
            .metadata
            .get("authorityGrantId")
            .and_then(Value::as_str)
            .map(grant)
            .unwrap_or_else(|| grant("worker-runtime")),
    );
    trigger.visibility = VisibilityScope::Session;
    let error = runtime
        .register_trigger(super::RegisterTrigger {
            definition: trigger,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("cannot register triggers")
    ));

    let (mut runtime, _handle, expected) =
        connected_activation_runtime("registration-extra-function", "activated_extra::echo").await;
    runtime
        .register_function(super::RegisterFunction {
            definition: expected.clone(),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    let mut extra = expected.clone();
    extra.id = fid("activated_extra::other");
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: extra,
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("only the expected function")
    ));
}

async fn issued_activation_bundle(
    handle: &EngineHostHandle,
    suffix: &str,
    function_id: &str,
) -> (String, WorkerHello, FunctionDefinition) {
    let refs = create_worker_activation_governance(
        handle,
        WorkerActivationGovernanceConfig::session(suffix, function_id),
    )
    .await;
    let issued = issue_worker_activation(handle, &refs, &format!("saawa-{suffix}-issue")).await;
    assert_eq!(issued.error, None, "activation issue failed: {issued:?}");
    let value = issued.value.as_ref().unwrap();
    let activation_id = value["activationResourceId"].as_str().unwrap().to_owned();
    let hello = serde_json::from_value(value["activationBundle"]["workerHello"].clone()).unwrap();
    let expected_function =
        serde_json::from_value(value["activationBundle"]["expectedFunctionDefinition"].clone())
            .unwrap();
    (activation_id, hello, expected_function)
}

async fn connected_activation_runtime(
    suffix: &str,
    function_id: &str,
) -> (
    EngineExternalWorkerRuntime,
    EngineHostHandle,
    FunctionDefinition,
) {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let (_activation_id, hello, expected_function) =
        issued_activation_bundle(&handle, suffix, function_id).await;
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    runtime.hello(hello).await.unwrap();
    runtime
        .attach_invoker(
            expected_function.owner_worker.clone(),
            Arc::new(EchoExternalInvoker),
        )
        .unwrap();
    (runtime, handle, expected_function)
}

async fn activation_resource_status(handle: &EngineHostHandle, activation_id: &str) -> String {
    let inspection = handle
        .inspect_resource(activation_id)
        .await
        .unwrap()
        .expect("activation resource should exist");
    let current = inspection.resource.current_version_id.as_ref().unwrap();
    let version = inspection
        .versions
        .iter()
        .find(|version| &version.version_id == current)
        .unwrap();
    assert_eq!(inspection.resource.lifecycle, version.payload["status"]);
    version.payload["status"].as_str().unwrap().to_owned()
}
