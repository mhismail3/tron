//! RPC-to-engine migration bridge.
//!
//! JSON-RPC is becoming a trigger transport into engine functions. This module
//! owns the temporary migration inventory for that path: every registered RPC
//! method has an explicit capability spec, selected read methods are already
//! engine-owned, and the remaining handler-only methods are represented as
//! non-routable internal catalog functions until their behavior moves behind
//! the engine boundary.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU16, Ordering};
use std::time::Instant;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EffectClass, EngineError,
    EngineHostHandle, FunctionDefinition, FunctionId, IdempotencyContract,
    InProcessFunctionHandler, Invocation, InvocationResult, Provenance, Result as EngineResult,
    RiskLevel, TraceId, VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
};
use crate::events::EventStore;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::profile_runtime::ProfileRuntime;
use crate::server::rpc::context::{RpcContext, run_blocking_task};
use crate::server::rpc::errors::{self, CLIENT_VERSION_UNSUPPORTED, RpcError};
use crate::server::rpc::handlers::{model, system};
use crate::server::rpc::registry::{HandlerExecutionPolicy, MethodRegistry};
use crate::skills::registry::SkillRegistry;

const RPC_WORKER_ID: &str = "rpc";
const RPC_OWNER_ACTOR: &str = "system";
const RPC_AUTHORITY_GRANT: &str = "rpc-bridge";
const RPC_READ_AUTHORITY: &str = "rpc.read";

/// Migration state for one JSON-RPC method.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RpcMigrationState {
    /// Current handler only; engine catalog entry is metadata/non-routable.
    HandlerOnly,
    /// Engine can mirror through the current handler path during validation.
    Mirrored,
    /// Business behavior is owned by an engine function.
    EngineOwned,
    /// Current method-specific handler is a thin engine adapter.
    ThinAdapter,
    /// Method group is served by a generic RPC-to-engine trigger.
    GenericTrigger,
    /// Historical method intentionally removed.
    Removed,
}

impl RpcMigrationState {
    fn as_str(self) -> &'static str {
        match self {
            Self::HandlerOnly => "handler_only",
            Self::Mirrored => "mirrored",
            Self::EngineOwned => "engine_owned",
            Self::ThinAdapter => "thin_adapter",
            Self::GenericTrigger => "generic_trigger",
            Self::Removed => "removed",
        }
    }
}

/// Idempotency source for a migrated RPC method.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RpcIdempotencyMode {
    /// Read-only method; no idempotency key is required.
    NotRequired,
    /// Temporary migration mode: JSON-RPC request id can seed the engine key.
    JsonRpcRequestIdSeed,
    /// Final engine-native mode: caller must provide an explicit key.
    ExplicitRequired,
}

impl RpcIdempotencyMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::NotRequired => "not_required",
            Self::JsonRpcRequestIdSeed => "json_rpc_request_id_seed",
            Self::ExplicitRequired => "explicit_required",
        }
    }
}

/// Execution path for a migrated RPC method.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RpcExecutionPolicy {
    /// Current handler remains the only executable implementation.
    CurrentHandler,
    /// Engine function delegates to the current handler path for comparison.
    MirrorThroughHandler,
    /// Engine function is the source of behavior.
    EngineFunction,
    /// Thin method-specific RPC handler calls the engine function.
    ThinAdapter,
    /// Generic trigger routes the request without a method-specific handler.
    GenericTrigger,
    /// Removed methods have no executable path.
    Removed,
}

impl RpcExecutionPolicy {
    fn as_str(self) -> &'static str {
        match self {
            Self::CurrentHandler => "current_handler",
            Self::MirrorThroughHandler => "mirror_through_handler",
            Self::EngineFunction => "engine_function",
            Self::ThinAdapter => "thin_adapter",
            Self::GenericTrigger => "generic_trigger",
            Self::Removed => "removed",
        }
    }
}

/// Schema mode for a migrated RPC method.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RpcSchemaMode {
    /// Temporary mirrored/handler-only method with an opaque JSON contract.
    OpaqueTransition,
    /// Engine-owned method with explicit request and response schemas.
    StrictJson,
}

impl RpcSchemaMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::OpaqueTransition => "opaque_transition",
            Self::StrictJson => "strict_json",
        }
    }
}

/// Capability classification for one RPC method.
#[derive(Clone, Debug, PartialEq)]
pub struct RpcCapabilitySpec {
    /// RPC method name.
    pub method: &'static str,
    /// Stable engine function id.
    pub function_id: FunctionId,
    /// Owner worker id.
    pub owner_worker: WorkerId,
    /// Migration state.
    pub migration_state: RpcMigrationState,
    /// Effect class.
    pub effect_class: EffectClass,
    /// Risk level.
    pub risk_level: RiskLevel,
    /// Engine visibility.
    pub visibility: VisibilityScope,
    /// Optional authority scope required to invoke.
    pub authority_scope: Option<&'static str>,
    /// Idempotency mode.
    pub idempotency_mode: RpcIdempotencyMode,
    /// Execution policy.
    pub execution_policy: RpcExecutionPolicy,
    /// Schema mode.
    pub schema_mode: RpcSchemaMode,
    /// Current handler module/group.
    pub handler_module: &'static str,
}

#[derive(Clone, Copy)]
struct RpcCapabilitySpecSeed {
    method: &'static str,
    migration_state: RpcMigrationState,
    schema_mode: RpcSchemaMode,
}

macro_rules! handler_only {
    ($method:literal) => {
        RpcCapabilitySpecSeed {
            method: $method,
            migration_state: RpcMigrationState::HandlerOnly,
            schema_mode: RpcSchemaMode::OpaqueTransition,
        }
    };
}

macro_rules! thin_adapter {
    ($method:literal) => {
        RpcCapabilitySpecSeed {
            method: $method,
            migration_state: RpcMigrationState::ThinAdapter,
            schema_mode: RpcSchemaMode::StrictJson,
        }
    };
}

const RPC_CAPABILITY_SEEDS: &[RpcCapabilitySpecSeed] = &[
    thin_adapter!("system.ping"),
    thin_adapter!("system.getInfo"),
    handler_only!("system.getDiagnostics"),
    handler_only!("system.shutdown"),
    handler_only!("system.checkForUpdates"),
    handler_only!("system.getUpdateStatus"),
    handler_only!("codexApp.status"),
    handler_only!("blob.get"),
    handler_only!("session.create"),
    handler_only!("session.resume"),
    handler_only!("session.list"),
    handler_only!("session.delete"),
    handler_only!("session.fork"),
    handler_only!("session.getHead"),
    handler_only!("session.getState"),
    handler_only!("session.getHistory"),
    handler_only!("session.reconstruct"),
    handler_only!("session.archive"),
    handler_only!("session.unarchive"),
    handler_only!("session.archiveOlderThan"),
    handler_only!("session.export"),
    handler_only!("agent.prompt"),
    handler_only!("agent.abort"),
    handler_only!("agent.abortTool"),
    handler_only!("agent.status"),
    handler_only!("agent.queuePrompt"),
    handler_only!("agent.dequeuePrompt"),
    handler_only!("agent.clearQueue"),
    handler_only!("agent.deliverSubagentResults"),
    handler_only!("agent.submitConfirmation"),
    handler_only!("agent.submitAnswers"),
    thin_adapter!("model.list"),
    handler_only!("model.switch"),
    handler_only!("config.setReasoningLevel"),
    handler_only!("context.getSnapshot"),
    handler_only!("context.getDetailedSnapshot"),
    handler_only!("context.getAuditTrace"),
    handler_only!("context.shouldCompact"),
    handler_only!("context.previewCompaction"),
    handler_only!("context.confirmCompaction"),
    handler_only!("context.canAcceptTurn"),
    handler_only!("context.clear"),
    handler_only!("context.compact"),
    handler_only!("events.getHistory"),
    handler_only!("events.getSince"),
    handler_only!("events.subscribe"),
    handler_only!("events.unsubscribe"),
    handler_only!("events.append"),
    thin_adapter!("settings.get"),
    handler_only!("settings.update"),
    handler_only!("settings.resetToDefaults"),
    handler_only!("auth.get"),
    handler_only!("auth.update"),
    handler_only!("auth.clear"),
    handler_only!("auth.oauthBegin"),
    handler_only!("auth.oauthComplete"),
    handler_only!("auth.renameAccount"),
    handler_only!("auth.setActive"),
    handler_only!("auth.removeAccount"),
    handler_only!("auth.removeApiKey"),
    handler_only!("tool.result"),
    handler_only!("message.delete"),
    handler_only!("logs.ingest"),
    thin_adapter!("logs.recent"),
    handler_only!("memory.retain"),
    handler_only!("mcp.status"),
    handler_only!("mcp.addServer"),
    handler_only!("mcp.removeServer"),
    handler_only!("mcp.enableServer"),
    handler_only!("mcp.disableServer"),
    handler_only!("mcp.restartServer"),
    handler_only!("mcp.reload"),
    handler_only!("mcp.listTools"),
    thin_adapter!("skill.list"),
    handler_only!("skill.get"),
    handler_only!("skill.refresh"),
    handler_only!("skill.activate"),
    handler_only!("skill.deactivate"),
    handler_only!("skill.active"),
    handler_only!("filesystem.listDir"),
    handler_only!("filesystem.getHome"),
    handler_only!("filesystem.createDir"),
    handler_only!("file.read"),
    handler_only!("tree.getVisualization"),
    handler_only!("tree.getBranches"),
    handler_only!("tree.getSubtree"),
    handler_only!("tree.getAncestors"),
    handler_only!("tree.compareBranches"),
    handler_only!("import.listSources"),
    handler_only!("import.listSessions"),
    handler_only!("import.previewSession"),
    handler_only!("import.execute"),
    handler_only!("browser.startStream"),
    handler_only!("browser.stopStream"),
    handler_only!("browser.getStatus"),
    handler_only!("display.stopStream"),
    handler_only!("job.background"),
    handler_only!("job.cancel"),
    handler_only!("job.list"),
    handler_only!("job.subscribe"),
    handler_only!("job.unsubscribe"),
    handler_only!("worktree.getStatus"),
    handler_only!("worktree.isGitRepo"),
    handler_only!("worktree.commit"),
    handler_only!("worktree.merge"),
    handler_only!("worktree.list"),
    handler_only!("worktree.getDiff"),
    handler_only!("worktree.acquire"),
    handler_only!("worktree.release"),
    handler_only!("worktree.listSessionBranches"),
    handler_only!("worktree.getCommittedDiff"),
    handler_only!("worktree.deleteBranch"),
    handler_only!("worktree.pruneBranches"),
    handler_only!("worktree.stageFiles"),
    handler_only!("worktree.unstageFiles"),
    handler_only!("worktree.discardFiles"),
    handler_only!("transcribe.audio"),
    handler_only!("transcribe.listModels"),
    handler_only!("transcribe.downloadModel"),
    handler_only!("device.register"),
    handler_only!("device.unregister"),
    handler_only!("device.respond"),
    handler_only!("plan.enter"),
    handler_only!("plan.exit"),
    handler_only!("plan.getState"),
    handler_only!("voiceNotes.save"),
    handler_only!("voiceNotes.list"),
    handler_only!("voiceNotes.delete"),
    handler_only!("git.clone"),
    handler_only!("git.syncMain"),
    handler_only!("git.push"),
    handler_only!("git.listLocalBranches"),
    handler_only!("git.listRemoteBranches"),
    handler_only!("worktree.finalizeSession"),
    handler_only!("worktree.rebaseOnMain"),
    handler_only!("worktree.startMerge"),
    handler_only!("worktree.listConflicts"),
    handler_only!("worktree.resolveConflict"),
    handler_only!("worktree.continueMerge"),
    handler_only!("worktree.abortMerge"),
    handler_only!("worktree.resolveConflictsWithSubagent"),
    handler_only!("repo.listSessions"),
    handler_only!("repo.getDivergence"),
    handler_only!("sandbox.listContainers"),
    handler_only!("sandbox.startContainer"),
    handler_only!("sandbox.stopContainer"),
    handler_only!("sandbox.killContainer"),
    handler_only!("sandbox.removeContainer"),
    handler_only!("notifications.list"),
    handler_only!("notifications.markRead"),
    handler_only!("notifications.markAllRead"),
    handler_only!("promptHistory.list"),
    handler_only!("promptHistory.delete"),
    handler_only!("promptHistory.clear"),
    handler_only!("promptSnippet.list"),
    handler_only!("promptSnippet.get"),
    handler_only!("promptSnippet.create"),
    handler_only!("promptSnippet.update"),
    handler_only!("promptSnippet.delete"),
    handler_only!("cron.list"),
    handler_only!("cron.get"),
    handler_only!("cron.create"),
    handler_only!("cron.update"),
    handler_only!("cron.delete"),
    handler_only!("cron.run"),
    handler_only!("cron.status"),
    handler_only!("cron.getRuns"),
];

/// Build and validate the complete bridge spec set for a registry.
pub fn capability_specs(registry: &MethodRegistry) -> EngineResult<Vec<RpcCapabilitySpec>> {
    validate_seed_uniqueness()?;
    let registered = registry.methods().into_iter().collect::<BTreeSet<_>>();
    let seeded = RPC_CAPABILITY_SEEDS
        .iter()
        .map(|seed| seed.method.to_owned())
        .collect::<BTreeSet<_>>();

    if let Some(method) = registered.difference(&seeded).next() {
        return Err(EngineError::PolicyViolation(format!(
            "RPC method {method} is registered without an engine bridge spec"
        )));
    }
    if let Some(method) = seeded.difference(&registered).next() {
        let seed = RPC_CAPABILITY_SEEDS
            .iter()
            .find(|candidate| candidate.method == method.as_str())
            .expect("seed came from the seed list");
        if seed.migration_state != RpcMigrationState::Removed {
            return Err(EngineError::PolicyViolation(format!(
                "RPC bridge spec {method} does not match a registered method"
            )));
        }
    }

    let mut specs = Vec::with_capacity(RPC_CAPABILITY_SEEDS.len());
    for seed in RPC_CAPABILITY_SEEDS {
        if seed.migration_state == RpcMigrationState::Removed {
            continue;
        }
        let policy = registry.method_policy(seed.method).ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "RPC bridge spec {} has no registry policy",
                seed.method
            ))
        })?;
        let spec = spec_from_seed(*seed, policy)?;
        if spec.visibility.is_agent_visible()
            && spec.effect_class.is_mutating()
            && spec.idempotency_mode == RpcIdempotencyMode::NotRequired
        {
            return Err(EngineError::PolicyViolation(format!(
                "agent-visible mutating RPC method {} lacks idempotency",
                spec.method
            )));
        }
        specs.push(spec);
    }
    Ok(specs)
}

/// Register the in-process RPC worker and its current capability inventory.
pub fn register_rpc_worker_for_context(
    ctx: &RpcContext,
    registry: &MethodRegistry,
) -> EngineResult<()> {
    register_rpc_worker(&ctx.engine_host, registry, RpcEngineDeps::from_context(ctx))
}

/// Invoke an engine-owned RPC method from a thin method-specific handler.
pub async fn invoke_thin_adapter(
    ctx: &RpcContext,
    method: &'static str,
    params: Option<Value>,
) -> Result<Value, RpcError> {
    let payload = payload_for_thin_adapter(ctx, method, params);
    let function_id = function_id_for_method(method).map_err(engine_error_to_rpc)?;
    let invocation = Invocation::new_sync(function_id, payload, rpc_context());
    let result = ctx.engine_host.invoke(invocation).await;
    result_to_rpc(result)
}

fn register_rpc_worker(
    handle: &EngineHostHandle,
    registry: &MethodRegistry,
    deps: RpcEngineDeps,
) -> EngineResult<()> {
    let specs = capability_specs(registry)?;
    handle.register_worker_for_setup(rpc_worker(), false)?;
    for spec in specs {
        let handler = (spec.execution_policy == RpcExecutionPolicy::ThinAdapter).then(|| {
            Arc::new(RpcReadFunctionHandler {
                method: spec.method,
                deps: deps.clone(),
            }) as Arc<dyn InProcessFunctionHandler>
        });
        handle.register_function_for_setup(function_definition_for_spec(&spec), handler, false)?;
    }
    Ok(())
}

fn validate_seed_uniqueness() -> EngineResult<()> {
    let mut seen = BTreeSet::new();
    for seed in RPC_CAPABILITY_SEEDS {
        if !seen.insert(seed.method) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate RPC bridge spec for {}",
                seed.method
            )));
        }
    }
    Ok(())
}

fn spec_from_seed(
    seed: RpcCapabilitySpecSeed,
    policy: HandlerExecutionPolicy,
) -> EngineResult<RpcCapabilitySpec> {
    let execution_policy = match seed.migration_state {
        RpcMigrationState::HandlerOnly => RpcExecutionPolicy::CurrentHandler,
        RpcMigrationState::Mirrored => RpcExecutionPolicy::MirrorThroughHandler,
        RpcMigrationState::EngineOwned => RpcExecutionPolicy::EngineFunction,
        RpcMigrationState::ThinAdapter => RpcExecutionPolicy::ThinAdapter,
        RpcMigrationState::GenericTrigger => RpcExecutionPolicy::GenericTrigger,
        RpcMigrationState::Removed => RpcExecutionPolicy::Removed,
    };
    let effect_class = if seed.migration_state == RpcMigrationState::ThinAdapter {
        EffectClass::PureRead
    } else {
        effect_class_for_method(seed.method, policy)
    };
    let visibility = if seed.migration_state == RpcMigrationState::ThinAdapter {
        VisibilityScope::System
    } else {
        VisibilityScope::Internal
    };
    Ok(RpcCapabilitySpec {
        method: seed.method,
        function_id: function_id_for_method(seed.method)?,
        owner_worker: worker_id(RPC_WORKER_ID)?,
        migration_state: seed.migration_state,
        effect_class,
        risk_level: risk_for_method(seed.method, effect_class),
        visibility,
        authority_scope: (seed.migration_state == RpcMigrationState::ThinAdapter)
            .then_some(RPC_READ_AUTHORITY),
        idempotency_mode: if effect_class.is_mutating() {
            RpcIdempotencyMode::JsonRpcRequestIdSeed
        } else {
            RpcIdempotencyMode::NotRequired
        },
        execution_policy,
        schema_mode: seed.schema_mode,
        handler_module: handler_module_for_method(seed.method),
    })
}

fn effect_class_for_method(method: &str, policy: HandlerExecutionPolicy) -> EffectClass {
    if policy != HandlerExecutionPolicy::Mutating {
        return EffectClass::PureRead;
    }
    if matches!(method, "events.append" | "logs.ingest") {
        return EffectClass::AppendOnlyEvent;
    }
    if matches!(
        method,
        "system.shutdown"
            | "message.delete"
            | "voiceNotes.delete"
            | "promptHistory.delete"
            | "promptHistory.clear"
            | "promptSnippet.delete"
            | "worktree.deleteBranch"
            | "worktree.discardFiles"
            | "sandbox.killContainer"
            | "sandbox.removeContainer"
    ) {
        return EffectClass::IrreversibleSideEffect;
    }
    if method.starts_with("git.")
        || method.starts_with("mcp.")
        || method.starts_with("browser.")
        || method.starts_with("display.")
        || method.starts_with("device.")
        || method.starts_with("transcribe.")
        || method.starts_with("sandbox.")
    {
        return EffectClass::ExternalSideEffect;
    }
    EffectClass::IdempotentWrite
}

fn risk_for_method(method: &str, effect: EffectClass) -> RiskLevel {
    if matches!(method, "git.push" | "system.shutdown") {
        RiskLevel::Critical
    } else if matches!(effect, EffectClass::IrreversibleSideEffect) {
        RiskLevel::High
    } else if effect.is_mutating() {
        RiskLevel::Medium
    } else {
        RiskLevel::Low
    }
}

fn function_definition_for_spec(spec: &RpcCapabilitySpec) -> FunctionDefinition {
    let mut definition = FunctionDefinition::new(
        spec.function_id.clone(),
        spec.owner_worker.clone(),
        format!("RPC compatibility capability for {}", spec.method),
        spec.visibility.clone(),
        spec.effect_class,
    )
    .with_risk(spec.risk_level)
    .with_provenance(Provenance::system());
    if let Some(scope) = spec.authority_scope {
        definition =
            definition.with_required_authority(crate::engine::AuthorityRequirement::scope(scope));
    }
    if spec.effect_class.is_mutating() {
        definition =
            definition.with_idempotency(IdempotencyContract::caller_session_engine_ledger());
    }
    if spec.schema_mode == RpcSchemaMode::StrictJson {
        if let Some(request_schema) = request_schema_for_method(spec.method) {
            definition = definition.with_request_schema(request_schema);
        }
        if let Some(response_schema) = response_schema_for_method(spec.method) {
            definition = definition.with_response_schema(response_schema);
        }
    } else {
        definition.opaque_response = true;
    }
    definition.metadata = json!({
        "transport": "json_rpc",
        "method": spec.method,
        "migrationState": spec.migration_state.as_str(),
        "executionPolicy": spec.execution_policy.as_str(),
        "schemaMode": spec.schema_mode.as_str(),
        "idempotencyMode": spec.idempotency_mode.as_str(),
        "handlerModule": spec.handler_module,
    });
    definition
}

fn rpc_worker() -> WorkerDefinition {
    WorkerDefinition::new(
        worker_id(RPC_WORKER_ID).expect("valid static rpc worker id"),
        WorkerKind::Compatibility,
        actor_id(RPC_OWNER_ACTOR).expect("valid static rpc owner actor"),
        grant_id(RPC_AUTHORITY_GRANT).expect("valid static rpc authority grant"),
    )
    .with_namespace_claim(RPC_WORKER_ID)
}

#[derive(Clone)]
struct RpcEngineDeps {
    orchestrator: Arc<Orchestrator>,
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    profile_runtime: Arc<ProfileRuntime>,
    server_start_time: Instant,
    auth_path: PathBuf,
    ws_port: Arc<AtomicU16>,
    onboarded_marker_path: PathBuf,
}

impl RpcEngineDeps {
    fn from_context(ctx: &RpcContext) -> Self {
        Self {
            orchestrator: Arc::clone(&ctx.orchestrator),
            session_manager: Arc::clone(&ctx.session_manager),
            event_store: Arc::clone(&ctx.event_store),
            skill_registry: Arc::clone(&ctx.skill_registry),
            profile_runtime: Arc::clone(&ctx.profile_runtime),
            server_start_time: ctx.server_start_time,
            auth_path: ctx.auth_path.clone(),
            ws_port: Arc::clone(&ctx.ws_port),
            onboarded_marker_path: ctx.onboarded_marker_path.clone(),
        }
    }
}

struct RpcReadFunctionHandler {
    method: &'static str,
    deps: RpcEngineDeps,
}

#[async_trait]
impl InProcessFunctionHandler for RpcReadFunctionHandler {
    async fn invoke(&self, invocation: Invocation) -> EngineResult<Value> {
        rpc_read_value(self.method, &invocation, &self.deps)
            .await
            .map_err(rpc_error_to_engine)
    }
}

async fn rpc_read_value(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    let allow_rpc_context = matches!(invocation.causal_context.actor_kind, ActorKind::Client);
    match method {
        "system.ping" => ping_value(Some(payload)),
        "system.getInfo" => Ok(system_info_value(payload, deps, allow_rpc_context)),
        "settings.get" => {
            serde_json::to_value(&deps.profile_runtime.current().settings).map_err(|error| {
                RpcError::Internal {
                    message: error.to_string(),
                }
            })
        }
        "model.list" => {
            let auth_json_path = allow_rpc_context
                .then(|| {
                    payload
                        .pointer("/__rpcContext/authPath")
                        .and_then(Value::as_str)
                        .map(PathBuf::from)
                })
                .flatten()
                .unwrap_or_else(|| deps.auth_path.clone());
            let auth_path = crate::llm::auth::openai::infer_auth_path(&auth_json_path, None)
                .unwrap_or(crate::llm::openai::types::OpenAIAuthPath::ChatGptCodex);
            Ok(json!({ "models": model::known_models(auth_path).await }))
        }
        "skill.list" => Ok(skill_list_value(Some(payload), deps)),
        "logs.recent" => recent_logs_value(Some(payload.clone()), deps).await,
        _ => Err(RpcError::Internal {
            message: format!("RPC method {method} is not engine-owned"),
        }),
    }
}

fn ping_value(params: Option<&Value>) -> Result<Value, RpcError> {
    let client_protocol_raw = params
        .and_then(|p| p.get("protocolVersion"))
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::InvalidParams {
            message: "system.ping requires numeric protocolVersion".into(),
        })?;
    let client_protocol =
        u32::try_from(client_protocol_raw).map_err(|_| RpcError::InvalidParams {
            message: "system.ping protocolVersion is too large".into(),
        })?;
    let client_version = params
        .and_then(|p| p.get("clientVersion"))
        .and_then(Value::as_str)
        .map(String::from);

    if client_protocol < system::MIN_CLIENT_PROTOCOL_VERSION {
        return Err(RpcError::Custom {
            code: CLIENT_VERSION_UNSUPPORTED.to_string(),
            message: format!(
                "Client protocol version {client_protocol} is below the minimum supported version \
                 {}. Please upgrade the Tron client.",
                system::MIN_CLIENT_PROTOCOL_VERSION
            ),
            details: Some(json!({
                "clientProtocolVersion": client_protocol,
                "minClientProtocolVersion": system::MIN_CLIENT_PROTOCOL_VERSION,
                "serverProtocolVersion": system::CURRENT_PROTOCOL_VERSION,
                "serverVersion": env!("CARGO_PKG_VERSION"),
                "clientVersion": client_version,
            })),
        });
    }

    Ok(json!({
        "pong": true,
        "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "serverVersion": env!("CARGO_PKG_VERSION"),
        "serverProtocolVersion": system::CURRENT_PROTOCOL_VERSION,
        "minClientProtocolVersion": system::MIN_CLIENT_PROTOCOL_VERSION,
        "compatible": true,
    }))
}

fn system_info_value(payload: &Value, deps: &RpcEngineDeps, allow_rpc_context: bool) -> Value {
    let marker_path = allow_rpc_context
        .then(|| {
            payload
                .pointer("/__rpcContext/onboardedMarkerPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .flatten()
        .unwrap_or_else(|| deps.onboarded_marker_path.clone());
    json!({
        "version": env!("CARGO_PKG_VERSION"),
        "uptime": deps.server_start_time.elapsed().as_secs(),
        "activeSessions": deps.orchestrator.active_session_count(),
        "platform": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "runtime": "agent",
        "port": deps.ws_port.load(Ordering::SeqCst),
        "tailscaleIp": deps.profile_runtime.current().settings.server.tailscale_ip,
        "paired": crate::server::onboarding::is_onboarded(&marker_path),
    })
}

fn payload_for_thin_adapter(
    ctx: &RpcContext,
    method: &'static str,
    params: Option<Value>,
) -> Value {
    let mut payload = params.unwrap_or_else(|| json!({}));
    if method == "system.getInfo" {
        if !payload.is_object() {
            payload = json!({});
        }
        if let Some(object) = payload.as_object_mut() {
            object.insert(
                "__rpcContext".to_owned(),
                json!({
                    "onboardedMarkerPath": ctx.onboarded_marker_path.to_string_lossy(),
                }),
            );
        }
    }
    if method == "model.list" {
        if !payload.is_object() {
            payload = json!({});
        }
        if let Some(object) = payload.as_object_mut() {
            object.insert(
                "__rpcContext".to_owned(),
                json!({
                    "authPath": ctx.auth_path.to_string_lossy(),
                }),
            );
        }
    }
    payload
}

fn skill_list_value(params: Option<&Value>, deps: &RpcEngineDeps) -> Value {
    let working_dir = resolve_skill_working_dir(params, deps);
    let mut registry = deps.skill_registry.write();
    let _ = registry.refresh_if_stale(&working_dir);
    let skills = registry.list(None);
    json!({ "skills": skills })
}

fn resolve_skill_working_dir(params: Option<&Value>, deps: &RpcEngineDeps) -> String {
    if let Some(wd) = params
        .and_then(|value| value.get("workingDirectory"))
        .and_then(Value::as_str)
    {
        return wd.to_owned();
    }
    if let Some(session_id) = params
        .and_then(|value| value.get("sessionId"))
        .and_then(Value::as_str)
    {
        if let Ok(Some(session)) = deps.session_manager.get_session(session_id) {
            return session.working_directory;
        }
    }
    "/tmp".to_owned()
}

const DEFAULT_RECENT_LIMIT: u32 = 200;
const MAX_RECENT_LIMIT: u32 = 1_000;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogsParams {
    #[serde(default = "default_recent_limit")]
    limit: u32,
}

fn default_recent_limit() -> u32 {
    DEFAULT_RECENT_LIMIT
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogsResult {
    entries: Vec<RecentLogEntry>,
    count: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecentLogEntry {
    id: i64,
    timestamp: String,
    level: String,
    component: String,
    message: String,
    origin: Option<String>,
    session_id: Option<String>,
    error_message: Option<String>,
}

async fn recent_logs_value(params: Option<Value>, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let params: RecentLogsParams = match params {
        Some(value) => serde_json::from_value(value).map_err(|error| RpcError::InvalidParams {
            message: format!("Invalid params: {error}"),
        })?,
        None => RecentLogsParams {
            limit: DEFAULT_RECENT_LIMIT,
        },
    };

    if params.limit > MAX_RECENT_LIMIT {
        return Err(RpcError::InvalidParams {
            message: format!("limit must be <= {MAX_RECENT_LIMIT}"),
        });
    }

    let limit = i64::from(params.limit);
    let pool = deps.event_store.pool().clone();
    let result = run_blocking_task("logs.recent", move || {
        let conn = pool.get().map_err(|error| RpcError::Internal {
            message: format!("Failed to get DB connection: {error}"),
        })?;
        let mut stmt = conn
            .prepare(
                "SELECT id, timestamp, level, component, message, origin, session_id, error_message \
                 FROM logs ORDER BY id DESC LIMIT ?1",
            )
            .map_err(|error| RpcError::Internal {
                message: format!("Failed to prepare logs query: {error}"),
            })?;
        let rows = stmt
            .query_map([limit], |row| {
                Ok(RecentLogEntry {
                    id: row.get(0)?,
                    timestamp: row.get(1)?,
                    level: row.get(2)?,
                    component: row.get(3)?,
                    message: row.get(4)?,
                    origin: row.get(5)?,
                    session_id: row.get(6)?,
                    error_message: row.get(7)?,
                })
            })
            .map_err(|error| RpcError::Internal {
                message: format!("Failed to read logs: {error}"),
            })?;

        let mut entries = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| RpcError::Internal {
                message: format!("Failed to decode logs: {error}"),
            })?;
        entries.reverse();
        Ok(RecentLogsResult {
            count: entries.len(),
            entries,
        })
    })
    .await?;
    serde_json::to_value(result).map_err(|error| RpcError::Internal {
        message: error.to_string(),
    })
}

fn rpc_error_to_engine(error: RpcError) -> EngineError {
    let body = error.to_error_body();
    EngineError::AdapterFailure {
        adapter: "rpc".to_owned(),
        code: body.code,
        message: body.message,
        details: body.details,
    }
}

fn result_to_rpc(result: InvocationResult) -> Result<Value, RpcError> {
    if let Some(error) = result.error {
        return Err(engine_error_to_rpc(error));
    }
    Ok(result.value.unwrap_or(Value::Null))
}

fn engine_error_to_rpc(error: EngineError) -> RpcError {
    match error {
        EngineError::AdapterFailure {
            adapter: _,
            code,
            message,
            details,
        } => rpc_error_from_parts(&code, message, details),
        EngineError::SchemaViolation { message, .. } => RpcError::InvalidParams { message },
        EngineError::PolicyViolation(message) => RpcError::InvalidParams { message },
        EngineError::NotFound { id, .. } => RpcError::NotFound {
            code: errors::NOT_FOUND.to_owned(),
            message: format!("Engine function '{id}' not found"),
        },
        other => RpcError::Internal {
            message: other.to_string(),
        },
    }
}

fn rpc_error_from_parts(code: &str, message: String, details: Option<Value>) -> RpcError {
    match code {
        errors::INVALID_PARAMS => RpcError::InvalidParams { message },
        errors::INTERNAL_ERROR => RpcError::Internal { message },
        errors::NOT_AVAILABLE => RpcError::NotAvailable { message },
        errors::NOT_FOUND => RpcError::NotFound {
            code: errors::NOT_FOUND.to_owned(),
            message,
        },
        _ => RpcError::Custom {
            code: code.to_owned(),
            message,
            details,
        },
    }
}

fn rpc_context() -> CausalContext {
    CausalContext::new(
        actor_id("rpc-client").expect("valid static rpc actor id"),
        ActorKind::Client,
        grant_id(RPC_AUTHORITY_GRANT).expect("valid static rpc grant id"),
        TraceId::generate(),
    )
    .with_scope(RPC_READ_AUTHORITY)
}

fn request_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "system.ping" => json!({
            "type": "object",
            "additionalProperties": true,
            "properties": {
                "protocolVersion": {"type": "integer"},
                "clientVersion": {"type": "string"}
            }
        }),
        "logs.recent" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"}
            }
        }),
        "skill.list" => json!({
            "type": "object",
            "additionalProperties": true,
            "properties": {
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"}
            }
        }),
        "system.getInfo" | "settings.get" | "model.list" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        _ => return None,
    })
}

fn response_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "system.ping" => json!({
            "type": "object",
            "required": [
                "pong",
                "timestamp",
                "serverVersion",
                "serverProtocolVersion",
                "minClientProtocolVersion",
                "compatible"
            ],
            "additionalProperties": false,
            "properties": {
                "pong": {"type": "boolean"},
                "timestamp": {"type": "string"},
                "serverVersion": {"type": "string"},
                "serverProtocolVersion": {"type": "integer"},
                "minClientProtocolVersion": {"type": "integer"},
                "compatible": {"type": "boolean"}
            }
        }),
        "system.getInfo" => json!({
            "type": "object",
            "required": [
                "version",
                "uptime",
                "activeSessions",
                "platform",
                "arch",
                "runtime",
                "port",
                "tailscaleIp",
                "paired"
            ],
            "additionalProperties": false,
            "properties": {
                "version": {"type": "string"},
                "uptime": {"type": "integer"},
                "activeSessions": {"type": "integer"},
                "platform": {"type": "string"},
                "arch": {"type": "string"},
                "runtime": {"type": "string"},
                "port": {"type": "integer"},
                "tailscaleIp": {"type": ["string", "null"]},
                "paired": {"type": "boolean"}
            }
        }),
        "settings.get" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "model.list" => json!({
            "type": "object",
            "required": ["models"],
            "additionalProperties": false,
            "properties": {
                "models": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                }
            }
        }),
        "skill.list" => json!({
            "type": "object",
            "required": ["skills"],
            "additionalProperties": false,
            "properties": {
                "skills": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                }
            }
        }),
        "logs.recent" => json!({
            "type": "object",
            "required": ["entries", "count"],
            "additionalProperties": false,
            "properties": {
                "entries": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                },
                "count": {"type": "integer"}
            }
        }),
        _ => return None,
    })
}

fn handler_module_for_method(method: &str) -> &'static str {
    let prefix = method.split('.').next().unwrap_or(method);
    match prefix {
        "codexApp" => "codex_app",
        "config" => "model",
        "file" | "filesystem" => "filesystem",
        "repo" => "git_workflow",
        "transcribe" => "transcription",
        "voiceNotes" => "voice_notes",
        "promptHistory" | "promptSnippet" => "prompt_library",
        other => match other {
            "agent" => "agent",
            "auth" => "auth",
            "blob" => "blob",
            "browser" => "browser",
            "context" => "context",
            "cron" => "cron",
            "device" => "device",
            "display" => "display",
            "events" => "events",
            "git" => "git_workflow",
            "import" => "import",
            "job" => "job",
            "logs" => "logs",
            "mcp" => "mcp",
            "memory" => "memory",
            "message" => "message",
            "model" => "model",
            "notifications" => "notifications",
            "plan" => "plan",
            "sandbox" => "sandbox",
            "session" => "session",
            "settings" => "settings",
            "skill" => "skills",
            "system" => "system",
            "tool" => "tool",
            "tree" => "tree",
            "worktree" => "worktree",
            _ => "unknown",
        },
    }
}

fn function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    FunctionId::new(format!("rpc::{method}"))
}

fn worker_id(value: &str) -> EngineResult<WorkerId> {
    WorkerId::new(value)
}

fn actor_id(value: &str) -> EngineResult<ActorId> {
    ActorId::new(value)
}

fn grant_id(value: &str) -> EngineResult<AuthorityGrantId> {
    AuthorityGrantId::new(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::types::RpcRequest;

    async fn direct_engine_value(ctx: &RpcContext, method: &'static str, payload: Value) -> Value {
        let result = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                function_id_for_method(method).unwrap(),
                payload,
                rpc_context(),
            ))
            .await;
        assert!(result.error.is_none(), "{method}: {:?}", result.error);
        result.value.unwrap()
    }

    async fn rpc_dispatch_value(ctx: &RpcContext, method: &str, params: Value) -> Value {
        let mut registry = MethodRegistry::new();
        handlers::register_all(&mut registry);
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

    fn normalize_unstable_fields(method: &str, mut value: Value) -> Value {
        if method == "system.ping" {
            value["timestamp"] = json!("<timestamp>");
        }
        if method == "system.getInfo" {
            value["uptime"] = json!(0);
        }
        value
    }

    #[test]
    fn bridge_specs_cover_every_registered_rpc_method() {
        let mut registry = MethodRegistry::new();
        handlers::register_all(&mut registry);
        let specs = capability_specs(&registry).unwrap();
        assert_eq!(registry.methods().len(), 167);
        assert_eq!(specs.len(), registry.methods().len());

        let spec_methods = specs
            .iter()
            .map(|spec| spec.method.to_owned())
            .collect::<BTreeSet<_>>();
        let registry_methods = registry.methods().into_iter().collect::<BTreeSet<_>>();
        assert_eq!(spec_methods, registry_methods);
    }

    #[test]
    fn bridge_specs_classify_selected_reads_as_thin_adapters() {
        let mut registry = MethodRegistry::new();
        handlers::register_all(&mut registry);
        let specs = capability_specs(&registry).unwrap();
        for method in [
            "system.ping",
            "system.getInfo",
            "settings.get",
            "model.list",
            "skill.list",
            "logs.recent",
        ] {
            let spec = specs.iter().find(|spec| spec.method == method).unwrap();
            assert_eq!(spec.migration_state, RpcMigrationState::ThinAdapter);
            assert_eq!(spec.effect_class, EffectClass::PureRead);
            assert_eq!(spec.schema_mode, RpcSchemaMode::StrictJson);
            assert_eq!(spec.visibility, VisibilityScope::System);
        }
    }

    #[test]
    fn bridge_specs_classify_representative_effect_and_risk_levels() {
        let mut registry = MethodRegistry::new();
        handlers::register_all(&mut registry);
        let specs = capability_specs(&registry).unwrap();
        let find = |method: &str| specs.iter().find(|spec| spec.method == method).unwrap();

        let session_list = find("session.list");
        assert_eq!(session_list.effect_class, EffectClass::PureRead);
        assert_eq!(session_list.risk_level, RiskLevel::Low);

        let settings_update = find("settings.update");
        assert_eq!(settings_update.effect_class, EffectClass::IdempotentWrite);
        assert_eq!(settings_update.risk_level, RiskLevel::Medium);

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
    fn bridge_specs_fail_closed_for_unclassified_registry_methods() {
        struct Echo;

        #[async_trait]
        impl crate::server::rpc::registry::MethodHandler for Echo {
            async fn handle(
                &self,
                _params: Option<Value>,
                _ctx: &RpcContext,
            ) -> Result<Value, RpcError> {
                Ok(Value::Null)
            }
        }

        let mut registry = MethodRegistry::new();
        handlers::register_all(&mut registry);
        registry.register("new.method", Echo);
        let err = capability_specs(&registry).unwrap_err();
        assert!(matches!(
            err,
            EngineError::PolicyViolation(message)
                if message.contains("new.method") && message.contains("without an engine bridge spec")
        ));
    }

    #[tokio::test]
    async fn thin_adapter_rpc_outputs_match_direct_engine_outputs() {
        let ctx = make_test_context();
        let cases = [
            ("system.ping", json!({"protocolVersion": 1})),
            ("system.getInfo", json!({})),
            ("settings.get", json!({})),
            ("model.list", json!({})),
            ("skill.list", json!({})),
            ("logs.recent", json!({})),
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
    async fn thin_adapter_records_invocation_ledger_metadata() {
        let ctx = make_test_context();
        let result = ctx
            .engine_host
            .invoke(Invocation::new_sync(
                function_id_for_method("system.ping").unwrap(),
                json!({"protocolVersion": 1}),
                rpc_context(),
            ))
            .await;
        assert!(result.error.is_none());
        let host = ctx.engine_host.lock().await;
        let record = host.catalog().invocations().last().unwrap();
        assert_eq!(
            record.function_id,
            function_id_for_method("system.ping").unwrap()
        );
        assert_eq!(record.worker_id, worker_id(RPC_WORKER_ID).unwrap());
        assert_eq!(record.actor_kind, ActorKind::Client);
        assert_eq!(record.delivery_mode, crate::engine::DeliveryMode::Sync);
        assert_eq!(record.function_revision, result.function_revision);
        assert_eq!(record.catalog_revision, result.catalog_revision);
        assert!(
            record
                .authority_scopes
                .contains(&RPC_READ_AUTHORITY.to_owned())
        );
    }
}
