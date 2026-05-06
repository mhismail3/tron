use std::collections::BTreeSet;

use serde_json::json;

use crate::engine::{
    ActorId, AuthorityGrantId, AuthorityRequirement, EffectClass, EngineError, FunctionDefinition,
    FunctionId, IdempotencyContract, Provenance, Result as EngineResult, RiskLevel,
    VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
};
use crate::server::rpc::registry::{HandlerExecutionPolicy, MethodRegistry};

use super::schemas::{request_schema_for_method, response_schema_for_method};
use super::{
    RPC_AUTHORITY_GRANT, RPC_OWNER_ACTOR, RPC_READ_AUTHORITY, RPC_WORKER_ID, RPC_WRITE_AUTHORITY,
};

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
    pub(super) fn as_str(self) -> &'static str {
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

macro_rules! generic_trigger {
    ($method:literal) => {
        RpcCapabilitySpecSeed {
            method: $method,
            migration_state: RpcMigrationState::GenericTrigger,
            schema_mode: RpcSchemaMode::StrictJson,
        }
    };
}

const RPC_CAPABILITY_SEEDS: &[RpcCapabilitySpecSeed] = &[
    generic_trigger!("system.ping"),
    generic_trigger!("system.getInfo"),
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
    generic_trigger!("model.list"),
    handler_only!("model.switch"),
    handler_only!("config.setReasoningLevel"),
    handler_only!("context.getSnapshot"),
    handler_only!("context.getDetailedSnapshot"),
    handler_only!("context.previewCompaction"),
    handler_only!("context.getAuditTrace"),
    handler_only!("context.shouldCompact"),
    handler_only!("context.confirmCompaction"),
    handler_only!("context.canAcceptTurn"),
    handler_only!("context.clear"),
    handler_only!("context.compact"),
    generic_trigger!("events.getHistory"),
    generic_trigger!("events.getSince"),
    handler_only!("events.subscribe"),
    handler_only!("events.unsubscribe"),
    handler_only!("events.append"),
    generic_trigger!("settings.get"),
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
    generic_trigger!("logs.recent"),
    handler_only!("memory.retain"),
    handler_only!("mcp.status"),
    handler_only!("mcp.addServer"),
    handler_only!("mcp.removeServer"),
    handler_only!("mcp.enableServer"),
    handler_only!("mcp.disableServer"),
    handler_only!("mcp.restartServer"),
    handler_only!("mcp.reload"),
    handler_only!("mcp.listTools"),
    generic_trigger!("skill.list"),
    handler_only!("skill.get"),
    handler_only!("skill.refresh"),
    handler_only!("skill.activate"),
    handler_only!("skill.deactivate"),
    handler_only!("skill.active"),
    handler_only!("filesystem.listDir"),
    generic_trigger!("filesystem.getHome"),
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
    handler_only!("worktree.finalizeSession"),
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
    generic_trigger!("promptHistory.list"),
    handler_only!("promptHistory.delete"),
    handler_only!("promptHistory.clear"),
    generic_trigger!("promptSnippet.list"),
    generic_trigger!("promptSnippet.get"),
    generic_trigger!("promptSnippet.create"),
    generic_trigger!("promptSnippet.update"),
    generic_trigger!("promptSnippet.delete"),
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
        if is_engine_routable(&spec) && spec.schema_mode != RpcSchemaMode::StrictJson {
            return Err(EngineError::PolicyViolation(format!(
                "generic-triggered RPC method {} must use strict schemas",
                spec.method
            )));
        }
        if is_engine_routable(&spec) {
            if spec.effect_class.is_mutating() {
                if spec.authority_scope != Some(RPC_WRITE_AUTHORITY) {
                    return Err(EngineError::PolicyViolation(format!(
                        "mutating generic-triggered RPC method {} must require rpc.write",
                        spec.method
                    )));
                }
                if spec.idempotency_mode == RpcIdempotencyMode::NotRequired {
                    return Err(EngineError::PolicyViolation(format!(
                        "mutating generic-triggered RPC method {} lacks idempotency",
                        spec.method
                    )));
                }
            } else if spec.authority_scope != Some(RPC_READ_AUTHORITY) {
                return Err(EngineError::PolicyViolation(format!(
                    "read generic-triggered RPC method {} must require rpc.read",
                    spec.method
                )));
            }
        }
        specs.push(spec);
    }
    Ok(specs)
}

pub(super) fn capability_spec_for_method(
    registry: &MethodRegistry,
    method: &str,
) -> EngineResult<Option<RpcCapabilitySpec>> {
    let Some(seed) = RPC_CAPABILITY_SEEDS
        .iter()
        .find(|candidate| candidate.method == method)
    else {
        return Ok(None);
    };
    if seed.migration_state == RpcMigrationState::Removed {
        return Ok(None);
    }
    let Some(policy) = registry.method_policy(method) else {
        return Ok(None);
    };
    spec_from_seed(*seed, policy).map(Some)
}

pub(super) fn is_engine_routable(spec: &RpcCapabilitySpec) -> bool {
    matches!(
        spec.execution_policy,
        RpcExecutionPolicy::ThinAdapter | RpcExecutionPolicy::GenericTrigger
    )
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
    let is_routable = matches!(
        seed.migration_state,
        RpcMigrationState::ThinAdapter | RpcMigrationState::GenericTrigger
    );
    let effect_class = effect_class_for_method(seed.method, policy);
    let visibility = if is_routable {
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
        authority_scope: is_routable.then_some(if effect_class.is_mutating() {
            RPC_WRITE_AUTHORITY
        } else {
            RPC_READ_AUTHORITY
        }),
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

pub(super) fn function_definition_for_spec(spec: &RpcCapabilitySpec) -> FunctionDefinition {
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
        let mut requirement = AuthorityRequirement::scope(scope);
        if spec.visibility.is_agent_visible()
            && spec.effect_class.requires_approval_for_agent_visibility()
        {
            requirement = requirement.with_approval_required();
        }
        definition = definition.with_required_authority(requirement);
    }
    if spec.effect_class.is_mutating() {
        definition = definition.with_idempotency(idempotency_contract_for_method(spec.method));
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

fn idempotency_contract_for_method(method: &str) -> IdempotencyContract {
    if method.starts_with("promptSnippet.") {
        IdempotencyContract::caller_system_engine_ledger()
    } else {
        IdempotencyContract::caller_session_engine_ledger()
    }
}

pub(super) fn rpc_worker() -> WorkerDefinition {
    WorkerDefinition::new(
        worker_id(RPC_WORKER_ID).expect("valid static rpc worker id"),
        WorkerKind::Compatibility,
        actor_id(RPC_OWNER_ACTOR).expect("valid static rpc owner actor"),
        grant_id(RPC_AUTHORITY_GRANT).expect("valid static rpc authority grant"),
    )
    .with_namespace_claim(RPC_WORKER_ID)
}

pub(super) fn function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    FunctionId::new(format!("rpc::{method}"))
}

pub(super) fn worker_id(value: &str) -> EngineResult<WorkerId> {
    WorkerId::new(value)
}

pub(super) fn actor_id(value: &str) -> EngineResult<ActorId> {
    ActorId::new(value)
}

pub(super) fn grant_id(value: &str) -> EngineResult<AuthorityGrantId> {
    AuthorityGrantId::new(value)
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
