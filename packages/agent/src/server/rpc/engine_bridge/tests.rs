use std::collections::BTreeSet;
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::*;
use crate::core::messages::Provider;
use crate::core::tools::{Tool, ToolCategory, TronToolResult, text_result};
use crate::engine::{
    ActorContext, ActorKind, CausalContext, DeliveryMode, EffectClass, EngineError,
    FunctionDefinition, FunctionId, FunctionQuery, Invocation, RiskLevel, StreamActorScope,
    StreamCursor, TraceId, VisibilityScope,
};
use crate::server::codex_app::{
    CodexAppServerChild, CodexAppServerExit, CodexAppServerLaunchSpec, CodexAppServerManager,
    CodexAppServerSpawner, CodexAppServerState,
};
use crate::server::rpc::bindings;
use crate::server::rpc::registry::MethodRegistry;
use crate::server::rpc::test_support::{make_test_agent_deps, make_test_context};
use crate::server::rpc::types::RpcRequest;
use crate::tools::errors::ToolError;
use crate::tools::traits::{
    ManagedProcessConfig, ManagedProcessHandle, ManagedProcessResult, ProcessInfo, ProcessKind,
    ProcessManagerOps,
};
use crate::tools::traits::{ToolContext, TronTool};

const GENERIC_READ_METHODS: &[&str] = &[
    "system.ping",
    "system.getInfo",
    "system.getDiagnostics",
    "system.checkForUpdates",
    "system.getUpdateStatus",
    "codexApp.status",
    "blob.get",
    "settings.get",
    "model.list",
    "skill.list",
    "skill.get",
    "skill.active",
    "logs.recent",
    "events.getHistory",
    "events.getSince",
    "session.list",
    "session.getHead",
    "session.getState",
    "session.getHistory",
    "session.reconstruct",
    "session.resume",
    "session.export",
    "context.getSnapshot",
    "context.getDetailedSnapshot",
    "context.getAuditTrace",
    "context.shouldCompact",
    "context.previewCompaction",
    "context.canAcceptTurn",
    "agent.status",
    "mcp.status",
    "mcp.listTools",
    "approval.get",
    "approval.list",
    "auth.get",
    "filesystem.listDir",
    "filesystem.getHome",
    "file.read",
    "job.list",
    "notifications.list",
    "plan.getState",
    "promptHistory.list",
    "promptSnippet.list",
    "promptSnippet.get",
    "cron.list",
    "cron.get",
    "cron.status",
    "cron.getRuns",
    "tree.getVisualization",
    "tree.getBranches",
    "tree.getSubtree",
    "tree.getAncestors",
    "tree.compareBranches",
    "repo.listSessions",
    "repo.getDivergence",
    "import.listSources",
    "import.listSessions",
    "import.previewSession",
    "browser.getStatus",
    "voiceNotes.list",
    "transcribe.listModels",
    "sandbox.listContainers",
    "worktree.getStatus",
    "worktree.isGitRepo",
    "worktree.list",
    "worktree.getDiff",
    "worktree.listSessionBranches",
    "worktree.getCommittedDiff",
    "worktree.listConflicts",
    "git.listLocalBranches",
    "git.listRemoteBranches",
];

const GENERIC_WRITE_METHODS: &[&str] = &[
    "logs.ingest",
    "events.append",
    "events.subscribe",
    "events.unsubscribe",
    "system.shutdown",
    "auth.update",
    "auth.clear",
    "auth.oauthBegin",
    "auth.oauthComplete",
    "auth.renameAccount",
    "auth.setActive",
    "auth.removeAccount",
    "auth.removeApiKey",
    "browser.startStream",
    "browser.stopStream",
    "display.stopStream",
    "transcribe.audio",
    "transcribe.downloadModel",
    "device.register",
    "device.unregister",
    "device.respond",
    "voiceNotes.save",
    "voiceNotes.delete",
    "sandbox.startContainer",
    "sandbox.stopContainer",
    "sandbox.killContainer",
    "sandbox.removeContainer",
    "session.create",
    "session.delete",
    "session.fork",
    "session.archive",
    "session.unarchive",
    "session.archiveOlderThan",
    "agent.prompt",
    "agent.abort",
    "agent.abortTool",
    "agent.queuePrompt",
    "agent.dequeuePrompt",
    "agent.clearQueue",
    "agent.deliverSubagentResults",
    "agent.submitConfirmation",
    "agent.submitAnswers",
    "mcp.addServer",
    "mcp.removeServer",
    "mcp.enableServer",
    "mcp.disableServer",
    "mcp.restartServer",
    "mcp.reload",
    "context.confirmCompaction",
    "context.clear",
    "context.compact",
    "job.background",
    "job.cancel",
    "approval.resolve",
    "settings.update",
    "settings.resetToDefaults",
    "skill.refresh",
    "skill.activate",
    "skill.deactivate",
    "filesystem.createDir",
    "job.subscribe",
    "job.unsubscribe",
    "notifications.markRead",
    "notifications.markAllRead",
    "plan.enter",
    "plan.exit",
    "promptHistory.delete",
    "promptHistory.clear",
    "promptSnippet.create",
    "promptSnippet.update",
    "promptSnippet.delete",
    "tool.result",
    "message.delete",
    "cron.create",
    "cron.update",
    "cron.delete",
    "cron.run",
    "model.switch",
    "config.setReasoningLevel",
    "memory.retain",
    "import.execute",
    "git.clone",
    "git.syncMain",
    "git.push",
    "worktree.acquire",
    "worktree.release",
    "worktree.stageFiles",
    "worktree.unstageFiles",
    "worktree.commit",
    "worktree.merge",
    "worktree.finalizeSession",
    "worktree.deleteBranch",
    "worktree.pruneBranches",
    "worktree.discardFiles",
    "worktree.rebaseOnMain",
    "worktree.startMerge",
    "worktree.resolveConflict",
    "worktree.continueMerge",
    "worktree.abortMerge",
    "worktree.resolveConflictsWithSubagent",
];

const ENGINE_TRANSPORT_METHODS: &[&str] = &[
    "engine.discover",
    "engine.inspect",
    "engine.watch",
    "engine.invoke",
    "engine.promote",
];

const SETTINGS_METHODS: &[&str] = &[
    "settings.get",
    "settings.update",
    "settings.resetToDefaults",
];

const LOGS_METHODS: &[&str] = &["logs.ingest", "logs.recent"];

const MCP_METHODS: &[&str] = &[
    "mcp.status",
    "mcp.addServer",
    "mcp.removeServer",
    "mcp.enableServer",
    "mcp.disableServer",
    "mcp.restartServer",
    "mcp.reload",
    "mcp.listTools",
];

const SKILL_METHODS: &[&str] = &[
    "skill.list",
    "skill.get",
    "skill.refresh",
    "skill.activate",
    "skill.deactivate",
    "skill.active",
];

const FILESYSTEM_ENGINE_METHODS: &[&str] = &[
    "filesystem.getHome",
    "filesystem.listDir",
    "filesystem.createDir",
    "file.read",
];

const SESSION_METHODS: &[&str] = &[
    "session.list",
    "session.getHead",
    "session.getState",
    "session.getHistory",
    "session.reconstruct",
    "session.create",
    "session.delete",
    "session.fork",
    "session.archive",
    "session.unarchive",
    "session.archiveOlderThan",
    "session.export",
];

const CONTEXT_READ_METHODS: &[&str] = &[
    "context.getSnapshot",
    "context.getDetailedSnapshot",
    "context.getAuditTrace",
    "context.shouldCompact",
    "context.previewCompaction",
    "context.canAcceptTurn",
];

const CONTEXT_COMMAND_METHODS: &[&str] = &[
    "context.confirmCompaction",
    "context.clear",
    "context.compact",
];

const AGENT_QUEUE_METHODS: &[&str] = &[
    "agent.queuePrompt",
    "agent.dequeuePrompt",
    "agent.clearQueue",
];

const JOB_METHODS: &[&str] = &[
    "job.background",
    "job.cancel",
    "job.list",
    "job.subscribe",
    "job.unsubscribe",
];

const NOTIFICATION_METHODS: &[&str] = &[
    "notifications.list",
    "notifications.markRead",
    "notifications.markAllRead",
];

const PLAN_METHODS: &[&str] = &["plan.enter", "plan.exit", "plan.getState"];

const PROMPT_LIBRARY_METHODS: &[&str] = &[
    "promptHistory.list",
    "promptHistory.delete",
    "promptHistory.clear",
    "promptSnippet.list",
    "promptSnippet.get",
    "promptSnippet.create",
    "promptSnippet.update",
    "promptSnippet.delete",
];

const CRON_METHODS: &[&str] = &[
    "cron.list",
    "cron.get",
    "cron.create",
    "cron.update",
    "cron.delete",
    "cron.run",
    "cron.status",
    "cron.getRuns",
];

const RUNTIME_TAIL_METHODS: &[&str] = &[
    "system.getDiagnostics",
    "system.getUpdateStatus",
    "codexApp.status",
    "blob.get",
    "tool.result",
    "message.delete",
];

const HIGH_RISK_COMMAND_METHODS: &[&str] = &[
    "model.switch",
    "config.setReasoningLevel",
    "memory.retain",
    "import.execute",
];

const GIT_WORKTREE_METHODS: &[&str] = &[
    "git.clone",
    "git.syncMain",
    "git.push",
    "git.listLocalBranches",
    "git.listRemoteBranches",
    "worktree.getStatus",
    "worktree.isGitRepo",
    "worktree.commit",
    "worktree.merge",
    "worktree.list",
    "worktree.getDiff",
    "worktree.acquire",
    "worktree.release",
    "worktree.listSessionBranches",
    "worktree.getCommittedDiff",
    "worktree.finalizeSession",
    "worktree.deleteBranch",
    "worktree.pruneBranches",
    "worktree.stageFiles",
    "worktree.unstageFiles",
    "worktree.discardFiles",
    "worktree.rebaseOnMain",
    "worktree.startMerge",
    "worktree.listConflicts",
    "worktree.resolveConflict",
    "worktree.continueMerge",
    "worktree.abortMerge",
    "worktree.resolveConflictsWithSubagent",
];

const SAFE_READ_COLLAPSE_METHODS: &[&str] = &[
    "tree.getVisualization",
    "tree.getBranches",
    "tree.getSubtree",
    "tree.getAncestors",
    "tree.compareBranches",
    "repo.listSessions",
    "repo.getDivergence",
    "import.listSources",
    "import.listSessions",
    "import.previewSession",
    "browser.getStatus",
    "voiceNotes.list",
    "transcribe.listModels",
    "sandbox.listContainers",
];

const MIGRATION_PARITY_TIMEOUT: Duration = Duration::from_secs(180);

fn migration_parity_registry() -> MethodRegistry {
    let mut registry = MethodRegistry::with_transport_timeout(MIGRATION_PARITY_TIMEOUT);
    bindings::register_all(&mut registry);
    registry
}

fn make_prompt_context() -> crate::server::rpc::context::RpcContext {
    let mut ctx = make_test_context();
    ctx.agent_deps = Some(make_test_agent_deps());
    let registry = migration_parity_registry();
    super::register_rpc_worker_for_context(&ctx, &registry).unwrap();
    ctx
}

fn make_cron_context() -> (crate::server::rpc::context::RpcContext, tempfile::TempDir) {
    let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        crate::events::run_migrations(&conn).unwrap();
    }

    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("automations.json");
    let backup_path = dir.path().join("automations.json.bak");

    let cancel = tokio_util::sync::CancellationToken::new();
    let deps = crate::cron::ExecutorDeps {
        agent_executor: None,
        broadcaster: std::sync::OnceLock::new(),
        push_notifier: None,
        event_injector: None,
        http_client: reqwest::Client::new(),
        pool: pool.clone(),
    };

    let scheduler = Arc::new(crate::cron::CronScheduler::new(
        pool.clone(),
        Arc::new(crate::cron::SystemClock),
        deps,
        config_path,
        backup_path,
        cancel,
    ));

    let mut ctx = make_test_context();
    ctx.cron_scheduler = Some(scheduler);
    let registry = migration_parity_registry();
    register_rpc_worker_for_context(&ctx, &registry).unwrap();
    ctx.cron_scheduler
        .as_ref()
        .unwrap()
        .set_engine_host(ctx.engine_host.clone());
    (ctx, dir)
}

async fn dispatch_ok(
    ctx: &crate::server::rpc::context::RpcContext,
    method: &str,
    params: Option<Value>,
) -> Value {
    let registry = migration_parity_registry();
    let response = registry
        .dispatch(
            RpcRequest {
                id: format!("test-{method}"),
                method: method.to_owned(),
                params,
            },
            ctx,
        )
        .await;
    assert!(response.success, "{method}: {:?}", response.error);
    response.result.unwrap()
}

struct SettingsTestGuard {
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl Drop for SettingsTestGuard {
    fn drop(&mut self) {
        crate::settings::init_settings(crate::settings::TronSettings::default());
    }
}

fn settings_test_guard() -> SettingsTestGuard {
    let guard = crate::settings::test_settings_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    crate::settings::init_settings(crate::settings::TronSettings::default());
    SettingsTestGuard { _guard: guard }
}

#[derive(Default)]
struct SettingsFakeSpawner {
    specs: Mutex<Vec<CodexAppServerLaunchSpec>>,
}

#[async_trait]
impl CodexAppServerSpawner for SettingsFakeSpawner {
    async fn spawn(
        &self,
        spec: CodexAppServerLaunchSpec,
    ) -> io::Result<Box<dyn CodexAppServerChild>> {
        self.specs.lock().unwrap().push(spec);
        Ok(Box::new(SettingsFakeChild))
    }
}

struct SettingsFakeChild;

#[async_trait]
impl CodexAppServerChild for SettingsFakeChild {
    fn id(&self) -> Option<u32> {
        Some(456)
    }

    fn try_wait(&mut self) -> io::Result<Option<CodexAppServerExit>> {
        Ok(None)
    }

    async fn terminate(&mut self, _timeout: Duration) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Default)]
struct QueueJobFakeProcessManager {
    promoted: Mutex<Vec<String>>,
    cancelled: Mutex<Vec<(String, bool)>>,
    processes: Mutex<Vec<ProcessInfo>>,
}

struct EngineCatalogSearchTool;
struct DynamicCatalogTool;

#[async_trait]
impl TronTool for EngineCatalogSearchTool {
    fn name(&self) -> &str {
        "Search"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Search
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "Search".to_owned(),
            description: "Test search tool".to_owned(),
            parameters: crate::core::tools::ToolParameterSchema {
                schema_type: "object".to_owned(),
                properties: None,
                required: None,
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        Ok(text_result(
            format!("searched {}", params["query"].as_str().unwrap_or_default()),
            false,
        ))
    }
}

#[async_trait]
impl TronTool for DynamicCatalogTool {
    fn name(&self) -> &str {
        "Dynamic"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "Dynamic".to_owned(),
            description: "Dynamically registered catalog tool".to_owned(),
            parameters: crate::core::tools::ToolParameterSchema {
                schema_type: "object".to_owned(),
                properties: None,
                required: None,
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(
        &self,
        _params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        Ok(text_result("dynamic", false))
    }
}

#[async_trait]
impl ProcessManagerOps for QueueJobFakeProcessManager {
    async fn spawn_managed(
        &self,
        _session_id: &str,
        _tool_call_id: &str,
        _config: ManagedProcessConfig,
        _task: std::pin::Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>>,
    ) -> Result<ManagedProcessHandle, ToolError> {
        Ok(ManagedProcessHandle {
            process_id: "unused".to_owned(),
            result: None,
            backgrounded: None,
        })
    }

    fn promote_to_background(&self, process_id: &str) -> Result<(), ToolError> {
        self.promoted.lock().unwrap().push(process_id.to_owned());
        Ok(())
    }

    fn cancel_process(&self, process_id: &str, user_initiated: bool) -> Result<(), ToolError> {
        self.cancelled
            .lock()
            .unwrap()
            .push((process_id.to_owned(), user_initiated));
        Ok(())
    }

    fn list_processes(&self, session_id: &str) -> Vec<ProcessInfo> {
        self.processes
            .lock()
            .unwrap()
            .iter()
            .filter(|process| process.session_id == session_id)
            .cloned()
            .collect()
    }

    fn get_result(&self, _process_id: &str) -> Option<ManagedProcessResult> {
        None
    }

    fn find_by_label(&self, _session_id: &str, _label_prefix: &str) -> Option<String> {
        None
    }

    fn cancel_session_processes(&self, _session_id: &str) {}

    fn cancel_all(&self) {}

    async fn wait_for_process(
        &self,
        process_id: &str,
        _timeout_ms: u64,
    ) -> Result<ManagedProcessResult, ToolError> {
        Err(ToolError::Validation {
            message: format!("process {process_id} was not started by this test"),
        })
    }
}

fn attach_codex_manager(
    ctx: &mut crate::server::rpc::context::RpcContext,
    token_dir: &tempfile::TempDir,
) -> (Arc<CodexAppServerManager>, Arc<SettingsFakeSpawner>) {
    let spawner = Arc::new(SettingsFakeSpawner::default());
    let manager = Arc::new(
        CodexAppServerManager::with_deps(
            crate::settings::CodexAppServerSettings::default(),
            token_dir.path().join("codex-token"),
            spawner.clone(),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap(),
    );
    ctx.codex_app_server = Some(manager.clone());
    (manager, spawner)
}

fn write_import_sample_session(dir: &std::path::Path) -> std::path::PathBuf {
    let file = dir.join("test-session-uuid.jsonl");
    let mut writer = std::fs::File::create(&file).unwrap();
    writeln!(
        writer,
        "{}",
        json!({
            "type": "user",
            "uuid": "u1",
            "timestamp": "2026-01-01T00:00:00Z",
            "promptId": "p1",
            "message": {"role": "user", "content": "Hello"}
        })
    )
    .unwrap();
    writeln!(
        writer,
        "{}",
        json!({
            "type": "assistant",
            "uuid": "a1",
            "parentUuid": "u1",
            "timestamp": "2026-01-01T00:00:01Z",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "content": [{"type": "text", "text": "Hi"}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 10, "output_tokens": 5},
                "model": "claude-opus-4-6"
            }
        })
    )
    .unwrap();
    writeln!(
        writer,
        "{}",
        json!({
            "type": "custom-title",
            "uuid": "ct1",
            "customTitle": "Imported",
            "sessionId": "s1"
        })
    )
    .unwrap();
    file
}

async fn direct_engine_value(ctx: &RpcContext, method: &'static str, params: Value) -> Value {
    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: format!("direct-{method}"),
        method: method.to_owned(),
        params: Some(params),
    };
    let envelope = RpcEngineInvocation::from_request(&registry, ctx, &request)
        .unwrap()
        .unwrap();
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            envelope.function_id,
            envelope.params_payload,
            envelope.causal_context,
        ))
        .await;
    assert!(result.error.is_none(), "{method}: {:?}", result.error);
    result.value.unwrap()
}

async fn direct_engine_error_body(ctx: &RpcContext, method: &'static str, params: Value) -> Value {
    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: format!("direct-{method}"),
        method: method.to_owned(),
        params: Some(params),
    };
    let envelope = RpcEngineInvocation::from_request(&registry, ctx, &request)
        .unwrap()
        .unwrap();
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            envelope.function_id,
            envelope.params_payload,
            envelope.causal_context,
        ))
        .await;
    let error = result_to_rpc(result).expect_err("direct engine invocation should fail");
    let mut body = error.to_error_body();
    body.message = crate::server::rpc::validation::sanitize_error_message(&error);
    serde_json::to_value(body).unwrap()
}

async fn rpc_dispatch_value(ctx: &RpcContext, method: &str, params: Value) -> Value {
    let registry = migration_parity_registry();
    let response = registry
        .dispatch(
            RpcRequest {
                id: format!("test-{method}"),
                method: method.to_owned(),
                params: Some(params),
            },
            ctx,
        )
        .await;
    assert!(response.success, "{method}: {:?}", response.error);
    response.result.unwrap()
}

async fn rpc_dispatch_error_body(ctx: &RpcContext, method: &str, params: Value) -> Value {
    let registry = migration_parity_registry();
    let response = registry
        .dispatch(
            RpcRequest {
                id: format!("test-{method}"),
                method: method.to_owned(),
                params: Some(params),
            },
            ctx,
        )
        .await;
    assert!(!response.success, "{method}: {:?}", response.result);
    serde_json::to_value(response.error.unwrap()).unwrap()
}

fn normalize_unstable_fields(method: &str, mut value: Value) -> Value {
    if method == "system.ping" {
        value["timestamp"] = json!("<timestamp>");
    }
    if method == "system.getInfo" {
        value["uptime"] = json!(0);
    }
    if method == "system.getDiagnostics" {
        value["server"]["uptimeSeconds"] = json!(0);
        value["timestamp"] = json!("<timestamp>");
    }
    if method == "session.create" {
        value["sessionId"] = json!("<session>");
        value["createdAt"] = json!("<createdAt>");
    }
    if method == "agent.queuePrompt" {
        value["queueId"] = json!("<queue>");
        value["timestamp"] = json!("<timestamp>");
    }
    if method == "agent.prompt" {
        value["runId"] = json!("<run>");
    }
    if method == "cron.create" || method == "cron.update" {
        value["job"]["id"] = json!("<cron>");
        value["job"]["createdAt"] = json!("<created>");
        value["job"]["updatedAt"] = json!("<updated>");
    }
    if method.starts_with("cron.") {
        normalize_cron_ids(&mut value);
    }
    if method == "cron.run" {
        value["jobId"] = json!("<cron>");
    }
    if method == "message.delete" {
        value["deletionEventId"] = json!("<deletion>");
    }
    value
}

fn normalize_cron_ids(value: &mut Value) {
    match value {
        Value::Array(values) => {
            for value in values {
                normalize_cron_ids(value);
            }
        }
        Value::Object(object) => {
            for (key, value) in object.iter_mut() {
                if matches!(key.as_str(), "id" | "jobId")
                    && value.as_str().is_some_and(|id| id.starts_with("cron_"))
                {
                    *value = json!("<cron>");
                } else if matches!(key.as_str(), "createdAt" | "updatedAt") {
                    *value = json!("<timestamp>");
                } else {
                    normalize_cron_ids(value);
                }
            }
        }
        _ => {}
    }
}

fn domain_scope_for_method(method: &str) -> &'static str {
    let registry = migration_parity_registry();
    let spec = specs::json_rpc_alias_for_method(&registry, method)
        .unwrap()
        .unwrap();
    spec.authority_scope.unwrap()
}

fn rpc_and_domain_context(
    method: &str,
    transport_scope: &'static str,
) -> crate::engine::CausalContext {
    super::dispatch::rpc_causal_context_for_scope(transport_scope)
        .with_scope(domain_scope_for_method(method))
}

fn assert_scope(scopes: &[String], scope: &str) {
    assert!(
        scopes.contains(&scope.to_owned()),
        "expected scope {scope} in {scopes:?}"
    );
}

#[test]
fn transport_bindings_cover_every_registered_rpc_method() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    assert_eq!(registry.methods().len(), 175);
    assert_eq!(specs.len(), registry.methods().len());

    let spec_methods = specs
        .iter()
        .map(|spec| spec.method.to_owned())
        .collect::<BTreeSet<_>>();
    let registry_methods = registry.methods().into_iter().collect::<BTreeSet<_>>();
    assert_eq!(spec_methods, registry_methods);
    assert_eq!(
        GENERIC_READ_METHODS.len() + GENERIC_WRITE_METHODS.len() + ENGINE_TRANSPORT_METHODS.len(),
        175
    );
    for method in GENERIC_READ_METHODS
        .iter()
        .chain(GENERIC_WRITE_METHODS.iter())
        .chain(ENGINE_TRANSPORT_METHODS.iter())
    {
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered now that the RPC surface is fully engine-owned"
        );
    }
}

#[test]
fn engine_function_modules_do_not_use_rpc_handler_adapters() {
    fn rust_files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                rust_files(&path, out);
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                out.push(path);
            }
        }
    }

    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/server/capabilities");
    let mut files = Vec::new();
    rust_files(&root, &mut files);
    assert!(!files.is_empty());

    for path in files {
        let source = std::fs::read_to_string(&path).unwrap();
        assert!(
            !source.contains("MethodHandler"),
            "{} must not implement or import RPC MethodHandler; engine functions are plain domain functions",
            path.display()
        );
        assert!(
            !source.contains(".handle("),
            "{} must not call old RPC handler adapters from canonical engine functions",
            path.display()
        );
    }
}

#[test]
fn shared_rpc_helpers_live_outside_handler_namespace() {
    let rpc_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/server/rpc");
    for removed in [
        "handlers/params.rs",
        "handlers/error_mapping.rs",
        "handlers/events.rs",
        "handlers/skill_session.rs",
        "handlers/model.rs",
        "handlers/memory.rs",
        "handlers/memory/auto_retain.rs",
        "handlers/agent_prompt_runtime.rs",
        "handlers/agent_prompt_service.rs",
    ] {
        assert!(
            !rpc_root.join(removed).exists(),
            "{removed} is shared production code and must not live under handlers/"
        );
    }
    for present in [
        "params.rs",
        "error_mapping.rs",
        "events_wire.rs",
        "skill_state.rs",
        "model_catalog.rs",
        "memory_retain/mod.rs",
        "memory_retain/auto_retain.rs",
        "agent_runtime/runtime.rs",
        "agent_runtime/service.rs",
    ] {
        assert!(
            rpc_root.join(present).exists(),
            "{present} should own the shared production behavior"
        );
    }
    for helper in [
        "events_wire.rs",
        "skill_state.rs",
        "model_catalog.rs",
        "memory_retain/mod.rs",
        "agent_runtime/runtime.rs",
        "agent_runtime/service.rs",
    ] {
        let source = std::fs::read_to_string(rpc_root.join(helper)).unwrap();
        assert!(
            !source.contains("impl MethodHandler"),
            "{helper} is shared production code and must expose plain domain functions, not MethodHandler adapters"
        );
    }
}

#[test]
fn production_handler_namespace_contains_no_method_specific_handlers() {
    let handlers_root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/server/rpc/handlers");
    assert!(
        !handlers_root.exists(),
        "server/rpc/handlers must stay deleted; JSON-RPC is a transport binding over canonical capabilities"
    );
}

#[test]
fn transport_specs_expose_canonical_engine_api_methods() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in ENGINE_TRANSPORT_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert_eq!(spec.owner_worker, specs::worker_id("engine").unwrap());
        assert_eq!(spec.domain_worker, specs::worker_id("engine").unwrap());
        assert_eq!(
            spec.function_id,
            specs::function_id_for_method(method).unwrap()
        );
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert!(registry.is_transport_binding(method));
        assert!(crate::server::capabilities::schemas::request_schema_for_method(method).is_some());
        assert!(crate::server::capabilities::schemas::response_schema_for_method(method).is_some());
    }

    let invoke = specs
        .iter()
        .find(|spec| spec.method == "engine.invoke")
        .unwrap();
    assert_eq!(invoke.effect_class, EffectClass::DelegatedInvocation);
    assert_eq!(invoke.risk_level, RiskLevel::Low);
    assert_eq!(invoke.transport_authority_scope, Some(RPC_READ_AUTHORITY));
    assert_eq!(invoke.authority_scope, Some("engine.read"));
    assert_eq!(invoke.idempotency_mode, JsonRpcIdempotencyMode::NotRequired);

    let promote = specs
        .iter()
        .find(|spec| spec.method == "engine.promote")
        .unwrap();
    assert_eq!(promote.effect_class, EffectClass::IdempotentWrite);
    assert_eq!(promote.risk_level, RiskLevel::Medium);
    assert_eq!(promote.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
    assert_eq!(promote.authority_scope, Some("engine.promote.workspace"));
    assert_eq!(
        promote.idempotency_mode,
        JsonRpcIdempotencyMode::ExplicitRequired
    );
}

#[tokio::test]
async fn engine_json_rpc_transport_methods_route_to_meta_capabilities() {
    let ctx = make_test_context();
    let discovered = rpc_dispatch_value(&ctx, "engine.discover", json!({})).await;
    assert!(
        discovered["functions"]
            .as_array()
            .is_some_and(|functions| functions
                .iter()
                .any(|function| function["id"] == "system::ping")),
        "engine.discover must expose canonical ids, got {discovered:?}"
    );

    let inspected = rpc_dispatch_value(
        &ctx,
        "engine.inspect",
        json!({"kind": "function", "id": "system::ping"}),
    )
    .await;
    assert_eq!(inspected["definition"]["id"], "system::ping");

    let invoked = rpc_dispatch_value(
        &ctx,
        "engine.invoke",
        json!({
            "functionId": "system::ping",
            "payload": {"protocolVersion": 1}
        }),
    )
    .await;
    assert_eq!(invoked["child"]["value"]["pong"], true);

    let rejected = rpc_dispatch_error_body(
        &ctx,
        "engine.invoke",
        json!({
            "functionId": "rpc::system.ping",
            "payload": {"protocolVersion": 1}
        }),
    )
    .await;
    assert_eq!(rejected["code"], errors::INVALID_PARAMS);
}

#[test]
fn transport_bindings_classify_selected_reads_as_generic_triggers() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    for method in GENERIC_READ_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert_eq!(spec.effect_class, EffectClass::PureRead);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.transport_authority_scope, Some(RPC_READ_AUTHORITY));
        assert!(
            spec.authority_scope
                .is_some_and(|scope| scope.ends_with(".read")),
            "{method} must require a domain read scope"
        );
        assert!(
            crate::server::capabilities::schemas::request_schema_for_method(method).is_some(),
            "{method} must declare a request schema"
        );
        assert!(
            crate::server::capabilities::schemas::response_schema_for_method(method).is_some(),
            "{method} must declare a response schema"
        );
    }
}

#[test]
fn transport_bindings_classify_generic_writes_as_generic_triggers() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    for method in GENERIC_WRITE_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert!(spec.effect_class.is_mutating());
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
        let expected_write_scope = if *method == "approval.resolve" {
            Some("approval.resolve")
        } else {
            spec.authority_scope
                .filter(|scope| scope.ends_with(".write"))
        };
        assert!(
            expected_write_scope.is_some(),
            "{method} must require a domain write scope"
        );
        assert_eq!(
            spec.idempotency_mode,
            JsonRpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        assert!(
            crate::server::capabilities::schemas::request_schema_for_method(method).is_some(),
            "{method} must declare a request schema"
        );
        assert!(
            crate::server::capabilities::schemas::response_schema_for_method(method).is_some(),
            "{method} must declare a response schema"
        );
    }

    let delete = specs
        .iter()
        .find(|spec| spec.method == "promptSnippet.delete")
        .unwrap();
    assert_eq!(delete.effect_class, EffectClass::IrreversibleSideEffect);
    let definition = specs::function_definition_for_alias(delete);
    assert!(definition.required_authority.approval_required);
}

#[test]
fn transport_bindings_classify_agent_prompt_as_queue_backed_engine_prompt() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    let spec = specs
        .iter()
        .find(|spec| spec.method == "agent.prompt")
        .unwrap();
    assert_eq!(spec.function_id, FunctionId::new("agent::prompt").unwrap());
    assert_eq!(spec.owner_worker, specs::worker_id("agent").unwrap());
    assert_eq!(spec.effect_class, EffectClass::ExternalSideEffect);
    assert_eq!(spec.risk_level, RiskLevel::High);
    assert_eq!(spec.visibility, VisibilityScope::System);
    assert_eq!(spec.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
    assert_eq!(spec.authority_scope, Some("agent.write"));
    assert_eq!(
        spec.idempotency_mode,
        JsonRpcIdempotencyMode::JsonRpcRequestIdSeed
    );
    assert!(
        crate::server::capabilities::schemas::request_schema_for_method("agent.prompt").is_some()
    );
    assert!(
        crate::server::capabilities::schemas::response_schema_for_method("agent.prompt").is_some()
    );
    let definition = specs::function_definition_for_alias(spec);
    assert!(definition.required_authority.approval_required);
    assert_eq!(
        definition
            .idempotency
            .as_ref()
            .unwrap()
            .dedupe_scope
            .as_str(),
        "session"
    );
    assert!(
        registry.is_transport_binding("agent.prompt"),
        "agent.prompt must be alias-registered, not a method-specific business handler"
    );
}

#[test]
fn transport_bindings_classify_prompt_library_as_fully_generic_triggered() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in PROMPT_LIBRARY_METHODS {
        assert!(specs.iter().any(|spec| spec.method == *method));
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
    }
}

#[test]
fn transport_bindings_classify_prompt_history_writes_as_guarded_irreversible_triggers() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    for method in ["promptHistory.delete", "promptHistory.clear"] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert_eq!(spec.effect_class, EffectClass::IrreversibleSideEffect);
        assert_eq!(spec.risk_level, RiskLevel::High);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
        assert_eq!(spec.authority_scope, Some("prompt_library.write"));
        assert_eq!(
            spec.idempotency_mode,
            JsonRpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        assert!(crate::server::capabilities::schemas::request_schema_for_method(method).is_some());
        assert!(crate::server::capabilities::schemas::response_schema_for_method(method).is_some());
        let definition = specs::function_definition_for_alias(spec);
        assert!(definition.required_authority.approval_required);
    }
}

#[test]
fn transport_bindings_classify_settings_as_fully_generic_triggered() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in SETTINGS_METHODS {
        assert!(specs.iter().any(|spec| spec.method == *method));
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
    }
}

#[test]
fn transport_bindings_classify_settings_writes_as_guarded_reversible_triggers() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    for method in ["settings.update", "settings.resetToDefaults"] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert_eq!(spec.effect_class, EffectClass::ReversibleSideEffect);
        assert_eq!(spec.risk_level, RiskLevel::High);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
        assert_eq!(spec.authority_scope, Some("settings.write"));
        assert_eq!(
            spec.idempotency_mode,
            JsonRpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        assert!(crate::server::capabilities::schemas::request_schema_for_method(method).is_some());
        assert!(crate::server::capabilities::schemas::response_schema_for_method(method).is_some());
        let definition = specs::function_definition_for_alias(spec);
        assert!(definition.required_authority.approval_required);
        assert_eq!(
            definition
                .idempotency
                .as_ref()
                .map(|contract| contract.dedupe_scope.clone()),
            Some(VisibilityScope::System)
        );
    }
}

#[test]
fn transport_bindings_classify_logs_as_fully_generic_triggered() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in LOGS_METHODS {
        assert!(specs.iter().any(|spec| spec.method == *method));
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
    }
}

#[test]
fn transport_bindings_classify_logs_ingest_as_guarded_append_only_trigger() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    let spec = specs
        .iter()
        .find(|spec| spec.method == "logs.ingest")
        .unwrap();
    assert_eq!(spec.effect_class, EffectClass::AppendOnlyEvent);
    assert_eq!(spec.risk_level, RiskLevel::Medium);
    assert_eq!(spec.visibility, VisibilityScope::System);
    assert_eq!(spec.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
    assert_eq!(spec.authority_scope, Some("logs.write"));
    assert_eq!(
        spec.idempotency_mode,
        JsonRpcIdempotencyMode::JsonRpcRequestIdSeed
    );
    assert!(
        crate::server::capabilities::schemas::request_schema_for_method("logs.ingest").is_some()
    );
    assert!(
        crate::server::capabilities::schemas::response_schema_for_method("logs.ingest").is_some()
    );
    let definition = specs::function_definition_for_alias(spec);
    assert_eq!(
        definition
            .idempotency
            .as_ref()
            .map(|contract| contract.dedupe_scope.clone()),
        Some(VisibilityScope::System)
    );
    assert!(!definition.required_authority.approval_required);
}

#[test]
fn transport_bindings_classify_mcp_as_fully_generic_triggered() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in MCP_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert_eq!(spec.owner_worker, specs::worker_id("mcp").unwrap());
        assert_eq!(spec.domain_worker, specs::worker_id("mcp").unwrap());
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
        assert!(crate::server::capabilities::schemas::request_schema_for_method(method).is_some());
        assert!(crate::server::capabilities::schemas::response_schema_for_method(method).is_some());
    }
}

#[test]
fn transport_bindings_classify_mcp_writes_as_guarded_external_side_effects() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    for method in [
        "mcp.addServer",
        "mcp.removeServer",
        "mcp.enableServer",
        "mcp.disableServer",
        "mcp.restartServer",
        "mcp.reload",
    ] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert_eq!(spec.effect_class, EffectClass::ExternalSideEffect);
        assert_eq!(spec.risk_level, RiskLevel::Medium);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
        assert_eq!(spec.authority_scope, Some("mcp.write"));
        assert_eq!(
            spec.idempotency_mode,
            JsonRpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        let definition = specs::function_definition_for_alias(spec);
        assert!(definition.required_authority.approval_required);
        assert_eq!(
            definition
                .idempotency
                .as_ref()
                .map(|contract| contract.dedupe_scope.clone()),
            Some(VisibilityScope::System)
        );
    }
}

#[test]
fn transport_bindings_classify_new_domain_groups_as_generic_triggered() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    for method in SKILL_METHODS
        .iter()
        .chain(FILESYSTEM_ENGINE_METHODS)
        .chain(SESSION_METHODS)
        .chain(CONTEXT_READ_METHODS)
        .chain(CONTEXT_COMMAND_METHODS)
        .chain(AGENT_QUEUE_METHODS)
        .chain(JOB_METHODS)
        .chain(NOTIFICATION_METHODS)
        .chain(PLAN_METHODS)
        .chain(SAFE_READ_COLLAPSE_METHODS)
        .chain(["events.append", "events.subscribe", "events.unsubscribe"].iter())
    {
        assert!(specs.iter().any(|spec| spec.method == *method));
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
        assert!(crate::server::capabilities::schemas::request_schema_for_method(method).is_some());
        assert!(crate::server::capabilities::schemas::response_schema_for_method(method).is_some());
    }
}

#[test]
fn transport_bindings_classify_cron_as_fully_generic_triggered() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in CRON_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert_eq!(spec.owner_worker, specs::worker_id("cron").unwrap());
        assert_eq!(spec.domain_worker, specs::worker_id("cron").unwrap());
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
        assert!(crate::server::capabilities::schemas::request_schema_for_method(method).is_some());
        assert!(crate::server::capabilities::schemas::response_schema_for_method(method).is_some());
    }
}

#[test]
fn transport_bindings_classify_cron_writes_as_guarded_trigger_capabilities() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in ["cron.create", "cron.update", "cron.delete", "cron.run"] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert!(spec.effect_class.is_mutating());
        assert_eq!(spec.risk_level, RiskLevel::High);
        assert_eq!(spec.visibility, VisibilityScope::System);
        assert_eq!(spec.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
        assert_eq!(spec.authority_scope, Some("cron.write"));
        assert_eq!(
            spec.idempotency_mode,
            JsonRpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        let definition = specs::function_definition_for_alias(spec);
        assert!(definition.required_authority.approval_required);
        assert_eq!(
            definition
                .idempotency
                .as_ref()
                .map(|contract| contract.dedupe_scope.clone()),
            Some(VisibilityScope::System)
        );
    }
}

#[tokio::test]
async fn cron_registers_schedule_trigger_type_and_live_job_triggers() {
    let (ctx, _dir) = make_cron_context();
    let registry = migration_parity_registry();
    register_rpc_worker_for_context(&ctx, &registry).unwrap();

    let trigger_type = ctx
        .engine_host
        .inspect_trigger_type(&crate::engine::TriggerTypeId::new("cron_schedule").unwrap())
        .await
        .unwrap();
    assert_eq!(trigger_type.owner_worker, specs::worker_id("cron").unwrap());
    assert_eq!(trigger_type.visibility, VisibilityScope::Internal);

    let created = dispatch_ok(
        &ctx,
        "cron.create",
        Some(json!({
            "job": {
                "name": "Projected",
                "schedule": {"type": "every", "intervalSecs": 60},
                "payload": {"type": "shellCommand", "command": "echo hi"}
            }
        })),
    )
    .await;
    let job_id = created["job"]["id"].as_str().unwrap();

    let trigger = ctx
        .engine_host
        .inspect_trigger(&crate::engine::TriggerId::new(format!("cron_schedule:{job_id}")).unwrap())
        .await
        .expect("created cron jobs should be projected into live trigger definitions");
    assert_eq!(trigger.owner_worker, specs::worker_id("cron").unwrap());
    assert_eq!(
        trigger.target_function,
        FunctionId::new("cron::scheduled_fire").unwrap()
    );
    assert_eq!(trigger.config["jobName"], "Projected");
    let system_actor = ActorContext::new(
        crate::engine::ActorId::new("system").unwrap(),
        ActorKind::System,
        crate::engine::AuthorityGrantId::new("system").unwrap(),
    );
    let hidden = ctx
        .engine_host
        .inspect_function(
            &FunctionId::new("cron::scheduled_fire").unwrap(),
            Some(&system_actor),
        )
        .await
        .unwrap();
    assert_eq!(hidden.visibility, VisibilityScope::Internal);
    assert!(
        hidden.metadata["hiddenCronScheduleFunction"]
            .as_bool()
            .unwrap()
    );
}

#[tokio::test]
async fn cron_schedule_trigger_dispatch_records_ledger_and_replays_duplicate_fire() {
    let (ctx, _dir) = make_cron_context();
    let created = dispatch_ok(
        &ctx,
        "cron.create",
        Some(json!({
            "job": {
                "name": "Scheduled",
                "schedule": {"type": "every", "intervalSecs": 60},
                "payload": {"type": "shellCommand", "command": "echo scheduled"}
            }
        })),
    )
    .await;
    let job_id = created["job"]["id"].as_str().unwrap();
    let scheduled_at = chrono::Utc::now();
    let trigger_id = crate::cron::CronScheduler::schedule_trigger_id(job_id).unwrap();
    let idempotency_key = format!(
        "cron-schedule:v1:{job_id}:{}",
        scheduled_at.timestamp_millis()
    );
    let mut request = crate::engine::TriggerDispatchRequest::new(
        trigger_id.clone(),
        json!({"jobId": job_id, "scheduledAt": scheduled_at.to_rfc3339()}),
        crate::engine::ActorId::new("cron-scheduler").unwrap(),
        ActorKind::System,
    );
    request.authority_scopes = vec!["cron.write".to_owned()];
    request.idempotency_key = Some(idempotency_key.clone());
    request.delivery_mode = Some(DeliveryMode::Sync);
    let first =
        crate::engine::EngineTriggerRuntime::dispatch(&ctx.engine_host, request.clone()).await;
    assert!(first.error.is_none(), "{:?}", first.error);

    let replay = crate::engine::EngineTriggerRuntime::dispatch(&ctx.engine_host, request).await;
    assert!(replay.error.is_none(), "{:?}", replay.error);
    assert!(replay.replayed_from.is_some());

    let host = ctx.engine_host.lock().await;
    let records = host.catalog().invocations();
    let record = records
        .iter()
        .rev()
        .find(|record| record.function_id == FunctionId::new("cron::scheduled_fire").unwrap())
        .unwrap();
    assert_eq!(record.trigger_id, Some(trigger_id));
    assert_eq!(record.actor_kind, ActorKind::System);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert_scope(&record.authority_scopes, "cron.write");
    assert_eq!(
        record.idempotency_key.as_ref().map(String::as_str),
        Some(idempotency_key.as_str())
    );
}

#[test]
fn transport_bindings_classify_runtime_tail_as_generic_triggered() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in RUNTIME_TAIL_METHODS {
        assert!(specs.iter().any(|spec| spec.method == *method));
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
        assert!(crate::server::capabilities::schemas::request_schema_for_method(method).is_some());
        assert!(crate::server::capabilities::schemas::response_schema_for_method(method).is_some());
    }
}

#[test]
fn transport_bindings_classify_first_high_risk_command_collapse() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for method in HIGH_RISK_COMMAND_METHODS {
        let spec = specs.iter().find(|spec| spec.method == *method).unwrap();
        assert!(spec.effect_class.is_mutating());
        assert_eq!(spec.risk_level, RiskLevel::High);
        assert_eq!(spec.transport_authority_scope, Some(RPC_WRITE_AUTHORITY));
        assert_eq!(
            spec.idempotency_mode,
            JsonRpcIdempotencyMode::JsonRpcRequestIdSeed
        );
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
        assert!(crate::server::capabilities::schemas::request_schema_for_method(method).is_some());
        assert!(crate::server::capabilities::schemas::response_schema_for_method(method).is_some());
        let definition = specs::function_definition_for_alias(spec);
        assert!(definition.required_authority.approval_required);
        assert!(
            definition.metadata["highRiskContract"]["resourceLock"]["required"]
                .as_bool()
                .unwrap(),
            "{method} must declare resource-lock metadata"
        );
        assert!(
            definition.metadata["highRiskContract"]["rollbackOrCompensation"]
                .as_str()
                .is_some_and(|value| !value.is_empty())
        );
    }

    let model = specs
        .iter()
        .find(|spec| spec.method == "model.switch")
        .unwrap();
    assert_eq!(model.function_id, FunctionId::new("model::switch").unwrap());
    assert_eq!(model.authority_scope, Some("model.write"));
    assert_eq!(model.effect_class, EffectClass::ReversibleSideEffect);
    assert_eq!(
        specs::function_definition_for_alias(model)
            .idempotency
            .as_ref()
            .map(|contract| contract.dedupe_scope.clone()),
        Some(VisibilityScope::Session)
    );

    let config = specs
        .iter()
        .find(|spec| spec.method == "config.setReasoningLevel")
        .unwrap();
    assert_eq!(
        config.function_id,
        FunctionId::new("config::set_reasoning_level").unwrap()
    );
    assert_eq!(config.owner_worker, specs::worker_id("config").unwrap());
    assert_eq!(config.authority_scope, Some("config.write"));
    assert_eq!(config.effect_class, EffectClass::ReversibleSideEffect);

    let memory = specs
        .iter()
        .find(|spec| spec.method == "memory.retain")
        .unwrap();
    assert_eq!(
        memory.function_id,
        FunctionId::new("memory::retain").unwrap()
    );
    assert_eq!(memory.owner_worker, specs::worker_id("memory").unwrap());
    assert_eq!(memory.authority_scope, Some("memory.write"));
    assert_eq!(memory.effect_class, EffectClass::ExternalSideEffect);

    let import = specs
        .iter()
        .find(|spec| spec.method == "import.execute")
        .unwrap();
    assert_eq!(
        import.function_id,
        FunctionId::new("import::execute").unwrap()
    );
    assert_eq!(import.authority_scope, Some("import.write"));
    assert_eq!(import.effect_class, EffectClass::AppendOnlyEvent);
    assert_eq!(
        specs::function_definition_for_alias(import)
            .idempotency
            .as_ref()
            .map(|contract| contract.dedupe_scope.clone()),
        Some(VisibilityScope::System)
    );
}

#[test]
fn transport_bindings_classify_git_worktree_as_fully_generic_triggered() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();

    for &method in GIT_WORKTREE_METHODS {
        assert!(specs.iter().any(|spec| spec.method == method));
        assert!(
            registry.is_transport_binding(method),
            "{method} must be alias-registered, not method-specific business logic"
        );
        assert!(
            crate::server::capabilities::schemas::request_schema_for_method(method).is_some(),
            "{method} must declare a request schema"
        );
        assert!(
            crate::server::capabilities::schemas::response_schema_for_method(method).is_some(),
            "{method} must declare a response schema"
        );
    }

    for method in [
        "worktree.acquire",
        "worktree.release",
        "worktree.stageFiles",
        "worktree.unstageFiles",
    ] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert_eq!(spec.risk_level, RiskLevel::Medium);
        assert!(
            !specs::function_definition_for_alias(spec)
                .required_authority
                .approval_required
        );
        assert!(
            specs::function_definition_for_alias(spec)
                .resource_lease
                .is_some(),
            "{method} must still be lease-guarded"
        );
    }

    for method in [
        "git.clone",
        "git.syncMain",
        "git.push",
        "worktree.commit",
        "worktree.merge",
        "worktree.finalizeSession",
        "worktree.deleteBranch",
        "worktree.pruneBranches",
        "worktree.discardFiles",
        "worktree.rebaseOnMain",
        "worktree.startMerge",
        "worktree.resolveConflict",
        "worktree.continueMerge",
        "worktree.abortMerge",
        "worktree.resolveConflictsWithSubagent",
    ] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert!(spec.risk_level >= RiskLevel::High);
        let definition = specs::function_definition_for_alias(spec);
        assert!(definition.required_authority.approval_required);
        assert!(definition.resource_lease.is_some());
        assert!(definition.compensation.is_some());
    }
}

fn git_worktree_error_payload(method: &str) -> Value {
    match method {
        "git.clone" => json!({
            "url": "not a git url",
            "targetPath": "/tmp/tron-engine-bridge-noop"
        }),
        "git.syncMain" | "git.push" | "git.listLocalBranches" | "git.listRemoteBranches" => {
            json!({"sessionId": "missing-session"})
        }
        "worktree.isGitRepo" => json!({"path": "/tmp"}),
        "worktree.list" => json!({}),
        "worktree.commit" => {
            json!({"sessionId": "missing-session", "message": "commit", "stageAll": true})
        }
        "worktree.merge" => json!({"sessionId": "missing-session", "targetBranch": "main"}),
        "worktree.deleteBranch" => json!({"sessionId": "missing-session", "branch": "session/x"}),
        "worktree.stageFiles" | "worktree.unstageFiles" | "worktree.discardFiles" => {
            json!({"sessionId": "missing-session", "paths": ["src/main.rs"]})
        }
        "worktree.startMerge" => json!({
            "sessionId": "missing-session",
            "sourceBranch": "feature",
            "targetBranch": "main"
        }),
        "worktree.resolveConflict" => json!({
            "sessionId": "missing-session",
            "path": "src/main.rs",
            "resolution": "ours"
        }),
        "worktree.abortMerge" => json!({"sessionId": "missing-session", "reason": "test"}),
        _ => json!({"sessionId": "missing-session"}),
    }
}

#[tokio::test]
async fn git_worktree_generic_triggers_match_direct_engine_error_shapes() {
    let ctx = make_test_context();

    for method in GIT_WORKTREE_METHODS {
        let payload = git_worktree_error_payload(method);
        let direct = direct_engine_error_body(&ctx, method, payload.clone()).await;
        let rpc = rpc_dispatch_error_body(&ctx, method, payload).await;
        assert_eq!(direct, rpc, "{method}");
    }
}

#[test]
fn transport_bindings_assign_generic_methods_to_domain_workers() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    for (method, worker) in [
        ("system.ping", "system"),
        ("settings.update", "settings"),
        ("logs.ingest", "logs"),
        ("promptSnippet.create", "prompt_library"),
        ("skill.activate", "skills"),
        ("filesystem.listDir", "filesystem"),
        ("events.append", "events"),
        ("notifications.markRead", "notifications"),
        ("plan.enter", "plan"),
        ("tree.getVisualization", "tree"),
        ("repo.getDivergence", "repo"),
        ("import.previewSession", "import"),
        ("import.execute", "import"),
        ("model.switch", "model"),
        ("config.setReasoningLevel", "config"),
        ("memory.retain", "memory"),
        ("browser.getStatus", "browser"),
        ("voiceNotes.list", "voice_notes"),
        ("transcribe.listModels", "transcription"),
        ("sandbox.listContainers", "sandbox"),
        ("git.push", "git"),
        ("worktree.commit", "worktree"),
    ] {
        let spec = specs.iter().find(|spec| spec.method == method).unwrap();
        assert_eq!(spec.owner_worker, specs::worker_id(worker).unwrap());
        assert_eq!(spec.domain_worker, specs::worker_id(worker).unwrap());
        let definition = specs::function_definition_for_alias(spec);
        assert_eq!(definition.owner_worker, specs::worker_id(worker).unwrap());
        assert_eq!(definition.metadata["domainWorker"], worker);
    }
}

#[tokio::test]
async fn tool_worker_registers_builtin_tools_as_canonical_functions() {
    let mut ctx = make_test_context();
    let mut agent_deps = make_test_agent_deps();
    agent_deps.tool_factory = Arc::new(|| {
        let mut registry = crate::tools::registry::ToolRegistry::new();
        registry.register(Arc::new(EngineCatalogSearchTool));
        registry
    });
    ctx.agent_deps = Some(agent_deps);
    let registry = migration_parity_registry();
    super::register_rpc_worker_for_context(&ctx, &registry).unwrap();

    let functions = ctx
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(
                ActorContext::new(
                    crate::engine::ActorId::new("test-agent").unwrap(),
                    ActorKind::Agent,
                    crate::engine::AuthorityGrantId::new("test-grant").unwrap(),
                )
                .with_scope("tool.read"),
            ),
            namespace_prefix: Some("tool".to_owned()),
            ..Default::default()
        })
        .await;
    let tool_function = functions
        .iter()
        .find(|function| function.id.as_str() == "tool::search")
        .expect("tool::search must be discoverable");
    assert_eq!(tool_function.owner_worker.as_str(), "tool");
    assert_eq!(tool_function.metadata["toolName"], "Search");
    assert_eq!(tool_function.metadata["modelToolName"], "Search");
    assert_eq!(tool_function.effect_class, EffectClass::PureRead);
    assert!(tool_function.request_schema.is_some());

    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("tool::search").unwrap(),
            json!({"query": "catalog"}),
            CausalContext::new(
                crate::engine::ActorId::new("test-agent").unwrap(),
                ActorKind::Agent,
                crate::engine::AuthorityGrantId::new("test-grant").unwrap(),
                TraceId::generate(),
            )
            .with_scope("tool.read"),
        ))
        .await;
    assert!(result.error.is_none(), "{:?}", result.error);
    let value = result.value.unwrap();
    assert_eq!(value["content"][0]["text"], "searched catalog");
}

#[tokio::test]
async fn provider_tool_surface_is_resolved_from_live_catalog_each_call() {
    let mut ctx = make_test_context();
    let mut agent_deps = make_test_agent_deps();
    agent_deps.tool_factory = Arc::new(|| {
        let mut registry = crate::tools::registry::ToolRegistry::new();
        registry.register(Arc::new(EngineCatalogSearchTool));
        registry
    });
    ctx.agent_deps = Some(agent_deps);
    let registry = migration_parity_registry();
    super::register_rpc_worker_for_context(&ctx, &registry).unwrap();

    let mut provider_registry = crate::tools::registry::ToolRegistry::new();
    provider_registry.register(Arc::new(EngineCatalogSearchTool));
    provider_registry.register(Arc::new(DynamicCatalogTool));
    let spec = crate::core::profile::bundled_default_execution_spec();
    let policy = crate::runtime::context::local_policy::ContextPolicy::from_entrypoint_with_spec(
        Provider::Anthropic,
        &spec,
        "main",
    );

    let first = crate::tools::capability_surface::resolve_provider_tools(
        &ctx.engine_host,
        &provider_registry,
        "surface-session",
        None,
        Provider::Anthropic,
        &policy,
    )
    .await
    .unwrap();
    assert_eq!(
        first
            .iter()
            .map(|tool| tool.name.as_str())
            .collect::<Vec<_>>(),
        ["Search"]
    );

    let mut definition = FunctionDefinition::new(
        FunctionId::new("tool::dynamic").unwrap(),
        specs::worker_id("tool").unwrap(),
        "Dynamically registered catalog tool",
        VisibilityScope::System,
        EffectClass::PureRead,
    )
    .with_required_authority(crate::engine::AuthorityRequirement::scope("tool.read"))
    .with_provenance(crate::engine::Provenance::system())
    .with_request_schema(json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {}
    }))
    .with_response_schema(json!({
        "type": "object",
        "additionalProperties": true
    }));
    definition.metadata = json!({
        "modelToolName": "Dynamic",
        "toolOrder": 2,
        "toolSchema": DynamicCatalogTool.definition(),
        "localToolSchema": DynamicCatalogTool.definition(),
    });
    ctx.engine_host
        .register_function(definition, None, true)
        .await
        .unwrap();

    let second = crate::tools::capability_surface::resolve_provider_tools(
        &ctx.engine_host,
        &provider_registry,
        "surface-session",
        None,
        Provider::Anthropic,
        &policy,
    )
    .await
    .unwrap();
    assert_eq!(
        second
            .iter()
            .map(|tool| tool.name.as_str())
            .collect::<Vec<_>>(),
        ["Search", "Dynamic"]
    );
}

#[test]
fn generic_trigger_specs_use_canonical_domain_function_ids() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    for spec in specs.iter().filter(|spec| specs::is_engine_routable(spec)) {
        assert_ne!(
            spec.function_id.namespace(),
            RPC_WORKER_ID,
            "{} must execute as a canonical domain function",
            spec.method
        );
        let definition = specs::function_definition_for_alias(spec);
        assert_eq!(
            definition.metadata["canonicalCapability"],
            spec.function_id.as_str()
        );
        assert_eq!(
            definition.metadata["compatFunctionId"],
            specs::compat_function_id_for_method(spec.method)
                .unwrap()
                .as_str()
        );
    }
}

#[tokio::test]
async fn json_rpc_triggers_target_canonical_domain_functions() {
    let ctx = make_test_context();
    for (method, target) in [
        ("system.ping", "system::ping"),
        ("settings.update", "settings::update"),
        ("logs.ingest", "logs::ingest"),
        ("skill.activate", "skills::activate"),
        ("filesystem.getHome", "filesystem::get_home"),
        ("file.read", "filesystem::read_file"),
        ("events.append", "events::append"),
        ("notifications.markAllRead", "notifications::mark_all_read"),
        ("plan.getState", "plan::get_state"),
        ("promptSnippet.create", "prompt_library::snippet_create"),
        ("tree.getBranches", "tree::get_branches"),
        ("repo.getDivergence", "repo::get_divergence"),
        ("import.listSources", "import::list_sources"),
        ("browser.getStatus", "browser::get_status"),
        ("voiceNotes.list", "voice_notes::list"),
        ("transcribe.listModels", "transcription::list_models"),
        ("sandbox.listContainers", "sandbox::list_containers"),
    ] {
        let trigger = ctx
            .engine_host
            .inspect_trigger(&specs::json_rpc_trigger_id_for_method(method).unwrap())
            .await
            .unwrap();
        assert_eq!(trigger.target_function.as_str(), target);
    }
}

#[tokio::test]
async fn canonical_functions_are_agent_discoverable_without_rpc_compat_surface() {
    let ctx = make_test_context();
    let actor = ActorContext::new(
        specs::actor_id("agent").unwrap(),
        ActorKind::Agent,
        specs::grant_id("agent-grant").unwrap(),
    )
    .with_scope("skills.read")
    .with_scope("skills.write");
    let functions = ctx
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor),
            namespace_prefix: Some("skills".to_owned()),
            ..FunctionQuery::default()
        })
        .await;
    let ids = functions
        .iter()
        .map(|function| function.id.as_str().to_owned())
        .collect::<BTreeSet<_>>();
    assert!(ids.contains("skills::activate"));
    assert!(ids.contains("skills::list"));
    assert!(
        ids.iter().all(|id| !id.starts_with("rpc::")),
        "agent-facing skills discovery must not expose rpc compatibility ids: {ids:?}"
    );
}

#[tokio::test]
async fn direct_canonical_invocation_requires_domain_scope() {
    let ctx = make_test_context();
    let function_id = specs::function_id_for_method("skill.list").unwrap();
    let missing_domain_scope = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({}),
            super::dispatch::rpc_causal_context_for_scope(RPC_READ_AUTHORITY),
        ))
        .await;
    assert!(matches!(
        missing_domain_scope.error,
        Some(EngineError::PolicyViolation(_))
    ));

    let ok = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id,
            json!({}),
            rpc_and_domain_context("skill.list", RPC_READ_AUTHORITY),
        ))
        .await;
    assert!(ok.error.is_none(), "{:?}", ok.error);
}

#[test]
fn transport_bindings_classify_representative_effect_and_risk_levels() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let specs = json_rpc_alias_specs(&registry).unwrap();
    let find = |method: &str| specs.iter().find(|spec| spec.method == method).unwrap();

    let session_list = find("session.list");
    assert_eq!(session_list.effect_class, EffectClass::PureRead);
    assert_eq!(session_list.risk_level, RiskLevel::Low);

    let settings_update = find("settings.update");
    assert_eq!(
        settings_update.effect_class,
        EffectClass::ReversibleSideEffect
    );
    assert_eq!(settings_update.risk_level, RiskLevel::High);

    let events_append = find("events.append");
    assert_eq!(events_append.effect_class, EffectClass::AppendOnlyEvent);
    assert_eq!(events_append.risk_level, RiskLevel::Medium);

    let message_delete = find("message.delete");
    assert_eq!(
        message_delete.effect_class,
        EffectClass::IrreversibleSideEffect
    );
    assert_eq!(message_delete.risk_level, RiskLevel::High);

    let system_shutdown = find("system.shutdown");
    assert_eq!(
        system_shutdown.effect_class,
        EffectClass::IrreversibleSideEffect
    );
    assert_eq!(system_shutdown.risk_level, RiskLevel::Critical);

    let git_push = find("git.push");
    assert_eq!(git_push.effect_class, EffectClass::ExternalSideEffect);
    assert_eq!(git_push.risk_level, RiskLevel::Critical);
}

#[test]
fn transport_bindings_fail_closed_for_unclassified_registry_methods() {
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    registry.register("new.method");
    let err = json_rpc_alias_specs(&registry).unwrap_err();
    assert!(matches!(
        err,
        EngineError::PolicyViolation(message)
            if message.contains("new.method") && message.contains("without a transport binding spec")
    ));
}

#[test]
fn rpc_engine_invocation_preserves_transport_metadata() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "req-123".to_owned(),
        method: "events.getHistory".to_owned(),
        params: Some(json!({"sessionId": "session-a", "workspaceId": "workspace-a", "limit": 5})),
    };
    let envelope = RpcEngineInvocation::from_request(&registry, &ctx, &request)
        .unwrap()
        .unwrap();
    assert_eq!(envelope.request_id, "req-123");
    assert_eq!(envelope.method, "events.getHistory");
    assert_eq!(envelope.params_payload["limit"], 5);
    assert_eq!(
        envelope.function_id,
        specs::function_id_for_method("events.getHistory").unwrap()
    );
    assert_eq!(envelope.causal_context.actor_id.as_str(), "rpc-client");
    assert_eq!(
        envelope.causal_context.authority_grant_id.as_str(),
        RPC_AUTHORITY_GRANT
    );
    assert!(envelope.causal_context.has_scope(RPC_READ_AUTHORITY));
    assert!(envelope.causal_context.has_scope("events.read"));
    assert_eq!(
        envelope.causal_context.session_id.as_deref(),
        Some("session-a")
    );
    assert_eq!(
        envelope.causal_context.workspace_id.as_deref(),
        Some("workspace-a")
    );
    assert!(!envelope.causal_context.trace_id.as_str().is_empty());
}

#[test]
fn rpc_engine_invocation_derives_write_authority_and_idempotency_key() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let payload = json!({"name": "Greeting", "text": "Hello!"});
    let request = RpcRequest {
        id: "write-1".to_owned(),
        method: "promptSnippet.create".to_owned(),
        params: Some(payload.clone()),
    };
    let first = RpcEngineInvocation::from_request(&registry, &ctx, &request)
        .unwrap()
        .unwrap();
    let second = RpcEngineInvocation::from_request(&registry, &ctx, &request)
        .unwrap()
        .unwrap();

    assert!(first.causal_context.has_scope(RPC_WRITE_AUTHORITY));
    assert!(first.causal_context.has_scope("prompt_library.write"));
    assert!(!first.causal_context.has_scope(RPC_READ_AUTHORITY));
    assert_eq!(
        first.causal_context.idempotency_key,
        second.causal_context.idempotency_key
    );
    assert!(
        first
            .causal_context
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );

    let changed = RpcEngineInvocation::from_request(
        &registry,
        &ctx,
        &RpcRequest {
            id: "write-1".to_owned(),
            method: "promptSnippet.create".to_owned(),
            params: Some(json!({"name": "Greeting 2", "text": "Hello!"})),
        },
    )
    .unwrap()
    .unwrap();
    assert_ne!(
        first.causal_context.idempotency_key,
        changed.causal_context.idempotency_key
    );
    assert_eq!(first.params_payload, payload);
}

#[test]
fn rpc_engine_invocation_rejects_empty_write_request_id() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let err = RpcEngineInvocation::from_request(
        &registry,
        &ctx,
        &RpcRequest {
            id: String::new(),
            method: "promptSnippet.create".to_owned(),
            params: Some(json!({"name": "n", "text": "t"})),
        },
    )
    .unwrap_err();
    assert_eq!(err.code(), errors::INVALID_PARAMS);
    assert!(err.to_string().contains("request id"));
}

#[test]
fn rpc_engine_invocation_rejects_empty_prompt_history_write_request_id() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let err = RpcEngineInvocation::from_request(
        &registry,
        &ctx,
        &RpcRequest {
            id: " ".to_owned(),
            method: "promptHistory.delete".to_owned(),
            params: Some(json!({"id": "history-1"})),
        },
    )
    .unwrap_err();
    assert_eq!(err.code(), errors::INVALID_PARAMS);
    assert!(err.to_string().contains("request id"));
}

#[test]
fn rpc_engine_invocation_rejects_empty_settings_write_request_id() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let err = RpcEngineInvocation::from_request(
        &registry,
        &ctx,
        &RpcRequest {
            id: " ".to_owned(),
            method: "settings.update".to_owned(),
            params: Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
        },
    )
    .unwrap_err();
    assert_eq!(err.code(), errors::INVALID_PARAMS);
    assert!(err.to_string().contains("request id"));
}

#[test]
fn rpc_engine_invocation_defaults_missing_params_to_empty_object() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "req-empty".to_owned(),
        method: "settings.get".to_owned(),
        params: None,
    };
    let envelope = RpcEngineInvocation::from_request(&registry, &ctx, &request)
        .unwrap()
        .unwrap();
    assert_eq!(envelope.params_payload, json!({}));
}

#[test]
fn fully_collapsed_methods_build_generic_envelopes() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "req-resume".to_owned(),
        method: "session.resume".to_owned(),
        params: Some(json!({"sessionId": "s1"})),
    };
    assert!(
        RpcEngineInvocation::from_request(&registry, &ctx, &request)
            .unwrap()
            .is_some()
    );
}

#[tokio::test]
async fn fully_collapsed_engine_functions_are_client_routable() {
    let ctx = make_test_context();
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            specs::function_id_for_method("session.resume").unwrap(),
            json!({}),
            rpc_and_domain_context("session.resume", RPC_READ_AUTHORITY),
        ))
        .await;
    assert!(matches!(
        result.error,
        Some(EngineError::SchemaViolation { .. })
    ));
}

#[tokio::test]
async fn json_rpc_transport_dispatches_without_marker_handlers() {
    let ctx = make_test_context();
    let result = rpc_dispatch_value(&ctx, "system.ping", json!({"protocolVersion": 1})).await;
    assert_eq!(result["pong"], true);
}

#[tokio::test]
async fn generic_trigger_engine_errors_keep_rpc_error_shape() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let response = registry
        .dispatch(
            RpcRequest {
                id: "bad-ping".to_owned(),
                method: "system.ping".to_owned(),
                params: Some(json!({})),
            },
            &ctx,
        )
        .await;
    assert!(!response.success);
    let error = response.error.unwrap();
    assert_eq!(error.code, errors::INVALID_PARAMS);
    assert!(error.message.contains("required field"));
}

#[tokio::test]
async fn generic_trigger_strict_request_schemas_reject_unknown_fields() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let response = registry
        .dispatch(
            RpcRequest {
                id: "bad-settings".to_owned(),
                method: "settings.get".to_owned(),
                params: Some(json!({"unexpected": true})),
            },
            &ctx,
        )
        .await;
    assert!(!response.success);
    let error = response.error.unwrap();
    assert_eq!(error.code, errors::INVALID_PARAMS);
    assert!(error.message.contains("additional property"));
}

#[tokio::test]
async fn approval_rpc_methods_route_to_engine_approval_primitive() {
    let ctx = make_test_context();
    let request = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("approval::request").unwrap(),
            json!({
                "functionId": "system::ping",
                "payload": {"protocolVersion": 1}
            }),
            CausalContext::new(
                specs::actor_id("agent:test").unwrap(),
                ActorKind::Agent,
                specs::grant_id("agent-test").unwrap(),
                TraceId::generate(),
            )
            .with_scope("approval.request")
            .with_session_id("approval-session")
            .with_idempotency_key("approval-rpc-test"),
        ))
        .await;
    assert!(request.error.is_none(), "{:?}", request.error);
    let approval_id = request.value.as_ref().unwrap()["approval"]["approvalId"]
        .as_str()
        .unwrap()
        .to_owned();

    let get = rpc_dispatch_value(&ctx, "approval.get", json!({"approvalId": approval_id})).await;
    assert_eq!(get["approval"]["status"], "pending");
    let list = rpc_dispatch_value(&ctx, "approval.list", json!({"status": "pending"})).await;
    assert!(
        list["approvals"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| record["approvalId"] == approval_id)
    );
    let resolved = rpc_dispatch_value(
        &ctx,
        "approval.resolve",
        json!({"approvalId": approval_id, "decision": "deny"}),
    )
    .await;
    assert_eq!(resolved["approval"]["status"], "denied");
    assert!(resolved["child"].is_null());
}

#[tokio::test]
async fn job_background_queues_hidden_apply_and_replays_transport_retry() {
    let mut ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("jobs"), None)
        .unwrap();
    let process_manager = Arc::new(QueueJobFakeProcessManager::default());
    process_manager.processes.lock().unwrap().push(ProcessInfo {
        process_id: "job-1".to_owned(),
        label: "demo".to_owned(),
        kind: ProcessKind::ToolOperation,
        state: "foreground".to_owned(),
        elapsed_ms: 0,
        session_id: session_id.clone(),
        tool_call_id: "tool-1".to_owned(),
    });
    ctx.process_manager = Some(process_manager.clone());
    let registry = migration_parity_registry();
    register_rpc_worker_for_context(&ctx, &registry).unwrap();

    let request = RpcRequest {
        id: "job-background-retry".to_owned(),
        method: "job.background".to_owned(),
        params: Some(json!({"sessionId": session_id, "jobId": "job-1"})),
    };
    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert_eq!(first.result.as_ref().unwrap()["backgrounded"], true);
    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);
    assert_eq!(
        process_manager.promoted.lock().unwrap().as_slice(),
        ["job-1"],
        "duplicate transport retry must replay without re-promoting"
    );
}

#[tokio::test]
async fn job_cancel_queues_hidden_apply_and_replays_transport_retry() {
    let mut ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("jobs"), None)
        .unwrap();
    let process_manager = Arc::new(QueueJobFakeProcessManager::default());
    process_manager.processes.lock().unwrap().push(ProcessInfo {
        process_id: "job-2".to_owned(),
        label: "demo".to_owned(),
        kind: ProcessKind::ToolOperation,
        state: "foreground".to_owned(),
        elapsed_ms: 0,
        session_id: session_id.clone(),
        tool_call_id: "tool-2".to_owned(),
    });
    ctx.process_manager = Some(process_manager.clone());
    let registry = migration_parity_registry();
    register_rpc_worker_for_context(&ctx, &registry).unwrap();

    let request = RpcRequest {
        id: "job-cancel-retry".to_owned(),
        method: "job.cancel".to_owned(),
        params: Some(json!({"sessionId": session_id, "jobId": "job-2"})),
    };
    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert_eq!(first.result.as_ref().unwrap()["cancelled"], true);
    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);
    assert_eq!(
        process_manager.cancelled.lock().unwrap().as_slice(),
        [("job-2".to_owned(), true)],
        "duplicate transport retry must replay without re-cancelling"
    );
}

#[tokio::test]
async fn generic_rpc_outputs_match_direct_engine_outputs() {
    let ctx = make_test_context();
    let cases = [
        ("system.ping", json!({"protocolVersion": 1})),
        ("system.getInfo", json!({})),
        ("settings.get", json!({})),
        ("model.list", json!({})),
        ("skill.list", json!({})),
        ("logs.recent", json!({})),
        ("filesystem.getHome", json!({})),
        ("browser.getStatus", json!({})),
        ("transcribe.listModels", json!({})),
        ("voiceNotes.list", json!({})),
        ("import.listSources", json!({})),
        (
            "tree.compareBranches",
            json!({"branchA": "a", "branchB": "b"}),
        ),
        ("promptHistory.list", json!({})),
        ("promptSnippet.list", json!({})),
    ];

    for (method, payload) in cases {
        let direct = normalize_unstable_fields(
            method,
            direct_engine_value(&ctx, method, payload.clone()).await,
        );
        let rpc =
            normalize_unstable_fields(method, rpc_dispatch_value(&ctx, method, payload).await);
        assert_eq!(direct, rpc, "{method}");
    }
}

#[tokio::test]
async fn generic_rpc_outputs_match_direct_engine_outputs_for_stateful_reads() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("stateful"), None)
        .unwrap();
    let _ = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let snippet =
        crate::prompt_library::store::create_snippet(ctx.event_store.pool(), "n", "t").unwrap();
    let session = ctx.event_store.get_session(&session_id).unwrap().unwrap();
    let root_event_id = session.root_event_id.clone();

    let cases = [
        ("events.getHistory", json!({"sessionId": session_id})),
        (
            "events.getSince",
            json!({"sessionId": session_id, "afterSequence": 0}),
        ),
        ("events.subscribe", json!({"sessionId": session_id})),
        ("events.unsubscribe", json!({"sessionId": session_id})),
        ("session.list", json!({})),
        ("session.getHead", json!({"sessionId": session_id})),
        ("session.getState", json!({"sessionId": session_id})),
        ("session.getHistory", json!({"sessionId": session_id})),
        ("session.reconstruct", json!({"sessionId": session_id})),
        ("context.getSnapshot", json!({"sessionId": session_id})),
        (
            "context.getDetailedSnapshot",
            json!({"sessionId": session_id}),
        ),
        ("context.shouldCompact", json!({"sessionId": session_id})),
        (
            "context.previewCompaction",
            json!({"sessionId": session_id}),
        ),
        ("context.canAcceptTurn", json!({"sessionId": session_id})),
        ("job.list", json!({"sessionId": session_id})),
        ("tree.getVisualization", json!({"sessionId": session_id})),
        ("tree.getBranches", json!({"sessionId": session_id})),
        ("tree.getSubtree", json!({"eventId": root_event_id})),
        ("tree.getAncestors", json!({"eventId": root_event_id})),
        ("promptSnippet.get", json!({"id": snippet.id})),
    ];

    for (method, payload) in cases {
        let direct = direct_engine_value(&ctx, method, payload.clone()).await;
        let rpc = rpc_dispatch_value(&ctx, method, payload).await;
        assert_eq!(direct, rpc, "{method}");
    }
}

#[tokio::test]
async fn cron_rpc_outputs_match_direct_engine_outputs_and_replay_writes() {
    let (direct_ctx, _direct_dir) = make_cron_context();
    let (rpc_ctx, _rpc_dir) = make_cron_context();
    let create = json!({
        "job": {
            "name": "Engine Cron",
            "schedule": {"type": "every", "intervalSecs": 60},
            "payload": {"type": "shellCommand", "command": "echo hi"}
        }
    });

    let direct_create = normalize_unstable_fields(
        "cron.create",
        direct_engine_value(&direct_ctx, "cron.create", create.clone()).await,
    );
    let rpc_create = normalize_unstable_fields(
        "cron.create",
        rpc_dispatch_value(&rpc_ctx, "cron.create", create).await,
    );
    assert_eq!(direct_create, rpc_create);

    let direct_job_id = direct_ctx
        .cron_scheduler
        .as_ref()
        .unwrap()
        .with_jobs(|jobs| jobs.values().next().unwrap().id.clone());
    let rpc_job_id = rpc_ctx
        .cron_scheduler
        .as_ref()
        .unwrap()
        .with_jobs(|jobs| jobs.values().next().unwrap().id.clone());

    for (method, direct_payload, rpc_payload) in [
        ("cron.list", json!({}), json!({})),
        (
            "cron.get",
            json!({"jobId": direct_job_id.clone()}),
            json!({"jobId": rpc_job_id.clone()}),
        ),
        ("cron.status", json!({}), json!({})),
        (
            "cron.getRuns",
            json!({"jobId": direct_job_id.clone()}),
            json!({"jobId": rpc_job_id.clone()}),
        ),
        (
            "cron.update",
            json!({"jobId": direct_job_id.clone(), "name": "Updated Cron", "enabled": false}),
            json!({"jobId": rpc_job_id.clone(), "name": "Updated Cron", "enabled": false}),
        ),
        (
            "cron.run",
            json!({"jobId": direct_job_id.clone()}),
            json!({"jobId": rpc_job_id.clone()}),
        ),
    ] {
        let direct = normalize_unstable_fields(
            method,
            direct_engine_value(&direct_ctx, method, direct_payload).await,
        );
        let rpc = normalize_unstable_fields(
            method,
            rpc_dispatch_value(&rpc_ctx, method, rpc_payload).await,
        );
        assert_eq!(direct, rpc, "{method}");
    }

    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: "cron-delete-retry".to_owned(),
        method: "cron.delete".to_owned(),
        params: Some(json!({"jobId": rpc_job_id})),
    };
    let first = registry.dispatch(request.clone(), &rpc_ctx).await;
    assert!(first.success, "{:?}", first.error);
    let second = registry.dispatch(request, &rpc_ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);
}

#[tokio::test]
async fn runtime_tail_rpc_outputs_match_direct_engine_outputs() {
    let ctx = make_test_context();
    let blob_id = {
        let conn = ctx.event_store.pool().get().unwrap();
        crate::events::sqlite::repositories::blob::BlobRepo::store(
            &conn,
            b"hello engine",
            "text/plain",
        )
        .unwrap()
    };
    for (method, payload) in [
        ("system.getDiagnostics", json!({})),
        ("system.getUpdateStatus", json!({})),
        ("codexApp.status", json!({})),
        ("blob.get", json!({"blobId": blob_id})),
    ] {
        let direct = normalize_unstable_fields(
            method,
            direct_engine_value(&ctx, method, payload.clone()).await,
        );
        let rpc =
            normalize_unstable_fields(method, rpc_dispatch_value(&ctx, method, payload).await);
        assert_eq!(direct, rpc, "{method}");
    }
}

#[tokio::test]
async fn runtime_tail_writes_replay_without_rerunning_handlers() {
    let ctx = make_test_context();
    let _pending = ctx.orchestrator.register_tool_call("tool-call-1");
    let registry = migration_parity_registry();
    let tool_request = RpcRequest {
        id: "tool-result-retry".to_owned(),
        method: "tool.result".to_owned(),
        params: Some(json!({
            "sessionId": "s1",
            "toolUseId": "tool-call-1",
            "result": {"output": "ok"}
        })),
    };
    let first = registry.dispatch(tool_request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    let second = registry.dispatch(tool_request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);

    let session_id = ctx
        .session_manager
        .create_session("m", "/tmp", Some("message"), None)
        .unwrap();
    let event = ctx
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let delete_request = RpcRequest {
        id: "message-delete-retry".to_owned(),
        method: "message.delete".to_owned(),
        params: Some(json!({"sessionId": session_id, "targetEventId": event.id})),
    };
    let first = registry.dispatch(delete_request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    let second = registry.dispatch(delete_request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);
}

#[tokio::test]
async fn session_create_outputs_match_direct_engine_outputs() {
    let params = json!({
        "workingDirectory": "/tmp",
        "model": "claude-opus-4-6",
        "title": "engine session"
    });
    let direct_ctx = make_test_context();
    let direct = normalize_unstable_fields(
        "session.create",
        direct_engine_value(&direct_ctx, "session.create", params.clone()).await,
    );
    let rpc_ctx = make_test_context();
    let rpc = normalize_unstable_fields(
        "session.create",
        rpc_dispatch_value(&rpc_ctx, "session.create", params).await,
    );
    assert_eq!(direct, rpc);
}

#[tokio::test]
async fn agent_queue_prompt_outputs_match_direct_engine_and_replays_rpc_retry() {
    let direct_ctx = make_test_context();
    let direct_session = direct_ctx
        .event_store
        .create_session("claude-opus-4-6", "/tmp", None, None, None, None)
        .unwrap()
        .session
        .id;
    let direct_payload = json!({"sessionId": direct_session, "prompt": "queued by engine"});
    let direct = normalize_unstable_fields(
        "agent.queuePrompt",
        direct_engine_value(&direct_ctx, "agent.queuePrompt", direct_payload).await,
    );

    let rpc_ctx = make_test_context();
    let rpc_session = rpc_ctx
        .event_store
        .create_session("claude-opus-4-6", "/tmp", None, None, None, None)
        .unwrap()
        .session
        .id;
    let rpc_payload = json!({"sessionId": rpc_session, "prompt": "queued by engine"});
    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: "queue-retry".to_owned(),
        method: "agent.queuePrompt".to_owned(),
        params: Some(rpc_payload.clone()),
    };
    let first = registry.dispatch(request.clone(), &rpc_ctx).await;
    assert!(first.success, "{:?}", first.error);
    let second = registry.dispatch(request, &rpc_ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);
    let rpc = normalize_unstable_fields("agent.queuePrompt", first.result.unwrap());
    assert_eq!(direct, rpc);

    let pending = crate::server::rpc::prompt_queue::PromptQueueService::get_pending_queue(
        &rpc_ctx.event_store,
        &rpc_session,
    )
    .unwrap();
    assert_eq!(pending.len(), 1, "idempotent retry must not enqueue twice");
}

#[tokio::test]
async fn agent_prompt_outputs_match_direct_engine_and_json_rpc_dispatch() {
    let direct_ctx = make_prompt_context();
    let direct_session = direct_ctx
        .event_store
        .create_session("claude-opus-4-6", "/tmp", None, None, None, None)
        .unwrap()
        .session
        .id;
    let direct = normalize_unstable_fields(
        "agent.prompt",
        direct_engine_value(
            &direct_ctx,
            "agent.prompt",
            json!({"sessionId": direct_session, "prompt": "hello from engine"}),
        )
        .await,
    );

    let rpc_ctx = make_prompt_context();
    let rpc_session = rpc_ctx
        .event_store
        .create_session("claude-opus-4-6", "/tmp", None, None, None, None)
        .unwrap()
        .session
        .id;
    let rpc = normalize_unstable_fields(
        "agent.prompt",
        rpc_dispatch_value(
            &rpc_ctx,
            "agent.prompt",
            json!({"sessionId": rpc_session, "prompt": "hello from engine"}),
        )
        .await,
    );
    assert_eq!(direct, json!({"acknowledged": true, "runId": "<run>"}));
    assert_eq!(direct, rpc);
}

#[tokio::test]
async fn agent_prompt_publishes_engine_stream_lifecycle_records() {
    let ctx = make_prompt_context();
    let session_id = ctx
        .event_store
        .create_session("claude-opus-4-6", "/tmp", None, None, None, None)
        .unwrap()
        .session
        .id;

    let result = rpc_dispatch_value(
        &ctx,
        "agent.prompt",
        json!({"sessionId": session_id, "prompt": "stream me"}),
    )
    .await;
    assert_eq!(
        normalize_unstable_fields("agent.prompt", result),
        json!({"acknowledged": true, "runId": "<run>"})
    );

    ctx.engine_host
        .subscribe_stream(
            "agent-prompt-lifecycle-test".to_owned(),
            "agent.queue".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some(session_id.clone()),
            None,
        )
        .await
        .unwrap();
    let actor = StreamActorScope::scoped(Some(session_id.clone()), None);
    let mut cursor = StreamCursor(0);
    let mut actions = BTreeSet::new();
    for _ in 0..600 {
        let page = ctx
            .engine_host
            .poll_stream("agent-prompt-lifecycle-test", Some(cursor), 100, &actor)
            .await
            .unwrap();
        cursor = page.next_cursor;
        for event in page.events {
            if event.payload["sessionId"] == session_id
                && let Some(action) = event.payload["action"].as_str()
            {
                actions.insert(action.to_owned());
            }
        }
        if actions.contains("completed") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }

    for expected in ["accepted", "apply_enqueued", "apply_started", "completed"] {
        assert!(
            actions.contains(expected),
            "missing prompt lifecycle stream action {expected}; saw {actions:?}"
        );
    }
}

#[tokio::test]
async fn agent_prompt_duplicate_transport_replays_without_second_apply() {
    let ctx = make_prompt_context();
    let session_id = ctx
        .event_store
        .create_session("claude-opus-4-6", "/tmp", None, None, None, None)
        .unwrap()
        .session
        .id;
    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: "prompt-retry".to_owned(),
        method: "agent.prompt".to_owned(),
        params: Some(json!({"sessionId": session_id, "prompt": "dedupe me"})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);

    let host = ctx.engine_host.lock().await;
    let apply_invocations = host
        .catalog()
        .invocations()
        .iter()
        .filter(|record| record.function_id == FunctionId::new("agent::prompt_apply").unwrap())
        .count();
    assert_eq!(
        apply_invocations, 1,
        "transport retry must replay the public prompt result without applying twice"
    );
    let replay = host.catalog().invocations().last().unwrap();
    assert!(replay.replayed_from.is_some());
}

#[tokio::test]
async fn agent_prompt_agent_invocation_requires_approval_before_execution() {
    let ctx = make_prompt_context();
    let client = crate::engine::AgentCapabilityClient::new(
        ctx.engine_host.clone(),
        specs::actor_id("agent:test").unwrap(),
        specs::grant_id("agent-test").unwrap(),
    )
    .with_scopes(["agent.write"])
    .with_session_id("approval-session");
    let result = client
        .invoke(
            FunctionId::new("agent::prompt").unwrap(),
            json!({"sessionId": "approval-session", "prompt": "needs approval"}),
            Some("agent-prompt-approval-key".to_owned()),
            None,
        )
        .await;

    let Some(EngineError::AdapterFailure { code, details, .. }) = result.error else {
        panic!(
            "expected approval-required adapter failure, got {:?}",
            result.error
        );
    };
    assert_eq!(code, "APPROVAL_REQUIRED");
    assert_eq!(details.unwrap()["code"], "APPROVAL_REQUIRED");
}

#[tokio::test]
async fn hidden_agent_prompt_runtime_functions_are_not_agent_discoverable() {
    let ctx = make_prompt_context();
    let functions = ctx
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(ActorContext::new(
                specs::actor_id("agent:test").unwrap(),
                ActorKind::Agent,
                specs::grant_id("agent-test").unwrap(),
            )),
            ..Default::default()
        })
        .await;
    let ids = functions
        .iter()
        .map(|function| function.id.as_str())
        .collect::<BTreeSet<_>>();
    assert!(ids.contains("agent::prompt"));
    assert!(!ids.contains("agent::prompt_apply"));
    assert!(!ids.contains("agent::run_turn"));
    assert!(!ids.contains("agent::prompt_queue_drain"));
}

#[tokio::test]
async fn logs_ingest_outputs_match_direct_engine_outputs() {
    let payload = json!({
        "entries": [
            {"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "WebSocket", "message": "connected"},
            {"timestamp": "2026-03-03T14:30:05.200Z", "level": "verbose", "category": "RPC", "message": "sending ping"}
        ]
    });

    let direct_ctx = make_test_context();
    let direct = direct_engine_value(&direct_ctx, "logs.ingest", payload.clone()).await;
    assert_eq!(direct, json!({"success": true, "inserted": 2}));

    let rpc_ctx = make_test_context();
    let rpc = rpc_dispatch_value(&rpc_ctx, "logs.ingest", payload).await;
    assert_eq!(direct, rpc);

    let recent = rpc_dispatch_value(&rpc_ctx, "logs.recent", json!({"limit": 2})).await;
    assert_eq!(recent["count"], 2);
    assert_eq!(recent["entries"][0]["component"], "ios.WebSocket");
    assert_eq!(recent["entries"][1]["level"], "trace");
}

#[tokio::test]
async fn settings_outputs_match_direct_engine_outputs() {
    let _guard = settings_test_guard();

    let get_ctx = make_test_context();
    let get_direct = direct_engine_value(&get_ctx, "settings.get", json!({})).await;
    let get_rpc = rpc_dispatch_value(&get_ctx, "settings.get", json!({})).await;
    assert_eq!(get_direct, get_rpc);

    let update_ctx = make_test_context();
    let update_direct = direct_engine_value(
        &update_ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    assert_eq!(update_direct, json!({"success": true}));

    let update_rpc_ctx = make_test_context();
    let update_rpc = rpc_dispatch_value(
        &update_rpc_ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    assert_eq!(update_direct, update_rpc);

    let reset_ctx = make_test_context();
    let _ = direct_engine_value(
        &reset_ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    let reset_direct = direct_engine_value(&reset_ctx, "settings.resetToDefaults", json!({})).await;
    assert_eq!(reset_direct["server"]["heartbeatIntervalMs"], 30_000);

    let reset_rpc_ctx = make_test_context();
    let _ = rpc_dispatch_value(
        &reset_rpc_ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    let reset_rpc = rpc_dispatch_value(&reset_rpc_ctx, "settings.resetToDefaults", json!({})).await;
    assert_eq!(reset_direct, reset_rpc);
}

#[tokio::test]
async fn prompt_snippet_write_outputs_match_direct_engine_outputs() {
    let ctx = make_test_context();

    let create_direct = direct_engine_value(
        &ctx,
        "promptSnippet.create",
        json!({"name": "direct", "text": "body"}),
    )
    .await;
    assert_eq!(create_direct["snippet"]["name"], "direct");

    let create_rpc = rpc_dispatch_value(
        &ctx,
        "promptSnippet.create",
        json!({"name": "rpc", "text": "body"}),
    )
    .await;
    assert_eq!(create_rpc["snippet"]["name"], "rpc");

    let created_id = create_rpc["snippet"]["id"].as_str().unwrap().to_owned();
    let update_direct = direct_engine_value(
        &ctx,
        "promptSnippet.update",
        json!({"id": created_id, "name": "renamed"}),
    )
    .await;
    assert_eq!(update_direct["snippet"]["name"], "renamed");

    let delete_direct = direct_engine_value(
        &ctx,
        "promptSnippet.delete",
        json!({"id": update_direct["snippet"]["id"].as_str().unwrap()}),
    )
    .await;
    assert_eq!(delete_direct, json!({"deleted": true}));
}

#[tokio::test]
async fn prompt_history_write_outputs_match_direct_engine_outputs() {
    let direct_delete_ctx = make_test_context();
    let direct_delete_pool = direct_delete_ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(direct_delete_pool, "delete me").unwrap();
    let direct_delete_page =
        crate::prompt_library::store::list_history(direct_delete_pool, 10, None, None).unwrap();
    let delete_direct = direct_engine_value(
        &direct_delete_ctx,
        "promptHistory.delete",
        json!({"id": direct_delete_page.items[0].id}),
    )
    .await;
    assert_eq!(delete_direct, json!({"deleted": true}));

    let rpc_delete_ctx = make_test_context();
    let rpc_delete_pool = rpc_delete_ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(rpc_delete_pool, "delete me").unwrap();
    let rpc_delete_page =
        crate::prompt_library::store::list_history(rpc_delete_pool, 10, None, None).unwrap();
    let delete_rpc = rpc_dispatch_value(
        &rpc_delete_ctx,
        "promptHistory.delete",
        json!({"id": rpc_delete_page.items[0].id}),
    )
    .await;
    assert_eq!(delete_direct, delete_rpc);

    let direct_clear_ctx = make_test_context();
    let direct_clear_pool = direct_clear_ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(direct_clear_pool, "clear a").unwrap();
    crate::prompt_library::store::record_prompt(direct_clear_pool, "clear b").unwrap();
    let clear_direct =
        direct_engine_value(&direct_clear_ctx, "promptHistory.clear", json!({})).await;
    assert_eq!(clear_direct, json!({"deletedCount": 2}));

    let rpc_clear_ctx = make_test_context();
    let rpc_clear_pool = rpc_clear_ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(rpc_clear_pool, "clear a").unwrap();
    crate::prompt_library::store::record_prompt(rpc_clear_pool, "clear b").unwrap();
    let clear_rpc = rpc_dispatch_value(&rpc_clear_ctx, "promptHistory.clear", json!({})).await;
    assert_eq!(clear_rpc, json!({"deletedCount": 2}));
    assert_eq!(clear_direct, clear_rpc);
}

#[tokio::test]
async fn prompt_history_delete_missing_target_returns_false() {
    let ctx = make_test_context();
    let value = rpc_dispatch_value(
        &ctx,
        "promptHistory.delete",
        json!({"id": "missing-history-id"}),
    )
    .await;
    assert_eq!(value, json!({"deleted": false}));
}

#[tokio::test]
async fn logs_ingest_duplicate_transport_replays_without_second_db_write() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "logs-ingest-retry".to_owned(),
        method: "logs.ingest".to_owned(),
        params: Some(json!({
            "entries": [
                {"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A", "message": "first"},
                {"timestamp": "2026-03-03T14:30:05.200Z", "level": "info", "category": "A", "message": "second"}
            ]
        })),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);
    assert_eq!(
        first.result.as_ref().unwrap(),
        &json!({"success": true, "inserted": 2})
    );

    let conn = ctx.event_store.pool().get().unwrap();
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 2);

    let host = ctx.engine_host.lock().await;
    let replay = host.catalog().invocations().last().unwrap();
    assert!(replay.replayed_from.is_some());
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
}

#[tokio::test]
async fn logs_ingest_errors_complete_idempotency_and_replay() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let entries: Vec<Value> = (0..10_001)
        .map(|i| {
            json!({"timestamp": format!("2026-03-03T14:30:{:02}.{:03}Z", i / 1000, i % 1000), "level": "info", "category": "A", "message": "x"})
        })
        .collect();
    let request = RpcRequest {
        id: "logs-ingest-invalid-retry".to_owned(),
        method: "logs.ingest".to_owned(),
        params: Some(json!({"entries": entries})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert!(!first.success);
    assert!(!second.success);
    assert_eq!(first.error.as_ref().unwrap().code, errors::INVALID_PARAMS);
    assert_eq!(second.error.as_ref().unwrap().code, errors::INVALID_PARAMS);

    let host = ctx.engine_host.lock().await;
    let records = host.catalog().invocations();
    let replay = records.last().unwrap();
    let original = records
        .iter()
        .find(|record| Some(record.invocation_id.clone()) == replay.replayed_from)
        .unwrap();
    assert!(!original.succeeded);
    assert!(!replay.succeeded);
    assert_eq!(original.idempotency_key, replay.idempotency_key);
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
}

#[tokio::test]
async fn logs_ingest_reused_request_id_with_different_payload_is_distinct_command() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);

    for message in ["first", "second"] {
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "same-logs-request-id".to_owned(),
                    method: "logs.ingest".to_owned(),
                    params: Some(json!({
                        "entries": [
                            {"timestamp": format!("2026-03-03T14:30:05.{message}Z"), "level": "info", "category": "A", "message": message}
                        ]
                    })),
                },
                &ctx,
            )
            .await;
        assert!(response.success, "{:?}", response.error);
    }

    let conn = ctx.event_store.pool().get().unwrap();
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 2);
}

#[tokio::test]
async fn logs_ingest_direct_engine_explicit_key_conflict_maps_to_rpc_code() {
    let ctx = make_test_context();
    let function_id = specs::function_id_for_method("logs.ingest").unwrap();
    let first = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"entries": [{"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A", "message": "first"}]}),
            rpc_and_domain_context("logs.ingest", RPC_WRITE_AUTHORITY)
                .with_idempotency_key("logs-explicit-key"),
        ))
        .await;
    assert!(first.error.is_none(), "{:?}", first.error);

    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id,
            json!({"entries": [{"timestamp": "2026-03-03T14:30:05.200Z", "level": "info", "category": "A", "message": "second"}]}),
            rpc_and_domain_context("logs.ingest", RPC_WRITE_AUTHORITY)
                .with_idempotency_key("logs-explicit-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    let rpc = result_to_rpc(conflict).unwrap_err();
    assert_eq!(rpc.code(), errors::IDEMPOTENCY_CONFLICT);
}

#[tokio::test]
async fn logs_ingest_rejects_strict_schema_violations() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let cases = [
        json!({}),
        json!({"entries": "not-array"}),
        json!({"entries": [{"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A"}]}),
        json!({"entries": [{"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A", "message": "x", "extra": true}]}),
        json!({"entries": [], "unexpected": true}),
    ];

    for (index, params) in cases.into_iter().enumerate() {
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("bad-logs-schema-{index}"),
                    method: "logs.ingest".to_owned(),
                    params: Some(params),
                },
                &ctx,
            )
            .await;
        assert!(!response.success, "{index}: {:?}", response.result);
        assert_eq!(response.error.unwrap().code, errors::INVALID_PARAMS);
    }
}

#[tokio::test]
async fn logs_ingest_rejects_empty_rpc_request_id() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let response = registry
        .dispatch(
            RpcRequest {
                id: String::new(),
                method: "logs.ingest".to_owned(),
                params: Some(json!({"entries": []})),
            },
            &ctx,
        )
        .await;
    assert!(!response.success);
    assert_eq!(response.error.unwrap().code, errors::INVALID_PARAMS);
}

#[tokio::test]
async fn prompt_snippet_write_duplicate_transport_replays_without_rerun() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "snippet-create-retry".to_owned(),
        method: "promptSnippet.create".to_owned(),
        params: Some(json!({"name": "retry", "text": "body"})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);

    let snippets = crate::prompt_library::store::list_snippets(ctx.event_store.pool()).unwrap();
    assert_eq!(snippets.len(), 1);

    let host = ctx.engine_host.lock().await;
    let records = host.catalog().invocations();
    let replay = records.last().unwrap();
    assert!(replay.replayed_from.is_some());
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
}

#[tokio::test]
async fn prompt_snippet_reused_request_id_with_different_payload_is_distinct_command() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);

    for name in ["first", "second"] {
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "reused-id".to_owned(),
                    method: "promptSnippet.create".to_owned(),
                    params: Some(json!({"name": name, "text": "body"})),
                },
                &ctx,
            )
            .await;
        assert!(response.success, "{:?}", response.error);
    }

    let snippets = crate::prompt_library::store::list_snippets(ctx.event_store.pool()).unwrap();
    assert_eq!(snippets.len(), 2);
}

#[tokio::test]
async fn prompt_snippet_update_duplicate_transport_replays_without_second_mutation() {
    let ctx = make_test_context();
    let snippet =
        crate::prompt_library::store::create_snippet(ctx.event_store.pool(), "original", "body")
            .unwrap();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "update-retry".to_owned(),
        method: "promptSnippet.update".to_owned(),
        params: Some(json!({"id": snippet.id, "name": "renamed"})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert_eq!(first.result.as_ref().unwrap()["snippet"]["name"], "renamed");

    crate::prompt_library::store::update_snippet(
        ctx.event_store.pool(),
        first.result.as_ref().unwrap()["snippet"]["id"]
            .as_str()
            .unwrap(),
        Some("outside-change".to_owned()),
        None,
    )
    .unwrap();

    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(second.result, first.result);

    let stored = crate::prompt_library::store::get_snippet(
        ctx.event_store.pool(),
        first.result.as_ref().unwrap()["snippet"]["id"]
            .as_str()
            .unwrap(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(stored.name, "outside-change");
}

#[tokio::test]
async fn prompt_snippet_delete_duplicate_transport_replays_true() {
    let ctx = make_test_context();
    let snippet =
        crate::prompt_library::store::create_snippet(ctx.event_store.pool(), "delete", "body")
            .unwrap();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "delete-retry".to_owned(),
        method: "promptSnippet.delete".to_owned(),
        params: Some(json!({"id": snippet.id})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert_eq!(first.result.unwrap(), json!({"deleted": true}));
    assert_eq!(second.result.unwrap(), json!({"deleted": true}));
}

#[tokio::test]
async fn prompt_snippet_write_errors_complete_idempotency_and_replay() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "invalid-create-retry".to_owned(),
        method: "promptSnippet.create".to_owned(),
        params: Some(json!({"name": "   ", "text": "body"})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert!(!first.success);
    assert!(!second.success);
    assert_eq!(first.error.as_ref().unwrap().code, errors::INVALID_PARAMS);
    assert_eq!(second.error.as_ref().unwrap().code, errors::INVALID_PARAMS);
    assert_eq!(
        first.error.as_ref().unwrap().message,
        second.error.as_ref().unwrap().message
    );

    let host = ctx.engine_host.lock().await;
    let records = host.catalog().invocations();
    let replay = records.last().unwrap();
    let original = records
        .iter()
        .find(|record| Some(record.invocation_id.clone()) == replay.replayed_from)
        .unwrap();
    assert!(!original.succeeded);
    assert!(original.error.is_some());
    assert!(!replay.succeeded);
    assert!(replay.error.is_some());
    assert_eq!(original.idempotency_key, replay.idempotency_key);
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
}

#[tokio::test]
async fn prompt_history_delete_duplicate_transport_replays_without_second_delete() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "delete retry").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let id = page.items[0].id.clone();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "history-delete-retry".to_owned(),
        method: "promptHistory.delete".to_owned(),
        params: Some(json!({"id": id})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert_eq!(first.result.unwrap(), json!({"deleted": true}));
    assert_eq!(second.result.unwrap(), json!({"deleted": true}));
}

#[tokio::test]
async fn prompt_history_clear_duplicate_transport_replays_original_count() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "first").unwrap();
    crate::prompt_library::store::record_prompt(pool, "second").unwrap();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    let request = RpcRequest {
        id: "history-clear-retry".to_owned(),
        method: "promptHistory.clear".to_owned(),
        params: Some(json!({})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    assert_eq!(first.result.as_ref().unwrap(), &json!({"deletedCount": 2}));
    crate::prompt_library::store::record_prompt(pool, "after first clear").unwrap();

    let second = registry.dispatch(request, &ctx).await;
    assert_eq!(second.result.as_ref().unwrap(), &json!({"deletedCount": 2}));
    let host = ctx.engine_host.lock().await;
    let replay = host.catalog().invocations().last().unwrap();
    assert!(replay.replayed_from.is_some());
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );

    let remaining = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    assert_eq!(remaining.items.len(), 1);
    assert_eq!(remaining.items[0].text, "after first clear");
}

#[tokio::test]
async fn prompt_history_reused_request_id_with_different_payload_is_distinct_command() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "first").unwrap();
    crate::prompt_library::store::record_prompt(pool, "second").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);

    for item in page.items.iter().take(2) {
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "same-history-request-id".to_owned(),
                    method: "promptHistory.delete".to_owned(),
                    params: Some(json!({"id": item.id})),
                },
                &ctx,
            )
            .await;
        assert!(response.success, "{:?}", response.error);
        assert_eq!(response.result.as_ref().unwrap(), &json!({"deleted": true}));
    }

    let remaining = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    assert_eq!(remaining.items.len(), 0);
}

#[tokio::test]
async fn skill_activate_duplicate_transport_replays_without_second_event() {
    let ctx = make_test_context();
    ctx.skill_registry
        .write()
        .insert(crate::skills::types::SkillMetadata {
            name: "browser".to_owned(),
            display_name: "browser".to_owned(),
            description: "browser skill".to_owned(),
            content: "browser content".to_owned(),
            frontmatter: crate::skills::types::SkillFrontmatter::default(),
            source: crate::skills::types::SkillSource::Global,
            service: "tron".to_owned(),
            scope_dir: String::new(),
            path: String::new(),
            skill_md_path: String::new(),
            additional_files: Vec::new(),
            last_modified: 0,
        });
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("skills"), None)
        .unwrap();
    let payload = json!({"sessionId": session_id, "skillName": "browser"});

    let first = rpc_dispatch_value(&ctx, "skill.activate", payload.clone()).await;
    let second = rpc_dispatch_value(&ctx, "skill.activate", payload).await;
    assert_eq!(first, second);

    let events = ctx
        .event_store
        .get_events_by_type(&session_id, &["skill.activated"], None)
        .unwrap();
    assert_eq!(events.len(), 1);
    let host = ctx.engine_host.lock().await;
    assert!(
        host.catalog()
            .invocations()
            .last()
            .unwrap()
            .replayed_from
            .is_some()
    );
}

#[tokio::test]
async fn events_append_duplicate_transport_replays_without_second_append() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("model", "/tmp", Some("events"), None)
        .unwrap();
    let payload = json!({
        "sessionId": session_id,
        "type": "message.user",
        "payload": {"text": "hello"}
    });

    let first = rpc_dispatch_value(&ctx, "events.append", payload.clone()).await;
    let second = rpc_dispatch_value(&ctx, "events.append", payload).await;
    assert_eq!(first, second);

    let events = ctx
        .event_store
        .get_events_by_type(&session_id, &["message.user"], None)
        .unwrap();
    assert_eq!(events.len(), 1);
    let host = ctx.engine_host.lock().await;
    assert!(
        host.catalog()
            .invocations()
            .last()
            .unwrap()
            .replayed_from
            .is_some()
    );
}

#[tokio::test]
async fn model_switch_outputs_match_direct_engine_and_replays_transport_retry() {
    let ctx = make_test_context();
    let direct_session = ctx
        .session_manager
        .create_session("claude-sonnet-4-6", "/tmp", Some("direct"), None)
        .unwrap();
    let rpc_session = ctx
        .session_manager
        .create_session("claude-sonnet-4-6", "/tmp", Some("rpc"), None)
        .unwrap();

    let direct = direct_engine_value(
        &ctx,
        "model.switch",
        json!({"sessionId": direct_session, "model": "claude-opus-4-6"}),
    )
    .await;
    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: "model-switch-retry".to_owned(),
        method: "model.switch".to_owned(),
        params: Some(json!({"sessionId": rpc_session, "model": "claude-opus-4-6"})),
    };
    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);

    assert_eq!(direct, first.result.clone().unwrap());
    assert_eq!(first.result, second.result);
    let events = ctx
        .event_store
        .get_events_by_type(&rpc_session, &["config.model_switch"], None)
        .unwrap();
    assert_eq!(events.len(), 1);
    let host = ctx.engine_host.lock().await;
    assert!(
        host.catalog()
            .invocations()
            .last()
            .unwrap()
            .replayed_from
            .is_some()
    );
}

#[tokio::test]
async fn reasoning_level_outputs_match_direct_engine_and_replays_transport_retry() {
    let ctx = make_test_context();
    let direct_session = ctx
        .session_manager
        .create_session("claude-sonnet-4-6", "/tmp", Some("direct"), None)
        .unwrap();
    let rpc_session = ctx
        .session_manager
        .create_session("claude-sonnet-4-6", "/tmp", Some("rpc"), None)
        .unwrap();

    let direct = direct_engine_value(
        &ctx,
        "config.setReasoningLevel",
        json!({"sessionId": direct_session, "level": "high"}),
    )
    .await;
    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: "reasoning-retry".to_owned(),
        method: "config.setReasoningLevel".to_owned(),
        params: Some(json!({"sessionId": rpc_session, "level": "high"})),
    };
    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);

    assert_eq!(direct, first.result.clone().unwrap());
    assert_eq!(first.result, second.result);
    let events = ctx
        .event_store
        .get_events_by_type(&rpc_session, &["config.reasoning_level"], None)
        .unwrap();
    assert_eq!(events.len(), 1);
}

#[tokio::test]
async fn memory_retain_outputs_match_direct_engine_and_replays_transport_retry() {
    let ctx = make_test_context();
    let direct_session = ctx
        .session_manager
        .create_session("claude-sonnet-4-6", "/tmp", Some("direct"), None)
        .unwrap();
    let rpc_session = ctx
        .session_manager
        .create_session("claude-sonnet-4-6", "/tmp", Some("rpc"), None)
        .unwrap();

    let direct =
        direct_engine_value(&ctx, "memory.retain", json!({"sessionId": direct_session})).await;
    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: "memory-retain-retry".to_owned(),
        method: "memory.retain".to_owned(),
        params: Some(json!({"sessionId": rpc_session})),
    };
    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);

    assert_eq!(direct, first.result.clone().unwrap());
    assert_eq!(first.result, second.result);
    assert_eq!(first.result.as_ref().unwrap()["retained"], false);
    let host = ctx.engine_host.lock().await;
    assert!(
        host.catalog()
            .invocations()
            .last()
            .unwrap()
            .replayed_from
            .is_some()
    );
}

#[tokio::test]
async fn import_execute_replays_transport_retry_without_second_import() {
    let ctx = make_test_context();
    let dir = tempfile::tempdir().unwrap();
    let session_path = write_import_sample_session(dir.path());
    let registry = migration_parity_registry();
    let request = RpcRequest {
        id: "import-execute-retry".to_owned(),
        method: "import.execute".to_owned(),
        params: Some(json!({
            "sessionPath": session_path.to_string_lossy(),
            "workingDirectory": "/tmp/project",
            "tags": ["test"]
        })),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert_eq!(first.result.as_ref().unwrap()["alreadyImported"], false);
    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);

    let sessions = ctx
        .event_store
        .list_sessions(
            &crate::events::sqlite::repositories::session::ListSessionsOptions::default(),
        )
        .unwrap();
    assert_eq!(sessions.len(), 1);
    let third = registry
        .dispatch(
            RpcRequest {
                id: "import-execute-distinct".to_owned(),
                method: "import.execute".to_owned(),
                params: Some(json!({
                    "sessionPath": session_path.to_string_lossy(),
                    "workingDirectory": "/tmp/project",
                    "tags": ["test"]
                })),
            },
            &ctx,
        )
        .await;
    assert!(third.success, "{:?}", third.error);
    assert_eq!(third.result.as_ref().unwrap()["alreadyImported"], true);
}

#[tokio::test]
async fn high_risk_direct_engine_explicit_key_conflict_maps_to_rpc_code() {
    let ctx = make_test_context();
    let session_id = ctx
        .session_manager
        .create_session("claude-sonnet-4-6", "/tmp", Some("model"), None)
        .unwrap();
    let context = rpc_and_domain_context("model.switch", RPC_WRITE_AUTHORITY)
        .with_session_id(&session_id)
        .with_idempotency_key("explicit-model-switch");
    let first = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("model::switch").unwrap(),
            json!({"sessionId": session_id, "model": "claude-opus-4-6"}),
            context.clone(),
        ))
        .await;
    assert!(first.error.is_none(), "{:?}", first.error);
    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("model::switch").unwrap(),
            json!({"sessionId": session_id, "model": "claude-sonnet-4-6"}),
            context,
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    let rpc = super::engine_error_to_rpc(conflict.error.unwrap());
    assert_eq!(rpc.code(), errors::IDEMPOTENCY_CONFLICT);
}

#[tokio::test]
async fn prompt_history_direct_engine_explicit_key_conflict_maps_to_rpc_code() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "first").unwrap();
    crate::prompt_library::store::record_prompt(pool, "second").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let function_id = specs::function_id_for_method("promptHistory.delete").unwrap();

    let first = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"id": page.items[0].id}),
            rpc_and_domain_context("promptHistory.delete", RPC_WRITE_AUTHORITY)
                .with_idempotency_key("history-explicit-key"),
        ))
        .await;
    assert!(first.error.is_none(), "{:?}", first.error);

    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id,
            json!({"id": page.items[1].id}),
            rpc_and_domain_context("promptHistory.delete", RPC_WRITE_AUTHORITY)
                .with_idempotency_key("history-explicit-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    let rpc = result_to_rpc(conflict).unwrap_err();
    assert_eq!(rpc.code(), errors::IDEMPOTENCY_CONFLICT);
}

#[tokio::test]
async fn settings_update_duplicate_transport_replays_without_second_side_effect() {
    let _guard = settings_test_guard();
    let mut ctx = make_test_context();
    let token_dir = tempfile::tempdir().unwrap();
    let (manager, spawner) = attach_codex_manager(&mut ctx, &token_dir);
    ctx.engine_host = crate::engine::EngineHostHandle::new_in_memory().unwrap();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);
    register_rpc_worker_for_context(&ctx, &registry).unwrap();
    let request = RpcRequest {
        id: "settings-update-retry".to_owned(),
        method: "settings.update".to_owned(),
        params: Some(json!({"settings": {"server": {"codexAppServer": {"port": 4517}}}})),
    };

    let first = registry.dispatch(request.clone(), &ctx).await;
    let second = registry.dispatch(request, &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert!(second.success, "{:?}", second.error);
    assert_eq!(first.result, second.result);
    assert_eq!(spawner.specs.lock().unwrap().len(), 1);
    let status = manager.status().await;
    assert_eq!(status.state, CodexAppServerState::Running);
    assert_eq!(status.endpoint.unwrap().port, 4517);

    let host = ctx.engine_host.lock().await;
    let replay = host.catalog().invocations().last().unwrap();
    assert!(replay.replayed_from.is_some());
    assert_eq!(
        replay
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
}

#[tokio::test]
async fn settings_reset_duplicate_transport_replays_without_second_reset() {
    let _guard = settings_test_guard();
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);

    let seed = registry
        .dispatch(
            RpcRequest {
                id: "settings-seed".to_owned(),
                method: "settings.update".to_owned(),
                params: Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
            },
            &ctx,
        )
        .await;
    assert!(seed.success, "{:?}", seed.error);

    let request = RpcRequest {
        id: "settings-reset-retry".to_owned(),
        method: "settings.resetToDefaults".to_owned(),
        params: Some(json!({})),
    };
    let first = registry.dispatch(request.clone(), &ctx).await;
    assert!(first.success, "{:?}", first.error);
    assert_eq!(
        first.result.as_ref().unwrap()["server"]["heartbeatIntervalMs"],
        30_000
    );

    crate::settings::SettingsStore::new(&ctx.settings_path)
        .update(json!({"server": {"heartbeatIntervalMs": 55_000}}))
        .unwrap();

    let second = registry.dispatch(request, &ctx).await;
    assert!(second.success, "{:?}", second.error);
    assert_eq!(second.result, first.result);
    let saved = crate::settings::SettingsStore::new(&ctx.settings_path)
        .read_sparse_value()
        .unwrap();
    assert_eq!(saved["server"]["heartbeatIntervalMs"], 55_000);
}

#[tokio::test]
async fn settings_update_reused_request_id_with_different_payload_is_distinct_command() {
    let _guard = settings_test_guard();
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    bindings::register_all(&mut registry);

    for interval in [40_000, 45_000] {
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "same-settings-request-id".to_owned(),
                    method: "settings.update".to_owned(),
                    params: Some(
                        json!({"settings": {"server": {"heartbeatIntervalMs": interval}}}),
                    ),
                },
                &ctx,
            )
            .await;
        assert!(response.success, "{:?}", response.error);
    }

    let saved = crate::settings::SettingsStore::new(&ctx.settings_path)
        .read_sparse_value()
        .unwrap();
    assert_eq!(saved["server"]["heartbeatIntervalMs"], 45_000);
}

#[tokio::test]
async fn settings_direct_engine_explicit_key_conflict_maps_to_rpc_code() {
    let _guard = settings_test_guard();
    let ctx = make_test_context();
    let function_id = specs::function_id_for_method("settings.update").unwrap();
    let first = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
            rpc_and_domain_context("settings.update", RPC_WRITE_AUTHORITY)
                .with_idempotency_key("settings-explicit-key"),
        ))
        .await;
    assert!(first.error.is_none(), "{:?}", first.error);

    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id,
            json!({"settings": {"server": {"heartbeatIntervalMs": 45_000}}}),
            rpc_and_domain_context("settings.update", RPC_WRITE_AUTHORITY)
                .with_idempotency_key("settings-explicit-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    let rpc = result_to_rpc(conflict).unwrap_err();
    assert_eq!(rpc.code(), errors::IDEMPOTENCY_CONFLICT);
}

#[tokio::test]
async fn prompt_snippet_direct_engine_explicit_key_conflict_maps_to_rpc_code() {
    let ctx = make_test_context();
    let function_id = specs::function_id_for_method("promptSnippet.create").unwrap();
    let first = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id.clone(),
            json!({"name": "same", "text": "body"}),
            rpc_and_domain_context("promptSnippet.create", RPC_WRITE_AUTHORITY)
                .with_idempotency_key("explicit-key"),
        ))
        .await;
    assert!(first.error.is_none(), "{:?}", first.error);

    let conflict = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            function_id,
            json!({"name": "different", "text": "body"}),
            rpc_and_domain_context("promptSnippet.create", RPC_WRITE_AUTHORITY)
                .with_idempotency_key("explicit-key"),
        ))
        .await;
    assert!(matches!(
        conflict.error,
        Some(EngineError::IdempotencyConflict { .. })
    ));
    let rpc = result_to_rpc(conflict).unwrap_err();
    assert_eq!(rpc.code(), errors::IDEMPOTENCY_CONFLICT);
}

#[tokio::test]
async fn fully_collapsed_json_rpc_methods_dispatch_through_engine() {
    let ctx = make_test_context();
    let result = rpc_dispatch_value(&ctx, "session.list", json!({})).await;
    assert!(result["sessions"].is_array());
}

#[tokio::test]
async fn registered_unaliased_methods_fail_closed_without_fallback_handlers() {
    let ctx = make_test_context();
    let mut registry = MethodRegistry::new();
    registry.register("custom.echo");
    let response = registry
        .dispatch(
            RpcRequest {
                id: "echo".to_owned(),
                method: "custom.echo".to_owned(),
                params: Some(json!({"ok": true})),
            },
            &ctx,
        )
        .await;
    assert!(!response.success);
    let error = response.error.unwrap();
    assert_eq!(error.code, errors::INTERNAL_ERROR);
    assert!(error.message.contains("Internal error"));
}

#[tokio::test]
async fn generic_trigger_records_invocation_ledger_metadata() {
    let ctx = make_test_context();
    let _ = rpc_dispatch_value(&ctx, "system.ping", json!({"protocolVersion": 1})).await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("system.ping").unwrap()
    );
    assert_eq!(record.worker_id, specs::worker_id("system").unwrap());
    assert_eq!(
        record.trigger_id,
        Some(specs::json_rpc_trigger_id_for_method("system.ping").unwrap())
    );
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert_scope(&record.authority_scopes, RPC_READ_AUTHORITY);
    assert_scope(&record.authority_scopes, "system.read");
}

#[tokio::test]
async fn generic_write_records_invocation_ledger_metadata() {
    let ctx = make_test_context();
    let _ = rpc_dispatch_value(
        &ctx,
        "promptSnippet.create",
        json!({"name": "ledger", "text": "body"}),
    )
    .await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("promptSnippet.create").unwrap()
    );
    assert_eq!(
        record.worker_id,
        specs::worker_id("prompt_library").unwrap()
    );
    assert_eq!(
        record.trigger_id,
        Some(specs::json_rpc_trigger_id_for_method("promptSnippet.create").unwrap())
    );
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert_scope(&record.authority_scopes, RPC_WRITE_AUTHORITY);
    assert_scope(&record.authority_scopes, "prompt_library.write");
    assert_eq!(
        record
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
    assert!(
        record
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );
    assert!(record.result_value.is_some());
}

#[tokio::test]
async fn generic_logs_write_records_invocation_ledger_metadata() {
    let ctx = make_test_context();
    let _ = rpc_dispatch_value(
        &ctx,
        "logs.ingest",
        json!({"entries": [{"timestamp": "2026-03-03T14:30:05.100Z", "level": "info", "category": "A", "message": "ledger"}]}),
    )
    .await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("logs.ingest").unwrap()
    );
    assert_eq!(record.worker_id, specs::worker_id("logs").unwrap());
    assert_eq!(
        record.trigger_id,
        Some(specs::json_rpc_trigger_id_for_method("logs.ingest").unwrap())
    );
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert_scope(&record.authority_scopes, RPC_WRITE_AUTHORITY);
    assert_scope(&record.authority_scopes, "logs.write");
    assert_eq!(
        record
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
    assert!(
        record
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );
    assert!(record.result_value.is_some());
}

#[tokio::test]
async fn generic_settings_write_records_invocation_ledger_metadata() {
    let _guard = settings_test_guard();
    let ctx = make_test_context();
    let _ = rpc_dispatch_value(
        &ctx,
        "settings.update",
        json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}}),
    )
    .await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("settings.update").unwrap()
    );
    assert_eq!(record.worker_id, specs::worker_id("settings").unwrap());
    assert_eq!(
        record.trigger_id,
        Some(specs::json_rpc_trigger_id_for_method("settings.update").unwrap())
    );
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert_scope(&record.authority_scopes, RPC_WRITE_AUTHORITY);
    assert_scope(&record.authority_scopes, "settings.write");
    assert_eq!(
        record
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
    assert!(
        record
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );
    assert!(record.result_value.is_some());
}

#[tokio::test]
async fn generic_prompt_history_write_records_invocation_ledger_metadata() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "ledger").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let _ = rpc_dispatch_value(
        &ctx,
        "promptHistory.delete",
        json!({"id": page.items[0].id}),
    )
    .await;
    let host = ctx.engine_host.lock().await;
    let record = host.catalog().invocations().last().unwrap();
    assert_eq!(
        record.function_id,
        specs::function_id_for_method("promptHistory.delete").unwrap()
    );
    assert_eq!(
        record.worker_id,
        specs::worker_id("prompt_library").unwrap()
    );
    assert_eq!(
        record.trigger_id,
        Some(specs::json_rpc_trigger_id_for_method("promptHistory.delete").unwrap())
    );
    assert_eq!(record.actor_kind, ActorKind::Client);
    assert_eq!(record.delivery_mode, DeliveryMode::Sync);
    assert_scope(&record.authority_scopes, RPC_WRITE_AUTHORITY);
    assert_scope(&record.authority_scopes, "prompt_library.write");
    assert_eq!(
        record
            .idempotency_scope
            .as_ref()
            .map(|scope| scope.kind.as_str()),
        Some("system")
    );
    assert!(
        record
            .idempotency_key
            .as_deref()
            .unwrap()
            .starts_with("json-rpc:v1:")
    );
    assert!(record.result_value.is_some());
}
