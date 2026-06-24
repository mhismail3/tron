//! Primitive traceability proof for the one-tool agent loop.

mod primitive_trace_execution_support;
use primitive_trace_execution_support::*;
use tracing::Level;
use tron::shared::observability::test_utils::{CapturedEvent, capture_global_logs};

#[tokio::test]
async fn execute_replay_manifest_is_read_only_and_does_not_create_trace_record() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("replay manifest"),
            Some("openai"),
        )
        .unwrap();

    let value = invoke_execute(
        &runtime.ctx,
        json!({"operation": "replay_manifest"}),
        causal_context(
            &runtime.ctx,
            TraceId::generate(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-replay-1",
            "trace-replay-1",
        )
        .await,
    )
    .await;
    let result: CapabilityResult = serde_json::from_value(value).unwrap();
    let details = result.details.as_ref().unwrap();
    assert_eq!(details["primitiveOperation"], "replay_manifest");
    assert_eq!(details["manifest"]["format"], "tron.replay.v1");
    assert_eq!(
        details["manifest"]["sections"]["traceRecords"]
            .as_array()
            .unwrap()
            .len(),
        0
    );

    let traces = runtime
        .ctx
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: Some(&created.session.id),
            trace_id: None,
            limit: Some(10),
        })
        .unwrap();
    assert!(
        traces.is_empty(),
        "replay_manifest must not mutate trace records"
    );
}

#[tokio::test]
async fn execute_catalog_search_does_not_require_working_directory_metadata() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("catalog discovery"),
            Some("openai"),
        )
        .unwrap();
    let trace_id = TraceId::generate();
    let actor_id = ActorId::new(format!("agent:{}", created.session.id)).unwrap();
    let grant_id = derive_capability_execute_grant(
        &runtime.ctx,
        &actor_id,
        trace_id.clone(),
        &created.session.id,
        &created.session.workspace_id,
        workspace.path().to_str().unwrap(),
        "provider-call-catalog-1",
        "none",
    )
    .await;

    let value = invoke_execute(
        &runtime.ctx,
        json!({
            "operation": "catalog_search",
            "text": "catalog",
            "includeProtectedCounts": true
        }),
        CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id.clone())
            .with_scope("capability.execute")
            .with_session_id(created.session.id.clone())
            .with_workspace_id(created.session.workspace_id.clone())
            .with_idempotency_key("trace-catalog-search-1")
            .with_runtime_metadata(
                RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
                "provider-call-catalog-1",
            )
            .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
            .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
            .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run_catalog_search_test")
            .with_runtime_metadata(RUNTIME_METADATA_TURN, "1"),
    )
    .await;

    let result: CapabilityResult = serde_json::from_value(value).unwrap();
    let details = result.details.as_ref().unwrap();
    assert_eq!(details["primitiveOperation"], "catalog_search");
    assert!(
        details["catalogDiscovery"]["summary"]["functions"]["visible"]
            .as_u64()
            .unwrap_or_default()
            > 0
    );
    assert_eq!(
        details["catalogDiscovery"]["continuity"]["reportResourceKind"],
        "catalog_discovery_report"
    );
}

#[tokio::test(flavor = "current_thread")]
async fn execute_catalog_search_emits_structured_agent_logs() {
    let logs = capture_global_logs();
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("catalog discovery logs"),
            Some("openai"),
        )
        .unwrap();
    let trace_id = TraceId::generate();
    let actor_id = ActorId::new(format!("agent:{}", created.session.id)).unwrap();
    let grant_id = derive_capability_execute_grant(
        &runtime.ctx,
        &actor_id,
        trace_id.clone(),
        &created.session.id,
        &created.session.workspace_id,
        workspace.path().to_str().unwrap(),
        "provider-call-catalog-log-1",
        "none",
    )
    .await;

    let value = invoke_execute(
        &runtime.ctx,
        json!({
            "operation": "catalog_search",
            "text": "catalog",
            "includeProtectedCounts": true
        }),
        CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id.clone())
            .with_scope("capability.execute")
            .with_session_id(created.session.id.clone())
            .with_workspace_id(created.session.workspace_id.clone())
            .with_idempotency_key("trace-catalog-search-log-1")
            .with_runtime_metadata(
                RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
                "provider-call-catalog-log-1",
            )
            .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
            .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
            .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run_catalog_search_log_test")
            .with_runtime_metadata(RUNTIME_METADATA_TURN, "1"),
    )
    .await;

    let result: CapabilityResult = serde_json::from_value(value).unwrap();
    assert_eq!(
        result.details.as_ref().unwrap()["primitiveOperation"],
        "catalog_search"
    );

    let events = logs.events();
    assert_agent_log(
        &events,
        Level::INFO,
        "execute_operation_started",
        &[
            ("operation", "catalog_search"),
            ("session_id", created.session.id.as_str()),
            ("trace_id", trace_id.as_str()),
        ],
    );
    assert_agent_log(
        &events,
        Level::INFO,
        "execute_trace_record_started",
        &[
            ("operation", "catalog_search"),
            ("session_id", created.session.id.as_str()),
            ("provider_invocation_id", "provider-call-catalog-log-1"),
        ],
    );
    assert_agent_log(
        &events,
        Level::INFO,
        "execute_operation_completed",
        &[
            ("operation", "catalog_search"),
            ("session_id", created.session.id.as_str()),
            ("status", "ok"),
        ],
    );
}

#[tokio::test]
async fn execute_file_write_records_agent_trace_and_trace_list_exposes_it() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("trace proof"),
            Some("openai"),
        )
        .unwrap();
    let trace_id = TraceId::generate();

    let write_value = invoke_execute(
        &runtime.ctx,
        json!({
            "operation": "file_write",
            "path": "notes/trace.txt",
            "content": "traceable\ncontent\n",
            "reason": "prove primitive trace capture"
        }),
        causal_context(
            &runtime.ctx,
            trace_id.clone(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-write-1",
            "trace-write-1",
        )
        .await,
    )
    .await;
    let write_result: CapabilityResult = serde_json::from_value(write_value).unwrap();
    assert_eq!(
        write_result.details.as_ref().unwrap()["primitiveOperation"],
        "file_write"
    );

    let list_value = invoke_execute(
        &runtime.ctx,
        json!({
            "operation": "trace_list",
            "traceId": trace_id.as_str(),
            "limit": 10
        }),
        causal_context(
            &runtime.ctx,
            trace_id.clone(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-list-1",
            "trace-list-1",
        )
        .await,
    )
    .await;
    let list_result: CapabilityResult = serde_json::from_value(list_value).unwrap();
    let records = list_result.details.as_ref().unwrap()["records"]
        .as_array()
        .expect("trace records array");
    let write_record = records
        .iter()
        .find(|record| {
            record["metadata"]["dev.tron"]["operation"] == "file_write"
                && record["metadata"]["dev.tron"]["providerInvocationId"] == "provider-call-write-1"
        })
        .expect("file_write trace record");
    let write_record = write_record.clone();
    let write_record_id = write_record["id"].as_str().unwrap().to_owned();

    let get_value = invoke_execute(
        &runtime.ctx,
        json!({
            "operation": "trace_get",
            "traceRecordId": write_record_id
        }),
        causal_context(
            &runtime.ctx,
            trace_id.clone(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-get-1",
            "trace-get-1",
        )
        .await,
    )
    .await;
    let get_result: CapabilityResult = serde_json::from_value(get_value).unwrap();
    assert_eq!(
        get_result.details.as_ref().unwrap()["record"]["metadata"]["dev.tron"]["operation"],
        "file_write"
    );
    assert_eq!(
        get_result.details.as_ref().unwrap()["record"]["id"],
        write_record_id
    );

    assert_eq!(write_record["version"], "0.1");
    assert_eq!(write_record["tool"]["name"], "tron");
    assert_eq!(
        write_record["metadata"]["dev.tron"]["traceId"],
        trace_id.as_str()
    );
    assert_eq!(write_record["metadata"]["dev.tron"]["status"], "ok");
    assert_eq!(
        write_record["metadata"]["dev.tron"]["authority"]["scopes"],
        json!(["capability.execute"])
    );
    assert_eq!(write_record["metadata"]["dev.tron"]["modelId"], "gpt-5.5");
    assert_eq!(write_record["metadata"]["dev.tron"]["provider"], "openai");
    assert_eq!(write_record["files"][0]["path"], "notes/trace.txt");
    assert_eq!(
        write_record["files"][0]["conversations"][0]["contributor"]["type"],
        "ai"
    );
    assert_eq!(
        write_record["files"][0]["conversations"][0]["contributor"]["model_id"],
        "gpt-5.5"
    );
    assert!(
        write_record["files"][0]["conversations"][0]["ranges"][0]["content_hash"]
            .as_str()
            .unwrap()
            .starts_with("sha256:")
    );
}

#[tokio::test]
async fn execute_process_run_expands_home_alias_in_trace_working_directory() {
    let runtime = test_runtime();
    let created = runtime
        .ctx
        .event_store
        .create_session("gpt-5.5", "~", Some("home trace proof"), Some("openai"))
        .unwrap();
    let trace_id = TraceId::generate();
    let expected_home = tron::shared::foundation::paths::normalize_working_directory("~")
        .unwrap()
        .display()
        .to_string();

    let result = runtime
        .ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            json!({
                "operation": "process_run",
                "command": "pwd",
                "timeoutMs": 5000,
                "maxOutputBytes": 2000,
                "reason": "prove working directory trace capture"
            }),
            causal_context_raw(
                &runtime.ctx,
                trace_id.clone(),
                &created.session.id,
                &created.session.workspace_id,
                "~",
                "provider-call-pwd-1",
                "trace-pwd-1",
            )
            .await,
        ))
        .await;

    #[cfg(target_os = "macos")]
    {
        assert_eq!(result.error, None);
        let run_result: CapabilityResult =
            serde_json::from_value(result.value.expect("capability result value")).unwrap();
        let details = run_result.details.as_ref().unwrap();
        assert_eq!(details["primitiveOperation"], "process_run");
        assert_eq!(details["status"], "ok");
        assert_eq!(details["stdout"].as_str().unwrap().trim(), expected_home);
    }

    #[cfg(not(target_os = "macos"))]
    {
        let error = result
            .error
            .expect("process_run should fail closed without a no-network sandbox")
            .to_string();
        assert!(
            error.contains("process_run cannot enforce networkPolicy none on this platform"),
            "process_run must fail closed without platform sandbox support, got: {error}"
        );
    }

    let records = runtime
        .ctx
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: Some(&created.session.id),
            trace_id: Some(trace_id.as_str()),
            limit: Some(10),
        })
        .unwrap();
    let run_record = records
        .iter()
        .find(|record| record.operation == "process_run")
        .expect("process_run trace record");
    assert_eq!(
        run_record.record_json["metadata"]["dev.tron"]["workingDirectory"],
        expected_home
    );
}

#[tokio::test]
async fn execute_log_recent_exposes_bounded_session_trace_logs() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "openai/gpt-4o",
            workspace.path().to_str().unwrap(),
            Some("log proof"),
            Some("openai"),
        )
        .unwrap();
    let trace_id = TraceId::generate();
    let mut current_session = ClientLogEntry::new(
        "2026-06-07T16:00:00.000Z",
        "info",
        "Engine",
        "current session evidence",
    );
    current_session.session_id = Some(created.session.id.clone());
    current_session.trace_id = Some(trace_id.to_string());
    let mut global_trace = ClientLogEntry::new(
        "2026-06-07T16:00:01.000Z",
        "warn",
        "Engine",
        "global trace evidence",
    );
    global_trace.trace_id = Some(trace_id.to_string());
    let mut other_session = ClientLogEntry::new(
        "2026-06-07T16:00:02.000Z",
        "error",
        "Engine",
        "other session evidence",
    );
    other_session.session_id = Some("sess_other".to_owned());
    other_session.trace_id = Some(trace_id.to_string());
    runtime
        .ctx
        .event_store
        .ingest_client_logs(&[current_session, global_trace, other_session])
        .unwrap();

    let logs_value = invoke_execute(
        &runtime.ctx,
        json!({
            "operation": "log_recent",
            "traceId": trace_id.as_str(),
            "limit": 10
        }),
        causal_context(
            &runtime.ctx,
            trace_id.clone(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-logs-1",
            "trace-logs-1",
        )
        .await,
    )
    .await;
    let logs_result: CapabilityResult = serde_json::from_value(logs_value).unwrap();
    assert_eq!(
        logs_result.details.as_ref().unwrap()["primitiveOperation"],
        "log_recent"
    );
    let entries = logs_result.details.as_ref().unwrap()["entries"]
        .as_array()
        .expect("log entries array");
    assert_eq!(entries.len(), 2);
    assert!(
        entries
            .iter()
            .any(|entry| entry["message"] == "current session evidence")
    );
    assert!(
        entries
            .iter()
            .any(|entry| entry["message"] == "global trace evidence")
    );
    assert!(
        !entries
            .iter()
            .any(|entry| entry["message"] == "other session evidence")
    );

    let sessionless_error = invoke_execute_error(
        &runtime.ctx,
        json!({
            "operation": "log_recent",
            "traceId": trace_id.as_str(),
            "limit": 10
        }),
        CausalContext::new(
            ActorId::new("agent:sessionless").unwrap(),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-capability-runtime").unwrap(),
            trace_id,
        )
        .with_scope("capability.execute")
        .with_runtime_metadata(
            RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
            "provider-call-logs-2",
        )
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run_trace_test")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1"),
    )
    .await;
    assert!(
        sessionless_error.contains("agent context requires session id"),
        "sessionless log_recent must fail closed, got: {sessionless_error}"
    );
}

#[tokio::test]
async fn execute_rejects_public_client_context() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("public denial"),
            Some("openai"),
        )
        .unwrap();
    let error = invoke_execute_error(
        &runtime.ctx,
        json!({"operation": "observe", "input": "public should not execute"}),
        CausalContext::new(
            ActorId::new("client:ios").unwrap(),
            ActorKind::Client,
            AuthorityGrantId::new("engine-transport").unwrap(),
            TraceId::generate(),
        )
        .with_scope("capability.execute")
        .with_session_id(created.session.id)
        .with_workspace_id(created.session.workspace_id)
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            workspace.path().display().to_string(),
        ),
    )
    .await;
    assert!(
        error.contains("trusted agent or system runtime context"),
        "public client execute must fail closed, got: {error}"
    );
}

#[tokio::test]
async fn execute_rejects_bootstrap_authority_grants() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("bootstrap denial"),
            Some("openai"),
        )
        .unwrap();
    let error = invoke_execute_error(
        &runtime.ctx,
        json!({"operation": "observe", "input": "bootstrap should not execute"}),
        CausalContext::new(
            ActorId::new(format!("agent:{}", created.session.id)).unwrap(),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-capability-runtime").unwrap(),
            TraceId::generate(),
        )
        .with_scope("capability.execute")
        .with_session_id(created.session.id)
        .with_workspace_id(created.session.workspace_id)
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            workspace.path().display().to_string(),
        ),
    )
    .await;
    assert!(
        error.contains("derived least-privilege authority grant"),
        "bootstrap execute must fail closed, got: {error}"
    );
}

#[tokio::test]
async fn execute_rejects_system_scoped_state() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("state denial"),
            Some("openai"),
        )
        .unwrap();
    let error = invoke_execute_error(
        &runtime.ctx,
        json!({
            "operation": "state_set",
            "scope": "system",
            "namespace": "proof",
            "key": "denied",
            "value": true
        }),
        causal_context(
            &runtime.ctx,
            TraceId::generate(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-state-denied-1",
            "trace-state-denied-1",
        )
        .await,
    )
    .await;
    assert!(
        error.contains("system-scoped state"),
        "system state must fail closed, got: {error}"
    );
}

#[tokio::test]
async fn execute_process_run_requires_none_network_policy() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "gpt-5.5",
            workspace.path().to_str().unwrap(),
            Some("process network denial"),
            Some("openai"),
        )
        .unwrap();
    let trace_id = TraceId::generate();
    let actor_id = ActorId::new(format!("agent:{}", created.session.id)).unwrap();
    let grant_id = derive_capability_execute_grant(
        &runtime.ctx,
        &actor_id,
        trace_id.clone(),
        &created.session.id,
        &created.session.workspace_id,
        workspace.path().to_str().unwrap(),
        "provider-call-process-loopback-1",
        "loopback",
    )
    .await;
    let error = invoke_execute_error(
        &runtime.ctx,
        json!({
            "operation": "process_run",
            "command": "pwd",
            "timeoutMs": 5000
        }),
        CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
            .with_scope("capability.execute")
            .with_session_id(created.session.id)
            .with_workspace_id(created.session.workspace_id)
            .with_idempotency_key("trace-process-network-denied-1")
            .with_runtime_metadata(
                RUNTIME_METADATA_WORKING_DIRECTORY,
                workspace.path().display().to_string(),
            )
            .with_runtime_metadata(
                RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
                "provider-call-process-loopback-1",
            )
            .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
            .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
            .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run_trace_test")
            .with_runtime_metadata(RUNTIME_METADATA_TURN, "1"),
    )
    .await;
    assert!(
        error.contains("networkPolicy none"),
        "process_run without none network policy must fail closed, got: {error}"
    );
}

fn assert_agent_log(
    events: &[CapturedEvent],
    level: Level,
    agent_event: &str,
    fields: &[(&str, &str)],
) {
    let matches = events.iter().any(|event| {
        event.level == level
            && event
                .fields
                .iter()
                .any(|(key, value)| key == "agent_event" && value == agent_event)
            && fields.iter().all(|(expected_key, expected_value)| {
                event.fields.iter().any(|(key, value)| {
                    key == expected_key && value.trim_matches('"') == *expected_value
                })
            })
    });
    assert!(
        matches,
        "missing {level:?} agent log {agent_event} with fields {fields:?}; events: {events:#?}"
    );
}
