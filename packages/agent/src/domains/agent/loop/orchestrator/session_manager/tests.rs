use super::*;

fn make_manager() -> SessionManager {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::ensure_schema(&conn).unwrap();
    }
    SessionManager::new(Arc::new(EventStore::new(pool)))
}

#[tokio::test]
async fn create_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();
    assert!(!sid.is_empty());
    assert!(mgr.is_cached(&sid));
    assert_eq!(mgr.cached_count(), 1);
}

#[tokio::test]
async fn resume_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    // Drop from the projection cache.
    mgr.invalidate_session(&sid);
    assert!(!mgr.is_cached(&sid));

    // Resume should reconstruct
    let state = mgr.resume_session(&sid).unwrap();
    assert_eq!(state.model, "test-model");
    assert!(mgr.is_cached(&sid));
}

#[tokio::test]
async fn resume_already_active() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    // Resume when already active should return existing
    let first = mgr.resume_session(&sid).unwrap();
    let second = mgr.resume_session(&sid).unwrap();
    assert_eq!(first.model, "test-model");
    assert!(
        Arc::ptr_eq(&first, &second),
        "cache must reuse one projection"
    );
    assert_eq!(mgr.cached_count(), 1);
}

#[test]
fn end_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    mgr.end_session(&sid).unwrap();
    assert!(!mgr.is_cached(&sid));
}

/// Anchors the wire contract that `session.end` is an actively emitted
/// event. This test guards against any future change that accidentally
/// stops emitting the event (e.g. refactoring `end_session` to skip
/// the append) because the iOS display layer treats the event as current.
#[test]
fn end_session_emits_session_end_event() {
    use crate::domains::session::event_store::ListEventsOptions;

    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    mgr.end_session(&sid).unwrap();

    let events = mgr
        .event_store
        .get_events_by_session(&sid, &ListEventsOptions::default())
        .unwrap();
    let end_event = events
        .iter()
        .find(|e| e.event_type == EventType::SessionEnd.as_str())
        .expect("end_session must persist a session.end event");
    let payload: serde_json::Value = serde_json::from_str(&end_event.payload).unwrap();
    assert_eq!(
        payload.get("reason").and_then(|r| r.as_str()),
        Some("completed"),
        "session.end payload must carry reason=completed"
    );
}

#[tokio::test]
async fn archive_invalidates_cache() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    mgr.archive_session(&sid).unwrap();
    assert!(!mgr.is_cached(&sid));
}

#[tokio::test]
async fn delete_session() {
    let mgr = make_manager();
    let sid = mgr
        .create_session("test-model", "/tmp", Some("test"))
        .unwrap();

    mgr.delete_session(&sid).unwrap();
    assert!(!mgr.is_cached(&sid));
}

#[tokio::test]
async fn shutdown_ends_unarchived_sessions_and_clears_cache() {
    let mgr = make_manager();
    let first = mgr.create_session("model-a", "/tmp/a", Some("s1")).unwrap();
    let second = mgr.create_session("model-b", "/tmp/b", Some("s2")).unwrap();
    let archived = mgr
        .create_session("model-c", "/tmp/c", Some("archived"))
        .unwrap();
    mgr.archive_session(&archived).unwrap();

    mgr.end_unarchived_sessions_for_shutdown();

    for session_id in [first, second] {
        let session = mgr.event_store.get_session(&session_id).unwrap().unwrap();
        assert!(session.ended_at.is_some());
        assert!(!mgr.is_cached(&session_id));
    }

    assert_eq!(mgr.event_store.count_events(&archived).unwrap(), 1);
}

#[tokio::test]
async fn session_not_found() {
    let mgr = make_manager();
    let result = mgr.resume_session("nonexistent");
    assert!(result.is_err());
}

// ── Cache eviction tests ────────────────────────────────────

#[tokio::test]
async fn evict_idle_session() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    // Force last_accessed to the past
    if let Some(cached) = mgr.cached_sessions.get(&sid) {
        *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
    }

    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 1);
    assert!(!mgr.is_cached(&sid));
}

#[tokio::test]
async fn evict_preserves_recent_session() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 0);
    assert!(mgr.is_cached(&sid));
}

#[tokio::test]
async fn cold_prompt_resume_is_pinned_until_cleanup() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    mgr.invalidate_session(&sid);
    assert!(!mgr.is_cached(&sid));

    let state = mgr.resume_session_for_prompt(&sid).unwrap();
    assert_eq!(state.model, "m");
    let ordinary_resume = mgr.resume_session(&sid).unwrap();
    assert!(Arc::ptr_eq(&state, &ordinary_resume));
    if let Some(cached) = mgr.cached_sessions.get(&sid) {
        *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
    }

    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 0, "prompt-pinned session must not be evicted");
    assert!(mgr.is_cached(&sid));

    mgr.invalidate_session(&sid);
    assert!(!mgr.is_cached(&sid));
}

#[tokio::test]
async fn evicted_session_reconstructs_on_resume() {
    let mgr = make_manager();
    let sid = mgr.create_session("m", "/tmp", Some("test")).unwrap();

    // Evict it
    if let Some(cached) = mgr.cached_sessions.get(&sid) {
        *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
    }
    let _ = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert!(!mgr.is_cached(&sid));

    // Resume should reconstruct
    let state = mgr.resume_session(&sid).unwrap();
    assert_eq!(state.model, "m");
    assert!(mgr.is_cached(&sid));
}

#[tokio::test]
async fn evict_mixed_idle_and_active() {
    let mgr = make_manager();
    let idle = mgr.create_session("m", "/tmp", Some("idle")).unwrap();
    let recent = mgr.create_session("m", "/tmp", Some("recent")).unwrap();

    if let Some(cached) = mgr.cached_sessions.get(&idle) {
        *cached.last_accessed.lock() = Instant::now() - Duration::from_secs(7200);
    }

    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 1);
    assert!(!mgr.is_cached(&idle));
    assert!(mgr.is_cached(&recent));
}

#[tokio::test]
async fn evict_zero_ttl_evicts_all_idle() {
    let mgr = make_manager();
    let s1 = mgr.create_session("m", "/tmp", Some("s1")).unwrap();
    let s2 = mgr.create_session("m", "/tmp", Some("s2")).unwrap();

    let evicted = mgr.evict_idle_sessions(Duration::ZERO);
    assert_eq!(evicted, 2);
    assert!(!mgr.is_cached(&s1));
    assert!(!mgr.is_cached(&s2));
}

#[tokio::test]
async fn evict_empty_map_is_noop() {
    let mgr = make_manager();
    let evicted = mgr.evict_idle_sessions(Duration::from_secs(3600));
    assert_eq!(evicted, 0);
}
