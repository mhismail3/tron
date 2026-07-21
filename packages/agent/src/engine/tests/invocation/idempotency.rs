use super::*;

#[tokio::test]
async fn mutating_invocation_missing_idempotency_key_stops_before_handler() {
    let mut catalog = LiveCatalog::new();
    let calls = Arc::new(AtomicUsize::new(0));
    catalog
        .register_function(
            write_function("alpha::write", "w1")
                .with_idempotency(IdempotencyContract::caller_session_engine_ledger()),
            Arc::new(CountingHandler {
                calls: calls.clone(),
            }),
        )
        .unwrap();

    let result = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            causal()
                .with_session_id("session-a")
                .with_workspace_id("workspace-a"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("idempotency") && message.contains("alpha::write")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}
