//! RPC handler modules and registration.
//!
//! Handlers are grouped into three registration sets:
//!
//! ## `register_core` — Session and agent lifecycle
//!
//! `system` (ping, info, shutdown), `session` (CRUD, fork, archive, export
//! generic except resume), `agent` (prompt/status/abort/tool/submission
//! controls generic), `model` (list, switch), `context` (snapshot and
//! compaction generic), `events`, `settings`, `approval`, `tool` (result),
//! `message`, `memory`, `logs`
//!
//! ## `register_capabilities` — Domain features
//!
//! `mcp`, `skills`, `skill_session`, prompt library, and basic filesystem
//! operations are fully generic-triggered engine functions;
//!
//! The remaining capability modules are
//! `tree` (visualization, branches), `import` (listSources, listSessions,
//! previewSession, execute), and `cron`
//!
//! ## `register_platform` — Platform-specific
//!
//! `browser` (stream), `worktree` (git), `job` (fully generic and queue-backed),
//! `transcription`, `device` (push tokens), `notifications` and `plan`
//! (fully generic), `voice_notes`, `git`, `sandbox`

pub mod agent;
#[cfg(test)]
pub mod agent_confirmation;
pub mod agent_queue;
#[cfg(test)]
pub mod agent_subagent;
pub mod auth;
pub mod blob;
pub mod browser;
pub mod codex_app;
pub mod context;
pub mod cron;
pub mod device;
pub mod display;
pub mod events;
pub mod filesystem;
pub mod git;
pub mod git_workflow;
pub mod import;
pub(crate) mod job;
pub mod logs;
pub mod mcp;
pub mod memory;
pub mod message;
pub mod model;
pub mod notifications;
pub mod plan;
pub mod prompt_library;
pub mod sandbox;
pub mod session;
pub mod settings;
pub mod skill_session;
pub mod skills;
pub mod system;
pub mod tool;
pub mod transcription;
pub mod tree;
pub mod voice_notes;
pub mod worktree;

use crate::server::rpc::engine_bridge::RpcGenericTriggerHandler;
use crate::server::rpc::registry::MethodRegistry;

/// Register all RPC handlers with the registry.
#[allow(clippy::too_many_lines)]
pub fn register_all(registry: &mut MethodRegistry) {
    register_core(registry);
    register_capabilities(registry);
    register_platform(registry);
}

fn register_core(registry: &mut MethodRegistry) {
    // System
    registry.register("system.ping", RpcGenericTriggerHandler::new("system.ping"));
    registry.register(
        "system.getInfo",
        RpcGenericTriggerHandler::new("system.getInfo"),
    );
    registry.register("system.getDiagnostics", system::GetDiagnosticsHandler);
    registry.register("system.shutdown", system::ShutdownHandler);
    // System — user-mode update checks/downloads.
    registry.register("system.checkForUpdates", system::CheckForUpdatesHandler);
    registry.register("system.getUpdateStatus", system::GetUpdateStatusHandler);

    // Codex App Server lifecycle discovery. Codex traffic remains direct iOS
    // -> managed `codex app-server`; this RPC only returns the server-owned
    // endpoint/token/status.
    registry.register("codexApp.status", codex_app::CodexAppStatusHandler);

    // Blob
    registry.register("blob.get", blob::GetBlobHandler);

    // Session
    registry.register(
        "session.create",
        RpcGenericTriggerHandler::new("session.create"),
    );
    registry.register("session.resume", session::ResumeSessionHandler);
    registry.register(
        "session.list",
        RpcGenericTriggerHandler::new("session.list"),
    );
    registry.register(
        "session.delete",
        RpcGenericTriggerHandler::new("session.delete"),
    );
    registry.register(
        "session.fork",
        RpcGenericTriggerHandler::new("session.fork"),
    );
    registry.register(
        "session.getHead",
        RpcGenericTriggerHandler::new("session.getHead"),
    );
    registry.register(
        "session.getState",
        RpcGenericTriggerHandler::new("session.getState"),
    );
    registry.register(
        "session.getHistory",
        RpcGenericTriggerHandler::new("session.getHistory"),
    );
    registry.register(
        "session.reconstruct",
        RpcGenericTriggerHandler::new("session.reconstruct"),
    );
    registry.register(
        "session.archive",
        RpcGenericTriggerHandler::new("session.archive"),
    );
    registry.register(
        "session.unarchive",
        RpcGenericTriggerHandler::new("session.unarchive"),
    );
    registry.register(
        "session.archiveOlderThan",
        RpcGenericTriggerHandler::new("session.archiveOlderThan"),
    );
    registry.register(
        "session.export",
        RpcGenericTriggerHandler::new("session.export"),
    );
    // Agent
    registry.register(
        "agent.prompt",
        RpcGenericTriggerHandler::new("agent.prompt"),
    );
    registry.register("agent.abort", RpcGenericTriggerHandler::new("agent.abort"));
    registry.register(
        "agent.abortTool",
        RpcGenericTriggerHandler::new("agent.abortTool"),
    );
    registry.register(
        "agent.status",
        RpcGenericTriggerHandler::new("agent.status"),
    );
    registry.register(
        "agent.queuePrompt",
        RpcGenericTriggerHandler::new("agent.queuePrompt"),
    );
    registry.register(
        "agent.dequeuePrompt",
        RpcGenericTriggerHandler::new("agent.dequeuePrompt"),
    );
    registry.register(
        "agent.clearQueue",
        RpcGenericTriggerHandler::new("agent.clearQueue"),
    );
    registry.register(
        "agent.deliverSubagentResults",
        RpcGenericTriggerHandler::new("agent.deliverSubagentResults"),
    );
    registry.register(
        "agent.submitConfirmation",
        RpcGenericTriggerHandler::new("agent.submitConfirmation"),
    );
    registry.register(
        "agent.submitAnswers",
        RpcGenericTriggerHandler::new("agent.submitAnswers"),
    );

    // Model
    registry.register("model.list", RpcGenericTriggerHandler::new("model.list"));
    registry.register("model.switch", model::SwitchModelHandler);
    registry.register("config.setReasoningLevel", model::SetReasoningLevelHandler);

    // Context
    registry.register(
        "context.getSnapshot",
        RpcGenericTriggerHandler::new("context.getSnapshot"),
    );
    registry.register(
        "context.getDetailedSnapshot",
        RpcGenericTriggerHandler::new("context.getDetailedSnapshot"),
    );
    registry.register(
        "context.getAuditTrace",
        RpcGenericTriggerHandler::new("context.getAuditTrace"),
    );
    registry.register(
        "context.shouldCompact",
        RpcGenericTriggerHandler::new("context.shouldCompact"),
    );
    registry.register(
        "context.previewCompaction",
        RpcGenericTriggerHandler::new("context.previewCompaction"),
    );
    registry.register(
        "context.confirmCompaction",
        RpcGenericTriggerHandler::new("context.confirmCompaction"),
    );
    registry.register(
        "context.canAcceptTurn",
        RpcGenericTriggerHandler::new("context.canAcceptTurn"),
    );
    registry.register(
        "context.clear",
        RpcGenericTriggerHandler::new("context.clear"),
    );
    registry.register(
        "context.compact",
        RpcGenericTriggerHandler::new("context.compact"),
    );

    // Events
    registry.register(
        "events.getHistory",
        RpcGenericTriggerHandler::new("events.getHistory"),
    );
    registry.register(
        "events.getSince",
        RpcGenericTriggerHandler::new("events.getSince"),
    );
    registry.register(
        "events.subscribe",
        RpcGenericTriggerHandler::new("events.subscribe"),
    );
    registry.register(
        "events.unsubscribe",
        RpcGenericTriggerHandler::new("events.unsubscribe"),
    );
    registry.register(
        "events.append",
        RpcGenericTriggerHandler::new("events.append"),
    );

    // Settings
    registry.register(
        "settings.get",
        RpcGenericTriggerHandler::new("settings.get"),
    );
    registry.register(
        "settings.update",
        RpcGenericTriggerHandler::new("settings.update"),
    );
    registry.register(
        "settings.resetToDefaults",
        RpcGenericTriggerHandler::new("settings.resetToDefaults"),
    );

    // Approval
    registry.register(
        "approval.get",
        RpcGenericTriggerHandler::new("approval.get"),
    );
    registry.register(
        "approval.list",
        RpcGenericTriggerHandler::new("approval.list"),
    );
    registry.register(
        "approval.resolve",
        RpcGenericTriggerHandler::new("approval.resolve"),
    );

    // Auth
    registry.register("auth.get", auth::GetAuthHandler);
    registry.register("auth.update", auth::UpdateAuthHandler);
    registry.register("auth.clear", auth::ClearAuthHandler);
    registry.register("auth.oauthBegin", auth::OAuthBeginHandler);
    registry.register("auth.oauthComplete", auth::OAuthCompleteHandler);
    registry.register("auth.renameAccount", auth::RenameAccountHandler);
    registry.register("auth.setActive", auth::SetActiveCredentialHandler);
    registry.register("auth.removeAccount", auth::RemoveAccountHandler);
    registry.register("auth.removeApiKey", auth::RemoveApiKeyHandler);

    // Tool
    registry.register("tool.result", tool::ToolResultHandler);

    // Message
    registry.register("message.delete", message::DeleteMessageHandler);

    // Logs
    registry.register("logs.ingest", RpcGenericTriggerHandler::new("logs.ingest"));
    registry.register("logs.recent", RpcGenericTriggerHandler::new("logs.recent"));

    // Memory
    registry.register("memory.retain", memory::RetainMemoryHandler);
}

fn register_capabilities(registry: &mut MethodRegistry) {
    // MCP
    registry.register("mcp.status", RpcGenericTriggerHandler::new("mcp.status"));
    registry.register(
        "mcp.addServer",
        RpcGenericTriggerHandler::new("mcp.addServer"),
    );
    registry.register(
        "mcp.removeServer",
        RpcGenericTriggerHandler::new("mcp.removeServer"),
    );
    registry.register(
        "mcp.enableServer",
        RpcGenericTriggerHandler::new("mcp.enableServer"),
    );
    registry.register(
        "mcp.disableServer",
        RpcGenericTriggerHandler::new("mcp.disableServer"),
    );
    registry.register(
        "mcp.restartServer",
        RpcGenericTriggerHandler::new("mcp.restartServer"),
    );
    registry.register("mcp.reload", RpcGenericTriggerHandler::new("mcp.reload"));
    registry.register(
        "mcp.listTools",
        RpcGenericTriggerHandler::new("mcp.listTools"),
    );

    // Skills
    registry.register("skill.list", RpcGenericTriggerHandler::new("skill.list"));
    registry.register("skill.get", RpcGenericTriggerHandler::new("skill.get"));
    registry.register(
        "skill.refresh",
        RpcGenericTriggerHandler::new("skill.refresh"),
    );

    // Session-scoped skill state
    registry.register(
        "skill.activate",
        RpcGenericTriggerHandler::new("skill.activate"),
    );
    registry.register(
        "skill.deactivate",
        RpcGenericTriggerHandler::new("skill.deactivate"),
    );
    registry.register(
        "skill.active",
        RpcGenericTriggerHandler::new("skill.active"),
    );

    // Filesystem
    registry.register(
        "filesystem.listDir",
        RpcGenericTriggerHandler::new("filesystem.listDir"),
    );
    registry.register(
        "filesystem.getHome",
        RpcGenericTriggerHandler::new("filesystem.getHome"),
    );
    registry.register(
        "filesystem.createDir",
        RpcGenericTriggerHandler::new("filesystem.createDir"),
    );
    registry.register("file.read", RpcGenericTriggerHandler::new("file.read"));

    // Tree
    registry.register("tree.getVisualization", tree::GetVisualizationHandler);
    registry.register("tree.getBranches", tree::GetBranchesHandler);
    registry.register("tree.getSubtree", tree::GetSubtreeHandler);
    registry.register("tree.getAncestors", tree::GetAncestorsHandler);
    registry.register("tree.compareBranches", tree::CompareBranchesHandler);

    // Import
    registry.register("import.listSources", import::ListSourcesHandler);
    registry.register("import.listSessions", import::ListSessionsHandler);
    registry.register("import.previewSession", import::PreviewSessionHandler);
    registry.register("import.execute", import::ExecuteImportHandler);
}

fn register_platform(registry: &mut MethodRegistry) {
    // Browser
    registry.register("browser.startStream", browser::StartStreamHandler);
    registry.register("browser.stopStream", browser::StopStreamHandler);
    registry.register("browser.getStatus", browser::GetStatusHandler);

    // Display
    registry.register("display.stopStream", display::StopStreamHandler);

    // Unified job management
    registry.register(
        "job.background",
        RpcGenericTriggerHandler::new("job.background"),
    );
    registry.register("job.cancel", RpcGenericTriggerHandler::new("job.cancel"));
    registry.register("job.list", RpcGenericTriggerHandler::new("job.list"));
    registry.register(
        "job.subscribe",
        RpcGenericTriggerHandler::new("job.subscribe"),
    );
    registry.register(
        "job.unsubscribe",
        RpcGenericTriggerHandler::new("job.unsubscribe"),
    );

    // Worktree
    registry.register("worktree.getStatus", worktree::GetStatusHandler);
    registry.register("worktree.isGitRepo", worktree::IsGitRepoHandler);
    registry.register("worktree.commit", worktree::CommitHandler);
    registry.register("worktree.merge", worktree::MergeHandler);
    registry.register("worktree.list", worktree::ListHandler);
    registry.register("worktree.getDiff", worktree::GetDiffHandler);
    registry.register("worktree.acquire", worktree::AcquireHandler);
    registry.register("worktree.release", worktree::ReleaseHandler);
    registry.register(
        "worktree.listSessionBranches",
        worktree::ListSessionBranchesHandler,
    );
    registry.register(
        "worktree.getCommittedDiff",
        worktree::GetCommittedDiffHandler,
    );
    registry.register("worktree.deleteBranch", worktree::DeleteBranchHandler);
    registry.register("worktree.pruneBranches", worktree::PruneBranchesHandler);
    registry.register("worktree.stageFiles", worktree::StageFilesHandler);
    registry.register("worktree.unstageFiles", worktree::UnstageFilesHandler);
    registry.register("worktree.discardFiles", worktree::DiscardFilesHandler);

    // Transcription
    registry.register("transcribe.audio", transcription::TranscribeAudioHandler);
    registry.register("transcribe.listModels", transcription::ListModelsHandler);
    registry.register(
        "transcribe.downloadModel",
        transcription::DownloadModelHandler,
    );

    // Device
    registry.register("device.register", device::RegisterTokenHandler);
    registry.register("device.unregister", device::UnregisterTokenHandler);
    registry.register("device.respond", device::DeviceRespondHandler);

    // Plan
    registry.register("plan.enter", RpcGenericTriggerHandler::new("plan.enter"));
    registry.register("plan.exit", RpcGenericTriggerHandler::new("plan.exit"));
    registry.register(
        "plan.getState",
        RpcGenericTriggerHandler::new("plan.getState"),
    );

    // Voice Notes
    registry.register("voiceNotes.save", voice_notes::SaveHandler);
    registry.register("voiceNotes.list", voice_notes::ListHandler);
    registry.register("voiceNotes.delete", voice_notes::DeleteHandler);

    // Git
    registry.register("git.clone", git::CloneHandler);

    // Git workflow (Phase 5)
    registry.register("git.syncMain", git_workflow::SyncMainHandler);
    registry.register("git.push", git_workflow::PushHandler);
    registry.register(
        "git.listLocalBranches",
        git_workflow::ListLocalBranchesHandler,
    );
    registry.register(
        "git.listRemoteBranches",
        git_workflow::ListRemoteBranchesHandler,
    );
    registry.register(
        "worktree.finalizeSession",
        git_workflow::FinalizeSessionHandler,
    );
    registry.register("worktree.rebaseOnMain", git_workflow::RebaseOnMainHandler);
    registry.register("worktree.startMerge", git_workflow::StartMergeHandler);
    registry.register("worktree.listConflicts", git_workflow::ListConflictsHandler);
    registry.register(
        "worktree.resolveConflict",
        git_workflow::ResolveConflictHandler,
    );
    registry.register("worktree.continueMerge", git_workflow::ContinueMergeHandler);
    registry.register("worktree.abortMerge", git_workflow::AbortMergeHandler);
    registry.register(
        "worktree.resolveConflictsWithSubagent",
        git_workflow::ResolveConflictsWithSubagentHandler,
    );
    registry.register("repo.listSessions", git_workflow::ListRepoSessionsHandler);
    registry.register("repo.getDivergence", git_workflow::GetDivergenceHandler);

    // Sandbox
    registry.register("sandbox.listContainers", sandbox::ListContainersHandler);
    registry.register("sandbox.startContainer", sandbox::StartContainerHandler);
    registry.register("sandbox.stopContainer", sandbox::StopContainerHandler);
    registry.register("sandbox.killContainer", sandbox::KillContainerHandler);
    registry.register("sandbox.removeContainer", sandbox::RemoveContainerHandler);

    // Notifications
    registry.register(
        "notifications.list",
        RpcGenericTriggerHandler::new("notifications.list"),
    );
    registry.register(
        "notifications.markRead",
        RpcGenericTriggerHandler::new("notifications.markRead"),
    );
    registry.register(
        "notifications.markAllRead",
        RpcGenericTriggerHandler::new("notifications.markAllRead"),
    );

    // Prompt Library
    registry.register(
        "promptHistory.list",
        RpcGenericTriggerHandler::new("promptHistory.list"),
    );
    registry.register(
        "promptHistory.delete",
        RpcGenericTriggerHandler::new("promptHistory.delete"),
    );
    registry.register(
        "promptHistory.clear",
        RpcGenericTriggerHandler::new("promptHistory.clear"),
    );
    registry.register(
        "promptSnippet.list",
        RpcGenericTriggerHandler::new("promptSnippet.list"),
    );
    registry.register(
        "promptSnippet.get",
        RpcGenericTriggerHandler::new("promptSnippet.get"),
    );
    registry.register(
        "promptSnippet.create",
        RpcGenericTriggerHandler::new("promptSnippet.create"),
    );
    registry.register(
        "promptSnippet.update",
        RpcGenericTriggerHandler::new("promptSnippet.update"),
    );
    registry.register(
        "promptSnippet.delete",
        RpcGenericTriggerHandler::new("promptSnippet.delete"),
    );

    // Cron
    registry.register("cron.list", cron::ListHandler);
    registry.register("cron.get", cron::GetHandler);
    registry.register("cron.create", cron::CreateHandler);
    registry.register("cron.update", cron::UpdateHandler);
    registry.register("cron.delete", cron::DeleteHandler);
    registry.register("cron.run", cron::RunHandler);
    registry.register("cron.status", cron::StatusHandler);
    registry.register("cron.getRuns", cron::GetRunsHandler);
}

// Param extraction helpers (require_param, opt_string, etc.) live in
// params.rs; the typed `WorktreeError` → `RpcError` mapper lives in
// error_mapping.rs. Both are re-exported under this module's namespace
// so handler files can keep using `super::*` imports.
mod error_mapping;
mod params;

pub(crate) use error_mapping::{
    map_auth_error, map_cron_error, map_event_store_error, map_import_error, map_worktree_error,
};
pub(crate) use params::{
    opt_array, opt_bool, opt_string, opt_u64, require_bool, require_param, require_string_param,
};

#[cfg(test)]
pub(crate) mod test_helpers;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::registry::MethodRegistry;

    #[test]
    fn register_all_populates_registry() {
        let mut reg = MethodRegistry::new();
        register_all(&mut reg);
        assert!(reg.has_method("system.ping"));
        assert!(reg.has_method("session.create"));
        assert!(reg.has_method("agent.prompt"));
        assert!(reg.has_method("git.clone"));
        assert!(!reg.has_method("memory.getHandoffs"));
        assert!(reg.has_method("mcp.status"));
        assert!(reg.has_method("mcp.addServer"));
        assert!(reg.has_method("mcp.reload"));
        assert!(reg.has_method("codexApp.status"));
        assert!(reg.has_method("system.checkForUpdates"));
        assert!(reg.has_method("system.getUpdateStatus"));
        assert!(!reg.has_method("system.probePermissions"));
    }

    #[test]
    fn register_all_method_count() {
        let mut reg = MethodRegistry::new();
        register_all(&mut reg);
        assert_eq!(
            reg.methods().len(),
            170,
            "expected 170 methods, got {}",
            reg.methods().len()
        );
    }

    // Param-helper tests (require_param, require_string_param, opt_string,
    // opt_u64, opt_bool, opt_array) live next to their helpers in params.rs.
    // The exhaustive map_worktree_error coverage lives in error_mapping.rs.

    #[test]
    fn to_json_value_ok() {
        use crate::server::rpc::errors::to_json_value;
        let v = to_json_value(&vec!["a", "b"]).unwrap();
        assert!(v.is_array());
    }
}
