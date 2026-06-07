//! Shared fixtures for engine test modules.

pub(in crate::engine::tests) use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

pub(in crate::engine::tests) use async_trait::async_trait;
pub(in crate::engine::tests) use chrono::{Duration as ChronoDuration, Utc};
pub(in crate::engine::tests) use serde_json::{Value, json};
pub(in crate::engine::tests) use tokio::sync::{Barrier, Notify};

pub(in crate::engine::tests) use crate::engine::discovery::{
    ActorContext, ActorKind, FunctionQuery,
};
pub(in crate::engine::tests) use crate::engine::errors::{EngineError, Result};
pub(in crate::engine::tests) use crate::engine::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, TriggerTypeId,
    WorkerId,
};
pub(in crate::engine::tests) use crate::engine::invocation::{
    CausalContext, InProcessFunctionHandler, Invocation,
};
pub(in crate::engine::tests) use crate::engine::ledger::{
    EngineLedgerStore, IdempotencyKey, IdempotencyReservation, IdempotencyReservationOutcome,
    IdempotencyStatus, InMemoryEngineLedgerStore, SqliteEngineLedgerStore, StoredInvocationOutcome,
};
pub(in crate::engine::tests) use crate::engine::registry::LiveCatalog;
pub(in crate::engine::tests) use crate::engine::types::{
    AuthorityRequirement, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CatalogSubjectKind, CompensationContract, CompensationKind, DeliveryMode,
    DurableOutputContract, EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision,
    IdempotencyContract, IdempotencyKeySource, IdempotencyScope, LedgerKind, Provenance,
    ReplayBehavior, ResourceLeaseRequirement, RiskLevel, TriggerDefinition, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition, WorkerKind,
};
pub(in crate::engine::tests) use crate::engine::{
    CatalogWatchRequest, EngineExternalWorkerRuntime, EngineHost, EngineHostHandle,
    EngineQueueDrainer, EngineResourceLeaseStatus, EngineTriggerRuntime, PublishStreamEvent,
    RegisterFunction, RegisterTrigger, SqliteEngineStreamStore, StreamActorScope, StreamCursor,
    TriggerDispatchRequest, WorkerDisconnect, WorkerHello, WorkerInvocationResult, WorkerInvoke,
    WorkerLifecycleState, WorkerProtocolMessage, WorkerRegistrationMode, WorkerStreamPublish,
};
pub(in crate::engine::tests) use crate::engine::{external, host, ids, queue};

pub(in crate::engine::tests) fn wid(value: &str) -> WorkerId {
    WorkerId::new(value).unwrap()
}

pub(in crate::engine::tests) fn fid(value: &str) -> FunctionId {
    FunctionId::new(value).unwrap()
}

pub(in crate::engine::tests) fn actor(value: &str) -> ActorId {
    ActorId::new(value).unwrap()
}

pub(in crate::engine::tests) fn grant(value: &str) -> AuthorityGrantId {
    AuthorityGrantId::new(value).unwrap()
}

pub(in crate::engine::tests) fn trace(value: &str) -> TraceId {
    TraceId::new(value).unwrap()
}

pub(in crate::engine::tests) fn worker(id: &str, namespace: &str) -> WorkerDefinition {
    WorkerDefinition::new(
        wid(id),
        WorkerKind::InProcess,
        actor("owner"),
        grant("grant"),
    )
    .with_namespace_claim(namespace)
}

pub(in crate::engine::tests) fn read_function(id: &str, owner: &str) -> FunctionDefinition {
    FunctionDefinition::new(
        fid(id),
        wid(owner),
        "read function",
        VisibilityScope::Agent,
        EffectClass::PureRead,
    )
}

pub(in crate::engine::tests) fn external_visible_function(
    mut function: FunctionDefinition,
) -> FunctionDefinition {
    let namespace = function.id.namespace().to_owned();
    let local_name = function
        .id
        .as_str()
        .split_once("::")
        .map(|(_, local)| local)
        .unwrap_or(function.id.as_str())
        .to_owned();
    function.request_schema = Some(json!({
        "type": "object",
        "additionalProperties": true
    }));
    function.response_schema = Some(json!({
        "type": "object",
        "additionalProperties": true
    }));
    function.metadata = json!({
        "contractId": function.id.as_str(),
        "implementationId": format!("session_generated.{namespace}.{local_name}"),
        "pluginId": format!("session_generated.{}", function.owner_worker.as_str()),
        "trustTier": "session_generated",
        "contextPrimerLevel": "catalog",
        "runtimeRequirements": {
            "workerKind": "external",
            "deliveryModes": ["Sync"]
        },
        "examples": []
    });
    function
}

pub(in crate::engine::tests) fn write_function(id: &str, owner: &str) -> FunctionDefinition {
    FunctionDefinition::new(
        fid(id),
        wid(owner),
        "write function",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_idempotency(IdempotencyContract::caller_session())
}

pub(in crate::engine::tests) fn reject_idempotency() -> IdempotencyContract {
    IdempotencyContract {
        key_source: IdempotencyKeySource::Caller,
        dedupe_scope: VisibilityScope::Session,
        replay_behavior: ReplayBehavior::Reject,
        ledger_kind: LedgerKind::InMemory,
    }
}

pub(in crate::engine::tests) fn noop_idempotency() -> IdempotencyContract {
    IdempotencyContract {
        key_source: IdempotencyKeySource::Caller,
        dedupe_scope: VisibilityScope::Session,
        replay_behavior: ReplayBehavior::NoOp,
        ledger_kind: LedgerKind::InMemory,
    }
}

#[derive(Clone)]
pub(in crate::engine::tests) struct EchoHandler;

#[async_trait]
impl InProcessFunctionHandler for EchoHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        Ok(json!({
            "echo": invocation.payload,
            "catalogRevision": invocation.causal_context.catalog_revision.0,
        }))
    }
}

pub(in crate::engine::tests) struct FailHandler;

#[async_trait]
impl InProcessFunctionHandler for FailHandler {
    async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
        Err(EngineError::HandlerFailed("boom".to_owned()))
    }
}

#[derive(Clone)]
pub(in crate::engine::tests) struct StaticValueHandler(pub(in crate::engine::tests) Value);

#[async_trait]
impl InProcessFunctionHandler for StaticValueHandler {
    async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
        Ok(self.0.clone())
    }
}

#[derive(Clone)]
pub(in crate::engine::tests) struct BlockingHandler {
    pub(in crate::engine::tests) started: Arc<Barrier>,
    pub(in crate::engine::tests) release: Arc<Notify>,
}

#[async_trait]
impl InProcessFunctionHandler for BlockingHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        self.started.wait().await;
        self.release.notified().await;
        Ok(json!({
            "payload": invocation.payload,
            "catalogRevision": invocation.causal_context.catalog_revision.0,
        }))
    }
}

#[derive(Clone)]
pub(in crate::engine::tests) struct CountingFailHandler {
    pub(in crate::engine::tests) calls: Arc<AtomicUsize>,
}

#[async_trait]
impl InProcessFunctionHandler for CountingFailHandler {
    async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
        let _ = self.calls.fetch_add(1, Ordering::SeqCst);
        Err(EngineError::HandlerFailed("boom".to_owned()))
    }
}

#[derive(Clone)]
pub(in crate::engine::tests) struct CountingHandler {
    pub(in crate::engine::tests) calls: Arc<AtomicUsize>,
}

#[async_trait]
impl InProcessFunctionHandler for CountingHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        Ok(json!({
            "call": call,
            "payload": invocation.payload,
        }))
    }
}

pub(in crate::engine::tests) struct ReserveFailingLedger;

impl EngineLedgerStore for ReserveFailingLedger {
    fn append_catalog_change(
        &mut self,
        _change: &crate::engine::types::CatalogChange,
    ) -> Result<()> {
        Ok(())
    }

    fn list_catalog_changes(&self) -> Result<Vec<crate::engine::types::CatalogChange>> {
        Ok(Vec::new())
    }

    fn catalog_changes_after(
        &self,
        _revision: CatalogRevision,
        _limit: usize,
    ) -> Result<Vec<crate::engine::types::CatalogChange>> {
        Ok(Vec::new())
    }

    fn append_invocation(
        &mut self,
        _record: &crate::engine::invocation::InvocationRecord,
    ) -> Result<()> {
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<crate::engine::invocation::InvocationRecord>> {
        Ok(Vec::new())
    }

    fn reserve_idempotency(
        &mut self,
        _reservation: IdempotencyReservation,
    ) -> Result<IdempotencyReservationOutcome> {
        Err(EngineError::LedgerFailure {
            operation: "reserve_idempotency",
            message: "injected failure".to_owned(),
        })
    }

    fn complete_idempotency(
        &mut self,
        _key: &IdempotencyKey,
        _invocation_id: &InvocationId,
        _outcome: StoredInvocationOutcome,
    ) -> Result<()> {
        Ok(())
    }
}

pub(in crate::engine::tests) struct CatalogChangeFailingLedger;

impl EngineLedgerStore for CatalogChangeFailingLedger {
    fn append_catalog_change(
        &mut self,
        _change: &crate::engine::types::CatalogChange,
    ) -> Result<()> {
        Err(EngineError::LedgerFailure {
            operation: "append_catalog_change",
            message: "injected failure".to_owned(),
        })
    }

    fn list_catalog_changes(&self) -> Result<Vec<crate::engine::types::CatalogChange>> {
        Ok(Vec::new())
    }

    fn catalog_changes_after(
        &self,
        _revision: CatalogRevision,
        _limit: usize,
    ) -> Result<Vec<crate::engine::types::CatalogChange>> {
        Ok(Vec::new())
    }

    fn append_invocation(
        &mut self,
        _record: &crate::engine::invocation::InvocationRecord,
    ) -> Result<()> {
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<crate::engine::invocation::InvocationRecord>> {
        Ok(Vec::new())
    }

    fn reserve_idempotency(
        &mut self,
        _reservation: IdempotencyReservation,
    ) -> Result<IdempotencyReservationOutcome> {
        Err(EngineError::LedgerFailure {
            operation: "reserve_idempotency",
            message: "unexpected reservation".to_owned(),
        })
    }

    fn complete_idempotency(
        &mut self,
        _key: &IdempotencyKey,
        _invocation_id: &InvocationId,
        _outcome: StoredInvocationOutcome,
    ) -> Result<()> {
        Ok(())
    }
}

pub(in crate::engine::tests) fn handler() -> Arc<dyn InProcessFunctionHandler> {
    Arc::new(EchoHandler)
}

pub(in crate::engine::tests) fn causal() -> CausalContext {
    CausalContext::new(
        actor("agent"),
        ActorKind::Agent,
        grant("grant"),
        trace("trace"),
    )
}

pub(in crate::engine::tests) fn mutating_causal(key: &str) -> CausalContext {
    causal()
        .with_session_id("session-a")
        .with_workspace_id("workspace-a")
        .with_idempotency_key(key)
}

pub(in crate::engine::tests) fn host_invocation(
    function_id: &str,
    payload: Value,
    context: CausalContext,
) -> Invocation {
    Invocation::new_sync(fid(function_id), payload, context)
}

pub(in crate::engine::tests) fn engine_ledger_contract(store: &mut dyn EngineLedgerStore) {
    let change = crate::engine::types::CatalogChange {
        id: "catalog_change_test".to_owned(),
        before: CatalogRevision(0),
        after: CatalogRevision(1),
        kind: CatalogChangeKind::FunctionRegistered,
        subject_id: "alpha::read".to_owned(),
        subject_kind: CatalogSubjectKind::Function,
        class: CatalogChangeClass::Availability,
        visibility: VisibilityScope::Agent,
        session_id: None,
        workspace_id: None,
        owner_worker: Some(wid("w1")),
        timestamp: chrono::Utc::now(),
    };
    store.append_catalog_change(&change).unwrap();
    assert_eq!(store.list_catalog_changes().unwrap(), vec![change.clone()]);
    assert_eq!(
        store.catalog_changes_after(CatalogRevision(0), 10).unwrap(),
        vec![change]
    );

    let invocation = Invocation::new_sync(
        fid("alpha::read"),
        json!({"x": 1}),
        causal()
            .with_session_id("session-a")
            .with_workspace_id("workspace-a"),
    );
    let result = crate::engine::invocation::InvocationResult::success(
        &invocation,
        wid("w1"),
        FunctionRevision(1),
        CatalogRevision(1),
        json!({"ok": true}),
    );
    let record =
        crate::engine::invocation::InvocationRecord::from_result(&invocation, &result, None);
    store.append_invocation(&record).unwrap();
    let records = store.list_invocations().unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].invocation_id, invocation.id);
    assert_eq!(records[0].session_id.as_deref(), Some("session-a"));
    assert_eq!(records[0].workspace_id.as_deref(), Some("workspace-a"));
    assert_eq!(records[0].result_value, Some(json!({"ok": true})));

    let key = IdempotencyKey {
        function_id: fid("alpha::write"),
        scope: IdempotencyScope::new("session", "session-a"),
        key: "dedupe-key".to_owned(),
    };
    let reservation = IdempotencyReservation {
        key: key.clone(),
        payload_fingerprint: "fingerprint-a".to_owned(),
        function_revision: FunctionRevision(1),
        replay_behavior: ReplayBehavior::ReturnPrevious,
        invocation_id: InvocationId::new("reservation-one").unwrap(),
    };
    let first = store.reserve_idempotency(reservation.clone()).unwrap();
    assert!(matches!(first, IdempotencyReservationOutcome::Reserved(_)));
    let second = store.reserve_idempotency(reservation.clone()).unwrap();
    let IdempotencyReservationOutcome::Existing(existing) = second else {
        panic!("second reservation should see existing in-progress entry");
    };
    assert_eq!(existing.status, IdempotencyStatus::InProgress);
    assert_eq!(existing.payload_fingerprint, "fingerprint-a");

    store
        .complete_idempotency(
            &key,
            &reservation.invocation_id,
            StoredInvocationOutcome::from_result(&result),
        )
        .unwrap();
    let completed = store.reserve_idempotency(reservation).unwrap();
    let IdempotencyReservationOutcome::Existing(existing) = completed else {
        panic!("completed reservation should be returned as existing");
    };
    assert_eq!(existing.status, IdempotencyStatus::Completed);
    assert_eq!(existing.outcome.unwrap().value, Some(json!({"ok": true})));
}
