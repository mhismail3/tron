//! RPC handler modules and registration.
//!
//! Handlers are grouped into three registration sets:
//!
//! ## `register_core` — Session and agent lifecycle
//!
//! `system` (ping, info, shutdown), `session` (CRUD, fork, archive),
//! `agent` (prompt, abort, state), `model` (list, switch), `context`
//! (snapshot, compaction), `events` (history, subscribe), `settings`,
//! `tool` (result), `message`, `memory` (ledger, search), `logs`
//!
//! ## `register_capabilities` — Domain features
//!
//! `skills` (list, get, refresh), `skill_session` (activate, deactivate,
//! active — session-scoped skill state), `filesystem` (list, read, mkdir),
//! `tree` (visualization, branches), `import` (listSources, listSessions,
//! previewSession, execute), `mcp`, `prompt_library`, and `cron`
//!
//! ## `register_platform` — Platform-specific
//!
//! `browser` (stream), `worktree` (git), `transcription`,
//! `device` (push tokens), `notifications` (inbox), `plan`,
//! `voice_notes`, `git`, `sandbox`

pub mod agent;
pub mod agent_confirmation;
pub mod agent_queue;
pub mod agent_subagent;
pub mod auth;
pub mod blob;
pub mod browser;
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
    registry.register("system.ping", system::PingHandler);
    registry.register("system.getInfo", system::GetInfoHandler);
    registry.register("system.getDiagnostics", system::GetDiagnosticsHandler);
    registry.register("system.shutdown", system::ShutdownHandler);
    // System — user-mode update checks/downloads.
    registry.register("system.checkForUpdates", system::CheckForUpdatesHandler);
    registry.register("system.getUpdateStatus", system::GetUpdateStatusHandler);

    // Blob
    registry.register("blob.get", blob::GetBlobHandler);

    // Session
    registry.register("session.create", session::CreateSessionHandler);
    registry.register("session.resume", session::ResumeSessionHandler);
    registry.register("session.list", session::ListSessionsHandler);
    registry.register("session.delete", session::DeleteSessionHandler);
    registry.register("session.fork", session::ForkSessionHandler);
    registry.register("session.getHead", session::GetHeadHandler);
    registry.register("session.getState", session::GetStateHandler);
    registry.register("session.getHistory", session::GetHistoryHandler);
    registry.register("session.reconstruct", session::ReconstructHandler);
    registry.register("session.archive", session::ArchiveSessionHandler);
    registry.register("session.unarchive", session::UnarchiveSessionHandler);
    registry.register("session.archiveOlderThan", session::ArchiveOlderThanHandler);
    registry.register("session.export", session::ExportSessionHandler);
    // Agent
    registry.register("agent.prompt", agent::PromptHandler);
    registry.register("agent.abort", agent::AbortHandler);
    registry.register("agent.abortTool", agent::AbortToolHandler);
    registry.register("agent.status", agent::StatusHandler);
    registry.register("agent.queuePrompt", agent_queue::QueuePromptHandler);
    registry.register("agent.dequeuePrompt", agent_queue::DequeuePromptHandler);
    registry.register("agent.clearQueue", agent_queue::ClearQueueHandler);
    registry.register(
        "agent.deliverSubagentResults",
        agent_subagent::DeliverSubagentResultsHandler,
    );
    registry.register(
        "agent.submitConfirmation",
        agent_confirmation::SubmitConfirmationHandler,
    );
    registry.register(
        "agent.submitAnswers",
        agent_confirmation::SubmitAnswersHandler,
    );

    // Model
    registry.register("model.list", model::ListModelsHandler);
    registry.register("model.switch", model::SwitchModelHandler);
    registry.register("config.setReasoningLevel", model::SetReasoningLevelHandler);

    // Context
    registry.register("context.getSnapshot", context::GetSnapshotHandler);
    registry.register(
        "context.getDetailedSnapshot",
        context::GetDetailedSnapshotHandler,
    );
    registry.register("context.shouldCompact", context::ShouldCompactHandler);
    registry.register(
        "context.previewCompaction",
        context::PreviewCompactionHandler,
    );
    registry.register(
        "context.confirmCompaction",
        context::ConfirmCompactionHandler,
    );
    registry.register("context.canAcceptTurn", context::CanAcceptTurnHandler);
    registry.register("context.clear", context::ClearHandler);
    registry.register("context.compact", context::CompactHandler);

    // Events
    registry.register("events.getHistory", events::GetHistoryHandler);
    registry.register("events.getSince", events::GetSinceHandler);
    registry.register("events.subscribe", events::SubscribeHandler);
    registry.register("events.unsubscribe", events::UnsubscribeHandler);
    registry.register("events.append", events::AppendHandler);

    // Settings
    registry.register("settings.get", settings::GetSettingsHandler);
    registry.register("settings.update", settings::UpdateSettingsHandler);
    registry.register("settings.resetToDefaults", settings::ResetSettingsHandler);

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
    registry.register("logs.ingest", logs::IngestLogsHandler);
    registry.register("logs.recent", logs::RecentLogsHandler);

    // Memory
    registry.register("memory.retain", memory::RetainMemoryHandler);
}

fn register_capabilities(registry: &mut MethodRegistry) {
    // MCP
    registry.register("mcp.status", mcp::McpStatusHandler);
    registry.register("mcp.addServer", mcp::McpAddServerHandler);
    registry.register("mcp.removeServer", mcp::McpRemoveServerHandler);
    registry.register("mcp.enableServer", mcp::McpEnableServerHandler);
    registry.register("mcp.disableServer", mcp::McpDisableServerHandler);
    registry.register("mcp.restartServer", mcp::McpRestartServerHandler);
    registry.register("mcp.reload", mcp::McpReloadHandler);
    registry.register("mcp.listTools", mcp::McpListToolsHandler);

    // Skills
    registry.register("skill.list", skills::ListSkillsHandler);
    registry.register("skill.get", skills::GetSkillHandler);
    registry.register("skill.refresh", skills::RefreshSkillsHandler);

    // Session-scoped skill state
    registry.register("skill.activate", skill_session::ActivateHandler);
    registry.register("skill.deactivate", skill_session::DeactivateHandler);
    registry.register("skill.active", skill_session::ActiveHandler);

    // Filesystem
    registry.register("filesystem.listDir", filesystem::ListDirHandler);
    registry.register("filesystem.getHome", filesystem::GetHomeHandler);
    registry.register("filesystem.createDir", filesystem::CreateDirHandler);
    registry.register("file.read", filesystem::ReadFileHandler);

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
    registry.register("job.background", job::BackgroundHandler);
    registry.register("job.cancel", job::CancelHandler);
    registry.register("job.list", job::ListHandler);
    registry.register("job.subscribe", job::SubscribeHandler);
    registry.register("job.unsubscribe", job::UnsubscribeHandler);

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
    registry.register("plan.enter", plan::EnterPlanHandler);
    registry.register("plan.exit", plan::ExitPlanHandler);
    registry.register("plan.getState", plan::GetPlanStateHandler);

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
    registry.register("notifications.list", notifications::ListHandler);
    registry.register("notifications.markRead", notifications::MarkReadHandler);
    registry.register(
        "notifications.markAllRead",
        notifications::MarkAllReadHandler,
    );

    // Prompt Library
    registry.register("promptHistory.list", prompt_library::ListHistoryHandler);
    registry.register("promptHistory.delete", prompt_library::DeleteHistoryHandler);
    registry.register("promptHistory.clear", prompt_library::ClearHistoryHandler);
    registry.register("promptSnippet.list", prompt_library::ListSnippetsHandler);
    registry.register("promptSnippet.get", prompt_library::GetSnippetHandler);
    registry.register("promptSnippet.create", prompt_library::CreateSnippetHandler);
    registry.register("promptSnippet.update", prompt_library::UpdateSnippetHandler);
    registry.register("promptSnippet.delete", prompt_library::DeleteSnippetHandler);

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
            165,
            "expected 165 methods, got {}",
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
