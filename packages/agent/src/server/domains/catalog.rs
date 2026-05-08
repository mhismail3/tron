//! Aggregated canonical capability catalog.
//!
//! Domain workers own their canonical function inventories in local `spec.rs`
//! modules. This file assembles those inventories into the engine registration,
//! discovery, diagnostics, and guardrail views, while contract-specific metadata
//! lives in `catalog::contracts`.

use std::collections::BTreeSet;

use serde_json::json;

use super::schemas::{request_schema_for_method, response_schema_for_method};
use crate::engine::{
    ActorId, AuthorityGrantId, DeliveryMode, EffectClass, EngineError, FunctionId,
    IdempotencyKeySource, Result as EngineResult, RiskLevel, TriggerDefinition, TriggerId,
    TriggerTypeDefinition, TriggerTypeId, VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
};

mod contracts;

pub(crate) use contracts::function_definition_for_capability;
use contracts::{
    effect_class_for_method, high_risk_contract_for_method, idempotency_mode_for_method,
    requires_resource_lease_metadata, risk_for_method,
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
    /// Public transport idempotency mode when this function is exposed through
    /// an engine protocol message.
    pub idempotency_mode: TransportIdempotencyMode,
    /// Domain module/group provenance.
    pub domain_module: &'static str,
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

/// Domain worker ownership view used by registration, diagnostics, and guards.
#[derive(Clone, Debug, PartialEq)]
pub struct DomainWorkerModule {
    /// Worker definition registered with the engine.
    pub worker: WorkerDefinition,
    /// Claimed namespace owned by the worker.
    pub namespace: String,
    /// Canonical functions owned by the worker.
    pub functions: Vec<CanonicalCapabilitySpec>,
}

const PUBLIC_ENGINE_TRANSPORT_METHODS: &[&str] =
    &["discover", "inspect", "watch", "invoke", "promote"];

const ENGINE_META_CAPABILITY_METHODS: &[&str] = &[
    "engine::discover",
    "engine::inspect",
    "engine::watch",
    "engine::invoke",
    "engine::promote",
];

const ENGINE_PRIMITIVE_CAPABILITY_METHODS: &[&str] =
    &["approval::get", "approval::list", "approval::resolve"];

fn canonical_capability_methods() -> Vec<&'static str> {
    let groups: &[&[&str]] = &[
        ENGINE_META_CAPABILITY_METHODS,
        ENGINE_PRIMITIVE_CAPABILITY_METHODS,
        super::agent::spec::FUNCTIONS,
        super::auth::spec::FUNCTIONS,
        super::blob::spec::FUNCTIONS,
        super::browser::spec::FUNCTIONS,
        super::codex_app::spec::FUNCTIONS,
        super::context::spec::FUNCTIONS,
        super::cron::spec::FUNCTIONS,
        super::device::spec::FUNCTIONS,
        super::display::spec::FUNCTIONS,
        super::events::spec::FUNCTIONS,
        super::filesystem::spec::FUNCTIONS,
        super::git::spec::FUNCTIONS,
        super::import::spec::FUNCTIONS,
        super::job::spec::FUNCTIONS,
        super::logs::spec::FUNCTIONS,
        super::mcp::spec::FUNCTIONS,
        super::memory::spec::FUNCTIONS,
        super::message::spec::FUNCTIONS,
        super::model::spec::FUNCTIONS,
        super::notifications::spec::FUNCTIONS,
        super::plan::spec::FUNCTIONS,
        super::prompt_library::spec::FUNCTIONS,
        super::repo::spec::FUNCTIONS,
        super::sandbox::spec::FUNCTIONS,
        super::session::spec::FUNCTIONS,
        super::settings::spec::FUNCTIONS,
        super::skills::spec::FUNCTIONS,
        super::system::spec::FUNCTIONS,
        super::tools::spec::FUNCTIONS,
        super::transcription::spec::FUNCTIONS,
        super::tree::spec::FUNCTIONS,
        super::voice_notes::spec::FUNCTIONS,
        super::worktree::spec::FUNCTIONS,
    ];
    groups
        .iter()
        .flat_map(|group| group.iter().copied())
        .collect()
}

/// Public `/engine` client protocol meta-methods.
pub fn public_engine_transport_methods() -> impl Iterator<Item = &'static str> {
    PUBLIC_ENGINE_TRANSPORT_METHODS.iter().copied()
}

/// Build canonical capability specs from the complete domain capability catalog.
pub fn canonical_capability_specs() -> EngineResult<Vec<CanonicalCapabilitySpec>> {
    validate_seed_uniqueness()?;
    canonical_capability_methods()
        .into_iter()
        .map(|method| {
            let spec = spec_from_method(method)?;
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

/// Build and validate the public `/engine` client protocol method set.
pub fn public_engine_transport_specs() -> EngineResult<Vec<CapabilitySpec>> {
    let mut specs = Vec::with_capacity(PUBLIC_ENGINE_TRANSPORT_METHODS.len());
    for method in PUBLIC_ENGINE_TRANSPORT_METHODS {
        let spec = spec_from_method(method)?;
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

pub(crate) fn public_engine_transport_spec_for_method(
    method: &str,
) -> EngineResult<Option<CapabilitySpec>> {
    let Some(method) = PUBLIC_ENGINE_TRANSPORT_METHODS
        .iter()
        .find(|candidate| **candidate == method)
        .copied()
    else {
        return Ok(None);
    };
    spec_from_method(method).map(Some)
}

/// Group canonical functions by their owning domain worker.
pub(crate) fn domain_worker_modules() -> EngineResult<Vec<DomainWorkerModule>> {
    let specs = canonical_capability_specs()?;
    domain_workers()?
        .into_iter()
        .map(|worker| {
            let namespace = worker
                .namespace_claims
                .first()
                .cloned()
                .unwrap_or_else(|| worker.id.as_str().to_owned());
            let functions = specs
                .iter()
                .filter(|spec| spec.owner_worker == worker.id)
                .cloned()
                .collect();
            Ok(DomainWorkerModule {
                worker,
                namespace,
                functions,
            })
        })
        .collect()
}

pub(crate) fn capability_spec_for_method(method: &str) -> EngineResult<CapabilitySpec> {
    let Some(canonical_method) = canonical_capability_methods()
        .into_iter()
        .find(|candidate| *candidate == method)
    else {
        return Err(EngineError::PolicyViolation(format!(
            "canonical capability operation {method} is not registered"
        )));
    };
    spec_from_method(canonical_method)
}

fn validate_seed_uniqueness() -> EngineResult<()> {
    let mut seen = BTreeSet::new();
    for method in canonical_capability_methods() {
        if !seen.insert(method) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate canonical capability spec for {}",
                method
            )));
        }
    }
    Ok(())
}

fn spec_from_method(method: &'static str) -> EngineResult<CapabilitySpec> {
    let effect_class = effect_class_for_method(method);
    let visibility = VisibilityScope::System;
    let owner_worker = domain_worker_for_method(method)?;
    Ok(CapabilitySpec {
        method,
        function_id: function_id_for_method(method)?,
        owner_worker: owner_worker.clone(),
        domain_worker: domain_worker_for_method(method)?,
        effect_class,
        risk_level: risk_for_method(method, effect_class),
        visibility,
        authority_scope: Some(domain_authority_scope_for_method(method, effect_class)),
        idempotency_mode: idempotency_mode_for_method(method, effect_class),
        domain_module: domain_module_for_method(method),
    })
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

pub(crate) fn engine_ws_trigger_type() -> EngineResult<TriggerTypeDefinition> {
    let mut definition = TriggerTypeDefinition::new(
        TriggerTypeId::new("engine_ws")?,
        worker_id("engine")?,
        "Engine WebSocket transport dispatch into a canonical function",
    );
    definition.allowed_delivery_modes = vec![DeliveryMode::Sync];
    definition.visibility = VisibilityScope::Internal;
    definition.config_schema = Some(json!({
        "type": "object",
        "required": ["messageType"],
        "additionalProperties": false,
        "properties": {
            "messageType": {"type": "string"}
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

pub(crate) fn engine_ws_trigger_for_spec(
    spec: &CapabilitySpec,
) -> EngineResult<Option<TriggerDefinition>> {
    let mut trigger = TriggerDefinition::new(
        engine_ws_trigger_id_for_method(spec.method)?,
        worker_id("engine")?,
        TriggerTypeId::new("engine_ws")?,
        spec.function_id.clone(),
        grant_id(SYSTEM_AUTHORITY_GRANT)?,
    )
    .with_delivery_mode(DeliveryMode::Sync);
    trigger.config = json!({ "messageType": spec.method });
    trigger.idempotency_key_strategy = if spec.effect_class.is_mutating() {
        Some(IdempotencyKeySource::TriggerDerived)
    } else {
        None
    };
    trigger.visibility = VisibilityScope::Internal;
    Ok(Some(trigger))
}

pub(crate) fn engine_ws_trigger_id_for_method(method: &str) -> EngineResult<TriggerId> {
    TriggerId::new(format!("engine_ws:{method}"))
}

pub(crate) fn function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    canonical_function_id_for_method(method)
}

pub(crate) fn canonical_function_id_for_method(method: &str) -> EngineResult<FunctionId> {
    FunctionId::new(canonical_capability_for_method(method))
}

fn domain_worker_for_method(method: &str) -> EngineResult<WorkerId> {
    worker_id(match method {
        method
            if matches!(
                method,
                "discover" | "inspect" | "watch" | "invoke" | "promote"
            ) || method.starts_with("engine::") =>
        {
            "engine"
        }
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
        method if method.starts_with("approval::") => "approval",
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
        "discover" | "engine::discover" => ("engine", "discover".to_owned()),
        "inspect" | "engine::inspect" => ("engine", "inspect".to_owned()),
        "watch" | "engine::watch" => ("engine", "watch".to_owned()),
        "invoke" | "engine::invoke" => ("engine", "invoke".to_owned()),
        "promote" | "engine::promote" => ("engine", "promote".to_owned()),
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

fn domain_module_for_method(method: &str) -> &'static str {
    match method {
        "git::sync_main"
        | "git::push"
        | "git::list_local_branches"
        | "git::list_remote_branches"
        | "worktree::finalize_session"
        | "worktree::rebase_on_main"
        | "worktree::start_merge"
        | "worktree::list_conflicts"
        | "worktree::resolve_conflict"
        | "worktree::continue_merge"
        | "worktree::abort_merge"
        | "worktree::resolve_conflicts_with_subagent" => return "worktree::git_workflow",
        "git::clone" => return "git",
        _ => {}
    }
    let prefix = method
        .split_once("::")
        .map(|(prefix, _)| prefix)
        .unwrap_or_else(|| method.split('.').next().unwrap_or(method));
    match prefix {
        "codexApp" => "codex_app",
        "codex_app" => "codex_app",
        "config" => "model",
        "file" | "filesystem" => "filesystem",
        "repo" => "repo",
        "transcribe" | "transcription" => "transcription",
        "voiceNotes" | "voice_notes" => "voice_notes",
        "promptHistory" | "promptSnippet" | "prompt_library" => "prompt_library",
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
            "git" => "git",
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
            "tool" => "tools",
            "tree" => "tree",
            "worktree" => "worktree",
            _ => "unknown",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_worker_modules_own_all_canonical_functions_once() {
        let specs = canonical_capability_specs().expect("canonical specs");
        let modules = domain_worker_modules().expect("domain modules");
        let module_worker_ids: std::collections::BTreeSet<_> = modules
            .iter()
            .map(|module| module.worker.id.clone())
            .collect();
        let domain_owned_specs = specs
            .iter()
            .filter(|spec| module_worker_ids.contains(&spec.owner_worker))
            .count();
        let owned: usize = modules.iter().map(|module| module.functions.len()).sum();
        assert_eq!(
            owned, domain_owned_specs,
            "domain worker modules must account for every server-owned canonical function"
        );
        for module in modules {
            assert!(
                module.worker.namespace_claims.contains(&module.namespace),
                "worker {} must claim namespace {}",
                module.worker.id.as_str(),
                module.namespace
            );
            for function in module.functions {
                assert_eq!(
                    function.owner_worker,
                    module.worker.id,
                    "function {} must be owned by its domain worker",
                    function.function_id.as_str()
                );
            }
        }
    }
}
