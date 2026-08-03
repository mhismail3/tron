//! Shared fixtures for engine test modules.

pub(in crate::engine::tests) use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

pub(in crate::engine::tests) use async_trait::async_trait;
pub(in crate::engine::tests) use serde_json::{Value, json};
pub(in crate::engine::tests) use tokio::sync::{Barrier, Notify};

pub(in crate::engine::tests) use crate::engine::catalog::discovery::{ActorContext, ActorKind};
pub(in crate::engine::tests) use crate::engine::catalog::registry::LiveCatalog;
pub(in crate::engine::tests) use crate::engine::durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, InMemoryEngineLedgerStore,
    SqliteEngineLedgerStore, StoredInvocationOutcome,
};
pub(in crate::engine::tests) use crate::engine::durability::streams::SqliteEngineStreamStore;
pub(in crate::engine::tests) use crate::engine::invocation::host::{self, EngineHost};
pub(in crate::engine::tests) use crate::engine::invocation::model::{
    CausalContext, InProcessFunctionHandler, Invocation,
};
pub(in crate::engine::tests) use crate::engine::kernel::errors::{EngineError, Result};
pub(in crate::engine::tests) use crate::engine::kernel::ids;
pub(in crate::engine::tests) use crate::engine::kernel::ids::{
    ActorId, FunctionId, InvocationId, TraceId, WorkerId,
};
pub(in crate::engine::tests) use crate::engine::kernel::types::{
    CatalogRevision, EffectClass, FunctionDefinition, FunctionRevision, FunctionVisibility,
    IdempotencyContract, IdempotencyScope, RiskLevel, StreamVisibility,
};
pub(in crate::engine::tests) use crate::engine::{
    EngineHostHandle, PublishStreamEvent, StreamActorScope, StreamCursor,
};

pub(in crate::engine::tests) fn wid(value: &str) -> WorkerId {
    WorkerId::new(value).unwrap()
}

pub(in crate::engine::tests) fn fid(value: &str) -> FunctionId {
    FunctionId::new(value).unwrap()
}

pub(in crate::engine::tests) fn actor(value: &str) -> ActorId {
    ActorId::new(value).unwrap()
}

pub(in crate::engine::tests) fn trace(value: &str) -> TraceId {
    TraceId::new(value).unwrap()
}

pub(in crate::engine::tests) fn read_function(id: &str, owner: &str) -> FunctionDefinition {
    FunctionDefinition::new(
        fid(id),
        wid(owner),
        "read function",
        FunctionVisibility::Public,
        EffectClass::PureRead,
    )
}

pub(in crate::engine::tests) fn write_function(id: &str, owner: &str) -> FunctionDefinition {
    FunctionDefinition::new(
        fid(id),
        wid(owner),
        "write function",
        FunctionVisibility::Public,
        EffectClass::IdempotentWrite,
    )
    .with_idempotency(IdempotencyContract::session())
}

#[derive(Clone)]
pub(in crate::engine::tests) struct EchoHandler;

#[async_trait]
impl InProcessFunctionHandler for EchoHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        Ok(json!({
            "echo": invocation.payload,
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
    fn catalog_revision(&self) -> Result<CatalogRevision> {
        Ok(CatalogRevision(0))
    }

    fn advance_catalog_revision(
        &mut self,
        _expected: CatalogRevision,
        _next: CatalogRevision,
    ) -> Result<()> {
        Ok(())
    }

    fn append_invocation(
        &mut self,
        _record: &crate::engine::invocation::model::InvocationRecord,
    ) -> Result<()> {
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<crate::engine::invocation::model::InvocationRecord>> {
        Ok(Vec::new())
    }

    fn list_invocations_by_session(
        &self,
        _session_id: &str,
    ) -> Result<Vec<crate::engine::invocation::model::InvocationRecord>> {
        Ok(Vec::new())
    }

    fn list_idempotency_by_session(&self, _session_id: &str) -> Result<Vec<IdempotencyEntry>> {
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

pub(in crate::engine::tests) struct CatalogRevisionFailingLedger;

impl EngineLedgerStore for CatalogRevisionFailingLedger {
    fn catalog_revision(&self) -> Result<CatalogRevision> {
        Ok(CatalogRevision(0))
    }

    fn advance_catalog_revision(
        &mut self,
        _expected: CatalogRevision,
        _next: CatalogRevision,
    ) -> Result<()> {
        Err(EngineError::LedgerFailure {
            operation: "advance_catalog_revision",
            message: "injected failure".to_owned(),
        })
    }

    fn append_invocation(
        &mut self,
        _record: &crate::engine::invocation::model::InvocationRecord,
    ) -> Result<()> {
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<crate::engine::invocation::model::InvocationRecord>> {
        Ok(Vec::new())
    }

    fn list_invocations_by_session(
        &self,
        _session_id: &str,
    ) -> Result<Vec<crate::engine::invocation::model::InvocationRecord>> {
        Ok(Vec::new())
    }

    fn list_idempotency_by_session(&self, _session_id: &str) -> Result<Vec<IdempotencyEntry>> {
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
    CausalContext::new(actor("agent"), ActorKind::Agent, trace("trace"))
}

pub(in crate::engine::tests) fn mutating_causal(key: &str) -> CausalContext {
    causal()
        .with_session_id("session-a")
        .with_workspace_id("workspace-a")
        .with_idempotency_key(key)
}

pub(in crate::engine::tests) fn engine_ledger_contract(store: &mut dyn EngineLedgerStore) {
    assert_eq!(store.catalog_revision().unwrap(), CatalogRevision(0));
    store
        .advance_catalog_revision(CatalogRevision(0), CatalogRevision(1))
        .unwrap();
    assert_eq!(store.catalog_revision().unwrap(), CatalogRevision(1));
    assert!(
        store
            .advance_catalog_revision(CatalogRevision(0), CatalogRevision(1))
            .is_err()
    );
    assert_eq!(store.catalog_revision().unwrap(), CatalogRevision(1));

    let invocation = Invocation::new_sync(
        fid("alpha::read"),
        json!({"x": 1}),
        causal()
            .with_session_id("session-a")
            .with_workspace_id("workspace-a"),
    );
    let result = crate::engine::invocation::model::InvocationResult::success(
        &invocation,
        wid("w1"),
        FunctionRevision(1),
        CatalogRevision(1),
        json!({"ok": true}),
    );
    let record =
        crate::engine::invocation::model::InvocationRecord::from_result(&invocation, &result, None);
    store.append_invocation(&record).unwrap();
    let records = store.list_invocations().unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].invocation_id, invocation.id);
    assert_eq!(records[0].session_id.as_deref(), Some("session-a"));
    assert_eq!(records[0].workspace_id.as_deref(), Some("workspace-a"));
    assert_eq!(records[0].result_value, Some(json!({"ok": true})));
    let session_records = store.list_invocations_by_session("session-a").unwrap();
    assert_eq!(session_records.len(), 1);
    assert_eq!(session_records[0].invocation_id, invocation.id);
    assert!(
        store
            .list_invocations_by_session("session-other")
            .unwrap()
            .is_empty()
    );

    let key = IdempotencyKey {
        function_id: fid("alpha::write"),
        scope: IdempotencyScope::session("session-a"),
        key: "dedupe-key".to_owned(),
    };
    let reservation = IdempotencyReservation {
        key: key.clone(),
        payload_fingerprint: "fingerprint-a".to_owned(),
        function_revision: FunctionRevision(1),
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
    let session_idempotency = store.list_idempotency_by_session("session-a").unwrap();
    assert_eq!(session_idempotency.len(), 1);
    assert_eq!(session_idempotency[0].payload_fingerprint, "fingerprint-a");
    assert!(
        store
            .list_idempotency_by_session("session-other")
            .unwrap()
            .is_empty()
    );
}
