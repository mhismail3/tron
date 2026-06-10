use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::AtomicU16;
use std::time::Instant;

pub use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::Mutex;
use tron::domains::agent::{Orchestrator, ProfileRuntime, SessionManager};
pub use tron::domains::session::event_store::{AgentTraceListOptions, ClientLogEntry};
use tron::domains::session::event_store::{ConnectionConfig, EventStore, new_file, run_migrations};
pub use tron::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
pub use tron::engine::{
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY,
};
pub use tron::shared::protocol::model_capabilities::CapabilityResult;
use tron::shared::server::context::ServerRuntimeContext;

pub struct TestRuntime {
    _temp: TempDir,
    pub ctx: ServerRuntimeContext,
}

fn unique_home(root: &Path) -> std::path::PathBuf {
    let home = root.join(".tron");
    tron::shared::foundation::constitution::ensure_tron_home_at(&home).unwrap();
    home
}

pub fn test_runtime() -> TestRuntime {
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
        .join(tron::shared::foundation::paths::dirs::PROFILES)
        .join(tron::shared::foundation::profile::USER_PROFILE)
        .join(tron::shared::foundation::paths::files::PROFILE_TOML);
    let auth_path = home
        .join(tron::shared::foundation::paths::dirs::PROFILES)
        .join(tron::shared::foundation::paths::files::AUTH_JSON);
    let profile_runtime = Arc::new(ProfileRuntime::load(&home).unwrap());
    let settings =
        tron::domains::settings::profile::storage::loader::load_settings_from_path(&settings_path)
            .expect("settings load");
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
        shutdown_coordinator: None,
        origin: "localhost:9847".to_owned(),
        auth_path,
        oauth_flows: Arc::new(Mutex::new(HashMap::new())),
        ws_port: Arc::new(AtomicU16::new(9847)),
        onboarded_marker_path: temp.path().join(".onboarded"),
    };
    tron::transport::runtime::setup::register_server_domains_for_context(&ctx).unwrap();
    TestRuntime { _temp: temp, ctx }
}

pub async fn causal_context(
    ctx: &ServerRuntimeContext,
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
    working_directory: &Path,
    provider_invocation_id: &str,
    idempotency_key: &str,
) -> CausalContext {
    causal_context_raw(
        ctx,
        trace_id,
        session_id,
        workspace_id,
        &working_directory.display().to_string(),
        provider_invocation_id,
        idempotency_key,
    )
    .await
}

pub async fn causal_context_raw(
    ctx: &ServerRuntimeContext,
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
    working_directory: &str,
    provider_invocation_id: &str,
    idempotency_key: &str,
) -> CausalContext {
    let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
    let grant_id = derive_capability_execute_grant(
        ctx,
        &actor_id,
        trace_id.clone(),
        session_id,
        workspace_id,
        working_directory,
        provider_invocation_id,
        "none",
    )
    .await;
    CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
        .with_scope("capability.execute")
        .with_session_id(session_id.to_owned())
        .with_workspace_id(workspace_id.to_owned())
        .with_idempotency_key(idempotency_key.to_owned())
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            working_directory.to_owned(),
        )
        .with_runtime_metadata(
            RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
            provider_invocation_id,
        )
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run_trace_test")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1")
}

#[allow(clippy::too_many_arguments)]
pub async fn derive_capability_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
    working_directory: &str,
    provider_invocation_id: &str,
    network_policy: &str,
) -> AuthorityGrantId {
    let root = tron::shared::foundation::paths::normalize_working_directory(working_directory)
        .unwrap()
        .display()
        .to_string();
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("grant::derive").unwrap(),
            json!({
                "parentGrantId": "agent-capability-runtime",
                "subjectActorId": actor_id.as_str(),
                "allowedCapabilities": [
                    "capability::execute",
                    "state::get",
                    "state::set",
                    "state::list"
                ],
                "allowedNamespaces": ["__no_namespace_authority__"],
                "allowedAuthorityScopes": [
                    "capability.execute",
                    "state.read",
                    "state.write"
                ],
                "allowedResourceKinds": ["agent_state"],
                "resourceSelectors": ["kind:agent_state"],
                "fileRoots": [root],
                "networkPolicy": network_policy,
                "maxRisk": "medium",
                "budget": {
                    "remainingInvocations": 2,
                    "remainingProcessMs": 120000
                },
                "canDelegate": false,
                "provenance": {
                    "source": "primitive_trace_execution_test",
                    "sessionId": session_id,
                    "workspaceId": workspace_id,
                    "providerInvocationId": provider_invocation_id,
                    "networkPolicy": network_policy,
                    "workingDirectory": root
                }
            }),
            CausalContext::new(
                ActorId::new("system:primitive-trace-test").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("grant").unwrap(),
                trace_id,
            )
            .with_scope("grant.write")
            .with_session_id(session_id.to_owned())
            .with_idempotency_key(format!(
                "derive-capability-grant-{provider_invocation_id}-{network_policy}"
            )),
        ))
        .await;
    assert_eq!(
        result.error, None,
        "grant derivation failed: {:?}",
        result.error
    );
    AuthorityGrantId::new(
        result.value.unwrap()["grant"]["grantId"]
            .as_str()
            .unwrap()
            .to_owned(),
    )
    .unwrap()
}

pub async fn invoke_execute(
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

pub async fn invoke_execute_error(
    ctx: &ServerRuntimeContext,
    payload: Value,
    causal: CausalContext,
) -> String {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            payload,
            causal,
        ))
        .await;
    result.error.expect("capability error").to_string()
}
