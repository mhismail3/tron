use std::collections::BTreeSet;

use serde_json::json;

use crate::engine::{
    ActorId, AuthorityGrantId, AuthorityRequirement, DeliveryMode, EffectClass, EngineError,
    FunctionDefinition, FunctionId, IdempotencyContract, IdempotencyKeySource, Provenance,
    Result as EngineResult, RiskLevel, TriggerDefinition, TriggerId, TriggerTypeDefinition,
    TriggerTypeId, VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
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
    /// Domain worker that owns the capability behavior.
    pub domain_worker: WorkerId,
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
    /// Optional JSON-RPC transport authority scope granted by the trigger.
    pub transport_authority_scope: Option<&'static str>,
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
    generic_trigger!("session.create"),
    handler_only!("session.resume"),
    generic_trigger!("session.list"),
    generic_trigger!("session.delete"),
    generic_trigger!("session.fork"),
    generic_trigger!("session.getHead"),
    generic_trigger!("session.getState"),
    generic_trigger!("session.getHistory"),
    generic_trigger!("session.reconstruct"),
    generic_trigger!("session.archive"),
    generic_trigger!("session.unarchive"),
    generic_trigger!("session.archiveOlderThan"),
    generic_trigger!("session.export"),
    handler_only!("agent.prompt"),
    handler_only!("agent.abort"),
    handler_only!("agent.abortTool"),
    handler_only!("agent.status"),
    generic_trigger!("agent.queuePrompt"),
    generic_trigger!("agent.dequeuePrompt"),
    generic_trigger!("agent.clearQueue"),
    handler_only!("agent.deliverSubagentResults"),
    handler_only!("agent.submitConfirmation"),
    handler_only!("agent.submitAnswers"),
    generic_trigger!("model.list"),
    handler_only!("model.switch"),
    handler_only!("config.setReasoningLevel"),
    generic_trigger!("context.getSnapshot"),
    generic_trigger!("context.getDetailedSnapshot"),
    generic_trigger!("context.previewCompaction"),
    generic_trigger!("context.getAuditTrace"),
    generic_trigger!("context.shouldCompact"),
    generic_trigger!("context.confirmCompaction"),
    generic_trigger!("context.canAcceptTurn"),
    generic_trigger!("context.clear"),
    generic_trigger!("context.compact"),
    generic_trigger!("events.getHistory"),
    generic_trigger!("events.getSince"),
    generic_trigger!("events.subscribe"),
    generic_trigger!("events.unsubscribe"),
    generic_trigger!("events.append"),
    generic_trigger!("settings.get"),
    generic_trigger!("settings.update"),
    generic_trigger!("settings.resetToDefaults"),
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
    generic_trigger!("logs.ingest"),
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
    generic_trigger!("skill.get"),
    generic_trigger!("skill.refresh"),
    generic_trigger!("skill.activate"),
    generic_trigger!("skill.deactivate"),
    generic_trigger!("skill.active"),
    generic_trigger!("filesystem.listDir"),
    generic_trigger!("filesystem.getHome"),
    generic_trigger!("filesystem.createDir"),
    generic_trigger!("file.read"),
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
    generic_trigger!("job.background"),
    generic_trigger!("job.cancel"),
    generic_trigger!("job.list"),
    generic_trigger!("job.subscribe"),
    generic_trigger!("job.unsubscribe"),
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
    generic_trigger!("plan.enter"),
    generic_trigger!("plan.exit"),
    generic_trigger!("plan.getState"),
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
    generic_trigger!("notifications.list"),
    generic_trigger!("notifications.markRead"),
    generic_trigger!("notifications.markAllRead"),
    generic_trigger!("promptHistory.list"),
    generic_trigger!("promptHistory.delete"),
    generic_trigger!("promptHistory.clear"),
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
                if spec.transport_authority_scope != Some(RPC_WRITE_AUTHORITY) {
                    return Err(EngineError::PolicyViolation(format!(
                        "mutating generic-triggered RPC method {} must grant rpc.write",
                        spec.method
                    )));
                }
                if spec.authority_scope.is_none() {
                    return Err(EngineError::PolicyViolation(format!(
                        "mutating generic-triggered RPC method {} must require a domain authority scope",
                        spec.method
                    )));
                }
                if spec.idempotency_mode == RpcIdempotencyMode::NotRequired {
                    return Err(EngineError::PolicyViolation(format!(
                        "mutating generic-triggered RPC method {} lacks idempotency",
                        spec.method
                    )));
                }
            } else if spec.transport_authority_scope != Some(RPC_READ_AUTHORITY) {
                return Err(EngineError::PolicyViolation(format!(
                    "read generic-triggered RPC method {} must grant rpc.read",
                    spec.method
                )));
            } else if spec.authority_scope.is_none() {
                return Err(EngineError::PolicyViolation(format!(
                    "read generic-triggered RPC method {} must require a domain authority scope",
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
    let owner_worker = if is_routable {
        domain_worker_for_method(seed.method)?
    } else {
        worker_id(RPC_WORKER_ID)?
    };
    Ok(RpcCapabilitySpec {
        method: seed.method,
        function_id: if is_routable {
            function_id_for_method(seed.method)?
        } else {
            compat_function_id_for_method(seed.method)?
        },
        owner_worker: owner_worker.clone(),
        domain_worker: domain_worker_for_method(seed.method)?,
        migration_state: seed.migration_state,
        effect_class,
        risk_level: risk_for_method(seed.method, effect_class),
        visibility,
        authority_scope: is_routable
            .then_some(domain_authority_scope_for_method(seed.method, effect_class)),
        transport_authority_scope: is_routable.then_some(if effect_class.is_mutating() {
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
    if matches!(
        method,
        "settings.update"
            | "settings.resetToDefaults"
            | "context.confirmCompaction"
            | "context.compact"
    ) {
        return EffectClass::ReversibleSideEffect;
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
            | "session.delete"
            | "context.clear"
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
    } else if matches!(
        method,
        "settings.update"
            | "settings.resetToDefaults"
            | "context.confirmCompaction"
            | "context.clear"
            | "context.compact"
            | "session.delete"
            | "session.archiveOlderThan"
            | "job.cancel"
    ) {
        RiskLevel::High
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
        format!(
            "Canonical domain capability for JSON-RPC method {}",
            spec.method
        ),
        spec.visibility.clone(),
        spec.effect_class,
    )
    .with_risk(spec.risk_level)
    .with_provenance(Provenance::system());
    if let Some(scope) = spec.authority_scope {
        let mut requirement = AuthorityRequirement::scope(scope);
        if spec.visibility.is_agent_visible()
            && (spec.effect_class.requires_approval_for_agent_visibility()
                || settings_write_requires_approval(spec.method))
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
        "compatFunctionId": compat_function_id_for_method(spec.method).map(|id| id.to_string()).unwrap_or_default(),
        "transportAuthorityScope": spec.transport_authority_scope,
        "domainWorker": spec.domain_worker.as_str(),
        "canonicalCapability": spec.function_id.as_str(),
        "domainAuthorityScope": spec.authority_scope,
        "migrationState": spec.migration_state.as_str(),
        "executionPolicy": spec.execution_policy.as_str(),
        "schemaMode": spec.schema_mode.as_str(),
        "idempotencyMode": spec.idempotency_mode.as_str(),
        "handlerModule": spec.handler_module,
    });
    definition
}

fn idempotency_contract_for_method(method: &str) -> IdempotencyContract {
    if method.starts_with("logs.")
        || method == "filesystem.createDir"
        || method == "job.unsubscribe"
        || method == "job.background"
        || method == "job.cancel"
        || method == "session.create"
        || method == "session.archiveOlderThan"
        || method.starts_with("notifications.")
        || method.starts_with("promptHistory.")
        || method.starts_with("promptSnippet.")
        || method == "skill.refresh"
        || method.starts_with("settings.")
    {
        IdempotencyContract::caller_system_engine_ledger()
    } else {
        IdempotencyContract::caller_session_engine_ledger()
    }
}

fn settings_write_requires_approval(method: &str) -> bool {
    matches!(
        method,
        "settings.update"
            | "settings.resetToDefaults"
            | "context.confirmCompaction"
            | "context.compact"
            | "session.archiveOlderThan"
            | "job.cancel"
    )
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

pub(super) fn domain_workers() -> EngineResult<Vec<WorkerDefinition>> {
    let domains = [
        "system",
        "model",
        "settings",
        "logs",
        "prompt_library",
        "skills",
        "filesystem",
        "events",
        "session",
        "context",
        "job",
        "agent",
        "notifications",
        "plan",
    ];
    domains
        .into_iter()
        .map(|domain| {
            Ok(WorkerDefinition::new(
                worker_id(domain)?,
                WorkerKind::InProcess,
                actor_id(RPC_OWNER_ACTOR)?,
                grant_id(RPC_AUTHORITY_GRANT)?,
            )
            .with_namespace_claim(domain))
        })
        .collect()
}

pub(super) fn json_rpc_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("json_rpc")?,
        worker_id(RPC_WORKER_ID)?,
        "JSON-RPC request dispatch into an engine function",
    );
    definition.allowed_delivery_modes = vec![DeliveryMode::Sync];
    definition.visibility = VisibilityScope::Internal;
    definition.config_schema = Some(json!({
        "type": "object",
        "required": ["method"],
        "additionalProperties": false,
        "properties": {
            "method": {"type": "string"}
        }
    }));
    Ok(definition)
}

pub(super) fn manual_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("manual")?,
        worker_id(RPC_WORKER_ID)?,
        "Manual in-process dispatch for tests and future agent tools",
    );
    definition.allowed_delivery_modes = vec![DeliveryMode::Sync];
    definition.visibility = VisibilityScope::Internal;
    Ok(definition)
}

pub(super) fn json_rpc_trigger_for_spec(
    spec: &RpcCapabilitySpec,
) -> EngineResult<Option<TriggerDefinition>> {
    if !is_engine_routable(spec) {
        return Ok(None);
    }
    let mut trigger = TriggerDefinition::new(
        json_rpc_trigger_id_for_method(spec.method)?,
        worker_id(RPC_WORKER_ID)?,
        TriggerTypeId::new("json_rpc")?,
        spec.function_id.clone(),
        grant_id(RPC_AUTHORITY_GRANT)?,
    )
    .with_delivery_mode(DeliveryMode::Sync);
    trigger.config = json!({ "method": spec.method });
    trigger.idempotency_key_strategy = if spec.effect_class.is_mutating() {
        Some(IdempotencyKeySource::TriggerDerived)
    } else {
        None
    };
    trigger.visibility = VisibilityScope::Internal;
    Ok(Some(trigger))
}

pub(super) fn json_rpc_trigger_id_for_method(method: &str) -> EngineResult<TriggerId> {
    TriggerId::new(format!("json_rpc:{method}"))
}

pub(super) fn function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    canonical_function_id_for_method(method)
}

pub(super) fn compat_function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    FunctionId::new(format!("rpc::{method}"))
}

pub(super) fn canonical_function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    FunctionId::new(canonical_capability_for_method(method))
}

fn domain_worker_for_method(method: &str) -> EngineResult<WorkerId> {
    worker_id(match method {
        method if method.starts_with("settings.") => "settings",
        method if method.starts_with("logs.") => "logs",
        method if method.starts_with("promptHistory.") || method.starts_with("promptSnippet.") => {
            "prompt_library"
        }
        method if method.starts_with("skill.") => "skills",
        method if method.starts_with("filesystem.") || method.starts_with("file.") => "filesystem",
        method if method.starts_with("events.") => "events",
        method if method.starts_with("session.") => "session",
        method if method.starts_with("context.") => "context",
        method if method.starts_with("job.") => "job",
        method if method.starts_with("agent.") => "agent",
        method if method.starts_with("notifications.") => "notifications",
        method if method.starts_with("plan.") => "plan",
        method if method.starts_with("system.") => "system",
        method if method.starts_with("model.") => "model",
        _ => RPC_WORKER_ID,
    })
}

fn canonical_capability_for_method(method: &str) -> String {
    let (namespace, operation) = canonical_parts_for_method(method);
    format!("{namespace}::{operation}")
}

fn canonical_parts_for_method(method: &str) -> (&'static str, String) {
    match method {
        "system.ping" => ("system", "ping".to_owned()),
        "system.getInfo" => ("system", "get_info".to_owned()),
        "model.list" => ("model", "list".to_owned()),
        "settings.get" => ("settings", "get".to_owned()),
        "settings.update" => ("settings", "update".to_owned()),
        "settings.resetToDefaults" => ("settings", "reset_to_defaults".to_owned()),
        "logs.ingest" => ("logs", "ingest".to_owned()),
        "logs.recent" => ("logs", "recent".to_owned()),
        "skill.list" => ("skills", "list".to_owned()),
        "skill.get" => ("skills", "get".to_owned()),
        "skill.refresh" => ("skills", "refresh".to_owned()),
        "skill.activate" => ("skills", "activate".to_owned()),
        "skill.deactivate" => ("skills", "deactivate".to_owned()),
        "skill.active" => ("skills", "active".to_owned()),
        "filesystem.listDir" => ("filesystem", "list_dir".to_owned()),
        "filesystem.getHome" => ("filesystem", "get_home".to_owned()),
        "file.read" => ("filesystem", "read_file".to_owned()),
        "filesystem.createDir" => ("filesystem", "create_dir".to_owned()),
        "events.getHistory" => ("events", "get_history".to_owned()),
        "events.getSince" => ("events", "get_since".to_owned()),
        "events.append" => ("events", "append".to_owned()),
        "events.subscribe" => ("events", "subscribe".to_owned()),
        "events.unsubscribe" => ("events", "unsubscribe".to_owned()),
        "session.list" => ("session", "list".to_owned()),
        "session.getHead" => ("session", "get_head".to_owned()),
        "session.getState" => ("session", "get_state".to_owned()),
        "session.getHistory" => ("session", "get_history".to_owned()),
        "session.reconstruct" => ("session", "reconstruct".to_owned()),
        "session.create" => ("session", "create".to_owned()),
        "session.delete" => ("session", "delete".to_owned()),
        "session.fork" => ("session", "fork".to_owned()),
        "session.archive" => ("session", "archive".to_owned()),
        "session.unarchive" => ("session", "unarchive".to_owned()),
        "session.archiveOlderThan" => ("session", "archive_older_than".to_owned()),
        "session.export" => ("session", "export".to_owned()),
        "agent.queuePrompt" => ("agent", "queue_prompt".to_owned()),
        "agent.dequeuePrompt" => ("agent", "dequeue_prompt".to_owned()),
        "agent.clearQueue" => ("agent", "clear_queue".to_owned()),
        "context.getSnapshot" => ("context", "get_snapshot".to_owned()),
        "context.getDetailedSnapshot" => ("context", "get_detailed_snapshot".to_owned()),
        "context.getAuditTrace" => ("context", "get_audit_trace".to_owned()),
        "context.shouldCompact" => ("context", "should_compact".to_owned()),
        "context.previewCompaction" => ("context", "preview_compaction".to_owned()),
        "context.canAcceptTurn" => ("context", "can_accept_turn".to_owned()),
        "context.confirmCompaction" => ("context", "confirm_compaction".to_owned()),
        "context.clear" => ("context", "clear".to_owned()),
        "context.compact" => ("context", "compact".to_owned()),
        "job.background" => ("job", "background".to_owned()),
        "job.cancel" => ("job", "cancel".to_owned()),
        "job.list" => ("job", "list".to_owned()),
        "job.subscribe" => ("job", "subscribe".to_owned()),
        "job.unsubscribe" => ("job", "unsubscribe".to_owned()),
        "notifications.list" => ("notifications", "list".to_owned()),
        "notifications.markRead" => ("notifications", "mark_read".to_owned()),
        "notifications.markAllRead" => ("notifications", "mark_all_read".to_owned()),
        "plan.enter" => ("plan", "enter".to_owned()),
        "plan.exit" => ("plan", "exit".to_owned()),
        "plan.getState" => ("plan", "get_state".to_owned()),
        "promptHistory.list" => ("prompt_library", "history_list".to_owned()),
        "promptHistory.delete" => ("prompt_library", "history_delete".to_owned()),
        "promptHistory.clear" => ("prompt_library", "history_clear".to_owned()),
        "promptSnippet.list" => ("prompt_library", "snippet_list".to_owned()),
        "promptSnippet.get" => ("prompt_library", "snippet_get".to_owned()),
        "promptSnippet.create" => ("prompt_library", "snippet_create".to_owned()),
        "promptSnippet.update" => ("prompt_library", "snippet_update".to_owned()),
        "promptSnippet.delete" => ("prompt_library", "snippet_delete".to_owned()),
        _ => match method.split_once('.') {
            Some(("promptHistory", operation)) => {
                ("prompt_library", format!("history_{operation}"))
            }
            Some(("promptSnippet", operation)) => {
                ("prompt_library", format!("snippet_{operation}"))
            }
            Some(("file", operation)) => ("filesystem", operation.to_owned()),
            Some(("skill", operation)) => ("skills", operation.to_owned()),
            Some((namespace, operation)) => {
                let namespace = match namespace {
                    "events" => "events",
                    "filesystem" => "filesystem",
                    "session" => "session",
                    "context" => "context",
                    "job" => "job",
                    "agent" => "agent",
                    "logs" => "logs",
                    "model" => "model",
                    "notifications" => "notifications",
                    "plan" => "plan",
                    "settings" => "settings",
                    "system" => "system",
                    _ => RPC_WORKER_ID,
                };
                (namespace, operation.to_owned())
            }
            None => (RPC_WORKER_ID, method.to_owned()),
        },
    }
}

fn domain_authority_scope_for_method(method: &str, effect_class: EffectClass) -> &'static str {
    let access = if effect_class.is_mutating() {
        "write"
    } else {
        "read"
    };
    match (
        domain_worker_for_method(method)
            .ok()
            .as_ref()
            .map(WorkerId::as_str),
        access,
    ) {
        (Some("system"), "read") => "system.read",
        (Some("system"), "write") => "system.write",
        (Some("model"), "read") => "model.read",
        (Some("model"), "write") => "model.write",
        (Some("settings"), "read") => "settings.read",
        (Some("settings"), "write") => "settings.write",
        (Some("logs"), "read") => "logs.read",
        (Some("logs"), "write") => "logs.write",
        (Some("prompt_library"), "read") => "prompt_library.read",
        (Some("prompt_library"), "write") => "prompt_library.write",
        (Some("skills"), "read") => "skills.read",
        (Some("skills"), "write") => "skills.write",
        (Some("filesystem"), "read") => "filesystem.read",
        (Some("filesystem"), "write") => "filesystem.write",
        (Some("events"), "read") => "events.read",
        (Some("events"), "write") => "events.write",
        (Some("session"), "read") => "session.read",
        (Some("session"), "write") => "session.write",
        (Some("context"), "read") => "context.read",
        (Some("context"), "write") => "context.write",
        (Some("job"), "read") => "job.read",
        (Some("job"), "write") => "job.write",
        (Some("agent"), "read") => "agent.read",
        (Some("agent"), "write") => "agent.write",
        (Some("notifications"), "read") => "notifications.read",
        (Some("notifications"), "write") => "notifications.write",
        (Some("plan"), "read") => "plan.read",
        (Some("plan"), "write") => "plan.write",
        (_, "write") => "rpc.write",
        _ => "rpc.read",
    }
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
