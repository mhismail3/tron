use std::collections::BTreeSet;

use serde_json::json;

use crate::engine::{
    ActorId, AuthorityGrantId, AuthorityRequirement, CompensationContract, CompensationKind,
    DeliveryMode, EffectClass, EngineError, FunctionDefinition, FunctionId, IdempotencyContract,
    IdempotencyKeySource, Provenance, ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
    TriggerDefinition, TriggerId, TriggerTypeDefinition, TriggerTypeId, VisibilityScope,
    WorkerDefinition, WorkerId, WorkerKind,
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
    generic_trigger!("system.getDiagnostics"),
    generic_trigger!("system.shutdown"),
    generic_trigger!("system.checkForUpdates"),
    generic_trigger!("system.getUpdateStatus"),
    generic_trigger!("codexApp.status"),
    generic_trigger!("blob.get"),
    generic_trigger!("session.create"),
    generic_trigger!("session.resume"),
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
    generic_trigger!("agent.prompt"),
    generic_trigger!("agent.abort"),
    generic_trigger!("agent.abortTool"),
    generic_trigger!("agent.status"),
    generic_trigger!("agent.queuePrompt"),
    generic_trigger!("agent.dequeuePrompt"),
    generic_trigger!("agent.clearQueue"),
    generic_trigger!("agent.deliverSubagentResults"),
    generic_trigger!("agent.submitConfirmation"),
    generic_trigger!("agent.submitAnswers"),
    generic_trigger!("model.list"),
    generic_trigger!("model.switch"),
    generic_trigger!("config.setReasoningLevel"),
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
    generic_trigger!("approval.get"),
    generic_trigger!("approval.list"),
    generic_trigger!("approval.resolve"),
    generic_trigger!("auth.get"),
    generic_trigger!("auth.update"),
    generic_trigger!("auth.clear"),
    generic_trigger!("auth.oauthBegin"),
    generic_trigger!("auth.oauthComplete"),
    generic_trigger!("auth.renameAccount"),
    generic_trigger!("auth.setActive"),
    generic_trigger!("auth.removeAccount"),
    generic_trigger!("auth.removeApiKey"),
    generic_trigger!("tool.result"),
    generic_trigger!("message.delete"),
    generic_trigger!("logs.ingest"),
    generic_trigger!("logs.recent"),
    generic_trigger!("memory.retain"),
    generic_trigger!("mcp.status"),
    generic_trigger!("mcp.addServer"),
    generic_trigger!("mcp.removeServer"),
    generic_trigger!("mcp.enableServer"),
    generic_trigger!("mcp.disableServer"),
    generic_trigger!("mcp.restartServer"),
    generic_trigger!("mcp.reload"),
    generic_trigger!("mcp.listTools"),
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
    generic_trigger!("tree.getVisualization"),
    generic_trigger!("tree.getBranches"),
    generic_trigger!("tree.getSubtree"),
    generic_trigger!("tree.getAncestors"),
    generic_trigger!("tree.compareBranches"),
    generic_trigger!("import.listSources"),
    generic_trigger!("import.listSessions"),
    generic_trigger!("import.previewSession"),
    generic_trigger!("import.execute"),
    generic_trigger!("browser.startStream"),
    generic_trigger!("browser.stopStream"),
    generic_trigger!("browser.getStatus"),
    generic_trigger!("display.stopStream"),
    generic_trigger!("job.background"),
    generic_trigger!("job.cancel"),
    generic_trigger!("job.list"),
    generic_trigger!("job.subscribe"),
    generic_trigger!("job.unsubscribe"),
    generic_trigger!("worktree.getStatus"),
    generic_trigger!("worktree.isGitRepo"),
    generic_trigger!("worktree.commit"),
    generic_trigger!("worktree.merge"),
    generic_trigger!("worktree.list"),
    generic_trigger!("worktree.getDiff"),
    generic_trigger!("worktree.acquire"),
    generic_trigger!("worktree.release"),
    generic_trigger!("worktree.listSessionBranches"),
    generic_trigger!("worktree.getCommittedDiff"),
    generic_trigger!("worktree.finalizeSession"),
    generic_trigger!("worktree.deleteBranch"),
    generic_trigger!("worktree.pruneBranches"),
    generic_trigger!("worktree.stageFiles"),
    generic_trigger!("worktree.unstageFiles"),
    generic_trigger!("worktree.discardFiles"),
    generic_trigger!("transcribe.audio"),
    generic_trigger!("transcribe.listModels"),
    generic_trigger!("transcribe.downloadModel"),
    generic_trigger!("device.register"),
    generic_trigger!("device.unregister"),
    generic_trigger!("device.respond"),
    generic_trigger!("plan.enter"),
    generic_trigger!("plan.exit"),
    generic_trigger!("plan.getState"),
    generic_trigger!("voiceNotes.save"),
    generic_trigger!("voiceNotes.list"),
    generic_trigger!("voiceNotes.delete"),
    generic_trigger!("git.clone"),
    generic_trigger!("git.syncMain"),
    generic_trigger!("git.push"),
    generic_trigger!("git.listLocalBranches"),
    generic_trigger!("git.listRemoteBranches"),
    generic_trigger!("worktree.rebaseOnMain"),
    generic_trigger!("worktree.startMerge"),
    generic_trigger!("worktree.listConflicts"),
    generic_trigger!("worktree.resolveConflict"),
    generic_trigger!("worktree.continueMerge"),
    generic_trigger!("worktree.abortMerge"),
    generic_trigger!("worktree.resolveConflictsWithSubagent"),
    generic_trigger!("repo.listSessions"),
    generic_trigger!("repo.getDivergence"),
    generic_trigger!("sandbox.listContainers"),
    generic_trigger!("sandbox.startContainer"),
    generic_trigger!("sandbox.stopContainer"),
    generic_trigger!("sandbox.killContainer"),
    generic_trigger!("sandbox.removeContainer"),
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
    generic_trigger!("cron.list"),
    generic_trigger!("cron.get"),
    generic_trigger!("cron.create"),
    generic_trigger!("cron.update"),
    generic_trigger!("cron.delete"),
    generic_trigger!("cron.run"),
    generic_trigger!("cron.status"),
    generic_trigger!("cron.getRuns"),
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
                if spec.risk_level >= RiskLevel::High
                    && high_risk_contract_for_method(spec.method).is_none()
                {
                    return Err(EngineError::PolicyViolation(format!(
                        "high-risk generic-triggered RPC method {} lacks a high-risk contract",
                        spec.method
                    )));
                }
                let definition = function_definition_for_spec(&spec);
                if spec.risk_level >= RiskLevel::High && definition.compensation.is_none() {
                    return Err(EngineError::PolicyViolation(format!(
                        "high-risk generic-triggered RPC method {} lacks typed compensation metadata",
                        spec.method
                    )));
                }
                if requires_resource_lease_metadata(spec.method)
                    && definition.resource_lease.is_none()
                {
                    return Err(EngineError::PolicyViolation(format!(
                        "generic-triggered RPC method {} lacks typed resource lease metadata",
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

pub(super) fn uses_existing_engine_primitive(spec: &RpcCapabilitySpec) -> bool {
    matches!(
        spec.function_id.as_str(),
        "approval::get" | "approval::list" | "approval::resolve"
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
        "mcp.addServer"
            | "mcp.removeServer"
            | "mcp.enableServer"
            | "mcp.disableServer"
            | "mcp.restartServer"
            | "mcp.reload"
    ) {
        return EffectClass::ExternalSideEffect;
    }
    if matches!(
        method,
        "settings.update"
            | "settings.resetToDefaults"
            | "model.switch"
            | "config.setReasoningLevel"
            | "context.confirmCompaction"
            | "context.compact"
            | "agent.abort"
            | "agent.abortTool"
            | "cron.create"
            | "cron.update"
            | "worktree.commit"
            | "worktree.merge"
            | "worktree.finalizeSession"
            | "worktree.rebaseOnMain"
            | "worktree.startMerge"
            | "worktree.resolveConflict"
            | "worktree.continueMerge"
            | "worktree.abortMerge"
    ) {
        return EffectClass::ReversibleSideEffect;
    }
    if matches!(method, "agent.prompt" | "cron.run") {
        return EffectClass::ExternalSideEffect;
    }
    if matches!(method, "memory.retain") {
        return EffectClass::ExternalSideEffect;
    }
    if matches!(method, "events.append" | "logs.ingest" | "import.execute") {
        return EffectClass::AppendOnlyEvent;
    }
    if matches!(
        method,
        "system.shutdown"
            | "message.delete"
            | "cron.delete"
            | "voiceNotes.delete"
            | "promptHistory.delete"
            | "promptHistory.clear"
            | "promptSnippet.delete"
            | "session.delete"
            | "context.clear"
            | "worktree.deleteBranch"
            | "worktree.discardFiles"
            | "worktree.pruneBranches"
            | "sandbox.killContainer"
            | "sandbox.removeContainer"
    ) {
        return EffectClass::IrreversibleSideEffect;
    }
    if matches!(
        method,
        "git.clone" | "git.syncMain" | "git.push" | "worktree.resolveConflictsWithSubagent"
    ) {
        return EffectClass::ExternalSideEffect;
    }
    if method.starts_with("git.")
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
        "auth.update"
            | "auth.clear"
            | "auth.oauthBegin"
            | "auth.oauthComplete"
            | "auth.renameAccount"
            | "auth.setActive"
            | "auth.removeAccount"
            | "auth.removeApiKey"
            | "settings.update"
            | "settings.resetToDefaults"
            | "context.confirmCompaction"
            | "context.clear"
            | "context.compact"
            | "session.delete"
            | "session.archiveOlderThan"
            | "job.cancel"
            | "approval.resolve"
            | "agent.prompt"
            | "agent.abort"
            | "message.delete"
            | "cron.create"
            | "cron.update"
            | "cron.delete"
            | "cron.run"
            | "model.switch"
            | "config.setReasoningLevel"
            | "memory.retain"
            | "import.execute"
            | "git.clone"
            | "git.syncMain"
            | "worktree.commit"
            | "worktree.merge"
            | "worktree.finalizeSession"
            | "worktree.deleteBranch"
            | "worktree.pruneBranches"
            | "worktree.discardFiles"
            | "worktree.rebaseOnMain"
            | "worktree.startMerge"
            | "worktree.resolveConflict"
            | "worktree.continueMerge"
            | "worktree.abortMerge"
            | "worktree.resolveConflictsWithSubagent"
            | "sandbox.startContainer"
            | "sandbox.stopContainer"
            | "sandbox.killContainer"
            | "sandbox.removeContainer"
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
    if let Some(requirement) = resource_lease_requirement_for_method(spec.method) {
        definition = definition.with_resource_lease(requirement);
    }
    if let Some(contract) = compensation_contract_for_method(spec.method, spec.effect_class) {
        definition = definition.with_compensation(contract);
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
        "highRiskContract": high_risk_contract_for_method(spec.method),
    });
    definition
}

fn idempotency_contract_for_method(method: &str) -> IdempotencyContract {
    if method.starts_with("logs.")
        || method.starts_with("mcp.")
        || method == "filesystem.createDir"
        || method == "job.unsubscribe"
        || method == "job.background"
        || method == "job.cancel"
        || method == "session.create"
        || method == "session.archiveOlderThan"
        || method == "approval.resolve"
        || method.starts_with("auth.")
        || method.starts_with("browser.")
        || method.starts_with("display.")
        || method.starts_with("device.")
        || method == "import.execute"
        || method.starts_with("sandbox.")
        || method.starts_with("transcribe.")
        || method.starts_with("voiceNotes.")
        || method.starts_with("notifications.")
        || method.starts_with("promptHistory.")
        || method.starts_with("promptSnippet.")
        || method == "skill.refresh"
        || method.starts_with("settings.")
        || method.starts_with("cron.")
        || method == "git.clone"
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
            | "agent.prompt"
            | "agent.abort"
            | "message.delete"
            | "mcp.addServer"
            | "mcp.removeServer"
            | "mcp.enableServer"
            | "mcp.disableServer"
            | "mcp.restartServer"
            | "mcp.reload"
            | "cron.create"
            | "cron.update"
            | "cron.delete"
            | "cron.run"
            | "model.switch"
            | "config.setReasoningLevel"
            | "memory.retain"
            | "import.execute"
            | "git.clone"
            | "git.syncMain"
            | "git.push"
            | "worktree.commit"
            | "worktree.merge"
            | "worktree.finalizeSession"
            | "worktree.deleteBranch"
            | "worktree.pruneBranches"
            | "worktree.discardFiles"
            | "worktree.rebaseOnMain"
            | "worktree.startMerge"
            | "worktree.resolveConflict"
            | "worktree.continueMerge"
            | "worktree.abortMerge"
            | "worktree.resolveConflictsWithSubagent"
            | "auth.update"
            | "auth.clear"
            | "auth.oauthBegin"
            | "auth.oauthComplete"
            | "auth.renameAccount"
            | "auth.setActive"
            | "auth.removeAccount"
            | "auth.removeApiKey"
            | "sandbox.startContainer"
            | "sandbox.stopContainer"
            | "sandbox.killContainer"
            | "sandbox.removeContainer"
            | "voiceNotes.delete"
            | "system.shutdown"
    )
}

fn requires_resource_lease_metadata(method: &str) -> bool {
    resource_lease_requirement_for_method(method).is_some()
}

fn resource_lease_requirement_for_method(method: &str) -> Option<ResourceLeaseRequirement> {
    let (kind, template, ttl_ms) = match method {
        "model.switch" => ("session", "session:{sessionId}:model", 60_000),
        "config.setReasoningLevel" => ("session", "session:{sessionId}:reasoning", 60_000),
        "memory.retain" => ("session", "session:{sessionId}:memory-retain", 300_000),
        "import.execute" => ("import", "import:{sessionPath}", 300_000),
        "auth.update" | "auth.clear" | "auth.oauthBegin" | "auth.oauthComplete"
        | "auth.renameAccount" | "auth.setActive" | "auth.removeAccount" | "auth.removeApiKey" => {
            ("auth", "auth:auth-json", 60_000)
        }
        "system.shutdown" => ("system", "system:shutdown", 60_000),
        "browser.startStream" | "browser.stopStream" => ("browser", "browser:stream", 60_000),
        "display.stopStream" => ("display", "display:{streamId}", 60_000),
        "device.register" | "device.unregister" => ("device", "device:{deviceToken}", 60_000),
        "device.respond" => ("device", "device-request:{requestId}", 60_000),
        "transcribe.audio" => ("transcription", "transcription:audio", 300_000),
        "transcribe.downloadModel" => ("transcription", "transcription:model-cache", 900_000),
        "voiceNotes.save" => ("voice_notes", "voice-notes:inbox", 60_000),
        "voiceNotes.delete" => ("voice_notes", "voice-note:{filename}", 60_000),
        "sandbox.startContainer"
        | "sandbox.stopContainer"
        | "sandbox.killContainer"
        | "sandbox.removeContainer" => ("sandbox", "container:{name}", 300_000),
        "git.clone" => ("git", "clone:{targetPath}", 1_800_000),
        "git.syncMain" => ("git", "session:{sessionId}:sync-main", 900_000),
        "git.push" => ("git", "session:{sessionId}:push", 900_000),
        "worktree.acquire" | "worktree.release" => {
            ("worktree", "session:{sessionId}:assignment", 300_000)
        }
        "worktree.stageFiles" | "worktree.unstageFiles" | "worktree.discardFiles" => {
            ("worktree", "session:{sessionId}:index", 300_000)
        }
        "worktree.commit"
        | "worktree.merge"
        | "worktree.finalizeSession"
        | "worktree.deleteBranch"
        | "worktree.pruneBranches"
        | "worktree.rebaseOnMain"
        | "worktree.startMerge"
        | "worktree.resolveConflict"
        | "worktree.continueMerge"
        | "worktree.abortMerge"
        | "worktree.resolveConflictsWithSubagent" => {
            ("worktree", "session:{sessionId}:workflow", 900_000)
        }
        _ => return None,
    };
    Some(ResourceLeaseRequirement::exclusive_template(
        kind, template, ttl_ms,
    ))
}

fn compensation_contract_for_method(
    method: &str,
    effect_class: EffectClass,
) -> Option<CompensationContract> {
    if !effect_class.is_mutating() {
        return None;
    }
    let kind = match effect_class {
        EffectClass::AppendOnlyEvent => CompensationKind::EventSourced,
        EffectClass::IdempotentWrite | EffectClass::ReversibleSideEffect => {
            CompensationKind::InverseCommandAvailable
        }
        EffectClass::ExternalSideEffect => CompensationKind::ManualOnly,
        EffectClass::IrreversibleSideEffect => CompensationKind::ExternalIrreversible,
        EffectClass::PureRead
        | EffectClass::DeterministicCompute
        | EffectClass::DelegatedInvocation => CompensationKind::None,
    };
    let notes = rollback_contract_for_method(method);
    if matches!(kind, CompensationKind::None) {
        None
    } else {
        Some(CompensationContract::new(kind, notes))
    }
}

fn high_risk_contract_for_method(method: &str) -> Option<serde_json::Value> {
    let (resource_required, resource_kind, resource_id_template, lease_ttl_ms, resource_reason) =
        match method {
            "model.switch" => (
                true,
                "session",
                "session:{sessionId}:model",
                60_000,
                "serializes model selection and session cache invalidation",
            ),
            "config.setReasoningLevel" => (
                true,
                "session",
                "session:{sessionId}:reasoning",
                60_000,
                "serializes reasoning-level event writes and session cache invalidation",
            ),
            "memory.retain" => (
                true,
                "session",
                "session:{sessionId}:memory-retain",
                300_000,
                "serializes retain startup before the existing background retain guard owns the long-running summarizer",
            ),
            "import.execute" => (
                true,
                "import",
                "import:{canonicalSessionPath}",
                300_000,
                "serializes session import for one source transcript path",
            ),
            "git.clone" => (
                true,
                "git",
                "clone:{targetPath}",
                1_800_000,
                "serializes clone operations into one target path",
            ),
            "auth.update" | "auth.clear" | "auth.oauthBegin" | "auth.oauthComplete"
            | "auth.renameAccount" | "auth.setActive" | "auth.removeAccount"
            | "auth.removeApiKey" => (
                true,
                "auth",
                "auth:auth-json",
                60_000,
                "serializes credential-file mutation, OAuth flow mutation, and auth broadcasts",
            ),
            "system.shutdown" => (
                true,
                "system",
                "system:shutdown",
                60_000,
                "serializes the graceful server shutdown command",
            ),
            "sandbox.startContainer"
            | "sandbox.stopContainer"
            | "sandbox.killContainer"
            | "sandbox.removeContainer" => (
                true,
                "sandbox",
                "container:{name}",
                300_000,
                "serializes lifecycle operations for one local sandbox container",
            ),
            "voiceNotes.delete" => (
                true,
                "voice_notes",
                "voice-note:{filename}",
                60_000,
                "serializes deletion of one local voice-note file",
            ),
            "git.syncMain" => (
                true,
                "git",
                "session:{sessionId}:sync-main",
                900_000,
                "serializes main-branch synchronization for the session repository",
            ),
            "git.push" => (
                true,
                "git",
                "session:{sessionId}:push",
                900_000,
                "serializes outbound pushes for a session worktree",
            ),
            "worktree.commit" | "worktree.merge" | "worktree.finalizeSession" => (
                true,
                "worktree",
                "session:{sessionId}:workflow",
                900_000,
                "serializes high-risk branch/workflow mutations for a session worktree",
            ),
            "worktree.deleteBranch" | "worktree.pruneBranches" | "worktree.discardFiles" => (
                true,
                "worktree",
                "session:{sessionId}:workflow",
                900_000,
                "serializes destructive branch/index mutations for a session worktree",
            ),
            "worktree.rebaseOnMain"
            | "worktree.startMerge"
            | "worktree.resolveConflict"
            | "worktree.continueMerge"
            | "worktree.abortMerge"
            | "worktree.resolveConflictsWithSubagent" => (
                true,
                "worktree",
                "session:{sessionId}:workflow",
                900_000,
                "serializes merge/rebase conflict workflows for a session worktree",
            ),
            method
                if matches!(
                    method,
                    "settings.update"
                        | "settings.resetToDefaults"
                        | "context.confirmCompaction"
                        | "context.clear"
                        | "context.compact"
                        | "session.delete"
                        | "session.archiveOlderThan"
                        | "job.cancel"
                        | "approval.resolve"
                        | "agent.prompt"
                        | "agent.abort"
                        | "message.delete"
                        | "promptHistory.delete"
                        | "promptHistory.clear"
                        | "promptSnippet.delete"
                        | "cron.create"
                        | "cron.update"
                        | "cron.delete"
                        | "cron.run"
                ) =>
            {
                (
                    false,
                    "documented-by-domain",
                    "not-required",
                    0,
                    "existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract",
                )
            }
            _ => return None,
        };
    Some(json!({
        "version": 1,
        "approvalRequiredForAgentVisibility": settings_write_requires_approval(method),
        "resourceLock": {
            "required": resource_required,
            "kind": resource_kind,
            "idTemplate": resource_id_template,
            "ttlMs": lease_ttl_ms,
            "reason": resource_reason
        },
        "streamTopics": ["resource.leases", "catalog.changes"],
        "rollbackOrCompensation": rollback_contract_for_method(method),
    }))
}

fn rollback_contract_for_method(method: &str) -> &'static str {
    match method {
        "model.switch" => {
            "previousModel is returned and persisted in config.model_switch for manual reversal"
        }
        "config.setReasoningLevel" => {
            "previousLevel is returned and persisted in config.reasoning_level for manual reversal"
        }
        "memory.retain" => {
            "background retain writes a memory.retained boundary; failures emit memory update completion without duplicate retention"
        }
        "import.execute" => {
            "import is append-only and duplicate sources return alreadyImported; full rollback is deferred"
        }
        "auth.update" | "auth.clear" | "auth.oauthBegin" | "auth.oauthComplete" => {
            "auth changes are masked in responses; manual auth.json recovery or inverse credential commands are available"
        }
        "auth.renameAccount" | "auth.setActive" | "auth.removeAccount" | "auth.removeApiKey" => {
            "account/key changes can be manually restored through auth update or OAuth login"
        }
        "system.shutdown" => {
            "shutdown is irreversible for the current process; restart Tron manually"
        }
        "sandbox.startContainer" | "sandbox.stopContainer" => {
            "inverse container lifecycle command can be run manually if the runtime is still available"
        }
        "sandbox.killContainer" | "sandbox.removeContainer" => {
            "sandbox kill/remove is external and may require manual container recreation"
        }
        "git.clone" => {
            "manual cleanup of the target directory is required if clone partially succeeds"
        }
        "git.syncMain" => {
            "sync_main uses existing stash/reset checks and must be manually inspected on failure"
        }
        "git.push" => {
            "remote pushes are external side effects; force/protected-branch checks limit blast radius"
        }
        "worktree.acquire" => {
            "worktree release is the inverse command and duplicate acquire replays"
        }
        "worktree.release" => "worktree acquire can recreate the assignment if needed",
        "worktree.stageFiles" => "worktree.unstageFiles is the inverse command",
        "worktree.unstageFiles" => "worktree.stageFiles is the inverse command",
        "worktree.commit" => "git revert/reset is a manual recovery path after commit creation",
        "worktree.merge" => {
            "merge abort or manual conflict recovery is available while merge state exists"
        }
        "worktree.finalizeSession" => {
            "finalize uses all-or-none branch publication; manual branch cleanup may be required"
        }
        "worktree.deleteBranch" => {
            "deleted local branches require reflog/remote recovery if still available"
        }
        "worktree.pruneBranches" => "pruned branches require manual branch restoration if needed",
        "worktree.discardFiles" => "discarded working-tree changes are externally irreversible",
        "worktree.rebaseOnMain" => {
            "rebase abort/manual reset is the recovery path while state exists"
        }
        "worktree.startMerge" => "worktree.abortMerge is the inverse command while merge is active",
        "worktree.resolveConflict" => "conflict files can be manually edited before continueMerge",
        "worktree.continueMerge" => "manual reset/revert is required after merge completion",
        "worktree.abortMerge" => "startMerge can recreate the merge attempt if inputs still exist",
        "worktree.resolveConflictsWithSubagent" => {
            "subagent conflict resolution writes files; manual review/reset remains the recovery path"
        }
        _ => "domain-specific tests preserve current rollback, no-op, or replay behavior",
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

pub(super) fn domain_workers() -> EngineResult<Vec<WorkerDefinition>> {
    let domains = [
        "system",
        "model",
        "config",
        "settings",
        "logs",
        "memory",
        "mcp",
        "auth",
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
        "tree",
        "repo",
        "import",
        "browser",
        "display",
        "device",
        "voice_notes",
        "transcription",
        "sandbox",
        "cron",
        "blob",
        "codex_app",
        "tool",
        "message",
        "git",
        "worktree",
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

pub(super) fn cron_schedule_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("cron_schedule")?,
        worker_id("cron")?,
        "Cron schedule projection into an engine trigger",
    );
    definition.allowed_delivery_modes = vec![DeliveryMode::Sync];
    definition.visibility = VisibilityScope::Internal;
    definition.config_schema = Some(json!({
        "type": "object",
        "required": ["jobId", "jobName", "enabled", "payloadKind"],
        "additionalProperties": true,
        "properties": {
            "jobId": {"type": "string"},
            "jobName": {"type": "string"},
            "enabled": {"type": "boolean"},
            "payloadKind": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    }));
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
        method if method.starts_with("memory.") => "memory",
        method if method.starts_with("config.") => "config",
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
        method if method.starts_with("mcp.") => "mcp",
        method if method.starts_with("auth.") => "auth",
        method if method.starts_with("approval.") => "approval",
        method if method.starts_with("notifications.") => "notifications",
        method if method.starts_with("plan.") => "plan",
        method if method.starts_with("tree.") => "tree",
        method if method.starts_with("repo.") => "repo",
        method if method.starts_with("import.") => "import",
        method if method.starts_with("browser.") => "browser",
        method if method.starts_with("display.") => "display",
        method if method.starts_with("device.") => "device",
        method if method.starts_with("voiceNotes.") => "voice_notes",
        method if method.starts_with("transcribe.") => "transcription",
        method if method.starts_with("sandbox.") => "sandbox",
        method if method.starts_with("cron.") => "cron",
        method if method.starts_with("blob.") => "blob",
        method if method.starts_with("codexApp.") => "codex_app",
        method if method.starts_with("tool.") => "tool",
        method if method.starts_with("message.") => "message",
        method if method.starts_with("git.") => "git",
        method if method.starts_with("worktree.") => "worktree",
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
        "system.getDiagnostics" => ("system", "get_diagnostics".to_owned()),
        "system.getUpdateStatus" => ("system", "get_update_status".to_owned()),
        "system.shutdown" => ("system", "shutdown".to_owned()),
        "system.checkForUpdates" => ("system", "check_for_updates".to_owned()),
        "codexApp.status" => ("codex_app", "status".to_owned()),
        "blob.get" => ("blob", "get".to_owned()),
        "tool.result" => ("tool", "result".to_owned()),
        "message.delete" => ("message", "delete".to_owned()),
        "cron.list" => ("cron", "list".to_owned()),
        "cron.get" => ("cron", "get".to_owned()),
        "cron.create" => ("cron", "create".to_owned()),
        "cron.update" => ("cron", "update".to_owned()),
        "cron.delete" => ("cron", "delete".to_owned()),
        "cron.run" => ("cron", "run".to_owned()),
        "cron.status" => ("cron", "status".to_owned()),
        "cron.getRuns" => ("cron", "get_runs".to_owned()),
        "model.list" => ("model", "list".to_owned()),
        "model.switch" => ("model", "switch".to_owned()),
        "config.setReasoningLevel" => ("config", "set_reasoning_level".to_owned()),
        "settings.get" => ("settings", "get".to_owned()),
        "settings.update" => ("settings", "update".to_owned()),
        "settings.resetToDefaults" => ("settings", "reset_to_defaults".to_owned()),
        "logs.ingest" => ("logs", "ingest".to_owned()),
        "logs.recent" => ("logs", "recent".to_owned()),
        "memory.retain" => ("memory", "retain".to_owned()),
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
        "session.resume" => ("session", "resume".to_owned()),
        "session.delete" => ("session", "delete".to_owned()),
        "session.fork" => ("session", "fork".to_owned()),
        "session.archive" => ("session", "archive".to_owned()),
        "session.unarchive" => ("session", "unarchive".to_owned()),
        "session.archiveOlderThan" => ("session", "archive_older_than".to_owned()),
        "session.export" => ("session", "export".to_owned()),
        "agent.status" => ("agent", "status".to_owned()),
        "agent.prompt" => ("agent", "prompt".to_owned()),
        "agent.abort" => ("agent", "abort".to_owned()),
        "agent.abortTool" => ("agent", "abort_tool".to_owned()),
        "agent.queuePrompt" => ("agent", "queue_prompt".to_owned()),
        "agent.dequeuePrompt" => ("agent", "dequeue_prompt".to_owned()),
        "agent.clearQueue" => ("agent", "clear_queue".to_owned()),
        "agent.deliverSubagentResults" => ("agent", "deliver_subagent_results".to_owned()),
        "agent.submitConfirmation" => ("agent", "submit_confirmation".to_owned()),
        "agent.submitAnswers" => ("agent", "submit_answers".to_owned()),
        "mcp.status" => ("mcp", "status".to_owned()),
        "mcp.addServer" => ("mcp", "add_server".to_owned()),
        "mcp.removeServer" => ("mcp", "remove_server".to_owned()),
        "mcp.enableServer" => ("mcp", "enable_server".to_owned()),
        "mcp.disableServer" => ("mcp", "disable_server".to_owned()),
        "mcp.restartServer" => ("mcp", "restart_server".to_owned()),
        "mcp.reload" => ("mcp", "reload".to_owned()),
        "mcp.listTools" => ("mcp", "list_tools".to_owned()),
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
        "approval.get" => ("approval", "get".to_owned()),
        "approval.list" => ("approval", "list".to_owned()),
        "approval.resolve" => ("approval", "resolve".to_owned()),
        "auth.get" => ("auth", "get".to_owned()),
        "auth.update" => ("auth", "update".to_owned()),
        "auth.clear" => ("auth", "clear".to_owned()),
        "auth.oauthBegin" => ("auth", "oauth_begin".to_owned()),
        "auth.oauthComplete" => ("auth", "oauth_complete".to_owned()),
        "auth.renameAccount" => ("auth", "rename_account".to_owned()),
        "auth.setActive" => ("auth", "set_active".to_owned()),
        "auth.removeAccount" => ("auth", "remove_account".to_owned()),
        "auth.removeApiKey" => ("auth", "remove_api_key".to_owned()),
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
        "tree.getVisualization" => ("tree", "get_visualization".to_owned()),
        "tree.getBranches" => ("tree", "get_branches".to_owned()),
        "tree.getSubtree" => ("tree", "get_subtree".to_owned()),
        "tree.getAncestors" => ("tree", "get_ancestors".to_owned()),
        "tree.compareBranches" => ("tree", "compare_branches".to_owned()),
        "repo.listSessions" => ("repo", "list_sessions".to_owned()),
        "repo.getDivergence" => ("repo", "get_divergence".to_owned()),
        "import.listSources" => ("import", "list_sources".to_owned()),
        "import.listSessions" => ("import", "list_sessions".to_owned()),
        "import.previewSession" => ("import", "preview_session".to_owned()),
        "import.execute" => ("import", "execute".to_owned()),
        "browser.getStatus" => ("browser", "get_status".to_owned()),
        "browser.startStream" => ("browser", "start_stream".to_owned()),
        "browser.stopStream" => ("browser", "stop_stream".to_owned()),
        "display.stopStream" => ("display", "stop_stream".to_owned()),
        "voiceNotes.list" => ("voice_notes", "list".to_owned()),
        "voiceNotes.save" => ("voice_notes", "save".to_owned()),
        "voiceNotes.delete" => ("voice_notes", "delete".to_owned()),
        "transcribe.listModels" => ("transcription", "list_models".to_owned()),
        "transcribe.audio" => ("transcription", "audio".to_owned()),
        "transcribe.downloadModel" => ("transcription", "download_model".to_owned()),
        "device.register" => ("device", "register".to_owned()),
        "device.unregister" => ("device", "unregister".to_owned()),
        "device.respond" => ("device", "respond".to_owned()),
        "sandbox.listContainers" => ("sandbox", "list_containers".to_owned()),
        "sandbox.startContainer" => ("sandbox", "start_container".to_owned()),
        "sandbox.stopContainer" => ("sandbox", "stop_container".to_owned()),
        "sandbox.killContainer" => ("sandbox", "kill_container".to_owned()),
        "sandbox.removeContainer" => ("sandbox", "remove_container".to_owned()),
        "git.clone" => ("git", "clone".to_owned()),
        "git.syncMain" => ("git", "sync_main".to_owned()),
        "git.push" => ("git", "push".to_owned()),
        "git.listLocalBranches" => ("git", "list_local_branches".to_owned()),
        "git.listRemoteBranches" => ("git", "list_remote_branches".to_owned()),
        "worktree.getStatus" => ("worktree", "get_status".to_owned()),
        "worktree.isGitRepo" => ("worktree", "is_git_repo".to_owned()),
        "worktree.list" => ("worktree", "list".to_owned()),
        "worktree.getDiff" => ("worktree", "get_diff".to_owned()),
        "worktree.getCommittedDiff" => ("worktree", "get_committed_diff".to_owned()),
        "worktree.listSessionBranches" => ("worktree", "list_session_branches".to_owned()),
        "worktree.acquire" => ("worktree", "acquire".to_owned()),
        "worktree.release" => ("worktree", "release".to_owned()),
        "worktree.stageFiles" => ("worktree", "stage_files".to_owned()),
        "worktree.unstageFiles" => ("worktree", "unstage_files".to_owned()),
        "worktree.discardFiles" => ("worktree", "discard_files".to_owned()),
        "worktree.commit" => ("worktree", "commit".to_owned()),
        "worktree.merge" => ("worktree", "merge".to_owned()),
        "worktree.finalizeSession" => ("worktree", "finalize_session".to_owned()),
        "worktree.deleteBranch" => ("worktree", "delete_branch".to_owned()),
        "worktree.pruneBranches" => ("worktree", "prune_branches".to_owned()),
        "worktree.rebaseOnMain" => ("worktree", "rebase_on_main".to_owned()),
        "worktree.startMerge" => ("worktree", "start_merge".to_owned()),
        "worktree.listConflicts" => ("worktree", "list_conflicts".to_owned()),
        "worktree.resolveConflict" => ("worktree", "resolve_conflict".to_owned()),
        "worktree.continueMerge" => ("worktree", "continue_merge".to_owned()),
        "worktree.abortMerge" => ("worktree", "abort_merge".to_owned()),
        "worktree.resolveConflictsWithSubagent" => {
            ("worktree", "resolve_conflicts_with_subagent".to_owned())
        }
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
                    "mcp" => "mcp",
                    "auth" => "auth",
                    "approval" => "approval",
                    "logs" => "logs",
                    "model" => "model",
                    "config" => "config",
                    "memory" => "memory",
                    "notifications" => "notifications",
                    "plan" => "plan",
                    "tree" => "tree",
                    "repo" => "repo",
                    "import" => "import",
                    "browser" => "browser",
                    "display" => "display",
                    "device" => "device",
                    "voiceNotes" => "voice_notes",
                    "transcribe" => "transcription",
                    "sandbox" => "sandbox",
                    "cron" => "cron",
                    "blob" => "blob",
                    "codexApp" => "codex_app",
                    "tool" => "tool",
                    "message" => "message",
                    "git" => "git",
                    "worktree" => "worktree",
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
        (Some("config"), "read") => "config.read",
        (Some("config"), "write") => "config.write",
        (Some("settings"), "read") => "settings.read",
        (Some("settings"), "write") => "settings.write",
        (Some("logs"), "read") => "logs.read",
        (Some("logs"), "write") => "logs.write",
        (Some("memory"), "read") => "memory.read",
        (Some("memory"), "write") => "memory.write",
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
        (Some("mcp"), "read") => "mcp.read",
        (Some("mcp"), "write") => "mcp.write",
        (Some("auth"), "read") => "auth.read",
        (Some("auth"), "write") => "auth.write",
        (Some("approval"), "read") => "approval.read",
        (Some("approval"), "write") => "approval.resolve",
        (Some("notifications"), "read") => "notifications.read",
        (Some("notifications"), "write") => "notifications.write",
        (Some("plan"), "read") => "plan.read",
        (Some("plan"), "write") => "plan.write",
        (Some("tree"), "read") => "tree.read",
        (Some("tree"), "write") => "tree.write",
        (Some("repo"), "read") => "repo.read",
        (Some("repo"), "write") => "repo.write",
        (Some("import"), "read") => "import.read",
        (Some("import"), "write") => "import.write",
        (Some("browser"), "read") => "browser.read",
        (Some("browser"), "write") => "browser.write",
        (Some("display"), "read") => "display.read",
        (Some("display"), "write") => "display.write",
        (Some("device"), "read") => "device.read",
        (Some("device"), "write") => "device.write",
        (Some("voice_notes"), "read") => "voice_notes.read",
        (Some("voice_notes"), "write") => "voice_notes.write",
        (Some("transcription"), "read") => "transcription.read",
        (Some("transcription"), "write") => "transcription.write",
        (Some("sandbox"), "read") => "sandbox.read",
        (Some("sandbox"), "write") => "sandbox.write",
        (Some("cron"), "read") => "cron.read",
        (Some("cron"), "write") => "cron.write",
        (Some("blob"), "read") => "blob.read",
        (Some("blob"), "write") => "blob.write",
        (Some("codex_app"), "read") => "codex_app.read",
        (Some("codex_app"), "write") => "codex_app.write",
        (Some("tool"), "read") => "tool.read",
        (Some("tool"), "write") => "tool.write",
        (Some("message"), "read") => "message.read",
        (Some("message"), "write") => "message.write",
        (Some("git"), "read") => "git.read",
        (Some("git"), "write") => "git.write",
        (Some("worktree"), "read") => "worktree.read",
        (Some("worktree"), "write") => "worktree.write",
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
