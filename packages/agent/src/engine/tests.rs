use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::sync::{Barrier, Notify};

use super::discovery::{ActorContext, ActorKind, FunctionQuery};
use super::errors::{EngineError, Result};
use super::ids::{
    ActorId, AuthorityGrantId, FunctionId, TraceId, TriggerId, TriggerTypeId, WorkerId,
};
use super::invocation::{CausalContext, InProcessFunctionHandler, Invocation};
use super::ledger::{
    EngineLedgerStore, IdempotencyKey, IdempotencyReservation, IdempotencyReservationOutcome,
    IdempotencyStatus, InMemoryEngineLedgerStore, SqliteEngineLedgerStore, StoredInvocationOutcome,
};
use super::registry::LiveCatalog;
use super::types::{
    AuthorityRequirement, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CatalogSubjectKind, DeliveryMode, EffectClass, FunctionDefinition, FunctionHealth,
    FunctionRevision, IdempotencyContract, IdempotencyKeySource, IdempotencyScope, LedgerKind,
    Provenance, ReplayBehavior, RiskLevel, TriggerDefinition, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition, WorkerKind,
};
use super::{EngineHost, EngineHostHandle, EngineTriggerRuntime, TriggerDispatchRequest};

fn wid(value: &str) -> WorkerId {
    WorkerId::new(value).unwrap()
}

fn fid(value: &str) -> FunctionId {
    FunctionId::new(value).unwrap()
}

fn actor(value: &str) -> ActorId {
    ActorId::new(value).unwrap()
}

fn grant(value: &str) -> AuthorityGrantId {
    AuthorityGrantId::new(value).unwrap()
}

fn trace(value: &str) -> TraceId {
    TraceId::new(value).unwrap()
}

fn worker(id: &str, namespace: &str) -> WorkerDefinition {
    WorkerDefinition::new(
        wid(id),
        WorkerKind::InProcess,
        actor("owner"),
        grant("grant"),
    )
    .with_namespace_claim(namespace)
}

fn read_function(id: &str, owner: &str) -> FunctionDefinition {
    FunctionDefinition::new(
        fid(id),
        wid(owner),
        "read function",
        VisibilityScope::Agent,
        EffectClass::PureRead,
    )
}

fn write_function(id: &str, owner: &str) -> FunctionDefinition {
    FunctionDefinition::new(
        fid(id),
        wid(owner),
        "write function",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_idempotency(IdempotencyContract::caller_session())
}

fn reject_idempotency() -> IdempotencyContract {
    IdempotencyContract {
        key_source: IdempotencyKeySource::Caller,
        dedupe_scope: VisibilityScope::Session,
        replay_behavior: ReplayBehavior::Reject,
        ledger_kind: LedgerKind::InMemory,
    }
}

fn noop_idempotency() -> IdempotencyContract {
    IdempotencyContract {
        key_source: IdempotencyKeySource::Caller,
        dedupe_scope: VisibilityScope::Session,
        replay_behavior: ReplayBehavior::NoOp,
        ledger_kind: LedgerKind::InMemory,
    }
}

#[derive(Clone)]
struct EchoHandler;

#[async_trait]
impl InProcessFunctionHandler for EchoHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        Ok(json!({
            "echo": invocation.payload,
            "catalogRevision": invocation.causal_context.catalog_revision.0,
        }))
    }
}

struct FailHandler;

#[async_trait]
impl InProcessFunctionHandler for FailHandler {
    async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
        Err(EngineError::HandlerFailed("boom".to_owned()))
    }
}

#[derive(Clone)]
struct BlockingHandler {
    started: Arc<Barrier>,
    release: Arc<Notify>,
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
struct CountingFailHandler {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl InProcessFunctionHandler for CountingFailHandler {
    async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
        let _ = self.calls.fetch_add(1, Ordering::SeqCst);
        Err(EngineError::HandlerFailed("boom".to_owned()))
    }
}

#[derive(Clone)]
struct CountingHandler {
    calls: Arc<AtomicUsize>,
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

struct ReserveFailingLedger;

impl EngineLedgerStore for ReserveFailingLedger {
    fn append_catalog_change(&mut self, _change: &super::types::CatalogChange) -> Result<()> {
        Ok(())
    }

    fn list_catalog_changes(&self) -> Result<Vec<super::types::CatalogChange>> {
        Ok(Vec::new())
    }

    fn catalog_changes_after(
        &self,
        _revision: CatalogRevision,
        _limit: usize,
    ) -> Result<Vec<super::types::CatalogChange>> {
        Ok(Vec::new())
    }

    fn append_invocation(&mut self, _record: &super::invocation::InvocationRecord) -> Result<()> {
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<super::invocation::InvocationRecord>> {
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
        _invocation_id: &super::ids::InvocationId,
        _outcome: StoredInvocationOutcome,
    ) -> Result<()> {
        Ok(())
    }
}

struct CatalogChangeFailingLedger;

impl EngineLedgerStore for CatalogChangeFailingLedger {
    fn append_catalog_change(&mut self, _change: &super::types::CatalogChange) -> Result<()> {
        Err(EngineError::LedgerFailure {
            operation: "append_catalog_change",
            message: "injected failure".to_owned(),
        })
    }

    fn list_catalog_changes(&self) -> Result<Vec<super::types::CatalogChange>> {
        Ok(Vec::new())
    }

    fn catalog_changes_after(
        &self,
        _revision: CatalogRevision,
        _limit: usize,
    ) -> Result<Vec<super::types::CatalogChange>> {
        Ok(Vec::new())
    }

    fn append_invocation(&mut self, _record: &super::invocation::InvocationRecord) -> Result<()> {
        Ok(())
    }

    fn list_invocations(&self) -> Result<Vec<super::invocation::InvocationRecord>> {
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
        _invocation_id: &super::ids::InvocationId,
        _outcome: StoredInvocationOutcome,
    ) -> Result<()> {
        Ok(())
    }
}

fn handler() -> Arc<dyn InProcessFunctionHandler> {
    Arc::new(EchoHandler)
}

fn causal() -> CausalContext {
    CausalContext::new(
        actor("agent"),
        ActorKind::Agent,
        grant("grant"),
        trace("trace"),
    )
}

fn mutating_causal(key: &str) -> CausalContext {
    causal()
        .with_session_id("session-a")
        .with_workspace_id("workspace-a")
        .with_idempotency_key(key)
}

fn host_invocation(function_id: &str, payload: Value, context: CausalContext) -> Invocation {
    Invocation::new_sync(fid(function_id), payload, context)
}

fn engine_ledger_contract(store: &mut dyn EngineLedgerStore) {
    let change = super::types::CatalogChange {
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

    let invocation = Invocation::new_sync(fid("alpha::read"), json!({"x": 1}), causal());
    let result = super::invocation::InvocationResult::success(
        &invocation,
        wid("w1"),
        FunctionRevision(1),
        CatalogRevision(1),
        json!({"ok": true}),
    );
    let record = super::invocation::InvocationRecord::from_result(&invocation, &result, None);
    store.append_invocation(&record).unwrap();
    let records = store.list_invocations().unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].invocation_id, invocation.id);
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
        invocation_id: super::ids::InvocationId::new("reservation-one").unwrap(),
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

#[test]
fn ids_reject_empty_and_invalid_function_ids() {
    assert!(WorkerId::new("").is_err());
    assert!(FunctionId::new("missing_separator").is_err());
    assert!(FunctionId::new("::op").is_err());
    assert!(FunctionId::new("ns::").is_err());
    assert!(FunctionId::new("ns::op::extra").is_err());
    assert_eq!(FunctionId::new("ns::op").unwrap().namespace(), "ns");
}

#[test]
fn effect_class_helpers_classify_mutation() {
    assert!(!EffectClass::PureRead.is_mutating());
    assert!(!EffectClass::DeterministicCompute.is_mutating());
    assert!(!EffectClass::DelegatedInvocation.is_mutating());
    assert!(EffectClass::IdempotentWrite.is_mutating());
    assert!(EffectClass::IrreversibleSideEffect.requires_approval_for_agent_visibility());
}

#[test]
fn empty_catalog_starts_at_revision_zero() {
    let catalog = LiveCatalog::new();
    assert_eq!(catalog.revision(), CatalogRevision(0));
    assert!(catalog.workers().is_empty());
    assert!(catalog.changes().is_empty());
}

#[test]
fn in_memory_and_sqlite_ledgers_share_storage_contract() {
    let mut memory = InMemoryEngineLedgerStore::new();
    engine_ledger_contract(&mut memory);

    let mut sqlite = SqliteEngineLedgerStore::open_in_memory().unwrap();
    engine_ledger_contract(&mut sqlite);
}

#[test]
fn sqlite_engine_ledger_persists_records_across_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("engine-ledger.sqlite");

    {
        let mut store = SqliteEngineLedgerStore::open(&db_path).unwrap();
        engine_ledger_contract(&mut store);
    }

    let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
    assert_eq!(store.list_catalog_changes().unwrap().len(), 1);
    assert_eq!(store.list_invocations().unwrap().len(), 1);

    let reservation = IdempotencyReservation {
        key: IdempotencyKey {
            function_id: fid("alpha::write"),
            scope: IdempotencyScope::new("session", "session-a"),
            key: "dedupe-key".to_owned(),
        },
        payload_fingerprint: "fingerprint-a".to_owned(),
        function_revision: FunctionRevision(1),
        replay_behavior: ReplayBehavior::ReturnPrevious,
        invocation_id: super::ids::InvocationId::new("reservation-two").unwrap(),
    };
    let existing = store
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM engine_idempotency_entries WHERE idempotency_key = 'dedupe-key'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(existing, 1);
    let mut reopened = SqliteEngineLedgerStore::open(&db_path).unwrap();
    assert!(matches!(
        reopened.reserve_idempotency(reservation).unwrap(),
        IdempotencyReservationOutcome::Existing(entry)
            if entry.status == IdempotencyStatus::Completed
    ));
}

#[test]
fn worker_registration_updates_revision_and_owner_conflicts_are_rejected() {
    let mut catalog = LiveCatalog::new();
    let rev = catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    assert_eq!(rev.0, 1);
    assert_eq!(catalog.revision().0, 1);
    assert_eq!(catalog.worker_is_volatile(&wid("w1")), Some(true));

    let rev = catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    assert_eq!(rev.0, 2);
    assert_eq!(catalog.revision().0, 2);

    let conflicting = WorkerDefinition::new(
        wid("w1"),
        WorkerKind::InProcess,
        actor("other"),
        grant("grant"),
    )
    .with_namespace_claim("alpha");
    assert!(matches!(
        catalog.register_worker(conflicting, true),
        Err(EngineError::OwnerMismatch { kind: "worker", .. })
    ));
}

#[test]
fn function_registration_requires_owner_and_namespace_claim() {
    let mut catalog = LiveCatalog::new();
    assert!(matches!(
        catalog.register_function(read_function("alpha::read", "w1"), Some(handler()), true),
        Err(EngineError::NotFound { kind: "worker", .. })
    ));

    catalog.register_worker(worker("w1", "beta"), true).unwrap();
    assert!(matches!(
        catalog.register_function(read_function("alpha::read", "w1"), Some(handler()), true),
        Err(EngineError::NamespaceDenied { .. })
    ));
}

#[test]
fn function_registration_allows_same_owner_update_and_rejects_cross_owner() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_worker(worker("w2", "alpha"), true)
        .unwrap();

    let rev = catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    assert_eq!(rev.0, 1);
    let rev = catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    assert_eq!(rev.0, 2);

    assert!(matches!(
        catalog.register_function(read_function("alpha::read", "w2"), Some(handler()), true),
        Err(EngineError::OwnerMismatch {
            kind: "function",
            ..
        })
    ));
}

#[test]
fn mutating_function_requires_idempotency() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let missing_contract = FunctionDefinition::new(
        fid("alpha::write"),
        wid("w1"),
        "write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    );
    assert!(matches!(
        catalog.register_function(missing_contract, Some(handler()), true),
        Err(EngineError::PolicyViolation(message)) if message.contains("requires idempotency")
    ));

    let internal_missing_contract = FunctionDefinition::new(
        fid("alpha::internal_write"),
        wid("w1"),
        "internal write",
        VisibilityScope::Internal,
        EffectClass::IdempotentWrite,
    );
    assert!(matches!(
        catalog.register_function(internal_missing_contract, Some(handler()), true),
        Err(EngineError::PolicyViolation(message)) if message.contains("requires idempotency")
    ));

    catalog
        .register_function(write_function("alpha::write", "w1"), Some(handler()), true)
        .unwrap();
}

#[test]
fn irreversible_agent_visible_function_requires_approval_metadata() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let irreversible = FunctionDefinition::new(
        fid("alpha::delete_forever"),
        wid("w1"),
        "irreversible",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_idempotency(IdempotencyContract::caller_session());
    assert!(matches!(
        catalog.register_function(irreversible, Some(handler()), true),
        Err(EngineError::PolicyViolation(message)) if message.contains("approval")
    ));

    let approved = FunctionDefinition::new(
        fid("alpha::delete_forever"),
        wid("w1"),
        "irreversible",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_idempotency(IdempotencyContract::caller_session())
    .with_required_authority(AuthorityRequirement::scope("delete").with_approval_required());
    catalog
        .register_function(approved, Some(handler()), true)
        .unwrap();
}

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

    let mut stale_target = TriggerDefinition::new(
        TriggerId::new("t-stale").unwrap(),
        wid("w1"),
        TriggerTypeId::new("cron").unwrap(),
        fid("alpha::read"),
        grant("grant"),
    );
    stale_target.target_revision = Some(FunctionRevision(99));
    assert!(matches!(
        catalog.register_trigger(stale_target, true),
        Err(EngineError::StaleFunctionRevision {
            expected: 99,
            actual: 1,
            ..
        })
    ));

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
fn catalog_changes_increment_by_one_and_record_subjects() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    let changes = catalog.changes();
    assert_eq!(changes.len(), 2);
    assert_eq!(changes[0].before.0, 0);
    assert_eq!(changes[0].after.0, 1);
    assert_eq!(changes[1].before.0, 1);
    assert_eq!(changes[1].after.0, 2);
    assert_eq!(changes[1].kind, CatalogChangeKind::FunctionRegistered);
    assert_eq!(changes[1].subject_id, "alpha::read");
    assert_eq!(changes[1].subject_kind, CatalogSubjectKind::Function);
    assert_eq!(changes[1].class, CatalogChangeClass::Availability);
    assert_eq!(changes[1].visibility, VisibilityScope::Agent);
}

#[test]
fn discovery_is_sorted_and_filters_visibility_namespace_effect_risk_health_and_text() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::zeta", "w1").with_tags(vec!["lookup".to_owned()]),
            Some(handler()),
            true,
        )
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::beta", "w1")
                .with_risk(RiskLevel::Medium)
                .with_health(FunctionHealth::Degraded),
            Some(handler()),
            true,
        )
        .unwrap();
    let internal = FunctionDefinition::new(
        fid("alpha::internal"),
        wid("w1"),
        "internal",
        VisibilityScope::Internal,
        EffectClass::PureRead,
    );
    catalog
        .register_function(internal, Some(handler()), true)
        .unwrap();

    let agent = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"));
    let all = catalog.discover_functions(&FunctionQuery {
        actor: Some(agent.clone()),
        ..FunctionQuery::default()
    });
    assert_eq!(
        all.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::beta", "alpha::zeta"]
    );

    let filtered = catalog.discover_functions(&FunctionQuery {
        namespace_prefix: Some("alpha::z".to_owned()),
        text: Some("lookup".to_owned()),
        effect_class: Some(EffectClass::PureRead),
        max_risk: Some(RiskLevel::Low),
        health: Some(FunctionHealth::Healthy),
        include_internal: false,
        actor: Some(agent),
        visibility: None,
    });
    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].id.as_str(), "alpha::zeta");
}

#[test]
fn discovery_enforces_scoped_visibility_and_internal_requires_admin() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let session_function = FunctionDefinition::new(
        fid("alpha::session"),
        wid("w1"),
        "session function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a"));
    let workspace_function = FunctionDefinition::new(
        fid("alpha::workspace"),
        wid("w1"),
        "workspace function",
        VisibilityScope::Workspace,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_workspace_id("workspace-a"));
    let internal_function = FunctionDefinition::new(
        fid("alpha::internal"),
        wid("w1"),
        "internal function",
        VisibilityScope::Internal,
        EffectClass::PureRead,
    );
    catalog
        .register_function(session_function, Some(handler()), true)
        .unwrap();
    catalog
        .register_function(workspace_function, Some(handler()), true)
        .unwrap();
    catalog
        .register_function(internal_function, Some(handler()), true)
        .unwrap();

    let scoped_actor = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_session_id("session-a")
        .with_workspace_id("workspace-a");
    let scoped = catalog.discover_functions(&FunctionQuery {
        actor: Some(scoped_actor),
        include_internal: true,
        ..FunctionQuery::default()
    });
    assert_eq!(
        scoped.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::session", "alpha::workspace"]
    );

    let other_session = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_session_id("session-b")
        .with_workspace_id("workspace-a");
    let workspace_only = catalog.discover_functions(&FunctionQuery {
        actor: Some(other_session),
        ..FunctionQuery::default()
    });
    assert_eq!(
        workspace_only
            .iter()
            .map(|f| f.id.as_str())
            .collect::<Vec<_>>(),
        vec!["alpha::workspace"]
    );

    let admin = ActorContext::new(actor("admin"), ActorKind::Admin, grant("grant"));
    let admin_view = catalog.discover_functions(&FunctionQuery {
        actor: Some(admin),
        include_internal: true,
        ..FunctionQuery::default()
    });
    assert_eq!(
        admin_view.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        vec!["alpha::internal", "alpha::session", "alpha::workspace"]
    );
}

#[test]
fn worker_unregister_cleans_owned_volatile_registrations_only() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog.register_worker(worker("w2", "beta"), true).unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    catalog
        .register_function(read_function("beta::read", "w2"), Some(handler()), true)
        .unwrap();

    catalog.unregister_worker(&wid("w1"), "owner").unwrap();
    assert!(catalog.function(&fid("alpha::read")).is_none());
    assert!(catalog.function(&fid("beta::read")).is_some());
}

#[tokio::test]
async fn sync_invocation_succeeds_and_records_revisions() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let function_revision = catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    let invocation = Invocation::new_sync(fid("alpha::read"), json!({"x": 1}), causal())
        .expecting_revision(function_revision);

    let result = catalog.invoke_sync(invocation).await;
    assert!(result.error.is_none());
    assert_eq!(result.function_revision, FunctionRevision(1));
    assert_eq!(result.catalog_revision, catalog.revision());
    assert_eq!(result.value.unwrap()["echo"]["x"], 1);
}

#[tokio::test]
async fn invocation_ledger_records_success_error_and_full_causality() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();

    let parent = super::ids::InvocationId::new("parent-invocation").unwrap();
    let trigger = TriggerId::new("trigger-a").unwrap();
    let invocation = Invocation::new_sync(
        fid("alpha::read"),
        json!({"x": 1}),
        causal()
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_parent_invocation(parent.clone())
            .with_trigger_id(trigger.clone()),
    );
    let result = catalog.invoke_sync(invocation).await;
    assert!(result.error.is_none());

    let missing = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::missing"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(missing.error.is_some());

    let records = catalog.invocations();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].function_id.as_str(), "alpha::read");
    assert_eq!(records[0].actor_id, actor("agent"));
    assert_eq!(records[0].authority_grant_id, grant("grant"));
    assert_eq!(records[0].trace_id, trace("trace"));
    assert_eq!(records[0].parent_invocation_id, Some(parent));
    assert_eq!(records[0].trigger_id, Some(trigger));
    assert_eq!(records[0].delivery_mode, DeliveryMode::Sync);
    assert_eq!(records[0].catalog_revision, catalog.revision());
    assert_eq!(records[0].function_revision, FunctionRevision(1));
    assert!(records[0].succeeded);
    assert!(!records[1].succeeded);
    assert!(matches!(
        records[1].error,
        Some(EngineError::NotFound {
            kind: "function",
            ..
        })
    ));
}

#[tokio::test]
async fn idempotency_replays_or_rejects_duplicates_without_reinvoking_handler() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    catalog
        .register_function(
            write_function("alpha::write", "w1"),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let first = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert_eq!(first.value.as_ref().unwrap()["call"], 1);

    let replay = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert_eq!(replay.value.as_ref().unwrap()["call"], 1);
    assert_eq!(replay.replayed_from, Some(first.invocation_id.clone()));
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let conflict = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 2}),
            mutating_causal("same-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let records = catalog.invocations();
    assert_eq!(records.len(), 3);
    assert_eq!(records[0].idempotency_key.as_deref(), Some("same-key"));
    assert_eq!(records[1].replayed_from, Some(first.invocation_id));
    assert!(!records[2].succeeded);
}

#[tokio::test]
async fn idempotency_reject_and_noop_policies_are_enforced() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    catalog
        .register_function(
            write_function("alpha::reject", "w1").with_idempotency(reject_idempotency()),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();
    catalog
        .register_function(
            write_function("alpha::noop", "w1").with_idempotency(noop_idempotency()),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let first_reject = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::reject"),
            json!({"x": 1}),
            mutating_causal("reject-key"),
        ))
        .await;
    assert!(first_reject.error.is_none());
    let duplicate_reject = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::reject"),
            json!({"x": 1}),
            mutating_causal("reject-key"),
        ))
        .await;
    assert!(matches!(
        duplicate_reject.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));

    let first_noop = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::noop"),
            json!({"x": 1}),
            mutating_causal("noop-key"),
        ))
        .await;
    assert!(first_noop.error.is_none());
    let duplicate_noop = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::noop"),
            json!({"x": 1}),
            mutating_causal("noop-key"),
        ))
        .await;
    assert_eq!(duplicate_noop.value, Some(Value::Null));
    assert_eq!(duplicate_noop.replayed_from, Some(first_noop.invocation_id));
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn sqlite_idempotency_replays_after_catalog_recreation_without_reinvoking_handler() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("engine-ledger.sqlite");
    let calls = Arc::new(AtomicUsize::new(0));

    {
        let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
        let mut catalog = LiveCatalog::with_ledger_store(Box::new(store));
        catalog
            .register_worker(worker("w1", "alpha"), true)
            .unwrap();
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

        let first = catalog
            .invoke_sync(Invocation::new_sync(
                fid("alpha::write"),
                json!({"x": 1}),
                mutating_causal("same-key"),
            ))
            .await;
        assert_eq!(first.error, None);
        assert_eq!(first.value.as_ref().unwrap()["call"], 1);
    }

    let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
    let mut restarted = LiveCatalog::with_ledger_store(Box::new(store));
    restarted
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    restarted
        .register_function(
            write_function("alpha::write", "w1")
                .with_idempotency(IdempotencyContract::caller_session_engine_ledger()),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let replay = restarted
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.value.as_ref().unwrap()["call"], 1);
    assert!(replay.replayed_from.is_some());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn duplicate_after_handler_failure_replays_stored_error_without_reinvoking() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    catalog
        .register_function(
            write_function("alpha::write", "w1"),
            Some(Arc::new(CountingFailHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let first = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("error-key"),
        ))
        .await;
    assert!(matches!(
        first.error,
        Some(EngineError::HandlerFailed(message)) if message == "boom"
    ));

    let duplicate = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({"x": 1}),
            mutating_causal("error-key"),
        ))
        .await;
    assert!(matches!(
        duplicate.error,
        Some(EngineError::StoredInvocationError { kind, .. }) if kind == "handler_failed"
    ));
    assert_eq!(duplicate.replayed_from, Some(first.invocation_id));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn idempotency_reservation_failure_prevents_handler_execution() {
    let calls = Arc::new(AtomicUsize::new(0));
    let mut catalog = LiveCatalog::with_ledger_store(Box::new(ReserveFailingLedger));
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            write_function("alpha::write", "w1"),
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
            mutating_causal("reserve-fails"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::LedgerFailure {
            operation: "reserve_idempotency",
            ..
        })
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn schema_validation_checks_request_and_response_payloads() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let schema = json!({
        "type": "object",
        "required": ["name"],
        "properties": {
            "name": {"type": "string"},
            "count": {"type": "integer"}
        },
        "additionalProperties": false
    });
    catalog
        .register_function(
            read_function("alpha::schema", "w1")
                .with_request_schema(schema)
                .with_response_schema(json!({
                    "type": "object",
                    "required": ["echo"],
                    "properties": {"echo": {"type": "object"}},
                    "additionalProperties": true
                })),
            Some(handler()),
            true,
        )
        .unwrap();

    let missing = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::schema"),
            json!({"count": 1}),
            causal(),
        ))
        .await;
    assert!(matches!(
        missing.error,
        Some(EngineError::SchemaViolation {
            direction: "request",
            ..
        })
    ));

    let wrong_type = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::schema"),
            json!({"name": "ok", "count": 1.25}),
            causal(),
        ))
        .await;
    assert!(matches!(
        wrong_type.error,
        Some(EngineError::SchemaViolation {
            direction: "request",
            ..
        })
    ));

    let valid = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::schema"),
            json!({"name": "ok", "count": 1}),
            causal(),
        ))
        .await;
    assert!(valid.error.is_none());

    let invalid_schema = read_function("alpha::invalid_schema", "w1")
        .with_request_schema(json!({"type": "definitely-not-json-schema"}));
    assert!(matches!(
        catalog.register_function(invalid_schema, Some(handler()), true),
        Err(EngineError::InvalidSchema { .. })
    ));
}

#[tokio::test]
async fn schema_validation_enforces_array_max_items() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::bounded", "w1").with_request_schema(json!({
                "type": "object",
                "required": ["items"],
                "properties": {
                    "items": {
                        "type": "array",
                        "maxItems": 2,
                        "items": {"type": "string"}
                    }
                },
                "additionalProperties": false
            })),
            Some(handler()),
            true,
        )
        .unwrap();

    let valid = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::bounded"),
            json!({"items": ["a", "b"]}),
            causal(),
        ))
        .await;
    assert!(valid.error.is_none());

    let too_many = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::bounded"),
            json!({"items": ["a", "b", "c"]}),
            causal(),
        ))
        .await;
    assert!(matches!(
        too_many.error,
        Some(EngineError::SchemaViolation {
            direction: "request",
            ..
        })
    ));

    let invalid_schema = read_function("alpha::bad_max_items", "w1")
        .with_request_schema(json!({"type": "array", "maxItems": -1}));
    assert!(matches!(
        catalog.register_function(invalid_schema, Some(handler()), true),
        Err(EngineError::InvalidSchema { .. })
    ));
}

#[tokio::test]
async fn schema_validation_enforces_array_max_items_without_items_schema() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::bare_bounded", "w1").with_request_schema(json!({
                "type": "array",
                "maxItems": 1
            })),
            Some(handler()),
            true,
        )
        .unwrap();

    let too_many = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::bare_bounded"),
            json!(["a", "b"]),
            causal(),
        ))
        .await;
    assert!(matches!(
        too_many.error,
        Some(EngineError::SchemaViolation {
            direction: "request",
            ..
        })
    ));
}

#[test]
fn inspect_and_promotion_are_visibility_and_owner_checked() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("alpha::session"),
        wid("w1"),
        "session function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a"));
    catalog
        .register_function(function, Some(handler()), true)
        .unwrap();

    let matching_session = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_session_id("session-a");
    let other_session = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_session_id("session-b");
    assert!(
        catalog
            .inspect_function(&fid("alpha::session"), Some(&matching_session))
            .is_ok()
    );
    assert!(matches!(
        catalog.inspect_function(&fid("alpha::session"), Some(&other_session)),
        Err(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    assert!(matches!(
        catalog.promote_function_visibility(
            &fid("alpha::session"),
            &wid("other"),
            VisibilityScope::Workspace,
            Some("workspace-a".to_owned())
        ),
        Err(EngineError::OwnerMismatch { .. })
    ));
    assert!(matches!(
        catalog.promote_function_visibility(
            &fid("alpha::session"),
            &wid("w1"),
            VisibilityScope::Session,
            None
        ),
        Err(EngineError::InvalidVisibilityPromotion { .. })
    ));
    let revision = catalog
        .promote_function_visibility(
            &fid("alpha::session"),
            &wid("w1"),
            VisibilityScope::Workspace,
            Some("workspace-a".to_owned()),
        )
        .unwrap();
    assert_eq!(revision, FunctionRevision(2));
    let promoted = catalog.function(&fid("alpha::session")).unwrap();
    assert_eq!(promoted.visibility, VisibilityScope::Workspace);
    assert_eq!(
        promoted.provenance.workspace_id.as_deref(),
        Some("workspace-a")
    );
    assert!(promoted.provenance.session_id.is_none());
    assert_eq!(
        catalog.changes().last().unwrap().kind,
        CatalogChangeKind::VisibilityChanged
    );

    let workspace_actor = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"))
        .with_workspace_id("workspace-a");
    assert!(
        catalog
            .inspect_function(&fid("alpha::session"), Some(&workspace_actor))
            .is_ok()
    );
    assert!(catalog.inspect_worker(&wid("w1")).is_ok());
}

#[test]
fn unregister_function_removes_targeting_triggers_and_revisions_remain_monotonic() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();
    catalog
        .register_trigger_type(
            TriggerTypeDefinition::new(TriggerTypeId::new("cron").unwrap(), wid("w1"), "cron"),
            true,
        )
        .unwrap();
    catalog
        .register_trigger(
            TriggerDefinition::new(
                TriggerId::new("t1").unwrap(),
                wid("w1"),
                TriggerTypeId::new("cron").unwrap(),
                fid("alpha::read"),
                grant("grant"),
            ),
            true,
        )
        .unwrap();
    let before = catalog.revision();

    catalog
        .unregister_function(&fid("alpha::read"), &wid("w1"))
        .unwrap();

    assert!(catalog.function(&fid("alpha::read")).is_none());
    assert!(
        catalog
            .inspect_trigger(&TriggerId::new("t1").unwrap())
            .is_err()
    );
    assert_eq!(catalog.revision().0, before.0 + 2);
    assert_eq!(
        catalog.changes()[catalog.changes().len() - 2].kind,
        CatalogChangeKind::TriggerUnregistered
    );
    assert_eq!(
        catalog.changes().last().unwrap().kind,
        CatalogChangeKind::FunctionUnregistered
    );
}

#[tokio::test]
async fn invocation_returns_structured_errors() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("alpha::read", "w1"),
            Some(Arc::new(FailHandler)),
            true,
        )
        .unwrap();

    let missing = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::missing"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(matches!(
        missing.error,
        Some(EngineError::NotFound {
            kind: "function",
            ..
        })
    ));

    let stale = catalog
        .invoke_sync(
            Invocation::new_sync(fid("alpha::read"), json!({}), causal())
                .expecting_revision(FunctionRevision(99)),
        )
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::StaleFunctionRevision {
            expected: 99,
            actual: 1,
            ..
        })
    ));

    let unsupported = catalog
        .invoke_sync(
            Invocation::new_sync(fid("alpha::read"), json!({}), causal())
                .with_delivery_mode(DeliveryMode::Void),
        )
        .await;
    assert!(matches!(
        unsupported.error,
        Some(EngineError::UnsupportedDeliveryMode { mode: "void" })
    ));

    let handler_failure = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::read"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(matches!(
        handler_failure.error,
        Some(EngineError::HandlerFailed(message)) if message == "boom"
    ));
}

#[tokio::test]
async fn invocation_enforces_authority_health_and_idempotency_key() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let function = write_function("alpha::write", "w1")
        .with_required_authority(AuthorityRequirement::scope("write"));
    catalog
        .register_function(function, Some(handler()), true)
        .unwrap();

    let no_scope = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            causal(),
        ))
        .await;
    assert!(matches!(
        no_scope.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("missing required authority")
    ));

    let no_key = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            causal().with_scope("write"),
        ))
        .await;
    assert!(matches!(
        no_key.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("idempotency key")
    ));

    let ok = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            mutating_causal("write-1").with_scope("write"),
        ))
        .await;
    assert!(ok.error.is_none());

    catalog
        .register_function(
            write_function("alpha::write", "w1")
                .with_required_authority(AuthorityRequirement::scope("write"))
                .with_health(FunctionHealth::Unhealthy),
            Some(handler()),
            true,
        )
        .unwrap();
    let unhealthy = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::write"),
            json!({}),
            mutating_causal("write-2").with_scope("write"),
        ))
        .await;
    assert!(matches!(
        unhealthy.error,
        Some(EngineError::NotRoutable { .. })
    ));
}

#[tokio::test]
async fn invocation_enforces_visibility_scope() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let session_function = FunctionDefinition::new(
        fid("alpha::session"),
        wid("w1"),
        "session function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a"));
    catalog
        .register_function(session_function, Some(handler()), true)
        .unwrap();

    let hidden = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::session"),
            json!({}),
            causal().with_session_id("session-b"),
        ))
        .await;
    assert!(matches!(
        hidden.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let visible = catalog
        .invoke_sync(Invocation::new_sync(
            fid("alpha::session"),
            json!({}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert!(visible.error.is_none());
}

#[test]
fn engine_host_bootstrap_registers_reserved_meta_capabilities_once() {
    let mut host = EngineHost::new().unwrap();
    let initial_revision = host.catalog().revision();
    let engine_worker = host.catalog().worker(&wid("engine")).unwrap();
    assert_eq!(engine_worker.kind, WorkerKind::System);
    assert_eq!(engine_worker.namespace_claims, vec!["engine".to_owned()]);

    for id in [
        "engine::discover",
        "engine::inspect",
        "engine::watch",
        "engine::invoke",
        "engine::promote",
    ] {
        let function = host.catalog().function(&fid(id)).unwrap();
        assert_eq!(function.owner_worker, wid("engine"));
        assert_eq!(function.visibility, VisibilityScope::Agent);
    }

    host.bootstrap_meta_capabilities().unwrap();
    assert_eq!(host.catalog().revision(), initial_revision);
}

#[tokio::test]
async fn engine_host_handle_bootstraps_in_memory_host() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    let host = handle.lock().await;
    assert!(host.catalog().worker(&wid("engine")).is_some());
    for id in [
        "engine::discover",
        "engine::inspect",
        "engine::watch",
        "engine::invoke",
        "engine::promote",
    ] {
        assert!(host.catalog().function(&fid(id)).is_some(), "{id}");
    }
}

#[tokio::test]
async fn engine_host_handle_invokes_handlers_without_blocking_discovery() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker(worker("w1", "alpha"), true)
        .await
        .unwrap();

    let started = Arc::new(Barrier::new(2));
    let release = Arc::new(Notify::new());
    handle
        .register_function(
            read_function("alpha::slow", "w1"),
            Some(Arc::new(BlockingHandler {
                started: Arc::clone(&started),
                release: Arc::clone(&release),
            })),
            true,
        )
        .await
        .unwrap();

    let invocation = Invocation::new_sync(fid("alpha::slow"), json!({"x": 1}), causal());
    let running = {
        let handle = handle.clone();
        tokio::spawn(async move { handle.invoke(invocation).await })
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
    .expect("discovery should not wait for slow handler");
    assert!(
        functions
            .iter()
            .any(|function| function.id == fid("alpha::slow"))
    );
    handle
        .register_function(
            read_function("alpha::new_read", "w1"),
            Some(handler()),
            true,
        )
        .await
        .expect("catalog updates should not wait for slow handler");

    release.notify_waiters();
    let result = running.await.unwrap();
    assert_eq!(result.value.as_ref().unwrap()["payload"], json!({"x": 1}));
    let host = handle.lock().await;
    assert!(
        result.catalog_revision < host.catalog().revision(),
        "finished invocation should preserve the catalog revision captured before the concurrent update"
    );
}

#[tokio::test]
async fn engine_invoke_meta_does_not_block_discovery_while_child_runs() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker(worker("w1", "alpha"), true)
        .await
        .unwrap();

    let started = Arc::new(Barrier::new(2));
    let release = Arc::new(Notify::new());
    handle
        .register_function(
            read_function("alpha::slow", "w1"),
            Some(Arc::new(BlockingHandler {
                started: Arc::clone(&started),
                release: Arc::clone(&release),
            })),
            true,
        )
        .await
        .unwrap();

    let invocation = Invocation::new_sync(
        fid("engine::invoke"),
        json!({
            "functionId": "alpha::slow",
            "payload": {"x": 1}
        }),
        causal(),
    );
    let running = {
        let handle = handle.clone();
        tokio::spawn(async move { handle.invoke(invocation).await })
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
    .expect("engine::invoke child execution should not block discovery");
    assert!(
        functions
            .iter()
            .any(|function| function.id == fid("alpha::slow"))
    );
    handle
        .register_function(
            read_function("alpha::new_read", "w1"),
            Some(handler()),
            true,
        )
        .await
        .expect("catalog updates should not wait for delegated child execution");

    release.notify_waiters();
    let result = running.await.unwrap();
    assert_eq!(
        result.value.as_ref().unwrap()["child"]["value"]["payload"],
        json!({"x": 1})
    );
    let host = handle.lock().await;
    let child_record = host
        .catalog()
        .invocations()
        .iter()
        .find(|record| record.function_id == fid("alpha::slow"))
        .unwrap();
    assert_eq!(
        child_record.parent_invocation_id,
        Some(result.invocation_id.clone())
    );
    assert!(
        child_record.catalog_revision < host.catalog().revision(),
        "delegated child should preserve the catalog revision captured before the concurrent update"
    );
}

#[tokio::test]
async fn engine_host_handle_records_panics_and_replays_panic_errors() {
    let handle = super::host::EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker(worker("w1", "alpha"), true)
        .await
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    #[derive(Clone)]
    struct CountingPanicHandler {
        calls: Arc<AtomicUsize>,
    }
    #[async_trait]
    impl InProcessFunctionHandler for CountingPanicHandler {
        async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
            let _ = self.calls.fetch_add(1, Ordering::SeqCst);
            panic!("panic stored for replay");
        }
    }

    handle
        .register_function(
            write_function("alpha::panic", "w1"),
            Some(Arc::new(CountingPanicHandler {
                calls: Arc::clone(&calls),
            })),
            true,
        )
        .await
        .unwrap();

    let first = handle
        .invoke(Invocation::new_sync(
            fid("alpha::panic"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert!(matches!(
        first.error,
        Some(EngineError::HandlerFailed(message))
            if message.contains("handler panicked") && message.contains("panic stored for replay")
    ));

    let duplicate = handle
        .invoke(Invocation::new_sync(
            fid("alpha::panic"),
            json!({"x": 1}),
            mutating_causal("same-key"),
        ))
        .await;
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(duplicate.replayed_from, Some(first.invocation_id));
    assert!(matches!(
        duplicate.error,
        Some(EngineError::StoredInvocationError { message, .. })
            if message.contains("handler failed")
    ));
}

#[test]
fn engine_ledger_path_is_sibling_of_event_database() {
    let db_path = std::path::Path::new("/tmp/tron/internal/database/log.db");
    assert_eq!(
        super::host::engine_ledger_path_for_event_db(db_path),
        std::path::PathBuf::from("/tmp/tron/internal/database/engine-ledger.sqlite")
    );
    assert_eq!(
        super::host::engine_ledger_path_for_event_db(std::path::Path::new("log.db")),
        std::path::PathBuf::from("engine-ledger.sqlite")
    );
}

#[tokio::test]
async fn sqlite_engine_host_handle_reopens_watchable_catalog_changes() {
    let dir = tempfile::tempdir().unwrap();
    let ledger_path = dir.path().join("engine-ledger.sqlite");
    {
        let handle = super::host::EngineHostHandle::open_sqlite(&ledger_path).unwrap();
        let mut host = handle.lock().await;
        host.catalog_mut()
            .register_worker(worker("w1", "alpha"), true)
            .unwrap();
    }

    let reopened = super::host::EngineHostHandle::open_sqlite(&ledger_path).unwrap();
    let host = reopened.lock().await;
    let changes = host
        .catalog()
        .catalog_changes_after(CatalogRevision(0), 100)
        .unwrap();
    assert!(
        changes
            .iter()
            .any(|change| change.subject_id == "engine::discover")
    );
    assert!(changes.iter().any(|change| change.subject_id == "w1"));
}

#[test]
fn engine_host_bootstrap_repairs_stale_system_meta_contracts() {
    let mut catalog = LiveCatalog::new();
    let engine_worker = WorkerDefinition::new(
        wid("engine"),
        WorkerKind::System,
        actor("system"),
        grant("engine-system"),
    )
    .with_namespace_claim("engine");
    catalog.register_worker(engine_worker, false).unwrap();
    catalog
        .register_function(
            FunctionDefinition::new(
                fid("engine::discover"),
                wid("engine"),
                "stale discover",
                VisibilityScope::Internal,
                EffectClass::IdempotentWrite,
            )
            .with_idempotency(IdempotencyContract::caller_session()),
            None,
            false,
        )
        .unwrap();

    let host = EngineHost::from_catalog(catalog).unwrap();
    let discover = host.catalog().function(&fid("engine::discover")).unwrap();
    assert_eq!(discover.description, "discover live engine capabilities");
    assert_eq!(discover.visibility, VisibilityScope::Agent);
    assert_eq!(discover.effect_class, EffectClass::PureRead);
    assert_eq!(discover.idempotency, None);
    assert_eq!(discover.revision, FunctionRevision(2));
}

#[test]
fn engine_namespace_is_reserved_for_the_system_engine_worker() {
    let mut catalog = LiveCatalog::new();
    let denied = catalog.register_worker(worker("w1", "engine"), true);
    assert!(matches!(
        denied,
        Err(EngineError::PolicyViolation(message))
            if message.contains("reserved engine namespace")
    ));

    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let denied_function = host.catalog_mut().register_function(
        read_function("engine::spoof", "w1"),
        Some(handler()),
        true,
    );
    assert!(matches!(
        denied_function,
        Err(EngineError::PolicyViolation(message))
            if message.contains("reserved engine namespace")
    ));
}

#[test]
fn catalog_change_ledger_failure_does_not_mutate_registered_catalog_entries() {
    let mut catalog = LiveCatalog::with_ledger_store(Box::new(CatalogChangeFailingLedger));

    let result = catalog.register_worker(worker("w1", "alpha"), true);
    assert!(matches!(
        result,
        Err(EngineError::LedgerFailure {
            operation: "append_catalog_change",
            ..
        })
    ));
    assert_eq!(catalog.revision(), CatalogRevision(0));
    assert!(catalog.worker(&wid("w1")).is_none());
    assert!(catalog.changes().is_empty());
}

#[tokio::test]
async fn engine_meta_discover_and_inspect_are_live_and_scope_checked() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            read_function("alpha::public", "w1").with_tags(vec!["visible".to_owned()]),
            Some(handler()),
            true,
        )
        .unwrap();
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::session"),
                wid("w1"),
                "session function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )
            .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a")),
            Some(handler()),
            true,
        )
        .unwrap();

    let session_a = causal().with_session_id("session-a");
    let discovered = host
        .invoke(host_invocation(
            "engine::discover",
            json!({"namespacePrefix": "alpha"}),
            session_a.clone(),
        ))
        .await;
    assert_eq!(discovered.error, None);
    let functions = discovered.value.unwrap()["functions"]
        .as_array()
        .unwrap()
        .clone();
    let ids: Vec<&str> = functions
        .iter()
        .map(|item| item["id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&"alpha::public"));
    assert!(ids.contains(&"alpha::session"));

    let hidden = host
        .invoke(host_invocation(
            "engine::inspect",
            json!({"kind": "function", "id": "alpha::session"}),
            causal().with_session_id("session-b"),
        ))
        .await;
    assert!(matches!(
        hidden.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let malformed = host
        .invoke(host_invocation(
            "engine::inspect",
            json!({"kind": "function"}),
            session_a,
        ))
        .await;
    assert!(matches!(
        malformed.error,
        Some(EngineError::SchemaViolation { .. })
    ));
}

#[tokio::test]
async fn engine_watch_filters_catalog_changes_without_leaking_hidden_scopes() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(read_function("alpha::public", "w1"), Some(handler()), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::session"),
                wid("w1"),
                "session function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )
            .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a")),
            Some(handler()),
            true,
        )
        .unwrap();
    let future_revision = host.catalog().revision().0 + 10;

    let visible = host
        .invoke(host_invocation(
            "engine::watch",
            json!({
                "afterRevision": 0,
                "classes": ["availability"],
                "subjectPrefix": "alpha::",
                "limit": 10
            }),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(visible.error, None);
    let changes = visible.value.unwrap()["changes"]
        .as_array()
        .unwrap()
        .clone();
    assert!(changes.iter().any(|change| {
        change["subjectId"] == "alpha::public"
            && change["subjectKind"] == "function"
            && change["class"] == "availability"
    }));
    assert!(changes.iter().any(|change| {
        change["subjectId"] == "alpha::session" && change["sessionId"] == "session-a"
    }));

    let hidden = host
        .invoke(host_invocation(
            "engine::watch",
            json!({"afterRevision": 0, "subjectPrefix": "alpha::", "limit": 10}),
            causal().with_session_id("session-b"),
        ))
        .await;
    assert_eq!(hidden.error, None);
    let hidden_changes = hidden.value.unwrap()["changes"].as_array().unwrap().clone();
    assert!(
        hidden_changes
            .iter()
            .all(|change| change["subjectId"] != "alpha::session")
    );

    host.catalog_mut()
        .unregister_function(&fid("alpha::session"), &wid("w1"))
        .unwrap();
    let removal = host
        .invoke(host_invocation(
            "engine::watch",
            json!({"afterRevision": 0, "kinds": ["function_unregistered"]}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(removal.error, None);
    assert!(
        removal.value.unwrap()["changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|change| change["subjectId"] == "alpha::session")
    );

    let future = host
        .invoke(host_invocation(
            "engine::watch",
            json!({"afterRevision": future_revision}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(future.error, None);
    let future_value = future.value.unwrap();
    assert_eq!(future_value["changes"].as_array().unwrap().len(), 0);
    assert_eq!(future_value["currentRevision"], host.catalog().revision().0);

    let zero_limit = host
        .invoke(host_invocation(
            "engine::watch",
            json!({"afterRevision": 0, "limit": 0}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert!(matches!(
        zero_limit.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("limit")
    ));
}

#[test]
fn sqlite_ledger_reopen_preserves_watch_scope_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("engine-ledger.sqlite");
    {
        let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
        let mut host = EngineHost::with_ledger_store(Box::new(store)).unwrap();
        host.catalog_mut()
            .register_worker(worker("w1", "alpha"), true)
            .unwrap();
        host.catalog_mut()
            .register_function(
                FunctionDefinition::new(
                    fid("alpha::session"),
                    wid("w1"),
                    "session function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(
                    Provenance::new(actor("agent"), "test").with_session_id("session-a"),
                ),
                Some(handler()),
                true,
            )
            .unwrap();
    }

    let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
    let changes = store
        .catalog_changes_after(CatalogRevision(0), 100)
        .unwrap();
    assert!(changes.iter().any(|change| {
        change.subject_kind == CatalogSubjectKind::Function
            && change.class == CatalogChangeClass::Availability
            && change.visibility == VisibilityScope::Session
            && change.session_id.as_deref() == Some("session-a")
    }));
}

#[tokio::test]
async fn engine_invoke_delegates_with_parent_causality_and_target_policy() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    host.catalog_mut()
        .register_function(
            write_function("alpha::write", "w1"),
            Some(Arc::new(CountingHandler {
                calls: calls.clone(),
            })),
            true,
        )
        .unwrap();

    let missing_key = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({"functionId": "alpha::write", "payload": {"x": 1}}),
            causal().with_session_id("session-a"),
        ))
        .await;
    assert_eq!(missing_key.error, None);
    assert!(
        missing_key.value.unwrap()["child"]["error"]["message"]
            .as_str()
            .unwrap()
            .contains("idempotency key")
    );
    assert_eq!(calls.load(Ordering::SeqCst), 0);

    let first = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "alpha::write",
                "payload": {"x": 1},
                "idempotencyKey": "child-key"
            }),
            causal()
                .with_session_id("session-a")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(first.error, None);
    assert_eq!(first.value.as_ref().unwrap()["child"]["value"]["call"], 1);

    let replay = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "alpha::write",
                "payload": {"x": 1},
                "idempotencyKey": "child-key"
            }),
            causal()
                .with_session_id("session-a")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.value.as_ref().unwrap()["child"]["value"]["call"], 1);
    assert!(replay.value.unwrap()["child"]["replayedFrom"].is_string());
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let child_records: Vec<_> = host
        .catalog()
        .invocations()
        .iter()
        .filter(|record| record.function_id == fid("alpha::write"))
        .collect();
    assert!(
        child_records
            .iter()
            .all(|record| record.parent_invocation_id.is_some())
    );
}

#[tokio::test]
async fn engine_invoke_reports_target_errors_in_child_envelope() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            read_function("alpha::fail", "w1"),
            Some(Arc::new(FailHandler)),
            true,
        )
        .unwrap();

    let result = host
        .invoke(host_invocation(
            "engine::invoke",
            json!({"functionId": "alpha::fail", "payload": {}}),
            causal(),
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        result.value.unwrap()["child"]["error"]["kind"],
        "handler_failed"
    );
}

#[tokio::test]
async fn engine_promote_requires_authority_revision_and_session_ownership() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    host.catalog_mut()
        .register_function(
            FunctionDefinition::new(
                fid("alpha::session"),
                wid("w1"),
                "session function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )
            .with_provenance(Provenance::new(actor("agent"), "test").with_session_id("session-a")),
            Some(handler()),
            true,
        )
        .unwrap();

    let no_scope = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-no-scope"),
        ))
        .await;
    assert!(matches!(
        no_scope.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("missing required authority")
    ));

    let stale = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 2
            }),
            mutating_causal("promote-stale").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::StaleFunctionRevision { .. })
    ));

    let cross_session = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            causal()
                .with_session_id("session-b")
                .with_workspace_id("workspace-a")
                .with_idempotency_key("promote-cross")
                .with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        cross_session.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("session")
    ));

    let promoted = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-ok").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert_eq!(promoted.error, None);
    assert_eq!(promoted.value.as_ref().unwrap()["revision"], 2);
    let function = host.catalog().function(&fid("alpha::session")).unwrap();
    assert_eq!(function.visibility, VisibilityScope::Workspace);
    assert_eq!(function.provenance.session_id, None);
    assert_eq!(
        function.provenance.workspace_id.as_deref(),
        Some("workspace-a")
    );

    let replay = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::session",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-ok").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.replayed_from, Some(promoted.invocation_id));
    assert_eq!(replay.value.as_ref().unwrap()["revision"], 2);
    assert_eq!(
        host.catalog()
            .function(&fid("alpha::session"))
            .unwrap()
            .revision,
        FunctionRevision(2)
    );
}

#[tokio::test]
async fn engine_promote_conflicting_duplicate_key_does_not_mutate_new_target() {
    let mut host = EngineHost::new().unwrap();
    host.catalog_mut()
        .register_worker(worker("w1", "alpha"), true)
        .unwrap();
    for id in ["alpha::one", "alpha::two"] {
        host.catalog_mut()
            .register_function(
                FunctionDefinition::new(
                    fid(id),
                    wid("w1"),
                    "session function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(
                    Provenance::new(actor("agent"), "test").with_session_id("session-a"),
                ),
                Some(handler()),
                true,
            )
            .unwrap();
    }

    let first = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::one",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-shared-key").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert_eq!(first.error, None);

    let conflict = host
        .invoke(host_invocation(
            "engine::promote",
            json!({
                "functionId": "alpha::two",
                "ownerWorker": "w1",
                "targetVisibility": "workspace",
                "workspaceId": "workspace-a",
                "expectedFunctionRevision": 1
            }),
            mutating_causal("promote-shared-key").with_scope("engine.promote.workspace"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    assert_eq!(
        host.catalog()
            .function(&fid("alpha::two"))
            .unwrap()
            .visibility,
        VisibilityScope::Session
    );
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
async fn trigger_runtime_stale_target_revision_records_attempt() {
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
    let mut trigger = TriggerDefinition::new(
        trigger_id.clone(),
        wid("alpha"),
        TriggerTypeId::new("manual").unwrap(),
        fid("alpha::echo"),
        grant("manual-grant"),
    );
    trigger.target_revision = Some(revision);
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
    assert!(matches!(
        result.error,
        Some(EngineError::StaleFunctionRevision { .. })
    ));

    let host = handle.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(record.function_id, fid("alpha::echo"));
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert!(
        record.function_revision > revision,
        "ledger should record the actual target revision that caused the stale-target failure"
    );
    assert!(matches!(
        record.error.as_ref(),
        Some(EngineError::StaleFunctionRevision { .. })
    ));
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
