use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::AtomicU16;
use std::time::Instant;

use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::sync::Mutex;
use tron::domains::agent::{Orchestrator, ProfileRuntime, SessionManager};
use tron::domains::session::event_store::{
    AgentTraceListOptions, ConnectionConfig, EventStore, new_file, run_migrations,
};
use tron::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use tron::engine::{
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY,
};
use tron::shared::protocol::model_capabilities::CapabilityResult;
use tron::shared::server::context::ServerRuntimeContext;

pub(super) const SCORECARD_PATH: &str =
    "packages/agent/docs/self-adapting-agent-authorship-scorecard.md";
pub(super) const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-adapting-agent-authorship-evidence-manifest.md";
pub(super) const INVENTORY_PATH: &str =
    "packages/agent/docs/self-adapting-agent-authorship-inventory.md";
pub(super) const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-adapting-agent-authorship-inventory.tsv";
pub(super) const INVARIANT_TEST_PATH: &str =
    "packages/agent/tests/self_adapting_agent_authorship_invariants.rs";

pub(super) const INVENTORY_HEADER: &str =
    "id\tpath\tlanguage\tsurface\tcurrent_role\tsaa_rows\tproof\tresidual_risk";

#[derive(Debug, Clone)]
pub(super) struct InventoryRow {
    pub(super) id: String,
    pub(super) path: String,
    pub(super) language: String,
    pub(super) surface: String,
    pub(super) current_role: String,
    pub(super) saa_rows: String,
    pub(super) proof: String,
    pub(super) residual_risk: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ScorecardRow {
    pub(super) row: String,
    pub(super) points: u32,
    pub(super) status: String,
}

pub(super) struct TestRuntime {
    _temp: TempDir,
    pub(super) ctx: ServerRuntimeContext,
}

pub(super) fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

pub(super) fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

pub(super) fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

pub(super) fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

pub(super) fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| SAA-"))
        .map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            assert!(
                columns.len() >= 5,
                "scorecard row must have at least 5 columns: {line}"
            );
            ScorecardRow {
                row: columns[1].to_owned(),
                points: columns[3]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid SAA score in {line}: {error}")),
                status: columns[4].to_owned(),
            }
        })
        .collect()
}

pub(super) fn parse_inventory() -> Vec<InventoryRow> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    let header = lines.next().expect("inventory TSV must have a header");
    assert_eq!(header, INVENTORY_HEADER, "SAA inventory TSV header changed");

    lines
        .enumerate()
        .filter(|(_, line)| !line.trim().is_empty())
        .map(|(index, line)| {
            let columns: Vec<_> = line.split('\t').collect();
            assert_eq!(
                columns.len(),
                8,
                "inventory row {} must have 8 tab-separated columns: {line}",
                index + 2
            );
            InventoryRow {
                id: columns[0].to_owned(),
                path: columns[1].to_owned(),
                language: columns[2].to_owned(),
                surface: columns[3].to_owned(),
                current_role: columns[4].to_owned(),
                saa_rows: columns[5].to_owned(),
                proof: columns[6].to_owned(),
                residual_risk: columns[7].to_owned(),
            }
        })
        .collect()
}

pub(super) fn inventory_by_path() -> BTreeMap<String, Vec<InventoryRow>> {
    let mut rows = BTreeMap::new();
    for row in parse_inventory() {
        rows.entry(row.path.clone())
            .or_insert_with(Vec::new)
            .push(row);
    }
    rows
}

pub(super) fn test_runtime() -> TestRuntime {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join(".tron");
    tron::shared::foundation::constitution::ensure_tron_home_at(&home).unwrap();
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

pub(super) async fn execute_causal_context(
    ctx: &ServerRuntimeContext,
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
    working_directory: &Path,
    provider_invocation_id: &str,
    idempotency_key: &str,
) -> CausalContext {
    let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
    let grant_id = derive_execute_grant(
        ctx,
        &actor_id,
        trace_id.clone(),
        session_id,
        workspace_id,
        working_directory,
        provider_invocation_id,
    )
    .await;
    CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
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
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run_saa_test")
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1")
}

async fn derive_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
    working_directory: &Path,
    provider_invocation_id: &str,
) -> AuthorityGrantId {
    let root = tron::shared::foundation::paths::normalize_working_directory(
        &working_directory.display().to_string(),
    )
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
                    "resource::create",
                    "resource::inspect",
                    "resource::link",
                    "resource::list",
                    "resource::update",
                    "state::get",
                    "state::set",
                    "state::list"
                ],
                "allowedNamespaces": ["__no_namespace_authority__"],
                "allowedAuthorityScopes": [
                    "capability.execute",
                    "resource.read",
                    "resource.write",
                    "state.read",
                    "state.write"
                ],
                "allowedResourceKinds": [
                    "agent_memory",
                    "agent_result",
                    "agent_rule",
                    "artifact",
                    "claim",
                    "decision",
                    "evidence",
                    "execution_output",
                    "goal",
                    "materialized_file",
                    "patch_proposal",
                    "ui_surface"
                ],
                "resourceSelectors": ["*"],
                "fileRoots": [root],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {
                    "remainingInvocations": 2,
                    "remainingProcessMs": 120000
                },
                "canDelegate": false,
                "provenance": {
                    "source": "self_adapting_agent_authorship_test",
                    "sessionId": session_id,
                    "workspaceId": workspace_id,
                    "providerInvocationId": provider_invocation_id,
                    "workingDirectory": root
                }
            }),
            CausalContext::new(
                ActorId::new("system:saa-test").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("grant").unwrap(),
                trace_id,
            )
            .with_scope("grant.write")
            .with_session_id(session_id.to_owned())
            .with_idempotency_key(format!("derive-saa-grant-{provider_invocation_id}")),
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

pub(super) async fn invoke_execute(
    ctx: &ServerRuntimeContext,
    payload: Value,
    causal: CausalContext,
) -> CapabilityResult {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            payload,
            causal,
        ))
        .await;
    assert_eq!(result.error, None, "execute failed: {:?}", result.error);
    serde_json::from_value(result.value.expect("capability result value")).unwrap()
}

pub(super) fn trace_operations(
    runtime: &ServerRuntimeContext,
    session_id: &str,
    trace_id: &TraceId,
) -> Vec<String> {
    runtime
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: Some(session_id),
            trace_id: Some(trace_id.as_str()),
            limit: Some(100),
        })
        .unwrap()
        .into_iter()
        .map(|record| record.operation)
        .collect()
}
