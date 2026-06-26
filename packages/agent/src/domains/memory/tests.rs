use serde_json::{Value, json};

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, DeriveGrant, FunctionId, Invocation,
    InvocationResult, RiskLevel, TraceId,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

#[tokio::test]
async fn status_defaults_disabled_and_writes_fail_closed() {
    let ctx = make_test_context();

    let status = invoke_read(
        &ctx,
        super::STATUS_FUNCTION,
        json!({}),
        "memory-disabled-status",
    )
    .await
    .expect("status");
    assert_eq!(status["mode"], "disabled");
    assert_eq!(status["policy"]["implicit"], true);
    assert_eq!(status["promptInclusion"]["enabledForPrompt"], false);
    assert_eq!(status["contract"]["hiddenPromptMemory"], false);
    assert_eq!(status["contract"]["semanticRetrieval"], false);

    let rejected = invoke_write_result(
        &ctx,
        super::RETAIN_FUNCTION,
        retain_payload("disabled-record"),
        "memory-disabled-retain",
    )
    .await;
    assert!(
        rejected
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("memory is disabled")),
        "disabled memory must reject writes: {:?}",
        rejected.error
    );
}

#[tokio::test]
async fn workspace_policy_inherits_into_session_until_session_policy_overrides() {
    let ctx = make_test_context();

    let workspace_policy = invoke_write_with_context(
        &ctx,
        super::CONFIGURE_FUNCTION,
        json!({
            "mode": "active",
            "provenance": {"source": "workspace_policy_test"}
        }),
        workspace_context("memory-workspace-policy")
            .with_idempotency_key("memory-workspace-policy"),
    )
    .await;
    assert_eq!(workspace_policy["status"], "configured");

    let inherited = invoke_read(
        &ctx,
        super::STATUS_FUNCTION,
        json!({}),
        "memory-workspace-inherited-status",
    )
    .await
    .expect("inherited workspace policy status");
    assert_eq!(inherited["mode"], "active");
    assert_eq!(
        inherited["policy"]["scope"],
        json!({"workspace": "memory-workspace"})
    );

    let session_policy = invoke_write(
        &ctx,
        super::CONFIGURE_FUNCTION,
        json!({
            "mode": "disabled",
            "provenance": {"source": "session_override_test"}
        }),
        "memory-session-policy-override",
    )
    .await;
    assert_eq!(session_policy["status"], "configured");

    let overridden = invoke_read(
        &ctx,
        super::STATUS_FUNCTION,
        json!({}),
        "memory-session-overridden-status",
    )
    .await
    .expect("session override status");
    assert_eq!(overridden["mode"], "disabled");
    assert_eq!(
        overridden["policy"]["scope"],
        json!({"session": "memory-session"})
    );
}

#[tokio::test]
async fn record_lifecycle_is_versioned_resource_backed_and_redacted() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-lifecycle-configure").await;

    let retained = invoke_write(
        &ctx,
        super::RETAIN_FUNCTION,
        retain_payload("lifecycle-record"),
        "memory-lifecycle-retain",
    )
    .await;
    let record_resource_id = retained["recordResourceId"].as_str().expect("record id");
    let retained_version_id = retained["recordVersionId"].as_str().expect("version id");
    assert_eq!(retained["status"], "retained");
    assert_eq!(
        retained["resourceRefs"][0]["kind"],
        super::MEMORY_RECORD_KIND
    );

    let list = invoke_read(
        &ctx,
        super::LIST_FUNCTION,
        json!({}),
        "memory-lifecycle-list",
    )
    .await
    .expect("list");
    assert_eq!(list["records"].as_array().expect("records").len(), 1);
    let listed_record = &list["records"][0]["record"];
    assert_eq!(listed_record["bodyRef"]["redacted"], true);
    assert!(listed_record["bodyRef"].get("uri").is_none());

    let edited = invoke_write(
        &ctx,
        super::EDIT_FUNCTION,
        json!({
            "recordResourceId": record_resource_id,
            "expectedCurrentVersionId": retained_version_id,
            "preview": "Updated preview",
            "reason": "test_edit"
        }),
        "memory-lifecycle-edit",
    )
    .await;
    let edited_version_id = edited["recordVersionId"].as_str().expect("edited version");
    assert_eq!(edited["status"], "edited");

    let tombstoned = invoke_write(
        &ctx,
        super::TOMBSTONE_FUNCTION,
        json!({
            "recordResourceId": record_resource_id,
            "expectedCurrentVersionId": edited_version_id,
            "reason": "test_tombstone"
        }),
        "memory-lifecycle-tombstone",
    )
    .await;
    assert_eq!(tombstoned["status"], "tombstoned");

    let inspected = invoke_read(
        &ctx,
        super::INSPECT_FUNCTION,
        json!({"recordResourceId": record_resource_id}),
        "memory-lifecycle-inspect",
    )
    .await
    .expect("inspect");
    assert_eq!(inspected["resource"]["kind"], super::MEMORY_RECORD_KIND);
    assert_eq!(inspected["resource"]["lifecycle"], "tombstoned");
    assert_eq!(inspected["versions"].as_array().expect("versions").len(), 3);
    assert_eq!(
        inspected["versions"][0]["record"]["bodyRef"]["redacted"],
        true
    );
    assert!(
        inspected["versions"][0]["record"]["bodyRef"]
            .get("uri")
            .is_none()
    );
}

#[tokio::test]
async fn record_id_operations_reject_cross_session_scope() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-scope-configure").await;
    let retained = invoke_write(
        &ctx,
        super::RETAIN_FUNCTION,
        retain_payload("scope-record"),
        "memory-scope-retain",
    )
    .await;
    let record_resource_id = retained["recordResourceId"].as_str().expect("record id");
    let retained_version_id = retained["recordVersionId"].as_str().expect("version id");

    invoke_write_with_context(
        &ctx,
        super::CONFIGURE_FUNCTION,
        json!({
            "mode": "active",
            "provenance": {"source": "other_session_scope_test"}
        }),
        other_session_context("memory-other-session-configure")
            .with_scope(super::READ_SCOPE)
            .with_scope(super::WRITE_SCOPE)
            .with_idempotency_key("memory-other-session-configure"),
    )
    .await;

    let inspect = invoke_read_result_with_context(
        &ctx,
        super::INSPECT_FUNCTION,
        json!({"recordResourceId": record_resource_id}),
        other_session_context("memory-other-session-inspect").with_scope(super::READ_SCOPE),
    )
    .await;
    assert!(
        inspect
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("scope mismatch")),
        "cross-session inspect must fail closed: {:?}",
        inspect.error
    );

    let edit = invoke_write_result_with_context(
        &ctx,
        super::EDIT_FUNCTION,
        json!({
            "recordResourceId": record_resource_id,
            "expectedCurrentVersionId": retained_version_id,
            "preview": "cross-session edit"
        }),
        other_session_context("memory-other-session-edit")
            .with_scope(super::READ_SCOPE)
            .with_scope(super::WRITE_SCOPE)
            .with_idempotency_key("memory-other-session-edit"),
    )
    .await;
    assert!(
        edit.error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("scope mismatch")),
        "cross-session edit must fail closed: {:?}",
        edit.error
    );

    let tombstone = invoke_write_result_with_context(
        &ctx,
        super::TOMBSTONE_FUNCTION,
        json!({
            "recordResourceId": record_resource_id,
            "expectedCurrentVersionId": retained_version_id,
            "reason": "cross-session tombstone"
        }),
        other_session_context("memory-other-session-tombstone")
            .with_scope(super::READ_SCOPE)
            .with_scope(super::WRITE_SCOPE)
            .with_idempotency_key("memory-other-session-tombstone"),
    )
    .await;
    assert!(
        tombstone
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("scope mismatch")),
        "cross-session tombstone must fail closed: {:?}",
        tombstone.error
    );
}

#[tokio::test]
async fn inline_body_refs_are_rejected() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-inline-configure").await;

    let rejected = invoke_write_result(
        &ctx,
        super::RETAIN_FUNCTION,
        json!({
            "recordId": "memory_record:inline-rejected",
            "subject": "inline",
            "scope": {"kind": "session", "id": "memory-session"},
            "preview": "Inline private material",
            "bodyRef": {"kind": "inline", "text": "secret private body"},
            "provenance": {"source": "test"},
            "confidence": {"score": 0.9},
            "sensitivity": "private",
            "retention": {"policy": "explicit"}
        }),
        "memory-inline-retain",
    )
    .await;

    assert!(
        rejected
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("cannot include inline text")),
        "inline body text must be rejected: {:?}",
        rejected.error
    );
}

#[tokio::test]
async fn nested_inline_body_refs_are_rejected_on_retain() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-nested-inline-configure").await;

    let rejected = invoke_write_result(
        &ctx,
        super::RETAIN_FUNCTION,
        json!({
            "recordId": "memory_record:nested-inline-rejected",
            "subject": "nested-inline",
            "scope": {"kind": "session", "id": "memory-session"},
            "preview": "Nested inline private material",
            "bodyRef": {
                "kind": "resource_pointer",
                "resourceId": "blob:nested-inline",
                "metadata": {
                    "text": "secret private body"
                }
            },
            "provenance": {"source": "test"},
            "confidence": {"score": 0.9},
            "sensitivity": "private",
            "retention": {"policy": "explicit"}
        }),
        "memory-nested-inline-retain",
    )
    .await;

    assert!(
        rejected
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("cannot include inline text")),
        "nested inline body text must be rejected: {:?}",
        rejected.error
    );
}

#[tokio::test]
async fn prompt_trace_records_audit_without_private_memory_content() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-prompt-configure").await;
    let retained = invoke_write(
        &ctx,
        super::RETAIN_FUNCTION,
        retain_payload("prompt-record"),
        "memory-prompt-retain",
    )
    .await;
    let record_resource_id = retained["recordResourceId"].as_str().expect("record id");

    let trace = invoke_write(
        &ctx,
        super::PROMPT_TRACE_FUNCTION,
        json!({"source": "test_prompt_trace", "limit": 10}),
        "memory-prompt-trace",
    )
    .await;

    let context = trace["context"].as_str().expect("context text");
    assert!(context.contains("Memory mode: active"));
    assert!(context.contains("Records considered: 1"));
    assert!(context.contains("Records included: 0"));
    assert!(context.contains("Private memory content included: no"));
    assert!(!context.contains("vault://"));
    assert!(!context.contains("secret private body"));
    assert_eq!(trace["trace"]["privateContentLogged"], false);
    assert_eq!(trace["trace"]["included"], 0);

    let inspection = ctx
        .engine_host
        .inspect_resource(
            trace["traceResourceId"]
                .as_str()
                .expect("trace resource id"),
        )
        .await
        .unwrap()
        .expect("prompt trace resource");
    let payload = &inspection.versions.last().expect("trace payload").payload;
    assert_eq!(payload["redaction"]["promptReceivesRecordBody"], false);
    assert_eq!(
        payload["considered"][0]["resourceRef"]["resourceId"],
        record_resource_id
    );
}

#[tokio::test]
async fn load_prompt_memory_context_is_explicit_when_memory_is_absent() {
    let ctx = make_test_context();

    let context = super::service::load_prompt_memory_context(
        &ctx.engine_host,
        "memory-session",
        Some("memory-workspace"),
        Some(TraceId::new("memory-load-context").unwrap()),
    )
    .await
    .expect("memory context text");

    assert!(context.contains("Memory mode: disabled"));
    assert!(context.contains("Records considered: 0"));
    assert!(context.contains("Private memory content included: no"));
}

#[tokio::test]
async fn load_prompt_memory_context_records_fresh_trace_after_policy_changes() {
    let ctx = make_test_context();

    let initial = super::service::load_prompt_memory_context(
        &ctx.engine_host,
        "memory-session",
        Some("memory-workspace"),
        Some(TraceId::new("memory-load-before-policy").unwrap()),
    )
    .await
    .expect("initial memory context text");
    assert!(initial.contains("Memory mode: disabled"));

    configure_active(&ctx, "memory-fresh-context-configure").await;
    invoke_write(
        &ctx,
        super::RETAIN_FUNCTION,
        retain_payload("fresh-context-record"),
        "memory-fresh-context-retain",
    )
    .await;

    let refreshed = super::service::load_prompt_memory_context(
        &ctx.engine_host,
        "memory-session",
        Some("memory-workspace"),
        Some(TraceId::new("memory-load-after-policy").unwrap()),
    )
    .await
    .expect("refreshed memory context text");
    assert!(refreshed.contains("Memory mode: active"));
    assert!(refreshed.contains("Records considered: 1"));
}

#[tokio::test]
async fn migration_export_import_uses_redacted_portable_envelope() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-migration-configure").await;
    invoke_write(
        &ctx,
        super::RETAIN_FUNCTION,
        retain_payload("migration-record"),
        "memory-migration-retain",
    )
    .await;

    let exported = invoke_write(
        &ctx,
        super::EXPORT_FUNCTION,
        json!({"targetEngineId": "future-memory-engine"}),
        "memory-migration-export",
    )
    .await;
    assert_eq!(exported["status"], "exported");
    assert_eq!(exported["recordCount"], 1);

    let envelope_resource_id = exported["envelopeResourceId"]
        .as_str()
        .expect("envelope resource id");
    let envelope = ctx
        .engine_host
        .inspect_resource(envelope_resource_id)
        .await
        .unwrap()
        .expect("envelope resource");
    let envelope_payload = envelope
        .versions
        .last()
        .expect("envelope payload")
        .payload
        .clone();
    assert_eq!(envelope_payload["validation"]["redacted"], true);
    assert_eq!(
        envelope_payload["records"][0]["record"]["bodyRef"]["redacted"],
        true
    );
    assert!(
        envelope_payload["records"][0]["record"]["bodyRef"]
            .get("uri")
            .is_none()
    );

    let imported = invoke_write(
        &ctx,
        super::IMPORT_FUNCTION,
        json!({"envelope": envelope_payload}),
        "memory-migration-import",
    )
    .await;
    assert_eq!(imported["status"], "imported");
    assert_eq!(imported["recordCount"], 1);
    assert_eq!(
        imported["resourceRefs"][0]["kind"],
        super::MEMORY_RECORD_KIND
    );
}

#[tokio::test]
async fn migration_import_rejects_nested_inline_body_ref_content() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-migration-inline-configure").await;

    let rejected = invoke_write_result(
        &ctx,
        super::IMPORT_FUNCTION,
        json!({
            "envelope": {
                "schemaVersion": "1",
                "operation": "import",
                "sourceEngineId": "resource-backed-memory",
                "records": [{
                    "record": imported_record_payload(
                        "migration-nested-inline",
                        json!({
                            "kind": "resource_pointer",
                            "resourceId": "blob:migration-nested-inline",
                            "metadata": {
                                "text": "secret private body"
                            }
                        })
                    )
                }]
            }
        }),
        "memory-migration-inline-import",
    )
    .await;

    assert!(
        rejected
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("cannot include inline text")),
        "migration import must reject nested inline body text: {:?}",
        rejected.error
    );
}

#[tokio::test]
async fn query_and_decision_evidence_are_metadata_only_and_idempotent() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-evidence-configure").await;
    let retained = invoke_write(
        &ctx,
        super::RETAIN_FUNCTION,
        retain_payload("evidence-record"),
        "memory-evidence-retain",
    )
    .await;
    let record_resource_id = retained["recordResourceId"].as_str().expect("record id");
    let record_version_id = retained["recordVersionId"]
        .as_str()
        .expect("record version");
    let record_ref = json!({
        "kind": super::MEMORY_RECORD_KIND,
        "resourceId": record_resource_id,
        "versionId": record_version_id,
        "role": "selected_memory_record"
    });

    let query = invoke_write(
        &ctx,
        super::RECORD_QUERY_FUNCTION,
        json!({
            "queryId": "candidate-query",
            "queryKind": "semantic_candidate_query",
            "intent": {"kind": "candidate_refs_only"},
            "filters": {"scope": "current_session"},
            "selectedRefs": [record_ref.clone()],
            "occurredAt": "2026-06-26T00:00:00Z"
        }),
        "memory-evidence-query",
    )
    .await;
    assert_eq!(query["status"], "recorded");
    assert_eq!(query["query"]["redaction"]["metadataOnly"], true);
    assert_eq!(query["query"]["redaction"]["memoryBodyStored"], false);
    assert_eq!(query["query"]["lifecycle"]["retrievalExecuted"], false);
    assert_eq!(query["query"]["idempotency"]["rawKeyStored"], false);
    let query_resource_id = query["queryResourceId"].as_str().expect("query id");
    let query_version_id = query["queryVersionId"].as_str().expect("query version");

    let replay = invoke_write(
        &ctx,
        super::RECORD_QUERY_FUNCTION,
        json!({
            "queryId": "candidate-query",
            "queryKind": "semantic_candidate_query",
            "intent": {"kind": "candidate_refs_only"},
            "filters": {"scope": "current_session"},
            "selectedRefs": [record_ref.clone()],
            "occurredAt": "2026-06-26T00:00:00Z"
        }),
        "memory-evidence-query",
    )
    .await;
    assert_eq!(replay["query"]["idempotency"]["rawKeyStored"], false);
    assert_eq!(replay["queryResourceId"], query_resource_id);

    let decision = invoke_write(
        &ctx,
        super::RECORD_DECISION_FUNCTION,
        json!({
            "decisionId": "candidate-decision",
            "decisionKind": "retrieve",
            "reasonCodes": ["candidate_ref_selected"],
            "subjectRef": record_ref,
            "queryRef": {
                "kind": super::MEMORY_QUERY_KIND,
                "resourceId": query_resource_id,
                "versionId": query_version_id,
                "role": "source_query"
            },
            "sourceRefs": [{"kind": "trace", "id": "memory-evidence-trace"}],
            "occurredAt": "2026-06-26T00:00:01Z"
        }),
        "memory-evidence-decision",
    )
    .await;
    assert_eq!(decision["status"], "recorded");
    assert_eq!(decision["decision"]["redaction"]["metadataOnly"], true);
    assert_eq!(
        decision["decision"]["lifecycle"]["decisionAppliedToPrompt"],
        false
    );
    assert_eq!(
        decision["decision"]["lifecycle"]["automaticRetentionPerformed"],
        false
    );

    let inspected = invoke_read(
        &ctx,
        super::INSPECT_QUERY_FUNCTION,
        json!({"queryResourceId": query_resource_id}),
        "memory-evidence-query-inspect",
    )
    .await
    .expect("query inspect");
    assert_eq!(inspected["resource"]["kind"], super::MEMORY_QUERY_KIND);
    assert_eq!(
        inspected["versions"][0]["record"]["redaction"]["metadataOnly"],
        true
    );
    let serialized = serde_json::to_string(&inspected).expect("serialize");
    assert!(!serialized.contains("vault://"));
}

#[tokio::test]
async fn query_and_decision_evidence_reject_wrong_scope_kind_stale_and_raw_material() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-evidence-guards-configure").await;
    let retained = invoke_write(
        &ctx,
        super::RETAIN_FUNCTION,
        retain_payload("evidence-guards-record"),
        "memory-evidence-guards-retain",
    )
    .await;
    let record_resource_id = retained["recordResourceId"].as_str().expect("record id");
    let record_version_id = retained["recordVersionId"]
        .as_str()
        .expect("record version");

    let raw = invoke_write_result(
        &ctx,
        super::RECORD_QUERY_FUNCTION,
        json!({
            "queryKind": "semantic_candidate_query",
            "intent": {"prompt": "raw prompt text must not be stored"},
            "occurredAt": "2026-06-26T00:01:00Z"
        }),
        "memory-evidence-raw-query",
    )
    .await;
    assert!(
        raw.error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("raw/private")),
        "raw query material must be rejected: {:?}",
        raw.error
    );

    let wrong_kind = invoke_write_result(
        &ctx,
        super::RECORD_QUERY_FUNCTION,
        json!({
            "queryKind": "semantic_candidate_query",
            "selectedRefs": [{
                "kind": super::MEMORY_QUERY_KIND,
                "resourceId": record_resource_id,
                "versionId": record_version_id,
                "role": "wrong_kind"
            }],
            "occurredAt": "2026-06-26T00:01:01Z"
        }),
        "memory-evidence-wrong-kind-query",
    )
    .await;
    assert!(
        wrong_kind
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("wrong kind")),
        "wrong-kind selected ref must fail: {:?}",
        wrong_kind.error
    );

    let stale = invoke_write_result(
        &ctx,
        super::RECORD_QUERY_FUNCTION,
        json!({
            "queryKind": "semantic_candidate_query",
            "selectedRefs": [{
                "kind": super::MEMORY_RECORD_KIND,
                "resourceId": record_resource_id,
                "versionId": "stale-version",
                "role": "stale"
            }],
            "occurredAt": "2026-06-26T00:01:02Z"
        }),
        "memory-evidence-stale-query",
    )
    .await;
    assert!(
        stale
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("stale version")),
        "stale selected ref must fail: {:?}",
        stale.error
    );

    let cross_scope = invoke_write_result_with_context(
        &ctx,
        super::RECORD_DECISION_FUNCTION,
        json!({
            "decisionKind": "retrieve",
            "reasonCodes": ["scope_mismatch"],
            "subjectRef": {
                "kind": super::MEMORY_RECORD_KIND,
                "resourceId": record_resource_id,
                "versionId": record_version_id,
                "role": "subject"
            },
            "occurredAt": "2026-06-26T00:01:03Z"
        }),
        other_session_context("memory-evidence-cross-scope-decision")
            .with_scope(super::READ_SCOPE)
            .with_scope(super::WRITE_SCOPE)
            .with_idempotency_key("memory-evidence-cross-scope-decision"),
    )
    .await;
    assert!(
        cross_scope
            .error
            .as_ref()
            .is_some_and(|error| error.to_string().contains("scope mismatch")),
        "cross-scope decision ref must fail: {:?}",
        cross_scope.error
    );
}

#[tokio::test]
async fn execute_can_read_only_inspect_query_and_decision_evidence() {
    let ctx = make_test_context();
    configure_active(&ctx, "memory-execute-evidence-configure").await;
    let query = invoke_write(
        &ctx,
        super::RECORD_QUERY_FUNCTION,
        json!({
            "queryId": "execute-query",
            "queryKind": "episodic_trace_query",
            "intent": {"kind": "trace_refs_only"},
            "occurredAt": "2026-06-26T00:02:00Z"
        }),
        "memory-execute-evidence-query",
    )
    .await;
    let decision = invoke_write(
        &ctx,
        super::RECORD_DECISION_FUNCTION,
        json!({
            "decisionId": "execute-decision",
            "decisionKind": "reject",
            "reasonCodes": ["retrieval_engine_absent"],
            "occurredAt": "2026-06-26T00:02:01Z"
        }),
        "memory-execute-evidence-decision",
    )
    .await;
    let execute_grant = derive_execute_grant(&ctx, "memory-execute-grant").await;

    let query_list = invoke_read_with_context(
        &ctx,
        crate::domains::capability::contract::EXECUTE_FUNCTION_ID,
        json!({"operation": "memory_query_list"}),
        agent_context("memory-execute-query-list", execute_grant.clone())
            .with_scope("capability.execute")
            .with_scope(super::READ_SCOPE),
    )
    .await
    .expect("execute query list");
    assert_eq!(
        query_list["details"]["primitiveOperation"],
        "memory_query_list"
    );
    assert_eq!(
        query_list["details"]["memory"]["queries"][0]["record"]["lifecycle"]["retrievalExecuted"],
        false
    );

    let decision_inspect = invoke_read_with_context(
        &ctx,
        crate::domains::capability::contract::EXECUTE_FUNCTION_ID,
        json!({
            "operation": "memory_decision_inspect",
            "decisionResourceId": decision["decisionResourceId"]
        }),
        agent_context("memory-execute-decision-inspect", execute_grant.clone())
            .with_scope("capability.execute")
            .with_scope(super::READ_SCOPE),
    )
    .await
    .expect("execute decision inspect");
    assert_eq!(
        decision_inspect["details"]["primitiveOperation"],
        "memory_decision_inspect"
    );
    assert_eq!(
        decision_inspect["details"]["memory"]["versions"][0]["record"]["redaction"]["memoryBodyStored"],
        false
    );

    let query_resource_id = query["queryResourceId"].as_str().expect("query id");
    let query_inspect = invoke_read_with_context(
        &ctx,
        crate::domains::capability::contract::EXECUTE_FUNCTION_ID,
        json!({
            "operation": "memory_query_inspect",
            "queryResourceId": query_resource_id
        }),
        agent_context("memory-execute-query-inspect", execute_grant)
            .with_scope("capability.execute")
            .with_scope(super::READ_SCOPE),
    )
    .await
    .expect("execute query inspect");
    assert_eq!(
        query_inspect["details"]["primitiveOperation"],
        "memory_query_inspect"
    );
}

async fn configure_active(ctx: &ServerRuntimeContext, key: &str) -> Value {
    invoke_write(
        ctx,
        super::CONFIGURE_FUNCTION,
        json!({
            "mode": "active",
            "provenance": {"source": "memory_test"}
        }),
        key,
    )
    .await
}

async fn invoke_read(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    trace_id: &str,
) -> Option<Value> {
    invoke_read_with_context(
        ctx,
        function_id,
        payload,
        client_context(trace_id).with_scope(super::READ_SCOPE),
    )
    .await
}

async fn invoke_read_with_context(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> Option<Value> {
    let result = invoke_read_result_with_context(ctx, function_id, payload, causal_context).await;
    assert_eq!(result.error, None, "read failed: {:?}", result.error);
    result.value
}

async fn invoke_read_result_with_context(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> InvocationResult {
    ctx.engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).unwrap(),
            payload,
            causal_context,
        ))
        .await
}

async fn invoke_write(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    key: &str,
) -> Value {
    let result = invoke_write_result(ctx, function_id, payload, key).await;
    assert_eq!(result.error, None, "write failed: {:?}", result.error);
    result.value.expect("write value")
}

async fn invoke_write_with_context(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> Value {
    let result = invoke_write_result_with_context(ctx, function_id, payload, causal_context).await;
    assert_eq!(result.error, None, "write failed: {:?}", result.error);
    result.value.expect("write value")
}

async fn invoke_write_result(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    key: &str,
) -> InvocationResult {
    invoke_write_result_with_context(
        ctx,
        function_id,
        payload,
        client_context(key)
            .with_scope(super::READ_SCOPE)
            .with_scope(super::WRITE_SCOPE)
            .with_idempotency_key(key),
    )
    .await
}

async fn invoke_write_result_with_context(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> InvocationResult {
    ctx.engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).unwrap(),
            payload,
            causal_context,
        ))
        .await
}

fn retain_payload(record_id: &str) -> Value {
    json!({
        "recordId": format!("memory_record:{record_id}"),
        "subject": record_id,
        "scope": {"kind": "session", "id": "memory-session"},
        "preview": "Remembered preference preview",
        "bodyRef": {
            "kind": "vault_blob",
            "resourceId": format!("blob:{record_id}"),
            "contentHash": format!("hash-{record_id}"),
            "uri": format!("vault://memory/{record_id}")
        },
        "provenance": {"source": "test", "evidence": "explicit_user_statement"},
        "confidence": {"score": 0.95, "basis": "explicit"},
        "sensitivity": "private",
        "retention": {"policy": "explicit", "until": "2099-01-01T00:00:00Z"},
        "sourceRefs": [{"kind": "message", "id": "msg-test"}],
        "migration": {"portable": true}
    })
}

fn imported_record_payload(record_id: &str, body_ref: Value) -> Value {
    json!({
        "schemaVersion": "1",
        "subject": record_id,
        "scope": {"kind": "session", "id": "memory-session"},
        "preview": "Imported preference preview",
        "bodyRef": body_ref,
        "provenance": {"source": "test_import"},
        "confidence": {"score": 0.95, "basis": "explicit"},
        "sensitivity": "private",
        "retention": {"policy": "explicit", "until": "2099-01-01T00:00:00Z"},
        "sourceRefs": [{"kind": "message", "id": "msg-import"}],
        "traceRefs": [],
        "replayRefs": [],
        "lifecycle": {"state": "retained"},
        "migration": {"portable": true},
        "revision": 1
    })
}

fn client_context(trace_id: &str) -> CausalContext {
    CausalContext::new(
        ActorId::new("engine-client").unwrap(),
        ActorKind::Client,
        AuthorityGrantId::new("engine-transport").unwrap(),
        TraceId::new(trace_id).unwrap(),
    )
    .with_session_id("memory-session")
    .with_workspace_id("memory-workspace")
}

async fn derive_execute_grant(ctx: &ServerRuntimeContext, suffix: &str) -> AuthorityGrantId {
    let grant = ctx
        .engine_host
        .derive_authority_grant(DeriveGrant {
            grant_id: Some(AuthorityGrantId::new(format!("memory-execute-{suffix}")).unwrap()),
            parent_grant_id: AuthorityGrantId::new("engine-system").unwrap(),
            subject_actor_id: Some(ActorId::new("agent:memory-session").unwrap()),
            subject_worker_id: None,
            subject_invocation_id: None,
            allowed_capabilities: vec![
                crate::domains::capability::contract::EXECUTE_FUNCTION_ID.to_owned(),
            ],
            allowed_namespaces: vec!["__no_namespace_authority__".to_owned()],
            allowed_authority_scopes: vec![
                "capability.execute".to_owned(),
                super::READ_SCOPE.to_owned(),
            ],
            allowed_resource_kinds: vec![
                super::MEMORY_QUERY_KIND.to_owned(),
                super::MEMORY_DECISION_KIND.to_owned(),
            ],
            resource_selectors: vec![
                "kind:memory_query".to_owned(),
                "kind:memory_decision".to_owned(),
            ],
            file_roots: vec!["/tmp".to_owned()],
            network_policy: "none".to_owned(),
            max_risk: RiskLevel::Medium,
            budget: json!({"class": "memory_query_decision_test"}),
            expires_at: None,
            can_delegate: false,
            provenance: json!({"source": "memory_query_decision_test"}),
            trace_id: TraceId::new(format!("trace-{suffix}")).unwrap(),
        })
        .await
        .expect("derive memory execute grant");
    grant.grant_id
}

fn agent_context(trace_id: &str, grant_id: AuthorityGrantId) -> CausalContext {
    CausalContext::new(
        ActorId::new("agent:memory-session").unwrap(),
        ActorKind::Agent,
        grant_id,
        TraceId::new(trace_id).unwrap(),
    )
    .with_session_id("memory-session")
    .with_workspace_id("memory-workspace")
}

fn workspace_context(trace_id: &str) -> CausalContext {
    CausalContext::new(
        ActorId::new("engine-client").unwrap(),
        ActorKind::Client,
        AuthorityGrantId::new("engine-transport").unwrap(),
        TraceId::new(trace_id).unwrap(),
    )
    .with_workspace_id("memory-workspace")
    .with_scope(super::READ_SCOPE)
    .with_scope(super::WRITE_SCOPE)
}

fn other_session_context(trace_id: &str) -> CausalContext {
    CausalContext::new(
        ActorId::new("engine-client").unwrap(),
        ActorKind::Client,
        AuthorityGrantId::new("engine-transport").unwrap(),
        TraceId::new(trace_id).unwrap(),
    )
    .with_session_id("other-memory-session")
    .with_workspace_id("memory-workspace")
}
