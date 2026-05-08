use super::*;
use std::sync::Arc;
use tempfile::tempdir;

use crate::events::EventStore;
use crate::runtime::Orchestrator;
use crate::server::shared::context::ServerRuntimeContext;
use crate::server::shared::test_support::make_test_context;
use crate::skills::registry::SkillRegistry;
use crate::worktree::{AcquireResult, WorktreeConfig, WorktreeCoordinator};

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
fn make_context_with_worktree(
    store: Arc<EventStore>,
) -> (ServerRuntimeContext, Arc<WorktreeCoordinator>) {
    let mgr =
        Arc::new(crate::runtime::orchestrator::session_manager::SessionManager::new(store.clone()));
    let orch = Arc::new(Orchestrator::new(mgr.clone()));
    let coord = Arc::new(WorktreeCoordinator::new(
        WorktreeConfig::default(),
        store.clone(),
    ));
    let home = crate::server::shared::test_support::unique_tron_home();
    let settings_path = crate::server::shared::test_support::test_user_profile_path(&home);
    let profile_runtime = crate::server::shared::test_support::test_profile_runtime(&home);
    let auth_path = crate::server::shared::test_support::test_auth_path(&home);

    let ctx = ServerRuntimeContext {
        orchestrator: orch,
        session_manager: mgr,
        event_store: store,
        engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
        skill_registry: Arc::new(parking_lot::RwLock::new(SkillRegistry::new())),
        memory_registry: Arc::new(parking_lot::Mutex::new(
            crate::runtime::memory::MemoryRegistry::new(),
        )),
        settings_path,
        profile_runtime,
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        codex_app_server: None,
        worktree_coordinator: Some(coord.clone()),
        device_request_broker: None,
        context_artifacts: Arc::new(
            crate::server::domains::session::context::ContextArtifactsService::new(),
        ),
        auth_path,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(crate::runtime::hooks::abort_tracker::HookAbortTracker::new()),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
        onboarded_marker_path: std::path::PathBuf::from("/tmp/tron-test-onboarded.marker"),
        release_fetcher: None,
        updater_state_path: std::path::PathBuf::from("/tmp/tron-test-updater-state.json"),
    };
    (ctx, coord)
}

fn make_store() -> Arc<EventStore> {
    let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
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
    assert!(
        coord.get_info(&sid).is_some(),
        "coordinator should track session"
    );

    // Archive via command service
    SessionCommandService::archive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    // Worktree should be released
    assert!(
        coord.get_info(&sid).is_none(),
        "coordinator should no longer track session"
    );
    assert!(!wt_path.exists(), "worktree directory should be removed");

    // worktree.released event should exist
    let events = store
        .get_events_by_type(&sid, &["worktree.released"], None)
        .unwrap();
    assert_eq!(
        events.len(),
        1,
        "should have exactly one worktree.released event"
    );

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

    SessionCommandService::archive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

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

    SessionCommandService::delete(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    assert!(
        coord.get_info(&sid).is_none(),
        "coordinator should no longer track session"
    );
    assert!(!wt_path.exists(), "worktree directory should be removed");

    // Session should be fully deleted
    assert!(
        store.get_session(&sid).unwrap().is_none(),
        "session should be deleted"
    );
}

#[tokio::test]
async fn delete_without_worktree_succeeds() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"), None)
        .unwrap();

    SessionCommandService::delete(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    assert!(ctx.event_store.get_session(&sid).unwrap().is_none());
}

// ── Bulk archive: archive_older_than ──────────────────────────────

/// Helper: set a session's `last_activity_at` to a specific RFC3339 time
/// so batch-archive tests can control the "age" of each fixture without
/// sleeping real wall-clock time.
fn set_last_activity(store: &EventStore, session_id: &str, rfc3339: &str) {
    let conn = store.pool().get().unwrap();
    conn.execute(
        "UPDATE sessions SET last_activity_at = ?1 WHERE id = ?2",
        rusqlite::params![rfc3339, session_id],
    )
    .unwrap();
}

/// Sessions with `last_activity_at` older than `days` days ago are
/// archived; fresh sessions are left untouched. This is the happy path —
/// if this regresses, batch cleanup is broken.
#[tokio::test]
async fn archive_older_than_archives_stale_and_preserves_fresh() {
    let ctx = make_test_context();

    let stale = ctx
        .session_manager
        .create_session("m", "/tmp", Some("stale"), None)
        .unwrap();
    let fresh = ctx
        .session_manager
        .create_session("m", "/tmp", Some("fresh"), None)
        .unwrap();

    let ten_days_ago = (chrono::Utc::now() - chrono::Duration::days(10)).to_rfc3339();
    set_last_activity(&ctx.event_store, &stale, &ten_days_ago);

    let result = SessionCommandService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();

    assert_eq!(result["archivedCount"].as_u64().unwrap(), 1);
    let ids: Vec<&str> = result["archivedSessionIds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![stale.as_str()]);

    let stale_row = ctx.event_store.get_session(&stale).unwrap().unwrap();
    let fresh_row = ctx.event_store.get_session(&fresh).unwrap().unwrap();
    assert!(stale_row.ended_at.is_some(), "stale should be archived");
    assert!(fresh_row.ended_at.is_none(), "fresh should stay active");
}

/// Already-archived sessions must be skipped — `ended_at IS NOT NULL`
/// is part of the candidate filter, so the batch must not re-archive
/// (which would churn broadcasts for no reason).
#[tokio::test]
async fn archive_older_than_skips_already_archived() {
    let ctx = make_test_context();

    let s1 = ctx
        .session_manager
        .create_session("m", "/tmp", Some("s1"), None)
        .unwrap();

    // Pre-archive s1 by hand.
    SessionCommandService::archive(&Deps::from_test_context(&ctx), s1.clone())
        .await
        .unwrap();

    let ten_days_ago = (chrono::Utc::now() - chrono::Duration::days(10)).to_rfc3339();
    set_last_activity(&ctx.event_store, &s1, &ten_days_ago);

    let result = SessionCommandService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();
    assert_eq!(result["archivedCount"].as_u64().unwrap(), 0);
    assert!(result["archivedSessionIds"].as_array().unwrap().is_empty());
}

/// Subagent sessions (spawning_session_id IS NOT NULL) must be excluded
/// from the batch — archiving a subagent mid-parent-turn would break
/// the parent's resume path. The existing `exclude_subagents: true`
/// filter covers this; the test is a regression guard.
#[tokio::test]
async fn archive_older_than_skips_subagents() {
    let ctx = make_test_context();

    let parent = ctx
        .session_manager
        .create_session("m", "/tmp", Some("parent"), None)
        .unwrap();
    let subagent = ctx
        .session_manager
        .create_session_for_subagent("m", "/tmp", Some("sub"), &parent, "task", "desc")
        .unwrap();

    let ten_days_ago = (chrono::Utc::now() - chrono::Duration::days(10)).to_rfc3339();
    set_last_activity(&ctx.event_store, &parent, &ten_days_ago);
    set_last_activity(&ctx.event_store, &subagent, &ten_days_ago);

    let result = SessionCommandService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();
    let archived_ids: Vec<&str> = result["archivedSessionIds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    // Only the parent is archived; the subagent is filtered out by
    // exclude_subagents.
    assert_eq!(archived_ids, vec![parent.as_str()]);
}

/// Non-user sessions (source = "cron", etc.) must be excluded — a user
/// cleanup shouldn't sweep automation-owned sessions. The `user_only`
/// filter covers this; regression guard for the behaviour.
#[tokio::test]
async fn archive_older_than_skips_non_user_sources() {
    let ctx = make_test_context();

    let user_sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("user"), None)
        .unwrap();
    let cron_sid = ctx
        .session_manager
        .create_session("m", "/tmp", Some("cron"), None)
        .unwrap();
    assert!(ctx.event_store.update_source(&cron_sid, "cron").unwrap());

    let ten_days_ago = (chrono::Utc::now() - chrono::Duration::days(10)).to_rfc3339();
    set_last_activity(&ctx.event_store, &user_sid, &ten_days_ago);
    set_last_activity(&ctx.event_store, &cron_sid, &ten_days_ago);

    let result = SessionCommandService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();
    let archived_ids: Vec<&str> = result["archivedSessionIds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(archived_ids, vec![user_sid.as_str()]);
}

/// `days == 0` is legal — it archives every currently-active user-facing
/// session. Provided as a documented cleanup-all shortcut. The cutoff is
/// `now`, so every session with a past timestamp (which is all of them)
/// qualifies.
#[tokio::test]
async fn archive_older_than_zero_days_archives_all_active() {
    let ctx = make_test_context();

    let a = ctx
        .session_manager
        .create_session("m", "/tmp", Some("a"), None)
        .unwrap();
    let b = ctx
        .session_manager
        .create_session("m", "/tmp", Some("b"), None)
        .unwrap();

    // Force both timestamps to the past so they unambiguously precede
    // the cutoff even on very fast machines.
    let one_hour_ago = (chrono::Utc::now() - chrono::Duration::hours(1)).to_rfc3339();
    set_last_activity(&ctx.event_store, &a, &one_hour_ago);
    set_last_activity(&ctx.event_store, &b, &one_hour_ago);

    let result = SessionCommandService::archive_older_than(&Deps::from_test_context(&ctx), 0)
        .await
        .unwrap();
    assert_eq!(result["archivedCount"].as_u64().unwrap(), 2);

    for sid in [&a, &b] {
        let row = ctx.event_store.get_session(sid).unwrap().unwrap();
        assert!(row.ended_at.is_some(), "session {sid} should be archived");
    }
}

/// The cutoff field echoed in the response is always in the past —
/// callers rely on this to render "Archived everything before <date>"
/// and to feed the next run of the same retention policy.
#[tokio::test]
async fn archive_older_than_returns_cutoff_in_the_past() {
    let ctx = make_test_context();
    let now = chrono::Utc::now();
    let result = SessionCommandService::archive_older_than(&Deps::from_test_context(&ctx), 30)
        .await
        .unwrap();
    let cutoff_str = result["cutoff"].as_str().unwrap();
    let cutoff: chrono::DateTime<chrono::Utc> = cutoff_str.parse().unwrap();
    assert!(cutoff < now, "cutoff {cutoff:?} must precede now {now:?}");
    let delta = now - cutoff;
    assert!(
        delta.num_days() >= 29 && delta.num_days() <= 31,
        "cutoff delta {} days",
        delta.num_days()
    );
}

/// Empty store: no candidates, no panic, no error. This is how the iOS
/// client will call the capability on a fresh install — it must not special-case.
#[tokio::test]
async fn archive_older_than_on_empty_store_returns_zero() {
    let ctx = make_test_context();
    let result = SessionCommandService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();
    assert_eq!(result["archivedCount"].as_u64().unwrap(), 0);
    assert!(result["archivedSessionIds"].as_array().unwrap().is_empty());
    assert!(result["skipped"].as_array().unwrap().is_empty());
}

/// Batch archive on multiple stale sessions archives all of them and
/// reports the full set in `archivedSessionIds`. Guards against an
/// early-return-on-first-failure loop.
#[tokio::test]
async fn archive_older_than_archives_batch_multiple_stale() {
    let ctx = make_test_context();

    let a = ctx
        .session_manager
        .create_session("m", "/tmp", Some("a"), None)
        .unwrap();
    let b = ctx
        .session_manager
        .create_session("m", "/tmp", Some("b"), None)
        .unwrap();
    let c = ctx
        .session_manager
        .create_session("m", "/tmp", Some("c"), None)
        .unwrap();

    let old = (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();
    for sid in [&a, &b, &c] {
        set_last_activity(&ctx.event_store, sid, &old);
    }

    let result = SessionCommandService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();
    assert_eq!(result["archivedCount"].as_u64().unwrap(), 3);

    let archived: std::collections::HashSet<&str> = result["archivedSessionIds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert!(archived.contains(a.as_str()));
    assert!(archived.contains(b.as_str()));
    assert!(archived.contains(c.as_str()));
}
