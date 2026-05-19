#![allow(unused_imports)]

pub(super) use super::super::{Deps, SessionCommandService};
pub(super) use crate::domains::agent::runner::Orchestrator;
pub(super) use crate::domains::session::event_store::EventStore;
pub(super) use crate::domains::skills::registry::SkillRegistry;
pub(super) use crate::domains::worktree::{AcquireResult, WorktreeConfig, WorktreeCoordinator};
pub(super) use crate::shared::server::context::ServerRuntimeContext;
pub(super) use crate::shared::server::test_support::make_test_context;
pub(super) use std::sync::Arc;
pub(super) use tempfile::tempdir;

pub(super) async fn run_cmd(dir: &std::path::Path, args: &[&str]) {
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

pub(super) async fn init_repo(dir: &std::path::Path) {
    run_cmd(dir, &["git", "init"]).await;
    run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
    run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
    std::fs::write(dir.join("README.md"), "# test").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "init"]).await;
}

pub(super) fn make_context_with_worktree(
    store: Arc<EventStore>,
) -> (ServerRuntimeContext, Arc<WorktreeCoordinator>) {
    let mgr = Arc::new(
        crate::domains::agent::runner::orchestrator::session_manager::SessionManager::new(
            store.clone(),
        ),
    );
    let orch = Arc::new(Orchestrator::new(mgr.clone()));
    let coord = Arc::new(WorktreeCoordinator::new(
        WorktreeConfig::default(),
        store.clone(),
    ));
    let home = crate::shared::server::test_support::unique_tron_home();
    let settings_path = crate::shared::server::test_support::test_user_profile_path(&home);
    let profile_runtime = crate::shared::server::test_support::test_profile_runtime(&home);
    let auth_path = crate::shared::server::test_support::test_auth_path(&home);

    let ctx = ServerRuntimeContext {
        orchestrator: orch,
        session_manager: mgr,
        event_store: store,
        engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
        skill_registry: Arc::new(parking_lot::RwLock::new(SkillRegistry::new())),
        memory_registry: Arc::new(parking_lot::Mutex::new(
            crate::domains::agent::runner::memory::MemoryRegistry::new(),
        )),
        settings_path,
        profile_runtime,
        agent_deps: None,
        capability_support_config: crate::shared::server::context::CapabilitySupportConfig::default(
        ),
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(crate::domains::model::providers::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        worktree_coordinator: Some(coord.clone()),
        device_request_broker: None,
        context_artifacts: Arc::new(
            crate::domains::session::context::ContextArtifactsService::new(),
        ),
        auth_path,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(
            crate::domains::agent::runner::hooks::abort_tracker::HookAbortTracker::new(),
        ),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: std::path::PathBuf::from("/tmp/tron-test-onboarded.marker"),
        release_fetcher: None,
        updater_state_path: std::path::PathBuf::from("/tmp/tron-test-updater-state.json"),
    };
    (ctx, coord)
}

pub(super) fn make_store() -> Arc<EventStore> {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    Arc::new(EventStore::new(pool))
}

pub(super) fn set_last_activity(store: &EventStore, session_id: &str, rfc3339: &str) {
    let conn = store.pool().get().unwrap();
    conn.execute(
        "UPDATE sessions SET last_activity_at = ?1 WHERE id = ?2",
        rusqlite::params![rfc3339, session_id],
    )
    .unwrap();
}
