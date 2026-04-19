//! Shared command-side services for session RPC handlers.

use std::time::Instant;

use metrics::{counter, histogram};
use serde_json::{Value, json};
use crate::core::events::{BaseEvent, TronEvent};
use crate::runtime::agent::event_emitter::EventEmitter;

use crate::server::rpc::context::{RpcContext, run_blocking_task};
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::session_context::{ContextArtifactsService, RuleFileLevel};

/// Release worktree for a session if one is active.
///
/// Logs and swallows errors — archive/delete must not fail due to worktree issues.
/// Mirrors the invariant in `SessionManager::end_session()`: worktree is released
/// BEFORE the session is marked as ended.
async fn release_worktree_if_active(ctx: &RpcContext, session_id: &str) {
    if let Some(ref coord) = ctx.worktree_coordinator {
        if let Err(e) = coord.release(session_id).await {
            tracing::warn!(
                session_id,
                error = %e,
                "failed to release worktree during session cleanup"
            );
        }
    }
}

pub(crate) struct CreateSessionRequest {
    pub(crate) working_directory: String,
    pub(crate) model: String,
    pub(crate) title: Option<String>,
    pub(crate) source: Option<String>,
    /// Per-session worktree override.
    /// `None` defers to the global isolation mode; `Some(true)` forces
    /// isolation, `Some(false)` forces passthrough.
    pub(crate) use_worktree: Option<bool>,
}

pub(crate) struct SessionCommandService;

impl SessionCommandService {
    pub(crate) async fn create(
        ctx: &RpcContext,
        request: CreateSessionRequest,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let working_directory = request.working_directory.clone();
        let model = request.model.clone();
        let title = request.title.clone();
        let source = request.source.clone();
        let use_worktree = request.use_worktree;
        let session_id = ctx
            .run_blocking("session.create", move || {
                session_manager
                    .create_session_with_worktree_override(
                        &model,
                        &working_directory,
                        title.as_deref(),
                        source.as_deref(),
                        use_worktree,
                    )
                    .map_err(|error| RpcError::Internal {
                        message: error.to_string(),
                    })
            })
            .await?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionCreated {
                base: BaseEvent::now(&session_id),
                model: request.model.clone(),
                working_directory: request.working_directory.clone(),
                source: request.source.clone(),
                title: request.title.clone(),
            });

        ctx.orchestrator.init_sequence_counter(&session_id, 0);

        // Skip optimistic context preload for chat sessions — they don't load context artifacts
        if request.source.as_deref() != Some("chat") {
            spawn_optimistic_context_preload(ctx, &session_id, &request.working_directory);
        }

        Ok(json!({
            "sessionId": session_id,
            "model": request.model,
            "workingDirectory": request.working_directory,
            "createdAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            "isActive": true,
            "isArchived": false,
            "messageCount": 0,
            "eventCount": 1,
            "inputTokens": 0,
            "outputTokens": 0,
            "cost": 0.0,
            "useWorktree": request.use_worktree,
        }))
    }

    pub(crate) async fn delete(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        release_worktree_if_active(ctx, &session_id).await;

        let session_manager = ctx.session_manager.clone();
        let session_id_for_delete = session_id.clone();
        ctx.run_blocking("session.delete", move || {
            session_manager
                .delete_session(&session_id_for_delete)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        ctx.orchestrator.remove_sequence_counter(&session_id);
        ctx.orchestrator.remove_compaction_handler(&session_id);

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionDeleted {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "deleted": true }))
    }

    pub(crate) async fn fork(
        ctx: &RpcContext,
        session_id: String,
        from_event_id: Option<String>,
        title: Option<String>,
    ) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id_for_fork = session_id.clone();
        let title_for_fork = title.clone();
        let (new_session_id, forked_from_event_id, root_event_id) = ctx
            .run_blocking("session.fork", move || {
                let result = session_manager
                    .fork_session(
                        &session_id_for_fork,
                        from_event_id.as_deref(),
                        None,
                        title_for_fork.as_deref(),
                    )
                    .map_err(|error| RpcError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: error.to_string(),
                    })?;
                Ok((
                    result.new_session_id,
                    result.forked_from_event_id,
                    result.root_event_id,
                ))
            })
            .await?;

        ctx.orchestrator.init_sequence_counter(&new_session_id, 0);

        let _ = ctx.orchestrator.broadcast().emit(TronEvent::SessionForked {
            base: BaseEvent::now(&session_id),
            new_session_id: new_session_id.clone(),
        });

        Ok(json!({
            "newSessionId": new_session_id,
            "forkedFromSessionId": session_id,
            "forkedFromEventId": forked_from_event_id,
            "rootEventId": root_event_id,
        }))
    }

    pub(crate) async fn archive(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        release_worktree_if_active(ctx, &session_id).await;

        let session_manager = ctx.session_manager.clone();
        let session_id_for_archive = session_id.clone();
        ctx.run_blocking("session.archive", move || {
            session_manager
                .archive_session(&session_id_for_archive)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        ctx.orchestrator.remove_sequence_counter(&session_id);
        ctx.orchestrator.remove_compaction_handler(&session_id);

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionArchived {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "archived": true }))
    }

    pub(crate) async fn unarchive(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let session_manager = ctx.session_manager.clone();
        let session_id_for_unarchive = session_id.clone();
        ctx.run_blocking("session.unarchive", move || {
            session_manager
                .unarchive_session(&session_id_for_unarchive)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionUnarchived {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "unarchived": true }))
    }

}

fn spawn_optimistic_context_preload(ctx: &RpcContext, session_id: &str, working_dir: &str) {
    let event_store = ctx.event_store.clone();
    let context_artifacts = ctx.context_artifacts.clone();
    let broadcast = ctx.orchestrator.broadcast().clone();
    let shutdown_coordinator = ctx.shutdown_coordinator.clone();
    let session_id_for_task = session_id.to_owned();
    let working_dir_for_task = working_dir.to_owned();
    let handle = tokio::spawn(async move {
        let start = Instant::now();
        let result = run_blocking_task("session.optimistic_context_preload", move || {
            let summary = emit_optimistic_context_events(
                &event_store,
                context_artifacts.as_ref(),
                &broadcast,
                &session_id_for_task,
                &working_dir_for_task,
            );
            Ok::<_, RpcError>(summary)
        })
        .await;
        match result {
            Ok(summary) => {
                histogram!("session_context_warmup_seconds").record(start.elapsed().as_secs_f64());
                if summary.loaded_rules {
                    counter!("session_context_warmups_total", "kind" => "rules").increment(1);
                }
                if summary.loaded_memory {
                    counter!("session_context_warmups_total", "kind" => "memory").increment(1);
                }
            }
            Err(error) => {
                counter!("session_context_warmup_failures_total").increment(1);
                tracing::warn!(error = %error, "optimistic context preload task failed");
            }
        }
    });
    if let Some(coord) = shutdown_coordinator {
        coord.register_task(handle);
    }
}

/// Discover rules files and memory, then persist + broadcast notification events.
fn emit_optimistic_context_events(
    event_store: &std::sync::Arc<crate::events::EventStore>,
    context_artifacts: &ContextArtifactsService,
    broadcast: &std::sync::Arc<EventEmitter>,
    session_id: &str,
    working_dir: &str,
) -> OptimisticContextSummary {
    let settings = crate::settings::get_settings();
    let artifacts = context_artifacts.load(event_store.as_ref(), working_dir, &settings);
    let mut summary = OptimisticContextSummary::default();

    let files_json: Vec<serde_json::Value> = artifacts
        .session
        .rules
        .files
        .iter()
        .map(|file| {
            let depth = if file.level == RuleFileLevel::Global {
                0
            } else {
                file.depth
            };
            json!({
                "path": file.path.to_string_lossy(),
                "relativePath": file.relative_path,
                "level": file.level.as_str(),
                "depth": depth,
                "sizeBytes": file.size_bytes,
            })
        })
        .collect();

    if !files_json.is_empty() {
        summary.loaded_rules = true;
        #[allow(clippy::cast_possible_truncation)]
        let total = files_json.len() as u32;
        let merged_tokens = artifacts.session.rules.merged_tokens_estimate();
        let _ = event_store.append(&crate::events::AppendOptions {
            session_id,
            event_type: crate::events::EventType::RulesLoaded,
            payload: json!({
                "files": files_json,
                "totalFiles": total,
                "mergedTokens": merged_tokens,
                "dynamicRulesCount": 0,
            }),
            parent_id: None,
            sequence: None,
        });
        let _ = broadcast.emit(TronEvent::RulesLoaded {
            base: BaseEvent::now(session_id),
            total_files: total,
            dynamic_rules_count: 0,
        });
    }

    summary
}

#[derive(Default)]
struct OptimisticContextSummary {
    loaded_rules: bool,
    loaded_memory: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use tempfile::tempdir;

    use crate::events::EventStore;
    use crate::runtime::Orchestrator;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::skills::registry::SkillRegistry;
    use crate::worktree::{WorktreeCoordinator, WorktreeConfig, AcquireResult};

    async fn run_cmd(dir: &std::path::Path, args: &[&str]) {
        let status = tokio::process::Command::new(args[0])
            .args(&args[1..])
            .current_dir(dir)
            .output()
            .await
            .unwrap();
        assert!(
            status.status.success(),
            "cmd {:?} failed: {}",
            args,
            String::from_utf8_lossy(&status.stderr)
        );
    }

    async fn init_repo(dir: &std::path::Path) {
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "# test").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
    }

    /// Build a test context with a worktree coordinator wired up.
    fn make_context_with_worktree(store: Arc<EventStore>) -> (RpcContext, Arc<WorktreeCoordinator>) {
        let mgr = Arc::new(crate::runtime::orchestrator::session_manager::SessionManager::new(
            store.clone(),
        ));
        let orch = Arc::new(Orchestrator::new(mgr.clone()));
        let coord = Arc::new(WorktreeCoordinator::new(WorktreeConfig::default(), store.clone()));

        let ctx = RpcContext {
            orchestrator: orch,
            session_manager: mgr,
            event_store: store,
            skill_registry: Arc::new(parking_lot::RwLock::new(SkillRegistry::new())),
            settings_path: std::path::PathBuf::from("/tmp/tron-test-settings.json"),
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            transcription_engine: Arc::new(std::sync::OnceLock::new()),
            subagent_manager: None,
            health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
            origin: "localhost:9847".to_string(),
            cron_scheduler: None,
            worktree_coordinator: Some(coord.clone()),
            device_request_broker: None,
            context_artifacts: Arc::new(
                crate::server::rpc::session_context::ContextArtifactsService::new(),
            ),
            auth_path: std::path::PathBuf::from("/tmp/tron-test-auth.json"),
            broadcast_manager: None,
            oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
            mcp_router: None,
            display_stream_registry: None,
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            hook_abort_tracker: Arc::new(crate::runtime::hooks::abort_tracker::HookAbortTracker::new()),
        };
        (ctx, coord)
    }

    fn make_store() -> Arc<EventStore> {
        let pool =
            crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    // ── Archive ────────────────────────────────────────────────────────

    #[tokio::test]
    async fn archive_releases_worktree() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let (ctx, coord) = make_context_with_worktree(store.clone());

        let sid = ctx
            .session_manager
            .create_session("model", &dir.path().to_string_lossy(), Some("test"), None)
            .unwrap();

        // Acquire worktree
        let result = coord.maybe_acquire(&sid, dir.path()).await.unwrap();
        let wt_path = match result {
            AcquireResult::Acquired(ref info) => info.worktree_path.clone(),
            other => panic!("expected Acquired, got {other:?}"),
        };
        assert!(wt_path.exists(), "worktree dir should exist after acquire");
        assert!(coord.get_info(&sid).is_some(), "coordinator should track session");

        // Archive via command service
        SessionCommandService::archive(&ctx, sid.clone()).await.unwrap();

        // Worktree should be released
        assert!(coord.get_info(&sid).is_none(), "coordinator should no longer track session");
        assert!(!wt_path.exists(), "worktree directory should be removed");

        // worktree.released event should exist
        let events = store
            .get_events_by_type(&sid, &["worktree.released"], None)
            .unwrap();
        assert_eq!(events.len(), 1, "should have exactly one worktree.released event");

        // Session should be archived (ended_at set)
        let session = store.get_session(&sid).unwrap().unwrap();
        assert!(session.ended_at.is_some(), "session should be archived");
    }

    #[tokio::test]
    async fn archive_without_worktree_succeeds() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"), None)
            .unwrap();

        SessionCommandService::archive(&ctx, sid.clone()).await.unwrap();

        let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
        assert!(session.ended_at.is_some());
    }

    // ── Delete ─────────────────────────────────────────────────────────

    #[tokio::test]
    async fn delete_releases_worktree() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let (ctx, coord) = make_context_with_worktree(store.clone());

        let sid = ctx
            .session_manager
            .create_session("model", &dir.path().to_string_lossy(), Some("test"), None)
            .unwrap();

        let result = coord.maybe_acquire(&sid, dir.path()).await.unwrap();
        let wt_path = match result {
            AcquireResult::Acquired(ref info) => info.worktree_path.clone(),
            other => panic!("expected Acquired, got {other:?}"),
        };
        assert!(wt_path.exists());

        SessionCommandService::delete(&ctx, sid.clone()).await.unwrap();

        assert!(coord.get_info(&sid).is_none(), "coordinator should no longer track session");
        assert!(!wt_path.exists(), "worktree directory should be removed");

        // Session should be fully deleted
        assert!(store.get_session(&sid).unwrap().is_none(), "session should be deleted");
    }

    #[tokio::test]
    async fn delete_without_worktree_succeeds() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"), None)
            .unwrap();

        SessionCommandService::delete(&ctx, sid.clone()).await.unwrap();

        assert!(ctx.event_store.get_session(&sid).unwrap().is_none());
    }

}
