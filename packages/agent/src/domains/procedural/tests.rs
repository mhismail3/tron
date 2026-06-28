use serde_json::{Value, json};

use super::service::test_support::procedural_payload;
use super::service::{
    inspect_activation_decision_value, inspect_activation_request_value,
    inspect_procedural_state_value, list_activation_decisions_value,
    list_activation_requests_value, list_procedural_state_value,
    record_activation_decision_value_at, record_activation_request_value_at,
    record_procedural_definition_value_at,
};
use super::{
    ACTIVATION_DECISION_SCHEMA_VERSION, ACTIVATION_REQUEST_SCHEMA_VERSION,
    PROCEDURAL_ACTIVATION_DECISION_KIND, PROCEDURAL_ACTIVATION_REQUEST_KIND,
    PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID, SCHEMA_VERSION,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, CreateResource, DeliveryMode, DeriveGrant,
    EngineResourceScope, EngineResourceVersioningMode, FunctionId, Invocation, InvocationId,
    RegisterResourceType, RiskLevel, TraceId, WorkerId,
};

const WORKER: &str = "procedural";

fn fixed_procedural_recorded_at() -> chrono::DateTime<chrono::Utc> {
    chrono::DateTime::parse_from_rfc3339("2026-04-09T00:00:00Z")
        .expect("fixed procedural timestamp")
        .with_timezone(&chrono::Utc)
}

macro_rules! assert_denied_contains {
    ($future:expr, $needle:expr, $label:literal) => {{
        let error = $future.await.expect_err($label).to_string();
        assert!(error.contains($needle), "{error}");
    }};
}

#[tokio::test]
async fn procedural_list_and_inspect_return_bounded_redacted_evidence() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let session_id = "procedural-redaction-session";
    let workspace_id = "workspace-procedural-redaction";
    let grant = derived_procedural_read_grant(
        &handle,
        "redacted",
        &["procedural.read", "resource.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:skill"],
        "none",
    )
    .await;
    let long_summary = "a".repeat(700);
    create_procedural_record(
        &handle,
        "procedural_record:skill:redacted",
        EngineResourceScope::Session(session_id.to_owned()),
        procedural_payload("skill", &long_summary, "candidate"),
        "candidate",
    )
    .await;
    let list_invocation = procedural_read_invocation(
        "list-redacted",
        json!({
            "operation": "procedural_state_list",
            "proceduralKind": "skill",
            "limit": 10
        }),
        grant.clone(),
        session_id,
        workspace_id,
    );
    let listed = list_procedural_state_value(&handle, &list_invocation, &list_invocation.payload)
        .await
        .expect("list procedural records");
    assert_eq!(listed["records"].as_array().unwrap().len(), 1);
    assert_eq!(listed["records"][0]["summary"]["truncated"], json!(true));
    assert_eq!(listed["records"][0]["eval"]["status"], json!("passed"));
    let inspect_invocation = procedural_read_invocation(
        "inspect-redacted",
        json!({
            "operation": "procedural_state_inspect",
            "proceduralKind": "skill",
            "proceduralRecordResourceId": "procedural_record:skill:redacted",
            "maxEvidenceItems": 1
        }),
        grant,
        session_id,
        workspace_id,
    );
    let inspected =
        inspect_procedural_state_value(&handle, &inspect_invocation, &inspect_invocation.payload)
            .await
            .expect("inspect procedural record");
    assert_eq!(inspected["resource"]["proceduralKind"], "skill");
    assert_eq!(
        inspected["resource"]["provenance"]["authorityGrantId"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["provenance"]["nested"]["grant_id"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["eval"]["failure"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["traceRefs"]["items"][0]["grantId"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["replayRefs"]["items"][0]["authority_grant_id"]["redacted"],
        json!(true)
    );
    assert_eq!(
        inspected["resource"]["sourceRefs"]["truncated"],
        json!(false)
    );
    assert_eq!(inspected["activation"]["skillActivated"], json!(false));
    assert_eq!(inspected["activation"]["hookFired"], json!(false));
    assert_eq!(inspected["activation"]["promptInjected"], json!(false));
    assert_eq!(inspected["activation"]["autonomousExecution"], json!(false));
    let serialized = serde_json::to_string(&inspected).expect("serialize projection");
    for forbidden in [
        "grant-procedural-secret-123",
        "grant-procedural-nested-123",
        "grant-procedural-failure",
        "grant-procedural-trace",
        "grant-procedural-replay",
        "secret-token",
        "raw secret procedure body",
        "raw manifest",
        "run dangerous thing",
        "/Users/example/private/procedure.md",
        "/private/procedural/body.md",
        "/private/path",
    ] {
        assert!(
            !serialized.contains(forbidden),
            "projection leaked forbidden material {forbidden}: {serialized}"
        );
    }
    assert!(serialized.contains("reviewed"), "{serialized}");
}

#[tokio::test]
async fn procedural_list_filters_kind_scope_and_truncates() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let session_id = "procedural-filter-session";
    let workspace_id = "workspace-procedural-filter";
    let grant = derived_procedural_read_grant(
        &handle,
        "filters",
        &["procedural.read", "resource.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:rule"],
        "none",
    )
    .await;
    create_procedural_record(
        &handle,
        "procedural_record:rule:one",
        EngineResourceScope::Session(session_id.to_owned()),
        procedural_payload("rule", "first rule", "validated"),
        "validated",
    )
    .await;
    create_procedural_record(
        &handle,
        "procedural_record:rule:workspace",
        EngineResourceScope::Workspace(workspace_id.to_owned()),
        procedural_payload("rule", "workspace rule", "candidate"),
        "candidate",
    )
    .await;
    create_procedural_record(
        &handle,
        "procedural_record:skill:wrong-kind",
        EngineResourceScope::Session(session_id.to_owned()),
        procedural_payload("skill", "wrong kind", "candidate"),
        "candidate",
    )
    .await;
    create_procedural_record(
        &handle,
        "procedural_record:rule:other-session",
        EngineResourceScope::Session("other-procedural-session".to_owned()),
        procedural_payload("rule", "other session", "candidate"),
        "candidate",
    )
    .await;
    let invocation = procedural_read_invocation(
        "list-filtered",
        json!({
            "operation": "procedural_state_list",
            "proceduralKind": "rule",
            "limit": 1
        }),
        grant,
        session_id,
        workspace_id,
    );
    let listed = list_procedural_state_value(&handle, &invocation, &invocation.payload)
        .await
        .expect("filtered list");
    let records = listed["records"].as_array().unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0]["proceduralKind"], "rule");
    assert_eq!(listed["limits"]["truncated"], json!(true));
}

#[tokio::test]
async fn procedural_inspect_denies_missing_grants_wildcards_and_wrong_scope() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    create_procedural_record(
        &handle,
        "procedural_record:hook:auth",
        EngineResourceScope::Session("procedural-auth-session".to_owned()),
        procedural_payload("hook", "auth hook", "candidate"),
        "candidate",
    )
    .await;
    let payload = json!({
        "operation": "procedural_state_inspect",
        "proceduralKind": "hook",
        "proceduralRecordResourceId": "procedural_record:hook:auth"
    });
    let missing_scope_grant = derived_procedural_read_grant(
        &handle,
        "missing-scope",
        &["resource.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:hook"],
        "none",
    )
    .await;
    let missing_scope_invocation = procedural_read_invocation(
        "missing-scope",
        payload.clone(),
        missing_scope_grant,
        "procedural-auth-session",
        "workspace-procedural-auth",
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &missing_scope_invocation,
            &missing_scope_invocation.payload,
        ),
        "procedural.read",
        "missing read grant denied"
    );
    let wildcard_scope_grant = derived_procedural_read_grant(
        &handle,
        "wildcard-scope",
        &["*", "resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:hook"],
        "none",
    )
    .await;
    let wildcard_scope_invocation = procedural_read_invocation(
        "wildcard-scope",
        payload.clone(),
        wildcard_scope_grant,
        "procedural-auth-session",
        "workspace-procedural-auth",
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &wildcard_scope_invocation,
            &wildcard_scope_invocation.payload,
        ),
        "wildcard",
        "wildcard authority denied"
    );
    let wildcard_kind_grant = derived_procedural_read_grant(
        &handle,
        "wildcard-kind",
        &["resource.read", "procedural.read"],
        &["*"],
        &["kind:procedural_record", "proceduralKind:hook"],
        "none",
    )
    .await;
    let wildcard_kind_invocation = procedural_read_invocation(
        "wildcard-kind",
        payload.clone(),
        wildcard_kind_grant,
        "procedural-auth-session",
        "workspace-procedural-auth",
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &wildcard_kind_invocation,
            &wildcard_kind_invocation.payload,
        ),
        "wildcard",
        "wildcard resource kind denied"
    );
    let wildcard_selector_grant = derived_procedural_read_grant(
        &handle,
        "wildcard-selector",
        &["resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["*", "kind:procedural_record", "proceduralKind:hook"],
        "none",
    )
    .await;
    let wildcard_selector_invocation = procedural_read_invocation(
        "wildcard-selector",
        payload.clone(),
        wildcard_selector_grant,
        "procedural-auth-session",
        "workspace-procedural-auth",
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &wildcard_selector_invocation,
            &wildcard_selector_invocation.payload,
        ),
        "wildcard",
        "wildcard selector denied"
    );
    let missing_selector_grant = derived_procedural_read_grant(
        &handle,
        "missing-selector",
        &["resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record"],
        "none",
    )
    .await;
    let missing_selector_invocation = procedural_read_invocation(
        "missing-selector",
        payload.clone(),
        missing_selector_grant,
        "procedural-auth-session",
        "workspace-procedural-auth",
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &missing_selector_invocation,
            &missing_selector_invocation.payload,
        ),
        "proceduralKind:hook",
        "missing proceduralKind selector denied"
    );
    let wrong_network_grant = derived_procedural_read_grant(
        &handle,
        "network",
        &["resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:hook"],
        "declared",
    )
    .await;
    let wrong_network_invocation = procedural_read_invocation(
        "network",
        payload.clone(),
        wrong_network_grant,
        "procedural-auth-session",
        "workspace-procedural-auth",
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &wrong_network_invocation,
            &wrong_network_invocation.payload,
        ),
        "networkPolicy none",
        "network policy denied"
    );

    let read_grant = derived_procedural_read_grant(
        &handle,
        "wrong-scope",
        &["resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:hook"],
        "none",
    )
    .await;
    let wrong_session_invocation = procedural_read_invocation(
        "wrong-session",
        payload,
        read_grant,
        "other-procedural-session",
        "workspace-procedural-auth",
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &wrong_session_invocation,
            &wrong_session_invocation.payload,
        ),
        "outside the current session/workspace",
        "wrong session denied"
    );
}

#[tokio::test]
async fn procedural_inspect_denies_wrong_workspace_missing_context_and_bad_actor() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    create_procedural_record(
        &handle,
        "procedural_record:procedure:workspace",
        EngineResourceScope::Workspace("expected-workspace".to_owned()),
        procedural_payload("procedure", "workspace procedure", "validated"),
        "validated",
    )
    .await;
    let grant = derived_procedural_read_grant(
        &handle,
        "context",
        &["resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:procedure"],
        "none",
    )
    .await;
    let payload = json!({
        "operation": "procedural_state_inspect",
        "proceduralKind": "procedure",
        "proceduralRecordResourceId": "procedural_record:procedure:workspace"
    });
    let wrong_workspace = procedural_read_invocation(
        "wrong-workspace",
        payload.clone(),
        grant.clone(),
        "procedural-context-session",
        "wrong-workspace",
    );
    assert_denied_contains!(
        inspect_procedural_state_value(&handle, &wrong_workspace, &wrong_workspace.payload),
        "outside the current session/workspace",
        "wrong workspace denied"
    );

    let missing_workspace = procedural_invocation_with_context(
        "missing-workspace",
        payload.clone(),
        grant.clone(),
        Some("procedural-context-session"),
        None,
        ActorId::new("agent:procedural-context-session").unwrap(),
        ActorKind::Agent,
    );
    assert_denied_contains!(
        inspect_procedural_state_value(&handle, &missing_workspace, &missing_workspace.payload),
        "workspace context",
        "missing workspace denied"
    );

    let bad_actor = procedural_invocation_with_context(
        "bad-actor",
        payload,
        grant,
        Some("procedural-context-session"),
        Some("expected-workspace"),
        ActorId::new("agent:other-session").unwrap(),
        ActorKind::Agent,
    );
    assert_denied_contains!(
        inspect_procedural_state_value(&handle, &bad_actor, &bad_actor.payload),
        "actor",
        "bad actor denied"
    );
}

#[tokio::test]
async fn procedural_inspect_revalidates_stored_kind_schema_version_lifecycle_and_payload() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let session_id = "procedural-kind-schema-session";
    let workspace_id = "workspace-procedural-kind-schema";
    let grant = derived_procedural_read_grant(
        &handle,
        "kind-schema",
        &["resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:rule"],
        "none",
    )
    .await;

    handle
        .create_resource(CreateResource {
            resource_id: Some("procedural_record:wrong-kind".to_owned()),
            kind: "artifact".to_owned(),
            schema_id: None,
            scope: EngineResourceScope::Session(session_id.to_owned()),
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
            owner_actor_id: ActorId::new(format!("agent:{session_id}")).unwrap(),
            lifecycle: Some("draft".to_owned()),
            policy: json!({"owner": WORKER}),
            initial_payload: Some(json!({"title": "not procedural", "body": "x"})),
            locations: Vec::new(),
            trace_id: TraceId::new("trace-procedural-wrong-kind").unwrap(),
            invocation_id: None,
        })
        .await
        .expect("wrong kind resource");
    let wrong_kind_invocation = procedural_read_invocation(
        "wrong-kind",
        json!({
            "operation": "procedural_state_inspect",
            "proceduralKind": "rule",
            "proceduralRecordResourceId": "procedural_record:wrong-kind"
        }),
        grant.clone(),
        session_id,
        workspace_id,
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &wrong_kind_invocation,
            &wrong_kind_invocation.payload,
        ),
        "expected procedural_record",
        "stored kind revalidated"
    );

    handle
        .register_resource_type(RegisterResourceType {
            kind: PROCEDURAL_RECORD_KIND.to_owned(),
            schema_id: "tron.resource.procedural_record.test_mismatch.v1".to_owned(),
            schema: json!({
                "type": "object",
                "required": ["schemaVersion", "proceduralKind", "summary", "status"],
                "additionalProperties": true
            }),
            lifecycle_states: vec!["candidate".to_owned()],
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: Vec::new(),
            default_retention: json!({"class": "test"}),
            redaction_rules: json!({}),
            materialization_rules: json!({}),
            required_capabilities: json!({}),
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
        })
        .await
        .expect("override type for mismatch test");
    create_procedural_record(
        &handle,
        "procedural_record:schema-mismatch",
        EngineResourceScope::Session(session_id.to_owned()),
        procedural_payload("rule", "schema mismatch", "candidate"),
        "candidate",
    )
    .await;
    let schema_invocation = procedural_read_invocation(
        "schema-mismatch",
        json!({
            "operation": "procedural_state_inspect",
            "proceduralKind": "rule",
            "proceduralRecordResourceId": "procedural_record:schema-mismatch"
        }),
        grant.clone(),
        session_id,
        workspace_id,
    );
    assert_denied_contains!(
        inspect_procedural_state_value(&handle, &schema_invocation, &schema_invocation.payload),
        PROCEDURAL_RECORD_SCHEMA_ID,
        "stored schema revalidated"
    );

    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("fresh engine host");
    let grant = derived_procedural_read_grant(
        &handle,
        "payload",
        &["resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:rule"],
        "none",
    )
    .await;
    create_procedural_record(
        &handle,
        "procedural_record:payload-version",
        EngineResourceScope::Session(session_id.to_owned()),
        {
            let mut payload = procedural_payload("rule", "wrong schema version", "candidate");
            payload["schemaVersion"] = json!("tron.procedural_record.v0");
            payload
        },
        "candidate",
    )
    .await;
    let bad_version_invocation = procedural_read_invocation(
        "bad-version",
        json!({
            "operation": "procedural_state_inspect",
            "proceduralKind": "rule",
            "proceduralRecordResourceId": "procedural_record:payload-version"
        }),
        grant.clone(),
        session_id,
        workspace_id,
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &bad_version_invocation,
            &bad_version_invocation.payload,
        ),
        SCHEMA_VERSION,
        "payload schema version denied"
    );

    create_procedural_record(
        &handle,
        "procedural_record:stale",
        EngineResourceScope::Session(session_id.to_owned()),
        procedural_payload("rule", "stale rule", "stale"),
        "stale",
    )
    .await;
    let stale_invocation = procedural_read_invocation(
        "stale",
        json!({
            "operation": "procedural_state_inspect",
            "proceduralKind": "rule",
            "proceduralRecordResourceId": "procedural_record:stale"
        }),
        grant.clone(),
        session_id,
        workspace_id,
    );
    assert_denied_contains!(
        inspect_procedural_state_value(&handle, &stale_invocation, &stale_invocation.payload),
        "stale",
        "stale denied"
    );

    handle
        .register_resource_type(RegisterResourceType {
            kind: PROCEDURAL_RECORD_KIND.to_owned(),
            schema_id: PROCEDURAL_RECORD_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": ["schemaVersion", "proceduralKind", "summary", "status"],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "proceduralKind": {"type": "string"},
                    "summary": {"type": "string"},
                    "status": {"type": "string"}
                }
            }),
            lifecycle_states: vec!["candidate".to_owned()],
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: Vec::new(),
            default_retention: json!({"class": "test"}),
            redaction_rules: json!({}),
            materialization_rules: json!({}),
            required_capabilities: json!({}),
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
        })
        .await
        .expect("weaken procedural schema for malformed payload test");
    create_procedural_record(
        &handle,
        "procedural_record:malformed",
        EngineResourceScope::Session(session_id.to_owned()),
        json!({
            "schemaVersion": SCHEMA_VERSION,
            "proceduralKind": "rule",
            "summary": "missing fields",
            "status": "candidate"
        }),
        "candidate",
    )
    .await;
    let malformed_invocation = procedural_read_invocation(
        "malformed",
        json!({
            "operation": "procedural_state_inspect",
            "proceduralKind": "rule",
            "proceduralRecordResourceId": "procedural_record:malformed"
        }),
        grant,
        session_id,
        workspace_id,
    );
    assert_denied_contains!(
        inspect_procedural_state_value(
            &handle,
            &malformed_invocation,
            &malformed_invocation.payload,
        ),
        "missing identity",
        "malformed denied"
    );
}

#[tokio::test]
async fn procedural_definition_record_is_metadata_only_and_idempotent() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let session_id = "procedural-record-session";
    let workspace_id = "workspace-procedural-record";
    let grant = derived_procedural_read_grant(
        &handle,
        "definition-record",
        &[
            "resource.read",
            "resource.write",
            "procedural.read",
            "procedural.write",
        ],
        &[PROCEDURAL_RECORD_KIND],
        &["kind:procedural_record", "proceduralKind:skill"],
        "none",
    )
    .await;
    let invocation = procedural_read_invocation(
        "definition-record",
        json!({
            "operation": "procedural_definition_record",
            "proceduralKind": "skill",
            "definitionId": "skill.review.demo",
            "summary": "Metadata only procedural definition",
            "idempotencyKey": "skill-review-demo",
            "triggerDeclarations": [{"kind": "manual", "summary": "review gate"}],
            "conflictMetadata": {"strategy": "deny_on_conflict"},
            "orderingMetadata": {"priority": "normal"},
            "scopedAuthorityProof": {"networkPolicy": "none"}
        }),
        grant,
        session_id,
        workspace_id,
    );
    let recorded = record_procedural_definition_value_at(
        &handle,
        &invocation,
        &invocation.payload,
        fixed_procedural_recorded_at(),
    )
    .await
    .expect("record definition");
    assert_eq!(recorded["idempotentReplay"], json!(false));
    assert_eq!(recorded["activation"]["hookFired"], json!(false));
    let replayed = record_procedural_definition_value_at(
        &handle,
        &invocation,
        &invocation.payload,
        fixed_procedural_recorded_at(),
    )
    .await
    .expect("replay definition");
    assert_eq!(replayed["idempotentReplay"], json!(true));
    assert_eq!(
        replayed["proceduralRecordResourceId"],
        recorded["proceduralRecordResourceId"]
    );
    let rendered = serde_json::to_string(&recorded).expect("serialize recorded definition");
    for forbidden in ["secret", "grant-", "/Users/", "/private/", "execute"] {
        assert!(
            !rendered.contains(forbidden),
            "definition projection leaked {forbidden}: {rendered}"
        );
    }
}

#[tokio::test]
async fn procedural_activation_request_and_decision_are_review_metadata_only() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let session_id = "procedural-activation-session";
    let workspace_id = "workspace-procedural-activation";
    let procedural_record_id = "procedural_record:hook:activation";
    create_procedural_record(
        &handle,
        procedural_record_id,
        EngineResourceScope::Session(session_id.to_owned()),
        procedural_payload("hook", "activation hook", "candidate"),
        "candidate",
    )
    .await;

    let request_grant = derived_procedural_read_grant(
        &handle,
        "activation-request",
        &[
            "resource.read",
            "resource.write",
            "procedural.read",
            "procedural.write",
        ],
        &[PROCEDURAL_RECORD_KIND, PROCEDURAL_ACTIVATION_REQUEST_KIND],
        &[
            "kind:procedural_record",
            "kind:procedural_activation_request",
            "proceduralKind:hook",
            "resource:procedural_record:hook:activation",
        ],
        "none",
    )
    .await;
    let request_invocation = procedural_read_invocation(
        "activation-request",
        json!({
            "operation": "procedural_activation_request_record",
            "proceduralKind": "hook",
            "proceduralRecordResourceId": procedural_record_id,
            "activationRequestId": "hook-activation-request",
            "requestedAction": "activate",
            "idempotencyKey": "hook-activation-request",
            "validationEvidenceRefs": [{"resourceId": "validation:hook"}],
            "triggerDeclarations": [{"kind": "manual", "summary": "review gate"}],
            "rollbackProofRefs": [{"resourceId": "rollback:hook"}]
        }),
        request_grant.clone(),
        session_id,
        workspace_id,
    );
    let request = record_activation_request_value_at(
        &handle,
        &request_invocation,
        &request_invocation.payload,
        fixed_procedural_recorded_at(),
    )
    .await
    .expect("record activation request");
    let request_resource_id = request["proceduralActivationRequestResourceId"]
        .as_str()
        .expect("request resource id")
        .to_owned();
    assert_eq!(
        request["schemaVersion"],
        json!(ACTIVATION_REQUEST_SCHEMA_VERSION)
    );
    assert_eq!(request["activation"]["hookFired"], json!(false));

    let request_list_invocation = procedural_read_invocation(
        "activation-request-list",
        json!({
            "operation": "procedural_activation_request_list",
            "proceduralKind": "hook"
        }),
        request_grant.clone(),
        session_id,
        workspace_id,
    );
    let requests = list_activation_requests_value(
        &handle,
        &request_list_invocation,
        &request_list_invocation.payload,
    )
    .await
    .expect("list activation requests");
    assert_eq!(requests["activationRequests"].as_array().unwrap().len(), 1);

    let request_inspect_grant = derived_procedural_read_grant(
        &handle,
        "activation-request-inspect",
        &["resource.read", "procedural.read"],
        &[PROCEDURAL_RECORD_KIND, PROCEDURAL_ACTIVATION_REQUEST_KIND],
        &[
            "kind:procedural_record",
            "kind:procedural_activation_request",
            "proceduralKind:hook",
            &format!("resource:{request_resource_id}"),
        ],
        "none",
    )
    .await;
    let request_inspect_invocation = procedural_read_invocation(
        "activation-request-inspect",
        json!({
            "operation": "procedural_activation_request_inspect",
            "proceduralKind": "hook",
            "proceduralActivationRequestResourceId": request_resource_id
        }),
        request_inspect_grant,
        session_id,
        workspace_id,
    );
    let inspected_request = inspect_activation_request_value(
        &handle,
        &request_inspect_invocation,
        &request_inspect_invocation.payload,
    )
    .await
    .expect("inspect activation request");
    assert_eq!(
        inspected_request["proceduralActivationRequest"]["payload"]["safetyProof"]["activationPerformed"],
        json!(false)
    );

    let decision_grant = derived_procedural_read_grant(
        &handle,
        "activation-decision",
        &[
            "resource.read",
            "resource.write",
            "procedural.read",
            "procedural.write",
        ],
        &[
            PROCEDURAL_RECORD_KIND,
            PROCEDURAL_ACTIVATION_REQUEST_KIND,
            PROCEDURAL_ACTIVATION_DECISION_KIND,
        ],
        &[
            "kind:procedural_record",
            "kind:procedural_activation_request",
            "kind:procedural_activation_decision",
            "proceduralKind:hook",
            "resource:procedural_record:hook:activation",
            &format!("resource:{request_resource_id}"),
        ],
        "none",
    )
    .await;
    let decision_invocation = procedural_read_invocation(
        "activation-decision",
        json!({
            "operation": "procedural_activation_decision_record",
            "proceduralKind": "hook",
            "proceduralActivationRequestResourceId": request_resource_id,
            "activationDecisionId": "hook-activation-decision",
            "decision": "deny_activation",
            "reason": "Validation evidence is still pending",
            "idempotencyKey": "hook-activation-decision",
            "deactivationProofRefs": [{"resourceId": "deactivation:hook"}],
            "rollbackProofRefs": [{"resourceId": "rollback:hook"}]
        }),
        decision_grant.clone(),
        session_id,
        workspace_id,
    );
    let decision = record_activation_decision_value_at(
        &handle,
        &decision_invocation,
        &decision_invocation.payload,
        fixed_procedural_recorded_at(),
    )
    .await
    .expect("record activation decision");
    let decision_resource_id = decision["proceduralActivationDecisionResourceId"]
        .as_str()
        .expect("decision resource id")
        .to_owned();
    assert_eq!(
        decision["schemaVersion"],
        json!(ACTIVATION_DECISION_SCHEMA_VERSION)
    );
    assert_eq!(decision["activation"]["promptInjected"], json!(false));

    let decision_list_invocation = procedural_read_invocation(
        "activation-decision-list",
        json!({
            "operation": "procedural_activation_decision_list",
            "proceduralKind": "hook"
        }),
        decision_grant.clone(),
        session_id,
        workspace_id,
    );
    let decisions = list_activation_decisions_value(
        &handle,
        &decision_list_invocation,
        &decision_list_invocation.payload,
    )
    .await
    .expect("list activation decisions");
    assert_eq!(
        decisions["activationDecisions"].as_array().unwrap().len(),
        1
    );

    let decision_inspect_grant = derived_procedural_read_grant(
        &handle,
        "activation-decision-inspect",
        &["resource.read", "procedural.read"],
        &[
            PROCEDURAL_RECORD_KIND,
            PROCEDURAL_ACTIVATION_REQUEST_KIND,
            PROCEDURAL_ACTIVATION_DECISION_KIND,
        ],
        &[
            "kind:procedural_record",
            "kind:procedural_activation_request",
            "kind:procedural_activation_decision",
            "proceduralKind:hook",
            &format!("resource:{decision_resource_id}"),
        ],
        "none",
    )
    .await;
    let decision_inspect_invocation = procedural_read_invocation(
        "activation-decision-inspect",
        json!({
            "operation": "procedural_activation_decision_inspect",
            "proceduralKind": "hook",
            "proceduralActivationDecisionResourceId": decision_resource_id
        }),
        decision_inspect_grant,
        session_id,
        workspace_id,
    );
    let inspected_decision = inspect_activation_decision_value(
        &handle,
        &decision_inspect_invocation,
        &decision_inspect_invocation.payload,
    )
    .await
    .expect("inspect activation decision");
    assert_eq!(
        inspected_decision["proceduralActivationDecision"]["payload"]["activationResult"]["performed"],
        json!(false)
    );
    let rendered = serde_json::to_string(&inspected_decision).expect("serialize decision");
    for forbidden in ["grant-", "/Users/", "/private/", "secret-token"] {
        assert!(
            !rendered.contains(forbidden),
            "decision projection leaked {forbidden}: {rendered}"
        );
    }
}

#[tokio::test]
async fn procedural_activation_decision_must_match_requested_action() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let session_id = "procedural-action-binding-session";
    let workspace_id = "workspace-procedural-action-binding";
    let procedural_record_id = "procedural_record:hook:action-binding";
    let request_resource_id = create_activation_request_for_decision_test(
        &handle,
        "action-binding",
        "deactivate",
        procedural_record_id,
        session_id,
        workspace_id,
    )
    .await;
    let decision_grant = activation_decision_grant_for_request(
        &handle,
        "action-binding",
        &request_resource_id,
        procedural_record_id,
    )
    .await;
    let decision_invocation = procedural_read_invocation(
        "action-binding-decision",
        json!({
            "operation": "procedural_activation_decision_record",
            "proceduralKind": "hook",
            "proceduralActivationRequestResourceId": request_resource_id,
            "activationDecisionId": "action-binding-decision",
            "decision": "approve_rollback",
            "reason": "Rollback proof exists, but the request asked for deactivation.",
            "idempotencyKey": "action-binding-decision",
            "rollbackProofRefs": [{"resourceId": "rollback:action-binding"}]
        }),
        decision_grant,
        session_id,
        workspace_id,
    );

    assert_denied_contains!(
        record_activation_decision_value_at(
            &handle,
            &decision_invocation,
            &decision_invocation.payload,
            fixed_procedural_recorded_at(),
        ),
        "decision action rollback does not match activation request requestedAction deactivate",
        "mismatched decision action denied"
    );
}

#[tokio::test]
async fn rollback_and_deactivation_approvals_require_matching_proof_refs() {
    let handle = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let session_id = "procedural-proof-required-session";
    let workspace_id = "workspace-procedural-proof-required";

    let rollback_record_id = "procedural_record:hook:rollback-proof";
    let rollback_request_id = create_activation_request_for_decision_test(
        &handle,
        "rollback-proof",
        "rollback",
        rollback_record_id,
        session_id,
        workspace_id,
    )
    .await;
    let rollback_grant = activation_decision_grant_for_request(
        &handle,
        "rollback-proof",
        &rollback_request_id,
        rollback_record_id,
    )
    .await;
    let rollback_invocation = procedural_read_invocation(
        "rollback-proof-decision",
        json!({
            "operation": "procedural_activation_decision_record",
            "proceduralKind": "hook",
            "proceduralActivationRequestResourceId": rollback_request_id,
            "activationDecisionId": "rollback-proof-decision",
            "decision": "approve_rollback",
            "reason": "Rollback approval must carry rollback proof refs.",
            "idempotencyKey": "rollback-proof-decision"
        }),
        rollback_grant,
        session_id,
        workspace_id,
    );
    assert_denied_contains!(
        record_activation_decision_value_at(
            &handle,
            &rollback_invocation,
            &rollback_invocation.payload,
            fixed_procedural_recorded_at(),
        ),
        "rollbackProofRefs are required for approve_rollback",
        "rollback proof refs required"
    );

    let deactivation_record_id = "procedural_record:hook:deactivation-proof";
    let deactivation_request_id = create_activation_request_for_decision_test(
        &handle,
        "deactivation-proof",
        "deactivate",
        deactivation_record_id,
        session_id,
        workspace_id,
    )
    .await;
    let deactivation_grant = activation_decision_grant_for_request(
        &handle,
        "deactivation-proof",
        &deactivation_request_id,
        deactivation_record_id,
    )
    .await;
    let deactivation_invocation = procedural_read_invocation(
        "deactivation-proof-decision",
        json!({
            "operation": "procedural_activation_decision_record",
            "proceduralKind": "hook",
            "proceduralActivationRequestResourceId": deactivation_request_id,
            "activationDecisionId": "deactivation-proof-decision",
            "decision": "approve_deactivation",
            "reason": "Deactivation approval must carry deactivation proof refs.",
            "idempotencyKey": "deactivation-proof-decision",
            "deactivationProofRefs": []
        }),
        deactivation_grant,
        session_id,
        workspace_id,
    );
    assert_denied_contains!(
        record_activation_decision_value_at(
            &handle,
            &deactivation_invocation,
            &deactivation_invocation.payload,
            fixed_procedural_recorded_at(),
        ),
        "deactivationProofRefs are required for approve_deactivation",
        "deactivation proof refs required"
    );
}

async fn create_activation_request_for_decision_test(
    handle: &crate::engine::EngineHostHandle,
    suffix: &str,
    requested_action: &str,
    procedural_record_id: &str,
    session_id: &str,
    workspace_id: &str,
) -> String {
    create_procedural_record(
        handle,
        procedural_record_id,
        EngineResourceScope::Session(session_id.to_owned()),
        procedural_payload("hook", suffix, "candidate"),
        "candidate",
    )
    .await;

    let request_grant = derived_procedural_read_grant(
        handle,
        &format!("{suffix}-request"),
        &[
            "resource.read",
            "resource.write",
            "procedural.read",
            "procedural.write",
        ],
        &[PROCEDURAL_RECORD_KIND, PROCEDURAL_ACTIVATION_REQUEST_KIND],
        &[
            "kind:procedural_record",
            "kind:procedural_activation_request",
            "proceduralKind:hook",
            &format!("resource:{procedural_record_id}"),
        ],
        "none",
    )
    .await;
    let request_invocation = procedural_read_invocation(
        &format!("{suffix}-request"),
        json!({
            "operation": "procedural_activation_request_record",
            "proceduralKind": "hook",
            "proceduralRecordResourceId": procedural_record_id,
            "activationRequestId": format!("{suffix}-request"),
            "requestedAction": requested_action,
            "idempotencyKey": format!("{suffix}-request"),
            "validationEvidenceRefs": [{"resourceId": format!("validation:{suffix}")}],
            "triggerDeclarations": [{"kind": "manual", "summary": "review gate"}]
        }),
        request_grant,
        session_id,
        workspace_id,
    );
    let request = record_activation_request_value_at(
        handle,
        &request_invocation,
        &request_invocation.payload,
        fixed_procedural_recorded_at(),
    )
    .await
    .expect("record activation request fixture");
    request["proceduralActivationRequestResourceId"]
        .as_str()
        .expect("request resource id")
        .to_owned()
}

async fn activation_decision_grant_for_request(
    handle: &crate::engine::EngineHostHandle,
    suffix: &str,
    request_resource_id: &str,
    procedural_record_id: &str,
) -> AuthorityGrantId {
    derived_procedural_read_grant(
        handle,
        &format!("{suffix}-decision"),
        &[
            "resource.read",
            "resource.write",
            "procedural.read",
            "procedural.write",
        ],
        &[
            PROCEDURAL_RECORD_KIND,
            PROCEDURAL_ACTIVATION_REQUEST_KIND,
            PROCEDURAL_ACTIVATION_DECISION_KIND,
        ],
        &[
            "kind:procedural_record",
            "kind:procedural_activation_request",
            "kind:procedural_activation_decision",
            "proceduralKind:hook",
            &format!("resource:{procedural_record_id}"),
            &format!("resource:{request_resource_id}"),
        ],
        "none",
    )
    .await
}

async fn derived_procedural_read_grant(
    handle: &crate::engine::EngineHostHandle,
    suffix: &str,
    scopes: &[&str],
    resource_kinds: &[&str],
    selectors: &[&str],
    network_policy: &str,
) -> AuthorityGrantId {
    let grant = handle
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("procedural-read-{suffix}")).unwrap()),
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
                .chain(
                    [
                        "procedural_record:skill:redacted",
                        "procedural_record:hook:auth",
                        "procedural_record:procedure:workspace",
                        "procedural_record:wrong-kind",
                        "procedural_record:schema-mismatch",
                        "procedural_record:payload-version",
                        "procedural_record:stale",
                        "procedural_record:malformed",
                    ]
                    .into_iter()
                    .map(|resource_id| format!("resource:{resource_id}")),
                )
                .collect(),
            file_roots: vec!["/tmp".to_owned()],
            network_policy: network_policy.to_owned(),
            max_risk: RiskLevel::Low,
            budget: json!({"class": "procedural_read_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "procedural_inspection_test"}),
            trace_id: TraceId::new(format!("trace-procedural-read-{suffix}")).unwrap(),
        })
        .await
        .expect("derive procedural read grant");
    grant.grant_id
}

fn procedural_read_invocation(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    session_id: &str,
    workspace_id: &str,
) -> Invocation {
    procedural_invocation_with_context(
        key,
        payload,
        grant_id,
        Some(session_id),
        Some(workspace_id),
        ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::Agent,
    )
}

fn procedural_invocation_with_context(
    key: &str,
    payload: Value,
    grant_id: AuthorityGrantId,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    actor_id: ActorId,
    actor_kind: ActorKind,
) -> Invocation {
    let mut context = CausalContext::new(
        actor_id,
        actor_kind,
        grant_id,
        TraceId::new(format!("trace-procedural-{key}")).unwrap(),
    );
    if let Some(session_id) = session_id {
        context = context.with_session_id(session_id.to_owned());
    }
    if let Some(workspace_id) = workspace_id {
        context = context.with_workspace_id(workspace_id.to_owned());
    }
    for scope in ["procedural.read", "resource.read"] {
        context = context.with_scope(scope);
    }
    Invocation {
        id: InvocationId::new(format!("invocation-procedural-{key}")).unwrap(),
        function_id: FunctionId::new("capability::execute").unwrap(),
        delivery_mode: DeliveryMode::Sync,
        payload,
        causal_context: context,
    }
}

async fn create_procedural_record(
    handle: &crate::engine::EngineHostHandle,
    resource_id: &str,
    scope: EngineResourceScope,
    payload: Value,
    lifecycle: &str,
) {
    handle
        .create_resource(CreateResource {
            resource_id: Some(resource_id.to_owned()),
            kind: PROCEDURAL_RECORD_KIND.to_owned(),
            schema_id: None,
            scope,
            owner_worker_id: WorkerId::new(WORKER).unwrap(),
            owner_actor_id: ActorId::new("agent:procedural-test").unwrap(),
            lifecycle: Some(lifecycle.to_owned()),
            policy: json!({"owner": WORKER, "activation": "forbidden"}),
            initial_payload: Some(payload),
            locations: Vec::new(),
            trace_id: TraceId::new(format!("trace-{resource_id}").replace(':', "-")).unwrap(),
            invocation_id: None,
        })
        .await
        .expect("create procedural record");
}
