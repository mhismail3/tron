use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use async_trait::async_trait;
use serde_json::{Value, json};

use super::discovery::{ActorContext, ActorKind, FunctionQuery};
use super::errors::{EngineError, Result};
use super::ids::{
    ActorId, AuthorityGrantId, FunctionId, TraceId, TriggerId, TriggerTypeId, WorkerId,
};
use super::invocation::{CausalContext, InProcessFunctionHandler, Invocation};
use super::registry::LiveCatalog;
use super::types::{
    AuthorityRequirement, CatalogChangeKind, CatalogRevision, DeliveryMode, EffectClass,
    FunctionDefinition, FunctionHealth, FunctionRevision, IdempotencyContract,
    IdempotencyKeySource, LedgerKind, Provenance, ReplayBehavior, RiskLevel, TriggerDefinition,
    TriggerTypeDefinition, VisibilityScope, WorkerDefinition, WorkerKind,
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
