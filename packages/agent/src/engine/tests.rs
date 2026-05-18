use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use async_trait::async_trait;
use chrono::{Duration as ChronoDuration, Utc};
use serde_json::{Value, json};
use tokio::sync::{Barrier, Notify};

use super::discovery::{ActorContext, ActorKind, FunctionQuery};
use super::errors::{EngineError, Result};
use super::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, TriggerTypeId,
    WorkerId,
};
use super::invocation::{CausalContext, InProcessFunctionHandler, Invocation};
use super::ledger::{
    EngineLedgerStore, IdempotencyKey, IdempotencyReservation, IdempotencyReservationOutcome,
    IdempotencyStatus, InMemoryEngineLedgerStore, SqliteEngineLedgerStore, StoredInvocationOutcome,
};
use super::registry::LiveCatalog;
use super::types::{
    AuthorityRequirement, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CatalogSubjectKind, CompensationContract, CompensationKind, DeliveryMode,
    DurableOutputContract, EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision,
    IdempotencyContract, IdempotencyKeySource, IdempotencyScope, LedgerKind, Provenance,
    ReplayBehavior, ResourceLeaseRequirement, RiskLevel, TriggerDefinition, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition, WorkerKind,
};
use super::{
    AcquireResourceLease, AgentCapabilityClient, ApprovalStatus, CatalogWatchRequest,
    EngineExternalWorkerRuntime, EngineHost, EngineHostHandle, EngineQueueDrainer,
    EngineResourceLeaseStatus, EngineTriggerRuntime, StreamActorScope, StreamCursor,
    TriggerDispatchRequest,
};

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

fn lease_request(resource_kind: &str, resource_id: &str, ttl_ms: i64) -> AcquireResourceLease {
    AcquireResourceLease {
        resource_kind: resource_kind.to_owned(),
        resource_id: resource_id.to_owned(),
        holder_invocation_id: InvocationId::generate(),
        function_id: fid("test::write"),
        actor_id: actor("actor"),
        authority_grant_id: grant("grant"),
        trace_id: trace("trace"),
        parent_invocation_id: None,
        idempotency_key: Some("idem".to_owned()),
        ttl_ms,
    }
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

fn external_visible_function(mut function: FunctionDefinition) -> FunctionDefinition {
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
struct StaticValueHandler(Value);

#[async_trait]
impl InProcessFunctionHandler for StaticValueHandler {
    async fn invoke(&self, _invocation: Invocation) -> Result<Value> {
        Ok(self.0.clone())
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

fn valid_ui_surface(action_target: &str, target_revision: u64) -> Value {
    json!({
        "surfaceId": "surface-test",
        "title": "Surface Test",
        "purpose": "Inspect and act on substrate state",
        "catalog": {
            "id": "tron.ui.catalog.core.v1",
            "revision": 1
        },
        "layout": {
            "type": "Section",
            "props": {"title": "Substrate"},
            "children": [
                {"type": "Heading", "props": {"text": "Substrate"}},
                {"type": "Text", "props": {"text": "Generated UI renders from a resource."}},
                {"type": "Button", "props": {"actionId": "submit-test"}}
            ]
        },
        "bindings": [],
        "actions": [
            {
                "actionId": "submit-test",
                "label": "Submit",
                "targetFunctionId": action_target,
                "inputSchema": {
                    "type": "object",
                    "required": ["message"],
                    "additionalProperties": false,
                    "properties": {
                        "message": {"type": "string"}
                    }
                },
                "payloadTemplate": {
                    "message": "${input.message}",
                    "sourceSurface": "${surface.resourceId}"
                },
                "idempotencyKeyTemplate": "${submission.idempotencyKey}",
                "requiredGrant": "grant",
                "requiredRisk": "medium",
                "approvalPolicy": {"required": false},
                "targetRevision": target_revision,
                "expiresAt": "2100-01-01T00:00:00Z"
            }
        ],
        "redactionPolicy": {"mode": "redacted"},
        "expiresAt": "2100-01-01T00:00:00Z",
        "refreshPolicy": {"mode": "manual"}
    })
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

    let invocation = Invocation::new_sync(
        fid("alpha::read"),
        json!({"x": 1}),
        causal()
            .with_session_id("session-a")
            .with_workspace_id("workspace-a"),
    );
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
    let db_path = dir.path().join("tron.sqlite");

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
fn sqlite_engine_ledger_blobs_large_results_but_replays_public_value() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let large = json!({"items": vec!["same payload"; 2048]});
    let invocation = Invocation::new_sync(
        fid("alpha::large"),
        json!({}),
        causal()
            .with_session_id("session-large")
            .with_workspace_id("workspace-large"),
    );
    let result = super::invocation::InvocationResult::success(
        &invocation,
        wid("w1"),
        FunctionRevision(1),
        CatalogRevision(1),
        large.clone(),
    );
    let record = super::invocation::InvocationRecord::from_result(&invocation, &result, None);

    {
        let mut store = SqliteEngineLedgerStore::open(&db_path).unwrap();
        store.append_invocation(&record).unwrap();
        let stored: String = store
            .connection()
            .query_row(
                "SELECT result_json FROM engine_invocations WHERE invocation_id = ?1",
                [invocation.id.as_str()],
                |row| row.get(0),
            )
            .unwrap();
        assert!(stored.contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY));
    }

    let store = SqliteEngineLedgerStore::open(&db_path).unwrap();
    let records = store.list_invocations().unwrap();
    assert_eq!(records[0].result_value, Some(large));
    let refs: i64 = store
        .connection()
        .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
            row.get(0)
        })
        .unwrap();
    let blobs: i64 = store
        .connection()
        .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
        .unwrap();
    assert_eq!(refs, 1);
    assert_eq!(blobs, 1);
}

#[test]
fn sqlite_queue_blobs_large_payload_but_claim_returns_original_payload() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let large = json!({"items": vec!["queued"; 2048]});
    let mut store = super::queue::SqliteEngineQueueStore::open(&db_path).unwrap();
    let item = store
        .enqueue(super::queue::EnqueueInvocation {
            queue: "agent".to_owned(),
            function_id: fid("agent::run_turn"),
            target_revision: Some(FunctionRevision(1)),
            payload: large.clone(),
            actor_id: actor("agent"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: grant("grant"),
            authority_scopes: vec!["agent.run".to_owned()],
            trace_id: TraceId::generate(),
            parent_invocation_id: None,
            trigger_id: None,
            session_id: Some("session-queue".to_owned()),
            workspace_id: Some("workspace-queue".to_owned()),
            idempotency_key: Some("queue-key".to_owned()),
        })
        .unwrap();
    let stored: String = store
        .connection()
        .query_row(
            "SELECT payload_json FROM engine_queue_items WHERE receipt_id = ?1",
            [item.receipt_id.as_str()],
            |row| row.get(0),
        )
        .unwrap();
    assert!(stored.contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY));
    let claimed = store.claim("agent", "test", 1000).unwrap().unwrap();
    assert_eq!(claimed.payload, large);
}

#[test]
fn sqlite_stream_blobs_large_payload_but_poll_returns_original_payload() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("tron.sqlite");
    let large = json!({"items": vec!["streamed"; 2048]});
    let mut store = super::streams::SqliteEngineStreamStore::open(&db_path).unwrap();
    store
        .publish(super::streams::PublishStreamEvent {
            topic: "agent.runtime".to_owned(),
            payload: large.clone(),
            visibility: VisibilityScope::Session,
            session_id: Some("session-stream".to_owned()),
            workspace_id: Some("workspace-stream".to_owned()),
            producer: "agent".to_owned(),
            trace_id: Some(TraceId::generate()),
            parent_invocation_id: None,
        })
        .unwrap();
    let stored: String = store
        .connection()
        .query_row(
            "SELECT payload_json FROM engine_stream_events WHERE cursor = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(stored.contains(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY));
    store
        .subscribe(
            "sub".to_owned(),
            "agent.runtime".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-stream".to_owned()),
            Some("workspace-stream".to_owned()),
        )
        .unwrap();
    let page = store
        .poll(
            "sub",
            None,
            10,
            &StreamActorScope {
                session_id: Some("session-stream".to_owned()),
                workspace_id: Some("workspace-stream".to_owned()),
                admin: false,
            },
        )
        .unwrap();
    assert_eq!(page.events[0].payload, large);
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
fn discovery_text_query_matches_tokens_across_canonical_id() {
    let mut catalog = LiveCatalog::new();
    catalog
        .register_worker(worker("sandbox", "worker"), true)
        .unwrap();
    catalog
        .register_function(
            read_function("worker::spawn", "sandbox"),
            Some(handler()),
            true,
        )
        .unwrap();

    let agent = ActorContext::new(actor("agent"), ActorKind::Agent, grant("grant"));
    let filtered = catalog.discover_functions(&FunctionQuery {
        text: Some("worker spawn".to_owned()),
        actor: Some(agent),
        ..FunctionQuery::default()
    });

    assert_eq!(filtered.len(), 1);
    assert_eq!(filtered[0].id.as_str(), "worker::spawn");
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
    let db_path = dir.path().join("tron.sqlite");
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
async fn host_unregister_function_updates_discovery_and_watch() {
    let host = EngineHostHandle::new_in_memory().unwrap();
    host.register_worker_for_setup(worker("w1", "alpha"), true)
        .unwrap();
    host.register_function_for_setup(read_function("alpha::read", "w1"), Some(handler()), true)
        .unwrap();

    let actor_context = ActorContext::new(actor("system"), ActorKind::System, grant("grant"));
    let query = FunctionQuery {
        actor: Some(actor_context.clone()),
        namespace_prefix: Some("alpha::".to_owned()),
        include_internal: true,
        ..FunctionQuery::default()
    };
    assert_eq!(host.discover(&query).await.len(), 1);

    let before = host
        .watch(&actor_context, CatalogWatchRequest::default())
        .await
        .unwrap()
        .current_revision;
    host.unregister_function(&fid("alpha::read"), &wid("w1"))
        .await
        .unwrap();

    assert!(host.discover(&query).await.is_empty());
    let page = host
        .watch(
            &actor_context,
            CatalogWatchRequest {
                after_revision: before,
                classes: Some(vec![CatalogChangeClass::Availability]),
                subject_prefix: Some("alpha::".to_owned()),
                owner_worker: Some(wid("w1")),
                ..CatalogWatchRequest::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(page.changes.len(), 1);
    assert_eq!(
        page.changes[0].kind,
        CatalogChangeKind::FunctionUnregistered
    );
    assert_eq!(page.changes[0].subject_id, "alpha::read");
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
        Some(EngineError::PolicyViolation(message)) if message.contains("idempotency key")
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
        assert_eq!(function.visibility, VisibilityScope::System);
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

#[tokio::test]
async fn sqlite_engine_host_handle_reopens_watchable_catalog_changes() {
    let dir = tempfile::tempdir().unwrap();
    let ledger_path = dir.path().join("tron.sqlite");
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
        .catalog_changes_after(CatalogRevision(0), 500)
        .unwrap();
    assert!(
        changes
            .iter()
            .any(|change| change.subject_id == "engine::discover")
    );
    assert!(changes.iter().any(|change| change.subject_id == "w1"));
}

#[tokio::test]
async fn storage_primitives_report_and_checkpoint_unified_sqlite_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();

    let stats = handle
        .invoke(Invocation::new_sync(
            fid("storage::stats"),
            json!({}),
            causal().with_scope("storage.read"),
        ))
        .await;
    assert_eq!(stats.error, None);
    assert_eq!(
        stats.value.as_ref().unwrap()["stats"]["databasePath"],
        path.to_string_lossy().as_ref()
    );

    let checkpoint = handle
        .invoke(Invocation::new_sync(
            fid("storage::checkpoint"),
            json!({}),
            causal()
                .with_scope("storage.write")
                .with_session_id("session-a")
                .with_idempotency_key("storage-checkpoint-test"),
        ))
        .await;
    assert_eq!(checkpoint.error, None);
    assert_eq!(
        checkpoint.value.as_ref().unwrap()["checkpoint"]["databasePath"],
        path.to_string_lossy().as_ref()
    );
}

#[tokio::test]
async fn observability_log_query_reads_storage_logs_and_expands_payloads_only_when_requested() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    {
        let runtime = crate::shared::storage::StorageRuntime::new(&path);
        let conn = runtime.open_connection().unwrap();
        conn.execute_batch(
            "CREATE TABLE logs (
                id INTEGER PRIMARY KEY,
                timestamp TEXT NOT NULL,
                level TEXT NOT NULL,
                level_num INTEGER NOT NULL,
                component TEXT NOT NULL DEFAULT '',
                message TEXT DEFAULT '',
                session_id TEXT,
                workspace_id TEXT,
                event_id TEXT,
                turn INTEGER,
                trace_id TEXT,
                parent_trace_id TEXT,
                depth INTEGER,
                data TEXT,
                error_message TEXT,
                error_stack TEXT,
                origin TEXT
            );",
        )
        .unwrap();
        let data = crate::shared::storage::store_json_bytes(
            &conn,
            serde_json::json!({"items": vec!["logged"; 2048]})
                .to_string()
                .as_bytes(),
            &crate::shared::storage::StorePayloadOptions::new(
                "log_entry",
                "log-query-row",
                "data",
                "diagnostic_verbose",
            )
            .with_scope(
                Some("trace-log".to_owned()),
                Some("session-log".to_owned()),
                Some("workspace-log".to_owned()),
            )
            .with_inline_threshold(1),
        )
        .unwrap();
        conn.execute(
            "INSERT INTO logs (
                timestamp, level, level_num, component, message, session_id,
                workspace_id, trace_id, data, origin
             ) VALUES (?1, 'debug', 20, 'StorageTest', 'large log payload',
                       'session-log', 'workspace-log', 'trace-log', ?2, 'test')",
            rusqlite::params![chrono::Utc::now().to_rfc3339(), data],
        )
        .unwrap();
    }

    let compact = handle
        .invoke(Invocation::new_sync(
            fid("observability::log_query"),
            json!({"traceId": "trace-log", "includeFullPayloads": false}),
            causal().with_scope("observability.read"),
        ))
        .await;
    assert_eq!(compact.error, None);
    let compact_logs = compact.value.as_ref().unwrap()["logs"].as_array().unwrap();
    assert_eq!(compact_logs.len(), 1);
    assert!(
        compact_logs[0]["data"]
            .get(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY)
            .is_some()
    );

    let expanded = handle
        .invoke(Invocation::new_sync(
            fid("observability::log_query"),
            json!({"traceId": "trace-log", "includeFullPayloads": true}),
            causal().with_scope("observability.read"),
        ))
        .await;
    assert_eq!(expanded.error, None);
    let expanded_logs = expanded.value.as_ref().unwrap()["logs"].as_array().unwrap();
    assert_eq!(expanded_logs.len(), 1);
    assert_eq!(
        expanded_logs[0]["data"]["items"]
            .as_array()
            .unwrap()
            .first()
            .and_then(Value::as_str),
        Some("logged")
    );
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
    assert_eq!(discover.visibility, VisibilityScope::System);
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
async fn primitive_catalog_worker_and_observability_functions_share_engine_path() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let system_context = |trace_id: &str, scope: &str| {
        CausalContext::new(
            actor("system"),
            ActorKind::System,
            grant("system-grant"),
            trace(trace_id),
        )
        .with_scope(scope)
    };

    let catalog = handle
        .invoke(host_invocation(
            "catalog::list",
            json!({"includeInternal": true}),
            system_context("primitive-trace", "catalog.read"),
        ))
        .await;
    assert_eq!(catalog.error, None);
    assert!(
        catalog.value.as_ref().unwrap()["functions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|function| function["id"] == "observability::trace_get")
    );

    let workers = handle
        .invoke(host_invocation(
            "worker::list",
            json!({}),
            system_context("primitive-trace", "worker.read"),
        ))
        .await;
    assert_eq!(workers.error, None);
    assert!(
        workers.value.as_ref().unwrap()["workers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|worker| worker["id"] == "observability")
    );

    let guide = handle
        .invoke(host_invocation(
            "worker::protocol_guide",
            json!({
                "functionId": "demo::echo",
                "workerId": "demo-echo-worker",
                "language": "python"
            }),
            system_context("primitive-trace", "worker.read"),
        ))
        .await;
    assert_eq!(guide.error, None);
    let guide_value = guide.value.as_ref().unwrap();
    assert_eq!(guide_value["protocolVersion"], 1);
    assert_eq!(
        guide_value["environment"]["TRON_ENGINE_BEARER_TOKEN"],
        "Bearer token injected by worker::spawn; send it as Authorization: Bearer <token>"
    );
    let template = guide_value["pythonTemplate"].as_str().unwrap();
    assert!(template.contains("Authorization: Bearer"));
    assert!(template.contains("\"type\": \"register_function\""));
    assert!(template.contains("demo::echo"));
    assert!(template.contains("endpoint = \"ws://\" + endpoint"));
    assert!(template.contains("must target /engine/workers"));

    let node_guide = handle
        .invoke(host_invocation(
            "worker::protocol_guide",
            json!({
                "functionId": "demo::echo",
                "workerId": "demo-echo-worker",
                "language": "node"
            }),
            system_context("primitive-trace-node", "worker.read"),
        ))
        .await;
    assert_eq!(node_guide.error, None);
    let node_guide_value = node_guide.value.as_ref().unwrap();
    assert_eq!(node_guide_value["requestedLanguage"], "node");
    assert_eq!(node_guide_value["templateLanguage"], "python");
    assert!(
        node_guide_value["pythonTemplate"]
            .as_str()
            .unwrap()
            .contains("demo::echo")
    );

    let trace_id = trace("primitive-trace");
    let parent_invocation_id = InvocationId::generate();
    let lease = handle
        .acquire_resource_lease(AcquireResourceLease {
            resource_kind: "test-resource".to_owned(),
            resource_id: "primitive-trace-resource".to_owned(),
            holder_invocation_id: parent_invocation_id.clone(),
            function_id: fid("test::write"),
            actor_id: actor("system"),
            authority_grant_id: grant("system-grant"),
            trace_id: trace_id.clone(),
            parent_invocation_id: Some(parent_invocation_id.clone()),
            idempotency_key: Some("primitive-trace-lease".to_owned()),
            ttl_ms: 30_000,
        })
        .await
        .unwrap();
    let stream_cursor = handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "test.observability".to_owned(),
            payload: json!({"ok": true}),
            visibility: VisibilityScope::System,
            session_id: None,
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace_id),
            parent_invocation_id: Some(parent_invocation_id),
        })
        .await
        .unwrap();

    let trace_get = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": "primitive-trace"}),
            system_context("observability-query", "observability.read"),
        ))
        .await;
    assert_eq!(trace_get.error, None);
    assert!(
        trace_get.value.as_ref().unwrap()["summary"]["streamCount"]
            .as_u64()
            .unwrap()
            >= 1
    );
    assert_eq!(
        trace_get.value.as_ref().unwrap()["summary"]["leaseCount"],
        1
    );
    let invocations = trace_get.value.as_ref().unwrap()["invocations"]
        .as_array()
        .unwrap();
    assert!(
        invocations
            .iter()
            .any(|record| record["functionId"] == "catalog::list")
    );
    assert!(
        trace_get.value.as_ref().unwrap()["streams"]
            .as_array()
            .unwrap()
            .iter()
            .any(|event| event["cursor"] == stream_cursor.0)
    );
    assert!(
        trace_get.value.as_ref().unwrap()["leases"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["leaseId"] == lease.lease_id)
    );

    let spans = handle
        .invoke(host_invocation(
            "observability::span_list",
            json!({"traceId": "primitive-trace"}),
            system_context("observability-query", "observability.read"),
        ))
        .await;
    assert_eq!(spans.error, None);
    assert!(
        spans.value.as_ref().unwrap()["spans"]
            .as_array()
            .unwrap()
            .iter()
            .any(|span| span["functionId"] == "worker::list")
    );
    assert!(
        spans.value.as_ref().unwrap()["spans"]
            .as_array()
            .unwrap()
            .iter()
            .any(|span| span["kind"] == "stream" && span["topic"] == "test.observability")
    );
    assert!(
        spans.value.as_ref().unwrap()["spans"]
            .as_array()
            .unwrap()
            .iter()
            .any(|span| span["kind"] == "resource_lease"
                && span["resourceId"] == "primitive-trace-resource")
    );

    let stream_logs = handle
        .invoke(host_invocation(
            "observability::log_query",
            json!({"traceId": "primitive-trace", "text": "stream"}),
            system_context("observability-query", "observability.read"),
        ))
        .await;
    assert_eq!(stream_logs.error, None);
    let logs = stream_logs.value.as_ref().unwrap()["logs"]
        .as_array()
        .unwrap();
    assert!(
        logs.iter()
            .any(|log| log["kind"] == "stream" && log["topic"] == "test.observability")
    );

    let metrics = handle
        .invoke(host_invocation(
            "observability::metrics_snapshot",
            json!({}),
            system_context("observability-query", "observability.read"),
        ))
        .await;
    assert_eq!(metrics.error, None);
    assert!(
        metrics.value.as_ref().unwrap()["metrics"]["workers"]
            .as_u64()
            .unwrap()
            >= 1
    );
    assert!(
        metrics.value.as_ref().unwrap()["metrics"]["traces"]
            .as_u64()
            .unwrap()
            >= 1
    );

    let delegated_metrics = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "observability::metrics_snapshot",
                "payload": {},
            }),
            system_context("observability-query-delegated", "observability.read"),
        ))
        .await;
    assert_eq!(delegated_metrics.error, None);
    let delegated_child = &delegated_metrics.value.as_ref().unwrap()["child"];
    assert_eq!(delegated_child["error"], Value::Null);
    assert!(
        delegated_child["value"]["metrics"]["workers"]
            .as_u64()
            .unwrap()
            >= 1
    );
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
    let db_path = dir.path().join("tron.sqlite");
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
        .catalog_changes_after(CatalogRevision(0), 500)
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

    let no_promote_grant = host
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "no-promote-grant",
                "parentGrantId": "grant",
                "allowedCapabilities": ["engine::discover"],
                "allowedNamespaces": ["engine"],
                "allowedAuthorityScopes": ["engine.discover"],
                "allowedResourceKinds": ["*"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "critical"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("promote-grant-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-no-promote"),
        ))
        .await;
    assert_eq!(no_promote_grant.error, None);

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
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("no-promote-grant"),
                trace("promote-no-grant"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_scope("engine.promote")
            .with_idempotency_key("promote-no-scope"),
        ))
        .await;
    assert!(matches!(
        no_scope.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow function")
                || message.contains("does not allow required authority")
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

#[tokio::test]
async fn stream_primitive_subscribe_poll_and_unsubscribe_are_scoped() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let subscribe = handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "sub-a",
                "topic": "events.session",
                "sessionId": "session-a"
            }),
            mutating_causal("stream-subscribe").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(subscribe.error, None);
    assert_eq!(subscribe.value.as_ref().unwrap()["subscriptionId"], "sub-a");

    handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"visible": true}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("stream-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();
    handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"visible": false}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-b".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("stream-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    let poll = handle
        .invoke(host_invocation(
            "stream::poll",
            json!({"subscriptionId": "sub-a", "limit": 10}),
            causal()
                .with_scope("stream.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(poll.error, None);
    let events = poll.value.as_ref().unwrap()["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["payload"], json!({"visible": true}));

    let hidden = handle
        .poll_stream(
            "sub-a",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-b".to_owned()), None),
        )
        .await;
    assert!(matches!(
        hidden,
        Err(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let unsubscribe = handle
        .invoke(host_invocation(
            "stream::unsubscribe",
            json!({"subscriptionId": "sub-a"}),
            mutating_causal("stream-unsubscribe").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(unsubscribe.error, None);
    assert_eq!(unsubscribe.value.as_ref().unwrap()["unsubscribed"], true);
}

#[tokio::test]
async fn stream_primitive_subscribe_without_after_cursor_starts_at_topic_tail() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let old_cursor = handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"old": true}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("stream-tail-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    let subscribe = handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "sub-tail",
                "topic": "events.session",
                "sessionId": "session-a"
            }),
            mutating_causal("stream-subscribe-tail").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(subscribe.error, None);
    assert_eq!(subscribe.value.as_ref().unwrap()["cursor"], old_cursor.0);

    handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"new": true}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("stream-tail-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    let poll = handle
        .invoke(host_invocation(
            "stream::poll",
            json!({"subscriptionId": "sub-tail", "limit": 10}),
            causal()
                .with_scope("stream.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(poll.error, None);
    let events = poll.value.as_ref().unwrap()["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["payload"], json!({"new": true}));
}

async fn assert_stream_poll_reaches_visible_event_after_invisible_prefix(handle: EngineHostHandle) {
    let target_session = "session-visible";
    for index in 0..4 {
        handle
            .publish_stream_event(super::PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({"visible": false, "index": index}),
                visibility: VisibilityScope::Session,
                session_id: Some("session-hidden".to_owned()),
                workspace_id: None,
                producer: "test".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
            .unwrap();
    }
    let target_cursor = handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"visible": true}),
            visibility: VisibilityScope::Session,
            session_id: Some(target_session.to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    handle
        .subscribe_stream(
            "sub-visible".to_owned(),
            "events.session".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some(target_session.to_owned()),
            None,
        )
        .await
        .unwrap();
    let actor = StreamActorScope::scoped(Some(target_session.to_owned()), None);
    let mut after = StreamCursor(0);
    for _ in 0..4 {
        let page = handle
            .poll_stream("sub-visible", Some(after), 2, &actor)
            .await
            .unwrap();
        if let Some(event) = page.events.first() {
            assert_eq!(event.cursor, target_cursor);
            assert_eq!(event.payload, json!({"visible": true}));
            assert!(page.next_cursor >= target_cursor);
            return;
        }
        assert!(
            page.next_cursor > after,
            "empty stream pages must still advance past visibility-filtered rows"
        );
        after = page.next_cursor;
    }
    panic!("stream poll did not reach visible event after invisible prefix");
}

#[tokio::test]
async fn stream_poll_advances_past_visibility_filtered_rows_in_memory() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    assert_stream_poll_reaches_visible_event_after_invisible_prefix(handle).await;
}

#[tokio::test]
async fn stream_poll_advances_past_visibility_filtered_rows_in_sqlite() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    assert_stream_poll_reaches_visible_event_after_invisible_prefix(handle).await;
}

#[tokio::test]
async fn state_primitive_revisions_cas_list_and_delete_are_idempotent() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let context = |key: &str| {
        mutating_causal(key)
            .with_scope("state.write")
            .with_session_id("session-a")
    };
    let set = handle
        .invoke(host_invocation(
            "state::set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "value": {"text": "one"}
            }),
            context("state-set-1"),
        ))
        .await;
    assert_eq!(set.error, None);
    assert_eq!(set.value.as_ref().unwrap()["entry"]["revision"], 1);

    let replay = handle
        .invoke(host_invocation(
            "state::set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "value": {"text": "one"}
            }),
            context("state-set-1"),
        ))
        .await;
    assert_eq!(replay.error, None);
    assert_eq!(replay.replayed_from, Some(set.invocation_id.clone()));

    let cas = handle
        .invoke(host_invocation(
            "state::compare_and_set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "expectedRevision": 1,
                "value": {"text": "two"}
            }),
            context("state-cas-1"),
        ))
        .await;
    assert_eq!(cas.error, None);
    assert_eq!(cas.value.as_ref().unwrap()["entry"]["revision"], 2);

    let stale = handle
        .invoke(host_invocation(
            "state::compare_and_set",
            json!({
                "scope": "session",
                "namespace": "agent",
                "key": "draft",
                "expectedRevision": 1,
                "value": {"text": "three"}
            }),
            context("state-cas-stale"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("revision conflict")
    ));

    let listed = handle
        .invoke(host_invocation(
            "state::list",
            json!({"scope": "session", "namespace": "agent", "keyPrefix": "dr"}),
            causal()
                .with_scope("state.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(listed.error, None);
    assert_eq!(
        listed.value.as_ref().unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let deleted = handle
        .invoke(host_invocation(
            "state::delete",
            json!({"scope": "session", "namespace": "agent", "key": "draft"}),
            context("state-delete-1"),
        ))
        .await;
    assert_eq!(deleted.error, None);
    assert_eq!(deleted.value.as_ref().unwrap()["deleted"], true);
}

#[tokio::test]
async fn resource_primitive_manages_typed_resources_through_capabilities() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let admin_context = || {
        CausalContext::new(
            actor("system"),
            ActorKind::System,
            grant("grant"),
            trace("trace"),
        )
        .with_session_id("session-a")
        .with_workspace_id("workspace-a")
        .with_idempotency_key("resource-type-1")
        .with_scope("resource.admin")
        .with_scope("resource.write")
    };
    let agent_register = handle
        .invoke(host_invocation(
            "resource::register_type",
            json!({
                "kind": "artifact",
                "schemaId": "artifact.v1",
                "schema": {"type": "object"},
                "lifecycleStates": ["draft", "promoted", "discarded"]
            }),
            mutating_causal("resource-type-agent")
                .with_scope("resource.admin")
                .with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        agent_register.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let registered = handle
        .invoke(host_invocation(
            "resource::register_type",
            json!({
                "kind": "artifact",
                "schemaId": "artifact.v1",
                "schema": {
                    "type": "object",
                    "required": ["title", "body"],
                    "additionalProperties": false,
                    "properties": {
                        "title": {"type": "string"},
                        "body": {"type": "string"}
                    }
                },
                "lifecycleStates": ["draft", "promoted", "discarded"],
                "allowedLinkRelations": ["supports", "supersedes"],
                "requiredCapabilities": {
                    "read": "resource::inspect",
                    "write": "resource::update"
                }
            }),
            admin_context(),
        ))
        .await;
    assert_eq!(registered.error, None);
    assert_eq!(
        registered.value.as_ref().unwrap()["typeDefinition"]["kind"],
        "artifact"
    );

    let invalid_create = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": "res_invalid_artifact",
                "kind": "artifact",
                "scope": "workspace",
                "lifecycle": "draft",
                "payload": {"title": "draft"}
            }),
            mutating_causal("resource-create-invalid")
                .with_scope("resource.write")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert!(matches!(
        invalid_create.error,
        Some(EngineError::SchemaViolation { .. })
    ));

    let malformed_list = handle
        .invoke(host_invocation(
            "resource::list",
            json!({"scope": "workspace"}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert!(matches!(
        malformed_list.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("workspace-scoped resource requires workspaceId")
    ));

    let write_context = |key: &str| {
        mutating_causal(key)
            .with_scope("resource.write")
            .with_workspace_id("workspace-a")
    };
    let created = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "resourceId": "res_test_artifact",
                "kind": "artifact",
                "scope": "workspace",
                "lifecycle": "draft",
                "payload": {"title": "draft", "body": "one"}
            }),
            write_context("resource-create-1"),
        ))
        .await;
    assert_eq!(created.error, None);
    let current = created.value.as_ref().unwrap()["resource"]["currentVersionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let stale = handle
        .invoke(host_invocation(
            "resource::update",
            json!({
                "resourceId": "res_test_artifact",
                "expectedCurrentVersionId": "stale",
                "payload": {"title": "draft", "body": "bad"}
            }),
            write_context("resource-update-stale"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("version conflict")
    ));

    let updated = handle
        .invoke(host_invocation(
            "resource::update",
            json!({
                "resourceId": "res_test_artifact",
                "expectedCurrentVersionId": current,
                "lifecycle": "promoted",
                "payload": {"title": "draft", "body": "two"}
            }),
            write_context("resource-update-1"),
        ))
        .await;
    assert_eq!(updated.error, None);

    let inspected = handle
        .invoke(host_invocation(
            "resource::inspect",
            json!({"resourceId": "res_test_artifact"}),
            causal()
                .with_scope("resource.read")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(inspected.error, None);
    let inspection = &inspected.value.as_ref().unwrap()["inspection"];
    assert_eq!(inspection["resource"]["lifecycle"], "promoted");
    assert_eq!(inspection["versions"].as_array().unwrap().len(), 2);

    let listed = handle
        .invoke(host_invocation(
            "resource::list",
            json!({
                "kind": "artifact",
                "scope": "workspace",
                "workspaceId": "workspace-a"
            }),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(listed.error, None);
    assert_eq!(
        listed.value.as_ref().unwrap()["resources"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn grant_derivation_rejects_broader_child_grants() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let broader = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "narrow-parent-grant",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::inspect"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low",
                "canDelegate": true
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-derive-parent"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-parent"),
        ))
        .await;
    assert_eq!(broader.error, None);

    let rejected = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "broader-grandchild",
                "parentGrantId": "narrow-parent-grant",
                "allowedCapabilities": ["artifact::inspect", "artifact::create"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-derive-child"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-child"),
        ))
        .await;

    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("capabilities exceeds parent")
    ));
}

#[tokio::test]
async fn invocation_authorization_uses_grant_not_raw_scope_strings() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "artifact-read-only",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::inspect"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["kind:artifact"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-raw-scope"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-read-only"),
        ))
        .await;
    assert_eq!(derived.error, None);

    let result = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "payload": {"title": "draft", "body": "body"}
            }),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("artifact-read-only"),
                trace("raw-scope-ignored"),
            )
            .with_scope("resource.write")
            .with_idempotency_key("artifact-create-denied"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("does not allow function")
                || message.contains("does not allow required authority")
                || message.contains("exceeds grant")
    ));
}

#[tokio::test]
async fn revoked_grants_fail_before_handler_execution() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "revoked-artifact-read",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::inspect"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-revoked-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-revoked"),
        ))
        .await;
    assert_eq!(derived.error, None);

    let revoked = handle
        .invoke(host_invocation(
            "grant::revoke",
            json!({"grantId": "revoked-artifact-read"}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-revoked"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("revoke-artifact-read"),
        ))
        .await;
    assert_eq!(revoked.error, None);

    let denied = handle
        .invoke(host_invocation(
            "artifact::inspect",
            json!({"resourceId": "missing-artifact"}),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("revoked-artifact-read"),
                trace("grant-revoked-invoke"),
            )
            .with_scope("resource.read"),
        ))
        .await;

    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("not active")
    ));
}

#[tokio::test]
async fn expired_grants_fail_before_handler_execution() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let expires_at = (Utc::now() + ChronoDuration::milliseconds(100)).to_rfc3339();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "expiring-artifact-read",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::inspect"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low",
                "expiresAt": expires_at,
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-expired-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-expiring"),
        ))
        .await;
    assert_eq!(derived.error, None);

    tokio::time::sleep(std::time::Duration::from_millis(150)).await;
    let denied = handle
        .invoke(host_invocation(
            "artifact::inspect",
            json!({"resourceId": "missing-artifact"}),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("expiring-artifact-read"),
                trace("grant-expired-invoke"),
            )
            .with_scope("resource.read"),
        ))
        .await;
    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("is expired")
    ));
}

#[tokio::test]
async fn grant_resource_selectors_block_unauthorized_resource_mutations() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "one-artifact-writer",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::create"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.write"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["resource:allowed-artifact"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "medium"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-selector-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-selector"),
        ))
        .await;
    assert_eq!(derived.error, None);

    let denied = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "resourceId": "denied-artifact",
                "payload": {"title": "draft", "body": "body"}
            }),
            CausalContext::new(
                actor("agent"),
                ActorKind::Agent,
                grant("one-artifact-writer"),
                trace("grant-selector-denied"),
            )
            .with_scope("resource.write")
            .with_idempotency_key("denied-artifact-create"),
        ))
        .await;

    assert!(matches!(
        denied.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("does not allow resource")
    ));
}

#[tokio::test]
async fn worker_registration_and_functions_cannot_exceed_worker_grant() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let derived = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "demo-worker-grant",
                "parentGrantId": "grant",
                "allowedCapabilities": ["demo::echo"],
                "allowedNamespaces": ["demo"],
                "allowedAuthorityScopes": ["demo.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("worker-grant-derive"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-demo-worker"),
        ))
        .await;
    assert_eq!(derived.error, None);

    let rejected_worker = handle.register_worker_for_setup(
        WorkerDefinition::new(
            wid("bad-demo-worker"),
            WorkerKind::InProcess,
            actor("owner"),
            grant("demo-worker-grant"),
        )
        .with_namespace_claim("other"),
        false,
    );
    assert!(matches!(
        rejected_worker,
        Err(EngineError::PolicyViolation(message)) if message.contains("namespace other exceeds")
    ));

    handle
        .register_worker_for_setup(
            WorkerDefinition::new(
                wid("demo-worker"),
                WorkerKind::InProcess,
                actor("owner"),
                grant("demo-worker-grant"),
            )
            .with_namespace_claim("demo"),
            false,
        )
        .unwrap();

    let rejected_function = handle.register_function_for_setup(
        FunctionDefinition::new(
            fid("demo::write"),
            wid("demo-worker"),
            "write",
            VisibilityScope::Agent,
            EffectClass::IdempotentWrite,
        )
        .with_required_authority(AuthorityRequirement::scope("demo.write"))
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger()),
        Some(handler()),
        false,
    );
    assert!(matches!(
        rejected_function,
        Err(EngineError::PolicyViolation(message)) if message.contains("exceeds worker grant")
    ));
}

#[tokio::test]
async fn artifact_goal_decision_wrappers_produce_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let artifact = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "resourceId": "artifact-wrapper-test",
                "payload": {"title": "Audit", "body": "draft"}
            }),
            mutating_causal("artifact-wrapper-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(artifact.error, None);
    assert_eq!(
        artifact.value.as_ref().unwrap()["resource"]["resourceId"],
        "artifact-wrapper-test"
    );

    let promoted = handle
        .invoke(host_invocation(
            "artifact::promote",
            json!({"resourceId": "artifact-wrapper-test"}),
            mutating_causal("artifact-wrapper-promote").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(promoted.error, None);
    assert_eq!(
        promoted.value.as_ref().unwrap()["version"]["resourceId"],
        "artifact-wrapper-test"
    );

    let goal = handle
        .invoke(host_invocation(
            "goal::create",
            json!({
                "resourceId": "goal-wrapper-test",
                "payload": {"intent": "Finish substrate", "successCriteria": ["decision recorded"]}
            }),
            mutating_causal("goal-wrapper-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(goal.error, None);

    let agent_result = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "agent_result",
                "resourceId": "agent-result-wrapper-test",
                "payload": {
                    "message": "Completed",
                    "promotedRefs": ["artifact-wrapper-test"],
                    "decisionRefs": [],
                    "subgoalRefs": [],
                    "stopReason": "completed",
                    "tokenUsage": {}
                }
            }),
            mutating_causal("agent-result-wrapper-create").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(agent_result.error, None);

    let completed = handle
        .invoke(host_invocation(
            "goal::complete",
            json!({
                "goalResourceId": "goal-wrapper-test",
                "agentResultResourceId": "agent-result-wrapper-test",
                "promotedResourceIds": ["artifact-wrapper-test"],
                "decision": {"status": "done", "summary": "Substrate checkpoint complete"}
            }),
            mutating_causal("goal-wrapper-complete").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(completed.error, None);
    let value = completed.value.as_ref().unwrap();
    assert_eq!(value["goalVersion"]["resourceId"], "goal-wrapper-test");
    assert_eq!(value["decision"]["kind"], "decision");
    assert_eq!(value["link"]["relation"], "decided_by");
    assert_eq!(value["agentResultLink"]["relation"], "produced");
    assert_eq!(value["promotedLinks"][0]["relation"], "promoted_output");
}

#[tokio::test]
async fn artifact_curation_and_goal_working_set_return_bounded_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let source = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "resourceId": "curation-source",
                "payload": {"title": "Source", "body": "alpha beta gamma"}
            }),
            mutating_causal("curation-source").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(source.error, None);

    let split = handle
        .invoke(host_invocation(
            "artifact::split",
            json!({
                "resourceId": "curation-source",
                "parts": [
                    {"resourceId": "curation-part-a", "payload": {"title": "A", "body": "alpha"}},
                    {"resourceId": "curation-part-b", "payload": {"title": "B", "body": "beta"}}
                ]
            }),
            mutating_causal("curation-split").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(split.error, None);
    assert_eq!(
        split.value.as_ref().unwrap()["resourceRefs"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    let composed = handle
        .invoke(host_invocation(
            "artifact::compose",
            json!({
                "resourceId": "curation-composed",
                "inputResourceIds": ["curation-part-a", "curation-part-b"],
                "payload": {"title": "Composed", "body": "alpha beta"}
            }),
            mutating_causal("curation-compose").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(composed.error, None);
    assert_eq!(
        composed.value.as_ref().unwrap()["resourceRefs"][0]["kind"],
        "artifact"
    );

    let search = handle
        .invoke(host_invocation(
            "artifact::search",
            json!({"query": "source", "scope": "workspace", "workspaceId": "workspace-a", "limit": 5}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(search.error, None);
    assert!(
        !search.value.as_ref().unwrap()["matches"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    let goal = handle
        .invoke(host_invocation(
            "goal::create",
            json!({
                "resourceId": "curation-goal",
                "payload": {"intent": "Curate artifacts", "successCriteria": ["candidate output identified"]}
            }),
            mutating_causal("curation-goal").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(goal.error, None);
    let link = handle
        .invoke(host_invocation(
            "resource::link",
            json!({
                "sourceResourceId": "curation-goal",
                "targetResourceId": "curation-composed",
                "relation": "candidate_output"
            }),
            mutating_causal("curation-link").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(link.error, None);
    let working_set = handle
        .invoke(host_invocation(
            "goal::working_set",
            json!({"goalResourceId": "curation-goal", "previewBytes": 12, "limit": 10}),
            causal().with_scope("resource.read"),
        ))
        .await;
    assert_eq!(working_set.error, None);
    assert_eq!(
        working_set.value.as_ref().unwrap()["candidateOutputs"][0]["resource"]["resourceId"],
        "curation-composed"
    );
    assert!(
        working_set.value.as_ref().unwrap()["resources"][0]["preview"]
            .as_str()
            .unwrap()
            .chars()
            .count()
            <= 12
    );
}

#[tokio::test]
async fn control_snapshot_projects_substrate_without_control_state() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let context = CausalContext::new(
        actor("system"),
        ActorKind::System,
        grant("grant"),
        trace("control-snapshot"),
    )
    .with_scope("control.read");
    let snapshot = handle
        .invoke(host_invocation(
            "control::snapshot",
            json!({"limit": 25}),
            context,
        ))
        .await;
    assert_eq!(snapshot.error, None);
    let value = snapshot.value.as_ref().unwrap();
    assert!(
        value["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability["id"] == "resource::create")
    );
    assert!(
        value["resourceTypes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|resource_type| resource_type["kind"] == "goal")
    );
    assert!(
        value["availableActions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|action| action["functionId"] != "control::act")
    );
}

#[tokio::test]
async fn ui_surface_resource_type_is_registered_and_validated() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let snapshot = handle
        .invoke(host_invocation(
            "control::snapshot",
            json!({"limit": 25}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(snapshot.error, None);
    assert!(
        snapshot.value.as_ref().unwrap()["resourceTypes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|resource_type| resource_type["kind"] == "ui_surface")
    );

    let invalid = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "ui_surface",
                "resourceId": "bad-ui-surface",
                "payload": {
                    "surfaceId": "bad",
                    "title": "Bad",
                    "purpose": "Reject unknown catalog",
                    "catalog": {"id": "tron.ui.catalog.unknown.v1", "revision": 1},
                    "layout": {"type": "Text", "props": {"text": "bad"}},
                    "bindings": [],
                    "actions": [],
                    "redactionPolicy": {"mode": "redacted"},
                    "expiresAt": "2100-01-01T00:00:00Z",
                    "refreshPolicy": {"mode": "manual"}
                }
            }),
            mutating_causal("ui-surface-invalid").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        invalid.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("catalog")
    ));

    let mut invalid_placeholder = valid_ui_surface("demo::inspect", 1);
    invalid_placeholder["actions"][0]["payloadTemplate"]["message"] = json!("${input.missing}");
    let invalid_placeholder_result = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "ui_surface",
                "resourceId": "bad-ui-placeholder",
                "payload": invalid_placeholder
            }),
            mutating_causal("bad-ui-placeholder").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        invalid_placeholder_result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("unknown input field")
    ));

    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-registered",
                "surface": valid_ui_surface("demo::inspect", 1)
            }),
            mutating_causal("ui-surface-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let value = created.value.as_ref().unwrap();
    assert_eq!(value["resourceRefs"][0]["kind"], "ui_surface");
    assert_eq!(value["resource"]["kind"], "ui_surface");
    assert_eq!(value["resource"]["lifecycle"], "active");
}

#[tokio::test]
async fn ui_surface_update_requires_expected_current_version() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();

    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-cas",
                "surface": valid_ui_surface("demo::inspect", 1)
            }),
            mutating_causal("ui-surface-cas-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);

    let rejected = handle
        .invoke(host_invocation(
            "ui::update_surface",
            json!({
                "resourceId": "ui-surface-cas",
                "expectedCurrentVersionId": "wrong-version",
                "surface": valid_ui_surface("demo::inspect", 1)
            }),
            mutating_causal("ui-surface-cas-update").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("version conflict")
    ));
}

#[tokio::test]
async fn ui_create_surface_rejects_unknown_action_target() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let rejected = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-missing-target",
                "surface": valid_ui_surface("missing::target", 1)
            }),
            mutating_causal("ui-surface-missing-target").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::NotFound { kind, id })
            if kind == "function" && id == "missing::target"
    ));
}

#[tokio::test]
async fn ui_create_surface_rejects_action_template_outside_target_request_schema() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let target = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "schema-constrained write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_request_schema(json!({
        "type": "object",
        "required": ["message"],
        "additionalProperties": false,
        "properties": {
            "message": {"type": "string"}
        }
    }))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(target, Some(handler()), false)
        .unwrap();

    let rejected = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-bad-template",
                "surface": valid_ui_surface("demo::write", 1)
            }),
            mutating_causal("ui-surface-bad-template").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("payloadTemplate")
                && message.contains("sourceSurface")
                && message.contains("not accepted")
    ));
}

#[tokio::test]
async fn ui_submit_action_validates_stored_surface_and_creates_child_invocation() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let target = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "resource-backed write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            target,
            Some(Arc::new(StaticValueHandler(json!({
                "accepted": true,
                "resourceRefs": [{
                    "resourceId": "artifact-from-ui",
                    "kind": "artifact",
                    "versionId": "ver-ui",
                    "role": "created",
                    "contentHash": "hash-ui"
                }]
            })))),
            false,
        )
        .unwrap();

    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-action",
                "surface": valid_ui_surface("demo::write", 1)
            }),
            mutating_causal("ui-surface-action-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);
    let surface_version = created.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let stale = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": "ui-surface-action",
                "surfaceVersionId": "wrong-version",
                "actionId": "submit-test",
                "userInput": {"message": "hello"},
                "idempotencyKey": "ui-action-stale"
            }),
            mutating_causal("ui-action-stale").with_scope("ui.write"),
        ))
        .await;
    assert!(matches!(
        stale.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("stale")
    ));

    let submitted = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": "ui-surface-action",
                "surfaceVersionId": surface_version,
                "actionId": "submit-test",
                "userInput": {"message": "hello"},
                "idempotencyKey": "ui-action-submit"
            }),
            mutating_causal("ui-action-submit").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(submitted.error, None);
    let value = submitted.value.as_ref().unwrap();
    assert_eq!(value["targetFunctionId"], "demo::write");
    assert_eq!(
        value["result"]["resourceRefs"][0]["resourceId"],
        "artifact-from-ui"
    );

    let records = handle.lock().await.catalog().invocations().to_vec();
    let child = records
        .iter()
        .find(|record| {
            record.function_id.as_str() == "demo::write"
                && record
                    .parent_invocation_id
                    .as_ref()
                    .is_some_and(|parent| parent == &submitted.invocation_id)
        })
        .expect("ui submit must create a trace-linked child invocation");
    assert_eq!(
        child.produced_resource_refs[0]["resourceId"],
        "artifact-from-ui"
    );
}

#[tokio::test]
async fn control_snapshot_and_inspect_expose_ui_surface_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("demo::inspect", "demo"),
            Some(handler()),
            false,
        )
        .unwrap();
    let created = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "ui-surface-control",
                "surface": valid_ui_surface("demo::inspect", 1),
                "links": [
                    {"targetType": "worker", "targetId": "demo"},
                    {"targetType": "capability", "targetId": "demo::inspect"}
                ]
            }),
            mutating_causal("ui-surface-control-create").with_scope("ui.write"),
        ))
        .await;
    assert_eq!(created.error, None);

    let snapshot = handle
        .invoke(host_invocation(
            "control::snapshot",
            json!({"limit": 25}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(snapshot.error, None);
    assert!(
        snapshot.value.as_ref().unwrap()["uiSurfaceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|surface| surface["resourceId"] == "ui-surface-control")
    );

    let inspect = handle
        .invoke(host_invocation(
            "control::inspect",
            json!({"targetType": "worker", "targetId": "demo"}),
            causal().with_scope("control.read"),
        ))
        .await;
    assert_eq!(inspect.error, None);
    assert!(
        inspect.value.as_ref().unwrap()["uiSurfaceRefs"]
            .as_array()
            .unwrap()
            .iter()
            .any(|surface| surface["resourceId"] == "ui-surface-control")
    );
}

#[tokio::test]
async fn materialized_file_update_writes_file_and_returns_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("nested").join("result.txt");

    let result = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "resource-owned bytes"
            }),
            mutating_causal("materialized-file-update").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "resource-owned bytes"
    );
    let value = result.value.as_ref().unwrap();
    assert_eq!(value["version"]["state"], "available");
    assert_eq!(value["resourceRefs"][0]["kind"], "materialized_file");
    assert_eq!(value["resourceRefs"][0]["role"], "updated");
}

#[tokio::test]
async fn materialized_file_version_conflict_does_not_touch_target_file() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("result.txt");

    let first = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "first version"
            }),
            mutating_causal("materialized-file-conflict-first").with_scope("resource.write"),
        ))
        .await;
    assert_eq!(first.error, None);

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "should not be written",
                "expectedCurrentVersionId": "wrong-version"
            }),
            mutating_causal("materialized-file-conflict-second").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("version conflict")
    ));
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "first version");
}

#[tokio::test]
async fn materialized_file_invalid_scope_does_not_touch_target_file() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("result.txt");

    let rejected = handle
        .invoke(host_invocation(
            "materialized_file::update",
            json!({
                "path": target.to_string_lossy(),
                "content": "should not be written",
                "scope": "workspace",
                "workspaceId": ""
            }),
            mutating_causal("materialized-file-invalid-scope").with_scope("resource.write"),
        ))
        .await;
    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("workspaceId must not be empty")
    ));
    assert!(
        !target.exists(),
        "invalid resource scope must fail before target bytes are written"
    );
}

#[tokio::test]
async fn resource_backed_invocation_fails_without_top_level_resource_refs() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(StaticValueHandler(json!({"ok": true})))),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "demo::write",
            json!({}),
            mutating_causal("resource-backed-missing-refs").with_scope("demo.write"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("resource-backed output")
                && message.contains("resourceRefs")
    ));
}

#[tokio::test]
async fn resource_backed_refs_are_persisted_in_invocation_records() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("demo", "demo"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("demo::write"),
        wid("demo"),
        "write",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("demo.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(StaticValueHandler(json!({
                "resourceRefs": [{
                    "resourceId": "artifact-test",
                    "kind": "artifact",
                    "versionId": "ver-test",
                    "role": "created",
                    "contentHash": "hash-test"
                }]
            })))),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "demo::write",
            json!({}),
            mutating_causal("resource-backed-persisted").with_scope("demo.write"),
        ))
        .await;
    assert_eq!(result.error, None);

    let records = handle.lock().await.catalog().invocations().to_vec();
    let record = records
        .iter()
        .find(|record| record.invocation_id == result.invocation_id)
        .unwrap();
    assert_eq!(record.produced_resource_refs.len(), 1);
    assert_eq!(
        record.produced_resource_refs[0]["resourceId"],
        "artifact-test"
    );
}

#[tokio::test]
async fn converted_filesystem_outputs_do_not_expose_output_audit_projection() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("filesystem", "filesystem"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("filesystem::write_file"),
        wid("filesystem"),
        "write file",
        VisibilityScope::Agent,
        EffectClass::IdempotentWrite,
    )
    .with_required_authority(AuthorityRequirement::scope("filesystem.write"))
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_output_contract(DurableOutputContract::resource_backed([
        "materialized_file",
    ]));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(StaticValueHandler(json!({
                "path": "/tmp/tron-output-audit.txt",
                "bytesWritten": 5,
                "created": true,
                "resourceRefs": [{
                    "resourceId": "materialized_file:test",
                    "kind": "materialized_file",
                    "versionId": "ver-test",
                    "role": "updated",
                    "contentHash": "hash-test"
                }]
            })))),
            false,
        )
        .unwrap();
    let result = handle
        .invoke(host_invocation(
            "filesystem::write_file",
            json!({"path": "/tmp/tron-output-audit.txt", "content": "draft"}),
            mutating_causal("filesystem-materialized-output")
                .with_scope("filesystem.write")
                .with_idempotency_key("filesystem-materialized-output"),
        ))
        .await;
    assert_eq!(result.error, None);
    let refs = result.value.as_ref().unwrap()["resourceRefs"]
        .as_array()
        .unwrap();
    assert_eq!(refs[0]["kind"], "materialized_file");

    let trace = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": result.trace_id.as_str()}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("output-audit-trace"),
            )
            .with_scope("observability.read"),
        ))
        .await;
    assert_eq!(trace.error, None);
    assert!(
        trace.value.as_ref().unwrap().get("outputAudit").is_none(),
        "output audit must not remain an active trace projection"
    );
}

#[tokio::test]
async fn resource_lease_acquire_release_conflict_and_stream_records() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let first = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await
        .unwrap();
    assert_eq!(first.status, EngineResourceLeaseStatus::Active);
    assert_eq!(first.resource_kind, "session");
    assert_eq!(first.resource_id, "s1:model");

    let conflict = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await;
    assert!(matches!(
        conflict,
        Err(EngineError::PolicyViolation(message)) if message.contains("resource lease conflict")
    ));

    let released = handle
        .release_resource_lease(&first.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(released.status, EngineResourceLeaseStatus::Released);
    let released_again = handle
        .release_resource_lease(&first.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(released_again.status, EngineResourceLeaseStatus::Released);

    let second = handle
        .acquire_resource_lease(lease_request("session", "s1:model", 30_000))
        .await
        .unwrap();
    assert_ne!(first.lease_id, second.lease_id);

    handle
        .subscribe_stream(
            "lease-sub".to_owned(),
            "resource.leases".to_owned(),
            StreamCursor(0),
            VisibilityScope::System,
            None,
            None,
        )
        .await
        .unwrap();
    let page = handle
        .poll_stream(
            "lease-sub",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::admin(),
        )
        .await
        .unwrap();
    let event_types = page
        .events
        .iter()
        .map(|event| event.payload["type"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(event_types.contains(&"resource_lease.acquired"));
    assert!(event_types.contains(&"resource_lease.released"));
}

#[tokio::test]
async fn resource_lease_expiry_and_sqlite_reopen_preserve_records() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    let first = handle
        .acquire_resource_lease(lease_request("import", "session.json", 1))
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    let second = handle
        .acquire_resource_lease(lease_request("import", "session.json", 30_000))
        .await
        .unwrap();
    assert_ne!(first.lease_id, second.lease_id);
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let loaded = reopened
        .get_resource_lease(&second.lease_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(loaded.status, EngineResourceLeaseStatus::Active);
    assert_eq!(loaded.resource_kind, "import");
    assert_eq!(loaded.resource_id, "session.json");
    assert_eq!(loaded.function_id, fid("test::write"));
    assert_eq!(loaded.idempotency_key.as_deref(), Some("idem"));
}

#[tokio::test]
async fn host_invocation_enforces_resource_lease_and_records_compensation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"sessionId": "session-a", "value": 1}),
            mutating_causal("lease-key").with_scope("alpha.write"),
        ))
        .await;

    assert_eq!(result.error, None);
    let host = handle.lock().await;
    let record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| record.function_id == fid("alpha::write"))
        .unwrap();
    assert_eq!(record.resource_lease_ids.len(), 1);
    assert_eq!(record.compensation_status.as_deref(), Some("recorded"));
    let lease_id = record.resource_lease_ids[0].clone();
    drop(host);

    let lease = handle.get_resource_lease(&lease_id).await.unwrap().unwrap();
    assert_eq!(lease.status, EngineResourceLeaseStatus::Released);
    let compensation = handle.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert_eq!(compensation[0].resource_lease_ids, vec![lease_id]);
    assert!(compensation[0].succeeded);
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let compensation = reopened.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert_eq!(compensation[0].function_id, fid("alpha::write"));
}

#[tokio::test]
async fn resource_lease_template_uses_causal_session_when_payload_omits_session_id() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"value": 1}),
            mutating_causal("lease-context-key").with_scope("alpha.write"),
        ))
        .await;

    assert_eq!(result.error, None);
    let host = handle.lock().await;
    let record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| record.function_id == fid("alpha::write"))
        .unwrap();
    let lease_id = record.resource_lease_ids[0].clone();
    drop(host);

    let lease = handle.get_resource_lease(&lease_id).await.unwrap().unwrap();
    assert_eq!(lease.resource_id, "session:session-a:write");
}

#[tokio::test]
async fn resource_lease_template_rejects_payload_session_that_conflicts_with_causal_context() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    handle
        .register_function_for_setup(
            write_function("alpha::write", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:write",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "test writes are manually compensated",
                )),
            Some(handler()),
            false,
        )
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::write",
            json!({"sessionId": "session-b", "value": 1}),
            mutating_causal("lease-context-conflict-key").with_scope("alpha.write"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message))
            if message.contains("payload field sessionId does not match invocation context")
    ));
}

#[tokio::test]
async fn host_resource_lease_conflict_fails_before_handler_execution() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    handle
        .register_function_for_setup(
            write_function("alpha::locked", "alpha")
                .with_risk(RiskLevel::High)
                .with_required_authority(
                    AuthorityRequirement::scope("alpha.write").with_approval_required(),
                )
                .with_resource_lease(ResourceLeaseRequirement::exclusive_template(
                    "session",
                    "session:{sessionId}:locked",
                    30_000,
                ))
                .with_compensation(CompensationContract::new(
                    CompensationKind::ManualOnly,
                    "lease conflict should be auditable",
                )),
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();
    let held = handle
        .acquire_resource_lease(lease_request("session", "session:session-a:locked", 30_000))
        .await
        .unwrap();

    let result = handle
        .invoke(host_invocation(
            "alpha::locked",
            json!({"sessionId": "session-a"}),
            mutating_causal("locked-key").with_scope("alpha.write"),
        ))
        .await;

    assert!(matches!(
        result.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("resource lease conflict")
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let compensation = handle.list_compensation_records().await.unwrap();
    assert_eq!(compensation.len(), 1);
    assert!(!compensation[0].succeeded);
    let _ = handle.release_resource_lease(&held.lease_id).await.unwrap();
}

#[tokio::test]
async fn enqueue_trigger_returns_receipt_and_queue_drain_preserves_causality() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("alpha", "alpha"), false)
        .unwrap();
    let mut trigger_type = TriggerTypeDefinition::new(
        TriggerTypeId::new("manual").unwrap(),
        wid("alpha"),
        "manual",
    );
    trigger_type.allowed_delivery_modes = vec![DeliveryMode::Sync, DeliveryMode::Enqueue];
    handle
        .register_trigger_type_for_setup(trigger_type, false)
        .unwrap();
    handle
        .register_function_for_setup(
            read_function("alpha::queued", "alpha")
                .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Enqueue])
                .with_required_authority(AuthorityRequirement::scope("queue.test")),
            Some(handler()),
            false,
        )
        .unwrap();
    let trigger_id = TriggerId::new("manual:alpha.queued").unwrap();
    handle
        .register_trigger_for_setup(
            TriggerDefinition::new(
                trigger_id.clone(),
                wid("alpha"),
                TriggerTypeId::new("manual").unwrap(),
                fid("alpha::queued"),
                grant("manual-grant"),
            )
            .with_delivery_mode(DeliveryMode::Enqueue),
            false,
        )
        .unwrap();

    let mut request = TriggerDispatchRequest::new(
        trigger_id.clone(),
        json!({"queued": true}),
        actor("agent"),
        ActorKind::Agent,
    );
    request.delivery_mode = Some(DeliveryMode::Enqueue);
    request.authority_scopes = vec!["queue.test".to_owned()];
    request.trace_id = Some(trace("queued-trace"));
    request.session_id = Some("session-a".to_owned());
    request.idempotency_key = Some("queue-target-key".to_owned());
    let queued = EngineTriggerRuntime::dispatch(&handle, request).await;
    assert_eq!(queued.error, None);
    let receipt = queued.value.as_ref().unwrap()["receiptId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(queued.value.as_ref().unwrap()["queued"], true);

    let drained = EngineQueueDrainer::drain_once(&handle, "default", "worker-a")
        .await
        .unwrap()
        .expect("queued item should drain");
    assert_eq!(drained.error, None);
    assert_eq!(
        drained.value.as_ref().unwrap()["echo"],
        json!({"queued": true})
    );

    let host = handle.lock().await;
    let target_record = host
        .catalog()
        .invocations()
        .iter()
        .rev()
        .find(|record| record.function_id == fid("alpha::queued"))
        .expect("queued target invocation should be recorded");
    assert_eq!(target_record.trigger_id, Some(trigger_id));
    assert_eq!(target_record.trace_id, trace("queued-trace"));
    assert_eq!(target_record.delivery_mode, DeliveryMode::Sync);
    assert_eq!(
        target_record.idempotency_key.as_deref(),
        Some("queue-target-key")
    );
    assert!(host.catalog().invocations().iter().any(|record| {
        record.result_value.as_ref().is_some_and(|value| {
            value.get("receiptId").and_then(Value::as_str) == Some(receipt.as_str())
        })
    }));
}

#[tokio::test]
async fn sqlite_primitive_stores_persist_stream_state_and_queue_records() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();

    let state_set = handle
        .invoke(host_invocation(
            "state::set",
            json!({
                "scope": "system",
                "namespace": "agent",
                "key": "boot",
                "value": {"ready": true}
            }),
            mutating_causal("sqlite-state-set").with_scope("state.write"),
        ))
        .await;
    assert_eq!(state_set.error, None);
    handle
        .subscribe_stream(
            "sqlite-sub".to_owned(),
            "catalog.changes".to_owned(),
            StreamCursor(0),
            VisibilityScope::System,
            None,
            None,
        )
        .await
        .unwrap();
    handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "catalog.changes".to_owned(),
            payload: json!({"subject": "alpha::one"}),
            visibility: VisibilityScope::System,
            session_id: None,
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("sqlite-stream-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();
    let queued = handle
        .invoke(host_invocation(
            "queue::enqueue",
            json!({
                "queue": "durable",
                "functionId": "state::get",
                "payload": {"scope": "system", "namespace": "agent", "key": "boot"}
            }),
            mutating_causal("sqlite-queue-enqueue").with_scope("queue.write"),
        ))
        .await;
    assert_eq!(queued.error, None);
    let receipt = queued.value.as_ref().unwrap()["item"]["receiptId"]
        .as_str()
        .unwrap()
        .to_owned();
    let approval = handle
        .invoke(host_invocation(
            "approval::request",
            json!({
                "functionId": "state::set",
                "payload": {"scope": "system", "namespace": "agent", "key": "boot", "value": {"ready": false}}
            }),
            mutating_causal("sqlite-approval").with_scope("approval.request"),
        ))
        .await;
    assert_eq!(approval.error, None);
    let approval_id = approval.value.as_ref().unwrap()["approval"]["approvalId"]
        .as_str()
        .unwrap()
        .to_owned();
    drop(handle);

    let reopened = EngineHostHandle::open_sqlite(&path).unwrap();
    let state_get = reopened
        .invoke(host_invocation(
            "state::get",
            json!({"scope": "system", "namespace": "agent", "key": "boot"}),
            causal().with_scope("state.read"),
        ))
        .await;
    assert_eq!(state_get.error, None);
    assert_eq!(
        state_get.value.as_ref().unwrap()["entry"]["value"],
        json!({"ready": true})
    );
    let stream_page = reopened
        .poll_stream(
            "sqlite-sub",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::admin(),
        )
        .await
        .unwrap();
    assert_eq!(stream_page.events.len(), 1);
    assert_eq!(
        stream_page.events[0].payload,
        json!({"subject": "alpha::one"})
    );
    let queue_get = reopened
        .invoke(host_invocation(
            "queue::get",
            json!({"receiptId": receipt}),
            causal().with_scope("queue.read"),
        ))
        .await;
    assert_eq!(queue_get.error, None);
    assert_eq!(
        queue_get.value.as_ref().unwrap()["item"]["queue"],
        "durable"
    );
    let approval_get = reopened
        .invoke(host_invocation(
            "approval::get",
            json!({"approvalId": approval_id}),
            causal()
                .with_scope("approval.read")
                .with_session_id("session-a")
                .with_workspace_id("workspace-a"),
        ))
        .await;
    assert_eq!(approval_get.error, None);
    assert_eq!(
        approval_get.value.as_ref().unwrap()["approval"]["status"],
        "pending"
    );
}

#[test]
fn external_worker_protocol_roundtrips_local_session_default_messages() {
    let worker = WorkerDefinition::new(
        wid("local-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("local");
    let hello =
        super::WorkerProtocolMessage::Hello(Box::new(super::WorkerHello::loopback(worker.clone())));
    let function = FunctionDefinition::new(
        fid("local::echo"),
        wid("local-worker"),
        "session-default external function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::system().with_session_id("session-a"));
    let register =
        super::WorkerProtocolMessage::RegisterFunction(Box::new(super::RegisterFunction {
            definition: external_visible_function(function),
            default_visibility: VisibilityScope::Session,
        }));
    if let super::WorkerProtocolMessage::RegisterFunction(message) = &register {
        assert_eq!(message.default_visibility, VisibilityScope::Session);
        assert_eq!(message.definition.visibility, VisibilityScope::Session);
    }
    let trigger = super::WorkerProtocolMessage::RegisterTrigger(super::RegisterTrigger {
        definition: TriggerDefinition::new(
            TriggerId::new("manual:local.echo").unwrap(),
            wid("local-worker"),
            TriggerTypeId::new("manual").unwrap(),
            fid("local::echo"),
            grant("external-grant"),
        ),
    });
    let invoke = super::WorkerProtocolMessage::Invoke(super::WorkerInvoke {
        invocation_id: super::InvocationId::generate(),
        function_id: fid("local::echo"),
        payload: json!({"hello": "worker"}),
        actor_kind: ActorKind::Agent,
        authority_grant_id: grant("agent-grant"),
        authority_scopes: vec!["local.read".to_owned()],
        trace_id: trace("worker-trace"),
        parent_invocation_id: None,
        trigger_id: Some(TriggerId::new("manual:local.echo").unwrap()),
        expected_function_revision: None,
        idempotency_key: None,
        session_id: Some("session-a".to_owned()),
        workspace_id: None,
        timeout_ms: 30_000,
    });
    for message in [hello, register, trigger, invoke] {
        let json = serde_json::to_string(&message).unwrap();
        let decoded: super::WorkerProtocolMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, message);
    }
}

#[tokio::test]
async fn agent_high_risk_invocation_creates_pending_approval_and_stream_event() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let function = FunctionDefinition::new(
        fid("danger::delete"),
        wid("danger"),
        "approval-gated delete",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test delete is manually compensated",
    ));
    handle
        .register_function_for_setup(function, Some(handler()), false)
        .unwrap();
    handle
        .subscribe_stream(
            "approval-test".to_owned(),
            "approvals".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();

    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let result = client
        .invoke(
            fid("danger::delete"),
            json!({"id": "target"}),
            Some("approval-key".to_owned()),
            None,
        )
        .await;
    let Some(EngineError::DomainFailure { code, details, .. }) = result.error else {
        panic!("expected approval domain failure, got {:?}", result.error);
    };
    assert_eq!(code, "APPROVAL_REQUIRED");
    let approval_id = details.unwrap()["approvalId"].as_str().unwrap().to_owned();
    let record = handle.get_approval(&approval_id).await.unwrap().unwrap();
    assert_eq!(record.status, ApprovalStatus::Pending);
    assert_eq!(record.function_id, fid("danger::delete"));
    assert_eq!(record.session_id.as_deref(), Some("session-a"));

    let page = handle
        .poll_stream(
            "approval-test",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    assert_eq!(page.events.len(), 1);
    assert_eq!(page.events[0].payload["type"], "approval.pending");
    assert_eq!(
        page.events[0].payload["approval"]["approvalId"],
        approval_id
    );

    let trace = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": record.trace_id.as_str()}),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("system-grant"),
                trace("approval-observe"),
            )
            .with_scope("observability.read"),
        ))
        .await;
    assert_eq!(trace.error, None);
    let invocations = trace.value.as_ref().unwrap()["invocations"]
        .as_array()
        .unwrap();
    assert!(invocations.iter().any(|invocation| {
        invocation["functionId"] == "danger::delete"
            && invocation["succeeded"] == false
            && invocation["error"]["message"]
                .as_str()
                .is_some_and(|message| message.contains("APPROVAL_REQUIRED"))
    }));
}

#[tokio::test]
async fn approval_request_function_publishes_once_and_replays_by_idempotency() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .subscribe_stream(
            "approval-request-test".to_owned(),
            "approvals".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();
    let context = mutating_causal("approval-request-key").with_scope("approval.request");
    let payload = json!({
        "functionId": "danger::delete",
        "payload": {"id": "target"}
    });

    let created = handle
        .invoke(host_invocation(
            "approval::request",
            payload.clone(),
            context.clone(),
        ))
        .await;
    assert_eq!(created.error, None);
    let approval_id = created.value.as_ref().unwrap()["approval"]["approvalId"]
        .as_str()
        .unwrap()
        .to_owned();
    let replayed = handle
        .invoke(host_invocation("approval::request", payload, context))
        .await;
    assert_eq!(replayed.error, None);
    assert_eq!(replayed.replayed_from, Some(created.invocation_id));
    assert_eq!(
        replayed.value.as_ref().unwrap()["approval"]["approvalId"],
        approval_id
    );

    let page = handle
        .poll_stream(
            "approval-request-test",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-a".to_owned()), None),
        )
        .await
        .unwrap();
    assert_eq!(page.events.len(), 1);
    assert_eq!(page.events[0].payload["type"], "approval.pending");
    assert_eq!(
        page.events[0].payload["approval"]["approvalId"],
        approval_id
    );
}

#[tokio::test]
async fn approval_resolution_rejects_agent_even_with_resolve_scope() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let request_context = mutating_causal("approval-agent-deny-key").with_scope("approval.request");
    let created = handle
        .invoke(host_invocation(
            "approval::request",
            json!({
                "functionId": "danger::write",
                "payload": {"value": 1}
            }),
            request_context,
        ))
        .await;
    assert_eq!(created.error, None);
    let approval_id = created.value.as_ref().unwrap()["approval"]["approvalId"]
        .as_str()
        .unwrap()
        .to_owned();

    let agent_resolve_context = CausalContext::new(
        actor("agent"),
        ActorKind::Agent,
        grant("approval-agent"),
        trace("approval-agent-trace"),
    )
    .with_scope("approval.resolve")
    .with_idempotency_key("approval-agent-resolve-key");
    let rejected = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": approval_id, "decision": "approve"}),
            agent_resolve_context,
        ))
        .await;
    let Some(EngineError::PolicyViolation(message)) = rejected.error else {
        panic!("expected policy violation, got {:?}", rejected.error);
    };
    assert!(message.contains("admin, system, or user-authorized actor"));
    let record = handle.get_approval(&approval_id).await.unwrap().unwrap();
    assert_eq!(record.status, ApprovalStatus::Pending);
}

#[tokio::test]
async fn agent_capability_client_hides_all_approval_primitives_without_new_approval() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["approval.resolve"])
        .with_session_id("session-a");
    let visible_approval_functions = client
        .discover(FunctionQuery {
            namespace_prefix: Some("approval".to_owned()),
            ..FunctionQuery::default()
        })
        .await;
    assert!(
        visible_approval_functions.is_empty(),
        "approval primitives are client-owned and must not be visible to agent discovery"
    );
    assert!(client.inspect(&fid("approval::get")).await.is_err());
    assert!(client.inspect(&fid("approval::list")).await.is_err());
    assert!(client.inspect(&fid("approval::resolve")).await.is_err());

    let rejected = client
        .invoke(
            fid("approval::resolve"),
            json!({"approvalId": "approval-a", "decision": "approve"}),
            Some("agent-approval-resolve-key".to_owned()),
            None,
        )
        .await;

    let Some(EngineError::PolicyViolation(message)) = rejected.error else {
        panic!("expected policy violation, got {:?}", rejected.error);
    };
    assert!(message.contains("user/client approval flow"));
    let approvals = handle.list_approvals(None, None, 100).await.unwrap();
    assert!(approvals.is_empty());
}

#[tokio::test]
async fn agent_approval_preflight_rejects_invalid_payload_before_request() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::delete"),
        wid("danger"),
        "approval-gated delete",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval preflight test delete is manually compensated",
    ))
    .with_request_schema(json!({
        "type": "object",
        "required": ["id"],
        "additionalProperties": false,
        "properties": {"id": {"type": "string"}}
    }));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();

    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let rejected = client
        .invoke(
            fid("danger::delete"),
            json!({}),
            Some("invalid-approval-key".to_owned()),
            None,
        )
        .await;

    assert!(matches!(
        rejected.error,
        Some(EngineError::SchemaViolation { .. })
    ));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let approvals = handle.list_approvals(None, None, 100).await.unwrap();
    assert!(approvals.is_empty());
}

#[tokio::test]
async fn approval_resolution_resumes_original_invocation_with_original_causality() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::write"),
        wid("danger"),
        "approval-gated write",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test write is manually compensated",
    ));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();
    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let pending = client
        .invoke(
            fid("danger::write"),
            json!({"value": 1}),
            Some("approval-run-key".to_owned()),
            None,
        )
        .await;
    let approval_id = match pending.error.unwrap() {
        EngineError::DomainFailure { details, .. } => {
            details.unwrap()["approvalId"].as_str().unwrap().to_owned()
        }
        other => panic!("unexpected error {other:?}"),
    };

    let resolve_context = CausalContext::new(
        actor("admin"),
        ActorKind::Admin,
        grant("approval-admin"),
        trace("approval-trace"),
    )
    .with_scope("approval.resolve")
    .with_idempotency_key("resolve-key");
    let resolved = handle
        .invoke(host_invocation(
            "approval::resolve",
            json!({"approvalId": approval_id, "decision": "approve"}),
            resolve_context,
        ))
        .await;
    assert_eq!(resolved.error, None);
    assert_eq!(
        resolved.value.as_ref().unwrap()["approval"]["status"],
        "executed"
    );
    assert_eq!(
        resolved.value.as_ref().unwrap()["child"]["value"]["call"],
        1
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn engine_invoke_routes_approval_resolve_through_host_resume_path() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_worker_for_setup(worker("danger", "danger"), false)
        .unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let function = FunctionDefinition::new(
        fid("danger::write"),
        wid("danger"),
        "approval-gated write",
        VisibilityScope::Agent,
        EffectClass::IrreversibleSideEffect,
    )
    .with_required_authority(AuthorityRequirement::scope("danger.write").with_approval_required())
    .with_risk(RiskLevel::High)
    .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
    .with_compensation(CompensationContract::new(
        CompensationKind::ManualOnly,
        "approval test write is manually compensated",
    ));
    handle
        .register_function_for_setup(
            function,
            Some(Arc::new(CountingHandler {
                calls: Arc::clone(&calls),
            })),
            false,
        )
        .unwrap();

    let client = AgentCapabilityClient::new(handle.clone(), actor("agent"), grant("agent-grant"))
        .with_scopes(["danger.write"])
        .with_session_id("session-a");
    let pending = client
        .invoke(
            fid("danger::write"),
            json!({"value": 1}),
            Some("approval-engine-invoke-child-key".to_owned()),
            None,
        )
        .await;
    let approval_id = match pending.error.unwrap() {
        EngineError::DomainFailure { details, .. } => {
            details.unwrap()["approvalId"].as_str().unwrap().to_owned()
        }
        other => panic!("unexpected error {other:?}"),
    };

    let resolved = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "approval::resolve",
                "payload": {"approvalId": approval_id, "decision": "approve"},
                "idempotencyKey": "transport-approval-resolve-key"
            }),
            CausalContext::new(
                actor("engine-user"),
                ActorKind::User,
                grant("engine-transport"),
                trace("transport-approval-trace"),
            )
            .with_scope("approval.resolve")
            .with_session_id("session-a"),
        ))
        .await;

    assert_eq!(resolved.error, None);
    assert_eq!(
        resolved.value.as_ref().unwrap()["child"]["value"]["approval"]["status"],
        "executed"
    );
    assert_eq!(
        resolved.value.as_ref().unwrap()["child"]["value"]["child"]["value"]["call"],
        1
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn local_external_worker_runtime_registers_session_functions_and_disconnects_cleanly() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    handle
        .register_trigger_type_for_setup(
            TriggerTypeDefinition::new(
                TriggerTypeId::new("manual").unwrap(),
                wid("engine"),
                "manual test trigger",
            ),
            false,
        )
        .unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker = WorkerDefinition::new(
        wid("local-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("local");
    let snapshot = runtime
        .hello(super::WorkerHello::loopback(worker))
        .await
        .unwrap();
    assert_eq!(runtime.connections(), vec![wid("local-worker")]);
    assert!(
        snapshot
            .functions
            .iter()
            .all(|function| function.id.namespace() != "rpc")
    );

    let function = FunctionDefinition::new(
        fid("local::echo"),
        wid("local-worker"),
        "session-default external function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::system().with_session_id("session-a"));
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(function),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    assert!(
        handle
            .inspect_function(
                &fid("local::echo"),
                Some(
                    &ActorContext::new(actor("agent"), ActorKind::Agent, grant("agent-grant"))
                        .with_session_id("session-a"),
                ),
            )
            .await
            .is_ok()
    );

    runtime
        .disconnect(super::WorkerDisconnect {
            worker_id: wid("local-worker"),
            reason: "test complete".to_owned(),
        })
        .await
        .unwrap();
    assert!(matches!(
        handle.inspect_function(&fid("local::echo"), None).await,
        Err(EngineError::NotFound { .. })
    ));
}

#[tokio::test]
async fn local_external_worker_rejects_visible_functions_without_capability_metadata() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker_id = wid("local-invalid-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("invalid_local");
    runtime
        .hello(super::WorkerHello::loopback(worker))
        .await
        .unwrap();
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: FunctionDefinition::new(
                fid("invalid_local::echo"),
                worker_id,
                "invalid external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            ),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("requires request and response schemas")
    ));
}

#[tokio::test]
async fn local_external_worker_rejects_metadata_outside_scoped_token() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker_id = wid("local-token-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("token_local");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.worker_token.plugin_id = "session_generated.allowed-plugin".to_owned();
    runtime.hello(hello).await.unwrap();
    let error = runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("token_local::echo"),
                worker_id,
                "token bounded external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message)
            if message.contains("does not match scoped token plugin")
    ));
}

#[tokio::test]
async fn local_external_worker_lifecycle_events_publish_through_streams_and_traces() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let subscribe = handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "worker-lifecycle-sub",
                "topic": "worker.lifecycle",
                "sessionId": "session-a"
            }),
            mutating_causal("worker-lifecycle-subscribe").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(subscribe.error, None);

    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-lifecycle-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("lifecycle_local");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.session_id = Some("session-a".to_owned());
    runtime.hello(hello).await.unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(
                FunctionDefinition::new(
                    fid("lifecycle_local::echo"),
                    worker_id.clone(),
                    "lifecycle external function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(Provenance::system().with_session_id("session-a")),
            ),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    runtime
        .disconnect(super::WorkerDisconnect {
            worker_id: worker_id.clone(),
            reason: "test complete".to_owned(),
        })
        .await
        .unwrap();

    let poll = handle
        .invoke(host_invocation(
            "stream::poll",
            json!({"subscriptionId": "worker-lifecycle-sub", "limit": 10}),
            causal()
                .with_scope("stream.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(poll.error, None);
    let events = poll.value.as_ref().unwrap()["events"].as_array().unwrap();
    let event_types = events
        .iter()
        .map(|event| event["payload"]["eventType"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        event_types,
        vec![
            "worker.connected",
            "worker.function_registered",
            "worker.disconnected",
            "worker.unregistered",
        ]
    );
    let trace_id = events[0]["payload"]["traceId"].as_str().unwrap();
    let trace = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": trace_id}),
            causal().with_scope("observability.read"),
        ))
        .await;
    assert_eq!(trace.error, None);
    assert!(
        trace.value.as_ref().unwrap()["streams"]
            .as_array()
            .unwrap()
            .iter()
            .any(|stream| stream["topic"] == "worker.lifecycle")
    );
}

struct EchoExternalInvoker;

#[async_trait]
impl super::external::ExternalWorkerInvoker for EchoExternalInvoker {
    async fn invoke(&self, invoke: super::WorkerInvoke) -> Result<super::WorkerInvocationResult> {
        Ok(super::WorkerInvocationResult {
            invocation_id: invoke.invocation_id,
            result: Some(json!({
                "functionId": invoke.function_id,
                "payload": invoke.payload,
                "traceId": invoke.trace_id,
            })),
            error: None,
        })
    }
}

#[tokio::test]
async fn local_external_worker_runtime_registers_executable_proxy_handler() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-exec-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("local_exec");
    runtime
        .hello(super::WorkerHello::loopback(worker))
        .await
        .unwrap();
    runtime
        .attach_invoker(worker_id.clone(), Arc::new(EchoExternalInvoker))
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(
                FunctionDefinition::new(
                    fid("local_exec::echo"),
                    worker_id,
                    "executable external function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(Provenance::system().with_session_id("session-a")),
            ),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();

    let result = handle
        .invoke(Invocation::new_sync(
            fid("local_exec::echo"),
            json!({"hello": "worker"}),
            causal()
                .with_scope("local_exec.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(result.error, None);
    assert_eq!(
        result.value.as_ref().unwrap()["payload"],
        json!({"hello": "worker"})
    );
}

#[tokio::test]
async fn local_external_worker_hello_rejects_identity_mismatch() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle);
    let worker = WorkerDefinition::new(
        wid("local-identity-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("identity_local");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.identity.worker_id = wid("different-worker");

    let error = runtime.hello(hello).await.unwrap_err();
    assert!(matches!(
        error,
        EngineError::PolicyViolation(message) if message.contains("does not match definition")
    ));
}

#[tokio::test]
async fn local_external_worker_durable_disconnect_marks_functions_unhealthy() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-durable-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("durable_local");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.registration_mode = super::WorkerRegistrationMode::Durable;
    hello.session_id = Some("session-a".to_owned());
    runtime.hello(hello).await.unwrap();
    runtime
        .attach_invoker(worker_id.clone(), Arc::new(EchoExternalInvoker))
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(FunctionDefinition::new(
                fid("durable_local::echo"),
                worker_id.clone(),
                "durable external function",
                VisibilityScope::Session,
                EffectClass::PureRead,
            )),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();

    runtime
        .disconnect(super::WorkerDisconnect {
            worker_id: worker_id.clone(),
            reason: "connection closed".to_owned(),
        })
        .await
        .unwrap();

    let admin = ActorContext::new(actor("admin"), ActorKind::System, grant("admin-grant"));
    let function = handle
        .inspect_function(&fid("durable_local::echo"), Some(&admin))
        .await
        .unwrap();
    assert_eq!(function.health, FunctionHealth::Unhealthy);
    assert_eq!(
        handle.inspect_worker(&worker_id).await.unwrap().lifecycle,
        super::WorkerLifecycleState::Stopped
    );
    let result = handle
        .invoke(Invocation::new_sync(
            fid("durable_local::echo"),
            json!({}),
            causal()
                .with_scope("durable_local.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::NotRoutable { .. })
    ));
}

#[tokio::test]
async fn local_external_worker_publish_stream_routes_through_stream_primitive() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let subscribe = handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "worker-sub-a",
                "topic": "worker.events",
                "sessionId": "session-a"
            }),
            mutating_causal("worker-stream-subscribe").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(subscribe.error, None);

    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-stream-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("stream_local");
    let mut hello = super::WorkerHello::loopback(worker);
    hello.session_id = Some("session-a".to_owned());
    runtime.hello(hello).await.unwrap();
    let response = runtime
        .handle_message(super::WorkerProtocolMessage::PublishStream(
            super::WorkerStreamPublish {
                worker_id: worker_id.clone(),
                topic: "worker.events".to_owned(),
                payload: json!({"from": "worker"}),
                visibility: VisibilityScope::Session,
                session_id: Some("session-a".to_owned()),
                workspace_id: None,
                trace_id: Some(trace("worker-stream-trace")),
                parent_invocation_id: Some(InvocationId::generate()),
                idempotency_key: "worker-stream-event-1".to_owned(),
            },
        ))
        .await
        .unwrap();
    assert!(matches!(
        response,
        Some(super::WorkerProtocolMessage::CatalogChange(change))
            if change.kind == "stream_published" && change.owner_worker == worker_id
    ));

    let poll = handle
        .invoke(host_invocation(
            "stream::poll",
            json!({"subscriptionId": "worker-sub-a", "limit": 10}),
            causal()
                .with_scope("stream.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(poll.error, None);
    let events = poll.value.as_ref().unwrap()["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["payload"], json!({"from": "worker"}));
    assert_eq!(events[0]["producer"], "local-stream-worker");
}

#[tokio::test]
async fn local_external_worker_heartbeat_timeout_unregisters_volatile_capabilities() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let mut runtime = EngineExternalWorkerRuntime::new(handle.clone());
    let worker_id = wid("local-timeout-worker");
    let worker = WorkerDefinition::new(
        worker_id.clone(),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("timeout_local");
    runtime
        .hello(super::WorkerHello::loopback(worker))
        .await
        .unwrap();
    runtime
        .register_function(super::RegisterFunction {
            definition: external_visible_function(
                FunctionDefinition::new(
                    fid("timeout_local::echo"),
                    worker_id.clone(),
                    "timeout external function",
                    VisibilityScope::Session,
                    EffectClass::PureRead,
                )
                .with_provenance(Provenance::system().with_session_id("session-a")),
            ),
            default_visibility: VisibilityScope::Session,
        })
        .await
        .unwrap();
    runtime
        .set_last_heartbeat_for_test(
            &worker_id,
            chrono::Utc::now() - chrono::Duration::seconds(120),
        )
        .unwrap();

    let expired = runtime
        .disconnect_timed_out(std::time::Duration::from_secs(30))
        .await
        .unwrap();
    assert_eq!(expired, vec![worker_id]);
    assert!(runtime.connections().is_empty());
    assert!(matches!(
        handle
            .inspect_function(&fid("timeout_local::echo"), None)
            .await,
        Err(EngineError::NotFound { .. })
    ));
}
