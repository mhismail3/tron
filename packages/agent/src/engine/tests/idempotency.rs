use super::*;

#[tokio::test]
async fn mutating_invocation_missing_idempotency_key_stops_before_handler() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    catalog
        .register_function(
            write_function("alpha::write", "w1")
                .with_idempotency(IdempotencyContract::caller_session_engine_ledger()),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let result = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            causal()
                .with_session_id("session-a")
                .with_workspace_id("workspace-a")
                .with_scope("alpha.write"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("idempotency") && message.contains("alpha::write")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn hmh_f1_host_mutation_families_reject_missing_idempotency_before_payload_handling() {
    let mut host = EngineHost::new().unwrap();

    for (function_id, scope) in [
        ("worker::disconnect", "worker.write"),
        ("ui::submit_action", "ui.write"),
        ("engine::promote", "engine.promote.workspace"),
        ("queue::enqueue", "queue.write"),
        ("resource::create", "resource.write"),
    ] {
        let result = host
            .invoke(host_invocation(
                function_id,
                json!({}),
                causal()
                    .with_session_id("session-a")
                    .with_workspace_id("workspace-a")
                    .with_scope(scope),
            ))
            .await;

        assert!(
            matches!(
                result.error,
                Some(EngineError::PolicyViolation(ref message))
                    if message.contains("idempotency") && message.contains(function_id)
            ),
            "{function_id} should reject missing idempotency before payload handling: {result:?}"
        );
    }
}

#[test]
fn hmh_f1_mutating_substrate_surfaces_declare_idempotency() {
    let host = EngineHost::new().unwrap();
    let functions = host.catalog().discover_functions(&FunctionQuery {
        actor: Some(ActorContext::new(
            actor("system"),
            ActorKind::System,
            grant("engine-system"),
        )),
        include_internal: true,
        ..FunctionQuery::default()
    });

    let missing = functions
        .iter()
        .filter(|function| hmh_f1_surface(function.id.as_str()))
        .filter(|function| function.effect_class.requires_idempotency())
        .filter(|function| function.idempotency.is_none())
        .map(|function| function.id.as_str().to_owned())
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "mutating worker/ui/promotion/queue/resource surfaces missing idempotency: {missing:?}"
    );

    for required in [
        "worker::disconnect",
        "ui::submit_action",
        "engine::promote",
        "queue::enqueue",
        "resource::create",
    ] {
        let definition = functions
            .iter()
            .find(|function| function.id.as_str() == required)
            .unwrap_or_else(|| panic!("{required} must be registered for idempotency coverage"));
        assert!(
            definition.effect_class.requires_idempotency(),
            "{required} must remain classified as mutating"
        );
        assert!(
            definition.idempotency.is_some(),
            "{required} must require an idempotency contract"
        );
    }
}

fn hmh_f1_surface(function_id: &str) -> bool {
    function_id == "engine::promote"
        || function_id.starts_with("worker::")
        || function_id.starts_with("ui::")
        || function_id.starts_with("queue::")
        || function_id.starts_with("resource::")
        || function_id.starts_with("artifact::")
        || function_id.starts_with("goal::")
        || function_id.starts_with("claim::")
        || function_id.starts_with("evidence::")
        || function_id.starts_with("decision::")
        || function_id.starts_with("materialized_file::")
        || function_id.starts_with("patch::")
}
