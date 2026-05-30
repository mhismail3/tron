pub(super) use super::super::*;
pub(super) use crate::domains::capability::types::CapabilityIndexHit;
pub(super) use crate::engine::{
    ActorId, AuthorityGrantId, AuthorityRequirement, CatalogRevision, FunctionId, FunctionRevision,
    InvocationId, TraceId, VisibilityScope, WorkerId,
};
pub(super) use serde_json::json;

pub(super) fn test_function(id: &str) -> FunctionDefinition {
    FunctionDefinition::new(
        FunctionId::new(id).expect("function id"),
        WorkerId::new(id.split("::").next().expect("namespace")).expect("worker id"),
        "Searchable test function",
        VisibilityScope::System,
        EffectClass::PureRead,
    )
}

pub(super) fn test_approval_record(
    function_id: FunctionId,
    parent_invocation_id: InvocationId,
    trace_id: TraceId,
    idempotency_key: &str,
) -> EngineApprovalRecord {
    let now = chrono::Utc::now();
    EngineApprovalRecord {
        approval_id: "approval-test".to_owned(),
        function_id,
        payload: json!({ "ok": true }),
        payload_fingerprint: "fingerprint".to_owned(),
        actor_id: ActorId::new("agent:test").expect("actor id"),
        actor_kind: ActorKind::Agent,
        authority_grant_id: AuthorityGrantId::new("grant:test").expect("grant id"),
        authority_scopes: vec!["process.run".to_owned()],
        trace_id,
        parent_invocation_id: Some(parent_invocation_id),
        trigger_id: None,
        session_id: Some("session-test".to_owned()),
        workspace_id: None,
        idempotency_key: Some(idempotency_key.to_owned()),
        delivery_mode: DeliveryMode::Sync,
        status: ApprovalStatus::Executed,
        decision_actor_id: Some(ActorId::new("engine-user").expect("actor id")),
        decided_at: Some(now),
        result: Some(json!({ "exitCode": 0, "stdout": "ok\n", "resourceRefs": [] })),
        error: None,
        created_at: now,
        updated_at: now,
    }
}

pub(super) fn test_invocation_record(
    invocation_id: InvocationId,
    function: &FunctionDefinition,
    parent_invocation_id: InvocationId,
    trace_id: TraceId,
    idempotency_key: &str,
) -> InvocationRecord {
    InvocationRecord {
        invocation_id,
        function_id: function.id.clone(),
        worker_id: function.owner_worker.clone(),
        function_revision: FunctionRevision(1),
        catalog_revision: CatalogRevision(77),
        actor_id: ActorId::new("agent:test").expect("actor id"),
        actor_kind: ActorKind::Agent,
        authority_grant_id: AuthorityGrantId::new("grant:test").expect("grant id"),
        authority_scopes: vec!["process.run".to_owned()],
        trace_id,
        parent_invocation_id: Some(parent_invocation_id),
        trigger_id: None,
        session_id: Some("session-test".to_owned()),
        workspace_id: None,
        delivery_mode: DeliveryMode::Sync,
        idempotency_key: Some(idempotency_key.to_owned()),
        idempotency_scope: None,
        resource_lease_ids: Vec::new(),
        compensation_status: None,
        produced_resource_refs: Vec::new(),
        replayed_from: None,
        succeeded: true,
        result_value: Some(json!({ "exitCode": 0, "stdout": "ok\n" })),
        error: None,
        timestamp: chrono::Utc::now(),
    }
}
