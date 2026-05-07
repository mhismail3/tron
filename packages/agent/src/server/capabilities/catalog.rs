use std::collections::BTreeSet;

use serde_json::json;

use super::schemas::{request_schema_for_method, response_schema_for_method};
use crate::engine::{
    ActorId, AuthorityGrantId, AuthorityRequirement, CompensationContract, CompensationKind,
    DeliveryMode, EffectClass, EngineError, FunctionDefinition, FunctionId, IdempotencyContract,
    IdempotencyKeySource, Provenance, ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
    TriggerDefinition, TriggerId, TriggerTypeDefinition, TriggerTypeId, VisibilityScope,
    WorkerDefinition, WorkerId, WorkerKind,
};

/// System actor used for server-owned capability registration.
pub(crate) const SYSTEM_OWNER_ACTOR: &str = "system";
/// Authority grant carried by first-party engine transport and domain workers.
pub(crate) const SYSTEM_AUTHORITY_GRANT: &str = "engine-transport";

/// Idempotency source for a public engine transport method.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransportIdempotencyMode {
    /// Read/delegated transport method; no transport-level key is required.
    NotRequired,
    /// Engine-native transport mode: payload contains an explicit key.
    ExplicitRequired,
}

impl TransportIdempotencyMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::NotRequired => "not_required",
            Self::ExplicitRequired => "explicit_required",
        }
    }
}

/// Canonical server capability contract.
#[derive(Clone, Debug, PartialEq)]
pub struct CapabilitySpec {
    /// Stable canonical operation key used by the domain dispatcher.
    pub method: &'static str,
    /// Stable engine function id.
    pub function_id: FunctionId,
    /// Owner worker id.
    pub owner_worker: WorkerId,
    /// Domain worker that owns the capability behavior.
    pub domain_worker: WorkerId,
    /// Effect class.
    pub effect_class: EffectClass,
    /// Risk level.
    pub risk_level: RiskLevel,
    /// Engine visibility.
    pub visibility: VisibilityScope,
    /// Optional authority scope required to invoke.
    pub authority_scope: Option<&'static str>,
    /// Public transport idempotency mode when this function is exposed as an
    /// `engine.*` JSON-RPC method.
    pub idempotency_mode: TransportIdempotencyMode,
    /// Domain module/group provenance.
    pub handler_module: &'static str,
}

/// Agent-facing canonical function contract.
#[derive(Clone, Debug, PartialEq)]
pub struct CanonicalCapabilitySpec {
    /// Stable canonical function id shown to agents and engine-native clients.
    pub function_id: FunctionId,
    /// Worker that owns the function implementation.
    pub owner_worker: WorkerId,
    /// Engine visibility for the function.
    pub visibility: VisibilityScope,
    /// Effect class enforced by the engine.
    pub effect_class: EffectClass,
    /// Risk level used by approval and guardrail policy.
    pub risk_level: RiskLevel,
    /// Domain authority scope required for direct invocation.
    pub authority_scope: Option<&'static str>,
    /// Canonical operation key routed to the domain implementation.
    pub method: &'static str,
}

#[derive(Clone, Copy)]
struct CapabilitySeed {
    method: &'static str,
}

macro_rules! capability_seed {
    ($method:literal) => {
        CapabilitySeed { method: $method }
    };
}

const PUBLIC_JSON_RPC_METHODS: &[&str] = &[
    "engine.discover",
    "engine.inspect",
    "engine.watch",
    "engine.invoke",
    "engine.promote",
];

const CAPABILITY_SEEDS: &[CapabilitySeed] = &[
    capability_seed!("engine.discover"),
    capability_seed!("engine.inspect"),
    capability_seed!("engine.watch"),
    capability_seed!("engine.invoke"),
    capability_seed!("engine.promote"),
    capability_seed!("system::ping"),
    capability_seed!("system::get_info"),
    capability_seed!("system::get_diagnostics"),
    capability_seed!("system::shutdown"),
    capability_seed!("system::check_for_updates"),
    capability_seed!("system::get_update_status"),
    capability_seed!("codex_app::status"),
    capability_seed!("blob::get"),
    capability_seed!("session::create"),
    capability_seed!("session::resume"),
    capability_seed!("session::list"),
    capability_seed!("session::delete"),
    capability_seed!("session::fork"),
    capability_seed!("session::get_head"),
    capability_seed!("session::get_state"),
    capability_seed!("session::get_history"),
    capability_seed!("session::reconstruct"),
    capability_seed!("session::archive"),
    capability_seed!("session::unarchive"),
    capability_seed!("session::archive_older_than"),
    capability_seed!("session::export"),
    capability_seed!("agent::prompt"),
    capability_seed!("agent::abort"),
    capability_seed!("agent::abort_tool"),
    capability_seed!("agent::status"),
    capability_seed!("agent::queue_prompt"),
    capability_seed!("agent::dequeue_prompt"),
    capability_seed!("agent::clear_queue"),
    capability_seed!("agent::deliver_subagent_results"),
    capability_seed!("agent::submit_confirmation"),
    capability_seed!("agent::submit_answers"),
    capability_seed!("model::list"),
    capability_seed!("model::switch"),
    capability_seed!("config::set_reasoning_level"),
    capability_seed!("context::get_snapshot"),
    capability_seed!("context::get_detailed_snapshot"),
    capability_seed!("context::preview_compaction"),
    capability_seed!("context::get_audit_trace"),
    capability_seed!("context::should_compact"),
    capability_seed!("context::confirm_compaction"),
    capability_seed!("context::can_accept_turn"),
    capability_seed!("context::clear"),
    capability_seed!("context::compact"),
    capability_seed!("events::get_history"),
    capability_seed!("events::get_since"),
    capability_seed!("events::subscribe"),
    capability_seed!("events::unsubscribe"),
    capability_seed!("events::append"),
    capability_seed!("settings::get"),
    capability_seed!("settings::update"),
    capability_seed!("settings::reset_to_defaults"),
    capability_seed!("approval::get"),
    capability_seed!("approval::list"),
    capability_seed!("approval::resolve"),
    capability_seed!("auth::get"),
    capability_seed!("auth::update"),
    capability_seed!("auth::clear"),
    capability_seed!("auth::oauth_begin"),
    capability_seed!("auth::oauth_complete"),
    capability_seed!("auth::rename_account"),
    capability_seed!("auth::set_active"),
    capability_seed!("auth::remove_account"),
    capability_seed!("auth::remove_api_key"),
    capability_seed!("tool::result"),
    capability_seed!("message::delete"),
    capability_seed!("logs::ingest"),
    capability_seed!("logs::recent"),
    capability_seed!("memory::retain"),
    capability_seed!("mcp::status"),
    capability_seed!("mcp::add_server"),
    capability_seed!("mcp::remove_server"),
    capability_seed!("mcp::enable_server"),
    capability_seed!("mcp::disable_server"),
    capability_seed!("mcp::restart_server"),
    capability_seed!("mcp::reload"),
    capability_seed!("mcp::list_tools"),
    capability_seed!("skills::list"),
    capability_seed!("skills::get"),
    capability_seed!("skills::refresh"),
    capability_seed!("skills::activate"),
    capability_seed!("skills::deactivate"),
    capability_seed!("skills::active"),
    capability_seed!("filesystem::list_dir"),
    capability_seed!("filesystem::get_home"),
    capability_seed!("filesystem::create_dir"),
    capability_seed!("filesystem::read_file"),
    capability_seed!("tree::get_visualization"),
    capability_seed!("tree::get_branches"),
    capability_seed!("tree::get_subtree"),
    capability_seed!("tree::get_ancestors"),
    capability_seed!("tree::compare_branches"),
    capability_seed!("import::list_sources"),
    capability_seed!("import::list_sessions"),
    capability_seed!("import::preview_session"),
    capability_seed!("import::execute"),
    capability_seed!("browser::start_stream"),
    capability_seed!("browser::stop_stream"),
    capability_seed!("browser::get_status"),
    capability_seed!("display::stop_stream"),
    capability_seed!("job::background"),
    capability_seed!("job::cancel"),
    capability_seed!("job::list"),
    capability_seed!("job::subscribe"),
    capability_seed!("job::unsubscribe"),
    capability_seed!("worktree::get_status"),
    capability_seed!("worktree::is_git_repo"),
    capability_seed!("worktree::commit"),
    capability_seed!("worktree::merge"),
    capability_seed!("worktree::list"),
    capability_seed!("worktree::get_diff"),
    capability_seed!("worktree::acquire"),
    capability_seed!("worktree::release"),
    capability_seed!("worktree::list_session_branches"),
    capability_seed!("worktree::get_committed_diff"),
    capability_seed!("worktree::finalize_session"),
    capability_seed!("worktree::delete_branch"),
    capability_seed!("worktree::prune_branches"),
    capability_seed!("worktree::stage_files"),
    capability_seed!("worktree::unstage_files"),
    capability_seed!("worktree::discard_files"),
    capability_seed!("transcription::audio"),
    capability_seed!("transcription::list_models"),
    capability_seed!("transcription::download_model"),
    capability_seed!("device::register"),
    capability_seed!("device::unregister"),
    capability_seed!("device::respond"),
    capability_seed!("plan::enter"),
    capability_seed!("plan::exit"),
    capability_seed!("plan::get_state"),
    capability_seed!("voice_notes::save"),
    capability_seed!("voice_notes::list"),
    capability_seed!("voice_notes::delete"),
    capability_seed!("git::clone"),
    capability_seed!("git::sync_main"),
    capability_seed!("git::push"),
    capability_seed!("git::list_local_branches"),
    capability_seed!("git::list_remote_branches"),
    capability_seed!("worktree::rebase_on_main"),
    capability_seed!("worktree::start_merge"),
    capability_seed!("worktree::list_conflicts"),
    capability_seed!("worktree::resolve_conflict"),
    capability_seed!("worktree::continue_merge"),
    capability_seed!("worktree::abort_merge"),
    capability_seed!("worktree::resolve_conflicts_with_subagent"),
    capability_seed!("repo::list_sessions"),
    capability_seed!("repo::get_divergence"),
    capability_seed!("sandbox::list_containers"),
    capability_seed!("sandbox::start_container"),
    capability_seed!("sandbox::stop_container"),
    capability_seed!("sandbox::kill_container"),
    capability_seed!("sandbox::remove_container"),
    capability_seed!("notifications::list"),
    capability_seed!("notifications::mark_read"),
    capability_seed!("notifications::mark_all_read"),
    capability_seed!("prompt_library::history_list"),
    capability_seed!("prompt_library::history_delete"),
    capability_seed!("prompt_library::history_clear"),
    capability_seed!("prompt_library::snippet_list"),
    capability_seed!("prompt_library::snippet_get"),
    capability_seed!("prompt_library::snippet_create"),
    capability_seed!("prompt_library::snippet_update"),
    capability_seed!("prompt_library::snippet_delete"),
    capability_seed!("cron::list"),
    capability_seed!("cron::get"),
    capability_seed!("cron::create"),
    capability_seed!("cron::update"),
    capability_seed!("cron::delete"),
    capability_seed!("cron::run"),
    capability_seed!("cron::status"),
    capability_seed!("cron::get_runs"),
];

/// Public JSON-RPC engine transport methods.
pub fn public_json_rpc_methods() -> impl Iterator<Item = &'static str> {
    PUBLIC_JSON_RPC_METHODS.iter().copied()
}

/// Build canonical capability specs from the complete domain capability catalog.
pub fn canonical_capability_specs() -> EngineResult<Vec<CanonicalCapabilitySpec>> {
    validate_seed_uniqueness()?;
    CAPABILITY_SEEDS
        .iter()
        .map(|seed| {
            let spec = spec_from_seed(*seed)?;
            Ok(CanonicalCapabilitySpec {
                function_id: spec.function_id,
                owner_worker: spec.owner_worker,
                visibility: spec.visibility,
                effect_class: spec.effect_class,
                risk_level: spec.risk_level,
                authority_scope: spec.authority_scope,
                method: spec.method,
            })
        })
        .collect()
}

/// Build and validate the public JSON-RPC engine transport method set.
pub fn public_json_rpc_specs(registered_methods: &[String]) -> EngineResult<Vec<CapabilitySpec>> {
    let registered = registered_methods.iter().cloned().collect::<BTreeSet<_>>();
    let seeded = PUBLIC_JSON_RPC_METHODS
        .iter()
        .map(|method| (*method).to_owned())
        .collect::<BTreeSet<_>>();

    if let Some(method) = registered.difference(&seeded).next() {
        return Err(EngineError::PolicyViolation(format!(
            "JSON-RPC method {method} is registered without a public engine transport spec"
        )));
    }
    if let Some(method) = seeded.difference(&registered).next() {
        return Err(EngineError::PolicyViolation(format!(
            "public engine transport method {method} does not match a registered method"
        )));
    }

    let mut specs = Vec::with_capacity(PUBLIC_JSON_RPC_METHODS.len());
    for method in PUBLIC_JSON_RPC_METHODS {
        let seed = CapabilitySeed { method: *method };
        let spec = spec_from_seed(seed)?;
        if spec.visibility.is_agent_visible()
            && spec.effect_class.is_mutating()
            && spec.idempotency_mode == TransportIdempotencyMode::NotRequired
        {
            return Err(EngineError::PolicyViolation(format!(
                "agent-visible public engine transport method {} lacks idempotency",
                spec.method
            )));
        }
        if request_schema_for_method(spec.method).is_none()
            || response_schema_for_method(spec.method).is_none()
        {
            return Err(EngineError::PolicyViolation(format!(
                "public engine transport method {} must declare strict request/response schemas",
                spec.method
            )));
        }
        if spec.effect_class.is_mutating() {
            if spec.authority_scope.is_none() {
                return Err(EngineError::PolicyViolation(format!(
                    "mutating public engine transport method {} must require an authority scope",
                    spec.method
                )));
            }
            if spec.idempotency_mode == TransportIdempotencyMode::NotRequired {
                return Err(EngineError::PolicyViolation(format!(
                    "mutating public engine transport method {} lacks explicit idempotency",
                    spec.method
                )));
            }
            if spec.risk_level >= RiskLevel::High
                && high_risk_contract_for_method(spec.method).is_none()
            {
                return Err(EngineError::PolicyViolation(format!(
                    "high-risk public engine transport method {} lacks a high-risk contract",
                    spec.method
                )));
            }
            let definition = function_definition_for_capability(&spec);
            if spec.risk_level >= RiskLevel::High && definition.compensation.is_none() {
                return Err(EngineError::PolicyViolation(format!(
                    "high-risk public engine transport method {} lacks typed compensation metadata",
                    spec.method
                )));
            }
            if requires_resource_lease_metadata(spec.method) && definition.resource_lease.is_none()
            {
                return Err(EngineError::PolicyViolation(format!(
                    "public engine transport method {} lacks typed resource lease metadata",
                    spec.method
                )));
            }
        } else if spec.authority_scope.is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "read public engine transport method {} must require an authority scope",
                spec.method
            )));
        }
        specs.push(spec);
    }
    Ok(specs)
}

pub(crate) fn public_json_rpc_spec_for_method(
    method: &str,
) -> EngineResult<Option<CapabilitySpec>> {
    let Some(seed) = PUBLIC_JSON_RPC_METHODS
        .iter()
        .find(|candidate| **candidate == method)
        .map(|method| CapabilitySeed { method: *method })
    else {
        return Ok(None);
    };
    spec_from_seed(seed).map(Some)
}

pub(crate) fn capability_spec_for_method(method: &str) -> EngineResult<CapabilitySpec> {
    let Some(seed) = CAPABILITY_SEEDS
        .iter()
        .find(|candidate| candidate.method == method)
    else {
        return Err(EngineError::PolicyViolation(format!(
            "canonical capability operation {method} is not registered"
        )));
    };
    spec_from_seed(*seed)
}

fn validate_seed_uniqueness() -> EngineResult<()> {
    let mut seen = BTreeSet::new();
    for seed in CAPABILITY_SEEDS {
        if !seen.insert(seed.method) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate canonical capability spec for {}",
                seed.method
            )));
        }
    }
    Ok(())
}

fn spec_from_seed(seed: CapabilitySeed) -> EngineResult<CapabilitySpec> {
    let effect_class = effect_class_for_method(seed.method);
    let visibility = VisibilityScope::System;
    let owner_worker = domain_worker_for_method(seed.method)?;
    Ok(CapabilitySpec {
        method: seed.method,
        function_id: function_id_for_method(seed.method)?,
        owner_worker: owner_worker.clone(),
        domain_worker: domain_worker_for_method(seed.method)?,
        effect_class,
        risk_level: risk_for_method(seed.method, effect_class),
        visibility,
        authority_scope: Some(domain_authority_scope_for_method(seed.method, effect_class)),
        idempotency_mode: idempotency_mode_for_method(seed.method, effect_class),
        handler_module: handler_module_for_method(seed.method),
    })
}

fn idempotency_mode_for_method(
    method: &str,
    effect_class: EffectClass,
) -> TransportIdempotencyMode {
    if method == "engine.promote" {
        TransportIdempotencyMode::ExplicitRequired
    } else {
        let _ = effect_class;
        TransportIdempotencyMode::NotRequired
    }
}

fn is_pure_read_method(method: &str) -> bool {
    matches!(
        method,
        "engine.discover"
            | "engine.inspect"
            | "engine.watch"
            | "system::ping"
            | "system::get_info"
            | "system::get_diagnostics"
            | "system::get_update_status"
            | "codex_app::status"
            | "agent::status"
            | "browser::get_status"
            | "blob::get"
            | "cron::status"
            | "cron::list"
            | "cron::get"
            | "cron::get_runs"
            | "context::get_snapshot"
            | "context::get_detailed_snapshot"
            | "context::get_audit_trace"
            | "context::preview_compaction"
            | "context::should_compact"
            | "context::can_accept_turn"
            | "events::get_history"
            | "events::get_since"
            | "filesystem::get_home"
            | "filesystem::list_dir"
            | "filesystem::read_file"
            | "git::list_local_branches"
            | "git::list_remote_branches"
            | "import::list_sources"
            | "import::list_sessions"
            | "import::preview_session"
            | "job::list"
            | "logs::recent"
            | "mcp::status"
            | "mcp::list_tools"
            | "model::list"
            | "notifications::list"
            | "plan::get_state"
            | "prompt_library::history_list"
            | "prompt_library::snippet_list"
            | "prompt_library::snippet_get"
            | "repo::list_sessions"
            | "repo::get_divergence"
            | "sandbox::list_containers"
            | "session::list"
            | "session::get_head"
            | "session::get_state"
            | "session::get_history"
            | "session::reconstruct"
            | "session::export"
            | "settings::get"
            | "skills::list"
            | "skills::get"
            | "skills::active"
            | "system::check_for_updates"
            | "transcription::list_models"
            | "tree::get_visualization"
            | "tree::get_branches"
            | "tree::get_subtree"
            | "tree::get_ancestors"
            | "tree::compare_branches"
            | "voice_notes::list"
            | "worktree::get_status"
            | "worktree::is_git_repo"
            | "worktree::list"
            | "worktree::get_diff"
            | "worktree::get_committed_diff"
            | "worktree::list_session_branches"
            | "worktree::list_conflicts"
            | "approval::get"
            | "approval::list"
            | "auth::get"
    )
}

fn effect_class_for_method(method: &str) -> EffectClass {
    if method == "engine.invoke" {
        return EffectClass::DelegatedInvocation;
    }
    if method == "engine.promote" {
        return EffectClass::IdempotentWrite;
    }
    if is_pure_read_method(method) {
        return EffectClass::PureRead;
    }
    if matches!(
        method,
        "mcp::add_server"
            | "mcp::remove_server"
            | "mcp::enable_server"
            | "mcp::disable_server"
            | "mcp::restart_server"
            | "mcp::reload"
    ) {
        return EffectClass::ExternalSideEffect;
    }
    if matches!(
        method,
        "settings::update"
            | "settings::reset_to_defaults"
            | "model::switch"
            | "config::set_reasoning_level"
            | "context::confirm_compaction"
            | "context::compact"
            | "agent::abort"
            | "agent::abort_tool"
            | "cron::create"
            | "cron::update"
            | "worktree::commit"
            | "worktree::merge"
            | "worktree::finalize_session"
            | "worktree::rebase_on_main"
            | "worktree::start_merge"
            | "worktree::resolve_conflict"
            | "worktree::continue_merge"
            | "worktree::abort_merge"
    ) {
        return EffectClass::ReversibleSideEffect;
    }
    if matches!(method, "agent::prompt" | "cron::run") {
        return EffectClass::ExternalSideEffect;
    }
    if matches!(method, "memory::retain") {
        return EffectClass::ExternalSideEffect;
    }
    if matches!(
        method,
        "events::append" | "logs::ingest" | "import::execute"
    ) {
        return EffectClass::AppendOnlyEvent;
    }
    if matches!(
        method,
        "system::shutdown"
            | "message::delete"
            | "cron::delete"
            | "voice_notes::delete"
            | "prompt_library::history_delete"
            | "prompt_library::history_clear"
            | "prompt_library::snippet_delete"
            | "session::delete"
            | "context::clear"
            | "worktree::delete_branch"
            | "worktree::discard_files"
            | "worktree::prune_branches"
            | "sandbox::kill_container"
            | "sandbox::remove_container"
    ) {
        return EffectClass::IrreversibleSideEffect;
    }
    if matches!(
        method,
        "git::clone" | "git::sync_main" | "git::push" | "worktree::resolve_conflicts_with_subagent"
    ) {
        return EffectClass::ExternalSideEffect;
    }
    if method.starts_with("git::")
        || method.starts_with("browser::")
        || method.starts_with("display::")
        || method.starts_with("device::")
        || method.starts_with("transcription::")
        || method.starts_with("sandbox::")
    {
        return EffectClass::ExternalSideEffect;
    }
    EffectClass::IdempotentWrite
}

fn risk_for_method(method: &str, effect: EffectClass) -> RiskLevel {
    if matches!(method, "git::push" | "system::shutdown") {
        RiskLevel::Critical
    } else if method == "engine.promote" {
        RiskLevel::Medium
    } else if matches!(
        method,
        "auth::update"
            | "auth::clear"
            | "auth::oauth_begin"
            | "auth::oauth_complete"
            | "auth::rename_account"
            | "auth::set_active"
            | "auth::remove_account"
            | "auth::remove_api_key"
            | "settings::update"
            | "settings::reset_to_defaults"
            | "context::confirm_compaction"
            | "context::clear"
            | "context::compact"
            | "session::delete"
            | "session::archive_older_than"
            | "job::cancel"
            | "approval::resolve"
            | "agent::prompt"
            | "agent::abort"
            | "message::delete"
            | "cron::create"
            | "cron::update"
            | "cron::delete"
            | "cron::run"
            | "model::switch"
            | "config::set_reasoning_level"
            | "memory::retain"
            | "import::execute"
            | "git::clone"
            | "git::sync_main"
            | "worktree::commit"
            | "worktree::merge"
            | "worktree::finalize_session"
            | "worktree::delete_branch"
            | "worktree::prune_branches"
            | "worktree::discard_files"
            | "worktree::rebase_on_main"
            | "worktree::start_merge"
            | "worktree::resolve_conflict"
            | "worktree::continue_merge"
            | "worktree::abort_merge"
            | "worktree::resolve_conflicts_with_subagent"
            | "sandbox::start_container"
            | "sandbox::stop_container"
            | "sandbox::kill_container"
            | "sandbox::remove_container"
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

pub(crate) fn function_definition_for_capability(spec: &CapabilitySpec) -> FunctionDefinition {
    let mut definition = FunctionDefinition::new(
        spec.function_id.clone(),
        spec.owner_worker.clone(),
        format!("Canonical domain capability {}", spec.method),
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
    if let Some(request_schema) = request_schema_for_method(spec.method) {
        definition = definition.with_request_schema(request_schema);
    }
    if let Some(response_schema) = response_schema_for_method(spec.method) {
        definition = definition.with_response_schema(response_schema);
    }
    definition.metadata = json!({
        "operationKey": spec.method,
        "domainWorker": spec.domain_worker.as_str(),
        "canonicalCapability": spec.function_id.as_str(),
        "domainAuthorityScope": spec.authority_scope,
        "idempotencyMode": spec.idempotency_mode.as_str(),
        "handlerModule": spec.handler_module,
        "highRiskContract": high_risk_contract_for_method(spec.method),
    });
    definition
}

fn idempotency_contract_for_method(method: &str) -> IdempotencyContract {
    if method == "engine.promote" {
        IdempotencyContract::caller_session_engine_ledger()
    } else if method.starts_with("logs::")
        || method.starts_with("mcp::")
        || method == "filesystem::create_dir"
        || method == "job::unsubscribe"
        || method == "job::background"
        || method == "job::cancel"
        || method == "session::create"
        || method == "session::archive_older_than"
        || method == "approval::resolve"
        || method.starts_with("auth::")
        || method.starts_with("browser::")
        || method.starts_with("display::")
        || method.starts_with("device::")
        || method == "import::execute"
        || method.starts_with("sandbox::")
        || method.starts_with("transcription::")
        || method.starts_with("voice_notes::")
        || method.starts_with("notifications::")
        || method.starts_with("prompt_library::history_")
        || method.starts_with("prompt_library::snippet_")
        || method == "skills::refresh"
        || method.starts_with("settings::")
        || method.starts_with("cron::")
        || method == "git::clone"
    {
        IdempotencyContract::caller_system_engine_ledger()
    } else {
        IdempotencyContract::caller_session_engine_ledger()
    }
}

fn settings_write_requires_approval(method: &str) -> bool {
    matches!(
        method,
        "engine.promote"
            | "settings::update"
            | "settings::reset_to_defaults"
            | "context::confirm_compaction"
            | "context::compact"
            | "session::archive_older_than"
            | "job::cancel"
            | "agent::prompt"
            | "agent::abort"
            | "message::delete"
            | "mcp::add_server"
            | "mcp::remove_server"
            | "mcp::enable_server"
            | "mcp::disable_server"
            | "mcp::restart_server"
            | "mcp::reload"
            | "cron::create"
            | "cron::update"
            | "cron::delete"
            | "cron::run"
            | "model::switch"
            | "config::set_reasoning_level"
            | "memory::retain"
            | "import::execute"
            | "git::clone"
            | "git::sync_main"
            | "git::push"
            | "worktree::commit"
            | "worktree::merge"
            | "worktree::finalize_session"
            | "worktree::delete_branch"
            | "worktree::prune_branches"
            | "worktree::discard_files"
            | "worktree::rebase_on_main"
            | "worktree::start_merge"
            | "worktree::resolve_conflict"
            | "worktree::continue_merge"
            | "worktree::abort_merge"
            | "worktree::resolve_conflicts_with_subagent"
            | "auth::update"
            | "auth::clear"
            | "auth::oauth_begin"
            | "auth::oauth_complete"
            | "auth::rename_account"
            | "auth::set_active"
            | "auth::remove_account"
            | "auth::remove_api_key"
            | "sandbox::start_container"
            | "sandbox::stop_container"
            | "sandbox::kill_container"
            | "sandbox::remove_container"
            | "voice_notes::delete"
            | "system::shutdown"
    )
}

fn requires_resource_lease_metadata(method: &str) -> bool {
    resource_lease_requirement_for_method(method).is_some()
}

fn resource_lease_requirement_for_method(method: &str) -> Option<ResourceLeaseRequirement> {
    let (kind, template, ttl_ms) = match method {
        "model::switch" => ("session", "session:{sessionId}:model", 60_000),
        "config::set_reasoning_level" => ("session", "session:{sessionId}:reasoning", 60_000),
        "memory::retain" => ("session", "session:{sessionId}:memory-retain", 300_000),
        "import::execute" => ("import", "import:{sessionPath}", 300_000),
        "auth::update"
        | "auth::clear"
        | "auth::oauth_begin"
        | "auth::oauth_complete"
        | "auth::rename_account"
        | "auth::set_active"
        | "auth::remove_account"
        | "auth::remove_api_key" => ("auth", "auth:auth-json", 60_000),
        "system::shutdown" => ("system", "system:shutdown", 60_000),
        "browser::start_stream" | "browser::stop_stream" => ("browser", "browser:stream", 60_000),
        "display::stop_stream" => ("display", "display:{streamId}", 60_000),
        "device::register" | "device::unregister" => ("device", "device:{deviceToken}", 60_000),
        "device::respond" => ("device", "device-request:{requestId}", 60_000),
        "transcription::audio" => ("transcription", "transcription:audio", 300_000),
        "transcription::download_model" => ("transcription", "transcription:model-cache", 900_000),
        "voice_notes::save" => ("voice_notes", "voice-notes:inbox", 60_000),
        "voice_notes::delete" => ("voice_notes", "voice-note:{filename}", 60_000),
        "sandbox::start_container"
        | "sandbox::stop_container"
        | "sandbox::kill_container"
        | "sandbox::remove_container" => ("sandbox", "container:{name}", 300_000),
        "git::clone" => ("git", "clone:{targetPath}", 1_800_000),
        "git::sync_main" => ("git", "session:{sessionId}:sync-main", 900_000),
        "git::push" => ("git", "session:{sessionId}:push", 900_000),
        "worktree::acquire" | "worktree::release" => {
            ("worktree", "session:{sessionId}:assignment", 300_000)
        }
        "worktree::stage_files" | "worktree::unstage_files" | "worktree::discard_files" => {
            ("worktree", "session:{sessionId}:index", 300_000)
        }
        "worktree::commit"
        | "worktree::merge"
        | "worktree::finalize_session"
        | "worktree::delete_branch"
        | "worktree::prune_branches"
        | "worktree::rebase_on_main"
        | "worktree::start_merge"
        | "worktree::resolve_conflict"
        | "worktree::continue_merge"
        | "worktree::abort_merge"
        | "worktree::resolve_conflicts_with_subagent" => {
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
            "model::switch" => (
                true,
                "session",
                "session:{sessionId}:model",
                60_000,
                "serializes model selection and session cache invalidation",
            ),
            "config::set_reasoning_level" => (
                true,
                "session",
                "session:{sessionId}:reasoning",
                60_000,
                "serializes reasoning-level event writes and session cache invalidation",
            ),
            "memory::retain" => (
                true,
                "session",
                "session:{sessionId}:memory-retain",
                300_000,
                "serializes retain startup before the existing background retain guard owns the long-running summarizer",
            ),
            "import::execute" => (
                true,
                "import",
                "import:{canonicalSessionPath}",
                300_000,
                "serializes session import for one source transcript path",
            ),
            "git::clone" => (
                true,
                "git",
                "clone:{targetPath}",
                1_800_000,
                "serializes clone operations into one target path",
            ),
            "auth::update"
            | "auth::clear"
            | "auth::oauth_begin"
            | "auth::oauth_complete"
            | "auth::rename_account"
            | "auth::set_active"
            | "auth::remove_account"
            | "auth::remove_api_key" => (
                true,
                "auth",
                "auth:auth-json",
                60_000,
                "serializes credential-file mutation, OAuth flow mutation, and auth broadcasts",
            ),
            "system::shutdown" => (
                true,
                "system",
                "system:shutdown",
                60_000,
                "serializes the graceful server shutdown command",
            ),
            "sandbox::start_container"
            | "sandbox::stop_container"
            | "sandbox::kill_container"
            | "sandbox::remove_container" => (
                true,
                "sandbox",
                "container:{name}",
                300_000,
                "serializes lifecycle operations for one local sandbox container",
            ),
            "voice_notes::delete" => (
                true,
                "voice_notes",
                "voice-note:{filename}",
                60_000,
                "serializes deletion of one local voice-note file",
            ),
            "git::sync_main" => (
                true,
                "git",
                "session:{sessionId}:sync-main",
                900_000,
                "serializes main-branch synchronization for the session repository",
            ),
            "git::push" => (
                true,
                "git",
                "session:{sessionId}:push",
                900_000,
                "serializes outbound pushes for a session worktree",
            ),
            "worktree::commit" | "worktree::merge" | "worktree::finalize_session" => (
                true,
                "worktree",
                "session:{sessionId}:workflow",
                900_000,
                "serializes high-risk branch/workflow mutations for a session worktree",
            ),
            "worktree::delete_branch" | "worktree::prune_branches" | "worktree::discard_files" => (
                true,
                "worktree",
                "session:{sessionId}:workflow",
                900_000,
                "serializes destructive branch/index mutations for a session worktree",
            ),
            "worktree::rebase_on_main"
            | "worktree::start_merge"
            | "worktree::resolve_conflict"
            | "worktree::continue_merge"
            | "worktree::abort_merge"
            | "worktree::resolve_conflicts_with_subagent" => (
                true,
                "worktree",
                "session:{sessionId}:workflow",
                900_000,
                "serializes merge/rebase conflict workflows for a session worktree",
            ),
            method
                if matches!(
                    method,
                    "settings::update"
                        | "settings::reset_to_defaults"
                        | "context::confirm_compaction"
                        | "context::clear"
                        | "context::compact"
                        | "session::delete"
                        | "session::archive_older_than"
                        | "job::cancel"
                        | "approval::resolve"
                        | "agent::prompt"
                        | "agent::abort"
                        | "message::delete"
                        | "prompt_library::history_delete"
                        | "prompt_library::history_clear"
                        | "prompt_library::snippet_delete"
                        | "cron::create"
                        | "cron::update"
                        | "cron::delete"
                        | "cron::run"
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
        "model::switch" => {
            "previousModel is returned and persisted in config.model_switch for manual reversal"
        }
        "config::set_reasoning_level" => {
            "previousLevel is returned and persisted in config.reasoning_level for manual reversal"
        }
        "memory::retain" => {
            "background retain writes a memory.retained boundary; failures emit memory update completion without duplicate retention"
        }
        "import::execute" => {
            "import is append-only and duplicate sources return alreadyImported; full rollback is deferred"
        }
        "auth::update" | "auth::clear" | "auth::oauth_begin" | "auth::oauth_complete" => {
            "auth changes are masked in responses; manual auth.json recovery or inverse credential commands are available"
        }
        "auth::rename_account"
        | "auth::set_active"
        | "auth::remove_account"
        | "auth::remove_api_key" => {
            "account/key changes can be manually restored through auth update or OAuth login"
        }
        "system::shutdown" => {
            "shutdown is irreversible for the current process; restart Tron manually"
        }
        "sandbox::start_container" | "sandbox::stop_container" => {
            "inverse container lifecycle command can be run manually if the runtime is still available"
        }
        "sandbox::kill_container" | "sandbox::remove_container" => {
            "sandbox kill/remove is external and may require manual container recreation"
        }
        "git::clone" => {
            "manual cleanup of the target directory is required if clone partially succeeds"
        }
        "git::sync_main" => {
            "sync_main uses existing stash/reset checks and must be manually inspected on failure"
        }
        "git::push" => {
            "remote pushes are external side effects; force/protected-branch checks limit blast radius"
        }
        "worktree::acquire" => {
            "worktree release is the inverse command and duplicate acquire replays"
        }
        "worktree::release" => "worktree acquire can recreate the assignment if needed",
        "worktree::stage_files" => "worktree.unstageFiles is the inverse command",
        "worktree::unstage_files" => "worktree.stageFiles is the inverse command",
        "worktree::commit" => "git revert/reset is a manual recovery path after commit creation",
        "worktree::merge" => {
            "merge abort or manual conflict recovery is available while merge state exists"
        }
        "worktree::finalize_session" => {
            "finalize uses all-or-none branch publication; manual branch cleanup may be required"
        }
        "worktree::delete_branch" => {
            "deleted local branches require reflog/remote recovery if still available"
        }
        "worktree::prune_branches" => "pruned branches require manual branch restoration if needed",
        "worktree::discard_files" => "discarded working-tree changes are externally irreversible",
        "worktree::rebase_on_main" => {
            "rebase abort/manual reset is the recovery path while state exists"
        }
        "worktree::start_merge" => {
            "worktree.abortMerge is the inverse command while merge is active"
        }
        "worktree::resolve_conflict" => {
            "conflict files can be manually edited before continueMerge"
        }
        "worktree::continue_merge" => "manual reset/revert is required after merge completion",
        "worktree::abort_merge" => {
            "startMerge can recreate the merge attempt if inputs still exist"
        }
        "worktree::resolve_conflicts_with_subagent" => {
            "subagent conflict resolution writes files; manual review/reset remains the recovery path"
        }
        _ => "domain-specific tests preserve current rollback, no-op, or replay behavior",
    }
}

pub(crate) fn domain_workers() -> EngineResult<Vec<WorkerDefinition>> {
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
                actor_id(SYSTEM_OWNER_ACTOR)?,
                grant_id(SYSTEM_AUTHORITY_GRANT)?,
            )
            .with_namespace_claim(domain))
        })
        .collect()
}

pub(crate) fn json_rpc_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("json_rpc")?,
        worker_id("engine")?,
        "JSON-RPC engine transport dispatch into a canonical function",
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

pub(crate) fn manual_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("manual")?,
        worker_id("engine")?,
        "Manual in-process dispatch for tests and future agent tools",
    );
    definition.allowed_delivery_modes = vec![DeliveryMode::Sync];
    definition.visibility = VisibilityScope::Internal;
    Ok(definition)
}

pub(crate) fn cron_schedule_trigger_type() -> EngineResult<TriggerTypeDefinition> {
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

pub(crate) fn json_rpc_trigger_for_spec(
    spec: &CapabilitySpec,
) -> EngineResult<Option<TriggerDefinition>> {
    let mut trigger = TriggerDefinition::new(
        json_rpc_trigger_id_for_method(spec.method)?,
        worker_id("engine")?,
        TriggerTypeId::new("json_rpc")?,
        spec.function_id.clone(),
        grant_id(SYSTEM_AUTHORITY_GRANT)?,
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

pub(crate) fn json_rpc_trigger_id_for_method(method: &str) -> EngineResult<TriggerId> {
    TriggerId::new(format!("json_rpc:{method}"))
}

pub(crate) fn function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    canonical_function_id_for_method(method)
}

pub(crate) fn canonical_function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    FunctionId::new(canonical_capability_for_method(method))
}

fn domain_worker_for_method(method: &str) -> EngineResult<WorkerId> {
    worker_id(match method {
        method if method.starts_with("engine.") => "engine",
        method if method.starts_with("settings::") => "settings",
        method if method.starts_with("logs::") => "logs",
        method if method.starts_with("memory::") => "memory",
        method if method.starts_with("config::") => "config",
        method
            if method.starts_with("prompt_library::history_")
                || method.starts_with("prompt_library::snippet_") =>
        {
            "prompt_library"
        }
        method if method.starts_with("skills::") => "skills",
        method if method.starts_with("filesystem::") || method.starts_with("filesystem::") => {
            "filesystem"
        }
        method if method.starts_with("events::") => "events",
        method if method.starts_with("session::") => "session",
        method if method.starts_with("context::") => "context",
        method if method.starts_with("job::") => "job",
        method if method.starts_with("agent::") => "agent",
        method if method.starts_with("mcp::") => "mcp",
        method if method.starts_with("auth::") => "auth",
        method if method.starts_with("approval.") => "approval",
        method if method.starts_with("notifications::") => "notifications",
        method if method.starts_with("plan::") => "plan",
        method if method.starts_with("tree::") => "tree",
        method if method.starts_with("repo::") => "repo",
        method if method.starts_with("import::") => "import",
        method if method.starts_with("browser::") => "browser",
        method if method.starts_with("display::") => "display",
        method if method.starts_with("device::") => "device",
        method if method.starts_with("voice_notes::") => "voice_notes",
        method if method.starts_with("transcription::") => "transcription",
        method if method.starts_with("sandbox::") => "sandbox",
        method if method.starts_with("cron::") => "cron",
        method if method.starts_with("blob::") => "blob",
        method if method.starts_with("codex_app::") => "codex_app",
        method if method.starts_with("tool::") => "tool",
        method if method.starts_with("message::") => "message",
        method if method.starts_with("git::") => "git",
        method if method.starts_with("worktree::") => "worktree",
        method if method.starts_with("system::") => "system",
        method if method.starts_with("model::") => "model",
        _ => "system",
    })
}

fn canonical_capability_for_method(method: &str) -> String {
    let (namespace, operation) = canonical_parts_for_method(method);
    format!("{namespace}::{operation}")
}

fn canonical_parts_for_method(method: &str) -> (&'static str, String) {
    match method {
        "engine.discover" => ("engine", "discover".to_owned()),
        "engine.inspect" => ("engine", "inspect".to_owned()),
        "engine.watch" => ("engine", "watch".to_owned()),
        "engine.invoke" => ("engine", "invoke".to_owned()),
        "engine.promote" => ("engine", "promote".to_owned()),
        "system::ping" => ("system", "ping".to_owned()),
        "system::get_info" => ("system", "get_info".to_owned()),
        "system::get_diagnostics" => ("system", "get_diagnostics".to_owned()),
        "system::get_update_status" => ("system", "get_update_status".to_owned()),
        "system::shutdown" => ("system", "shutdown".to_owned()),
        "system::check_for_updates" => ("system", "check_for_updates".to_owned()),
        "codex_app::status" => ("codex_app", "status".to_owned()),
        "blob::get" => ("blob", "get".to_owned()),
        "tool::result" => ("tool", "result".to_owned()),
        "message::delete" => ("message", "delete".to_owned()),
        "cron::list" => ("cron", "list".to_owned()),
        "cron::get" => ("cron", "get".to_owned()),
        "cron::create" => ("cron", "create".to_owned()),
        "cron::update" => ("cron", "update".to_owned()),
        "cron::delete" => ("cron", "delete".to_owned()),
        "cron::run" => ("cron", "run".to_owned()),
        "cron::status" => ("cron", "status".to_owned()),
        "cron::get_runs" => ("cron", "get_runs".to_owned()),
        "model::list" => ("model", "list".to_owned()),
        "model::switch" => ("model", "switch".to_owned()),
        "config::set_reasoning_level" => ("config", "set_reasoning_level".to_owned()),
        "settings::get" => ("settings", "get".to_owned()),
        "settings::update" => ("settings", "update".to_owned()),
        "settings::reset_to_defaults" => ("settings", "reset_to_defaults".to_owned()),
        "logs::ingest" => ("logs", "ingest".to_owned()),
        "logs::recent" => ("logs", "recent".to_owned()),
        "memory::retain" => ("memory", "retain".to_owned()),
        "skills::list" => ("skills", "list".to_owned()),
        "skills::get" => ("skills", "get".to_owned()),
        "skills::refresh" => ("skills", "refresh".to_owned()),
        "skills::activate" => ("skills", "activate".to_owned()),
        "skills::deactivate" => ("skills", "deactivate".to_owned()),
        "skills::active" => ("skills", "active".to_owned()),
        "filesystem::list_dir" => ("filesystem", "list_dir".to_owned()),
        "filesystem::get_home" => ("filesystem", "get_home".to_owned()),
        "filesystem::read_file" => ("filesystem", "read_file".to_owned()),
        "filesystem::create_dir" => ("filesystem", "create_dir".to_owned()),
        "events::get_history" => ("events", "get_history".to_owned()),
        "events::get_since" => ("events", "get_since".to_owned()),
        "events::append" => ("events", "append".to_owned()),
        "events::subscribe" => ("events", "subscribe".to_owned()),
        "events::unsubscribe" => ("events", "unsubscribe".to_owned()),
        "session::list" => ("session", "list".to_owned()),
        "session::get_head" => ("session", "get_head".to_owned()),
        "session::get_state" => ("session", "get_state".to_owned()),
        "session::get_history" => ("session", "get_history".to_owned()),
        "session::reconstruct" => ("session", "reconstruct".to_owned()),
        "session::create" => ("session", "create".to_owned()),
        "session::resume" => ("session", "resume".to_owned()),
        "session::delete" => ("session", "delete".to_owned()),
        "session::fork" => ("session", "fork".to_owned()),
        "session::archive" => ("session", "archive".to_owned()),
        "session::unarchive" => ("session", "unarchive".to_owned()),
        "session::archive_older_than" => ("session", "archive_older_than".to_owned()),
        "session::export" => ("session", "export".to_owned()),
        "agent::status" => ("agent", "status".to_owned()),
        "agent::prompt" => ("agent", "prompt".to_owned()),
        "agent::abort" => ("agent", "abort".to_owned()),
        "agent::abort_tool" => ("agent", "abort_tool".to_owned()),
        "agent::queue_prompt" => ("agent", "queue_prompt".to_owned()),
        "agent::dequeue_prompt" => ("agent", "dequeue_prompt".to_owned()),
        "agent::clear_queue" => ("agent", "clear_queue".to_owned()),
        "agent::deliver_subagent_results" => ("agent", "deliver_subagent_results".to_owned()),
        "agent::submit_confirmation" => ("agent", "submit_confirmation".to_owned()),
        "agent::submit_answers" => ("agent", "submit_answers".to_owned()),
        "mcp::status" => ("mcp", "status".to_owned()),
        "mcp::add_server" => ("mcp", "add_server".to_owned()),
        "mcp::remove_server" => ("mcp", "remove_server".to_owned()),
        "mcp::enable_server" => ("mcp", "enable_server".to_owned()),
        "mcp::disable_server" => ("mcp", "disable_server".to_owned()),
        "mcp::restart_server" => ("mcp", "restart_server".to_owned()),
        "mcp::reload" => ("mcp", "reload".to_owned()),
        "mcp::list_tools" => ("mcp", "list_tools".to_owned()),
        "context::get_snapshot" => ("context", "get_snapshot".to_owned()),
        "context::get_detailed_snapshot" => ("context", "get_detailed_snapshot".to_owned()),
        "context::get_audit_trace" => ("context", "get_audit_trace".to_owned()),
        "context::should_compact" => ("context", "should_compact".to_owned()),
        "context::preview_compaction" => ("context", "preview_compaction".to_owned()),
        "context::can_accept_turn" => ("context", "can_accept_turn".to_owned()),
        "context::confirm_compaction" => ("context", "confirm_compaction".to_owned()),
        "context::clear" => ("context", "clear".to_owned()),
        "context::compact" => ("context", "compact".to_owned()),
        "job::background" => ("job", "background".to_owned()),
        "job::cancel" => ("job", "cancel".to_owned()),
        "job::list" => ("job", "list".to_owned()),
        "job::subscribe" => ("job", "subscribe".to_owned()),
        "job::unsubscribe" => ("job", "unsubscribe".to_owned()),
        "approval::get" => ("approval", "get".to_owned()),
        "approval::list" => ("approval", "list".to_owned()),
        "approval::resolve" => ("approval", "resolve".to_owned()),
        "auth::get" => ("auth", "get".to_owned()),
        "auth::update" => ("auth", "update".to_owned()),
        "auth::clear" => ("auth", "clear".to_owned()),
        "auth::oauth_begin" => ("auth", "oauth_begin".to_owned()),
        "auth::oauth_complete" => ("auth", "oauth_complete".to_owned()),
        "auth::rename_account" => ("auth", "rename_account".to_owned()),
        "auth::set_active" => ("auth", "set_active".to_owned()),
        "auth::remove_account" => ("auth", "remove_account".to_owned()),
        "auth::remove_api_key" => ("auth", "remove_api_key".to_owned()),
        "notifications::list" => ("notifications", "list".to_owned()),
        "notifications::mark_read" => ("notifications", "mark_read".to_owned()),
        "notifications::mark_all_read" => ("notifications", "mark_all_read".to_owned()),
        "plan::enter" => ("plan", "enter".to_owned()),
        "plan::exit" => ("plan", "exit".to_owned()),
        "plan::get_state" => ("plan", "get_state".to_owned()),
        "prompt_library::history_list" => ("prompt_library", "history_list".to_owned()),
        "prompt_library::history_delete" => ("prompt_library", "history_delete".to_owned()),
        "prompt_library::history_clear" => ("prompt_library", "history_clear".to_owned()),
        "prompt_library::snippet_list" => ("prompt_library", "snippet_list".to_owned()),
        "prompt_library::snippet_get" => ("prompt_library", "snippet_get".to_owned()),
        "prompt_library::snippet_create" => ("prompt_library", "snippet_create".to_owned()),
        "prompt_library::snippet_update" => ("prompt_library", "snippet_update".to_owned()),
        "prompt_library::snippet_delete" => ("prompt_library", "snippet_delete".to_owned()),
        "tree::get_visualization" => ("tree", "get_visualization".to_owned()),
        "tree::get_branches" => ("tree", "get_branches".to_owned()),
        "tree::get_subtree" => ("tree", "get_subtree".to_owned()),
        "tree::get_ancestors" => ("tree", "get_ancestors".to_owned()),
        "tree::compare_branches" => ("tree", "compare_branches".to_owned()),
        "repo::list_sessions" => ("repo", "list_sessions".to_owned()),
        "repo::get_divergence" => ("repo", "get_divergence".to_owned()),
        "import::list_sources" => ("import", "list_sources".to_owned()),
        "import::list_sessions" => ("import", "list_sessions".to_owned()),
        "import::preview_session" => ("import", "preview_session".to_owned()),
        "import::execute" => ("import", "execute".to_owned()),
        "browser::get_status" => ("browser", "get_status".to_owned()),
        "browser::start_stream" => ("browser", "start_stream".to_owned()),
        "browser::stop_stream" => ("browser", "stop_stream".to_owned()),
        "display::stop_stream" => ("display", "stop_stream".to_owned()),
        "voice_notes::list" => ("voice_notes", "list".to_owned()),
        "voice_notes::save" => ("voice_notes", "save".to_owned()),
        "voice_notes::delete" => ("voice_notes", "delete".to_owned()),
        "transcription::list_models" => ("transcription", "list_models".to_owned()),
        "transcription::audio" => ("transcription", "audio".to_owned()),
        "transcription::download_model" => ("transcription", "download_model".to_owned()),
        "device::register" => ("device", "register".to_owned()),
        "device::unregister" => ("device", "unregister".to_owned()),
        "device::respond" => ("device", "respond".to_owned()),
        "sandbox::list_containers" => ("sandbox", "list_containers".to_owned()),
        "sandbox::start_container" => ("sandbox", "start_container".to_owned()),
        "sandbox::stop_container" => ("sandbox", "stop_container".to_owned()),
        "sandbox::kill_container" => ("sandbox", "kill_container".to_owned()),
        "sandbox::remove_container" => ("sandbox", "remove_container".to_owned()),
        "git::clone" => ("git", "clone".to_owned()),
        "git::sync_main" => ("git", "sync_main".to_owned()),
        "git::push" => ("git", "push".to_owned()),
        "git::list_local_branches" => ("git", "list_local_branches".to_owned()),
        "git::list_remote_branches" => ("git", "list_remote_branches".to_owned()),
        "worktree::get_status" => ("worktree", "get_status".to_owned()),
        "worktree::is_git_repo" => ("worktree", "is_git_repo".to_owned()),
        "worktree::list" => ("worktree", "list".to_owned()),
        "worktree::get_diff" => ("worktree", "get_diff".to_owned()),
        "worktree::get_committed_diff" => ("worktree", "get_committed_diff".to_owned()),
        "worktree::list_session_branches" => ("worktree", "list_session_branches".to_owned()),
        "worktree::acquire" => ("worktree", "acquire".to_owned()),
        "worktree::release" => ("worktree", "release".to_owned()),
        "worktree::stage_files" => ("worktree", "stage_files".to_owned()),
        "worktree::unstage_files" => ("worktree", "unstage_files".to_owned()),
        "worktree::discard_files" => ("worktree", "discard_files".to_owned()),
        "worktree::commit" => ("worktree", "commit".to_owned()),
        "worktree::merge" => ("worktree", "merge".to_owned()),
        "worktree::finalize_session" => ("worktree", "finalize_session".to_owned()),
        "worktree::delete_branch" => ("worktree", "delete_branch".to_owned()),
        "worktree::prune_branches" => ("worktree", "prune_branches".to_owned()),
        "worktree::rebase_on_main" => ("worktree", "rebase_on_main".to_owned()),
        "worktree::start_merge" => ("worktree", "start_merge".to_owned()),
        "worktree::list_conflicts" => ("worktree", "list_conflicts".to_owned()),
        "worktree::resolve_conflict" => ("worktree", "resolve_conflict".to_owned()),
        "worktree::continue_merge" => ("worktree", "continue_merge".to_owned()),
        "worktree::abort_merge" => ("worktree", "abort_merge".to_owned()),
        "worktree::resolve_conflicts_with_subagent" => {
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
                    "engine" => "engine",
                    _ => "system",
                };
                (namespace, operation.to_owned())
            }
            None => ("system", method.to_owned()),
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
        (Some("engine"), "read") => "engine.read",
        (Some("engine"), "write") => "engine.promote.workspace",
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
        (Some("approval"), "write") => "approval::resolve",
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
        (_, "write") => "system.write",
        _ => "system.read",
    }
}

pub(crate) fn worker_id(value: &str) -> EngineResult<WorkerId> {
    WorkerId::new(value)
}

pub(crate) fn actor_id(value: &str) -> EngineResult<ActorId> {
    ActorId::new(value)
}

pub(crate) fn grant_id(value: &str) -> EngineResult<AuthorityGrantId> {
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
            "engine" => "engine",
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
