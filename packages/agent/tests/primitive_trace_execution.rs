//! Primitive traceability proof for the one-tool agent loop.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicU16;
use std::time::Instant;

use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::Mutex;
use tron::domains::agent::runner::{Orchestrator, ProfileRuntime, SessionManager};
use tron::domains::model::providers::ProviderHealthTracker;
use tron::domains::session::event_store::{ConnectionConfig, EventStore, new_file, run_migrations};
use tron::engine::invocation::{
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN, RUNTIME_METADATA_WORKING_DIRECTORY,
};
use tron::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use tron::shared::model_capabilities::CapabilityResult;
use tron::shared::server::context::ServerRuntimeContext;

struct TestRuntime {
    _temp: TempDir,
    ctx: ServerRuntimeContext,
}

fn unique_home(root: &Path) -> PathBuf {
    let home = root.join(".tron");
    tron::shared::constitution::ensure_tron_home_at(&home).unwrap();
    home
}

fn test_runtime() -> TestRuntime {
    let temp = tempfile::tempdir().unwrap();
    let home = unique_home(temp.path());
    let db_path = temp.path().join("tron.sqlite");
    let pool = new_file(db_path.to_str().unwrap(), &ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        run_migrations(&conn).unwrap();
    }
    let event_store = Arc::new(EventStore::new(pool));
    let session_manager = Arc::new(SessionManager::new(Arc::clone(&event_store)));
    let orchestrator = Arc::new(Orchestrator::new(Arc::clone(&session_manager)));
    let settings_path = home
        .join(tron::shared::paths::dirs::PROFILES)
        .join(tron::shared::profile::USER_PROFILE)
        .join(tron::shared::paths::files::PROFILE_TOML);
    let auth_path = home
        .join(tron::shared::paths::dirs::PROFILES)
        .join(tron::shared::paths::files::AUTH_JSON);
    let profile_runtime = Arc::new(ProfileRuntime::load(&home).unwrap());
    let settings =
        tron::domains::settings::load_settings_from_path(&settings_path).expect("settings load");
    tron::domains::settings::init_settings(settings);

    let ctx = ServerRuntimeContext {
        orchestrator,
        session_manager,
        event_store,
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        settings_path,
        profile_runtime,
        agent_deps: None,
        server_start_time: Instant::now(),
        health_tracker: Arc::new(ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_owned(),
        auth_path,
        oauth_flows: Arc::new(Mutex::new(HashMap::new())),
        ws_port: Arc::new(AtomicU16::new(9847)),
        onboarded_marker_path: temp.path().join(".onboarded"),
        release_fetcher: None,
        updater_state_path: temp.path().join("updater-state.json"),
    };
    tron::transport::setup::register_server_domains_for_context(&ctx).unwrap();
    TestRuntime { _temp: temp, ctx }
}

fn causal_context(
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
    working_directory: &Path,
    provider_invocation_id: &str,
    idempotency_key: &str,
) -> CausalContext {
    CausalContext::new(
        ActorId::new(format!("agent:{session_id}")).unwrap(),
        ActorKind::Agent,
        AuthorityGrantId::new("agent-capability-runtime").unwrap(),
        trace_id,
    )
    .with_scope("capability.execute")
    .with_session_id(session_id.to_owned())
    .with_workspace_id(workspace_id.to_owned())
    .with_idempotency_key(idempotency_key.to_owned())
    .with_runtime_metadata(
        RUNTIME_METADATA_WORKING_DIRECTORY,
        working_directory.display().to_string(),
    )
    .with_runtime_metadata(
        RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
        provider_invocation_id,
    )
    .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
    .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run_trace_test")
    .with_runtime_metadata(RUNTIME_METADATA_TURN, "1")
}

async fn invoke_execute(
    ctx: &ServerRuntimeContext,
    payload: Value,
    causal: CausalContext,
) -> Value {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            payload,
            causal,
        ))
        .await;
    assert_eq!(result.error, None);
    result.value.expect("capability result value")
}

#[tokio::test]
async fn execute_file_write_records_agent_trace_and_trace_list_exposes_it() {
    let runtime = test_runtime();
    let workspace = tempfile::tempdir().unwrap();
    let created = runtime
        .ctx
        .event_store
        .create_session(
            "openai/gpt-4o",
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
            trace_id.clone(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-write-1",
            "trace-write-1",
        ),
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
            trace_id.clone(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-list-1",
            "trace-list-1",
        ),
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
            trace_id.clone(),
            &created.session.id,
            &created.session.workspace_id,
            workspace.path(),
            "provider-call-get-1",
            "trace-get-1",
        ),
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
    assert_eq!(
        write_record["metadata"]["dev.tron"]["modelId"],
        "openai/gpt-4o"
    );
    assert_eq!(write_record["metadata"]["dev.tron"]["provider"], "openai");
    assert_eq!(write_record["files"][0]["path"], "notes/trace.txt");
    assert_eq!(
        write_record["files"][0]["conversations"][0]["contributor"]["type"],
        "ai"
    );
    assert_eq!(
        write_record["files"][0]["conversations"][0]["contributor"]["model_id"],
        "openai/gpt-4o"
    );
    assert!(
        write_record["files"][0]["conversations"][0]["ranges"][0]["content_hash"]
            .as_str()
            .unwrap()
            .starts_with("sha256:")
    );
}
