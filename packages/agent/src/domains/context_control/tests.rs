use std::sync::Arc;

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::contract::{READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WRITE_SCOPE};
use super::service::{
    RuntimeCompactionInput, action_inspect_value, action_list_value, clear_value_at,
    exclusion_list_value, exclusion_record_value_at, policy_snapshot_value_at,
    record_runtime_compaction_action, snapshot_value_at, survivor_disable_value_at,
    survivor_list_value, survivor_record_value_at, ui_action_list_value, ui_compact_value_at,
    ui_snapshot_value_at,
};
use super::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_ACTION_SCHEMA_ID, CONTEXT_CONTROL_EPOCH_KIND,
    CONTEXT_CONTROL_EPOCH_SCHEMA_ID, CONTEXT_CONTROL_SNAPSHOT_KIND,
    CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID, CONTEXT_EXCLUSION_KIND, CONTEXT_EXCLUSION_SCHEMA_ID,
    CONTEXT_POLICY_SNAPSHOT_KIND, CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID, CONTEXT_SURVIVOR_KIND,
    CONTEXT_SURVIVOR_SCHEMA_ID, Deps,
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
            "kind:context_survivor".to_owned(),
            "kind:context_exclusion".to_owned(),
            "kind:context_policy_snapshot".to_owned(),
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
                CONTEXT_SURVIVOR_KIND,
                CONTEXT_EXCLUSION_KIND,
                CONTEXT_POLICY_SNAPSHOT_KIND,
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
                CONTEXT_SURVIVOR_KIND,
                CONTEXT_EXCLUSION_KIND,
                CONTEXT_POLICY_SNAPSHOT_KIND,
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
        (CONTEXT_CONTROL_EPOCH_KIND, CONTEXT_CONTROL_EPOCH_SCHEMA_ID),
        (CONTEXT_SURVIVOR_KIND, CONTEXT_SURVIVOR_SCHEMA_ID),
        (CONTEXT_EXCLUSION_KIND, CONTEXT_EXCLUSION_SCHEMA_ID),
        (
            CONTEXT_POLICY_SNAPSHOT_KIND,
            CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID,
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
        "kind:context_survivor".to_owned(),
        "kind:context_exclusion".to_owned(),
        "kind:context_policy_snapshot".to_owned(),
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
            CONTEXT_SURVIVOR_KIND,
            CONTEXT_EXCLUSION_KIND,
            CONTEXT_POLICY_SNAPSHOT_KIND,
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
async fn context_policy_records_list_disable_and_snapshot_with_exact_authority() {
    let fixture = Fixture::new("context-control-policy").await;
    let survivor_payload = json!({
        "operation": "context_survivor_record",
        "sessionId": fixture.session_id,
        "targetKind": "message",
        "targetRef": "message:decision-1",
        "label": "Keep project decision",
        "reason": "Must survive future compaction",
        "priority": 80,
        "idempotencyKey": "survivor-1"
    });
    let survivor_invocation = fixture.write_invocation(
        "survivor-1",
        "context_survivor_record",
        survivor_payload.clone(),
    );
    let survivor = survivor_record_value_at(
        &fixture.deps,
        &survivor_invocation,
        &survivor_payload,
        operation_at(),
    )
    .await
    .expect("record survivor");
    assert_eq!(survivor["operation"], json!("context_survivor_record"));
    assert_eq!(survivor["status"], json!("active"));
    assert_eq!(
        survivor["projection"]["policyRecord"]["futureProviderContextBinding"],
        json!("must_preserve_ref")
    );
    assert_eq!(
        survivor["projection"]["policyRecord"]["targetRef"],
        json!("message:decision-1")
    );
    assert_eq!(
        survivor["projection"]["target"]["providerSafeRefOnly"],
        json!(true)
    );
    assert_eq!(
        survivor["projection"]["proof"]["hiddenPromptBodiesExcluded"],
        json!(true)
    );

    let replay = survivor_record_value_at(
        &fixture.deps,
        &survivor_invocation,
        &survivor_payload,
        operation_at(),
    )
    .await
    .expect("survivor replay");
    assert_eq!(replay["idempotentReplay"], json!(true));
    assert_eq!(
        replay["contextPolicyResourceId"],
        survivor["contextPolicyResourceId"]
    );

    let exclusion_payload = json!({
        "operation": "context_exclusion_record",
        "sessionId": fixture.session_id,
        "targetKind": "message",
        "targetRef": "message:obsolete-1",
        "label": "Drop outdated branch notes",
        "reason": "Outdated state must not survive future context",
        "priority": 60,
        "idempotencyKey": "exclusion-1"
    });
    let exclusion_invocation = fixture.write_invocation(
        "exclusion-1",
        "context_exclusion_record",
        exclusion_payload.clone(),
    );
    let exclusion = exclusion_record_value_at(
        &fixture.deps,
        &exclusion_invocation,
        &exclusion_payload,
        operation_at(),
    )
    .await
    .expect("record exclusion");
    assert_eq!(
        exclusion["projection"]["policyRecord"]["futureProviderContextBinding"],
        json!("must_omit_ref")
    );

    let list_payload = json!({
        "operation": "context_survivor_list",
        "sessionId": fixture.session_id,
        "limit": 10
    });
    let list_invocation = fixture.read_invocation(
        "survivor-list-1",
        "context_survivor_list",
        list_payload.clone(),
    );
    let list = survivor_list_value(&fixture.deps, &list_invocation, &list_payload)
        .await
        .expect("list survivor");
    assert_eq!(list["projection"]["records"].as_array().unwrap().len(), 1);
    assert_eq!(
        list["projection"]["records"][0]["targetRef"],
        json!("message:decision-1")
    );

    let snapshot_payload = json!({
        "operation": "context_policy_snapshot",
        "sessionId": fixture.session_id,
        "idempotencyKey": "policy-snapshot-1"
    });
    let snapshot_invocation = fixture.write_invocation(
        "policy-snapshot-1",
        "context_policy_snapshot",
        snapshot_payload.clone(),
    );
    let snapshot = policy_snapshot_value_at(
        &fixture.deps,
        &snapshot_invocation,
        &snapshot_payload,
        operation_at(),
    )
    .await
    .expect("policy snapshot");
    assert_eq!(snapshot["status"], json!("available"));
    assert_eq!(
        snapshot["projection"]["policySnapshot"]["policy"]["survivorCount"],
        json!(1)
    );
    assert_eq!(
        snapshot["projection"]["policySnapshot"]["policy"]["exclusionCount"],
        json!(1)
    );
    assert_eq!(
        snapshot["projection"]["policySnapshot"]["survivorRefs"][0]["targetRef"],
        json!("message:decision-1")
    );
    assert_eq!(
        snapshot["projection"]["policySnapshot"]["exclusionRefs"][0]["targetRef"],
        json!("message:obsolete-1")
    );

    let survivor_id = survivor["contextPolicyResourceId"].as_str().unwrap();
    let disable_payload = json!({
        "operation": "context_survivor_disable",
        "sessionId": fixture.session_id,
        "contextSurvivorResourceId": survivor_id,
        "reason": "No longer needed",
        "idempotencyKey": "disable-survivor-1"
    });
    let denied = survivor_disable_value_at(
        &fixture.deps,
        &fixture.write_invocation(
            "disable-survivor-denied",
            "context_survivor_disable",
            disable_payload.clone(),
        ),
        &disable_payload,
        operation_at(),
    )
    .await
    .expect_err("disable without exact resource selector denied");
    assert!(
        denied
            .to_string()
            .contains(&format!("requires exact resource:{survivor_id} selector")),
        "{denied}"
    );

    let exact_selectors = [
        "kind:context_control_snapshot".to_owned(),
        "kind:context_control_action".to_owned(),
        "kind:context_control_epoch".to_owned(),
        "kind:context_survivor".to_owned(),
        "kind:context_exclusion".to_owned(),
        "kind:context_policy_snapshot".to_owned(),
        format!("session:{}", fixture.session_id),
        format!("resource:{survivor_id}"),
    ];
    let exact_grant = derive_grant(
        &fixture.deps,
        "survivor-disable-exact",
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
            CONTEXT_SURVIVOR_KIND,
            CONTEXT_EXCLUSION_KIND,
            CONTEXT_POLICY_SNAPSHOT_KIND,
        ],
        &exact_selectors
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
    )
    .await;
    let disable_invocation = invocation(
        "disable-survivor-1",
        "context_survivor_disable",
        disable_payload.clone(),
        exact_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let disabled = survivor_disable_value_at(
        &fixture.deps,
        &disable_invocation,
        &disable_payload,
        operation_at(),
    )
    .await
    .expect("disable survivor");
    assert_eq!(disabled["status"], json!("disabled"));
    assert_eq!(
        disabled["projection"]["policyRecord"]["state"],
        json!("disabled")
    );

    let list_after_disable = survivor_list_value(&fixture.deps, &list_invocation, &list_payload)
        .await
        .expect("list survivor after disable");
    assert_eq!(
        list_after_disable["projection"]["records"]
            .as_array()
            .unwrap()
            .len(),
        0
    );

    let exclusion_list_payload = json!({
        "operation": "context_exclusion_list",
        "sessionId": fixture.session_id,
        "limit": 10
    });
    let exclusion_list_invocation = fixture.read_invocation(
        "exclusion-list-1",
        "context_exclusion_list",
        exclusion_list_payload.clone(),
    );
    let exclusion_list = exclusion_list_value(
        &fixture.deps,
        &exclusion_list_invocation,
        &exclusion_list_payload,
    )
    .await
    .expect("list exclusion");
    assert_eq!(
        exclusion_list["projection"]["records"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        exclusion_list["projection"]["records"][0]["targetRef"],
        json!("message:obsolete-1")
    );
}

#[tokio::test]
async fn context_policy_record_rejects_raw_local_paths() {
    let fixture = Fixture::new("context-control-policy-unsafe").await;
    let payload = json!({
        "operation": "context_survivor_record",
        "sessionId": fixture.session_id,
        "targetKind": "message",
        "targetRef": "/home/local-user/secret-notes.txt",
        "label": "Unsafe raw path",
        "reason": "This must fail",
        "idempotencyKey": "survivor-unsafe"
    });
    let invocation = fixture.write_invocation(
        "survivor-unsafe",
        "context_survivor_record",
        payload.clone(),
    );
    let error = survivor_record_value_at(&fixture.deps, &invocation, &payload, operation_at())
        .await
        .expect_err("raw local path rejected");
    assert!(
        error
            .to_string()
            .contains("bounded provider-safe non-wildcard ref"),
        "{error}"
    );
}

#[tokio::test]
async fn context_policy_records_require_safe_refs_and_reason() {
    let fixture = Fixture::new("context-control-policy-contract").await;
    let base = json!({
        "operation": "context_survivor_record",
        "sessionId": fixture.session_id,
        "targetKind": "message",
        "targetRef": "message:decision-1",
        "label": "Keep decision",
        "reason": "Must survive compaction",
        "idempotencyKey": "survivor-safe-contract"
    });

    let mut missing_reason = base.clone();
    missing_reason.as_object_mut().unwrap().remove("reason");
    let missing_reason_invocation = fixture.write_invocation(
        "survivor-missing-reason",
        "context_survivor_record",
        missing_reason.clone(),
    );
    let error = survivor_record_value_at(
        &fixture.deps,
        &missing_reason_invocation,
        &missing_reason,
        operation_at(),
    )
    .await
    .expect_err("policy reason is required");
    assert!(error.to_string().contains("reason is required"), "{error}");

    for (field, value, key) in [
        ("targetKind", "*", "bad-kind-wildcard"),
        ("targetRef", "resource:*", "bad-ref-wildcard"),
        ("targetRef", "/etc/passwd", "bad-ref-path"),
        ("targetRef", "grantId=abc123", "bad-ref-grant"),
        ("targetRef", "command:git_status", "bad-ref-command"),
    ] {
        let mut payload = base.clone();
        payload[field] = json!(value);
        payload["idempotencyKey"] = json!(key);
        let invocation = fixture.write_invocation(key, "context_survivor_record", payload.clone());
        let error = survivor_record_value_at(&fixture.deps, &invocation, &payload, operation_at())
            .await
            .expect_err("unsafe policy ref rejected");
        assert!(
            error.to_string().contains("provider-safe")
                || error
                    .to_string()
                    .contains("supported provider-safe context ref kind"),
            "{field}={value} should be rejected, got {error}"
        );
    }
}

#[tokio::test]
async fn context_policy_snapshot_rejects_overflow_instead_of_truncating() {
    let fixture = Fixture::new("context-control-policy-overflow").await;
    for index in 0..51 {
        let payload = json!({
            "operation": "context_survivor_record",
            "sessionId": fixture.session_id,
            "targetKind": "message",
            "targetRef": format!("message:decision-{index}"),
            "label": format!("Keep decision {index}"),
            "reason": "Must survive compaction",
            "idempotencyKey": format!("survivor-overflow-{index}")
        });
        let invocation = fixture.write_invocation(
            &format!("survivor-overflow-{index}"),
            "context_survivor_record",
            payload.clone(),
        );
        survivor_record_value_at(&fixture.deps, &invocation, &payload, operation_at())
            .await
            .expect("record survivor");
    }

    let snapshot_payload = json!({
        "operation": "context_policy_snapshot",
        "sessionId": fixture.session_id,
        "idempotencyKey": "policy-snapshot-overflow"
    });
    let snapshot_invocation = fixture.write_invocation(
        "policy-snapshot-overflow",
        "context_policy_snapshot",
        snapshot_payload.clone(),
    );
    let error = policy_snapshot_value_at(
        &fixture.deps,
        &snapshot_invocation,
        &snapshot_payload,
        operation_at(),
    )
    .await
    .expect_err("overflow snapshot must fail closed");
    assert!(
        error.to_string().contains("more than 50 active records"),
        "{error}"
    );
}

#[tokio::test]
async fn context_policy_list_rejects_limit_truncation() {
    let fixture = Fixture::new("context-control-policy-list-overflow").await;
    for index in 0..21 {
        let payload = json!({
            "operation": "context_survivor_record",
            "sessionId": fixture.session_id,
            "targetKind": "message",
            "targetRef": format!("message:list-decision-{index}"),
            "label": format!("Keep list decision {index}"),
            "reason": "Must survive compaction",
            "idempotencyKey": format!("survivor-list-overflow-{index}")
        });
        let invocation = fixture.write_invocation(
            &format!("survivor-list-overflow-{index}"),
            "context_survivor_record",
            payload.clone(),
        );
        survivor_record_value_at(&fixture.deps, &invocation, &payload, operation_at())
            .await
            .expect("record survivor");
    }

    let list_payload = json!({
        "operation": "context_survivor_list",
        "sessionId": fixture.session_id
    });
    let list_invocation = fixture.read_invocation(
        "survivor-list-overflow",
        "context_survivor_list",
        list_payload.clone(),
    );
    let error = survivor_list_value(&fixture.deps, &list_invocation, &list_payload)
        .await
        .expect_err("list must fail closed instead of truncating active policies");
    assert!(
        error.to_string().contains("exceeds requested limit 20"),
        "{error}"
    );
}

#[tokio::test]
async fn context_policy_disable_replay_requires_same_idempotency_key() {
    let fixture = Fixture::new("context-control-policy-disable-replay").await;
    let survivor_payload = json!({
        "operation": "context_survivor_record",
        "sessionId": fixture.session_id,
        "targetKind": "message",
        "targetRef": "message:decision-1",
        "label": "Keep project decision",
        "reason": "Must survive future compaction",
        "idempotencyKey": "survivor-disable-replay"
    });
    let survivor_invocation = fixture.write_invocation(
        "survivor-disable-replay",
        "context_survivor_record",
        survivor_payload.clone(),
    );
    let survivor = survivor_record_value_at(
        &fixture.deps,
        &survivor_invocation,
        &survivor_payload,
        operation_at(),
    )
    .await
    .expect("record survivor");
    let survivor_id = survivor["contextPolicyResourceId"].as_str().unwrap();
    let exact_selectors = [
        "kind:context_control_snapshot".to_owned(),
        "kind:context_control_action".to_owned(),
        "kind:context_control_epoch".to_owned(),
        "kind:context_survivor".to_owned(),
        "kind:context_exclusion".to_owned(),
        "kind:context_policy_snapshot".to_owned(),
        format!("session:{}", fixture.session_id),
        format!("resource:{survivor_id}"),
    ];
    let exact_grant = derive_grant(
        &fixture.deps,
        "survivor-disable-replay-exact",
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
            CONTEXT_SURVIVOR_KIND,
            CONTEXT_EXCLUSION_KIND,
            CONTEXT_POLICY_SNAPSHOT_KIND,
        ],
        &exact_selectors
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>(),
    )
    .await;
    let disable_payload = json!({
        "operation": "context_survivor_disable",
        "sessionId": fixture.session_id,
        "contextSurvivorResourceId": survivor_id,
        "reason": "No longer needed",
        "idempotencyKey": "disable-survivor-replay-1"
    });
    let disable_invocation = invocation(
        "disable-survivor-replay-1",
        "context_survivor_disable",
        disable_payload.clone(),
        exact_grant.clone(),
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    survivor_disable_value_at(
        &fixture.deps,
        &disable_invocation,
        &disable_payload,
        operation_at(),
    )
    .await
    .expect("disable survivor");

    let replay = survivor_disable_value_at(
        &fixture.deps,
        &disable_invocation,
        &disable_payload,
        operation_at(),
    )
    .await
    .expect("same-key disable replay");
    assert_eq!(replay["idempotentReplay"], json!(true));

    let stale_payload = json!({
        "operation": "context_survivor_disable",
        "sessionId": fixture.session_id,
        "contextSurvivorResourceId": survivor_id,
        "reason": "Different retry must not be masked",
        "idempotencyKey": "disable-survivor-replay-2"
    });
    let stale_invocation = invocation(
        "disable-survivor-replay-2",
        "context_survivor_disable",
        stale_payload.clone(),
        exact_grant,
        &[
            READ_SCOPE,
            WRITE_SCOPE,
            RESOURCE_READ_SCOPE,
            RESOURCE_WRITE_SCOPE,
        ],
        &fixture.session_id,
    );
    let error = survivor_disable_value_at(
        &fixture.deps,
        &stale_invocation,
        &stale_payload,
        operation_at(),
    )
    .await
    .expect_err("different-key disable cannot replay");
    assert!(
        error.to_string().contains("different idempotencyKey"),
        "{error}"
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
            CONTEXT_SURVIVOR_KIND,
            CONTEXT_EXCLUSION_KIND,
            CONTEXT_POLICY_SNAPSHOT_KIND,
        ],
        &[
            "kind:context_control_snapshot",
            "kind:context_control_action",
            "kind:context_control_epoch",
            "kind:context_survivor",
            "kind:context_exclusion",
            "kind:context_policy_snapshot",
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
