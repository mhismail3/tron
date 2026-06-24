use super::*;
use async_trait::async_trait;

pub(in crate::engine::tests) fn grant_context(trace_id: &str, key: &str) -> CausalContext {
    CausalContext::new(
        actor("system"),
        ActorKind::System,
        grant("grant"),
        trace(trace_id),
    )
    .with_scope("grant.write")
    .with_idempotency_key(key)
}

pub(in crate::engine::tests) fn base_child_grant_payload(
    grant_id: &str,
    parent_grant_id: &str,
    root: &str,
) -> Value {
    json!({
        "grantId": grant_id,
        "parentGrantId": parent_grant_id,
        "allowedCapabilities": ["demo::write"],
        "allowedNamespaces": ["demo"],
        "allowedAuthorityScopes": ["demo.write"],
        "allowedResourceKinds": ["artifact"],
        "resourceSelectors": ["resource:artifact-a"],
        "fileRoots": [root],
        "networkPolicy": "loopback",
        "maxRisk": "medium",
        "budget": {"remainingInvocations": 5, "maxTokens": 100},
        "expiresAt": (Utc::now() + ChronoDuration::minutes(30)).to_rfc3339(),
        "canDelegate": false,
        "provenance": {"source": "grant-authority-test"}
    })
}

pub(in crate::engine::tests) async fn derive_grant(
    handle: &EngineHostHandle,
    payload: Value,
    key: &str,
) -> crate::engine::invocation::model::InvocationResult {
    handle
        .invoke(host_invocation(
            "grant::derive",
            payload,
            grant_context(&format!("derive-{key}"), key),
        ))
        .await
}

pub(in crate::engine::tests) async fn grant_exists(
    handle: &EngineHostHandle,
    grant_id: &str,
) -> bool {
    let inspected = handle
        .invoke(host_invocation(
            "grant::inspect",
            json!({"grantId": grant_id}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace(&format!("inspect-{grant_id}")),
            )
            .with_scope("grant.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    !inspected.value.as_ref().unwrap()["grant"].is_null()
}

pub(in crate::engine::tests) async fn derive_bootstrap_grant(
    handle: &EngineHostHandle,
    grant_id: &str,
    mut payload: Value,
) -> crate::engine::invocation::model::InvocationResult {
    let object = payload.as_object_mut().unwrap();
    object.insert("grantId".to_owned(), json!(grant_id));
    object.insert("parentGrantId".to_owned(), json!("grant"));
    derive_grant(handle, payload, grant_id).await
}

#[derive(Clone)]
pub(in crate::engine::tests) struct CountingResourceHandler {
    pub(in crate::engine::tests) calls: Arc<AtomicUsize>,
}

#[async_trait]
impl InProcessFunctionHandler for CountingResourceHandler {
    async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        Ok(json!({
            "call": call,
            "resourceRefs": [{
                "resourceId": format!("artifact-from-grant-{call}"),
                "kind": "artifact",
                "versionId": format!("version-from-grant-{call}"),
                "role": "created",
                "contentHash": format!("hash-from-grant-{call}")
            }]
        }))
    }
}
