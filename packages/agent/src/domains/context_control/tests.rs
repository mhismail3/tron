use std::sync::Arc;

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    RuntimeCompactionInput, action_inspect_value, action_list_value, clear_value_at,
    record_runtime_compaction_action, snapshot_value_at, ui_action_list_value, ui_compact_value_at,
    ui_snapshot_value_at,
};
use super::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_ACTION_SCHEMA_ID, CONTEXT_CONTROL_EPOCH_KIND,
    CONTEXT_CONTROL_SNAPSHOT_KIND, CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID, Deps,
};
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationId, RiskLevel, TraceId, builtin_resource_type_definitions,
};
use crate::shared::server::test_support::make_test_context;

const DEFAULT_OPERATION_AT: &str = "2026-06-30T12:00:00Z";

struct Fixture {
    deps: Deps,
    session_id: String,
    write_grant_id: AuthorityGrantId,
    read_grant_id: AuthorityGrantId,
}

impl Fixture {
    async fn new(label: &str) -> Self {
        let ctx = make_test_context();
        let deps = Deps {
            engine_host: ctx.engine_host.clone(),
            event_store: ctx.event_store.clone(),
            session_manager: ctx.session_manager.clone(),
        };
        let session_id = deps
            .session_manager
            .create_session(
                "context-control-test-model",
                "/tmp/context-control",
                Some(label),
            )
            .expect("create context-control test session");
        deps.event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::MessageUser,
                payload: json!({
                    "content": "Please inspect the context composition without exposing raw prompt bodies.",
                }),
                parent_id: None,
                sequence: None,
            })
            .expect("seed context-control test message");
        let selectors = [
            "kind:context_control_snapshot".to_owned(),
            "kind:context_control_action".to_owned(),
            "kind:context_control_epoch".to_owned(),
            format!("session:{session_id}"),
        ];
        let write_grant_id = derive_grant(
            &deps,
            &format!("{label}-write"),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &[
                CONTEXT_CONTROL_SNAPSHOT_KIND,
                CONTEXT_CONTROL_ACTION_KIND,
                CONTEXT_CONTROL_EPOCH_KIND,
            ],
            &selectors.iter().map(String::as_str).collect::<Vec<_>>(),
        )
        .await;
        let read_grant_id = derive_grant(
            &deps,
            &format!("{label}-read"),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &[
                CONTEXT_CONTROL_SNAPSHOT_KIND,
                CONTEXT_CONTROL_ACTION_KIND,
                CONTEXT_CONTROL_EPOCH_KIND,
            ],
            &selectors.iter().map(String::as_str).collect::<Vec<_>>(),
        )
        .await;
        Self {
            deps,
            session_id,
            write_grant_id,
            read_grant_id,
        }
    }

    fn write_invocation(&self, key: &str, operation: &str, payload: Value) -> Invocation {
        invocation(
            key,
            operation,
            payload,
            self.write_grant_id.clone(),
            &[
                READ_SCOPE,
                WRITE_SCOPE,
                RESOURCE_READ_SCOPE,
                RESOURCE_WRITE_SCOPE,
            ],
            &self.session_id,
        )
    }

    fn read_invocation(&self, key: &str, operation: &str, payload: Value) -> Invocation {
        invocation(
            key,
            operation,
            payload,
            self.read_grant_id.clone(),
            &[READ_SCOPE, RESOURCE_READ_SCOPE],
            &self.session_id,
        )
    }
}

#[test]
fn context_control_resource_types_are_registered_with_metadata_only_bounds() {
    let definitions = builtin_resource_type_definitions();
    for (kind, schema_id) in [
        (
            CONTEXT_CONTROL_SNAPSHOT_KIND,
            CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID,
        ),
        (
            CONTEXT_CONTROL_ACTION_KIND,
            CONTEXT_CONTROL_ACTION_SCHEMA_ID,
        ),
    ] {
        let definition = definitions
            .iter()
            .find(|definition| definition.kind == kind)
            .expect("context-control definition");
        assert_eq!(definition.schema_id, schema_id);
        assert_eq!(
            definition.required_capabilities["read"],
            json!([READ_SCOPE, RESOURCE_READ_SCOPE])
        );
        assert_eq!(
            definition.required_capabilities["write"],
            json!([WRITE_SCOPE, RESOURCE_WRITE_SCOPE])
        );
        assert_eq!(
            definition.materialization_rules["networkPolicy"],
            json!("none")
        );
        assert_eq!(
            definition.materialization_rules["providerSafeProjectionRequired"],
            json!(true)
        );
    }
}

#[tokio::test]
async fn snapshot_records_provider_safe_composition_and_replays_same_idempotency_key() {
    let fixture = Fixture::new("context-control-snapshot").await;
    let payload = json!({
        "operation": "context_control_snapshot",
        "sessionId": fixture.session_id,
        "idempotencyKey": "snapshot-1"
    });
    let invocation =
        fixture.write_invocation("snapshot-1", "context_control_snapshot", payload.clone());
    let first = snapshot_value_at(&fixture.deps, &invocation, &payload, operation_at())
        .await
        .expect("snapshot");
    let replay = snapshot_value_at(&fixture.deps, &invocation, &payload, operation_at())
        .await
        .expect("snapshot replay");

    assert_eq!(first["operation"], json!("context_control_snapshot"));
    assert_eq!(first["idempotentReplay"], json!(false));
    assert_eq!(replay["idempotentReplay"], json!(true));
    assert_eq!(
        first["contextControlSnapshotResourceId"],
        replay["contextControlSnapshotResourceId"]
    );
    let projection = &first["projection"]["snapshot"];
    assert_eq!(projection["proof"]["providerSafe"], json!(true));
    assert_eq!(
        projection["composition"]["promptBlocks"][0]["bodyExcluded"],
        json!(true)
    );
    let rendered = serde_json::to_string(&first).expect("serialize snapshot");
    for forbidden in [
        "\"systemPrompt\"",
        "\"authorityGrantId\"",
        "sk-",
        "/Users/",
        "chain of thought",
        "rawCommandsStored",
    ] {
        assert!(
            !rendered.contains(forbidden),
            "snapshot leaked forbidden material {forbidden}: {rendered}"
        );
    }
}

#[tokio::test]
async fn clear_creates_durable_action_epoch_and_provider_safe_action_projection() {
    let fixture = Fixture::new("context-control-clear").await;
    let payload = json!({
        "operation": "context_control_clear",
        "sessionId": fixture.session_id,
        "reason": "Start a fresh context epoch for stress testing",
        "idempotencyKey": "clear-1"
    });
    let clear_invocation =
        fixture.write_invocation("clear-1", "context_control_clear", payload.clone());
    let cleared = clear_value_at(&fixture.deps, &clear_invocation, &payload, operation_at())
        .await
        .expect("clear context");
    assert_eq!(cleared["operation"], json!("context_control_clear"));
    assert_eq!(cleared["projection"]["action"]["kind"], json!("clear"));
    assert_eq!(
        cleared["projection"]["result"]["priorTurnsExcludedFromProviderContext"],
        json!(true)
    );
    assert_eq!(
        cleared["projection"]["result"]["historyStillInspectable"],
        json!(true)
    );

    let action_id = cleared["contextControlActionResourceId"]
        .as_str()
        .expect("action id");
    let exact_read_selectors = [
        "kind:context_control_snapshot".to_owned(),
        "kind:context_control_action".to_owned(),
        "kind:context_control_epoch".to_owned(),
        format!("session:{}", fixture.session_id),
        format!("resource:{action_id}"),
    ];
    let exact_read_grant = derive_grant(
        &fixture.deps,
        "clear-exact-read",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[
            CONTEXT_CONTROL_SNAPSHOT_KIND,
            CONTEXT_CONTROL_ACTION_KIND,
            CONTEXT_CONTROL_EPOCH_KIND,
        ],
        &exact_read_selectors
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
    )
    .await;
    let inspect_payload = json!({
        "operation": "context_control_action_inspect",
        "sessionId": fixture.session_id,
        "contextControlActionResourceId": action_id
    });
    let read_invocation = invocation(
        "clear-inspect",
        "context_control_action_inspect",
        inspect_payload.clone(),
        exact_read_grant,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &fixture.session_id,
    );
    let inspected = action_inspect_value(&fixture.deps, &read_invocation, &inspect_payload)
        .await
        .expect("inspect action");
    assert_eq!(
        inspected["projection"]["action"]["resource"]["resourceId"],
        json!(action_id)
    );
    assert_eq!(
        inspected["projection"]["proof"]["rawGrantIdsExcluded"],
        json!(true)
    );

    let list_payload = json!({
        "operation": "context_control_action_list",
        "sessionId": fixture.session_id,
        "limit": 5
    });
    let list_invocation = fixture.read_invocation(
        "clear-list",
        "context_control_action_list",
        list_payload.clone(),
    );
    let listed = action_list_value(&fixture.deps, &list_invocation, &list_payload)
        .await
        .expect("list actions");
    assert_eq!(
        listed["projection"]["actions"][0]["resource"]["resourceId"],
        json!(action_id)
    );
}

#[tokio::test]
async fn runtime_compaction_records_action_refs_on_durable_boundary() {
    let fixture = Fixture::new("context-control-runtime-compact").await;
    let persister = Arc::new(EventPersister::new(Arc::clone(&fixture.deps.event_store)));
    record_runtime_compaction_action(
        &fixture.deps,
        RuntimeCompactionInput {
            session_id: &fixture.session_id,
            reason: "threshold_exceeded",
            summary: "Earlier context was compacted into bounded metadata.",
            tokens_before: 10_000,
            tokens_after: 1_200,
            compression_ratio: 0.12,
            persister: &persister,
            sequence_counter: None,
            operation_at: operation_at(),
        },
    )
    .await
    .expect("record runtime compaction action");

    let events = fixture
        .deps
        .event_store
        .get_latest_events(&fixture.session_id, Some(10))
        .expect("latest events");
    let boundary = events
        .iter()
        .find(|event| event.event_type == "compact.boundary")
        .expect("compact boundary event");
    let payload: Value = serde_json::from_str(&boundary.payload).expect("boundary payload json");
    assert_eq!(payload["originalTokens"], json!(10_000));
    assert_eq!(payload["compactedTokens"], json!(1_200));
    let action_id = payload["contextControlActionResourceId"]
        .as_str()
        .expect("context control action id");
    assert!(
        payload["contextControlSnapshotResourceId"]
            .as_str()
            .is_some_and(|value| value.starts_with("context_control_snapshot:"))
    );

    let action = fixture
        .deps
        .engine_host
        .inspect_resource(action_id)
        .await
        .expect("inspect action resource")
        .expect("action resource exists");
    let current = action
        .resource
        .current_version_id
        .as_deref()
        .expect("current action version");
    let payload = action
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .expect("current action payload")
        .payload
        .clone();
    assert_eq!(payload["action"]["actorKind"], json!("system"));
    assert_eq!(
        payload["result"]["timelineEvent"]["eventId"],
        json!(boundary.id)
    );
    assert_eq!(
        payload["preflight"]["policyProof"]["networkPolicy"],
        json!("none")
    );
}

#[tokio::test]
async fn session_briefing_ui_wrappers_accept_first_party_client_context() {
    let fixture = Fixture::new("context-control-ui-wrapper").await;
    let snapshot_payload = json!({
        "sessionId": fixture.session_id,
        "idempotencyKey": "ui-snapshot-1"
    });
    let client_snapshot = client_invocation(
        "ui-snapshot-1",
        "context_control::ui_snapshot",
        snapshot_payload.clone(),
        &fixture.session_id,
    );
    let snapshot = ui_snapshot_value_at(
        &fixture.deps,
        &client_snapshot,
        &snapshot_payload,
        operation_at(),
    )
    .await
    .expect("ui snapshot");
    assert_eq!(snapshot["operation"], json!("context_control_snapshot"));
    assert_eq!(
        snapshot["projection"]["snapshot"]["proof"]["providerSafe"],
        json!(true)
    );

    let compact_payload = json!({
        "sessionId": fixture.session_id,
        "reason": "Manual Session Briefing compact from iOS",
        "idempotencyKey": "ui-compact-1"
    });
    let client_compact = client_invocation(
        "ui-compact-1",
        "context_control::ui_compact",
        compact_payload.clone(),
        &fixture.session_id,
    );
    let compact = ui_compact_value_at(
        &fixture.deps,
        &client_compact,
        &compact_payload,
        operation_at(),
    )
    .await
    .expect("ui compact");
    assert_eq!(compact["operation"], json!("context_control_compact"));
    assert_eq!(
        compact["projection"]["action"]["actorKind"],
        json!("system")
    );
    assert_eq!(
        compact["projection"]["proof"]["rawGrantIdsExcluded"],
        json!(true)
    );

    let list_payload = json!({
        "sessionId": fixture.session_id,
        "limit": 5
    });
    let client_list = client_invocation(
        "ui-list-1",
        "context_control::ui_action_list",
        list_payload.clone(),
        &fixture.session_id,
    );
    let list = ui_action_list_value(&fixture.deps, &client_list, &list_payload)
        .await
        .expect("ui action list");
    assert_eq!(list["operation"], json!("context_control_action_list"));
    assert_eq!(
        list["projection"]["actions"][0]["resource"]["resourceId"],
        compact["contextControlActionResourceId"]
    );
}

#[tokio::test]
async fn missing_session_selector_denies_provider_context_control_access() {
    let fixture = Fixture::new("context-control-selector").await;
    let bad_grant = derive_grant(
        &fixture.deps,
        "missing-session-selector",
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &[
            CONTEXT_CONTROL_SNAPSHOT_KIND,
            CONTEXT_CONTROL_ACTION_KIND,
            CONTEXT_CONTROL_EPOCH_KIND,
        ],
        &[
            "kind:context_control_snapshot",
            "kind:context_control_action",
            "kind:context_control_epoch",
        ],
    )
    .await;
    let payload = json!({
        "operation": "context_control_action_list",
        "sessionId": fixture.session_id,
        "limit": 1
    });
    let invocation = invocation(
        "selector-denied",
        "context_control_action_list",
        payload.clone(),
        bad_grant,
        &[READ_SCOPE, RESOURCE_READ_SCOPE],
        &fixture.session_id,
    );
    let error = action_list_value(&fixture.deps, &invocation, &payload)
        .await
        .expect_err("missing session selector must deny access");
    assert!(
        error.to_string().contains(&format!(
            "requires exact session:{} selector",
            fixture.session_id
        )),
        "{error}"
    );
}

async fn derive_grant(
    deps: &Deps,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
) -> AuthorityGrantId {
    let grant = deps
        .engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("context-control-{suffix}")).unwrap()),
            parent_grant_id: AuthorityGrantId::new("engine-system").unwrap(),
            subject_actor_id: None,
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec!["capability::execute".to_owned()],
            allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
            allowed_authority_scopes: scopes.iter().map(|scope| (*scope).to_owned()).collect(),
            allowed_resource_kinds: resource_kinds
                .iter()
                .map(|kind| (*kind).to_owned())
                .collect(),
            resource_selectors: selectors
                .iter()
                .map(|selector| (*selector).to_owned())
                .collect(),
            file_roots: vec!["/tmp".to_owned()],
            network_policy: "none".to_owned(),
            max_risk: RiskLevel::Medium,
            budget: json!({"class": "context_control_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "context_control_test"}),
            trace_id: TraceId::new(format!("trace-context-control-{suffix}")).unwrap(),
        })
        .await
        .expect("derive grant");
    grant.grant_id
}

fn invocation(
    key: &str,
    operation: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    scopes: &[&str],
    session_id: &str,
) -> Invocation {
    let mut context = CausalContext::new(
        ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::Agent,
        grant_id,
        TraceId::new(format!("trace-{key}")).unwrap(),
    )
    .with_workspace_id("workspace-context-control")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(key.to_owned());
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    let mut payload = payload;
    payload["operation"] = json!(operation);
    Invocation {
        id: InvocationId::new(format!("invocation-{key}")).unwrap(),
        function_id: FunctionId::new("capability::execute").unwrap(),
        payload,
        causal_context: context,
        delivery_mode: crate::engine::DeliveryMode::Sync,
    }
}

fn client_invocation(key: &str, function_id: &str, payload: Value, session_id: &str) -> Invocation {
    Invocation {
        id: InvocationId::new(format!("client-invocation-{key}")).unwrap(),
        function_id: FunctionId::new(function_id).unwrap(),
        payload,
        causal_context: CausalContext::new(
            ActorId::new("engine-client").unwrap(),
            ActorKind::Client,
            AuthorityGrantId::new("engine-transport").unwrap(),
            TraceId::new(format!("trace-client-{key}")).unwrap(),
        )
        .with_session_id(session_id.to_owned()),
        delivery_mode: crate::engine::DeliveryMode::Sync,
    }
}

fn operation_at() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(DEFAULT_OPERATION_AT)
        .unwrap()
        .with_timezone(&Utc)
}
