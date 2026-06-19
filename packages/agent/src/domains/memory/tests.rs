use serde_json::{Value, json};

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, InvocationResult,
    TraceId,
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
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).unwrap(),
            payload,
            causal_context,
        ))
        .await;
    assert_eq!(result.error, None, "read failed: {:?}", result.error);
    result.value
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
