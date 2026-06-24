use super::*;

#[tokio::test]
async fn engine_host_handle_engine_invoke_spends_parent_budget_before_regular_child_prepare() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker(worker("w1", "alpha"), true)
        .await
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    handle
        .register_function(
            read_function("alpha::counted", "w1"),
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            true,
        )
        .await
        .unwrap();
    derive_budget_invocation_grant(
        &handle,
        "delegated-regular-one-shot",
        1,
        &["engine::invoke", "alpha::counted"],
        &["engine", "alpha"],
        &["*"],
    )
    .await;

    let result = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "alpha::counted",
                "payload": {"x": 1}
            }),
            budget_context("delegated-regular-one-shot", "delegated-regular-wrapper"),
        ))
        .await;

    assert_eq!(result.error, None);
    let value = result.value.as_ref().unwrap();
    assert_eq!(value["child"]["functionId"], "alpha::counted");
    assert!(
        value["child"]["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("budget remainingInvocations is exhausted"),
        "{value:?}"
    );
    assert_eq!(
        calls.load(Ordering::SeqCst),
        0,
        "child handler must not run after the parent wrapper spends the one-shot budget"
    );
    let consumed = handle
        .inspect_authority_grant(&grant("delegated-regular-one-shot"))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(consumed.budget["remainingInvocations"], json!(0));
}

#[tokio::test]
async fn engine_host_handle_engine_invoke_spends_parent_budget_before_host_dispatched_child() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    let worker_id = wid("volatile-budget-worker");
    handle
        .register_worker(worker("volatile-budget-worker", "budget_worker"), true)
        .await
        .unwrap();
    derive_budget_invocation_grant(
        &handle,
        "delegated-worker-one-shot",
        1,
        &["engine::invoke", "worker::disconnect"],
        &["engine", "worker"],
        &["worker.write"],
    )
    .await;

    let result = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "worker::disconnect",
                "payload": {"workerId": worker_id.as_str()},
                "idempotencyKey": "delegated-worker-disconnect"
            }),
            budget_context("delegated-worker-one-shot", "delegated-worker-wrapper")
                .with_scope("worker.write"),
        ))
        .await;

    assert_eq!(result.error, None);
    let value = result.value.as_ref().unwrap();
    assert_eq!(value["child"]["functionId"], "worker::disconnect");
    assert!(
        value["child"]["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("budget remainingInvocations is exhausted"),
        "{value:?}"
    );
    assert_eq!(
        handle.worker_is_volatile(&worker_id).await,
        Some(true),
        "host-dispatched child must not disconnect the volatile worker after parent budget use"
    );
    let consumed = handle
        .inspect_authority_grant(&grant("delegated-worker-one-shot"))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(consumed.budget["remainingInvocations"], json!(0));
}

#[tokio::test]
async fn engine_host_handle_engine_invoke_exhausted_parent_budget_stops_before_child_prepare() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker(worker("w1", "alpha"), true)
        .await
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    handle
        .register_function(
            read_function("alpha::counted", "w1"),
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            true,
        )
        .await
        .unwrap();
    derive_budget_invocation_grant(
        &handle,
        "delegated-parent-exhausted",
        0,
        &["engine::invoke", "alpha::counted"],
        &["engine", "alpha"],
        &["*"],
    )
    .await;

    let result = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "alpha::counted",
                "payload": {"x": 1}
            }),
            budget_context(
                "delegated-parent-exhausted",
                "delegated-parent-exhausted-wrapper",
            ),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("budget remainingInvocations is exhausted")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let records = handle.invocation_records().await;
    assert!(
        !records
            .iter()
            .any(|record| record.function_id == fid("alpha::counted")),
        "exhausted parent wrapper must fail before child invocation preparation"
    );
    let grant = handle
        .inspect_authority_grant(&grant("delegated-parent-exhausted"))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(grant.budget["remainingInvocations"], json!(0));
}

async fn derive_budget_invocation_grant(
    handle: &EngineHostHandle,
    grant_id: &str,
    remaining_invocations: u64,
    allowed_capabilities: &[&str],
    allowed_namespaces: &[&str],
    allowed_authority_scopes: &[&str],
) {
    let result = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": grant_id,
                "parentGrantId": "grant",
                "allowedCapabilities": allowed_capabilities,
                "allowedNamespaces": allowed_namespaces,
                "allowedAuthorityScopes": allowed_authority_scopes,
                "allowedResourceKinds": ["*"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "high",
                "budget": {"remainingInvocations": remaining_invocations},
                "provenance": {"source": "delegated-engine-invoke-budget-ordering-test"}
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace(&format!("derive-{grant_id}")),
            )
            .with_scope("grant.write")
            .with_idempotency_key(format!("derive-{grant_id}")),
        ))
        .await;
    assert!(
        result.error.is_none(),
        "failed to derive budget grant {grant_id}: {:?}",
        result.error
    );
}

fn budget_context(grant_id: &str, trace_id: &str) -> CausalContext {
    CausalContext::new(
        actor("agent"),
        ActorKind::Agent,
        grant(grant_id),
        trace(trace_id),
    )
}
