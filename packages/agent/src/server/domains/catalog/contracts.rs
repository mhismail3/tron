//! Effect, risk, idempotency, resource-lease, and compensation contracts for canonical functions.

use serde_json::json;

use super::{CapabilitySpec, TransportIdempotencyMode};
use crate::engine::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, FunctionDefinition,
    IdempotencyContract, Provenance, ResourceLeaseRequirement, RiskLevel,
};
use crate::server::domains::schemas::{request_schema_for_method, response_schema_for_method};

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
