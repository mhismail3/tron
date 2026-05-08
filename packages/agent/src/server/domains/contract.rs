//! Shared capability-contract builders used by domain-owned contract modules.
//!
//! Domain `contract.rs` files own which canonical functions belong to each
//! worker. This module keeps the mechanics for turning those local domain
//! contracts into engine definitions so the catalog can aggregate without
//! owning domain policy.

use serde_json::{Value, json};

use super::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::engine::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, FunctionDefinition,
    IdempotencyContract, Provenance, ResourceLeaseRequirement, RiskLevel,
};

pub(super) fn idempotency_mode_for_method(
    method: &str,
    effect_class: EffectClass,
) -> TransportIdempotencyMode {
    if matches!(method, "promote" | "engine::promote") {
        TransportIdempotencyMode::ExplicitRequired
    } else {
        let _ = effect_class;
        TransportIdempotencyMode::NotRequired
    }
}

fn is_pure_read_method(method: &str) -> bool {
    matches!(
        method,
        "discover"
            | "inspect"
            | "watch"
            | "engine::discover"
            | "engine::inspect"
            | "engine::watch"
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

pub(super) fn effect_class_for_method(method: &str) -> EffectClass {
    if matches!(method, "invoke" | "engine::invoke") {
        return EffectClass::DelegatedInvocation;
    }
    if matches!(method, "promote" | "engine::promote") {
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

pub(super) fn risk_for_method(method: &str, effect: EffectClass) -> RiskLevel {
    if matches!(method, "git::push" | "system::shutdown") {
        RiskLevel::Critical
    } else if matches!(method, "promote" | "engine::promote") {
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
        "domainModule": spec.domain_module,
        "highRiskContract": high_risk_contract_for_method(spec.method),
    });
    definition
}

fn idempotency_contract_for_method(method: &str) -> IdempotencyContract {
    if matches!(method, "promote" | "engine::promote") {
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
        "promote"
            | "engine::promote"
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

pub(super) fn requires_resource_lease_metadata(method: &str) -> bool {
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

pub(super) fn high_risk_contract_for_method(method: &str) -> Option<serde_json::Value> {
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

fn session_scoped_schema() -> Value {
    json!({
        "type": "object",
        "required": ["sessionId"],
        "additionalProperties": false,
        "properties": {
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

pub(crate) fn request_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "discover" | "engine::discover" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "visibility": {"type": "string"},
                "namespacePrefix": {"type": "string"},
                "text": {"type": "string"},
                "effectClass": {"type": "string"},
                "maxRisk": {"type": "string"},
                "health": {"type": "string"},
                "includeInternal": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "inspect" | "engine::inspect" => json!({
            "type": "object",
            "required": ["kind", "id"],
            "additionalProperties": false,
            "properties": {
                "kind": {"type": "string", "enum": ["function", "worker", "trigger_type", "trigger"]},
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "watch" | "engine::watch" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "afterRevision": {"type": "integer"},
                "limit": {"type": "integer"},
                "classes": {"type": "array", "items": {"type": "string"}},
                "kinds": {"type": "array", "items": {"type": "string"}},
                "subjectPrefix": {"type": "string"},
                "ownerWorker": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "invoke" | "engine::invoke" => json!({
            "type": "object",
            "required": ["functionId"],
            "additionalProperties": false,
            "properties": {
                "functionId": {"type": "string"},
                "payload": {},
                "expectedFunctionRevision": {"type": "integer"},
                "deliveryMode": {"type": "string", "enum": ["sync"]},
                "idempotencyKey": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promote" | "engine::promote" => json!({
            "type": "object",
            "required": [
                "functionId",
                "targetVisibility",
                "expectedFunctionRevision",
                "idempotencyKey"
            ],
            "additionalProperties": false,
            "properties": {
                "functionId": {"type": "string"},
                "ownerWorker": {"type": "string"},
                "targetVisibility": {"type": "string", "enum": ["workspace", "system"]},
                "expectedFunctionRevision": {"type": "integer"},
                "workspaceId": {"type": "string"},
                "idempotencyKey": {"type": "string"}
            }
        }),
        "system::ping" => json!({
            "type": "object",
            "required": ["protocolVersion"],
            "additionalProperties": false,
            "properties": {
                "protocolVersion": {"type": "integer"},
                "clientVersion": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "logs::recent" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "logs::ingest" => json!({
            "type": "object",
            "required": ["entries"],
            "additionalProperties": false,
            "properties": {
                "entries": {
                    "type": "array",
                    "maxItems": 10_000,
                    "items": {
                        "type": "object",
                        "required": ["timestamp", "level", "category", "message"],
                        "additionalProperties": false,
                        "properties": {
                            "timestamp": {"type": "string"},
                            "level": {"type": "string"},
                            "category": {"type": "string"},
                            "message": {"type": "string"}
                        }
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "system::get_diagnostics"
        | "system::get_update_status"
        | "system::check_for_updates"
        | "system::shutdown"
        | "codex_app::status"
        | "cron::status"
        | "transcription::download_model" => {
            json!({
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "sessionId": {"type": "string"},
                    "workspaceId": {"type": "string"}
                }
            })
        }
        "auth::get" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::update" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "service": {"type": "string"},
                "apiKey": {"type": ["string", "null"]},
                "apiKeyLabel": {"type": "string"},
                "oauth": {"type": ["object", "null"], "additionalProperties": true},
                "clientId": {"type": ["string", "null"]},
                "clientSecret": {"type": ["string", "null"]},
                "projectId": {"type": ["string", "null"]},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::clear" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "service": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::oauth_begin" => json!({
            "type": "object",
            "required": ["provider"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::oauth_complete" => json!({
            "type": "object",
            "required": ["flowId", "code", "label"],
            "additionalProperties": false,
            "properties": {
                "flowId": {"type": "string"},
                "code": {"type": "string"},
                "label": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::rename_account" => json!({
            "type": "object",
            "required": ["provider", "oldLabel", "newLabel"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "oldLabel": {"type": "string"},
                "newLabel": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::set_active" => json!({
            "type": "object",
            "required": ["provider", "credential"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "credential": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "auth::remove_account" | "auth::remove_api_key" => json!({
            "type": "object",
            "required": ["provider", "label"],
            "additionalProperties": false,
            "properties": {
                "provider": {"type": "string"},
                "label": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "browser::start_stream" | "browser::stop_stream" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "display::stop_stream" => json!({
            "type": "object",
            "required": ["streamId"],
            "additionalProperties": false,
            "properties": {
                "streamId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "device::register" => json!({
            "type": "object",
            "required": ["deviceToken", "bundleId"],
            "additionalProperties": false,
            "properties": {
                "deviceToken": {"type": "string"},
                "bundleId": {"type": "string"},
                "environment": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "device::unregister" => json!({
            "type": "object",
            "required": ["deviceToken"],
            "additionalProperties": false,
            "properties": {
                "deviceToken": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "device::respond" => json!({
            "type": "object",
            "required": ["requestId"],
            "additionalProperties": false,
            "properties": {
                "requestId": {"type": "string"},
                "result": {},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "transcription::audio" => json!({
            "type": "object",
            "required": ["audioBase64"],
            "additionalProperties": false,
            "properties": {
                "audioBase64": {"type": "string"},
                "mimeType": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "voice_notes::save" => json!({
            "type": "object",
            "required": ["audioBase64"],
            "additionalProperties": false,
            "properties": {
                "audioBase64": {"type": "string"},
                "mimeType": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "voice_notes::delete" => json!({
            "type": "object",
            "required": ["filename"],
            "additionalProperties": false,
            "properties": {
                "filename": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "sandbox::start_container"
        | "sandbox::stop_container"
        | "sandbox::kill_container"
        | "sandbox::remove_container" => json!({
            "type": "object",
            "required": ["name"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "blob::get" => json!({
            "type": "object",
            "required": ["blobId"],
            "additionalProperties": false,
            "properties": {
                "blobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tool::result" => json!({
            "type": "object",
            "required": ["sessionId", "toolUseId", "result"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "toolUseId": {"type": "string"},
                "result": {},
                "workspaceId": {"type": "string"}
            }
        }),
        "message::delete" => json!({
            "type": "object",
            "required": ["sessionId", "targetEventId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "targetEventId": {"type": "string"},
                "reason": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "enabled": {"type": "boolean"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "workspaceId": {"type": "string"},
                "sessionId": {"type": "string"}
            }
        }),
        "cron::get" | "cron::delete" | "cron::run" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron::get_runs" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "status": {"type": "string"},
                "limit": {"type": "integer"},
                "offset": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron::create" => json!({
            "type": "object",
            "required": ["job"],
            "additionalProperties": false,
            "properties": {
                "job": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "cron::update" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "name": {"type": "string"},
                "description": {"type": ["string", "null"]},
                "enabled": {"type": "boolean"},
                "schedule": {"type": "object", "additionalProperties": true},
                "payload": {"type": "object", "additionalProperties": true},
                "delivery": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "overlapPolicy": {"type": "string"},
                "misfirePolicy": {"type": "string"},
                "maxRetries": {"type": "integer"},
                "autoDisableAfter": {"type": "integer"},
                "stuckTimeoutSecs": {"type": "integer"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "toolRestrictions": {"type": ["object", "null"], "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": ["string", "null"]}
            }
        }),
        "skills::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skills::get" => json!({
            "type": "object",
            "required": ["name"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skills::refresh" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skills::activate" | "skills::deactivate" => json!({
            "type": "object",
            "required": ["sessionId", "skillName"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "skillName": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skills::active" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events::get_history" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "types": {"type": "array", "items": {"type": "string"}},
                "beforeEventId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events::get_since" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "afterEventId": {"type": "string"},
                "afterSequence": {"type": "integer"},
                "limit": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events::append" => json!({
            "type": "object",
            "required": ["sessionId", "type", "payload"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "type": {"type": "string"},
                "payload": {},
                "parentId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events::subscribe" | "events::unsubscribe" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem::list_dir" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "showHidden": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem::read_file" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem::get_home" | "prompt_library::snippet_list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem::create_dir" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree::get_visualization" | "tree::get_branches" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree::get_subtree" | "tree::get_ancestors" => json!({
            "type": "object",
            "required": ["eventId"],
            "additionalProperties": false,
            "properties": {
                "eventId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "tree::compare_branches" => json!({
            "type": "object",
            "required": ["branchA", "branchB"],
            "additionalProperties": false,
            "properties": {
                "branchA": {"type": "string"},
                "branchB": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "repo::list_sessions" | "repo::get_divergence" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import::list_sources"
        | "browser::get_status"
        | "transcription::list_models"
        | "sandbox::list_containers" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import::list_sessions" => json!({
            "type": "object",
            "required": ["encodedDir"],
            "additionalProperties": false,
            "properties": {
                "encodedDir": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import::preview_session" => json!({
            "type": "object",
            "required": ["sessionPath"],
            "additionalProperties": false,
            "properties": {
                "sessionPath": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "import::execute" => json!({
            "type": "object",
            "required": ["sessionPath"],
            "additionalProperties": false,
            "properties": {
                "sessionPath": {"type": "string"},
                "workingDirectory": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "voice_notes::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "offset": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "includeArchived": {"type": "boolean"},
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::create" => json!({
            "type": "object",
            "required": ["workingDirectory"],
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "model": {"type": "string"},
                "title": {"type": "string"},
                "source": {"type": "string"},
                "profile": {"type": "string"},
                "useWorktree": {"type": "boolean"},
                "__capabilityContext": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "transportId": {"type": "string"}
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::resume" | "session::delete" | "session::archive" | "session::unarchive"
        | "session::export" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::fork" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "fromEventId": {"type": "string"},
                "title": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::archive_older_than" => json!({
            "type": "object",
            "required": ["days"],
            "additionalProperties": false,
            "properties": {
                "days": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::get_head" | "session::get_state" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::reconstruct" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "beforeSequence": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "session::get_history" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "beforeId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context::get_snapshot"
        | "context::get_detailed_snapshot"
        | "context::should_compact"
        | "context::preview_compaction"
        | "context::can_accept_turn" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context::get_audit_trace" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "turn": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context::confirm_compaction" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "editedSummary": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "context::clear" | "context::compact" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::prompt" => json!({
            "type": "object",
            "required": ["sessionId", "prompt"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "prompt": {"type": "string"},
                "reasoningLevel": {"type": "string"},
                "images": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                },
                "attachments": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                },
                "source": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::queue_prompt" => json!({
            "type": "object",
            "required": ["sessionId", "prompt"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "prompt": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::dequeue_prompt" => json!({
            "type": "object",
            "required": ["sessionId", "queueId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "queueId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::clear_queue" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::status" | "agent::abort" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::abort_tool" => json!({
            "type": "object",
            "required": ["sessionId", "toolCallId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "toolCallId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::deliver_subagent_results" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::submit_confirmation" => json!({
            "type": "object",
            "required": ["sessionId", "action", "decision"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "action": {"type": "string"},
                "decision": {"type": "string"},
                "note": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "agent::submit_answers" => json!({
            "type": "object",
            "required": ["sessionId", "questions"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "questions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["question"],
                        "additionalProperties": false,
                        "properties": {
                            "question": {"type": "string"},
                            "selectedValues": {"type": "array", "items": {"type": "string"}},
                            "otherValue": {"type": "string"}
                        }
                    }
                },
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp::status" | "mcp::reload" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp::list_tools" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "server": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp::add_server" => json!({
            "type": "object",
            "required": ["name"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "command": {"type": "string"},
                "args": {"type": "array", "items": {"type": "string"}},
                "env": {"type": "object", "additionalProperties": true},
                "url": {"type": "string"},
                "enabled": {"type": "boolean"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "mcp::remove_server"
        | "mcp::enable_server"
        | "mcp::disable_server"
        | "mcp::restart_server" => {
            json!({
                "type": "object",
                "required": ["name"],
                "additionalProperties": false,
                "properties": {
                    "name": {"type": "string"},
                    "sessionId": {"type": "string"},
                    "workspaceId": {"type": "string"}
                }
            })
        }
        "job::list" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job::background" | "job::cancel" => json!({
            "type": "object",
            "required": ["jobId", "sessionId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job::subscribe" => json!({
            "type": "object",
            "required": ["jobId", "sessionId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "job::unsubscribe" => json!({
            "type": "object",
            "required": ["jobId"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications::mark_read" => json!({
            "type": "object",
            "required": ["eventId"],
            "additionalProperties": false,
            "properties": {
                "eventId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "notifications::mark_all_read" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "plan::enter" | "plan::exit" | "plan::get_state" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "settings::get" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {}
        }),
        "settings::update" => json!({
            "type": "object",
            "required": ["settings"],
            "additionalProperties": false,
            "properties": {
                "settings": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "settings::reset_to_defaults" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "approval::get" => json!({
            "type": "object",
            "required": ["approvalId"],
            "additionalProperties": false,
            "properties": {
                "approvalId": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "approval::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "status": {"type": "string"},
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "approval::resolve" => json!({
            "type": "object",
            "required": ["approvalId", "decision"],
            "additionalProperties": false,
            "properties": {
                "approvalId": {"type": "string"},
                "decision": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "model::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "__capabilityContext": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "authPath": {"type": "string"}
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "model::switch" => json!({
            "type": "object",
            "required": ["sessionId", "model"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "model": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "config::set_reasoning_level" => json!({
            "type": "object",
            "required": ["sessionId", "level"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "level": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "memory::retain" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::history_list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "cursor": {"type": "string"},
                "query": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::history_delete" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::history_clear" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::snippet_get" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::snippet_create" => json!({
            "type": "object",
            "required": ["name", "text"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "text": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::snippet_update" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "name": {"type": "string"},
                "text": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "prompt_library::snippet_delete" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "system::get_info" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "__capabilityContext": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "onboardedMarkerPath": {"type": "string"}
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "git::clone" => json!({
            "type": "object",
            "required": ["url", "targetPath"],
            "additionalProperties": false,
            "properties": {
                "url": {"type": "string"},
                "targetPath": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "git::sync_main" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "targetBranch": {"type": "string"},
                "remote": {"type": "string"},
                "fetchTimeoutMs": {"type": "integer"},
                "prune": {"type": "boolean"},
                "dryRun": {"type": "boolean"},
                "workspaceId": {"type": "string"}
            }
        }),
        "git::push" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "branch": {"type": "string"},
                "remote": {"type": "string"},
                "forceWithLease": {"type": "boolean"},
                "setUpstream": {"type": "boolean"},
                "dryRun": {"type": "boolean"},
                "overrideProtected": {"type": "boolean"},
                "protectedBranches": {"type": "array", "items": {"type": "string"}},
                "workspaceId": {"type": "string"}
            }
        }),
        "git::list_local_branches" => session_scoped_schema(),
        "git::list_remote_branches" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "remote": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::get_status"
        | "worktree::list_session_branches"
        | "worktree::get_committed_diff"
        | "worktree::acquire"
        | "worktree::release"
        | "worktree::prune_branches"
        | "worktree::list_conflicts"
        | "worktree::continue_merge" => session_scoped_schema(),
        "worktree::is_git_repo" => json!({
            "type": "object",
            "required": ["path"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::get_diff" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "file": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::commit" => json!({
            "type": "object",
            "required": ["sessionId", "message", "stageAll"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "message": {"type": "string"},
                "stageAll": {"type": "boolean"},
                "amend": {"type": "boolean"},
                "signoff": {"type": "boolean"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::merge" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "targetBranch": {"type": "string"},
                "strategy": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::finalize_session" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "sourceBranch": {"type": "string"},
                "targetBranch": {"type": "string"},
                "strategy": {"type": "string"},
                "newBranchName": {"type": "string"},
                "preserveOld": {"type": "boolean"},
                "rebranch": {"type": "boolean"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::delete_branch" => json!({
            "type": "object",
            "required": ["sessionId", "branch"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "branch": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::stage_files" | "worktree::unstage_files" | "worktree::discard_files" => json!({
            "type": "object",
            "required": ["sessionId", "paths"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "paths": {"type": "array", "items": {"type": "string"}},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::rebase_on_main" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "strategy": {"type": "string"},
                "mainBranch": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::start_merge" => json!({
            "type": "object",
            "required": ["sessionId", "sourceBranch", "targetBranch"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "sourceBranch": {"type": "string"},
                "targetBranch": {"type": "string"},
                "strategy": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::resolve_conflict" => json!({
            "type": "object",
            "required": ["sessionId", "path", "resolution"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "path": {"type": "string"},
                "resolution": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::abort_merge" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "reason": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "worktree::resolve_conflicts_with_subagent" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        _ => return None,
    })
}

pub(crate) fn response_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "discover" | "engine::discover" => json!({
            "type": "object",
            "required": ["catalogRevision", "functions"],
            "additionalProperties": false,
            "properties": {
                "catalogRevision": {"type": "integer"},
                "functions": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "inspect" | "engine::inspect" => json!({
            "type": "object",
            "required": ["catalogRevision", "kind", "definition"],
            "additionalProperties": false,
            "properties": {
                "catalogRevision": {"type": "integer"},
                "kind": {"type": "string"},
                "definition": {"type": "object", "additionalProperties": true}
            }
        }),
        "watch" | "engine::watch" => json!({
            "type": "object",
            "required": ["changes", "currentRevision", "hasMore"],
            "additionalProperties": false,
            "properties": {
                "changes": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "currentRevision": {"type": "integer"},
                "hasMore": {"type": "boolean"}
            }
        }),
        "invoke" | "engine::invoke" => json!({
            "type": "object",
            "required": ["catalogRevision", "child"],
            "additionalProperties": false,
            "properties": {
                "catalogRevision": {"type": "integer"},
                "child": {"type": "object", "additionalProperties": true}
            }
        }),
        "promote" | "engine::promote" => json!({
            "type": "object",
            "required": ["functionId", "revision", "visibility"],
            "additionalProperties": false,
            "properties": {
                "functionId": {"type": "string"},
                "revision": {"type": "integer"},
                "visibility": {"type": "string"}
            }
        }),
        "system::ping" => json!({
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
        "system::get_info" => json!({
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
        "settings::get" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "settings::update" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "settings::reset_to_defaults" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "approval::get" => json!({
            "type": "object",
            "required": ["approval"],
            "additionalProperties": false,
            "properties": {"approval": {}}
        }),
        "approval::list" => json!({
            "type": "object",
            "required": ["approvals"],
            "additionalProperties": false,
            "properties": {"approvals": {"type": "array"}}
        }),
        "approval::resolve" => json!({
            "type": "object",
            "required": ["approval", "child"],
            "additionalProperties": false,
            "properties": {
                "approval": {"type": "object"},
                "child": {}
            }
        }),
        "model::list" => json!({
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
        "model::switch" => json!({
            "type": "object",
            "required": ["previousModel", "newModel"],
            "additionalProperties": false,
            "properties": {
                "previousModel": {"type": "string"},
                "newModel": {"type": "string"}
            }
        }),
        "config::set_reasoning_level" => json!({
            "type": "object",
            "required": ["previousLevel", "newLevel", "changed"],
            "additionalProperties": false,
            "properties": {
                "previousLevel": {"type": ["string", "null"]},
                "newLevel": {"type": "string"},
                "changed": {"type": "boolean"}
            }
        }),
        "memory::retain" => json!({
            "type": "object",
            "required": ["retained"],
            "additionalProperties": false,
            "properties": {
                "retained": {"type": "boolean"},
                "status": {"type": "string"},
                "reason": {"type": "string"}
            }
        }),
        "import::execute" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workingDirectory": {"type": "string"},
                "model": {"type": "string"},
                "eventCount": {"type": "integer"},
                "turnCount": {"type": "integer"},
                "messageCount": {"type": "integer"},
                "cost": {"type": "number"},
                "warnings": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "alreadyImported": {"type": "boolean"},
                "existingSessionId": {"type": "string"}
            }
        }),
        "skills::list" => json!({
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
        "skills::get" => json!({
            "type": "object",
            "required": ["skill", "found"],
            "additionalProperties": false,
            "properties": {
                "skill": {"type": "object", "additionalProperties": true},
                "found": {"type": "boolean"}
            }
        }),
        "skills::refresh" => json!({
            "type": "object",
            "required": ["success", "skillCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "skillCount": {"type": "integer"}
            }
        }),
        "skills::activate" => json!({
            "type": "object",
            "required": ["success", "skill"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "alreadyActive": {"type": "boolean"},
                "skill": {"type": "object", "additionalProperties": true}
            }
        }),
        "skills::deactivate" => json!({
            "type": "object",
            "required": ["success", "wasActive", "deactivatedSkill"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "wasActive": {"type": "boolean"},
                "deactivatedSkill": {"type": "string"}
            }
        }),
        "skills::active" => json!({
            "type": "object",
            "required": ["skills"],
            "additionalProperties": false,
            "properties": {
                "skills": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "logs::recent" => json!({
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
        "logs::ingest" => json!({
            "type": "object",
            "required": ["success", "inserted"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "inserted": {"type": "integer"}
            }
        }),
        "system::get_diagnostics"
        | "system::get_update_status"
        | "system::check_for_updates"
        | "codex_app::status"
        | "cron::list"
        | "cron::get"
        | "cron::create"
        | "cron::update"
        | "cron::status"
        | "cron::get_runs" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "system::shutdown" => json!({
            "type": "object",
            "required": ["acknowledged"],
            "additionalProperties": false,
            "properties": {
                "acknowledged": {"type": "boolean"}
            }
        }),
        "auth::get"
        | "auth::update"
        | "auth::clear"
        | "auth::oauth_complete"
        | "auth::rename_account"
        | "auth::set_active"
        | "auth::remove_account"
        | "auth::remove_api_key" => json!({
            "type": "object",
            "required": ["providers", "services"],
            "additionalProperties": false,
            "properties": {
                "providers": {"type": "object", "additionalProperties": true},
                "services": {"type": "object", "additionalProperties": true}
            }
        }),
        "auth::oauth_begin" => json!({
            "type": "object",
            "required": ["flowId", "authUrl"],
            "additionalProperties": false,
            "properties": {
                "flowId": {"type": "string"},
                "authUrl": {"type": "string"}
            }
        }),
        "blob::get" => json!({
            "type": "object",
            "required": ["blobId", "mimeType", "data", "sizeBytes"],
            "additionalProperties": false,
            "properties": {
                "blobId": {"type": "string"},
                "mimeType": {"type": "string"},
                "data": {"type": "string"},
                "sizeBytes": {"type": "integer"}
            }
        }),
        "tool::result" => json!({
            "type": "object",
            "required": ["success", "toolCallId"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "toolCallId": {"type": "string"}
            }
        }),
        "message::delete" => json!({
            "type": "object",
            "required": ["success", "deletionEventId", "targetType"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "deletionEventId": {"type": "string"},
                "targetType": {"type": "string"}
            }
        }),
        "cron::delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {"deleted": {"type": "boolean"}}
        }),
        "cron::run" => json!({
            "type": "object",
            "required": ["triggered", "jobId"],
            "additionalProperties": false,
            "properties": {
                "triggered": {"type": "boolean"},
                "jobId": {"type": "string"}
            }
        }),
        "events::get_history" => json!({
            "type": "object",
            "required": ["sessionId", "events", "hasMore", "oldestEventId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "events": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "hasMore": {"type": "boolean"},
                "oldestEventId": {"type": ["string", "null"]}
            }
        }),
        "events::get_since" => json!({
            "type": "object",
            "required": ["events", "hasMore", "nextCursor"],
            "additionalProperties": false,
            "properties": {
                "events": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "hasMore": {"type": "boolean"},
                "nextCursor": {"type": ["string", "null"]}
            }
        }),
        "events::append" => json!({
            "type": "object",
            "required": ["event", "newHeadEventId"],
            "additionalProperties": false,
            "properties": {
                "event": {"type": "object", "additionalProperties": true},
                "newHeadEventId": {"type": ["string", "null"]}
            }
        }),
        "events::subscribe" => json!({
            "type": "object",
            "required": ["subscribed"],
            "additionalProperties": false,
            "properties": {"subscribed": {"type": "boolean"}}
        }),
        "events::unsubscribe" => json!({
            "type": "object",
            "required": ["unsubscribed"],
            "additionalProperties": false,
            "properties": {"unsubscribed": {"type": "boolean"}}
        }),
        "filesystem::list_dir" => json!({
            "type": "object",
            "required": ["path", "parent", "entries"],
            "additionalProperties": false,
            "properties": {
                "path": {"type": "string"},
                "parent": {"type": ["string", "null"]},
                "entries": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "filesystem::get_home" => json!({
            "type": "object",
            "required": ["homePath", "suggestedPaths"],
            "additionalProperties": false,
            "properties": {
                "homePath": {"type": "string"},
                "suggestedPaths": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "path", "exists"],
                        "additionalProperties": false,
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "exists": {"type": "boolean"}
                        }
                    }
                }
            }
        }),
        "filesystem::read_file" => json!({
            "type": "object",
            "required": ["content", "path"],
            "additionalProperties": false,
            "properties": {
                "content": {"type": "string"},
                "path": {"type": "string"}
            }
        }),
        "filesystem::create_dir" => json!({
            "type": "object",
            "required": ["created", "path"],
            "additionalProperties": false,
            "properties": {
                "created": {"type": "boolean"},
                "path": {"type": "string"}
            }
        }),
        "session::list"
        | "session::create"
        | "session::resume"
        | "session::delete"
        | "session::fork"
        | "session::get_head"
        | "session::get_state"
        | "session::get_history"
        | "session::reconstruct"
        | "session::archive"
        | "session::unarchive"
        | "session::archive_older_than"
        | "session::export"
        | "context::get_snapshot"
        | "context::get_detailed_snapshot"
        | "context::get_audit_trace"
        | "context::should_compact"
        | "context::preview_compaction"
        | "context::can_accept_turn"
        | "context::confirm_compaction"
        | "context::clear"
        | "context::compact"
        | "tree::get_visualization"
        | "tree::get_branches"
        | "tree::get_subtree"
        | "tree::get_ancestors"
        | "tree::compare_branches"
        | "repo::list_sessions"
        | "repo::get_divergence"
        | "import::list_sources"
        | "import::list_sessions"
        | "import::preview_session"
        | "voice_notes::list"
        | "transcription::list_models"
        | "sandbox::list_containers" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "browser::get_status" => json!({
            "type": "object",
            "required": ["hasBrowser", "isStreaming"],
            "additionalProperties": false,
            "properties": {
                "hasBrowser": {"type": "boolean"},
                "isStreaming": {"type": "boolean"}
            }
        }),
        "browser::start_stream" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "browser::stop_stream" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "display::stop_stream" => json!({
            "type": "object",
            "required": ["streamId", "stopped"],
            "additionalProperties": false,
            "properties": {
                "streamId": {"type": "string"},
                "stopped": {"type": "boolean"}
            }
        }),
        "device::register" => json!({
            "type": "object",
            "required": ["id", "created"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "created": {"type": "boolean"}
            }
        }),
        "device::unregister" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "device::respond" => json!({
            "type": "object",
            "required": ["resolved"],
            "additionalProperties": false,
            "properties": {"resolved": {"type": "boolean"}}
        }),
        "transcription::audio" => json!({
            "type": "object",
            "required": [
                "text",
                "rawText",
                "language",
                "durationSeconds",
                "processingTimeMs",
                "model",
                "device",
                "computeType",
                "cleanupMode"
            ],
            "additionalProperties": false,
            "properties": {
                "text": {"type": "string"},
                "rawText": {"type": "string"},
                "language": {"type": "string"},
                "durationSeconds": {"type": "number"},
                "processingTimeMs": {"type": "integer"},
                "model": {"type": "string"},
                "device": {"type": "string"},
                "computeType": {"type": "string"},
                "cleanupMode": {"type": "string"}
            }
        }),
        "transcription::download_model" => json!({
            "type": "object",
            "required": ["started", "reason"],
            "additionalProperties": false,
            "properties": {
                "started": {"type": "boolean"},
                "reason": {"type": "string"},
                "message": {"type": "string"}
            }
        }),
        "voice_notes::save" => json!({
            "type": "object",
            "required": ["success", "filename", "filepath", "transcription"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "filename": {"type": "string"},
                "filepath": {"type": "string"},
                "transcription": {"type": "object", "additionalProperties": true}
            }
        }),
        "voice_notes::delete" => json!({
            "type": "object",
            "required": ["success", "filename"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "filename": {"type": "string"}
            }
        }),
        "sandbox::start_container"
        | "sandbox::stop_container"
        | "sandbox::kill_container"
        | "sandbox::remove_container" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {"success": {"type": "boolean"}}
        }),
        "agent::prompt" => json!({
            "type": "object",
            "required": ["acknowledged", "runId"],
            "additionalProperties": false,
            "properties": {
                "acknowledged": {"type": "boolean"},
                "runId": {"type": "string"}
            }
        }),
        "agent::status"
        | "agent::abort"
        | "agent::abort_tool"
        | "agent::queue_prompt"
        | "agent::dequeue_prompt"
        | "agent::clear_queue"
        | "agent::deliver_subagent_results"
        | "agent::submit_confirmation"
        | "agent::submit_answers" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "mcp::status" => json!({
            "type": "array",
            "items": {"type": "object", "additionalProperties": true}
        }),
        "mcp::list_tools" => json!({
            "type": "array",
            "items": {"type": "object", "additionalProperties": true}
        }),
        "mcp::add_server" | "mcp::restart_server" => json!({
            "type": "object",
            "required": ["success", "toolCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "toolCount": {"type": "integer"}
            }
        }),
        "mcp::remove_server" | "mcp::enable_server" | "mcp::disable_server" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "mcp::reload" => json!({
            "type": "object",
            "required": ["success", "serverCount"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"},
                "serverCount": {"type": "integer"}
            }
        }),
        "job::background" => json!({
            "type": "object",
            "required": ["jobId", "backgrounded"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "backgrounded": {"type": "boolean"}
            }
        }),
        "job::cancel" => json!({
            "type": "object",
            "required": ["jobId", "cancelled"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "cancelled": {"type": "boolean"}
            }
        }),
        "job::list" => json!({
            "type": "object",
            "required": ["jobs"],
            "additionalProperties": false,
            "properties": {"jobs": {"type": "array"}}
        }),
        "job::subscribe" => json!({
            "type": "object",
            "required": ["subscribed", "jobId"],
            "additionalProperties": false,
            "properties": {
                "subscribed": {"type": "boolean"},
                "jobId": {"type": "string"}
            }
        }),
        "job::unsubscribe" => json!({
            "type": "object",
            "required": ["jobId", "unsubscribed"],
            "additionalProperties": false,
            "properties": {
                "jobId": {"type": "string"},
                "unsubscribed": {"type": "boolean"}
            }
        }),
        "notifications::list" => json!({
            "type": "object",
            "required": ["notifications", "unreadCount"],
            "additionalProperties": false,
            "properties": {
                "notifications": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "unreadCount": {"type": "integer"}
            }
        }),
        "notifications::mark_read" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "notifications::mark_all_read" => json!({
            "type": "object",
            "required": ["marked"],
            "additionalProperties": false,
            "properties": {
                "marked": {"type": "integer"}
            }
        }),
        "plan::enter" | "plan::exit" | "plan::get_state" => json!({
            "type": "object",
            "required": ["planMode"],
            "additionalProperties": false,
            "properties": {
                "planMode": {"type": "boolean"}
            }
        }),
        "prompt_library::history_list" => json!({
            "type": "object",
            "required": ["items", "nextCursor"],
            "additionalProperties": false,
            "properties": {
                "items": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "nextCursor": {"type": ["string", "null"]}
            }
        }),
        "prompt_library::history_delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {
                "deleted": {"type": "boolean"}
            }
        }),
        "prompt_library::history_clear" => json!({
            "type": "object",
            "required": ["deletedCount"],
            "additionalProperties": false,
            "properties": {
                "deletedCount": {"type": "integer"}
            }
        }),
        "prompt_library::snippet_list" => json!({
            "type": "object",
            "required": ["items"],
            "additionalProperties": false,
            "properties": {
                "items": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "prompt_library::snippet_get" => json!({
            "type": "object",
            "required": ["snippet"],
            "additionalProperties": false,
            "properties": {
                "snippet": {"type": "object", "additionalProperties": true}
            }
        }),
        "prompt_library::snippet_create" | "prompt_library::snippet_update" => json!({
            "type": "object",
            "required": ["snippet"],
            "additionalProperties": false,
            "properties": {
                "snippet": {"type": "object", "additionalProperties": true}
            }
        }),
        "prompt_library::snippet_delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {
                "deleted": {"type": "boolean"}
            }
        }),
        method if method.starts_with("git::") || method.starts_with("worktree::") => {
            json!({
                "type": "object",
                "additionalProperties": true
            })
        }
        _ => return None,
    })
}

pub(crate) fn capability_specs_for_methods(
    methods: &[&'static str],
) -> crate::engine::Result<Vec<CapabilitySpec>> {
    methods
        .iter()
        .copied()
        .map(capability_spec_for_method)
        .collect()
}

pub(crate) fn capability_spec_for_method(
    method: &'static str,
) -> crate::engine::Result<CapabilitySpec> {
    let effect_class = effect_class_for_method(method);
    let owner_worker = crate::server::domains::catalog::domain_worker_for_method(method)?;
    Ok(CapabilitySpec {
        method,
        function_id: crate::server::domains::catalog::function_id_for_method(method)?,
        owner_worker: owner_worker.clone(),
        domain_worker: owner_worker,
        effect_class,
        risk_level: risk_for_method(method, effect_class),
        visibility: crate::engine::VisibilityScope::System,
        authority_scope: Some(
            crate::server::domains::catalog::domain_authority_scope_for_method(
                method,
                effect_class,
            ),
        ),
        idempotency_mode: idempotency_mode_for_method(method, effect_class),
        domain_module: crate::server::domains::catalog::domain_module_for_method(method),
    })
}
