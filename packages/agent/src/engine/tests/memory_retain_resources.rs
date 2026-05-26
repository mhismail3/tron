use super::*;

use crate::domains::session::event_store::AppendOptions;
use crate::domains::session::event_store::types::EventType;

fn memory_write_context(key: &str, session_id: &str) -> CausalContext {
    CausalContext::new(
        actor("system:memory-test"),
        ActorKind::System,
        grant("engine-system"),
        trace("memory-retain-resource-test"),
    )
    .with_session_id(session_id)
    .with_workspace_id("workspace-a")
    .with_scope("memory.write")
    .with_idempotency_key(key)
}

async fn memory_artifacts(handle: &EngineHostHandle) -> Vec<Value> {
    let listed = handle
        .invoke(host_invocation(
            "resource::list",
            json!({"kind": "artifact", "limit": 10_000}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(listed.error, None);
    listed.value.unwrap()["resources"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|resource| {
            resource["resourceId"].as_str().is_some_and(|id| {
                id.starts_with("artifact:memory-journal:")
                    || id.starts_with("artifact:memory-rule:")
                    || id.starts_with("artifact:memory-argument:")
            })
        })
        .cloned()
        .collect()
}

async fn inspect_resource(handle: &EngineHostHandle, resource_id: &str) -> Value {
    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": resource_id}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    inspected.value.unwrap()["inspection"].clone()
}

fn current_payload(inspection: &Value) -> &Value {
    let current = inspection["resource"]["currentVersionId"].as_str().unwrap();
    inspection["versions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|version| version["versionId"] == current)
        .and_then(|version| version.get("payload"))
        .unwrap()
}

async fn wait_for_memory_retained(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    session_id: &str,
) -> Value {
    for _ in 0..40 {
        if let Some(row) = ctx
            .event_store
            .get_latest_event_by_type(session_id, "memory.retained")
            .unwrap()
        {
            return serde_json::from_str(&row.payload).unwrap();
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("memory.retained event was not persisted");
}

#[tokio::test]
async fn memory_retain_produces_resource_backed_journal_and_projection() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let created = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = created.session.id;
    ctx.event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({"content": "Remember that retain outputs must be resource-backed."}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let retained = handle
        .invoke(host_invocation(
            "memory::retain",
            json!({"sessionId": session_id.clone()}),
            memory_write_context("memory-retain-resource-backed", &session_id),
        ))
        .await;
    assert_eq!(retained.error, None);
    assert_eq!(retained.value.as_ref().unwrap()["retained"], true);

    let event_payload = wait_for_memory_retained(&ctx, &session_id).await;
    let refs = event_payload["resourceRefs"].as_array().unwrap();
    assert!(refs.iter().any(|reference| reference["kind"] == "artifact"));
    assert!(
        refs.iter()
            .any(|reference| reference["kind"] == "materialized_file")
    );
    let evidence_refs = event_payload["evidenceRefs"].as_array().unwrap();
    assert!(
        evidence_refs
            .iter()
            .any(|reference| reference["kind"] == "evidence"),
        "keyword recovery should produce inspectable evidence refs"
    );

    let journal_ref = refs
        .iter()
        .find(|reference| {
            reference["resourceId"]
                .as_str()
                .is_some_and(|id| id.starts_with("artifact:memory-journal:"))
        })
        .expect("journal artifact ref");
    let journal = inspect_resource(&handle, journal_ref["resourceId"].as_str().unwrap()).await;
    let journal_payload = current_payload(&journal);
    assert_eq!(journal_payload["metadata"]["domain"], "memory");
    assert_eq!(journal_payload["metadata"]["recordKind"], "journal");

    let evidence_ref = evidence_refs
        .iter()
        .find(|reference| reference["kind"] == "evidence")
        .expect("recovery evidence ref");
    let evidence = inspect_resource(&handle, evidence_ref["resourceId"].as_str().unwrap()).await;
    let evidence_payload = current_payload(&evidence);
    assert_eq!(
        evidence_payload["metadata"]["evidenceType"],
        "memory_retain_recovery"
    );

    let materialized_ref = refs
        .iter()
        .find(|reference| {
            reference["resourceId"]
                .as_str()
                .is_some_and(|id| id.starts_with("materialized_file:memory-session:"))
        })
        .expect("session materialized ref");
    let materialized =
        inspect_resource(&handle, materialized_ref["resourceId"].as_str().unwrap()).await;
    let materialized_payload = current_payload(&materialized);
    assert!(
        materialized_payload["content"]
            .as_str()
            .unwrap()
            .contains(&format!("Session {session_id}"))
    );
}

#[tokio::test]
async fn memory_retain_idempotency_does_not_duplicate_memory_artifacts() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    let created = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = created.session.id;
    ctx.event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({"content": "Check memory retain idempotency."}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let payload = json!({"sessionId": session_id.clone()});
    let context = memory_write_context("memory-retain-idempotent", &session_id);
    let first = handle
        .invoke(host_invocation(
            "memory::retain",
            payload.clone(),
            context.clone(),
        ))
        .await;
    assert_eq!(first.error, None);
    let _ = wait_for_memory_retained(&ctx, &session_id).await;
    let artifacts_after_first = memory_artifacts(&handle).await.len();

    let second = handle
        .invoke(host_invocation("memory::retain", payload, context))
        .await;
    assert_eq!(second.error, None);
    tokio::time::sleep(std::time::Duration::from_millis(150)).await;
    assert_eq!(memory_artifacts(&handle).await.len(), artifacts_after_first);
}
